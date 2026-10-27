#if os(macOS)
import Accelerate
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import FOHCore

/// The bridge's meter source: input levels from the audio interface (read-only AUHAL capture), MainStage's
/// output from a Core Audio process tap, and an RTA on whichever input channels a client subscribed to.
///
/// Two private serial queues:
/// - the *control* queue opens and closes devices and taps. It may stall while macOS shows a permission prompt
///   (Microphone / System Audio Recording), which must never freeze the meters or the bridge;
/// - the *meter* queue runs the timers and delivers `onFrame` / `onRTA`. It never blocks.
/// `start`, `stop` and `setRTAChannels` return immediately and may be called from any thread. After `stop()`
/// returns no further callbacks are delivered. A missing device, a denied permission or MainStage not running
/// only means that half reports nothing — nothing throws.
///
/// The input follows the hardware: a HAL listener (plus a 5 s poll as a fallback) reopens the chosen interface
/// within about half a second of it being plugged back in, closes it when it's unplugged, and with "system
/// default" follows macOS's default input. See `InputDevicePolicy`.
public final class CoreAudioMeterSource: MeterSource, @unchecked Sendable {
    public static let mainStageBundleID = "com.apple.mainstage3"

    public var onFrame: (@Sendable (MeterFrame) -> Void)?
    public var onRTA: (@Sendable ([Int], [UInt8]) -> Void)?

    public var inputDeviceName: String? { status.read().inputName }
    public var inputChannelCount: Int? { status.read().inputChannels }
    public var outputTapName: String? { status.read().tapName }
    /// The device MainStage's output is tapped on (its own preferred device, else the system output).
    public var outputDeviceName: String? { status.read().outputDeviceName }
    /// "per-channel 18 ch on Scarlett 18i20" or "stereo mixdown".
    public var outputTapSummary: String? { status.read().outputSummary }

    /// Bundle id of the app whose output is tapped (MainStage; overridable for testing).
    public var tapBundleID: String = CoreAudioMeterSource.mainStageBundleID
    /// Meter frames per second.
    public var frameRate: Double = 25

    private struct Status {
        var inputName: String?
        var inputChannels: Int?
        var inputSampleRate: Double?
        var tapName: String?
        var outputDeviceName: String?
        var outputSummary: String?
    }
    private let status = LockedBox(Status())
    private let generation = LockedBox(0)

    private let controlQueue = DispatchQueue(label: "io.itstudios.foh.meters.control", qos: .userInitiated)
    private let meterQueue = DispatchQueue(label: "io.itstudios.foh.meters", qos: .userInitiated)

    // Control-queue state.
    private var log: @Sendable (String) -> Void = { _ in }
    private var requestedUID: String?
    private var input: InputCapture?
    /// UID of the device `input` was opened on (kept after the device vanishes, so the change is noticed).
    private var openUID: String?
    private var lastDecision: InputDevicePolicy.Decision?
    private var watcher: AudioDeviceWatcher?
    private var tap: AnyObject?
    private var tapPID: pid_t?
    private var tapFailedPID: pid_t?
    private var tapPlan: OutputTapPlan?
    private var perChannelFailed: Set<String> = []
    private var pollTimer: DispatchSourceTimer?

    // Meter-queue state.
    private var meterTimers: [DispatchSourceTimer] = []
    private var analyzer: RTAAnalyzer?

    // Shared with the audio threads.
    private let inputLevels = LevelAccumulator()
    private let outputLevels = LevelAccumulator()
    private let rtaChannels = LockedBox<[Int]>([])
    private let rtaFIFO = SampleFIFO(capacity: 1 << 17)
    private var rtaScratch = [Float](repeating: 0, count: 8192)

    public init() {}

    deinit {
        pollTimer?.cancel()
        meterTimers.forEach { $0.cancel() }
    }

    // MARK: MeterSource

    public func start(inputDeviceUID: String?, log: @escaping @Sendable (String) -> Void) {
        let gen = generation.read() + 1
        generation.write(gen)
        meterQueue.sync { startMeterTimers(generation: gen) }
        requestMicrophoneAccessIfNeeded(log: log)
        controlQueue.async { [self] in
            guard generation.read() == gen else { return }
            teardownInput()
            teardownTap()
            self.log = log
            requestedUID = inputDeviceUID
            lastDecision = nil
            followInput()
            refreshTap()
            startPollTimer(generation: gen)
            watcher = AudioDeviceWatcher(queue: controlQueue) { [weak self] in
                guard let self, self.generation.read() == gen else { return }
                self.followInput()
            }
        }
    }

    public func stop() {
        generation.write(generation.read() + 1)
        meterQueue.sync {
            meterTimers.forEach { $0.cancel() }
            meterTimers.removeAll()
            analyzer = nil
        }
        rtaFIFO.clear()
        controlQueue.async { [self] in
            pollTimer?.cancel()
            pollTimer = nil
            watcher?.stop()
            watcher = nil
            teardownInput()
            teardownTap()
        }
    }

    public func setRTAChannels(_ channels: [Int]) {
        rtaChannels.write(channels)
        rtaFIFO.clear()
        meterQueue.async { [self] in analyzer?.reset() }
    }

    // MARK: Permission

    /// Never called on our queues: the system call can block until the user answers the prompt.
    private func requestMicrophoneAccessIfNeeded(log: @escaping @Sendable (String) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            log("Meters: asking for microphone access (needed to read your interface's inputs)")
            DispatchQueue.global(qos: .utility).async {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    log(granted ? "Meters: microphone access granted" : "Meters: microphone access denied — input meters stay silent")
                }
            }
        case .denied, .restricted:
            log("Meters: microphone access is off — input meters will be silent (System Settings › Privacy & Security › Microphone)")
        @unknown default:
            break
        }
    }

    // MARK: Input (control queue)

    /// Open, switch or close the input capture to match the chosen device and what's connected now.
    /// A capture that failed to open (no permission yet) is simply retried on the next poll.
    private func followInput() {
        let connected = AudioDevices.inputDevices()
        let decision = InputDevicePolicy.decide(chosenUID: requestedUID, connected: connected.map(\.uid),
                                                defaultUID: connected.first(where: \.isDefault)?.uid)
        let changed = decision != lastDecision
        lastDecision = decision
        var closing: String?
        if InputDevicePolicy.needsChange(openUID: openUID, for: decision) {
            if input != nil {
                closing = status.read().inputName ?? "The input device"
                teardownInput()
            }
            if case .open(let uid) = decision { openInput(uid: uid) }
        }
        switch decision {
        case .open:
            break
        case .waiting(let uid):
            if let closing {
                log("Meters: \(closing) was unplugged — waiting for it to come back")
            } else if changed {
                log("Meters: input device \(uid) isn't connected — waiting for it")
            }
        case .noDevice:
            if changed || closing != nil { log("Meters: no input device") }
        }
    }

    private func openInput(uid: String) {
        guard let device = HAL.device(forUID: uid) else { return }
        do {
            let capture = try InputCapture(deviceID: device)
            inputLevels.configure(channels: capture.channels)
            capture.onBuffers = { [weak self] list, frames in self?.handleInput(list, frames: frames) }
            try capture.start()
            input = capture
            openUID = uid
            let name = HAL.name(device) ?? "Input"
            var s = status.read()
            s.inputName = name
            s.inputChannels = capture.channels
            s.inputSampleRate = capture.sampleRate
            status.write(s)
            log("Meters: reading \(capture.channels) input channel(s) from \(name) at \(Int(capture.sampleRate)) Hz")
        } catch {
            log("Meters: couldn't open the input device — \(error)")
        }
    }

    private func teardownInput() {
        input?.stop()
        input = nil
        openUID = nil
        var s = status.read()
        s.inputName = nil
        s.inputChannels = nil
        s.inputSampleRate = nil
        status.write(s)
    }

    /// Real-time thread: levels for every channel, plus the summed RTA channels into the FIFO.
    private func handleInput(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        inputLevels.add(list, frames: frames)
        let chans = rtaChannels.read()
        guard !chans.isEmpty else { return }
        let n = min(frames, rtaScratch.count)
        rtaScratch.withUnsafeMutableBufferPointer { scratch in
            guard let out = scratch.baseAddress else { return }
            var first = true
            for c in chans where c < list.count {
                guard let data = list[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if first {
                    out.update(from: data, count: n)
                    first = false
                } else {
                    vDSP_vadd(out, 1, data, 1, out, 1, vDSP_Length(n))
                }
            }
            if !first { rtaFIFO.write(out, count: n) }
        }
    }

    // MARK: Output tap (control queue)

    /// The tap plan for the app being metered: MainStage's own device (from its preferences) or the system output.
    private func currentPlan() -> OutputTapPlan {
        tapBundleID == Self.mainStageBundleID
            ? AudioDevices.mainStageOutputPlan(perChannelFailed: perChannelFailed)
            : AudioDevices.systemOutputPlan(perChannel: !perChannelFailed.contains(AudioDevices.defaultOutputUID() ?? ""))
    }

    private static func sameTarget(_ a: OutputTapPlan?, _ b: OutputTapPlan) -> Bool {
        guard let a else { return false }
        return a.mode == b.mode && a.deviceUID == b.deviceUID && a.streams == b.streams
    }

    private func refreshTap() {
        guard let pid = RunningApps.pid(bundleID: tapBundleID) else {
            if tap != nil { teardownTap() }
            tapFailedPID = nil
            return
        }
        let plan = currentPlan()
        // Same process, same device, same layout: keep tapping. Anything else (MainStage relaunched, switched
        // interface, interface plugged in) rebuilds the tap.
        if pid == tapPID, tap != nil, Self.sameTarget(tapPlan, plan) { return }
        teardownTap()
        guard #available(macOS 14.2, *) else {
            if tapFailedPID != pid { log("Meters: output metering needs macOS 14.2 or later") }
            tapFailedPID = pid
            return
        }
        do {
            let (capture, fallbackError) = try ProcessTapCapture.make(pid: pid, plan: plan)
            if let fallbackError, let uid = plan.deviceUID {
                perChannelFailed.insert(uid)
                log("Meters: per-channel tap on \(plan.deviceName ?? uid) failed — \(fallbackError); using the stereo mixdown")
            }
            outputLevels.configure(channels: capture.channels)
            capture.onBuffers = { [weak self] list, frames in self?.outputLevels.add(list, frames: frames) }
            try capture.start()
            tap = capture
            tapPID = pid
            tapPlan = capture.plan
            tapFailedPID = nil
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "MainStage"
            var s = status.read()
            s.tapName = name
            s.outputDeviceName = capture.plan.deviceName
            s.outputSummary = capture.plan.summary
            status.write(s)
            log("Meters: tapping \(name)'s output — \(capture.plan.summary) (\(capture.channels) ch)"
                + (capture.plan.note.map { ". \($0)" } ?? ""))
        } catch {
            // MainStage may not have opened its audio yet; retry on the next poll, logging once per pid.
            if tapFailedPID != pid {
                log("Meters: couldn't tap MainStage's output yet — \(error). Output meters need System Audio Recording permission.")
            }
            tapFailedPID = pid
        }
    }

    private func teardownTap() {
        if #available(macOS 14.2, *), let capture = tap as? ProcessTapCapture { capture.stop() }
        if tap != nil { log("Meters: stopped tapping MainStage's output") }
        tap = nil
        tapPID = nil
        tapPlan = nil
        var s = status.read()
        s.tapName = nil
        s.outputDeviceName = nil
        s.outputSummary = nil
        status.write(s)
    }

    private func startPollTimer(generation gen: Int) {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: controlQueue)
        t.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self, self.generation.read() == gen else { return }
            self.refreshTap()
            self.followInput()
        }
        t.resume()
        pollTimer = t
    }

    // MARK: Meter queue

    private func startMeterTimers(generation gen: Int) {
        meterTimers.forEach { $0.cancel() }
        meterTimers = [
            makeTimer(interval: 1 / max(1, frameRate)) { [weak self] in self?.emitFrame(generation: gen) },
            makeTimer(interval: 1.0 / 15) { [weak self] in self?.emitRTA(generation: gen) },
        ]
    }

    private func makeTimer(interval: TimeInterval, _ handler: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: meterQueue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        t.setEventHandler(handler: handler)
        t.resume()
        return t
    }

    private func emitFrame(generation gen: Int) {
        guard generation.read() == gen else { return }
        let s = status.read()
        let now = ProcessInfo.processInfo.systemUptime
        let none: (peak: [UInt8], rms: [UInt8]) = ([], [])
        let i = s.inputName != nil ? inputLevels.take(now: now) : none
        let o = s.tapName != nil ? outputLevels.take(now: now) : none
        guard !i.peak.isEmpty || !o.peak.isEmpty else { return }
        onFrame?(MeterFrame(inputPeak: i.peak, inputRMS: i.rms, outputPeak: o.peak, outputRMS: o.rms))
    }

    private func emitRTA(generation gen: Int) {
        guard generation.read() == gen else { return }
        let chans = rtaChannels.read()
        guard !chans.isEmpty, let rate = status.read().inputSampleRate else { return }
        if analyzer == nil || analyzer?.sampleRate != rate { analyzer = RTAAnalyzer(sampleRate: rate) }
        guard let analyzer else { return }
        let samples = rtaFIFO.drain()
        guard !samples.isEmpty else { return }
        if analyzer.process(samples) > 0 || analyzer.hasData {
            onRTA?(chans, analyzer.bandBytes())
        }
    }
}
#endif

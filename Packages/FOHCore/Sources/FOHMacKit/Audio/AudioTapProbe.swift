#if os(macOS)
import AppKit
import Foundation

public enum RunningApps {
    public static func pid(bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }
}

/// Process-tap any process and report its levels — `fohctl tap` uses it to test taps without MainStage.
@available(macOS 14.2, *)
public final class AudioTapProbe: @unchecked Sendable {
    public var channels: Int { capture.channels }
    public var sampleRate: Double { capture.sampleRate }
    /// (peak bytes, RMS bytes) per channel, ~10× a second, on a private queue.
    public var onLevels: (@Sendable ([UInt8], [UInt8]) -> Void)?
    public var framesReceived: Int { frames.read() }

    /// "per-channel 2 ch on MacBook Pro Speakers" / "stereo mixdown".
    public var summary: String { capture.plan.summary }
    /// Why per-channel fell back to the mixdown, if it did.
    public let fallbackReason: String?

    private let capture: ProcessTapCapture
    private let levels = LevelAccumulator()
    private let frames = LockedBox(0)
    private var timer: DispatchSourceTimer?

    public init(pid: pid_t, perChannel: Bool = false) throws {
        let made = try ProcessTapCapture.make(pid: pid, plan: AudioDevices.systemOutputPlan(perChannel: perChannel))
        capture = made.0
        fallbackReason = made.fallbackFrom.map { "\($0)" }
        levels.configure(channels: capture.channels)
        capture.onBuffers = { [levels, frames] list, n in
            levels.add(list, frames: n)
            frames.write(frames.read() + n)
        }
    }

    public func start() throws {
        try capture.start()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.itstudios.foh.tapprobe"))
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let l = self.levels.take(now: ProcessInfo.processInfo.systemUptime)
            self.onLevels?(l.peak, l.rms)
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        capture.stop()
    }
}
#endif

import Foundation
import FOHCore
import FOHMacKit

// Audio metering / RTA test commands.

private func audioRunLoop(seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
    }
}

private func meterBar(_ byte: UInt8, width: Int = 30) -> String {
    let filled = Int((Double(byte) / 255 * Double(width)).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

private func dbText(_ byte: UInt8) -> String {
    let db = MeterScale.db(fromByte: byte)
    return db.isFinite ? String(format: "%6.1f dB", db) : "  -inf dB"
}

/// Prints one frame's bars, at most every `interval` seconds.
private final class FramePrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval
    init(interval: TimeInterval) { self.interval = interval }

    func shouldPrint() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(last) >= interval else { return false }
        last = Date()
        return true
    }
}

let audioCommands: [Command] = [
    Command(name: "devices", usage: "               list audio input devices (meter sources)") { _ in
        let devices = AudioDevices.inputDevices()
        for d in devices {
            print("  \(d.isDefault ? "*" : " ") \(d.name)  — \(d.inputChannels) in  [uid \(d.uid)]")
        }
        print("\(devices.count) input device(s); * = system default")
    },
    Command(name: "meters", usage: "[--device UID] [--seconds N]   live input + MainStage output meters") { args in
        setvbuf(stdout, nil, _IOLBF, 0)
        let seconds = Double(option("--seconds", in: args) ?? "") ?? 5
        let source = CoreAudioMeterSource()
        if let bundle = option("--tap-bundle", in: args) { source.tapBundleID = bundle }
        let printer = FramePrinter(interval: 0.25)
        source.onFrame = { frame in
            guard printer.shouldPrint() else { return }
            var lines = ["— \(Date().formatted(date: .omitted, time: .standard))"]
            for (i, p) in frame.inputPeak.enumerated() {
                let r = i < frame.inputRMS.count ? frame.inputRMS[i] : 0
                lines.append(String(format: "  in  %2d %@ %@  (rms %@)", i + 1, meterBar(p), dbText(p), dbText(r)))
            }
            for (i, p) in frame.outputPeak.enumerated() {
                let r = i < frame.outputRMS.count ? frame.outputRMS[i] : 0
                lines.append(String(format: "  out %2d %@ %@  (rms %@)", i + 1, meterBar(p), dbText(p), dbText(r)))
            }
            print(lines.joined(separator: "\n"))
        }
        source.start(inputDeviceUID: option("--device", in: args), log: { print("[meters] \($0)") })
        audioRunLoop(seconds: seconds)
        print("input: \(source.inputDeviceName ?? "none") (\(source.inputChannelCount ?? 0) ch)")
        print("output tap: \(source.outputTapName.map { "\($0) — \(source.outputTapSummary ?? "")" } ?? "none")")
        source.stop()
    },
    Command(name: "rta", usage: "--channel N [--device UID] [--seconds N]   strongest 1/6-octave bands of input N (1-based)") { args in
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let ch = Int(option("--channel", in: args) ?? "1"), ch >= 1 else { throw UsageError("usage: fohctl rta --channel N") }
        let seconds = Double(option("--seconds", in: args) ?? "") ?? 5
        let source = CoreAudioMeterSource()
        let printer = FramePrinter(interval: 0.5)
        source.onRTA = { _, bands in
            guard printer.shouldPrint() else { return }
            let top = bands.enumerated().sorted { $0.element > $1.element }.prefix(5)
            let text = top.map { i, b -> String in
                let f = RTAFrame.bandCenters[i]
                let label = f >= 1000 ? String(format: "%.1fk", f / 1000) : String(format: "%.0f", f)
                return "\(label) Hz \(dbText(b).trimmingCharacters(in: .whitespaces))"
            }
            print("  " + text.joined(separator: " · "))
        }
        source.start(inputDeviceUID: option("--device", in: args), log: { print("[rta] \($0)") })
        source.setRTAChannels([ch - 1])
        audioRunLoop(seconds: seconds)
        source.stop()
    },
    Command(name: "tap", usage: "[--pid PID] [--per-channel] [--seconds N]   process-tap any app's output (default: MainStage)") { args in
        setvbuf(stdout, nil, _IOLBF, 0)
        let seconds = Double(option("--seconds", in: args) ?? "") ?? 5
        guard #available(macOS 14.2, *) else { throw UsageError("process taps need macOS 14.2+") }
        let pid: pid_t
        if let p = option("--pid", in: args), let n = pid_t(p) {
            pid = n
        } else if let ms = RunningApps.pid(bundleID: CoreAudioMeterSource.mainStageBundleID) {
            pid = ms
        } else {
            throw UsageError("MainStage isn't running — pass --pid of another process (e.g. afplay)")
        }
        let tap = try AudioTapProbe(pid: pid, perChannel: args.contains("--per-channel"))
        print("tapping pid \(pid): \(tap.summary) — \(tap.channels) ch at \(Int(tap.sampleRate)) Hz")
        if let why = tap.fallbackReason { print("(per-channel failed: \(why))") }
        let printer = FramePrinter(interval: 0.25)
        tap.onLevels = { peak, rms in
            guard printer.shouldPrint() else { return }
            let lines = peak.enumerated().map { i, p in
                String(format: "  ch %d %@ %@  (rms %@)", i + 1, meterBar(p), dbText(p), dbText(i < rms.count ? rms[i] : 0))
            }
            print(lines.joined(separator: "\n"))
        }
        try tap.start()
        audioRunLoop(seconds: seconds)
        tap.stop()
        print("frames received: \(tap.framesReceived)")
    },
]

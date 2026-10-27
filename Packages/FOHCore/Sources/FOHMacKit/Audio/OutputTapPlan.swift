#if os(macOS)
import CoreFoundation
import Foundation

/// An output device as the tap planner sees it.
public struct OutputDeviceInfo: Hashable, Sendable {
    public let uid: String
    public let name: String
    /// Channels in each of the device's output streams, in stream order.
    public let streamChannels: [Int]

    public init(uid: String, name: String, streamChannels: [Int]) {
        self.uid = uid
        self.name = name
        self.streamChannels = streamChannels
    }

    public var outputChannels: Int { streamChannels.reduce(0, +) }
}

/// Which device to tap MainStage on, and how. Pure, so the choice is testable without hardware.
///
/// Per-channel taps one process tap per output stream of MainStage's device and concatenates them, so channel *n*
/// of the meter frame is the device's output channel *n* ("Out 3-4" → channels 2, 3). Mixdown is the stereo fallback.
public struct OutputTapPlan: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        case perChannel = "per-channel"
        case mixdown
    }

    public var mode: Mode
    public var deviceUID: String?
    public var deviceName: String?
    /// Channels per tapped stream (per-channel only).
    public var streams: [Int]
    /// A sentence for the log explaining any fallback.
    public var note: String?

    /// Meter channels the plan produces (mixdown is always stereo).
    public var channelCount: Int { mode == .perChannel ? streams.reduce(0, +) : 2 }

    /// First meter channel of each tapped stream.
    public var streamOffsets: [Int] {
        var offsets: [Int] = []
        var next = 0
        for n in streams { offsets.append(next); next += n }
        return offsets
    }

    /// "per-channel 18 ch on Scarlett 18i20" / "stereo mixdown"
    public var summary: String {
        switch mode {
        case .perChannel: return "per-channel \(channelCount) ch on \(deviceName ?? "output")"
        case .mixdown: return "stereo mixdown" + (deviceName.map { " (\($0))" } ?? "")
        }
    }

    /// - Parameters:
    ///   - preferredUID / preferredName: MainStage's chosen output device (its preferences).
    ///   - defaultOutputUID: the system default output, used when MainStage's device isn't connected.
    ///   - perChannelFailed: device UIDs a per-channel tap already failed on this session.
    public static func choose(preferredUID: String?, preferredName: String?, defaultOutputUID: String?,
                              devices: [OutputDeviceInfo], perChannelFailed: Set<String> = []) -> OutputTapPlan {
        let usable = devices.filter { $0.outputChannels > 0 }
        let preferred = usable.first { $0.uid == preferredUID && preferredUID != nil }
            ?? usable.first { preferredName != nil && $0.name == preferredName }
        let fallback = usable.first { $0.uid == defaultOutputUID && defaultOutputUID != nil }
        guard let device = preferred ?? fallback else {
            return OutputTapPlan(mode: .mixdown, deviceUID: nil, deviceName: nil, streams: [], note: "no output device found")
        }
        var note: String?
        if preferred == nil, let wanted = preferredName ?? preferredUID {
            note = "MainStage's device \(wanted) isn't connected — using the system output \(device.name)"
        }
        if perChannelFailed.contains(device.uid) {
            let reason = "a per-channel tap failed on \(device.name) — using the stereo mixdown"
            return OutputTapPlan(mode: .mixdown, deviceUID: device.uid, deviceName: device.name, streams: [],
                                 note: [note, reason].compactMap { $0 }.joined(separator: "; "))
        }
        return OutputTapPlan(mode: .perChannel, deviceUID: device.uid, deviceName: device.name,
                             streams: device.streamChannels.filter { $0 > 0 }, note: note)
    }

    /// The stereo fallback for a plan whose per-channel tap couldn't be created.
    public func asMixdown(reason: String) -> OutputTapPlan {
        OutputTapPlan(mode: .mixdown, deviceUID: deviceUID, deviceName: deviceName, streams: [],
                      note: [note, reason].compactMap { $0 }.joined(separator: "; "))
    }
}

/// MainStage's audio device, from its preferences (`com.apple.mainstage3` › AudioHardwarePreferences).
public enum MainStagePreferences {
    public static let domain = "com.apple.mainstage3"

    public struct AudioDevice: Hashable, Sendable {
        public var outputUID: String?
        public var outputName: String?
    }

    /// Reads fresh values each call (MainStage may switch devices while running).
    public static func audioDevice() -> AudioDevice {
        CFPreferencesAppSynchronize(domain as CFString)
        let hw = CFPreferencesCopyAppValue("AudioHardwarePreferences" as CFString, domain as CFString) as? [String: Any]
        let name = CFPreferencesCopyAppValue("FullOutputDriverName" as CFString, domain as CFString) as? String
        return parse(hardware: hw, outputDriverName: name)
    }

    public static func parse(hardware: [String: Any]?, outputDriverName: String?) -> AudioDevice {
        let uid = (hardware?["CurrentCoreAudioDeviceUID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = outputDriverName.flatMap { $0.isEmpty ? nil : $0 }
        return AudioDevice(outputUID: uid, outputName: name)
    }
}
#endif

#if os(macOS)
import Foundation

/// Which audio device the input meters read, given the user's choice and what's connected right now.
/// Pure, so the meter source and the bridge's status line agree and it can be tested without hardware.
public enum InputDevicePolicy {
    public enum Decision: Equatable, Sendable {
        /// Read this device.
        case open(uid: String)
        /// The chosen device isn't connected: read nothing until it comes back.
        case waiting(uid: String)
        /// Following the system default, and this Mac has no input device at all.
        case noDevice
    }

    /// `chosenUID` nil = follow the system default input. A chosen device that's missing is waited for, never
    /// replaced by another input: the built-in microphone would put the room on Lead vox's meter.
    public static func decide(chosenUID: String?, connected: [String], defaultUID: String?) -> Decision {
        if let chosen = chosenUID, !chosen.isEmpty {
            return connected.contains(chosen) ? .open(uid: chosen) : .waiting(uid: chosen)
        }
        if let def = defaultUID, connected.contains(def) { return .open(uid: def) }
        return .noDevice
    }

    /// Whether a capture currently open on `openUID` (nil = none) must be opened, switched or closed.
    public static func needsChange(openUID: String?, for decision: Decision) -> Bool {
        switch decision {
        case .open(let uid): return openUID != uid
        case .waiting, .noDevice: return openUID != nil
        }
    }
}
#endif

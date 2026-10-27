#if os(macOS)
import Foundation
import FOHCore

/// Where the bridge's meters and RTA come from (PLAN.md §2.5). BridgeServer depends only on this protocol;
/// the Core Audio implementation lives beside it in `Audio/`.
public protocol MeterSource: AnyObject {
    /// Latest levels, delivered on an arbitrary queue at roughly `frameRate` Hz.
    var onFrame: (@Sendable (MeterFrame) -> Void)? { get set }
    /// RTA bands for the subscribed input channel(s), on an arbitrary queue at ~15 Hz.
    var onRTA: (@Sendable (_ channels: [Int], _ bands: [UInt8]) -> Void)? { get set }

    /// Human-readable description for BridgeStatus ("Focusrite 18i20 · 18 in", "MainStage").
    var inputDeviceName: String? { get }
    var inputChannelCount: Int? { get }
    var outputTapName: String? { get }

    /// Start metering. `inputDeviceUID` nil = pick the default input device. Never throws for a missing
    /// permission or device: it just reports nothing for that half and logs through `log`.
    func start(inputDeviceUID: String?, log: @escaping @Sendable (String) -> Void)
    func stop()

    /// Analyse these zero-based hardware input channels (summed) for the RTA; empty stops it.
    func setRTAChannels(_ channels: [Int])
}

/// An input-capable audio device, for the bridge's device picker.
public struct AudioInputDevice: Hashable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let isDefault: Bool
    public var id: String { uid }

    public init(uid: String, name: String, inputChannels: Int, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.isDefault = isDefault
    }
}

public enum AudioMetering {
    /// The meter source BridgeServer uses: Core Audio input capture + MainStage process tap + RTA.
    /// Tests can swap in `NullMeterSource`.
    nonisolated(unsafe) public static var makeDefault: () -> MeterSource = { CoreAudioMeterSource() }
    /// Input devices on this Mac.
    nonisolated(unsafe) public static var listInputDevices: () -> [AudioInputDevice] = { AudioDevices.inputDevices() }
}

/// Reports nothing; used until the Core Audio source exists and in tests.
public final class NullMeterSource: MeterSource {
    public var onFrame: (@Sendable (MeterFrame) -> Void)?
    public var onRTA: (@Sendable ([Int], [UInt8]) -> Void)?
    public var inputDeviceName: String? { nil }
    public var inputChannelCount: Int? { nil }
    public var outputTapName: String? { nil }
    public init() {}
    public func start(inputDeviceUID: String?, log: @escaping @Sendable (String) -> Void) {}
    public func stop() {}
    public func setRTAChannels(_ channels: [Int]) {}
}
#endif

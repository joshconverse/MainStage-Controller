#if os(macOS)
import CoreAudio
import Foundation

/// Small typed wrappers over the Core Audio HAL property API.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T {
        var addr = address(selector, scope)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Total channels across a device's streams in one direction.
    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        streamChannels(device, scope: scope).reduce(0, +)
    }

    /// Channels in each stream of a device in one direction, in stream order.
    static func streamChannels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func defaultInputDevice() -> AudioDeviceID {
        value(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    static func uid(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ device: AudioDeviceID) -> String? { string(device, kAudioObjectPropertyName) }

    static func device(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { HAL.uid($0) == uid }
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        value(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }
}

/// Input-capable devices on this Mac, for the bridge's device picker (`AudioMetering.listInputDevices`).
public enum AudioDevices {
    /// UID prefix of the private aggregate devices the output tap creates; never offered as an input.
    static let privateTapPrefix = "io.itstudios.foh.tap."

    public static func inputDevices() -> [AudioInputDevice] {
        let defaultID = HAL.defaultInputDevice()
        return HAL.deviceIDs().compactMap { id -> AudioInputDevice? in
            let channels = HAL.channelCount(id, scope: kAudioObjectPropertyScopeInput)
            guard channels > 0, let uid = HAL.uid(id), !uid.hasPrefix(privateTapPrefix) else { return nil }
            return AudioInputDevice(uid: uid, name: HAL.name(id) ?? uid, inputChannels: channels, isDefault: id == defaultID)
        }
    }

    public static func defaultInput() -> AudioInputDevice? {
        inputDevices().first(where: \.isDefault)
    }

    /// Output-capable devices (excluding the tap's own private aggregates), for the output tap planner.
    public static func outputDevices() -> [OutputDeviceInfo] {
        HAL.deviceIDs().compactMap { id -> OutputDeviceInfo? in
            let streams = HAL.streamChannels(id, scope: kAudioObjectPropertyScopeOutput)
            guard streams.reduce(0, +) > 0, let uid = HAL.uid(id), !uid.hasPrefix(privateTapPrefix) else { return nil }
            return OutputDeviceInfo(uid: uid, name: HAL.name(id) ?? uid, streamChannels: streams)
        }
    }

    public static func defaultOutputUID() -> String? {
        let id = HAL.defaultOutputDevice()
        return id == kAudioObjectUnknown ? nil : HAL.uid(id)
    }

    /// The plan the meter source uses for MainStage: its preferred device, else the system output.
    public static func mainStageOutputPlan(perChannelFailed: Set<String> = []) -> OutputTapPlan {
        let prefs = MainStagePreferences.audioDevice()
        return OutputTapPlan.choose(preferredUID: prefs.outputUID, preferredName: prefs.outputName,
                                    defaultOutputUID: defaultOutputUID(), devices: outputDevices(),
                                    perChannelFailed: perChannelFailed)
    }

    /// The plan for tapping any process on the system output (fohctl tap).
    public static func systemOutputPlan(perChannel: Bool) -> OutputTapPlan {
        let plan = OutputTapPlan.choose(preferredUID: nil, preferredName: nil, defaultOutputUID: defaultOutputUID(),
                                        devices: outputDevices())
        return perChannel ? plan : plan.asMixdown(reason: "mixdown requested")
    }
}
#endif

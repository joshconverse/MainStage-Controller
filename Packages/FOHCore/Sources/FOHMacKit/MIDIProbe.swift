#if os(macOS)
import CoreMIDI
import Foundation

/// Plays the part of MainStage for tests and spikes: lists endpoints, listens to a source
/// (what the bridge sends), and sends to a destination (MainStage "Send Value to" feedback).
public final class MIDIProbe: @unchecked Sendable {
    public struct Endpoint: Sendable, CustomStringConvertible {
        public let name: String
        public let uniqueID: Int32
        public let isVirtual: Bool
        public var description: String { "\(name)  [uid \(uniqueID)]\(isVirtual ? "  (virtual)" : "")" }
    }

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()

    public init(name: String = "fohctl") throws {
        try check(MIDIClientCreateWithBlock(name as CFString, &client) { _ in }, "MIDIClientCreate")
        try check(MIDIOutputPortCreate(client, "out" as CFString, &outPort), "MIDIOutputPortCreate")
    }

    deinit {
        MIDIClientDispose(client)
    }

    public static func sources() -> [Endpoint] {
        (0..<MIDIGetNumberOfSources()).map { endpoint(MIDIGetSource($0)) }
    }

    public static func destinations() -> [Endpoint] {
        (0..<MIDIGetNumberOfDestinations()).map { endpoint(MIDIGetDestination($0)) }
    }

    static func endpoint(_ ref: MIDIEndpointRef) -> Endpoint {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
        var uid: Int32 = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uid)
        var entity = MIDIEntityRef()
        let isVirtual = MIDIEndpointGetEntity(ref, &entity) != noErr || entity == 0
        return Endpoint(name: (name?.takeRetainedValue() as String?) ?? "?", uniqueID: uid, isVirtual: isVirtual)
    }

    static func find(_ name: String, sources: Bool) -> MIDIEndpointRef? {
        let count = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let ref = sources ? MIDIGetSource(i) : MIDIGetDestination(i)
            if endpoint(ref).name == name { return ref }
        }
        return nil
    }

    /// Listen to a source by display name. Handler gets raw MIDI 1.0 bytes (status, d1, d2).
    public func monitor(source name: String, handler: @escaping @Sendable (UInt8, UInt8, UInt8) -> Void) throws {
        guard let src = Self.find(name, sources: true) else {
            throw MIDIError(status: -1, context: "No MIDI source named \(name)")
        }
        try check(MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { list, _ in
            for packet in list.unsafeSequence() {
                for word in MIDIEngine.words(of: packet) where word >> 28 == 0x2 {
                    handler(UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F))
                }
            }
        }, "MIDIInputPortCreate")
        try check(MIDIPortConnectSource(inPort, src, nil), "MIDIPortConnectSource")
    }

    /// Send one MIDI 1.0 message to a destination by display name.
    public func send(toDestination name: String, status: UInt8, data1: UInt8, data2: UInt8) throws {
        guard let dst = Self.find(name, sources: false) else {
            throw MIDIError(status: -1, context: "No MIDI destination named \(name)")
        }
        var list = MIDIEventList()
        var words: [UInt32] = [(0x2 << 28) | (UInt32(status) << 16) | (UInt32(data1) << 8) | UInt32(data2)]
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &words)
        try check(MIDISendEventList(outPort, dst, &list), "MIDISendEventList")
    }
}
#endif

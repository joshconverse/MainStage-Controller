#if os(macOS)
import CoreMIDI
import Foundation
import FOHCore

public struct MIDIError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let context: String
    public var description: String { "\(context) failed (OSStatus \(status))" }
}

@discardableResult
func check(_ status: OSStatus, _ context: String) throws -> OSStatus {
    guard status == noErr else { throw MIDIError(status: status, context: context) }
    return status
}

/// The bridge's four virtual MIDI ports (PLAN.md §4).
///
/// Each `FOHPort` is a virtual *source* (bridge → MainStage) plus a virtual *destination* of the
/// same name (MainStage "Send Value to" → bridge). Unique IDs are persisted so MainStage's learned
/// assignments, which are tied to the port, survive bridge restarts.
public final class MIDIEngine: @unchecked Sendable {
    /// A MIDI 1.0 channel-voice message received on one of the bridge's destinations.
    public struct Message: Sendable, CustomStringConvertible {
        public let port: FOHPort
        public let status: UInt8
        public let data1: UInt8
        public let data2: UInt8

        public var channel: UInt8 { (status & 0x0F) + 1 }
        public var isControlChange: Bool { status & 0xF0 == 0xB0 }

        public var description: String {
            String(format: "%@ status=%02X d1=%d d2=%d", port.rawValue, status, data1, data2)
        }
    }

    public var onReceive: (@Sendable (Message) -> Void)?

    private let clientName: String
    private let defaults: UserDefaults
    /// Appended to every port name ("FOH In 1-16 (test)") so a test bridge never collides with the real one.
    /// Suffixed ports persist their unique IDs under their own keys.
    public let nameSuffix: String
    private var client = MIDIClientRef()
    private var sources: [FOHPort: MIDIEndpointRef] = [:]
    private var destinations: [FOHPort: MIDIEndpointRef] = [:]
    private let lock = NSLock()
    private var counters: [FOHPort: (sent: Int, received: Int)] = [:]

    /// Shared by FOHBridge.app and `fohctl bridge`, so both publish the *same* port unique IDs and
    /// MainStage's learned assignments work whichever one is running.
    public static let sharedDefaults = UserDefaults(suiteName: "io.itstudios.foh.bridge") ?? .standard

    public init(clientName: String = "FOH Bridge", defaults: UserDefaults = MIDIEngine.sharedDefaults, nameSuffix: String = "") {
        self.clientName = clientName
        self.defaults = defaults
        self.nameSuffix = nameSuffix
    }

    /// The endpoint name MainStage sees for a port.
    public func name(of port: FOHPort) -> String { port.rawValue + nameSuffix }

    public func start() throws {
        try check(MIDIClientCreateWithBlock(clientName as CFString, &client) { _ in }, "MIDIClientCreate")
        for port in FOHPort.allCases {
            let name = name(of: port)
            var src = MIDIEndpointRef()
            try check(MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &src), "MIDISourceCreate \(name)")
            persistUniqueID(src, key: "foh.midi.uid.source.\(name)")
            sources[port] = src

            var dst = MIDIEndpointRef()
            try check(MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &dst) { [weak self] list, _ in
                self?.handle(list, port: port)
            }, "MIDIDestinationCreate \(name)")
            persistUniqueID(dst, key: "foh.midi.uid.destination.\(name)")
            destinations[port] = dst
        }
    }

    public func stop() {
        for e in sources.values { MIDIEndpointDispose(e) }
        for e in destinations.values { MIDIEndpointDispose(e) }
        sources.removeAll()
        destinations.removeAll()
        if client != 0 { MIDIClientDispose(client) }
        client = 0
    }

    public func uniqueID(of port: FOHPort, source: Bool = true) -> Int32 {
        guard let e = source ? sources[port] : destinations[port] else { return 0 }
        var uid: Int32 = 0
        MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &uid)
        return uid
    }

    public func counts(_ port: FOHPort) -> (sent: Int, received: Int) {
        lock.lock(); defer { lock.unlock() }
        return counters[port] ?? (0, 0)
    }

    /// Send a control change. `address.channel` is 1–16.
    public func sendCC(_ address: MIDIAddress, value: Int) {
        let status = UInt8(0xB0 | ((address.channel - 1) & 0x0F))
        send(address.port, status: status, data1: address.cc & 0x7F, data2: UInt8(FOHProtocol.clampMIDI(value)))
    }

    public func send(_ port: FOHPort, status: UInt8, data1: UInt8, data2: UInt8) {
        guard let src = sources[port] else { return }
        let word: UInt32 = (0x2 << 28) | (UInt32(status) << 16) | (UInt32(data1) << 8) | UInt32(data2)
        var list = MIDIEventList()
        var words = [word]
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &words)
        MIDIReceivedEventList(src, &list)
        lock.lock()
        counters[port, default: (0, 0)].sent += 1
        lock.unlock()
    }

    private func handle(_ list: UnsafePointer<MIDIEventList>, port: FOHPort) {
        for packet in list.unsafeSequence() {
            for word in Self.words(of: packet) where word >> 28 == 0x2 {
                let msg = Message(port: port, status: UInt8((word >> 16) & 0xFF),
                                  data1: UInt8((word >> 8) & 0x7F), data2: UInt8(word & 0x7F))
                lock.lock()
                counters[port, default: (0, 0)].received += 1
                lock.unlock()
                onReceive?(msg)
            }
        }
    }

    static func words(of packet: UnsafePointer<MIDIEventPacket>) -> [UInt32] {
        let count = Int(packet.pointee.wordCount)
        guard count > 0, let offset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) else { return [] }
        let base = UnsafeRawPointer(packet).advanced(by: offset).assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: base, count: count))
    }

    private func persistUniqueID(_ endpoint: MIDIEndpointRef, key: String) {
        let saved = Int32(truncatingIfNeeded: defaults.integer(forKey: key))
        if saved != 0 {
            // A collision means another bridge instance already owns the ID; keep the saved one for next time.
            if MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, saved) != noErr {
                NSLog("FOH: unique ID \(saved) for \(key) is in use (another bridge running?) — using a temporary ID")
            }
            return
        }
        var uid: Int32 = 0
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
        defaults.set(Int(uid), forKey: key)
    }
}
#endif

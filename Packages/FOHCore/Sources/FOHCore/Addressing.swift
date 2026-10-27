import Foundation

/// The bridge's virtual MIDI ports. Each is a source (bridge → MainStage) and a
/// destination with the same name (MainStage "Send Value to" → bridge).
public enum FOHPort: String, CaseIterable, Codable, Sendable {
    case inputs1 = "FOH In 1-16"
    case inputs2 = "FOH In 17-32"
    case auxBus = "FOH Aux+Bus"
    case global = "FOH Global"
    /// Plugin parameters (PLAN.md §9c): addresses handed out by `ShowConfig.syncPluginControls`, never by strip slot.
    case plugins1 = "FOH Plugins 1"
    case plugins2 = "FOH Plugins 2"

    public static let pluginPorts: [FOHPort] = [.plugins1, .plugins2]
    public var isPluginPort: Bool { Self.pluginPorts.contains(self) }
}

public enum StripKind: String, CaseIterable, Codable, Sendable {
    case input = "in"
    case fx
    case output = "out"
    case master

    public var slotRange: ClosedRange<Int> {
        switch self {
        case .input: return 1...32
        case .fx: return 1...8
        case .output: return 1...8
        case .master: return 1...1
        }
    }
}

/// A strip's slot. Slots never move when strips are reordered or renamed in the app,
/// so the MIDI address learned in MainStage stays valid (PLAN.md §3).
public struct StripRef: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let kind: StripKind
    public let slot: Int

    public init?(kind: StripKind, slot: Int) {
        guard kind.slotRange.contains(slot) else { return nil }
        self.kind = kind
        self.slot = slot
    }

    enum CodingKeys: String, CodingKey { case kind, slot }

    /// Validates the slot: a corrupt or hand-edited show must not produce a slot whose MIDI channel traps.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(StripKind.self, forKey: .kind)
        let slot = try c.decode(Int.self, forKey: .slot)
        guard let ref = StripRef(kind: kind, slot: slot) else {
            throw DecodingError.dataCorruptedError(forKey: .slot, in: c, debugDescription: "slot \(slot) is out of range for \(kind.rawValue)")
        }
        self = ref
    }

    public static func input(_ slot: Int) -> StripRef { StripRef(kind: .input, slot: slot)! }
    public static func fx(_ slot: Int) -> StripRef { StripRef(kind: .fx, slot: slot)! }
    public static func output(_ slot: Int) -> StripRef { StripRef(kind: .output, slot: slot)! }
    public static let master = StripRef(kind: .master, slot: 1)!

    /// `in/1`, `fx/2`, `out/3`, `master/1` — used in OSC paths and as dictionary keys.
    public var key: String { "\(kind.rawValue)/\(slot)" }
    public var description: String { key }

    public init?(key: String) {
        let parts = key.split(separator: "/")
        guard parts.count == 2, let kind = StripKind(rawValue: String(parts[0])), let slot = Int(parts[1]) else { return nil }
        self.init(kind: kind, slot: slot)
    }

    public var port: FOHPort {
        switch kind {
        case .input: return slot <= 16 ? .inputs1 : .inputs2
        case .fx, .output: return .auxBus
        case .master: return .global
        }
    }

    /// MIDI channel 1–16.
    public var channel: UInt8 {
        switch kind {
        case .input: return UInt8(slot <= 16 ? slot : slot - 16)
        case .fx: return UInt8(slot)
        case .output: return UInt8(8 + slot)
        case .master: return 1
        }
    }

    public static func from(port: FOHPort, channel: UInt8) -> StripRef? {
        let ch = Int(channel)
        guard (1...16).contains(ch) else { return nil }
        switch port {
        case .inputs1: return .input(ch)
        case .inputs2: return .input(ch + 16)
        case .auxBus: return ch <= 8 ? .fx(ch) : .output(ch - 8)
        case .global: return ch == 1 ? .master : nil
        case .plugins1, .plugins2: return nil
        }
    }

    public static func < (a: StripRef, b: StripRef) -> Bool {
        let order: [StripKind] = [.input, .fx, .output, .master]
        let ia = order.firstIndex(of: a.kind)!, ib = order.firstIndex(of: b.kind)!
        return ia != ib ? ia < ib : a.slot < b.slot
    }
}

/// One MIDI CC address on one of the bridge's ports.
public struct MIDIAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    public let port: FOHPort
    /// 1–16 (human numbering, as MainStage shows it).
    public let channel: UInt8
    public let cc: UInt8

    public init(port: FOHPort, channel: UInt8, cc: UInt8) {
        self.port = port
        self.channel = channel
        self.cc = cc
    }

    public var description: String { "\(port.rawValue) · ch \(channel) · CC \(cc)" }
}

public enum AddressMap {
    public static func address(_ strip: StripRef, _ role: Role) -> MIDIAddress {
        MIDIAddress(port: strip.port, channel: strip.channel, cc: role.cc)
    }

    public static func resolve(_ address: MIDIAddress) -> (strip: StripRef, role: Role)? {
        guard let strip = StripRef.from(port: address.port, channel: address.channel),
              let role = Role.byCC[address.cc] else { return nil }
        return (strip, role)
    }
}

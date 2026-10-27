import Foundation

/// A mixer *role* — "Band 2 gain", "Comp threshold", "Fader".
///
/// Every strip uses the same CC number for the same role (PLAN.md §4). What a role
/// actually controls on a given strip comes from that strip's binding (PLAN.md §5).
/// Roles are identified by a stable dotted id (`band.2.gain`); never renumber a role's
/// CC once assignments have been learned in MainStage.
public struct Role: Hashable, Sendable, Identifiable, CustomStringConvertible {
    public enum Group: String, Sendable, Codable, CaseIterable {
        case mix, eq, band, dyn, comp, gate, send, insert
        /// MainStage's transport (concert recording); bound on the Master strip only.
        case transport
    }

    /// How the role is sent by default. A binding may override this
    /// (for example SSL's "Fast Atk" switch bound to `comp.attack`).
    public enum Kind: String, Sendable, Codable {
        case continuous
        case toggle
    }

    public let id: String
    public let cc: UInt8
    public let group: Group
    public let kind: Kind
    public let label: String

    public var description: String { id }

    /// `band.2.gain` → `band/2/gain`, used in OSC value paths.
    public var pathSuffix: String { id.replacingOccurrences(of: ".", with: "/") }

    /// Band number for `band.*`, send number for `send.*`, insert slot for `ins.*`.
    public var index: Int? {
        let parts = id.split(separator: ".")
        guard parts.count >= 2, let n = Int(parts[1]) else { return nil }
        return n
    }

    public static subscript(id: String) -> Role? { byID[id] }
}

extension Role: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(String.self)
        guard let role = Role.byID[id] else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown role id \(id)")
        }
        self = role
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

// MARK: - Catalog

extension Role {
    /// CCs MainStage (or MIDI itself) treats specially. Never assign these.
    /// 0/32 bank select · 6/38 data entry · 96–101 NRPN/RPN · 120–127 channel mode.
    public static let reservedCCs: Set<UInt8> = Set([0, 6, 32, 38] + Array(96...101) + Array(120...127))

    /// Base CC for EQ bands 1–4 (on, freq, gain, Q follow).
    static let bandBase: [UInt8] = [20, 24, 28, 33]

    /// Insert slot → (bypass CC, first macro CC, macro count).
    public static let insertLayout: [Int: (bypass: UInt8, firstMacro: UInt8, macros: Int)] = [
        1: (102, 103, 8),
        2: (111, 112, 8),
        3: (80, 81, 8),
        4: (89, 90, 6),
    ]

    public static let all: [Role] = {
        var r: [Role] = []
        func add(_ id: String, _ cc: UInt8, _ group: Group, _ kind: Kind, _ label: String) {
            r.append(Role(id: id, cc: cc, group: group, kind: kind, label: label))
        }

        add("mix.mute", 1, .mix, .toggle, "Mute")
        add("mix.solo", 2, .mix, .toggle, "Solo")
        add("mix.phase", 3, .mix, .toggle, "Phase")
        add("mix.fader", 7, .mix, .continuous, "Fader")
        add("mix.trimIn", 8, .mix, .continuous, "Input trim")
        add("mix.trimOut", 9, .mix, .continuous, "Output trim")
        add("mix.pan", 10, .mix, .continuous, "Pan")
        add("transport.record", 4, .transport, .toggle, "Record")

        add("eq.on", 12, .eq, .toggle, "EQ on")
        add("eq.hpfOn", 13, .eq, .toggle, "HPF on")
        add("eq.hpfFreq", 14, .eq, .continuous, "HPF freq")
        add("eq.hpfSlope", 15, .eq, .continuous, "HPF slope")
        add("eq.lpfOn", 16, .eq, .toggle, "LPF on")
        add("eq.lpfFreq", 17, .eq, .continuous, "LPF freq")

        add("band.1.type", 18, .band, .toggle, "Band 1 shelf/bell")
        add("band.4.type", 19, .band, .toggle, "Band 4 shelf/bell")
        for n in 1...4 {
            let base = bandBase[n - 1]
            add("band.\(n).on", base, .band, .toggle, "Band \(n) on")
            add("band.\(n).freq", base + 1, .band, .continuous, "Band \(n) freq")
            add("band.\(n).gain", base + 2, .band, .continuous, "Band \(n) gain")
            add("band.\(n).q", base + 3, .band, .continuous, "Band \(n) Q")
        }

        add("dyn.filtersToSC", 37, .dyn, .toggle, "Filters → sidechain")
        add("dyn.on", 40, .dyn, .toggle, "Dynamics on")

        add("comp.thresh", 41, .comp, .continuous, "Comp threshold")
        add("comp.ratio", 42, .comp, .continuous, "Comp ratio")
        add("comp.attack", 43, .comp, .continuous, "Comp attack")
        add("comp.release", 44, .comp, .continuous, "Comp release")
        add("comp.makeup", 45, .comp, .continuous, "Comp makeup")
        add("comp.knee", 46, .comp, .continuous, "Comp knee")
        add("comp.mix", 47, .comp, .continuous, "Comp mix")

        add("gate.on", 50, .gate, .toggle, "Gate on")
        add("gate.thresh", 51, .gate, .continuous, "Gate threshold")
        add("gate.range", 52, .gate, .continuous, "Gate range")
        add("gate.attack", 53, .gate, .continuous, "Gate attack")
        add("gate.hold", 54, .gate, .continuous, "Gate hold")
        add("gate.release", 55, .gate, .continuous, "Gate release")
        add("gate.mode", 56, .gate, .toggle, "Gate mode (exp/gate)")

        for n in 1...8 {
            add("send.\(n).level", UInt8(59 + n), .send, .continuous, "Send \(n) level")
            add("send.\(n).on", UInt8(69 + n), .send, .toggle, "Send \(n) on")
        }

        for slot in 1...4 {
            let layout = insertLayout[slot]!
            add("ins.\(slot).bypass", layout.bypass, .insert, .toggle, "Insert \(slot) bypass")
            for m in 1...layout.macros {
                add("ins.\(slot).macro.\(m)", layout.firstMacro + UInt8(m - 1), .insert, .continuous, "Insert \(slot) macro \(m)")
            }
        }
        return r
    }()

    public static let byID: [String: Role] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    public static let byCC: [UInt8: Role] = Dictionary(uniqueKeysWithValues: all.map { ($0.cc, $0) })

    // Frequently used roles.
    public static let mute = byID["mix.mute"]!
    public static let solo = byID["mix.solo"]!
    public static let phase = byID["mix.phase"]!
    public static let fader = byID["mix.fader"]!
    public static let trimIn = byID["mix.trimIn"]!
    public static let trimOut = byID["mix.trimOut"]!
    public static let pan = byID["mix.pan"]!
    /// MainStage's Record (the concert recording): an action, mapped on the Master strip.
    public static let record = byID["transport.record"]!
    public static let eqOn = byID["eq.on"]!
    public static let dynOn = byID["dyn.on"]!

    public static func band(_ n: Int, _ param: String) -> Role? { byID["band.\(n).\(param)"] }
    public static func send(_ n: Int, _ param: String) -> Role? { byID["send.\(n).\(param)"] }
    public static func insertBypass(_ slot: Int) -> Role? { byID["ins.\(slot).bypass"] }
    public static func insertMacro(_ slot: Int, _ macro: Int) -> Role? { byID["ins.\(slot).macro.\(macro)"] }
}

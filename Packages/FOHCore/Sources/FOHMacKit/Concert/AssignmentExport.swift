import CryptoKit
import Foundation
import FOHCore

// Everything MainStage has to learn, resolved by FOHCore: one row per bound role and active plugin control with its
// MIDI address, the ports' CoreMIDI unique IDs and what the row drives. Tools/concert-format/concert_write.py reads
// this to write the assignments straight into the concert (`fohctl assignments`, and the bridge's MainStage sync).

public struct AssignmentExport: Codable, Hashable, Sendable {
    public struct PortIDs: Codable, Hashable, Sendable {
        public let source: Int
        public let destination: Int

        public init(source: Int, destination: Int) {
            self.source = source
            self.destination = destination
        }
    }

    public struct Row: Codable, Hashable, Sendable {
        public let role: String
        public let label: String
        public let port: String
        public let channel: Int
        public let cc: Int
        /// plugin · bypass · volume · mute · solo · pan · sendLevel · sendMute · record
        public let target: String
        public let pluginPosition: Int
        public let pluginName: String
        public let parameterID: String
        public let parameterName: String
        public let kind: String
        public let invert: Bool
        /// MainStage bus number for send roles (Bus 1 = 1); nil when the send has no bus yet.
        public let bus: Int?
        /// The value on the wire right now (after `invert`), from the running bridge; nil when exported from a file.
        public let value: Int?

        /// What the concert has to contain for this row: its address and what it drives (not names or the value).
        var concertKey: String {
            "\(port)|\(channel)|\(cc)|\(target)|\(pluginPosition)|\(parameterID)|\(invert)|\(bus.map(String.init) ?? "-")"
        }
    }

    public struct StripRows: Codable, Hashable, Sendable {
        public let key: String
        public let name: String
        public let mainStage: MainStageLink?
        public let roles: [Row]
    }

    public let show: String
    public let ports: [String: PortIDs]
    public let strips: [StripRows]

    /// The ports' unique IDs as the bridge last saved them (for tools that run without a bridge).
    public static func savedPortIDs(suffix: String) -> [String: PortIDs] {
        let defaults = MIDIEngine.sharedDefaults
        var ports: [String: PortIDs] = [:]
        for port in FOHPort.allCases {
            let name = port.rawValue + suffix
            ports[name] = .init(source: defaults.integer(forKey: "foh.midi.uid.source.\(name)"),
                                destination: defaults.integer(forKey: "foh.midi.uid.destination.\(name)"))
        }
        return ports
    }

    public init(_ show: ShowConfig, values: [String: Int], suffix: String, ports: [String: PortIDs]) {
        self.show = show.name
        self.ports = ports
        self.strips = show.strips.sorted { $0.ref < $1.ref }.map { strip -> StripRows in
            let rows = show.binding(strip.ref).roles.values.sorted { $0.role.cc < $1.role.cc }.map { b -> Row in
                let address = AddressMap.address(strip.ref, b.role)
                let bus = b.role.group == .send ? b.role.index.flatMap { n in show.sends.first { $0.index == n }?.busNumber } : nil
                let value = values[FOHProtocol.valuePath(strip.ref, b.role)].map(b.wireValue)
                return .init(role: b.role.id, label: b.role.label, port: address.port.rawValue + suffix, channel: Int(address.channel),
                             cc: Int(address.cc), target: Self.target(of: b), pluginPosition: b.pluginPosition, pluginName: b.pluginName,
                             parameterID: b.parameterID, parameterName: b.parameterName, kind: Self.kindName(b.kind), invert: b.invert,
                             bus: bus, value: value)
            }
            // Plugin controls (PLAN.md §9c): the plugin ports, mapped like any plugin parameter.
            let pluginRows = show.activePluginControls.filter { $0.strip == strip.ref }.map { c -> Row in
                .init(role: "plugin.\(c.position).\(c.parameterID)", label: c.name, port: c.address.port.rawValue + suffix,
                      channel: Int(c.address.channel), cc: Int(c.address.cc), target: "plugin", pluginPosition: c.position,
                      pluginName: strip.plugins.first { $0.position == c.position }?.name ?? "plugin \(c.position)",
                      parameterID: c.parameterID, parameterName: c.name, kind: "continuous", invert: false, bus: nil, value: values[c.path])
            }
            return .init(key: strip.ref.key, name: strip.name, mainStage: strip.mainStage, roles: rows + pluginRows)
        }
    }

    public var rowCount: Int { strips.reduce(0) { $0 + $1.roles.count } }

    /// Each row's concert key, by strip ("in/1 FOH In 1-16|1|7|volume|…").
    public var concertKeys: Set<String> {
        Set(strips.flatMap { strip -> [String] in
            let link = strip.mainStage.map { "\($0.level.rawValue)/\($0.patchName ?? "")/\($0.stripName)" } ?? "-"
            return strip.roles.map { row in "\(strip.key) \(link) \(row.concertKey)" }
        })
    }

    /// A digest of what the concert must contain (values and names left out, port IDs in): when it changes, the
    /// concert needs a sync.
    public var signature: String {
        let text = (concertKeys.sorted() + ports.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.source)/\($0.value.destination)" })
            .joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func target(of binding: RoleBinding) -> String {
        guard binding.parameterID.hasPrefix("@") else { return "plugin" }
        switch binding.parameterID {
        case ChannelStripParameter.volume.id: return "volume"
        case ChannelStripParameter.mute.id: return "mute"
        case ChannelStripParameter.solo.id: return "solo"
        case ChannelStripParameter.pan.id: return "pan"
        case ChannelStripParameter.record.id: return "record"
        case let id where id.hasSuffix(".bypass"): return "bypass"
        case let id where id.hasSuffix(".level"): return "sendLevel"
        case let id where id.hasSuffix(".mute"): return "sendMute"
        default: return "unknown"
        }
    }

    static func kindName(_ kind: ParamKind) -> String {
        switch kind {
        case .continuous: return "continuous"
        case .toggle: return "toggle"
        case .stepped(let n): return "stepped(\(n))"
        }
    }
}

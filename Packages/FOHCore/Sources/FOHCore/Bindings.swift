import Foundation

/// One app role bound to one plugin parameter (PLAN.md §5 "Bind").
public struct RoleBinding: Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable { case auto, manual }

    public var role: Role
    /// Plugin chain position on the MainStage strip; 0 = the channel strip itself (fader, pan, sends…).
    public var pluginPosition: Int
    public var pluginName: String
    /// AUParameter identifier, or a `ChannelStripParameter` id ("@fader") when `pluginPosition == 0`.
    public var parameterID: String
    public var parameterName: String
    public var unitName: String?
    public var kind: ParamKind
    /// Display text for MIDI 0…127 (copied from discovery, already inverted if `invert`).
    public var steps: [String]
    /// The role's "on" is the parameter's "off" (SSL's `EQBypass` bound to `eq.on`). The bridge sends 127 − value.
    public var invert: Bool
    public var origin: Origin

    public init(role: Role, pluginPosition: Int, pluginName: String, parameterID: String, parameterName: String,
                unitName: String? = nil, kind: ParamKind, steps: [String], invert: Bool = false, origin: Origin) {
        self.role = role
        self.pluginPosition = pluginPosition
        self.pluginName = pluginName
        self.parameterID = parameterID
        self.parameterName = parameterName
        self.unitName = unitName
        self.kind = kind
        self.steps = steps
        self.invert = invert
        self.origin = origin
    }

    public var isChannelStrip: Bool { pluginPosition == 0 }

    /// Role value (what the iPad shows) → wire value MainStage receives.
    public func wireValue(_ roleValue: Int) -> Int {
        invert ? 127 - FOHProtocol.clampMIDI(roleValue) : FOHProtocol.clampMIDI(roleValue)
    }
}

extension RoleBinding: DisplaySteps {}

/// Anything with display text for each MIDI value 0…127 (a role binding, a plugin parameter from discovery).
public protocol DisplaySteps {
    var steps: [String] { get }
    var unitName: String? { get }
}

extension DisplaySteps {
    public func display(_ midi: Int) -> String {
        let i = FOHProtocol.clampMIDI(midi)
        return i < steps.count ? steps[i] : "\(i)"
    }

    public func numeric(_ midi: Int) -> DisplayValue? {
        DisplayValue.parse(display(midi), unitHint: unitName)
    }

    /// For stepped parameters: the MIDI value at the middle of each distinct display run (e.g. the 17 Waves Tune keys).
    public var stepCenters: [(midi: Int, label: String)] {
        var runs: [(start: Int, end: Int, label: String)] = []
        for (i, s) in steps.enumerated() {
            if let last = runs.last, last.label == s { runs[runs.count - 1].end = i } else { runs.append((i, i, s)) }
        }
        return runs.map { (($0.start + $0.end) / 2, $0.label) }
    }

    /// Nearest MIDI value whose parsed display is closest to `target` (for drag-to-value on the EQ graph).
    public func midi(closestTo target: Double) -> Int? {
        var best: (Int, Double)?
        for i in 0..<min(128, steps.count) {
            guard let v = numeric(i)?.value, v.isFinite else { continue }
            let d = abs(v - target)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}

/// All bindings for one strip.
public struct StripBinding: Codable, Hashable, Sendable {
    /// Keyed by role id.
    public var roles: [String: RoleBinding]
    /// Roles the bound plugins don't have; hidden on EQ/Dynamics pages.
    public var notInPlugin: [String]

    public init(roles: [String: RoleBinding] = [:], notInPlugin: [String] = []) {
        self.roles = roles
        self.notInPlugin = notInPlugin
    }

    public subscript(role: Role) -> RoleBinding? { roles[role.id] }

    public func isBound(_ role: Role) -> Bool { roles[role.id] != nil }

    enum CodingKeys: String, CodingKey { case roles, notInPlugin }

    /// Bindings are rebuilt from discovery anyway, so a role this build doesn't know (a newer or older bridge)
    /// drops just that role instead of failing the whole show.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = try c.decodeIfPresent([String: Lenient<RoleBinding>].self, forKey: .roles) ?? [:]
        roles = lenient.compactMapValues(\.value)
        notInPlugin = try c.decodeIfPresent([String].self, forKey: .notInPlugin) ?? []
    }
}

/// Decodes a value or nil, never failing its container.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Templates

/// Name-matching rules that auto-bind a known plugin's parameters to roles.
public struct BindingTemplate: Sendable {
    public struct Rule: Sendable {
        public let role: Role
        /// Parameter names to try, in order (compared case/punctuation-insensitively).
        public let candidates: [String]
        public let invert: Bool
        /// Overrides a plugin's wrong unit name (Waves reports SSL release in "ms"; the values are seconds).
        public let unit: String?

        public init(_ roleID: String, _ candidates: [String], invert: Bool = false, unit: String? = nil) {
            self.role = Role.byID[roleID]!
            self.candidates = candidates
            self.invert = invert
            self.unit = unit
        }
    }

    public let name: String
    /// Matched against the plugin's name or component subtype.
    public let pluginMatches: [String]
    /// Which pages the template's roles feed.
    public let groups: Set<Role.Group>
    public let rules: [Rule]

    public init(name: String, pluginMatches: [String], groups: Set<Role.Group>, rules: [Rule]) {
        self.name = name
        self.pluginMatches = pluginMatches
        self.groups = groups
        self.rules = rules
    }

    public func applies(to plugin: PluginDescription) -> Bool {
        let n = Self.normalize(plugin.name)
        return pluginMatches.contains { Self.normalize($0) == n || Self.normalize($0) == Self.normalize(plugin.component.subtype) }
    }

    public struct Result: Sendable {
        public var bound: [RoleBinding]
        /// Roles in the template's groups the plugin doesn't provide.
        public var notInPlugin: [Role]
    }

    /// Bind every rule it can. Roles in `groups` without a rule or a match become "not in plugin".
    public func bind(_ plugin: PluginDescription, position: Int, roles limitTo: Set<Role.Group>? = nil) -> Result {
        let wanted = limitTo.map { groups.intersection($0) } ?? groups
        var bound: [RoleBinding] = []
        var usedParams = Set<String>()
        for rule in rules where wanted.contains(rule.role.group) || (rule.role.group == .mix && wanted.contains(.mix)) {
            guard let p = Self.find(rule.candidates, in: plugin.parameters, excluding: usedParams) else { continue }
            usedParams.insert(p.id)
            var kind = p.kind
            if rule.role.kind == .toggle, case .stepped(2) = kind { kind = .toggle }
            bound.append(RoleBinding(role: rule.role, pluginPosition: position, pluginName: plugin.name, parameterID: p.id,
                                     parameterName: p.name, unitName: rule.unit ?? p.unitName, kind: kind,
                                     steps: rule.invert ? p.steps.reversed() : p.steps, invert: rule.invert, origin: .auto))
        }
        let boundIDs = Set(bound.map(\.role.id))
        let notIn = Role.all.filter { wanted.contains($0.group) && !boundIDs.contains($0.id) && $0.group != .mix && $0.group != .send && $0.group != .insert }
        return Result(bound: bound, notInPlugin: notIn)
    }

    static func find(_ candidates: [String], in params: [PluginParameterInfo], excluding: Set<String>) -> PluginParameterInfo? {
        let available = params.filter { !excluding.contains($0.id) }
        for c in candidates {
            let nc = normalize(c)
            if let p = available.first(where: { normalize($0.name) == nc }) { return p }
        }
        // Fallback: prefix match ("LF Type (m)"), never substring — "Gain" must not grab "LMF Gain".
        for c in candidates {
            let nc = normalize(c)
            if let p = available.first(where: { normalize($0.name).hasPrefix(nc) }) { return p }
        }
        return nil
    }

    public static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}

public enum Templates {
    /// Waves SSL Channel (m/s). Parameter names come from real discovery on Waves V15 (SPIKES.md S8).
    /// EQBypass / DynamicBypass are "On = bypassed", so they bind inverted to `eq.on` / `dyn.on`.
    public static let wavesSSLChannel = BindingTemplate(
        name: "Waves SSL Channel",
        pluginMatches: ["SSLChannel", "SSLChannel (m)", "SSLChannel (s)", "SCHM", "SCHS"],
        groups: [.mix, .eq, .band, .dyn, .comp, .gate],
        rules: [
            .init("mix.trimIn", ["InputLevel", "Input Trim"]),
            .init("mix.trimOut", ["Gain", "Output Trim"]),
            .init("mix.phase", ["PhaseReverse", "Phase"]),
            .init("eq.on", ["EQBypass"], invert: true),
            .init("eq.hpfFreq", ["HP Frq"]),
            .init("eq.lpfFreq", ["LP Frq"]),
            .init("band.1.freq", ["LF Frq"]),
            .init("band.1.gain", ["LF Gain"]),
            .init("band.1.type", ["LF Type", "LF Bell"]),
            .init("band.2.freq", ["LMF Frq"]),
            .init("band.2.gain", ["LMF Gain"]),
            .init("band.2.q", ["LMF Q"]),
            .init("band.3.freq", ["HMF Frq"]),
            .init("band.3.gain", ["HMF Gain"]),
            .init("band.3.q", ["HMF Q"]),
            .init("band.4.freq", ["HF Frq"]),
            .init("band.4.gain", ["HF Gain"]),
            .init("band.4.type", ["HF Type", "HF Bell"]),
            .init("dyn.on", ["DynamicBypass"], invert: true),
            .init("dyn.filtersToSC", ["FilterSplit"]),
            .init("comp.thresh", ["CompThresh"]),
            .init("comp.ratio", ["CompRatio"]),
            .init("comp.attack", ["CompFast"]),
            .init("comp.release", ["CompRelease"], unit: "s"),
            .init("gate.thresh", ["ExpThresh"]),
            .init("gate.range", ["ExpRange"]),
            .init("gate.attack", ["ExpAttack"]),
            .init("gate.release", ["ExpRelease"], unit: "s"),
            .init("gate.mode", ["ExpGate"]),
        ]
    )

    public static let all: [BindingTemplate] = [wavesSSLChannel]

    public static func template(for plugin: PluginDescription) -> BindingTemplate? {
        all.first { $0.applies(to: plugin) }
    }
}

/// Labelled macros for an insert page (PLAN.md §5: plugins not bound to EQ/Dynamics/Trim).
public struct InsertTemplate: Sendable {
    public let name: String
    public let pluginMatches: [String]
    /// Macro number (1-based) → candidate parameter names.
    public let macros: [(macro: Int, candidates: [String])]

    public func applies(to plugin: PluginDescription) -> Bool {
        let n = BindingTemplate.normalize(plugin.name)
        return pluginMatches.contains { let m = BindingTemplate.normalize($0); return m == n || m == BindingTemplate.normalize(plugin.component.subtype) }
    }

    /// Binds `ins.<page>.macro.<n>` roles plus `ins.<page>.bypass` (MainStage's own slot bypass).
    public func bind(_ plugin: PluginDescription, position: Int, page: Int) -> [RoleBinding] {
        var out: [RoleBinding] = []
        var used = Set<String>()
        for (macro, candidates) in macros {
            guard let role = Role.insertMacro(page, macro),
                  let p = BindingTemplate.find(candidates, in: plugin.parameters, excluding: used) else { continue }
            used.insert(p.id)
            out.append(RoleBinding(role: role, pluginPosition: position, pluginName: plugin.name, parameterID: p.id, parameterName: p.name,
                                   unitName: p.unitName, kind: p.kind, steps: p.steps, origin: .auto))
        }
        if let bypass = Role.insertBypass(page) {
            out.append(ChannelStripParameter.pluginBypass(position).binding(bypass, pluginName: plugin.name, position: position))
        }
        return out
    }
}

extension Templates {
    public static let wavesTuneRealTime = InsertTemplate(
        name: "Waves Tune Real-Time",
        pluginMatches: ["Waves Tune Real-Time", "Waves Tune Real-Time (m)", "Waves Tune Real-Time (s)", "LVLM", "LVLS"],
        macros: [(1, ["Speed"]), (2, ["Note Transition"]), (3, ["Scale Root"]), (4, ["Scale Type"]),
                 (5, ["Correction On/Off"]), (6, ["Correction"]), (7, ["Vibrato Depth"]), (8, ["Formant"])]
    )

    public static let fabFilterProQ3 = InsertTemplate(
        name: "FabFilter Pro-Q 3",
        pluginMatches: ["Pro-Q 3", "FQ3p"],
        macros: [(1, ["Output Level"]), (2, ["Auto Gain"]), (3, ["Gain Scale"])]
    )

    public static let inserts: [InsertTemplate] = [wavesTuneRealTime, fabFilterProQ3]

    public static func insertTemplate(for plugin: PluginDescription) -> InsertTemplate? {
        inserts.first { $0.applies(to: plugin) }
    }
}

// MARK: - MainStage channel-strip parameters (not plugin parameters)

/// Roles that map to MainStage's own channel-strip controls rather than a plugin parameter.
/// Display tables are *estimates* until calibrated against MainStage (spikes S5 / S7).
public enum ChannelStripParameter: Sendable {
    case volume, mute, solo, pan
    /// MainStage's Record action (Master strip only).
    case record
    case sendLevel(Int), sendMute(Int)
    case pluginBypass(Int)

    public var id: String {
        switch self {
        case .volume: return "@volume"
        case .mute: return "@mute"
        case .solo: return "@solo"
        case .pan: return "@pan"
        case .record: return "@record"
        case .sendLevel(let n): return "@send\(n).level"
        case .sendMute(let n): return "@send\(n).mute"
        case .pluginBypass(let p): return "@plugin\(p).bypass"
        }
    }

    public var name: String {
        switch self {
        case .volume: return "Volume"
        case .mute: return "Mute"
        case .solo: return "Solo"
        case .pan: return "Pan"
        case .record: return "Record"
        case .sendLevel(let n): return "Send \(n) level"
        case .sendMute(let n): return "Send \(n) on"
        case .pluginBypass(let p): return "Plugin \(p) bypass"
        }
    }

    /// Estimated MainStage volume law: 40·log10(v/127) + 6 dB → 127 = +6 dB, 90 ≈ 0 dB, 0 = −∞.
    public static func estimatedVolumeDB(_ midi: Int) -> Double {
        midi <= 0 ? -.infinity : 40 * log10(Double(midi) / 127) + 6
    }

    /// Volume in dB for a MIDI value, bent to measured MainStage readings when there are any:
    /// linear in dB between calibration points, and the estimated law's shape (offset to meet the nearest
    /// point) outside them. MIDI 0 is always −∞.
    public static func volumeDB(_ midi: Int, calibration: [CalibrationPoint]) -> Double {
        let points = calibration.compactMap { p in p.db.map { (midi: p.midi, db: $0) } }
            .filter { $0.midi > 0 && $0.db.isFinite }.sorted { $0.midi < $1.midi }
        guard midi > 0, let first = points.first, let last = points.last else { return estimatedVolumeDB(midi) }
        if midi <= first.midi { return estimatedVolumeDB(midi) + (first.db - estimatedVolumeDB(first.midi)) }
        if midi >= last.midi { return estimatedVolumeDB(midi) + (last.db - estimatedVolumeDB(last.midi)) }
        for (a, b) in zip(points, points.dropFirst()) where midi >= a.midi && midi <= b.midi {
            let t = Double(midi - a.midi) / Double(max(1, b.midi - a.midi))
            return a.db + t * (b.db - a.db)
        }
        return estimatedVolumeDB(midi)
    }

    public static func formatDB(_ db: Double) -> String {
        guard db.isFinite else { return "-inf dB" }
        return String(format: "%@%.1f dB", db > 0.05 ? "+" : "", abs(db) < 0.05 ? 0 : db)
    }

    public var kind: ParamKind {
        switch self {
        case .volume, .pan, .sendLevel: return .continuous
        case .mute, .solo, .sendMute, .pluginBypass, .record: return .toggle
        }
    }

    public var steps: [String] { steps(calibration: []) }

    public func steps(calibration: [CalibrationPoint]) -> [String] {
        switch self {
        case .volume, .sendLevel:
            return (0...127).map { Self.formatDB(Self.volumeDB($0, calibration: calibration)) }
        case .pan:
            return (0...127).map { $0 == 64 ? "C" : ($0 < 64 ? "L\(64 - $0)" : "R\($0 - 64)") }
        case .mute, .solo:
            return (0...127).map { $0 >= 64 ? "On" : "Off" }
        case .record:
            return (0...127).map { $0 >= 64 ? "Recording" : "Stopped" }
        case .sendMute:
            return (0...127).map { $0 >= 64 ? "On" : "Off" }
        case .pluginBypass:
            return (0...127).map { $0 >= 64 ? "Bypassed" : "Active" }
        }
    }

    public func binding(_ role: Role, pluginName: String = "Channel strip", position: Int = 0,
                        calibration: [CalibrationPoint] = []) -> RoleBinding {
        RoleBinding(role: role, pluginPosition: position, pluginName: pluginName, parameterID: id, parameterName: name,
                    unitName: nil, kind: kind, steps: steps(calibration: calibration), origin: .auto)
    }
}

extension StripBinding {
    /// Neutral starting values for roles the bridge has never heard from MainStage: each plugin's own default
    /// (from discovery), unity fader and centre pan for channel-strip roles, everything else off. Real values
    /// replace these as soon as MainStage feedback ("Send Value to") arrives.
    public func defaultRoleValues(discovered: [Int: PluginDescription]) -> [Role: Int] {
        var out: [Role: Int] = [:]
        for b in roles.values {
            if b.parameterID.hasPrefix("@") {
                switch b.parameterID {
                case ChannelStripParameter.volume.id: out[b.role] = 90
                case ChannelStripParameter.pan.id: out[b.role] = 64
                default: out[b.role] = 0
                }
                continue
            }
            guard let p = discovered[b.pluginPosition]?.parameter(id: b.parameterID), p.maxValue > p.minValue else { continue }
            let fraction = (Double(p.defaultValue) - Double(p.minValue)) / (Double(p.maxValue) - Double(p.minValue))
            guard fraction.isFinite else { continue }   // a plugin reporting NaN/inf must not trap the bridge
            let midi = FOHProtocol.clampMIDI(Int((min(max(fraction, 0), 1) * 127).rounded()))
            out[b.role] = b.invert ? 127 - midi : midi
        }
        return out
    }

    /// Fader, mute, solo, pan and configured sends — present on every strip, bound to MainStage's channel strip.
    public static func channelStripDefaults(for strip: Strip, sends: [SendBus], calibration: [CalibrationPoint] = []) -> [RoleBinding] {
        var out: [RoleBinding] = [
            ChannelStripParameter.volume.binding(.fader, calibration: calibration),
            ChannelStripParameter.mute.binding(.mute),
        ]
        guard strip.ref.kind != .master else { return out + [ChannelStripParameter.record.binding(.record)] }
        out.append(ChannelStripParameter.solo.binding(.solo))
        out.append(ChannelStripParameter.pan.binding(.pan))
        if strip.ref.kind == .input {
            for bus in sends {
                if let level = Role.send(bus.index, "level") {
                    out.append(ChannelStripParameter.sendLevel(bus.index).binding(level, calibration: calibration))
                }
                if let on = Role.send(bus.index, "on") { out.append(ChannelStripParameter.sendMute(bus.index).binding(on)) }
            }
        }
        return out
    }

    /// Build a strip's full binding from discovery results: channel-strip defaults, the processing template
    /// for the plugin driving EQ/Dynamics/Trim, and insert-page templates.
    public static func build(for strip: Strip, sends: [SendBus], discovered: [Int: PluginDescription],
                             calibration: [CalibrationPoint] = [], customTemplates: [CustomTemplate] = []) -> StripBinding {
        var roles: [String: RoleBinding] = [:]
        var notIn: [String] = []
        for b in channelStripDefaults(for: strip, sends: sends, calibration: calibration) { roles[b.role.id] = b }

        let processingPositions = Set([strip.processing.eq, strip.processing.dynamics, strip.processing.trim].compactMap { $0 })
        for position in processingPositions.sorted() {
            guard let plugin = discovered[position] else { continue }
            var groups: Set<Role.Group> = []
            if strip.processing.eq == position { groups.formUnion([.eq, .band]) }
            if strip.processing.dynamics == position { groups.formUnion([.dyn, .comp, .gate]) }
            if strip.processing.trim == position { groups.insert(.mix) }
            if let custom = customTemplates.first(where: { $0.use == .processing && $0.matches(plugin) }) {
                let result = custom.bindProcessing(plugin, position: position, groups: groups)
                for b in result.bound { roles[b.role.id] = b }
                notIn += result.hidden
            } else if let template = Templates.template(for: plugin) {
                let result = template.bind(plugin, position: position, roles: groups)
                for b in result.bound { roles[b.role.id] = b }
                notIn += result.notInPlugin.map(\.id)
            }
        }
        for (page, position) in strip.processing.insertPages.sorted(by: { $0.key < $1.key }) {
            guard let plugin = discovered[position] else { continue }
            if let custom = customTemplates.first(where: { $0.use == .insert && $0.matches(plugin) }) {
                for b in custom.bindInsert(plugin, position: position, page: page) { roles[b.role.id] = b }
            } else if let template = Templates.insertTemplate(for: plugin) {
                for b in template.bind(plugin, position: position, page: page) { roles[b.role.id] = b }
            }
        }
        return StripBinding(roles: roles, notInPlugin: Array(Set(notIn)).sorted())
    }
}

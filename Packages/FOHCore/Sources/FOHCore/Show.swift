import Foundation

public enum ChannelColor: String, Codable, CaseIterable, Sendable {
    case red, green, yellow, blue, magenta, cyan, white, off
}

/// Where the strip lives in the MainStage concert.
public struct MainStageLink: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable { case concert, patch }

    public var stripName: String
    public var level: Level
    public var patchName: String?

    public init(stripName: String, level: Level, patchName: String? = nil) {
        self.stripName = stripName
        self.level = level
        self.patchName = patchName
    }
}

/// An Audio Unit component id, as four-character codes ("aufx", "SCHM", "ksWV").
public struct AUComponentID: Codable, Hashable, Sendable, CustomStringConvertible {
    public var type: String
    public var subtype: String
    public var manufacturer: String

    public init(type: String, subtype: String, manufacturer: String) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
    }

    public var description: String { "\(type)/\(subtype)/\(manufacturer)" }
}

/// One plugin in a MainStage channel strip's chain.
public struct PluginRef: Codable, Hashable, Sendable {
    /// 1-based position in the MainStage strip's audio-effect chain.
    public var position: Int
    public var name: String
    public var component: AUComponentID?
    public var preset: String?

    public init(position: Int, name: String, component: AUComponentID? = nil, preset: String? = nil) {
        self.position = position
        self.name = name
        self.component = component
        self.preset = preset
    }
}

/// Which plugin (by chain position) drives each app page for a strip.
public struct ProcessingSources: Codable, Hashable, Sendable {
    public var eq: Int?
    public var dynamics: Int?
    public var trim: Int?
    /// FOH insert page (1–4) → plugin chain position, for macro pages like Waves Tune.
    public var insertPages: [Int: Int]

    public init(eq: Int? = nil, dynamics: Int? = nil, trim: Int? = nil, insertPages: [Int: Int] = [:]) {
        self.eq = eq
        self.dynamics = dynamics
        self.trim = trim
        self.insertPages = insertPages
    }
}

public struct Strip: Codable, Hashable, Sendable, Identifiable {
    public var ref: StripRef
    public var name: String
    public var color: ChannelColor
    public var stereo: Bool
    public var mainStage: MainStageLink?
    public var hardwareIO: String?
    public var plugins: [PluginRef]
    public var processing: ProcessingSources

    public var id: String { ref.key }

    public init(ref: StripRef, name: String, color: ChannelColor, stereo: Bool = false, mainStage: MainStageLink? = nil,
                hardwareIO: String? = nil, plugins: [PluginRef] = [], processing: ProcessingSources = ProcessingSources()) {
        self.ref = ref
        self.name = name
        self.color = color
        self.stereo = stereo
        self.mainStage = mainStage
        self.hardwareIO = hardwareIO
        self.plugins = plugins
        self.processing = processing
    }

    public func plugin(at position: Int?) -> PluginRef? {
        guard let position else { return nil }
        return plugins.first { $0.position == position }
    }
}

/// A send the user configured (FOH send number → MainStage bus).
public struct SendBus: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var name: String
    public var busNumber: Int?
    public var existsInConcert: Bool

    public var id: Int { index }

    public init(index: Int, name: String, busNumber: Int?, existsInConcert: Bool) {
        self.index = index
        self.name = name
        self.busNumber = busNumber
        self.existsInConcert = existsInConcert
    }
}

/// One measured MainStage fader reading: the dB MainStage showed for a MIDI value (`db` nil = −∞).
public struct CalibrationPoint: Codable, Hashable, Sendable {
    public var midi: Int
    public var db: Double?

    public init(midi: Int, db: Double?) {
        self.midi = midi
        self.db = db
    }
}

/// A MainStage patch in the setlist. Selecting it sends Program Change on "FOH Global" ch 1.
public struct PatchInfo: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var name: String
    /// MainStage's program change number for the patch (0–127), if it has one.
    public var programChange: Int?

    public var id: Int { index }

    public init(index: Int, name: String, programChange: Int?) {
        self.index = index
        self.name = name
        self.programChange = programChange
    }
}

public struct ShowConfig: Codable, Hashable, Sendable {
    public var name: String
    public var strips: [Strip]
    public var sends: [SendBus]
    /// Keyed by `StripRef.key`.
    public var bindings: [String: StripBinding]
    /// Setlist, in concert order.
    public var patches: [PatchInfo]
    /// Index into `patches` of the patch MainStage is on (as far as the bridge knows).
    public var currentPatch: Int?
    /// Where the concert was imported from (bridge-side path).
    public var concertPath: String?
    /// MainStage fader readings from `fohctl calibrate fader` (spike S5). Empty = use the estimated law.
    public var faderCalibration: [CalibrationPoint]
    /// The user's display order (strip keys). Purely visual: slots — and so MIDI addresses — never change.
    /// Strips not listed follow in slot order.
    public var stripOrder: [String]
    /// Templates saved from hand-tuned strips; they take precedence over the built-in ones.
    public var customTemplates: [CustomTemplate]
    /// Every plugin-parameter address ever handed out (PLAN.md §9c); see `syncPluginControls`.
    public var pluginControls: [PluginControl]
    /// Per plugin type ("aumf/FQ3p/FabF"): parameters added to or removed from its core set.
    public var pluginSelections: [String: PluginSelection]
    /// Parameters of MainStage's own plugins, learned from hand-made Assign & Maps, by plugin name ("Channel EQ").
    public var learnedParameters: [String: [LearnedParameter]] = [:]
    /// Controls waiting for their hand-made Assign & Map in MainStage.
    public var pendingLearns: [PendingLearn] = []

    public init(name: String, strips: [Strip], sends: [SendBus], bindings: [String: StripBinding] = [:],
                patches: [PatchInfo] = [], currentPatch: Int? = nil, concertPath: String? = nil,
                faderCalibration: [CalibrationPoint] = [], stripOrder: [String] = [], customTemplates: [CustomTemplate] = [],
                pluginControls: [PluginControl] = [], pluginSelections: [String: PluginSelection] = [:]) {
        self.name = name
        self.strips = strips
        self.sends = sends
        self.bindings = bindings
        self.patches = patches
        self.currentPatch = currentPatch
        self.concertPath = concertPath
        self.faderCalibration = faderCalibration
        self.stripOrder = stripOrder
        self.customTemplates = customTemplates
        self.pluginControls = pluginControls
        self.pluginSelections = pluginSelections
    }

    enum CodingKeys: String, CodingKey {
        case name, strips, sends, bindings, patches, currentPatch, concertPath, faderCalibration, stripOrder, customTemplates
        case pluginControls, pluginSelections, learnedParameters, pendingLearns
    }

    /// Tolerates show files written before newer fields existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        strips = try c.decode([Strip].self, forKey: .strips)
        sends = try c.decodeIfPresent([SendBus].self, forKey: .sends) ?? []
        bindings = try c.decodeIfPresent([String: StripBinding].self, forKey: .bindings) ?? [:]
        patches = try c.decodeIfPresent([PatchInfo].self, forKey: .patches) ?? []
        currentPatch = try c.decodeIfPresent(Int.self, forKey: .currentPatch)
        concertPath = try c.decodeIfPresent(String.self, forKey: .concertPath)
        faderCalibration = try c.decodeIfPresent([CalibrationPoint].self, forKey: .faderCalibration) ?? []
        stripOrder = try c.decodeIfPresent([String].self, forKey: .stripOrder) ?? []
        customTemplates = try c.decodeIfPresent([CustomTemplate].self, forKey: .customTemplates) ?? []
        pluginControls = try c.decodeIfPresent([PluginControl].self, forKey: .pluginControls) ?? []
        pluginSelections = try c.decodeIfPresent([String: PluginSelection].self, forKey: .pluginSelections) ?? [:]
        learnedParameters = try c.decodeIfPresent([String: [LearnedParameter]].self, forKey: .learnedParameters) ?? [:]
        pendingLearns = try c.decodeIfPresent([PendingLearn].self, forKey: .pendingLearns) ?? []
    }

    /// Strips of one kind in the user's display order (then slot order for anything not placed).
    public func ordered(_ kind: StripKind) -> [Strip] {
        let rank = Dictionary(stripOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return strips.filter { $0.ref.kind == kind }.sorted { a, b in
            switch (rank[a.ref.key], rank[b.ref.key]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.ref < b.ref
            }
        }
    }

    public func strip(_ ref: StripRef) -> Strip? { strips.first { $0.ref == ref } }
    public func binding(_ ref: StripRef) -> StripBinding { bindings[ref.key] ?? StripBinding() }

    /// First unused slot for a strip kind, or nil when that kind is full.
    public func nextFreeSlot(_ kind: StripKind) -> Int? {
        let used = Set(strips.filter { $0.ref.kind == kind }.map(\.ref.slot))
        return kind.slotRange.first { !used.contains($0) }
    }
}

extension Strip {
    /// Zero-based hardware input channels parsed from `hardwareIO` ("In 1" → [0], "In 3-4" → [2, 3]).
    /// Empty for buses and outputs. Used to map the bridge's input meters onto strips.
    public var hardwareInputChannels: [Int] {
        guard let io = hardwareIO?.trimmingCharacters(in: .whitespaces), ref.kind == .input, io.lowercased().hasPrefix("in") else { return [] }
        return Self.channels(io, separators: ["-", "–", "/"], stereo: stereo)
    }

    /// Zero-based hardware output channels ("Out 1-2" → [0, 1]).
    public var hardwareOutputChannels: [Int] {
        guard let io = hardwareIO?.trimmingCharacters(in: .whitespaces), io.lowercased().hasPrefix("out") else { return [] }
        return Self.channels(io, separators: ["-", "–"], stereo: stereo)
    }

    /// Largest channel number and span accepted from the free-text I/O field. A typo like "In 1-99999" would
    /// otherwise build a huge array (meters for thousands of channels, or an allocation that crashes).
    static let maxChannel = 256
    static let maxSpan = 64

    private static func channels(_ io: String, separators: Set<Character>, stereo: Bool) -> [Int] {
        let parts = io.drop { !$0.isNumber }.split(whereSeparator: { separators.contains($0) })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = parts.first, (1...maxChannel).contains(first) else { return [] }
        if parts.count >= 2, parts[1] >= first, parts[1] <= maxChannel, parts[1] - first < maxSpan {
            return Array((first - 1)...(parts[1] - 1))
        }
        return stereo && first < maxChannel ? [first - 1, first] : [first - 1]
    }
}

// MARK: - Default show: today's Church.concert

extension AUComponentID {
    public static let wavesSSLChannel = AUComponentID(type: "aufx", subtype: "SCHM", manufacturer: "ksWV")
    public static let wavesTuneRealTime = AUComponentID(type: "aumf", subtype: "LVLM", manufacturer: "ksWV")
    public static let fabFilterProQ3 = AUComponentID(type: "aumf", subtype: "FQ3p", manufacturer: "FabF")
    public static let fabFilterProR2 = AUComponentID(type: "aumf", subtype: "FR2p", manufacturer: "FabF")
}

extension ShowConfig {
    public static let church = ShowConfig(
        name: "Church",
        strips: [
            Strip(ref: .input(1), name: "Lead vox", color: .cyan,
                  mainStage: MainStageLink(stripName: "Lead vox", level: .patch, patchName: "Song One"),
                  hardwareIO: "In 1",
                  plugins: [
                      PluginRef(position: 1, name: "Waves Tune Real-Time", component: .wavesTuneRealTime),
                      PluginRef(position: 2, name: "Pro-Q 3", component: .fabFilterProQ3),
                      PluginRef(position: 3, name: "SSLChannel", component: .wavesSSLChannel, preset: "AT Female Vocal 1"),
                  ],
                  processing: ProcessingSources(eq: 3, dynamics: 3, trim: 3, insertPages: [1: 1, 2: 2])),
            Strip(ref: .input(2), name: "Guitar", color: .yellow,
                  mainStage: MainStageLink(stripName: "Guitar", level: .patch, patchName: "Song One"),
                  hardwareIO: "In 2",
                  plugins: [PluginRef(position: 1, name: "SSLChannel", component: .wavesSSLChannel, preset: "Acc Gtr")],
                  processing: ProcessingSources(eq: 1, dynamics: 1, trim: 1)),
            Strip(ref: .fx(1), name: "Botta Church", color: .blue, stereo: true,
                  mainStage: MainStageLink(stripName: "Botta Church", level: .concert),
                  hardwareIO: "Bus 1",
                  plugins: [PluginRef(position: 1, name: "Space Designer")]),
            Strip(ref: .output(1), name: "Main", color: .white, stereo: true,
                  mainStage: MainStageLink(stripName: "Main", level: .concert),
                  hardwareIO: "Out 1-2",
                  plugins: [
                      PluginRef(position: 1, name: "Gain"),
                      PluginRef(position: 2, name: "MultiMeter"),
                      PluginRef(position: 3, name: "Channel EQ", preset: "Final Mix - Pop"),
                      PluginRef(position: 4, name: "Multipressor", preset: "Final Pop Compressor"),
                      PluginRef(position: 5, name: "Direction Mixer", preset: "Stereo Spread Wide"),
                      PluginRef(position: 6, name: "MultiMeter"),
                  ]),
            Strip(ref: .output(2), name: "Output 1", color: .white,
                  mainStage: MainStageLink(stripName: "Output 1", level: .concert),
                  plugins: [PluginRef(position: 1, name: "Pro-Q 3", component: .fabFilterProQ3)]),
            Strip(ref: .output(3), name: "Output 2", color: .white,
                  mainStage: MainStageLink(stripName: "Output 2", level: .concert)),
            Strip(ref: .master, name: "Master", color: .white, stereo: true,
                  mainStage: MainStageLink(stripName: "Master", level: .concert)),
        ],
        sends: [
            SendBus(index: 1, name: "Mon 1", busNumber: 2, existsInConcert: false),
            SendBus(index: 2, name: "Mon 2", busNumber: 3, existsInConcert: false),
            SendBus(index: 3, name: "Rev 1 · Botta Church", busNumber: 1, existsInConcert: true),
            SendBus(index: 4, name: "Rev 2", busNumber: 4, existsInConcert: false),
            SendBus(index: 5, name: "Delay", busNumber: 5, existsInConcert: false),
        ],
        patches: [PatchInfo(index: 0, name: "Song One", programChange: 0)],
        currentPatch: 0
    )
}

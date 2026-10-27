import Foundation

/// How a bound parameter behaves.
public enum ParamKind: Codable, Hashable, Sendable {
    case continuous
    case toggle
    /// Discrete choices (e.g. Waves Tune key: 12 steps).
    case stepped(Int)
}

/// One Audio Unit parameter as read off-line by the bridge (PLAN.md §5 "Discover").
public struct PluginParameterInfo: Codable, Hashable, Sendable, Identifiable, DisplaySteps {
    /// AUParameter.identifier (stable across instances).
    public var id: String
    public var address: UInt64
    public var name: String
    public var unitName: String?
    /// Raw `AudioUnitParameterUnit`.
    public var unit: UInt32
    public var minValue: Float
    public var maxValue: Float
    public var defaultValue: Float
    /// `kAudioUnitParameterFlag_DisplayLogarithmic` — relevant to spike S5.
    public var displayLogarithmic: Bool
    public var valueStrings: [String]?
    /// Display text at each MIDI value 0…127, assuming MainStage maps 0–127 linearly
    /// across min…max (spike S5 verifies this). Empty if the plugin can't format values.
    public var steps: [String]
    /// AU flags (catalog version 2+; nil in older caches): the host may set it / it's a meter or read-only display.
    public var writable: Bool?
    public var meter: Bool?
    /// The AU parameter group it sits in ("Band 3"), when the plugin groups its parameters.
    public var group: String?

    public init(id: String, address: UInt64, name: String, unitName: String?, unit: UInt32, minValue: Float, maxValue: Float,
                defaultValue: Float, displayLogarithmic: Bool, valueStrings: [String]?, steps: [String],
                writable: Bool? = nil, meter: Bool? = nil, group: String? = nil) {
        self.id = id
        self.address = address
        self.name = name
        self.unitName = unitName
        self.unit = unit
        self.minValue = minValue
        self.maxValue = maxValue
        self.defaultValue = defaultValue
        self.displayLogarithmic = displayLogarithmic
        self.valueStrings = valueStrings
        self.steps = steps
        self.writable = writable
        self.meter = meter
        self.group = group
    }

    /// A real control a person would want on the iPad: settable, not a meter, and not one of the analyzer,
    /// display, MIDI or GUI-state parameters plugins expose (Pro-Q 3: 358 parameters, 273 controls).
    public var isControl: Bool {
        if writable == false || meter == true { return false }
        return name.range(of: Self.nonControlPattern, options: .regularExpression) == nil
    }

    static let nonControlPattern =
        #"Analyzer|Display|Midi|MIDI|\bVU\b|VU |Scroll|Zoom|Popup|Graph|Spectrum|Keyboard|Window|Marker|Receive|Send to All|Attn|Status|Detected|Target Pitch|Retune|Horizontal|Pitch Position|Speakers|External Side Chain|Solo$|Solo Gain|Freeze|Reset|Clip"#

    /// AudioUnitParameterUnit: 2 = boolean, 1 = indexed.
    public var kind: ParamKind {
        if unit == 2 { return .toggle }
        if let strings = valueStrings, !strings.isEmpty {
            return strings.count == 2 ? .toggle : .stepped(strings.count)
        }
        if unit == 1 {
            let span = Double(maxValue) - Double(minValue)
            if span.isFinite, span >= 0, span < 10_000 {
                let count = Int(span) + 1
                return count == 2 ? .toggle : .stepped(max(count, 2))
            }
        }
        // Two-state parameters not flagged boolean (Waves Tune "Formant": Off/On over 0…1).
        if Set(steps).count == 2 { return .toggle }
        return .continuous
    }

    /// The plugin's default as a MIDI value (MainStage maps 0–127 linearly over min…max); nil if not finite.
    public var defaultMIDI: Int? {
        let fraction = (Double(defaultValue) - Double(minValue)) / (Double(maxValue) - Double(minValue))
        guard fraction.isFinite else { return nil }
        return FOHProtocol.clampMIDI(Int((min(max(fraction, 0), 1) * 127).rounded()))
    }

    /// The AU value MainStage should produce for a MIDI value, assuming a linear map.
    public func value(forMIDI midi: Int) -> Float {
        minValue + (maxValue - minValue) * Float(FOHProtocol.clampMIDI(midi)) / 127
    }
}

/// Everything discovery learned about one plugin.
public struct PluginDescription: Codable, Hashable, Sendable {
    public var component: AUComponentID
    public var name: String
    public var manufacturerName: String
    public var parameters: [PluginParameterInfo]
    /// What discovery recorded: 1 (nil) = ranges and steps; 2 adds AU flags and groups.
    public var catalogVersion: Int?

    /// Discovery re-reads cached plugins older than this.
    public static let currentCatalogVersion = 2

    public init(component: AUComponentID, name: String, manufacturerName: String, parameters: [PluginParameterInfo],
                catalogVersion: Int? = PluginDescription.currentCatalogVersion) {
        self.component = component
        self.name = name
        self.manufacturerName = manufacturerName
        self.parameters = parameters
        self.catalogVersion = catalogVersion
    }

    public var isCurrentCatalog: Bool { (catalogVersion ?? 1) >= Self.currentCatalogVersion }

    public func parameter(id: String) -> PluginParameterInfo? { parameters.first { $0.id == id } }
}

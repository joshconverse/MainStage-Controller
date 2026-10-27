import Foundation

// Plugin controls (PLAN.md §9c): every loaded plugin's core set of parameters gets a permanent MIDI address on the
// plugin ports, so the concert writer can map it in MainStage and the iPad can show it, with no hand-mapping.

/// Which parameters of one plugin type are controlled: its core set, minus what the user removed, plus what they added.
public struct PluginSelection: Codable, Hashable, Sendable {
    public var added: [String]
    public var removed: [String]

    public init(added: [String] = [], removed: [String] = []) {
        self.added = added
        self.removed = removed
    }
}

/// One plugin parameter's permanent MIDI address. Kept forever once handed out (like a role's CC), so a plugin that
/// comes back gets the same address; `active` says whether it's in a strip's current chain and selection.
public struct PluginControl: Codable, Hashable, Sendable {
    public var strip: StripRef
    /// Chain position (1-based), as in `PluginRef.position`.
    public var position: Int
    public var component: AUComponentID
    public var parameterID: String
    /// The parameter's display name when it was last synced ("Band 1 Frequency").
    public var name: String
    public var address: MIDIAddress
    public var active: Bool

    public init(strip: StripRef, position: Int, component: AUComponentID, parameterID: String, name: String = "",
                address: MIDIAddress, active: Bool = true) {
        self.strip = strip
        self.position = position
        self.component = component
        self.parameterID = parameterID
        self.name = name
        self.address = address
        self.active = active
    }

    public var path: String { FOHProtocol.pluginPath(strip, position, parameterID) }

    func matches(_ strip: StripRef, _ position: Int, _ component: AUComponentID, _ parameterID: String) -> Bool {
        self.strip == strip && self.position == position && self.component == component && self.parameterID == parameterID
    }
}

/// The parameters each plugin type controls before the user adds or removes any.
public enum PluginControlSets {
    /// Plugins the core set comes from by name (FabFilter's AU parameter IDs aren't documented; names are stable).
    static let proQ3 = (subtype: "FQ3p", manufacturer: "FabF")
    static let proR2 = (subtype: "FR2p", manufacturer: "FabF")
    /// Any other plugin: its first real controls, in the plugin's own order.
    public static let genericCount = 24

    public static func core(for plugin: PluginDescription) -> [String] {
        let c = plugin.component
        // MainStage's own plugins: the first real controls of MainStage's table, plus every parameter learned by hand.
        if c.isMainStagePlugin {
            let learned = plugin.parameters.filter { $0.group == PluginDescription.learnedGroup }.map(\.id)
            let listed = plugin.parameters.filter { $0.group != PluginDescription.learnedGroup && $0.isControl }.prefix(genericCount).map(\.id)
            return listed + learned.filter { !listed.contains($0) }
        }
        if c.subtype == proQ3.subtype && c.manufacturer == proQ3.manufacturer {
            let perBand = ["Used", "Enabled", "Frequency", "Gain", "Q", "Shape", "Slope", "Dynamics Enabled", "Threshold", "Dynamic Range"]
            let names = (1...8).flatMap { n in perBand.map { "Band \(n) \($0)" } } + ["Output Level", "Gain Scale", "Auto Gain", "Output Pan", "Bypass"]
            return ids(named: names, in: plugin)
        }
        if c.subtype == proR2.subtype && c.manufacturer == proR2.manufacturer {
            let main = ["Space", "Decay Rate", "Distance", "Brightness", "Character", "Thickness", "Stereo Width", "Ducking", "Mix",
                        "Predelay", "Output Level", "Bypass"]
            let decayEQ = (1...6).flatMap { n in ["Used", "Enabled", "Frequency", "Rate", "Q", "Shape"].map { "Decay EQ Band \(n) \($0)" } }
            return ids(named: main + decayEQ, in: plugin)
        }
        return plugin.parameters.filter(\.isControl).prefix(genericCount).map(\.id)
    }

    /// The parameter IDs a plugin controls under a selection, in order: core first, then additions.
    public static func selected(for plugin: PluginDescription, _ selection: PluginSelection?) -> [String] {
        let removed = Set(selection?.removed ?? [])
        var out = core(for: plugin).filter { !removed.contains($0) }
        let known = Set(plugin.parameters.map(\.id))
        for id in selection?.added ?? [] where known.contains(id) && !out.contains(id) { out.append(id) }
        return out
    }

    /// IDs in the order of `names`; names a plugin version doesn't have are skipped.
    private static func ids(named names: [String], in plugin: PluginDescription) -> [String] {
        let byName = Dictionary(plugin.parameters.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        return names.compactMap { byName[$0] }
    }
}

extension MIDIAddress {
    /// CCs MIDI reserves (bank select, data entry, NRPN/RPN, channel mode): never handed out on the plugin ports.
    public static let reservedCCs: Set<UInt8> = Set([0, 6, 32, 38] + Array(96...101) + Array(120...127))
    public static let usableCCs: [UInt8] = (0...127).map(UInt8.init).filter { !reservedCCs.contains($0) }
}

extension ShowConfig {
    /// Selection key for a plugin type: "aumf/FQ3p/FabF".
    public static func selectionKey(_ component: AUComponentID) -> String { component.description }

    public var activePluginControls: [PluginControl] { pluginControls.filter(\.active) }

    /// Add a parameter to its plugin type's controlled set (every instance of that plugin gets it). False when it's
    /// already in the set. Call `syncPluginControls` afterwards to hand out its address.
    @discardableResult
    public mutating func addPluginControl(_ plugin: PluginDescription, parameterID id: String) -> Bool {
        let key = Self.selectionKey(plugin.component)
        var selection = pluginSelections[key] ?? PluginSelection()
        if selection.removed.contains(id) {
            selection.removed.removeAll { $0 == id }
        } else if PluginControlSets.core(for: plugin).contains(id) || selection.added.contains(id) || plugin.parameter(id: id) == nil {
            return false
        } else {
            selection.added.append(id)
        }
        pluginSelections[key] = selection
        return true
    }

    /// Take a parameter out of its plugin type's controlled set. Its address is kept for if it comes back.
    @discardableResult
    public mutating func removePluginControl(_ plugin: PluginDescription, parameterID id: String) -> Bool {
        let key = Self.selectionKey(plugin.component)
        var selection = pluginSelections[key] ?? PluginSelection()
        if selection.added.contains(id) {
            selection.added.removeAll { $0 == id }
        } else if PluginControlSets.core(for: plugin).contains(id) && !selection.removed.contains(id) {
            selection.removed.append(id)
        } else {
            return false
        }
        pluginSelections[key] = selection
        return true
    }

    public func pluginControl(at address: MIDIAddress) -> PluginControl? {
        pluginControls.first { $0.active && $0.address == address }
    }

    public func pluginControl(path: String) -> PluginControl? {
        pluginControls.first { $0.active && $0.path == path }
    }

    /// Bring the plugin controls in line with what discovery found. For every strip in `discovered`, each identified
    /// plugin that isn't the strip's EQ/dynamics/trim source (those are driven by roles) gets its selected parameters
    /// activated, allocating an address for any that never had one; that strip's other controls are deactivated.
    /// Strips discovery didn't report on are left alone. Returns how many addresses were newly handed out and how
    /// many controls changed active state.
    @discardableResult
    public mutating func syncPluginControls(discovered: [String: [Int: PluginDescription]]) -> (allocated: Int, changed: Int) {
        var allocated = 0, changed = 0
        var used = Set(pluginControls.map(\.address) + pendingLearns.map(\.address))
        var free = FOHPort.pluginPorts.lazy.flatMap { port in (1...16).lazy.flatMap { ch in
            MIDIAddress.usableCCs.lazy.map { MIDIAddress(port: port, channel: UInt8(ch), cc: $0) } } }.makeIterator()
        func nextFree() -> MIDIAddress? {
            while let a = free.next() { if !used.contains(a) { return a } }
            return nil
        }
        for strip in strips {
            guard let found = discovered[strip.ref.key] else { continue }
            let processing = Set([strip.processing.eq, strip.processing.dynamics, strip.processing.trim].compactMap { $0 })
            var wanted: [(position: Int, component: AUComponentID, parameterID: String, name: String)] = []
            for (position, plugin) in found.sorted(by: { $0.key < $1.key }) where !processing.contains(position) {
                let selection = pluginSelections[Self.selectionKey(plugin.component)]
                for id in PluginControlSets.selected(for: plugin, selection) {
                    wanted.append((position, plugin.component, id, plugin.parameter(id: id)?.name ?? id))
                }
            }
            var keep = Set<Int>()
            for w in wanted {
                if let i = pluginControls.firstIndex(where: { $0.matches(strip.ref, w.position, w.component, w.parameterID) }) {
                    keep.insert(i)
                    if !pluginControls[i].active { pluginControls[i].active = true; changed += 1 }
                    if pluginControls[i].name != w.name { pluginControls[i].name = w.name }
                } else if let address = nextFree() {
                    used.insert(address)
                    pluginControls.append(PluginControl(strip: strip.ref, position: w.position, component: w.component,
                                                        parameterID: w.parameterID, name: w.name, address: address))
                    keep.insert(pluginControls.count - 1)
                    allocated += 1
                    changed += 1
                }
            }
            for i in pluginControls.indices where pluginControls[i].strip == strip.ref && pluginControls[i].active && !keep.contains(i) {
                pluginControls[i].active = false
                changed += 1
            }
        }
        return (allocated, changed)
    }
}

extension FOHProtocol {
    /// `/foh/in/1/plugin/2/315`: strip in/1, the plugin at chain position 2, AU parameter 315.
    public static func pluginPath(_ strip: StripRef, _ position: Int, _ parameterID: String) -> String {
        "/foh/\(strip.key)/plugin/\(position)/\(parameterID)"
    }

    public static func parsePluginPath(_ path: String) -> (strip: StripRef, position: Int, parameterID: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 6, parts[0] == "foh", parts[3] == "plugin",
              let strip = StripRef(key: "\(parts[1])/\(parts[2])"), let position = Int(parts[4]) else { return nil }
        return (strip, position, parts[5...].joined(separator: "/"))
    }

    /// A value update for any value path (role or plugin control); see `valueMessage(_:_:_:confirmed:)`.
    public static func valueMessage(path: String, _ value: Int, confirmed: Bool) -> OSCMessage {
        OSCMessage(path, [.int(Int32(clampMIDI(value))), .int(confirmed ? 1 : 0)])
    }
}

// MARK: MainStage's own plugins (PLAN.md §9c phase 5)

/// A parameter of one of MainStage's own plugins (Channel EQ, Compressor…), which FOH Bridge can't load: learned from
/// one hand-made Assign & Map, then used on every instance of that plugin.
public struct LearnedParameter: Codable, Hashable, Sendable {
    /// MainStage's parameter number (`parameterIndex_1` in the concert).
    public var index: Int
    public var name: String

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}

/// A control waiting for its hand-made Assign & Map: the user maps this address to a parameter in MainStage, and
/// FOH Bridge reads which one from the saved concert.
public struct PendingLearn: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var strip: StripRef
    public var position: Int
    public var pluginName: String
    /// What the user called it ("Low Cut Freq").
    public var name: String
    public var address: MIDIAddress

    public init(id: String = UUID().uuidString, strip: StripRef, position: Int, pluginName: String, name: String, address: MIDIAddress) {
        self.id = id
        self.strip = strip
        self.position = position
        self.pluginName = pluginName
        self.name = name
        self.address = address
    }
}

extension AUComponentID {
    /// Stand-in id for one of MainStage's own plugins ("mstg/Channel EQ/appl").
    public static func mainStagePlugin(_ name: String) -> AUComponentID {
        AUComponentID(type: "mstg", subtype: name, manufacturer: "appl")
    }

    public var isMainStagePlugin: Bool { type == "mstg" && manufacturer == "appl" }
}

extension PluginDescription {
    /// The group learned parameters of a MainStage plugin go in.
    public static let learnedGroup = "Learned"

    /// Display text for MainStage plugin parameters, whose ranges and units FOH Bridge can't know: 0–100%.
    public static let percentSteps = (0...127).map { String(format: "%.0f%%", Double($0) / 127 * 100) }
    public static let onOffSteps = (0...127).map { $0 < 64 ? "Off" : "On" }

    /// What FOH Bridge knows of one of MainStage's own plugins: the parameters in MainStage's table for it
    /// (`catalog`, when there is one), plus any learned by hand.
    public static func mainStagePlugin(_ name: String, catalog: PluginDescription? = nil, learned: [LearnedParameter]) -> PluginDescription {
        var parameters = catalog?.parameters ?? []
        let listed = Set(parameters.map(\.id))
        for l in learned where !listed.contains("\(l.index)") {
            parameters.append(PluginParameterInfo(id: "\(l.index)", address: UInt64(max(l.index, 0)), name: l.name, unitName: nil, unit: 0,
                                                  minValue: 0, maxValue: 1, defaultValue: 0.5, displayLogarithmic: false, valueStrings: nil,
                                                  steps: percentSteps, writable: true, meter: false, group: learnedGroup))
        }
        return PluginDescription(component: .mainStagePlugin(name), name: name, manufacturerName: "Apple", parameters: parameters)
    }
}

extension ShowConfig {
    /// Descriptions for the MainStage plugins on a strip, by chain position: MainStage's table for the plugin
    /// (`catalog`, by plugin name) plus learned parameters. Plugins with neither are left out.
    public func mainStagePluginDescriptions(_ strip: Strip, catalog: (String) -> PluginDescription? = { _ in nil }) -> [Int: PluginDescription] {
        var out: [Int: PluginDescription] = [:]
        for p in strip.plugins where p.component == nil {
            let table = catalog(p.name), learned = learnedParameters[p.name] ?? []
            guard table != nil || !learned.isEmpty else { continue }
            out[p.position] = .mainStagePlugin(p.name, catalog: table, learned: learned)
        }
        return out
    }

    /// Hand out an address for a new learn: one no control and no other learn uses.
    public mutating func startLearn(strip: StripRef, position: Int, pluginName: String, name: String) -> PendingLearn? {
        let used = Set(pluginControls.map(\.address) + pendingLearns.map(\.address))
        for port in FOHPort.pluginPorts {
            for ch in 1...16 {
                for cc in MIDIAddress.usableCCs {
                    let a = MIDIAddress(port: port, channel: UInt8(ch), cc: cc)
                    guard !used.contains(a) else { continue }
                    let learn = PendingLearn(strip: strip, position: position, pluginName: pluginName, name: name, address: a)
                    pendingLearns.append(learn)
                    return learn
                }
            }
        }
        return nil
    }

    /// MainStage mapped a learn's address to `parameterIndex` of its plugin: remember that parameter for the plugin
    /// type, and keep the learn's address as the control's, so the hand-made mapping is that control's mapping.
    @discardableResult
    public mutating func resolveLearn(_ id: String, parameterIndex: Int) -> LearnedParameter? {
        guard let i = pendingLearns.firstIndex(where: { $0.id == id }) else { return nil }
        let learn = pendingLearns.remove(at: i)
        var list = learnedParameters[learn.pluginName] ?? []
        let learned = list.first { $0.index == parameterIndex } ?? LearnedParameter(index: parameterIndex, name: learn.name)
        if !list.contains(where: { $0.index == parameterIndex }) { list.append(learned) }
        learnedParameters[learn.pluginName] = list
        let component = AUComponentID.mainStagePlugin(learn.pluginName)
        let id = "\(parameterIndex)"
        if let c = pluginControls.firstIndex(where: { $0.matches(learn.strip, learn.position, component, id) }) {
            pluginControls[c].active = true
        } else {
            pluginControls.append(PluginControl(strip: learn.strip, position: learn.position, component: component, parameterID: id,
                                                name: learned.name, address: learn.address))
        }
        return learned
    }

    /// Forget a learned parameter of a MainStage plugin (its controls go inactive at the next sync).
    @discardableResult
    public mutating func forgetLearned(_ pluginName: String, index: Int) -> Bool {
        guard var list = learnedParameters[pluginName], list.contains(where: { $0.index == index }) else { return false }
        list.removeAll { $0.index == index }
        learnedParameters[pluginName] = list.isEmpty ? nil : list
        return true
    }
}

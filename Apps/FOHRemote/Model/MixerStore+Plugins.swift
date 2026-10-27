import FOHCore
import SwiftUI

/// One plugin control as a page uses it (PLAN.md §9c): its permanent path, plus the parameter's catalog entry
/// (range, display text at each MIDI step) once the bridge has sent the plugin's description.
struct PluginParam: Identifiable {
    let control: PluginControl
    let info: PluginParameterInfo?

    var id: String { control.path }
    var path: String { control.path }
    var name: String { control.name }

    func display(_ midi: Int) -> String { info?.display(midi) ?? "\(midi)" }

    /// The parsed number (Hz, dB, %…) at a MIDI value, or nil ("Auto", "-INF dB").
    func numeric(_ midi: Int) -> Double? {
        guard let v = info?.numeric(midi)?.value, v.isFinite else { return nil }
        return v
    }

    var stepCenters: [(midi: Int, label: String)] { info?.stepCenters ?? [] }
    var isToggle: Bool { info.map { $0.kind == .toggle || $0.stepCenters.count == 2 } ?? false }
    var isStepped: Bool {
        if case .stepped = info?.kind { return true }
        return false
    }

    /// The MIDI value whose display is closest to `target` (in the parsed unit).
    func midi(closestTo target: Double) -> Int? { info?.midi(closestTo: target) }

    /// The parameter's default as MIDI; nil for MainStage's own plugins, whose defaults FOH Bridge can't know.
    var defaultMIDI: Int? { control.component.isMainStagePlugin ? nil : info?.defaultMIDI }
}

/// A plugin's active controls, looked up by parameter name ("Band 3 Frequency").
struct PluginControls {
    let strip: StripRef
    let position: Int
    let byName: [String: PluginParam]
    /// In allocation order (core set first, then additions).
    let all: [PluginParam]
    /// The bridge's description has arrived (ranges and display text are known).
    let described: Bool

    subscript(_ name: String) -> PluginParam? { byName[name] }
    var isEmpty: Bool { all.isEmpty }
}

extension MixerStore {
    func pluginControls(_ strip: StripRef, _ position: Int) -> PluginControls {
        let controls = config.pluginControls.filter { $0.active && $0.strip == strip && $0.position == position }
        let index = parameterIndex(strip, position)
        let params = controls.map { PluginParam(control: $0, info: index?[$0.parameterID]) }
        var byName: [String: PluginParam] = [:]
        for p in params where byName[p.name] == nil { byName[p.name] = p }
        return PluginControls(strip: strip, position: position, byName: byName, all: params, described: index != nil)
    }

    func hasPluginControls(_ strip: StripRef, _ position: Int) -> Bool {
        config.pluginControls.contains { $0.active && $0.strip == strip && $0.position == position }
    }

    /// Parameters by ID for a plugin whose description is cached (built once per description).
    private func parameterIndex(_ strip: StripRef, _ position: Int) -> [String: PluginParameterInfo]? {
        guard let desc = pluginDescription(strip, position) else { return nil }
        let key = pluginKey(strip, position) + "|" + desc.component.description
        if let cached = pluginParameterIndex[key], cached.count == desc.parameters.count { return cached }
        let index = Dictionary(desc.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        pluginParameterIndex[key] = index
        return index
    }

    /// Unknown values read as the parameter's default (until the bridge sends one).
    func value(_ p: PluginParam) -> Int { values[p.path] ?? p.defaultMIDI ?? 0 }

    func isOn(_ p: PluginParam) -> Bool { value(p) >= 64 }

    func set(_ p: PluginParam, _ value: Int) {
        guard !locked else { return }
        send(path: p.path, FOHProtocol.clampMIDI(value))
    }

    func set(_ p: PluginParam, numeric target: Double) {
        guard let midi = p.midi(closestTo: target) else { return }
        set(p, midi)
    }

    func toggle(_ p: PluginParam) { set(p, isOn(p) ? 0 : 127) }

    func numeric(_ p: PluginParam) -> Double? { p.numeric(value(p)) }

    func display(_ p: PluginParam) -> String { p.display(value(p)) }

    func beginTouch(_ p: PluginParam) { beginTouch(path: p.path) }
    func endTouch(_ p: PluginParam) { endTouch(path: p.path) }

    /// Set several controls as one gesture (adding a band): each is touched, set, and released together.
    func setTogether(_ changes: [(PluginParam?, Int)]) {
        let real = changes.compactMap { p, v in p.map { ($0, v) } }
        real.forEach { beginTouch($0.0) }
        real.forEach { set($0.0, $0.1) }
        real.forEach { endTouch($0.0) }
    }
}

// MARK: Add control / remove control (PLAN.md §9c phase 4)

extension MixerStore {
    /// Add a parameter to its plugin type's controls (every instance gets it; MainStage maps it at the next update).
    func addPluginControl(_ strip: StripRef, _ position: Int, parameterID: String) {
        changePluginControl(strip, position, parameterID: parameterID, add: true)
    }

    func removePluginControl(_ strip: StripRef, _ position: Int, parameterID: String) {
        changePluginControl(strip, position, parameterID: parameterID, add: false)
    }

    private func changePluginControl(_ strip: StripRef, _ position: Int, parameterID: String, add: Bool) {
        guard !locked else { return }
        guard isDemo else {
            let path = add ? FOHProtocol.Path.pluginControlAdd : FOHProtocol.Path.pluginControlRemove
            client?.send(OSCMessage(path, [.string(strip.key), .int(Int32(position)), .string(parameterID)]))
            return
        }
        // Offline: the same change the bridge makes, against the bundled catalogs.
        guard let plugin = pluginDescription(strip, position), let name = plugin.parameter(id: parameterID)?.name else { return }
        let changed = add ? config.addPluginControl(plugin, parameterID: parameterID) : config.removePluginControl(plugin, parameterID: parameterID)
        guard changed else { return }
        config.syncPluginControls(discovered: Dictionary(uniqueKeysWithValues: config.strips.map { ($0.ref.key, DemoShow.discovered(for: $0)) }))
        showToast("\(add ? "Added" : "Removed") \(name) on every \(plugin.name) (demo)")
    }
}

// MARK: MainStage's own plugins (PLAN.md §9c phase 5)

extension MixerStore {
    /// Name a control of one of MainStage's own plugins; the bridge hands out an address to map it to by hand.
    func startPluginLearn(_ strip: StripRef, _ position: Int, name: String) {
        guard !locked else { return }
        guard isDemo else {
            client?.send(OSCMessage(FOHProtocol.Path.pluginLearnStart, [.string(strip.key), .int(Int32(position)), .string(name)]))
            return
        }
        guard let plugin = config.strip(strip)?.plugin(at: position) else { return }
        _ = config.startLearn(strip: strip, position: position, pluginName: plugin.name, name: name)
    }

    /// The learn signal: a sweep on the learn's address, while Assign & Map is on in MainStage.
    func sendPluginLearn(_ learn: PendingLearn) {
        guard isDemo else { return client?.send(OSCMessage(FOHProtocol.Path.pluginLearnSend, [.string(learn.id)])) ?? () }
        showToast("Sent \(learn.name)'s learn signal (demo)")
    }

    func cancelPluginLearn(_ learn: PendingLearn) {
        guard isDemo else { return client?.send(OSCMessage(FOHProtocol.Path.pluginLearnCancel, [.string(learn.id)])) ?? () }
        config.pendingLearns.removeAll { $0.id == learn.id }
    }

    /// Ask the bridge to read the saved concert for finished learns (it also does when MainStage quits). Offline,
    /// pretend MainStage mapped each one, so the flow can be tried.
    func checkPluginLearns() {
        guard isDemo else { return client?.send(OSCMessage(FOHProtocol.Path.pluginLearnCheck)) ?? () }
        for (n, learn) in config.pendingLearns.enumerated() { config.resolveLearn(learn.id, parameterIndex: 900 + n) }
        config.syncPluginControls(discovered: Dictionary(uniqueKeysWithValues: config.strips.map { s in
            (s.ref.key, DemoShow.discovered(for: s).merging(config.mainStagePluginDescriptions(s)) { a, _ in a })
        }))
        showToast("Learned (demo: as if MainStage had mapped them)")
    }

    /// Send the learn signal for one control (mapping it by hand in MainStage, e.g. the first on a mono output).
    func sendLearnSignal(_ p: PluginParam) {
        guard isDemo else { return client?.send(OSCMessage(FOHProtocol.Path.learnFire, [.string(p.path)])) ?? () }
        showToast("Sent \(p.name)'s learn signal (demo)")
    }
}

/// Parameters under headings for the controls page and the Add control list: the plugin's own groups ("Band 3")
/// when it has them, else shared first words ("Vibrato Depth", "Vibrato On/Off" → Vibrato), else "Main".
struct ParameterGroup: Identifiable {
    let name: String
    var items: [PluginParameterInfo]
    var id: String { name }

    static func make(_ parameters: [PluginParameterInfo]) -> [ParameterGroup] {
        func own(_ p: PluginParameterInfo) -> String {
            let g = (p.group ?? "").replacingOccurrences(of: "global › ", with: "").replacingOccurrences(of: "global", with: "")
            return g.isEmpty ? "Main" : g
        }
        let owns = parameters.map(own)
        let useOwn = Set(owns).count > 1
        var firstWordCounts: [String: Int] = [:]
        for p in parameters { firstWordCounts[firstWord(p.name), default: 0] += 1 }
        var groups: [ParameterGroup] = []
        for (i, p) in parameters.enumerated() {
            let word = firstWord(p.name)
            let name = useOwn ? owns[i] : (firstWordCounts[word, default: 0] > 1 && word.count > 1 ? word : "Main")
            if let g = groups.firstIndex(where: { $0.name == name }) { groups[g].items.append(p) } else { groups.append(.init(name: name, items: [p])) }
        }
        // "Main" first: it holds the plugin's top-level controls.
        return groups.sorted { ($0.name == "Main" ? 0 : 1) < ($1.name == "Main" ? 0 : 1) }
    }

    /// "Vibrato Depth" → "Vibrato"; a numbered prefix stays whole ("Band 9 Frequency" → "Band 9").
    private static func firstWord(_ name: String) -> String {
        let words = name.split(separator: " ")
        guard let first = words.first else { return "" }
        if words.count > 2, Int(words[1]) != nil { return "\(first) \(words[1])" }
        return String(first)
    }
}

extension View {
    /// Ask the bridge for a plugin's description whenever its page shows without one: on appear, and again once a
    /// bridge has synced (a page opened before the first sync, from the demo, or across a reconnect).
    func requestingPlugin(_ store: MixerStore, _ strip: StripRef, _ position: Int, described: Bool) -> some View {
        task(id: "\(store.isDemo) \(store.synced) \(described)") {
            if !described { store.requestPlugin(strip, position) }
        }
    }
}

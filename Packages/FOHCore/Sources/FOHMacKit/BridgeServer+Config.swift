#if os(macOS)
import Foundation
import FOHCore

// Show editing, concert import, the binding editor and the setlist (PLAN.md §3, §5, §6).
extension BridgeServer {
    // MARK: Bindings

    /// Template binding + manual overrides + neutral defaults for one strip, from the current discovery results.
    func rebuildBinding(_ strip: Strip) {
        let found = discovered[strip.ref.key] ?? [:]
        var binding = StripBinding.build(for: strip, sends: show.sends, discovered: found, calibration: show.faderCalibration,
                                         customTemplates: show.customTemplates)
        applyOverrides(&binding, strip: strip, discovered: found)
        show.bindings[strip.ref.key] = binding
        seedDefaults(strip.ref, binding, discovered: found)
        // Plugin controls (PLAN.md §9c) only once discovery has reported on this strip (or it has a MainStage plugin
        // with learned parameters).
        if let reported = reportedPlugins(strip) {
            show.syncPluginControls(discovered: [strip.ref.key: reported])
            seedPluginDefaults(strip.ref, discovered: reported)
        }
    }

    /// Plugin controls MainStage hasn't reported yet start at the plugin's own default.
    func seedPluginDefaults(_ strip: StripRef, discovered found: [Int: PluginDescription]) {
        var seeded = 0
        // MainStage's own plugins have no known defaults: their values come only from MainStage ("Send Value to"), so
        // a Push all can never send a made-up value to them.
        for control in show.pluginControls where control.active && control.strip == strip && values[control.path] == nil
            && !control.component.isMainStagePlugin {
            guard let midi = found[control.position]?.parameter(id: control.parameterID)?.defaultMIDI else { continue }
            values[control.path] = midi
            seeded += 1
        }
        if seeded > 0 {
            valueCount = values.count
            scheduleSaveValues()
        }
    }

    func applyOverrides(_ binding: inout StripBinding, strip: Strip, discovered found: [Int: PluginDescription]) {
        guard let manual = overrides[strip.ref.key] else { return }
        for (roleID, override) in manual.sorted(by: { $0.key < $1.key }) {
            guard let role = Role.byID[roleID] else { continue }
            if override.hides {
                binding.roles[roleID] = nil
                if !binding.notInPlugin.contains(roleID) { binding.notInPlugin.append(roleID) }
                continue
            }
            if let b = Self.makeBinding(role, position: override.position, parameterID: override.parameterID, strip: strip, discovered: found) {
                binding.roles[roleID] = b
                binding.notInPlugin.removeAll { $0 == roleID }
            }
        }
        binding.notInPlugin.sort()
    }

    /// A manual RoleBinding for a plugin parameter (from discovery) or a MainStage channel-strip control ("@volume").
    static func makeBinding(_ role: Role, position: Int, parameterID: String, strip: Strip,
                            discovered found: [Int: PluginDescription]) -> RoleBinding? {
        if parameterID.hasPrefix("@") {
            guard let param = ChannelStripParameter(id: parameterID) else { return nil }
            var b = param.binding(role, pluginName: position == 0 ? "Channel strip" : (strip.plugin(at: position)?.name ?? "Plugin \(position)"),
                                  position: position)
            b.origin = .manual
            return b
        }
        guard let plugin = found[position], let p = plugin.parameter(id: parameterID) else { return nil }
        var kind = p.kind
        if role.kind == .toggle, case .stepped(2) = kind { kind = .toggle }
        // "EQBypass" bound to "EQ on": the role's on is the parameter's off.
        let invert = p.name.lowercased().contains("bypass") && (role.id.hasSuffix(".on") || role.id == "eq.on" || role.id == "dyn.on")
        return RoleBinding(role: role, pluginPosition: position, pluginName: strip.plugin(at: position)?.name ?? plugin.name,
                           parameterID: p.id, parameterName: p.name, unitName: p.unitName, kind: kind,
                           steps: invert ? p.steps.reversed() : p.steps, invert: invert, origin: .manual)
    }

    /// `/foh/bind/set`: bind a role to a parameter ("" hides it). Survives rebuilds and rediscovery.
    @discardableResult
    public func setBinding(strip key: String, roleID: String, position: Int, parameterID: String) -> BridgeAck {
        guard let ref = StripRef(key: key), let strip = show.strip(ref), let role = Role.byID[roleID] else {
            return .fail("Unknown strip \(key) or role \(roleID)")
        }
        if !parameterID.isEmpty, !parameterID.hasPrefix("@"), discovered[key]?[position]?.parameter(id: parameterID) == nil {
            return .fail("\(strip.name) has no discovered parameter \(parameterID) at plugin \(position)")
        }
        overrides[key, default: [:]][roleID] = BindingOverride(position: position, parameterID: parameterID)
        rebuildBinding(strip)
        let what = parameterID.isEmpty ? "hidden" : (show.binding(ref)[role].map { "\($0.pluginName) › \($0.parameterName)" } ?? parameterID)
        log("Bound \(strip.name) \(role.id) → \(what) (manual)")
        commitBindingChange()
        return .ok("\(strip.name): \(role.label) → \(what)")
    }

    /// `/foh/bind/apply`: make `to` mirror `from` — processing sources and manual overrides are mapped across by
    /// plugin component, so Guitar's SSL (position 1) gets what Lead vox's SSL (position 3) has.
    @discardableResult
    public func applyBindings(from fromKey: String, to toKey: String) -> BridgeAck {
        guard let fromRef = StripRef(key: fromKey), let toRef = StripRef(key: toKey),
              let source = show.strip(fromRef), let index = show.strips.firstIndex(where: { $0.ref == toRef }) else {
            return .fail("Unknown strip \(fromKey) or \(toKey)")
        }
        var target = show.strips[index]
        func mapped(_ position: Int?) -> Int? {
            guard let position else { return nil }
            if position == 0 { return 0 }
            guard let component = source.plugin(at: position)?.component else { return nil }
            return target.plugins.first { $0.component == component }?.position
        }
        var processing = target.processing
        if source.processing.eq != nil, let p = mapped(source.processing.eq) { processing.eq = p }
        if source.processing.dynamics != nil, let p = mapped(source.processing.dynamics) { processing.dynamics = p }
        if source.processing.trim != nil, let p = mapped(source.processing.trim) { processing.trim = p }
        for (page, position) in source.processing.insertPages {
            if let p = mapped(position) { processing.insertPages[page] = p }
        }
        target.processing = processing
        show.strips[index] = target

        var copied: [String: BindingOverride] = overrides[toKey] ?? [:]
        var count = 0
        for (roleID, override) in overrides[fromKey] ?? [:] {
            if override.hides || override.parameterID.hasPrefix("@") {
                copied[roleID] = override
            } else if let p = mapped(override.position) {
                copied[roleID] = BindingOverride(position: p, parameterID: override.parameterID)
            } else {
                continue
            }
            count += 1
        }
        overrides[toKey] = copied.isEmpty ? nil : copied
        rebuildBinding(target)
        log("Applied \(source.name)'s bindings to \(target.name): \(count) manual override(s), processing mapped by plugin")
        if discovered[toKey] == nil && options.discoverPlugins { runDiscovery(strips: [toKey]) }
        commitBindingChange()
        return .ok("Applied \(source.name)'s bindings to \(target.name) (\(count) manual)")
    }

    /// `/foh/bind/reset`: drop manual bindings and re-run the templates.
    @discardableResult
    public func resetBindings(strip key: String) -> BridgeAck {
        guard let ref = StripRef(key: key), let strip = show.strip(ref) else { return .fail("Unknown strip \(key)") }
        snapshot("Before resetting \(strip.name)'s bindings")
        overrides[key] = nil
        rebuildBinding(strip)
        log("Reset \(strip.name) to its templates")
        commitBindingChange()
        return .ok("\(strip.name) reset to its templates")
    }

    /// `/foh/calibration/set`: adopt measured MainStage fader readings and rebuild every fader and send scale.
    @discardableResult
    public func setFaderCalibration(_ points: [CalibrationPoint]) -> BridgeAck {
        snapshot("Before fader calibration")
        show.faderCalibration = points.sorted { $0.midi < $1.midi }
        for strip in show.strips { rebuildBinding(strip) }
        let summary = show.faderCalibration.map { "\($0.midi)→\($0.db.map { String(format: "%.1f", $0) } ?? "-inf")" }.joined(separator: " ")
        log("Fader calibration: \(points.isEmpty ? "cleared (estimated law)" : summary)")
        commitBindingChange()
        return .ok(points.isEmpty ? "Fader calibration cleared" : "Fader calibration saved (\(points.count) points)")
    }

    func commitBindingChange() {
        do { try options.store.saveOverrides(overrides) } catch { log("Couldn't save overrides: \(error)") }
        saveShow()
        broadcastConfig()
    }

    // MARK: Plugin controls (PLAN.md §9c phase 4)

    /// `/foh/plugin/control/add|remove`: add a parameter to (or take it out of) its plugin type's controls. Every
    /// strip with that plugin gets the change; MainStage learns it at the next update (automatic once it's closed).
    @discardableResult
    public func changePluginControl(strip key: String, position: Int, parameterID: String, add: Bool) -> BridgeAck {
        guard let plugin = StripRef(key: key).flatMap({ show.strip($0) }).flatMap(reportedPlugins)?[position] else {
            return .fail("FOH Bridge hasn't read the plugin at \(key) insert \(position)")
        }
        guard let parameter = plugin.parameter(id: parameterID) else { return .fail("\(plugin.name) has no parameter \(parameterID)") }
        if add && (parameter.writable == false || parameter.meter == true) {
            return .fail("\(parameter.name) is a meter or read-only; MainStage can't set it")
        }
        let changed = add ? show.addPluginControl(plugin, parameterID: parameterID) : show.removePluginControl(plugin, parameterID: parameterID)
        guard changed else { return .ok("\(parameter.name) is already \(add ? "a control" : "off the iPad")") }
        let before = Set(show.activePluginControls.map(\.path))
        let strips = show.strips.filter { s in reportedPlugins(s)?.values.contains { $0.component == plugin.component } == true }
        for strip in strips { rebuildBinding(strip) }
        commitBindingChange()
        for control in show.activePluginControls where !before.contains(control.path) {
            if let v = values[control.path] {
                broadcast(.message(FOHProtocol.valueMessage(path: control.path, v, confirmed: confirmedPaths.contains(control.path))))
            }
        }
        let verb = add ? "Added" : "Removed"
        log("Plugin controls: \(verb.lowercased()) \(parameter.name) on \(plugin.name) (\(strips.count) strip\(strips.count == 1 ? "" : "s"))")
        return .ok("\(verb) \(parameter.name) on every \(plugin.name) · \(mainStageSync.summary)")
    }

    // MARK: Show editing

    /// `/foh/config/set`: adopt the client's strips, sends and setlist. Bindings for strips whose plugins and
    /// processing didn't change are kept; changed or new strips are rebuilt and rediscovered.
    @discardableResult
    public func applyConfig(_ incoming: ShowConfig, from who: String = "local") -> BridgeAck {
        snapshot("Before config change from \(who)")
        var new = incoming
        var seen = Set<StripRef>()
        new.strips = new.strips.filter { seen.insert($0.ref).inserted }.sorted { $0.ref < $1.ref }
        new.bindings = [:]
        // Only their own endpoints change calibration and custom templates; the client's stripOrder is kept.
        new.faderCalibration = show.faderCalibration
        new.customTemplates = show.customTemplates
        // Plugin controls are the bridge's too: a client's copy may be older than a learn or an Add control.
        new.pluginControls = show.pluginControls
        new.pluginSelections = show.pluginSelections
        new.learnedParameters = show.learnedParameters
        new.pendingLearns = show.pendingLearns
        new.stripOrder = new.stripOrder.filter { key in new.strips.contains { $0.ref.key == key } }
        let old = show
        let sendsChanged = old.sends != new.sends
        var rebuild: [Strip] = []
        var rediscover: Set<String> = []
        for strip in new.strips {
            let key = strip.ref.key
            if let previous = old.strip(strip.ref), previous.plugins == strip.plugins, previous.processing == strip.processing,
               let binding = old.bindings[key] {
                new.bindings[key] = binding
                if sendsChanged && strip.ref.kind == .input { rebuild.append(strip) }
            } else {
                if old.strip(strip.ref)?.plugins != strip.plugins {
                    discovered[key] = nil
                    if strip.plugins.contains(where: { $0.component != nil }) { rediscover.insert(key) }
                }
                rebuild.append(strip)
            }
        }
        for strip in old.strips where new.strip(strip.ref) == nil {
            discovered[strip.ref.key] = nil
            overrides[strip.ref.key] = nil
        }
        if let current = new.currentPatch, current >= new.patches.count { new.currentPatch = new.patches.isEmpty ? nil : 0 }
        show = new
        for strip in rebuild { rebuildBinding(strip) }
        log("Config from \(who): \(new.strips.count) strips, \(new.sends.count) sends, \(new.patches.count) patches; rebuilt \(rebuild.count)")
        commitBindingChange()
        if !rediscover.isEmpty && options.discoverPlugins { runDiscovery(strips: rediscover) }
        return .ok("Saved: \(new.strips.count) strips, \(new.sends.count) sends\(rebuild.isEmpty ? "" : " · rebuilt \(rebuild.count)")")
    }

    // MARK: Concert import

    /// Scan a `.concert` (default: the show's concert, else the first on the Desktop).
    @discardableResult
    public func scanConcert(path: String?) throws -> ConcertInfo {
        let url: URL
        if let path, !path.isEmpty {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if let found = ConcertParser.defaultConcertURL(preferred: show.concertPath) {
            url = found
        } else {
            throw ConcertParser.ParseError.notAConcert("~/Desktop (no .concert found)")
        }
        let info = try ConcertParser.parse(url)
        lastConcert = info
        log("Scanned \(url.lastPathComponent): \(info.strips.count) strips, \(info.patches.count) patches")
        return info
    }

    /// Scan and merge into the show (`ShowConfig.merged(with:)`), then rebuild and rediscover what changed.
    @discardableResult
    public func mergeConcert(path: String?) throws -> BridgeAck {
        let info = try scanConcert(path: path)
        return adoptConcert(info)
    }

    private func adoptConcert(_ info: ConcertInfo) -> BridgeAck {
        let name = URL(fileURLWithPath: info.path).lastPathComponent
        snapshot("Before concert merge (\(name))")
        let before = Set(show.strips.map(\.ref))
        let merged = show.merged(with: info)
        let added = merged.strips.filter { !before.contains($0.ref) }.count
        applyConfig(merged, from: "concert \(name)")
        return .ok("Concert merged from \(name): \(added) new strip\(added == 1 ? "" : "s")")
    }

    /// Reading a concert (even listing ~/Desktop to find one) can sit behind a macOS privacy prompt until the user
    /// answers it, so the network/menu paths parse on this queue and finish on main — MIDI and OSC never stall.
    static let concertQueue = DispatchQueue(label: "foh.bridge.concert", qos: .userInitiated)

    public func scanConcertInBackground(path: String?, completion: @escaping (Result<ConcertInfo, Error>) -> Void) {
        let preferred = show.concertPath
        log("Reading concert \(path.map { ($0 as NSString).lastPathComponent } ?? "(default)")… macOS may ask FOH Bridge for folder access")
        Self.concertQueue.async {
            let result = Result<ConcertInfo, Error> {
                let url: URL
                if let path, !path.isEmpty {
                    url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                } else if let found = ConcertParser.defaultConcertURL(preferred: preferred) {
                    url = found
                } else {
                    throw ConcertParser.ParseError.notAConcert("~/Desktop (no .concert found)")
                }
                return try ConcertParser.parse(url)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .success(let info) = result {
                    self.lastConcert = info
                    self.log("Scanned \(URL(fileURLWithPath: info.path).lastPathComponent): \(info.strips.count) strips, \(info.patches.count) patches")
                }
                completion(result)
            }
        }
    }

    public func mergeConcertInBackground(path: String?, completion: @escaping (BridgeAck) -> Void) {
        scanConcertInBackground(path: path) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info): completion(self.adoptConcert(info))
            case .failure(let error): completion(.fail("Concert merge failed: \(error)"))
            }
        }
    }

    // MARK: Plugins

    /// `/foh/plugin/get`: the full discovered parameter list, from memory, the disk cache, or after discovery.
    func sendPlugin(strip key: String, position: Int, to conn: BridgeConnection) {
        let mainStage = StripRef(key: key).flatMap { show.strip($0) }
            .flatMap { show.mainStagePluginDescriptions($0, catalog: options.mainStageCatalog ?? { _ in nil })[position] }
        if let description = discovered[key]?[position] ?? cachedPlugin(strip: key, position: position) ?? mainStage {
            sendPluginMessage(strip: key, position: position, description, to: conn)
            return
        }
        guard let ref = StripRef(key: key), show.strip(ref)?.plugin(at: position)?.component != nil else {
            return log("plugin/get: \(key) has no identified plugin at position \(position)")
        }
        pendingPluginRequests.append((conn.id, key, position))
        runDiscovery(strips: [key])
    }

    private func cachedPlugin(strip key: String, position: Int) -> PluginDescription? {
        guard let ref = StripRef(key: key), let component = show.strip(ref)?.plugin(at: position)?.component else { return nil }
        return options.store.loadPlugin(component)
    }

    private func sendPluginMessage(strip key: String, position: Int, _ description: PluginDescription, to conn: BridgeConnection) {
        guard let json = try? JSONEncoder().encode(description) else { return }
        conn.send(OSCMessage(FOHProtocol.Path.plugin, [.string(key), .int(Int32(position)), .blob(json)]))
    }

    func answerPendingPluginRequests() {
        let pending = pendingPluginRequests
        pendingPluginRequests = []
        for request in pending {
            guard let conn = connections[request.conn] else { continue }
            if let d = discovered[request.strip]?[request.position] {
                sendPluginMessage(strip: request.strip, position: request.position, d, to: conn)
            } else {
                log("plugin/get: discovery found nothing at \(request.strip) position \(request.position)")
            }
        }
    }

    // MARK: Setlist

    /// `/foh/patch/select`: Program Change on "FOH Global" ch 1, then remember the patch.
    @discardableResult
    public func selectPatch(_ index: Int) -> BridgeAck {
        guard show.patches.indices.contains(index) else { return .fail("No patch \(index)") }
        let patch = show.patches[index]
        guard let pc = patch.programChange else {
            return .fail("Patch \"\(patch.name)\" has no program change — set one in MainStage's Patch Inspector")
        }
        sendProgramChange(pc)
        show.currentPatch = index
        log("Patch → \(patch.name) (PC \(pc))")
        saveShow()
        broadcastConfig()
        return .ok("Selected \(patch.name) (PC \(pc))")
    }

    /// `/foh/pull`: re-select the current patch so MainStage re-sends every mapped value through "Send Value to".
    @discardableResult
    public func pullFromMainStage() -> BridgeAck {
        guard let index = show.currentPatch, show.patches.indices.contains(index), let pc = show.patches[index].programChange else {
            return .fail("Pull needs a current patch with a program change")
        }
        sendProgramChange(pc)
        log("Pull: re-selected \(show.patches[index].name) (PC \(pc)) — MainStage re-sends mapped values")
        return .ok("Re-selected \(show.patches[index].name) — MainStage re-sends its mapped values")
    }

    func sendProgramChange(_ program: Int) {
        engine.send(.global, status: FOHProtocol.programChangeStatus, data1: UInt8(FOHProtocol.clampMIDI(program)), data2: 0)
    }
}

extension ChannelStripParameter {
    /// Parse an id like "@volume", "@send3.level", "@plugin2.bypass".
    public init?(id: String) {
        switch id {
        case "@volume": self = .volume
        case "@mute": self = .mute
        case "@solo": self = .solo
        case "@pan": self = .pan
        case "@record": self = .record
        default:
            let body = id.dropFirst()
            func number(after prefix: String, before suffix: String) -> Int? {
                guard body.hasPrefix(prefix), body.hasSuffix(suffix) else { return nil }
                return Int(body.dropFirst(prefix.count).dropLast(suffix.count))
            }
            if let n = number(after: "send", before: ".level") { self = .sendLevel(n) }
            else if let n = number(after: "send", before: ".mute") { self = .sendMute(n) }
            else if let n = number(after: "plugin", before: ".bypass") { self = .pluginBypass(n) }
            else { return nil }
        }
    }
}
#endif

#if os(macOS)
import Foundation
import FOHCore

/// MainStage's own plugins (PLAN.md §9c phase 5). They aren't Audio Units, but MainStage ships a parameter table for
/// most of them (`MainStagePluginCatalog`), so they get plugin controls like any other plugin. For a parameter no
/// table lists, one hand-made Assign & Map teaches it: the user names a control on the iPad, the bridge hands out an
/// address and sends a learn signal on it while the user maps a parameter in MainStage, and once the concert is saved
/// the bridge reads which parameter that was. Every instance of the plugin then gets it, and the writer maps the rest.
extension BridgeServer {
    /// What a strip's plugin controls come from: discovery's Audio Units plus stand-ins for MainStage plugins with
    /// learned parameters. nil until discovery has reported on the strip (unless a MainStage plugin has some).
    func reportedPlugins(_ strip: Strip) -> [Int: PluginDescription]? {
        let mainStage = show.mainStagePluginDescriptions(strip, catalog: options.mainStageCatalog ?? { _ in nil })
        guard let found = discovered[strip.ref.key] else {
            // Not before discovery has read the strip's Audio Units: syncing without them would switch theirs off.
            let hasAudioUnits = strip.plugins.contains { $0.component != nil }
            return mainStage.isEmpty || hasAudioUnits ? nil : mainStage
        }
        return found.merging(mainStage) { au, _ in au }
    }

    @discardableResult
    public func startPluginLearn(strip key: String, position: Int, name: String) -> BridgeAck {
        guard let ref = StripRef(key: key), let plugin = show.strip(ref)?.plugin(at: position) else {
            return .fail("No plugin at \(key) insert \(position)")
        }
        guard plugin.component == nil else {
            return .fail("\(plugin.name) is an Audio Unit: use Add control instead (FOH Bridge reads its parameters)")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .fail("Give the control a name first") }
        guard let learn = show.startLearn(strip: ref, position: position, pluginName: plugin.name, name: trimmed) else {
            return .fail("No free address left on the plugin ports")
        }
        saveShow()
        broadcastConfig()
        log("Learn \(plugin.name) › \(trimmed) on \(show.strip(ref)?.name ?? key): \(portName(learn.address.port)) ch \(learn.address.channel) CC \(learn.address.cc)")
        return .ok("Learning \(trimmed): in MainStage, Assign & Map \(plugin.name)'s parameter, then tap Send")
    }

    @discardableResult
    public func sendPluginLearn(_ id: String) -> BridgeAck {
        guard let learn = show.pendingLearns.first(where: { $0.id == id }) else { return .fail("That learn is no longer waiting") }
        // The parameter follows the sweep once MainStage has mapped it: leave it in the middle.
        sweep(learn.address, restore: 64, label: "learn \(learn.pluginName) › \(learn.name)")
        return .ok("Sent \(learn.name)'s learn signal")
    }

    @discardableResult
    public func cancelPluginLearn(_ id: String) -> BridgeAck {
        guard let i = show.pendingLearns.firstIndex(where: { $0.id == id }) else { return .ok("Nothing to cancel") }
        let learn = show.pendingLearns.remove(at: i)
        saveShow()
        broadcastConfig()
        return .ok("Stopped learning \(learn.name)")
    }

    @discardableResult
    public func forgetLearnedParameter(_ pluginName: String, index: Int) -> BridgeAck {
        guard show.forgetLearned(pluginName, index: index) else { return .ok("Nothing to forget") }
        for strip in show.strips where strip.plugins.contains(where: { $0.component == nil && $0.name == pluginName }) {
            // Discovery's report doesn't cover MainStage plugins: sync the strip so the forgotten control goes inactive.
            if let reported = reportedPlugins(strip) { show.syncPluginControls(discovered: [strip.ref.key: reported]) }
            else if !strip.plugins.contains(where: { $0.component != nil }) { show.syncPluginControls(discovered: [strip.ref.key: [:]]) }
        }
        commitBindingChange()
        return .ok("Forgot \(pluginName) parameter \(index)")
    }

    /// Read the saved concert for pending learns MainStage now maps. Runs the writer's `--list-mappings` off the main
    /// thread; finished learns become controls on every instance of their plugin.
    public func checkPluginLearns(completion: ((BridgeAck) -> Void)? = nil) {
        guard !show.pendingLearns.isEmpty else { completion?(.ok("No learns waiting")); return }
        guard let path = show.concertPath, FileManager.default.fileExists(atPath: path), let writer = options.concertWriter else {
            completion?(.fail("Can't read the concert to finish learns (import it, and run the bridge app)"))
            return
        }
        Self.concertQueue.async { [weak self] in
            let result = Result { try ConcertSync.listMappings(concert: URL(fileURLWithPath: path), writer: writer) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.log("⚠︎ Couldn't read the concert's mappings: \(error)")
                    completion?(.fail("Couldn't read the concert: \(error)"))
                case .success(let mappings):
                    completion?(self.resolveLearns(mappings))
                }
            }
        }
    }

    /// Match pending learns to the concert's mappings by address.
    @discardableResult
    func resolveLearns(_ mappings: [ConcertSync.Mapping]) -> BridgeAck {
        var learned: [String] = [], problems: [String] = []
        for learn in show.pendingLearns {
            let uid = Int(engine.uniqueID(of: learn.address.port))
            guard let m = mappings.first(where: { $0.source == uid && $0.channel == Int(learn.address.channel) && $0.cc == Int(learn.address.cc) })
            else { continue }
            guard m.kind == "MAPlugInParameterMapping", let index = m.parameter else {
                problems.append("\(learn.name) is mapped to something other than a plugin parameter (\(m.kind ?? "?"))")
                continue
            }
            guard m.position == learn.position else {
                problems.append("\(learn.name) is mapped to insert \(m.position.map(String.init) ?? "?"), not \(learn.pluginName) on insert \(learn.position)")
                continue
            }
            if let p = show.resolveLearn(learn.id, parameterIndex: index) { learned.append("\(learn.pluginName) › \(p.name) (#\(index))") }
        }
        problems.forEach { log("⚠︎ Learn: \($0)") }
        guard !learned.isEmpty else {
            let waiting = show.pendingLearns.count
            return problems.isEmpty ? .ok("\(waiting) learn\(waiting == 1 ? "" : "s") still waiting: map in MainStage, then save the concert")
                                    : .fail(problems.joined(separator: " · "))
        }
        for strip in show.strips where strip.plugins.contains(where: { $0.component == nil }) { rebuildBinding(strip) }
        commitBindingChange()
        log("Learned \(learned.joined(separator: ", ")); every instance of the plugin gets it at the next MainStage update")
        return .ok("Learned " + learned.joined(separator: ", "))
    }

    /// A full 0→127→0 sweep on one address (so MainStage's Assign & Map sees the whole range), then `restore`.
    func sweep(_ address: MIDIAddress, restore: Int?, label: String) {
        var steps = Array(stride(from: 0, through: 124, by: 4)) + [127]
        steps += Array(stride(from: 123, through: 3, by: -4)) + [0]
        let interval = 0.015
        let total = Double(steps.count) * interval
        sweepingUntil[address] = ProcessInfo.processInfo.systemUptime + total + 0.25 + Self.echoWindow
        log("Learn sweep \(label) → \(portName(address.port)) · ch \(address.channel) · CC \(address.cc)")
        for (i, v) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * interval) { [weak self] in self?.sendWire(address, v) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.25) { [weak self] in
            guard let self else { return }
            self.sweepingUntil[address] = nil
            if let restore { self.sendWire(address, restore) }
        }
    }
}
#endif

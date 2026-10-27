#if os(macOS)
import AppKit
import Foundation
import FOHCore

/// Parameter names of MainStage's own plugins (Channel EQ, Compressor, Multipressor… about 130), from the tables
/// MainStage ships for its plugin windows: `MADSP.framework/Resources/<Plugin>.plist` (PLAN.md §9c phase 5). A concert
/// mapping's parameter number (`parameterIndex_1`) is the table's `parameterID` − 1, which Apple's own concerts
/// confirm. The tables have no ranges or units, so values show as 0–100% and on/off switches as Off/On.
public enum MainStagePluginCatalog {
    /// MADSP's resources inside MainStage (or a test folder).
    nonisolated(unsafe) public static var resources: URL? = {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ConcertSync.mainStageBundleID)
            ?? URL(fileURLWithPath: "/Applications/MainStage.app")
        let url = app.appendingPathComponent("Contents/Frameworks/MADSP.framework/Versions/A/Resources")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: PluginDescription?] = [:]

    /// MainStage's table for a plugin by its name in the concert ("Channel EQ"), or nil if it has none.
    public static func description(named name: String) -> PluginDescription? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        var found: PluginDescription?
        if let dir = resources, !name.contains("/"),
           let data = try? Data(contentsOf: dir.appendingPathComponent(name + ".plist")) {
            found = parse(data, name: name)
        }
        cache[name] = found
        return found
    }

    /// The table's parameters in window order (section by section), each once.
    static func parse(_ data: Data, name: String) -> PluginDescription? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        var parameters: [PluginParameterInfo] = []
        var seen = Set<Int>()

        func add(_ entry: [String: Any], section: String, type: String?) {
            guard let rawName = entry["name"] as? String, let number = entry["parameterID"] as? NSNumber else { return }
            let id = number.intValue
            guard id >= 1, seen.insert(id).inserted else { return }
            let onOff = type == "onOff" || type == "toggle"
            var label = rawName.trimmingCharacters(in: .whitespaces)
            if ["on/off", "on", "off"].contains(label.lowercased()) && !section.isEmpty { label = "\(section) On/Off" }
            parameters.append(PluginParameterInfo(
                id: "\(id - 1)", address: UInt64(id - 1), name: label, unitName: nil, unit: onOff ? 2 : 0, minValue: 0, maxValue: 1,
                defaultValue: 0.5, displayLogarithmic: false, valueStrings: onOff ? ["Off", "On"] : nil,
                steps: onOff ? PluginDescription.onOffSteps : PluginDescription.percentSteps, writable: true, meter: false,
                group: section.isEmpty ? nil : section))
        }

        func walk(_ node: Any, section: String) {
            if let dict = node as? [String: Any] {
                let here = (dict["sectionName"] as? String) ?? section
                if let onOff = dict["onOffParameter"] as? [String: Any] { add(onOff, section: here, type: "onOff") }
                if dict["parameterID"] != nil, dict["groups"] == nil, dict["parameters"] == nil {
                    add(dict, section: here, type: dict["preferredControlType"] as? String)
                }
                for (key, value) in dict where key != "onOffParameter" { walk(value, section: here) }
            } else if let list = node as? [Any] {
                for value in list { walk(value, section: section) }
            }
        }
        // The tables are arrays of sections and groups, so window order survives; a section's switch comes first.
        walk(root, section: "")
        guard !parameters.isEmpty else { return nil }
        return PluginDescription(component: .mainStagePlugin(name), name: name, manufacturerName: "Apple", parameters: parameters)
    }
}
#endif

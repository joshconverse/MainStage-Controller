#if os(macOS)
import Foundation
import FOHCore

/// A manual binding the user made in Setup › Processing. It survives template rebuilds and rediscovery.
/// `parameterID` "" hides the role (marks it not-in-plugin).
public struct BindingOverride: Codable, Hashable, Sendable {
    public var position: Int
    public var parameterID: String

    public init(position: Int, parameterID: String) {
        self.position = position
        self.parameterID = parameterID
    }

    public var hides: Bool { parameterID.isEmpty }
}

/// Files the bridge keeps in `~/Library/Application Support/FOH Bridge/` (or a test directory).
public struct BridgeStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("FOH Bridge", isDirectory: true)
        }
    }

    public var showURL: URL { directory.appendingPathComponent("show.json") }
    public var valuesURL: URL { directory.appendingPathComponent("values.json") }
    public var learnURL: URL { directory.appendingPathComponent("learn.json") }
    public var overridesURL: URL { directory.appendingPathComponent("overrides.json") }
    public var pluginsDirectory: URL { directory.appendingPathComponent("plugins", isDirectory: true) }

    public func pluginURL(_ id: AUComponentID) -> URL {
        pluginsDirectory.appendingPathComponent("\(id.type)-\(id.subtype)-\(id.manufacturer).json")
    }

    func ensureDirectories() {
        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
    }

    private func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Reading a state file: missing, loaded, or present but unreadable. An unreadable file is moved aside
    /// (`show.unreadable-20261025-101500.json`) so nothing overwrites it, and the caller decides how to recover.
    public enum Stored<T> {
        case missing
        case loaded(T)
        case unreadable(keptAs: URL?, reason: String)

        public var value: T? {
            if case .loaded(let v) = self { return v }
            return nil
        }
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> Stored<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .loaded(try JSONDecoder().decode(type, from: Data(contentsOf: url)))
        } catch {
            return .unreadable(keptAs: setAside(url), reason: Self.describe(error))
        }
    }

    private func setAside(_ url: URL) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent
        let dest = url.deletingLastPathComponent().appendingPathComponent("\(name).unreadable-\(f.string(from: Date())).json")
        return (try? FileManager.default.moveItem(at: url, to: dest)) != nil ? dest : nil
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let c): return c.debugDescription
        case DecodingError.keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            return "\(c.debugDescription) at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        default: return error.localizedDescription
        }
    }

    public func readShow() -> Stored<ShowConfig> { read(ShowConfig.self, showURL) }
    public func readValues() -> Stored<[String: Int]> { read([String: Int].self, valuesURL) }
    public func readLearn() -> Stored<LearnState> { read(LearnState.self, learnURL) }
    public func readOverrides() -> Stored<[String: [String: BindingOverride]]> { read([String: [String: BindingOverride]].self, overridesURL) }

    private func save<T: Encodable>(_ value: T, _ url: URL) throws {
        ensureDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(value).write(to: url, options: .atomic)
    }

    public func loadShow() -> ShowConfig? { load(ShowConfig.self, showURL) }
    public func saveShow(_ show: ShowConfig) throws { try save(show, showURL) }

    public func loadValues() -> [String: Int] { load([String: Int].self, valuesURL) ?? [:] }
    public func saveValues(_ values: [String: Int]) throws { try save(values, valuesURL) }

    public func loadLearn() -> LearnState { load(LearnState.self, learnURL) ?? LearnState() }
    public func saveLearn(_ state: LearnState) throws { try save(state, learnURL) }

    /// stripKey → roleID → override.
    public func loadOverrides() -> [String: [String: BindingOverride]] { load([String: [String: BindingOverride]].self, overridesURL) ?? [:] }
    public func saveOverrides(_ overrides: [String: [String: BindingOverride]]) throws { try save(overrides, overridesURL) }

    public func loadPlugin(_ id: AUComponentID) -> PluginDescription? { load(PluginDescription.self, pluginURL(id)) }

    public func savePlugin(_ plugin: PluginDescription) throws {
        ensureDirectories()
        try JSONEncoder().encode(plugin).write(to: pluginURL(plugin.component), options: .atomic)
    }

    // MARK: Backups

    /// One snapshot in `backups/index.json`. `contentHash` covers show, overrides and learn state (not values),
    /// so automatic snapshots of an unchanged show are skipped.
    public struct BackupIndexEntry: Codable, Hashable, Sendable {
        public var info: BackupInfo
        public var contentHash: String

        public init(info: BackupInfo, contentHash: String) {
            self.info = info
            self.contentHash = contentHash
        }
    }

    public var backupsDirectory: URL { directory.appendingPathComponent("backups", isDirectory: true) }
    public var backupIndexURL: URL { backupsDirectory.appendingPathComponent("index.json") }
    public func backupURL(_ id: String) -> URL { backupsDirectory.appendingPathComponent("\(id).json") }

    /// Newest first. Rebuilt from the snapshot files if the index is missing.
    public func loadBackupIndex() -> [BackupIndexEntry] {
        if let index = load([BackupIndexEntry].self, backupIndexURL) { return index }
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }.compactMap { url in
            guard let bundle = load(BackupBundle.self, url) else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            return BackupIndexEntry(info: BackupInfo(id: id, date: bundle.created, reason: bundle.reason, stripCount: bundle.show.strips.count),
                                    contentHash: "")
        }.sorted { $0.info.date > $1.info.date }
    }

    public func saveBackupIndex(_ entries: [BackupIndexEntry]) throws {
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        try save(entries, backupIndexURL)
    }

    public func saveBackup(_ bundle: BackupBundle, id: String) throws {
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        try save(bundle, backupURL(id))
    }

    public func loadBackup(_ id: String) -> BackupBundle? { load(BackupBundle.self, backupURL(id)) }

    public func deleteBackup(_ id: String) { try? FileManager.default.removeItem(at: backupURL(id)) }
}
#endif

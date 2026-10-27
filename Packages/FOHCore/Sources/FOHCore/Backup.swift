import Foundation

/// A manual binding override as the bridge stores it (same JSON shape as FOHMacKit's `BindingOverride`).
public struct BindingOverrideRecord: Codable, Hashable, Sendable {
    public var position: Int
    /// "" = hidden; "@…" = a MainStage channel-strip control.
    public var parameterID: String

    public init(position: Int, parameterID: String) {
        self.position = position
        self.parameterID = parameterID
    }
}

/// Everything needed to put a show back exactly: strips, sends, setlist, calibration, custom templates (all in
/// `show`), manual binding overrides, learn progress and the last known values.
public struct BackupBundle: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var created: Date
    public var reason: String
    public var show: ShowConfig
    /// Strip key → role id → override.
    public var overrides: [String: [String: BindingOverrideRecord]]
    public var learn: LearnState
    public var values: [String: Int]

    public init(created: Date = Date(), reason: String, show: ShowConfig, overrides: [String: [String: BindingOverrideRecord]],
                learn: LearnState, values: [String: Int]) {
        self.version = Self.currentVersion
        self.created = created
        self.reason = reason
        self.show = show
        self.overrides = overrides
        self.learn = learn
        self.values = values
    }

    /// "Church 2026-10-24 2215.fohshow"
    public var suggestedFilename: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "\(show.name) \(f.string(from: created)).fohshow"
    }
}

/// One automatic or manual snapshot kept by the bridge.
public struct BackupInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var date: Date
    public var reason: String
    public var stripCount: Int

    public init(id: String, date: Date, reason: String, stripCount: Int) {
        self.id = id
        self.date = date
        self.reason = reason
        self.stripCount = stripCount
    }
}

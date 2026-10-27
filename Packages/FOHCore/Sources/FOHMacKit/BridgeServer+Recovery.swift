#if os(macOS)
import Foundation
import FOHCore

extension BridgeServer {
    struct LoadedState {
        var show: ShowConfig
        var values: [String: Int]
        var learn: LearnState
        var overrides: [String: [String: BindingOverride]]
        var warnings: [String]
    }

    /// Read the saved state at launch. A file that exists but won't decode (damaged, or from a build that no longer
    /// reads it) is set aside rather than overwritten, and replaced by the newest backup's copy, else a clean
    /// default. Each recovery is reported as a warning for the log and the menu: the show must never silently
    /// turn into the built-in Church default and then be saved over the real one.
    static func loadState(_ store: BridgeStore) -> LoadedState {
        var warnings: [String] = []
        var checkedBackup = false
        var backup: BackupBundle?
        func newestBackup() -> BackupBundle? {
            if !checkedBackup {
                checkedBackup = true
                backup = store.loadBackupIndex().lazy.compactMap { store.loadBackup($0.info.id) }.first
            }
            return backup
        }
        func recover<T>(_ file: String, _ stored: BridgeStore.Stored<T>, _ fallback: T, _ fromBackup: (BackupBundle) -> T) -> T {
            switch stored {
            case .loaded(let value): return value
            case .missing: return fallback
            case .unreadable(let keptAs, let reason):
                let kept = keptAs.map { "kept as \($0.lastPathComponent)" } ?? "left in place"
                guard let b = newestBackup() else {
                    warnings.append("\(file) couldn't be read (\(reason)); \(kept). No backup to restore from, so it starts fresh.")
                    return fallback
                }
                let when = DateFormatter.localizedString(from: b.created, dateStyle: .medium, timeStyle: .short)
                warnings.append("\(file) couldn't be read (\(reason)); \(kept). Restored from the backup of \(when) (\(b.reason)).")
                return fromBackup(b)
            }
        }
        let show = recover("show.json", store.readShow(), .church) { $0.show }
        let values = recover("values.json", store.readValues(), [:]) { $0.values }
        let learn = recover("learn.json", store.readLearn(), LearnState()) { $0.learn }
        let overrides = recover("overrides.json", store.readOverrides(), [:]) { b in
            b.overrides.mapValues { $0.mapValues { BindingOverride(position: $0.position, parameterID: $0.parameterID) } }
        }
        return LoadedState(show: show, values: values, learn: learn, overrides: overrides, warnings: warnings)
    }
}
#endif

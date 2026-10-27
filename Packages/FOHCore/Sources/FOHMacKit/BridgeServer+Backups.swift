#if os(macOS)
import CryptoKit
import Foundation
import FOHCore

// Snapshots of the whole show (strips, sends, setlist, calibration, custom templates, manual bindings, learn
// progress, values). Taken automatically before risky changes and on request; restorable from the iPad or the menu.
extension BridgeServer {
    static let backupLimit = 30

    static let backupIDFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let backupTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// The current state as a bundle. Bindings are left out: they're rebuilt from discovery, templates and overrides.
    public func exportBundle(reason: String = "Export") -> BackupBundle {
        var stripped = show
        stripped.bindings = [:]
        let records = overrides.mapValues { $0.mapValues { BindingOverrideRecord(position: $0.position, parameterID: $0.parameterID) } }
        return BackupBundle(reason: reason, show: stripped, overrides: records, learn: learn, values: values)
    }

    /// Hash of show + overrides + learn (not values or time), so unchanged automatic snapshots are skipped.
    static func contentHash(_ bundle: BackupBundle) -> String {
        struct Content: Encodable { let show: ShowConfig; let overrides: [String: [String: BindingOverrideRecord]]; let learn: LearnState }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(Content(show: bundle.show, overrides: bundle.overrides, learn: bundle.learn))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Save a snapshot. With `dedupe`, nothing is written when the newest snapshot has the same content.
    @discardableResult
    func snapshot(_ reason: String, dedupe: Bool = true) -> BackupInfo? {
        let bundle = exportBundle(reason: reason)
        let hash = Self.contentHash(bundle)
        if dedupe, let latest = backupIndex.first, latest.contentHash == hash { return nil }
        var id = Self.backupIDFormatter.string(from: bundle.created)
        var n = 2
        while backupIndex.contains(where: { $0.info.id == id }) { id = Self.backupIDFormatter.string(from: bundle.created) + "-\(n)"; n += 1 }
        do {
            try options.store.saveBackup(bundle, id: id)
        } catch {
            log("Couldn't save snapshot: \(error)")
            return nil
        }
        let info = BackupInfo(id: id, date: bundle.created, reason: reason, stripCount: bundle.show.strips.count)
        backupIndex.insert(BridgeStore.BackupIndexEntry(info: info, contentHash: hash), at: 0)
        while backupIndex.count > Self.backupLimit {
            options.store.deleteBackup(backupIndex.removeLast().info.id)
        }
        do { try options.store.saveBackupIndex(backupIndex) } catch { log("Couldn't save the snapshot index: \(error)") }
        backups = backupIndex.map(\.info)
        log("Snapshot \(id): \(reason)")
        broadcastBackups()
        return info
    }

    /// `/foh/backup/create`: always writes a snapshot, even if nothing changed.
    @discardableResult
    public func createBackup(reason: String) -> BridgeAck {
        guard let info = snapshot(reason.isEmpty ? "Manual snapshot" : reason, dedupe: false) else {
            return .fail("Couldn't write the snapshot (see the bridge log)")
        }
        return .ok("Snapshot saved at \(Self.backupTimeFormatter.string(from: info.date))")
    }

    /// `/foh/backup/restore`.
    @discardableResult
    public func restoreBackup(id: String) -> BridgeAck {
        guard let bundle = options.store.loadBackup(id) else { return .fail("No snapshot \(id)") }
        return restore(bundle, label: "backup from \(Self.backupTimeFormatter.string(from: bundle.created)) (\(bundle.reason))")
    }

    /// `/foh/backup/import`: a `.fohshow` the user picked.
    @discardableResult
    public func importBackup(_ bundle: BackupBundle) -> BridgeAck {
        guard bundle.version <= BackupBundle.currentVersion else {
            return .fail("That show file is from a newer FOH Remote (format \(bundle.version))")
        }
        return restore(bundle, label: "imported show \"\(bundle.show.name)\" from \(Self.backupTimeFormatter.string(from: bundle.created))")
    }

    /// Adopt a bundle: show, manual bindings, learn state and values. Rediscover changed strips, rebuild every
    /// binding, persist, and broadcast config, learn and values. Nothing is sent to MainStage.
    func restore(_ bundle: BackupBundle, label: String) -> BridgeAck {
        snapshot("Before restoring \(label)")
        let old = show
        var new = bundle.show
        new.bindings = [:]
        var rediscover: Set<String> = []
        for strip in new.strips where old.strip(strip.ref)?.plugins != strip.plugins {
            discovered[strip.ref.key] = nil
            if strip.plugins.contains(where: { $0.component != nil }) { rediscover.insert(strip.ref.key) }
        }
        for strip in old.strips where new.strip(strip.ref) == nil { discovered[strip.ref.key] = nil }
        show = new
        overrides = bundle.overrides.mapValues { $0.mapValues { BindingOverride(position: $0.position, parameterID: $0.parameterID) } }
        values = bundle.values
        valueCount = values.count
        confirmedPaths.removeAll()
        pendingConfirm.removeAll()
        confirmedCount = 0
        for strip in show.strips { rebuildBinding(strip) }
        flushValues()
        commitBindingChange()          // saves overrides + show, broadcasts config
        commitLearn(bundle.learn)      // saves + broadcasts learn
        broadcastAllValues()
        if !rediscover.isEmpty && options.discoverPlugins { runDiscovery(strips: rediscover) }
        log("Restored \(label): \(show.strips.count) strips, \(values.count) values")
        return .ok("Restored \(label)")
    }

    func sendBackups(to conn: BridgeConnection) {
        if let m = try? FOHProtocol.jsonMessage(FOHProtocol.Path.backups, backups) { conn.send(m) }
    }

    func broadcastBackups() {
        guard !connections.isEmpty, let m = try? FOHProtocol.jsonMessage(FOHProtocol.Path.backups, backups) else { return }
        broadcast(.message(m))
    }
}
#endif

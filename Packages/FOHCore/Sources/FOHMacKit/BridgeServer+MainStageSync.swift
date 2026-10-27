#if os(macOS)
import AppKit
import Foundation
import FOHCore

/// What the MainStage sync is doing, for the menu and the iPad (PLAN.md §9c).
public struct MainStageSyncState: Hashable, Sendable {
    public enum Phase: Hashable, Sendable { case idle, waiting, running, failed }

    public var phase: Phase = .idle
    /// Assignments that differ from what the concert last got (rows added or gone since the last sync).
    public var pendingChanges = 0
    public var lastReport: ConcertSync.Report?
    public var lastRun: Date?
    public var lastError: String?

    /// One line: "Up to date", "12 changes waiting — quit MainStage to apply", "Updating MainStage…".
    public var summary: String {
        switch phase {
        case .running: return "Updating MainStage assignments…"
        case .waiting:
            guard pendingChanges > 0 else { return "Update waiting — quit MainStage to apply" }
            return "\(pendingChanges) change\(pendingChanges == 1 ? "" : "s") waiting — quit MainStage to apply"
        case .failed: return "Update failed: \(lastError ?? "unknown error")"
        case .idle:
            if pendingChanges > 0 { return "\(pendingChanges) change\(pendingChanges == 1 ? "" : "s") to apply" }
            guard let lastRun else { return "Not checked against the concert yet" }
            let when = lastRun.formatted(date: .omitted, time: .shortened)
            return "Up to date · \(lastReport.map { $0.changed ? "updated" : "checked" } ?? "updated") \(when)"
        }
    }
}

/// The last concert the bridge synced, and with what (`concert-sync.json`).
struct ConcertSyncRecord: Codable {
    var concertPath: String
    var signature: String
    var keys: [String]
    var date: Date
    /// Newest file date inside the concert right after the sync: a later one means MainStage saved it since.
    var contentDate: Date?
}

extension BridgeStore {
    var concertSyncURL: URL { directory.appendingPathComponent("concert-sync.json") }

    func loadConcertSync() -> ConcertSyncRecord? {
        guard let data = try? Data(contentsOf: concertSyncURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ConcertSyncRecord.self, from: data)
    }

    func saveConcertSync(_ record: ConcertSyncRecord) throws {
        ensureDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(record).write(to: concertSyncURL, options: .atomic)
    }
}

extension BridgeServer {
    /// What MainStage has to contain right now (no values: they don't change the concert).
    public func assignmentExport(values: [String: Int] = [:]) -> AssignmentExport {
        var ports: [String: AssignmentExport.PortIDs] = [:]
        for port in FOHPort.allCases {
            ports[portName(port)] = .init(source: Int(engine.uniqueID(of: port)), destination: Int(engine.uniqueID(of: port, source: false)))
        }
        return AssignmentExport(show, values: values, suffix: options.portNameSuffix, ports: ports)
    }

    public var concertBackupDirectory: URL { ConcertSync.backupDirectory(options.store) }

    var isMainStageRunning: Bool { options.isMainStageRunning() }

    func startMainStageSync() {
        concertSyncRecord = options.store.loadConcertSync()
        if let record = concertSyncRecord {
            mainStageSync.lastRun = record.date
        }
        guard options.autoSyncMainStage else { return checkMainStageSync() }
        mainStageObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == ConcertSync.mainStageBundleID else { return }
            self?.mainStageQuit()
        }
        checkMainStageSync()
    }

    func stopMainStageSync() {
        if let observer = mainStageObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        mainStageObserver = nil
        mainStageSyncWork?.cancel()
    }

    /// After any show change: does the concert still match? If not (and automatic updates are on), update it once
    /// things settle — now if MainStage is closed, otherwise when it quits.
    func checkMainStageSync() {
        guard mainStageSync.phase != .running else { return }
        let export = assignmentExport()
        let record = concertSyncRecord
        let upToDate = record?.signature == export.signature && record?.concertPath == show.concertPath && !mainStageVerifyNext
        if upToDate {
            mainStageSync.pendingChanges = 0
            if mainStageSync.phase == .waiting { mainStageSync.phase = .idle }
            return
        }
        // Rows added or gone since this concert's last update; unknown (0) for a concert the bridge hasn't updated.
        let before = record.flatMap { $0.concertPath == show.concertPath ? Set($0.keys) : nil }
        mainStageSync.pendingChanges = before.map { $0.symmetricDifference(export.concertKeys).count } ?? 0
        guard options.autoSyncMainStage, let path = show.concertPath, FileManager.default.fileExists(atPath: path) else { return }
        mainStageSyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoSyncMainStage() }
        mainStageSyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + options.mainStageSyncDelay, execute: work)
    }

    private func autoSyncMainStage() {
        // Discovery rebuilds bindings and plugin controls; wait for it (it calls back here when done).
        guard !isDiscovering, discoveryFinishedOnce || !options.discoverPlugins else { return }
        updateMainStage(trigger: "automatic")
    }

    /// MainStage quit. If it saved the concert since our last update, re-read it (its plugin changes flow into the
    /// show) and check the concert once more; otherwise apply what was waiting.
    func mainStageQuit() {
        guard let path = show.concertPath else { return }
        let saved = ConcertSync.contentDate(of: URL(fileURLWithPath: path))
        if let saved, saved > (concertSyncRecord?.contentDate ?? .distantPast) {
            log("MainStage quit after saving \(URL(fileURLWithPath: path).lastPathComponent): re-reading it")
            mainStageVerifyNext = true
            mergeConcertInBackground(path: path) { [weak self] ack in
                self?.log(ack.message)
                // Hand-made Assign & Maps for pending learns are in the concert now (phase 5).
                self?.checkPluginLearns { _ in self?.checkMainStageSync() }
            }
        } else if mainStageSync.phase == .waiting {
            log("MainStage quit: applying the waiting assignment changes")
            checkMainStageSync()
        }
    }

    /// Bring the concert in line with the show: `/foh/mainstage/update`, the menu, and the automatic trigger.
    /// Never while MainStage is running.
    public func updateMainStage(trigger: String, completion: ((BridgeAck) -> Void)? = nil) {
        mainStageSyncWork?.cancel()
        if let completion { mainStageSyncWaiters.append(completion) }
        guard mainStageSync.phase != .running else { return }
        func finish(_ ack: BridgeAck) {
            let waiters = mainStageSyncWaiters
            mainStageSyncWaiters = []
            waiters.forEach { $0(ack) }
            refreshStatus(broadcast: true)
        }
        guard let path = show.concertPath, FileManager.default.fileExists(atPath: path) else {
            mainStageSync.phase = .failed
            mainStageSync.lastError = show.concertPath == nil ? "no concert imported yet" : "\(show.concertPath!) is missing; import the concert again"
            log("MainStage update (\(trigger)): \(mainStageSync.lastError!)")
            return finish(.fail("MainStage update: \(mainStageSync.lastError!)"))
        }
        if isMainStageRunning {
            mainStageSync.phase = .waiting
            log("MainStage update (\(trigger)): \(mainStageSync.summary)")
            return finish(.fail(mainStageSync.summary))
        }
        guard let writer = options.concertWriter else {
            mainStageSync.phase = .failed
            mainStageSync.lastError = ConcertSync.Failure.noWriter.description
            return finish(.fail("MainStage update: \(mainStageSync.lastError!)"))
        }
        let export = assignmentExport(values: values)
        let concert = URL(fileURLWithPath: path)
        let backups = concertBackupDirectory
        mainStageSync.phase = .running
        refreshStatus(broadcast: true)
        log("Updating MainStage assignments in \(concert.lastPathComponent) (\(trigger)): \(export.rowCount) wanted")
        Self.concertQueue.async { [weak self] in
            let result = Result { try ConcertSync.run(export, concert: concert, backups: backups, writer: writer) { line in
                DispatchQueue.main.async { self?.log(line) }
            } }
            let contentDate = ConcertSync.contentDate(of: concert)
            DispatchQueue.main.async {
                guard let self else { return }
                self.mainStageSync.lastRun = Date()
                switch result {
                case .success(let report):
                    let record = ConcertSyncRecord(concertPath: path, signature: export.signature, keys: export.concertKeys.sorted(),
                                                   date: Date(), contentDate: contentDate)
                    do { try self.options.store.saveConcertSync(record) } catch { self.log("Couldn't save the sync record: \(error)") }
                    self.concertSyncRecord = record
                    self.mainStageVerifyNext = false
                    self.mainStageSync.phase = .idle
                    self.mainStageSync.lastReport = report
                    self.mainStageSync.lastError = nil
                    self.mainStageSync.pendingChanges = 0
                    self.log("MainStage assignments: \(report.summary)" + (report.backup.map { " · previous version kept in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""))
                    let reasons = Dictionary(grouping: report.skipped, by: \.reason).sorted { $0.value.count > $1.value.count }
                    for (reason, rows) in reasons.prefix(4) { self.log("  skipped \(rows.count): \(reason)") }
                    finish(.ok("MainStage assignments: \(report.summary)"))
                case .failure(let error):
                    self.mainStageSync.phase = .failed
                    self.mainStageSync.lastError = "\(error)"
                    self.log("⚠︎ MainStage update failed: \(error)")
                    finish(.fail("MainStage update failed: \(error)"))
                }
                // The show may have changed while the writer ran.
                if case .success = result { self.checkMainStageSync() }
            }
        }
    }
}

extension ConcertSync {
    /// The newest modification date of any file inside a concert (MainStage rewrites files inside the bundle).
    public static func contentDate(of concert: URL) -> Date? {
        guard let files = FileManager.default.enumerator(at: concert, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: Date?
        for case let url as URL in files {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date > (newest ?? .distantPast) {
                newest = date
            }
        }
        return newest
    }
}
#endif

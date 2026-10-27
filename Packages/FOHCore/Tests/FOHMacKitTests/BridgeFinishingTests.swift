import XCTest
import FOHCore
@testable import FOHMacKit

/// Backups, custom templates, acks and confirmed values.
final class BridgeFinishingTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("foh-finishing-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeServer(port: UInt16 = FOHProtocol.defaultPort, suffix: String = " (unit)") -> BridgeServer {
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory)
        options.discoverPlugins = false
        options.enableMeters = false
        options.advertiseBonjour = false
        options.port = port
        options.portNameSuffix = suffix
        let server = BridgeServer(options: options)
        server.discovered["in/1"] = [3: BridgeServerTests.ssl]
        server.discovered["in/2"] = [1: BridgeServerTests.ssl]
        for key in ["in/1", "in/2"] { server.rebuildBinding(server.show.strip(StripRef(key: key)!)!) }
        return server
    }

    let lmfGain = Role.band(2, "gain")!

    func testBackupCreateChangeRestore() throws {
        let server = makeServer()
        server.setBinding(strip: "in/1", roleID: lmfGain.id, position: 3, parameterID: "23")   // HMF Gain
        server.learnBeginIfNeeded()
        server.learnNext()
        let created = server.createBackup(reason: "Before rehearsal")
        XCTAssertTrue(created.ok, created.message)
        let id = try XCTUnwrap(server.backups.first?.id)

        var edited = server.show
        edited.strips[0].name = "Changed"
        server.applyConfig(edited)
        server.resetBindings(strip: "in/1")
        server.learnClear()
        XCTAssertEqual(server.show.strip(.input(1))?.name, "Changed")
        XCTAssertEqual(server.show.binding(.input(1))[lmfGain]?.parameterName, "LMF Gain")

        let restored = server.restoreBackup(id: id)
        XCTAssertTrue(restored.ok, restored.message)
        XCTAssertEqual(server.show.strip(.input(1))?.name, "Lead vox")
        XCTAssertEqual(server.show.binding(.input(1))[lmfGain]?.parameterName, "HMF Gain")   // manual override back
        XCTAssertEqual(server.show.binding(.input(1))[lmfGain]?.origin, .manual)
        XCTAssertTrue(server.learn.learned.contains("in/1|mix.mute"))
        XCTAssertEqual(server.backups.first?.reason.hasPrefix("Before restoring"), true)     // safety snapshot first

        // Persisted: index, files, and the restored overrides.
        let store = BridgeStore(directory: directory)
        XCTAssertEqual(store.loadBackupIndex().map(\.info.id), server.backups.map(\.id))
        XCTAssertNotNil(store.loadBackup(id))
        XCTAssertEqual(store.loadOverrides()["in/1"]?[lmfGain.id]?.parameterID, "23")
    }

    func testAutomaticSnapshotsDedupeAndPrune() {
        let server = makeServer()
        server.snapshot("A")
        server.snapshot("B")                       // same content → skipped
        XCTAssertEqual(server.backups.count, 1)
        for i in 0..<(BridgeServer.backupLimit + 3) { server.createBackup(reason: "manual \(i)") }
        XCTAssertEqual(server.backups.count, BridgeServer.backupLimit)
        XCTAssertEqual(server.backups.first?.reason, "manual \(BridgeServer.backupLimit + 2)")
    }

    func testImportRejectsNewerFormatAndExportRoundTrips() throws {
        let server = makeServer()
        var bundle = server.exportBundle()
        XCTAssertTrue(bundle.show.bindings.isEmpty)                               // bindings are rebuilt, not stored
        XCTAssertEqual(try JSONDecoder().decode(BackupBundle.self, from: JSONEncoder().encode(bundle)), bundle)
        bundle.version = BackupBundle.currentVersion + 1
        XCTAssertFalse(server.importBackup(bundle).ok)
    }

    func testTemplateFromLeadVoxAppliesToGuitar() throws {
        let server = makeServer()
        server.setBinding(strip: "in/1", roleID: lmfGain.id, position: 3, parameterID: "23")
        let saved = server.saveTemplate(strip: "in/1", name: "Vocal SSL", use: .processing, position: 3)
        XCTAssertTrue(saved.ok, saved.message)
        XCTAssertTrue(saved.message.contains("2 strips"), saved.message)
        let template = try XCTUnwrap(server.show.customTemplates.first)

        // Guitar has no manual overrides; the template moves its LMF gain onto HMF Gain at Guitar's plugin 1.
        XCTAssertEqual(server.show.binding(.input(2))[lmfGain]?.parameterName, "HMF Gain")
        XCTAssertEqual(server.show.binding(.input(2))[lmfGain]?.pluginPosition, 1)
        server.rebuildBinding(server.show.strip(.input(2))!)                     // survives a rebuild/rediscovery
        XCTAssertEqual(server.show.binding(.input(2))[lmfGain]?.parameterName, "HMF Gain")

        // config/set from a client that doesn't know about templates keeps them, and keeps its strip order.
        var edited = server.show
        edited.customTemplates = []
        edited.stripOrder = ["in/2", "in/1"]
        server.applyConfig(edited)
        XCTAssertEqual(server.show.customTemplates.map(\.id), [template.id])
        XCTAssertEqual(server.show.stripOrder, ["in/2", "in/1"])

        // Same name replaces; delete puts Guitar back on the built-in template.
        XCTAssertTrue(server.saveTemplate(strip: "in/1", name: "Vocal SSL", use: .processing, position: 3).ok)
        XCTAssertEqual(server.show.customTemplates.count, 1)
        let deleted = server.deleteTemplate(id: server.show.customTemplates[0].id)
        XCTAssertTrue(deleted.ok)
        XCTAssertEqual(server.show.binding(.input(2))[lmfGain]?.parameterName, "LMF Gain")
        XCTAssertFalse(server.saveTemplate(strip: "in/1", name: " ", use: .processing, position: 3).ok)
    }

    func testConfirmedValues() throws {
        let server = makeServer()
        let path = FOHProtocol.valuePath(.input(1), .fader)
        server.values[path] = 90
        XCTAssertTrue(server.confirm(path))
        XCTAssertFalse(server.confirm(path))

        func flag(_ packets: [OSCPacket]) -> OSCArgument? {
            packets.flatMap(\.messages).first { $0.address == path }.flatMap { $0.arguments.count > 1 ? $0.arguments[1] : nil }
        }
        XCTAssertEqual(flag(server.valueBundles()), .int(1))

        // A client change MainStage never echoes stops being confirmed.
        server.pendingConfirm[path] = ProcessInfo.processInfo.systemUptime - 2
        server.expirePendingConfirmations()
        XCTAssertFalse(server.confirmedPaths.contains(path))
        XCTAssertEqual(server.confirmedCount, 0)
        XCTAssertEqual(flag(server.valueBundles()), .int(0))
    }

    func testAckArrivesForPullOverTCP() throws {
        let server = makeServer(port: 0, suffix: " (ack test)")
        try server.start()
        defer { server.stop() }
        let deadline = Date().addingTimeInterval(5)
        while server.listeningPort == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let port = try XCTUnwrap(server.listeningPort)

        let client = BridgeOSCClient(host: "127.0.0.1", port: port)
        var acks: [OSCMessage] = []
        var backupsReply: [BackupInfo]?
        let pulled = expectation(description: "pull ack")
        let listed = expectation(description: "backups")
        client.onMessage = { m in
            if m.address == FOHProtocol.Path.ack {
                acks.append(m)
                if m.arguments.first?.stringValue == FOHProtocol.Path.pull { pulled.fulfill() }
            }
            if m.address == FOHProtocol.Path.backups, backupsReply == nil {
                backupsReply = try? FOHProtocol.decodeJSON([BackupInfo].self, from: m)
                listed.fulfill()
            }
        }
        client.start()
        defer { client.cancel() }
        client.send(OSCMessage(FOHProtocol.Path.hello, [.string("unit test"), .int(FOHProtocol.version)]))
        client.send(OSCMessage(FOHProtocol.Path.pull))
        client.send(OSCMessage(FOHProtocol.Path.backupList))
        wait(for: [pulled, listed], timeout: 5)

        let ack = try XCTUnwrap(acks.first { $0.arguments.first?.stringValue == FOHProtocol.Path.pull })
        XCTAssertEqual(ack.arguments[1], .int(1))
        XCTAssertTrue(ack.arguments[2].stringValue?.contains("Song One") ?? false)
        XCTAssertEqual(backupsReply, [])
    }
}

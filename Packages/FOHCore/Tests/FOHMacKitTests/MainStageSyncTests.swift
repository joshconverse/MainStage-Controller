import XCTest
import FOHCore
@testable import FOHMacKit

/// The MainStage sync (PLAN.md §9c): the export's signature, the bundled writer run in place, and the bridge waiting
/// for MainStage to quit. Runs the real concert writer (/usr/bin/python3) on a copy of a MainStage-saved concert.
final class MainStageSyncTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let writer = repo.appendingPathComponent("Tools/concert-format/concert_write.py")
    static let fixture = repo.appendingPathComponent("Tools/concert-format/fixtures/mainstage-saved.concert")

    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("foh-mainstage-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ConcertSync.python.path), "needs /usr/bin/python3")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func copyOfFixture() throws -> URL {
        let concert = directory.appendingPathComponent("Live.concert")
        try FileManager.default.copyItem(at: Self.fixture, to: concert)
        return concert
    }

    func waitUntil(_ timeout: TimeInterval = 30, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Two Pro-Q 3 controls on Lead vox (concert level) on a plugin port.
    func pluginExport(_ ids: [String]) throws -> AssignmentExport {
        let rows = ids.enumerated().map { i, id in
            #"{"role":"plugin.2.\#(id)","label":"\#(id)","port":"FOH Plugins 1","channel":1,"cc":\#(i + 1),"target":"plugin","#
            + #""pluginPosition":2,"pluginName":"Pro-Q 3","parameterID":"\#(id)","parameterName":"\#(id)","kind":"continuous","invert":false}"#
        }
        let json = #"{"show":"test","ports":{"FOH Plugins 1":{"source":-2051801880,"destination":-2051801881}},"strips":[{"key":"in/1","#
            + #""name":"Lead vox","mainStage":{"level":"concert","stripName":"Lead vox"},"roles":[\#(rows.joined(separator: ","))]}]}"#
        return try JSONDecoder().decode(AssignmentExport.self, from: Data(json.utf8))
    }

    func testSignatureIgnoresValuesAndFollowsPluginControls() throws {
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory)
        options.discoverPlugins = false
        options.enableMeters = false
        let server = BridgeServer(options: options)
        server.discovered["fx/1"] = [1: PluginControlBridgeTests.reverb]
        server.rebuildBinding(server.show.strip(.fx(1))!)
        let before = server.assignmentExport()
        let path = try XCTUnwrap(server.show.activePluginControls.first?.path)
        XCTAssertEqual(server.assignmentExport(values: [path: 99]).signature, before.signature, "values don't change the concert")
        server.discovered["fx/1"] = [:]
        server.rebuildBinding(server.show.strip(.fx(1))!)
        let after = server.assignmentExport()
        XCTAssertNotEqual(after.signature, before.signature)
        XCTAssertEqual(before.concertKeys.subtracting(after.concertKeys).count, 2, "the reverb's two controls")
    }

    func testRunWritesInPlaceWithABackup() throws {
        let concert = try copyOfFixture()
        let backups = directory.appendingPathComponent("backups")
        let export = try pluginExport(["315", "316"])
        let report = try ConcertSync.run(export, concert: concert, backups: backups, writer: Self.writer)
        XCTAssertTrue(report.changed)
        XCTAssertEqual(report.written, 2)
        let backup = try XCTUnwrap(report.backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup))
        XCTAssertEqual(URL(fileURLWithPath: backup).deletingLastPathComponent().standardizedFileURL, backups.standardizedFileURL)

        let again = try ConcertSync.run(export, concert: concert, backups: backups, writer: Self.writer)
        XCTAssertFalse(again.changed)
        XCTAssertNil(again.backup)
        XCTAssertEqual(again.kept, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1, "no change, no new backup")

        let fewer = try ConcertSync.run(try pluginExport(["315"]), concert: concert, backups: backups, writer: Self.writer)
        XCTAssertEqual([fewer.changed ? 1 : 0, fewer.removed, fewer.kept], [1, 1, 1])
        XCTAssertTrue(fewer.summary.contains("1 removed"))
    }

    func testRunReportsWriterFailures() throws {
        let missing = directory.appendingPathComponent("Missing.concert")
        XCTAssertThrowsError(try ConcertSync.run(try pluginExport(["315"]), concert: missing, backups: directory, writer: Self.writer)) { error in
            guard case ConcertSync.Failure.failed = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ConcertSync.run(try pluginExport(["315"]), concert: missing, backups: directory,
                                                 writer: directory.appendingPathComponent("nope.py"))) { error in
            guard case ConcertSync.Failure.noWriter = error else { return XCTFail("\(error)") }
        }
    }

    func testWaitsForMainStageToQuitThenUpdates() throws {
        let concert = try copyOfFixture()
        var mainStageRunning = true
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory.appendingPathComponent("store"))
        options.discoverPlugins = false
        options.enableMeters = false
        options.autoSyncMainStage = true
        options.concertWriter = Self.writer
        options.mainStageSyncDelay = 0.01
        options.isMainStageRunning = { mainStageRunning }
        let server = BridgeServer(options: options)
        defer { server.stopMainStageSync() }
        server.show.concertPath = concert.path
        server.startMainStageSync()

        waitUntil(5) { server.mainStageSync.phase == .waiting }
        XCTAssertEqual(server.mainStageSync.phase, .waiting)
        XCTAssertTrue(server.mainStageSync.summary.hasSuffix("quit MainStage to apply"), server.mainStageSync.summary)
        XCTAssertEqual(server.mainStageSync.summary, "Update waiting — quit MainStage to apply", "never updated: no count to give")
        XCTAssertNil(server.mainStageSync.lastReport, "nothing written while MainStage runs")

        // MainStage quits; it had saved the concert, so the bridge re-reads it first, then updates.
        mainStageRunning = false
        server.mainStageQuit()
        waitUntil { server.mainStageSync.lastReport != nil && server.mainStageSync.phase == .idle }
        XCTAssertEqual(server.mainStageSync.phase, .idle, server.mainStageSync.lastError ?? "")
        XCTAssertEqual(server.mainStageSync.pendingChanges, 0)
        XCTAssertTrue(server.mainStageSync.summary.hasPrefix("Up to date"), server.mainStageSync.summary)
        let record = try XCTUnwrap(options.store.loadConcertSync())
        XCTAssertEqual(record.concertPath, concert.path)

        // Nothing changed since: nothing to do, and MainStage quitting again without saving does nothing.
        server.checkMainStageSync()
        XCTAssertEqual(server.mainStageSync.pendingChanges, 0)
        let runs = server.mainStageSync.lastRun
        server.mainStageQuit()
        waitUntil(0.5) { false }
        XCTAssertEqual(server.mainStageSync.lastRun, runs)
    }

    // MARK: MainStage's own plugins (phase 5)

    func testListMappingsReadsTheSavedConcert() throws {
        let mappings = try ConcertSync.listMappings(concert: Self.fixture, writer: Self.writer)
        XCTAssertEqual(mappings.count, 93)
        let mute = try XCTUnwrap(mappings.first { $0.identity == "84AD0D07-8D03-41EA-A01C-1FCD6A213EA0" })
        XCTAssertEqual(mute.kind, "WsActionParameterMapping")
        XCTAssertEqual(mute.parameter, 8)
        let lmf = try XCTUnwrap(mappings.first { $0.identity == "C0E63B33-4183-4A99-8CBE-3140784EFAF2" })
        XCTAssertEqual([lmf.parameter, lmf.position, lmf.channel, lmf.cc], [20, 3, 1, 26])
        XCTAssertEqual(lmf.strip, "Lead vox")
    }

    /// MainStage's parameter tables for its own plugins (phase 5): names by `parameterIndex_1`, on/off as switches.
    func testMainStagePluginCatalog() throws {
        try XCTSkipIf(MainStagePluginCatalog.resources == nil, "needs MainStage installed")
        let eq = try XCTUnwrap(MainStagePluginCatalog.description(named: "Channel EQ"))
        XCTAssertEqual(eq.component, .mainStagePlugin("Channel EQ"))
        XCTAssertGreaterThan(eq.parameters.count, 40)
        XCTAssertEqual(eq.parameter(id: "0")?.name, "Low Cut On/Off", "table ID 1 is mapping parameter 0")
        XCTAssertEqual(eq.parameter(id: "0")?.kind, .toggle)
        XCTAssertEqual(eq.parameter(id: "10")?.name, "Peak 1 Gain")
        XCTAssertEqual(eq.parameter(id: "10")?.display(127), "100%")
        XCTAssertEqual(eq.parameter(id: "1")?.group, "Low Cut")
        XCTAssertEqual(Set(eq.parameters.map(\.id)).count, eq.parameters.count, "each once")
        XCTAssertNotNil(MainStagePluginCatalog.description(named: "Compressor"))
        XCTAssertNil(MainStagePluginCatalog.description(named: "No Such Plugin"))
        XCTAssertNil(MainStagePluginCatalog.description(named: "../Info"))

        // A strip with Channel EQ gets plugin controls from the table without discovery, and none are seeded.
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory.appendingPathComponent("store"))
        options.discoverPlugins = false
        options.enableMeters = false
        options.mainStageCatalog = MainStagePluginCatalog.description(named:)
        let server = BridgeServer(options: options)
        let main = try XCTUnwrap(server.show.strip(.output(1)))
        server.rebuildBinding(main)
        let controls = server.show.activePluginControls.filter { $0.strip == .output(1) && $0.position == 3 }
        XCTAssertEqual(controls.count, PluginControlSets.genericCount)
        XCTAssertTrue(controls.allSatisfy { $0.component == .mainStagePlugin("Channel EQ") })
        XCTAssertTrue(controls.allSatisfy { server.value(at: $0.path) == nil }, "values come only from MainStage")
        let rows = server.assignmentExport().strips.first { $0.key == "out/1" }?.roles.filter { $0.pluginPosition == 3 && $0.role.hasPrefix("plugin.") }
        XCTAssertEqual(rows?.count, PluginControlSets.genericCount)
        XCTAssertTrue(server.changePluginControl(strip: "out/1", position: 3, parameterID: eq.parameters.last!.id, add: true).ok, "Add control works too")
    }

    func testLearningAMainStagePluginParameter() throws {
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory.appendingPathComponent("store"))
        options.discoverPlugins = false
        options.enableMeters = false
        let server = BridgeServer(options: options)
        // Channel EQ on Main (insert 3) and on Output 2, as one plugin type.
        let out2 = try XCTUnwrap(server.show.strips.firstIndex { $0.ref == .output(3) })
        server.show.strips[out2].plugins = [PluginRef(position: 1, name: "Channel EQ")]
        let main = try XCTUnwrap(server.show.strip(.output(1)))
        XCTAssertEqual(main.plugin(at: 3)?.name, "Channel EQ")

        XCTAssertFalse(server.startPluginLearn(strip: "in/1", position: 2, name: "x").ok, "Pro-Q is an Audio Unit: Add control")
        XCTAssertFalse(server.startPluginLearn(strip: "out/1", position: 3, name: "  ").ok, "needs a name")
        XCTAssertTrue(server.startPluginLearn(strip: "out/1", position: 3, name: "Low Cut Freq").ok)
        let learn = try XCTUnwrap(server.show.pendingLearns.first)
        XCTAssertTrue(server.sendPluginLearn(learn.id).ok)

        func mapping(position: Int, parameter: Int) -> ConcertSync.Mapping {
            ConcertSync.Mapping(source: Int(server.engine.uniqueID(of: learn.address.port)), channel: Int(learn.address.channel),
                                cc: Int(learn.address.cc), identity: "HAND", autogenerated: true, kind: "MAPlugInParameterMapping",
                                parameter: parameter, position: position, strip: "Main", level: "concert", patch: nil)
        }
        // Mapped to the wrong insert: reported, still waiting.
        XCTAssertFalse(server.resolveLearns([mapping(position: 4, parameter: 999)]).ok)
        XCTAssertEqual(server.show.pendingLearns.count, 1)
        // Not mapped yet: still waiting, no error.
        XCTAssertTrue(server.resolveLearns([]).ok)

        let done = server.resolveLearns([mapping(position: 3, parameter: 999)])
        // 999 is a parameter no table lists, the case learning is for.
        XCTAssertTrue(done.ok, done.message)
        XCTAssertTrue(server.show.pendingLearns.isEmpty)
        XCTAssertEqual(server.show.learnedParameters["Channel EQ"], [LearnedParameter(index: 999, name: "Low Cut Freq")])
        let onMain = try XCTUnwrap(server.show.activePluginControls.first { $0.strip == .output(1) && $0.position == 3 && $0.parameterID == "999" })
        XCTAssertEqual(onMain.address, learn.address, "the hand-made mapping is the control's")
        XCTAssertEqual(onMain.parameterID, "999")
        XCTAssertTrue(server.show.activePluginControls.contains { $0.strip == .output(3) && $0.position == 1 && $0.parameterID == "999" },
                      "every Channel EQ gets it")
        // The writer's rows for it: a plugin parameter on insert 3, like any Audio Unit's.
        let rows = server.assignmentExport().strips.first { $0.key == "out/1" }?.roles.filter { $0.role == "plugin.3.999" } ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.pluginPosition, 3)

        XCTAssertTrue(server.forgetLearnedParameter("Channel EQ", index: 999).ok)
        XCTAssertFalse(server.show.activePluginControls.contains { $0.parameterID == "999" && $0.component.isMainStagePlugin })
    }

    /// MainStage's Record button: a Master-strip role, exported for the writer as an action, never pushed.
    func testRecordOnTheMasterStrip() throws {
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory.appendingPathComponent("store"))
        options.discoverPlugins = false
        options.enableMeters = false
        let server = BridgeServer(options: options)
        let binding = try XCTUnwrap(server.show.binding(.master)[.record])
        XCTAssertEqual(binding.parameterID, "@record")
        XCTAssertEqual([binding.display(0), binding.display(127)], ["Stopped", "Recording"])
        XCTAssertNil(server.show.binding(.output(1))[.record], "Master only")
        XCTAssertEqual(AddressMap.address(.master, .record).port, .global)
        XCTAssertEqual(AddressMap.address(.master, .record).cc, 4)

        let row = try XCTUnwrap(server.assignmentExport().strips.first { $0.key == "master/1" }?.roles.first { $0.role == "transport.record" })
        XCTAssertEqual(row.target, "record")

        let path = FOHProtocol.valuePath(.master, .record)
        server.values[path] = 0
        _ = server.pushAllToMainStage()
        XCTAssertNil(server.pendingConfirm[path], "Push all never sends Record (it could stop a recording)")
    }

    func testManualUpdateRefusesWhileMainStageRuns() throws {
        let concert = try copyOfFixture()
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory.appendingPathComponent("store"))
        options.discoverPlugins = false
        options.enableMeters = false
        options.concertWriter = Self.writer
        options.isMainStageRunning = { true }
        let server = BridgeServer(options: options)
        server.show.concertPath = concert.path
        var ack: BridgeAck?
        server.updateMainStage(trigger: "test") { ack = $0 }
        XCTAssertEqual(ack?.ok, false)
        XCTAssertTrue(ack?.message.contains("quit MainStage") ?? false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }, [])

        server.show.concertPath = directory.appendingPathComponent("Gone.concert").path
        server.updateMainStage(trigger: "test") { ack = $0 }
        XCTAssertEqual(server.mainStageSync.phase, .failed)
        XCTAssertTrue(ack?.message.contains("import the concert again") ?? false)
    }
}

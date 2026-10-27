import XCTest
import FOHCore
@testable import FOHMacKit

/// An unreadable state file must never silently become the built-in default and then be saved over the real one.
final class StateRecoveryTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("foh-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeServer() -> BridgeServer {
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory)
        options.discoverPlugins = false
        options.enableMeters = false
        return BridgeServer(options: options)
    }

    private var unreadableFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.contains(".unreadable-") }
    }

    func testUnreadableShowIsSetAsideAndRestoredFromTheNewestBackup() throws {
        let store = BridgeStore(directory: directory)
        var saved = ShowConfig.church
        saved.name = "Sunday"
        try store.saveBackup(BackupBundle(reason: "before import", show: saved, overrides: [:], learn: LearnState(),
                                          values: ["/foh/in/1/mix/fader": 77]), id: "b1")
        try store.saveBackupIndex([.init(info: BackupInfo(id: "b1", date: Date(), reason: "before import", stripCount: saved.strips.count),
                                         contentHash: "")])
        try Data("{ not json".utf8).write(to: store.showURL)
        try Data("[1,2".utf8).write(to: store.valuesURL)

        let server = makeServer()
        XCTAssertEqual(server.show.name, "Sunday")
        XCTAssertEqual(server.value(at: "/foh/in/1/mix/fader"), 77)
        XCTAssertEqual(server.startupWarnings.count, 2)
        XCTAssertTrue(server.startupWarnings[0].contains("show.json couldn't be read"), server.startupWarnings[0])
        XCTAssertEqual(unreadableFiles.count, 2, "the damaged files are kept, not overwritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.showURL.path))
    }

    func testUnreadableShowWithoutABackupStartsFreshAndSaysSo() throws {
        let store = BridgeStore(directory: directory)
        try Data(#"{"name":"Sunday","strips":[{"ref":{"kind":"in","slot":999}}]}"#.utf8).write(to: store.showURL)
        let server = makeServer()
        XCTAssertEqual(server.show.name, ShowConfig.church.name)
        XCTAssertEqual(server.startupWarnings.count, 1)
        XCTAssertTrue(server.startupWarnings[0].contains("No backup"), server.startupWarnings[0])
        XCTAssertEqual(unreadableFiles.count, 1)
    }

    func testMissingFilesAreNotWarnings() {
        let server = makeServer()
        XCTAssertEqual(server.show.name, ShowConfig.church.name)
        XCTAssertTrue(server.startupWarnings.isEmpty)
    }
}

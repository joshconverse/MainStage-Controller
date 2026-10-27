import XCTest
import FOHCore
@testable import FOHMacKit

/// Plugin controls in the bridge (PLAN.md §9c): activation, defaults, MainStage feedback, echoes, sync. No network,
/// and the MIDI engine isn't started.
final class PluginControlBridgeTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("foh-plugin-controls-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A small plugin no core set knows: its first real controls are used, the meter isn't.
    static let reverb = PluginDescription(component: AUComponentID(type: "aufx", subtype: "TVRB", manufacturer: "Test"),
                                          name: "Test Verb", manufacturerName: "Test", parameters: [
        PluginParameterInfo(id: "1", address: 1, name: "Size", unitName: nil, unit: 0, minValue: 0, maxValue: 100, defaultValue: 50,
                            displayLogarithmic: false, valueStrings: nil, steps: []),
        PluginParameterInfo(id: "2", address: 2, name: "Mix", unitName: "%", unit: 0, minValue: 0, maxValue: 100, defaultValue: 25,
                            displayLogarithmic: false, valueStrings: nil, steps: []),
        PluginParameterInfo(id: "3", address: 3, name: "Output VU", unitName: nil, unit: 0, minValue: 0, maxValue: 1, defaultValue: 0,
                            displayLogarithmic: false, valueStrings: nil, steps: [], writable: false, meter: true),
    ])

    func makeServer() -> BridgeServer {
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory)
        options.discoverPlugins = false
        options.enableMeters = false
        options.portNameSuffix = " (unit)"
        let server = BridgeServer(options: options)
        server.discovered["fx/1"] = [1: Self.reverb]
        server.rebuildBinding(server.show.strip(.fx(1))!)
        return server
    }

    func testControlsActivateWithDefaults() throws {
        let server = makeServer()
        let controls = server.show.activePluginControls
        XCTAssertEqual(controls.map(\.name), ["Size", "Mix"], "the meter isn't a control")
        XCTAssertEqual(server.value(at: controls[0].path), 64, "Size defaults to 50 of 0…100 → MIDI 64")
        XCTAssertEqual(server.value(at: controls[1].path), 32)
        XCTAssertTrue(controls.allSatisfy { $0.address.port == .plugins1 })
    }

    func testMainStageFeedbackAndEchoes() throws {
        let server = makeServer()
        let mix = try XCTUnwrap(server.show.activePluginControls.first { $0.name == "Mix" })
        func feedback(_ value: UInt8) {
            server.handlePluginMIDI(MIDIEngine.Message(port: mix.address.port, status: 0xB0 + mix.address.channel - 1,
                                                       data1: mix.address.cc, data2: value))
        }
        // MainStage moved it (e.g. the mouse on the plugin): the bridge takes the value and calls it confirmed.
        feedback(100)
        XCTAssertEqual(server.value(at: mix.path), 100)
        XCTAssertTrue(server.confirmedPaths.contains(mix.path))

        // The bridge sent 40; MainStage's echo of 40 confirms it without changing anything.
        server.unconfirm(mix.path, broadcastChange: false)
        server.values[mix.path] = 40
        server.sendWire(mix.address, 40)
        feedback(40)
        XCTAssertEqual(server.value(at: mix.path), 40)
        XCTAssertTrue(server.confirmedPaths.contains(mix.path))

        // Feedback on a plugin-port address nobody owns is ignored.
        server.handlePluginMIDI(MIDIEngine.Message(port: .plugins2, status: 0xBF, data1: 119, data2: 1))
        XCTAssertNil(server.values.keys.first { $0.contains("plugins2") })
    }

    func testSyncAndPushIncludePluginControls() throws {
        let server = makeServer()
        let paths = Set(server.show.activePluginControls.map(\.path))
        let sent = server.valueBundles().flatMap { packet -> [String] in
            guard case .bundle(_, let elements) = packet else { return [] }
            return elements.compactMap { if case .message(let m) = $0 { return m.address }; return nil }
        }
        XCTAssertTrue(paths.isSubset(of: Set(sent)))
        let ack = server.pushAllToMainStage()
        XCTAssertTrue(ack.ok)
        for path in paths { XCTAssertNotNil(server.pendingConfirm[path], path) }
    }

    /// Add control / remove control from the iPad (phase 4): the type's set changes on every strip with that plugin.
    func testAddAndRemoveControlFromClient() throws {
        let server = makeServer()
        let meter = server.changePluginControl(strip: "fx/1", position: 1, parameterID: "3", add: true)
        XCTAssertFalse(meter.ok, "a meter can't be a control")
        XCTAssertFalse(server.changePluginControl(strip: "fx/1", position: 9, parameterID: "1", add: true).ok, "no plugin there")

        let removed = server.changePluginControl(strip: "fx/1", position: 1, parameterID: "2", add: false)
        XCTAssertTrue(removed.ok, removed.message)
        XCTAssertEqual(server.show.activePluginControls.map(\.name), ["Size"])
        XCTAssertEqual(server.show.pluginSelections["aufx/TVRB/Test"]?.removed, ["2"])

        let again = server.changePluginControl(strip: "fx/1", position: 1, parameterID: "2", add: true)
        XCTAssertTrue(again.ok, again.message)
        XCTAssertEqual(server.show.activePluginControls.map(\.name), ["Size", "Mix"])
        XCTAssertNotNil(server.value(at: server.show.activePluginControls[1].path), "seeded with its default")
        XCTAssertNotNil(server.options.store.loadShow()?.pluginSelections["aufx/TVRB/Test"], "saved with the show")
    }

    func testPluginLeavingTheChainDeactivatesItsControls() {
        let server = makeServer()
        XCTAssertEqual(server.show.activePluginControls.count, 2)
        server.discovered["fx/1"] = [:]
        server.rebuildBinding(server.show.strip(.fx(1))!)
        XCTAssertTrue(server.show.activePluginControls.isEmpty)
        XCTAssertEqual(server.show.pluginControls.count, 2, "addresses are kept for when it comes back")
    }
}

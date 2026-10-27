import XCTest
import FOHCore
@testable import FOHMacKit

/// Binding editor, config editing, setlist and learn logic — no network, no MIDI (the engine isn't started).
final class BridgeServerTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("foh-bridge-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A cut-down SSL Channel with real parameter names.
    static let ssl: PluginDescription = {
        func p(_ id: String, _ name: String, _ unit: String? = "dB") -> PluginParameterInfo {
            PluginParameterInfo(id: id, address: 0, name: name, unitName: unit, unit: 26, minValue: 0, maxValue: 1000, defaultValue: 500,
                                displayLogarithmic: false, valueStrings: nil, steps: (0...127).map { "\($0)" })
        }
        return PluginDescription(component: .wavesSSLChannel, name: "SSLChannel", manufacturerName: "Waves", parameters: [
            p("20", "LMF Gain"), p("21", "LMF Frq", "KHz"), p("22", "LMF Q", nil),
            p("23", "HMF Gain"), p("24", "HMF Frq", "KHz"), p("25", "HMF Q", nil),
        ])
    }()

    func makeServer() -> BridgeServer {
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory)
        options.discoverPlugins = false
        options.enableMeters = false
        options.portNameSuffix = " (unit)"
        let server = BridgeServer(options: options)
        server.discovered["in/1"] = [3: Self.ssl]
        server.discovered["in/2"] = [1: Self.ssl]
        for key in ["in/1", "in/2"] { server.rebuildBinding(server.show.strip(StripRef(key: key)!)!) }
        return server
    }

    func testManualBindingSurvivesRebuildAndApplyMapsByComponent() {
        let server = makeServer()
        let kelly = StripRef.input(1), guitar = StripRef.input(2)
        let gain = Role.band(2, "gain")!, q3 = Role.band(3, "q")!
        XCTAssertEqual(server.show.binding(kelly)[gain]?.parameterName, "LMF Gain")
        XCTAssertEqual(server.show.binding(kelly)[gain]?.origin, .auto)

        server.setBinding(strip: "in/1", roleID: gain.id, position: 3, parameterID: "23")
        server.setBinding(strip: "in/1", roleID: q3.id, position: 3, parameterID: "")
        XCTAssertEqual(server.show.binding(kelly)[gain]?.parameterName, "HMF Gain")
        XCTAssertEqual(server.show.binding(kelly)[gain]?.origin, .manual)
        XCTAssertNil(server.show.binding(kelly)[q3])
        XCTAssertTrue(server.show.binding(kelly).notInPlugin.contains(q3.id))

        // Rediscovery rebuilds from templates; the manual choices must come back.
        server.rebuildBinding(server.show.strip(kelly)!)
        XCTAssertEqual(server.show.binding(kelly)[gain]?.parameterName, "HMF Gain")
        XCTAssertNil(server.show.binding(kelly)[q3])

        // Lead vox's SSL is plugin 3, Guitar's is plugin 1.
        server.applyBindings(from: "in/1", to: "in/2")
        XCTAssertEqual(server.show.binding(guitar)[gain]?.parameterName, "HMF Gain")
        XCTAssertEqual(server.show.binding(guitar)[gain]?.pluginPosition, 1)
        XCTAssertNil(server.show.binding(guitar)[q3])

        server.resetBindings(strip: "in/2")
        XCTAssertEqual(server.show.binding(guitar)[gain]?.parameterName, "LMF Gain")
        XCTAssertEqual(server.show.binding(guitar)[gain]?.origin, .auto)

        // Overrides persist.
        XCTAssertEqual(BridgeStore(directory: directory).loadOverrides()["in/1"]?[gain.id]?.parameterID, "23")
    }

    func testChannelStripParameterIDs() {
        XCTAssertNotNil(ChannelStripParameter(id: "@volume"))
        if case .sendLevel(3)? = ChannelStripParameter(id: "@send3.level") {} else { XCTFail("send level") }
        if case .pluginBypass(2)? = ChannelStripParameter(id: "@plugin2.bypass") {} else { XCTFail("bypass") }
        XCTAssertNil(ChannelStripParameter(id: "@nope"))
    }

    func testApplyConfigKeepsUnchangedBindingsAndRebuildsChanged() {
        let server = makeServer()
        let manualGain = Role.band(2, "gain")!
        server.setBinding(strip: "in/1", roleID: manualGain.id, position: 3, parameterID: "23")

        var edited = server.show
        edited.strips[0].name = "Lead (main)"                                    // rename only
        edited.strips.append(Strip(ref: .input(3), name: "Bass", color: .green, hardwareIO: "In 3"))
        edited.sends.removeAll { $0.index == 5 }                                  // drop "Delay"
        server.applyConfig(edited)

        XCTAssertEqual(server.show.strip(.input(1))?.name, "Lead (main)")
        XCTAssertEqual(server.show.binding(.input(1))[manualGain]?.parameterName, "HMF Gain")   // kept (rebuilt for sends)
        XCTAssertNil(server.show.binding(.input(1))[Role.send(5, "level")!])                 // send roles follow sends
        XCTAssertNotNil(server.show.binding(.input(3))[Role.fader])                          // new strip has a baseline
    }

    func testPatchSelectAndLearn() {
        let server = makeServer()
        server.selectPatch(0)
        XCTAssertEqual(server.show.currentPatch, 0)

        XCTAssertNil(server.learn.current)
        server.learnBeginIfNeeded()
        XCTAssertEqual(server.learn.current, LearnState.Item(.input(1), .mute))
        server.learnNext()
        XCTAssertTrue(server.learn.learned.contains("in/1|mix.mute"))
        XCTAssertEqual(server.learn.current, LearnState.Item(.input(1), .solo))
        server.learnPrevious()
        XCTAssertEqual(server.learn.current, LearnState.Item(.input(1), .mute))
        XCTAssertEqual(server.learnDisplay?.cc, 1)
        XCTAssertEqual(server.learnDisplay?.portName, "FOH In 1-16 (unit)")
        XCTAssertEqual(BridgeStore(directory: directory).loadLearn().learned, ["in/1|mix.mute"])
        XCTAssertGreaterThan(server.learnProgress.total, 10)
    }
}

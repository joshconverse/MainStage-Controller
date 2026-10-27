import XCTest
@testable import FOHCore

/// Plugin controls (PLAN.md §9c): the catalog filter, core sets and permanent addresses on the plugin ports.
final class PluginControlTests: XCTestCase {
    func fixture(_ name: String) throws -> PluginDescription {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(PluginDescription.self, from: Data(contentsOf: url))
    }

    func testControlFilterOnRealPlugins() throws {
        XCTAssertEqual(try fixture("pro-q-3").parameters.filter(\.isControl).count, 273)
        XCTAssertEqual(try fixture("pro-r-2").parameters.filter(\.isControl).count, 120)
        let tune = try fixture("waves-tune-rt")
        XCTAssertFalse(tune.parameters.first { $0.name == "VU In Left" }!.isControl)
        XCTAssertTrue(tune.parameters.first { $0.name == "Speed" }!.isControl)
        // Flags from catalog version 2 win over the name.
        var meter = tune.parameters.first { $0.name == "Speed" }!
        meter.meter = true
        XCTAssertFalse(meter.isControl)
    }

    func testCoreSets() throws {
        let proQ = try fixture("pro-q-3"), proR = try fixture("pro-r-2"), tune = try fixture("waves-tune-rt")
        let q = PluginControlSets.core(for: proQ)
        XCTAssertEqual(q.count, 85, "8 bands × 10 + 5 globals")
        XCTAssertEqual(proQ.parameter(id: q[0])?.name, "Band 1 Used")
        XCTAssertTrue(q.contains { proQ.parameter(id: $0)?.name == "Band 8 Dynamic Range" })
        XCTAssertFalse(q.contains { proQ.parameter(id: $0)?.name == "Band 9 Frequency" })
        XCTAssertEqual(PluginControlSets.core(for: proR).count, 48, "12 main + 6 decay-EQ bands × 6")
        let generic = PluginControlSets.core(for: tune)
        XCTAssertEqual(generic.count, min(PluginControlSets.genericCount, tune.parameters.filter(\.isControl).count))
        XCTAssertTrue(generic.allSatisfy { tune.parameter(id: $0)!.isControl })
    }

    func testSelectionRemovesAndAdds() throws {
        let proQ = try fixture("pro-q-3")
        let core = PluginControlSets.core(for: proQ)
        let band9 = try XCTUnwrap(proQ.parameters.first { $0.name == "Band 9 Frequency" }?.id)
        let picked = PluginControlSets.selected(for: proQ, PluginSelection(added: [band9, "no-such-id"], removed: [core[0]]))
        XCTAssertEqual(picked.count, 85)
        XCTAssertFalse(picked.contains(core[0]))
        XCTAssertEqual(picked.last, band9)
    }

    /// The iPad's Pro-Q 3 and Pro-R 2 pages read values through the same display helpers as role bindings.
    func testPluginParametersReadLikeBindings() throws {
        let proQ = try fixture("pro-q-3"), proR = try fixture("pro-r-2")
        func q(_ name: String) throws -> PluginParameterInfo { try XCTUnwrap(proQ.parameters.first { $0.name == name }) }
        let freq = try q("Band 1 Frequency")
        XCTAssertEqual(freq.numeric(0)?.value, 10)
        XCTAssertEqual(freq.numeric(127)?.value, 30000)
        let thousand = try XCTUnwrap(freq.midi(closestTo: 1000))
        XCTAssertEqual(freq.numeric(thousand)?.value ?? 0, 1000, accuracy: 60, "1/11 octave per step")
        XCTAssertEqual(try q("Band 1 Gain").numeric(64)?.value ?? 99, 0.24, accuracy: 0.01)
        XCTAssertEqual(try q("Band 1 Q").numeric(64)?.value ?? 0, 1.029, accuracy: 0.001)
        XCTAssertEqual(try q("Band 1 Shape").stepCenters.map(\.label),
                       ["Bell", "Low Shelf", "Low Cut", "High Shelf", "High Cut", "Notch", "Band Pass", "Tilt Shelf", "Flat Tilt"])
        XCTAssertEqual(try q("Band 1 Slope").stepCenters.count, 10)
        XCTAssertNil(try q("Band 1 Threshold").numeric(127), "Auto")
        let rate = try XCTUnwrap(proR.parameters.first { $0.name == "Decay EQ Band 1 Rate" })
        XCTAssertEqual(rate.numeric(127)?.value, 200)
        XCTAssertEqual(rate.numeric(127)?.unit, .percent)
    }

    /// Add control / remove control (phase 4): edits the plugin type's selection; the next sync allocates or
    /// deactivates, and addresses are never reused.
    func testAddAndRemoveControlsChangeTheTypeSelection() throws {
        var show = ShowConfig.church
        let found = try discovered()
        show.syncPluginControls(discovered: found)
        let proQ = found["in/1"]![2]!
        let band9 = try XCTUnwrap(proQ.parameters.first { $0.name == "Band 9 Frequency" }?.id)
        let band1 = try XCTUnwrap(proQ.parameters.first { $0.name == "Band 1 Frequency" }?.id)

        XCTAssertTrue(show.addPluginControl(proQ, parameterID: band9))
        XCTAssertFalse(show.addPluginControl(proQ, parameterID: band9), "already added")
        XCTAssertFalse(show.addPluginControl(proQ, parameterID: band1), "already in the core set")
        XCTAssertFalse(show.addPluginControl(proQ, parameterID: "no-such-id"))
        XCTAssertEqual(show.syncPluginControls(discovered: found).allocated, 1)
        let added = try XCTUnwrap(show.activePluginControls.first { $0.parameterID == band9 && $0.strip == .input(1) && $0.position == 2 })

        XCTAssertTrue(show.removePluginControl(proQ, parameterID: band1))
        XCTAssertFalse(show.removePluginControl(proQ, parameterID: band1), "already removed")
        XCTAssertTrue(show.removePluginControl(proQ, parameterID: band9))
        show.syncPluginControls(discovered: found)
        XCTAssertFalse(show.activePluginControls.contains { $0.strip == .input(1) && $0.position == 2 && [band1, band9].contains($0.parameterID) })

        // Put back: the same address as before, nothing new handed out.
        XCTAssertTrue(show.addPluginControl(proQ, parameterID: band9))
        XCTAssertTrue(show.addPluginControl(proQ, parameterID: band1), "un-removes a core parameter")
        XCTAssertEqual(show.syncPluginControls(discovered: found).allocated, 0)
        XCTAssertEqual(show.activePluginControls.first { $0.parameterID == band9 && $0.strip == .input(1) && $0.position == 2 }?.address, added.address)
        XCTAssertEqual(show.pluginSelections[ShowConfig.selectionKey(proQ.component)], PluginSelection(added: [band9], removed: []))
    }

    /// MainStage's own plugins (phase 5): one hand-made mapping teaches a parameter, every instance gets it.
    func testLearnedMainStagePluginParametersGeneralise() throws {
        var show = ShowConfig.church
        let found = try discovered()
        show.syncPluginControls(discovered: found)
        // Channel EQ on Main (out/1, insert 3) and, for this test, on Output 2 too.
        let i = try XCTUnwrap(show.strips.firstIndex { $0.ref == .output(3) })
        show.strips[i].plugins = [PluginRef(position: 1, name: "Channel EQ")]
        let main = try XCTUnwrap(show.strip(.output(1))), out2 = show.strips[i]
        XCTAssertTrue(show.mainStagePluginDescriptions(main).isEmpty, "nothing learned yet")

        let learn = try XCTUnwrap(show.startLearn(strip: .output(1), position: 3, pluginName: "Channel EQ", name: "Low Cut Freq"))
        XCTAssertFalse(show.pluginControls.contains { $0.address == learn.address }, "a free address")
        XCTAssertEqual(show.syncPluginControls(discovered: found).allocated, 0)
        XCTAssertFalse(show.activePluginControls.contains { $0.address == learn.address }, "never handed to a control while pending")

        let learned = try XCTUnwrap(show.resolveLearn(learn.id, parameterIndex: 12))
        XCTAssertEqual(learned, LearnedParameter(index: 12, name: "Low Cut Freq"))
        XCTAssertTrue(show.pendingLearns.isEmpty)
        XCTAssertEqual(show.activePluginControls.first { $0.strip == .output(1) && $0.parameterID == "12" }?.address, learn.address,
                       "the hand-made mapping's address is the control's")

        // Generalise: every Channel EQ gets it once its strip syncs with the stand-in description.
        let described = show.mainStagePluginDescriptions(out2)
        XCTAssertEqual(described[1]?.parameters.map(\.name), ["Low Cut Freq"])
        XCTAssertEqual(described[1]?.parameters.first?.display(127), "100%")
        XCTAssertEqual(show.syncPluginControls(discovered: ["out/1": show.mainStagePluginDescriptions(main), "out/3": described]).allocated, 1)
        XCTAssertTrue(show.activePluginControls.contains { $0.strip == .output(3) && $0.position == 1 && $0.parameterID == "12" })
        XCTAssertTrue(show.activePluginControls.contains { $0.strip == .output(1) && $0.parameterID == "12" }, "kept on Main")

        XCTAssertTrue(show.forgetLearned("Channel EQ", index: 12))
        show.syncPluginControls(discovered: ["out/1": show.mainStagePluginDescriptions(main), "out/3": show.mainStagePluginDescriptions(out2)])
        XCTAssertFalse(show.activePluginControls.contains { $0.parameterID == "12" && $0.component.isMainStagePlugin })
        let back = try JSONDecoder().decode(ShowConfig.self, from: JSONEncoder().encode(show))
        XCTAssertEqual(back.learnedParameters, show.learnedParameters)
    }

    func testPluginPathsRoundTrip() {
        let path = FOHProtocol.pluginPath(.input(1), 2, "315")
        XCTAssertEqual(path, "/foh/in/1/plugin/2/315")
        let parsed = FOHProtocol.parsePluginPath(path)
        XCTAssertEqual(parsed?.strip, .input(1))
        XCTAssertEqual(parsed?.position, 2)
        XCTAssertEqual(parsed?.parameterID, "315")
        XCTAssertNil(FOHProtocol.parseValuePath(path), "a plugin path is not a role path")
        XCTAssertNil(FOHProtocol.parsePluginPath("/foh/in/1/band/2/gain"))
        XCTAssertNil(StripRef.from(port: .plugins1, channel: 1))
    }

    /// Lead vox (Tune 1, Pro-Q 2, SSL 3 as EQ/dynamics) and the reverb return (Pro-R 1).
    func discovered() throws -> [String: [Int: PluginDescription]] {
        ["in/1": [1: try fixture("waves-tune-rt"), 2: try fixture("pro-q-3"), 3: try fixture("ssl-channel")],
         "fx/1": [1: try fixture("pro-r-2")]]
    }

    func testSyncAllocatesStableAddressesOnThePluginPorts() throws {
        var show = ShowConfig.church
        let found = try discovered()
        let tuneCount = PluginControlSets.core(for: found["in/1"]![1]!).count
        let first = show.syncPluginControls(discovered: found)
        XCTAssertEqual(first.allocated, tuneCount + 85 + 48, "Tune + Pro-Q core on Lead vox, Pro-R core on the return; SSL is driven by roles")
        let active = show.activePluginControls
        XCTAssertEqual(Set(active.map(\.address)).count, active.count, "every address unique")
        XCTAssertTrue(active.allSatisfy { $0.address.port.isPluginPort && !MIDIAddress.reservedCCs.contains($0.address.cc) })
        XCTAssertFalse(active.contains { $0.strip == .input(1) && $0.position == 3 }, "the SSL is the EQ/dynamics source")
        XCTAssertEqual(show.pluginControl(path: active[0].path), active[0])
        XCTAssertEqual(show.pluginControl(at: active[0].address), active[0])
        XCTAssertFalse(active.contains { $0.name.isEmpty })

        // Re-syncing changes nothing.
        let addresses = Dictionary(uniqueKeysWithValues: show.pluginControls.map { ($0.path, $0.address) })
        XCTAssertEqual(show.syncPluginControls(discovered: found).allocated, 0)

        // Pro-Q leaves Lead vox's chain: its controls go inactive, Tune's stay.
        var without = found
        without["in/1"]![2] = nil
        show.syncPluginControls(discovered: without)
        XCTAssertFalse(show.activePluginControls.contains { $0.strip == .input(1) && $0.position == 2 })
        XCTAssertEqual(show.activePluginControls.filter { $0.strip == .input(1) }.count, tuneCount)

        // It comes back: the same addresses, nothing new handed out.
        XCTAssertEqual(show.syncPluginControls(discovered: found).allocated, 0)
        for c in show.activePluginControls { XCTAssertEqual(addresses[c.path], c.address, c.path) }

        // Strips discovery didn't report on are left alone.
        show.syncPluginControls(discovered: ["in/2": [:]])
        XCTAssertEqual(show.activePluginControls.count, tuneCount + 85 + 48)
    }

    func testAllocationSkipsReservedCCsAndFillsPortsInOrder() {
        XCTAssertEqual(MIDIAddress.usableCCs.count, 110)
        XCTAssertFalse(MIDIAddress.usableCCs.contains(0))
        XCTAssertFalse(MIDIAddress.usableCCs.contains(121))
        var show = ShowConfig.church
        let big = PluginDescription(component: AUComponentID(type: "aufx", subtype: "BIG1", manufacturer: "Test"), name: "Big",
                                    manufacturerName: "Test", parameters: (0..<2000).map {
            PluginParameterInfo(id: "\($0)", address: UInt64($0), name: "P\($0)", unitName: nil, unit: 0, minValue: 0, maxValue: 1,
                                defaultValue: 0, displayLogarithmic: false, valueStrings: nil, steps: [])
        })
        show.pluginSelections[ShowConfig.selectionKey(big.component)] = PluginSelection(added: (0..<2000).map { "\($0)" })
        show.syncPluginControls(discovered: ["out/1": [1: big]])
        let ports = Set(show.activePluginControls.map(\.address.port))
        XCTAssertEqual(ports, [.plugins1, .plugins2], "1,760 fit on the first port; the rest spill to the second")
        XCTAssertEqual(show.activePluginControls.filter { $0.address.port == .plugins1 }.count, 1760)
    }

    func testShowWithPluginControlsRoundTripsAndOldShowsDecode() throws {
        var show = ShowConfig.church
        show.syncPluginControls(discovered: try discovered())
        show.pluginSelections["aumf/FQ3p/FabF"] = PluginSelection(added: ["400"])
        let back = try JSONDecoder().decode(ShowConfig.self, from: JSONEncoder().encode(show))
        XCTAssertEqual(back.pluginControls, show.pluginControls)
        XCTAssertEqual(back.pluginSelections, show.pluginSelections)
        let old = #"{"name":"Old","strips":[]}"#
        XCTAssertTrue(try JSONDecoder().decode(ShowConfig.self, from: Data(old.utf8)).pluginControls.isEmpty)
    }
}

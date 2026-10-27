import XCTest
@testable import FOHCore

final class RoleMapTests: XCTestCase {
    func testEveryRoleHasAUniqueUnreservedCC() {
        var seen: [UInt8: String] = [:]
        for role in Role.all {
            XCTAssertFalse(Role.reservedCCs.contains(role.cc), "\(role.id) uses reserved CC \(role.cc)")
            XCTAssertNil(seen[role.cc], "\(role.id) and \(seen[role.cc] ?? "") share CC \(role.cc)")
            seen[role.cc] = role.id
            XCTAssertLessThan(role.cc, 128)
        }
    }

    func testPlanTableSpotChecks() {
        XCTAssertEqual(Role.fader.cc, 7)
        XCTAssertEqual(Role.band(2, "gain")?.cc, 26)
        XCTAssertEqual(Role.band(4, "freq")?.cc, 34)
        XCTAssertEqual(Role["band.1.type"]?.cc, 18)
        XCTAssertEqual(Role["comp.thresh"]?.cc, 41)
        XCTAssertEqual(Role["gate.mode"]?.cc, 56)
        XCTAssertEqual(Role.send(1, "level")?.cc, 60)
        XCTAssertEqual(Role.send(8, "on")?.cc, 77)
        XCTAssertEqual(Role.insertBypass(1)?.cc, 102)
        XCTAssertEqual(Role.insertMacro(2, 8)?.cc, 119)
        XCTAssertEqual(Role.insertMacro(4, 6)?.cc, 95)
        XCTAssertNil(Role.insertMacro(4, 7))
    }

    func testRoleCodableUsesID() throws {
        let data = try JSONEncoder().encode([Role.fader])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"mix.fader\"]")
        XCTAssertEqual(try JSONDecoder().decode([Role].self, from: data), [Role.fader])
    }
}

final class AddressTests: XCTestCase {
    func testStripPortsAndChannels() {
        XCTAssertEqual(StripRef.input(1).port, .inputs1)
        XCTAssertEqual(StripRef.input(1).channel, 1)
        XCTAssertEqual(StripRef.input(17).port, .inputs2)
        XCTAssertEqual(StripRef.input(17).channel, 1)
        XCTAssertEqual(StripRef.fx(1).port, .auxBus)
        XCTAssertEqual(StripRef.fx(1).channel, 1)
        XCTAssertEqual(StripRef.output(1).channel, 9)
        XCTAssertEqual(StripRef.master.port, .global)
        XCTAssertNil(StripRef(kind: .fx, slot: 9))
    }

    func testEveryAddressRoundTrips() {
        var strips: [StripRef] = []
        for kind in StripKind.allCases { for slot in kind.slotRange { strips.append(StripRef(kind: kind, slot: slot)!) } }
        var seen = Set<MIDIAddress>()
        for strip in strips {
            for role in Role.all {
                let addr = AddressMap.address(strip, role)
                XCTAssertTrue(seen.insert(addr).inserted, "duplicate address \(addr)")
                let back = AddressMap.resolve(addr)
                XCTAssertEqual(back?.strip, strip)
                XCTAssertEqual(back?.role, role)
            }
        }
    }

    func testLeadVoxExampleFromPlan() {
        let a = AddressMap.address(.input(1), Role.band(2, "gain")!)
        XCTAssertEqual(a, MIDIAddress(port: .inputs1, channel: 1, cc: 26))
    }
}

final class OSCTests: XCTestCase {
    func testMessageRoundTrip() throws {
        let m = OSCMessage("/foh/in/1/band/2/gain", [.int(64), .float(0.5), .string("hey"), .blob(Data([1, 2, 3])),
                                                     .bool(true), .int64(-5), .double(2.25)])
        let decoded = try OSCPacket.decode(m.encoded())
        XCTAssertEqual(decoded, .message(m))
    }

    func testEncodingIsFourByteAligned() {
        for addr in ["/a", "/ab", "/abc", "/abcd"] {
            XCTAssertEqual(OSCMessage(addr, [.string("x")]).encoded().count % 4, 0)
        }
    }

    func testKnownBytes() {
        // "/foo" ,i 1000 — classic OSC spec example shape.
        let bytes = [UInt8](OSCMessage("/foo", [.int(1000)]).encoded())
        XCTAssertEqual(bytes, [0x2F, 0x66, 0x6F, 0x6F, 0, 0, 0, 0, 0x2C, 0x69, 0, 0, 0, 0, 0x03, 0xE8])
    }

    func testBundleRoundTrip() throws {
        let b = OSCPacket.bundle(timeTag: OSCPacket.immediate, elements: [
            .message(OSCMessage("/foh/sync")),
            .message(OSCMessage("/foh/in/1/mix/fader", [.int(100)])),
        ])
        let decoded = try OSCPacket.decode(b.encoded())
        XCTAssertEqual(decoded, b)
        XCTAssertEqual(decoded.messages.count, 2)
    }

    func testTruncatedThrows() {
        let data = OSCMessage("/foh/x", [.int(1)]).encoded().dropLast(2)
        XCTAssertThrowsError(try OSCPacket.decode(Data(data)))
    }
}

final class SLIPTests: XCTestCase {
    func testFramingAcrossArbitraryChunks() {
        let packets = [Data([1, 2, 0xC0, 3]), Data([0xDB, 0xDB, 9]), OSCMessage("/foh/sync").encoded()]
        var stream = Data()
        for p in packets { stream.append(SLIP.encode(p)) }
        var decoder = SLIP.Decoder()
        var out: [Data] = []
        var i = 0
        while i < stream.count {
            let n = min(3, stream.count - i)
            out += decoder.feed(stream.subdata(in: i..<(i + n)))
            i += n
        }
        XCTAssertEqual(out, packets)
    }
}

final class ProtocolTests: XCTestCase {
    func testValuePathRoundTrip() {
        for strip in [StripRef.input(1), .input(32), .fx(3), .output(8), .master] {
            for role in Role.all {
                let path = FOHProtocol.valuePath(strip, role)
                let back = FOHProtocol.parseValuePath(path)
                XCTAssertEqual(back?.strip, strip, path)
                XCTAssertEqual(back?.role, role, path)
            }
        }
        XCTAssertEqual(FOHProtocol.valuePath(.input(1), Role.band(2, "gain")!), "/foh/in/1/band/2/gain")
        XCTAssertNil(FOHProtocol.parseValuePath("/foh/in/99/mix/fader"))
        XCTAssertNil(FOHProtocol.parseValuePath("/foh/in/1/nope"))
    }

    func testShowConfigCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(ShowConfig.church)
        let back = try JSONDecoder().decode(ShowConfig.self, from: data)
        XCTAssertEqual(back, ShowConfig.church)
        XCTAssertEqual(back.strip(.input(1))?.name, "Lead vox")
    }
}

final class DisplayValueTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(DisplayValue.parse("320 Hz"), DisplayValue(value: 320, unit: .hz))
        XCTAssertEqual(DisplayValue.parse("3.2 kHz"), DisplayValue(value: 3200, unit: .hz))
        XCTAssertEqual(DisplayValue.parse("3.2k"), DisplayValue(value: 3200, unit: .hz))
        XCTAssertEqual(DisplayValue.parse("-3.5 dB"), DisplayValue(value: -3.5, unit: .db))
        XCTAssertEqual(DisplayValue.parse("−3.5dB"), DisplayValue(value: -3.5, unit: .db))
        XCTAssertEqual(DisplayValue.parse("3.0:1"), DisplayValue(value: 3, unit: .ratio))
        XCTAssertEqual(DisplayValue.parse("300 ms"), DisplayValue(value: 300, unit: .ms))
        XCTAssertEqual(DisplayValue.parse("0.3 s"), DisplayValue(value: 0.3, unit: .s))
        XCTAssertEqual(DisplayValue.parse("12", unitHint: "dB"), DisplayValue(value: 12, unit: .db))
        XCTAssertEqual(DisplayValue.parse("-inf dB")?.value, -.infinity)
        XCTAssertNil(DisplayValue.parse("Off"))
    }
}

final class TemplateTests: XCTestCase {
    func testSSLTemplateBindsByName() {
        func p(_ id: String, _ name: String, unit: UInt32 = 0, steps: [String] = []) -> PluginParameterInfo {
            PluginParameterInfo(id: id, address: 0, name: name, unitName: nil, unit: unit, minValue: 0, maxValue: 1,
                                defaultValue: 0, displayLogarithmic: false, valueStrings: nil, steps: steps)
        }
        let plugin = PluginDescription(component: .wavesSSLChannel, name: "SSLChannel", manufacturerName: "Waves", parameters: [
            p("1", "LMF Gain"), p("2", "LMF Frq"), p("3", "LMF Q"), p("4", "Comp Ratio"), p("5", "LF Bell", unit: 2),
        ])
        let template = Templates.template(for: plugin)
        XCTAssertEqual(template?.name, "Waves SSL Channel")
        let result = template!.bind(plugin, position: 3)
        let ids = Set(result.bound.map(\.role.id))
        XCTAssertTrue(ids.isSuperset(of: ["band.2.gain", "band.2.freq", "band.2.q", "comp.ratio", "band.1.type"]))
        XCTAssertEqual(result.bound.first { $0.role.id == "band.1.type" }?.kind, .toggle)
        XCTAssertTrue(result.notInPlugin.contains { $0.id == "band.2.on" })
    }

    func fixture(_ name: String) throws -> PluginDescription {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(PluginDescription.self, from: Data(contentsOf: url))
    }

    /// Real discovery output from Waves SSLChannel (m), V15 (spike S8).
    func testLeadVoxBindingFromRealSSLDiscovery() throws {
        let ssl = try fixture("ssl-channel")
        let tune = try fixture("waves-tune-rt")
        let strip = ShowConfig.church.strip(.input(1))!
        let binding = StripBinding.build(for: strip, sends: ShowConfig.church.sends, discovered: [3: ssl, 1: tune])

        // Every SSL template rule found its parameter.
        XCTAssertEqual(Templates.wavesSSLChannel.bind(ssl, position: 3).bound.count, Templates.wavesSSLChannel.rules.count)

        let lmfGain = try XCTUnwrap(binding[Role.band(2, "gain")!])
        XCTAssertEqual(lmfGain.parameterName, "LMF Gain")
        XCTAssertEqual(lmfGain.pluginPosition, 3)
        XCTAssertEqual(lmfGain.display(0), "-15.0")
        XCTAssertEqual(lmfGain.display(127), "15.0")
        XCTAssertEqual(lmfGain.numeric(127)?.unit, .db)

        let lmfFreq = try XCTUnwrap(binding[Role.band(2, "freq")!])
        XCTAssertEqual(lmfFreq.numeric(127)?.value ?? 0, 2500, accuracy: 1)   // "2.50" with unit KHz
        XCTAssertEqual(lmfFreq.midi(closestTo: 1010), 64)                     // drag-to-value honours KHz

        XCTAssertEqual(binding[Role.insertMacro(1, 8)!]?.parameterName, "Formant")
        XCTAssertEqual(binding[Role.insertMacro(1, 8)!]?.kind, .toggle)       // Off/On over 0…1, not flagged boolean

        let eqOn = try XCTUnwrap(binding[Role.eqOn])
        XCTAssertEqual(eqOn.parameterName, "EQBypass")
        XCTAssertTrue(eqOn.invert)
        XCTAssertEqual(eqOn.wireValue(127), 0)       // EQ on → EQBypass off
        XCTAssertEqual(eqOn.display(127), "Off")     // shows the bypass param's text, inverted

        XCTAssertEqual(binding[Role.trimOut]?.parameterName, "Gain")
        XCTAssertEqual(binding[Role.fader]?.parameterID, "@volume")
        XCTAssertEqual(binding[Role.send(3, "level")!]?.parameterName, "Send 3 level")

        // Waves Tune on insert page 1.
        XCTAssertEqual(binding[Role.insertMacro(1, 1)!]?.parameterName, "Speed")
        let key = try XCTUnwrap(binding[Role.insertMacro(1, 3)!])
        XCTAssertEqual(key.parameterName, "Scale Root")
        XCTAssertEqual(key.stepCenters.first?.label, "C")
        XCTAssertEqual(binding[Role.insertBypass(1)!]?.parameterID, "@plugin1.bypass")

        // SSL has no per-band on switches.
        XCTAssertTrue(binding.notInPlugin.contains("band.2.on"))
        XCTAssertFalse(binding.isBound(Role.band(2, "on")!))

        // Neutral defaults for a fresh bridge cache.
        let defaults = binding.defaultRoleValues(discovered: [3: ssl, 1: tune])
        XCTAssertEqual(defaults[Role.band(2, "gain")!].map { lmfGain.display($0) }, "0.1")   // SSL default 500/1000
        XCTAssertEqual(defaults[Role.eqOn], 127)                                               // EQBypass off → EQ on
        XCTAssertEqual(defaults[Role.fader], 90)                                               // ≈ 0 dB
        XCTAssertEqual(defaults[Role.pan], 64)
    }

    func testEstimatedVolumeLaw() {
        XCTAssertEqual(ChannelStripParameter.estimatedVolumeDB(127), 6, accuracy: 0.001)
        XCTAssertEqual(ChannelStripParameter.estimatedVolumeDB(90), 0, accuracy: 0.05)
        XCTAssertEqual(ChannelStripParameter.estimatedVolumeDB(0), -.infinity)
    }
}

final class Phase2ContractTests: XCTestCase {
    func testOldShowFilesStillDecode() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ShowConfig.church)) as! [String: Any]
        json["patches"] = nil
        json["currentPatch"] = nil
        json["concertPath"] = nil
        let back = try JSONDecoder().decode(ShowConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.patches, [])
        XCTAssertEqual(back.strips.count, ShowConfig.church.strips.count)
    }

    func testHardwareChannels() {
        XCTAssertEqual(ShowConfig.church.strip(.input(1))?.hardwareInputChannels, [0])
        XCTAssertEqual(ShowConfig.church.strip(.output(1))?.hardwareOutputChannels, [0, 1])
        XCTAssertEqual(Strip(ref: .input(3), name: "Keys", color: .magenta, stereo: true, hardwareIO: "In 3-4").hardwareInputChannels, [2, 3])
        XCTAssertEqual(Strip(ref: .input(5), name: "Pad", color: .blue, stereo: true, hardwareIO: "In 5").hardwareInputChannels, [4, 5])
        XCTAssertEqual(ShowConfig.church.strip(.fx(1))?.hardwareInputChannels, [])
        XCTAssertEqual(ShowConfig.church.nextFreeSlot(.input), 3)
        XCTAssertEqual(ShowConfig.church.nextFreeSlot(.master), nil)
    }

    func testMeterFrameRoundTripAndScale() {
        let f = MeterFrame(inputPeak: [0, 128, 255], inputRMS: [0, 100, 200], outputPeak: [10, 20], outputRMS: [5, 6])
        XCTAssertEqual(MeterFrame(data: f.encoded()), f)
        XCTAssertNil(MeterFrame(data: Data([9, 0, 0, 0, 0])))
        XCTAssertEqual(MeterScale.byte(fromDB: 0), 255)
        XCTAssertEqual(MeterScale.byte(fromDB: -100), 0)
        XCTAssertEqual(MeterScale.byte(fromLinear: 1), 255)
        XCTAssertEqual(MeterScale.db(fromByte: MeterScale.byte(fromDB: -18)), -18, accuracy: 0.3)
        let kelly = ShowConfig.church.strip(.input(1))!
        XCTAssertEqual(f.peak(for: kelly), [0])
        XCTAssertEqual(f.peak(for: ShowConfig.church.strip(.output(1))!), [10, 20])
        XCTAssertEqual(RTAFrame.bandCenters.count, 59)
        let rta = RTAFrame(strip: "in/1", bands: [1, 2, 3])
        XCTAssertEqual(RTAFrame(rta.message()), rta)
    }

    func testLearnOrderAndNext() {
        var show = ShowConfig.church
        for s in show.strips { show.bindings[s.ref.key] = StripBinding.build(for: s, sends: show.sends, discovered: [:]) }
        let order = LearnState.order(in: show)
        XCTAssertEqual(order.first, LearnState.Item(.input(1), .mute))
        var state = LearnState()
        let first = state.next(after: nil, in: show)
        XCTAssertEqual(first, LearnState.Item(.input(1), .mute))
        state.learned = [first!.key]
        XCTAssertEqual(state.next(after: first, in: show), LearnState.Item(.input(1), .solo))
        XCTAssertEqual(state.next(after: nil, in: show, strip: .input(2))?.strip, "in/2")
        XCTAssertEqual(LearnState.label(LearnState.Item(.input(1), .fader), in: show), "Lead vox › Channel strip › Volume")
    }

    func testConcertMergeKeepsSlotsAndAddsNewStrips() {
        let concert = ConcertInfo(name: "Church", path: "/x/Church.concert", strips: [
            .init(name: "Lead vox", kind: .audioInput, level: .concert, input: "In 1",
                  plugins: ShowConfig.church.strip(.input(1))!.plugins),
            .init(name: "Bass", kind: .audioInput, level: .concert, input: "In 3",
                  plugins: [PluginRef(position: 1, name: "SSLChannel", component: .wavesSSLChannel)]),
            .init(name: "Botta Church", kind: .aux, level: .concert, stereo: true, input: "Bus 1"),
            .init(name: "Delay", kind: .aux, level: .concert, stereo: true, input: "Bus 5"),
            .init(name: "Metronome", kind: .instrument, level: .concert),
        ], patches: [PatchInfo(index: 0, name: "Song One", programChange: 0), PatchInfo(index: 1, name: "Song Two", programChange: 1)])
        let merged = ShowConfig.church.merged(with: concert)

        let kelly = merged.strip(.input(1))!
        XCTAssertEqual(kelly.name, "Lead vox")
        XCTAssertEqual(kelly.mainStage?.level, .concert)             // moved to concert level in MainStage
        XCTAssertEqual(kelly.processing.eq, 3)                       // chain unchanged → processing kept

        let bass = merged.strip(.input(3))!                          // next free input slot
        XCTAssertEqual(bass.name, "Bass")
        XCTAssertEqual(bass.processing.eq, 1)                        // SSL suggested for EQ/Dyn/Trim
        XCTAssertEqual(bass.hardwareIO, "In 3")
        XCTAssertNotNil(merged.strip(.fx(2)))                        // Delay aux added
        XCTAssertFalse(merged.strips.contains { $0.name == "Metronome" })

        XCTAssertEqual(merged.sends.first { $0.busNumber == 5 }?.existsInConcert, true)   // Delay bus now real
        XCTAssertEqual(merged.sends.first { $0.busNumber == 2 }?.existsInConcert, false)  // Mon 1 still missing
        XCTAssertEqual(merged.patches.count, 2)
        XCTAssertEqual(merged.concertPath, "/x/Church.concert")
    }

    func testSuggestedProcessing() {
        let p = ProcessingSources.suggested(for: ShowConfig.church.strip(.input(1))!.plugins)
        XCTAssertEqual(p.eq, 3)
        XCTAssertEqual(p.insertPages, [1: 1, 2: 2])
    }
}

final class CalibrationTests: XCTestCase {
    func testCalibrationBendsTheVolumeLaw() {
        let cal = [CalibrationPoint(midi: 127, db: 6), CalibrationPoint(midi: 100, db: 0), CalibrationPoint(midi: 64, db: -10),
                   CalibrationPoint(midi: 0, db: nil)]
        XCTAssertEqual(ChannelStripParameter.volumeDB(100, calibration: cal), 0, accuracy: 0.001)
        XCTAssertEqual(ChannelStripParameter.volumeDB(82, calibration: cal), -5, accuracy: 0.001)     // halfway 64…100
        XCTAssertEqual(ChannelStripParameter.volumeDB(0, calibration: cal), -.infinity)
        // Below the lowest point: the estimated shape, offset to meet MIDI 64 = −10 dB.
        let est = ChannelStripParameter.estimatedVolumeDB(32) + (-10 - ChannelStripParameter.estimatedVolumeDB(64))
        XCTAssertEqual(ChannelStripParameter.volumeDB(32, calibration: cal), est, accuracy: 0.001)
        XCTAssertEqual(ChannelStripParameter.volumeDB(90, calibration: []), ChannelStripParameter.estimatedVolumeDB(90))

        let strip = ShowConfig.church.strip(.input(1))!
        let b = StripBinding.build(for: strip, sends: ShowConfig.church.sends, discovered: [:], calibration: cal)
        XCTAssertEqual(b[Role.fader]?.display(100), "0.0 dB")
        XCTAssertEqual(b[Role.send(3, "level")!]?.display(100), "0.0 dB")
    }

    func testCalibrationSurvivesShowRoundTrip() throws {
        var show = ShowConfig.church
        show.faderCalibration = [CalibrationPoint(midi: 90, db: 0), CalibrationPoint(midi: 0, db: nil)]
        let back = try JSONDecoder().decode(ShowConfig.self, from: JSONEncoder().encode(show))
        XCTAssertEqual(back.faderCalibration, show.faderCalibration)
    }
}

final class FinishingContractTests: XCTestCase {
    func fixture(_ name: String) throws -> PluginDescription {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(PluginDescription.self, from: Data(contentsOf: url))
    }

    func testCustomTemplateCapturedFromLeadVoxAppliesToGuitar() throws {
        let ssl = try fixture("ssl-channel")
        let show = ShowConfig.church
        let kelly = show.strip(.input(1))!, guitar = show.strip(.input(2))!
        var kb = StripBinding.build(for: kelly, sends: show.sends, discovered: [3: ssl])
        // Hand-tune: LMF gain → HMF Gain, hide band.3.q.
        let hmfGain = ssl.parameters.first { $0.name == "HMF Gain" }!
        kb.roles["band.2.gain"] = RoleBinding(role: Role.band(2, "gain")!, pluginPosition: 3, pluginName: "SSLChannel",
                                               parameterID: hmfGain.id, parameterName: hmfGain.name, unitName: hmfGain.unitName,
                                               kind: .continuous, steps: hmfGain.steps, origin: .manual)
        kb.roles["band.3.q"] = nil
        kb.notInPlugin.append("band.3.q")

        let template = try XCTUnwrap(CustomTemplate.capture(name: "Vocal SSL", strip: kelly, binding: kb, position: 3, use: .processing))
        XCTAssertEqual(template.component, .wavesSSLChannel)
        XCTAssertEqual(template.rules["eq.on"]?.invert, true)            // EQBypass inversion carried over
        XCTAssertEqual(template.rules["band.2.gain"]?.parameterID, hmfGain.id)

        let gb = StripBinding.build(for: guitar, sends: show.sends, discovered: [1: ssl], customTemplates: [template])
        XCTAssertEqual(gb[Role.band(2, "gain")!]?.parameterName, "HMF Gain")
        XCTAssertEqual(gb[Role.band(2, "gain")!]?.pluginPosition, 1)       // Guitar's SSL is plugin 1
        XCTAssertFalse(gb.isBound(Role.band(3, "q")!))
        XCTAssertTrue(gb.notInPlugin.contains("band.3.q"))
        XCTAssertEqual(gb[Role.eqOn]?.wireValue(127), 0)
        XCTAssertEqual(gb[Role.fader]?.parameterID, "@volume")             // channel-strip roles still there
    }

    func testInsertTemplateCapture() throws {
        let tune = try fixture("waves-tune-rt")
        let kelly = ShowConfig.church.strip(.input(1))!
        let kb = StripBinding.build(for: kelly, sends: [], discovered: [1: tune])
        let t = try XCTUnwrap(CustomTemplate.capture(name: "Tune", strip: kelly, binding: kb, position: 1, use: .insert))
        XCTAssertEqual(t.rules["macro.3"].flatMap { tune.parameter(id: $0.parameterID)?.name }, "Scale Root")
        let again = StripBinding.build(for: kelly, sends: [], discovered: [1: tune], customTemplates: [t])
        XCTAssertEqual(again[Role.insertMacro(1, 3)!]?.parameterName, "Scale Root")
        XCTAssertEqual(again[Role.insertBypass(1)!]?.parameterID, "@plugin1.bypass")
    }

    func testDisplayOrderNeverMovesSlots() {
        var show = ShowConfig.church
        show.stripOrder = ["in/2", "in/1"]
        XCTAssertEqual(show.ordered(.input).map(\.name), ["Guitar", "Lead vox"])
        XCTAssertEqual(show.ordered(.output).map(\.name), ["Main", "Output 1", "Output 2"])   // unlisted → slot order
        XCTAssertEqual(show.strip(.input(1))?.name, "Lead vox")                                // address unchanged
    }

    func testBackupBundleRoundTrip() throws {
        var show = ShowConfig.church
        show.customTemplates = [CustomTemplate(name: "X", component: nil, pluginName: "SSLChannel", use: .processing,
                                               rules: ["band.2.gain": .init(parameterID: "23")])]
        let bundle = BackupBundle(reason: "test", show: show, overrides: ["in/1": ["band.2.gain": .init(position: 3, parameterID: "23")]],
                                  learn: LearnState(current: .init(.input(1), .fader), learned: ["in/1|mix.mute"]), values: ["/foh/in/1/mix/fader": 90])
        let back = try JSONDecoder().decode(BackupBundle.self, from: JSONEncoder().encode(bundle))
        XCTAssertEqual(back, bundle)
        XCTAssertTrue(back.suggestedFilename.hasSuffix(".fohshow"))
    }

    func testConfirmedValueMessage() {
        let m = FOHProtocol.valueMessage(.input(1), .fader, 90, confirmed: true)
        XCTAssertEqual(m.arguments, [.int(90), .int(1)])
        XCTAssertEqual(FOHProtocol.parseValuePath(m.address)?.role, .fader)
        let ack = FOHProtocol.ackMessage(FOHProtocol.Path.pull, ok: true, "Re-selected Song One")
        XCTAssertEqual(ack.arguments.count, 3)
    }
}

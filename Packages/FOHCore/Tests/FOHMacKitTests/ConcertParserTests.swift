import XCTest
import FOHCore
@testable import FOHMacKit

final class ConcertParserTests: XCTestCase {
    var fixture: URL {
        Bundle.module.url(forResource: "Church", withExtension: "concert", subdirectory: "Fixtures")!
    }

    /// Full names as AVAudioUnitComponentManager reports them on a Mac with Waves V15 + FabFilter.
    let names: [AUComponentID: String] = [
        .wavesSSLChannel: "SSLChannel (m)",
        .wavesTuneRealTime: "Waves Tune Real-Time (m)",
        .fabFilterProQ3: "Pro-Q 3",
    ]

    func strip(_ info: ConcertInfo, _ name: String) throws -> ConcertInfo.ChannelStrip {
        try XCTUnwrap(info.strips.first { $0.name == name }, "no strip \(name)")
    }

    func testChurchConcert() throws {
        let info = try ConcertParser.parse(fixture, componentNames: names)
        XCTAssertEqual(info.name, "Church")
        XCTAssertEqual(info.audioInputCount, 18)
        XCTAssertEqual(info.patches.map(\.name), ["Song One"])
        XCTAssertEqual(info.patches.first?.programChange, 0)

        let kelly = try strip(info, "Lead vox")
        XCTAssertEqual(kelly.kind, .audioInput)
        XCTAssertEqual(kelly.level, .patch)
        XCTAssertEqual(kelly.patchName, "Song One")
        XCTAssertEqual(kelly.input, "In 1")
        XCTAssertFalse(kelly.stereo)
        XCTAssertEqual(kelly.plugins.map(\.name), ["Waves Tune Real-Time", "Pro-Q 3", "SSLChannel"])
        XCTAssertEqual(kelly.plugins.map(\.position), [1, 2, 3])
        XCTAssertEqual(kelly.plugins.map(\.component), [.wavesTuneRealTime, .fabFilterProQ3, .wavesSSLChannel])
        // Waves' own factory preset name really is spelled "AT Femal Vocal 1".
        XCTAssertEqual(kelly.plugins[2].preset, "AT Femal Vocal 1")
        XCTAssertNil(kelly.plugins[0].preset)          // "Untitled" is generic
        XCTAssertEqual(kelly.sends.first?.slot, 1)
        XCTAssertEqual(kelly.sends.first?.bus, 1)

        let guitar = try strip(info, "Guitar")
        XCTAssertEqual(guitar.kind, .audioInput)
        XCTAssertEqual(guitar.input, "In 2")
        XCTAssertEqual(guitar.plugins.first?.preset, "Acc Gtr")
        XCTAssertEqual(guitar.sends.first?.bus, 1)
        XCTAssertEqual(guitar.sends.first?.level ?? 0, 0.378, accuracy: 0.001)

        let botta = try strip(info, "Botta Church")
        XCTAssertEqual(botta.kind, .aux)
        XCTAssertEqual(botta.level, .concert)
        XCTAssertEqual(botta.input, "Bus 1")
        XCTAssertEqual(botta.inputBus, 1)
        XCTAssertTrue(botta.stereo)
        XCTAssertEqual(botta.plugins.map(\.name), ["Space Designer"])

        let main = try strip(info, "Main")
        XCTAssertEqual(main.kind, .output)
        XCTAssertEqual(main.output, "Out 1-2")
        XCTAssertTrue(main.stereo)
        XCTAssertEqual(main.plugins.map(\.name), ["Gain", "MultiMeter", "Channel EQ", "Multipressor", "Direction Mixer", "MultiMeter"])
        XCTAssertEqual(main.plugins[2].preset, "Final Mix - Pop")
        XCTAssertEqual(main.plugins[3].preset, "Final Pop Compressor")

        let out1 = try strip(info, "Output 1")
        XCTAssertEqual(out1.kind, .output)
        XCTAssertEqual(out1.output, "Out 1")
        XCTAssertEqual(out1.plugins.map(\.name), ["Pro-Q 3"])

        XCTAssertEqual(try strip(info, "Output 2").plugins, [])
        XCTAssertEqual(try strip(info, "Master").kind, .master)
        XCTAssertEqual(try strip(info, "Metronome").kind, .instrument)
    }

    func testWithoutComponentLookupKeepsShortNames() throws {
        let info = try ConcertParser.parse(fixture, componentNames: [:])
        let kelly = try strip(info, "Lead vox")
        XCTAssertEqual(kelly.plugins.map(\.name), ["Waves Tune", "Pro-Q 3", "SSLChannel"])
        XCTAssertEqual(kelly.plugins.map(\.component), [.wavesTuneRealTime, .fabFilterProQ3, .wavesSSLChannel])
    }

    func testMergeIntoChurchShowKeepsLeadVoxProcessing() throws {
        let info = try ConcertParser.parse(fixture, componentNames: names)
        let merged = ShowConfig.church.merged(with: info)
        XCTAssertEqual(merged.strip(.input(1))?.name, "Lead vox")
        XCTAssertEqual(merged.strip(.input(1))?.processing.eq, 3)
        XCTAssertEqual(merged.strip(.input(2))?.name, "Guitar")
        XCTAssertFalse(merged.strips.contains { $0.name == "Metronome" })
        XCTAssertEqual(merged.patches.map(\.name), ["Song One"])
        XCTAssertEqual(merged.concertPath, fixture.path)
    }

    func testHelpers() {
        XCTAssertEqual(ConcertParser.auComponent(Array("VWskxfuaMHCS".utf8)), .wavesSSLChannel)
        XCTAssertNil(ConcertParser.auComponent(Array("GAME\0\0\0\0abcd".utf8)))
        XCTAssertEqual(ConcertParser.ioLabel("In", index: 1, stereo: true), "In 3-4")
        XCTAssertEqual(ConcertParser.cleanVariantSuffix("SSLChannel (s)"), "SSLChannel")
        XCTAssertEqual(ConcertParser.classify(header: "Aux 1", name: "x", inputIndex: 0, inputIsBus: true), .aux)
        XCTAssertEqual(ConcertParser.classify(header: "Aux 2", name: "x", inputIndex: 0, inputIsBus: false), .audioInput)
    }
}

import XCTest
@testable import FOHCore

/// FOH Meter plugin readings and the meter frame's plugin-meter trailer.
final class PluginMeterTests: XCTestCase {
    /// Bytes the real plugin (Apps/FOHMeter) sent for a −6 dBFS sine on the left and −26 dBFS on the right.
    static let pluginBytes = "2f666f682f6d657465722f706c7567696e0000002c736962620000005652422052657475726e000042f99ce4"
        + "000000083f0000003d4ccccd000000083e0000003aa3d70b"

    static func data(hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
    }

    func testDecodesWhatThePluginSends() throws {
        let packet = try XCTUnwrap(OSCPacket.decode(Self.data(hex: Self.pluginBytes)).messages.first.flatMap(PluginMeterPacket.init))
        XCTAssertEqual(packet.contextName, "VRB Return")
        XCTAssertEqual(packet.instance, 0x42F9_9CE4)
        XCTAssertEqual(packet.peak, [0.5, 0.05])
        XCTAssertEqual(packet.meanSquare[0], 0.125)
        XCTAssertEqual(packet.meanSquare[1], 0.00125, accuracy: 1e-7)
        XCTAssertEqual(PluginMeterPacket(packet.message()), packet)
        XCTAssertEqual(packet.message().encoded(), Self.data(hex: Self.pluginBytes))
    }

    func testRejectsMalformedPackets() {
        let good = PluginMeterPacket(contextName: "A", instance: 1, peak: [0.1], meanSquare: [0.01]).message()
        XCTAssertNotNil(PluginMeterPacket(good))
        var wrongAddress = good
        wrongAddress.address = "/foh/meters"
        XCTAssertNil(PluginMeterPacket(wrongAddress))
        XCTAssertNil(PluginMeterPacket(OSCMessage(FOHProtocol.Path.pluginMeter, [.string("A"), .int(1), .blob(Data([0, 0, 0])), .blob(Data())])))
        let mismatched = OSCMessage(FOHProtocol.Path.pluginMeter, [.string("A"), .int(1), .blob(Data(count: 8)), .blob(Data(count: 4))])
        XCTAssertNil(PluginMeterPacket(mismatched))
        let tooMany = OSCMessage(FOHProtocol.Path.pluginMeter, [.string("A"), .int(1), .blob(Data(count: 4 * 65)), .blob(Data(count: 4 * 65))])
        XCTAssertNil(PluginMeterPacket(tooMany))
    }

    func testFrameCarriesStripMetersAndOldDecodersStillWork() throws {
        let f = MeterFrame(inputPeak: [1, 2], inputRMS: [3, 4], outputPeak: [5], outputRMS: [6],
                           strips: ["fx/1": StripLevels(peak: [200, 150], rms: [180, 120]), "in/1": StripLevels(peak: [9], rms: [8])])
        let encoded = f.encoded()
        XCTAssertEqual(MeterFrame(data: encoded), f)
        // A frame without plugin meters is byte-for-byte the old format.
        let plain = MeterFrame(inputPeak: [1, 2], inputRMS: [3, 4], outputPeak: [5], outputRMS: [6])
        XCTAssertEqual(plain.encoded(), Data([1, 0, 2, 0, 1, 1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(encoded.prefix(11), plain.encoded())   // older iPads read this much and stop
        // A damaged trailer loses only the plugin meters.
        for cut in 12..<encoded.count {
            let partial = try XCTUnwrap(MeterFrame(data: encoded.prefix(cut)))
            XCTAssertEqual(partial.inputPeak, [1, 2])
            XCTAssertTrue(partial.strips.isEmpty || partial.strips == f.strips)
        }
    }

    func testPluginMeterWinsForItsStrip() {
        let show = ShowConfig.church
        let vox = show.strip(.input(1))!, fx = show.strip(.fx(1))!, main = show.strip(.output(1))!
        let f = MeterFrame(inputPeak: [10], inputRMS: [5], outputPeak: [20, 30], outputRMS: [1, 2],
                           strips: ["fx/1": StripLevels(peak: [100, 110], rms: [90, 95])])
        XCTAssertEqual(f.peak(for: fx), [100, 110])
        XCTAssertEqual(f.peak(for: vox), [10])
        XCTAssertEqual(f.peak(for: main), [20, 30])
        XCTAssertNil(MeterFrame().peak(for: fx))
    }

    func testFindsTheStripFromMainStagesName() {
        var show = ShowConfig.church
        XCTAssertEqual(show.stripForPluginMeter(contextName: "Botta Church")?.id, "fx/1")       // MainStage name
        XCTAssertEqual(show.stripForPluginMeter(contextName: "botta church ")?.id, "fx/1")      // case, spaces
        XCTAssertEqual(show.stripForPluginMeter(contextName: "Concert: Main")?.id, "out/1")     // contained
        XCTAssertEqual(show.stripForPluginMeter(contextName: "Output 1 copy")?.id, "out/2")     // longest contained
        XCTAssertNil(show.stripForPluginMeter(contextName: "Nothing like it"))

        show.strips[2].name = "Reverb"                                                           // FOH name differs
        XCTAssertEqual(show.stripForPluginMeter(contextName: "reverb")?.id, "fx/1")

        // No usable name: the only strip with FOH Meter in its chain.
        show.strips[2].plugins.append(PluginRef(position: 2, name: "FOH Meter", component: PluginMeterPacket.component))
        XCTAssertEqual(show.stripForPluginMeter(contextName: "")?.id, "fx/1")
        XCTAssertEqual(show.stripForPluginMeter(contextName: "Aux 1")?.id, "fx/1")
        show.strips[0].plugins.append(PluginRef(position: 4, name: "FOH Meter", component: PluginMeterPacket.component))
        XCTAssertNil(show.stripForPluginMeter(contextName: ""))                                  // two: can't tell
    }
}

import XCTest
@testable import FOHCore

/// Inputs from the network or a damaged file that used to trap.
final class StabilityTests: XCTestCase {
    func testNonFiniteFloatsAreNotIntegers() {
        XCTAssertNil(OSCArgument.float(.nan).intValue)
        XCTAssertNil(OSCArgument.double(.infinity).intValue)
        XCTAssertNil(OSCArgument.double(-.infinity).intValue)
        XCTAssertEqual(OSCArgument.double(1e30).intValue, Int(Int32.max))
        XCTAssertEqual(OSCArgument.float(63.6).intValue, 64)
    }

    func testHardwareIOTyposStayBounded() {
        func strip(_ io: String, stereo: Bool = false, kind: StripKind = .input) -> Strip {
            Strip(ref: StripRef(kind: kind, slot: 1)!, name: "x", color: .cyan, stereo: stereo, hardwareIO: io)
        }
        XCTAssertEqual(strip("In 3-4").hardwareInputChannels, [2, 3])
        XCTAssertEqual(strip("In 1-99999999999").hardwareInputChannels, [0])
        XCTAssertEqual(strip("In 1-16000").hardwareInputChannels, [0])
        XCTAssertEqual(strip("In 99999").hardwareInputChannels, [])
        XCTAssertEqual(strip("In 256", stereo: true).hardwareInputChannels, [255])
        XCTAssertEqual(strip("Out 1-99999", kind: .output).hardwareOutputChannels, [0])
    }

    func testOutOfRangeSlotIsRejected() {
        let bad = Data(#"{"kind":"in","slot":900}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StripRef.self, from: bad))
        let good = Data(#"{"kind":"out","slot":3}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StripRef.self, from: good), .output(3))
        XCTAssertEqual(try JSONDecoder().decode(StripRef.self, from: JSONEncoder().encode(StripRef.input(17))), .input(17))
    }

    func testUnknownRoleDropsOnlyThatBinding() throws {
        var binding = StripBinding()
        binding.roles["mix.fader"] = ChannelStripParameter.volume.binding(.fader)
        binding.notInPlugin = ["band.1.q"]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as! [String: Any]
        var roles = json["roles"] as! [String: Any]
        var future = roles["mix.fader"] as! [String: Any]
        future["role"] = "mix.someFutureRole"
        roles["mix.someFutureRole"] = future
        json["roles"] = roles
        let decoded = try JSONDecoder().decode(StripBinding.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(Set(decoded.roles.keys), ["mix.fader"])
        XCTAssertEqual(decoded.notInPlugin, ["band.1.q"])
    }

    func testNonFinitePluginDefaultsAreSkipped() {
        func param(_ id: String, min: Float, max: Float, value: Float) -> PluginParameterInfo {
            PluginParameterInfo(id: id, address: 0, name: id, unitName: nil, unit: 0, minValue: min, maxValue: max,
                                defaultValue: value, displayLogarithmic: false, valueStrings: nil, steps: [])
        }
        let plugin = PluginDescription(component: AUComponentID(type: "aufx", subtype: "TEST", manufacturer: "Test"), name: "T",
                                       manufacturerName: "T", parameters: [param("1", min: 0, max: 1, value: .nan),
                                                                           param("2", min: 0, max: 10, value: 500)])
        var binding = StripBinding()
        binding.roles["comp.thresh"] = RoleBinding(role: Role["comp.thresh"]!, pluginPosition: 1, pluginName: "T", parameterID: "1",
                                                   parameterName: "a", unitName: nil, kind: .continuous, steps: [], origin: .auto)
        binding.roles["comp.ratio"] = RoleBinding(role: Role["comp.ratio"]!, pluginPosition: 1, pluginName: "T", parameterID: "2",
                                                  parameterName: "b", unitName: nil, kind: .continuous, steps: [], origin: .auto)
        let values = binding.defaultRoleValues(discovered: [1: plugin])
        XCTAssertNil(values[Role["comp.thresh"]!])
        XCTAssertEqual(values[Role["comp.ratio"]!], 127)
        XCTAssertEqual(param("3", min: 0, max: .infinity, value: 0).kind, .continuous)
    }
}

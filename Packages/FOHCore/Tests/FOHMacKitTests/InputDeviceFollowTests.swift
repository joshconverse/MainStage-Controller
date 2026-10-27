import XCTest
import FOHCore
@testable import FOHMacKit

/// The input meters follow the chosen interface as it's plugged in and unplugged (no hardware needed).
final class InputDeviceFollowTests: XCTestCase {
    typealias Policy = InputDevicePolicy

    func testChosenDeviceIsOpenedWhenConnectedAndWaitedForWhenNot() {
        XCTAssertEqual(Policy.decide(chosenUID: "scarlett", connected: ["mic", "scarlett"], defaultUID: "mic"), .open(uid: "scarlett"))
        // Unplugged: wait for it, never fall back to the built-in mic.
        XCTAssertEqual(Policy.decide(chosenUID: "scarlett", connected: ["mic"], defaultUID: "mic"), .waiting(uid: "scarlett"))
        XCTAssertEqual(Policy.decide(chosenUID: "scarlett", connected: [], defaultUID: nil), .waiting(uid: "scarlett"))
    }

    func testSystemDefaultIsFollowed() {
        XCTAssertEqual(Policy.decide(chosenUID: nil, connected: ["mic", "scarlett"], defaultUID: "mic"), .open(uid: "mic"))
        XCTAssertEqual(Policy.decide(chosenUID: nil, connected: ["mic", "scarlett"], defaultUID: "scarlett"), .open(uid: "scarlett"))
        XCTAssertEqual(Policy.decide(chosenUID: "", connected: ["mic"], defaultUID: "mic"), .open(uid: "mic"))
        XCTAssertEqual(Policy.decide(chosenUID: nil, connected: [], defaultUID: nil), .noDevice)
        XCTAssertEqual(Policy.decide(chosenUID: nil, connected: ["mic"], defaultUID: "gone"), .noDevice)
    }

    func testWhenTheCaptureHasToChange() {
        XCTAssertFalse(Policy.needsChange(openUID: "scarlett", for: .open(uid: "scarlett")))
        XCTAssertTrue(Policy.needsChange(openUID: nil, for: .open(uid: "scarlett")))        // plugged back in
        XCTAssertTrue(Policy.needsChange(openUID: "mic", for: .open(uid: "scarlett")))      // default changed
        XCTAssertTrue(Policy.needsChange(openUID: "scarlett", for: .waiting(uid: "scarlett"))) // unplugged
        XCTAssertFalse(Policy.needsChange(openUID: nil, for: .waiting(uid: "scarlett")))
        XCTAssertTrue(Policy.needsChange(openUID: "mic", for: .noDevice))
        XCTAssertFalse(Policy.needsChange(openUID: nil, for: .noDevice))
    }

    // MARK: Bridge status

    var directory: URL!
    var suffix: String!
    var savedList: (() -> [AudioInputDevice])!
    var devices: [AudioInputDevice] = []

    static let scarlett = AudioInputDevice(uid: "AppleUSBAudioEngine:Focusrite:Scarlett 2i2 USB:1", name: "Scarlett 2i2 USB",
                                           inputChannels: 2, isDefault: false)
    static let mic = AudioInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", inputChannels: 1, isDefault: true)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("foh-input-tests-\(UUID().uuidString)")
        suffix = " (input-test \(UUID().uuidString.prefix(8)))"
        savedList = AudioMetering.listInputDevices
        AudioMetering.listInputDevices = { [unowned self] in self.devices }
    }

    override func tearDown() {
        AudioMetering.listInputDevices = savedList
        for key in [BridgeServer.inputDeviceKey, BridgeServer.inputDeviceNameKey] {
            MIDIEngine.sharedDefaults.removeObject(forKey: key + suffix)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func makeServer() -> BridgeServer {
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory)
        options.discoverPlugins = false
        options.portNameSuffix = suffix
        options.meterSourceFactory = { NullMeterSource() }
        return BridgeServer(options: options)
    }

    func testStatusSaysWhatTheMetersAreWaitingFor() {
        devices = [Self.mic, Self.scarlett]
        let server = makeServer()
        server.startMeters()
        defer { server.stopMeters() }

        server.setInputDevice(uid: Self.scarlett.uid)
        server.refreshMeterStatus()
        XCTAssertNil(server.status.inputWaitingFor, "connected: nothing to wait for")
        XCTAssertEqual(server.savedInputDeviceName, "Scarlett 2i2 USB")

        // Unplugged.
        devices = [Self.mic]
        server.refreshInputDevicesNow()
        server.refreshMeterStatus()
        XCTAssertEqual(server.status.inputWaitingFor, "Scarlett 2i2 USB")

        // A restarted bridge still knows the name.
        let restarted = makeServer()
        restarted.startMeters()
        defer { restarted.stopMeters() }
        XCTAssertEqual(restarted.inputDeviceUID, Self.scarlett.uid)
        XCTAssertEqual(restarted.status.inputWaitingFor, "Scarlett 2i2 USB")

        // Plugged back in.
        devices = [Self.mic, Self.scarlett]
        server.refreshInputDevicesNow()
        server.refreshMeterStatus()
        XCTAssertNil(server.status.inputWaitingFor)
    }

    func testFollowingTheSystemDefaultNeverWaits() {
        devices = []
        let server = makeServer()
        server.startMeters()
        defer { server.stopMeters() }
        server.setInputDevice(uid: nil)
        server.refreshMeterStatus()
        XCTAssertNil(server.status.inputWaitingFor)
        XCTAssertNil(server.savedInputDeviceName)
    }

    func testStatusDecodesWithoutTheNewField() throws {
        let old = #"{"bridgeName":"FOH Bridge","ports":[],"clients":[],"discoveredPlugins":[],"inputDevice":"Scarlett 2i2 USB"}"#
        let status = try JSONDecoder().decode(BridgeStatus.self, from: Data(old.utf8))
        XCTAssertEqual(status.inputDevice, "Scarlett 2i2 USB")
        XCTAssertNil(status.inputWaitingFor)
    }
}

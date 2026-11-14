import Darwin
import XCTest
import FOHCore
@testable import FOHMacKit

/// The bridge side of the FOH Meter plugin: ballistics, timeouts, and readings arriving over UDP reaching a client.
final class PluginMeterBridgeTests: XCTestCase {
    func packet(_ name: String = "Botta Church", instance: UInt32 = 7, peakDB: [Double], rmsDB: [Double]) -> PluginMeterPacket {
        PluginMeterPacket(contextName: name, instance: instance, peak: peakDB.map { Float(pow(10, $0 / 20)) },
                          meanSquare: rmsDB.map { Float(pow(10, $0 / 10)) })
    }

    func testPeaksHoldAndFallBackLikeTheHardwareMeters() {
        var bank = PluginMeterBank()
        bank.add(packet(peakDB: [-6, -20], rmsDB: [-9, -23]), stripKey: "fx/1", now: 0)
        var levels = bank.levels(now: 0)["fx/1"]!
        XCTAssertEqual(MeterScale.db(fromByte: levels.peak[0]), -6, accuracy: 0.3)
        XCTAssertEqual(MeterScale.db(fromByte: levels.rms[1]), -23, accuracy: 0.3)

        bank.add(packet(peakDB: [-40, -40], rmsDB: [-43, -43]), stripKey: "fx/1", now: 0.25)   // quiet: peak falls 6 dB
        levels = bank.levels(now: 0.25)["fx/1"]!
        XCTAssertEqual(MeterScale.db(fromByte: levels.peak[0]), -12, accuracy: 0.3)
        XCTAssertEqual(MeterScale.db(fromByte: levels.rms[0]), -43, accuracy: 0.3)          // RMS doesn't hold
    }

    func testSilentInstancesDropOutAndTwoInstancesShowTheLouder() {
        var bank = PluginMeterBank()
        bank.add(packet(instance: 1, peakDB: [-30], rmsDB: [-33]), stripKey: "fx/1", now: 0)
        bank.add(packet(instance: 2, peakDB: [-10], rmsDB: [-40]), stripKey: "fx/1", now: 0)
        bank.add(packet("Nowhere", instance: 3, peakDB: [-10], rmsDB: [-13]), stripKey: nil, now: 0)
        let merged = bank.levels(now: 0.1)
        XCTAssertEqual(Array(merged.keys), ["fx/1"])
        XCTAssertEqual(MeterScale.db(fromByte: merged["fx/1"]!.peak[0]), -10, accuracy: 0.3)
        XCTAssertEqual(MeterScale.db(fromByte: merged["fx/1"]!.rms[0]), -33, accuracy: 0.3)
        XCTAssertTrue(bank.levels(now: 0.6).isEmpty)
        XCTAssertTrue(bank.entries.isEmpty)
    }

    func testReadingsOverUDPReachTheIPad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foh-plugin-meter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = BridgeServer.Options()
        options.store = BridgeStore(directory: directory)
        options.discoverPlugins = false
        options.advertiseBonjour = false
        options.port = 0
        options.portNameSuffix = " (plugin meter test)"
        options.meterSourceFactory = { FakeMeterSource(inputs: 2, outputs: 2) }
        // Never 9009: that's the installed bridge's.
        let udpPort = UInt16.random(in: 41000...48999)
        options.pluginMeterPort = udpPort
        let server = BridgeServer(options: options)
        try server.start()
        defer { server.stop() }
        let deadline = Date().addingTimeInterval(5)
        while server.listeningPort == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let port = try XCTUnwrap(server.listeningPort)
        XCTAssertNotNil(server.pluginMeterReceiver, "couldn't bind UDP \(udpPort)")

        let client = BridgeOSCClient(host: "127.0.0.1", port: port)
        var seen: StripLevels?
        var status: BridgeStatus?
        let metered = expectation(description: "FX return meter")
        let reported = expectation(description: "status names the strip")
        client.onMessage = { m in
            if m.address == FOHProtocol.Path.meters, seen == nil,
               let frame = m.arguments.first?.blobValue.flatMap(MeterFrame.init(data:)), let fx = frame.strips["fx/1"] {
                XCTAssertFalse(frame.inputPeak.isEmpty)   // the hardware meters still come along
                seen = fx
                metered.fulfill()
            }
            if m.address == FOHProtocol.Path.status, status == nil,
               let s = try? FOHProtocol.decodeJSON(BridgeStatus.self, from: m), s.pluginMeters != nil {
                status = s
                reported.fulfill()
            }
        }
        client.start()
        defer { client.cancel() }
        client.send(OSCMessage(FOHProtocol.Path.hello, [.string("unit test"), .int(FOHProtocol.version)]))

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = udpPort.bigEndian
        to.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bytes = [UInt8](packet(peakDB: [-6, -12], rmsDB: [-9, -15]).message().encoded())
        let sender = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            _ = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        defer { sender.invalidate() }
        wait(for: [metered, reported], timeout: 5)

        let fx = try XCTUnwrap(seen)
        XCTAssertEqual(fx.peak.count, 2)
        XCTAssertEqual(MeterScale.db(fromByte: fx.peak[0]), -6, accuracy: 0.5)
        XCTAssertEqual(MeterScale.db(fromByte: fx.rms[1]), -15, accuracy: 0.5)
        XCTAssertEqual(status?.pluginMeters, ["Botta Church"])
        XCTAssertTrue(server.logLines.contains { $0.contains("FOH Meter on \"Botta Church\" → Botta Church (2 ch)") })

        // Stop sending: the strip drops out of the frames and the status.
        sender.invalidate()
        let until = Date().addingTimeInterval(2)
        while server.status.pluginMeters != nil && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNil(server.status.pluginMeters)
    }
}

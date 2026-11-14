#if os(macOS)
import Darwin
import Foundation
import FOHCore

/// Hears the FOH Meter plugin (Apps/FOHMeter) on a UDP port bound to 127.0.0.1, so nothing off this Mac can reach
/// it. Packets that don't decode are dropped. `onPacket` runs on `queue`.
final class PluginMeterReceiver {
    private let source: DispatchSourceRead

    struct BindError: Error, CustomStringConvertible {
        var port: UInt16
        var code: Int32
        var description: String {
            code == EADDRINUSE ? "UDP \(port) is in use (another FOH Bridge?)" : "UDP \(port): \(String(cString: strerror(code)))"
        }
    }

    init(port: UInt16, queue: DispatchQueue, onPacket: @escaping (PluginMeterPacket) -> Void) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw BindError(port: port, code: errno) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw BindError(port: port, code: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = [UInt8](repeating: 0, count: 2048)
        source.setEventHandler {
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                guard n > 0 else { return }
                guard let packet = try? OSCPacket.decode(Data(buffer[0..<n])) else { continue }
                for message in packet.messages {
                    if let reading = PluginMeterPacket(message) { onPacket(reading) }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func stop() { source.cancel() }

    deinit { source.cancel() }
}

/// Live FOH Meter readings, per plugin instance, turned into meter bytes with the hardware meters' ballistics: peaks
/// hold and fall back at `peakDecayDBPerSecond`, RMS is the window since the plugin's previous packet. An instance that
/// stops sending (MainStage quit, plugin removed or bypassed) drops out after `timeout`. Pure, so it's testable.
struct PluginMeterBank {
    struct Entry {
        var contextName: String
        var stripKey: String?
        var heldPeakDB: [Double]
        var rms: [UInt8]
        var lastSeen: TimeInterval
    }

    var peakDecayDBPerSecond: Double = 24
    var timeout: TimeInterval = 0.5
    private(set) var entries: [UInt32: Entry] = [:]

    mutating func add(_ p: PluginMeterPacket, stripKey: String?, now: TimeInterval) {
        let previous = entries[p.instance].flatMap { $0.heldPeakDB.count == p.peak.count ? $0 : nil }
        let dt = previous.map { max(0, now - $0.lastSeen) } ?? 0
        let held = p.peak.enumerated().map { c, peak -> Double in
            let block = peak > 0 && peak.isFinite ? 20 * log10(Double(peak)) : -.infinity
            return max(block, (previous?.heldPeakDB[c] ?? -.infinity) - peakDecayDBPerSecond * dt)
        }
        let rms = p.meanSquare.map { MeterScale.byte(fromLinear: $0 > 0 && $0.isFinite ? $0.squareRoot() : 0) }
        entries[p.instance] = Entry(contextName: p.contextName, stripKey: stripKey, heldPeakDB: held, rms: rms, lastSeen: now)
    }

    /// Strip key → levels for every instance heard within `timeout`; two instances on one strip show the louder.
    mutating func levels(now: TimeInterval) -> [String: StripLevels] {
        entries = entries.filter { now - $0.value.lastSeen <= timeout }
        var result: [String: StripLevels] = [:]
        for e in entries.values {
            guard let key = e.stripKey else { continue }
            let levels = StripLevels(peak: e.heldPeakDB.map { MeterScale.byte(fromDB: $0) }, rms: e.rms)
            if let existing = result[key], existing.peak.count == levels.peak.count {
                result[key] = StripLevels(peak: zip(existing.peak, levels.peak).map { max($0, $1) },
                                          rms: zip(existing.rms, levels.rms).map { max($0, $1) })
            } else {
                result[key] = levels
            }
        }
        return result
    }
}
#endif

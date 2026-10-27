import XCTest
@testable import FOHCore

/// Bytes off the network must never crash the bridge or the iPad: every malformed packet is either decoded
/// or rejected with an error. Seeded, so a failure reproduces.
final class DecoderFuzzTests: XCTestCase {
    /// xorshift64*: small, seedable, good enough for fuzzing.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2685821657736338717
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8(truncatingIfNeeded: next()) }) }
    }

    /// Valid packets of every kind, to mutate.
    static let seeds: [Data] = [
        OSCPacket.message(OSCMessage("/foh/in/1/band/2/gain", [.int(64)])).encoded(),
        OSCPacket.message(OSCMessage("/foh/config", [.string(#"{"name":"Church"}"#), .blob(Data([1, 2, 3])), .float(0.5)])).encoded(),
        OSCPacket.message(OSCMessage("/foh/meters", [.blob(Data(repeating: 7, count: 33)), .int64(9), .double(1.5), .bool(true), .bool(false)])).encoded(),
        OSCPacket.bundle(timeTag: OSCPacket.immediate, elements: [
            .message(OSCMessage("/a", [.int(1)])),
            .bundle(timeTag: 1, elements: [.message(OSCMessage("/b", [.string("x")]))]),
        ]).encoded(),
    ]

    func testRandomBytesNeverCrashTheOSCDecoder() {
        var rng = Rng(state: 0x9E37_79B9_7F4A_7C15)
        for _ in 0..<20_000 {
            _ = try? OSCPacket.decode(rng.bytes(rng.int(0...96)))
        }
    }

    func testMutatedPacketsNeverCrashTheOSCDecoder() {
        var rng = Rng(state: 42)
        for _ in 0..<40_000 {
            var p = Self.seeds[rng.int(0...(Self.seeds.count - 1))]
            switch rng.int(0...3) {
            case 0:  // flip a few bytes
                for _ in 0..<rng.int(1...4) where !p.isEmpty { p[rng.int(0...(p.count - 1))] = UInt8(truncatingIfNeeded: rng.next()) }
            case 1:  // truncate
                p = p.prefix(rng.int(0...p.count))
            case 2:  // overwrite a 4-byte length/int with something huge or odd
                if p.count >= 4 {
                    let at = rng.int(0...(p.count - 4)) & ~3
                    let v = [UInt32.max, 0x7FFF_FFFF, 0x8000_0000, 1, 2, 3, UInt32(p.count)][rng.int(0...6)]
                    p.replaceSubrange(at..<(at + 4), with: withUnsafeBytes(of: v.bigEndian) { Data($0) })
                }
            default:  // splice random bytes in
                let at = rng.int(0...p.count)
                p.insert(contentsOf: rng.bytes(rng.int(1...12)), at: at)
            }
            _ = try? OSCPacket.decode(p)
        }
    }

    /// A blob whose padding runs past the end used to leave the reader beyond the data; the next string read trapped.
    func testBlobWithoutPaddingThenStringIsRejected() {
        var p = Data()
        p.appendOSCString("/x")
        p.appendOSCString(",bs")
        p.appendBigEndian(UInt32(1))
        p.append(0xAB)                       // 1-byte blob, padding missing, then no string at all
        XCTAssertThrowsError(try OSCPacket.decode(p))
    }

    /// Deeply nested bundles would recurse until the stack overflowed (background threads have small stacks).
    func testDeeplyNestedBundlesAreRejected() {
        var inner = OSCPacket.message(OSCMessage("/x"))
        for _ in 0..<5_000 { inner = .bundle(timeTag: 1, elements: [inner]) }
        let data = inner.encoded()
        let done = expectation(description: "decoded on a small-stack thread")
        let rejected = LockedFlag()
        let thread = Thread {
            if (try? OSCPacket.decode(data)) == nil { rejected.set() }
            done.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [done], timeout: 10)
        XCTAssertTrue(rejected.value, "a 5,000-deep bundle should be rejected")
    }

    func testRealisticNestingStillDecodes() throws {
        let packet = OSCPacket.bundle(timeTag: 1, elements: [.bundle(timeTag: 2, elements: [.message(OSCMessage("/a", [.int(5)]))])])
        XCTAssertEqual(try OSCPacket.decode(packet.encoded()), packet)
    }

    func testSLIPDecoderSurvivesRandomStreams() {
        var rng = Rng(state: 7)
        var decoder = SLIP.Decoder()
        for _ in 0..<5_000 {
            for packet in decoder.feed(rng.bytes(rng.int(0...64))) { _ = try? OSCPacket.decode(packet) }
        }
        // Still in sync afterwards: a clean packet comes through intact.
        _ = decoder.feed(Data([SLIP.end]))
        let message = OSCPacket.message(OSCMessage("/foh/ping", [.int(1)]))
        XCTAssertEqual(decoder.feed(SLIP.encode(message.encoded())).last.flatMap { try? OSCPacket.decode($0) }, message)
    }

    /// A client that never sends an END byte must not grow the buffer without limit.
    func testSLIPDecoderDropsOversizedPackets() {
        var decoder = SLIP.Decoder()
        let chunk = Data(repeating: 0x41, count: 1 << 20)
        for _ in 0..<(SLIP.maxPacketSize / chunk.count + 4) { XCTAssertTrue(decoder.feed(chunk).isEmpty) }
        XCTAssertLessThanOrEqual(decoder.bufferedBytes, SLIP.maxPacketSize)
        // The oversized packet is discarded at its END; the next one decodes normally.
        XCTAssertTrue(decoder.feed(Data([SLIP.end])).isEmpty)
        let message = OSCPacket.message(OSCMessage("/ok"))
        XCTAssertEqual(decoder.feed(SLIP.encode(message.encoded())).compactMap { try? OSCPacket.decode($0) }, [message])
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

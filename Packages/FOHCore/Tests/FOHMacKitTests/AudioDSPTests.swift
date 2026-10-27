import XCTest
import FOHCore
@testable import FOHMacKit

final class AudioDSPTests: XCTestCase {
    func sine(_ frequency: Double, amplitude: Float, sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    /// Deterministic white noise in −1…1 (xorshift).
    func whiteNoise(count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(Double(state % 2_000_001) / 1_000_000 - 1)
        }
    }

    /// Paul Kellet's economy pink filter applied to white noise (≈ −3 dB/octave).
    func pinkNoise(count: Int) -> [Float] {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        return whiteNoise(count: count).map { w in
            b0 = 0.99765 * b0 + w * 0.0990460
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            return (b0 + b1 + b2 + w * 0.1848) * 0.1
        }
    }

    let kiloBand = RTAFrame.bandCenters.firstIndex { abs($0 - 1000) < 0.01 }!

    func testSinePeaksInItsBand() {
        let rta = RTAAnalyzer(sampleRate: 48_000)
        let db = rta.spectrumDB(of: sine(1000, amplitude: 0.5, sampleRate: 48_000, count: RTAAnalyzer.fftSize))
        XCTAssertEqual(db.indices.max { db[$0] < db[$1] }, kiloBand)
        XCTAssertEqual(Double(db[kiloBand]), -6.02, accuracy: 1.0)          // sine-referenced dBFS
        XCTAssertLessThan(db[kiloBand - 1], db[kiloBand] - 20)
        XCTAssertLessThan(db[kiloBand + 1], db[kiloBand] - 20)
    }

    func testStreamingPathOverlapAndLevel() {
        let rta = RTAAnalyzer(sampleRate: 48_000)
        XCTAssertEqual(rta.hop, 1024)                                        // 75 % overlap of 4096
        let produced = rta.process(sine(1000, amplitude: 1, sampleRate: 48_000, count: 48_000))
        XCTAssertEqual(produced, (48_000 - 4096) / 1024 + 1, accuracy: 1)
        XCTAssertTrue(rta.hasData)
        XCTAssertEqual(Double(rta.bandDB[kiloBand]), 0, accuracy: 1.0)       // full-scale sine reads 0 dB
        XCTAssertEqual(rta.bandBytes()[kiloBand], MeterScale.byte(fromDB: Double(rta.bandDB[kiloBand])))
        rta.reset()
        XCTAssertFalse(rta.hasData)
        XCTAssertEqual(rta.spectraAnalyzed, 0)
    }

    func testPinkNoiseIsRoughlyFlat() {
        let rate = 44_100.0
        let rta = RTAAnalyzer(sampleRate: rate)
        rta.process(pinkNoise(count: Int(rate * 8)))
        let db = rta.averageDB
        let indices = RTAFrame.bandCenters.indices.filter { (100...10_000).contains(RTAFrame.bandCenters[$0]) }
        let values = indices.map { Double(db[$0]) }.sorted()
        let median = values[values.count / 2]
        for i in indices {
            XCTAssertEqual(Double(db[i]), median, accuracy: 2.5, "band \(RTAFrame.bandCenters[i]) Hz")
        }
    }

    func testWhiteNoiseRisesThreeDBPerOctave() {
        let rta = RTAAnalyzer(sampleRate: 48_000)
        rta.process(whiteNoise(count: 48_000 * 6))
        let db = rta.averageDB
        let eightK = RTAFrame.bandCenters.firstIndex { abs($0 - 8000) < 0.01 }!
        XCTAssertEqual(Double(db[eightK] - db[kiloBand]), 9.03, accuracy: 1.5)   // 3 octaves × 3 dB
    }

    func testBandEdgesAreContiguousAndCoverRange() {
        let edges = RTAAnalyzer.bandEdges()
        XCTAssertEqual(edges.count, 59)
        for i in 1..<edges.count {
            XCTAssertEqual(edges[i].lo, edges[i - 1].hi, accuracy: edges[i].lo * 1e-9)
        }
        XCTAssertLessThan(edges.first!.lo, 21)         // first centre is 22.1 Hz (fixed by RTAFrame)
        XCTAssertGreaterThan(edges.last!.hi, 18_000)
        // Every band gets at least part of a bin, even the narrow ones at the bottom.
        let weights = RTAAnalyzer.makeBandWeights(sampleRate: 48_000, fftSize: RTAAnalyzer.fftSize)
        XCTAssertTrue(weights.allSatisfy { !$0.isEmpty })
    }

    func testPeakAndRMSBytes() {
        let full = LevelDSP.levels(of: sine(1000, amplitude: 1, sampleRate: 48_000, count: 4800))
        XCTAssertEqual(full.peak, 255)
        XCTAssertEqual(Int(full.rms), 244, accuracy: 1)                    // −3.01 dB
        let half = LevelDSP.levels(of: sine(1000, amplitude: 0.5, sampleRate: 48_000, count: 4800))
        XCTAssertEqual(Int(half.peak), 234, accuracy: 1)                   // −6.02 dB
        XCTAssertEqual(Int(half.rms), 223, accuracy: 1)                    // −9.03 dB
        XCTAssertEqual(LevelDSP.levels(of: [Float](repeating: 0, count: 100)).peak, 0)
        XCTAssertEqual(LevelDSP.levels(of: []).rms, 0)
    }

    func testAccumulatorPeakHoldDecays() {
        let acc = LevelAccumulator()
        acc.configure(channels: 2)
        var loud: [Float] = [0.1, -1.0, 0.5, 0.0]
        loud.withUnsafeMutableBufferPointer { acc.add(channel: 0, samples: $0.baseAddress!, stride: 1, frames: 4) }
        let first = acc.take(now: 0)
        XCTAssertEqual(first.peak, [255, 0])
        let quiet = [Float](repeating: 0, count: 64)
        quiet.withUnsafeBufferPointer { acc.add(channel: 0, samples: $0.baseAddress!, stride: 1, frames: 64) }
        let second = acc.take(now: 1)
        XCTAssertEqual(Int(second.peak[0]), Int(MeterScale.byte(fromDB: -24)), accuracy: 1)   // 24 dB/s fall-back
        XCTAssertEqual(second.rms[0], 0)
        // Interleaved stereo: channel 1 reads every second sample.
        var stereo: [Float] = [0, 0.5, 0, -0.5, 0, 0.25]
        stereo.withUnsafeMutableBufferPointer { acc.add(channel: 1, samples: $0.baseAddress! + 1, stride: 2, frames: 3) }
        XCTAssertEqual(Int(acc.take(now: 2).peak[1]), Int(MeterScale.byte(fromDB: -6.02)), accuracy: 1)
    }

    func testSampleFIFOOverflowKeepsNewest() {
        let fifo = SampleFIFO(capacity: 4)
        let a: [Float] = [1, 2, 3]
        a.withUnsafeBufferPointer { fifo.write($0.baseAddress!, count: 3) }
        XCTAssertEqual(fifo.drain(), [1, 2, 3])
        let b: [Float] = [4, 5, 6, 7, 8, 9]
        b.withUnsafeBufferPointer { fifo.write($0.baseAddress!, count: 4) }
        let c: [Float] = [10, 11]
        c.withUnsafeBufferPointer { fifo.write($0.baseAddress!, count: 2) }
        XCTAssertEqual(fifo.drain(), [6, 7, 10, 11])
        XCTAssertEqual(fifo.drain(), [])
    }
}

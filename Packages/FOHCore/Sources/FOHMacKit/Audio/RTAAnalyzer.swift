#if os(macOS)
import Accelerate
import Foundation
import FOHCore

/// Real-time analyser maths, independent of audio I/O so it can be tested with synthetic signals.
///
/// A 4096-point Hann-windowed FFT runs every `hop` samples (75% overlap). Bin powers are normalised so they
/// sum to the signal's mean square (Parseval, window-compensated), then integrated into the 1/6-octave bands
/// of `RTAFrame.bandCenters` (edges at centre × 2^(±1/12)), counting the fraction of each bin inside a band so
/// narrow low bands still get a value. Levels are sine-referenced dBFS: a full-scale sine reads 0 dB in its band.
public final class RTAAnalyzer {
    public static let fftSize = 4096
    static let log2n = vDSP_Length(12)

    public let sampleRate: Double
    public let hop: Int
    /// Weight of each new spectrum in the running (power-domain) smoothing. 1 = no smoothing.
    public var smoothing: Float = 0.35

    private let setup: FFTSetup
    private var window: [Float]
    private let windowPowerSum: Float
    private var ring: [Float]
    private var ringIndex = 0
    private var filled = 0
    private var sinceHop = 0
    private let bandWeights: [[(bin: Int, weight: Float)]]
    private var smoothedPower: [Float]?
    private var averagePower: [Float]
    private var averageCount = 0

    /// Spectra computed since creation or `reset()`.
    public private(set) var spectraAnalyzed = 0

    public init(sampleRate: Double, overlap: Double = 0.75) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        let n = Self.fftSize
        hop = max(1, Int(Double(n) * (1 - overlap)))
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        window = w
        var s: Float = 0
        vDSP_svesq(w, 1, &s, vDSP_Length(n))
        windowPowerSum = s
        ring = [Float](repeating: 0, count: n)
        averagePower = [Float](repeating: 0, count: RTAFrame.bandCenters.count)
        bandWeights = Self.makeBandWeights(sampleRate: self.sampleRate, fftSize: n)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Band edges in Hz, contiguous: each band's `hi` is the next band's `lo`.
    public static func bandEdges() -> [(lo: Double, hi: Double)] {
        let r = pow(2, 1.0 / 12)
        return RTAFrame.bandCenters.map { ($0 / r, $0 * r) }
    }

    static func makeBandWeights(sampleRate: Double, fftSize n: Int) -> [[(bin: Int, weight: Float)]] {
        let df = sampleRate / Double(n)
        return bandEdges().map { band in
            var weights: [(Int, Float)] = []
            let first = max(1, Int((band.lo / df).rounded(.down)))
            let last = min(n / 2 - 1, Int((band.hi / df).rounded(.up)))
            guard first <= last else { return [] }
            for k in first...last {
                let binLo = (Double(k) - 0.5) * df, binHi = (Double(k) + 0.5) * df
                let overlap = min(binHi, band.hi) - max(binLo, band.lo)
                if overlap > 0 { weights.append((k, Float(overlap / df))) }
            }
            return weights
        }
    }

    public func reset() {
        for i in ring.indices { ring[i] = 0 }
        ringIndex = 0
        filled = 0
        sinceHop = 0
        smoothedPower = nil
        resetAverage()
        spectraAnalyzed = 0
    }

    public func resetAverage() {
        for i in averagePower.indices { averagePower[i] = 0 }
        averageCount = 0
    }

    /// Feed mono samples. Returns how many new spectra were computed.
    @discardableResult
    public func process(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return 0 }
            return process(base, count: p.count)
        }
    }

    @discardableResult
    public func process(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        let n = Self.fftSize
        var produced = 0
        var i = 0
        while i < count {
            let take = min(hop - sinceHop, count - i)
            for j in 0..<take {
                ring[ringIndex] = samples[i + j]
                ringIndex = (ringIndex + 1) % n
            }
            i += take
            sinceHop += take
            filled = min(n, filled + take)
            if sinceHop >= hop {
                sinceHop = 0
                if filled == n {
                    analyzeRing()
                    produced += 1
                }
            }
        }
        return produced
    }

    /// Smoothed band levels in sine-referenced dBFS (−120 when empty).
    public var bandDB: [Float] { (smoothedPower ?? averagePower).map(Self.db) }

    /// Mean of every spectrum since `resetAverage()` (Welch average), in dB.
    public var averageDB: [Float] {
        averageCount > 0 ? averagePower.map { Self.db($0 / Float(averageCount)) } : averagePower.map { _ in -120 }
    }

    public var hasData: Bool { smoothedPower != nil }

    public func bandBytes() -> [UInt8] {
        bandDB.map { MeterScale.byte(fromDB: Double($0)) }
    }

    /// Band levels (dB, no smoothing) of exactly one block of `fftSize` samples, oldest first.
    public func spectrumDB(of block: [Float]) -> [Float] {
        precondition(block.count == Self.fftSize)
        return bandPowers(ofOrderedBlock: block).map(Self.db)
    }

    static func db(_ power: Float) -> Float {
        power > 0 ? max(-120, 10 * log10(2 * power)) : -120
    }

    private func analyzeRing() {
        let n = Self.fftSize
        var ordered = [Float](repeating: 0, count: n)
        let tail = n - ringIndex
        for j in 0..<tail { ordered[j] = ring[ringIndex + j] }
        for j in 0..<ringIndex { ordered[tail + j] = ring[j] }
        let power = bandPowers(ofOrderedBlock: ordered)
        spectraAnalyzed += 1
        for b in power.indices { averagePower[b] += power[b] }
        averageCount += 1
        if var s = smoothedPower {
            let a = smoothing
            for b in s.indices { s[b] = s[b] * (1 - a) + power[b] * a }
            smoothedPower = s
        } else {
            smoothedPower = power
        }
    }

    /// Per-band power (mean-square units) of one ordered block.
    private func bandPowers(ofOrderedBlock block: [Float]) -> [Float] {
        let n = Self.fftSize
        let half = n / 2
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(block, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // vDSP's real FFT output is 2× the DFT, so |X|² = mags / 4. One-sided, window-compensated power:
        // P_k = 2·|X_k|² / (N · Σw²) = mags_k / (2 · N · Σw²). Bin 0 packs DC and Nyquist; it's never used.
        let scale = 1 / (2 * Float(n) * windowPowerSum)
        return bandWeights.map { weights in
            var p: Float = 0
            for (bin, w) in weights { p += mags[bin] * scale * w }
            return p
        }
    }
}
#endif

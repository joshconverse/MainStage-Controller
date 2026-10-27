#if os(macOS)
import Accelerate
import CoreAudio
import Foundation
import os
import FOHCore

/// Pure level maths shared by the live meters and the tests.
public enum LevelDSP {
    /// Largest |x| over `count` samples, reading every `stride`-th value (interleaved buffers).
    public static func peak(_ samples: UnsafePointer<Float>, stride: Int = 1, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var result: Float = 0
        vDSP_maxmgv(samples, vDSP_Stride(stride), &result, vDSP_Length(count))
        return result
    }

    public static func sumOfSquares(_ samples: UnsafePointer<Float>, stride: Int = 1, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var result: Float = 0
        vDSP_svesq(samples, vDSP_Stride(stride), &result, vDSP_Length(count))
        return result
    }

    public static func rmsByte(sumOfSquares: Float, count: Int) -> UInt8 {
        count > 0 ? MeterScale.byte(fromLinear: (sumOfSquares / Float(count)).squareRoot()) : 0
    }

    /// (peak byte, RMS byte) of a whole mono signal.
    public static func levels(of samples: [Float]) -> (peak: UInt8, rms: UInt8) {
        samples.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress, !p.isEmpty else { return (0, 0) }
            return (MeterScale.byte(fromLinear: peak(base, count: p.count)),
                    rmsByte(sumOfSquares: sumOfSquares(base, count: p.count), count: p.count))
        }
    }
}

/// A tiny unfair lock that is safe to take briefly on the real-time audio thread.
final class UnfairLock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always) func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}

/// A value guarded by an unfair lock.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = UnfairLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func read() -> T { lock.withLock { value } }
    func write(_ newValue: T) { lock.withLock { value = newValue } }
}

/// Per-channel peak/RMS accumulated on the audio thread (allocation-free once configured) and turned into
/// meter bytes on the meter queue. Peaks fall back at `peakDecayDBPerSecond` so short transients stay visible.
final class LevelAccumulator: @unchecked Sendable {
    private let lock = UnfairLock()
    private var peak: [Float] = []
    private var sumSquares: [Float] = []
    private var count: [Int] = []
    private var heldPeakDB: [Double] = []
    private var lastTake: TimeInterval?
    var peakDecayDBPerSecond: Double = 24

    var channels: Int { lock.withLock { peak.count } }

    func configure(channels n: Int) {
        lock.withLock {
            peak = [Float](repeating: 0, count: n)
            sumSquares = [Float](repeating: 0, count: n)
            count = [Int](repeating: 0, count: n)
            heldPeakDB = [Double](repeating: -.infinity, count: n)
            lastTake = nil
        }
    }

    /// Real-time safe: no allocation; channels beyond the configured count are ignored.
    @inline(__always) func add(channel: Int, samples: UnsafePointer<Float>, stride: Int, frames: Int) {
        guard frames > 0 else { return }
        let p = LevelDSP.peak(samples, stride: stride, count: frames)
        let s = LevelDSP.sumOfSquares(samples, stride: stride, count: frames)
        lock.withLock {
            guard channel < peak.count else { return }
            if p > peak[channel] { peak[channel] = p }
            sumSquares[channel] += s
            count[channel] += frames
        }
    }

    /// Accumulate every channel of an audio buffer list (interleaved or not).
    func add(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        var channelBase = 0
        for buffer in list {
            let n = Int(buffer.mNumberChannels)
            guard n > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { channelBase += n; continue }
            let bufferFrames = min(frames, Int(buffer.mDataByteSize) / (4 * n))
            for k in 0..<n {
                add(channel: channelBase + k, samples: data + k, stride: n, frames: bufferFrames)
            }
            channelBase += n
        }
    }

    /// Bytes since the last take, then reset the window.
    func take(now: TimeInterval) -> (peak: [UInt8], rms: [UInt8]) {
        lock.withLock {
            let dt = lastTake.map { max(0, now - $0) } ?? 0
            lastTake = now
            var peaks = [UInt8](repeating: 0, count: peak.count)
            var rms = [UInt8](repeating: 0, count: peak.count)
            for c in 0..<peak.count {
                let blockDB = peak[c] > 0 ? 20 * log10(Double(peak[c])) : -Double.infinity
                let decayed = heldPeakDB[c] - peakDecayDBPerSecond * dt
                heldPeakDB[c] = max(blockDB, decayed)
                peaks[c] = MeterScale.byte(fromDB: heldPeakDB[c])
                rms[c] = LevelDSP.rmsByte(sumOfSquares: sumSquares[c], count: count[c])
                peak[c] = 0
                sumSquares[c] = 0
                count[c] = 0
            }
            return (peaks, rms)
        }
    }
}

/// Lock-protected ring of mono samples: written on the audio thread, drained on the analysis queue.
final class SampleFIFO: @unchecked Sendable {
    private let lock = UnfairLock()
    private var buffer: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0

    init(capacity: Int) {
        buffer = [Float](repeating: 0, count: capacity)
    }

    /// Real-time safe. Overwrites the oldest samples when full.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        lock.withLock {
            let cap = buffer.count
            for i in 0..<min(count, cap) {
                buffer[writeIndex] = samples[i]
                writeIndex = (writeIndex + 1) % cap
            }
            available = min(cap, available + count)
            if available == cap { readIndex = writeIndex }
        }
    }

    func drain() -> [Float] {
        lock.withLock {
            guard available > 0 else { return [] }
            var out = [Float](repeating: 0, count: available)
            let cap = buffer.count
            for i in 0..<available { out[i] = buffer[(readIndex + i) % cap] }
            readIndex = (readIndex + available) % cap
            available = 0
            return out
        }
    }

    func clear() {
        lock.withLock { readIndex = writeIndex; available = 0 }
    }
}
#endif

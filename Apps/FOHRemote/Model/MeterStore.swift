import Foundation
import Observation
import FOHCore

/// Meter and RTA levels, kept apart from `MixerStore` so 25 Hz updates only redraw the meter views.
@MainActor
@Observable
final class MeterStore {
    struct Level: Equatable {
        var peak: Double
        var rms: Double
        var hold: Double
    }

    private(set) var frame = MeterFrame()
    private(set) var rta: RTAFrame?
    private(set) var inputHold: [UInt8] = []
    private(set) var outputHold: [UInt8] = []

    /// Strip key whose RTA the demo generator should produce (live RTA comes from the bridge).
    @ObservationIgnored var demoRTAStrip: String?
    @ObservationIgnored private var inputHoldAt: [Date] = []
    @ObservationIgnored private var outputHoldAt: [Date] = []
    @ObservationIgnored private var demoTimer: Timer?
    @ObservationIgnored private var demoPhase = 0.0
    @ObservationIgnored private var demoInputs = 0
    @ObservationIgnored private var demoOutputs = 0
    @ObservationIgnored private var demoRTABands: [Double] = []

    var isDemoRunning: Bool { demoTimer != nil }

    func update(_ f: MeterFrame) {
        frame = f
        let now = Date()
        Self.stepHold(&inputHold, &inputHoldAt, f.inputPeak, now)
        Self.stepHold(&outputHold, &outputHoldAt, f.outputPeak, now)
    }

    func updateRTA(_ r: RTAFrame) { rta = r }

    func clear() {
        frame = MeterFrame()
        rta = nil
        inputHold = []; outputHold = []
        inputHoldAt = []; outputHoldAt = []
    }

    private static func stepHold(_ hold: inout [UInt8], _ at: inout [Date], _ peaks: [UInt8], _ now: Date) {
        if hold.count != peaks.count { hold = peaks; at = Array(repeating: now, count: peaks.count); return }
        for i in peaks.indices where peaks[i] >= hold[i] || now.timeIntervalSince(at[i]) > 1.5 {
            hold[i] = peaks[i]
            at[i] = now
        }
    }

    private static func frac(_ a: [UInt8], _ i: Int) -> Double { i < a.count ? MeterScale.fraction(a[i]) : 0 }

    /// One level per channel for a strip (hardware inputs for inputs, MainStage outputs for outputs);
    /// nil when the strip has no meter source (FX returns, unrouted outputs).
    func levels(for strip: Strip) -> [Level]? {
        let inCh = strip.hardwareInputChannels
        if !inCh.isEmpty {
            return inCh.map { Level(peak: Self.frac(frame.inputPeak, $0), rms: Self.frac(frame.inputRMS, $0), hold: Self.frac(inputHold, $0)) }
        }
        let outCh = strip.hardwareOutputChannels
        if !outCh.isEmpty {
            return outCh.map { Level(peak: Self.frac(frame.outputPeak, $0), rms: Self.frac(frame.outputRMS, $0), hold: Self.frac(outputHold, $0)) }
        }
        return nil
    }

    /// Master meter: the Main output strip's channels, else the first two MainStage outputs.
    func masterLevels(_ config: ShowConfig) -> [Level]? {
        if let main = config.strips.first(where: { $0.ref.kind == .output && !$0.hardwareOutputChannels.isEmpty }) {
            return levels(for: main)
        }
        guard !frame.outputPeak.isEmpty else { return nil }
        return (0..<min(2, frame.outputPeak.count)).map {
            Level(peak: Self.frac(frame.outputPeak, $0), rms: Self.frac(frame.outputRMS, $0), hold: Self.frac(outputHold, $0))
        }
    }

    /// Peak dBFS for a strip (loudest channel), for the estimated-GR meter.
    func peakDB(for strip: Strip) -> Double? {
        guard let l = levels(for: strip), let maxPeak = l.map(\.peak).max(), maxPeak > 0 else { return nil }
        return MeterScale.floorDB + maxPeak * -MeterScale.floorDB
    }

    // MARK: Demo

    /// Gently animated meters and RTA for the offline demo show.
    func startDemo(_ config: ShowConfig) {
        demoInputs = (config.strips.flatMap(\.hardwareInputChannels).max() ?? -1) + 1
        demoOutputs = max((config.strips.flatMap(\.hardwareOutputChannels).max() ?? -1) + 1, 2)
        guard demoTimer == nil else { return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.demoTick() }
        }
    }

    func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        clear()
    }

    private func demoTick() {
        demoPhase += 1.0 / 25
        let t = demoPhase
        func level(_ base: Double, _ speed: Double, _ seed: Double) -> (UInt8, UInt8) {
            let rms = base + 5 * sin(t * speed + seed) + 2 * sin(t * speed * 3.1 + seed * 2)
            let peak = rms + 6 + Double.random(in: 0...3)
            return (MeterScale.byte(fromDB: peak), MeterScale.byte(fromDB: rms))
        }
        let inBases = [-17.0, -21, -24, -26]
        let ins = (0..<demoInputs).map { level(inBases[$0 % inBases.count], 1.3 + Double($0) * 0.4, Double($0)) }
        let outs = (0..<demoOutputs).map { level(-14, 0.9, Double($0) * 0.3) }
        update(MeterFrame(inputPeak: ins.map(\.0), inputRMS: ins.map(\.1), outputPeak: outs.map(\.0), outputRMS: outs.map(\.1)))

        guard let strip = demoRTAStrip else { return }
        if demoRTABands.count != RTAFrame.bandCenters.count { demoRTABands = Array(repeating: -60, count: RTAFrame.bandCenters.count) }
        for (i, f) in RTAFrame.bandCenters.enumerated() {
            // A voice-ish spectrum: rising to ~250 Hz, presence around 3 kHz, rolling off above 8 kHz.
            let lf = -18 * pow(max(0, log2(220 / f)), 1.2)
            let hf = -9 * max(0, log2(f / 2500))
            let presence = 4 * exp(-pow(log2(f / 3000), 2) * 2)
            let target = -24 + lf + hf + presence + 4 * sin(t * 2.2 + Double(i) * 0.35) + Double.random(in: -2...2)
            demoRTABands[i] = demoRTABands[i] * 0.6 + target * 0.4
        }
        updateRTA(RTAFrame(strip: strip, bands: demoRTABands.map { MeterScale.byte(fromDB: $0) }))
    }
}

import SwiftUI
import FOHCore

/// One EQ section as drawn on the graph, derived from a strip's bound roles.
struct EQBand: Identifiable, Equatable {
    enum Kind: Equatable { case peak, lowShelf, highShelf, highPass, lowPass, notch, bandPass, tiltShelf, flatTilt }

    /// "hpf", "lpf", "band.1"…"band.4"
    let id: String
    let label: String
    var kind: Kind
    var freq: Double
    var gain: Double
    var q: Double
    var slope: Double
    var enabled: Bool

    var hasGain: Bool { ![.highPass, .lowPass, .notch, .bandPass].contains(kind) }
}

/// RBJ biquad magnitudes at 48 kHz — the same math as the design canvas.
enum EQMath {
    static let fs = 48000.0
    static let fMin = 20.0, fMax = 20000.0

    static func biquadDB(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double, _ w: Double) -> Double {
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }

    static func magnitudeDB(_ band: EQBand, at f: Double) -> Double {
        guard band.enabled else { return 0 }
        let w = 2 * Double.pi * f / fs, w0 = 2 * Double.pi * min(band.freq, fs * 0.45) / fs
        let cw = cos(w0), sw = sin(w0)
        switch band.kind {
        case .highPass, .lowPass:
            // One 12 dB/oct section scaled to the slope; `q` is its resonance (0.707 = none).
            let al = sw / (2 * max(band.q, 0.1))
            let k = band.kind == .highPass ? [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2] : [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
            return biquadDB(k[0], k[1], k[2], 1 + al, -2 * cw, 1 - al, w) * (band.slope / 12)
        case .notch, .bandPass:
            let al = sw / (2 * max(band.q, 0.05))
            if band.kind == .notch { return biquadDB(1, -2 * cw, 1, 1 + al, -2 * cw, 1 - al, w) }
            return biquadDB(al, 0, -al, 1 + al, -2 * cw, 1 - al, w)
        case .tiltShelf:
            // Half the gain each way around the frequency: lows down, highs up for a positive gain.
            var low = band, high = band
            low.kind = .lowShelf; low.gain = -band.gain / 2
            high.kind = .highShelf; high.gain = band.gain / 2
            return magnitudeDB(low, at: f) + magnitudeDB(high, at: f)
        case .flatTilt:
            // A straight tilt through the frequency, reaching ± half the gain three decades apart.
            let t = log10(f / max(band.freq, 1)) / 3
            return max(-abs(band.gain), min(abs(band.gain), band.gain * t))
        case .peak:
            let A = pow(10, band.gain / 40), al = sw / (2 * max(band.q, 0.05))
            return biquadDB(1 + al * A, -2 * cw, 1 - al * A, 1 + al / A, -2 * cw, 1 - al / A, w)
        case .lowShelf, .highShelf:
            let A = pow(10, band.gain / 40), al = sw / (2 * max(band.q, 0.05)), sA = 2 * sqrt(A) * al
            if band.kind == .lowShelf {
                return biquadDB(A * ((A + 1) - (A - 1) * cw + sA), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - sA),
                                (A + 1) + (A - 1) * cw + sA, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - sA, w)
            }
            return biquadDB(A * ((A + 1) + (A - 1) * cw + sA), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - sA),
                            (A + 1) - (A - 1) * cw + sA, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - sA, w)
        }
    }

    static func response(_ bands: [EQBand], at f: Double) -> Double {
        bands.reduce(0) { $0 + magnitudeDB($1, at: f) }
    }

    // Log-frequency ↔ x mapping.
    static func x(for f: Double, width: CGFloat) -> CGFloat {
        CGFloat(log10(f / fMin) / log10(fMax / fMin)) * width
    }

    static func freq(forX x: CGFloat, width: CGFloat) -> Double {
        fMin * pow(fMax / fMin, Double(max(0, min(1, x / width))))
    }

    static func y(for db: Double, height: CGFloat, range: Double) -> CGFloat {
        height / 2 - CGFloat(db / range) * (height / 2)
    }

    static func db(forY y: CGFloat, height: CGFloat, range: Double) -> Double {
        Double((height / 2 - y) / (height / 2)) * range
    }

    static func curve(_ bands: [EQBand], size: CGSize, range: Double, points: Int = 160) -> Path {
        var path = Path()
        for i in 0..<points {
            let t = Double(i) / Double(points - 1)
            let f = fMin * pow(fMax / fMin, t)
            let db = max(-range * 1.2, min(range * 1.2, response(bands, at: f)))
            let p = CGPoint(x: CGFloat(t) * size.width, y: y(for: db, height: size.height, range: range))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

extension MixerStore {
    /// Short section name from the bound parameter ("LMF Gain" → "LMF"), else "Band n".
    private func bandLabel(_ strip: StripRef, _ n: Int) -> String {
        for p in ["gain", "freq"] {
            if let name = Role.band(n, p).flatMap({ binding(strip, $0) })?.parameterName,
               let first = name.split(separator: " ").first, first.count <= 4, name.contains(" ") {
                return String(first)
            }
        }
        return "Band \(n)"
    }

    /// The EQ bands a strip's binding provides, in graph order (HPF, bands, LPF).
    func eqBands(_ strip: StripRef) -> [EQBand] {
        var bands: [EQBand] = []
        let isSSL = config.binding(strip).roles.values.contains { $0.pluginName.localizedCaseInsensitiveContains("SSL") }
        if let r = Role["eq.hpfFreq"], isBound(strip, r) {
            let f = numeric(strip, r)
            let slope = Role["eq.hpfSlope"].flatMap { isBound(strip, $0) ? numeric(strip, $0) : nil } ?? (isSSL ? 18 : 12)
            let on = Role["eq.hpfOn"].map { isBound(strip, $0) ? isOn(strip, $0) : true } ?? true
            bands.append(EQBand(id: "hpf", label: "HPF", kind: .highPass, freq: f ?? 20, gain: 0, q: 0.707, slope: slope,
                                enabled: on && f != nil))
        }
        for n in 1...4 {
            guard let fr = Role.band(n, "freq"), let gr = Role.band(n, "gain"), isBound(strip, fr) || isBound(strip, gr) else { continue }
            var kind: EQBand.Kind = .peak
            if n == 1 || n == 4 {
                let shelf: EQBand.Kind = n == 1 ? .lowShelf : .highShelf
                if let t = Role.band(n, "type"), isBound(strip, t) { kind = isOn(strip, t) ? .peak : shelf } else { kind = shelf }
            }
            let defaultQ = kind == .peak ? 1.0 : 0.7071
            let q = Role.band(n, "q").flatMap { isBound(strip, $0) ? numeric(strip, $0) : nil } ?? defaultQ
            let on = Role.band(n, "on").map { isBound(strip, $0) ? isOn(strip, $0) : true } ?? true
            bands.append(EQBand(id: "band.\(n)", label: bandLabel(strip, n), kind: kind,
                                freq: numeric(strip, fr) ?? [100, 400, 2500, 10000][n - 1],
                                gain: numeric(strip, gr) ?? 0, q: q, slope: 12, enabled: on))
        }
        if let r = Role["eq.lpfFreq"], isBound(strip, r) {
            let f = numeric(strip, r)
            let on = Role["eq.lpfOn"].map { isBound(strip, $0) ? isOn(strip, $0) : true } ?? true
            bands.append(EQBand(id: "lpf", label: "LPF", kind: .lowPass, freq: f ?? 20000, gain: 0, q: 0.707, slope: 12,
                                enabled: on && f != nil))
        }
        return bands
    }

    /// EQ engaged (EQ on role, or true if unbound).
    func eqEngaged(_ strip: StripRef) -> Bool { isBound(strip, .eqOn) ? isOn(strip, .eqOn) : true }

    /// Short label for the plugin driving a strip's EQ ("SSL", "PRO-Q").
    func eqSourceLabel(_ strip: Strip) -> String {
        guard let name = strip.plugin(at: strip.processing.eq)?.name else { return "" }
        return Self.abbreviate(name)
    }

    static func abbreviate(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("ssl") { return "SSL" }
        if n.contains("tune") { return "TUNE" }
        if n.contains("pro-q") { return "PRO-Q" }
        if n.contains("space designer") { return "SPACE D" }
        if n.contains("channel eq") { return "CH EQ" }
        return String(name.split(separator: " ").first ?? "").uppercased().prefix(7).description
    }
}

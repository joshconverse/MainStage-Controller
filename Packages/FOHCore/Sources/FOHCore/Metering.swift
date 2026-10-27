import Foundation

/// Meter levels travel as one byte per channel: 0 = −72 dBFS (or below), 255 = 0 dBFS, linear in dB (~0.28 dB/step).
public enum MeterScale {
    public static let floorDB: Double = -72

    public static func byte(fromDB db: Double) -> UInt8 {
        guard db.isFinite else { return db > 0 ? 255 : 0 }
        let clamped = min(0, max(floorDB, db))
        return UInt8(((clamped - floorDB) / -floorDB * 255).rounded())
    }

    public static func byte(fromLinear amplitude: Float) -> UInt8 {
        amplitude <= 0 ? 0 : byte(fromDB: 20 * log10(Double(amplitude)))
    }

    public static func db(fromByte b: UInt8) -> Double {
        b == 0 ? -.infinity : floorDB + Double(b) / 255 * -floorDB
    }

    /// 0…1 for drawing a meter bar.
    public static func fraction(_ b: UInt8) -> Double { Double(b) / 255 }
}

/// One meter update from the bridge (~25 Hz): peak and RMS per hardware input channel (the bridge's input tap,
/// pre-everything) and per MainStage output channel (the Core Audio process tap on MainStage).
public struct MeterFrame: Hashable, Sendable {
    public var inputPeak: [UInt8]
    public var inputRMS: [UInt8]
    public var outputPeak: [UInt8]
    public var outputRMS: [UInt8]

    public init(inputPeak: [UInt8] = [], inputRMS: [UInt8] = [], outputPeak: [UInt8] = [], outputRMS: [UInt8] = []) {
        self.inputPeak = inputPeak
        self.inputRMS = inputRMS
        self.outputPeak = outputPeak
        self.outputRMS = outputRMS
    }

    static let version: UInt8 = 1

    /// `[version][nIn u16][nOut u16][inPeak…][inRMS…][outPeak…][outRMS…]`
    public func encoded() -> Data {
        var d = Data([Self.version])
        d.appendBigEndian(UInt16(inputPeak.count))
        d.appendBigEndian(UInt16(outputPeak.count))
        d.append(contentsOf: inputPeak)
        d.append(contentsOf: pad(inputRMS, inputPeak.count))
        d.append(contentsOf: outputPeak)
        d.append(contentsOf: pad(outputRMS, outputPeak.count))
        return d
    }

    private func pad(_ a: [UInt8], _ n: Int) -> [UInt8] {
        a.count >= n ? Array(a.prefix(n)) : a + [UInt8](repeating: 0, count: n - a.count)
    }

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 5, b[0] == Self.version else { return nil }
        let nIn = Int(b[1]) << 8 | Int(b[2]), nOut = Int(b[3]) << 8 | Int(b[4])
        guard b.count >= 5 + 2 * nIn + 2 * nOut else { return nil }
        var i = 5
        func take(_ n: Int) -> [UInt8] { defer { i += n }; return Array(b[i..<(i + n)]) }
        inputPeak = take(nIn)
        inputRMS = take(nIn)
        outputPeak = take(nOut)
        outputRMS = take(nOut)
    }

    /// Peak for a strip: the loudest of its hardware input channels (inputs) or output channels (outputs).
    public func peak(for strip: Strip) -> [UInt8]? {
        let inCh = strip.hardwareInputChannels
        if !inCh.isEmpty { return inCh.map { $0 < inputPeak.count ? inputPeak[$0] : 0 } }
        let outCh = strip.hardwareOutputChannels
        if !outCh.isEmpty { return outCh.map { $0 < outputPeak.count ? outputPeak[$0] : 0 } }
        return nil
    }
}

/// A real-time analyser frame for one strip's input: 1/6-octave bands, one byte each on the meter scale.
public struct RTAFrame: Hashable, Sendable {
    public var strip: String
    public var bands: [UInt8]

    public init(strip: String, bands: [UInt8]) {
        self.strip = strip
        self.bands = bands
    }

    /// 1/6-octave centres from ~20 Hz to ~18 kHz (59 bands), relative to 1 kHz.
    public static let bandCenters: [Double] = (-33...25).map { 1000 * pow(2, Double($0) / 6) }

    public func message() -> OSCMessage {
        OSCMessage(FOHProtocol.Path.rta, [.string(strip), .blob(Data(bands))])
    }

    public init?(_ message: OSCMessage) {
        guard message.arguments.count >= 2, let s = message.arguments[0].stringValue, let d = message.arguments[1].blobValue else { return nil }
        self.init(strip: s, bands: [UInt8](d))
    }
}

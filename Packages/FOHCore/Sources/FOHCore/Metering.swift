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

/// Peak and RMS per channel of one strip, measured by the FOH Meter plugin inside MainStage.
public struct StripLevels: Hashable, Sendable {
    public var peak: [UInt8]
    public var rms: [UInt8]

    public init(peak: [UInt8], rms: [UInt8]) {
        self.peak = peak
        self.rms = rms
    }
}

/// One meter update from the bridge (~25 Hz): peak and RMS per hardware input channel (the bridge's input tap,
/// pre-everything), per MainStage output channel (the Core Audio process tap on MainStage), and per strip that has a
/// FOH Meter plugin on it (Apps/FOHMeter; this is how FX returns get meters).
public struct MeterFrame: Hashable, Sendable {
    public var inputPeak: [UInt8]
    public var inputRMS: [UInt8]
    public var outputPeak: [UInt8]
    public var outputRMS: [UInt8]
    /// Strip key → FOH Meter levels.
    public var strips: [String: StripLevels]

    public init(inputPeak: [UInt8] = [], inputRMS: [UInt8] = [], outputPeak: [UInt8] = [], outputRMS: [UInt8] = [],
                strips: [String: StripLevels] = [:]) {
        self.inputPeak = inputPeak
        self.inputRMS = inputRMS
        self.outputPeak = outputPeak
        self.outputRMS = outputRMS
        self.strips = strips
    }

    static let version: UInt8 = 1
    static let stripsTag: UInt8 = 0x53   // "S"

    /// `[version][nIn u16][nOut u16][inPeak…][inRMS…][outPeak…][outRMS…]`, then, when there are plugin meters,
    /// `["S"][nStrips u8]{[keyLen u8][key][nCh u8][peak…][rms…]}`. Older clients stop reading before the trailer.
    public func encoded() -> Data {
        var d = Data([Self.version])
        d.appendBigEndian(UInt16(inputPeak.count))
        d.appendBigEndian(UInt16(outputPeak.count))
        d.append(contentsOf: inputPeak)
        d.append(contentsOf: pad(inputRMS, inputPeak.count))
        d.append(contentsOf: outputPeak)
        d.append(contentsOf: pad(outputRMS, outputPeak.count))
        let entries = strips.sorted { $0.key < $1.key }.compactMap { key, levels -> (Data, StripLevels)? in
            let k = Data(key.utf8)
            return k.count <= 255 ? (k, levels) : nil
        }.prefix(255)
        guard !entries.isEmpty else { return d }
        d.append(contentsOf: [Self.stripsTag, UInt8(entries.count)])
        for (key, levels) in entries {
            let n = min(levels.peak.count, 255)
            d.append(UInt8(key.count))
            d.append(key)
            d.append(UInt8(n))
            d.append(contentsOf: levels.peak.prefix(n))
            d.append(contentsOf: pad(levels.rms, n))
        }
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
        strips = Self.decodeStrips(b, from: i)
    }

    /// The plugin-meter trailer; a malformed one is dropped without losing the hardware meters.
    private static func decodeStrips(_ b: [UInt8], from start: Int) -> [String: StripLevels] {
        guard start + 2 <= b.count, b[start] == stripsTag else { return [:] }
        var i = start + 2
        var result: [String: StripLevels] = [:]
        for _ in 0..<Int(b[start + 1]) {
            guard i < b.count else { return [:] }
            let keyLength = Int(b[i])
            guard i + 1 + keyLength < b.count else { return [:] }
            let key = String(decoding: b[(i + 1)..<(i + 1 + keyLength)], as: UTF8.self)
            i += 1 + keyLength
            let n = Int(b[i])
            guard i + 1 + 2 * n <= b.count else { return [:] }
            result[key] = StripLevels(peak: Array(b[(i + 1)..<(i + 1 + n)]), rms: Array(b[(i + 1 + n)..<(i + 1 + 2 * n)]))
            i += 1 + 2 * n
        }
        return result
    }

    /// Peak for a strip: its FOH Meter plugin if it has one (you put it there on purpose), else the loudest of its
    /// hardware input channels (inputs) or output channels (outputs).
    public func peak(for strip: Strip) -> [UInt8]? {
        if let levels = strips[strip.id] { return levels.peak }
        let inCh = strip.hardwareInputChannels
        if !inCh.isEmpty { return inCh.map { $0 < inputPeak.count ? inputPeak[$0] : 0 } }
        let outCh = strip.hardwareOutputChannels
        if !outCh.isEmpty { return outCh.map { $0 < outputPeak.count ? outputPeak[$0] : 0 } }
        return nil
    }
}

/// One reading from the FOH Meter plugin (Apps/FOHMeter), sent over UDP to the bridge on this Mac
/// (`FOHProtocol.pluginMeterPort`, loopback only) ~25 times a second while MainStage renders the instance:
/// `/foh/meter/plugin ,sibb contextName instanceID peak(float32[] BE) meanSquare(float32[] BE)`.
/// The context name is MainStage's name for the channel strip.
public struct PluginMeterPacket: Hashable, Sendable {
    public var contextName: String
    public var instance: UInt32
    /// Linear peak (|sample|) and mean square per channel since the previous packet.
    public var peak: [Float]
    public var meanSquare: [Float]

    public init(contextName: String, instance: UInt32, peak: [Float], meanSquare: [Float]) {
        self.contextName = contextName
        self.instance = instance
        self.peak = peak
        self.meanSquare = meanSquare
    }

    /// Plenty for any channel strip; anything longer is not from the plugin.
    static let maxChannels = 64

    public init?(_ message: OSCMessage) {
        guard message.address == FOHProtocol.Path.pluginMeter, message.arguments.count >= 4,
              let name = message.arguments[0].stringValue, let id = message.arguments[1].intValue,
              let peak = message.arguments[2].blobValue.flatMap(Self.floats),
              let meanSquare = message.arguments[3].blobValue.flatMap(Self.floats),
              !peak.isEmpty, peak.count == meanSquare.count else { return nil }
        self.init(contextName: name, instance: UInt32(truncatingIfNeeded: id), peak: peak, meanSquare: meanSquare)
    }

    public func message() -> OSCMessage {
        OSCMessage(FOHProtocol.Path.pluginMeter, [.string(contextName), .int(Int32(bitPattern: instance)),
                                                   .blob(Self.data(peak)), .blob(Self.data(meanSquare))])
    }

    private static func floats(_ d: Data) -> [Float]? {
        guard d.count % 4 == 0, d.count / 4 <= maxChannels else { return nil }
        let b = [UInt8](d)
        return stride(from: 0, to: b.count, by: 4).map {
            Float(bitPattern: UInt32(b[$0]) << 24 | UInt32(b[$0 + 1]) << 16 | UInt32(b[$0 + 2]) << 8 | UInt32(b[$0 + 3]))
        }
    }

    private static func data(_ values: [Float]) -> Data {
        var d = Data()
        for v in values { d.appendBigEndian(v.bitPattern) }
        return d
    }
}

extension ShowConfig {
    /// The strip a FOH Meter plugin is on. MainStage gives the plugin its channel strip's name, so match that against
    /// each strip's MainStage name, then its FOH name (ignoring case), then the longest of those the context name
    /// contains. If nothing matches and exactly one strip has FOH Meter in its plugin chain (known once the concert
    /// has been read), it's that one.
    public func stripForPluginMeter(contextName: String) -> Strip? {
        let name = contextName.trimmingCharacters(in: .whitespaces).lowercased()
        func names(_ s: Strip) -> [String] {
            [s.mainStage?.stripName, s.name].compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        if !name.isEmpty {
            if let s = strips.first(where: { $0.mainStage.map { $0.stripName.lowercased() == name } ?? false }) { return s }
            if let s = strips.first(where: { $0.name.lowercased() == name }) { return s }
            let contained = strips.compactMap { s in names(s).filter { $0.count >= 3 && name.contains($0) }.map(\.count).max().map { (s, $0) } }
            if let best = contained.max(by: { $0.1 < $1.1 }) { return best.0 }
        }
        let withPlugin = strips.filter { $0.plugins.contains { $0.component.map(PluginMeterPacket.isFOHMeter) ?? false } }
        return withPlugin.count == 1 ? withPlugin[0] : nil
    }
}

extension PluginMeterPacket {
    /// FOH Meter's Audio Unit id: aufx / FMtr / FOHr.
    public static let component = AUComponentID(type: "aufx", subtype: "FMtr", manufacturer: "FOHr")

    public static func isFOHMeter(_ c: AUComponentID) -> Bool { c.subtype == component.subtype && c.manufacturer == component.manufacturer }
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

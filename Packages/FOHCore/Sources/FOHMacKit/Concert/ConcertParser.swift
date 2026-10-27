#if os(macOS)
import Foundation
import FOHCore

/// Reads a MainStage `.concert` bundle into `ConcertInfo` (PLAN.md §3 "Import from concert").
///
/// Layout (MainStage 4.3):
/// - `data.plist` — document settings; `Document_TypeCount["Input Mono"]` is the audio device's input count.
/// - `Concert.patch/data.plist` — `channels` (concert-level strips), `nodes` (child patch/set folders, in order),
///   `patch.engineNode.name` (concert name).
/// - `<name>.patch/data.plist` — a patch (or a set, when it has `nodes` of its own): `channels`,
///   `patch.engineNode` with `name`, `hasProgramChange`, `patchChangeNum`.
/// - `<strip>.cst` — binary channel-strip settings. Offset 96 holds the strip type word ("Aux 2", "Output 1-2",
///   "Master", "Inst 1"). Each plugin slot is a `UCuA` block: preset file name at +50, short plugin name at +156
///   (12 bytes), then either a byte-reversed AU triple at +168 ("VWskxfuaMHCS" → aufx/SCHM/ksWV) or "GAME" for
///   Logic's built-in plugins. The first block with an empty name ends the chain.
public enum ConcertParser {
    public enum ParseError: Error, CustomStringConvertible {
        case notAConcert(String)

        public var description: String {
            switch self {
            case .notAConcert(let p): return "\(p) is not a MainStage concert (no Concert.patch/data.plist)"
            }
        }
    }

    /// Parse a concert. `componentNames` maps installed AU ids to their full names (used to expand the 12-byte
    /// names stored in the .cst); pass `[:]` to skip lookup, or omit to query the system.
    public static func parse(_ url: URL, componentNames: [AUComponentID: String]? = nil) throws -> ConcertInfo {
        let concertDir = url.appendingPathComponent("Concert.patch", isDirectory: true)
        guard let root = plist(concertDir.appendingPathComponent("data.plist")) else {
            throw ParseError.notAConcert(url.path)
        }
        let names = componentNames ?? installedComponentNames()
        let doc = plist(url.appendingPathComponent("data.plist"))
        let typeCount = doc?["Document_TypeCount"] as? [String: Any]
        let inputCount = (typeCount?["Input Mono"] as? NSNumber)?.intValue

        var strips: [ConcertInfo.ChannelStrip] = []
        var patches: [PatchInfo] = []

        strips += channels(in: root, dir: concertDir, level: .concert, patchName: nil, names: names)
        walkNodes(of: root, dir: concertDir, names: names, strips: &strips, patches: &patches)

        let concertName = engineNode(root)?["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        return ConcertInfo(name: concertName, path: url.path, strips: strips, patches: patches, audioInputCount: inputCount)
    }

    /// Default concert to import: the show's own path if it still exists, else the first `~/Desktop/*.concert`.
    public static func defaultConcertURL(preferred: String?) -> URL? {
        let fm = FileManager.default
        if let preferred, fm.fileExists(atPath: preferred) { return URL(fileURLWithPath: preferred) }
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let items = (try? fm.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "concert" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    // MARK: Patches and sets

    private static func walkNodes(of node: [String: Any], dir: URL, names: [AUComponentID: String],
                                  strips: inout [ConcertInfo.ChannelStrip], patches: inout [PatchInfo]) {
        for child in (node["nodes"] as? [String]) ?? [] {
            let childDir = dir.appendingPathComponent(child, isDirectory: true)
            guard let data = plist(childDir.appendingPathComponent("data.plist")) else { continue }
            let engine = engineNode(data)
            let name = engine?["name"] as? String ?? (child as NSString).deletingPathExtension
            let isSet = !((data["nodes"] as? [String]) ?? []).isEmpty
            strips += channels(in: data, dir: childDir, level: .patch, patchName: name, names: names)
            if isSet {
                walkNodes(of: data, dir: childDir, names: names, strips: &strips, patches: &patches)
            } else {
                let hasPC = (engine?["hasProgramChange"] as? NSNumber)?.boolValue ?? false
                let pc = (engine?["patchChangeNum"] as? NSNumber)?.intValue
                patches.append(PatchInfo(index: patches.count, name: name, programChange: hasPC ? pc : nil))
            }
        }
    }

    private static func engineNode(_ data: [String: Any]) -> [String: Any]? {
        (data["patch"] as? [String: Any])?["engineNode"] as? [String: Any]
    }

    // MARK: Channel strips

    private static func channels(in data: [String: Any], dir: URL, level: MainStageLink.Level, patchName: String?,
                                 names: [AUComponentID: String]) -> [ConcertInfo.ChannelStrip] {
        ((data["channels"] as? [[String: Any]]) ?? []).map { ch in
            let name = ch["Channel_name"] as? String ?? "Untitled"
            let cst = (ch["Filename"] as? String).flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
            let header = cst.map(typeWord) ?? ""
            let inputIndex = int(ch["Channel_inputIndex_1"]) ?? -1
            let inputIsBus = bool(ch["Channel_inputIsBus"])
            let inputIsStereo = bool(ch["Channel_inputIsStereo"])
            let outputIndex = int(ch["Channel_outputIndex"]) ?? -1
            let outputIsBus = bool(ch["Channel_outputIsBus"])
            let outputIsStereo = bool(ch["Channel_outputIsStereo"])

            let kind = classify(header: header, name: name, inputIndex: inputIndex, inputIsBus: inputIsBus)
            var input: String?
            if inputIndex >= 0 {
                input = inputIsBus ? "Bus \(inputIndex + 1)" : ioLabel("In", index: inputIndex, stereo: inputIsStereo)
            }
            var output: String?
            if kind == .output, header.hasPrefix("Output") {
                output = "Out" + header.dropFirst("Output".count)
            } else if outputIndex >= 0 {
                output = outputIsBus ? "Bus \(outputIndex + 1)" : ioLabel("Out", index: outputIndex, stereo: outputIsStereo)
            }
            let stereo: Bool
            switch kind {
            case .audioInput: stereo = inputIsStereo
            case .master: stereo = true
            case .output: stereo = output?.contains("-") ?? outputIsStereo
            default: stereo = outputIsStereo
            }
            return ConcertInfo.ChannelStrip(name: name, kind: kind, level: level, patchName: patchName, stereo: stereo,
                                            input: input, output: output, plugins: cst.map { plugins(in: $0, names: names) } ?? [],
                                            sends: sends(ch["Channel_sends"]))
        }
    }

    static func classify(header: String, name: String, inputIndex: Int, inputIsBus: Bool) -> ConcertInfo.ChannelStrip.Kind {
        if header.hasPrefix("Inst") { return .instrument }
        if header.hasPrefix("Output") { return .output }
        if header.hasPrefix("Master") { return .master }
        if header.hasPrefix("Aux") { return inputIsBus ? .aux : .audioInput }
        // No .cst — fall back on the plist.
        if name == "Master" { return .master }
        if name == "Metronome" { return .instrument }
        if inputIsBus { return .aux }
        if inputIndex >= 0 { return .audioInput }
        return .unknown
    }

    /// "In 1", or for a stereo pair index "In 3-4".
    static func ioLabel(_ prefix: String, index: Int, stereo: Bool) -> String {
        stereo ? "\(prefix) \(index * 2 + 1)-\(index * 2 + 2)" : "\(prefix) \(index + 1)"
    }

    private static func sends(_ value: Any?) -> [ConcertInfo.Send] {
        ((value as? [[String: Any]]) ?? []).enumerated().compactMap { i, s in
            guard let bus = int(s["sendOutputIndex"]) else { return nil }   // empty slot
            return ConcertInfo.Send(slot: i + 1, bus: bus + 1, level: (s["sendVolume"] as? NSNumber)?.doubleValue,
                                    muted: bool(s["sendIsMuted"]))
        }
    }

    // MARK: .cst

    /// The strip type word at offset 96 (" Aux 2" → "Aux 2").
    static func typeWord(_ data: Data) -> String {
        cString(data, at: 96, max: 32)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Logic's 12-byte short names for its own plugins → the names users know.
    static let appleNames: [String: String] = [
        "Multipr": "Multipressor",
        "DirMix": "Direction Mixer",
        "Space D": "Space Designer",
        "ChromaVerb": "ChromaVerb",
        "Comp": "Compressor",
        "NoiseGate": "Noise Gate",
        "Chan EQ": "Channel EQ",
        "Lin EQ": "Linear Phase EQ",
        "Tape Delay": "Tape Delay",
        "Stereo Delay": "Stereo Delay",
    ]

    /// Plugins in chain order, numbered 1… (empty slots skipped), with component ids and preset names.
    static func plugins(in data: Data, names: [AUComponentID: String]) -> [PluginRef] {
        let bytes = [UInt8](data)
        let marker: [UInt8] = Array("UCuA".utf8)
        var out: [PluginRef] = []
        var i = 0
        var blockStarts: [Int] = []
        while let found = find(marker, in: bytes, from: i) {
            blockStarts.append(found)
            i = found + 4
        }
        for (n, start) in blockStarts.enumerated() {
            guard start + 180 <= bytes.count else { break }
            guard let shortName = cString(data, at: start + 156, max: 12), !shortName.isEmpty else {
                // An empty-name block after plugins ends the chain; before any plugin it's an empty slot.
                if !out.isEmpty { break }
                continue
            }
            let code = Array(bytes[(start + 168)..<(start + 180)])
            let end = n + 1 < blockStarts.count ? blockStarts[n + 1] : bytes.count
            let block = data.subdata(in: start..<end)
            let trimmed = shortName.trimmingCharacters(in: .whitespaces)
            if let component = auComponent(code) {
                let full = names[component].map(cleanVariantSuffix) ?? trimmed
                out.append(PluginRef(position: out.count + 1, name: full, component: component, preset: presetName(block)))
            } else if code.starts(with: Array("GAME".utf8)) {
                out.append(PluginRef(position: out.count + 1, name: appleNames[trimmed] ?? trimmed, component: nil,
                                     preset: presetName(block)))
            } else if !out.isEmpty {
                break   // archived data after the chain
            }
        }
        return out
    }

    /// "VWskxfuaMHCS" → manufacturer "ksWV", type "aufx", subtype "SCHM" (each 4CC stored byte-reversed).
    static func auComponent(_ code: [UInt8]) -> AUComponentID? {
        guard code.count == 12, code.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        func rev(_ r: Range<Int>) -> String { String(bytes: code[r].reversed(), encoding: .ascii) ?? "" }
        let manufacturer = rev(0..<4), type = rev(4..<8), subtype = rev(8..<12)
        let knownTypes: Set<String> = ["aufx", "aumf", "aumu", "aumx", "aufc", "augn", "aumi"]
        guard knownTypes.contains(type) else { return nil }
        return AUComponentID(type: type, subtype: subtype, manufacturer: manufacturer)
    }

    /// The user-facing preset: the preset file name at +50 ("AT Femal Vocal 1.aupreset"), else the AU state's
    /// `name`; generic names ("Untitled", "Default Setting") are dropped.
    static func presetName(_ block: Data) -> String? {
        var candidates: [String] = []
        if let file = cString(block, at: 50, max: 100), !file.isEmpty {
            candidates.append((file as NSString).deletingPathExtension)
        }
        if let text = String(data: block, encoding: .isoLatin1),
           let r = text.range(of: #"<key>name</key>\s*<string>([^<]*)</string>"#, options: .regularExpression) {
            let match = String(text[r])
            if let open = match.range(of: "<string>"), let close = match.range(of: "</string>") {
                candidates.append(String(match[open.upperBound..<close.lowerBound]))
            }
        }
        let generic: Set<String> = ["untitled", "default setting", "default", ""]
        return candidates.first { !generic.contains($0.lowercased()) }
    }

    /// "SSLChannel (m)" → "SSLChannel": the mono/stereo variant suffix Waves adds to component names.
    static func cleanVariantSuffix(_ name: String) -> String {
        for suffix in [" (m)", " (s)", " (m->s)", " (s->s)"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    static func installedComponentNames() -> [AUComponentID: String] {
        var out: [AUComponentID: String] = [:]
        for c in PluginDiscovery.components() { out[c.id] = c.name }
        return out
    }

    // MARK: Helpers

    static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func cString(_ data: Data, at offset: Int, max: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        let end = Swift.min(data.count, offset + max)
        let slice = data[data.startIndex + offset ..< data.startIndex + end]
        let bytes = slice.prefix { $0 != 0 }
        guard bytes.allSatisfy({ $0 >= 0x20 }) else { return nil }
        return String(data: Data(bytes), encoding: .utf8)
    }

    static func find(_ needle: [UInt8], in hay: [UInt8], from start: Int) -> Int? {
        guard needle.count <= hay.count, start <= hay.count - needle.count else { return nil }
        var i = start
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    static func bool(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }
}
#endif

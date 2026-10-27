import Foundation

/// What the bridge found in a MainStage `.concert` bundle (PLAN.md §3 "Import from concert").
public struct ConcertInfo: Codable, Hashable, Sendable {
    public struct Send: Codable, Hashable, Sendable {
        /// MainStage send slot on the strip (1-based).
        public var slot: Int
        /// MainStage bus number the send feeds (1-based), if known.
        public var bus: Int?
        /// Send level as stored (0…1), if known.
        public var level: Double?
        public var muted: Bool

        public init(slot: Int, bus: Int?, level: Double?, muted: Bool) {
            self.slot = slot
            self.bus = bus
            self.level = level
            self.muted = muted
        }
    }

    public struct ChannelStrip: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case audioInput, aux, output, master, instrument, unknown
        }

        public var name: String
        public var kind: Kind
        public var level: MainStageLink.Level
        public var patchName: String?
        public var stereo: Bool
        /// "In 1", "In 3-4", "Bus 1" — nil if the strip has no input (outputs, master).
        public var input: String?
        /// "Out 1-2", "Bus 2", "Main" …
        public var output: String?
        public var plugins: [PluginRef]
        public var sends: [Send]

        public init(name: String, kind: Kind, level: MainStageLink.Level, patchName: String? = nil, stereo: Bool = false,
                    input: String? = nil, output: String? = nil, plugins: [PluginRef] = [], sends: [Send] = []) {
            self.name = name
            self.kind = kind
            self.level = level
            self.patchName = patchName
            self.stereo = stereo
            self.input = input
            self.output = output
            self.plugins = plugins
            self.sends = sends
        }

        /// The app strip kind this concert strip becomes, or nil for strips the mixer doesn't show (instruments).
        public var stripKind: StripKind? {
            switch kind {
            case .audioInput: return .input
            case .aux: return .fx
            case .output: return .output
            case .master: return .master
            case .instrument, .unknown: return nil
            }
        }

        /// "Bus 1" → 1 for aux strips fed by a bus.
        public var inputBus: Int? {
            guard let input, input.lowercased().hasPrefix("bus") else { return nil }
            return Int(input.drop { !$0.isNumber }.prefix { $0.isNumber })
        }
    }

    public var name: String
    public var path: String
    public var strips: [ChannelStrip]
    public var patches: [PatchInfo]
    /// Mono inputs the concert's audio device was set up with ("Document_TypeCount").
    public var audioInputCount: Int?

    public init(name: String, path: String, strips: [ChannelStrip], patches: [PatchInfo], audioInputCount: Int? = nil) {
        self.name = name
        self.path = path
        self.strips = strips
        self.patches = patches
        self.audioInputCount = audioInputCount
    }
}

extension ProcessingSources {
    /// A sensible starting point from a plugin chain: an SSL Channel drives EQ, Dynamics and Trim; known insert
    /// plugins (Waves Tune, Pro-Q 3) and any other identified plugin fill insert pages 1–4 in chain order.
    public static func suggested(for plugins: [PluginRef]) -> ProcessingSources {
        var p = ProcessingSources()
        let sslSubtypes: Set<String> = ["SCHM", "SCHS"]
        if let ssl = plugins.first(where: { sslSubtypes.contains($0.component?.subtype ?? "") || BindingTemplate.normalize($0.name).hasPrefix("sslchannel") }) {
            p.eq = ssl.position
            p.dynamics = ssl.position
            p.trim = ssl.position
        }
        var page = 1
        for plugin in plugins where plugin.component != nil && plugin.position != p.eq && page <= 4 {
            p.insertPages[page] = plugin.position
            page += 1
        }
        return p
    }
}

extension ShowConfig {
    /// Merge a concert scan into this show without moving anything the user already has:
    /// strips match by MainStage strip name and keep their slot, name and colour; new strips take the next free
    /// slot; strips no longer in the concert are kept (the user may have added them by hand); patches are
    /// replaced; sends are flagged by whether an aux strip in the concert is fed by their bus.
    public func merged(with concert: ConcertInfo) -> ShowConfig {
        var show = self
        show.name = concert.name
        show.concertPath = concert.path
        let palette: [ChannelColor] = [.cyan, .yellow, .green, .magenta, .red, .blue]
        var paletteIndex = show.strips.filter { $0.ref.kind == .input }.count

        for cs in concert.strips {
            guard let kind = cs.stripKind else { continue }
            let link = MainStageLink(stripName: cs.name, level: cs.level, patchName: cs.patchName)
            let io = kind == .input || kind == .fx ? cs.input : cs.output
            if let i = show.strips.firstIndex(where: { $0.mainStage?.stripName == cs.name && $0.ref.kind == kind }) {
                var strip = show.strips[i]
                let chainChanged = strip.plugins.map(\.name) != cs.plugins.map(\.name)
                strip.mainStage = link
                strip.stereo = cs.stereo
                if let io { strip.hardwareIO = io }
                strip.plugins = cs.plugins
                if chainChanged {
                    strip.processing = .suggested(for: cs.plugins)
                    show.bindings[strip.ref.key] = nil
                }
                show.strips[i] = strip
            } else {
                guard let slot = show.nextFreeSlot(kind), let ref = StripRef(kind: kind, slot: slot) else { continue }
                let color: ChannelColor
                switch kind {
                case .input: color = palette[paletteIndex % palette.count]; paletteIndex += 1
                case .fx: color = .blue
                case .output, .master: color = .white
                }
                show.strips.append(Strip(ref: ref, name: cs.name, color: color, stereo: cs.stereo, mainStage: link,
                                         hardwareIO: io, plugins: cs.plugins, processing: .suggested(for: cs.plugins)))
            }
        }
        show.strips.sort { $0.ref < $1.ref }

        let fedBuses = Set(concert.strips.compactMap(\.inputBus))
        for i in show.sends.indices {
            if let bus = show.sends[i].busNumber { show.sends[i].existsInConcert = fedBuses.contains(bus) }
        }
        // Buses fed in the concert that no configured send points at get a send of their own.
        for bus in fedBuses.sorted() where !show.sends.contains(where: { $0.busNumber == bus }) {
            let index = (1...8).first { n in !show.sends.contains { $0.index == n } }
            guard let index else { break }
            let auxName = concert.strips.first { $0.inputBus == bus }?.name ?? "Bus \(bus)"
            show.sends.append(SendBus(index: index, name: auxName, busNumber: bus, existsInConcert: true))
        }
        show.sends.sort { $0.index < $1.index }

        if !concert.patches.isEmpty {
            show.patches = concert.patches
            if let current = show.currentPatch, current >= concert.patches.count { show.currentPatch = 0 }
            if show.currentPatch == nil { show.currentPatch = 0 }
        }
        return show
    }
}

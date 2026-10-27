import Foundation
import FOHCore

/// Offline demo: today's Church.concert with bindings built locally from the bundled discovery
/// fixtures (Waves SSL Channel + Waves Tune Real-Time), seeded to match the design canvas.
enum DemoShow {
    static func load(_ name: String) -> PluginDescription? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PluginDescription.self, from: data)
    }

    /// The bundled discovery fixtures, by component (stands in for the bridge's plugin discovery offline).
    static let plugins: [AUComponentID: PluginDescription] = {
        var out: [AUComponentID: PluginDescription] = [:]
        if let ssl = load("ssl-channel") { out[.wavesSSLChannel] = ssl }
        if let tune = load("waves-tune-rt") { out[.wavesTuneRealTime] = tune }
        // Their core sets (PLAN.md §9c), plus Pro-Q bands 9–10 for Add control, to keep the app small.
        if let proQ = load("pro-q-3") { out[.fabFilterProQ3] = proQ }
        if let proR = load("pro-r-2") { out[.fabFilterProR2] = proR }
        return out
    }()

    /// Discovered plugins for one strip, keyed by chain position.
    static func discovered(for strip: Strip) -> [Int: PluginDescription] {
        var d: [Int: PluginDescription] = [:]
        for p in strip.plugins {
            if let c = p.component, let desc = plugins[c] { d[p.position] = desc }
        }
        return d
    }

    static func binding(for strip: Strip, sends: [SendBus]) -> StripBinding {
        StripBinding.build(for: strip, sends: sends, discovered: discovered(for: strip))
    }

    /// An import preview: today's concert plus a Bass input and a Delay aux, so "new" strips show up.
    static var concert: ConcertInfo {
        var strips: [ConcertInfo.ChannelStrip] = ShowConfig.church.strips.compactMap { s in
            guard let link = s.mainStage else { return nil }
            let kind: ConcertInfo.ChannelStrip.Kind
            switch s.ref.kind {
            case .input: kind = .audioInput
            case .fx: kind = .aux
            case .output: kind = .output
            case .master: kind = .master
            }
            let io = s.hardwareIO
            return ConcertInfo.ChannelStrip(name: link.stripName, kind: kind, level: link.level, patchName: link.patchName,
                                            stereo: s.stereo, input: s.ref.kind == .input || s.ref.kind == .fx ? io : nil,
                                            output: s.ref.kind == .output ? io : nil, plugins: s.plugins,
                                            sends: s.ref.kind == .input ? [.init(slot: 1, bus: 1, level: 0.38, muted: false)] : [])
        }
        strips.append(.init(name: "Bass", kind: .audioInput, level: .concert, input: "In 3",
                            plugins: [PluginRef(position: 1, name: "SSLChannel", component: .wavesSSLChannel)]))
        strips.append(.init(name: "Delay", kind: .aux, level: .concert, stereo: true, input: "Bus 5",
                            plugins: [PluginRef(position: 1, name: "Stereo Delay")]))
        strips.append(.init(name: "Metronome", kind: .instrument, level: .concert))
        return ConcertInfo(name: "Church", path: "~/Desktop/Church.concert", strips: strips,
                           patches: [PatchInfo(index: 0, name: "Song One", programChange: 0),
                                     PatchInfo(index: 1, name: "Song Two", programChange: 1)],
                           audioInputCount: 18)
    }

    static func make() -> (config: ShowConfig, values: [String: Int]) {
        var config = ShowConfig.church
        config.patches = [PatchInfo(index: 0, name: "Song One", programChange: 0),
                          PatchInfo(index: 1, name: "Song Two", programChange: 1)]
        config.currentPatch = 0
        config.concertPath = "~/Desktop/Church.concert"
        // The reverb return as it is now: FabFilter Pro-R 2 on "VRB Return".
        if let i = config.strips.firstIndex(where: { $0.ref == .fx(1) }) {
            config.strips[i].name = "VRB Return"
            config.strips[i].plugins = [PluginRef(position: 1, name: "Pro-R 2", component: .fabFilterProR2)]
        }
        for strip in config.strips {
            config.bindings[strip.ref.key] = Self.binding(for: strip, sends: config.sends)
        }
        config.syncPluginControls(discovered: Dictionary(uniqueKeysWithValues: config.strips.map { ($0.ref.key, discovered(for: $0)) }))

        var values: [String: Int] = [:]
        func binding(_ s: StripRef, _ id: String) -> RoleBinding? { config.binding(s).roles[id] }
        func setNum(_ s: StripRef, _ id: String, _ target: Double) {
            guard let b = binding(s, id), let midi = b.midi(closestTo: target) else { return }
            values[FOHProtocol.valuePath(s, b.role)] = midi
        }
        func setRaw(_ s: StripRef, _ id: String, _ v: Int) {
            guard let role = Role.byID[id] else { return }
            values[FOHProtocol.valuePath(s, role)] = v
        }
        func setStep(_ s: StripRef, _ id: String, _ label: String) {
            guard let b = binding(s, id), let c = b.stepCenters.first(where: { $0.label == label }) else { return }
            values[FOHProtocol.valuePath(s, b.role)] = c.midi
        }

        // Lead vox (input 1) — SSL Channel on insert 3, Waves Tune on page 1.
        let kv = StripRef.input(1)
        setNum(kv, "mix.fader", -2.5); setRaw(kv, "mix.pan", 64)
        setNum(kv, "mix.trimIn", 0); setNum(kv, "mix.trimOut", 2)
        setRaw(kv, "eq.on", 127)
        setNum(kv, "eq.hpfFreq", 100); setRaw(kv, "eq.lpfFreq", 0)
        setNum(kv, "band.1.freq", 120); setNum(kv, "band.1.gain", -1.5); setRaw(kv, "band.1.type", 0)
        setNum(kv, "band.2.freq", 320); setNum(kv, "band.2.gain", -3.5); setNum(kv, "band.2.q", 2.2)
        setNum(kv, "band.3.freq", 2800); setNum(kv, "band.3.gain", 3); setNum(kv, "band.3.q", 1.1)
        setNum(kv, "band.4.freq", 11000); setNum(kv, "band.4.gain", 3); setRaw(kv, "band.4.type", 0)
        setRaw(kv, "dyn.on", 127)
        setNum(kv, "comp.thresh", -18); setNum(kv, "comp.ratio", 3); setNum(kv, "comp.release", 0.3); setRaw(kv, "comp.attack", 0)
        setNum(kv, "gate.thresh", -30); setNum(kv, "gate.range", 20); setNum(kv, "gate.release", 0.25)
        setRaw(kv, "gate.attack", 127); setRaw(kv, "gate.mode", 0)
        for (i, db) in [(1, -2.0), (2, -8.0), (3, -10.0), (4, -16.0), (5, -18.0)] {
            setNum(kv, "send.\(i).level", db); setRaw(kv, "send.\(i).on", 127)
        }
        setNum(kv, "ins.1.macro.1", 20); setNum(kv, "ins.1.macro.2", 80)
        setStep(kv, "ins.1.macro.3", "A"); setStep(kv, "ins.1.macro.4", "Chromatic")
        setRaw(kv, "ins.1.macro.5", 127); setNum(kv, "ins.1.macro.6", 80)

        // Guitar (input 2) — SSL Channel "Acc Gtr" on insert 1.
        let gt = StripRef.input(2)
        setNum(gt, "mix.fader", -8); setRaw(gt, "mix.pan", 64)
        setNum(gt, "mix.trimIn", 0); setNum(gt, "mix.trimOut", 0)
        setRaw(gt, "eq.on", 127)
        setNum(gt, "eq.hpfFreq", 80); setRaw(gt, "eq.lpfFreq", 0)
        setNum(gt, "band.1.freq", 150); setNum(gt, "band.1.gain", -2); setRaw(gt, "band.1.type", 0)
        setNum(gt, "band.2.freq", 350); setNum(gt, "band.2.gain", -2.5); setNum(gt, "band.2.q", 1.5)
        setNum(gt, "band.3.freq", 3000); setNum(gt, "band.3.gain", 2.5); setNum(gt, "band.3.q", 1.2)
        setNum(gt, "band.4.freq", 10000); setNum(gt, "band.4.gain", 2); setRaw(gt, "band.4.type", 0)
        setRaw(gt, "dyn.on", 127)
        setNum(gt, "comp.thresh", -14); setNum(gt, "comp.ratio", 2); setNum(gt, "comp.release", 0.2)
        setNum(gt, "gate.thresh", -30); setNum(gt, "gate.range", 0)
        for (i, db) in [(1, -8.0), (2, -4.0), (3, -14.0), (5, -24.0)] {
            setNum(gt, "send.\(i).level", db); setRaw(gt, "send.\(i).on", 127)
        }

        // Plugin controls: Pro-Q 3 on Lead vox (a low cut, two bells, one of them dynamic, and a high shelf) and
        // Pro-R 2 on the reverb return.
        func plugin(_ s: StripRef, _ position: Int, _ name: String, _ target: Double? = nil, step: String? = nil, raw: Int? = nil) {
            guard let c = config.pluginControls.first(where: { $0.strip == s && $0.position == position && $0.name == name }),
                  let comp = config.strip(s)?.plugin(at: position)?.component, let info = plugins[comp]?.parameter(id: c.parameterID) else { return }
            let midi = raw ?? step.flatMap { label in info.stepCenters.first { $0.label == label }?.midi } ?? target.flatMap(info.midi(closestTo:))
            if let midi { values[c.path] = midi }
        }
        let proQ = [(1, "Low Cut", 90.0, 0.0, "24 dB/oct"), (2, "Bell", 250, -3, "12 dB/oct"), (3, "Bell", 3200, 2, "12 dB/oct"),
                    (4, "High Shelf", 11000, 1.5, "12 dB/oct")]
        for (n, shape, freq, gain, slope) in proQ {
            plugin(kv, 2, "Band \(n) Used", raw: 127); plugin(kv, 2, "Band \(n) Enabled", raw: 127)
            plugin(kv, 2, "Band \(n) Shape", step: shape); plugin(kv, 2, "Band \(n) Slope", step: slope)
            plugin(kv, 2, "Band \(n) Frequency", freq); plugin(kv, 2, "Band \(n) Gain", gain)
        }
        plugin(kv, 2, "Band 2 Q", 1.4)
        plugin(kv, 2, "Band 3 Dynamics Enabled", raw: 127); plugin(kv, 2, "Band 3 Dynamic Range", -4); plugin(kv, 2, "Band 3 Threshold", raw: 60)
        let vrb = StripRef.fx(1)
        plugin(vrb, 1, "Space", raw: 70); plugin(vrb, 1, "Mix", 22)
        plugin(vrb, 1, "Decay EQ Band 1 Shape", step: "Low Shelf"); plugin(vrb, 1, "Decay EQ Band 1 Frequency", 200); plugin(vrb, 1, "Decay EQ Band 1 Rate", 70)
        plugin(vrb, 1, "Decay EQ Band 2 Shape", step: "High Shelf"); plugin(vrb, 1, "Decay EQ Band 2 Frequency", 6000); plugin(vrb, 1, "Decay EQ Band 2 Rate", 50)
        for n in 3...6 { plugin(vrb, 1, "Decay EQ Band \(n) Used", raw: 0) }

        setNum(.fx(1), "mix.fader", -6); setRaw(.fx(1), "mix.pan", 64)
        setNum(.output(1), "mix.fader", -1); setRaw(.output(1), "mix.pan", 64)
        setNum(.output(2), "mix.fader", -4); setRaw(.output(2), "mix.pan", 64)
        setRaw(.output(3), "mix.fader", 0); setRaw(.output(3), "mix.mute", 127); setRaw(.output(3), "mix.pan", 64)
        setNum(.master, "mix.fader", 0)
        return (config, values)
    }
}

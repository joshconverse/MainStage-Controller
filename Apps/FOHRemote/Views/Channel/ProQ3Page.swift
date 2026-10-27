import SwiftUI
import FOHCore

/// FabFilter Pro-Q 3 (PLAN.md §9c): the EQ graph with up to 8 bands, each band's shape, slope and dynamic EQ, and
/// the plugin's output section. Everything is a plugin control on the plugin ports, mapped by the concert writer.
struct ProQ3Page: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let plugin: PluginRef
    @State private var selectedBand = 1
    /// Frequency/gain MIDI values when a drag began, restored if it turns into a pinch.
    @State private var dragStart: [String: Int] = [:]
    @State private var pinchStartQ: Double?

    static let bandCount = 8
    static let colors: [Color] = [Color(hex: 0xF5A524), Color(hex: 0x3DD68C), Color(hex: 0x4C9EFF), Color(hex: 0xE5484D),
                                  Color(hex: 0xA78BFA), Color(hex: 0x2DD4BF), Color(hex: 0xF472B6), Color(hex: 0xF5D90A)]
    /// Where a band added with the button lands (Hz), by band number.
    static let addFrequencies: [Double] = [80, 200, 500, 1000, 2500, 5000, 10000, 15000]

    /// One Pro-Q band's controls.
    struct Band {
        let n: Int
        let used, enabled, freq, gain, q, shape, slope, dynamics, threshold, range: PluginParam?

        init(_ n: Int, _ c: PluginControls) {
            self.n = n
            func p(_ name: String) -> PluginParam? { c["Band \(n) \(name)"] }
            used = p("Used"); enabled = p("Enabled"); freq = p("Frequency"); gain = p("Gain"); q = p("Q")
            shape = p("Shape"); slope = p("Slope"); dynamics = p("Dynamics Enabled"); threshold = p("Threshold"); range = p("Dynamic Range")
        }
    }

    var body: some View {
        let c = store.pluginControls(strip, plugin.position)
        let bands = (1...Self.bandCount).map { Band($0, c) }
        let scale = gainScale(c)
        VStack(spacing: 10) {
            header(c)
            PluginMappingNotice(controls: c)
            if c.described {
                PluginEQGraph(bands: bands.compactMap { graphBand($0, scale: scale) }, selected: selectedBand,
                              engaged: !(c["Bypass"].map(store.isOn) ?? false), rtaStrip: strip,
                              callout: { callout(bands[$0.id - 1], $0) },
                              onSelect: { selectedBand = $0 },
                              onDragBegin: { beginDrag(bands[$0 - 1]) },
                              onDrag: { drag(bands[$0 - 1], freq: $1, gain: $2 / scale) },
                              onDragEnd: { endDrag(bands[$0 - 1]) },
                              onDragRevert: { revertDrag(bands[$0 - 1]) },
                              onPinchBegin: { beginPinch(bands[$0 - 1]) },
                              onPinch: { pinch(bands[$0 - 1], $1) },
                              onPinchEnd: { endPinch(bands[$0 - 1]) },
                              onDoubleTap: { resetGain(bands[$0 - 1]) },
                              onAdd: { add(bands, freq: $0, gain: $1 / scale) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bandChips(bands)
                bandPanel(bands[selectedBand - 1])
                    .frame(height: 176)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading Pro-Q 3's parameters from FOH Bridge…").foregroundStyle(Theme.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .requestingPlugin(store, strip, plugin.position, described: c.described)
        .onAppear {
            store.subscribeRTA(strip)
            if let first = bands.first(where: { isUsed($0) }) { selectedBand = first.n }
        }
        .onDisappear { store.subscribeRTA(nil) }
    }

    // MARK: Model

    private func isUsed(_ b: Band) -> Bool { b.used.map(store.isOn) ?? false }

    /// Pro-Q's "Dynamics Enabled" is on by default; a band only acts dynamically once it has a range (the nearest
    /// MIDI step to 0 dB is ±0.24 dB, so anything under half a dB counts as none).
    private func isDynamic(_ b: Band) -> Bool {
        guard b.dynamics.map(store.isOn) == true, let range = b.range.flatMap(store.numeric) else { return false }
        return abs(range) >= 0.5
    }

    private func gainScale(_ c: PluginControls) -> Double {
        guard let p = c["Gain Scale"], let pct = store.numeric(p) else { return 1 }
        return pct / 100
    }

    static func kind(_ shape: String) -> EQBand.Kind {
        switch shape {
        case "Low Shelf": return .lowShelf
        case "Low Cut": return .highPass
        case "High Shelf": return .highShelf
        case "High Cut": return .lowPass
        case "Notch": return .notch
        case "Band Pass": return .bandPass
        case "Tilt Shelf": return .tiltShelf
        case "Flat Tilt": return .flatTilt
        default: return .peak
        }
    }

    /// "24 dB/oct" → 24; "Brickwall" → 120.
    static func slopeDB(_ text: String) -> Double {
        if text.lowercased().hasPrefix("brick") { return 120 }
        return DisplayValue.parse(text)?.value ?? 12
    }

    private func graphBand(_ b: Band, scale: Double) -> GraphBand? {
        guard isUsed(b), let freq = b.freq.flatMap(store.numeric) else { return nil }
        let kind = Self.kind(b.shape.map(store.display) ?? "Bell")
        let q = b.q.flatMap(store.numeric) ?? 1
        let gain = (b.gain.flatMap(store.numeric) ?? 0) * scale
        // Pro-Q's Q 1 is a plain second-order response; RBJ shelves and cuts call that 0.707.
        let shapeQ = kind == .peak || kind == .notch || kind == .bandPass ? q : q * 0.7071
        let eq = EQBand(id: "band.\(b.n)", label: "Band \(b.n)", kind: kind, freq: freq, gain: gain, q: shapeQ,
                        slope: b.slope.map { Self.slopeDB(store.display($0)) } ?? 12, enabled: b.enabled.map(store.isOn) ?? true)
        var dynamic: Double?
        if isDynamic(b), let range = b.range.flatMap(store.numeric), eq.hasGain { dynamic = gain + range * scale }
        return GraphBand(id: b.n, eq: eq, color: Self.colors[b.n - 1], dynamicGain: dynamic)
    }

    private func callout(_ b: Band, _ g: GraphBand) -> String {
        var parts = ["\(b.n) · \(b.shape.map(store.display) ?? "Bell")", EQGraph.freqText(g.eq.freq)]
        if g.eq.hasGain, let gain = b.gain { parts.append(store.display(gain)) }
        if let q = b.q, g.eq.kind != .flatTilt { parts.append("Q " + store.display(q)) }
        if g.dynamicGain != nil, let range = b.range { parts.append("dynamic " + store.display(range)) }
        if !g.eq.enabled { parts.append("off") }
        return parts.joined(separator: " · ")
    }

    // MARK: Gestures

    private func beginDrag(_ b: Band) {
        dragStart = [:]
        for p in [b.freq, b.gain].compactMap({ $0 }) {
            store.beginTouch(p)
            dragStart[p.path] = store.value(p)
        }
    }

    private func drag(_ b: Band, freq: Double, gain: Double) {
        if let f = b.freq { store.set(f, numeric: freq) }
        let kind = Self.kind(b.shape.map(store.display) ?? "Bell")
        if let g = b.gain, ![.highPass, .lowPass, .notch, .bandPass].contains(kind) { store.set(g, numeric: gain) }
    }

    private func endDrag(_ b: Band) {
        for p in [b.freq, b.gain].compactMap({ $0 }) { store.endTouch(p) }
    }

    private func revertDrag(_ b: Band) {
        for p in [b.freq, b.gain].compactMap({ $0 }) { if let v = dragStart[p.path] { store.set(p, v) } }
    }

    private func beginPinch(_ b: Band) -> Bool {
        guard let q = b.q, let start = store.numeric(q), start > 0 else { return false }
        pinchStartQ = start
        store.beginTouch(q)
        return true
    }

    /// Spreading the fingers widens the band (lower Q), as in Pro-Q itself.
    private func pinch(_ b: Band, _ scale: Double) {
        guard let q = b.q, let start = pinchStartQ else { return }
        store.set(q, numeric: start / scale)
    }

    private func endPinch(_ b: Band) {
        if let q = b.q { store.endTouch(q) }
        pinchStartQ = nil
    }

    private func resetGain(_ b: Band) {
        guard let g = b.gain, let zero = g.midi(closestTo: 0) else { return }
        store.setTogether([(g, zero)])
    }

    /// A tap on empty graph: the first unused band, as a bell where the finger was.
    private func add(_ bands: [Band], freq: Double, gain: Double) {
        guard let b = bands.first(where: { !isUsed($0) && $0.used != nil }) else {
            return store.showToast("All \(Self.bandCount) Pro-Q bands on the iPad are in use", ok: false)
        }
        addBand(b, freq: freq, gain: gain)
    }

    private func addBand(_ b: Band, freq: Double, gain: Double) {
        let bell = b.shape?.stepCenters.first { $0.label == "Bell" }?.midi
        store.setTogether([(b.shape, bell ?? 0), (b.freq, b.freq?.midi(closestTo: freq) ?? 64),
                           (b.gain, b.gain?.midi(closestTo: gain) ?? 64), (b.q, b.q?.info?.defaultMIDI ?? 64),
                           (b.enabled, 127), (b.used, 127)])
        selectedBand = b.n
    }

    // MARK: Header, chips, band panel

    private func header(_ c: PluginControls) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).font(.system(size: 18, weight: .bold))
                Text("Insert \(plugin.position)\(plugin.preset.map { " · \($0)" } ?? "") · \(c.all.count) controls")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            PluginDragField(param: c["Gain Scale"], title: "GAIN SCALE", width: 120)
            PluginDragField(param: c["Output Level"], title: "OUTPUT", width: 120)
            PluginDragField(param: c["Output Pan"], title: "PAN", width: 150)
            PluginToggle(param: c["Auto Gain"], title: "AUTO GAIN", color: Theme.eq).frame(width: 104)
            PluginToggle(param: c["Bypass"], title: "BYPASS", color: Theme.mute).frame(width: 90)
            AllControlsButton(strip: strip, plugin: plugin)
        }
    }

    private func bandChips(_ bands: [Band]) -> some View {
        HStack(spacing: 6) {
            ForEach(bands, id: \.n) { b in
                let used = isUsed(b)
                let color = Self.colors[b.n - 1]
                let on = b.enabled.map(store.isOn) ?? true
                Button { selectedBand = b.n } label: {
                    HStack(spacing: 6) {
                        Text(used ? "\(b.n)" : "+").font(.system(size: 12, weight: .heavy))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(used && on ? Theme.ground : color)
                            .background(Circle().fill(used && on ? color : Theme.raised2))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(used ? Self.short(b.shape.map(store.display) ?? "") : "Band \(b.n)")
                                .font(.system(size: 11, weight: .bold)).lineLimit(1)
                            Text(used ? (b.freq.flatMap(store.numeric).map(EQGraph.freqText) ?? "") : "off")
                                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text2).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selectedBand == b.n ? color : .clear, lineWidth: 2))
                    .opacity(used ? 1 : 0.6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Band \(b.n)\(used ? "" : ", not in use")")
            }
        }
    }

    static func short(_ shape: String) -> String {
        ["Low Shelf": "Lo Shelf", "High Shelf": "Hi Shelf", "Low Cut": "Lo Cut", "High Cut": "Hi Cut", "Band Pass": "B Pass",
         "Tilt Shelf": "Tilt", "Flat Tilt": "Flat Tilt"][shape] ?? shape
    }

    @ViewBuilder
    private func bandPanel(_ b: Band) -> some View {
        let color = Self.colors[b.n - 1]
        if isUsed(b) {
            let kind = Self.kind(b.shape.map(store.display) ?? "Bell")
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("BAND \(b.n)").font(.system(size: 12, weight: .heavy)).foregroundStyle(color)
                    PluginToggle(param: b.enabled, title: "ON", color: color, height: 40)
                    Button { store.setTogether([(b.used, 0)]) } label: {
                        Text("REMOVE").font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(Theme.text2).background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 100)
                HStack(alignment: .top, spacing: 2) {
                    PluginKnob(param: b.freq, title: "Freq", color: color, size: 52)
                    if ![.highPass, .lowPass, .notch, .bandPass].contains(kind) {
                        PluginKnob(param: b.gain, title: "Gain", color: color, size: 52, resetValue: b.gain?.midi(closestTo: 0))
                    }
                    if kind != .flatTilt { PluginKnob(param: b.q, title: "Q", color: color, size: 52) }
                }
                .frame(width: 216, alignment: .leading)
                section("SHAPE") { PluginPicker(param: b.shape, columns: 3, color: color, label: Self.short) }
                    .frame(width: 240)
                section("SLOPE") {
                    PluginPicker(param: b.slope, columns: 5, color: color) {
                        $0.lowercased().hasPrefix("brick") ? "Brick" : $0.replacingOccurrences(of: " dB/oct", with: "")
                    }
                }
                .frame(width: 210)
                if ![.highPass, .lowPass].contains(kind) {
                    section(isDynamic(b) ? "DYNAMIC EQ · ACTIVE" : "DYNAMIC EQ") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 0) {
                                PluginKnob(param: b.range, title: "Range", color: color, size: 40, resetValue: b.range?.midi(closestTo: 0))
                                PluginKnob(param: b.threshold, title: "Thresh", color: color, size: 40)
                            }
                            .opacity(b.dynamics.map(store.isOn) == false ? 0.45 : 1)
                            PluginToggle(param: b.dynamics, title: "DYNAMICS ON", color: color, height: 32)
                        }
                    }
                    .frame(minWidth: 150)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(spacing: 12) {
                Text("Band \(b.n) isn't in use. Tap the graph where you want a band, or add it here.")
                    .foregroundStyle(Theme.text2)
                ToggleChip(title: "ADD BAND \(b.n)", isOn: true, color: color) {
                    addBand(b, freq: Self.addFrequencies[b.n - 1], gain: 0)
                }
                .frame(width: 180)
                .disabled(b.used == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(Theme.text3)
            content()
        }
    }
}

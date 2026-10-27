import SwiftUI
import FOHCore

/// FabFilter Pro-R 2 (PLAN.md §9c): the reverb's main controls and its decay-rate EQ as a graph. Each decay EQ band
/// scales the decay time around its frequency (12.5%…200%), so the graph's scale is the rate, drawn in dB of it.
struct ProR2Page: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let plugin: PluginRef
    @State private var selectedBand = 1
    @State private var dragStart: [String: Int] = [:]
    @State private var pinchStartQ: Double?

    static let bandCount = 6
    static let colors = Array(ProQ3Page.colors.prefix(bandCount))
    static let addFrequencies: [Double] = [100, 300, 1000, 3000, 8000, 14000]
    /// Rate in dB of the multiplier: 12.5% = −18 dB … 200% = +6 dB.
    static let axis = GraphAxis(min: -20, max: 8, lines: [(-18.06, "12.5%"), (-12.04, "25%"), (-6.02, "50%"), (0, "100%"), (6.02, "200%")])

    struct Band {
        let n: Int
        let used, enabled, freq, rate, q, shape: PluginParam?

        init(_ n: Int, _ c: PluginControls) {
            self.n = n
            func p(_ name: String) -> PluginParam? { c["Decay EQ Band \(n) \(name)"] }
            used = p("Used"); enabled = p("Enabled"); freq = p("Frequency"); rate = p("Rate"); q = p("Q"); shape = p("Shape")
        }
    }

    static func rateDB(_ percent: Double) -> Double { 20 * log10(max(percent, 0.1) / 100) }
    static func percent(_ db: Double) -> Double { 100 * pow(10, db / 20) }

    var body: some View {
        let c = store.pluginControls(strip, plugin.position)
        let bands = (1...Self.bandCount).map { Band($0, c) }
        VStack(spacing: 10) {
            header(c)
            PluginMappingNotice(controls: c)
            if c.described {
                mainControls(c)
                HStack {
                    Text("DECAY RATE EQ").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(Theme.text3)
                    Text("how much longer or shorter the reverb rings at each frequency").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    Spacer()
                }
                PluginEQGraph(bands: bands.compactMap(graphBand), selected: selectedBand, axis: Self.axis,
                              engaged: !(c["Bypass"].map(store.isOn) ?? false),
                              callout: { callout(bands[$0.id - 1], $0) },
                              onSelect: { selectedBand = $0 },
                              onDragBegin: { beginDrag(bands[$0 - 1]) },
                              onDrag: { drag(bands[$0 - 1], freq: $1, rateDB: $2) },
                              onDragEnd: { endDrag(bands[$0 - 1]) },
                              onDragRevert: { revertDrag(bands[$0 - 1]) },
                              onPinchBegin: { beginPinch(bands[$0 - 1]) },
                              onPinch: { pinch(bands[$0 - 1], $1) },
                              onPinchEnd: { endPinch(bands[$0 - 1]) },
                              onDoubleTap: { resetRate(bands[$0 - 1]) },
                              onAdd: { add(bands, freq: $0, rateDB: $1) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(alignment: .top, spacing: 10) {
                    bandChips(bands).frame(width: 300)
                    bandPanel(bands[selectedBand - 1])
                }
                .frame(height: 150)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading Pro-R 2's parameters from FOH Bridge…").foregroundStyle(Theme.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .requestingPlugin(store, strip, plugin.position, described: c.described)
        .onAppear {
            if let first = bands.first(where: { isUsed($0) }) { selectedBand = first.n }
        }
    }

    private func header(_ c: PluginControls) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).font(.system(size: 18, weight: .bold))
                Text("Insert \(plugin.position)\(plugin.preset.map { " · \($0)" } ?? "") · \(c.all.count) controls")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            PluginDragField(param: c["Output Level"], title: "OUTPUT", width: 120)
            PluginToggle(param: c["Bypass"], title: "BYPASS", color: Theme.mute).frame(width: 96)
            AllControlsButton(strip: strip, plugin: plugin)
        }
    }

    private func mainControls(_ c: PluginControls) -> some View {
        HStack(alignment: .center, spacing: 18) {
            PluginKnob(param: c["Space"], title: "Space", color: Theme.inserts, size: 92)
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    PluginKnob(param: c["Decay Rate"], title: "Decay Rate", size: 50)
                    PluginKnob(param: c["Distance"], size: 50)
                    PluginKnob(param: c["Brightness"], size: 50)
                    PluginKnob(param: c["Character"], size: 50)
                    PluginKnob(param: c["Thickness"], size: 50)
                }
                HStack(spacing: 6) {
                    PluginKnob(param: c["Stereo Width"], title: "Width", size: 50)
                    PluginKnob(param: c["Predelay"], size: 50)
                    PluginKnob(param: c["Ducking"], size: 50)
                    PluginKnob(param: c["Mix"], color: Theme.sends, size: 50)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Model

    private func isUsed(_ b: Band) -> Bool { b.used.map(store.isOn) ?? false }

    static func kind(_ shape: String) -> EQBand.Kind {
        switch shape {
        case "Low Shelf": return .lowShelf
        case "High Shelf": return .highShelf
        case "Notch": return .notch
        default: return .peak
        }
    }

    private func graphBand(_ b: Band) -> GraphBand? {
        guard isUsed(b), let freq = b.freq.flatMap(store.numeric) else { return nil }
        let kind = Self.kind(b.shape.map(store.display) ?? "Bell")
        let rate = b.rate.flatMap(store.numeric) ?? 100
        let eq = EQBand(id: "decay.\(b.n)", label: "Band \(b.n)", kind: kind == .notch ? .peak : kind, freq: freq,
                        gain: Self.rateDB(rate), q: max(b.q.flatMap(store.numeric) ?? 0.5, 0.05) * (kind == .peak ? 1 : 0.7071),
                        slope: 12, enabled: b.enabled.map(store.isOn) ?? true)
        return GraphBand(id: b.n, eq: eq, color: Self.colors[b.n - 1])
    }

    private func callout(_ b: Band, _ g: GraphBand) -> String {
        var parts = ["\(b.n) · \(b.shape.map(store.display) ?? "Bell")", EQGraph.freqText(g.eq.freq)]
        if let r = b.rate { parts.append("decay " + store.display(r)) }
        if let q = b.q { parts.append("Q " + store.display(q)) }
        if !g.eq.enabled { parts.append("off") }
        return parts.joined(separator: " · ")
    }

    // MARK: Gestures

    private func beginDrag(_ b: Band) {
        dragStart = [:]
        for p in [b.freq, b.rate].compactMap({ $0 }) {
            store.beginTouch(p)
            dragStart[p.path] = store.value(p)
        }
    }

    private func drag(_ b: Band, freq: Double, rateDB: Double) {
        if let f = b.freq { store.set(f, numeric: freq) }
        if let r = b.rate { store.set(r, numeric: Self.percent(rateDB)) }
    }

    private func endDrag(_ b: Band) {
        for p in [b.freq, b.rate].compactMap({ $0 }) { store.endTouch(p) }
    }

    private func revertDrag(_ b: Band) {
        for p in [b.freq, b.rate].compactMap({ $0 }) { if let v = dragStart[p.path] { store.set(p, v) } }
    }

    private func beginPinch(_ b: Band) -> Bool {
        guard let q = b.q, let start = store.numeric(q), start > 0 else { return false }
        pinchStartQ = start
        store.beginTouch(q)
        return true
    }

    private func pinch(_ b: Band, _ scale: Double) {
        guard let q = b.q, let start = pinchStartQ else { return }
        store.set(q, numeric: start / scale)
    }

    private func endPinch(_ b: Band) {
        if let q = b.q { store.endTouch(q) }
        pinchStartQ = nil
    }

    private func resetRate(_ b: Band) {
        guard let r = b.rate, let hundred = r.midi(closestTo: 100) else { return }
        store.setTogether([(r, hundred)])
    }

    private func add(_ bands: [Band], freq: Double, rateDB: Double) {
        guard let b = bands.first(where: { !isUsed($0) && $0.used != nil }) else {
            return store.showToast("All \(Self.bandCount) decay EQ bands are in use", ok: false)
        }
        addBand(b, freq: freq, percent: Self.percent(rateDB))
    }

    private func addBand(_ b: Band, freq: Double, percent: Double) {
        let bell = b.shape?.stepCenters.first { $0.label == "Bell" }?.midi
        store.setTogether([(b.shape, bell ?? 0), (b.freq, b.freq?.midi(closestTo: freq) ?? 64),
                           (b.rate, b.rate?.midi(closestTo: percent) ?? 64), (b.enabled, 127), (b.used, 127)])
        selectedBand = b.n
    }

    // MARK: Chips and band panel

    private func bandChips(_ bands: [Band]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(bands, id: \.n) { b in
                let used = isUsed(b)
                let color = Self.colors[b.n - 1]
                Button { selectedBand = b.n } label: {
                    HStack(spacing: 6) {
                        Text(used ? "\(b.n)" : "+").font(.system(size: 12, weight: .heavy))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(used ? Theme.ground : color)
                            .background(Circle().fill(used ? color : Theme.raised2))
                        Text(used ? (b.rate.flatMap(store.numeric).map { String(format: "%.0f%%", $0) } ?? "") : "off")
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selectedBand == b.n ? color : .clear, lineWidth: 2))
                    .opacity(used ? 1 : 0.6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Decay band \(b.n)\(used ? "" : ", not in use")")
            }
        }
    }

    @ViewBuilder
    private func bandPanel(_ b: Band) -> some View {
        let color = Self.colors[b.n - 1]
        if isUsed(b) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("BAND \(b.n)").font(.system(size: 12, weight: .heavy)).foregroundStyle(color)
                    PluginToggle(param: b.enabled, title: "ON", color: color, height: 38)
                    Button { store.setTogether([(b.used, 0)]) } label: {
                        Text("REMOVE").font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity, minHeight: 38)
                            .foregroundStyle(Theme.text2).background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 100)
                PluginKnob(param: b.freq, title: "Freq", color: color, size: 50)
                PluginKnob(param: b.rate, title: "Decay", color: color, size: 50, resetValue: b.rate?.midi(closestTo: 100))
                PluginKnob(param: b.q, title: "Q", color: color, size: 50)
                VStack(alignment: .leading, spacing: 6) {
                    Text("SHAPE").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(Theme.text3)
                    PluginPicker(param: b.shape, columns: 2, color: color, label: ProQ3Page.short)
                }
                .frame(width: 200)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(spacing: 12) {
                Text("Decay band \(b.n) isn't in use. Tap the graph to add one, or add it here.").foregroundStyle(Theme.text2)
                ToggleChip(title: "ADD BAND \(b.n)", isOn: true, color: color) {
                    addBand(b, freq: Self.addFrequencies[b.n - 1], percent: 100)
                }
                .frame(width: 180)
                .disabled(b.used == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

import SwiftUI
import FOHCore

struct EQView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        let ref = store.selectedStrip
        let bands = store.eqBands(ref)
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                SourceLine(label: "EQ source:", plugin: store.selected?.plugin(at: store.selected?.processing.eq))
                Spacer()
                DragValueField(strip: ref, role: .trimIn, title: "IN TRIM").id(ref)
                DragValueField(strip: ref, role: .trimOut, title: "OUT TRIM").id(ref)
                RoleToggle(strip: ref, role: .eqOn, title: "EQ IN", color: Theme.eq).frame(width: 90)
            }
            if bands.isEmpty {
                UnboundPanel(text: "No EQ bound on this strip.")
            } else {
                // `.id`: switching strips mid-drag gets a fresh graph, not the old strip's drag/pinch state.
                EQGraph(strip: ref, bands: bands)
                    .id(ref)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(bands) { band in BandCard(strip: ref, band: band) }
                }
                .frame(height: 232)
            }
        }
        .onAppear { store.subscribeRTA(ref) }
        .onDisappear { store.subscribeRTA(nil) }
        .onChange(of: store.selectedStrip) { _, new in store.subscribeRTA(new) }
    }
}

/// Empty state for a page with nothing bound: explains and links to Setup › Processing.
struct UnboundPanel: View {
    @Environment(MixerStore.self) private var store
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Text(text).foregroundStyle(Theme.text2)
            ToggleChip(title: "BIND IN SETUP › PROCESSING", isOn: true, color: Theme.sends) { store.openSetup(.processing) }
                .frame(width: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The strip's input spectrum (1/6-octave, from the bridge's input tap) as a soft filled area behind the EQ curve.
struct RTAOverlay: View {
    @Environment(MeterStore.self) private var meters
    let strip: StripRef

    var body: some View {
        Canvas { ctx, size in
            guard let rta = meters.rta, rta.strip == strip.key, !rta.bands.isEmpty else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, b) in rta.bands.enumerated() where i < RTAFrame.bandCenters.count {
                let x = EQMath.x(for: RTAFrame.bandCenters[i], width: size.width)
                path.addLine(to: CGPoint(x: x, y: size.height * (1 - MeterScale.fraction(b))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .color(Theme.text.opacity(0.10)))
            ctx.stroke(path, with: .color(Theme.text.opacity(0.22)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Interactive EQ graph: grid, per-band responses, composite curve and draggable handles.
/// One finger drags a band's frequency and gain; a pinch anywhere sets the selected band's Q.
struct EQGraph: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let bands: [EQBand]
    @State private var dragging: String?
    /// Freq/gain MIDI values when the current drag began, restored if it turns into a pinch.
    @State private var dragStart: [Role: Int] = [:]
    /// A pinch took over this touch sequence: ignore the first finger's drag until it lifts.
    @State private var dragSuppressed = false
    @State private var pinching = false
    @State private var pinch: (role: Role, startQ: Double)?
    /// Reset when a gesture ends or is cancelled; a cancel skips `onEnded`, so `onChange` cleans up instead.
    @GestureState private var dragActive = false
    @GestureState private var pinchActive = false
    private let range = 18.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let engaged = store.eqEngaged(strip)
            ZStack(alignment: .topLeading) {
                RTAOverlay(strip: strip)
                Canvas { ctx, size in
                    drawGrid(ctx, size)
                    for b in bands where b.enabled {
                        ctx.stroke(EQMath.curve([b], size: size, range: range, points: 120), with: .color(Theme.eq.opacity(0.28)), lineWidth: 1)
                    }
                    let curve = EQMath.curve(engaged ? bands : [], size: size, range: range, points: 240)
                    var fill = curve
                    fill.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    fill.addLine(to: CGPoint(x: 0, y: size.height / 2))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .color(Theme.eq.opacity(engaged ? 0.12 : 0.04)))
                    ctx.stroke(curve, with: .color(engaged ? Theme.eq : Theme.text3), lineWidth: 2.5)
                }
                ForEach(bands) { b in
                    handle(b, size: size)
                }
                if let sel = bands.first(where: { $0.id == store.selectedEQHandle }) {
                    callout(sel, size: size)
                }
                Text("Input RTA · via Bridge").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                    .padding(8).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragActive) { _, state, _ in state = true }
                .onChanged { g in drag(g, size: size) }
                .onEnded { _ in
                    endDrag()
                    dragSuppressed = false
                })
            .simultaneousGesture(MagnifyGesture()
                .updating($pinchActive) { _, state, _ in state = true }
                .onChanged { g in magnify(g.magnification) }
                .onEnded { _ in endMagnify() })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in resetGain(at: tap.location, size: size) })
            .onChange(of: dragActive) { _, active in
                guard !active else { return }
                endDrag()
                dragSuppressed = false
            }
            .onChange(of: pinchActive) { _, active in if !active { endMagnify() } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("eq.graph")
        }
        .background(Theme.ground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func position(_ b: EQBand, _ size: CGSize) -> CGPoint {
        let x = EQMath.x(for: max(EQMath.fMin, min(EQMath.fMax, b.freq)), width: size.width)
        let y = b.hasGain ? EQMath.y(for: b.gain, height: size.height, range: range) : EQMath.y(for: -3, height: size.height, range: range)
        return CGPoint(x: min(max(x, 16), size.width - 16), y: min(max(y, 16), size.height - 16))
    }

    private func handle(_ b: EQBand, size: CGSize) -> some View {
        let selected = store.selectedEQHandle == b.id
        let text = b.id == "hpf" ? "H" : b.id == "lpf" ? "L" : String(b.id.last ?? "?")
        return Text(text)
            .font(.system(size: 12, weight: .heavy))
            .frame(width: 26, height: 26)
            .foregroundStyle(b.enabled ? Theme.ground : Theme.text3)
            .background(Circle().fill(b.enabled ? Theme.eq : Theme.raised2))
            .overlay(Circle().stroke(selected ? Theme.text : .clear, lineWidth: 2.5).padding(-3))
            .position(position(b, size))
            .accessibilityLabel("\(b.label) handle")
    }

    private func callout(_ b: EQBand, size: CGSize) -> some View {
        var parts = [Self.freqText(b.freq)]
        if b.hasGain { parts.append(String(format: "%@%.1f dB", b.gain > 0 ? "+" : "", b.gain)) }
        if b.kind == .peak { parts.append(String(format: "Q %.2f", b.q)) }
        if !b.enabled { parts = [b.kind == .highPass || b.kind == .lowPass ? "Out" : "Off"] }
        let p = position(b, size)
        return Text("\(b.label) · " + parts.joined(separator: " · "))
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.raised2, in: RoundedRectangle(cornerRadius: 8))
            .position(x: min(max(p.x, 110), size.width - 110), y: max(24, p.y - 34))
            .accessibilityIdentifier("eq.callout")
    }

    static func freqText(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.1f kHz", f / 1000) : String(format: "%.0f Hz", f)
    }

    private func roles(for id: String) -> (freq: Role?, gain: Role?) {
        switch id {
        case "hpf": return (Role["eq.hpfFreq"], nil)
        case "lpf": return (Role["eq.lpfFreq"], nil)
        default:
            let n = Int(id.split(separator: ".").last ?? "") ?? 0
            return (Role.band(n, "freq"), Role.band(n, "gain"))
        }
    }

    private func drag(_ g: DragGesture.Value, size: CGSize) {
        guard !dragSuppressed else { return }
        if dragging == nil {
            let nearest = bands.min { a, b in
                hypot(position(a, size).x - g.startLocation.x, position(a, size).y - g.startLocation.y) <
                    hypot(position(b, size).x - g.startLocation.x, position(b, size).y - g.startLocation.y)
            }
            guard let n = nearest, hypot(position(n, size).x - g.startLocation.x, position(n, size).y - g.startLocation.y) < 44 else { return }
            dragging = n.id
            store.selectedEQHandle = n.id
            let r = roles(for: n.id)
            dragStart = [:]
            for role in [r.freq, r.gain].compactMap({ $0 }) {
                store.beginTouch(strip, role)
                dragStart[role] = store.value(strip, role)
            }
        }
        guard let id = dragging else { return }
        // A tap selects without moving: only a real drag puts the band under the finger.
        guard hypot(g.translation.width, g.translation.height) >= 3 else { return }
        let r = roles(for: id)
        if let f = r.freq { store.setNumeric(strip, f, EQMath.freq(forX: g.location.x, width: size.width)) }
        if let gr = r.gain { store.setNumeric(strip, gr, EQMath.db(forY: g.location.y, height: size.height, range: range)) }
    }

    /// Double-tap a band's handle: its gain back to 0 dB.
    private func resetGain(at location: CGPoint, size: CGSize) {
        let nearest = bands.min { hypot(position($0, size).x - location.x, position($0, size).y - location.y) <
                                  hypot(position($1, size).x - location.x, position($1, size).y - location.y) }
        guard let band = nearest, hypot(position(band, size).x - location.x, position(band, size).y - location.y) < 44,
              let gain = roles(for: band.id).gain, let zero = store.zeroValue(strip, gain) else { return }
        store.selectedEQHandle = band.id
        if dragging != nil { endDrag() }
        dragSuppressed = true   // the rest of this touch mustn't drag the band back off 0 dB
        store.beginTouch(strip, gain)
        store.set(strip, gain, zero)
        store.endTouch(strip, gain)
    }

    private func endDrag() {
        if let id = dragging {
            let r = roles(for: id)
            if let f = r.freq { store.endTouch(strip, f) }
            if let gr = r.gain { store.endTouch(strip, gr) }
        }
        dragging = nil
    }

    /// Pinch: the selected band's Q. Spreading the fingers widens the bell (lower Q), as in Pro-Q and Mixing Station.
    /// Bands without a bound Q (the SSL's shelves) ignore it.
    private func magnify(_ scale: CGFloat) {
        if !pinching {
            pinching = true
            // The first finger's drag may have nudged the band before the pinch was recognised: put it back.
            if dragging != nil {
                for (role, midi) in dragStart { store.set(strip, role, midi) }
                endDrag()
            }
            dragSuppressed = true
            if let role = Role["\(store.selectedEQHandle).q"], store.isBound(strip, role),
               let q = store.numeric(strip, role), q > 0 {
                pinch = (role, q)
                store.beginTouch(strip, role)
            }
        }
        guard let p = pinch, scale > 0 else { return }
        store.setNumeric(strip, p.role, p.startQ / Double(scale))
    }

    private func endMagnify() {
        if let p = pinch { store.endTouch(strip, p.role) }
        pinch = nil
        pinching = false
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        let gridColor = Color(hex: 0x1E2126)
        for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            let x = EQMath.x(for: f, width: size.width)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(gridColor), lineWidth: 1)
            ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 10)).foregroundColor(Theme.text3),
                     at: CGPoint(x: x + 3, y: size.height - 10), anchor: .leading)
        }
        for db in [-18.0, -12, -6, 0, 6, 12, 18] {
            let y = EQMath.y(for: db, height: size.height, range: range)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                       with: .color(db == 0 ? Theme.line : gridColor), lineWidth: 1)
            if db != 18 && db != -18 {
                ctx.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(.system(size: 10)).foregroundColor(Theme.text3),
                         at: CGPoint(x: 6, y: y - 7), anchor: .leading)
            }
        }
    }
}

/// One band's bound controls. Only roles the binding provides are shown.
struct BandCard: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let band: EQBand

    var body: some View {
        let selected = store.selectedEQHandle == band.id
        VStack(spacing: 8) {
            HStack {
                Text(band.label).font(.system(size: 13, weight: .heavy))
                Spacer()
                Text(kindText).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text2)
            }
            HStack(alignment: .top, spacing: 2) {
                ForEach(roleIDs, id: \.self) { id in
                    if let role = Role[id] { RoleKnob(strip: strip, role: role, title: title(id), color: Theme.eq, size: 46) }
                }
            }
            if let typeRole = typeRole {
                RoleToggle(strip: strip, role: typeRole, title: "BELL", color: Theme.eq, height: 36)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.eq : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { store.selectedEQHandle = band.id }
    }

    private var kindText: String {
        switch band.kind {
        case .highPass: return band.enabled ? "\(Int(band.slope)) dB/oct" : "Out"
        case .lowPass: return band.enabled ? "\(Int(band.slope)) dB/oct" : "Out"
        case .lowShelf, .highShelf: return "Shelf"
        case .peak: return "Bell"
        case .notch: return "Notch"
        case .bandPass: return "Band pass"
        case .tiltShelf, .flatTilt: return "Tilt"
        }
    }

    private var roleIDs: [String] {
        switch band.id {
        case "hpf": return ["eq.hpfFreq", "eq.hpfSlope"]
        case "lpf": return ["eq.lpfFreq"]
        default: return ["\(band.id).gain", "\(band.id).freq", "\(band.id).q"]
        }
    }

    private var typeRole: Role? {
        guard band.id == "band.1" || band.id == "band.4", let r = Role["\(band.id).type"], store.isBound(strip, r) else { return nil }
        return r
    }

    private func title(_ id: String) -> String {
        switch id.split(separator: ".").last ?? "" {
        case "gain": return "Gain"
        case "q": return "Q"
        case "hpfSlope": return "Slope"
        default: return "Freq"
        }
    }
}

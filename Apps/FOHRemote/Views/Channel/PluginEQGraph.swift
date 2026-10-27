import SwiftUI
import FOHCore

/// One band on a plugin's graph (Pro-Q 3's EQ, Pro-R 2's decay-rate EQ).
struct GraphBand: Identifiable, Equatable {
    /// Band number, 1-based.
    let id: Int
    /// Shape for the curve, with `gain` in the graph's units.
    var eq: EQBand
    var color: Color
    /// Dynamic EQ: where the gain goes when the band is fully triggered (graph units), drawn as a second curve.
    var dynamicGain: Double?
}

/// The graph's vertical scale: a range in dB-like units and the grid lines with their labels.
struct GraphAxis {
    var min: Double
    var max: Double
    var lines: [(value: Double, label: String)]

    func y(_ v: Double, _ height: CGFloat) -> CGFloat { height * CGFloat((max - v) / (max - min)) }
    func value(_ y: CGFloat, _ height: CGFloat) -> Double { max - Double(y / Swift.max(height, 1)) * (max - min) }

    static let eq = GraphAxis(min: -18, max: 18, lines: [-12, -6, 0, 6, 12].map { ($0, $0 > 0 ? "+\(Int($0))" : "\(Int($0))") })
}

/// Interactive plugin EQ graph. One finger on a band drags its frequency and gain; a tap on empty graph adds a band
/// there; a pinch sets the selected band's Q; a double-tap on a band returns its gain to 0. The page owning the
/// graph maps all of this onto plugin controls.
struct PluginEQGraph: View {
    let bands: [GraphBand]
    let selected: Int?
    var axis: GraphAxis = .eq
    var engaged = true
    var rtaStrip: StripRef?
    var callout: (GraphBand) -> String
    var onSelect: (Int) -> Void
    var onDragBegin: (Int) -> Void
    /// Band, frequency (Hz), axis value.
    var onDrag: (Int, Double, Double) -> Void
    var onDragEnd: (Int) -> Void
    /// The first finger moved the band before a pinch took over: put it back.
    var onDragRevert: (Int) -> Void
    /// Returns false when the band has no Q to pinch.
    var onPinchBegin: (Int) -> Bool
    /// Band, magnification since the pinch began.
    var onPinch: (Int, Double) -> Void
    var onPinchEnd: (Int) -> Void
    var onDoubleTap: (Int) -> Void
    /// Frequency (Hz) and axis value where an empty part of the graph was tapped.
    var onAdd: (Double, Double) -> Void

    @State private var dragging: Int?
    /// Where the current one-finger touch began: a new start point means a new touch, whatever the last one left.
    @State private var touchStart: CGPoint?
    @State private var touchOnEmpty = false
    @State private var dragMoved = false
    /// A pinch or double-tap took over this touch sequence: ignore the first finger until it lifts.
    @State private var dragSuppressed = false
    @State private var pinching: Int?
    @State private var pinchStarted = false
    /// Reset when a gesture ends or is cancelled; a cancel skips `onEnded`, so `onChange` cleans up instead.
    @GestureState private var dragActive = false
    @GestureState private var pinchActive = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if let rtaStrip { RTAOverlay(strip: rtaStrip) }
                Canvas { ctx, size in draw(ctx, size) }
                ForEach(bands) { b in handle(b, size: size) }
                if let sel = bands.first(where: { $0.id == selected }) { calloutView(sel, size: size) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragActive) { _, state, _ in state = true }
                .onChanged { g in drag(g, size: size) }
                .onEnded { g in endDrag(at: g.location, translation: g.translation, size: size) })
            .simultaneousGesture(MagnifyGesture()
                .updating($pinchActive) { _, state, _ in state = true }
                .onChanged { g in magnify(g.magnification) }
                .onEnded { _ in endMagnify() })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in doubleTap(at: tap.location, size: size) })
            .onChange(of: dragActive) { _, active in if !active { cancelDrag() } }
            .onChange(of: pinchActive) { _, active in if !active { endMagnify() } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("plugin.graph")
        }
        .background(Theme.ground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    // MARK: Drawing

    private func curve(_ list: [EQBand], _ size: CGSize, points: Int) -> Path {
        var path = Path()
        for i in 0..<points {
            let t = Double(i) / Double(points - 1)
            let f = EQMath.fMin * pow(EQMath.fMax / EQMath.fMin, t)
            let v = max(axis.min - 3, min(axis.max + 3, EQMath.response(list, at: f)))
            let p = CGPoint(x: CGFloat(t) * size.width, y: axis.y(v, size.height))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func filled(_ line: Path, _ size: CGSize) -> Path {
        var fill = line
        let zero = axis.y(0, size.height)
        fill.addLine(to: CGPoint(x: size.width, y: zero))
        fill.addLine(to: CGPoint(x: 0, y: zero))
        fill.closeSubpath()
        return fill
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let grid = Color(hex: 0x1E2126)
        for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            let x = EQMath.x(for: f, width: size.width)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(grid), lineWidth: 1)
            ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 10)).foregroundColor(Theme.text3),
                     at: CGPoint(x: x + 3, y: size.height - 10), anchor: .leading)
        }
        for line in axis.lines {
            let y = axis.y(line.value, size.height)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                       with: .color(line.value == 0 ? Theme.line : grid), lineWidth: 1)
            ctx.draw(Text(line.label).font(.system(size: 10)).foregroundColor(Theme.text3), at: CGPoint(x: 6, y: y - 7), anchor: .leading)
        }
        for b in bands where b.eq.enabled {
            let mine = curve([b.eq], size, points: 110)
            let isSelected = b.id == selected
            ctx.fill(filled(mine, size), with: .color(b.color.opacity(engaged ? (isSelected ? 0.24 : 0.12) : 0.04)))
            if isSelected { ctx.stroke(mine, with: .color(b.color.opacity(engaged ? 0.8 : 0.3)), lineWidth: 1.5) }
            if let dyn = b.dynamicGain {
                var moved = b.eq
                moved.gain = dyn
                ctx.stroke(curve([moved], size, points: 110), with: .color(b.color.opacity(engaged ? 0.9 : 0.3)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        let all = curve(engaged ? bands.map(\.eq) : [], size, points: 240)
        ctx.stroke(all, with: .color(engaged ? Theme.text : Theme.text3), lineWidth: 2.5)
    }

    private func position(_ b: GraphBand, _ size: CGSize) -> CGPoint {
        let x = EQMath.x(for: max(EQMath.fMin, min(EQMath.fMax, b.eq.freq)), width: size.width)
        let y = axis.y(b.eq.hasGain ? b.eq.gain : 0, size.height)
        return CGPoint(x: min(max(x, 16), size.width - 16), y: min(max(y, 16), size.height - 16))
    }

    private func handle(_ b: GraphBand, size: CGSize) -> some View {
        let isSelected = selected == b.id
        let p = position(b, size)
        return ZStack {
            if let dyn = b.dynamicGain, b.eq.hasGain {
                // The dynamic range as a bar from the band's gain to where it goes when triggered.
                let dy = axis.y(dyn, size.height) - p.y
                Capsule().fill(b.color.opacity(0.45))
                    .frame(width: 6, height: max(abs(dy), 6))
                    .offset(y: dy / 2)
            }
            Text("\(b.id)")
                .font(.system(size: 12, weight: .heavy))
                .frame(width: 28, height: 28)
                .foregroundStyle(b.eq.enabled ? Theme.ground : b.color)
                .background(Circle().fill(b.eq.enabled ? b.color : Theme.raised2))
                .overlay(Circle().stroke(isSelected ? Theme.text : (b.eq.enabled ? .clear : b.color), lineWidth: isSelected ? 2.5 : 1.5)
                    .padding(isSelected ? -3 : 0))
        }
        .position(p)
        .accessibilityLabel("Band \(b.id)")
        .accessibilityValue(callout(b))
    }

    private func calloutView(_ b: GraphBand, size: CGSize) -> some View {
        let p = position(b, size)
        return Text(callout(b))
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.raised2, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(b.color.opacity(0.6)))
            .position(x: min(max(p.x, 150), size.width - 150), y: p.y > 60 ? p.y - 36 : p.y + 40)
            .allowsHitTesting(false)
            .accessibilityIdentifier("plugin.callout")
    }

    // MARK: Gestures

    private func nearest(to point: CGPoint, _ size: CGSize) -> GraphBand? {
        let best = bands.min { hypot(position($0, size).x - point.x, position($0, size).y - point.y) <
                               hypot(position($1, size).x - point.x, position($1, size).y - point.y) }
        guard let b = best, hypot(position(b, size).x - point.x, position(b, size).y - point.y) < 44 else { return nil }
        return b
    }

    private func drag(_ g: DragGesture.Value, size: CGSize) {
        if g.startLocation != touchStart {
            touchStart = g.startLocation
            if let id = dragging { onDragEnd(id) }
            dragging = nil
            touchOnEmpty = false
            dragMoved = false
            dragSuppressed = pinchStarted
        }
        guard !dragSuppressed else { return }
        if dragging == nil && !touchOnEmpty {
            if let b = nearest(to: g.startLocation, size) {
                dragging = b.id
                dragMoved = false
                onSelect(b.id)
                onDragBegin(b.id)
            } else {
                touchOnEmpty = true
            }
        }
        guard let id = dragging else { return }
        // A tap selects without moving: only a real drag puts the band under the finger.
        guard dragMoved || hypot(g.translation.width, g.translation.height) >= 3 else { return }
        dragMoved = true
        onDrag(id, EQMath.freq(forX: g.location.x, width: size.width), axis.value(g.location.y, size.height))
    }

    private func endDrag(at location: CGPoint, translation: CGSize, size: CGSize) {
        if let id = dragging {
            onDragEnd(id)
        } else if touchOnEmpty, !dragSuppressed, hypot(translation.width, translation.height) < 8 {
            onAdd(EQMath.freq(forX: location.x, width: size.width), axis.value(location.y, size.height))
        }
        dragging = nil
        touchOnEmpty = false
        dragMoved = false
        touchStart = nil
    }

    /// The touch was cancelled (`onEnded` never comes): release the band. The next touch resets the rest.
    private func cancelDrag() {
        if let id = dragging { onDragEnd(id) }
        dragging = nil
    }

    private func doubleTap(at location: CGPoint, size: CGSize) {
        guard let b = nearest(to: location, size) else { return }
        if let id = dragging { onDragEnd(id); dragging = nil }
        dragSuppressed = true   // the rest of this touch mustn't drag the band back off 0
        onSelect(b.id)
        onDoubleTap(b.id)
    }

    private func magnify(_ scale: CGFloat) {
        if !pinchStarted {
            pinchStarted = true
            if let id = dragging {
                if dragMoved { onDragRevert(id) }
                onDragEnd(id)
                dragging = nil
            }
            touchOnEmpty = false
            dragSuppressed = true
            if let id = selected, onPinchBegin(id) { pinching = id }
        }
        guard let id = pinching, scale > 0 else { return }
        onPinch(id, Double(scale))
    }

    private func endMagnify() {
        if let id = pinching { onPinchEnd(id) }
        pinching = nil
        pinchStarted = false
    }
}

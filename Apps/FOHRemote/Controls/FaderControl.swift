import SwiftUI
import FOHCore

/// Vertical fader in MIDI units. Cap position is linear in MIDI value (MainStage volume is a linear CC),
/// so 0 dB sits at ≈ 90/127 with the estimated law. Double-tap returns to `resetValue` (0 dB).
struct FaderControl: View {
    var value: Int
    var capColor: Color = Theme.faderCap
    var capWidth: CGFloat = 30
    var showScale = true
    /// Meter levels 0…1; empty draws a dim placeholder. Ignored when `meter` is set.
    var meterLevels: [Double] = []
    /// Live meter drawn beside the track (reads `MeterStore`).
    var meter: MeterTarget? = nil
    var fine = false
    /// Double-tap target: the strip's 0 dB (from its binding, so calibration counts).
    var resetValue: Int = 90
    var onChange: (Int) -> Void
    var onTouch: (Bool) -> Void = { _ in }

    @State private var dragStart: Int?
    /// A double-tap snapped this touch: its drag must not send the start value back a frame later.
    @State private var snapped = false
    /// Resets when the drag ends or is cancelled; a cancel skips `onEnded`, so `onChange` ends the touch instead.
    @GestureState private var dragging = false
    private let capHeight: CGFloat = 22

    static let ticks: [(db: Double, label: String)] = [(6, "+6"), (0, "0"), (-5, "5"), (-10, "10"), (-20, "20"), (-30, "30"), (-40, "40"), (-60, "60")]

    static func midi(forDB db: Double) -> Double { 127 * pow(10, (db - 6) / 40) }

    /// Movement (points) below which a touch is a tap, not a drag. Taps used to re-send the start value, which
    /// undid a double-tap's snap one frame later.
    static let tapSlop: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let usable = h - capHeight
            let w = geo.size.width
            let trackX = showScale ? w * 0.42 : w * 0.4
            ZStack(alignment: .topLeading) {
                if showScale {
                    ForEach(Self.ticks, id: \.label) { t in
                        let y = (1 - CGFloat(Self.midi(forDB: t.db) / 127)) * usable + capHeight / 2
                        Text(t.label)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.text3)
                            .frame(width: trackX - 10, alignment: .trailing)
                            .position(x: (trackX - 10) / 2, y: y)
                        Rectangle().fill(Color(hex: 0x3A3F46)).frame(width: 5, height: 1)
                            .position(x: trackX - 6, y: y)
                    }
                    Text("∞").font(.system(size: 9)).foregroundStyle(Theme.text3)
                        .frame(width: trackX - 10, alignment: .trailing)
                        .position(x: (trackX - 10) / 2, y: h - capHeight / 2)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.line, lineWidth: 1))
                    .frame(width: 4, height: usable)
                    .position(x: trackX, y: h / 2)
                meter(height: h)
                    .position(x: w - 6, y: h / 2)
                RoundedRectangle(cornerRadius: 4)
                    .fill(capColor)
                    .overlay(Rectangle().fill(Theme.ground).frame(height: 2).padding(.horizontal, 4))
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
                    .frame(width: capWidth, height: capHeight)
                    .position(x: trackX, y: (1 - CGFloat(value) / 127) * usable + capHeight / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { g in
                        if dragStart == nil { dragStart = value; snapped = false; onTouch(true) }
                        guard !snapped, abs(g.translation.height) >= Self.tapSlop else { return }   // a tap isn't a move
                        let delta = -Double(g.translation.height / max(usable, 1)) * 127 / (fine ? 4 : 1)
                        guard delta.isFinite else { return }
                        onChange(FOHProtocol.clampMIDI(Int((Double(dragStart ?? value) + delta).rounded())))
                    }
                    .onEnded { _ in endDrag() }
            )
            .onChange(of: dragging) { _, active in if !active { endDrag() } }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                snapped = true
                onTouch(true); onChange(resetValue); onTouch(false)
            })
        }
        // One adjustable element for VoiceOver and UI tests; callers add the label, identifier and display value.
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            onTouch(true)
            onChange(FOHProtocol.clampMIDI(value + (direction == .increment ? 4 : -4)))
            onTouch(false)
        }
    }

    /// Called from both `onEnded` and the cancel path; only the first ends the touch.
    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        onTouch(false)
    }

    @ViewBuilder
    private func meter(height: CGFloat) -> some View {
        if let meter {
            LiveMeter(target: meter).frame(height: height)
        } else if meterLevels.isEmpty {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 8, height: height)
        } else {
            HStack(spacing: 2) {
                ForEach(Array(meterLevels.enumerated()), id: \.offset) { _, level in
                    ZStack(alignment: .top) {
                        LinearGradient(colors: [Theme.meterRed, Theme.meterYellow, Theme.meterGreen, Theme.meterGreen],
                                       startPoint: .top, endPoint: .bottom)
                        Color(hex: 0x101215).frame(height: height * CGFloat(1 - level))
                    }
                    .frame(width: meterLevels.count == 1 ? 8 : 4, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
        }
    }
}

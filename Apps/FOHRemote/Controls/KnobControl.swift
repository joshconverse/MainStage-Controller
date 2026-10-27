import SwiftUI
import FOHCore

/// Rotary control in MIDI units: drag up/down (160 pt = full range, ÷4 in fine mode).
struct KnobControl: View {
    var title: String
    var value: Int
    var display: String
    var color: Color
    var size: CGFloat = 64
    var caption: String?
    var fine = false
    /// MainStage hasn't confirmed this value (shows "≈").
    var assumed = false
    /// Double-tap target (0 dB for gains); nil turns double-tap off.
    var resetValue: Int? = nil
    var onChange: (Int) -> Void
    var onTouch: (Bool) -> Void = { _ in }

    @State private var dragStart: Int?
    /// A double-tap snapped this touch: its drag must not send the start value back.
    @State private var snapped = false
    /// Resets when the drag ends or is cancelled; a cancel skips `onEnded`, so `onChange` ends the touch instead.
    @GestureState private var dragging = false

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Theme.raised2, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * CGFloat(value) / 127)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().fill(Theme.raised).padding(9)
                Capsule().fill(Theme.text)
                    .frame(width: 3, height: size * 0.22)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.degrees(-135 + 270 * Double(value) / 127))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { g in
                        if dragStart == nil { dragStart = value; snapped = false; onTouch(true) }
                        guard !snapped, abs(g.translation.height) >= FaderControl.tapSlop else { return }
                        let delta = -Double(g.translation.height) / 160 * 127 / (fine ? 4 : 1)
                        guard delta.isFinite else { return }
                        onChange(FOHProtocol.clampMIDI(Int((Double(dragStart ?? value) + delta).rounded())))
                    }
                    .onEnded { _ in endDrag() }
            )
            .onChange(of: dragging) { _, active in if !active { endDrag() } }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard let resetValue else { return }
                snapped = true
                onTouch(true); onChange(resetValue); onTouch(false)
            })
            AssumedText(text: display, assumed: assumed)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(minWidth: size + 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(assumed ? "\(display), not confirmed by MainStage" : display)
        .accessibilityAdjustableAction { dir in
            onChange(FOHProtocol.clampMIDI(value + (dir == .increment ? 1 : -1)))
        }
    }

    /// Called from both `onEnded` and the cancel path; only the first ends the touch.
    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        onTouch(false)
    }
}

import SwiftUI
import FOHCore

/// Lit/unlit button (mute, solo, EQ IN, fast attack…). Lit = accent fill with dark text.
struct ToggleChip: View {
    var title: String
    var isOn: Bool
    var color: Color
    var height: CGFloat = 44
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: height)
                .padding(.horizontal, 6)
                .foregroundStyle(isOn ? Theme.ground : Theme.text2)
                .background(isOn ? color : Theme.raised, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Grid of discrete choices built from `RoleBinding.stepCenters` (Waves Tune key / scale).
struct SteppedPicker: View {
    var options: [(midi: Int, label: String)]
    var selected: String
    var columns: Int
    var color: Color
    var onSelect: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(options, id: \.midi) { o in
                Button { onSelect(o.midi) } label: {
                    Text(o.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 4)
                        .foregroundStyle(o.label == selected ? Theme.ground : Theme.text)
                        .background(o.label == selected ? color : Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Horizontal pan control (MIDI 64 = centre). Double-tap centres.
struct PanBar: View {
    var value: Int
    var label: String
    var onChange: (Int) -> Void
    var onTouch: (Bool) -> Void = { _ in }
    @State private var dragStart: Int?
    /// A double-tap centred this touch: its drag must not send the start value back.
    @State private var snapped = false
    /// Resets when the drag ends or is cancelled; a cancel skips `onEnded`, so `onChange` ends the touch instead.
    @GestureState private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width - 8, 1)
            let center = 4 + w / 2
            let x = 4 + CGFloat(value) / 127 * w
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.raised)
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity).padding(.top, 3)
                Capsule().fill(Theme.ground).frame(width: w, height: 5).offset(x: 4, y: 19)
                Rectangle().fill(Color(hex: 0x6B727B)).frame(width: abs(x - center), height: 5).offset(x: min(x, center), y: 19)
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.text).frame(width: 3, height: 11).offset(x: x - 1.5, y: 16)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { g in
                    if dragStart == nil { dragStart = value; snapped = false; onTouch(true) }
                    guard !snapped, abs(g.translation.width) >= FaderControl.tapSlop else { return }
                    let delta = Double(g.translation.width / w) * 127 / 2
                    guard delta.isFinite else { return }
                    onChange(FOHProtocol.clampMIDI(Int((Double(dragStart ?? value) + delta).rounded())))
                }
                .onEnded { _ in endDrag() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { snapped = true; onTouch(true); onChange(64); onTouch(false) })
            .onChange(of: dragging) { _, active in if !active { endDrag() } }
        }
        .frame(height: 30)
    }

    /// Called from both `onEnded` and the cancel path; only the first ends the touch.
    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        onTouch(false)
    }
}

/// A value readout that marks values MainStage hasn't confirmed yet: a small "≈" and a dimmer colour.
struct AssumedText: View {
    let text: String
    let assumed: Bool
    var font: Font = .system(size: 13, weight: .bold).monospacedDigit()
    var color: Color = Theme.text

    var body: some View {
        (assumed ? Text("≈ ").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.text3) : Text(""))
            + Text(text).font(font).foregroundColor(assumed ? Theme.text2 : color)
    }
}

/// Address chip: "ch 1 · CC 26".
struct CCChip: View {
    var strip: StripRef
    var role: Role
    var body: some View {
        Text("ch \(strip.channel) · CC \(role.cc)")
            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.text3)
    }
}

extension RoleBinding {
    /// Two-state parameters that aren't flagged boolean (Waves Tune "Formant": Off/On over 0…1) render as switches.
    var behavesAsToggle: Bool { kind == .toggle || stepCenters.count == 2 }

    /// Display text with the plugin's unit appended when the text has none ("-3.5" → "-3.5 dB").
    func formatted(_ midi: Int) -> String {
        let text = display(midi)
        guard let unit = unitName, !unit.isEmpty, text.rangeOfCharacter(from: .letters) == nil,
              text.rangeOfCharacter(from: .decimalDigits) != nil else { return text }
        let u = unit.lowercased() == "khz" ? "kHz" : unit
        return "\(text) \(u)"
    }
}

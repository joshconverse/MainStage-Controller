import SwiftUI
import FOHCore

/// Knob bound to one role on one strip. Renders nothing if the role isn't bound (unbound roles are hidden).
struct RoleKnob: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let role: Role
    var title: String?
    var color: Color = Theme.eq
    var size: CGFloat = 64

    var body: some View {
        if let b = store.binding(strip, role) {
            KnobControl(title: title ?? b.parameterName, value: store.value(strip, role), display: b.formatted(store.value(strip, role)),
                        color: color, size: size, caption: "\(b.parameterName) · CC \(role.cc)", fine: store.fineMode,
                        assumed: store.isAssumed(strip, role), resetValue: store.zeroValue(strip, role),
                        onChange: { store.set(strip, role, $0) },
                        onTouch: { $0 ? store.beginTouch(strip, role) : store.endTouch(strip, role) })
                .id(strip)   // knobs are reused across strips: don't carry a drag's start to the next one
        }
    }
}

/// On/off chip bound to one role. Hidden when unbound.
struct RoleToggle: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let role: Role
    var title: String
    var color: Color
    var height: CGFloat = 44

    var body: some View {
        if store.isBound(strip, role) {
            ToggleChip(title: title, isOn: store.isOn(strip, role), color: color, height: height) {
                store.toggle(strip, role)
            }
        }
    }
}

/// Two-way segmented switch using the parameter's own labels ("Exp" | "Gate").
struct RoleSegmented: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let role: Role
    var color: Color

    var body: some View {
        if let b = store.binding(strip, role) {
            let options = b.stepCenters
            HStack(spacing: 4) {
                ForEach(options, id: \.midi) { o in
                    let selected = b.display(store.value(strip, role)) == o.label
                    Button { store.set(strip, role, o.midi < 64 ? 0 : 127) } label: {
                        Text(o.label)
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? Theme.ground : Theme.text2)
                            .background(selected ? color : Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Small mini-EQ thumbnail for mixer strips.
struct MiniEQView: View {
    var bands: [EQBand]
    var engaged: Bool
    var source: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                           with: .color(Theme.raised2), lineWidth: 1)
                let curve = EQMath.curve(engaged ? bands : [], size: size, range: 15, points: 48)
                ctx.stroke(curve, with: .color(engaged && !bands.isEmpty ? Theme.eq : Color(hex: 0x4A5058)), lineWidth: 1.5)
            }
            Text(source)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.text3)
                .padding(.leading, 3)
                .padding(.top, 1)
        }
        .background(Theme.ground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
    }
}

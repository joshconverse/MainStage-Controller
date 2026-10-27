import SwiftUI
import FOHCore

struct MixerView: View {
    @Environment(MixerStore.self) private var store
    @State private var layer = "All"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MixerSidebar(layer: $layer)
                .frame(width: 112)
            VStack(alignment: .leading, spacing: 6) {
                header
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(groups, id: \.title) { g in
                            VStack(alignment: .leading, spacing: 4) {
                                SectionLabel("\(g.title) · \(g.strips.count)").frame(height: 14).padding(.leading, 4)
                                HStack(spacing: 2) {
                                    ForEach(g.strips) { StripView(strip: $0) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity)
            MasterSection()
                .frame(width: 160)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let n = store.sendsOnFaders, let bus = store.config.sends.first(where: { $0.index == n }) {
                Text("Sends on faders → \(bus.name)").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(hex: 0x5EEAD4))
                Text("Faders show each input’s send to \(bus.name) · tap Main to return").font(.system(size: 12)).foregroundStyle(Theme.text2)
            } else {
                Text("\(layer == "All" ? "All strips" : layer) · Main mix").font(.system(size: 14, weight: .bold))
                Text("Tap a name for channel detail · tap G / C / inserts to jump there").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 4)
    }

    private var groups: [(title: String, strips: [Strip])] {
        if store.sendsOnFaders != nil { return [("Inputs", store.inputs)] }
        let all: [(String, [Strip])] = [("Inputs", store.inputs), ("FX returns", store.fxReturns), ("Outputs", store.outputs)]
        switch layer {
        case "Inputs": return [all[0]]
        case "FX returns": return [all[1]]
        case "Outputs": return [all[2]]
        default: return all.filter { !$0.1.isEmpty }
        }
    }
}

struct MixerSidebar: View {
    @Environment(MixerStore.self) private var store
    @Binding var layer: String

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Layers").padding(.horizontal, 4)
            ForEach(["All", "Inputs", "FX returns", "Outputs"], id: \.self) { l in
                sidebarButton(l, active: layer == l, activeColor: Theme.text) { layer = l }
            }
            SectionLabel("Sends on faders").padding(.horizontal, 4).padding(.top, 12)
            sidebarButton("Main", active: store.sendsOnFaders == nil, activeColor: Theme.text, height: 40) { store.sendsOnFaders = nil }
            ForEach(store.config.sends) { bus in
                sidebarButton(bus.name, active: store.sendsOnFaders == bus.index, activeColor: Theme.sends, height: 40) {
                    store.sendsOnFaders = bus.index
                }
            }
            Spacer()
            Button { store.fineMode.toggle() } label: {
                Text("Fine").font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(store.fineMode ? Theme.ground : Theme.text)
                    .background(store.fineMode ? Theme.text : Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            }
            .buttonStyle(.plain)
            Text("Meters: inputs pre-fader (Bridge input tap) · outputs (MainStage tap)")
                .font(.system(size: 10)).foregroundStyle(Theme.text3).padding(.horizontal, 2)
        }
    }

    private func sidebarButton(_ title: String, active: Bool, activeColor: Color, height: CGFloat = 44, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .padding(.horizontal, 12)
                .foregroundStyle(active ? Theme.ground : Theme.text)
                .background(active ? activeColor : Theme.raised, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct MasterSection: View {
    @Environment(MixerStore.self) private var store
    @State private var click = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Master").frame(height: 14).padding(.leading, 4).padding(.top, 34)
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("GLOBAL · CH 1").font(.system(size: 9.5, weight: .bold)).opacity(0.8)
                    Text(store.master?.name ?? "Master").font(.system(size: 13, weight: .heavy))
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 8)
                .foregroundStyle(Theme.ground)
                .background(Theme.text, in: RoundedRectangle(cornerRadius: 6))

                if store.guardMaster { MasterArmButton() }
                ToggleChip(title: "CLICK", isOn: click, color: Theme.eq) { click.toggle() }
                ToggleChip(title: "MUTE MASTER", isOn: store.isOn(.master, .mute), color: Theme.mute) { store.toggle(.master, .mute) }

                FaderControl(value: store.value(.master, .fader), capWidth: 44, meter: .master, fine: store.fineMode,
                             resetValue: store.zeroValue(.master, .fader) ?? 90,
                             onChange: { store.set(.master, .fader, $0) },
                             onTouch: { $0 ? store.beginTouch(.master, .fader) : store.endTouch(.master, .fader) })
                    .padding(.top, 6)
                Text(StripView.faderText(store.display(.master, .fader)))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .padding(.bottom, 6)
            }
            .padding(6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// "Guard master": hold 0.5 s to arm the master fader and mute for 5 s (any master move re-arms).
struct MasterArmButton: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let remaining = store.masterArmedUntil.map { $0.timeIntervalSince(context.date) } ?? 0
            let armed = remaining > 0
            Text(armed ? "ARMED · \(Int(remaining.rounded(.up)))s" : "HOLD TO ARM")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(armed ? Theme.ground : Theme.eq)
                .background(armed ? Theme.eq : Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(armed ? .clear : Theme.eq.opacity(0.6), lineWidth: 1))
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) { store.armMaster() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(armed ? "Master armed" : "Hold to arm master")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { store.armMaster() }
        }
    }
}

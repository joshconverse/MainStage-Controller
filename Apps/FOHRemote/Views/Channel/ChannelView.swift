import SwiftUI
import FOHCore

/// Channel frame shared by EQ / Dynamics / Inserts / Sends: selected strip on the left, sends on the right.
struct ChannelView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SelectedStripCard().frame(width: 96)
            VStack(spacing: 10) {
                ChannelHeader()
                Group {
                    switch store.channelSection {
                    case .eq: EQView()
                    case .dynamics: DynamicsView()
                    case .inserts: InsertsView()
                    case .sends: ChannelSendsView(strip: store.selectedStrip)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            SendsColumn().frame(width: 132)
        }
    }
}

extension ChannelSection {
    var accent: Color {
        switch self {
        case .dynamics: return Theme.dynamics
        case .eq: return Theme.eq
        case .inserts: return Theme.inserts
        case .sends: return Theme.sends
        }
    }
}

struct ChannelHeader: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            Button { store.stepChannel(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44).background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).accessibilityLabel("Previous channel")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            .frame(minWidth: 180, alignment: .leading)
            Button { store.stepChannel(1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44).background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).accessibilityLabel("Next channel")

            Spacer()
            HStack(spacing: 4) {
                ForEach(ChannelSection.allCases) { s in
                    Button { store.channelSection = s } label: {
                        Text(s.rawValue).font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18).frame(height: 40)
                            .foregroundStyle(store.channelSection == s ? Theme.ground : Theme.text)
                            .background(store.channelSection == s ? s.accent : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.channelSection == s ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
        }
        .frame(height: 56)
    }

    private var title: String {
        guard let s = store.selected else { return "—" }
        let num = s.ref.kind == .input ? "\(s.ref.slot)" : s.ref.kind == .fx ? "FX \(s.ref.slot)" : s.ref.kind == .output ? "OUT \(s.ref.slot)" : ""
        return num.isEmpty ? s.name : "\(num) · \(s.name)"
    }

    private var subtitle: String {
        guard let s = store.selected else { return "" }
        var parts: [String] = []
        if let io = s.hardwareIO { parts.append(io) }
        parts.append(s.stereo ? "stereo" : "mono")
        if let ms = s.mainStage { parts.append(ms.level == .patch ? (ms.patchName ?? "patch") : "concert") }
        return parts.joined(separator: " · ")
    }
}

/// Left column: the selected strip's tag, fader, mute/solo and pan.
struct SelectedStripCard: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        let ref = store.selectedStrip
        VStack(spacing: 6) {
            if let s = store.selected {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.kind == .input ? "\(ref.slot)" : ref.key.uppercased()).font(.system(size: 10, weight: .bold)).opacity(0.8)
                    Text(s.name).font(.system(size: 13, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 6)
                .foregroundStyle(Theme.channelText(s.color))
                .background(Theme.channel(s.color), in: RoundedRectangle(cornerRadius: 6))
            }
            // `.id`: a new strip gets fresh controls, so a drag in progress can't carry one strip's start to another.
            PanBar(value: store.value(ref, .pan), label: panText(store.value(ref, .pan)),
                   onChange: { store.set(ref, .pan, $0) },
                   onTouch: { $0 ? store.beginTouch(ref, .pan) : store.endTouch(ref, .pan) })
                .id(ref)
            FaderControl(value: store.value(ref, .fader), capWidth: 34, meter: store.selected.map { .strip($0) }, fine: store.fineMode,
                         resetValue: store.zeroValue(ref, .fader) ?? 90,
                         onChange: { store.set(ref, .fader, $0) },
                         onTouch: { $0 ? store.beginTouch(ref, .fader) : store.endTouch(ref, .fader) })
                .id(ref)
                .padding(.top, 4)
            AssumedText(text: StripView.faderText(store.display(ref, .fader)), assumed: store.isAssumed(ref, .fader))
            ToggleChip(title: "MUTE", isOn: store.isOn(ref, .mute), color: Theme.mute) { store.toggle(ref, .mute) }
            if ref.kind != .master {
                ToggleChip(title: "SOLO", isOn: store.isOn(ref, .solo), color: Theme.solo) { store.toggle(ref, .solo) }
            }
        }
        .padding(6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func panText(_ v: Int) -> String { v == 64 ? "C" : (v < 64 ? "L\(64 - v)" : "R\(v - 64)") }
}

/// Right column: quick view of the selected strip's sends.
struct SendsColumn: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        let ref = store.selectedStrip
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Sends")
            if ref.kind == .input {
                ForEach(store.config.sends) { bus in
                    if let role = Role.send(bus.index, "level"), store.isBound(ref, role) {
                        let on = Role.send(bus.index, "on").map { store.isOn(ref, $0) } ?? true
                        Button { store.channelSection = .sends } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(bus.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                    Spacer(minLength: 2)
                                    Text(StripView.faderText(store.display(ref, role))).font(.system(size: 11, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(on ? Theme.text : Theme.text3)
                                }
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.ground)
                                        Capsule().fill(on ? Theme.sends : Theme.text3).frame(width: g.size.width * CGFloat(store.value(ref, role)) / 127)
                                    }
                                }
                                .frame(height: 4)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(store.config.sends.count..<8, id: \.self) { i in
                    Text("Send \(i + 1) · not assigned").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            } else {
                Text("Sends are on inputs.").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Horizontal drag field for compact values (input/output trim).
struct DragValueField: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let role: Role
    let title: String
    @State private var dragStart: Int?
    /// Resets when the drag ends or is cancelled; a cancel skips `onEnded`, so `onChange` ends the touch instead.
    @GestureState private var dragging = false

    var body: some View {
        if let b = store.binding(strip, role) {
            let v = store.value(strip, role)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text2)
                    Text("\(b.parameterName) · CC \(role.cc)").font(.system(size: 9.5)).foregroundStyle(Theme.text3)
                }
                AssumedText(text: b.formatted(v), assumed: store.isAssumed(strip, role), font: .system(size: 14, weight: .bold).monospacedDigit())
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { g in
                    if dragStart == nil { dragStart = v; store.beginTouch(strip, role) }
                    let delta = g.translation.width / (store.fineMode ? 8 : 2)
                    guard delta.isFinite else { return }
                    store.set(strip, role, (dragStart ?? v) + Int(delta.rounded()))
                }
                .onEnded { _ in endDrag() })
            .onChange(of: dragging) { _, active in if !active { endDrag() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(b.formatted(v))
            .accessibilityAdjustableAction { dir in store.set(strip, role, v + (dir == .increment ? 1 : -1)) }
        }
    }

    /// Called from both `onEnded` and the cancel path; only the first ends the touch.
    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        store.endTouch(strip, role)
    }
}

/// "Rebind…" → Setup › Processing for the selected strip.
struct RebindButton: View {
    @Environment(MixerStore.self) private var store
    var body: some View {
        Button { store.openSetup(.processing) } label: {
            Text("Rebind…").foregroundStyle(Theme.sends).underline()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Setup › Processing for this channel")
    }
}

/// "EQ source: Waves SSL Channel · insert 3"
struct SourceLine: View {
    let label: String
    let plugin: PluginRef?
    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Theme.text2)
            if let plugin {
                Text("\(plugin.name)\(plugin.preset.map { " · \($0)" } ?? "") · insert \(plugin.position)").fontWeight(.semibold)
            } else {
                Text("none bound").foregroundStyle(Theme.text3)
            }
            RebindButton()
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
    }
}

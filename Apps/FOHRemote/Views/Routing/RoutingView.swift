import SwiftUI
import FOHCore

/// Routing: the sends matrix (inputs × configured sends) plus the selected input's sends, I/O and buses.
struct RoutingView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Sends matrix").font(.system(size: 20, weight: .bold))
                    Text("Drag a cell to set the level · tap ON to switch a send · tap a column to put it on the faders")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    Spacer()
                }
                SendsMatrix()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            RoutingSidePanel().frame(width: 380)
        }
    }
}

struct SendsMatrix: View {
    @Environment(MixerStore.self) private var store
    private let rowHeaderWidth: CGFloat = 150

    var body: some View {
        let sends = store.config.sends
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Color.clear.frame(width: rowHeaderWidth, height: 1)
                ForEach(sends) { bus in columnHeader(bus) }
                if sends.count < 8 {
                    Button { store.openSetup(.channels) } label: {
                        Label("Add send", systemImage: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                            .frame(width: 92, height: 74)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(store.inputs) { strip in
                HStack(spacing: 4) {
                    rowHeader(strip)
                    ForEach(sends) { bus in
                        MatrixCell(strip: strip.ref, bus: bus, selected: store.selectedStrip == strip.ref)
                    }
                    if sends.count < 8 { Color.clear.frame(width: 92, height: 1) }
                }
            }
            HStack(spacing: 4) {
                Button { store.openSetup(.channels) } label: {
                    Label("Add input", systemImage: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                        .frame(width: rowHeaderWidth, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func columnHeader(_ bus: SendBus) -> some View {
        Button {
            store.sendsOnFaders = bus.index
            store.tab = .mixer
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(bus.name).font(.system(size: 12.5, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                ConcertTag(inConcert: bus.existsInConcert, yes: "✓ in concert", no: "not in concert")
                Text("on faders →").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.sends)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(bus.name) — show on faders")
    }

    private func rowHeader(_ strip: Strip) -> some View {
        Button { store.selectedStrip = strip.ref } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.channel(strip.color)).frame(width: 8, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(strip.ref.slot)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
                    Text(strip.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: rowHeaderWidth, height: 64)
            .background(store.selectedStrip == strip.ref ? Theme.raised2 : Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(store.selectedStrip == strip.ref ? Theme.text : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// One input → send cell: drag horizontally for level, ON button in the corner.
struct MatrixCell: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let bus: SendBus
    let selected: Bool
    @State private var dragStart: Int?
    /// Resets when the drag ends or is cancelled; a cancel skips `onEnded`, so `onChange` ends the touch instead.
    @GestureState private var dragging = false

    var body: some View {
        if let level = Role.send(bus.index, "level"), let on = Role.send(bus.index, "on"), store.isBound(strip, level) {
            let v = store.value(strip, level)
            let isOn = store.isOn(strip, on)
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.raised2 : Theme.raised)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(StripView.faderText(store.display(strip, level)))
                                .font(.system(size: 13, weight: .bold).monospacedDigit())
                                .foregroundStyle(isOn ? Theme.text : Theme.text3)
                            Spacer()
                            Button { store.toggle(strip, on) } label: {
                                Text("ON").font(.system(size: 10, weight: .heavy))
                                    .frame(width: 34, height: 24)
                                    .foregroundStyle(isOn ? Theme.ground : Theme.text3)
                                    .background(isOn ? Theme.sends : Theme.raised2, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(bus.name) send on")
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                        }
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.ground)
                            Capsule().fill(isOn ? Theme.sends : Theme.text3).frame(width: (g.size.width - 16) * CGFloat(v) / 127)
                        }
                        .frame(height: 6)
                    }
                    .padding(8)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 6)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        if dragStart == nil { dragStart = v; store.beginTouch(strip, level); store.selectedStrip = strip }
                        let delta = Double(gesture.translation.width / max(g.size.width, 1)) * 127 / (store.fineMode ? 4 : 1)
                        guard delta.isFinite else { return }
                        store.set(strip, level, Int((Double(dragStart ?? v) + delta).rounded()))
                    }
                    .onEnded { _ in endDrag(level) })
                .onTapGesture { store.selectedStrip = strip }
                .onChange(of: dragging) { _, active in if !active { endDrag(level) } }
            }
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(store.config.strip(strip)?.name ?? "") to \(bus.name)")
            .accessibilityValue(store.display(strip, level))
            .accessibilityAdjustableAction { dir in store.set(strip, level, v + (dir == .increment ? 2 : -2)) }
        } else {
            Text("—").foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
                .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Called from both `onEnded` and the cancel path; only the first ends the touch.
    private func endDrag(_ level: Role) {
        guard dragStart != nil else { return }
        dragStart = nil
        store.endTouch(strip, level)
    }
}

/// Right panel: the selected input's sends, its I/O and the bus list.
struct RoutingSidePanel: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        let ref = store.selectedStrip
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if ref.kind == .input, let s = store.config.strip(ref) {
                    Text("\(ref.slot) · \(s.name) · Sends").font(.system(size: 17, weight: .bold))
                    ForEach(store.config.sends) { bus in
                        if let level = Role.send(bus.index, "level"), let on = Role.send(bus.index, "on"), store.isBound(ref, level) {
                            CompactSendRow(strip: ref, bus: bus, level: level, on: on).id(ref)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("I/O · from concert (read-only)")
                        Text("Input \(s.hardwareIO ?? "—") · \(s.stereo ? "stereo" : "mono") → Main")
                            .font(.system(size: 13, weight: .semibold))
                        Text("MainStage doesn't expose I/O routing to MIDI — change it in MainStage; the Bridge re-imports it.")
                            .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text("Select an input to see its sends.").foregroundStyle(Theme.text2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Buses & returns")
                    ForEach(store.config.sends) { bus in
                        let aux = store.fxReturns.first { $0.hardwareIO?.lowercased() == "bus \(bus.busNumber ?? -1)" }
                        HStack(spacing: 8) {
                            Text("Bus \(bus.busNumber.map(String.init) ?? "?")").font(.system(size: 12, weight: .bold).monospacedDigit())
                                .frame(width: 52, alignment: .leading)
                            Text("→ \(aux?.name ?? bus.name)").font(.system(size: 12.5)).lineLimit(1)
                            Spacer()
                            if bus.existsInConcert {
                                Text("→ Main").font(.system(size: 11)).foregroundStyle(Theme.text2)
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.meterGreen)
                            } else {
                                Text("add aux strip in MainStage").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.eq)
                            }
                        }
                        .padding(.horizontal, 10).frame(minHeight: 36)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { store.openSetup(.channels) } label: {
                        Text("Outputs: \(store.outputs.map(\.name).joined(separator: " · ")) — configure in Setup › Channels & I/O")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.sends).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Narrow send row for the routing side panel.
struct CompactSendRow: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let bus: SendBus
    let level: Role
    let on: Role
    @State private var dragStart: Int?
    /// Resets when the drag ends or is cancelled; a cancel skips `onEnded`, so `onChange` ends the touch instead.
    @GestureState private var dragging = false

    var body: some View {
        let v = store.value(strip, level)
        let isOn = store.isOn(strip, on)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToggleChip(title: "ON", isOn: isOn, color: Theme.sends, height: 36) { store.toggle(strip, on) }.frame(width: 48)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bus.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("CC \(level.cc) / \(on.cc)").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Theme.text3)
                }
                Spacer()
                Text(StripView.faderText(store.display(strip, level))).font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(isOn ? Theme.text : Theme.text3)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ground).frame(height: 6)
                    Capsule().fill(isOn ? Theme.sends : Theme.text3).frame(width: g.size.width * CGFloat(v) / 127, height: 6)
                    Circle().fill(Theme.text).frame(width: 18, height: 18).offset(x: g.size.width * CGFloat(v) / 127 - 9)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        if dragStart == nil { dragStart = v; store.beginTouch(strip, level) }
                        let delta = Double(gesture.translation.width / max(g.size.width, 1)) * 127 / (store.fineMode ? 4 : 1)
                        guard delta.isFinite else { return }
                        store.set(strip, level, Int((Double(dragStart ?? v) + delta).rounded()))
                    }
                    .onEnded { _ in endDrag() })
                .onChange(of: dragging) { _, active in if !active { endDrag() } }
            }
            .frame(height: 30)
        }
        .padding(10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    /// Called from both `onEnded` and the cancel path; only the first ends the touch.
    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        store.endTouch(strip, level)
    }
}

/// Send rows for one input: ON toggle, horizontal level fader, bus status.
struct ChannelSendsView: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(store.config.strip(strip)?.name ?? strip.key) · Sends").font(.system(size: 18, weight: .bold))
            ForEach(store.config.sends) { bus in
                if let level = Role.send(bus.index, "level"), let on = Role.send(bus.index, "on"), store.isBound(strip, level) {
                    SendRow(strip: strip, bus: bus, level: level, on: on).id(strip)
                }
            }
            if strip.kind == .input, let s = store.config.strip(strip) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("I/O · from concert (read-only)")
                    Text("Input \(s.hardwareIO ?? "—") · \(s.stereo ? "stereo" : "mono") · MainStage strip “\(s.mainStage?.stripName ?? s.name)”")
                        .font(.system(size: 13))
                    Text("MainStage doesn't expose I/O routing to MIDI — change it in MainStage.")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer()
        }
    }
}

struct SendRow: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let bus: SendBus
    let level: Role
    let on: Role
    @State private var dragStart: Int?
    /// Resets when the drag ends or is cancelled; a cancel skips `onEnded`, so `onChange` ends the touch instead.
    @GestureState private var dragging = false

    var body: some View {
        let v = store.value(strip, level)
        let isOn = store.isOn(strip, on)
        HStack(spacing: 12) {
            ToggleChip(title: "ON", isOn: isOn, color: Theme.sends) { store.toggle(strip, on) }.frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(bus.name).font(.system(size: 14, weight: .semibold))
                Text(bus.existsInConcert ? "Bus \(bus.busNumber ?? 0) · in concert" : "Bus \(bus.busNumber ?? 0) · not in concert yet")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(bus.existsInConcert ? Theme.meterGreen : Theme.eq)
            }
            .frame(width: 190, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ground).frame(height: 8)
                    Capsule().fill(isOn ? Theme.sends : Theme.text3).frame(width: g.size.width * CGFloat(v) / 127, height: 8)
                    Circle().fill(Theme.text).frame(width: 22, height: 22).offset(x: g.size.width * CGFloat(v) / 127 - 11)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        if dragStart == nil { dragStart = v; store.beginTouch(strip, level) }
                        let delta = Double(gesture.translation.width / max(g.size.width, 1)) * 127 / (store.fineMode ? 4 : 1)
                        guard delta.isFinite else { return }
                        store.set(strip, level, Int((Double(dragStart ?? v) + delta).rounded()))
                    }
                    .onEnded { _ in endDrag() })
                .onChange(of: dragging) { _, active in if !active { endDrag() } }
            }
            .frame(height: 44)
            Text(StripView.faderText(store.display(strip, level))).font(.system(size: 14, weight: .bold).monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            CCChip(strip: strip, role: level).frame(width: 90)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 64)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Called from both `onEnded` and the cancel path; only the first ends the touch.
    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        store.endTouch(strip, level)
    }
}

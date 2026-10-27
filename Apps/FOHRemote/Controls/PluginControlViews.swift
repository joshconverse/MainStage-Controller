import SwiftUI
import FOHCore

/// Knob for one plugin control. Renders nothing when the plugin doesn't have it in its controlled set.
struct PluginKnob: View {
    @Environment(MixerStore.self) private var store
    let param: PluginParam?
    var title: String?
    var color: Color = Theme.inserts
    var size: CGFloat = 56
    /// Double-tap target; by default the parameter's own default value.
    var resetValue: Int?

    var body: some View {
        if let p = param {
            KnobControl(title: title ?? p.name, value: store.value(p), display: store.display(p), color: color, size: size,
                        fine: store.fineMode, assumed: store.isAssumed(path: p.path),
                        resetValue: resetValue ?? p.defaultMIDI,
                        onChange: { store.set(p, $0) },
                        onTouch: { $0 ? store.beginTouch(p) : store.endTouch(p) })
                .id(p.path)   // a new strip or band gets a fresh knob, not the old one's drag state
        }
    }
}

/// On/off chip for a two-state plugin control (lit when the value is in the top half).
struct PluginToggle: View {
    @Environment(MixerStore.self) private var store
    let param: PluginParam?
    var title: String
    var color: Color = Theme.inserts
    var height: CGFloat = 44

    var body: some View {
        if let p = param {
            ToggleChip(title: title, isOn: store.isOn(p), color: color, height: height) { store.toggle(p) }
                .opacity(store.isAssumed(path: p.path) ? 0.75 : 1)
        }
    }
}

/// A stepped plugin control as a grid of its own labels (Pro-Q 3's shapes and slopes).
struct PluginPicker: View {
    @Environment(MixerStore.self) private var store
    let param: PluginParam?
    var columns: Int
    var color: Color = Theme.inserts
    /// Which options to offer (Tune's common scales out of 44); the current one is always shown.
    var include: (String) -> Bool = { _ in true }
    /// Shorter labels for tight grids ("Low Shelf" → "Lo Shelf").
    var label: (String) -> String = { $0 }

    var body: some View {
        if let p = param, !p.stepCenters.isEmpty {
            let current = store.display(p)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                ForEach(p.stepCenters.filter { include($0.label) || $0.label == current }, id: \.midi) { option in
                    let selected = option.label == current
                    Button { store.set(p, option.midi) } label: {
                        Text(label(option.label))
                            .font(.system(size: 11.5, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .foregroundStyle(selected ? Theme.ground : Theme.text2)
                            .background(selected ? color : Theme.raised, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

/// Compact horizontal drag field for a plugin control (output level, gain scale): drag sideways, double-tap for
/// the default.
struct PluginDragField: View {
    @Environment(MixerStore.self) private var store
    let param: PluginParam?
    let title: String
    var width: CGFloat = 130
    @State private var dragStart: Int?
    /// Resets when the drag ends or is cancelled; a cancel skips `onEnded`, so `onChange` ends the touch instead.
    @GestureState private var dragging = false

    var body: some View {
        if let p = param {
            let v = store.value(p)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text2)
                AssumedText(text: store.display(p), assumed: store.isAssumed(path: p.path), font: .system(size: 14, weight: .bold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: 44, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { g in
                    if dragStart == nil { dragStart = v; store.beginTouch(p) }
                    guard abs(g.translation.width) >= FaderControl.tapSlop else { return }
                    let delta = g.translation.width / (store.fineMode ? 8 : 2)
                    guard delta.isFinite else { return }
                    store.set(p, (dragStart ?? v) + Int(delta.rounded()))
                }
                .onEnded { _ in endDrag() })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard let d = p.defaultMIDI else { return }
                store.beginTouch(p); store.set(p, d); store.endTouch(p)
            })
            .onChange(of: dragging) { _, active in if !active { endDrag() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(store.display(p))
            .accessibilityAdjustableAction { dir in store.set(p, v + (dir == .increment ? 1 : -1)) }
        }
    }

    private func endDrag() {
        guard let p = param, dragStart != nil else { return }
        dragStart = nil
        store.endTouch(p)
    }
}

/// Shown on a plugin page when MainStage hasn't reported any of its controls back: they're probably not mapped in
/// the concert yet, so moving them won't reach the plugin.
struct PluginMappingNotice: View {
    @Environment(MixerStore.self) private var store
    let controls: PluginControls
    @State private var mapping = false

    var body: some View {
        if !store.isDemo, store.confirmationsSupported, !controls.isEmpty,
           !controls.all.contains(where: { store.confirmed.contains($0.path) }) {
            HStack(alignment: .top, spacing: 10) {
                Label("MainStage hasn't confirmed any of these controls yet. If FOH Bridge just restarted, Setup › Pull from "
                      + "MainStage confirms them. Otherwise they may not be mapped: Update assignments maps them (with MainStage "
                      + "closed), and on a mono output, map one by hand first.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.eq)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                ToggleChip(title: "MAP BY HAND…", isOn: false, color: Theme.eq, height: 34) { mapping = true }
                    .frame(width: 140)
            }
            .sheet(isPresented: $mapping) {
                MapByHandSheet(controls: controls,
                               pluginName: store.config.strip(controls.strip)?.plugin(at: controls.position)?.name ?? "plugin")
            }
        }
    }
}

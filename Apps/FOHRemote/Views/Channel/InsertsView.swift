import SwiftUI
import FOHCore

struct InsertsView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        let ref = store.selectedStrip
        let plugins = store.selected?.plugins ?? []
        let current = store.insertPosition.flatMap { p in plugins.first { $0.position == p } } ?? defaultPlugin
        VStack(spacing: 10) {
            if !plugins.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(plugins, id: \.position) { p in
                            PluginTab(strip: ref, plugin: p, badge: badge(p), selected: current?.position == p.position) {
                                store.insertPosition = p.position
                            }
                        }
                    }
                }
                .frame(height: 58)
            }
            Group {
                if let p = current {
                    page(p, ref)
                        .id("\(ref.key)#\(p.position)")   // a page's band selection and drags belong to one plugin
                } else {
                    Text("No plugins on this strip.").foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
        .onChange(of: store.selectedStrip) { _, _ in store.insertPosition = nil }
    }

    /// Pro-Q 3, Pro-R 2 and Waves Tune have their own pages; any other plugin with plugin controls gets them under
    /// headings. Plugin pages replace the old insert macro pages, which remain only for plugins without controls.
    @ViewBuilder
    private func page(_ p: PluginRef, _ ref: StripRef) -> some View {
        let controlled = store.hasPluginControls(ref, p.position)
        if isProcessing(p) {
            BoundProcessingPanel(plugin: p)
        } else if p.component == .fabFilterProQ3 && controlled {
            ProQ3Page(strip: ref, plugin: p)
        } else if p.component == .fabFilterProR2 && controlled {
            ProR2Page(strip: ref, plugin: p)
        } else if p.component == .wavesTuneRealTime && controlled {
            TunePluginPage(strip: ref, plugin: p)
        } else if p.component == nil {
            ApplePluginPage(strip: ref, plugin: p)
        } else if controlled {
            PluginControlsPanel(strip: ref, plugin: p)
        } else if let page = page(for: p) {
            if p.name.localizedCaseInsensitiveContains("Tune") {
                TunePage(strip: ref, page: page, plugin: p)
            } else {
                MacroPage(strip: ref, page: page, plugin: p)
            }
        } else {
            UnboundPanel(text: p.component == nil
                         ? "\(p.name) is one of MainStage's own plugins, which FOH Bridge can't read yet."
                         : "\(p.name) has no controls on the iPad yet.")
        }
    }

    private var defaultPlugin: PluginRef? {
        guard let s = store.selected else { return nil }
        if let first = s.processing.insertPages.sorted(by: { $0.key < $1.key }).first { return s.plugin(at: first.value) }
        return s.plugins.first { store.hasPluginControls(s.ref, $0.position) } ?? s.plugins.first
    }

    private func page(for p: PluginRef) -> Int? {
        store.selected?.processing.insertPages.first { $0.value == p.position }?.key
    }

    private func isProcessing(_ p: PluginRef) -> Bool {
        guard let s = store.selected else { return false }
        return [s.processing.eq, s.processing.dynamics, s.processing.trim].contains(p.position)
    }

    private func badge(_ p: PluginRef) -> String {
        guard let s = store.selected else { return "" }
        let proc = [(s.processing.eq, "EQ"), (s.processing.dynamics, "Dynamics"), (s.processing.trim, "Trim")]
            .filter { $0.0 == p.position }.map(\.1)
        if !proc.isEmpty { return "Bound → " + proc.joined(separator: " · ") }
        let count = store.pluginControls(s.ref, p.position).all.count
        if count > 0 { return "\(count) controls" }
        if let page = page(for: p) { return "Insert page \(page)" }
        return "Not on the iPad"
    }
}

/// One plugin in the strip's chain: position, name, what drives it, and whether it's bypassed.
struct PluginTab: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let plugin: PluginRef
    let badge: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(plugin.position)").font(.system(size: 12, weight: .heavy)).frame(width: 24, height: 24)
                    .background(Theme.raised2, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(badge).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(badge.hasPrefix("Not") ? Theme.text3 : Theme.text2).lineLimit(1)
                }
                if bypassed {
                    Text("BYP").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.ground)
                        .padding(.horizontal, 6).frame(height: 22)
                        .background(Theme.mute, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 150, minHeight: 52, alignment: .leading)
            .background(selected ? Theme.raised2 : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.inserts : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The plugin's own Bypass control when it has one, else the strip's insert bypass.
    private var bypassed: Bool {
        if let p = store.pluginControls(strip, plugin.position)["Bypass"] { return store.isOn(p) }
        if let page = store.selected?.processing.insertPages.first(where: { $0.value == plugin.position })?.key,
           let role = Role.insertBypass(page), store.isBound(strip, role) {
            return store.isOn(strip, role)
        }
        return false
    }
}

struct BoundProcessingPanel: View {
    @Environment(MixerStore.self) private var store
    let plugin: PluginRef

    var body: some View {
        let ref = store.selectedStrip
        let count = store.config.binding(ref).roles.values.filter { $0.pluginPosition == plugin.position }.count
        VStack(alignment: .leading, spacing: 14) {
            Text(plugin.name).font(.system(size: 20, weight: .bold))
            Text("Bound to the EQ, Dynamics and Trim pages · \(count) roles").foregroundStyle(Theme.text2)
            HStack(spacing: 10) {
                ToggleChip(title: "OPEN EQ", isOn: true, color: Theme.eq) { store.channelSection = .eq }.frame(width: 140)
                ToggleChip(title: "OPEN DYNAMICS", isOn: true, color: Theme.dynamics) { store.channelSection = .dynamics }.frame(width: 160)
            }
            Spacer()
        }
    }
}

/// Generic insert page: bypass + labelled macros.
struct MacroPage: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let page: Int
    let plugin: PluginRef

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(strip: strip, page: page, plugin: plugin)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                ForEach(1...8, id: \.self) { m in
                    if let role = Role.insertMacro(page, m), let b = store.binding(strip, role) {
                        if b.behavesAsToggle {
                            RoleToggle(strip: strip, role: role, title: b.parameterName.uppercased(), color: Theme.inserts)
                        } else {
                            RoleKnob(strip: strip, role: role, color: Theme.inserts, size: 64)
                        }
                    }
                }
            }
            MacroTable(strip: strip, page: page)
            Spacer()
        }
    }
}

struct PageHeader: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let page: Int
    let plugin: PluginRef

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).font(.system(size: 18, weight: .bold))
                Text("Insert page \(page) · plugin slot \(plugin.position)").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if let bypass = Role.insertBypass(page) {
                RoleToggle(strip: strip, role: bypass, title: "BYPASS", color: Theme.eq).frame(width: 110)
            }
        }
    }
}

/// Waves Tune Real-Time page: key + scale pickers, speed / note transition, correction.
struct TunePage: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let page: Int
    let plugin: PluginRef

    static let commonScales = ["Chromatic", "Major", "Natural Minor", "Harmonic Minor", "Melodic Minor (Asc)", "Dorian",
                                       "Mixolydian", "Lydian", "Phrygian", "Blues", "Major Pentatonic", "Minor Pentatonic"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(strip: strip, page: page, plugin: plugin)
            if let keyRole = Role.insertMacro(page, 3), let b = store.binding(strip, keyRole) {
                pickerSection("KEY", "\(b.parameterName) · CC \(keyRole.cc)") {
                    SteppedPicker(options: b.stepCenters, selected: b.display(store.value(strip, keyRole)), columns: 9, color: Theme.inserts) {
                        store.set(strip, keyRole, $0)
                    }
                }
            }
            if let scaleRole = Role.insertMacro(page, 4), let b = store.binding(strip, scaleRole) {
                let options = b.stepCenters.filter { Self.commonScales.contains($0.label) }
                pickerSection("SCALE", "\(b.parameterName) · CC \(scaleRole.cc) · \(b.stepCenters.count) scales") {
                    SteppedPicker(options: options, selected: b.display(store.value(strip, scaleRole)), columns: 6, color: Theme.inserts) {
                        store.set(strip, scaleRole, $0)
                    }
                }
            }
            HStack(alignment: .top, spacing: 18) {
                macroControl(1, "Speed")
                macroControl(2, "Note transition")
                macroControl(6, "Correction")
                macroControl(5, "Correction")
                macroControl(7, "Vibrato depth")
                macroControl(8, "Formant")
            }
            MacroTable(strip: strip, page: page)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func macroControl(_ m: Int, _ title: String) -> some View {
        if let role = Role.insertMacro(page, m), let b = store.binding(strip, role) {
            if b.behavesAsToggle {
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                    ToggleChip(title: b.display(store.value(strip, role)).uppercased(), isOn: store.isOn(strip, role), color: Theme.inserts) {
                        store.toggle(strip, role)
                    }
                    .frame(width: 90)
                    Text("\(b.parameterName) · CC \(role.cc)").font(.system(size: 9.5)).foregroundStyle(Theme.text3)
                }
            } else {
                RoleKnob(strip: strip, role: role, title: title, color: Theme.inserts, size: 64)
            }
        }
    }

    private func pickerSection<Content: View>(_ title: String, _ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .heavy)).tracking(1)
                Text(caption).font(.system(size: 10)).foregroundStyle(Theme.text3)
            }
            content()
        }
    }
}

/// Macro map: macro → plugin parameter → CC → learned.
struct MacroTable: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let page: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MACRO").frame(width: 60, alignment: .leading)
                Text("MAINSTAGE PARAMETER").frame(maxWidth: .infinity, alignment: .leading)
                Text("RANGE").frame(width: 200, alignment: .leading)
                Text("CC").frame(width: 50, alignment: .leading)
                Text("LEARNED").frame(width: 70, alignment: .leading)
            }
            .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
            .padding(.vertical, 6)
            ForEach(1...8, id: \.self) { m in
                if let role = Role.insertMacro(page, m) {
                    let b = store.binding(strip, role)
                    HStack {
                        Text("\(m)").frame(width: 60, alignment: .leading)
                        Text(b?.parameterName ?? "— unassigned").foregroundStyle(b == nil ? Theme.text3 : Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(b.map { "\($0.display(0)) … \($0.display(127))" } ?? "").foregroundStyle(Theme.text2).lineLimit(1)
                            .frame(width: 200, alignment: .leading)
                        Text("\(role.cc)").frame(width: 50, alignment: .leading)
                        Text(store.isLearned(strip, role) ? "✓" : (b == nil ? "" : "pending"))
                            .foregroundStyle(store.isLearned(strip, role) ? Theme.meterGreen : Theme.text3)
                            .frame(width: 70, alignment: .leading)
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .frame(height: 26)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
        }
    }
}

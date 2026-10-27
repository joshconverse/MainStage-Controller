import SwiftUI
import FOHCore

/// A plugin's controls under headings, filtered by a search: knobs, switches and step menus. Long-press a control to
/// take it off the iPad (for every instance of that plugin).
struct PluginControlsBrowser: View {
    @Environment(MixerStore.self) private var store
    let controls: PluginControls
    let pluginName: String
    var query = ""
    var color: Color = Theme.inserts

    var body: some View {
        let groups = grouped()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.name.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(Theme.text3)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), alignment: .leading, spacing: 14) {
                            ForEach(group.params) { p in
                                cell(p)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            store.removePluginControl(controls.strip, controls.position, parameterID: p.control.parameterID)
                                        } label: {
                                            Label("Remove from \(pluginName) controls", systemImage: "minus.circle")
                                        }
                                    }
                            }
                        }
                    }
                }
                if groups.isEmpty {
                    Text(query.isEmpty ? "No controls on the iPad for \(pluginName) yet. Add some with Add control."
                                       : "No control matches “\(query)”.")
                        .foregroundStyle(Theme.text3).padding(.top, 20)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func grouped() -> [(name: String, params: [PluginParam])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = controls.all.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        let byID = Dictionary(shown.map { ($0.control.parameterID, $0) }, uniquingKeysWith: { a, _ in a })
        var out = ParameterGroup.make(shown.compactMap(\.info)).map { g in (g.name, g.items.compactMap { byID[$0.id] }) }
        let undescribed = shown.filter { $0.info == nil }
        if !undescribed.isEmpty { out.append(("Main", undescribed)) }
        return out.filter { !$0.1.isEmpty }
    }

    @ViewBuilder
    private func cell(_ p: PluginParam) -> some View {
        if p.isToggle {
            VStack(spacing: 6) {
                Text(p.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2).lineLimit(1).minimumScaleFactor(0.8)
                ToggleChip(title: store.display(p).uppercased(), isOn: store.isOn(p), color: color) { store.toggle(p) }
            }
        } else if p.isStepped {
            PluginStepMenu(param: p, color: color)
        } else {
            PluginKnob(param: p, color: color, size: 54)
        }
    }
}

/// A stepped control with many options (Tune's 44 scales) as a menu of its labels.
struct PluginStepMenu: View {
    @Environment(MixerStore.self) private var store
    let param: PluginParam
    var color: Color = Theme.inserts

    var body: some View {
        let current = store.display(param)
        VStack(spacing: 6) {
            Text(param.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2).lineLimit(1).minimumScaleFactor(0.8)
            Menu {
                ForEach(param.stepCenters, id: \.midi) { option in
                    Button { store.set(param, option.midi) } label: {
                        if option.label == current { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current).font(.system(size: 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.5)))
            }
            .accessibilityLabel(param.name)
            .accessibilityValue(current)
        }
    }
}

/// Every parameter of a plugin that isn't on the iPad yet: add one, and it joins that plugin type's controls on every
/// strip; FOH Bridge maps it in MainStage at the next update.
struct AddPluginControlSheet: View {
    @Environment(MixerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let strip: StripRef
    let plugin: PluginRef
    @State private var query = ""
    @State private var showHidden = false
    @State private var requested: Set<String> = []
    /// The keyboard pushes a form sheet up; it goes away after Add so the list and Done are in view.
    @FocusState private var searching: Bool

    var body: some View {
        let active = Set(store.pluginControls(strip, plugin.position).all.map(\.control.parameterID))
        let all = store.pluginDescription(strip, plugin.position)?.parameters ?? []
        let q = query.trimmingCharacters(in: .whitespaces)
        let candidates = all.filter { p in
            !active.contains(p.id) && (p.isControl || (showHidden && p.writable != false && p.meter != true))
                && (q.isEmpty || p.name.localizedCaseInsensitiveContains(q))
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add control · \(plugin.name)").font(.system(size: 18, weight: .bold))
                    Text("Joins every \(plugin.name) in the show. FOH Bridge maps it in MainStage at its next update.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Spacer()
                Button("Done") { dismiss() }.font(.system(size: 15, weight: .semibold))
                    .accessibilityIdentifier("addcontrol.done")
            }
            if let sync = store.status?.mainStageSync {
                Label(sync, systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
            }
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                    TextField("Search \(all.count) parameters", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searching)
                        .submitLabel(.done)
                        .accessibilityIdentifier("addcontrol.search")
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                Toggle("Show display and analyzer parameters", isOn: $showHidden).font(.system(size: 12)).fixedSize()
            }
            if all.isEmpty {
                ProgressView("Reading \(plugin.name)'s parameters…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(ParameterGroup.make(candidates)) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(group.name.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.8)
                                    .foregroundStyle(Theme.text3).padding(.bottom, 4)
                                ForEach(group.items) { p in row(p) }
                            }
                        }
                        if candidates.isEmpty {
                            Text(q.isEmpty ? "Every parameter is already on the iPad." : "Nothing matches “\(q)”.")
                                .foregroundStyle(Theme.text3).padding(.top, 20)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
        .background(Theme.panel)
        .requestingPlugin(store, strip, plugin.position, described: !all.isEmpty)
    }

    private func row(_ p: PluginParameterInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 14, weight: .semibold))
                Text(range(p)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            if requested.contains(p.id) {
                Text("Adding…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
            } else {
                Button {
                    requested.insert(p.id)
                    searching = false
                    store.addPluginControl(strip, plugin.position, parameterID: p.id)
                } label: {
                    Label("Add", systemImage: "plus").font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12).frame(height: 34)
                        .foregroundStyle(Theme.ground).background(Theme.inserts, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(p.name)")
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func range(_ p: PluginParameterInfo) -> String {
        switch p.kind {
        case .toggle: return "switch · \(p.display(0)) / \(p.display(127))"
        case .stepped(let n): return "\(n) steps · \(p.display(0)) … \(p.display(127))"
        case .continuous: return "\(p.display(0)) … \(p.display(127))"
        }
    }
}

/// A plugin without a dedicated page, and the "All controls" view of one with: its controls under headings, a
/// search, and Add control.
struct PluginControlsPanel: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let plugin: PluginRef
    var showsHeader = true
    @State private var query = ""
    @State private var adding = false

    var body: some View {
        let c = store.pluginControls(strip, plugin.position)
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name).font(.system(size: 18, weight: .bold))
                        Text("Insert \(plugin.position)\(plugin.preset.map { " · \($0)" } ?? "") · \(c.all.count) controls")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    PluginToggle(param: c["Bypass"], title: "BYPASS", color: Theme.mute).frame(width: 96)
                }
                PluginMappingNotice(controls: c)
            }
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                    TextField("Search \(c.all.count) controls", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("controls.search")
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                ToggleChip(title: "ADD CONTROL", isOn: true, color: Theme.inserts, height: 40) { adding = true }
                    .frame(width: 150)
            }
            if c.described || c.isEmpty {
                PluginControlsBrowser(controls: c, pluginName: plugin.name, query: query)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .requestingPlugin(store, strip, plugin.position, described: c.described)
        .sheet(isPresented: $adding) { AddPluginControlSheet(strip: strip, plugin: plugin) }
    }
}

/// "ALL CONTROLS" on a dedicated page (Pro-Q 3, Pro-R 2, Tune): the full list, including added parameters the page
/// doesn't draw, and Add control.
struct AllControlsButton: View {
    let strip: StripRef
    let plugin: PluginRef
    @State private var open = false

    var body: some View {
        ToggleChip(title: "ALL CONTROLS", isOn: false, color: Theme.inserts) { open = true }
            .frame(width: 130)
            .sheet(isPresented: $open) {
                AllControlsSheet(strip: strip, plugin: plugin)
            }
    }
}

private struct AllControlsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let strip: StripRef
    let plugin: PluginRef

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(plugin.name) · all controls").font(.system(size: 18, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.font(.system(size: 15, weight: .semibold))
            }
            PluginControlsPanel(strip: strip, plugin: plugin, showsHeader: false)
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 640)
        .background(Theme.panel)
    }
}

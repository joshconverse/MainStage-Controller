import SwiftUI
import FOHCore

/// Setup › Processing: choose which plugin drives each page, then confirm or re-point each control's binding.
struct ProcessingView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        let ref = store.selectedStrip
        VStack(alignment: .leading, spacing: 12) {
            SetupFlowIndicator(current: 2)
            HStack(spacing: 10) {
                Button { store.stepChannel(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44).background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).accessibilityLabel("Previous channel")
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.selected.map { "\(ref.kind == .input ? "\(ref.slot) · " : "")\($0.name)" } ?? "—").font(.system(size: 18, weight: .bold))
                    Text("\(ref.port.rawValue) · ch \(ref.channel)").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                .frame(minWidth: 170, alignment: .leading)
                Button { store.stepChannel(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44).background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).accessibilityLabel("Next channel")
                Spacer()
                SubStepper()
            }
            if let strip = store.selected {
                HStack(alignment: .top, spacing: 10) {
                    PluginChainColumn(strip: strip).frame(width: 300)
                    BindingTable(strip: strip).frame(maxWidth: .infinity)
                }
                .id(strip.ref)
            }
        }
        .onAppear { requestAll() }
        .onChange(of: store.synced) { _, synced in if synced { requestAll() } }
        .onChange(of: store.selectedStrip) { _, _ in requestAll() }
        .onChange(of: store.config.strip(store.selectedStrip)?.plugins) { _, _ in requestAll() }
    }

    private func requestAll() {
        guard let s = store.selected else { return }
        for p in s.plugins where p.component != nil { store.requestPlugin(s.ref, p.position) }
    }
}

/// Discover ✓ → Bind → Learn → Verify for the current channel.
private struct SubStepper: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            step("Discover", state: .done)
            arrow
            step("Bind", state: .current)
            arrow
            Button { store.setupSection = .learn } label: { stepLabel("Learn", state: .pending) }.buttonStyle(.plain)
            arrow
            step("Verify", state: .pending)
        }
    }

    enum StepState { case done, current, pending }

    private var arrow: some View { Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3) }

    private func step(_ title: String, state: StepState) -> some View { stepLabel(title, state: state) }

    private func stepLabel(_ title: String, state: StepState) -> some View {
        HStack(spacing: 4) {
            if state == .done { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)) }
            Text(title).font(.system(size: 12, weight: .bold))
        }
        .padding(.horizontal, 10).frame(height: 30)
        .foregroundStyle(state == .current ? Theme.ground : state == .done ? Theme.meterGreen : Theme.text2)
        .background(state == .current ? Theme.inserts : Theme.raised, in: Capsule())
    }
}

/// The strip's plugin chain from discovery, with "Drives" chips that set `ProcessingSources`.
struct PluginChainColumn: View {
    struct SaveTarget: Identifiable {
        let position: Int
        let pluginName: String
        let use: CustomTemplate.Use
        var id: Int { position }
    }

    @Environment(MixerStore.self) private var store
    let strip: Strip
    @State private var saveTarget: SaveTarget?
    @State private var templateName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Plugin chain · \(strip.mainStage?.stripName ?? strip.name)")
                if strip.plugins.isEmpty {
                    Text("No plugins on this strip. Import the concert in Channels & I/O to read its chain.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                ForEach(strip.plugins, id: \.position) { p in card(p) }
                ToggleChip(title: "RESCAN PLUGINS", isOn: false, color: Theme.text) { store.rescanPlugins(strip.ref) }
                    .padding(.top, 4)
                Text("The Bridge loads each plugin off-line on the Mac to read its parameter names, ranges and value text.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .alert("Save as template", isPresented: Binding(get: { saveTarget != nil }, set: { if !$0 { saveTarget = nil } })) {
            TextField("Template name", text: $templateName)
            Button("Save") {
                if let t = saveTarget { store.saveTemplate(name: templateName, strip: strip.ref, position: t.position, use: t.use) }
                saveTarget = nil
            }
            Button("Cancel", role: .cancel) { saveTarget = nil }
        } message: {
            Text(saveTarget.map { t in
                "Saves \(strip.name)'s current \(t.use == .processing ? "EQ / Dynamics / Trim" : "insert macro") bindings for \(t.pluginName). " +
                "Every strip with \(t.pluginName) then uses them instead of the built-in template."
            } ?? "")
        }
    }

    private func card(_ p: PluginRef) -> some View {
        let desc = store.pluginDescription(strip.ref, p.position)
        let proc = strip.processing
        let page = proc.insertPages.first { $0.value == p.position }?.key
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(p.position)").font(.system(size: 11, weight: .heavy)).frame(width: 22, height: 22)
                    .foregroundStyle(Theme.ground).background(Theme.text2, in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    if let preset = p.preset { Text(preset).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1) }
                }
            }
            Group {
                if let desc {
                    Label("\(desc.parameters.count) params read via Bridge", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.meterGreen)
                } else if p.component == nil {
                    Label("Not discoverable (no Audio Unit id)", systemImage: "minus.circle").foregroundStyle(Theme.text3)
                } else {
                    Label(store.isDemo ? "No discovery data in the demo" : "Reading parameters…", systemImage: "hourglass").foregroundStyle(Theme.text3)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            Text("DRIVES").font(Theme.label).tracking(1).foregroundStyle(Theme.text3)
            HStack(spacing: 4) {
                chip("EQ", on: proc.eq == p.position, color: Theme.eq) { toggle(\.eq, p.position) }
                chip("Dyn", on: proc.dynamics == p.position, color: Theme.dynamics) { toggle(\.dynamics, p.position) }
                chip("Trim", on: proc.trim == p.position, color: Theme.text) { toggle(\.trim, p.position) }
                chip(page.map { "Page \($0)" } ?? "Insert", on: page != nil, color: Theme.inserts) { toggleInsert(p.position) }
            }
            let drivesProcessing = proc.eq == p.position || proc.dynamics == p.position || proc.trim == p.position
            if desc != nil && (drivesProcessing || page != nil) {
                Button {
                    templateName = "\(p.name) · \(strip.name)"
                    saveTarget = SaveTarget(position: p.position, pluginName: p.name, use: drivesProcessing ? .processing : .insert)
                } label: {
                    Label("Save as template…", systemImage: "square.and.arrow.down.on.square")
                        .font(.system(size: 11.5, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(Theme.inserts)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.inserts.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save \(p.name) bindings as a template")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func chip(_ title: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .heavy))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(on ? Theme.ground : Theme.text2)
                .background(on ? color : Theme.raised2, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ key: WritableKeyPath<ProcessingSources, Int?>, _ position: Int) {
        store.updateStrip(strip.ref) { s in
            s.processing[keyPath: key] = s.processing[keyPath: key] == position ? nil : position
        }
    }

    private func toggleInsert(_ position: Int) {
        store.updateStrip(strip.ref) { s in
            if let page = s.processing.insertPages.first(where: { $0.value == position })?.key {
                s.processing.insertPages[page] = nil
            } else if let free = (1...4).first(where: { s.processing.insertPages[$0] == nil }) {
                s.processing.insertPages[free] = position
            }
        }
    }
}

/// Role → plugin parameter table, grouped by page.
struct BindingTable: View {
    @Environment(MixerStore.self) private var store
    let strip: Strip
    @State private var confirmReset = false

    struct Section: Identifiable {
        let id: String
        let title: String
        let color: Color
        let roles: [Role]
        let source: Int?
    }

    private var sections: [Section] {
        let p = strip.processing
        func roles(_ groups: Set<Role.Group>) -> [Role] { Role.all.filter { groups.contains($0.group) }.sorted { $0.cc < $1.cc } }
        var out = [
            Section(id: "trim", title: "Trim & phase", color: Theme.text, roles: [.trimIn, .trimOut, .phase], source: p.trim),
            Section(id: "eq", title: "EQ", color: Theme.eq, roles: roles([.eq, .band]), source: p.eq),
            Section(id: "dyn", title: "Dynamics", color: Theme.dynamics, roles: roles([.dyn, .comp, .gate]), source: p.dynamics),
        ]
        for (page, pos) in p.insertPages.sorted(by: { $0.key < $1.key }) {
            let insertRoles = Role.all.filter { $0.group == .insert && $0.index == page }.sorted { $0.cc < $1.cc }
            out.append(Section(id: "ins\(page)", title: "Insert page \(page) · \(strip.plugin(at: pos)?.name ?? "")",
                               color: Theme.inserts, roles: insertRoles, source: pos))
        }
        return out
    }

    var body: some View {
        let binding = store.config.binding(strip.ref)
        VStack(alignment: .leading, spacing: 10) {
            banner(binding)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in sectionView(section, binding: binding) }
                    channelStripSection(binding)
                }
                .padding(.bottom, 10)
            }
            footer
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .alert("Reset \(strip.name) to its templates?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.bindReset(strip.ref) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Manual bindings on this channel are replaced by the template's automatic matches.")
        }
    }

    private func banner(_ binding: StripBinding) -> some View {
        let pluginRoles = binding.roles.values.filter { !$0.isChannelStrip && !$0.parameterID.hasPrefix("@") }
        let auto = pluginRoles.filter { $0.origin == .auto }.count
        let manual = pluginRoles.filter { $0.origin == .manual }.count
        let templateName: String = {
            guard let pos = strip.processing.eq ?? strip.processing.dynamics,
                  let desc = store.pluginDescription(strip.ref, pos) else { return strip.plugin(at: strip.processing.eq)?.name ?? "Custom" }
            if let custom = store.config.customTemplates.first(where: { $0.use == .processing && $0.matches(desc) }) {
                return "\(custom.name) (custom)"
            }
            return Templates.template(for: desc)?.name ?? "Custom (\(desc.name))"
        }()
        return HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(Theme.inserts)
            Text("Template: \(templateName)").font(.system(size: 13, weight: .bold))
            Text("— \(auto) auto-matched · \(manual) manual · \(binding.notInPlugin.count) hidden")
                .font(.system(size: 13)).foregroundStyle(Theme.text2)
            Spacer()
        }
        .padding(.horizontal, 12).frame(minHeight: 40)
        .background(Theme.inserts.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func sectionView(_ section: Section, binding: StripBinding) -> some View {
        let bound = section.roles.filter { binding.isBound($0) }
        let rest = section.roles.filter { !binding.isBound($0) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(section.color).frame(width: 4, height: 16)
                Text(section.title.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(0.8)
                if let pos = section.source, let p = strip.plugin(at: pos) {
                    Text("← \(p.name) · slot \(pos)").font(.system(size: 11)).foregroundStyle(Theme.text2)
                } else {
                    Text("no plugin drives this page — use the Drives chips").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.bottom, 2)
            if section.source != nil {
                ForEach(bound) { role in BindingRow(strip: strip, role: role, source: section.source) }
                if !rest.isEmpty {
                    DisclosureGroup {
                        ForEach(rest) { role in BindingRow(strip: strip, role: role, source: section.source) }
                    } label: {
                        Text("Not in plugin / unbound (\(rest.count)) — hidden on the \(section.title) page")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                    .tint(Theme.text3)
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private func channelStripSection(_ binding: StripBinding) -> some View {
        let fixed = binding.roles.values.filter(\.isChannelStrip).map(\.role).sorted { $0.cc < $1.cc }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.sends).frame(width: 4, height: 16)
                Text("MAINSTAGE CHANNEL STRIP").font(.system(size: 11, weight: .heavy)).tracking(0.8)
                Text("fixed — learned straight onto the strip").font(.system(size: 11)).foregroundStyle(Theme.text2)
            }
            Text(fixed.map(\.label).joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.channelOrder.filter { $0.ref != strip.ref }) { other in
                    Button("\(other.name)") { store.bindApply(from: strip.ref, to: other.ref) }
                }
            } label: {
                Text("APPLY TO…").font(.system(size: 11, weight: .heavy)).tracking(0.6)
                    .frame(width: 140, height: 44)
                    .foregroundStyle(Theme.text)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            }
            ToggleChip(title: "RESET TO TEMPLATE", isOn: false, color: Theme.text) { confirmReset = true }.frame(width: 190)
            Spacer()
            ToggleChip(title: "NEXT: MAINSTAGE LEARN →", isOn: true, color: Theme.eq) { store.setupSection = .learn }.frame(width: 240)
        }
    }
}

/// One role's binding: picker for the plugin parameter, range and status.
struct BindingRow: View {
    @Environment(MixerStore.self) private var store
    let strip: Strip
    let role: Role
    let source: Int?

    var body: some View {
        let binding = store.config.binding(strip.ref)
        let b = binding[role]
        let hidden = binding.notInPlugin.contains(role.id)
        HStack(spacing: 10) {
            Text(role.label).font(.system(size: 13, weight: .semibold)).frame(width: 160, alignment: .leading).lineLimit(1)
            Text("CC \(role.cc)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text3)
                .frame(width: 46, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
            picker(b, hidden: hidden)
            Text(rangeText(b)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.text2)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            statusPill(b, hidden: hidden)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        .opacity(b == nil ? 0.7 : 1)
    }

    @ViewBuilder
    private func picker(_ b: RoleBinding?, hidden: Bool) -> some View {
        let title = b?.parameterName ?? (hidden ? "— hidden" : "— unbound")
        if let pos = b?.pluginPosition ?? source, !(b?.parameterID.hasPrefix("@") ?? false) {
            let desc = store.pluginDescription(strip.ref, pos)
            Menu {
                if let desc {
                    ForEach(desc.parameters.filter { !$0.name.isEmpty }) { p in
                        Button {
                            store.bindSet(strip.ref, role, position: pos, parameterID: p.id)
                        } label: {
                            if p.id == b?.parameterID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                    Divider()
                    Button("Hide (not in plugin)", role: .destructive) { store.bindSet(strip.ref, role, position: pos, parameterID: "") }
                } else {
                    Text(store.isDemo ? "No discovery data for this plugin in the demo" : "Reading parameters from the Bridge…")
                }
            } label: {
                pill(title, dim: b == nil)
            }
            .simultaneousGesture(TapGesture().onEnded { store.requestPlugin(strip.ref, pos) })
            .accessibilityLabel("\(role.label) parameter")
            .accessibilityValue(title)
        } else {
            pill(title, dim: true)
        }
    }

    private func pill(_ title: String, dim: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 10)
        .frame(width: 190, height: 34, alignment: .leading)
        .foregroundStyle(dim ? Theme.text3 : Theme.text)
        .background(Theme.raised2, in: RoundedRectangle(cornerRadius: 7))
    }

    private func rangeText(_ b: RoleBinding?) -> String {
        guard let b else { return "" }
        switch b.kind {
        case .toggle: return "switch · \(b.display(0)) / \(b.display(127))"
        case .stepped(let n): return "\(n) steps · \(b.display(0)) … \(b.display(127))"
        case .continuous: return "\(b.formatted(0)) … \(b.formatted(127))"
        }
    }

    private func statusPill(_ b: RoleBinding?, hidden: Bool) -> some View {
        let (text, color): (String, Color?) = {
            if let b { return b.origin == .manual ? ("Manual", Theme.dynamics) : ("Auto", Theme.meterGreen) }
            return hidden ? ("Not in plugin", nil) : ("Unbound", nil)
        }()
        return Text(text).font(.system(size: 10.5, weight: .bold))
            .padding(.horizontal, 8).frame(width: 96, height: 22)
            .foregroundStyle(color == nil ? Theme.text3 : Theme.ground)
            .background(color ?? .clear, in: Capsule())
            .overlay(Capsule().stroke(color == nil ? Theme.line : .clear))
    }
}

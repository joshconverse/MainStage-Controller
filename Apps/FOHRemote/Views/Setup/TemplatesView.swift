import SwiftUI
import FOHCore

/// Setup › Plugin templates: the built-in templates (read-only) and templates saved from hand-tuned strips.
/// Custom templates match by plugin and win over the built-ins, so a tuned SSL binding follows the plugin to new strips.
struct TemplatesView: View {
    enum Selection: Hashable {
        case builtIn(String)
        case insert(String)
        case custom(String)
    }

    @Environment(MixerStore.self) private var store
    @State private var selection: Selection?
    @State private var deleteTarget: CustomTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 10) {
                list.frame(width: 380)
                detail.frame(maxWidth: .infinity)
            }
        }
        .alert("Delete “\(deleteTarget?.name ?? "")”?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete", role: .destructive) {
                if let t = deleteTarget {
                    store.deleteTemplate(t.id)
                    if case .custom(let id) = current, id == t.id { selection = nil }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Strips using it go back to the built-in template for \(deleteTarget?.pluginName ?? "that plugin"). Manual bindings are kept.")
        }
    }

    private var current: Selection? {
        selection ?? store.config.customTemplates.first.map { .custom($0.id) } ?? Templates.all.first.map { .builtIn($0.name) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Plugin templates").font(.system(size: 22, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("heading.templates")
            Text("Templates bind app controls to plugin parameters automatically. Save one from Setup › Processing (“Save as template…”) after hand-tuning a strip; it then applies to every strip with that plugin.")
                .font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Custom · \(store.config.customTemplates.count)")
                if store.config.customTemplates.isEmpty {
                    Text("None yet — hand-tune a strip in Processing, then “Save as template…”.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                        .padding(.vertical, 6)
                }
                ForEach(store.config.customTemplates) { t in
                    rowButton(.custom(t.id), title: t.name,
                              subtitle: "\(t.pluginName) · \(t.use == .processing ? "EQ / Dynamics / Trim" : "insert macros") · \(t.rules.count) rules",
                              badge: "CUSTOM", badgeColor: Theme.inserts)
                }
                SectionLabel("Built-in · processing").padding(.top, 10)
                ForEach(Templates.all, id: \.name) { t in
                    rowButton(.builtIn(t.name), title: t.name, subtitle: "EQ / Dynamics / Trim · \(t.rules.count) rules",
                              badge: "BUILT-IN", badgeColor: Theme.text3)
                }
                SectionLabel("Built-in · insert pages").padding(.top, 10)
                ForEach(Templates.inserts, id: \.name) { t in
                    rowButton(.insert(t.name), title: t.name, subtitle: "Insert macros · \(t.macros.count) macros",
                              badge: "BUILT-IN", badgeColor: Theme.text3)
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func rowButton(_ sel: Selection, title: String, subtitle: String, badge: String, badgeColor: Color) -> some View {
        let selected = current == sel
        return Button { selection = sel } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                Spacer()
                Text(badge).font(.system(size: 9.5, weight: .heavy)).foregroundStyle(badgeColor)
                    .padding(.horizontal, 6).frame(height: 18)
                    .overlay(Capsule().stroke(badgeColor.opacity(0.6)))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .background(selected ? Theme.raised2 : Theme.raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.text : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch current {
            case .custom(let id):
                if let t = store.config.customTemplates.first(where: { $0.id == id }) { customDetail(t) } else { empty }
            case .builtIn(let name):
                if let t = Templates.all.first(where: { $0.name == name }) { builtInDetail(t) } else { empty }
            case .insert(let name):
                if let t = Templates.inserts.first(where: { $0.name == name }) { insertDetail(t) } else { empty }
            case nil:
                empty
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var empty: some View {
        Text("Select a template.").foregroundStyle(Theme.text2).frame(maxWidth: .infinity, minHeight: 200)
    }

    private func titleBlock(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 18, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func customDetail(_ t: CustomTemplate) -> some View {
        let plugin = description(for: t)
        let rows = t.rules.sorted { (Role.byID[$0.key]?.cc ?? 0, $0.key) < (Role.byID[$1.key]?.cc ?? 0, $1.key) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                titleBlock(t.name, "Custom · \(t.pluginName)\(t.component.map { " (\($0))" } ?? "") · " +
                           (t.use == .processing ? "drives EQ / Dynamics / Trim" : "labels insert-page macros") +
                           (t.hidden.isEmpty ? "" : " · \(t.hidden.count) roles hidden"))
                Spacer()
                ToggleChip(title: "DELETE…", isOn: false, color: Theme.mute) { deleteTarget = t }
                    .frame(width: 110)
                    .accessibilityLabel("Delete \(t.name)")
            }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(rows, id: \.key) { pair in
                        ruleRow(roleLabel(pair.key), cc: Role.byID[pair.key]?.cc,
                                target: plugin?.parameter(id: pair.value.parameterID)?.name ?? "parameter \(pair.value.parameterID)",
                                note: pair.value.invert ? "inverted" : nil)
                    }
                    if !t.hidden.isEmpty {
                        Text("Hidden (not in plugin): " + t.hidden.compactMap { Role.byID[$0]?.label }.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(Theme.text3).padding(.top, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func builtInDetail(_ t: BindingTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            titleBlock(t.name, "Built-in · matches " + t.pluginMatches.joined(separator: ", ") +
                       " · roles bind by parameter name (first candidate found wins)")
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(t.rules.sorted { $0.role.cc < $1.role.cc }, id: \.role.id) { rule in
                        ruleRow(rule.role.label, cc: rule.role.cc, target: rule.candidates.joined(separator: " / "),
                                note: [rule.invert ? "inverted" : nil, rule.unit.map { "unit \($0)" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
                    }
                }
            }
        }
    }

    private func insertDetail(_ t: InsertTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            titleBlock(t.name, "Built-in · insert page macros · matches " + t.pluginMatches.joined(separator: ", "))
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(t.macros.enumerated()), id: \.offset) { item in
                        ruleRow("Macro \(item.element.macro)", cc: nil, target: item.element.candidates.joined(separator: " / "), note: nil)
                    }
                    ruleRow("Bypass", cc: nil, target: "MainStage plugin bypass", note: nil)
                }
            }
        }
    }

    private func ruleRow(_ role: String, cc: UInt8?, target: String, note: String?) -> some View {
        HStack(spacing: 10) {
            Text(role).font(.system(size: 13, weight: .semibold)).frame(width: 170, alignment: .leading).lineLimit(1)
            Text(cc.map { "CC \($0)" } ?? "").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text3).frame(width: 46, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
            Text(target).font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let note {
                Text(note).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text2)
                    .padding(.horizontal, 6).frame(height: 18).background(Theme.raised2, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 40)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
    }

    /// "macro.3" → "Macro 3"; role ids → their labels.
    private func roleLabel(_ key: String) -> String {
        if let r = Role.byID[key] { return r.label }
        if key.hasPrefix("macro.") { return "Macro \(key.dropFirst(6))" }
        return key
    }

    /// A discovered description of the template's plugin (bridge cache, or the demo fixtures), for parameter names.
    private func description(for t: CustomTemplate) -> PluginDescription? {
        if let c = t.component {
            if let d = store.pluginCache.values.first(where: { $0.component == c }) { return d }
            return DemoShow.plugins[c]
        }
        return store.pluginCache.values.first { BindingTemplate.normalize($0.name) == BindingTemplate.normalize(t.pluginName) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

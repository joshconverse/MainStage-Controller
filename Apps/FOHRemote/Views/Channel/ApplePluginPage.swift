import SwiftUI
import FOHCore

/// One of MainStage's own plugins (Channel EQ, Compressor…; PLAN.md §9c phase 5). FOH Bridge reads their parameter
/// names from the tables MainStage ships, so most work like any plugin (with Add control). A parameter no table lists
/// is taught once by hand: name it here, map it in MainStage, and every instance of the plugin gets it.
struct ApplePluginPage: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let plugin: PluginRef
    @State private var newName = ""
    @State private var query = ""

    @State private var teaching = false

    var body: some View {
        let c = store.pluginControls(strip, plugin.position)
        let pending = store.config.pendingLearns.filter { $0.strip == strip && $0.position == plugin.position }
        // MainStage ships a parameter table for most of its plugins (read by FOH Bridge); learning is for the rest.
        let table = store.pluginDescription(strip, plugin.position)?.parameters.contains { $0.group != PluginDescription.learnedGroup } ?? false
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.system(size: 18, weight: .bold))
                    let learned = c.all.filter { $0.info?.group == PluginDescription.learnedGroup }.count
                    Text("MainStage plugin · insert \(plugin.position)\(plugin.preset.map { " · \($0)" } ?? "") · \(c.all.count) controls"
                         + (learned > 0 ? " (\(learned) learned)" : ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Spacer()
                if let page = store.selected?.processing.insertPages.first(where: { $0.value == plugin.position })?.key,
                   let role = Role.insertBypass(page) {
                    RoleToggle(strip: strip, role: role, title: "BYPASS", color: Theme.mute).frame(width: 96)
                }
            }
            if table {
                PluginMappingNotice(controls: c)
                Text("Values show as 0–100%: MainStage doesn't publish its plugins' ranges.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                PluginControlsPanel(strip: strip, plugin: plugin, showsHeader: false)
                if teaching || !pending.isEmpty {
                    learnCard(pending)
                } else {
                    Button("A parameter isn't in MainStage's list? Teach it by hand…") { teaching = true }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sends)
                }
            } else {
                if !c.isEmpty {
                    PluginMappingNotice(controls: c)
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                        TextField("Search \(c.all.count) controls", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                    PluginControlsBrowser(controls: c, pluginName: plugin.name, query: query)
                        .frame(maxHeight: .infinity)
                }
                learnCard(pending)
                if c.isEmpty { Spacer(minLength: 0) }
            }
        }
        .requestingPlugin(store, strip, plugin.position, described: table)
    }

    private func learnCard(_ pending: [PendingLearn]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TEACH FOH REMOTE A \(plugin.name.uppercased()) CONTROL").font(.system(size: 11, weight: .heavy)).tracking(0.8)
                .foregroundStyle(Theme.inserts)
            Text("FOH Bridge can't read MainStage's own plugins, so each control is mapped by hand once. After that, every "
                 + "\(plugin.name) in the show gets it, mapped by FOH Bridge.")
                .font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField("Control name, e.g. Low Cut Freq", text: $newName)
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityIdentifier("learn.name")
                ToggleChip(title: "START", isOn: true, color: Theme.inserts, height: 40) {
                    store.startPluginLearn(strip, plugin.position, name: newName)
                    newName = ""
                }
                .frame(width: 110)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(pending) { learn in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(learn.name).font(.system(size: 14, weight: .semibold))
                        Text("Waiting for MainStage · FOH Plugins \(learn.address.port == .plugins1 ? 1 : 2) · ch \(learn.address.channel) · CC \(learn.address.cc)")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    ToggleChip(title: "SEND", isOn: true, color: Theme.sends, height: 36) { store.sendPluginLearn(learn) }.frame(width: 90)
                    ToggleChip(title: "CANCEL", isOn: false, color: Theme.mute, height: 36) { store.cancelPluginLearn(learn) }.frame(width: 96)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("learn.pending")
            }
            if !pending.isEmpty {
                MapByHandSteps(plugin: plugin.name, strip: store.selected?.name ?? strip.key, parameter: "the \(plugin.name) parameter")
                HStack {
                    Spacer()
                    ToggleChip(title: "CHECK THE SAVED CONCERT NOW", isOn: true, color: Theme.inserts, height: 36) { store.checkPluginLearns() }
                        .frame(width: 280)
                }
            }
        }
        .padding(12)
        .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// How to map one control by hand in MainStage, for a learn and for the first control on a strip MainStage hasn't
/// confirmed (a mono output strip needs one before FOH Bridge can map the rest).
struct MapByHandSteps: View {
    let plugin: String
    let strip: String
    let parameter: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            step(1, "In MainStage, open \(plugin) on \(strip) and turn on Assign & Map (Edit mode).")
            step(2, "Tap SEND here, then click \(parameter) in MainStage. The parameter jumps as it maps: set it back after.")
            step(3, "Turn Assign & Map off, save the concert, and quit MainStage. FOH Bridge reads the mapping and does the rest.")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .heavy)).frame(width: 18, height: 18)
                .background(Circle().fill(Theme.raised2))
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Map one control of a plugin by hand: for a strip where MainStage hasn't confirmed any (Output 1/2 are mono
/// outputs, which need one hand-made Assign & Map before FOH Bridge can map the rest).
struct MapByHandSheet: View {
    @Environment(MixerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let controls: PluginControls
    let pluginName: String

    var body: some View {
        let first = controls.all.first
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Map one \(pluginName) control by hand").font(.system(size: 18, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("mapbyhand.done")
            }
            Text("MainStage hasn't confirmed any of these controls. On some strips (mono outputs) FOH Bridge needs one mapping made "
                 + "in MainStage before it can map the rest. Map this one, and the next update maps everything else on the strip.")
                .font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if let first {
                MapByHandSteps(plugin: pluginName, strip: store.config.strip(controls.strip)?.name ?? controls.strip.key,
                               parameter: "\(pluginName)'s “\(first.name)”")
                ToggleChip(title: "SEND (\(first.name.uppercased()))", isOn: true, color: Theme.sends) { store.sendLearnSignal(first) }
                    .frame(width: 300)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 360)
        .background(Theme.panel)
    }
}

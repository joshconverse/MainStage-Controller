import SwiftUI
import FOHCore

/// Waves Tune Real-Time on its plugin controls (PLAN.md §9c phase 4; the insert-page macro version remains for a
/// Tune without them): key and scale, the correction controls, and everything else under ALL CONTROLS.
struct TunePluginPage: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let plugin: PluginRef

    var body: some View {
        let c = store.pluginControls(strip, plugin.position)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.system(size: 18, weight: .bold))
                    Text("Insert \(plugin.position)\(plugin.preset.map { " · \($0)" } ?? "") · \(c.all.count) controls")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Spacer()
                bypass(c)
                AllControlsButton(strip: strip, plugin: plugin)
            }
            PluginMappingNotice(controls: c)
            if c.described {
                if let key = c["Scale Root"] {
                    section("KEY", key.name) { PluginPicker(param: key, columns: 9) }
                }
                if let scale = c["Scale Type"] {
                    section("SCALE", "\(scale.name) · \(scale.stepCenters.count) scales (the rest under ALL CONTROLS)") {
                        PluginPicker(param: scale, columns: 6, include: { TunePage.commonScales.contains($0) })
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    control(c["Speed"], "Speed")
                    control(c["Note Transition"], "Note transition")
                    control(c["Correction"], "Correction")
                    control(c["Correction On/Off"], "Correction")
                    control(c["Vibrato Depth"], "Vibrato depth")
                    control(c["Vibrato On/Off"], "Vibrato")
                    control(c["Formant"], "Formant")
                }
                Spacer(minLength: 0)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .requestingPlugin(store, strip, plugin.position, described: c.described)
    }

    /// The plugin's own bypass if it's a control, else the strip's insert bypass (a channel-strip control).
    @ViewBuilder
    private func bypass(_ c: PluginControls) -> some View {
        if let p = c["Bypass"] {
            PluginToggle(param: p, title: "BYPASS", color: Theme.mute).frame(width: 96)
        } else if let page = store.selected?.processing.insertPages.first(where: { $0.value == plugin.position })?.key,
                  let role = Role.insertBypass(page) {
            RoleToggle(strip: strip, role: role, title: "BYPASS", color: Theme.mute).frame(width: 96)
        }
    }

    /// A switch for two-state parameters, a knob for the rest.
    @ViewBuilder
    private func control(_ p: PluginParam?, _ title: String) -> some View {
        if let p, p.isToggle {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                ToggleChip(title: store.display(p).uppercased(), isOn: store.isOn(p), color: Theme.inserts) { store.toggle(p) }
                    .frame(width: 96)
            }
        } else {
            PluginKnob(param: p, title: title, size: 64)
        }
    }

    private func section<Content: View>(_ title: String, _ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .heavy)).tracking(1)
                Text(caption).font(.system(size: 10)).foregroundStyle(Theme.text3)
            }
            content()
        }
    }
}

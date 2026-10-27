import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FOHCore
import FOHMacKit

/// The menu-bar popover (design canvas board 9, native macOS).
struct BridgeMenuView: View {
    let server: BridgeServer
    @Environment(\.openWindow) private var openWindow
    private var hud: LearnHUDController { LearnHUDController.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(server.startupWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    clients
                    mainStage
                    setlist
                    learn
                    audio
                    plugins
                    templates
                    concert
                    backups
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 640)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { server.refreshInputDevices() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("FOH Bridge").font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Circle().fill(server.isRunning ? Color.green : Color.red).frame(width: 9, height: 9)
                .help(server.isRunning ? "Running" : "Stopped")
        }
    }

    private var statusLine: String {
        guard server.isRunning else { return "Stopped — see the log" }
        let port = server.listeningPort.map { "OSC :\($0)" } ?? "OSC starting…"
        return "Running · \(port) · Bonjour \(FOHProtocol.bonjourType)\n\(server.bonjourName)"
    }

    private var clients: some View {
        section("Clients") {
            if server.status.clients.isEmpty {
                Text("No iPad connected. Open FOH Remote on the same Wi-Fi.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(server.status.clients, id: \.self) { name in
                    HStack(spacing: 8) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text(name).font(.callout)
                        Spacer()
                        Text("full control").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var mainStage: some View {
        section("MainStage ports") {
            ForEach(server.status.ports, id: \.name) { port in
                HStack(spacing: 8) {
                    Circle().fill(port.sent + port.received > 0 ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(port.name).font(.callout)
                    Spacer()
                    Text("↑\(port.sent)  ↓\(port.received)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: port.feedbackSeen ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(port.feedbackSeen ? Color.green : Color.secondary)
                        .help(port.feedbackSeen ? "MainStage feedback seen" : "No feedback yet — set Send Value to → \(port.name)")
                }
            }
            let seen = server.status.ports.filter(\.feedbackSeen).count
            Text("Feedback (Send Value to) seen on \(seen) of \(server.status.ports.count) ports")
                .font(.caption).foregroundStyle(.secondary)
            if server.echoStats.count > 0 {
                Text(String(format: "MainStage round trip: avg %.1f ms (min %.1f · max %.1f · n %d)", server.echoStats.averageMS,
                            server.echoStats.minMS, server.echoStats.maxMS, server.echoStats.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var setlist: some View {
        section("Setlist") {
            if server.show.patches.isEmpty {
                Text("No patches — import the concert to read its setlist.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("Patch", selection: Binding(
                        get: { server.show.currentPatch ?? -1 },
                        set: { server.selectPatch($0) })) {
                        ForEach(server.show.patches) { patch in
                            Text(patch.programChange.map { "\(patch.name)  ·  PC \($0)" } ?? "\(patch.name)  ·  no PC").tag(patch.index)
                        }
                    }
                    .labelsHidden()
                    Button("Pull from MainStage") { server.pullFromMainStage() }
                        .help("Re-selects the current patch so MainStage re-sends every mapped value (needs Send Value to)")
                }
                .controlSize(.small)
            }
        }
    }

    private var learn: some View {
        section("MainStage learn") {
            HStack {
                Toggle("Show Learn HUD", isOn: Binding(get: { hud.isVisible }, set: { hud.setVisible($0, server: server) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                let progress = server.learnProgress
                Text("\(progress.learned) / \(progress.total) learned").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("⌃⌥Space send sweep · ⌃⌥→ learned & next · ⌃⌥← back — works while MainStage is in front.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var inputTapSummary: String {
        if let device = server.status.inputDevice { return "\(device) · \(server.status.inputChannelCount ?? 0) ch" }
        if let waiting = server.status.inputWaitingFor { return "waiting for \(waiting) — plug it in" }
        return "off (no device or no microphone permission)"
    }

    private var audio: some View {
        section("Meters") {
            HStack {
                Picker("Input", selection: Binding(
                    get: { server.inputDeviceUID ?? "" },
                    set: { server.setInputDevice(uid: $0.isEmpty ? nil : $0) })) {
                    Text("System default input").tag("")
                    ForEach(server.inputDevices) { device in
                        Text("\(device.name) · \(device.inputChannels) in").tag(device.uid)
                    }
                }
                Button { server.refreshInputDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan audio devices")
            }
            .controlSize(.small)
            Text("Input tap: \(inputTapSummary)")
                .font(.caption).foregroundStyle(server.status.inputWaitingFor == nil ? Color.secondary : Color.orange)
            Text("Output tap: \(server.status.outputTap ?? "off — MainStage not running, or System Audio Recording not allowed")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var plugins: some View {
        section("Plugins · discovery") {
            if server.isDiscovering {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading plugin parameters…").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(server.status.discoveredPlugins, id: \.self) { name in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").foregroundStyle(.green).font(.caption.weight(.bold))
                    Text(name).font(.callout)
                    Spacer()
                    Text("params read").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Used by Setup › Processing for real units and curves.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Rescan") { server.rediscover() }
                    .controlSize(.small)
                    .disabled(server.isDiscovering)
            }
        }
    }

    private var concert: some View {
        section("Concert") {
            let strips = server.show.strips
            let inputs = strips.filter { $0.ref.kind == .input }.count
            let fx = strips.filter { $0.ref.kind == .fx }.count
            let outputs = strips.filter { $0.ref.kind == .output }.count
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.show.concertPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "\(server.show.name).concert")
                        .font(.callout)
                    Text("\(inputs) input\(inputs == 1 ? "" : "s") · \(fx) FX return\(fx == 1 ? "" : "s") · \(outputs) output\(outputs == 1 ? "" : "s") · \(server.show.patches.count) patch\(server.show.patches.count == 1 ? "" : "es")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(server.valueCount) values cached · \(server.confirmedCount) confirmed by MainStage")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Confirmed = MainStage reported the value (Send Value to). Others are the bridge's assumptions.")
                }
                Spacer()
                Button("Import concert…") { importConcert() }
                    .controlSize(.small)
            }
            // The MainStage sync (PLAN.md §9c): the bridge writes its assignments into the concert while MainStage is closed.
            let sync = server.mainStageSync
            Label(sync.summary, systemImage: sync.phase == .failed ? "exclamationmark.triangle.fill"
                  : sync.phase == .waiting ? "clock" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(sync.phase == .failed ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help("FOH Bridge writes its MIDI assignments into the concert itself, only while MainStage is closed. The previous version is kept in Concert backups.")
            HStack {
                Button("Update MainStage assignments") { server.updateMainStage(trigger: "Mac menu") }
                    .disabled(sync.phase == .running)
                Button("Concert backups") {
                    let folder = server.concertBackupDirectory
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
            }
            .controlSize(.small)
        }
    }

    private var templates: some View {
        section("Custom templates") {
            if server.show.customTemplates.isEmpty {
                Text("None yet — use Save as template in the iPad's Setup › Processing.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(server.show.customTemplates) { t in
                    HStack(spacing: 8) {
                        Image(systemName: t.use == .processing ? "slider.horizontal.3" : "square.stack.3d.up")
                            .foregroundStyle(.secondary).font(.caption)
                        Text(t.name).font(.callout)
                        Spacer()
                        Text("\(t.pluginName) · \(server.stripsUsing(t).count) strip\(server.stripsUsing(t).count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var backups: some View {
        section("Backups") {
            if server.backups.isEmpty {
                Text("No snapshots yet. One is taken automatically before imports, restores and big changes.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(server.backups.prefix(5)) { b in
                    HStack(spacing: 8) {
                        Text(b.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        Text(b.reason).font(.callout).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Button("Restore…") { confirmRestore(b) }.controlSize(.small)
                    }
                }
                if server.backups.count > 5 {
                    Text("\(server.backups.count - 5) older snapshot\(server.backups.count - 5 == 1 ? "" : "s") — restore them from the iPad's Setup › Backup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Snapshot now") { server.createBackup(reason: "Snapshot from the Mac menu") }
                Button("Export…") { exportShow() }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) { confirmPushAll() } label: {
                Text("Push all values to MainStage…")
            }
            .disabled(server.valueCount == 0)
            Spacer()
            Button("Open log") {
                openWindow(id: "log")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") {
                server.stop()
                NSApp.terminate(nil)
            }
        }
        .controlSize(.small)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            content()
        }
    }

    private func importConcert() {
        let panel = NSOpenPanel()
        panel.title = "Import a MainStage concert"
        panel.message = "Choose a .concert — strips keep their slots; new ones are added."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "concert") ?? .package, .package, .folder]
        panel.directoryURL = server.show.concertPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "concert" else {
            server.appendLog("Import: \(url.lastPathComponent) isn't a .concert")
            return
        }
        server.mergeConcertInBackground(path: url.path) { ack in server.appendLog(ack.message) }
    }

    private func confirmRestore(_ backup: BackupInfo) {
        let alert = NSAlert()
        alert.messageText = "Restore the snapshot from \(backup.date.formatted(date: .abbreviated, time: .shortened))?"
        alert.informativeText = "\(backup.reason)\n\nStrips, sends, setlist, bindings, templates, learn progress and cached values go back to that point. The current state is snapshotted first, and nothing is sent to MainStage."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let ack = server.restoreBackup(id: backup.id)
            if !ack.ok { server.appendLog("Restore failed: \(ack.message)") }
        }
    }

    private func exportShow() {
        let bundle = server.exportBundle()
        let panel = NSSavePanel()
        panel.title = "Export show"
        panel.nameFieldStringValue = bundle.suggestedFilename
        panel.allowedContentTypes = [UTType(filenameExtension: "fohshow") ?? .json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(bundle).write(to: url, options: .atomic)
            server.appendLog("Exported show to \(url.path)")
        } catch {
            server.appendLog("Export failed: \(error)")
        }
    }

    private func confirmPushAll() {
        let alert = NSAlert()
        alert.messageText = "Push all values to MainStage?"
        alert.informativeText = "Re-sends all \(server.valueCount) cached values. Use this after MainStage restarts — its controls will jump to the bridge's values."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Push")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            server.pushAllToMainStage()
        }
    }
}

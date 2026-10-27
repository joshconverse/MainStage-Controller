import SwiftUI
import UniformTypeIdentifiers
import FOHCore

/// Setup › Backup & restore: the bridge's snapshots (automatic before risky changes, or on demand), plus export and
/// import of a whole show as a `.fohshow` file.
struct BackupView: View {
    @Environment(MixerStore.self) private var store
    @State private var askReason = false
    @State private var reason = ""
    @State private var restoreTarget: BackupInfo?
    @State private var importing = false
    @State private var pendingImport: BackupBundle?

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 10) {
                snapshotList
                    .frame(maxWidth: .infinity)
                sidePanel
                    .frame(width: 360)
            }
        }
        .onAppear { store.listBackups() }
        // On a cold launch the screen appears before the bridge has synced; ask again once it has.
        .onChange(of: store.synced) { _, synced in if synced { store.listBackups() } }
        .alert("Snapshot now", isPresented: $askReason) {
            TextField("Reason (e.g. Before Sunday soundcheck)", text: $reason)
            Button("Save snapshot") { store.createBackup(reason: reason); reason = "" }
            Button("Cancel", role: .cancel) { reason = "" }
        } message: {
            Text(store.isDemo ? "Saved on this iPad (demo)." : "Saved on the bridge with the show, bindings, learn progress and values.")
        }
        .alert("Restore this snapshot?", isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })) {
            Button("Restore", role: .destructive) { if let t = restoreTarget { store.restoreBackup(t.id) }; restoreTarget = nil }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: {
            Text(restoreTarget.map { "“\($0.reason)” from \(Self.dateText($0.date)) replaces the current show, bindings and learn progress. The bridge snapshots the current state first." } ?? "")
        }
        .alert("Import this show?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            Button("Import", role: .destructive) { if let b = pendingImport { store.importBackup(b) }; pendingImport = nil }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text(pendingImport.map { "“\($0.show.name)” · \($0.show.strips.count) strips · saved \(Self.dateText($0.created)) (\($0.reason)). It replaces the current show." } ?? "")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes) { result in
            switch result {
            case .success(let url): readImport(url)
            case .failure(let e): store.showToast("Couldn't open the file: \(e.localizedDescription)", ok: false)
            }
        }
    }

    static let importTypes: [UTType] = [UTType("io.itstudios.foh.show"), UTType(filenameExtension: "fohshow"), .json].compactMap { $0 }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Backup & restore").font(.system(size: 22, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("heading.backup")
                Text(store.isDemo ? "Demo — snapshots stay on this iPad." :
                        "The bridge snapshots the show automatically before concert merges, config changes, template resets, calibration and restores (newest 30 kept).")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            ToggleChip(title: "SNAPSHOT NOW", isOn: true, color: Theme.sends) { askReason = true }
                .frame(width: 160)
                .disabled(!store.isDemo && !store.connection.isConnected)
        }
    }

    private var snapshotList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(store.isDemo ? "Snapshots · this iPad" : "Snapshots on the bridge · \(store.backups.count)")
            ScrollView {
                VStack(spacing: 4) {
                    if store.backups.isEmpty {
                        Text(store.connection.isConnected || store.isDemo ? "No snapshots yet." : "Connect to FOH Bridge to see its snapshots.")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    ForEach(store.backups) { b in row(b) }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ b: BackupInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(for: b.reason)).frame(width: 28).foregroundStyle(Theme.text2)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.reason).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(Self.dateText(b.date)) · \(b.stripCount) strips").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            }
            Spacer()
            ToggleChip(title: "RESTORE…", isOn: false, color: Theme.mute) { restoreTarget = b }
                .frame(width: 110)
                .accessibilityLabel("Restore \(b.reason)")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 56)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Show file (.fohshow)")
            Text("Everything needed to rebuild this console on another Mac or iPad: strips, sends, setlist, bindings, custom templates, fader calibration, learn progress and the last known values.")
                .font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            ToggleChip(title: "EXPORT SHOW…", isOn: true, color: Theme.sends) { store.exportBackup() }
                .disabled(!store.isDemo && !store.connection.isConnected)
            if let url = store.exportURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ready: \(url.lastPathComponent)").font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                    ShareLink(item: url) {
                        Label("Save or share…", systemImage: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(Theme.ground)
                            .background(Theme.text, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
            }
            ToggleChip(title: "IMPORT SHOW…", isOn: false, color: Theme.text) { importing = true }
                .disabled(!store.isDemo && !store.connection.isConnected)
            Text("Importing replaces the current show. The bridge snapshots the current state first, so you can always go back.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func readImport(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pendingImport = try JSONDecoder().decode(BackupBundle.self, from: data)
        } catch {
            store.showToast("That file isn't a FOH show (\(error.localizedDescription))", ok: false)
        }
    }

    static func dateText(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    static func icon(for reason: String) -> String {
        let r = reason.lowercased()
        if r.contains("merge") || r.contains("concert") { return "square.and.arrow.down.on.square" }
        if r.contains("calibrat") { return "slider.horizontal.below.square.and.square.filled" }
        if r.contains("restore") || r.contains("import") { return "clock.arrow.circlepath" }
        if r.contains("template") || r.contains("reset") { return "square.on.square" }
        return "externaldrive"
    }
}

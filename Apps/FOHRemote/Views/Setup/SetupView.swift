import SwiftUI
import FOHCore

struct SetupView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SetupSection.allCases) { s in
                    Button { store.setupSection = s } label: {
                        HStack(spacing: 10) {
                            Image(systemName: s.icon).frame(width: 20)
                            Text(s.rawValue).font(.system(size: 14, weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .foregroundStyle(store.setupSection == s ? Theme.ground : Theme.text)
                        .background(store.setupSection == s ? Theme.text : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.setupSection == s ? .isSelected : [])
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 220)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))

            Group {
                switch store.setupSection {
                case .connection: ConnectionView()
                case .channels: ChannelsView()
                case .processing: ProcessingView()
                case .learn: LearnView()
                case .verify: VerifyView()
                case .templates: TemplatesView()
                case .backup: BackupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The 4-step setup flow: Channels & I/O → Processing → MainStage learn → Verify.
struct SetupFlowIndicator: View {
    @Environment(MixerStore.self) private var store
    let current: Int
    private let steps = ["Channels & I/O", "Processing", "MainStage learn", "Verify"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, title in
                let n = i + 1
                Button { go(n) } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(n < current ? Theme.meterGreen : n == current ? Theme.text : Theme.raised2)
                            if n < current {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                            } else {
                                Text("\(n)").font(.system(size: 11, weight: .heavy))
                            }
                        }
                        .frame(width: 22, height: 22)
                        .foregroundStyle(n <= current ? Theme.ground : Theme.text2)
                        Text(title)
                            .font(.system(size: 12.5, weight: n == current ? .bold : .medium))
                            .foregroundStyle(n == current ? Theme.text : Theme.text2)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(n == current ? Theme.raised2 : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(n): \(title)\(n == current ? ", current" : n < current ? ", done" : "")")
                if n < steps.count { Rectangle().fill(Theme.line).frame(width: 16, height: 1) }
            }
            Spacer()
        }
    }

    private func go(_ n: Int) {
        switch n {
        case 1: store.setupSection = .channels
        case 2: store.setupSection = .processing
        case 3: store.setupSection = .learn
        case 4: store.setupSection = .verify
        default: break
        }
    }
}

struct ConnectionView: View {
    @Environment(MixerStore.self) private var store
    @Environment(BridgeClient.self) private var client
    @State private var confirmPush = false

    var body: some View {
        @Bindable var client = client
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connection").font(.system(size: 22, weight: .bold))
                card {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.connection.label).font(.system(size: 16, weight: .semibold))
                            if let name = store.bridgeName { Text("Bridge reports: \(name)").font(.system(size: 12)).foregroundStyle(Theme.text2) }
                            Text(store.isDemo ? "Showing the offline demo show (Church.concert + bundled SSL/Tune discovery)." :
                                    "Show “\(store.config.name)” · \(store.config.strips.count) strips · \(store.values.count) values\(store.synced ? " · synced" : "")")
                                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        if store.connection.isConnected {
                            ToggleChip(title: "RESYNC", isOn: false, color: Theme.sends) { client.requestSync() }.frame(width: 100)
                            ToggleChip(title: "DISCONNECT", isOn: false, color: Theme.mute) { client.disconnect(); store.connection = .demo }.frame(width: 120)
                        }
                        ToggleChip(title: "USE DEMO", isOn: store.isDemo, color: Theme.eq) { client.useDemo() }.frame(width: 110)
                    }
                }
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Bridges on this network (Bonjour \(FOHProtocol.bonjourType))")
                        if client.discovered.isEmpty {
                            Text("None found yet. Make sure FOH Bridge is running on the Mac and both are on the same Wi-Fi.")
                                .font(.system(size: 13)).foregroundStyle(Theme.text2)
                        }
                        ForEach(client.discovered) { d in
                            Button { client.connect(.bonjour(name: d.name, endpoint: d.endpoint)) } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    Text(d.name).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Text(client.target == .bonjour(name: d.name, endpoint: d.endpoint) ? "Selected" : "Connect")
                                        .foregroundStyle(Theme.sends)
                                }
                                .padding(.horizontal, 12).frame(minHeight: 48)
                                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                        Toggle("Connect automatically to the first bridge found", isOn: $client.autoConnect)
                            .font(.system(size: 13)).tint(Theme.sends)
                    }
                }
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Manual host")
                        HStack {
                            TextField("host:port", text: $client.manualHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 15).monospacedDigit())
                                .padding(.horizontal, 12).frame(height: 44)
                                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                                .accessibilityLabel("Bridge host and port")
                            ToggleChip(title: "CONNECT", isOn: true, color: Theme.sends) { client.connectManual() }.frame(width: 120)
                        }
                        Text("From the Simulator, 127.0.0.1:9000 reaches a bridge running on this Mac.")
                            .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("MainStage state")
                        HStack(spacing: 10) {
                            ToggleChip(title: "PULL FROM MAINSTAGE", isOn: store.connection.isConnected, color: Theme.sends) {
                                store.pullFromMainStage()
                            }
                            .frame(width: 210)
                            .disabled(!store.connection.isConnected)
                            ToggleChip(title: "PUSH ALL TO MAINSTAGE…", isOn: false, color: Theme.mute) { confirmPush = true }
                                .frame(width: 230)
                                .disabled(!store.connection.isConnected)
                            Spacer()
                        }
                        Text("Pull re-selects the current patch so MainStage re-sends every mapped value (needs “Send Value to”). Push overwrites MainStage with the bridge’s cached values.")
                            .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        if let sync = store.status?.mainStageSync {
                            HStack(spacing: 10) {
                                ToggleChip(title: "UPDATE ASSIGNMENTS", isOn: false, color: Theme.eq) { store.updateMainStageAssignments() }
                                    .frame(width: 210)
                                    .disabled(!store.connection.isConnected)
                                Text(sync).font(.system(size: 13, weight: .semibold))
                                Spacer()
                            }
                            Text("The bridge writes its MIDI assignments (plugin controls included) into the concert itself, only while MainStage is closed, and keeps the previous version as a backup on the Mac.")
                                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                        if !store.isDemo {
                            let counts = store.confirmationCounts
                            HStack(spacing: 8) {
                                Image(systemName: counts.confirmed == counts.total && counts.total > 0 ? "checkmark.seal.fill" : "questionmark.circle")
                                    .foregroundStyle(counts.confirmed == counts.total && counts.total > 0 ? Theme.meterGreen : Theme.eq)
                                Text(store.confirmationsSupported ? "\(counts.confirmed) of \(counts.total) values confirmed by MainStage" :
                                        "This bridge doesn't report which values MainStage confirmed")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .accessibilityElement(children: .combine)
                            Text("Values marked ≈ are the bridge's assumption. Set “Send Value to” on each MainStage assignment, then use Pull to confirm them.")
                                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                        Toggle("Guard master — hold 0.5 s to arm the master fader and mute", isOn: $store.guardMaster)
                            .font(.system(size: 13)).tint(Theme.eq)
                    }
                }
                .alert("Push all values to MainStage?", isPresented: $confirmPush) {
                    Button("Push all", role: .destructive) { store.pushAllToMainStage() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every cached fader, EQ, dynamics and send value is sent to MainStage, replacing what it has now.")
                }
                if let status = store.status {
                    card {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Bridge status")
                            HStack(spacing: 18) {
                                statusItem("Input meters", status.inputDevice.map { "\($0)\(status.inputChannelCount.map { " · \($0) in" } ?? "")" }
                                           ?? status.inputWaitingFor.map { "waiting for \($0)" } ?? "no input device")
                                statusItem("Output tap", status.outputTap ?? "not running")
                                statusItem("Echo round trip", status.echoRTTms.map { String(format: "%.1f ms", $0) } ?? "no feedback yet")
                            }
                            ForEach(status.ports, id: \.name) { p in
                                HStack {
                                    Circle().fill(p.feedbackSeen ? Theme.meterGreen : Theme.text3).frame(width: 8, height: 8)
                                    Text(p.name).font(.system(size: 13, weight: .semibold)).frame(width: 140, alignment: .leading)
                                    Text("sent \(p.sent) · received \(p.received)").font(.system(size: 12)).foregroundStyle(Theme.text2)
                                    Spacer()
                                    Text(p.feedbackSeen ? "MainStage feedback seen" : "no feedback yet").font(.system(size: 11))
                                        .foregroundStyle(p.feedbackSeen ? Theme.meterGreen : Theme.text3)
                                }
                            }
                            if !status.discoveredPlugins.isEmpty {
                                Text("Plugins discovered: " + status.discoveredPlugins.joined(separator: ", "))
                                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                            }
                            if !status.clients.isEmpty {
                                Text("Clients: " + status.clients.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(Theme.label).tracking(0.8).foregroundStyle(Theme.text3)
            Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

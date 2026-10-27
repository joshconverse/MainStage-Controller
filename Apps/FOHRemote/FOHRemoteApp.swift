import SwiftUI
import FOHCore

@main
struct FOHRemoteApp: App {
    @State private var store: MixerStore
    @State private var client: BridgeClient
    @State private var meters: MeterStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = MixerStore()
        let meters = MeterStore()
        store.meters = meters
        meters.startDemo(store.config)
        let client = BridgeClient(store: store)
        LaunchOptions.apply(to: store, client: client)
        _store = State(initialValue: store)
        _client = State(initialValue: client)
        _meters = State(initialValue: meters)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(client)
                .environment(meters)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Auto-Lock would suspend the app, and drop the bridge, during a long sermon.
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: client.appBecameActive()
            case .background: client.appEnteredBackground()
            default: break
            }
        }
    }
}

/// Launch arguments for screenshots and testing:
/// `-demo` stay offline · `-host 127.0.0.1:9000` connect to a host
/// `-screen mixer|eq|dynamics|inserts|sends|routing|setup|connection|channels|processing|learn`
/// `-strip in/2` select a strip · `-plugin 2` open that plugin on Inserts · `-sof 3` sends-on-faders for send 3 · `-import` open the concert import preview
/// `-locked` start locked · `-offline` show the reconnecting state (with `-demo`) · `-armed` arm the master.
/// `-screen templates|backup|verify` · `-reorder` Channels & I/O in reorder mode · `-toast` show a sample toast.
/// `-badconfig` feed an unreadable `/foh/config` (with `-demo`), as from a bridge on another version.
enum LaunchOptions {
    @MainActor
    static func apply(to store: MixerStore, client: BridgeClient) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let s = value("-strip"), let ref = StripRef(key: s) { store.selectedStrip = ref }
        if let s = value("-plugin"), let n = Int(s) { store.insertPosition = n }
        if let s = value("-sof"), let n = Int(s) { store.sendsOnFaders = n }
        switch value("-screen") {
        case "eq": store.tab = .channel; store.channelSection = .eq
        case "dynamics": store.tab = .channel; store.channelSection = .dynamics
        case "inserts": store.tab = .channel; store.channelSection = .inserts
        case "sends": store.tab = .channel; store.channelSection = .sends
        case "routing": store.tab = .routing
        case "setup", "connection": store.tab = .setup; store.setupSection = .connection
        case "channels": store.tab = .setup; store.setupSection = .channels
        case "processing": store.tab = .setup; store.setupSection = .processing
        case "learn": store.tab = .setup; store.setupSection = .learn
        case "verify": store.tab = .setup; store.setupSection = .verify
        case "templates": store.tab = .setup; store.setupSection = .templates
        case "backup": store.tab = .setup; store.setupSection = .backup
        default: break
        }
        if args.contains("-locked") { store.locked = true }
        if args.contains("-reorder") { store.channelsReorder = true }
        if args.contains("-toast") { store.showToast("Re-selected Song One — MainStage re-sent 56 values") }
        if args.contains("-armed") { store.armMaster() }
        if args.contains("-demo") {
            client.autoConnect = false
            store.connection = .demo
            client.startBrowsing()
            if args.contains("-import") { store.scanConcert() }
            if args.contains("-offline") {
                store.meters?.stopDemo()
                store.isDemo = false
                store.connection = .failed("no route to host")
            }
            if args.contains("-badconfig") {
                store.connection = .connected("test")   // as if a bridge answered (nothing is sent: no socket)
                store.handle(OSCMessage(FOHProtocol.Path.config, [.blob(Data("{}".utf8))]))
            }
            return
        }
        if let host = value("-host") {
            client.autoConnect = false   // an explicit host: never hop to another bridge Bonjour finds
            client.manualHost = host
            client.connectManual()
        }
        client.startBrowsing()
        if args.contains("-e2e") { EndToEndScript.run(store: store) }
    }
}

/// `-e2e`: after the first sync, drive a few Lead vox controls through the real store → client → TCP path,
/// so the iPad → Bridge → MIDI direction can be verified from the command line (no taps needed).
enum EndToEndScript {
    @MainActor
    static func run(store: MixerStore) {
        Task { @MainActor in
            while !store.synced { try? await Task.sleep(for: .milliseconds(100)) }
            let kelly = StripRef.input(1)
            let steps: [(Role, Int)] = [
                (.mute, 127), (.mute, 0),
                (.fader, 100),
                (Role.band(2, "gain")!, 100),
                (.eqOn, 0), (.eqOn, 127),
                (Role.insertMacro(1, 3)!, 60),
            ]
            for (role, value) in steps {
                store.set(kelly, role, value)
                try? await Task.sleep(for: .milliseconds(300))
            }
            store.setNumeric(kelly, Role.band(2, "freq")!, 1010)   // "1.01" kHz → MIDI 64
            // A plugin control (PLAN.md §9c): Pro-Q 3's output level on insert 2, out on the plugin port and back.
            if let output = store.pluginControls(kelly, 2)["Output Level"] {
                let before = store.value(output)
                try? await Task.sleep(for: .milliseconds(300))
                store.set(output, 100)
                try? await Task.sleep(for: .milliseconds(300))
                store.set(output, before)
            }
        }
    }
}

#if os(macOS)
import Foundation
import Network
import Observation
import SystemConfiguration
import FOHCore

/// The outcome of a client request, sent back as `/foh/ack` to the client that asked.
public struct BridgeAck: Hashable, Sendable {
    public var ok: Bool
    public var message: String

    public static func ok(_ message: String) -> BridgeAck { BridgeAck(ok: true, message: message) }
    public static func fail(_ message: String) -> BridgeAck { BridgeAck(ok: false, message: message) }
}

/// The FOH Bridge (PLAN.md §2): OSC over TCP from the iPad ↔ virtual MIDI ports into MainStage.
///
/// All state lives on the main thread. Network callbacks run on `netQueue` and CoreMIDI callbacks on
/// CoreMIDI's thread; both hop to main before touching state. Plugin discovery runs on its own thread,
/// and the meter source delivers frames on its own queue.
///
/// Feature areas live in extensions: `BridgeServer+Config` (show editing, concert import, bindings, setlist),
/// `BridgeServer+Learn` (the shared learn walk-through) and `BridgeServer+Meters` (meters and RTA).
@Observable
public final class BridgeServer {
    public struct Options {
        public var port: UInt16 = FOHProtocol.defaultPort
        public var advertiseBonjour = true
        public var discoverPlugins = true
        public var store = BridgeStore()
        /// Appended to the MIDI port names ("FOH In 1-16 (test)") for test bridges.
        public var portNameSuffix = ""
        public var enableMeters = true
        public var meterSourceFactory: () -> MeterSource = { AudioMetering.makeDefault() }
        /// Clients that send nothing (not even a ping) for this long are dropped.
        public var clientTimeout: TimeInterval = 10
        /// Called for every log line (fohctl prints them).
        public var onLog: ((String) -> Void)?
        /// Update the concert's MainStage assignments automatically when they change (PLAN.md §9c). The app turns
        /// it on; tests and fohctl leave it off.
        public var autoSyncMainStage = false
        /// Tools/concert-format/concert_write.py (bundled with FOH Bridge).
        public var concertWriter: URL?
        /// How long show changes must settle before an automatic update.
        public var mainStageSyncDelay: TimeInterval = 3
        public var isMainStageRunning: () -> Bool = { RunningApps.pid(bundleID: ConcertSync.mainStageBundleID) != nil }
        /// MainStage's parameter tables for its own plugins (`MainStagePluginCatalog.description(named:)`). The app and
        /// fohctl's bridge read them; tests leave it off unless they're testing it.
        public var mainStageCatalog: ((String) -> PluginDescription?)?

        public init() {}
    }

    /// MainStage round-trip times measured from suppressed echoes (spike S1).
    public struct EchoStats: Hashable, Sendable {
        public var count = 0
        public var minMS = Double.infinity
        public var maxMS = 0.0
        public var totalMS = 0.0
        public var averageMS: Double { count > 0 ? totalMS / Double(count) : 0 }

        mutating func add(_ ms: Double) {
            count += 1
            minMS = Swift.min(minMS, ms)
            maxMS = Swift.max(maxMS, ms)
            totalMS += ms
        }
    }

    // MARK: Observable state (UI)

    public internal(set) var show: ShowConfig
    public internal(set) var status: BridgeStatus
    public internal(set) var logLines: [String] = []
    public internal(set) var listeningPort: UInt16?
    public internal(set) var bonjourName: String
    public internal(set) var isDiscovering = false
    public internal(set) var isRunning = false
    public internal(set) var valueCount = 0
    public internal(set) var echoStats = EchoStats()
    /// The shared MainStage learn walk-through (PLAN.md §7).
    public internal(set) var learn: LearnState
    /// The last concert scanned (Setup › Channels preview, menu summary).
    public internal(set) var lastConcert: ConcertInfo?
    /// Audio input devices for the menu's picker (refresh with `refreshInputDevices()`).
    public internal(set) var inputDevices: [AudioInputDevice] = []
    /// Persisted input device for the meters (nil = system default).
    public internal(set) var inputDeviceUID: String?
    /// Snapshots, newest first (menu, `/foh/backups`).
    public internal(set) var backups: [BackupInfo] = []
    /// How many cached values MainStage itself has reported ("Send Value to" feedback or echoes).
    public internal(set) var confirmedCount = 0
    /// Problems found at launch (an unreadable state file and what it was restored from). Shown in the menu.
    public internal(set) var startupWarnings: [String] = []
    /// The MainStage assignment sync (menu, `/foh/status`).
    public internal(set) var mainStageSync = MainStageSyncState()

    // MARK: Internals

    @ObservationIgnored let options: Options
    @ObservationIgnored let engine: MIDIEngine
    @ObservationIgnored let netQueue = DispatchQueue(label: "foh.bridge.net")
    @ObservationIgnored var listener: NWListener?
    @ObservationIgnored var triedFallbackPort = false
    /// Consecutive listener failures, for the retry backoff; reset once it's listening again.
    @ObservationIgnored var listenerFailures = 0
    /// Bumped per discovery run; a run the watchdog gave up on can't apply its late results.
    @ObservationIgnored var discoveryGeneration = 0
    /// When unsaved value changes began, so a steady stream of changes still saves every few seconds.
    @ObservationIgnored var valuesDirtySince: Date?
    /// Echo lines logged in the current second (MainStage echoes every move; the log keeps a sample).
    @ObservationIgnored var echoLogWindow: (second: Int, count: Int) = (0, 0)
    @ObservationIgnored var connections: [UUID: BridgeConnection] = [:]
    @ObservationIgnored var values: [String: Int] = [:]
    @ObservationIgnored var lastSent: [MIDIAddress: (wire: Int, time: TimeInterval)] = [:]
    /// Addresses mid learn-sweep (and 300 ms after): MainStage feedback for them is ignored.
    @ObservationIgnored var sweepingUntil: [MIDIAddress: TimeInterval] = [:]
    @ObservationIgnored var feedbackSeen: Set<FOHPort> = []
    @ObservationIgnored var loggedUnbound: Set<String> = []
    @ObservationIgnored var discoveredNames: [String] = []
    @ObservationIgnored var saveValuesWork: DispatchWorkItem?
    @ObservationIgnored var statusTimer: Timer?
    /// Discovery results per strip key: plugin chain position → description (every identified plugin).
    @ObservationIgnored var discovered: [String: [Int: PluginDescription]] = [:]
    /// Manual bindings from Setup › Processing: stripKey → roleID → override.
    @ObservationIgnored var overrides: [String: [String: BindingOverride]] = [:]
    /// Strips waiting for discovery while another run is in progress.
    @ObservationIgnored var pendingDiscovery: Set<String> = []
    @ObservationIgnored var pendingDiscoveryForce = false
    /// `/foh/plugin/get` requests waiting on discovery.
    @ObservationIgnored var pendingPluginRequests: [(conn: UUID, strip: String, position: Int)] = []
    // Meters
    @ObservationIgnored var meterSource: MeterSource?
    @ObservationIgnored var deviceWatcher: AudioDeviceWatcher?
    @ObservationIgnored var meterTimer: Timer?
    @ObservationIgnored var latestFrame: MeterFrame?
    @ObservationIgnored var frameDirty = false
    @ObservationIgnored var rtaOrder: [UUID] = []
    @ObservationIgnored var rtaActiveStrip: String?
    // Backups
    @ObservationIgnored var backupIndex: [BridgeStore.BackupIndexEntry] = []
    // Confirmed values: paths MainStage has reported, and client-set paths waiting for MainStage's echo.
    @ObservationIgnored var confirmedPaths: Set<String> = []
    @ObservationIgnored var pendingConfirm: [String: TimeInterval] = [:]
    @ObservationIgnored var lastLoggedConfirmed = 0
    // MainStage sync
    @ObservationIgnored var concertSyncRecord: ConcertSyncRecord?
    @ObservationIgnored var mainStageSyncWork: DispatchWorkItem?
    @ObservationIgnored var mainStageSyncWaiters: [(BridgeAck) -> Void] = []
    @ObservationIgnored var mainStageObserver: NSObjectProtocol?
    /// MainStage saved the concert since our last update: run the writer once even if the show looks unchanged.
    @ObservationIgnored var mainStageVerifyNext = false
    @ObservationIgnored var discoveryFinishedOnce = false

    static let echoWindow: TimeInterval = 0.3
    /// A client-set value with no MainStage echo after this long is no longer "confirmed".
    static let confirmTimeout: TimeInterval = 1

    public init(options: Options = Options()) {
        self.options = options
        self.engine = MIDIEngine(nameSuffix: options.portNameSuffix)
        let name = "FOH Bridge (\(Self.computerName()))" + options.portNameSuffix
        self.bonjourName = name
        let state = Self.loadState(options.store)
        var show = state.show
        if show.patches.isEmpty { show.patches = ShowConfig.church.patches; show.currentPatch = ShowConfig.church.currentPatch }
        self.show = show
        self.status = BridgeStatus(bridgeName: name, ports: FOHPort.allCases.map { .init(name: $0.rawValue + options.portNameSuffix) },
                                   clients: [], discoveredPlugins: [])
        self.values = state.values
        self.valueCount = values.count
        self.learn = state.learn
        self.overrides = state.overrides
        self.startupWarnings = state.warnings
        self.inputDeviceUID = MIDIEngine.sharedDefaults.string(forKey: Self.inputDeviceKey + options.portNameSuffix)
        self.backupIndex = options.store.loadBackupIndex()
        self.backups = backupIndex.map(\.info)
        ensureBaselineBindings()
    }

    static let inputDeviceKey = "foh.audio.inputDeviceUID"

    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }

    /// The MIDI endpoint name MainStage sees for a port (includes any test suffix).
    public func portName(_ port: FOHPort) -> String { engine.name(of: port) }

    // MARK: Lifecycle

    public func start() throws {
        guard !isRunning else { return }
        engine.onReceive = { [weak self] msg in
            DispatchQueue.main.async { self?.handleMIDI(msg) }
        }
        try engine.start()
        log("MIDI ports up: " + FOHPort.allCases.map { "\(portName($0)) (uid \(engine.uniqueID(of: $0)))" }.joined(separator: ", "))
        try startListener(port: options.port)
        isRunning = true
        // .common mode: keep ticking while a menu, alert or open panel runs a modal loop.
        let status = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(status, forMode: .common)
        statusTimer = status
        log("Show \"\(show.name)\": \(show.strips.count) strips, \(values.count) cached values, \(show.patches.count) patches")
        startupWarnings.forEach { log("⚠︎ \($0)") }
        if options.discoverPlugins { runDiscovery() }
        startMeters()
        startMainStageSync()
    }

    public func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        stopMainStageSync()
        stopMeters()
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
        engine.stop()
        flushValues()
        isRunning = false
        refreshStatus()
    }

    // MARK: Public actions

    public func appendLog(_ line: String) { log(line) }

    /// Re-send every cached value to MainStage (after a MainStage relaunch). Guarded in the UI.
    @discardableResult
    public func pushAllToMainStage() -> BridgeAck {
        var sent = 0
        let now = ProcessInfo.processInfo.systemUptime
        for (path, value) in values.sorted(by: { $0.key < $1.key }) {
            if let (strip, role) = FOHProtocol.parseValuePath(path), let binding = show.binding(strip)[role] {
                // Never the transport: re-sending a cached Record could stop (or start) a recording.
                guard role.group != .transport else { continue }
                sendWire(AddressMap.address(strip, role), binding.wireValue(value))
            } else if let control = show.pluginControl(path: path) {
                sendWire(control.address, value)
            } else {
                continue
            }
            pendingConfirm[path] = now
            sent += 1
        }
        log("Pushed \(sent) values to MainStage")
        return .ok("Pushed \(sent) values to MainStage")
    }

    /// Re-run plugin discovery (all strips, or one), ignoring the on-disk cache when `force`.
    public func rediscover(stripKey: String? = nil, force: Bool = true) {
        runDiscovery(strips: stripKey.map { [$0] }, force: force)
    }

    /// Current role value for a path, if cached.
    public func value(at path: String) -> Int? { values[path] }

    /// A discovered plugin on a strip, if discovery has read it.
    public func discoveredPlugin(_ strip: StripRef, position: Int) -> PluginDescription? { discovered[strip.key]?[position] }

    // MARK: Network

    func startListener(port: UInt16) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params, on: nwPort)
        if options.advertiseBonjour {
            listener.service = NWListener.Service(name: bonjourName, type: FOHProtocol.bonjourType)
        }
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] nw in
            DispatchQueue.main.async { self?.accept(nw) }
        }
        listener.start(queue: netQueue)
        self.listener = listener
    }

    func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            listenerFailures = 0
            listeningPort = listener?.port?.rawValue
            log("Listening for OSC on TCP :\(listeningPort ?? 0)\(options.advertiseBonjour ? " · Bonjour \"\(bonjourName)\" \(FOHProtocol.bonjourType)" : "")")
        case .failed(let error):
            log("Listener failed: \(error)")
            listener?.cancel()
            listener = nil
            listeningPort = nil
            // Port taken at startup (e.g. a second bridge): fall back to any free port once; Bonjour still finds it.
            if case .posix(let code) = error, code == .EADDRINUSE, !triedFallbackPort, listenerFailures == 0 {
                triedFallbackPort = true
                log("Port \(options.port) is in use; listening on any free port")
                try? startListener(port: 0)
                return
            }
            // Anything else (e.g. mDNSResponder restarting after sleep): keep retrying the same port with backoff,
            // so the iPads find the bridge again without a relaunch.
            listenerFailures += 1
            let delay = min(pow(2, Double(listenerFailures - 1)), 15)
            log(String(format: "Retrying the listener in %.0f s", delay))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning, self.listener == nil else { return }
                do { try self.startListener(port: self.triedFallbackPort ? 0 : self.options.port) } catch {
                    self.listenerChanged(.failed(.posix(.EADDRNOTAVAIL)))
                }
            }
        default:
            break
        }
    }

    func accept(_ nw: NWConnection) {
        let conn = BridgeConnection(nw, server: self, queue: netQueue)
        connections[conn.id] = conn
        conn.start()
        log("Client connected: \(conn.label)")
        refreshStatus()
    }

    func connection(_ conn: BridgeConnection, changedTo state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            removeConnection(conn, reason: "disconnected")
        default:
            break
        }
    }

    func removeConnection(_ conn: BridgeConnection, reason: String) {
        guard connections.removeValue(forKey: conn.id) != nil else { return }
        conn.cancel()
        log("Client \(reason): \(conn.label)")
        pendingPluginRequests.removeAll { $0.conn == conn.id }
        if conn.rtaStrip != nil {
            conn.rtaStrip = nil
            updateRTASubscriptions()
        }
        refreshStatus(broadcast: true)
    }

    func broadcast(_ packet: OSCPacket, except: UUID? = nil) {
        for (id, c) in connections where id != except { c.send(packet) }
    }

    func broadcastConfig() {
        guard !connections.isEmpty, let m = try? FOHProtocol.jsonMessage(FOHProtocol.Path.config, show) else { return }
        broadcast(.message(m))
    }

    /// One value message per cached value, flagged confirmed/assumed, in bundles of ≤200.
    func valueBundles() -> [OSCPacket] {
        let plugin = Set(show.activePluginControls.map(\.path))
        let messages = values.sorted(by: { $0.key < $1.key }).compactMap { path, value -> OSCPacket? in
            guard FOHProtocol.parseValuePath(path) != nil || plugin.contains(path) else { return nil }
            return .message(FOHProtocol.valueMessage(path: path, value, confirmed: confirmedPaths.contains(path)))
        }
        return stride(from: 0, to: messages.count, by: 200).map { start in
            .bundle(timeTag: OSCPacket.immediate, elements: Array(messages[start..<min(start + 200, messages.count)]))
        }
    }

    /// Every value to every client (after a restore).
    func broadcastAllValues() {
        guard !connections.isEmpty else { return }
        for packet in valueBundles() { broadcast(packet) }
    }

    /// Tell clients a path's confirmed flag changed (its value is unchanged).
    func broadcastConfirmation(_ path: String) {
        guard let value = values[path], FOHProtocol.parseValuePath(path) != nil || show.pluginControl(path: path) != nil else { return }
        broadcast(.message(FOHProtocol.valueMessage(path: path, value, confirmed: confirmedPaths.contains(path))))
    }

    /// MainStage reported (or echoed) this path. Returns true if it wasn't confirmed before.
    @discardableResult
    func confirm(_ path: String) -> Bool {
        pendingConfirm[path] = nil
        return confirmedPaths.insert(path).inserted
    }

    /// Drop a path's confirmation (a sweep moved it, or MainStage didn't echo a client's change).
    func unconfirm(_ path: String, broadcastChange: Bool = true) {
        pendingConfirm[path] = nil
        if confirmedPaths.remove(path) != nil, broadcastChange { broadcastConfirmation(path) }
    }

    func reply(_ conn: BridgeConnection, _ action: String, _ ack: BridgeAck) {
        conn.send(FOHProtocol.ackMessage(action, ok: ack.ok, ack.message))
        if !ack.ok { log("\(action): \(ack.message)") }
    }

    // MARK: OSC routing

    func handle(_ messages: [OSCMessage], from conn: BridgeConnection) {
        for m in messages { handle(m, from: conn) }
    }

    private func handle(_ m: OSCMessage, from conn: BridgeConnection) {
        let args = m.arguments
        func string(_ i: Int) -> String? { i < args.count ? args[i].stringValue : nil }
        func int(_ i: Int) -> Int? { i < args.count ? args[i].intValue : nil }

        switch m.address {
        case FOHProtocol.Path.hello:
            conn.name = string(0) ?? conn.label
            conn.send(OSCMessage(FOHProtocol.Path.welcome, [.string(bonjourName), .int(FOHProtocol.version)]))
            log("Hello from \(conn.name!)")
            refreshStatus(broadcast: true)
        case FOHProtocol.Path.sync:
            sendSync(to: conn)
        case FOHProtocol.Path.ping:
            conn.send(OSCMessage(FOHProtocol.Path.pong, args))
        case FOHProtocol.Path.learnFire:
            guard let path = string(0) else { return log("learn/fire needs a path") }
            learnSweep(path)
        case FOHProtocol.Path.learnSend:
            guard let path = string(0), let v = int(1) else { return log("learn/send needs ,s path ,i value") }
            if let control = show.pluginControl(path: path) {
                sendWire(control.address, v)
            } else if let (strip, role) = FOHProtocol.parseValuePath(path) {
                sendWire(AddressMap.address(strip, role), v)
            } else {
                return log("learn/send: \(path) isn't a role or an active plugin control")
            }
            log("learn/send \(path) wire \(v)")
        case FOHProtocol.Path.discover:
            // Cached plugins aren't reloaded (loading a third-party plugin inside the bridge is the risky part);
            // a second argument of 1 forces it, as the menu's Rescan does.
            rediscover(stripKey: string(0).flatMap { $0.isEmpty ? nil : $0 }, force: int(1) == 1)

        // Phase 2 — configuration, concert, bindings
        case FOHProtocol.Path.configSet:
            do { reply(conn, m.address, applyConfig(try FOHProtocol.decodeJSON(ShowConfig.self, from: m), from: conn.label)) }
            catch { reply(conn, m.address, .fail("Bad config payload: \(error)")) }
        case FOHProtocol.Path.concertScan:
            scanConcertInBackground(path: string(0)) { [weak self, weak conn] result in
                switch result {
                case .success(let info):
                    if let reply = try? FOHProtocol.jsonMessage(FOHProtocol.Path.concert, info) { conn?.send(reply) }
                case .failure(let error):
                    self?.log("Concert scan failed: \(error)")
                }
            }
        case FOHProtocol.Path.concertMerge:
            let address = m.address
            mergeConcertInBackground(path: string(0)) { [weak self, weak conn] ack in
                guard let self, let conn else { return }
                self.reply(conn, address, ack)
            }
        case FOHProtocol.Path.pluginControlAdd, FOHProtocol.Path.pluginControlRemove:
            guard let strip = string(0), let position = int(1), let id = string(2) else {
                return reply(conn, m.address, .fail("\(m.address) needs ,s strip ,i position ,s parameterID"))
            }
            reply(conn, m.address, changePluginControl(strip: strip, position: position, parameterID: id,
                                                       add: m.address == FOHProtocol.Path.pluginControlAdd))
        case FOHProtocol.Path.pluginLearnStart:
            guard let strip = string(0), let position = int(1), let name = string(2) else {
                return reply(conn, m.address, .fail("learn/start needs ,s strip ,i position ,s name"))
            }
            reply(conn, m.address, startPluginLearn(strip: strip, position: position, name: name))
        case FOHProtocol.Path.pluginLearnSend:
            reply(conn, m.address, sendPluginLearn(string(0) ?? ""))
        case FOHProtocol.Path.pluginLearnCancel:
            reply(conn, m.address, cancelPluginLearn(string(0) ?? ""))
        case FOHProtocol.Path.pluginLearnForget:
            guard let plugin = string(0), let index = int(1) else { return reply(conn, m.address, .fail("learn/forget needs ,s plugin ,i index")) }
            reply(conn, m.address, forgetLearnedParameter(plugin, index: index))
        case FOHProtocol.Path.pluginLearnCheck:
            let address = m.address
            checkPluginLearns { [weak self, weak conn] ack in
                guard let self, let conn else { return }
                self.reply(conn, address, ack)
            }
        case FOHProtocol.Path.mainStageUpdate:
            let address = m.address
            updateMainStage(trigger: "requested by \(conn.label)") { [weak self, weak conn] ack in
                guard let self, let conn else { return }
                self.reply(conn, address, ack)
            }
        case FOHProtocol.Path.pluginGet:
            guard let strip = string(0), let position = int(1) else { return log("plugin/get needs ,s strip ,i position") }
            sendPlugin(strip: strip, position: position, to: conn)
        case FOHProtocol.Path.bindSet:
            guard let strip = string(0), let role = string(1), let position = int(2) else {
                return reply(conn, m.address, .fail("bind/set needs ,s strip ,s role ,i position ,s parameterID"))
            }
            reply(conn, m.address, setBinding(strip: strip, roleID: role, position: position, parameterID: string(3) ?? ""))
        case FOHProtocol.Path.bindApply:
            guard let from = string(0), let to = string(1) else { return reply(conn, m.address, .fail("bind/apply needs ,s from ,s to")) }
            reply(conn, m.address, applyBindings(from: from, to: to))
        case FOHProtocol.Path.bindReset:
            guard let strip = string(0) else { return reply(conn, m.address, .fail("bind/reset needs ,s strip")) }
            reply(conn, m.address, resetBindings(strip: strip))

        // Phase 2 — setlist, state, learn
        case FOHProtocol.Path.patchSelect:
            guard let index = int(0) else { return reply(conn, m.address, .fail("patch/select needs ,i index")) }
            reply(conn, m.address, selectPatch(index))
        case FOHProtocol.Path.pull:
            reply(conn, m.address, pullFromMainStage())
        case FOHProtocol.Path.pushAll:
            reply(conn, m.address, pushAllToMainStage())
        case FOHProtocol.Path.learnState:
            do { updateLearn(from: try FOHProtocol.decodeJSON(LearnState.self, from: m)) } catch { log("learn/state: bad payload (\(error))") }
        case FOHProtocol.Path.learnNext:
            learnNext()
        case FOHProtocol.Path.calibrationSet:
            do { reply(conn, m.address, setFaderCalibration(try FOHProtocol.decodeJSON([CalibrationPoint].self, from: m))) }
            catch { reply(conn, m.address, .fail("Bad calibration payload: \(error)")) }

        // Finishing — backups and custom templates
        case FOHProtocol.Path.backupList:
            sendBackups(to: conn)
        case FOHProtocol.Path.backupCreate:
            reply(conn, m.address, createBackup(reason: string(0) ?? "Manual snapshot"))
        case FOHProtocol.Path.backupRestore:
            guard let id = string(0) else { return reply(conn, m.address, .fail("backup/restore needs ,s backupID")) }
            reply(conn, m.address, restoreBackup(id: id))
        case FOHProtocol.Path.backupExport:
            let bundle = exportBundle()
            do {
                let enc = JSONEncoder()
                enc.outputFormatting = [.sortedKeys]
                conn.send(OSCMessage(FOHProtocol.Path.backupData, [.string(bundle.suggestedFilename), .blob(try enc.encode(bundle))]))
                log("Exported \(bundle.suggestedFilename) to \(conn.label)")
            } catch { log("backup/export: \(error)") }
        case FOHProtocol.Path.backupImport:
            do { reply(conn, m.address, importBackup(try FOHProtocol.decodeJSON(BackupBundle.self, from: m))) }
            catch { reply(conn, m.address, .fail("That file isn't a FOH show backup (\(error.localizedDescription))")) }
        case FOHProtocol.Path.templateSave:
            guard let strip = string(0), let name = string(1), let useText = string(2), let use = CustomTemplate.Use(rawValue: useText),
                  let position = int(3) else {
                return reply(conn, m.address, .fail("template/save needs ,s strip ,s name ,s processing|insert ,i position"))
            }
            reply(conn, m.address, saveTemplate(strip: strip, name: name, use: use, position: position))
        case FOHProtocol.Path.templateDelete:
            guard let id = string(0) else { return reply(conn, m.address, .fail("template/delete needs ,s templateID")) }
            reply(conn, m.address, deleteTemplate(id: id))

        // Phase 3 — RTA
        case FOHProtocol.Path.rtaSubscribe:
            let key = string(0) ?? ""
            conn.rtaStrip = key.isEmpty ? nil : key
            rtaOrder.removeAll { $0 == conn.id }
            if conn.rtaStrip != nil { rtaOrder.append(conn.id) }
            updateRTASubscriptions()

        default:
            if let (strip, role) = FOHProtocol.parseValuePath(m.address), let v = int(0) {
                setFromClient(strip, role, v, path: m.address, from: conn)
            } else if let control = show.pluginControl(path: m.address), let v = int(0) {
                setPluginFromClient(control, v, from: conn)
            } else {
                log("Unhandled OSC \(m.address)")
            }
        }
    }

    private func setFromClient(_ strip: StripRef, _ role: Role, _ raw: Int, path: String, from conn: BridgeConnection) {
        guard let binding = show.binding(strip)[role] else {
            if loggedUnbound.insert(path).inserted { log("Ignoring unbound role \(path)") }
            return
        }
        let value = FOHProtocol.clampMIDI(raw)
        values[path] = value
        valueCount = values.count
        scheduleSaveValues()
        sendWire(AddressMap.address(strip, role), binding.wireValue(value))
        // Confirmed again only if MainStage echoes it (checked in `tick`).
        pendingConfirm[path] = ProcessInfo.processInfo.systemUptime
        broadcast(.message(FOHProtocol.valueMessage(strip, role, value, confirmed: confirmedPaths.contains(path))), except: conn.id)
    }

    func setPluginFromClient(_ control: PluginControl, _ raw: Int, from conn: BridgeConnection) {
        let value = FOHProtocol.clampMIDI(raw)
        let path = control.path
        values[path] = value
        valueCount = values.count
        scheduleSaveValues()
        sendWire(control.address, value)
        pendingConfirm[path] = ProcessInfo.processInfo.systemUptime
        broadcast(.message(FOHProtocol.valueMessage(path: path, value, confirmed: confirmedPaths.contains(path))), except: conn.id)
    }

    private func sendSync(to conn: BridgeConnection) {
        do {
            conn.send(try FOHProtocol.jsonMessage(FOHProtocol.Path.config, show))
            conn.send(try FOHProtocol.jsonMessage(FOHProtocol.Path.learnState, learn))
        } catch {
            log("Couldn't encode show: \(error)")
        }
        for packet in valueBundles() { conn.send(packet) }
        conn.send(OSCMessage(FOHProtocol.Path.syncDone, [.int(Int32(values.count))]))
        refreshStatus()
        if let s = try? FOHProtocol.jsonMessage(FOHProtocol.Path.status, status) { conn.send(s) }
        log("Synced \(conn.label): config + learn + \(values.count) values (confirmed \(confirmedPaths.count)/\(values.count))")
    }

    // MARK: MIDI out

    func sendWire(_ address: MIDIAddress, _ wire: Int) {
        let v = FOHProtocol.clampMIDI(wire)
        lastSent[address] = (v, ProcessInfo.processInfo.systemUptime)
        engine.sendCC(address, value: v)
    }

    /// Learn sweep: 0→127→0 so MainStage's Learn sees the full range, then restore the cached value. A plugin
    /// control's path works too (mapping one by hand, e.g. the first control on a mono output strip).
    func learnSweep(_ path: String) {
        if let control = show.pluginControl(path: path) {
            unconfirm(path)
            return sweep(control.address, restore: values[path], label: "\(path) (\(control.name))")
        }
        guard let (strip, role) = FOHProtocol.parseValuePath(path) else { return log("learn/fire: bad path \(path)") }
        let address = AddressMap.address(strip, role)
        var steps = Array(stride(from: 0, through: 124, by: 4)) + [127]
        steps += Array(stride(from: 123, through: 3, by: -4)) + [0]
        let interval = 0.015
        let total = Double(steps.count) * interval
        sweepingUntil[address] = ProcessInfo.processInfo.systemUptime + total + 0.25 + Self.echoWindow
        unconfirm(path)
        log("Learn sweep \(path) → \(portName(address.port)) · ch \(address.channel) · CC \(address.cc)")
        for (i, v) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * interval) { [weak self] in self?.sendWire(address, v) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.25) { [weak self] in
            guard let self else { return }
            // The sweep's own echoes have arrived by now; let the restore's echo through so it can confirm the value.
            self.sweepingUntil[address] = nil
            if let cached = self.values[path], let binding = self.show.binding(strip)[role] {
                self.sendWire(address, binding.wireValue(cached))
                self.log("Learn sweep done; restored \(path) = \(cached)")
            } else {
                self.log("Learn sweep done; no cached value to restore for \(path)")
            }
        }
    }

    // MARK: MIDI in (MainStage "Send Value to")

    private func handleMIDI(_ msg: MIDIEngine.Message) {
        if msg.port.isPluginPort { return handlePluginMIDI(msg) }
        guard msg.isControlChange, let (strip, role) = AddressMap.resolve(MIDIAddress(port: msg.port, channel: msg.channel, cc: msg.data1)) else {
            log(String(format: "unmapped feedback %@ status=%02X d1=%d d2=%d", portName(msg.port), msg.status, msg.data1, msg.data2))
            return
        }
        if feedbackSeen.insert(msg.port).inserted {
            log("Feedback seen on \(portName(msg.port)) — \"Send Value to\" works")
            refreshStatus(broadcast: true)
        }
        let address = AddressMap.address(strip, role)
        let now = ProcessInfo.processInfo.systemUptime
        if let until = sweepingUntil[address] {
            if now < until { return }
            sweepingUntil[address] = nil
        }
        let wire = Int(msg.data2)
        let path = FOHProtocol.valuePath(strip, role)
        if let sent = lastSent[address], sent.wire == wire, now - sent.time < Self.echoWindow {
            let ms = (now - sent.time) * 1000
            echoStats.add(ms)
            let second = Int(now)
            if echoLogWindow.second != second { echoLogWindow = (second, 0) }
            echoLogWindow.count += 1
            if echoLogWindow.count <= 3 {   // a sample per second; a fader move echoes dozens of times
                log(String(format: "echo ch%d CC%d rtt %.1f ms (min %.1f / avg %.1f / max %.1f, n=%d)", msg.channel, msg.data1, ms,
                           echoStats.minMS, echoStats.averageMS, echoStats.maxMS, echoStats.count))
            }
            // MainStage applied the value we sent.
            if confirm(path) { broadcastConfirmation(path) }
            return
        }
        let binding = show.binding(strip)[role]
        let value = binding?.invert == true ? 127 - wire : wire
        let newlyConfirmed = confirm(path)
        guard values[path] != value || newlyConfirmed else { return }
        values[path] = value
        valueCount = values.count
        scheduleSaveValues()
        broadcast(.message(FOHProtocol.valueMessage(strip, role, value, confirmed: true)))
    }

    /// "Send Value to" feedback for a plugin control: the plugin ports carry values straight (no invert).
    func handlePluginMIDI(_ msg: MIDIEngine.Message) {
        let address = MIDIAddress(port: msg.port, channel: msg.channel, cc: msg.data1)
        guard msg.isControlChange, let control = show.pluginControl(at: address) else {
            if loggedUnbound.insert("\(address)").inserted { log("Ignoring feedback on \(address): no active plugin control there") }
            return
        }
        if feedbackSeen.insert(msg.port).inserted {
            log("Feedback seen on \(portName(msg.port)) — \"Send Value to\" works")
            refreshStatus(broadcast: true)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let wire = Int(msg.data2)
        let path = control.path
        if let sent = lastSent[address], sent.wire == wire, now - sent.time < Self.echoWindow {
            echoStats.add((now - sent.time) * 1000)
            if confirm(path) { broadcastConfirmation(path) }
            return
        }
        let newlyConfirmed = confirm(path)
        guard values[path] != wire || newlyConfirmed else { return }
        values[path] = wire
        valueCount = values.count
        scheduleSaveValues()
        broadcast(.message(FOHProtocol.valueMessage(path: path, wire, confirmed: true)))
    }

    // MARK: Discovery & bindings

    /// Every strip gets at least its channel-strip roles (fader, mute, pan, sends) before discovery finishes.
    private func ensureBaselineBindings() {
        for strip in show.strips where show.bindings[strip.ref.key] == nil {
            rebuildBinding(strip)
        }
        for strip in show.strips { seedDefaults(strip.ref, show.binding(strip.ref), discovered: [:]) }
    }

    /// Fill values we have never seen with neutral defaults (cache only — nothing is sent to MainStage),
    /// so a fresh iPad doesn't show every gain at −15 dB and every fader at −∞.
    func seedDefaults(_ strip: StripRef, _ binding: StripBinding, discovered: [Int: PluginDescription]) {
        var seeded = 0
        for (role, value) in binding.defaultRoleValues(discovered: discovered) {
            let path = FOHProtocol.valuePath(strip, role)
            if values[path] == nil { values[path] = value; seeded += 1 }
        }
        if seeded > 0 {
            valueCount = values.count
            scheduleSaveValues()
        }
    }

    /// Discover every identified plugin on the given strips (all strips when nil). Requests made while a run is
    /// in progress are queued and run afterwards.
    func runDiscovery(strips only: Set<String>? = nil, force: Bool = false) {
        let wanted = only ?? Set(show.strips.map(\.ref.key))
        guard !wanted.isEmpty else { return }
        guard !isDiscovering else {
            pendingDiscovery.formUnion(wanted)
            pendingDiscoveryForce = pendingDiscoveryForce || force
            return
        }
        isDiscovering = true
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let show = self.show
        let store = options.store
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.discoveryWatchdog) { [weak self] in
            self?.discoveryStuck(generation)
        }
        let thread = Thread { [weak self] in
            var results: [String: [Int: PluginDescription]] = [:]
            var byComponent: [AUComponentID: PluginDescription] = [:]
            var lines: [String] = []
            for strip in show.strips where wanted.contains(strip.ref.key) {
                results[strip.ref.key] = [:]
                for plugin in strip.plugins {
                    guard let component = plugin.component else { continue }
                    if let known = byComponent[component] {
                        results[strip.ref.key]![plugin.position] = known
                        continue
                    }
                    if !force, let cached = store.loadPlugin(component), cached.isCurrentCatalog {
                        byComponent[component] = cached
                        results[strip.ref.key]![plugin.position] = cached
                        lines.append("Plugin \(plugin.name): \(cached.parameters.count) params (cached)")
                        continue
                    }
                    let started = Date()
                    do {
                        let described = try PluginDiscovery.describe(component, name: plugin.name)
                        try? store.savePlugin(described)
                        byComponent[component] = described
                        results[strip.ref.key]![plugin.position] = described
                        lines.append(String(format: "Discovered %@: %d params in %.2fs", plugin.name, described.parameters.count, Date().timeIntervalSince(started)))
                    } catch {
                        lines.append("Discovery failed for \(plugin.name): \(error)")
                    }
                }
            }
            DispatchQueue.main.async { self?.finishDiscovery(results, lines: lines, generation: generation) }
        }
        thread.name = "FOH plugin discovery"
        thread.start()
    }

    /// Longest a discovery run may take before the bridge stops waiting for it.
    static let discoveryWatchdog: TimeInterval = 120

    /// A plugin is hanging while loading or formatting values. Stop waiting: Setup's plugin requests get what's
    /// cached, Rescan works again, and the late results (if they ever come) are ignored. Queued runs are dropped,
    /// since they would load the same stuck plugin again.
    private func discoveryStuck(_ generation: Int) {
        guard isDiscovering, generation == discoveryGeneration else { return }
        log("⚠︎ Plugin discovery is still running after \(Int(Self.discoveryWatchdog)) s; a plugin seems stuck loading. Gave up waiting; restart FOH Bridge to try again.")
        discoveryGeneration += 1
        isDiscovering = false
        discoveryFinishedOnce = true
        pendingDiscovery = []
        pendingDiscoveryForce = false
        answerPendingPluginRequests()
        refreshStatus(broadcast: true)
    }

    private func finishDiscovery(_ results: [String: [Int: PluginDescription]], lines: [String], generation: Int) {
        guard generation == discoveryGeneration else {
            log("Ignoring plugin discovery that finished after the watchdog gave up")
            return
        }
        lines.forEach { log($0) }
        for (key, found) in results { discovered[key] = found }
        for strip in show.strips where results[strip.ref.key] != nil {
            rebuildBinding(strip)
            let binding = show.binding(strip.ref)
            if !(results[strip.ref.key] ?? [:]).isEmpty {
                log("Bound \(strip.name): \(binding.roles.count) roles, \(binding.notInPlugin.count) not in plugin")
            }
            let controls = show.activePluginControls.filter { $0.strip == strip.ref }
            if !controls.isEmpty {
                let byPlugin = Dictionary(grouping: controls, by: \.position).sorted { $0.key < $1.key }.map { position, list in
                    "\(strip.plugins.first { $0.position == position }?.name ?? "plugin \(position)") \(list.count)"
                }
                log("Plugin controls on \(strip.name): \(byPlugin.joined(separator: ", "))")
            }
        }
        var names = Set(discoveredNames)
        for strip in results.values { for d in strip.values { names.insert(d.name) } }
        discoveredNames = names.sorted()
        isDiscovering = false
        discoveryFinishedOnce = true
        saveShow()
        broadcastConfig()
        answerPendingPluginRequests()
        refreshStatus(broadcast: true)
        if !pendingDiscovery.isEmpty {
            let next = pendingDiscovery, force = pendingDiscoveryForce
            pendingDiscovery = []
            pendingDiscoveryForce = false
            runDiscovery(strips: next, force: force)
        }
    }

    // MARK: Status, log, persistence

    /// Once a second: counters, meter status, silent-client cleanup, unechoed values.
    private func tick() {
        refreshCounts()
        let now = Date()
        for conn in connections.values where now.timeIntervalSince(conn.lastActivity) > options.clientTimeout {
            removeConnection(conn, reason: "timed out (silent \(Int(options.clientTimeout)) s)")
        }
        expirePendingConfirmations()
        refreshMeterStatus()
    }

    /// Client-set values MainStage never echoed are assumptions again; log the confirmed count when it changes.
    func expirePendingConfirmations(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for (path, sentAt) in pendingConfirm where now - sentAt > Self.confirmTimeout {
            unconfirm(path)
        }
        confirmedPaths.formIntersection(values.keys)
        if confirmedCount != confirmedPaths.count { confirmedCount = confirmedPaths.count }
        if confirmedPaths.count != lastLoggedConfirmed {
            lastLoggedConfirmed = confirmedPaths.count
            log("Values confirmed by MainStage: \(confirmedPaths.count)/\(values.count)")
        }
    }

    func refreshCounts() {
        let ports = FOHPort.allCases.map { p -> BridgeStatus.PortStatus in
            let c = engine.counts(p)
            return .init(name: portName(p), sent: c.sent, received: c.received, feedbackSeen: feedbackSeen.contains(p))
        }
        if ports != status.ports { status.ports = ports }
        let rtt = echoStats.count > 0 ? (echoStats.averageMS * 10).rounded() / 10 : nil
        if rtt != status.echoRTTms { status.echoRTTms = rtt }
    }

    func refreshStatus(broadcast shouldBroadcast: Bool = false) {
        refreshCounts()
        let clients = connections.values.map(\.label).sorted()
        if clients != status.clients { status.clients = clients }
        if discoveredNames != status.discoveredPlugins { status.discoveredPlugins = discoveredNames }
        if mainStageSync.summary != status.mainStageSync { status.mainStageSync = mainStageSync.summary }
        if shouldBroadcast, !connections.isEmpty, let m = try? FOHProtocol.jsonMessage(FOHProtocol.Path.status, status) {
            broadcast(.message(m))
        }
    }

    func log(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        let entry = "\(stamp)  \(line)"
        logLines.append(entry)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        options.onLog?(entry)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func saveShow() {
        do { try options.store.saveShow(show) } catch { log("Couldn't save show: \(error)") }
        checkMainStageSync()
    }

    /// Save a second after changes stop, but at least every 5 s while they keep coming (MainStage feedback and
    /// iPad moves can arrive continuously), so a crash or power cut loses only seconds of the mix.
    func scheduleSaveValues() {
        let now = Date()
        if let since = valuesDirtySince, now.timeIntervalSince(since) >= 5 { return flushValues() }
        if valuesDirtySince == nil { valuesDirtySince = now }
        saveValuesWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushValues() }
        saveValuesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Write everything that can be dirty: on quit, and whenever the debounce fires.
    public func saveAll() {
        flushValues()
        saveShow()
    }

    func flushValues() {
        saveValuesWork?.cancel()
        saveValuesWork = nil
        valuesDirtySince = nil
        do { try options.store.saveValues(values) } catch { log("Couldn't save values: \(error)") }
    }
}
#endif

#if os(macOS)
/// State is confined to the main thread (see the type's doc comment).
extension BridgeServer: @unchecked Sendable {}
#endif

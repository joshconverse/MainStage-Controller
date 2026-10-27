import Foundation
import Observation
import FOHCore

enum ConnectionState: Equatable {
    case demo
    case searching
    case connecting(String)
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .demo: return "Demo"
        case .searching: return "Searching for Bridge…"
        case .connecting(let n): return "Connecting · \(n)"
        case .connected(let n): return "Bridge · \(n)"
        case .failed(let why): return "Offline · \(why)"
        }
    }

    var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

enum AppTab: String, CaseIterable, Identifiable {
    case mixer = "Mixer", channel = "Channel", routing = "Routing", setup = "Setup"
    var id: String { rawValue }
}

enum ChannelSection: String, CaseIterable, Identifiable {
    case dynamics = "Dynamics", eq = "EQ", inserts = "Inserts", sends = "Sends"
    var id: String { rawValue }
}

enum SetupSection: String, CaseIterable, Identifiable {
    case connection = "Connection", channels = "Channels & I/O", processing = "Processing", learn = "MainStage learn", verify = "Verify"
    case templates = "Plugin templates", backup = "Backup & restore"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .connection: return "wifi"
        case .channels: return "slider.vertical.3"
        case .processing: return "point.3.connected.trianglepath.dotted"
        case .learn: return "dot.radiowaves.left.and.right"
        case .verify: return "checkmark.seal"
        case .templates: return "square.on.square"
        case .backup: return "externaldrive"
        }
    }

    /// Position in the 4-step setup flow (Connection isn't a step).
    var flowStep: Int? {
        switch self {
        case .connection: return nil
        case .channels: return 1
        case .processing: return 2
        case .learn: return 3
        case .verify: return 4
        case .templates, .backup: return nil
        }
    }
}

/// Step 4 results ("in/1|band.2.gain" → passed?), kept on this iPad.
@MainActor
@Observable
final class VerifyResults {
    private(set) var results: [String: Bool] = (UserDefaults.standard.dictionary(forKey: "foh.verify") as? [String: Bool]) ?? [:]

    func result(_ strip: StripRef, _ role: Role) -> Bool? { results[LearnState.Item(strip, role).key] }

    func set(_ strip: StripRef, _ role: Role, passed: Bool?) {
        results[LearnState.Item(strip, role).key] = passed
        UserDefaults.standard.set(results, forKey: "foh.verify")
    }
}

/// A short, non-blocking confirmation at the top of the screen (bridge `/foh/ack`, or local in the demo).
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let ok: Bool
    let message: String
}

/// All app state: the show (strips + bindings) from the bridge, role values, and UI navigation.
@MainActor
@Observable
final class MixerStore {
    var config: ShowConfig
    /// Role values (0–127) keyed by OSC value path.
    var values: [String: Int] = [:]
    var status: BridgeStatus?
    var connection: ConnectionState = .demo
    var bridgeName: String?
    var synced = false
    var isDemo = true

    // Navigation / UI state
    var tab: AppTab = .mixer
    var channelSection: ChannelSection = .eq
    var setupSection: SetupSection = .connection
    var selectedStrip: StripRef = .input(1)
    /// Send index shown on the faders, or nil for the main mix.
    var sendsOnFaders: Int?
    var fineMode = false
    var locked = false
    /// EQ handle selected on the Channel › EQ graph ("hpf", "lpf", "band.N").
    var selectedEQHandle = "band.2"
    /// Plugin tab open on Channel › Inserts (chain position); nil shows the strip's first page.
    var insertPosition: Int?

    // Setup state
    /// Last concert scan from the bridge (or the demo), for the import preview.
    var concertInfo: ConcertInfo?
    var showConcertImport = false
    var scanningConcert = false
    /// Discovered plugin parameter lists, keyed "in/1#3".
    var pluginCache: [String: PluginDescription] = [:]
    var learnState = LearnState()

    /// Value paths MainStage itself has reported ("Send Value to"), from the second argument of value messages.
    var confirmed: Set<String> = []
    /// True once the bridge sends confirmation flags at all (older bridges don't).
    var confirmationsSupported = false

    var toast: Toast?
    /// The bridge's `/foh/config` didn't decode (app and bridge on different versions). Shown as a banner until a
    /// show decodes or the demo is loaded.
    var configError: String?
    /// A show from the bridge has decoded since the demo was left. With one, an unreadable update keeps the last
    /// good show live (never freeze a working desk mid-service); without one, the console pauses, because the
    /// strips on screen would be the demo's.
    var hasBridgeShow = false
    var configErrorPausesConsole: Bool { configError != nil && !hasBridgeShow }

    // Backups
    var backups: [BackupInfo] = []
    /// A bundle written to a temporary file, ready to share/save as `.fohshow`.
    var exportURL: URL?
    @ObservationIgnored private var demoSnapshots: [String: BackupBundle] = [:]

    /// Channels & I/O reorder mode (drag handles + move buttons).
    var channelsReorder = false

    /// Master fader / mute need a long-press to arm (then stay armed for 5 s).
    var guardMaster: Bool = UserDefaults.standard.object(forKey: "foh.guardMaster") as? Bool ?? false {
        didSet { UserDefaults.standard.set(guardMaster, forKey: "foh.guardMaster") }
    }
    var masterArmedUntil: Date?
    /// When this iPad saw MainStage's recording start (for the elapsed time on the REC button).
    var recordingSince: Date?

    /// Learned roles in the offline demo ("in/1|band.2.gain"); live, the bridge's LearnState is the truth.
    var demoLearned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "foh.learned") ?? []) {
        didSet { UserDefaults.standard.set(Array(demoLearned).sorted(), forKey: "foh.learned") }
    }

    @ObservationIgnored weak var client: BridgeClient?
    @ObservationIgnored weak var meters: MeterStore?
    @ObservationIgnored private var touching: [String: Int] = [:]
    /// Last begin/set on a touched path; a touch quiet for `touchTimeout` stops suppressing (see `isSuppressed`).
    @ObservationIgnored private var touchedAt: [String: Date] = [:]
    @ObservationIgnored private var releasedAt: [String: Date] = [:]
    @ObservationIgnored private var rtaStrip: String?
    /// Plugin parameters by ID, per cached description ("in/1#2"), so plugin pages look them up without a scan.
    @ObservationIgnored var pluginParameterIndex: [String: [String: PluginParameterInfo]] = [:]

    init() {
        let demo = DemoShow.make()
        config = demo.config
        values = demo.values
        seedDemoSnapshots()
    }

    // MARK: Strips

    /// Strips in the user's display order (`ShowConfig.stripOrder`); slots — and MIDI addresses — never move.
    var inputs: [Strip] { config.ordered(.input) }
    var fxReturns: [Strip] { config.ordered(.fx) }
    var outputs: [Strip] { config.ordered(.output) }
    var master: Strip? { config.strip(.master) }
    var selected: Strip? { config.strip(selectedStrip) }

    /// Strips you can step through on the Channel screen.
    var channelOrder: [Strip] { inputs + fxReturns + outputs + (master.map { [$0] } ?? []) }

    func stepChannel(_ delta: Int) {
        let order = channelOrder
        guard let i = order.firstIndex(where: { $0.ref == selectedStrip }), !order.isEmpty else { return }
        selectedStrip = order[(i + delta + order.count) % order.count].ref
    }

    func open(_ strip: StripRef, section: ChannelSection = .eq) {
        selectedStrip = strip
        channelSection = section
        tab = .channel
    }

    func openSetup(_ section: SetupSection, strip: StripRef? = nil) {
        if let strip { selectedStrip = strip }
        setupSection = section
        tab = .setup
    }

    // MARK: Values

    func path(_ strip: StripRef, _ role: Role) -> String { FOHProtocol.valuePath(strip, role) }

    /// Unknown values (not yet sent by the bridge) read as 0, except pan which reads as centre.
    func value(_ strip: StripRef, _ role: Role) -> Int { values[path(strip, role)] ?? (role == .pan ? 64 : 0) }

    func isOn(_ strip: StripRef, _ role: Role) -> Bool { value(strip, role) >= 64 }

    var masterUnlocked: Bool { !guardMaster || (masterArmedUntil.map { $0 > Date() } ?? false) }

    func armMaster() { masterArmedUntil = Date().addingTimeInterval(5) }

    func set(_ strip: StripRef, _ role: Role, _ value: Int) {
        guard !locked else { return }
        // The master guard protects the mix; MainStage's Record (a transport role on the Master strip) isn't the mix.
        let guarded = strip == .master && role.group != .transport
        if guarded && !masterUnlocked { return }
        if guarded { masterArmedUntil = Date().addingTimeInterval(5) }   // keep armed while in use
        let v = FOHProtocol.clampMIDI(value)
        let p = path(strip, role)
        send(path: p, v)
    }

    /// Store and send a value for any value path (a role, or a plugin control from `MixerStore+Plugins`).
    func send(path p: String, _ v: Int) {
        if touching[p] != nil { touchedAt[p] = Date() }
        guard values[p] != v else { return }
        values[p] = v
        noteRecording(p)
        client?.sendValue(p, v)
    }

    // MARK: Recording (MainStage's Record button)

    /// Start or stop MainStage's concert recording (the Master strip's Record role, mapped to MainStage's action).
    func setRecording(_ on: Bool) { set(.master, .record, on ? 127 : 0) }

    var isRecording: Bool { isOn(.master, .record) }

    /// Keeps `recordingSince` in step with the Record value, from either direction.
    private func noteRecording(_ p: String) {
        guard p == path(.master, .record) else { return }
        if isRecording { if recordingSince == nil { recordingSince = Date() } } else { recordingSince = nil }
    }

    /// Where a double-tap snaps a control: 0 dB for faders, send levels, EQ gains, trims and makeup gain
    /// (the MIDI value whose display is closest to 0 dB on this binding, so calibration is respected), centre
    /// for pan; nil for anything without a neutral point.
    func zeroValue(_ strip: StripRef, _ role: Role) -> Int? {
        if role == .pan { return 64 }
        let gainLike = role == .fader || role == .trimIn || role == .trimOut || role.id == "comp.makeup"
            || role.id.hasSuffix(".gain") || (role.group == .send && role.id.hasSuffix(".level"))
        guard gainLike, let b = binding(strip, role), let midi = b.midi(closestTo: 0),
              let v = b.numeric(midi)?.value, abs(v) < 1 else { return nil }
        return midi
    }

    func toggle(_ strip: StripRef, _ role: Role) {
        set(strip, role, isOn(strip, role) ? 0 : 127)
    }

    func binding(_ strip: StripRef, _ role: Role) -> RoleBinding? { config.binding(strip)[role] }

    func isBound(_ strip: StripRef, _ role: Role) -> Bool { binding(strip, role) != nil }

    func display(_ strip: StripRef, _ role: Role) -> String {
        binding(strip, role)?.display(value(strip, role)) ?? "\(value(strip, role))"
    }

    /// Connected to a bridge that reports confirmations, and MainStage hasn't confirmed this value yet:
    /// the iPad is showing the bridge's assumption (seeded default or the last value sent).
    func isAssumed(_ strip: StripRef, _ role: Role) -> Bool { isAssumed(path: path(strip, role)) }

    func isAssumed(path p: String) -> Bool {
        !isDemo && confirmationsSupported && !confirmed.contains(p)
    }

    /// (confirmed, total) over the values the bridge has sent.
    var confirmationCounts: (confirmed: Int, total: Int) {
        (values.keys.filter { confirmed.contains($0) }.count, values.count)
    }

    /// Parsed number (Hz, dB, ratio, s…) for the current value, or nil ("Out", "Off").
    func numeric(_ strip: StripRef, _ role: Role) -> Double? {
        guard let v = binding(strip, role)?.numeric(value(strip, role))?.value, v.isFinite || v == .infinity else { return nil }
        return v
    }

    /// Set a role to the MIDI value whose display is closest to `target` (in the parsed unit, e.g. Hz).
    func setNumeric(_ strip: StripRef, _ role: Role, _ target: Double) {
        guard let midi = binding(strip, role)?.midi(closestTo: target) else { return }
        set(strip, role, midi)
    }

    // MARK: Touch ownership (echo suppression)

    /// SwiftUI skips `onEnded` when a gesture is cancelled (tab switch, system edge swipe, controls disabled while
    /// offline), so an `endTouch` may never come: a touch with no begin/set for this long no longer owns its path.
    static let touchTimeout: TimeInterval = 1

    func beginTouch(_ strip: StripRef, _ role: Role) { beginTouch(path: path(strip, role)) }

    func endTouch(_ strip: StripRef, _ role: Role) { endTouch(path: path(strip, role)) }

    /// A finger is on the control for this value path (role or plugin control): MainStage's echoes of it are ignored
    /// until shortly after it lifts.
    func beginTouch(path p: String) {
        if !isTouchLive(p) { touching[p] = nil }   // drop a stale count left by a cancelled gesture
        touching[p, default: 0] += 1
        touchedAt[p] = Date()
    }

    func endTouch(path p: String) {
        touching[p] = max(0, (touching[p] ?? 1) - 1)
        if touching[p] == 0 { touching[p] = nil }
        releasedAt[p] = Date()
        client?.flushNow()
    }

    /// Connection dropped or app backgrounded: no gesture survives that, so forget every touch.
    func resetTouches() {
        touching.removeAll()
        touchedAt.removeAll()
        releasedAt.removeAll()
    }

    private func isTouchLive(_ path: String) -> Bool {
        guard touching[path] != nil, let t = touchedAt[path] else { return false }
        return Date().timeIntervalSince(t) < Self.touchTimeout
    }

    private func isSuppressed(_ path: String) -> Bool {
        if isTouchLive(path) { return true }
        if let t = releasedAt[path], Date().timeIntervalSince(t) < 0.25 { return true }
        return false
    }

    // MARK: Incoming

    func handle(_ m: OSCMessage) {
        switch m.address {
        case FOHProtocol.Path.meters:
            if let blob = m.arguments.first?.blobValue, let f = MeterFrame(data: blob) { meters?.update(f) }
        case FOHProtocol.Path.rta:
            if let r = RTAFrame(m) { meters?.updateRTA(r) }
        case FOHProtocol.Path.welcome:
            bridgeName = m.arguments.first?.stringValue
            if connection.isConnected, let name = bridgeName { connection = .connected(Self.shortBridgeName(name)) }
        case FOHProtocol.Path.config:
            let cfg = try? FOHProtocol.decodeJSON(ShowConfig.self, from: m)
            // Leave the demo either way: its meter timer would otherwise mix fake frames with the bridge's.
            if isDemo {
                values = [:]
                pluginCache = [:]
                confirmed = []
                backups = []
                meters?.stopDemo()
            }
            isDemo = false
            guard let cfg else {
                configError = "Couldn't read the bridge's show — update FOH Remote and FOH Bridge to the same version"
                return
            }
            configError = nil
            hasBridgeShow = true
            config = cfg
            if config.strip(selectedStrip) == nil, let first = channelOrder.first { selectedStrip = first.ref }
        case FOHProtocol.Path.syncDone:
            synced = true
            if let rtaStrip { client?.send(OSCMessage(FOHProtocol.Path.rtaSubscribe, [.string(rtaStrip)])) }
        case FOHProtocol.Path.status:
            status = try? FOHProtocol.decodeJSON(BridgeStatus.self, from: m)
        case FOHProtocol.Path.concert:
            if let info = try? FOHProtocol.decodeJSON(ConcertInfo.self, from: m) {
                concertInfo = info
                if scanningConcert { showConcertImport = true }
                scanningConcert = false
            }
        case FOHProtocol.Path.plugin:
            guard m.arguments.count >= 3, let key = m.arguments[0].stringValue, let pos = m.arguments[1].intValue,
                  let blob = m.arguments[2].blobValue, let desc = try? JSONDecoder().decode(PluginDescription.self, from: blob) else { return }
            pluginCache["\(key)#\(pos)"] = desc
        case FOHProtocol.Path.learnState:
            if let s = try? FOHProtocol.decodeJSON(LearnState.self, from: m) { learnState = s }
        case FOHProtocol.Path.ack:
            handleAck(m)
        case FOHProtocol.Path.backups:
            if let list = try? FOHProtocol.decodeJSON([BackupInfo].self, from: m) { backups = list.sorted { $0.date > $1.date } }
        case FOHProtocol.Path.backupData:
            guard m.arguments.count >= 2, let name = m.arguments[0].stringValue, let blob = m.arguments[1].blobValue else { return }
            writeExport(blob, filename: name)
        case FOHProtocol.Path.pong, FOHProtocol.Path.plugins:
            break
        default:
            guard let v = m.arguments.first?.intValue,
                  FOHProtocol.parseValuePath(m.address) != nil || FOHProtocol.parsePluginPath(m.address) != nil else { return }
            guard !isSuppressed(m.address) else { return }
            values[m.address] = FOHProtocol.clampMIDI(v)
            noteRecording(m.address)
            if m.arguments.count >= 2, let c = m.arguments[1].intValue {
                confirmationsSupported = true
                if c == 1 { confirmed.insert(m.address) } else { confirmed.remove(m.address) }
            }
        }
    }

    /// "FOH Bridge (Josh's MacBook Pro (13319)) (test)" → "Josh's MacBook Pro (13319) (test)" for the connection pill:
    /// unwrap the parenthesised host (which may itself contain parentheses) and keep anything after it.
    static func shortBridgeName(_ name: String) -> String {
        let prefix = "FOH Bridge ("
        guard name.hasPrefix(prefix) else { return name }
        let rest = name.dropFirst(prefix.count)
        var depth = 1
        for i in rest.indices {
            if rest[i] == "(" { depth += 1 }
            if rest[i] == ")" { depth -= 1 }
            if depth == 0 {
                let host = rest[..<i]
                let tail = rest[rest.index(after: i)...]
                return (host + tail).trimmingCharacters(in: .whitespaces)
            }
        }
        return String(rest)
    }

    func loadDemo() {
        let demo = DemoShow.make()
        config = demo.config
        values = demo.values
        isDemo = true
        synced = false
        connection = .demo
        configError = nil
        hasBridgeShow = false
        pluginCache = [:]
        learnState = LearnState()
        confirmed = []
        confirmationsSupported = false
        backups = demoSnapshots.map { Self.info($0.key, $0.value) }.sorted { $0.date > $1.date }
        meters?.startDemo(config)
        meters?.demoRTAStrip = rtaStrip
    }

    // MARK: Config editing (Setup › Channels & I/O)

    /// Apply an edited show: optimistic locally, then `/foh/config/set` (the bridge answers with `/foh/config`).
    /// Offline, bindings for changed or new strips are rebuilt from the bundled discovery fixtures.
    func applyConfig(_ new: ShowConfig) {
        var next = new
        let sendsChanged = next.sends != config.sends
        for strip in next.strips {
            let old = config.strip(strip.ref)
            let changed = old == nil || old?.plugins != strip.plugins || old?.processing != strip.processing || sendsChanged
            if changed {
                next.bindings[strip.ref.key] = isDemo
                    ? DemoShow.binding(for: strip, sends: next.sends)
                    : (old == nil || sendsChanged ? Self.mergeChannelStripDefaults(next.binding(strip.ref), strip: strip, sends: next.sends, calibration: next.faderCalibration) : next.binding(strip.ref))
            }
        }
        let refs = Set(next.strips.map(\.ref.key))
        next.bindings = next.bindings.filter { refs.contains($0.key) }
        config = next
        if config.strip(selectedStrip) == nil, let first = channelOrder.first { selectedStrip = first.ref }
        guard !isDemo else { return }
        if let msg = try? FOHProtocol.jsonMessage(FOHProtocol.Path.configSet, next) { client?.send(msg) }
    }

    func updateConfig(_ mutate: (inout ShowConfig) -> Void) {
        var c = config
        mutate(&c)
        applyConfig(c)
    }

    private static func mergeChannelStripDefaults(_ b: StripBinding, strip: Strip, sends: [SendBus], calibration: [CalibrationPoint]) -> StripBinding {
        var out = b
        out.roles = out.roles.filter { !$0.value.isChannelStrip || $0.value.role.group != .send }
        for d in StripBinding.channelStripDefaults(for: strip, sends: sends, calibration: calibration) where out.roles[d.role.id] == nil { out.roles[d.role.id] = d }
        return out
    }

    @discardableResult
    func addStrip(_ kind: StripKind) -> StripRef? {
        guard let slot = config.nextFreeSlot(kind), let ref = StripRef(kind: kind, slot: slot) else { return nil }
        let palette: [ChannelColor] = [.cyan, .yellow, .green, .magenta, .red, .blue]
        let name: String, color: ChannelColor, io: String?
        switch kind {
        case .input: name = "Input \(slot)"; color = palette[(slot - 1) % palette.count]; io = "In \(slot)"
        case .fx: name = "FX \(slot)"; color = .blue; io = nil
        case .output: name = "Output \(slot)"; color = .white; io = nil
        case .master: name = "Master"; color = .white; io = nil
        }
        updateConfig { $0.strips.append(Strip(ref: ref, name: name, color: color, hardwareIO: io)) }
        selectedStrip = ref
        return ref
    }

    func removeStrip(_ ref: StripRef) {
        updateConfig { c in
            c.strips.removeAll { $0.ref == ref }
            c.bindings[ref.key] = nil
        }
    }

    func updateStrip(_ ref: StripRef, _ mutate: (inout Strip) -> Void) {
        updateConfig { c in
            guard let i = c.strips.firstIndex(where: { $0.ref == ref }) else { return }
            mutate(&c.strips[i])
        }
    }

    @discardableResult
    func addSend() -> Int? {
        guard let index = (1...8).first(where: { n in !config.sends.contains { $0.index == n } }) else { return nil }
        let bus = (config.sends.compactMap(\.busNumber).max() ?? 0) + 1
        updateConfig { c in
            c.sends.append(SendBus(index: index, name: "Send \(index)", busNumber: bus, existsInConcert: false))
            c.sends.sort { $0.index < $1.index }
        }
        return index
    }

    func updateSend(_ index: Int, _ mutate: (inout SendBus) -> Void) {
        updateConfig { c in
            guard let i = c.sends.firstIndex(where: { $0.index == index }) else { return }
            mutate(&c.sends[i])
        }
    }

    func removeSend(_ index: Int) {
        updateConfig { $0.sends.removeAll { $0.index == index } }
        if sendsOnFaders == index { sendsOnFaders = nil }
    }

    // MARK: Concert import

    func scanConcert(path: String? = nil) {
        scanningConcert = true
        if isDemo {
            concertInfo = DemoShow.concert
            scanningConcert = false
            showConcertImport = true
            return
        }
        client?.send(OSCMessage(FOHProtocol.Path.concertScan, path.map { [.string($0)] } ?? []))
    }

    func mergeConcert() {
        showConcertImport = false
        guard let info = concertInfo else { return }
        if isDemo {
            var merged = config.merged(with: info)
            for strip in merged.strips where merged.bindings[strip.ref.key] == nil {
                merged.bindings[strip.ref.key] = DemoShow.binding(for: strip, sends: merged.sends)
            }
            config = merged
            return showToast("Merged \(info.name) into the show (demo)")
        }
        client?.send(OSCMessage(FOHProtocol.Path.concertMerge, [.string(info.path)]))
    }

    /// Whether a concert strip matches a strip already in the show (same MainStage name and kind).
    func existingStrip(for cs: ConcertInfo.ChannelStrip) -> Strip? {
        guard let kind = cs.stripKind else { return nil }
        return config.strips.first { $0.mainStage?.stripName == cs.name && $0.ref.kind == kind }
    }

    // MARK: Plugins & bindings (Setup › Processing)

    func pluginKey(_ strip: StripRef, _ position: Int) -> String { "\(strip.key)#\(position)" }

    func pluginDescription(_ strip: StripRef, _ position: Int) -> PluginDescription? {
        // MainStage's own plugins: MainStage's table from the bridge (when it has one) plus what's been learned, from
        // the show, so a new learn shows without asking again.
        if let s = config.strip(strip), let p = s.plugin(at: position), p.component == nil {
            let table = pluginCache[pluginKey(strip, position)]
            return config.mainStagePluginDescriptions(s) { _ in table }[position]
        }
        if let cached = pluginCache[pluginKey(strip, position)] { return cached }
        if isDemo, let c = config.strip(strip)?.plugin(at: position)?.component { return DemoShow.plugins[c] }
        return nil
    }

    func requestPlugin(_ strip: StripRef, _ position: Int) {
        guard !isDemo, pluginCache[pluginKey(strip, position)] == nil else { return }
        client?.send(OSCMessage(FOHProtocol.Path.pluginGet, [.string(strip.key), .int(Int32(position))]))
    }

    func rescanPlugins(_ strip: StripRef) {
        pluginCache = pluginCache.filter { !$0.key.hasPrefix(strip.key + "#") }
        guard !isDemo else { return }
        client?.send(OSCMessage(FOHProtocol.Path.discover, [.string(strip.key)]))
    }

    /// Bind a role to a plugin parameter ("" hides it as not-in-plugin). Optimistic; the bridge answers with config.
    func bindSet(_ strip: StripRef, _ role: Role, position: Int, parameterID: String) {
        var b = config.binding(strip)
        if parameterID.isEmpty {
            b.roles[role.id] = nil
            if !b.notInPlugin.contains(role.id) { b.notInPlugin.append(role.id) }
        } else if let desc = pluginDescription(strip, position), let p = desc.parameter(id: parameterID) {
            var kind = p.kind
            if role.kind == .toggle, case .stepped(2) = kind { kind = .toggle }
            b.roles[role.id] = RoleBinding(role: role, pluginPosition: position, pluginName: desc.name, parameterID: p.id,
                                           parameterName: p.name, unitName: p.unitName, kind: kind, steps: p.steps, origin: .manual)
            b.notInPlugin.removeAll { $0 == role.id }
        }
        config.bindings[strip.key] = b
        guard !isDemo else {
            return showToast(parameterID.isEmpty ? "\(role.label) hidden" : "\(role.label) → \(b[role]?.parameterName ?? parameterID)")
        }
        client?.send(OSCMessage(FOHProtocol.Path.bindSet, [.string(strip.key), .string(role.id), .int(Int32(position)), .string(parameterID)]))
    }

    /// Copy plugin bindings from one strip to another wherever the same plugin is on both.
    func bindApply(from: StripRef, to: StripRef) {
        if isDemo, let target = config.strip(to) {
            var b = config.binding(to)
            for rb in config.binding(from).roles.values where !rb.parameterID.hasPrefix("@") {
                guard let comp = config.strip(from)?.plugin(at: rb.pluginPosition)?.component,
                      let pos = target.plugins.first(where: { $0.component == comp })?.position else { continue }
                var copy = rb
                copy.pluginPosition = pos
                b.roles[rb.role.id] = copy
            }
            config.bindings[to.key] = b
            return showToast("Applied \(config.strip(from)?.name ?? from.key)'s bindings to \(target.name)")
        }
        client?.send(OSCMessage(FOHProtocol.Path.bindApply, [.string(from.key), .string(to.key)]))
    }

    func bindReset(_ strip: StripRef) {
        if isDemo, let s = config.strip(strip) {
            config.bindings[strip.key] = DemoShow.binding(for: s, sends: config.sends)
            return showToast("\(s.name) reset to its templates")
        }
        client?.send(OSCMessage(FOHProtocol.Path.bindReset, [.string(strip.key)]))
    }

    // MARK: Setlist & state

    var currentPatch: PatchInfo? {
        guard let i = config.currentPatch, config.patches.indices.contains(i) else { return config.patches.first }
        return config.patches[i]
    }

    func selectPatch(_ index: Int) {
        guard !locked, config.patches.indices.contains(index) else { return }
        config.currentPatch = index
        guard !isDemo else { return showToast("Patch → \(config.patches[index].name) (demo — no Program Change sent)") }
        client?.send(OSCMessage(FOHProtocol.Path.patchSelect, [.int(Int32(index))]))
    }

    func pullFromMainStage() {
        guard !isDemo else { return showToast("Demo — connect to FOH Bridge to pull from MainStage", ok: false) }
        client?.send(OSCMessage(FOHProtocol.Path.pull))
    }

    func pushAllToMainStage() {
        guard !isDemo else { return showToast("Demo — connect to FOH Bridge to push to MainStage", ok: false) }
        client?.send(OSCMessage(FOHProtocol.Path.pushAll))
    }

    /// Ask the bridge to write its assignments into the MainStage concert (it waits if MainStage is open).
    func updateMainStageAssignments() {
        guard !isDemo else { return showToast("Demo — connect to FOH Bridge to update MainStage", ok: false) }
        client?.send(OSCMessage(FOHProtocol.Path.mainStageUpdate))
    }

    // MARK: Toasts & acks

    func showToast(_ message: String, ok: Bool = true) {
        let t = Toast(ok: ok, message: message)
        toast = t
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    /// `/foh/ack ,s action ,i ok ,s message` → toast. Successful config saves stay quiet (they happen on every edit).
    private func handleAck(_ m: OSCMessage) {
        let action = m.arguments.first?.stringValue ?? ""
        let ok = (m.arguments.count > 1 ? m.arguments[1].intValue : 1) == 1
        let message = m.arguments.count > 2 ? (m.arguments[2].stringValue ?? "") : ""
        if ok && action == FOHProtocol.Path.configSet { return }
        showToast(message.isEmpty ? "\(Self.actionName(action)) \(ok ? "done" : "failed")" : message, ok: ok)
    }

    static func actionName(_ path: String) -> String {
        switch path {
        case FOHProtocol.Path.pull: return "Pull from MainStage"
        case FOHProtocol.Path.pushAll: return "Push to MainStage"
        case FOHProtocol.Path.patchSelect: return "Patch change"
        case FOHProtocol.Path.concertMerge: return "Concert merge"
        case FOHProtocol.Path.mainStageUpdate: return "Update MainStage assignments"
        case FOHProtocol.Path.pluginControlAdd: return "Add control"
        case FOHProtocol.Path.pluginControlRemove: return "Remove control"
        case FOHProtocol.Path.pluginLearnStart: return "Learn"
        case FOHProtocol.Path.pluginLearnSend: return "Learn signal"
        case FOHProtocol.Path.pluginLearnCancel: return "Cancel learn"
        case FOHProtocol.Path.pluginLearnCheck: return "Check concert"
        case FOHProtocol.Path.pluginLearnForget: return "Forget"
        case FOHProtocol.Path.learnFire: return "Learn signal"
        case FOHProtocol.Path.bindSet: return "Binding"
        case FOHProtocol.Path.bindApply: return "Apply bindings"
        case FOHProtocol.Path.bindReset: return "Reset to template"
        case FOHProtocol.Path.calibrationSet: return "Calibration"
        case FOHProtocol.Path.backupCreate: return "Snapshot"
        case FOHProtocol.Path.backupRestore: return "Restore"
        case FOHProtocol.Path.backupImport: return "Import"
        case FOHProtocol.Path.templateSave: return "Save template"
        case FOHProtocol.Path.templateDelete: return "Delete template"
        default: return path.split(separator: "/").last.map(String.init)?.capitalized ?? "Request"
        }
    }

    // MARK: Display order (Setup › Channels & I/O)

    /// Move a strip within its kind's display order. Never changes its slot or MIDI address.
    func moveStrip(_ ref: StripRef, to index: Int) {
        var keys = config.ordered(ref.kind).map(\.ref.key)
        guard let from = keys.firstIndex(of: ref.key) else { return }
        let to = max(0, min(keys.count - 1, index))
        guard from != to else { return }
        keys.remove(at: from)
        keys.insert(ref.key, at: to)
        setOrder(ref.kind, keys)
    }

    func moveStrip(_ ref: StripRef, by delta: Int) {
        guard let i = config.ordered(ref.kind).firstIndex(where: { $0.ref == ref }) else { return }
        moveStrip(ref, to: i + delta)
    }

    private func setOrder(_ kind: StripKind, _ keys: [String]) {
        var order: [String] = []
        for k in [StripKind.input, .fx, .output, .master] {
            order += k == kind ? keys : config.ordered(k).map(\.ref.key)
        }
        updateConfig { $0.stripOrder = order }
    }

    // MARK: Backups (Setup › Backup & restore)

    private static func info(_ id: String, _ b: BackupBundle) -> BackupInfo {
        BackupInfo(id: id, date: b.created, reason: b.reason, stripCount: b.show.strips.count)
    }

    private func seedDemoSnapshots() {
        let now = Date()
        for (offset, reason) in [(-86_400.0, "Before concert merge"), (-7_200.0, "Demo show loaded")] {
            let id = UUID().uuidString
            demoSnapshots[id] = BackupBundle(created: now.addingTimeInterval(offset), reason: reason, show: config,
                                             overrides: [:], learn: LearnState(), values: values)
        }
        backups = demoSnapshots.map { Self.info($0.key, $0.value) }.sorted { $0.date > $1.date }
    }

    private func currentBundle(_ reason: String) -> BackupBundle {
        BackupBundle(reason: reason, show: config, overrides: [:], learn: learnState, values: values)
    }

    func listBackups() {
        guard !isDemo else { return }
        client?.send(OSCMessage(FOHProtocol.Path.backupList))
    }

    func createBackup(reason: String) {
        let reason = reason.trimmingCharacters(in: .whitespaces).isEmpty ? "Manual snapshot" : reason
        if isDemo {
            let id = UUID().uuidString
            demoSnapshots[id] = currentBundle(reason)
            backups = demoSnapshots.map { Self.info($0.key, $0.value) }.sorted { $0.date > $1.date }
            return showToast("Snapshot saved: \(reason)")
        }
        client?.send(OSCMessage(FOHProtocol.Path.backupCreate, [.string(reason)]))
    }

    func restoreBackup(_ id: String) {
        if isDemo {
            guard let b = demoSnapshots[id] else { return showToast("Snapshot not found", ok: false) }
            apply(b)
            return showToast("Restored “\(b.reason)”")
        }
        client?.send(OSCMessage(FOHProtocol.Path.backupRestore, [.string(id)]))
    }

    func exportBackup() {
        if isDemo {
            let b = currentBundle("Exported from FOH Remote (demo)")
            guard let data = try? JSONEncoder().encode(b) else { return }
            return writeExport(data, filename: b.suggestedFilename)
        }
        client?.send(OSCMessage(FOHProtocol.Path.backupExport))
    }

    func importBackup(_ bundle: BackupBundle) {
        if isDemo {
            apply(bundle)
            return showToast("Imported “\(bundle.show.name)” (\(bundle.reason))")
        }
        guard let msg = try? FOHProtocol.jsonMessage(FOHProtocol.Path.backupImport, bundle) else { return }
        client?.send(msg)
    }

    private func apply(_ b: BackupBundle) {
        config = b.show
        values = b.values
        learnState = b.learn
        if config.strip(selectedStrip) == nil, let first = channelOrder.first { selectedStrip = first.ref }
    }

    private func writeExport(_ data: Data, filename: String) {
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe.hasSuffix(".fohshow") ? safe : safe + ".fohshow")
        do {
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            showToast("Couldn't write the export: \(error.localizedDescription)", ok: false)
        }
    }

    // MARK: Custom templates (Setup › Plugin templates)

    func saveTemplate(name: String, strip: StripRef, position: Int, use: CustomTemplate.Use) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return showToast("A template needs a name", ok: false) }
        if isDemo {
            guard let s = config.strip(strip),
                  let t = CustomTemplate.capture(name: name, strip: s, binding: config.binding(strip), position: position, use: use) else {
                return showToast("Nothing bound to that plugin yet", ok: false)
            }
            config.customTemplates.removeAll { $0.name == name }
            config.customTemplates.append(t)
            rebuildDemoBindings()
            return showToast("Saved template “\(name)” (\(t.rules.count) rules)")
        }
        client?.send(OSCMessage(FOHProtocol.Path.templateSave, [.string(strip.key), .string(name), .string(use.rawValue), .int(Int32(position))]))
    }

    func deleteTemplate(_ id: String) {
        if isDemo {
            let name = config.customTemplates.first { $0.id == id }?.name ?? "template"
            config.customTemplates.removeAll { $0.id == id }
            rebuildDemoBindings()
            return showToast("Deleted “\(name)”")
        }
        client?.send(OSCMessage(FOHProtocol.Path.templateDelete, [.string(id)]))
    }

    /// Offline only: re-run templates (custom first) for every strip from the bundled discovery fixtures.
    private func rebuildDemoBindings() {
        for s in config.strips {
            config.bindings[s.ref.key] = StripBinding.build(for: s, sends: config.sends, discovered: DemoShow.discovered(for: s),
                                                           calibration: config.faderCalibration, customTemplates: config.customTemplates)
        }
    }

    // MARK: Meters & RTA

    /// Stream this strip's input RTA (nil stops).
    func subscribeRTA(_ strip: StripRef?) {
        let key = strip?.key
        guard key != rtaStrip else { return }
        rtaStrip = key
        if isDemo {
            meters?.demoRTAStrip = key
        } else {
            client?.send(OSCMessage(FOHProtocol.Path.rtaSubscribe, [.string(key ?? "")]))
        }
    }

    // MARK: Learn

    func learnKey(_ strip: StripRef, _ role: Role) -> String { LearnState.Item(strip, role).key }

    func isLearned(_ strip: StripRef, _ role: Role) -> Bool {
        let key = learnKey(strip, role)
        return isDemo ? demoLearned.contains(key) : learnState.learned.contains(key)
    }

    /// Bound roles for a strip in CC order (the MainStage learn list).
    func learnList(_ strip: StripRef) -> [RoleBinding] {
        config.binding(strip).roles.values.sorted { $0.role.cc < $1.role.cc }
    }

    /// The item being learned, shared with the Mac's Learn HUD.
    func setLearnCurrent(_ strip: StripRef, _ role: Role) {
        learnState.current = LearnState.Item(strip, role)
        guard !isDemo, let msg = try? FOHProtocol.jsonMessage(FOHProtocol.Path.learnState, learnState) else { return }
        client?.send(msg)
    }

    /// Mark the current item learned and move to the next pending one on the same strip.
    func learnNext(markLearned: Bool) {
        guard let current = learnState.current else { return }
        if isDemo {
            if markLearned { demoLearned.insert(current.key) }
            var s = learnState
            s.learned = Array(demoLearned)
            learnState.current = s.next(after: current, in: config, strip: current.stripRef)
            return
        }
        if markLearned {
            client?.send(OSCMessage(FOHProtocol.Path.learnNext))
        } else if let next = learnState.next(after: current, in: config, strip: current.stripRef),
                  let ref = next.stripRef, let role = next.roleValue {
            setLearnCurrent(ref, role)
        }
    }

    func resetDemoLearned(_ strip: StripRef) {
        demoLearned = demoLearned.filter { !$0.hasPrefix(strip.key + "|") }
    }
}

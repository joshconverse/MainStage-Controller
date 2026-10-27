import Foundation

/// The iPad ↔ Bridge OSC protocol (PLAN.md §6).
///
/// Values travel as MIDI-resolution integers (0–127) because MainStage is 7-bit;
/// display text comes from the strip's binding value table.
public enum FOHProtocol {
    public static let version: Int32 = 1
    public static let bonjourType = "_fohbridge._tcp"
    public static let defaultPort: UInt16 = 9000

    public enum Path {
        /// client → bridge: `,s clientName ,i protocolVersion`
        public static let hello = "/foh/hello"
        /// bridge → client: `,s bridgeName ,i protocolVersion`
        public static let welcome = "/foh/welcome"
        /// client → bridge: request a full state dump. Bridge replies with config, bindings,
        /// plugins, every cached value, then `syncDone`.
        public static let sync = "/foh/sync"
        public static let syncDone = "/foh/sync/done"
        /// bridge → client: `,b json(ShowConfig)`
        public static let config = "/foh/config"
        /// bridge → client: `,b json([String: [PluginDescription]])` keyed by strip key
        public static let plugins = "/foh/plugins"
        /// bridge → client: `,b json(BridgeStatus)`
        public static let status = "/foh/status"
        /// client → bridge: `,s valuePath` — fire the learn sweep for that role
        public static let learnFire = "/foh/learn/fire"
        /// client → bridge: `,s valuePath ,i value` — send one raw value without caching (learn/verify)
        public static let learnSend = "/foh/learn/send"
        /// client → bridge: `,s stripKey` — re-run plugin discovery + template binding for a strip
        public static let discover = "/foh/discover"
        /// bidirectional keep-alive: `,i sequence`
        public static let ping = "/foh/ping"
        public static let pong = "/foh/pong"

        // MARK: Phase 2 — configuration, concert import, binding editor

        /// client → bridge: `,b json(ShowConfig)` — the edited show (strips, sends, patches). The bridge keeps its own
        /// bindings for unchanged strips, rebuilds bindings for strips whose plugins/processing changed, persists,
        /// and broadcasts `/foh/config`.
        public static let configSet = "/foh/config/set"
        /// client → bridge: `[,s path]` — scan a .concert (default: the show's `concertPath`, else ~/Desktop/*.concert).
        /// Bridge replies `concert`.
        public static let concertScan = "/foh/concert/scan"
        /// bridge → client: `,b json(ConcertInfo)`
        public static let concert = "/foh/concert"
        /// client → bridge: `[,s path]` — scan and merge into the show (`ShowConfig.merged(with:)`), rediscover, broadcast config.
        public static let concertMerge = "/foh/concert/merge"
        /// client → bridge: `,s stripKey ,i pluginPosition` — request a discovered plugin's full parameter list.
        public static let pluginGet = "/foh/plugin/get"
        /// bridge → client: `,s stripKey ,i pluginPosition ,b json(PluginDescription)`
        public static let plugin = "/foh/plugin"
        /// client → bridge: `,s stripKey ,s roleID ,i pluginPosition ,s parameterID` — bind a role to a parameter
        /// (`parameterID` "" hides the role / marks it not-in-plugin). Bridge rebuilds the RoleBinding from discovery
        /// (steps, kind, unit) with origin `.manual`, persists, broadcasts config.
        public static let bindSet = "/foh/bind/set"
        /// client → bridge: `,s fromStripKey ,s toStripKey` — copy bindings to another strip with the same plugin(s).
        public static let bindApply = "/foh/bind/apply"
        /// client → bridge: `,s stripKey` — throw away manual bindings and re-run the templates.
        public static let bindReset = "/foh/bind/reset"

        // MARK: Phase 2 — setlist, state, learn

        /// client → bridge: `,i patchIndex` — send that patch's Program Change on "FOH Global" ch 1.
        public static let patchSelect = "/foh/patch/select"
        /// client → bridge: re-select the current patch so MainStage re-sends every mapped value ("Send Value to").
        public static let pull = "/foh/pull"
        /// client → bridge: re-send every cached value to MainStage (the iPad guards this behind a confirm).
        public static let pushAll = "/foh/push"
        /// bidirectional: `,b json(LearnState)` — clients send the item they move to; the bridge broadcasts the truth.
        public static let learnState = "/foh/learn/state"
        /// client/HUD → bridge: mark the current item learned and advance to the next pending one.
        public static let learnNext = "/foh/learn/next"
        /// client → bridge: `,b json([CalibrationPoint])` — measured MainStage fader readings; the bridge stores them in
        /// `ShowConfig.faderCalibration`, rebuilds every fader/send binding and broadcasts config.
        public static let calibrationSet = "/foh/calibration/set"

        // MARK: Finishing — acknowledgements, backups, custom templates

        /// bridge → the client that asked: `,s action ,i ok(1/0) ,s message` after pull, push, patch select, concert
        /// merge, config set, bind set/apply/reset, calibration, backup create/restore/import, template save/delete.
        /// `action` is the request's path ("/foh/pull").
        public static let ack = "/foh/ack"
        /// client → bridge: list snapshots. Bridge replies `backups`.
        public static let backupList = "/foh/backup/list"
        /// bridge → client: `,b json([BackupInfo])`, newest first (also broadcast whenever one is added).
        public static let backups = "/foh/backups"
        /// client → bridge: `,s reason` — snapshot now. The bridge also snapshots automatically before concert merge,
        /// config set, bind reset, calibration and restore, keeping the newest 30.
        public static let backupCreate = "/foh/backup/create"
        /// client → bridge: `,s backupID` — restore a snapshot (show, overrides, learn, values), rebuild, broadcast.
        public static let backupRestore = "/foh/backup/restore"
        /// client → bridge: export the current state. Bridge replies `backupData`.
        public static let backupExport = "/foh/backup/export"
        /// bridge → client: `,s suggestedFilename ,b json(BackupBundle)`
        public static let backupData = "/foh/backup/data"
        /// client → bridge: `,b json(BackupBundle)` — restore from a file the user picked.
        public static let backupImport = "/foh/backup/import"
        /// client → bridge: `,s stripKey ,s name ,s use ("processing"|"insert") ,i pluginPosition` — save that strip's
        /// bindings for that plugin as a `CustomTemplate` (replacing one with the same name), rebuild matching strips.
        public static let templateSave = "/foh/template/save"
        /// client → bridge: `,s templateID` — delete a custom template and rebuild.
        public static let templateDelete = "/foh/template/delete"

        // MARK: Phase 3 — meters and RTA

        /// bridge → client: `,b MeterFrame.encoded()` at ~25 Hz while the client is connected.
        public static let meters = "/foh/meters"
        /// client → bridge: `,s stripKey` — start streaming that strip's input RTA ("" stops).
        public static let rtaSubscribe = "/foh/rta/subscribe"
        /// bridge → client: `,s stripKey ,b bands` (see `RTAFrame`) at ~15 Hz.
        public static let rta = "/foh/rta"

        // MARK: Plugin controls (PLAN.md §9c)

        /// client → bridge: write the show's assignments into the MainStage concert now (only while MainStage is
        /// closed; otherwise the change waits for it to quit). Bridge replies `ack` when done.
        public static let mainStageUpdate = "/foh/mainstage/update"
        /// client → bridge: `,s stripKey ,i pluginPosition ,s parameterID` — add that parameter to its plugin type's
        /// controls (every instance gets it; mapped in MainStage at the next update). Bridge replies `ack` and `config`.
        public static let pluginControlAdd = "/foh/plugin/control/add"
        /// client → bridge: same arguments — take it out of the plugin type's controls.
        public static let pluginControlRemove = "/foh/plugin/control/remove"

        // MARK: MainStage's own plugins (PLAN.md §9c phase 5)

        /// client → bridge: `,s stripKey ,i pluginPosition ,s name` — start teaching a control of one of MainStage's
        /// own plugins: the bridge hands out an address (a `PendingLearn` in the config). Bridge replies `ack`.
        public static let pluginLearnStart = "/foh/plugin/learn/start"
        /// client → bridge: `,s learnID` — send the learn signal on that address (for MainStage's Assign & Map).
        public static let pluginLearnSend = "/foh/plugin/learn/send"
        /// client → bridge: `,s learnID` — give up on a learn.
        public static let pluginLearnCancel = "/foh/plugin/learn/cancel"
        /// client → bridge: read the saved concert now for finished learns (the bridge also does when MainStage quits).
        public static let pluginLearnCheck = "/foh/plugin/learn/check"
        /// client → bridge: `,s pluginName ,i parameterIndex` — forget a learned parameter.
        public static let pluginLearnForget = "/foh/plugin/learn/forget"
    }

    /// Program Change status byte for "FOH Global" ch 1.
    public static let programChangeStatus: UInt8 = 0xC0

    /// A value update. `confirmed` (bridge → client only): 1 when MainStage itself reported this value through
    /// "Send Value to" (or echoed it), 0 when it's the bridge's assumption (seeded default or last sent value).
    /// Clients read argument 0 and treat a missing argument 1 as unknown.
    public static func valueMessage(_ strip: StripRef, _ role: Role, _ value: Int, confirmed: Bool) -> OSCMessage {
        OSCMessage(valuePath(strip, role), [.int(Int32(clampMIDI(value))), .int(confirmed ? 1 : 0)])
    }

    public static func ackMessage(_ action: String, ok: Bool, _ message: String) -> OSCMessage {
        OSCMessage(Path.ack, [.string(action), .int(ok ? 1 : 0), .string(message)])
    }

    /// `/foh/in/1/band/2/gain`
    public static func valuePath(_ strip: StripRef, _ role: Role) -> String {
        "/foh/\(strip.key)/\(role.pathSuffix)"
    }

    public static func parseValuePath(_ path: String) -> (strip: StripRef, role: Role)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[0] == "foh",
              let strip = StripRef(key: "\(parts[1])/\(parts[2])") else { return nil }
        let roleID = parts[3...].joined(separator: ".")
        guard let role = Role.byID[roleID] else { return nil }
        return (strip, role)
    }

    public static func valueMessage(_ strip: StripRef, _ role: Role, _ value: Int) -> OSCMessage {
        OSCMessage(valuePath(strip, role), [.int(Int32(clampMIDI(value)))])
    }

    public static func clampMIDI(_ v: Int) -> Int { min(127, max(0, v)) }

    public static func jsonMessage<T: Encodable>(_ path: String, _ value: T) throws -> OSCMessage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return OSCMessage(path, [.blob(try encoder.encode(value))])
    }

    public static func decodeJSON<T: Decodable>(_ type: T.Type, from message: OSCMessage) throws -> T {
        guard let blob = message.arguments.first?.blobValue else { throw OSCError.badTypeTag }
        return try JSONDecoder().decode(type, from: blob)
    }
}

/// Bridge health, shown in the iPad's connection pill and Setup › Connection.
public struct BridgeStatus: Codable, Hashable, Sendable {
    public struct PortStatus: Codable, Hashable, Sendable {
        public var name: String
        public var sent: Int
        public var received: Int
        /// True once MainStage has sent anything back on this port ("Send Value to" works).
        public var feedbackSeen: Bool

        public init(name: String, sent: Int = 0, received: Int = 0, feedbackSeen: Bool = false) {
            self.name = name
            self.sent = sent
            self.received = received
            self.feedbackSeen = feedbackSeen
        }
    }

    public var bridgeName: String
    public var ports: [PortStatus]
    public var clients: [String]
    public var discoveredPlugins: [String]
    /// Audio interface the input meters read from, and how many channels it has.
    public var inputDevice: String?
    public var inputChannelCount: Int?
    /// The chosen interface while it's unplugged ("Scarlett 2i2 USB"): the meters wait for it rather than
    /// reading another input. nil when it's connected or the meters follow the system default.
    public var inputWaitingFor: String?
    /// "MainStage" while the output process tap is running, nil if it isn't (not running / no permission).
    public var outputTap: String?
    /// Average MainStage echo round trip, once feedback has been seen.
    public var echoRTTms: Double?
    /// The MainStage assignment sync in one line ("Up to date · checked 9:41", "3 changes waiting — quit MainStage
    /// to apply"); nil from bridges that don't sync.
    public var mainStageSync: String?

    public init(bridgeName: String, ports: [PortStatus], clients: [String], discoveredPlugins: [String],
                inputDevice: String? = nil, inputChannelCount: Int? = nil, inputWaitingFor: String? = nil,
                outputTap: String? = nil, echoRTTms: Double? = nil) {
        self.bridgeName = bridgeName
        self.ports = ports
        self.clients = clients
        self.discoveredPlugins = discoveredPlugins
        self.inputDevice = inputDevice
        self.inputChannelCount = inputChannelCount
        self.inputWaitingFor = inputWaitingFor
        self.outputTap = outputTap
        self.echoRTTms = echoRTTms
    }
}

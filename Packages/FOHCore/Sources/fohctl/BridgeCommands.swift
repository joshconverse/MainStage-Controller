import Foundation
import FOHCore
import FOHMacKit

// Headless bridge and MainStage-simulation commands.

/// Line-buffer stdout so background runs that log to a file show output immediately.
func lineBufferStdout() {
    setvbuf(stdout, nil, _IOLBF, 0)
}

func runMainLoop(seconds: Double?, until done: () -> Bool = { false }) {
    let deadline = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
    while Date() < deadline && !done() {
        RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.1)))
    }
}

func describeMessage(_ m: OSCMessage) -> String {
    let args = m.arguments.map { a -> String in
        switch a {
        case .int(let v): return "\(v)"
        case .float(let v): return "\(v)"
        case .string(let s): return "\"\(s)\""
        case .blob(let d): return "<blob \(d.count) bytes>"
        case .int64(let v): return "\(v)"
        case .double(let v): return "\(v)"
        case .bool(let b): return b ? "T" : "F"
        }
    }
    return ([m.address] + args).joined(separator: " ")
}

/// `osc` arguments after the path: `--s text`, `--i 64`, `--f 0.5`, or bare tokens (ints become ,i, others ,s).
func oscArguments(_ args: [String]) -> [OSCArgument] {
    var out: [OSCArgument] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--s" where i + 1 < args.count: out.append(.string(args[i + 1])); i += 2
        case "--i" where i + 1 < args.count: out.append(.int(Int32(args[i + 1]) ?? 0)); i += 2
        case "--f" where i + 1 < args.count: out.append(.float(Float(args[i + 1]) ?? 0)); i += 2
        case "--host", "--port", "--seconds": i += 2
        default:
            out.append(Int32(a).map(OSCArgument.int) ?? .string(a))
            i += 1
        }
    }
    return out
}

func connectClient(_ args: [String], name: String) -> BridgeOSCClient {
    let host = option("--host", in: args) ?? "127.0.0.1"
    let port = UInt16(option("--port", in: args) ?? "") ?? FOHProtocol.defaultPort
    let client = BridgeOSCClient(host: host, port: port)
    client.onState = { state in
        if case .failed(let e) = state { print("connection failed: \(e)") }
    }
    client.start()
    client.send(OSCMessage(FOHProtocol.Path.hello, [.string(name), .int(FOHProtocol.version)]))
    return client
}

/// Connect, sync, and return the bridge's config, learn state, status and values.
func syncBridge(_ args: [String], name: String) throws -> (config: ShowConfig, learn: LearnState?, status: BridgeStatus?, values: [String: Int]) {
    let client = connectClient(args, name: name)
    var config: ShowConfig?
    var learn: LearnState?
    var status: BridgeStatus?
    var values: [String: Int] = [:]
    var done = false
    client.onMessage = { m in
        switch m.address {
        case FOHProtocol.Path.config: config = try? FOHProtocol.decodeJSON(ShowConfig.self, from: m)
        case FOHProtocol.Path.learnState: learn = try? FOHProtocol.decodeJSON(LearnState.self, from: m)
        case FOHProtocol.Path.status: status = try? FOHProtocol.decodeJSON(BridgeStatus.self, from: m)
        case FOHProtocol.Path.syncDone: done = true
        default:
            if FOHProtocol.parseValuePath(m.address) != nil || FOHProtocol.parsePluginPath(m.address) != nil,
               let v = m.arguments.first?.intValue { values[m.address] = v }
        }
    }
    client.send(OSCMessage(FOHProtocol.Path.sync))
    runMainLoop(seconds: 5) { done }
    runMainLoop(seconds: 0.3) // the status message follows sync/done
    client.cancel()
    guard let config else { throw UsageError("no /foh/config received") }
    return (config, learn, status, values)
}

/// Print an `/foh/ack` as "✓ /foh/pull: Re-selected Song One".
func printAck(_ m: OSCMessage) {
    guard m.address == FOHProtocol.Path.ack, m.arguments.count >= 3, let action = m.arguments[0].stringValue else { return }
    print("\(m.arguments[1].intValue == 1 ? "✓" : "✗") \(action): \(m.arguments[2].stringValue ?? "")")
}

func printShowSummary(_ config: ShowConfig) {
    let patch = config.currentPatch.flatMap { config.patches.indices.contains($0) ? config.patches[$0].name : nil } ?? "—"
    print("show \"\(config.name)\": \(config.strips.count) strips, \(config.sends.count) sends, \(config.patches.count) patches (current: \(patch))")
    for strip in config.strips {
        let b = config.binding(strip.ref)
        let plugins = Dictionary(grouping: b.roles.values, by: \.pluginName).map { "\($0.key) \($0.value.count)" }.sorted()
        let manual = b.roles.values.filter { $0.origin == .manual }.count
        print(String(format: "  %-8@ %-14@ %3d roles bound (%d manual), %2d not in plugin   [%@]", strip.ref.key as NSString,
                     strip.name as NSString, b.roles.count, manual, b.notInPlugin.count, plugins.joined(separator: ", ") as NSString))
    }
}

func printConcert(_ info: ConcertInfo) {
    print("\(info.name) — \(info.path)")
    print("  audio inputs: \(info.audioInputCount.map(String.init) ?? "?") · patches: \(info.patches.map { "\($0.name)\($0.programChange.map { " (PC \($0))" } ?? "")" }.joined(separator: ", "))")
    for s in info.strips {
        let io = [s.input.map { "in \($0)" }, s.output.map { "out \($0)" }].compactMap { $0 }.joined(separator: " · ")
        let where_ = s.level == .concert ? "concert" : "patch \(s.patchName ?? "?")"
        print("  \(s.name) [\(s.kind.rawValue), \(where_)\(s.stereo ? ", stereo" : "")] \(io)")
        for p in s.plugins {
            print("      \(p.position). \(p.name)\(p.component.map { "  [\($0)]" } ?? "")\(p.preset.map { "  · \($0)" } ?? "")")
        }
        for send in s.sends {
            print("      send \(send.slot) → bus \(send.bus.map(String.init) ?? "?")\(send.level.map { String(format: " @ %.3f", $0) } ?? "")\(send.muted ? " (muted)" : "")")
        }
    }
}

let bridgeCommands: [Command] = [
    Command(name: "bridge", usage: "[--seconds N] [--port P] [--suffix S] [--store DIR] [--no-discovery] [--no-meters|--fake-meters]   run the bridge headless") { args in
        lineBufferStdout()
        var opts = BridgeServer.Options()
        opts.onLog = { print($0) }
        opts.mainStageCatalog = MainStagePluginCatalog.description(named:)
        if let p = option("--port", in: args), let port = UInt16(p) { opts.port = port }
        if let s = option("--suffix", in: args) { opts.portNameSuffix = s }
        if let dir = option("--store", in: args) { opts.store = BridgeStore(directory: URL(fileURLWithPath: dir)) }
        if args.contains("--no-discovery") { opts.discoverPlugins = false }
        if args.contains("--no-meters") { opts.enableMeters = false }
        if args.contains("--fake-meters") { opts.meterSourceFactory = { FakeMeterSource() } }
        if !opts.portNameSuffix.isEmpty { opts.advertiseBonjour = false }
        let server = BridgeServer(options: opts)
        try server.start()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        var stop = false
        let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { stop = true }
            s.resume()
            return s
        }
        runMainLoop(seconds: option("--seconds", in: args).flatMap(Double.init)) { stop }
        server.stop()
        _ = sources
        print("bridge stopped")
    },
    Command(name: "monitor", usage: "<port name|all> [--suffix S] [--seconds N]   print what MainStage receives from the bridge") { args in
        lineBufferStdout()
        guard let which = positional(args).first else { throw UsageError("usage: fohctl monitor <port name|all>") }
        let suffix = option("--suffix", in: args) ?? ""
        let ports = which == "all" ? FOHPort.allCases : FOHPort.allCases.filter { $0.rawValue == which || $0.rawValue + suffix == which }
        guard !ports.isEmpty else { throw UsageError("unknown port \(which); use one of: " + FOHPort.allCases.map(\.rawValue).joined(separator: ", ")) }
        var probes: [MIDIProbe] = []
        for port in ports {
            let name = port.rawValue + suffix
            let probe = try MIDIProbe(name: "fohctl monitor")
            try probe.monitor(source: name) { status, d1, d2 in
                let ch = Int(status & 0x0F) + 1
                if status & 0xF0 == 0xB0 {
                    // Plugin ports carry plugin controls, not roles: their CCs mean nothing on their own.
                    let role = port.isPluginPort ? " (plugin control)" : Role.byCC[d1].map { " (\($0.id))" } ?? ""
                    print("\(name) ch \(ch) CC \(d1) = \(d2)\(role)")
                } else {
                    print(String(format: "%@ status=%02X d1=%d d2=%d", name, status, d1, d2))
                }
            }
            probes.append(probe)
        }
        print("monitoring \(ports.map { $0.rawValue + suffix }.joined(separator: ", "))")
        runMainLoop(seconds: option("--seconds", in: args).flatMap(Double.init))
        _ = probes
    },
    Command(name: "feedback", usage: "<port name> <ch> <cc> <value> [--suffix S]   simulate MainStage \"Send Value to\"") { args in
        let p = positional(args)
        guard p.count == 4, let ch = UInt8(p[1]), (1...16).contains(ch), let cc = UInt8(p[2]), let value = UInt8(p[3]) else {
            throw UsageError("usage: fohctl feedback <port name> <ch 1-16> <cc> <value>")
        }
        let suffix = option("--suffix", in: args) ?? ""
        let name = p[0].hasSuffix(suffix) ? p[0] : p[0] + suffix
        let probe = try MIDIProbe(name: "fohctl feedback")
        try probe.send(toDestination: name, status: 0xB0 | (ch - 1), data1: cc & 0x7F, data2: value & 0x7F)
        print("sent \(name) ch \(ch) CC \(cc) = \(value)")
        runMainLoop(seconds: 0.2)
    },
    Command(name: "osc", usage: "<path> [args: int | --s text | --i n | --f x] [--host H] [--port P] [--seconds N]   OSC client") { args in
        lineBufferStdout()
        guard let path = args.first, path.hasPrefix("/") else { throw UsageError("usage: fohctl osc <path> [args]") }
        let client = connectClient(args, name: "fohctl osc")
        client.onMessage = { print("← \(describeMessage($0))") }
        let message = OSCMessage(path, oscArguments(Array(args.dropFirst())))
        client.send(message)
        print("→ \(describeMessage(message))")
        runMainLoop(seconds: option("--seconds", in: args).flatMap(Double.init) ?? 2)
        client.cancel()
    },
    Command(name: "sync", usage: "[--host H] [--port P]   connect, sync, and summarise the bridge's state") { args in
        lineBufferStdout()
        let state = try syncBridge(args, name: "fohctl sync")
        printShowSummary(state.config)
        print("\(state.values.count) values")
        if let learn = state.learn {
            print("learn: current \(learn.current?.key ?? "—"), \(learn.learned.count) learned")
        }
        if let status = state.status {
            print("status: \(status.bridgeName); clients: \(status.clients.joined(separator: ", "))")
            for p in status.ports { print("  \(p.name): sent \(p.sent), received \(p.received)\(p.feedbackSeen ? ", feedback ✓" : "")") }
            print("  plugins: \(status.discoveredPlugins.joined(separator: ", "))")
            let input = status.inputWaitingFor.map { "waiting for \($0)" } ?? "\(status.inputDevice ?? "none") (\(status.inputChannelCount ?? 0) ch)"
            print("  meters: input \(input) · output tap \(status.outputTap ?? "off")\(status.echoRTTms.map { String(format: " · echo %.1f ms", $0) } ?? "")")
        }
    },
    Command(name: "concert", usage: "[path]   parse a .concert locally and print what the bridge would import") { args in
        let url: URL
        if let path = positional(args).first {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if let found = ConcertParser.defaultConcertURL(preferred: nil) {
            url = found
        } else {
            throw UsageError("no .concert on the Desktop; pass a path")
        }
        printConcert(try ConcertParser.parse(url))
    },
    Command(name: "merge", usage: "[path] [--host H] [--port P]   ask the bridge to import a .concert into the show") { args in
        lineBufferStdout()
        let client = connectClient(args, name: "fohctl merge")
        var config: ShowConfig?
        client.onMessage = { m in
            if m.address == FOHProtocol.Path.config { config = try? FOHProtocol.decodeJSON(ShowConfig.self, from: m) }
            printAck(m)
        }
        let path = positional(args).first.map { ($0 as NSString).expandingTildeInPath }
        client.send(OSCMessage(FOHProtocol.Path.concertMerge, path.map { [.string($0)] } ?? []))
        runMainLoop(seconds: option("--seconds", in: args).flatMap(Double.init) ?? 4)
        client.cancel()
        guard let config else { throw UsageError("the bridge sent no config back (see its log)") }
        printShowSummary(config)
    },
    Command(name: "learn", usage: "[next|skip] [--host H] [--port P]   print (or advance) the shared learn state") { args in
        lineBufferStdout()
        if let action = positional(args).first, action == "next" || action == "skip" {
            let client = connectClient(args, name: "fohctl learn")
            client.onMessage = { m in
                if m.address == FOHProtocol.Path.learnState, let s = try? FOHProtocol.decodeJSON(LearnState.self, from: m) {
                    print("← learn: current \(s.current?.key ?? "—"), \(s.learned.count) learned")
                }
            }
            if action == "next" {
                client.send(OSCMessage(FOHProtocol.Path.learnNext))
            } else {
                print("(skip is HUD-only; sending next)")
                client.send(OSCMessage(FOHProtocol.Path.learnNext))
            }
            runMainLoop(seconds: 1.5)
            client.cancel()
            return
        }
        let state = try syncBridge(args, name: "fohctl learn")
        let learn = state.learn ?? LearnState()
        let order = LearnState.order(in: state.config)
        print("current: \(learn.current.map { "\($0.key) — \(LearnState.label($0, in: state.config))" } ?? "—")")
        print("learned \(learn.learned.count) of \(order.count)")
        if let current = learn.current { print("hint: \(LearnState.hint(current, in: state.config))") }
    },
    Command(name: "config", usage: "[--out FILE] [--host H] [--port P]   fetch the bridge's show as JSON") { args in
        let state = try syncBridge(args, name: "fohctl config")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(state.config)
        if let out = option("--out", in: args) {
            try data.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        } else {
            print(String(data: data, encoding: .utf8) ?? "")
        }
    },
    Command(name: "config-set", usage: "<file.json> [--host H] [--port P]   send an edited show to the bridge (/foh/config/set)") { args in
        lineBufferStdout()
        guard let file = positional(args).first else { throw UsageError("usage: fohctl config-set <file.json>") }
        let show = try JSONDecoder().decode(ShowConfig.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let client = connectClient(args, name: "fohctl config-set")
        var config: ShowConfig?
        client.onMessage = { m in
            if m.address == FOHProtocol.Path.config { config = try? FOHProtocol.decodeJSON(ShowConfig.self, from: m) }
            printAck(m)
        }
        client.send(try FOHProtocol.jsonMessage(FOHProtocol.Path.configSet, show))
        runMainLoop(seconds: option("--seconds", in: args).flatMap(Double.init) ?? 2)
        client.cancel()
        guard let config else { throw UsageError("no config came back") }
        printShowSummary(config)
    },
] + backupCommands

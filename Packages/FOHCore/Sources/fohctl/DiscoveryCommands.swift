import Foundation
import FOHCore
import FOHMacKit

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func positional(_ args: [String]) -> [String] {
    var out: [String] = []
    var skip = false
    for a in args {
        if skip { skip = false; continue }
        if a.hasPrefix("--") { skip = !["--oop", "--steps", "--all"].contains(a); continue }
        out.append(a)
    }
    return out
}

func findComponent(_ filter: String) throws -> PluginDiscovery.ComponentInfo {
    let matches = PluginDiscovery.components(matching: filter)
    guard let first = matches.first else { throw UsageError("No Audio Unit matches \"\(filter)\" — try `fohctl plugins`") }
    if matches.count > 1 {
        print("(\(matches.count) matches; using \(first))")
    }
    return first
}

let discoveryCommands: [Command] = [
    Command(name: "plugins", usage: "[filter]          list installed effect Audio Units") { args in
        let list = PluginDiscovery.components(matching: positional(args).first)
        for c in list { print(c) }
        print("\(list.count) component(s)")
    },
    Command(name: "params", usage: "<filter> [--json FILE] [--steps] [--oop]   dump a plugin's parameters (spike S8)") { args in
        guard let filter = positional(args).first else { throw UsageError("usage: fohctl params <filter>") }
        let comp = try findComponent(filter)
        let started = Date()
        let desc = try PluginDiscovery.describe(comp.id, name: comp.name, outOfProcess: args.contains("--oop"))
        print("\(desc.manufacturerName): \(desc.name) [\(desc.component)] — \(desc.parameters.count) parameters, loaded in \(String(format: "%.2f", Date().timeIntervalSince(started)))s\n")
        for p in desc.parameters {
            let first = p.steps.first ?? "", mid = p.steps.count > 64 ? p.steps[64] : "", last = p.steps.last ?? ""
            print(String(format: "  %-28@ id=%-10@ unit=%2u %@ range %g…%g  0→\"%@\" 64→\"%@\" 127→\"%@\"%@",
                         p.name as NSString, p.id as NSString, p.unit, (p.unitName ?? "") as NSString, p.minValue, p.maxValue,
                         first as NSString, mid as NSString, last as NSString, p.displayLogarithmic ? "  [log]" : ""))
            if args.contains("--steps") { print("      " + p.steps.joined(separator: " | ")) }
        }
        if let path = option("--json", in: args) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(desc).write(to: URL(fileURLWithPath: path))
            print("\nwrote \(path)")
        }
    },
    Command(name: "bind", usage: "<filter> [--json FILE]   discover a plugin and apply its binding template") { args in
        guard let filter = positional(args).first else { throw UsageError("usage: fohctl bind <filter>") }
        let comp = try findComponent(filter)
        let desc = try PluginDiscovery.describe(comp.id, name: comp.name)
        guard let template = Templates.template(for: desc) else { throw UsageError("No template matches \(desc.name)") }
        let result = template.bind(desc, position: 1)
        print("Template \(template.name): \(result.bound.count) bound, \(result.notInPlugin.count) not in plugin\n")
        for b in result.bound.sorted(by: { $0.role.cc < $1.role.cc }) {
            print(String(format: "  CC %3d  %-22@ → %-22@ %@ … %@", b.role.cc, b.role.id as NSString, b.parameterName as NSString,
                         b.display(0) as NSString, b.display(127) as NSString))
        }
        print("\n  not in plugin: " + result.notInPlugin.map(\.id).joined(separator: ", "))
        let unused = desc.parameters.filter { p in !result.bound.contains { $0.parameterID == p.id } }
        print("\n  plugin parameters not bound (\(unused.count)): " + unused.map(\.name).joined(separator: ", "))
        if let path = option("--json", in: args) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(StripBinding(roles: Dictionary(uniqueKeysWithValues: result.bound.map { ($0.role.id, $0) }),
                                        notInPlugin: result.notInPlugin.map(\.id))).write(to: URL(fileURLWithPath: path))
            print("\nwrote \(path)")
        }
    },
    Command(name: "midi", usage: "                  list MIDI sources and destinations") { _ in
        print("Sources:")
        for e in MIDIProbe.sources() { print("  \(e)") }
        print("Destinations:")
        for e in MIDIProbe.destinations() { print("  \(e)") }
    },
    Command(name: "ports", usage: "[seconds]           create the four FOH virtual ports and hold them (spike S1)") { args in
        let seconds = Double(positional(args).first ?? "") ?? 30
        let engine = MIDIEngine(clientName: "FOH Bridge")
        try engine.start()
        for p in FOHPort.allCases {
            print("  \(p.rawValue): source uid \(engine.uniqueID(of: p)), destination uid \(engine.uniqueID(of: p, source: false))")
        }
        engine.onReceive = { msg in print("  ← \(msg)") }
        print("Holding ports for \(Int(seconds))s…")
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        engine.stop()
    },
    Command(name: "roles", usage: "                 print the role → CC table") { _ in
        for r in Role.all { print(String(format: "  CC %3d  %-20@ %@", r.cc, r.id as NSString, r.label as NSString)) }
        print("\(Role.all.count) roles")
    },
]

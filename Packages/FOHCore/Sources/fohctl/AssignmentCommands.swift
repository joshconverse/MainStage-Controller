import Foundation
import FOHCore
import FOHMacKit

// Plugin controls and the assignment export (FOHMacKit's `AssignmentExport`) for the concert writer, and the
// bridge's MainStage update.

let assignmentCommands: [Command] = [
    Command(name: "plugin-controls", usage: "[--strip in/1] [--all] [--host H] [--port P]   plugin parameters with their MIDI addresses (PLAN.md §9c)") { args in
        let state = try syncBridge(args, name: "fohctl plugin-controls")
        let only = option("--strip", in: args)
        let controls = state.config.pluginControls.filter { (args.contains("--all") || $0.active) && (only == nil || $0.strip.key == only) }
        for strip in state.config.strips where controls.contains(where: { $0.strip == strip.ref }) {
            for (position, list) in Dictionary(grouping: controls.filter { $0.strip == strip.ref }, by: \.position).sorted(by: { $0.key < $1.key }) {
                let plugin = strip.plugins.first { $0.position == position }?.name ?? "plugin \(position)"
                print("\(strip.name) › \(position). \(plugin): \(list.count) controls")
                for c in list {
                    let value = state.values[c.path].map(String.init) ?? "—"
                    let name = c.name.padding(toLength: max(28, c.name.count), withPad: " ", startingAt: 0)
                    print("    \(name) \(c.address.port.rawValue)  " + String(format: "ch %2d CC %3d", Int(c.address.channel), Int(c.address.cc))
                          + "  value \(value)" + (c.active ? "" : "  (inactive)"))
                }
            }
        }
        print("\(controls.count) plugin controls; \(state.config.pluginControls.count) addresses handed out in all")
    },
    Command(name: "assignments", usage: "[--show FILE] [--out FILE] [--suffix S] [--host H] [--port P]   every bound role's MIDI address, for the concert writer") { args in
        let show: ShowConfig
        var values: [String: Int] = [:]
        if let file = option("--show", in: args) {
            show = try JSONDecoder().decode(ShowConfig.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        } else {
            let state = try syncBridge(args, name: "fohctl assignments")
            show = state.config
            values = state.values
        }
        let suffix = option("--suffix", in: args) ?? ""
        let result = AssignmentExport(show, values: values, suffix: suffix, ports: AssignmentExport.savedPortIDs(suffix: suffix))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(result)
        if let out = option("--out", in: args) {
            try data.write(to: URL(fileURLWithPath: out))
            print("wrote \(out): \(result.rowCount) roles on \(result.strips.count) strips")
        } else {
            print(String(data: data, encoding: .utf8) ?? "")
        }
    },
    Command(name: "mainstage-update", usage: "[--host H] [--port P] [--seconds N]   ask the bridge to write its assignments into the concert (MainStage closed)") { args in
        lineBufferStdout()
        let client = connectClient(args, name: "fohctl mainstage-update")
        var answered = false
        client.onMessage = { m in
            guard m.address == FOHProtocol.Path.ack, m.arguments.first?.stringValue == FOHProtocol.Path.mainStageUpdate else { return }
            printAck(m)
            answered = true
        }
        client.send(OSCMessage(FOHProtocol.Path.mainStageUpdate, []))
        runMainLoop(seconds: option("--seconds", in: args).flatMap(Double.init) ?? 200) { answered }
        client.cancel()
        if !answered { throw UsageError("no answer from the bridge (see its log)") }
    },
]

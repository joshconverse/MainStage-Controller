import Foundation
import FOHCore
import FOHMacKit

// Backups and custom templates against a running bridge.

/// Send one request and run until a reply satisfies `done` (or the timeout). Acks are printed as they arrive.
@discardableResult
func request(_ args: [String], name: String, _ message: OSCMessage, seconds: Double = 4,
             until done: @escaping (OSCMessage) -> Bool) -> [OSCMessage] {
    let client = connectClient(args, name: name)
    var received: [OSCMessage] = []
    var finished = false
    client.onMessage = { m in
        received.append(m)
        printAck(m)
        if done(m) { finished = true }
    }
    client.send(message)
    runMainLoop(seconds: option("--seconds", in: args).flatMap(Double.init) ?? seconds) { finished }
    client.cancel()
    return received
}

func isAck(for path: String) -> (OSCMessage) -> Bool {
    { $0.address == FOHProtocol.Path.ack && $0.arguments.first?.stringValue == path }
}

let backupCommands: [Command] = [
    Command(name: "backup", usage: "list | create <reason> | restore <id> | export <file> | import <file>   [--host H] [--port P]") { args in
        lineBufferStdout()
        let p = positional(args)
        guard let action = p.first else { throw UsageError("usage: fohctl backup list|create|restore|export|import") }
        switch action {
        case "list":
            let replies = request(args, name: "fohctl backup", OSCMessage(FOHProtocol.Path.backupList)) { $0.address == FOHProtocol.Path.backups }
            guard let m = replies.last(where: { $0.address == FOHProtocol.Path.backups }),
                  let list = try? FOHProtocol.decodeJSON([BackupInfo].self, from: m) else { throw UsageError("no /foh/backups reply") }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            for b in list { print("  \(b.id)  \(f.string(from: b.date))  \(b.stripCount) strips  \(b.reason)") }
            print("\(list.count) snapshot(s)")
        case "create":
            let reason = p.dropFirst().joined(separator: " ")
            request(args, name: "fohctl backup", OSCMessage(FOHProtocol.Path.backupCreate, [.string(reason.isEmpty ? "fohctl snapshot" : reason)]),
                    until: isAck(for: FOHProtocol.Path.backupCreate))
        case "restore":
            guard p.count >= 2 else { throw UsageError("usage: fohctl backup restore <id>  (see fohctl backup list)") }
            request(args, name: "fohctl backup", OSCMessage(FOHProtocol.Path.backupRestore, [.string(p[1])]),
                    until: isAck(for: FOHProtocol.Path.backupRestore))
        case "export":
            let replies = request(args, name: "fohctl backup", OSCMessage(FOHProtocol.Path.backupExport)) { $0.address == FOHProtocol.Path.backupData }
            guard let m = replies.last(where: { $0.address == FOHProtocol.Path.backupData }), m.arguments.count >= 2,
                  let blob = m.arguments[1].blobValue else { throw UsageError("no /foh/backup/data reply") }
            let suggested = m.arguments[0].stringValue ?? "show.fohshow"
            let path = p.count >= 2 ? (p[1] as NSString).expandingTildeInPath : suggested
            try blob.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(blob.count) bytes; bridge suggested \"\(suggested)\")")
        case "import":
            guard p.count >= 2 else { throw UsageError("usage: fohctl backup import <file.fohshow>") }
            let data = try Data(contentsOf: URL(fileURLWithPath: (p[1] as NSString).expandingTildeInPath))
            request(args, name: "fohctl backup", OSCMessage(FOHProtocol.Path.backupImport, [.blob(data)]),
                    until: isAck(for: FOHProtocol.Path.backupImport))
        default:
            throw UsageError("unknown backup action \(action)")
        }
    },
    Command(name: "template", usage: "list | save <strip> <name> <processing|insert> <plugin position> | delete <id>   [--host H] [--port P]") { args in
        lineBufferStdout()
        let p = positional(args)
        guard let action = p.first else { throw UsageError("usage: fohctl template list|save|delete") }
        switch action {
        case "list":
            let state = try syncBridge(args, name: "fohctl template")
            for t in state.config.customTemplates {
                print("  \(t.id)  \"\(t.name)\"  \(t.use.rawValue)  \(t.pluginName)\(t.component.map { " [\($0)]" } ?? "")  \(t.rules.count) rules, \(t.hidden.count) hidden")
            }
            print("\(state.config.customTemplates.count) custom template(s)")
        case "save":
            guard p.count >= 5, let position = Int32(p[4]) else {
                throw UsageError("usage: fohctl template save <strip key, e.g. in/1> <name> <processing|insert> <plugin position>")
            }
            request(args, name: "fohctl template",
                    OSCMessage(FOHProtocol.Path.templateSave, [.string(p[1]), .string(p[2]), .string(p[3]), .int(position)]),
                    until: isAck(for: FOHProtocol.Path.templateSave))
        case "delete":
            guard p.count >= 2 else { throw UsageError("usage: fohctl template delete <id>  (see fohctl template list)") }
            request(args, name: "fohctl template", OSCMessage(FOHProtocol.Path.templateDelete, [.string(p[1])]),
                    until: isAck(for: FOHProtocol.Path.templateDelete))
        default:
            throw UsageError("unknown template action \(action)")
        }
    },
]

import Foundation

struct Command {
    let name: String
    let usage: String
    let run: ([String]) throws -> Void
}

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

let commands: [Command] = discoveryCommands + bridgeCommands + audioCommands + calibrateCommands + assignmentCommands

func printUsage() {
    print("fohctl — FOH Remote spike & test tool\n")
    for c in commands { print("  fohctl \(c.name) \(c.usage)") }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let name = args.first, let command = commands.first(where: { $0.name == name }) else {
    printUsage()
    exit(args.isEmpty ? 0 : 64)
}
do {
    try command.run(Array(args.dropFirst()))
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}

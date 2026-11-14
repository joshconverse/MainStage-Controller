#if os(macOS)
import Foundation
import FOHCore

// Keeping FOH Remote installed (free Personal Team signing lasts 7 days). `Tools/refresh-ipad.sh --enable` records the
// project folder and the iPad here; every 2 hours, while no client is connected, the bridge runs the script with
// `--if-due`, which decides whether to rebuild and reinstall. The bridge runs it rather than a LaunchAgent because
// macOS only lets an app with permission read the project in ~/Documents.
extension BridgeServer {
    static let iPadRefreshRepoKey = "foh.ipadRefresh.repo"
    static let iPadRefreshExpiresKey = "foh.ipadRefresh.expires"
    static let iPadRefreshResultKey = "foh.ipadRefresh.result"
    static let iPadRefreshInterval = 2 * 3600
    static let iPadRefreshTimeout: TimeInterval = 20 * 60

    /// One line for the menu: when the iPad app's signature runs out, and the last refresh result.
    public var iPadRefreshSummary: String? {
        let defaults = MIDIEngine.sharedDefaults
        guard defaults.string(forKey: Self.iPadRefreshRepoKey) != nil else { return nil }
        let expires = (defaults.object(forKey: Self.iPadRefreshExpiresKey) as? Date)
            .map { "good until " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) }
        return [expires ?? "expiry unknown", defaults.string(forKey: Self.iPadRefreshResultKey)].compactMap { $0 }.joined(separator: " · last: ")
    }

    /// From the 1 s tick: first a minute after launch, then every 2 hours.
    func iPadRefreshTick() {
        guard options.renewsIPadApp, tickCount % Self.iPadRefreshInterval == 60 else { return }
        runIPadRefresh()
    }

    func runIPadRefresh() {
        guard !iPadRefreshRunning, connections.isEmpty,
              let repo = MIDIEngine.sharedDefaults.string(forKey: Self.iPadRefreshRepoKey) else { return }
        let script = URL(fileURLWithPath: repo).appendingPathComponent("Tools/refresh-ipad.sh")
        iPadRefreshRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lines = Self.runScript(script, ["--if-due"], timeout: Self.iPadRefreshTimeout)
            DispatchQueue.main.async {
                guard let self else { return }
                self.iPadRefreshRunning = false
                lines.forEach { self.log("FOH Remote refresh: \($0)") }
                self.iPadRefreshSummaryVersion += 1
            }
        }
    }

    /// Output lines of `/bin/bash script args` (plus a line for a failure to start, a timeout or the exit status).
    private static func runScript(_ script: URL, _ arguments: [String], timeout: TimeInterval) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return ["couldn't run \(script.path): \(error.localizedDescription)"] }
        var output = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async { output = pipe.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 10)
        }
        reader.wait()
        var lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        if process.terminationReason == .uncaughtSignal { lines.append("stopped after \(Int(timeout / 60)) min") }
        else if process.terminationStatus != 0 { lines.append("exit \(process.terminationStatus)") }
        return lines
    }
}
#endif

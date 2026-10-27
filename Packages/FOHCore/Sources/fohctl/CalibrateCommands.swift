import Foundation
import FOHCore
import FOHMacKit

// Spike S5 made self-serve: send values through the running bridge, type what MainStage shows,
// and (for faders) store the readings so every fader and send scale becomes exact.

private func ask(_ prompt: String) -> String? {
    print(prompt, terminator: "")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespaces)
}

/// "−3.5", "-3.5 dB", "+6" → value; "inf", "-inf", "∞" → .some(nil) (−∞); anything else → nil.
private func parseReading(_ s: String) -> Double?? {
    let lower = s.lowercased()
    if lower.contains("inf") || lower.contains("∞") { return .some(nil) }
    if let v = DisplayValue.parse(s)?.value, v.isFinite { return .some(v) }
    return nil
}

/// Connect, sync, and return the show plus the bridge's cached role values.
private func fetchState(_ client: BridgeOSCClient) -> (ShowConfig, [String: Int])? {
    var config: ShowConfig?
    var values: [String: Int] = [:]
    var done = false
    client.onMessage = { m in
        switch m.address {
        case FOHProtocol.Path.config: config = try? FOHProtocol.decodeJSON(ShowConfig.self, from: m)
        case FOHProtocol.Path.syncDone: done = true
        default:
            if FOHProtocol.parseValuePath(m.address) != nil, let v = m.arguments.first?.intValue { values[m.address] = v }
        }
    }
    client.send(OSCMessage(FOHProtocol.Path.sync))
    runMainLoop(seconds: 5) { done }
    client.onMessage = nil
    return config.map { ($0, values) }
}

/// One short-lived connection per step: the bridge drops clients that stay silent for 10 s, and this command
/// sits silently in `readLine()` while you read MainStage, so a long-lived connection would be gone by step 2.
private func sendWire(_ args: [String], _ path: String, _ wire: Int) {
    let client = connectClient(args, name: "fohctl calibrate")
    client.send(OSCMessage(FOHProtocol.Path.learnSend, [.string(path), .int(Int32(FOHProtocol.clampMIDI(wire)))]))
    runMainLoop(seconds: 0.35)
    client.cancel()
}

private func sendOnce(_ args: [String], _ message: OSCMessage) {
    let client = connectClient(args, name: "fohctl calibrate")
    client.send(message)
    runMainLoop(seconds: 0.8)
    client.cancel()
}

let calibrateCommands: [Command] = [
    Command(name: "calibrate", usage: "fader [--strip in/1] | param [--path /foh/in/1/band/2/gain]   S5: compare/store MainStage readings") { args in
        lineBufferStdout()
        guard let mode = positional(args).first, ["fader", "param"].contains(mode) else {
            throw UsageError("usage: fohctl calibrate fader [--strip in/1]   or   fohctl calibrate param --path <value path>")
        }
        let client = connectClient(args, name: "fohctl calibrate")
        guard let (show, cached) = fetchState(client) else { client.cancel(); throw UsageError("no reply from the bridge — is FOH Bridge running?") }
        client.cancel()

        if mode == "fader" {
            let key = option("--strip", in: args) ?? "in/1"
            guard let ref = StripRef(key: key), let strip = show.strip(ref) else { throw UsageError("unknown strip \(key)") }
            let path = FOHProtocol.valuePath(ref, .fader)
            print("""
            Fader calibration for \(strip.name) (\(AddressMap.address(ref, .fader))).
            Its fader must already be learned in MainStage. After each step, type the dB MainStage shows
            for \(strip.name)'s volume ("inf" for −∞). Enter skips a step, q stops.

            """)
            var points: [CalibrationPoint] = []
            for v in [127, 115, 105, 100, 95, 90, 85, 75, 64, 45, 30, 15] {
                sendWire(args, path, v)
                let estimate = ChannelStripParameter.formatDB(ChannelStripParameter.estimatedVolumeDB(v))
                guard let answer = ask("  MIDI \(String(format: "%3d", v)) (estimate \(estimate)) → MainStage shows: "), answer != "q" else { break }
                if answer.isEmpty { continue }
                guard let reading = parseReading(answer) else { print("    couldn't read \"\(answer)\" — skipped"); continue }
                points.append(CalibrationPoint(midi: v, db: reading))
            }
            if let original = cached[path], let b = show.binding(ref)[.fader] { sendWire(args, path, b.wireValue(original)) }
            guard !points.isEmpty else { return print("\nNo readings — nothing saved.") }
            print("\n  MIDI   estimate   MainStage   difference")
            for p in points {
                let est = ChannelStripParameter.estimatedVolumeDB(p.midi)
                let measured = p.db.map { String(format: "%+6.1f dB", $0) } ?? "   -inf  "
                let diff = p.db.map { String(format: "%+5.1f", $0 - est) } ?? "  —"
                print(String(format: "  %4d   %+6.1f dB  %@   %@", p.midi, est, measured, diff))
            }
            if (ask("\nSave these readings to the bridge so every fader and send uses them? [Y/n] ") ?? "n").lowercased() != "n" {
                sendOnce(args, try FOHProtocol.jsonMessage(FOHProtocol.Path.calibrationSet, points))
                print("Saved. The iPad's fader readouts now follow MainStage.")
            }
        } else {
            let path = option("--path", in: args) ?? "/foh/in/1/band/2/gain"
            guard let (ref, role) = FOHProtocol.parseValuePath(path), let b = show.binding(ref)[role] else {
                throw UsageError("\(path) isn't a bound role on the bridge")
            }
            print("""
            Checking \(show.strip(ref)?.name ?? ref.key) › \(b.pluginName) › \(b.parameterName) (\(AddressMap.address(ref, role))).
            It must already be learned in MainStage. After each step, type the value the plugin window shows.

            """)
            var mismatches = 0, checked = 0
            for v in [0, 32, 64, 96, 127] {
                sendWire(args, path, b.wireValue(v))
                let expected = b.display(v) + (b.unitName.map { " \($0)" } ?? "")
                guard let answer = ask("  MIDI \(String(format: "%3d", v)) → expected \(expected); MainStage shows: "), answer != "q" else { break }
                if answer.isEmpty { continue }
                checked += 1
                let want = DisplayValue.parse(b.display(v))?.value
                let got = DisplayValue.parse(answer)?.value
                if let want, let got, abs(want - got) <= max(0.15, abs(want) * 0.02) {
                    print("    ✓")
                } else if want == nil && answer.lowercased() == b.display(v).lowercased() {
                    print("    ✓")
                } else {
                    mismatches += 1
                    print("    ✗ expected \(b.display(v))")
                }
            }
            if let original = cached[path] { sendWire(args, path, b.wireValue(original)) }
            print(checked == 0 ? "\nNo readings."
                  : mismatches == 0 ? "\nLinear mapping confirmed — the bridge's value table matches MainStage (S5 ✓)."
                  : "\n\(mismatches) of \(checked) readings differ — note them in SPIKES.md (S5) so the taper rule can be fixed.")
        }
    },
]

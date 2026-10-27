import Foundation
import Network
import Observation
import UIKit
import FOHCore

/// Finds FOH Bridge with Bonjour (or a manual host), speaks SLIP-framed OSC over TCP,
/// coalesces outgoing values and keeps the connection alive.
@MainActor
@Observable
final class BridgeClient {
    struct Discovered: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    enum Target: Equatable {
        case bonjour(name: String, endpoint: NWEndpoint)
        case host(String, UInt16)

        var label: String {
            switch self {
            case .bonjour(let name, _): return name
            case .host(let h, let p): return "\(h):\(p)"
            }
        }
    }

    var discovered: [Discovered] = []
    var manualHost: String = UserDefaults.standard.string(forKey: "foh.manualHost") ?? "127.0.0.1:9000" {
        didSet { UserDefaults.standard.set(manualHost, forKey: "foh.manualHost") }
    }
    /// Automatically connect to the first bridge found.
    var autoConnect = true
    private(set) var target: Target?

    @ObservationIgnored private let store: MixerStore
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var decoder = SLIP.Decoder()
    @ObservationIgnored private var pending: [String: Int] = [:]
    @ObservationIgnored private var pendingOrder: [String] = []
    @ObservationIgnored private var flushTimer: Timer?
    @ObservationIgnored private var pingTimer: Timer?
    @ObservationIgnored private var pingSeq: Int32 = 0
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var backoff: TimeInterval = 1
    @ObservationIgnored private var reconnectWork: DispatchWorkItem?
    @ObservationIgnored private var userDisconnected = false

    init(store: MixerStore) {
        self.store = store
        store.client = self
    }

    // MARK: Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: FOHProtocol.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.discovered = results.compactMap { r in
                    if case .service(let name, _, _, _) = r.endpoint { return Discovered(name: name, endpoint: r.endpoint) }
                    return nil
                }.sorted { $0.name < $1.name }
                // During a reconnect backoff, go back to the bridge we were on rather than whichever sorts first.
                if self.autoConnect, self.connection == nil, !self.userDisconnected,
                   let pick = self.discovered.first(where: { $0.name == self.target?.label }) ?? self.discovered.first {
                    self.connect(.bonjour(name: pick.name, endpoint: pick.endpoint))
                }
            }
        }
        // The browser fails for good when mDNSResponder restarts or the network goes away: start a fresh one.
        b.stateUpdateHandler = { [weak self, weak b] state in
            MainActor.assumeIsolated {
                guard let self, let b, b === self.browser, case .failed = state else { return }
                b.cancel()
                self.browser = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated { self?.startBrowsing() }
                }
            }
        }
        b.start(queue: .main)
        browser = b
        if case .demo = store.connection, autoConnect { store.connection = .searching }
    }

    // MARK: Connection

    func connectManual() {
        let parts = manualHost.split(separator: ":")
        guard let host = parts.first.map(String.init), !host.isEmpty else { return }
        let port = parts.count > 1 ? UInt16(parts[1]) ?? FOHProtocol.defaultPort : FOHProtocol.defaultPort
        connect(.host(host, port))
    }

    func connect(_ t: Target) {
        userDisconnected = false
        tearDown()
        target = t
        let endpoint: NWEndpoint
        switch t {
        case .bonjour(_, let e): endpoint = e
        case .host(let h, let p): endpoint = .hostPort(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: p) ?? 9000)
        }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = Int(Self.connectTimeout)   // fail fast and retry when the Mac is unreachable
        }
        let c = NWConnection(to: endpoint, using: params)
        connection = c
        decoder = SLIP.Decoder()
        store.connection = .connecting(t.label)
        c.stateUpdateHandler = { [weak self, weak c] state in
            MainActor.assumeIsolated {
                guard let self, let c, c === self.connection else { return }
                switch state {
                case .ready: self.didConnect()
                case .failed(let e): self.dropped("\(e.localizedDescription)")
                case .waiting(let e): self.dropped("\(e.localizedDescription)")
                case .cancelled: break
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(on: c)
        // Backstop for the TCP timeout, which doesn't cover resolving a stale Bonjour service.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout + 1) { [weak self, weak c] in
            MainActor.assumeIsolated {
                guard let self, let c, c === self.connection, case .connecting = self.store.connection else { return }
                self.dropped("timed out")
            }
        }
    }

    func disconnect() {
        userDisconnected = true
        tearDown()
        target = nil
    }

    func useDemo() {
        disconnect()
        store.loadDemo()
    }

    private func tearDown() {
        reconnectWork?.cancel()
        flushTimer?.invalidate(); flushTimer = nil
        pingTimer?.invalidate(); pingTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        pending.removeAll(); pendingOrder.removeAll()
        store.resetTouches()
    }

    private func didConnect() {
        backoff = 1
        lastHeard = Date()
        store.synced = false
        store.connection = .connected(target?.label ?? "Bridge")
        send(OSCMessage(FOHProtocol.Path.hello, [.string(UIDevice.current.name), .int(FOHProtocol.version)]))
        send(OSCMessage(FOHProtocol.Path.sync))
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNow() }
        }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ping() }
        }
    }

    private func ping() {
        if Date().timeIntervalSince(lastHeard) > Self.silenceLimit {
            dropped("no reply")
            return
        }
        pingSeq &+= 1
        send(OSCMessage(FOHProtocol.Path.ping, [.int(pingSeq)]))
    }

    // MARK: App lifecycle

    /// A link silent this long is dead. The bridge answers every ping (and streams meters), so on a LAN anything
    /// past a few seconds means the socket is gone; shorter Wi-Fi stalls shouldn't force a full re-sync.
    static let silenceLimit: TimeInterval = 5

    /// How long a connection attempt may take before it's dropped and retried.
    static let connectTimeout: TimeInterval = 4

    /// Back in the foreground. iOS suspends the app and its socket in the background, so a link that has been
    /// quiet is replaced at once instead of waiting for the ping to notice: moves made in that window used to go
    /// into a dead connection and be lost, then the reconnect's sync snapped the controls back.
    func appBecameActive() {
        guard !userDisconnected, let t = target else { return }
        guard connection == nil || Date().timeIntervalSince(lastHeard) > 1.5 else { return }
        backoff = 1
        connect(t)
    }

    /// Going to the background: send what's queued and close cleanly, so the bridge drops us now (not 10 s later)
    /// and nothing is sent into a socket iOS is about to suspend. `appBecameActive` reconnects.
    func appEnteredBackground() {
        store.resetTouches()   // iOS cancels every gesture, often without `onEnded`
        guard connection != nil, !userDisconnected else { return }
        flushNow()
        tearDown()
        store.connection = .failed("paused while FOH Remote was in the background")
        store.synced = false
    }

    private func dropped(_ why: String) {
        guard !userDisconnected else { return }
        let t = target
        tearDown()
        store.connection = .failed(why)
        store.synced = false
        store.meters?.clear()
        guard let t else { return }
        let delay = backoff
        backoff = min(backoff * 2, 10)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.userDisconnected, self.connection == nil else { return }
                self.connect(t)
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self, weak c] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let c, c === self.connection else { return }
                if let data, !data.isEmpty {
                    self.lastHeard = Date()
                    for packet in self.decoder.feed(data) {
                        guard let p = try? OSCPacket.decode(packet) else { continue }
                        for m in p.messages { self.store.handle(m) }
                    }
                }
                if let error {
                    self.dropped(error.localizedDescription)
                } else if isComplete {
                    self.dropped("closed by bridge")
                } else {
                    self.receive(on: c)
                }
            }
        }
    }

    // MARK: Sending

    /// Queue a value; the 60 Hz flush sends only the latest value per path.
    func sendValue(_ path: String, _ value: Int) {
        guard connection != nil else { return }
        if pending[path] == nil { pendingOrder.append(path) }
        pending[path] = value
    }

    func flushNow() {
        guard !pending.isEmpty, connection != nil else { return }
        let messages = pendingOrder.compactMap { p in pending[p].map { OSCPacket.message(OSCMessage(p, [.int(Int32($0))])) } }
        pending.removeAll(); pendingOrder.removeAll()
        send(messages.count == 1 ? messages[0] : .bundle(timeTag: OSCPacket.immediate, elements: messages))
    }

    func send(_ message: OSCMessage) { send(.message(message)) }

    func send(_ packet: OSCPacket) {
        guard let c = connection else { return }
        c.send(content: SLIP.encode(packet.encoded()), completion: .contentProcessed { _ in })
    }

    /// One raw wire value, not cached by the bridge (Verify's wiggle).
    func learnSend(_ path: String, wire: Int) {
        send(OSCMessage(FOHProtocol.Path.learnSend, [.string(path), .int(Int32(FOHProtocol.clampMIDI(wire)))]))
    }

    func learnFire(_ path: String) {
        send(OSCMessage(FOHProtocol.Path.learnFire, [.string(path)]))
    }

    func requestSync() {
        send(OSCMessage(FOHProtocol.Path.sync))
    }
}

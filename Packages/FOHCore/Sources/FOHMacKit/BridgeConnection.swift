#if os(macOS)
import Foundation
import Network
import FOHCore

/// One SLIP-framed OSC-over-TCP connection (an iPad, or `fohctl osc`).
/// Network callbacks run on `queue`; decoded messages are handed to the server on the main queue.
final class BridgeConnection: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    let queue: DispatchQueue
    weak var server: BridgeServer?
    /// From `/foh/hello`; main-queue only.
    var name: String?
    /// Last time anything arrived (main-queue only) — clients silent for 10 s are dropped.
    var lastActivity = Date()
    /// Strip key this client wants the RTA for (main-queue only).
    var rtaStrip: String?
    private var decoder = SLIP.Decoder()

    init(_ connection: NWConnection, server: BridgeServer, queue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    var label: String {
        if let name { return name }
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async { self.server?.connection(self, changedTo: state) }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ packet: OSCPacket) {
        connection.send(content: SLIP.encode(packet.encoded()), completion: .contentProcessed { _ in })
    }

    func send(_ message: OSCMessage) {
        send(.message(message))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var messages: [OSCMessage] = []
                for packet in self.decoder.feed(data) {
                    if let decoded = try? OSCPacket.decode(packet) { messages += decoded.messages }
                }
                DispatchQueue.main.async {
                    self.lastActivity = Date()
                    if !messages.isEmpty { self.server?.handle(messages, from: self) }
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }
}
#endif

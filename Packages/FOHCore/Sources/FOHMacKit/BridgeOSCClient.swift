#if os(macOS)
import Foundation
import Network
import FOHCore

/// Minimal SLIP/OSC-over-TCP client for `fohctl osc` / `fohctl sync` (and tests).
/// Messages and state changes are delivered on the main queue.
public final class BridgeOSCClient: @unchecked Sendable {
    public var onMessage: ((OSCMessage) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "foh.client.net")
    private var decoder = SLIP.Decoder()

    public init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any, using: .tcp)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.onState?(state) }
        }
        connection.start(queue: queue)
        receive()
    }

    public func cancel() { connection.cancel() }

    public func send(_ message: OSCMessage) { send(.message(message)) }

    public func send(_ packet: OSCPacket) {
        connection.send(content: SLIP.encode(packet.encoded()), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var messages: [OSCMessage] = []
                for packet in self.decoder.feed(data) {
                    if let decoded = try? OSCPacket.decode(packet) { messages += decoded.messages }
                }
                if !messages.isEmpty {
                    DispatchQueue.main.async { messages.forEach { self.onMessage?($0) } }
                }
            }
            if isComplete || error != nil { return }
            self.receive()
        }
    }
}
#endif

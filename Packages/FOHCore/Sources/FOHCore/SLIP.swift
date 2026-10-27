import Foundation

/// SLIP framing (RFC 1055) as used by OSC 1.1 over TCP: each packet is wrapped in END bytes.
public enum SLIP {
    static let end: UInt8 = 0xC0
    static let esc: UInt8 = 0xDB
    static let escEnd: UInt8 = 0xDC
    static let escEsc: UInt8 = 0xDD

    public static func encode(_ packet: Data) -> Data {
        var out = Data(capacity: packet.count + 8)
        out.append(end)
        for byte in packet {
            switch byte {
            case end: out.append(contentsOf: [esc, escEnd])
            case esc: out.append(contentsOf: [esc, escEsc])
            default: out.append(byte)
            }
        }
        out.append(end)
        return out
    }

    /// Largest packet the decoder keeps (the show config is a few hundred KB). A peer that streams more without
    /// an END byte has its packet dropped, so a misbehaving client can't grow the buffer without limit.
    public static let maxPacketSize = 16 << 20

    /// Streaming decoder: feed arbitrary TCP chunks, get back complete packets.
    public struct Decoder: Sendable {
        private var buffer = Data()
        private var escaping = false
        /// The current packet passed `maxPacketSize`: skip the rest of it, up to its END.
        private var discarding = false

        public init() {}

        /// Bytes held for the packet in progress.
        public var bufferedBytes: Int { buffer.count }

        public mutating func feed(_ chunk: Data) -> [Data] {
            var packets: [Data] = []
            for byte in chunk {
                if escaping {
                    escaping = false
                    switch byte {
                    case SLIP.escEnd: append(SLIP.end)
                    case SLIP.escEsc: append(SLIP.esc)
                    default: append(byte) // protocol violation; keep the byte
                    }
                    continue
                }
                switch byte {
                case SLIP.end:
                    if !buffer.isEmpty && !discarding { packets.append(buffer) }
                    buffer.removeAll(keepingCapacity: buffer.count <= 1 << 20)
                    discarding = false
                case SLIP.esc:
                    escaping = true
                default:
                    append(byte)
                }
            }
            return packets
        }

        private mutating func append(_ byte: UInt8) {
            guard !discarding else { return }
            guard buffer.count < SLIP.maxPacketSize else {
                discarding = true
                buffer.removeAll()
                return
            }
            buffer.append(byte)
        }
    }
}

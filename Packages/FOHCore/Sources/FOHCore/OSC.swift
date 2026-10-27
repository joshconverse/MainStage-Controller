import Foundation

/// Minimal OSC 1.0/1.1 codec: messages and bundles with i, f, s, b, h, d, T, F arguments.
public enum OSCArgument: Hashable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob(Data)
    case int64(Int64)
    case double(Double)
    case bool(Bool)

    var tag: Character {
        switch self {
        case .int: return "i"
        case .float: return "f"
        case .string: return "s"
        case .blob: return "b"
        case .int64: return "h"
        case .double: return "d"
        case .bool(let b): return b ? "T" : "F"
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .int64(let v): return Int(v)
        case .float(let v): return Self.integer(Double(v))
        case .double(let v): return Self.integer(v)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// Rounded and clamped to Int32's range; nil for NaN or infinity, which `Int(_:)` would trap on.
    private static func integer(_ v: Double) -> Int? {
        guard v.isFinite else { return nil }
        return Int(min(max(v.rounded(), Double(Int32.min)), Double(Int32.max)))
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var blobValue: Data? {
        if case .blob(let d) = self { return d }
        return nil
    }
}

public struct OSCMessage: Hashable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }
}

public enum OSCPacket: Hashable, Sendable {
    case message(OSCMessage)
    case bundle(timeTag: UInt64, elements: [OSCPacket])

    /// Messages in this packet, flattening bundles.
    public var messages: [OSCMessage] {
        switch self {
        case .message(let m): return [m]
        case .bundle(_, let elements): return elements.flatMap(\.messages)
        }
    }
}

public enum OSCError: Error, Equatable {
    case truncated
    case badTypeTag
    case unsupportedType(Character)
    case badString
    /// Bundles nested deeper than `OSCReader.maxBundleDepth`.
    case tooDeep
}

// MARK: - Encoding

extension OSCMessage {
    public func encoded() -> Data {
        var data = Data()
        data.appendOSCString(address)
        data.appendOSCString("," + String(arguments.map(\.tag)))
        for arg in arguments {
            switch arg {
            case .int(let v): data.appendBigEndian(UInt32(bitPattern: v))
            case .float(let v): data.appendBigEndian(v.bitPattern)
            case .string(let s): data.appendOSCString(s)
            case .blob(let b):
                data.appendBigEndian(UInt32(b.count))
                data.append(b)
                data.append(contentsOf: [UInt8](repeating: 0, count: (4 - b.count % 4) % 4))
            case .int64(let v): data.appendBigEndian(UInt64(bitPattern: v))
            case .double(let v): data.appendBigEndian(v.bitPattern)
            case .bool: break
            }
        }
        return data
    }
}

extension OSCPacket {
    /// "Immediately" time tag.
    public static let immediate: UInt64 = 1

    public func encoded() -> Data {
        switch self {
        case .message(let m):
            return m.encoded()
        case .bundle(let timeTag, let elements):
            var data = Data()
            data.appendOSCString("#bundle")
            data.appendBigEndian(timeTag)
            for e in elements {
                let body = e.encoded()
                data.appendBigEndian(UInt32(body.count))
                data.append(body)
            }
            return data
        }
    }

    /// Decode one packet. Malformed input throws; it never traps, whatever the bytes.
    public static func decode(_ data: Data) throws -> OSCPacket {
        var reader = OSCReader(data: data)
        return try reader.readPacket(length: data.count, depth: 0)
    }
}

// MARK: - Decoding

struct OSCReader {
    let data: Data
    var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var end: Int { data.endIndex }

    /// We never nest bundles; a little depth is allowed, but not enough to exhaust a background thread's stack.
    static let maxBundleDepth = 8

    mutating func readPacket(length: Int, depth: Int) throws -> OSCPacket {
        let start = offset
        let stop = start + length
        guard length >= 0, stop <= end else { throw OSCError.truncated }
        if length >= 8, data[start] == UInt8(ascii: "#") {
            guard depth < Self.maxBundleDepth else { throw OSCError.tooDeep }
            let tag = try readString()
            guard tag == "#bundle" else { throw OSCError.badString }
            let timeTag = try readUInt64()
            var elements: [OSCPacket] = []
            while offset < stop {
                let size = Int(try readUInt32())
                guard offset + size <= stop else { throw OSCError.truncated }
                elements.append(try readPacket(length: size, depth: depth + 1))
            }
            return .bundle(timeTag: timeTag, elements: elements)
        }
        let address = try readString()
        var args: [OSCArgument] = []
        if offset < stop {
            let tags = try readString()
            guard tags.first == "," else { throw OSCError.badTypeTag }
            for tag in tags.dropFirst() {
                switch tag {
                case "i": args.append(.int(Int32(bitPattern: try readUInt32())))
                case "f": args.append(.float(Float(bitPattern: try readUInt32())))
                case "s": args.append(.string(try readString()))
                case "b":
                    let size = Int(try readUInt32())
                    guard offset + size <= end else { throw OSCError.truncated }
                    args.append(.blob(data.subdata(in: offset..<(offset + size))))
                    offset = min(offset + size + (4 - size % 4) % 4, end)   // padding may be missing at the very end
                case "h": args.append(.int64(Int64(bitPattern: try readUInt64())))
                case "d": args.append(.double(Double(bitPattern: try readUInt64())))
                case "T": args.append(.bool(true))
                case "F": args.append(.bool(false))
                default: throw OSCError.unsupportedType(tag)
                }
            }
        }
        offset = max(offset, stop)
        return .message(OSCMessage(address, args))
    }

    mutating func readString() throws -> String {
        guard offset < end, let zero = data[offset..<end].firstIndex(of: 0) else { throw OSCError.truncated }
        guard let s = String(data: data[offset..<zero], encoding: .utf8) else { throw OSCError.badString }
        let consumed = zero - offset + 1
        offset += consumed + (4 - consumed % 4) % 4
        guard offset <= end else { throw OSCError.truncated }
        return s
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= end else { throw OSCError.truncated }
        let v = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return v
    }

    mutating func readUInt64() throws -> UInt64 {
        let hi = UInt64(try readUInt32())
        let lo = UInt64(try readUInt32())
        return (hi << 32) | lo
    }
}

extension Data {
    mutating func appendOSCString(_ s: String) {
        let bytes = Array(s.utf8)
        append(contentsOf: bytes)
        append(0)
        let consumed = bytes.count + 1
        append(contentsOf: [UInt8](repeating: 0, count: (4 - consumed % 4) % 4))
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

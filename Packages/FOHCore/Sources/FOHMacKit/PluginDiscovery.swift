#if os(macOS)
import AVFoundation
import AudioToolbox
import Foundation
import FOHCore

/// Loads Audio Unit plugins off-line (no audio running) to read their parameter trees —
/// names, ranges, units and display text — for the processing learn (PLAN.md §5, spike S8).
public enum PluginDiscovery {
    public struct ComponentInfo: Sendable, CustomStringConvertible {
        public let name: String
        public let manufacturerName: String
        public let id: AUComponentID
        public var description: String { "\(manufacturerName): \(name)  [\(id)]" }
    }

    public enum DiscoveryError: Error, CustomStringConvertible {
        case notFound(String)
        case noParameterTree(String)
        case timeout(String)
        case instantiation(String, Error)

        public var description: String {
            switch self {
            case .notFound(let s): return "No Audio Unit matching \(s)"
            case .noParameterTree(let s): return "\(s) exposes no parameter tree"
            case .timeout(let s): return "Timed out loading \(s)"
            case .instantiation(let s, let e): return "Couldn't load \(s): \(e)"
            }
        }
    }

    /// Effect and music-effect components installed on this Mac.
    public static func components(matching filter: String? = nil) -> [ComponentInfo] {
        let types: Set<OSType> = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        let all = AVAudioUnitComponentManager.shared().components { c, _ in
            types.contains(c.audioComponentDescription.componentType)
        }
        return all.compactMap { c -> ComponentInfo? in
            let d = c.audioComponentDescription
            let info = ComponentInfo(name: c.name, manufacturerName: c.manufacturerName,
                                     id: AUComponentID(type: FourCC.string(d.componentType), subtype: FourCC.string(d.componentSubType),
                                                       manufacturer: FourCC.string(d.componentManufacturer)))
            guard let filter, !filter.isEmpty else { return info }
            let f = filter.lowercased()
            return (info.name.lowercased().contains(f) || info.manufacturerName.lowercased().contains(f) || info.id.subtype.lowercased() == f) ? info : nil
        }
    }

    /// Instantiate the plugin and read every parameter, including display text at each of the 128 MIDI steps.
    /// On the main thread (a command-line tool) it pumps the run loop while waiting; on any other thread (the
    /// bridge's discovery thread) it blocks on a semaphore, since pumping a run loop with no sources would spin a core.
    public static func describe(_ id: AUComponentID, name: String? = nil, outOfProcess: Bool = false,
                                timeout: TimeInterval = 20) throws -> PluginDescription {
        let desc = AudioComponentDescription(componentType: FourCC.code(id.type), componentSubType: FourCC.code(id.subtype),
                                             componentManufacturer: FourCC.code(id.manufacturer), componentFlags: 0, componentFlagsMask: 0)
        let result = LockedBox<(unit: AVAudioUnit?, error: Error?)?>(nil)
        let ready = DispatchSemaphore(value: 0)
        AVAudioUnit.instantiate(with: desc, options: outOfProcess ? [.loadOutOfProcess] : []) { unit, error in
            result.write((unit, error))
            ready.signal()
        }
        if Thread.isMainThread {
            let deadline = Date().addingTimeInterval(timeout)
            while result.read() == nil && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        } else {
            _ = ready.wait(timeout: .now() + timeout)
        }
        guard let outcome = result.read() else { throw DiscoveryError.timeout(id.description) }
        if let loadError = outcome.error { throw DiscoveryError.instantiation(id.description, loadError) }
        guard let unit = outcome.unit else { throw DiscoveryError.notFound(id.description) }

        let au = unit.auAudioUnit
        guard let tree = au.parameterTree else { throw DiscoveryError.noParameterTree(id.description) }
        var groups: [AUParameterAddress: String] = [:]
        func walk(_ nodes: [AUParameterNode], _ path: [String]) {
            for node in nodes {
                if let group = node as? AUParameterGroup {
                    walk(group.children, path + [group.displayName])
                } else if let p = node as? AUParameter, !path.isEmpty {
                    groups[p.address] = path.joined(separator: " › ")
                }
            }
        }
        walk(tree.children, [])
        let params = tree.allParameters.map { describe($0, group: groups[$0.address]) }
        return PluginDescription(component: id, name: name ?? au.audioUnitName ?? id.subtype,
                                 manufacturerName: au.manufacturerName ?? id.manufacturer, parameters: params)
    }

    static func describe(_ p: AUParameter, group: String? = nil) -> PluginParameterInfo {
        let original = p.value
        var steps: [String] = []
        steps.reserveCapacity(128)
        for i in 0...127 {
            var v = p.minValue + (p.maxValue - p.minValue) * AUValue(i) / 127
            var s = p.string(fromValue: &v)
            if s.isEmpty {
                // Some AUv2 plugins only format their *current* value.
                p.value = v
                s = p.string(fromValue: nil)
            }
            steps.append(s)
        }
        p.value = original
        return PluginParameterInfo(id: p.identifier, address: p.address, name: p.displayName, unitName: p.unitName,
                                   unit: p.unit.rawValue, minValue: p.minValue, maxValue: p.maxValue, defaultValue: original,
                                   displayLogarithmic: p.flags.contains(.flag_DisplayLogarithmic), valueStrings: p.valueStrings,
                                   steps: steps, writable: p.flags.contains(.flag_IsWritable),
                                   meter: p.flags.contains(.flag_MeterReadOnly), group: group)
    }
}

public enum FourCC {
    public static func code(_ s: String) -> OSType {
        var result: OSType = 0
        for byte in s.utf8.prefix(4) { result = (result << 8) | OSType(byte) }
        return result
    }

    public static func string(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }
}
#endif

import Foundation

/// The MainStage learn walk-through, owned by the bridge and shared with every client, so the iPad screen and
/// the Mac's floating Learn HUD (with its hotkey) always agree on what's being learned (PLAN.md §7).
public struct LearnState: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
        public var strip: String
        public var role: String

        public init(strip: String, role: String) {
            self.strip = strip
            self.role = role
        }

        public init(_ strip: StripRef, _ role: Role) {
            self.init(strip: strip.key, role: role.id)
        }

        public var key: String { "\(strip)|\(role)" }
        public var stripRef: StripRef? { StripRef(key: strip) }
        public var roleValue: Role? { Role.byID[role] }
    }

    public var current: Item?
    /// Learned items as `Item.key` ("in/1|band.2.gain").
    public var learned: [String]

    public init(current: Item? = nil, learned: [String] = []) {
        self.current = current
        self.learned = learned
    }

    public func isLearned(_ item: Item) -> Bool { learned.contains(item.key) }

    /// Every bound role in walk-through order: strips in show order, roles by CC.
    public static func order(in show: ShowConfig) -> [Item] {
        show.strips.sorted { $0.ref < $1.ref }.flatMap { strip in
            show.binding(strip.ref).roles.values.map(\.role).sorted { $0.cc < $1.cc }.map { Item(strip.ref, $0) }
        }
    }

    /// The next item that isn't learned yet, after `item` (wrapping), optionally limited to one strip.
    public func next(after item: Item?, in show: ShowConfig, strip only: StripRef? = nil) -> Item? {
        let all = Self.order(in: show).filter { only == nil || $0.strip == only!.key }
        guard !all.isEmpty else { return nil }
        let start = item.flatMap { i in all.firstIndex(of: i) }.map { $0 + 1 } ?? 0
        for offset in 0..<all.count {
            let candidate = all[(start + offset) % all.count]
            if !isLearned(candidate) && candidate != item { return candidate }
        }
        return nil
    }

    /// "Lead vox › SSLChannel › LMF Gain"
    public static func label(_ item: Item, in show: ShowConfig) -> String {
        guard let ref = item.stripRef, let role = item.roleValue else { return item.key }
        let stripName = show.strip(ref)?.name ?? ref.key
        guard let b = show.binding(ref)[role] else { return "\(stripName) › \(role.label)" }
        return "\(stripName) › \(b.pluginName) › \(b.parameterName)"
    }

    /// What to click in MainStage for this item.
    public static func hint(_ item: Item, in show: ShowConfig) -> String {
        guard let ref = item.stripRef, let role = item.roleValue, let b = show.binding(ref)[role] else { return "" }
        let stripName = show.strip(ref)?.name ?? ref.key
        if b.isChannelStrip { return "Click \(b.parameterName) on \(stripName)'s channel strip" }
        if b.parameterID.hasPrefix("@plugin") { return "Click the bypass button of \(b.pluginName) on \(stripName)" }
        return "Click \(b.parameterName) in \(stripName)'s \(b.pluginName) window"
    }
}

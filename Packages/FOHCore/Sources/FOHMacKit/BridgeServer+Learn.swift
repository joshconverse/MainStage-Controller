#if os(macOS)
import Foundation
import FOHCore

// The shared MainStage learn walk-through (PLAN.md §7). The bridge owns LearnState; the iPad and the Mac's
// Learn HUD both drive it, so they always show the same item.
extension BridgeServer {
    public struct LearnProgress: Hashable, Sendable {
        public var learned: Int
        public var total: Int
    }

    /// The current item, its label, the click hint and its MIDI address — what the HUD shows.
    public struct LearnDisplay: Hashable, Sendable {
        public var item: LearnState.Item
        public var label: String
        public var hint: String
        public var portName: String
        public var channel: UInt8
        public var cc: UInt8
        public var learned: Bool
    }

    public var learnProgress: LearnProgress {
        let order = LearnState.order(in: show)
        let learnedSet = Set(learn.learned)
        return LearnProgress(learned: order.filter { learnedSet.contains($0.key) }.count, total: order.count)
    }

    public var learnDisplay: LearnDisplay? {
        guard let item = learn.current, let ref = item.stripRef, let role = item.roleValue else { return nil }
        let address = AddressMap.address(ref, role)
        return LearnDisplay(item: item, label: LearnState.label(item, in: show), hint: LearnState.hint(item, in: show),
                            portName: portName(address.port), channel: address.channel, cc: address.cc,
                            learned: learn.isLearned(item))
    }

    /// `/foh/learn/state` from a client: adopt its current item (and learned list), then broadcast the truth.
    func updateLearn(from incoming: LearnState) {
        var state = learn
        state.current = incoming.current
        var seen = Set<String>()
        state.learned = incoming.learned.filter { seen.insert($0).inserted }
        commitLearn(state)
    }

    /// Mark the current item learned and move to the next pending one.
    public func learnNext() {
        var state = learn
        if let current = state.current, !state.isLearned(current) { state.learned.append(current.key) }
        state.current = state.next(after: state.current, in: show)
        commitLearn(state)
    }

    /// Move to the next pending item without marking the current one.
    public func learnSkip() {
        var state = learn
        state.current = state.next(after: state.current, in: show)
        commitLearn(state)
    }

    /// Step back one item in walk-through order (learned or not).
    public func learnPrevious() {
        let order = LearnState.order(in: show)
        guard !order.isEmpty else { return }
        var state = learn
        let index = state.current.flatMap { order.firstIndex(of: $0) } ?? 0
        state.current = order[(index - 1 + order.count) % order.count]
        commitLearn(state)
    }

    /// Jump to a specific item (iPad list tap, HUD).
    public func learnSelect(_ item: LearnState.Item?) {
        var state = learn
        state.current = item
        commitLearn(state)
    }

    /// Start (or resume) the walk-through at the first pending item if nothing is current.
    public func learnBeginIfNeeded() {
        guard learn.current == nil else { return }
        var state = learn
        state.current = state.next(after: nil, in: show)
        commitLearn(state)
    }

    /// Forget every learned mark (after rebuilding a concert in MainStage).
    public func learnClear() {
        commitLearn(LearnState(current: LearnState().next(after: nil, in: show), learned: []))
    }

    /// Fire the learn sweep for the current item (HUD button, ⌃⌥Space).
    public func learnFireCurrent() {
        guard let item = learn.current, let ref = item.stripRef, let role = item.roleValue else {
            learnBeginIfNeeded()
            return
        }
        learnSweep(FOHProtocol.valuePath(ref, role))
    }

    func commitLearn(_ state: LearnState) {
        learn = state
        do { try options.store.saveLearn(state) } catch { log("Couldn't save learn state: \(error)") }
        if !connections.isEmpty, let m = try? FOHProtocol.jsonMessage(FOHProtocol.Path.learnState, state) {
            broadcast(.message(m))
        }
    }
}
#endif

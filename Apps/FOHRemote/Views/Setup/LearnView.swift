import SwiftUI
import FOHCore

/// MainStage learn assistant: walk through every bound role, fire the sweep, mark it learned.
struct LearnView: View {
    @Environment(MixerStore.self) private var store
    @Environment(BridgeClient.self) private var client

    var body: some View {
        let ref = store.selectedStrip
        let list = store.learnList(ref)
        let shared = store.learnState.current
        // The bridge-owned current item when it's on this strip; else the first role not learned yet.
        let current = list.first { shared?.strip == ref.key && $0.role.id == shared?.role }
            ?? list.first { !store.isLearned(ref, $0.role) } ?? list.first
        VStack(alignment: .leading, spacing: 10) {
            SetupFlowIndicator(current: 3)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    header(list)
                    stripPicker
                    if let current { hero(current, ref: ref) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                checklist(list, ref: ref, current: current)
                    .frame(width: 400)
            }
        }
    }

    /// Make `b` the shared current item (so the Mac's Learn HUD agrees) before acting on it.
    private func adopt(_ b: RoleBinding, _ ref: StripRef) {
        let item = LearnState.Item(ref, b.role)
        if store.learnState.current != item { store.setLearnCurrent(ref, b.role) }
    }

    private func header(_ list: [RoleBinding]) -> some View {
        let ref = store.selectedStrip
        let done = list.filter { store.isLearned(ref, $0.role) }.count
        return HStack(alignment: .firstTextBaseline) {
            Text("MainStage learn").font(.system(size: 22, weight: .bold))
            Text("\(done) / \(list.count) learned on this strip").foregroundStyle(Theme.text2)
            Spacer()
        }
    }

    private var stripPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.channelOrder) { s in
                    Button { store.selectedStrip = s.ref } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.channel(s.color)).frame(width: 10, height: 20)
                            Text(s.name).font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .background(store.selectedStrip == s.ref ? Theme.raised2 : Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(store.selectedStrip == s.ref ? Theme.text : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func hero(_ b: RoleBinding, ref: StripRef) -> some View {
        let addr = AddressMap.address(ref, b.role)
        let stripName = store.config.strip(ref)?.name ?? ref.key
        let path = store.path(ref, b.role)
        let portStatus = store.status?.ports.first { $0.name == addr.port.rawValue }
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Now learning")
            Text("\(ref.kind == .input ? "\(ref.slot) · " : "")\(stripName) › \(b.isChannelStrip ? "Channel strip" : b.pluginName) › \(b.parameterName)")
                .font(.system(size: 20, weight: .bold))
            HStack(spacing: 8) {
                chip(addr.port.rawValue)
                chip("Ch \(addr.channel)")
                chip("CC \(addr.cc)")
                Text(b.role.label).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Text(b.kind == .continuous ? "Continuous · sends a 0→127→0 sweep" : "Switch · learned as continuous, sends a 0→127 sweep, then 0 / 127")
                .font(.system(size: 13)).foregroundStyle(Theme.text2)
            VStack(alignment: .leading, spacing: 6) {
                step(1, "In MainStage: Assignments & Mappings (⇧⌘M) → Action menu → New Assignment → Assign & Map")
                step(2, "Tap Send sweep here — or press ⌃⌥Space on the Mac (Learn HUD)")
                step(3, b.isChannelStrip ? "Click \(b.parameterName) on \(stripName)'s channel strip" :
                        "Click \(b.parameterName) in \(stripName)'s \(b.pluginName) window")
                step(4, "Set Send Value to → \(addr.port.rawValue) so the iPad follows MainStage")
            }
            HStack(spacing: 10) {
                Button { adopt(b, ref); client.learnFire(path) } label: {
                    Text(store.connection.isConnected ? "Send sweep" : "Connect to send").font(.system(size: 17, weight: .heavy))
                        .frame(width: 220, height: 56)
                        .foregroundStyle(store.connection.isConnected ? Theme.ground : Theme.text2)
                        .background(store.connection.isConnected ? Theme.eq : Theme.raised, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!store.connection.isConnected)
                ToggleChip(title: "LEARNED → NEXT", isOn: false, color: Theme.meterGreen, height: 56) {
                    adopt(b, ref)
                    store.learnNext(markLearned: true)
                }
                .frame(width: 180)
                ToggleChip(title: "SKIP", isOn: false, color: Theme.text, height: 56) {
                    adopt(b, ref)
                    store.learnNext(markLearned: false)
                }
                .frame(width: 90)
            }
            HStack(spacing: 8) {
                Circle().fill(portStatus?.feedbackSeen == true ? Theme.meterGreen : Theme.eq).frame(width: 8, height: 8)
                Text(portStatus?.feedbackSeen == true ? "Feedback seen on \(addr.port.rawValue)" :
                        store.connection.isConnected ? "Waiting for MainStage to echo CC \(addr.cc) — set Send Value to → \(addr.port.rawValue)" :
                        "Connect to FOH Bridge to send sweeps")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.eq.opacity(0.6), lineWidth: 1.5))
    }

    private func checklist(_ list: [RoleBinding], ref: StripRef, current: RoleBinding?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("\(store.config.strip(ref)?.name ?? "") · bound roles")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(list, id: \.role.id) { b in
                        let learned = store.isLearned(ref, b.role)
                        let isNow = current?.role.id == b.role.id
                        Button { store.setLearnCurrent(ref, b.role) } label: {
                            HStack(spacing: 8) {
                                Text("CC \(b.role.cc)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.text3).frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(b.role.label).font(.system(size: 13, weight: .semibold))
                                    Text(b.isChannelStrip ? b.parameterName : "\(b.pluginName) › \(b.parameterName)")
                                        .font(.system(size: 10.5)).foregroundStyle(Theme.text2).lineLimit(1)
                                }
                                Spacer()
                                pill(learned ? "Learned" : isNow ? "Now" : "Pending",
                                     fill: learned ? Theme.meterGreen : isNow ? Theme.eq : nil)
                            }
                            .padding(.horizontal, 10).frame(minHeight: 44)
                            .background(isNow ? Theme.raised2 : Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                    let hidden = store.config.binding(ref).notInPlugin
                    if !hidden.isEmpty {
                        Text("Not in plugin (\(hidden.count)) — hidden: " + hidden.joined(separator: ", "))
                            .font(.system(size: 10.5)).foregroundStyle(Theme.text3).padding(.top, 8)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .bold).monospacedDigit())
            .padding(.horizontal, 12).frame(height: 34)
            .background(Theme.raised2, in: RoundedRectangle(cornerRadius: 8))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .heavy)).frame(width: 22, height: 22)
                .foregroundStyle(Theme.ground).background(Theme.eq, in: Circle())
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pill(_ text: String, fill: Color?) -> some View {
        Text(text).font(.system(size: 10.5, weight: .bold))
            .padding(.horizontal, 8).frame(height: 22)
            .foregroundStyle(fill == nil ? Theme.text2 : Theme.ground)
            .background(fill ?? .clear, in: Capsule())
            .overlay(Capsule().stroke(fill == nil ? Theme.line : .clear))
    }
}

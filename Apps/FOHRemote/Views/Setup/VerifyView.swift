import SwiftUI
import FOHCore

/// Step 4: for each learned role, wiggle it from here and confirm MainStage moved the right control and shows
/// the same value (PLAN.md §5 "Verify"). A failure sends you straight back to MainStage learn for that role.
struct VerifyView: View {
    @Environment(MixerStore.self) private var store
    @Environment(BridgeClient.self) private var client
    @State private var results = VerifyResults()
    @State private var selectedRole: String?
    @State private var wiggling = false

    var body: some View {
        let ref = store.selectedStrip
        let all = store.learnList(ref)
        let learned = all.filter { store.isLearned(ref, $0.role) }
        let list = learned.isEmpty ? all : learned
        let current = list.first { $0.role.id == selectedRole } ?? list.first { results.result(ref, $0.role) == nil } ?? list.first
        VStack(alignment: .leading, spacing: 10) {
            SetupFlowIndicator(current: 4)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    header(list, ref: ref, onlyLearned: !learned.isEmpty)
                    stripPicker
                    if let current { card(current, ref: ref, list: list) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                checklist(list, ref: ref, current: current)
                    .frame(width: 400)
            }
        }
    }

    private func header(_ list: [RoleBinding], ref: StripRef, onlyLearned: Bool) -> some View {
        let passed = list.filter { results.result(ref, $0.role) == true }.count
        let failed = list.filter { results.result(ref, $0.role) == false }.count
        return HStack(alignment: .firstTextBaseline) {
            Text("Verify").font(.system(size: 22, weight: .bold))
            Text("\(passed) / \(list.count) verified\(failed > 0 ? " · \(failed) to re-learn" : "")\(onlyLearned ? "" : " · nothing learned yet on this strip")")
                .foregroundStyle(Theme.text2)
            Spacer()
        }
    }

    private var stripPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.channelOrder) { s in
                    Button { store.selectedStrip = s.ref; selectedRole = nil } label: {
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

    private func card(_ b: RoleBinding, ref: StripRef, list: [RoleBinding]) -> some View {
        let addr = AddressMap.address(ref, b.role)
        let stripName = store.config.strip(ref)?.name ?? ref.key
        let unit = b.unitName.map { " \($0)" } ?? ""
        let connected = store.connection.isConnected
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Checking")
            Text("\(stripName) › \(b.isChannelStrip ? "Channel strip" : b.pluginName) › \(b.parameterName)")
                .font(.system(size: 20, weight: .bold))
            HStack(spacing: 8) {
                chip(addr.port.rawValue)
                chip("Ch \(addr.channel)")
                chip("CC \(addr.cc)")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1  Tap Wiggle — the control moves up, down and back in MainStage.").font(.system(size: 13))
                Text("2  Check it's \(b.isChannelStrip ? "\(stripName)'s \(b.parameterName.lowercased())" : "\(b.parameterName) in \(b.pluginName)") that moved,")
                    .font(.system(size: 13))
                HStack(spacing: 6) {
                    Text("    and that MainStage shows").font(.system(size: 13))
                    Text(store.display(ref, b.role) + unit).font(.system(size: 15, weight: .heavy).monospacedDigit())
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(Theme.raised2, in: RoundedRectangle(cornerRadius: 6))
                    Text("now.").font(.system(size: 13))
                }
            }
            .foregroundStyle(Theme.text)
            HStack(spacing: 10) {
                Button { wiggle(b, ref: ref) } label: {
                    Text(connected ? (wiggling ? "Wiggling…" : "Wiggle") : "Connect to wiggle")
                        .font(.system(size: 17, weight: .heavy))
                        .frame(width: 200, height: 56)
                        .foregroundStyle(connected ? Theme.ground : Theme.text2)
                        .background(connected ? Theme.eq : Theme.raised, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!connected || wiggling)
                ToggleChip(title: "✓ MOVED & MATCHES", isOn: false, color: Theme.meterGreen, height: 56) {
                    results.set(ref, b.role, passed: true)
                    advance(after: b, ref: ref, list: list)
                }
                .frame(width: 200)
                ToggleChip(title: "✗ WRONG", isOn: false, color: Theme.mute, height: 56) {
                    results.set(ref, b.role, passed: false)
                }
                .frame(width: 120)
            }
            if results.result(ref, b.role) == false {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.eq)
                    Text("Wrong control or value? Re-learn it: delete the assignment in MainStage, then Assign & Map again.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    Spacer()
                    ToggleChip(title: "RE-LEARN →", isOn: false, color: Theme.eq, height: 44) {
                        store.setLearnCurrent(ref, b.role)
                        store.setupSection = .learn
                    }
                    .frame(width: 140)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.meterGreen.opacity(0.5), lineWidth: 1.5))
    }

    /// Up, down, back — around the current value, so it's visible but leaves the mix where it was.
    private func wiggle(_ b: RoleBinding, ref: StripRef) {
        let path = store.path(ref, b.role)
        let value = store.value(ref, b.role)
        let isSwitch = b.kind == .toggle || b.stepCenters.count == 2
        let sequence = isSwitch ? [value >= 64 ? 0 : 127, value] : [min(127, value + 20), max(0, value - 20), value]
        wiggling = true
        Task { @MainActor in
            for v in sequence {
                client.learnSend(path, wire: b.wireValue(v))
                try? await Task.sleep(for: .milliseconds(isSwitch ? 600 : 350))
            }
            wiggling = false
        }
    }

    private func advance(after b: RoleBinding, ref: StripRef, list: [RoleBinding]) {
        guard let i = list.firstIndex(where: { $0.role.id == b.role.id }) else { return }
        let rest = list[(i + 1)...] + list[..<i]
        selectedRole = rest.first { results.result(ref, $0.role) == nil }?.role.id ?? b.role.id
    }

    private func checklist(_ list: [RoleBinding], ref: StripRef, current: RoleBinding?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("\(store.config.strip(ref)?.name ?? "") · learned roles")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(list, id: \.role.id) { b in
                        let result = results.result(ref, b.role)
                        let isNow = current?.role.id == b.role.id
                        Button { selectedRole = b.role.id } label: {
                            HStack(spacing: 8) {
                                Text("CC \(b.role.cc)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.text3).frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(b.role.label).font(.system(size: 13, weight: .semibold))
                                    Text(b.isChannelStrip ? b.parameterName : "\(b.pluginName) › \(b.parameterName)")
                                        .font(.system(size: 10.5)).foregroundStyle(Theme.text2).lineLimit(1)
                                }
                                Spacer()
                                pill(result == true ? "Verified" : result == false ? "Re-learn" : isNow ? "Now" : "Pending",
                                     fill: result == true ? Theme.meterGreen : result == false ? Theme.mute : isNow ? Theme.eq : nil)
                            }
                            .padding(.horizontal, 10).frame(minHeight: 44)
                            .background(isNow ? Theme.raised2 : Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
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

    private func pill(_ text: String, fill: Color?) -> some View {
        Text(text).font(.system(size: 10.5, weight: .bold))
            .padding(.horizontal, 8).frame(height: 22)
            .foregroundStyle(fill == nil ? Theme.text2 : Theme.ground)
            .background(fill ?? .clear, in: Capsule())
            .overlay(Capsule().stroke(fill == nil ? Theme.line : .clear))
    }
}

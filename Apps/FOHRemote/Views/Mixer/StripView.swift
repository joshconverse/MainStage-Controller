import SwiftUI
import FOHCore

/// One 64 pt mixer strip.
struct StripView: View {
    @Environment(MixerStore.self) private var store
    let strip: Strip

    private var ref: StripRef { strip.ref }
    private var sofRole: Role? { store.sendsOnFaders.flatMap { Role.send($0, "level") } }
    private var faderRole: Role { sofRole ?? .fader }
    private var isSelected: Bool { store.selectedStrip == ref }

    static func faderText(_ display: String) -> String {
        display.replacingOccurrences(of: " dB", with: "").replacingOccurrences(of: "-inf", with: "−∞").replacingOccurrences(of: "-", with: "−")
    }

    var body: some View {
        VStack(spacing: 4) {
            nameTag
            Button { store.open(ref, section: .eq) } label: {
                MiniEQView(bands: store.eqBands(ref), engaged: store.eqEngaged(ref), source: store.eqSourceLabel(strip))
                    .frame(height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(strip.name) EQ")
            HStack(spacing: 3) {
                badge("G", lit: gateLit)
                badge("C", lit: compLit)
            }
            Button { store.open(ref, section: .inserts) } label: {
                Text(insertsText)
                    .font(.system(size: 9.5, weight: .heavy))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 18)
                    .foregroundStyle(insertsText == "—" ? Theme.text3 : Color(hex: 0xC4B5FD))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(insertsText == "—" ? Theme.line : Theme.inserts))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(strip.name) inserts")
            PanBar(value: store.value(ref, .pan), label: panText,
                   onChange: { store.set(ref, .pan, $0) },
                   onTouch: { $0 ? store.beginTouch(ref, .pan) : store.endTouch(ref, .pan) })
                .padding(.top, 2)
                .opacity(store.isBound(ref, .pan) ? 1 : 0.3)
            ToggleChip(title: "MUTE", isOn: store.isOn(ref, .mute), color: Theme.mute) { store.toggle(ref, .mute) }
                .padding(.top, 2)
                .accessibilityLabel("\(strip.name) mute")
                .accessibilityIdentifier("mute.\(ref.key)")
            if ref.kind != .master {
                ToggleChip(title: "SOLO", isOn: store.isOn(ref, .solo), color: Theme.solo) { store.toggle(ref, .solo) }
                    .accessibilityLabel("\(strip.name) solo")
                    .accessibilityIdentifier("solo.\(ref.key)")
            }
            FaderControl(value: store.value(ref, faderRole), capColor: sofRole == nil ? Theme.faderCap : Theme.sends,
                         meter: .strip(strip), fine: store.fineMode, resetValue: store.zeroValue(ref, faderRole) ?? 90,
                         onChange: { store.set(ref, faderRole, $0) },
                         onTouch: { $0 ? store.beginTouch(ref, faderRole) : store.endTouch(ref, faderRole) })
                .id(faderRole)   // sends-on-faders flipping mid-drag gets a fresh fader, not the old role's start
                .padding(.top, 6)
                .accessibilityLabel("\(strip.name) fader")
                .accessibilityIdentifier("fader.\(ref.key)")
                .accessibilityValue(store.display(ref, faderRole))
            AssumedText(text: Self.faderText(store.display(ref, faderRole)), assumed: store.isAssumed(ref, faderRole),
                        font: .system(size: 12, weight: .semibold).monospacedDigit(),
                        color: sofRole != nil ? Color(hex: 0x5EEAD4) : (store.isOn(ref, .mute) ? Theme.text3 : Theme.text))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .frame(width: 64)
        .background(isSelected ? Theme.raised : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Theme.text : .clear, lineWidth: 2))
    }

    private var nameTag: some View {
        Button { store.open(ref, section: .eq) } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(ref.kind == .input ? "\(ref.slot)" : ref.kind == .fx ? "FX \(ref.slot)" : "OUT \(ref.slot)")
                    Spacer()
                    if strip.stereo { Text("ST") }
                }
                .font(.system(size: 9.5, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(0.8)
                Text(strip.name)
                    .font(.system(size: strip.name.count > 9 ? 10.5 : 12, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .foregroundStyle(Theme.channelText(strip.color))
            .background(Theme.channel(strip.color), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(strip.name)")
    }

    private func badge(_ letter: String, lit: Bool) -> some View {
        Button { store.open(ref, section: .dynamics) } label: {
            Text(letter).font(.system(size: 10, weight: .heavy))
                .frame(maxWidth: .infinity, minHeight: 20)
                .foregroundStyle(lit ? Theme.ground : Theme.text3)
                .background(lit ? Theme.dynamics : Theme.raised, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var dynOn: Bool { store.isBound(ref, .dynOn) && store.isOn(ref, .dynOn) }
    private var compLit: Bool { dynOn && (Role["comp.thresh"].map { store.isBound(ref, $0) } ?? false) }
    private var gateLit: Bool {
        guard dynOn, let thr = Role["gate.thresh"], let range = Role["gate.range"], store.isBound(ref, thr) else { return false }
        // Lit when the expander/gate actually does something (range above 0).
        return (store.numeric(ref, range) ?? 1) > 0.05
    }

    private var insertsText: String {
        let pages = strip.processing.insertPages.sorted { $0.key < $1.key }.compactMap { strip.plugin(at: $0.value) }
        let processing = Set([strip.processing.eq, strip.processing.dynamics, strip.processing.trim].compactMap { $0 })
        let others = pages.isEmpty ? strip.plugins.filter { !processing.contains($0.position) && !["Gain", "MultiMeter"].contains($0.name) } : pages
        guard let first = others.first else { return "—" }
        return MixerStore.abbreviate(first.name) + (others.count > 1 ? " +\(others.count - 1)" : "")
    }

    private var panText: String {
        let v = store.value(ref, .pan)
        return v == 64 ? "C" : (v < 64 ? "L\(64 - v)" : "R\(v - 64)")
    }
}

import SwiftUI
import FOHCore

struct DynamicsView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        let ref = store.selectedStrip
        let dynOn = store.isBound(ref, .dynOn) ? store.isOn(ref, .dynOn) : true
        let hasComp = Role["comp.thresh"].map { store.isBound(ref, $0) } ?? false
        let hasGate = Role["gate.thresh"].map { store.isBound(ref, $0) } ?? false
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                SourceLine(label: "Dynamics source:", plugin: store.selected?.plugin(at: store.selected?.processing.dynamics))
                Spacer()
                RoleToggle(strip: ref, role: .dynOn, title: "DYN IN", color: Theme.dynamics).frame(width: 96)
            }
            if !hasComp && !hasGate {
                UnboundPanel(text: "No dynamics bound on this strip.")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    if hasComp { CompressorPanel(strip: ref).opacity(dynOn ? 1 : 0.4) }
                    if hasGate { ExpanderPanel(strip: ref).opacity(dynOn ? 1 : 0.4) }
                    DynamicsMeterColumn(strip: ref).frame(width: 120)
                }
            }
        }
    }
}

/// Picks a knob or a switch based on how the role is bound (SSL "Fast Atk" is a switch on `comp.attack`).
struct DynControl: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef
    let roleID: String
    let title: String

    var body: some View {
        if let role = Role[roleID], let b = store.binding(strip, role) {
            if b.behavesAsToggle {
                VStack(spacing: 4) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                    ToggleChip(title: b.display(store.value(strip, role)).uppercased(), isOn: store.isOn(strip, role), color: Theme.dynamics) {
                        store.toggle(strip, role)
                    }
                    .frame(width: 84)
                    Text("\(b.parameterName) · CC \(role.cc)").font(.system(size: 9.5)).foregroundStyle(Theme.text3)
                }
            } else {
                RoleKnob(strip: strip, role: role, title: title, color: Theme.dynamics, size: 62)
            }
        }
    }
}

struct TransferGraph: View {
    var transfer: (Double) -> Double
    var threshold: Double?
    var liveInput: Double = -14

    var body: some View {
        Canvas { ctx, size in
            let grid = Color(hex: 0x1E2126)
            for db in stride(from: -54.0, through: -6, by: 6) {
                let a = DynamicsMath.point(db, DynamicsMath.minDB, size), b = DynamicsMath.point(db, DynamicsMath.maxDB, size)
                ctx.stroke(Path { p in p.move(to: CGPoint(x: a.x, y: 0)); p.addLine(to: CGPoint(x: b.x, y: size.height)) }, with: .color(grid))
                let y = DynamicsMath.point(DynamicsMath.minDB, db, size).y
                ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(grid))
            }
            ctx.stroke(DynamicsMath.path(size: size) { $0 }, with: .color(Theme.line), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            if let t = threshold {
                let x = DynamicsMath.point(t, 0, size).x
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(Theme.dynamics.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            ctx.stroke(DynamicsMath.path(size: size, transfer), with: .color(Theme.dynamics), lineWidth: 2.5)
            let p = DynamicsMath.point(liveInput, transfer(liveInput), size)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(Theme.text))
            ctx.draw(Text("−60").font(.system(size: 9)).foregroundColor(Theme.text3), at: CGPoint(x: 4, y: size.height - 8), anchor: .leading)
            ctx.draw(Text("0 dBFS").font(.system(size: 9)).foregroundColor(Theme.text3), at: CGPoint(x: size.width - 4, y: size.height - 8), anchor: .trailing)
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Theme.ground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct CompressorPanel: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef

    var body: some View {
        let thr = Role["comp.thresh"].flatMap { store.numeric(strip, $0) } ?? -18
        let ratio = Role["comp.ratio"].flatMap { store.numeric(strip, $0) } ?? 3
        VStack(alignment: .leading, spacing: 12) {
            Text("COMPRESSOR").font(.system(size: 12, weight: .heavy)).tracking(1)
            TransferGraph(transfer: { DynamicsMath.compressor($0, threshold: thr, ratio: ratio, knee: 2) }, threshold: thr)
                .frame(maxWidth: 340)
            HStack(alignment: .top, spacing: 6) {
                DynControl(strip: strip, roleID: "comp.thresh", title: "Threshold")
                DynControl(strip: strip, roleID: "comp.ratio", title: "Ratio")
                DynControl(strip: strip, roleID: "comp.release", title: "Release")
            }
            HStack(alignment: .top, spacing: 6) {
                DynControl(strip: strip, roleID: "comp.attack", title: "Fast attack")
                DynControl(strip: strip, roleID: "comp.makeup", title: "Makeup")
                DynControl(strip: strip, roleID: "comp.knee", title: "Knee")
                DynControl(strip: strip, roleID: "comp.mix", title: "Mix")
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ExpanderPanel: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef

    var body: some View {
        let thr = Role["gate.thresh"].flatMap { store.numeric(strip, $0) } ?? -50
        let range = abs(Role["gate.range"].flatMap { store.numeric(strip, $0) } ?? 20)
        let gate = Role["gate.mode"].map { store.isBound(strip, $0) && store.isOn(strip, $0) } ?? false
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("EXPANDER / GATE").font(.system(size: 12, weight: .heavy)).tracking(1)
                Spacer()
                if let mode = Role["gate.mode"] { RoleSegmented(strip: strip, role: mode, color: Theme.dynamics).frame(width: 160) }
            }
            TransferGraph(transfer: { DynamicsMath.expander($0, threshold: thr, range: range, gate: gate) }, threshold: thr)
                .frame(maxWidth: 340)
            HStack(alignment: .top, spacing: 6) {
                DynControl(strip: strip, roleID: "gate.thresh", title: "Threshold")
                DynControl(strip: strip, roleID: "gate.range", title: "Range")
                DynControl(strip: strip, roleID: "gate.release", title: "Release")
                DynControl(strip: strip, roleID: "gate.hold", title: "Hold")
            }
            HStack(alignment: .top, spacing: 6) {
                DynControl(strip: strip, roleID: "gate.attack", title: "Fast attack")
                DynControl(strip: strip, roleID: "dyn.filtersToSC", title: "Filters → SC")
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DynamicsMeterColumn: View {
    @Environment(MixerStore.self) private var store
    let strip: StripRef

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(spacing: 4) {
                    Group {
                        if let s = store.config.strip(strip) { LiveMeter(target: .strip(s), barWidth: 14) } else { LiveMeter(target: .master, barWidth: 14) }
                    }
                    .frame(height: 260)
                    Text("IN").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
                }
                EstimatedGRMeter(strip: strip)
            }
            Text("≈ GR is estimated from the input level and the comp settings — MainStage doesn't report gain reduction.")
                .font(.system(size: 10)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
            RoleKnob(strip: strip, role: .trimOut, title: "Output trim", color: Theme.dynamics, size: 54)
            Spacer()
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Gain reduction estimated from the live input peak: (in − threshold) × (1 − 1/ratio) above threshold.
struct EstimatedGRMeter: View {
    @Environment(MixerStore.self) private var store
    @Environment(MeterStore.self) private var meters
    let strip: StripRef
    private let rangeDB = 20.0

    var body: some View {
        let gr = estimate()
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .top) {
                    Color(hex: 0x101215)
                    Theme.dynamics.frame(height: g.size.height * CGFloat(min(gr, rangeDB) / rangeDB))
                }
            }
            .frame(width: 14, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("≈ GR").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
            Text(gr > 0.05 ? String(format: "−%.1f", gr) : "0.0").font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.dynamics)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated gain reduction")
        .accessibilityValue(String(format: "%.1f dB", gr))
    }

    private func estimate() -> Double {
        guard store.isBound(strip, .dynOn) ? store.isOn(strip, .dynOn) : true,
              let s = store.config.strip(strip), let inDB = meters.peakDB(for: s),
              let thrRole = Role["comp.thresh"], let ratioRole = Role["comp.ratio"],
              let thr = store.numeric(strip, thrRole) else { return 0 }
        let ratio = store.numeric(strip, ratioRole) ?? 1
        guard inDB > thr, ratio > 1 else { return 0 }
        return (inDB - thr) * (ratio.isFinite ? 1 - 1 / ratio : 1)
    }
}

import SwiftUI
import FOHCore

/// Setup › Channels & I/O: the strips and sends the user has configured, with concert import.
struct ChannelsView: View {
    enum Selection: Hashable {
        case strip(StripRef)
        case send(Int)
    }

    @Environment(MixerStore.self) private var store
    @State private var selection: Selection?
    @State private var dragging: StripRef?

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            SetupFlowIndicator(current: 1)
            header
            HStack(alignment: .top, spacing: 10) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        stripGroup("Inputs", kind: .input, add: "Add input")
                        stripGroup("FX returns", kind: .fx, add: "Add FX return")
                        sendsGroup
                        stripGroup("Outputs", kind: .output, add: "Add output")
                        stripGroup("Master", kind: .master, add: store.master == nil ? "Add master" : nil)
                    }
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
                Group {
                    switch currentSelection {
                    case .strip(let ref):
                        if let s = store.config.strip(ref) { StripEditPanel(strip: s).id(ref) } else { emptyPanel }
                    case .send(let i):
                        if let bus = store.config.sends.first(where: { $0.index == i }) { SendEditPanel(bus: bus).id(i) } else { emptyPanel }
                    case nil:
                        emptyPanel
                    }
                }
                .frame(width: 380)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var currentSelection: Selection? {
        selection ?? (store.config.strip(store.selectedStrip) != nil ? .strip(store.selectedStrip) : nil)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Channels & I/O").font(.system(size: 22, weight: .bold))
                Text(summary).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if store.scanningConcert { ProgressView().tint(Theme.sends) }
            ToggleChip(title: "IMPORT FROM CONCERT", isOn: true, color: Theme.sends) { store.scanConcert() }
                .frame(width: 210)
                .disabled(!store.isDemo && !store.connection.isConnected)
        }
    }

    private var summary: String {
        let c = store.config
        let counts = "\(store.inputs.count) inputs · \(store.fxReturns.count) FX returns · \(store.outputs.count) outputs · \(c.sends.count) sends"
        return "Show “\(c.name)” · " + counts + (c.concertPath.map { " · from \(($0 as NSString).lastPathComponent)" } ?? "")
    }

    private var emptyPanel: some View {
        Text("Select a channel or send to edit it.")
            .foregroundStyle(Theme.text2)
            .frame(maxWidth: .infinity, minHeight: 200)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func stripGroup(_ title: String, kind: StripKind, add: String?) -> some View {
        let strips = store.config.ordered(kind)
        let reorder = store.channelsReorder && strips.count > 1
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionLabel("\(title) · \(strips.count)")
                Spacer()
                if strips.count > 1 {
                    Button { store.channelsReorder.toggle() } label: {
                        Label(store.channelsReorder ? "Done" : "Reorder", systemImage: store.channelsReorder ? "checkmark" : "arrow.up.arrow.down")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(store.channelsReorder ? Theme.ground : Theme.text2)
                            .padding(.horizontal, 10).frame(minHeight: 30)
                            .background(store.channelsReorder ? Theme.sends : Theme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.channelsReorder ? "Done reordering" : "Reorder \(title.lowercased())")
                }
            }
            if reorder {
                Text("Drag ≡ or use the arrows. Order is visual only — every strip keeps its slot and MIDI address, so nothing needs re-learning in MainStage.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(strips.enumerated()), id: \.element.id) { index, s in
                HStack(spacing: 6) {
                    if reorder { reorderControls(s, index: index, count: strips.count) }
                    StripConfigRow(strip: s, selected: currentSelection == .strip(s.ref)) {
                        selection = .strip(s.ref)
                        store.selectedStrip = s.ref
                    }
                }
                .onDrop(of: [.text], delegate: StripDropDelegate(target: s.ref, index: index, dragging: $dragging, store: store))
            }
            if let add, store.config.nextFreeSlot(kind) != nil {
                AddRowButton(title: add) {
                    if let ref = store.addStrip(kind) { selection = .strip(ref) }
                }
            }
        }
    }

    /// Drag handle plus up/down buttons (VoiceOver, UI tests, and anyone who'd rather tap).
    private func reorderControls(_ s: Strip, index: Int, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .frame(width: 36, height: 60)
                .contentShape(Rectangle())
                .onDrag {
                    dragging = s.ref
                    return NSItemProvider(object: s.ref.key as NSString)
                }
                .accessibilityHidden(true)
            Button { store.moveStrip(s.ref, by: -1) } label: {
                Image(systemName: "chevron.up").frame(width: 44, height: 44).background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .opacity(index == 0 ? 0.35 : 1)
            .accessibilityLabel("Move \(s.name) up")
            Button { store.moveStrip(s.ref, by: 1) } label: {
                Image(systemName: "chevron.down").frame(width: 44, height: 44).background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(index == count - 1)
            .opacity(index == count - 1 ? 0.35 : 1)
            .accessibilityLabel("Move \(s.name) down")
        }
        .foregroundStyle(Theme.text)
    }

    private var sendsGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Buses / sends · \(store.config.sends.count)")
            ForEach(store.config.sends) { bus in
                Button { selection = .send(bus.index) } label: {
                    HStack(spacing: 12) {
                        Text("S\(bus.index)").font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.ground)
                            .frame(width: 30, height: 30).background(Theme.sends, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bus.name).font(.system(size: 14, weight: .semibold))
                            Text(bus.busNumber.map { "MainStage Bus \($0)" } ?? "No bus set").font(.system(size: 11)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        ConcertTag(inConcert: bus.existsInConcert, yes: "in concert", no: "not in concert yet")
                        Text("CC \(Role.send(bus.index, "level")?.cc ?? 0) / \(Role.send(bus.index, "on")?.cc ?? 0)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text3)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 56)
                    .background(currentSelection == .send(bus.index) ? Theme.raised2 : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(currentSelection == .send(bus.index) ? Theme.text : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            if store.config.sends.count < 8 {
                AddRowButton(title: "Add send") { if let i = store.addSend() { selection = .send(i) } }
            }
        }
    }
}

/// Live reordering while dragging a strip's handle over its siblings (same kind only).
@MainActor
struct StripDropDelegate: DropDelegate {
    let target: StripRef
    let index: Int
    @Binding var dragging: StripRef?
    let store: MixerStore

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target, d.kind == target.kind else { return }
        store.moveStrip(d, to: index)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// One strip in the Channels & I/O list.
struct StripConfigRow: View {
    let strip: Strip
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.channel(strip.color)).frame(width: 10, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(strip.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(typeText).font(.system(size: 11)).foregroundStyle(Theme.text2)
                }
                .frame(width: 130, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(strip.mainStage?.stripName ?? "— not linked").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let link = strip.mainStage {
                        ConcertTag(inConcert: link.level == .concert, yes: "concert", no: "patch: \(link.patchName ?? "?")")
                    }
                }
                .frame(width: 130, alignment: .leading)
                Text(strip.hardwareIO ?? "—").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(strip.hardwareIO == nil ? Theme.text3 : Theme.text).frame(width: 64, alignment: .leading)
                Text(Self.processingSummary(strip)).font(.system(size: 11)).foregroundStyle(Theme.text2)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(strip.ref.port.rawValue) · ch \(strip.ref.channel)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text3)
                    .fixedSize()
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 60)
            .background(selected ? Theme.raised2 : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.text : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(strip.name), \(typeText)")
    }

    private var typeText: String {
        switch strip.ref.kind {
        case .input: return "Input \(strip.ref.slot) · \(strip.stereo ? "stereo" : "mono")"
        case .fx: return "FX return \(strip.ref.slot)"
        case .output: return "Output \(strip.ref.slot)\(strip.stereo ? " · stereo" : "")"
        case .master: return "Master"
        }
    }

    /// "SSLChannel → EQ · Dyn · Trim · + Waves Tune, Pro-Q 3"
    static func processingSummary(_ s: Strip) -> String {
        var parts: [String] = []
        let p = s.processing
        var byPlugin: [Int: [String]] = [:]
        if let e = p.eq { byPlugin[e, default: []].append("EQ") }
        if let d = p.dynamics { byPlugin[d, default: []].append("Dyn") }
        if let t = p.trim { byPlugin[t, default: []].append("Trim") }
        for (pos, roles) in byPlugin.sorted(by: { $0.key < $1.key }) {
            parts.append("\(s.plugin(at: pos)?.name ?? "plugin \(pos)") → " + roles.joined(separator: " · "))
        }
        let pages = p.insertPages.sorted { $0.key < $1.key }.compactMap { s.plugin(at: $0.value)?.name }
        if !pages.isEmpty { parts.append("+ " + pages.joined(separator: ", ")) }
        if parts.isEmpty { return s.plugins.isEmpty ? "No plugins" : s.plugins.map(\.name).joined(separator: ", ") }
        return parts.joined(separator: "  ")
    }
}

struct ConcertTag: View {
    let inConcert: Bool
    let yes: String
    let no: String

    var body: some View {
        Text(inConcert ? yes : no)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).frame(height: 18)
            .foregroundStyle(inConcert ? Theme.meterGreen : Theme.eq)
            .background((inConcert ? Theme.meterGreen : Theme.eq).opacity(0.12), in: Capsule())
    }
}

struct AddRowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(.plain)
    }
}

/// Right-hand editor for one strip. Edits a draft; Save applies it through `/foh/config/set`.
struct StripEditPanel: View {
    @Environment(MixerStore.self) private var store
    let strip: Strip
    @State private var draft: Strip
    @State private var confirmRemove = false

    init(strip: Strip) {
        self.strip = strip
        _draft = State(initialValue: strip)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Edit · \(strip.name)").font(.system(size: 17, weight: .bold))
                field("Name", text: $draft.name)
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Colour")
                    HStack(spacing: 6) {
                        ForEach(ChannelColor.allCases, id: \.self) { c in
                            Button { draft.color = c } label: {
                                RoundedRectangle(cornerRadius: 6).fill(Theme.channel(c))
                                    .frame(width: 36, height: 36)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(draft.color == c ? Theme.text : .clear, lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.rawValue)
                            .accessibilityAddTraits(draft.color == c ? .isSelected : [])
                        }
                    }
                }
                if strip.ref.kind == .input || strip.ref.kind == .fx || strip.ref.kind == .output {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Type")
                        HStack(spacing: 6) {
                            ToggleChip(title: "MONO", isOn: !draft.stereo, color: Theme.text) { draft.stereo = false }
                            ToggleChip(title: "STEREO", isOn: draft.stereo, color: Theme.text) { draft.stereo = true }
                        }
                    }
                }
                field("MainStage strip", text: Binding(
                    get: { draft.mainStage?.stripName ?? "" },
                    set: { name in
                        if draft.mainStage == nil { draft.mainStage = MainStageLink(stripName: name, level: .concert) } else { draft.mainStage?.stripName = name }
                    }))
                if let link = draft.mainStage, link.level == .patch {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.eq)
                        Text("This strip lives in the patch “\(link.patchName ?? "?")”. Move it to the concert level in MainStage so it stays live — and its mappings stay fixed — when you change patches.")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Theme.eq.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                field(strip.ref.kind == .output ? "Hardware output" : "Hardware input", text: Binding(
                    get: { draft.hardwareIO ?? "" },
                    set: { draft.hardwareIO = $0.isEmpty ? nil : $0 }), placeholder: strip.ref.kind == .output ? "Out 1-2" : "In 1 or In 3-4 or Bus 1")
                Text("Slot \(strip.ref.slot) → \(strip.ref.port.rawValue) · ch \(strip.ref.channel) — stays fixed when you rename or reorder.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 8) {
                    ToggleChip(title: "SAVE", isOn: draft != strip, color: Theme.sends) { store.updateStrip(strip.ref) { $0 = draft } }
                        .disabled(draft == strip)
                    ToggleChip(title: "REVERT", isOn: false, color: Theme.text) { draft = strip }
                        .disabled(draft == strip)
                }
                ToggleChip(title: "SET UP PROCESSING →", isOn: true, color: Theme.inserts) { store.openSetup(.processing, strip: strip.ref) }
                Button { confirmRemove = true } label: {
                    Text("Remove channel").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mute)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.mute.opacity(0.7)))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .alert("Remove \(strip.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.removeStrip(strip.ref) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The strip leaves FOH Remote. Nothing changes in MainStage, and slot \(strip.ref.slot) becomes free.")
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.label).tracking(1).foregroundStyle(Theme.text3)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .padding(.horizontal, 12).frame(height: 44)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel(title)
        }
    }
}

/// Right-hand editor for one send.
struct SendEditPanel: View {
    @Environment(MixerStore.self) private var store
    let bus: SendBus
    @State private var draft: SendBus
    @State private var confirmRemove = false

    init(bus: SendBus) {
        self.bus = bus
        _draft = State(initialValue: bus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit · Send \(bus.index)").font(.system(size: 17, weight: .bold))
            VStack(alignment: .leading, spacing: 6) {
                Text("NAME").font(Theme.label).tracking(1).foregroundStyle(Theme.text3)
                TextField("Mon 1", text: $draft.name)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("Send name")
            }
            Stepper(value: Binding(get: { draft.busNumber ?? 1 }, set: { draft.busNumber = $0 }), in: 1...64) {
                Text("MainStage Bus \(draft.busNumber ?? 1)").font(.system(size: 14, weight: .semibold))
            }
            HStack(spacing: 8) {
                ConcertTag(inConcert: bus.existsInConcert, yes: "Bus fed in the concert", no: "No aux strip on this bus yet")
                Spacer()
            }
            Text(bus.existsInConcert ? "An aux strip in the concert is fed by this bus." :
                    "Add an aux channel strip fed by Bus \(draft.busNumber ?? 1) in MainStage, then re-import the concert.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            Text("Level CC \(Role.send(bus.index, "level")?.cc ?? 0) · On CC \(Role.send(bus.index, "on")?.cc ?? 0) on every input's channel")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            HStack(spacing: 8) {
                ToggleChip(title: "SAVE", isOn: draft != bus, color: Theme.sends) { store.updateSend(bus.index) { $0 = draft } }
                    .disabled(draft == bus)
                ToggleChip(title: "REVERT", isOn: false, color: Theme.text) { draft = bus }.disabled(draft == bus)
            }
            ToggleChip(title: "SHOW ON FADERS", isOn: true, color: Theme.sends) {
                store.sendsOnFaders = bus.index
                store.tab = .mixer
            }
            Button { confirmRemove = true } label: {
                Text("Remove send").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mute)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.mute.opacity(0.7)))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .alert("Remove \(bus.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.removeSend(bus.index) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Send \(bus.index) disappears from every input in FOH Remote. MainStage is unchanged.")
        }
    }
}

/// Preview of a concert scan before merging it into the show.
struct ConcertImportSheet: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let info = store.concertInfo {
                let merged = store.config.merged(with: info)
                let rows = info.strips.map { cs -> (ConcertInfo.ChannelStrip, String, Color) in
                    guard let kind = cs.stripKind else { return (cs, "SKIPPED · \(cs.kind == .instrument ? "instrument" : "unknown")", Theme.text3) }
                    let existing = store.existingStrip(for: cs)
                    let target = merged.strips.first { $0.mainStage?.stripName == cs.name && $0.ref.kind == kind }
                    if let existing { return (cs, "UPDATE · \(existing.ref.key)", Theme.sends) }
                    if let target { return (cs, "NEW → \(target.ref.key)", Theme.meterGreen) }
                    return (cs, "NO FREE SLOT", Theme.mute)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Import from concert").font(.system(size: 22, weight: .bold))
                        Text(info.path).font(.system(size: 12).monospaced()).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                }
                Text(countsText(rows.map(\.1), patches: info.patches.count, inputs: info.audioInputCount))
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            let (cs, status, color) = row
                            HStack(spacing: 12) {
                                Text(kindText(cs.kind)).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.text3).lineLimit(1).frame(width: 86, alignment: .leading)
                                Text(cs.name).font(.system(size: 14, weight: .semibold)).frame(width: 150, alignment: .leading)
                                ConcertTag(inConcert: cs.level == .concert, yes: "concert", no: "patch: \(cs.patchName ?? "?")").frame(width: 130, alignment: .leading)
                                Text(cs.input ?? cs.output ?? "—").font(.system(size: 12).monospacedDigit()).frame(width: 70, alignment: .leading)
                                Text(cs.plugins.map(\.name).joined(separator: ", ")).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(status).font(.system(size: 10.5, weight: .heavy)).foregroundStyle(color)
                                    .frame(width: 130, alignment: .trailing)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if !info.patches.isEmpty {
                    HStack(spacing: 6) {
                        SectionLabel("Patches")
                        ForEach(info.patches) { p in
                            Text("\(p.name)\(p.programChange.map { " · PC \($0)" } ?? "")")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(Theme.raised, in: Capsule())
                        }
                    }
                }
                Text("Existing strips keep their slot, name and colour. Strips no longer in the concert are kept.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 10) {
                    Spacer()
                    ToggleChip(title: "CANCEL", isOn: false, color: Theme.text) { store.showConcertImport = false }.frame(width: 120)
                    ToggleChip(title: "MERGE INTO SHOW", isOn: true, color: Theme.sends) { store.mergeConcert() }.frame(width: 200)
                }
            } else {
                Text("No concert scanned yet.").foregroundStyle(Theme.text2)
            }
        }
        .padding(24)
        .frame(width: 1080, height: 760)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .foregroundStyle(Theme.text)
    }

    private func kindText(_ k: ConcertInfo.ChannelStrip.Kind) -> String {
        switch k {
        case .audioInput: return "INPUT"
        case .aux: return "AUX / FX"
        case .output: return "OUTPUT"
        case .master: return "MASTER"
        case .instrument: return "INSTRUMENT"
        case .unknown: return "OTHER"
        }
    }

    private func countsText(_ statuses: [String], patches: Int, inputs: Int?) -> String {
        let new = statuses.filter { $0.hasPrefix("NEW") }.count
        let upd = statuses.filter { $0.hasPrefix("UPDATE") }.count
        let skip = statuses.filter { $0.hasPrefix("SKIPPED") }.count
        var parts = ["\(statuses.count) strips found", "\(new) new", "\(upd) to update", "\(skip) skipped", "\(patches) patches"]
        if let inputs { parts.append("audio device set to \(inputs) inputs") }
        return parts.joined(separator: " · ")
    }
}

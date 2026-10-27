import SwiftUI
import FOHCore

struct RootView: View {
    @Environment(MixerStore.self) private var store

    /// Not demo, not connected: dim the console (Setup stays usable so you can fix the connection).
    private var offline: Bool { !store.isDemo && !store.connection.isConnected }
    /// Also paused while the bridge's show can't be read: the strips on screen aren't the bridge's.
    private var paused: Bool { offline || store.configErrorPausesConsole }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            if offline { StatusBanner.offline(store.connection) }
            if let error = store.configError { StatusBanner.configError(error, paused: store.configErrorPausesConsole) }
            if store.locked { StatusBanner.locked { store.locked = false } }
            Group {
                switch store.tab {
                case .mixer: MixerView()
                case .channel: ChannelView()
                case .routing: RoutingView()
                case .setup: SetupView()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(paused && store.tab != .setup ? 0.45 : 1)
            .allowsHitTesting(!(paused && store.tab != .setup))
        }
        .background(Theme.ground)
        .foregroundStyle(Theme.text)
        .font(.system(size: 13).monospacedDigit())
        .overlay {
            if store.showConcertImport {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                        .onTapGesture { store.showConcertImport = false }
                        .accessibilityLabel("Close import preview")
                    ConcertImportSheet()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.showConcertImport)
        .overlay(alignment: .top) {
            if let toast = store.toast {
                ToastView(toast: toast) { store.toast = nil }
                    .padding(.top, 68)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast)
    }
}

/// Small confirmation pill (bridge ack or local demo action). Tap to dismiss; disappears after 3 s.
struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: 10) {
                Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(toast.ok ? Theme.meterGreen : Theme.mute)
                Text(toast.message).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: 560)
            .background(Theme.raised2, in: Capsule())
            .overlay(Capsule().strokeBorder((toast.ok ? Theme.meterGreen : Theme.mute).opacity(0.7), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(toast.message)
        .accessibilityIdentifier("toast")
        .accessibilityHint("Dismiss")
    }
}

struct TopBar: View {
    @Environment(MixerStore.self) private var store
    @Environment(BridgeClient.self) private var client

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                BrandMark()
                (Text("FOH ").fontWeight(.heavy) + Text("Remote").fontWeight(.medium).foregroundColor(Theme.text2))
                    .font(.system(size: 15))
            }
            .frame(width: 112, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    Button { store.tab = tab } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .foregroundStyle(store.tab == tab ? Theme.ground : Theme.text)
                            .background(store.tab == tab ? Theme.text : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.tab == tab ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 12))

            Spacer()
            PatchPill()
            Spacer()
            RecordButton()

            Button { store.tab = .setup; store.setupSection = .connection } label: {
                HStack(spacing: 8) {
                    Circle().fill(connectionColor).frame(width: 8, height: 8)
                    Text(store.connection.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Theme.raised, in: Capsule())
            }
            .buttonStyle(.plain)

            Button { store.locked.toggle() } label: {
                Image(systemName: store.locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(store.locked ? Theme.ground : Theme.text)
                    .background(store.locked ? Theme.eq : Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.locked ? "Unlock controls" : "Lock controls")
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var connectionColor: Color {
        switch store.connection {
        case .connected: return Theme.meterGreen
        case .connecting, .searching: return Theme.eq
        case .failed: return Theme.mute
        case .demo: return Theme.text3
        }
    }
}

/// MainStage's Record button (concert recording). One tap starts it; stopping asks first, so a stray tap can't end a
/// recording mid-service. While recording it's red, with the time since this iPad saw it start.
struct RecordButton: View {
    @Environment(MixerStore.self) private var store
    @State private var confirmStop = false

    var body: some View {
        if store.isBound(.master, .record) {
            let on = store.isRecording
            Button { if on { confirmStop = true } else { store.setRecording(true) } } label: {
                HStack(spacing: 8) {
                    Circle().fill(on ? Theme.text : Theme.mute).frame(width: 11, height: 11)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(on ? Self.elapsed(since: store.recordingSince, now: context.date) : "REC")
                            .font(.system(size: 13, weight: .heavy).monospacedDigit())
                    }
                }
                .padding(.horizontal, 14)
                .frame(minWidth: 84, minHeight: 40)
                .foregroundStyle(Theme.text)
                .background(on ? Theme.mute : Theme.raised, in: Capsule())
                .overlay(Capsule().stroke(store.isAssumed(.master, .record) && on ? Theme.text.opacity(0.6) : .clear,
                                          style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            }
            .buttonStyle(.plain)
            .disabled(store.locked)
            .accessibilityLabel(on ? "Stop recording" : "Start recording")
            .accessibilityIdentifier("record")
            .alert("Stop recording?", isPresented: $confirmStop) {
                Button("Stop recording", role: .destructive) { store.setRecording(false) }
                Button("Keep recording", role: .cancel) {}
            } message: {
                Text("MainStage stops recording the concert.")
            }
        }
    }

    /// "REC 12:34", or "REC" when this iPad didn't see the recording start.
    static func elapsed(since start: Date?, now: Date) -> String {
        guard let start else { return "REC" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "REC %d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "REC %d:%02d", s / 60, s % 60)
    }
}

/// Setlist: the current MainStage patch, with prev / next sending Program Change via the bridge.
struct PatchPill: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        let patches = store.config.patches
        let index = store.config.currentPatch ?? 0
        HStack(spacing: 4) {
            Button { store.selectPatch(index - 1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 40)
                    .background(Theme.raised2, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).accessibilityLabel("Previous patch")
            .disabled(index <= 0 || store.locked)
            .opacity(index <= 0 ? 0.4 : 1)
            Menu {
                ForEach(patches) { p in
                    Button { store.selectPatch(p.index) } label: {
                        if p.index == index { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
                if store.connection.isConnected {
                    Divider()
                    Button("Pull values from MainStage") { store.pullFromMainStage() }
                }
            } label: {
                VStack(spacing: 1) {
                    Text(patches.isEmpty ? "NO PATCHES · \(store.config.name.uppercased())" :
                            "PATCH \(index + 1) / \(patches.count) · \(store.config.name.uppercased())")
                        .font(Theme.label).tracking(0.8).foregroundStyle(Theme.text2)
                    Text(store.currentPatch?.name ?? "—").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                }
                .frame(minWidth: 190, minHeight: 40)
            }
            .disabled(store.locked)
            .accessibilityLabel("Patch \(store.currentPatch?.name ?? "none")")
            Button { store.selectPatch(index + 1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 40)
                    .background(Theme.raised2, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).accessibilityLabel("Next patch")
            .disabled(index >= patches.count - 1 || store.locked)
            .opacity(index >= patches.count - 1 ? 0.4 : 1)
        }
        .padding(4)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Thin banner under the top bar for "Locked", "Reconnecting" and an unreadable show.
enum StatusBanner {
    static func configError(_ message: String, paused: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).fontWeight(.semibold)
            Spacer()
            Text(paused ? "Controls are paused · Setup stays available" : "Still showing the last show it sent")
                .foregroundStyle(Theme.text.opacity(0.75))
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Theme.mute.opacity(0.85))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("banner.configError")
    }

    static func locked(_ unlock: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text("Locked — controls ignore touches.").fontWeight(.semibold)
            Button("Unlock", action: unlock).fontWeight(.bold).underline().buttonStyle(.plain)
            Spacer()
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.ground)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Theme.eq)
    }

    static func offline(_ state: ConnectionState) -> some View {
        HStack(spacing: 8) {
            ProgressView().tint(Theme.text).scaleEffect(0.7)
            Text(state == .searching ? "Searching for FOH Bridge…" : "Reconnecting to FOH Bridge…").fontWeight(.semibold)
            if case .failed(let why) = state { Text(why).foregroundStyle(Theme.text.opacity(0.75)) }
            Spacer()
            Text("Controls are paused until the bridge is back · Setup stays available").foregroundStyle(Theme.text.opacity(0.75))
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Theme.mute.opacity(0.85))
    }
}

struct BrandMark: View {
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 5), with: .color(Theme.text), lineWidth: 1.5)
            for (i, x) in [7.0, 11.0, 15.0].enumerated() {
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 5)); p.addLine(to: CGPoint(x: x, y: 17)) }, with: .color(Theme.text3), lineWidth: 1.5)
                let y = [11.0, 7.0, 12.0][i]
                ctx.fill(Path(roundedRect: CGRect(x: x - 2, y: y, width: 4, height: 3), cornerRadius: 1), with: .color(i == 0 ? Theme.eq : Theme.text))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

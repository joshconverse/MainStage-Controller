import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import FOHCore
import FOHMacKit

/// The floating Learn HUD (PLAN.md §7): stays on top of MainStage so you can run the whole MainStage learn
/// from the Mac — ⌃⌥Space fires the sweep, ⌃⌥→ marks it learned and moves on, ⌃⌥← goes back.
/// It drives the bridge's shared LearnState, so the iPad's learn screen follows along.
@MainActor
@Observable
final class LearnHUDController {
    static let shared = LearnHUDController()

    private(set) var isVisible = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var server: BridgeServer?

    func setVisible(_ visible: Bool, server: BridgeServer) {
        visible ? show(server: server) : hide()
    }

    func show(server: BridgeServer) {
        self.server = server
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 236),
                                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .hudWindow],
                                backing: .buffered, defer: false)
            panel.title = "FOH Learn"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: LearnHUDView(server: server))
            panel.center()
            panel.setFrameAutosaveName("FOHLearnHUD")
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didClose() }
            }
            self.panel = panel
        }
        server.learnBeginIfNeeded()
        panel?.orderFrontRegardless()
        isVisible = true
        registerHotKeys()
    }

    func hide() {
        panel?.orderOut(nil)
        didClose()
    }

    private func didClose() {
        isVisible = false
        HotKeyCenter.shared.unregisterAll()
    }

    private func registerHotKeys() {
        let mods = UInt32(controlKey | optionKey)
        HotKeyCenter.shared.unregisterAll()
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_Space), modifiers: mods, id: 1) { [weak self] in self?.server?.learnFireCurrent() }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_RightArrow), modifiers: mods, id: 2) { [weak self] in self?.server?.learnNext() }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_LeftArrow), modifiers: mods, id: 3) { [weak self] in self?.server?.learnPrevious() }
    }
}

/// System-wide hotkeys through Carbon's RegisterEventHotKey — works while MainStage has focus and needs no
/// Accessibility permission.
final class HotKeyCenter {
    nonisolated(unsafe) static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x464F_4848), id: id) // 'FOHH'
        if RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

struct LearnHUDView: View {
    let server: BridgeServer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MAINSTAGE LEARN").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                let progress = server.learnProgress
                Text("\(progress.learned) / \(progress.total) learned").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let display = server.learnDisplay {
                Text(display.label).font(.title3.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    chip(display.portName)
                    chip("Ch \(display.channel)")
                    chip("CC \(display.cc)")
                    if display.learned {
                        Label("learned", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    }
                }
                Text("1  Assignments & Mappings → New Assignment → Assign & Map\n2  Send the sweep (⌃⌥Space)\n3  \(display.hint)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { server.learnPrevious() } label: { Image(systemName: "chevron.left") }
                        .help("Previous (⌃⌥←)")
                    Button("Send sweep") { server.learnFireCurrent() }
                        .keyboardShortcut(.defaultAction)
                        .help("⌃⌥Space")
                    Button("Learned → Next") { server.learnNext() }
                        .help("⌃⌥→")
                    Button("Skip") { server.learnSkip() }
                    Spacer()
                }
                .controlSize(.regular)
            } else {
                Text("Nothing left to learn.").font(.title3.weight(.semibold))
                Text("Every bound control is marked learned. Clear the marks to start over after rebuilding the concert.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Start again") { server.learnClear() }
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(width: 440, alignment: .leading)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.22)))
    }
}

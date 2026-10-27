import AppKit
import SwiftUI
import FOHCore
import FOHMacKit

/// `FOHBridge -renderHUD <out.png> [-store <dir>]`: draw the Learn HUD for one item into a PNG and quit.
/// Runs fully offline (no MIDI ports, no network, no metering), so it can sit beside a running bridge.
/// Used to check the HUD's layout without screen-recording permission.
enum HUDSnapshot {
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-renderHUD"), i + 1 < args.count else { return false }
        let out = URL(fileURLWithPath: args[i + 1])
        var options = BridgeServer.Options()
        if let s = args.firstIndex(of: "-store"), s + 1 < args.count {
            options.store = BridgeStore(directory: URL(fileURLWithPath: args[s + 1]))
        }
        options.discoverPlugins = false
        options.enableMeters = false
        options.advertiseBonjour = false
        let server = BridgeServer(options: options)
        server.learnSelect(LearnState.Item(.input(1), Role.band(2, "gain")!))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let host = NSHostingView(rootView: LearnHUDView(server: server)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: .darkAqua)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: NSSize(width: 440, height: max(size.height, 120)))
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.display()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
            }
            exit(0)
        }
        return true
    }
}

import SwiftUI
import FOHCore
import FOHMacKit

@main
struct FOHBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var server: BridgeServer

    init() {
        if HUDSnapshot.runIfRequested() {
            // Offline render: a server that never starts (no ports, no network).
            _server = State(initialValue: BridgeServer(options: { var o = BridgeServer.Options(); o.enableMeters = false; return o }()))
            return
        }
        var options = BridgeServer.Options()
        options.onLog = { LogFile.append($0) }
        options.autoSyncMainStage = true
        options.concertWriter = Bundle.main.url(forResource: "concert_write", withExtension: "py")
        options.mainStageCatalog = MainStagePluginCatalog.description(named:)
        let server = BridgeServer(options: options)
        do {
            try server.start()
        } catch {
            server.appendLog("Couldn't start the bridge: \(error)")
        }
        _server = State(initialValue: server)
        AppDelegate.server = server
    }

    var body: some Scene {
        MenuBarExtra {
            BridgeMenuView(server: server)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)

        Window("FOH Bridge Log", id: "log") {
            BridgeLogView(server: server)
        }
        .defaultSize(width: 760, height: 440)
    }
}

/// Saves the mix on any quit (menu, logout, shutdown), not only the menu's Quit button.
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var server: BridgeServer?

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.server?.saveAll()
    }
}

import SwiftUI

@main
struct ModelViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = LocalHTTPServer()
    @StateObject private var actionRunner = ActionRunner()

    var body: some Scene {
        WindowGroup("3D Model Viewer") {
            ContentView()
                .environmentObject(server)
                .environmentObject(actionRunner)
                .onAppear {
                    server.start()
                    appDelegate.actionRunner = actionRunner
                }
        }
        .defaultSize(width: 1440, height: 960)
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var actionRunner: ActionRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        actionRunner?.stop()
    }
}

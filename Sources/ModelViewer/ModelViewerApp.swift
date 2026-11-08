import SwiftUI

@main
struct ModelViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = LocalHTTPServer()

    var body: some Scene {
        WindowGroup("3D Model Viewer") {
            ContentView()
                .environmentObject(server)
                .onAppear { server.start() }
        }
        .defaultSize(width: 1440, height: 960)
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

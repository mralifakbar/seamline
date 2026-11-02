import AppKit
import SwiftUI

@main
struct SeamlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Seamline", id: "main") {
            RootView()
                .environmentObject(model)
                #if DEBUG
                .onAppear { Snapshot.runIfRequested(model) }
                #endif
        }
        .defaultSize(width: 720, height: 580)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            // The glyph changes only when the pointer really is on another Mac.
            Image(systemName: model.focus == .local ? "display.2" : "cursorarrow.motionlines")
                .accessibilityLabel(model.focusName.map { "Seamline, pointer on \($0)" } ?? "Seamline")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

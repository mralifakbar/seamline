#if DEBUG
import AppKit
import SwiftUI
import SeamlineCore

/// Debug builds only: renders each screen to PNG for visual review.
/// SEAMLINE_SNAPSHOT_DIR=/path SEAMLINE_SCENARIO=host [SEAMLINE_DARK=1] Seamline.app/Contents/MacOS/Seamline
@MainActor
enum Snapshot {
    nonisolated static var autopair: Bool { ProcessInfo.processInfo.environment["SEAMLINE_AUTOPAIR"] == "1" }
    private static var watcher: Any?

    /// Headless two-process test: pairs with whatever is nearby, confirms prompts, and logs every state change.
    static func runAutopair(_ model: AppModel) {
        guard autopair else { return }
        let tag = model.role == .host ? "host" : "guest"
        watcher = model.objectWillChange.sink { _ in
            DispatchQueue.main.async {
                let line = model.machines.map { "\($0.name)=\($0.status)" }.joined(separator: ", ")
                print("[\(tag)] machines: \(line) pairing: \(model.pairing?.code ?? "-") controller: \(model.controller ?? "-") problem: \(String(describing: model.discoveryProblem))")
                fflush(stdout)
                if let prompt = model.pairing, !prompt.waiting { model.acceptPairing() }
                for m in model.machines where m.status == .nearby { model.pair(m.id) }
            }
        }
    }

    static func runIfRequested(_ model: AppModel) {
        runAutopair(model)
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SEAMLINE_SNAPSHOT_DIR"], let scenario = env["SEAMLINE_SCENARIO"] else { return }
        NSApp.appearance = NSAppearance(named: env["SEAMLINE_DARK"] == "1" ? .darkAqua : .aqua)
        // A debug binary has no bundle icon; borrow the README's so the menu bar panel shows the real one.
        if let icon = NSImage(contentsOfFile: "docs/images/icon.png") { NSApp.applicationIconImage = icon }
        apply(scenario, to: model)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let suffix = env["SEAMLINE_DARK"] == "1" ? "-dark" : ""
            // No keyboard focus ring in screenshots.
            for window in NSApp.windows { window.makeFirstResponder(nil) }
            for window in NSApp.windows where window.isVisible && window.frame.width > 200 {
                guard let view = window.contentView?.superview ?? window.contentView else { continue }
                let name = window.sheetParent != nil ? "sheet" : (window.title.isEmpty ? "window" : window.title)
                let path = "\(dir)/\(scenario)\(suffix)-\(name).png"
                // A real window capture keeps the active-window look (blue switches, vibrancy); an offscreen
                // render draws controls as inactive. Fall back to it when Screen Recording is not allowed.
                if window.sheetParent != nil || !capture(window, to: path) { write(view, to: path) }
            }
            let menu = NSHostingView(rootView: MenuBarView().environmentObject(model).background(Color(nsColor: .windowBackgroundColor)))
            menu.frame = NSRect(origin: .zero, size: menu.fittingSize)
            let panel = NSWindow(contentRect: menu.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.contentView = menu
            menu.layoutSubtreeIfNeeded()
            let settings = NSHostingView(rootView: SettingsView().environmentObject(model).background(Color(nsColor: .windowBackgroundColor)))
            settings.frame = NSRect(origin: .zero, size: settings.fittingSize)
            let settingsWindow = NSWindow(contentRect: settings.frame, styleMask: [.titled], backing: .buffered, defer: false)
            settingsWindow.contentView = settings
            settings.layoutSubtreeIfNeeded()
            // Put both on screen briefly so they can be captured as real windows.
            let extra: [(NSWindow, NSView, String)] = [(panel, menu, "menubar"), (settingsWindow, settings, "settings")]
            for (window, _, _) in extra { window.center(); window.orderFrontRegardless() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                for (window, view, name) in extra {
                    let path = "\(dir)/\(scenario)\(suffix)-\(name).png"
                    if !capture(window, to: path) { write(view, to: path) }
                }
                exit(0)
            }
        }
    }

    private static func capture(_ window: NSWindow, to path: String) -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
    }

    private static func write(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func apply(_ scenario: String, to model: AppModel) {
        let air = UUID(), mini = UUID(), imac = UUID()
        func host() {
            model.previewing = true
            model.role = .host
            model.setupComplete = true
            var layout = Layout()
            layout.place(model.identity.id.uuidString, at: Cell(x: 0, y: 0))
            layout.place(air.uuidString, at: Cell(x: 1, y: 0))
            layout.place(mini.uuidString, at: Cell(x: 0, y: 1))
            model.layout = layout
            model.machines = [
                Machine(id: air, name: "MacBook Air", kind: .laptop, displays: [Rect(x: 0, y: 0, width: 1470, height: 956)], status: .connected, isPaired: true, latency: 6.4, link: .wifi),
                Machine(id: mini, name: "Mac mini", kind: .desktop, displays: [Rect(x: 0, y: 0, width: 2560, height: 1440)], status: .offline, isPaired: true),
                Machine(id: imac, name: "iMac", kind: .allInOne, displays: [], status: .nearby, isPaired: false),
            ]
        }
        switch scenario {
        case "role":
            model.previewing = true
            model.role = nil
            model.setupComplete = false
        case "permissions":
            model.role = .host
            model.setupComplete = false
        case "host":
            host()
        case "host-remote":
            host()
            model.focus = .remote(air)
            model.secureInputApp = "1Password"
        case "host-empty":
            model.previewing = true
            model.role = .host
            model.setupComplete = true
            var layout = Layout()
            layout.place(model.identity.id.uuidString, at: Cell(x: 0, y: 0))
            model.layout = layout
            model.machines = []
        case "pairing-host":
            host()
            model.pairing = PairingPrompt(id: imac, name: "iMac", code: "482913", waiting: false)
        case "guest":
            model.previewing = true
            model.role = .guest
            model.setupComplete = true
            model.listenAddresses = ["192.168.1.20", "100.101.102.103 (VPN)"]
            model.machines = [Machine(id: air, name: "Mac Studio", kind: .desktop, displays: [], status: .connected, isPaired: true)]
        case "guest-controlled":
            model.previewing = true
            model.role = .guest
            model.setupComplete = true
            model.controller = "Mac Studio"
            model.machines = [Machine(id: air, name: "Mac Studio", kind: .desktop, displays: [], status: .connected, isPaired: true)]
        case "pairing-guest":
            model.previewing = true
            model.role = .guest
            model.setupComplete = true
            model.pairing = PairingPrompt(id: air, name: "Mac Studio", code: "482913", waiting: true)
        default:
            break
        }
    }
}
#endif

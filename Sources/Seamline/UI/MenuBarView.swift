import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var status: String {
        guard model.isRunning else { return "Not set up yet" }
        if model.role == .guest {
            return model.controller.map { "Controlled by \($0)" } ?? "Ready to be controlled"
        }
        if model.paused { return "Sharing paused" }
        return model.focusName.map { "Pointer on \($0)" } ?? "Pointer on this Mac"
    }

    private var statusColor: Color {
        guard model.isRunning else { return .orange }
        if model.role == .host, model.paused { return .gray }
        return .green
    }

    private var paired: [Machine] { model.machines.filter(\.isPaired) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            cards

            if model.isRunning, !paired.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paired Macs").font(.caption.weight(.semibold)).foregroundStyle(.subdued)
                    ForEach(paired) { machine in
                        HStack(spacing: 10) {
                            Image(systemName: machine.kind.symbol)
                                .foregroundStyle(machine.status == .connected ? Color.accentColor : Color.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            Text(machine.name).lineLimit(1)
                            Spacer(minLength: 8)
                            StatusDot(color: machine.status.dotColor)
                            Text(machine.linkDetail)
                                .font(.caption)
                                .foregroundStyle(.subdued)
                        }
                        .frame(minHeight: 22)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Divider()
            VStack(spacing: 0) {
                MenuRow(title: "Open Seamline") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                SettingsRow()
                MenuRow(title: "Quit Seamline", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            // The rows' hover highlight reaches a little past the text, like a menu's.
            .padding(.horizontal, -6)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconImage(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Seamline").font(.headline)
                HStack(spacing: 6) {
                    StatusDot(color: statusColor)
                    Text(status).font(.caption).foregroundStyle(.subdued)
                }
            }
            Spacer()
            if model.isRunning, model.role == .host {
                Toggle("Share Keyboard and Mouse", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Share Keyboard and Mouse")
            }
        }
    }

    @ViewBuilder private var cards: some View {
        if !model.isRunning {
            ActionCard(symbol: "sparkles", tint: .orange, text: "Finish setting up in the Seamline window.",
                       button: "Continue Setup") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        if let app = model.secureInputApp {
            ActionCard(symbol: "lock.fill", tint: .orange, text: "\(app) is keeping typing on this Mac.")
        }
    }
}

/// Opens the Settings scene. Since macOS 14 the old `showSettingsWindow:` action does nothing,
/// so newer systems go through `openSettings`, then bring the window forward: a menu bar app
/// isn't frontmost, and the window would otherwise open behind other apps.
private struct SettingsRow: View {
    var body: some View {
        if #available(macOS 14, *) {
            Modern()
        } else {
            MenuRow(title: "Settings…", shortcut: "⌘,") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    @available(macOS 14, *)
    private struct Modern: View {
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            MenuRow(title: "Settings…", shortcut: "⌘,") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?.makeKeyAndOrderFront(nil)
                }
            }
            .keyboardShortcut(",")
        }
    }
}

/// A plain row that highlights on hover like a native menu item. Shortcuts show as keycaps.
private struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    KeyCaps(text: shortcut)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var status: String {
        guard model.isRunning else { return "Finish setting up in the Seamline window." }
        if model.role == .guest {
            return model.controller.map { "Controlled by \($0)" } ?? "Ready to be controlled"
        }
        if model.paused { return "Sharing paused" }
        return model.focusName.map { "Pointer on \($0)" } ?? "Pointer on this Mac"
    }

    private var paired: [Machine] { model.machines.filter(\.isPaired) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Seamline").font(.headline)
                Text(status).foregroundStyle(.subdued)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if let app = model.secureInputApp {
                Label {
                    Text("\(app) is keeping typing on this Mac.")
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            if model.isRunning, !paired.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(paired) { machine in
                        HStack(spacing: 8) {
                            Image(systemName: machine.kind.symbol)
                                .foregroundStyle(.subdued)
                                .frame(width: 20)
                            Text(machine.name).lineLimit(1)
                            Spacer()
                            Text(machine.linkDetail)
                                .font(.callout)
                                .foregroundStyle(.subdued)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if model.isRunning, model.role == .host {
                Divider()
                Toggle("Share Keyboard and Mouse", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                    .toggleStyle(.switch)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            Divider()
            VStack(spacing: 0) {
                MenuRow(title: "Open Seamline") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuRow(title: "Settings…", shortcut: "⌘,") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                MenuRow(title: "Quit Seamline", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(5)
        }
        .frame(width: 290)
    }
}

/// A plain row that highlights on hover like a native menu item.
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
                    Text(shortcut).foregroundStyle(.subdued)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

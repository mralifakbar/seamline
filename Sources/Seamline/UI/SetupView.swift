import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.role == nil {
                RoleStep()
            } else {
                PermissionStep()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RoleStep: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 10) {
                Text("Which Mac has the keyboard and mouse?")
                    .font(.title.weight(.semibold))
                    .tracking(-0.3)
                Text("Seamline lets one keyboard and mouse work across the Macs on your desk. Push the pointer past the edge of one screen and it appears on the next.")
                    .font(.body)
                    .foregroundStyle(.subdued)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 16) {
                RoleChoice(symbol: "keyboard", title: "This Mac", detail: "Share this keyboard and mouse with Macs nearby.") {
                    model.role = .host
                }
                RoleChoice(symbol: SystemInfo.kind.symbol, title: "Another Mac", detail: "Let a Mac nearby control this one.") {
                    model.role = .guest
                }
            }

            Text("You can change this later in Settings.")
                .font(.footnote)
                .foregroundStyle(.subdued)
        }
    }
}

private struct RoleChoice: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .frame(height: 44)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.subdued)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(width: 210, height: 190)
        }
        .buttonStyle(ChoiceButtonStyle())
    }
}

/// Feedback lands on press, not on release: the surface dips the moment the pointer goes down.
struct ChoiceButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(hovering ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: hovering ? 1.5 : 1)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

private struct PermissionStep: View {
    @EnvironmentObject private var model: AppModel

    private var isHost: Bool { model.role == .host }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Text(isHost ? "Let Seamline use this keyboard and mouse" : "Let Seamline click and type on this Mac")
                    .font(.title.weight(.semibold))
                    .tracking(-0.3)
                Text(isHost
                     ? "macOS asks before any app can read input or move the pointer. Seamline needs two permissions on this Mac."
                     : "macOS asks before any app can click or type for you. Seamline needs one permission on this Mac.")
                    .foregroundStyle(.subdued)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            VStack(spacing: 0) {
                PermissionRow(
                    title: "Accessibility",
                    detail: isHost
                        ? "Holds this Mac's pointer still and moves it onto your other Macs."
                        : "Clicks and types on this Mac for the Mac you pair with.",
                    granted: model.accessibilityGranted,
                    request: Permissions.requestAccessibility)
                if isHost {
                    Divider().padding(.leading, 52)
                    PermissionRow(
                        title: "Input Monitoring",
                        detail: "Reads your typing so it can go to the Mac the pointer is on.",
                        granted: model.inputMonitoringGranted,
                        request: Permissions.requestInputMonitoring)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            .frame(maxWidth: 520)

            Text(model.permissionsReady
                 ? "All set."
                 : "After you switch Seamline on in System Settings, come back here. This page updates by itself.")
                .font(.footnote)
                .foregroundStyle(.subdued)

            HStack {
                Button("Back") { model.role = nil }
                Spacer()
                Button(isHost ? "Find Nearby Macs" : "Make This Mac Visible") { model.setupComplete = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.permissionsReady)
            }
            .frame(maxWidth: 520)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 22))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.subdued)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Text("Allowed")
                    .foregroundStyle(.subdued)
            } else {
                Button("Allow…", action: request)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityValue(granted ? "Allowed" : "Not allowed")
    }
}

import SwiftUI

/// First run: choose a role, allow permissions, then pair from the main window.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    /// Role, permissions, then finding and pairing a Mac in the main window.
    private let steps = 3
    private var step: Int { model.role == nil ? 0 : 1 }
    private var isHost: Bool { model.role == .host }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.role == nil {
                    RoleStep()
                } else {
                    PermissionStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 36)

            HStack {
                StepDots(count: steps, current: step)
                Spacer()
                if model.role != nil {
                    Button("Back") { model.role = nil }
                    Button(isHost ? "Find Nearby Macs" : "Make This Mac Visible") { model.setupComplete = true }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.permissionsReady)
                } else {
                    Text("You can change this later in Settings.")
                        .font(.callout)
                        .foregroundStyle(.subdued)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RoleStep: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Text("Which Mac has the keyboard and mouse?")
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Seamline lets one keyboard and mouse work across the Macs on your desk. Push the pointer past the edge of one screen and it appears on the next.")
                    .font(.title3)
                    .foregroundStyle(.subdued)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                RoleChoice(symbol: "keyboard", title: "This Mac", detail: "Share this keyboard and mouse with Macs nearby.") {
                    model.role = .host
                }
                RoleChoice(symbol: SystemInfo.kind.symbol, title: "Another Mac", detail: "Let a Mac nearby control this one.") {
                    model.role = .guest
                }
            }
            Spacer(minLength: 0)
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
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
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
            .frame(width: 220, height: 190)
        }
        .buttonStyle(ChoiceButtonStyle())
    }
}

private struct PermissionStep: View {
    @EnvironmentObject private var model: AppModel

    private var isHost: Bool { model.role == .host }

    /// Snapshot runs report permissions as ready; show the rows the same way.
    private var previewing: Bool {
        #if DEBUG
        return model.previewing
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isHost ? "Let Seamline use this keyboard and mouse" : "Let Seamline click and type on this Mac")
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(isHost
                 ? "macOS asks before any app can read input or move the pointer. Seamline needs two permissions on this Mac."
                 : "macOS asks before any app can click or type for you. Seamline needs one permission on this Mac.")
                .foregroundStyle(.subdued)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                PermissionRow(
                    title: "Accessibility",
                    detail: isHost
                        ? "Holds this Mac's pointer still and moves it onto your other Macs."
                        : "Clicks and types on this Mac for the Mac you pair with.",
                    granted: model.accessibilityGranted || previewing,
                    request: Permissions.requestAccessibility)
                if isHost {
                    Divider().padding(.leading, 44)
                    PermissionRow(
                        title: "Input Monitoring",
                        detail: "Reads your typing so it can go to the Mac the pointer is on.",
                        granted: model.inputMonitoringGranted || previewing,
                        request: Permissions.requestInputMonitoring)
                }
            }
            .padding(16)
            .background(SoftCard())

            Text(model.permissionsReady
                 ? "All set."
                 : "After you switch Seamline on in System Settings, come back here. This page updates by itself.")
                .font(.callout)
                .foregroundStyle(.subdued)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "lock.shield")
                .font(.system(size: 26))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
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
        .accessibilityElement(children: .combine)
        .accessibilityValue(granted ? "Allowed" : "Not allowed")
    }
}

import SwiftUI

struct GuestView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.discoveryProblem == .localNetworkDenied {
                ActionCard(symbol: "wifi.exclamationmark", tint: .red,
                           text: "Other Macs can't find this one because Local Network access is off for Seamline.",
                           button: "Open Privacy Settings", action: Permissions.openLocalNetworkSettings)
                    .padding(.bottom, 12)
            }

            Spacer(minLength: 16)

            VStack(spacing: 16) {
                Image(systemName: SystemInfo.kind.symbol)
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(model.controller != nil ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(model.controller.map { "Controlled by \($0)" } ?? "Ready to be controlled")
                        .font(.system(size: 30, weight: .bold))
                    Text(detail)
                        .font(.title3)
                        .foregroundStyle(.subdued)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.controller)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 18) {
                if model.controller == nil, !model.listenAddresses.isEmpty {
                    Section2(title: "On another network") {
                        SettingRow(symbol: "network", title: "Connect by address",
                                   detail: "On the Mac with your keyboard and mouse, choose Connect by Address and enter one of these.") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(model.listenAddresses, id: \.self) { address in
                                    Text(address)
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.subdued)
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                pairedList
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Seamline")
        .navigationSubtitle(model.controller == nil ? "Visible as “\(model.identity.name)”" : "In use")
    }

    private var detail: String {
        if let host = model.controller {
            return "Push the pointer back across the edge to return to \(host), or press Control-Option-Command-Escape there."
        }
        if case .unavailable(let reason) = model.discoveryProblem {
            return "This Mac can't be found on the network right now: \(reason)"
        }
        return "On the Mac with your keyboard and mouse, open Seamline and pair with “\(model.identity.name)”."
    }

    @ViewBuilder private var pairedList: some View {
        if !model.machines.isEmpty {
            Section2(title: "Paired Macs") {
                ForEach(Array(model.machines.enumerated()), id: \.element.id) { index, machine in
                    if index > 0 { Divider().padding(.leading, 34) }
                    SettingRow(symbol: machine.kind.symbol, title: machine.name, detail: machine.linkDetail) {
                        Button("Forget") { model.forget(machine.id) }
                    }
                }
            }
        }
    }
}

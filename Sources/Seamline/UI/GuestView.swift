import SwiftUI

struct GuestView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.discoveryProblem == .localNetworkDenied {
                Banner(tone: .error, symbol: "wifi.exclamationmark",
                       message: "Other Macs can't find this one because Local Network access is off for Seamline.",
                       action: ("Open Privacy Settings", Permissions.openLocalNetworkSettings))
            }

            Spacer(minLength: 24)

            VStack(spacing: 18) {
                Image(systemName: SystemInfo.kind.symbol)
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(model.controller != nil ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(model.controller.map { "Controlled by \($0)" } ?? "Ready to be controlled")
                        .font(.title.weight(.semibold))
                        .tracking(-0.3)
                    Text(detail)
                        .foregroundStyle(.subdued)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.controller)

            if model.controller == nil, !model.listenAddresses.isEmpty {
                Text("On another network? Connect by address: \(model.listenAddresses.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.subdued)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding(.top, 14)
            }

            Spacer(minLength: 24)

            pairedList
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
        }
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Paired Macs")
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(model.machines.enumerated()), id: \.element.id) { index, machine in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: machine.kind.symbol)
                                .foregroundStyle(.subdued)
                                .frame(width: 22)
                            Text(machine.name)
                            Spacer()
                            Text(machine.linkDetail)
                                .foregroundStyle(.subdued)
                            Button("Forget") { model.forget(machine.id) }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            }
            .frame(maxWidth: 520)
        }
    }
}

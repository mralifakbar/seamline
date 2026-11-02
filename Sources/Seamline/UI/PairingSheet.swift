import SwiftUI

struct PairingSheet: View {
    @EnvironmentObject private var model: AppModel
    let prompt: PairingPrompt

    private var isHost: Bool { model.role == .host }

    /// "482913" reads as "482 913": two chunks are easier to compare across two screens.
    private var spacedCode: String {
        let code = prompt.code
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    var body: some View {
        VStack(spacing: 18) {
            Text(isHost ? "Pair with \(prompt.name)" : "\(prompt.name) wants to control this Mac")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(spacedCode)
                .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(1)
                .textSelection(.enabled)
                .accessibilityLabel("Pairing code \(prompt.code.map(String.init).joined(separator: " "))")

            Text(isHost
                 ? "Check that \(prompt.name) shows the same code, then select Pair on both Macs."
                 : "Allow this only if \(prompt.name) shows the same code. Once paired, its keyboard and mouse can control this Mac.")
                .foregroundStyle(.subdued)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if prompt.waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(prompt.name)…")
                        .foregroundStyle(.subdued)
                }
                .transition(.opacity)
            }

            HStack {
                Button(isHost ? "Cancel" : "Decline", role: .cancel) { model.declinePairing() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isHost ? "Pair" : "Allow") { model.acceptPairing() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.waiting)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 400)
        .animation(.easeOut(duration: 0.2), value: prompt.waiting)
    }
}

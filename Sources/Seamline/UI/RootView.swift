import SwiftUI
import SeamlineCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 520)
            .sheet(item: $model.pairing) { prompt in
                PairingSheet(prompt: prompt)
                    .environmentObject(model)
            }
            .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }

    @ViewBuilder private var content: some View {
        if !model.isRunning {
            SetupView()
        } else if model.role == .host {
            HostView()
        } else {
            GuestView()
        }
    }
}

extension Machine.Status {
    var label: String {
        switch self {
        case .nearby: return "Not paired"
        case .connecting: return "Connecting…"
        case .pairing: return "Waiting for pairing"
        case .connected: return "Connected"
        case .offline: return "Not available"
        }
    }
}

extension Machine {
    /// "Connected · 6 ms" when a measurement exists; the latency is a live round trip, never an estimate.
    var statusDetail: String {
        guard status == .connected, let latency else { return status.label }
        return "Connected · \(Machine.format(latency))"
    }

    /// "6 ms, Wi-Fi" for compact rows.
    var linkDetail: String {
        guard status == .connected else { return status.label }
        let parts = [latency.map(Machine.format), link?.rawValue].compactMap { $0 }
        return parts.isEmpty ? status.label : parts.joined(separator: ", ")
    }

    static func format(_ ms: Double) -> String {
        ms < 1 ? "under 1 ms" : "\(Int(ms.rounded())) ms"
    }
}

extension MachineKind {
    var symbol: String {
        switch self {
        case .laptop: return "laptopcomputer"
        case .allInOne: return "desktopcomputer"
        case .desktop: return "display"
        }
    }
}

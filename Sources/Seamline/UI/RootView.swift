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

/// A full-width notice for problems that block the main task. Orange and red stay reserved for these.
struct Banner: View {
    enum Tone { case warning, error }

    let tone: Tone
    let symbol: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tone == .error ? Color.red : Color.orange)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background((tone == .error ? Color.red : Color.orange).opacity(0.1))
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

extension ShapeStyle where Self == Color {
    /// Secondary text at WCAG AA. The system secondary label measures about 3.9:1 on light gray surfaces.
    static var subdued: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.62)
                : NSColor(white: 0, alpha: 0.64)
        })
    }
}

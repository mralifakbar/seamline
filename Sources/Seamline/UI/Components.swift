import AppKit
import SwiftUI

// Shared building blocks. They follow Panefold's look so the two apps read as one family:
// soft cards without borders, a secondary label above each group, a caption line under each title,
// keycaps for shortcuts and tinted cards for anything that needs doing.

/// A titled group of rows on a soft card.
struct Section2<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).foregroundStyle(.subdued)
                Spacer(minLength: 8)
                accessory
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SoftCard())
        }
    }
}

extension Section2 where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.accessory = EmptyView()
    }
}

/// The card surface every group sits on.
struct SoftCard: View {
    var cornerRadius: CGFloat = 12
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(0.04))
    }
}

/// A title with a caption under it and a control trailing. An optional accent symbol leads.
struct SettingRow<Control: View>: View {
    var symbol: String?
    var symbolStyle: Color = .accentColor
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(symbolStyle)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.subdued)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
    }
}

extension SettingRow where Control == EmptyView {
    init(symbol: String? = nil, symbolStyle: Color = .accentColor, title: String, detail: String? = nil) {
        self.init(symbol: symbol, symbolStyle: symbolStyle, title: title, detail: detail) { EmptyView() }
    }
}

/// A key combination drawn like keycaps.
struct KeyCaps: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
            .accessibilityLabel(text)
    }
}

/// A tinted card for something that needs doing. Orange and red stay reserved for problems.
struct ActionCard: View {
    let symbol: String
    let tint: Color
    let text: String
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let button {
                    Button(button, action: action).controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }
}

/// A small colored dot for a connection's state.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

extension Machine.Status {
    var dotColor: Color {
        switch self {
        case .connected: return .green
        case .connecting, .pairing: return .orange
        case .nearby, .offline: return .gray
        }
    }
}

/// Progress through a multi-step flow: the current step is a wider accent capsule.
struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// The app icon at a small size, for the menu bar panel's header.
struct AppIconImage: View {
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A large choice on a soft card. Feedback lands on press, not on release: the surface dips
/// the moment the pointer goes down. Hovering outlines it in the accent color.
struct ChoiceButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(hovering ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .opacity(hovering ? 1 : 0)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
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

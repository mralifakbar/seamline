import SwiftUI
import SeamlineCore

struct HostView: View {
    @EnvironmentObject private var model: AppModel

    private var subtitle: String {
        if model.paused { return "Sharing paused" }
        return model.focusName.map { "Pointer on \($0)" } ?? "Pointer on this Mac"
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            ArrangementCanvas()
                .padding(16)
            Divider()
            NearbyList()
        }
        .navigationTitle("Seamline")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Text("Sharing")
                        .foregroundStyle(.subdued)
                    Toggle("Share Keyboard and Mouse", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                .help("Turn off to keep the pointer on this Mac")
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if model.discoveryProblem == .localNetworkDenied {
            Banner(tone: .error, symbol: "wifi.exclamationmark",
                   message: "Seamline can't see other Macs because Local Network access is off for it.",
                   action: ("Open Privacy Settings", Permissions.openLocalNetworkSettings))
        }
        if model.tapFailed {
            Banner(tone: .error, symbol: "exclamationmark.triangle.fill",
                   message: "Seamline couldn't start reading the keyboard and mouse. Check Accessibility and Input Monitoring.",
                   action: ("Open Settings", Permissions.requestAccessibility))
        }
        if let app = model.secureInputApp, let target = model.focusName {
            Banner(tone: .warning, symbol: "lock.fill",
                   message: "\(app) is protecting a password field on this Mac, so typing stays here instead of going to \(target). Close or leave that field to type on \(target).")
        }
    }
}

// MARK: - Arrangement

private struct CanvasGeometry {
    let origin: CGPoint
    let cell: CGSize
    let box: CGSize
    let minCell: Cell

    static let fallbackDisplay = Rect(x: 0, y: 0, width: 1440, height: 900)
    /// Every Mac gets the same box, because crossing maps a whole edge onto a whole edge regardless of physical size.
    private static let idealBox = CGSize(width: 172, height: 112)
    private static let spacing = 1.22

    init(size: CGSize, layout: Layout) {
        let cells = Array(layout.cells.values)
        let minX = (cells.map(\.x).min() ?? 0) - 1, maxX = (cells.map(\.x).max() ?? 0) + 1
        let minY = (cells.map(\.y).min() ?? 0) - 1, maxY = (cells.map(\.y).max() ?? 0) + 1
        let columns = Double(maxX - minX + 1), rows = Double(maxY - minY + 1)
        let ideal = CGSize(width: Self.idealBox.width * Self.spacing, height: Self.idealBox.height * Self.spacing)
        let k = min(1, size.width / (columns * ideal.width), size.height / (rows * ideal.height))
        box = CGSize(width: Self.idealBox.width * k, height: Self.idealBox.height * k)
        cell = CGSize(width: ideal.width * k, height: ideal.height * k)
        minCell = Cell(x: minX, y: minY)
        origin = CGPoint(x: (size.width - cell.width * columns) / 2, y: (size.height - cell.height * rows) / 2)
    }

    /// Fits the Mac's display shape into the box, with a floor so the name always has room.
    func tileSize(for bounds: Rect) -> CGSize {
        let aspect = bounds.width / max(bounds.height, 1)
        var w = box.width, h = box.width / aspect
        if h > box.height { h = box.height; w = box.height * aspect }
        return CGSize(width: max(w, box.width * 0.72), height: max(h, box.height * 0.68))
    }

    func center(of c: Cell) -> CGPoint {
        CGPoint(x: origin.x + (Double(c.x - minCell.x) + 0.5) * cell.width,
                y: origin.y + (Double(c.y - minCell.y) + 0.5) * cell.height)
    }

    func nearest(to point: CGPoint, in targets: Set<Cell>) -> Cell? {
        targets.min { a, b in
            let pa = center(of: a), pb = center(of: b)
            return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
        }
    }
}

private struct DragState: Equatable {
    var id: String
    var offset: CGSize
    var target: Cell?
}

private struct ArrangementCanvas: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: DragState?

    private var selfKey: String { model.identity.id.uuidString }

    private var placed: [Machine] {
        var list = [model.thisMac]
        list += model.machines.filter { model.layout.cell(of: $0.id.uuidString) != nil }
        return list
    }

    private func bounds(_ m: Machine) -> Rect {
        guard !m.displays.isEmpty else { return CanvasGeometry.fallbackDisplay }
        return ScreenSpace(displays: m.displays).bounds
    }

    var body: some View {
        GeometryReader { proxy in
            let machines = placed
            let spaces = Dictionary(uniqueKeysWithValues: machines.map { ($0.id.uuidString, bounds($0)) })
            let geometry = CanvasGeometry(size: proxy.size, layout: model.layout)

            ZStack {
                if let target = drag?.target, let id = drag?.id, let rect = spaces[id] {
                    let size = geometry.tileSize(for: rect)
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(width: size.width, height: size.height)
                        .position(geometry.center(of: target))
                        .accessibilityHidden(true)
                }

                seams(machines: machines, spaces: spaces, geometry: geometry)

                ForEach(machines) { machine in
                    tile(machine, spaces: spaces, geometry: geometry)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
        .overlay(alignment: .bottom) {
            Text(model.layout.cells.count > 1
                 ? "Drag the Macs to match your desk. The pointer crosses where two Macs touch."
                 : "Pair a Mac below and it appears here, next to this one.")
                .font(.callout)
                .foregroundStyle(.subdued)
                .padding(.bottom, 14)
        }
        .frame(minHeight: 280)
    }

    // The crossing seam is Seamline's one accent: it marks exactly where the pointer moves between Macs.
    @ViewBuilder
    private func seams(machines: [Machine], spaces: [String: Rect], geometry: CanvasGeometry) -> some View {
        ForEach(machines) { machine in
            let key = machine.id.uuidString
            ForEach([Edge.right, Edge.bottom], id: \.self) { edge in
                if let cell = model.layout.cell(of: key),
                   let other = model.layout.neighbor(of: key, toward: edge),
                   let otherMachine = machines.first(where: { $0.id.uuidString == other }),
                   drag?.id != key, drag?.id != other {
                    let a = geometry.tileSize(for: spaces[key]!), b = geometry.tileSize(for: spaces[other]!)
                    let live = machine.status == .connected && otherMachine.status == .connected
                    let mid = geometry.center(of: cell)
                    let next = geometry.center(of: cell.step(edge))
                    Capsule()
                        .fill(live ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: edge == .right ? 4 : min(a.width, b.width) * 0.6,
                               height: edge == .right ? min(a.height, b.height) * 0.6 : 4)
                        .position(x: (mid.x + next.x) / 2 + (edge == .right ? (a.width - b.width) / 4 : 0),
                                  y: (mid.y + next.y) / 2 + (edge == .bottom ? (a.height - b.height) / 4 : 0))
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func tile(_ machine: Machine, spaces: [String: Rect], geometry: CanvasGeometry) -> some View {
        let key = machine.id.uuidString
        let cell = model.layout.cell(of: key) ?? Cell(x: 0, y: 0)
        let size = geometry.tileSize(for: spaces[key]!)
        let isDragging = drag?.id == key
        let hasPointer = machine.id == model.identity.id ? model.focus == .local : model.focus == .remote(machine.id)

        return MachineTile(machine: machine, isThisMac: machine.id == model.identity.id, hasPointer: hasPointer && !model.paused, lifted: isDragging && !reduceMotion)
            .frame(width: size.width, height: size.height)
            // Before .position, which grows the view to the whole canvas: the focus ring must hug the tile.
            .focusable()
            .onMoveCommand { direction in
                let edge: Edge
                switch direction {
                case .left: edge = .left
                case .right: edge = .right
                case .up: edge = .top
                case .down: edge = .bottom
                @unknown default: return
                }
                let target = cell.step(edge)
                guard model.layout.dropTargets(for: key).contains(target) else { NSSound.beep(); return }
                withAnimation(settle(flicked: false)) { model.move(machine.id, to: target) }
            }
            .position(geometry.center(of: cell))
            .offset(isDragging ? drag!.offset : .zero)
            .zIndex(isDragging ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .local)
                    .onChanged { value in
                        let point = geometry.center(of: cell) + value.translation
                        let target = geometry.nearest(to: point, in: model.layout.dropTargets(for: key))
                        drag = DragState(id: key, offset: value.translation, target: target)
                    }
                    .onEnded { value in
                        // Land where the throw was heading, not where the pointer let go.
                        let projected = geometry.center(of: cell) + value.predictedEndTranslation
                        let target = geometry.nearest(to: projected, in: model.layout.dropTargets(for: key)) ?? cell
                        let speed = hypot(value.predictedEndTranslation.width - value.translation.width,
                                          value.predictedEndTranslation.height - value.translation.height)
                        withAnimation(settle(flicked: speed > 60)) {
                            model.move(machine.id, to: target)
                            drag = nil
                        }
                    }
            )
            .contextMenu {
                if machine.id != model.identity.id {
                    Button("Forget \(machine.name)", role: .destructive) { model.forget(machine.id) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(machine.id == model.identity.id ? "\(machine.name), this Mac" : "\(machine.name), \(machine.linkDetail)")
            .accessibilityValue(hasPointer ? "Pointer is here" : "")
            .accessibilityHint("Drag, or use the arrow keys, to move this Mac in the arrangement.")
    }

    /// Critically damped by default; a little bounce only when the tile was thrown.
    private func settle(flicked: Bool) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        return .spring(response: 0.35, dampingFraction: flicked ? 0.8 : 1.0)
    }
}

private struct MachineTile: View {
    let machine: Machine
    let isThisMac: Bool
    let hasPointer: Bool
    let lifted: Bool

    private var dimmed: Bool { machine.status == .offline || machine.status == .connecting }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    hasPointer ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: hasPointer ? 2 : 1, dash: machine.status == .offline ? [4, 3] : []))
            VStack(spacing: 4) {
                Image(systemName: machine.kind.symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.subdued)
                    .opacity(dimmed ? 0.5 : 1)
                Text(machine.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isThisMac ? "This Mac" : machine.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.subdued)
                    .lineLimit(1)
            }
            .padding(8)
        }
        // Elevation only while lifted, so the dragged tile reads as held above the others.
        .shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: lifted ? 14 : 0, y: lifted ? 6 : 0)
        .scaleEffect(lifted ? 1.03 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: lifted)
    }
}

private func + (point: CGPoint, size: CGSize) -> CGPoint {
    CGPoint(x: point.x + size.width, y: point.y + size.height)
}

// MARK: - Nearby

private struct NearbyList: View {
    @EnvironmentObject private var model: AppModel
    @State private var addressSheet = false
    @State private var searchingLong = false

    private var nearby: [Machine] {
        model.machines.filter { !$0.isPaired }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Nearby")
                    .font(.headline)
                Spacer()
                Button("Connect by Address…") { addressSheet = true }
                    .help("For a Mac on another network, for example over Tailscale")
            }
            .sheet(isPresented: $addressSheet) { AddressSheet() }

            if case .unavailable(let reason) = model.discoveryProblem {
                Label("Can't search the network right now: \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.subdued)
            } else if nearby.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.machines.isEmpty
                             ? "Looking for Macs on this network. On the other Mac, open Seamline and choose “Another Mac”."
                             : "Looking for more Macs. On another Mac, open Seamline and choose “Another Mac”.")
                            .foregroundStyle(.subdued)
                            .fixedSize(horizontal: false, vertical: true)
                        // macOS can block Bonjour without reporting an error, so after a while say where to look.
                        // Once any Mac has shown up, discovery evidently works and the hint would mislead.
                        if searchingLong, model.machines.isEmpty {
                            HStack(spacing: 6) {
                                Text("Still nothing? Local Network access may be off for Seamline.")
                                    .foregroundStyle(.subdued)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Open Privacy Settings", action: Permissions.openLocalNetworkSettings)
                                    .buttonStyle(.link)
                            }
                        }
                    }
                }
                .task {
                    searchingLong = false
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    searchingLong = true
                }
            } else {
                ForEach(nearby) { machine in
                    HStack(spacing: 10) {
                        Image(systemName: machine.kind.symbol)
                            .foregroundStyle(.subdued)
                            .frame(width: 22)
                        Text(machine.name)
                        Spacer()
                        if machine.status == .nearby {
                            Button("Pair…") { model.pair(machine.id) }
                        } else {
                            ProgressView().controlSize(.small)
                            Text(machine.status.label)
                                .foregroundStyle(.subdued)
                        }
                    }
                    .frame(minHeight: 28)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AddressSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect by Address")
                .font(.title3.weight(.semibold))
            Text("Use this when the other Mac is on a different network, for example over Tailscale. Its address is shown in Seamline on that Mac. Seamline remembers it and reconnects by itself.")
                .foregroundStyle(.subdued)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Address", text: $address, prompt: Text("100.101.102.103 or macbook.tailnet.ts.net"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(connect)
                .onChange(of: address) { _ in problem = nil }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func connect() {
        if let message = model.connect(address: address) {
            problem = message
        } else {
            dismiss()
        }
    }
}

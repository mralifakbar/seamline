import AppKit
import CoreGraphics
import SeamlineCore

enum Focus: Equatable {
    case local
    case remote(UUID)
}

/// Decides, per input event, whether it stays on this Mac or travels to another one.
/// Runs on the event tap thread; everything else reaches it through the lock.
final class HostEngine {
    private struct Peer {
        let connection: PeerConnection
        var space: ScreenSpace
    }

    private static let returnKeyCode: Int64 = 53 // Escape
    private static let returnFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    private static let cornerGuard = 6.0
    /// Within this distance of an edge that leads to another Mac, its link is woken ahead of the crossing.
    private static let prewarmDistance = 160.0

    private let lock = NSLock()
    private let selfKey: String
    private var peers: [UUID: Peer] = [:]
    private var layout = Layout()
    private var localSpace = ScreenSpace(displays: SystemInfo.displays())
    private var resistance: Double = 30
    private var localPush = EdgeResistance(threshold: 30)
    private var focus: Focus = .local
    private var cursor: VirtualCursor?
    private var parkPoint = CGPoint.zero
    private var buttonsDown: UInt32 = 0
    private var flags: UInt32 = 0

    /// Called on the main queue whenever the pointer changes machine.
    var onFocusChange: ((Focus) -> Void)?

    init(selfID: UUID) { selfKey = selfID.uuidString }

    var hasPeers: Bool { lock.withLock { !peers.isEmpty } }

    func add(_ connection: PeerConnection, id: UUID, displays: [Rect]) {
        lock.withLock { peers[id] = Peer(connection: connection, space: ScreenSpace(displays: displays)) }
    }

    func updateDisplays(_ displays: [Rect], for id: UUID) {
        lock.withLock { peers[id]?.space = ScreenSpace(displays: displays) }
    }

    func remove(_ id: UUID) {
        lock.withLock {
            if focus == .remote(id) { returnLocal(at: parkPoint, notifyPeer: false) }
            peers[id] = nil
        }
    }

    func setLayout(_ layout: Layout) { lock.withLock { self.layout = layout } }

    func setResistance(_ value: Double) {
        lock.withLock {
            resistance = value
            localPush = EdgeResistance(threshold: value)
        }
    }

    func localDisplaysChanged() {
        lock.withLock { localSpace = ScreenSpace(displays: SystemInfo.displays()) }
    }

    /// Brings the pointer home, e.g. when sharing is paused.
    func returnHome() {
        lock.withLock { if case .remote = focus { returnLocal(at: parkPoint, notifyPeer: true) } }
    }

    // MARK: Event tap

    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        trackButtons(type, event)
        switch focus {
        case .local:
            if type == .mouseMoved, buttonsDown == 0 { checkLocalEdge(event) }
            return false
        case .remote(let id):
            return forward(type, event, to: id)
        }
    }

    private func trackButtons(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .leftMouseDown: buttonsDown |= 1
        case .leftMouseUp: buttonsDown &= ~1
        case .rightMouseDown: buttonsDown |= 2
        case .rightMouseUp: buttonsDown &= ~2
        case .otherMouseDown: buttonsDown |= 1 << UInt32(min(event.getIntegerValueField(.mouseEventButtonNumber), 31))
        case .otherMouseUp: buttonsDown &= ~(1 << UInt32(min(event.getIntegerValueField(.mouseEventButtonNumber), 31)))
        default: break
        }
    }

    private func checkLocalEdge(_ event: CGEvent) {
        let location = event.location
        let delta = Point(x: event.getDoubleValueField(.mouseEventDeltaX), y: event.getDoubleValueField(.mouseEventDeltaY))
        let point = Point(x: location.x, y: location.y)
        prewarmNeighbors(near: point)
        let edge = localSpace.pushedEdge(at: point, delta: delta, cornerGuard: Self.cornerGuard)
        let target = edge.flatMap { layout.neighbor(of: selfKey, toward: $0) }.flatMap(UUID.init(uuidString:))
        guard let edge, let target, peers[target] != nil else { localPush.reset(); return }
        guard localPush.push(edge, amount: edge.isHorizontal ? delta.x : delta.y) else { return }
        parkPoint = location
        flags = UInt32(truncatingIfNeeded: event.flags.rawValue)
        CursorControl.detach()
        enter(target, through: edge.opposite, fraction: localSpace.fraction(of: point, along: edge))
    }

    /// Wakes the radio link toward a Mac the pointer is heading for, so the first packet after crossing is not the slow one.
    private func prewarmNeighbors(near p: Point) {
        guard let i = localSpace.displayIndex(containing: p) else { return }
        let d = localSpace.displays[i]
        let distances: [(Edge, Double)] = [(.left, p.x - d.minX), (.right, d.maxX - p.x), (.top, p.y - d.minY), (.bottom, d.maxY - p.y)]
        for (edge, distance) in distances where distance < Self.prewarmDistance {
            guard let next = layout.neighbor(of: selfKey, toward: edge), let id = UUID(uuidString: next),
                  let peer = peers[id], localSpace.isOuter(edge, ofDisplay: i, at: p) else { continue }
            peer.connection.prewarm()
        }
    }

    private func enter(_ id: UUID, through edge: Edge, fraction: Double) {
        guard let peer = peers[id] else { return }
        let start = peer.space.entryPoint(through: edge, fraction: fraction)
        cursor = VirtualCursor(space: peer.space, position: start, resistance: resistance)
        focus = .remote(id)
        peer.connection.setHot(true)
        peer.connection.send(.enter(x: Float(start.x), y: Float(start.y), flags: flags, motionSeq: 0))
        notify()
    }

    private func returnLocal(at point: CGPoint, notifyPeer: Bool) {
        if case .remote(let id) = focus {
            if notifyPeer { peers[id]?.connection.send(.leave) }
            peers[id]?.connection.setHot(false)
        }
        focus = .local
        cursor = nil
        localPush.reset()
        CursorControl.attach(at: point)
        notify()
    }

    private func notify() {
        let focus = self.focus
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?(focus) }
    }

    private func forward(_ type: CGEventType, _ event: CGEvent, to id: UUID) -> Bool {
        guard let connection = peers[id]?.connection else { returnLocal(at: parkPoint, notifyPeer: false); return false }
        let eventFlags = UInt32(truncatingIfNeeded: event.flags.rawValue)

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            guard var cursor else { return true }
            let outcome = cursor.move(dx: dx, dy: dy, allowExit: buttonsDown == 0)
            self.cursor = cursor
            switch outcome {
            case .moved(let p):
                connection.send(.move(seq: 0, x: Float(p.x), y: Float(p.y), dx: Float(dx), dy: Float(dy)))
            case let .exited(edge, fraction):
                cross(from: id, edge: edge, fraction: fraction, connection: connection)
            }

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let index: UInt8
            switch type {
            case .leftMouseDown, .leftMouseUp: index = 0
            case .rightMouseDown, .rightMouseUp: index = 1
            default: index = UInt8(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
            }
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            let clicks = UInt8(clamping: event.getIntegerValueField(.mouseEventClickState))
            let at = cursor?.position ?? Point(x: 0, y: 0)
            connection.send(.button(index: index, down: down, clicks: clicks, flags: eventFlags, x: Float(at.x), y: Float(at.y)))

        case .scrollWheel:
            connection.send(.scroll(Scroll(
                lineY: Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                lineX: Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                pointY: Int32(clamping: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
                pointX: Int32(clamping: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                fixedY: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                fixedX: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                phase: UInt8(clamping: event.getIntegerValueField(.scrollWheelEventScrollPhase)),
                momentumPhase: UInt8(clamping: event.getIntegerValueField(.scrollWheelEventMomentumPhase)))))

        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown, code == Self.returnKeyCode, event.flags.isSuperset(of: Self.returnFlags) {
                returnLocal(at: parkPoint, notifyPeer: true)
                return true
            }
            connection.send(.key(code: UInt16(clamping: code), down: type == .keyDown,
                                 isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                 flags: eventFlags,
                                 keyboardType: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeyboardType))))

        case .flagsChanged:
            flags = eventFlags
            connection.send(.modifiers(code: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)), flags: eventFlags))

        case EventTap.systemDefined:
            // Subtype 8 carries media, volume and brightness keys; other subtypes are bookkeeping and stay local.
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
            connection.send(.systemKey(subtype: ns.subtype.rawValue, data1: Int32(truncatingIfNeeded: ns.data1), data2: Int32(truncatingIfNeeded: ns.data2)))

        default:
            return false
        }
        return true
    }

    private func cross(from id: UUID, edge: Edge, fraction: Double, connection: PeerConnection) {
        guard let next = layout.neighbor(of: id.uuidString, toward: edge) else { return }
        if next == selfKey {
            connection.send(.leave)
            returnLocal(at: localEntry(through: edge.opposite, fraction: fraction), notifyPeer: false)
        } else if let nextID = UUID(uuidString: next), peers[nextID] != nil {
            connection.send(.leave)
            connection.setHot(false)
            enter(nextID, through: edge.opposite, fraction: fraction)
        }
    }

    private func localEntry(through edge: Edge, fraction: Double) -> CGPoint {
        let p = localSpace.entryPoint(through: edge, fraction: fraction)
        // Land a few points inside so the very next motion does not bounce straight back out.
        let inset: Double = 2
        switch edge {
        case .left: return CGPoint(x: p.x + inset, y: p.y)
        case .right: return CGPoint(x: p.x - inset, y: p.y)
        case .top: return CGPoint(x: p.x, y: p.y + inset)
        case .bottom: return CGPoint(x: p.x, y: p.y - inset)
        }
    }
}

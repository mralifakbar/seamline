import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import SeamlineCore

/// Replays the host's input on this Mac. Runs on the connection queue; CGEvent posting is thread-safe.
final class InputInjector {
    private let source: CGEventSource?
    private var position = CGPoint.zero
    private var buttons: UInt32 = 0
    private var keysDown = Set<UInt16>()
    private var flags: UInt32 = 0
    private var activity: IOPMAssertionID = 0
    /// Moves only apply between enter and leave; a late datagram must not yank the pointer afterwards.
    private var entered = false

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Without this, macOS ignores the local mouse for 250 ms after every injected event.
        source?.localEventsSuppressionInterval = 0
    }

    func handle(_ message: Message) {
        switch message {
        case let .enter(x, y, newFlags, _):
            entered = true
            flags = newFlags
            position = CGPoint(x: CGFloat(x), y: CGFloat(y))
            CGWarpMouseCursorPosition(position)
            postMove(dx: 0, dy: 0)
            // Wakes a sleeping display the moment the pointer arrives.
            IOPMAssertionDeclareUserActivity("Seamline pointer arrived" as CFString, kIOPMUserActiveLocal, &activity)
        case .leave:
            entered = false
            releaseAll()
        case let .move(_, x, y, dx, dy):
            guard entered else { return }
            position = CGPoint(x: CGFloat(x), y: CGFloat(y))
            postMove(dx: Double(dx), dy: Double(dy))
        case let .button(index, down, clicks, newFlags, x, y):
            flags = newFlags
            position = CGPoint(x: CGFloat(x), y: CGFloat(y))
            postButton(index: index, down: down, clicks: clicks)
        case .scroll(let s):
            postScroll(s)
        case let .key(code, down, isRepeat, newFlags, keyboardType):
            flags = newFlags
            if down { keysDown.insert(code) } else { keysDown.remove(code) }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            event.flags = CGEventFlags(rawValue: UInt64(newFlags))
            event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
            if keyboardType != 0 { event.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(keyboardType)) }
            event.post(tap: .cghidEventTap)
        case let .modifiers(code, newFlags):
            flags = newFlags
            // The key code matters even here: 0 is the A key, and some input methods react to it.
            guard let event = CGEvent(source: source) else { return }
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
            event.flags = CGEventFlags(rawValue: UInt64(newFlags))
            event.post(tap: .cghidEventTap)
        case let .systemKey(subtype, data1, data2):
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: subtype, data1: Int(data1), data2: Int(data2))?
                .cgEvent?.post(tap: .cghidEventTap)
        default:
            break
        }
    }

    /// Lifts every key and button this Mac still thinks is held, so nothing sticks after the pointer leaves.
    func releaseAll() {
        for code in keysDown {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
        }
        keysDown.removeAll()
        for index in 0..<32 where buttons & (1 << index) != 0 {
            postButton(index: UInt8(index), down: false, clicks: 1)
        }
        if flags & 0x00FF_0000 != 0, let event = CGEvent(source: source) {
            event.type = .flagsChanged
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        flags = 0
    }

    private func postMove(dx: Double, dy: Double) {
        let type: CGEventType
        let button: CGMouseButton
        if buttons & 1 != 0 { type = .leftMouseDragged; button = .left }
        else if buttons & 2 != 0 { type = .rightMouseDragged; button = .right }
        else if buttons != 0 { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        // Games and 3D apps read deltas instead of positions.
        event.setDoubleValueField(.mouseEventDeltaX, value: dx)
        event.setDoubleValueField(.mouseEventDeltaY, value: dy)
        event.flags = CGEventFlags(rawValue: UInt64(flags))
        event.post(tap: .cghidEventTap)
    }

    private func postButton(index: UInt8, down: Bool, clicks: UInt8) {
        let type: CGEventType
        let button: CGMouseButton
        switch index {
        case 0: type = down ? .leftMouseDown : .leftMouseUp; button = .left
        case 1: type = down ? .rightMouseDown : .rightMouseUp; button = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; button = CGMouseButton(rawValue: UInt32(index)) ?? .center
        }
        if down { buttons |= 1 << UInt32(index) } else { buttons &= ~(1 << UInt32(index)) }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(index))
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clicks, 1)))
        event.flags = CGEventFlags(rawValue: UInt64(flags))
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(_ s: Scroll) {
        let units: CGScrollEventUnit = s.continuous ? .pixel : .line
        let primary = s.continuous ? s.pointY : s.lineY
        let secondary = s.continuous ? s.pointX : s.lineX
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2, wheel1: primary, wheel2: secondary, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(s.lineY))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(s.lineX))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(s.pointY))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(s.pointX))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: s.fixedY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: s.fixedX)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: s.continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(s.phase))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(s.momentumPhase))
        event.flags = CGEventFlags(rawValue: UInt64(flags))
        event.post(tap: .cghidEventTap)
    }
}

import Foundation

public enum MachineKind: UInt8, Codable, Sendable {
    case laptop, allInOne, desktop
}

/// First encrypted message each side sends: who it is and what its displays look like.
public struct Introduction: Equatable, Sendable {
    public var kind: MachineKind
    public var displays: [Rect]
    /// Whether the sender already trusts the other side's key from an earlier pairing.
    public var trustsPeer: Bool

    public init(kind: MachineKind, displays: [Rect], trustsPeer: Bool) {
        self.kind = kind; self.displays = displays; self.trustsPeer = trustsPeer
    }
}

/// Scroll fields copied 1:1 from the source CGEvent, so trackpad phases and momentum survive the trip.
public struct Scroll: Equatable, Sendable {
    public var lineY: Int32
    public var lineX: Int32
    public var pointY: Int32
    public var pointX: Int32
    public var fixedY: Double
    public var fixedX: Double
    public var continuous: Bool
    public var phase: UInt8
    public var momentumPhase: UInt8

    public init(lineY: Int32, lineX: Int32, pointY: Int32, pointX: Int32, fixedY: Double, fixedX: Double,
                continuous: Bool, phase: UInt8, momentumPhase: UInt8) {
        self.lineY = lineY; self.lineX = lineX; self.pointY = pointY; self.pointX = pointX
        self.fixedY = fixedY; self.fixedX = fixedX
        self.continuous = continuous; self.phase = phase; self.momentumPhase = momentumPhase
    }
}

public enum Message: Equatable, Sendable {
    case introduction(Introduction)
    case displays([Rect])
    case pairAccept
    case pairDecline

    /// Host to guest: the pointer arrives at (x, y). Carries live modifier flags so held keys stay held.
    /// `motionSeq` marks where this visit starts, so a late move from an earlier visit is ignored.
    case enter(x: Float, y: Float, flags: UInt32, motionSeq: UInt32)
    /// Host to guest: the pointer left. The guest releases anything still pressed and returns its clipboard if it changed.
    case leave
    /// Absolute position, newest wins. `seq` is stamped by the connection.
    case move(seq: UInt32, x: Float, y: Float, dx: Float, dy: Float)
    /// Carries its own position, so a click lands in the right place even if it overtakes a move.
    case button(index: UInt8, down: Bool, clicks: UInt8, flags: UInt32, x: Float, y: Float)
    case scroll(Scroll)
    case key(code: UInt16, down: Bool, isRepeat: Bool, flags: UInt32, keyboardType: UInt16)
    case modifiers(code: UInt16, flags: UInt32)
    /// Media and brightness keys, sent as NSSystemDefined events.
    case systemKey(subtype: Int16, data1: Int32, data2: Int32)
    /// One slice of a clipboard transfer. Slices ride the bulk lane so typing never waits behind an image.
    case clipboardChunk(transfer: UInt32, index: UInt32, count: UInt32, bytes: Data)

    /// An input event numbered for exactly-once, in-order delivery across the stream and datagram paths.
    indirect case sequenced(seq: UInt32, message: Message)
    case probe(id: UInt32, nanos: UInt64)
    case probeReply(id: UInt32, nanos: UInt64)

    public var isBulk: Bool {
        if case .clipboardChunk = self { return true }
        return false
    }

    /// Discrete input that must arrive exactly once and in order.
    public var isEvent: Bool {
        switch self {
        case .enter, .leave, .button, .scroll, .key, .modifiers, .systemKey: return true
        default: return false
        }
    }
}

extension Message {
    private enum Tag: UInt8 {
        case introduction = 0x01, displays = 0x02, pairAccept = 0x03, pairDecline = 0x04
        case enter = 0x10, leave = 0x11, move = 0x12, button = 0x13, scroll = 0x14
        case key = 0x15, modifiers = 0x16, systemKey = 0x17
        case clipboardChunk = 0x20
        case sequenced = 0x30
        case probe = 0x40, probeReply = 0x41
    }

    public func encode(into w: inout ByteWriter) {
        switch self {
        case .introduction(let intro):
            w.u8(Tag.introduction.rawValue)
            w.u8(intro.kind.rawValue)
            w.bool(intro.trustsPeer)
            Self.writeRects(intro.displays, into: &w)
        case .displays(let rects):
            w.u8(Tag.displays.rawValue)
            Self.writeRects(rects, into: &w)
        case .pairAccept:
            w.u8(Tag.pairAccept.rawValue)
        case .pairDecline:
            w.u8(Tag.pairDecline.rawValue)
        case let .enter(x, y, flags, motionSeq):
            w.u8(Tag.enter.rawValue); w.f32(x); w.f32(y); w.u32(flags); w.u32(motionSeq)
        case .leave:
            w.u8(Tag.leave.rawValue)
        case let .move(seq, x, y, dx, dy):
            w.u8(Tag.move.rawValue); w.u32(seq); w.f32(x); w.f32(y); w.f32(dx); w.f32(dy)
        case let .button(index, down, clicks, flags, x, y):
            w.u8(Tag.button.rawValue); w.u8(index); w.bool(down); w.u8(clicks); w.u32(flags); w.f32(x); w.f32(y)
        case .scroll(let s):
            w.u8(Tag.scroll.rawValue)
            w.i32(s.lineY); w.i32(s.lineX); w.i32(s.pointY); w.i32(s.pointX)
            w.f64(s.fixedY); w.f64(s.fixedX)
            w.bool(s.continuous); w.u8(s.phase); w.u8(s.momentumPhase)
        case let .key(code, down, isRepeat, flags, keyboardType):
            w.u8(Tag.key.rawValue); w.u16(code); w.bool(down); w.bool(isRepeat); w.u32(flags); w.u16(keyboardType)
        case let .modifiers(code, flags):
            w.u8(Tag.modifiers.rawValue); w.u16(code); w.u32(flags)
        case let .systemKey(subtype, data1, data2):
            w.u8(Tag.systemKey.rawValue); w.i16(subtype); w.i32(data1); w.i32(data2)
        case let .clipboardChunk(transfer, index, count, bytes):
            w.u8(Tag.clipboardChunk.rawValue); w.u32(transfer); w.u32(index); w.u32(count); w.bytes(bytes)
        case let .sequenced(seq, message):
            var inner = ByteWriter(capacity: 32)
            message.encode(into: &inner)
            w.u8(Tag.sequenced.rawValue); w.u32(seq); w.bytes(inner.data)
        case let .probe(id, nanos):
            w.u8(Tag.probe.rawValue); w.u32(id); w.u64(nanos)
        case let .probeReply(id, nanos):
            w.u8(Tag.probeReply.rawValue); w.u32(id); w.u64(nanos)
        }
    }

    public static func decode(from r: inout ByteReader) throws -> Message {
        let raw = try r.u8()
        guard let tag = Tag(rawValue: raw) else { throw WireError.unknownMessage(raw) }
        switch tag {
        case .introduction:
            guard let kind = MachineKind(rawValue: try r.u8()) else { throw WireError.invalidValue }
            let trusts = try r.bool()
            return .introduction(Introduction(kind: kind, displays: try readRects(&r), trustsPeer: trusts))
        case .displays:
            return .displays(try readRects(&r))
        case .pairAccept: return .pairAccept
        case .pairDecline: return .pairDecline
        case .enter:
            return .enter(x: try r.f32(), y: try r.f32(), flags: try r.u32(), motionSeq: try r.u32())
        case .leave: return .leave
        case .move:
            return .move(seq: try r.u32(), x: try r.f32(), y: try r.f32(), dx: try r.f32(), dy: try r.f32())
        case .button:
            return .button(index: try r.u8(), down: try r.bool(), clicks: try r.u8(), flags: try r.u32(), x: try r.f32(), y: try r.f32())
        case .scroll:
            return .scroll(Scroll(lineY: try r.i32(), lineX: try r.i32(), pointY: try r.i32(), pointX: try r.i32(),
                                  fixedY: try r.f64(), fixedX: try r.f64(),
                                  continuous: try r.bool(), phase: try r.u8(), momentumPhase: try r.u8()))
        case .key:
            return .key(code: try r.u16(), down: try r.bool(), isRepeat: try r.bool(), flags: try r.u32(), keyboardType: try r.u16())
        case .modifiers:
            return .modifiers(code: try r.u16(), flags: try r.u32())
        case .systemKey:
            return .systemKey(subtype: try r.i16(), data1: try r.i32(), data2: try r.i32())
        case .clipboardChunk:
            return .clipboardChunk(transfer: try r.u32(), index: try r.u32(), count: try r.u32(), bytes: try r.bytes(limit: 1 << 20))
        case .sequenced:
            let seq = try r.u32()
            var inner = ByteReader(try r.bytes(limit: 4096))
            let message = try decode(from: &inner)
            guard message.isEvent else { throw WireError.invalidValue }
            return .sequenced(seq: seq, message: message)
        case .probe:
            return .probe(id: try r.u32(), nanos: try r.u64())
        case .probeReply:
            return .probeReply(id: try r.u32(), nanos: try r.u64())
        }
    }

    private static func writeRects(_ rects: [Rect], into w: inout ByteWriter) {
        w.varint(UInt64(rects.count))
        for r in rects { w.f32(Float(r.x)); w.f32(Float(r.y)); w.f32(Float(r.width)); w.f32(Float(r.height)) }
    }

    private static func readRects(_ r: inout ByteReader) throws -> [Rect] {
        let count = try r.varint()
        guard count <= 64 else { throw WireError.invalidValue }
        return try (0..<count).map { _ in
            let rect = Rect(x: Double(try r.f32()), y: Double(try r.f32()), width: Double(try r.f32()), height: Double(try r.f32()))
            guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { throw WireError.invalidValue }
            return rect
        }
    }

    /// Packs several messages into one plaintext batch: each is prefixed by its varint length.
    public static func encodeBatch(_ messages: [Message]) -> Data {
        var batch = ByteWriter(capacity: 64)
        var scratch = ByteWriter(capacity: 32)
        for m in messages {
            scratch = ByteWriter(capacity: 32)
            m.encode(into: &scratch)
            batch.bytes(scratch.data)
        }
        return batch.data
    }

    public static func decodeBatch(_ data: Data) throws -> [Message] {
        var r = ByteReader(data)
        var out: [Message] = []
        while !r.isAtEnd {
            var inner = ByteReader(try r.bytes(limit: 2 << 20))
            out.append(try decode(from: &inner))
        }
        return out
    }
}

/// Outgoing messages for one peer: a realtime lane for input and a bulk lane for clipboard slices.
/// Consecutive pointer moves collapse into one, so a busy link always carries the newest position.
public struct Outbox {
    private var realtime: [Message] = []
    private var bulk: [Message] = []

    public init() {}

    public var isEmpty: Bool { realtime.isEmpty && bulk.isEmpty }

    public mutating func push(_ m: Message) {
        if m.isBulk { bulk.append(m); return }
        if case let .move(seq, x, y, dx, dy) = m, case let .move(_, _, _, pdx, pdy)? = realtime.last {
            realtime[realtime.count - 1] = .move(seq: seq, x: x, y: y, dx: pdx + dx, dy: pdy + dy)
            return
        }
        realtime.append(m)
    }

    /// Everything realtime, plus at most one bulk slice, so input always goes first.
    public mutating func drain() -> [Message] {
        var out = realtime
        realtime.removeAll(keepingCapacity: true)
        if !bulk.isEmpty { out.append(bulk.removeFirst()) }
        return out
    }
}

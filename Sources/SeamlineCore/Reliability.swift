import CryptoKit
import Foundation

/// Merges events arriving on two paths (datagram and stream) into one in-order, exactly-once sequence.
public struct EventSequencer {
    public private(set) var next: UInt32 = 1
    private var pending: [UInt32: Message] = [:]
    /// A gap this large means the sender restarted its numbering; resync instead of waiting forever.
    private static let window: UInt32 = 4096

    public init() {}

    /// Returns the events that became deliverable, in order. Duplicates and stale copies return nothing.
    public mutating func accept(_ seq: UInt32, _ message: Message) -> [Message] {
        if seq < next || pending[seq] != nil { return [] }
        if seq - next > Self.window {
            pending.removeAll()
            next = seq
        }
        guard seq == next else {
            pending[seq] = message
            return []
        }
        var out = [message]
        next += 1
        while let buffered = pending.removeValue(forKey: next) {
            out.append(buffered)
            next += 1
        }
        return out
    }

    public var buffered: Int { pending.count }
}

/// ChaCha20-Poly1305 for single datagrams. Each packet carries its own counter, since UDP may drop or reorder.
/// Layout: 8-byte session tag, 8-byte counter, ciphertext, 16-byte tag.
public struct DatagramCrypto {
    public let tag: Data
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var counter: UInt64 = 0

    public init(tag: Data, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.tag = tag; self.sendKey = sendKey; self.receiveKey = receiveKey
    }

    public static let overhead = 8 + 8 + 16

    public mutating func seal(_ plaintext: Data) throws -> Data {
        counter += 1
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(counter))
        var out = Data(capacity: plaintext.count + Self.overhead)
        out.append(tag)
        withUnsafeBytes(of: counter.littleEndian) { out.append(contentsOf: $0) }
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    /// Replays need no window here: stale moves lose to newer ones and repeated events are deduplicated by sequence.
    public func open(_ packet: Data) -> Data? {
        guard packet.count >= Self.overhead else { return nil }
        let base = packet.startIndex
        guard packet[base..<(base + 8)] == tag else { return nil }
        var counter: UInt64 = 0
        withUnsafeMutableBytes(of: &counter) { packet.copyBytes(to: $0.bindMemory(to: UInt8.self), from: (base + 8)..<(base + 16)) }
        let end = packet.endIndex
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(UInt64(littleEndian: counter)),
                                                  ciphertext: packet[(base + 16)..<(end - 16)], tag: packet[(end - 16)...])
        else { return nil }
        return try? ChaChaPoly.open(box, using: receiveKey)
    }

    public static func sessionTag(of packet: Data) -> Data? {
        packet.count >= overhead ? Data(packet.prefix(8)) : nil
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data([0x64, 0x67, 0x72, 0x6D])
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// Round-trip samples in milliseconds: a smoothed value for the interface, percentiles for benchmarks.
public struct LatencyStats: Sendable {
    public private(set) var smoothed: Double?
    private var samples: [Double] = []
    private var cursor = 0
    private static let capacity = 4096

    public init() {}

    public mutating func add(_ ms: Double) {
        smoothed = smoothed.map { $0 * 0.85 + ms * 0.15 } ?? ms
        if samples.count < Self.capacity { samples.append(ms) } else {
            samples[cursor] = ms
            cursor = (cursor + 1) % Self.capacity
        }
    }

    public var count: Int { samples.count }

    public func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count - 1)).rounded())))
        return sorted[index]
    }

    public mutating func reset() { samples = []; cursor = 0; smoothed = nil }
}

public struct LinkStats: Sendable {
    public var datagramsOut = 0
    public var movesSent = 0
    public var datagramsIn = 0
    public var datagramsRejected = 0
    public var eventsDelivered = 0
    public var eventsFirstByDatagram = 0
    public var eventsFirstByStream = 0
    public var redundantCopies = 0
    public var movesDelivered = 0
    public var movesStale = 0
    public init() {}
}

public enum LinkKind: String, Sendable {
    case ethernet = "Ethernet"
    case wifi = "Wi-Fi"
    case peerToPeer = "Peer-to-peer Wi-Fi"
    case vpn = "VPN"
    case loopback = "This Mac"
    case other = "Network"
}

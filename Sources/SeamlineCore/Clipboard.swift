import Foundation

public struct ClipboardPayload: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var type: String
        public var data: Data
        public init(type: String, data: Data) { self.type = type; self.data = data }
    }

    public var items: [Item]
    public init(items: [Item]) { self.items = items }

    public var byteCount: Int { items.reduce(0) { $0 + $1.data.count } }

    public static let chunkSize = 60 * 1024

    public func encoded() -> Data {
        var w = ByteWriter(capacity: byteCount + 64)
        w.varint(UInt64(items.count))
        for item in items { w.string(item.type); w.bytes(item.data) }
        let plain = w.data
        // LZFSE only when it pays: images are already compressed, text usually shrinks 3-5x.
        if plain.count > 1024, let packed = try? (plain as NSData).compressed(using: .lzfse) as Data, packed.count < plain.count {
            return Data([1]) + packed
        }
        return Data([0]) + plain
    }

    public static func decode(_ data: Data) throws -> ClipboardPayload {
        guard let flag = data.first else { throw WireError.truncated }
        var body = data.dropFirst()
        if flag == 1 {
            guard let unpacked = try? (Data(body) as NSData).decompressed(using: .lzfse) as Data else { throw WireError.invalidValue }
            body = unpacked[...]
        }
        var r = ByteReader(Data(body))
        let count = try r.varint()
        guard count <= 64 else { throw WireError.invalidValue }
        let items = try (0..<count).map { _ in Item(type: try r.string(), data: try r.bytes()) }
        return ClipboardPayload(items: items)
    }

    public func chunks(transfer: UInt32) -> [Message] {
        let data = encoded()
        let count = max(1, (data.count + Self.chunkSize - 1) / Self.chunkSize)
        return (0..<count).map { i in
            let start = data.startIndex + i * Self.chunkSize
            let end = min(start + Self.chunkSize, data.endIndex)
            return .clipboardChunk(transfer: transfer, index: UInt32(i), count: UInt32(count), bytes: data.subdata(in: start..<end))
        }
    }
}

/// Rebuilds clipboard transfers from slices. A newer transfer replaces an unfinished older one.
public struct ClipboardAssembler {
    private var transfer: UInt32?
    private var parts: [Data] = []
    private var expected = 0
    public let maxBytes: Int
    private var received = 0

    public init(maxBytes: Int = 64 << 20) { self.maxBytes = maxBytes }

    public mutating func add(transfer id: UInt32, index: UInt32, count: UInt32, bytes: Data) throws -> ClipboardPayload? {
        if transfer != id {
            guard count > 0, Int(count) * ClipboardPayload.chunkSize <= maxBytes + ClipboardPayload.chunkSize else { throw WireError.invalidValue }
            transfer = id
            parts = []
            expected = Int(count)
            received = 0
        }
        guard Int(index) == parts.count, Int(count) == expected else {
            transfer = nil
            throw WireError.invalidValue
        }
        parts.append(bytes)
        received += bytes.count
        guard received <= maxBytes else { transfer = nil; throw WireError.invalidValue }
        guard parts.count == expected else { return nil }
        transfer = nil
        let whole = parts.reduce(into: Data(capacity: received)) { $0.append($1) }
        parts = []
        return try ClipboardPayload.decode(whole)
    }
}

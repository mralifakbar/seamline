import Foundation

public enum WireError: Error, Equatable {
    case truncated
    case unknownMessage(UInt8)
    case invalidValue
    case frameTooLarge(Int)
}

/// Little-endian binary writer. Everything on the wire goes through here.
public struct ByteWriter {
    public private(set) var data: Data

    public init(capacity: Int = 32) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }

    public mutating func u16(_ v: UInt16) { append(v.littleEndian) }
    public mutating func u32(_ v: UInt32) { append(v.littleEndian) }
    public mutating func u64(_ v: UInt64) { append(v.littleEndian) }
    public mutating func i16(_ v: Int16) { append(v.littleEndian) }
    public mutating func i32(_ v: Int32) { append(v.littleEndian) }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }

    public mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    public mutating func bytes(_ d: Data) {
        varint(UInt64(d.count))
        data.append(d)
    }

    public mutating func raw(_ d: Data) { data.append(d) }

    public mutating func string(_ s: String) { bytes(Data(s.utf8)) }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
    }
}

public struct ByteReader {
    private let data: Data
    private var offset: Data.Index

    public init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    public var isAtEnd: Bool { offset >= data.endIndex }
    public var remaining: Int { data.endIndex - offset }

    public mutating func u8() throws -> UInt8 {
        guard offset < data.endIndex else { throw WireError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func bool() throws -> Bool { try u8() != 0 }
    public mutating func u16() throws -> UInt16 { try fixed() }
    public mutating func u32() throws -> UInt32 { try fixed() }
    public mutating func u64() throws -> UInt64 { try fixed() }
    public mutating func i16() throws -> Int16 { try fixed() }
    public mutating func i32() throws -> Int32 { try fixed() }
    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    public mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    public mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            guard shift < 64 else { throw WireError.invalidValue }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    public mutating func raw(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    public mutating func bytes(limit: Int = 64 << 20) throws -> Data {
        let count = try varint()
        guard count <= UInt64(limit) else { throw WireError.invalidValue }
        return try raw(Int(count))
    }

    public mutating func string() throws -> String {
        guard let s = String(data: try bytes(limit: 4096), encoding: .utf8) else { throw WireError.invalidValue }
        return s
    }

    private mutating func fixed<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw WireError.truncated }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self), from: offset..<(offset + size))
        }
        offset += size
        return T(littleEndian: value)
    }
}

/// Splits a TCP byte stream into frames prefixed by a 4-byte big-endian length.
public struct FrameReader {
    public var maxFrame: Int
    private var buffer = Data()
    private var start = 0

    public init(maxFrame: Int) { self.maxFrame = maxFrame }

    public mutating func append(_ chunk: Data) { buffer.append(chunk) }

    public mutating func next() throws -> Data? {
        let available = buffer.count - start
        guard available >= 4 else { compactIfNeeded(); return nil }
        let base = buffer.startIndex + start
        let length = Int(buffer[base]) << 24 | Int(buffer[base + 1]) << 16 | Int(buffer[base + 2]) << 8 | Int(buffer[base + 3])
        guard length <= maxFrame else { throw WireError.frameTooLarge(length) }
        guard available >= 4 + length else { compactIfNeeded(); return nil }
        let frame = buffer.subdata(in: (base + 4)..<(base + 4 + length))
        start += 4 + length
        return frame
    }

    /// Drops consumed bytes once they dominate the buffer, so reads stay amortized O(n).
    private mutating func compactIfNeeded() {
        if start > 0, start >= buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + start))
            start = 0
        }
    }

    public static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        let n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: n) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

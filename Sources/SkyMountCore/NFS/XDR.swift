import Foundation

/// XDR (RFC 4506) decoding over a received RPC record.
struct XDRReader {
    private let data: Data
    private(set) var offset: Int

    struct Underflow: Error {}

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func u32() throws -> UInt32 {
        guard offset + 4 <= data.endIndex else { throw Underflow() }
        let v = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return v
    }

    mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }
    mutating func bool() throws -> Bool { try u32() != 0 }

    mutating func fixed(_ n: Int) throws -> Data {
        let padded = (n + 3) & ~3
        guard n >= 0, offset + padded <= data.endIndex else { throw Underflow() }
        let out = data[offset..<offset + n]
        offset += padded
        return Data(out)
    }

    mutating func opaque(max: Int = 1 << 24) throws -> Data {
        let n = Int(try u32())
        guard n <= max else { throw Underflow() }
        return try fixed(n)
    }

    /// Bytes not consumed yet.
    var remaining: Data { Data(data[offset..<data.endIndex]) }

    mutating func string() throws -> String {
        String(decoding: try opaque(max: 4096), as: UTF8.self)
    }
}

/// XDR encoding for replies.
struct XDRWriter {
    private(set) var data = Data()

    init(capacity: Int = 256) { data.reserveCapacity(capacity) }

    mutating func u32(_ v: UInt32) {
        data.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
    mutating func bool(_ v: Bool) { u32(v ? 1 : 0) }

    mutating func fixed(_ d: Data) {
        data.append(d)
        let pad = (4 - d.count % 4) % 4
        if pad > 0 { data.append(contentsOf: [UInt8](repeating: 0, count: pad)) }
    }

    mutating func opaque(_ d: Data) {
        u32(UInt32(d.count))
        fixed(d)
    }

    mutating func string(_ s: String) { opaque(Data(s.utf8)) }
}

import Foundation

/// Wire format: every message is
///   [type: UInt8][length: UInt32 big-endian][payload: length bytes]
/// carried inside the TLS connection. Unknown types are skipped, so newer
/// versions can add messages without breaking older ones.
public enum MessageType: UInt8 {
    /// client -> host. Payload: protocol version (UInt16).
    case hello = 1
    /// host -> client. Payload: `VideoFramePacket`.
    case videoFrame = 2
    /// client -> host. Empty payload. Sent after a decode error or on start.
    case requestKeyframe = 3
    // 10...19 reserved for input events (milestone 2).
}

public let protocolVersion: UInt16 = 1
public let maxPayloadSize = 32 * 1024 * 1024

public struct ProtocolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - Byte helpers

public struct ByteWriter {
    public private(set) var data = Data()
    public init(capacity: Int = 0) { data.reserveCapacity(capacity) }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func bytes(_ d: Data) { data.append(d) }
}

public struct ByteReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw ProtocolError("truncated message") }
        let slice = data[offset..<(offset + n)]
        offset += n
        return slice
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let slice = try take(MemoryLayout<T>.size)
        return slice.reduce(T(0)) { ($0 << 8) | T($1) }
    }

    public mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try integer(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    public mutating func bytes(_ n: Int) throws -> Data { Data(try take(n)) }
    public mutating func rest() -> Data { Data((try? take(remaining)) ?? Data()) }
}

// MARK: - Messages

/// One encoded H.264 frame in AVCC form (4-byte length-prefixed NAL units),
/// exactly as VideoToolbox produces it. Keyframes carry SPS/PPS so the
/// client can (re)build its decoder from any keyframe.
public struct VideoFramePacket: Equatable, Sendable {
    public var isKeyframe: Bool
    public var presentationTimeMicros: UInt64
    public var parameterSets: [Data]
    public var avccData: Data

    public init(isKeyframe: Bool, presentationTimeMicros: UInt64, parameterSets: [Data], avccData: Data) {
        self.isKeyframe = isKeyframe
        self.presentationTimeMicros = presentationTimeMicros
        self.parameterSets = parameterSets
        self.avccData = avccData
    }

    public func encoded() -> Data {
        var w = ByteWriter(capacity: avccData.count + 64)
        w.u8(isKeyframe ? 1 : 0)
        w.u64(presentationTimeMicros)
        w.u8(UInt8(parameterSets.count))
        for set in parameterSets {
            w.u16(UInt16(set.count))
            w.bytes(set)
        }
        w.bytes(avccData)
        return w.data
    }

    public static func decode(_ data: Data) throws -> VideoFramePacket {
        var r = ByteReader(data)
        let flags = try r.u8()
        let pts = try r.u64()
        let count = Int(try r.u8())
        var sets: [Data] = []
        for _ in 0..<count {
            let len = Int(try r.u16())
            sets.append(try r.bytes(len))
        }
        return VideoFramePacket(
            isKeyframe: flags & 1 != 0,
            presentationTimeMicros: pts,
            parameterSets: sets,
            avccData: r.rest()
        )
    }
}

public enum Hello {
    public static func encode(version: UInt16 = protocolVersion) -> Data {
        var w = ByteWriter()
        w.u16(version)
        return w.data
    }

    public static func decode(_ data: Data) throws -> UInt16 {
        var r = ByteReader(data)
        return try r.u16()
    }
}

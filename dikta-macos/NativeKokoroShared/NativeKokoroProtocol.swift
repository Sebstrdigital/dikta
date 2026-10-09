import Foundation

// Version 1 private bounded transport. Runtime controls are qualification-only.
public enum NKError: Error, Equatable { case framing, version, oversized, sequence, identity, audio, backpressure, closed, launch, timeout }
public enum NKKind: UInt16 {
    case hello = 1, ready, blockedWork, cancel, cancelled, shutdown, audio, failed
    case describe, layout, initialize, synthesize, phase, complete, loopback
}
public enum NKPhase: UInt8 { case initializing = 1, synthesizing }
public enum NKControl {
    // No arbitrary paths/URLs/asset identities are accepted from the parent.
    public static func validate(_ frame: NKFrame) throws {
        switch frame.kind {
        case .hello, .blockedWork, .cancel, .shutdown, .describe, .initialize:
            guard frame.payload.isEmpty else { throw NKError.framing }
        case .synthesize:
            guard let text = String(data: frame.payload, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  frame.payload.count <= 1024,
                  text.split(whereSeparator: { $0.isWhitespace }).count <= 64,
                  text.split(whereSeparator: { $0.isWhitespace }).allSatisfy({ $0.count <= 62 }),
                  !text.unicodeScalars.contains(where: { $0.value < 32 && !$0.properties.isWhitespace }) else { throw NKError.framing }
        case .loopback:
            guard frame.payload.count == 2,
                  frame.payload.nkInteger(0, as: UInt16.self) >= 49152 else { throw NKError.framing }
        default: throw NKError.identity
        }
    }
    public static func failure(_ data: Data) throws -> NKRuntimeFailure {
        guard data.count == 1, let failure = NKRuntimeFailure(rawValue: data[0]) else { throw NKError.framing }
        return failure
    }
    public static func phase(_ data: Data) throws -> NKPhase {
        guard data.count == 1, let phase = NKPhase(rawValue: data[0]) else { throw NKError.framing }
        return phase
    }
}
public struct NKFrame: Equatable {
    public var kind: NKKind
    public var session: UInt64
    public var request: UInt64
    public var sequence: UInt32
    public var payload: Data
    public init(_ kind: NKKind, session: UInt64, request: UInt64 = 0, sequence: UInt32 = 0, payload: Data = Data()) {
        self.kind = kind; self.session = session; self.request = request; self.sequence = sequence; self.payload = payload
    }
    public static let headerSize = 32
    public static let maxPayload = 1_048_576
    public func encoded() throws -> Data {
        guard payload.count <= Self.maxPayload, kind == .audio || payload.count <= 4096 else { throw NKError.oversized }
        var data = Data([0x4e, 0x4b, 0x50, 0x31])
        data.nkAppend(UInt16(1)); data.nkAppend(kind.rawValue); data.nkAppend(UInt32(payload.count))
        data.nkAppend(session); data.nkAppend(request); data.nkAppend(sequence); data.append(payload)
        return data
    }
}
public extension Data {
    mutating func nkAppend<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    func nkInteger<T: FixedWidthInteger>(_ offset: Int, as: T.Type) -> T {
        (offset..<(offset + MemoryLayout<T>.size)).reduce(T(0)) { ($0 << 8) | T(self[startIndex + $1]) }
    }
}
// Incrementally accepts at most a validated frame, never an attacker-sized input buffer.
public struct NKDecoder {
    private var buffer = Data()
    private var expected = NKFrame.headerSize
    public init() {}
    public var bufferedBytes: Int { buffer.count }
    public mutating func feed(_ input: Data, consume: (NKFrame) throws -> Void) throws {
        var offset = 0
        while offset < input.count {
            let n = min(expected - buffer.count, input.count - offset)
            buffer.append(input.subdata(in: offset..<(offset + n))); offset += n
            if buffer.count == NKFrame.headerSize && expected == NKFrame.headerSize {
                guard Array(buffer.prefix(4)) == [0x4e, 0x4b, 0x50, 0x31] else { throw NKError.framing }
                guard buffer.nkInteger(4, as: UInt16.self) == 1 else { throw NKError.version }
                guard let kind = NKKind(rawValue: buffer.nkInteger(6, as: UInt16.self)) else { throw NKError.framing }
                let size = Int(buffer.nkInteger(8, as: UInt32.self))
                guard size <= NKFrame.maxPayload, kind == .audio || size <= 4096 else { throw NKError.oversized }
                expected += size
            }
            if buffer.count == expected {
                let frame = NKFrame(NKKind(rawValue: buffer.nkInteger(6, as: UInt16.self))!,
                    session: buffer.nkInteger(12, as: UInt64.self), request: buffer.nkInteger(20, as: UInt64.self),
                    sequence: buffer.nkInteger(28, as: UInt32.self), payload: Data(buffer.dropFirst(NKFrame.headerSize)))
                buffer.removeAll(keepingCapacity: false); expected = NKFrame.headerSize
                try consume(frame)
            }
        }
    }
    public func finish() throws { if !buffer.isEmpty { throw NKError.framing } }
}
public struct NKIdentityGate {
    public let session: UInt64
    public var request: UInt64
    private var next: UInt32 = 0
    public init(session: UInt64, request: UInt64 = 0) { self.session = session; self.request = request }
    // Stale identities do not advance current sequence; impossible same-session ordering is fatal.
    public mutating func accept(_ frame: NKFrame) throws -> Bool {
        guard frame.session == session, frame.request == request else { return false }
        guard frame.sequence == next, next < UInt32.max else { throw NKError.sequence }
        next += 1; return true
    }
}
public struct NKOutbox {
    public static let maxBytes = 2 * (NKFrame.maxPayload + NKFrame.headerSize)
    public static let maxFrames = 4
    private var frames: [Data] = []
    private var offset = 0
    public private(set) var bytes = 0
    public init() {}
    public mutating func enqueue(_ frame: NKFrame) throws {
        let data = try frame.encoded()
        guard frames.count < Self.maxFrames, bytes + data.count <= Self.maxBytes else { throw NKError.backpressure }
        frames.append(data); bytes += data.count
    }
    public mutating func flush(write: (Data) throws -> Int) throws {
        guard let head = frames.first else { return }
        let part = Data(head.dropFirst(offset).prefix(16_384))
        let n = try write(part)
        guard n >= 0, n <= part.count else { throw NKError.closed }
        offset += n; bytes -= n
        if offset == head.count { frames.removeFirst(); offset = 0 }
    }
    public mutating func clear() { frames.removeAll(); offset = 0; bytes = 0 }
}
// Binary audio shape reserved for later synthesis: canonical mono PCM16 WAV at 24 kHz.
// Exact canonical header prevents embedded metadata and oversized/ambiguous chunk layouts.
public enum NKAudio {
    public static func validate(_ data: Data) throws {
        func le(_ p: Int, _ n: Int) -> UInt32 { (0..<n).reduce(0) { $0 | (UInt32(data[p + $1]) << (8 * $1)) } }
        guard data.count >= 46, data.count <= NKFrame.maxPayload,
              Array(data[0..<4]) == Array("RIFF".utf8), Array(data[8..<12]) == Array("WAVE".utf8),
              Array(data[12..<16]) == Array("fmt ".utf8), Array(data[36..<40]) == Array("data".utf8),
              le(4,4) == data.count - 8, le(16,4) == 16, le(20,2) == 1, le(22,2) == 1,
              le(24,4) == 24000, le(28,4) == 48000, le(32,2) == 2, le(34,2) == 16,
              le(40,4) == data.count - 44, (data.count - 44) % 2 == 0 else { throw NKError.audio }
    }
}

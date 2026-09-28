import Foundation

/// Wire format: [4-byte big-endian payload length][1-byte type][payload]
/// Length counts the type byte plus the payload.
enum PacketType: UInt8 {
    case hello  = 1   // JSON: sender name + geometry + codec
    case format = 2   // codec parameter sets, length-prefixed each
    case frame  = 3   // [1 byte keyframe flag][access unit]
    case bye    = 4
    case caps   = 5   // JSON: what the receiver can decode. Sent first, by the receiver.
}

/// H.264 hardware encoding stops at 4096x2304 on Apple silicon, so a real 5K
/// desktop has to go through HEVC. Older builds only speak H.264, hence the
/// negotiation.
enum VideoCodec: String, Codable, CaseIterable {
    case h264, hevc
    var displayName: String { self == .hevc ? "HEVC" : "H.264" }
}

/// Sent by the receiver the moment it connects. A sender that gets nothing
/// within a short window assumes an old receiver and falls back to H.264.
struct Capabilities: Codable {
    var codecs: [String]          // codec rawValues this receiver can decode
    var maxWidth: Int
    var maxHeight: Int
    var appVersion: String

    var decodes: Set<VideoCodec> {
        Set(codecs.compactMap { VideoCodec(rawValue: $0) })
    }
}

struct Hello: Codable {
    var name: String
    var width: Int
    var height: Int
    var fps: Int
    var mode: String        // "mirror" or "extend"
    var codec: String?      // nil means h264, for older receivers
}

enum Packet {
    static func encode(_ type: PacketType, _ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        var len = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(payload)
        return out
    }
}

/// Incremental parser. Rejects absurd lengths rather than allocating wildly —
/// a truncated or hostile stream must not be able to exhaust memory.
final class PacketParser {
    private var buffer = Data()
    private static let maxPayload = 64 * 1024 * 1024

    enum ParseError: Error { case oversized(Int) }

    func append(_ data: Data) { buffer.append(data) }

    func next() throws -> (PacketType, Data)? {
        while true {
            guard buffer.count >= 4 else { return nil }
            let len = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let total = Int(len)
            if total < 1 || total > Self.maxPayload { throw ParseError.oversized(total) }
            guard buffer.count >= 4 + total else { return nil }
            let typeByte = buffer[buffer.startIndex + 4]
            let payload = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + 4 + total))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + total))
            guard let type = PacketType(rawValue: typeByte) else { continue }  // skip unknown
            return (type, payload)
        }
    }
}

/// Parameter sets carried as [4-byte len][bytes] repeated.
/// H.264 sends two (SPS, PPS); HEVC sends three (VPS, SPS, PPS).
enum ParameterSets {
    static func encode(_ sets: [Data]) -> Data {
        var out = Data()
        for s in sets {
            var l = UInt32(s.count).bigEndian
            withUnsafeBytes(of: &l) { out.append(contentsOf: $0) }
            out.append(s)
        }
        return out
    }

    static func decode(_ data: Data) -> [Data] {
        var sets: [Data] = []
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            let l = Int(data[i..<i+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            i += 4
            guard l > 0, i + l <= data.endIndex else { break }
            sets.append(data.subdata(in: i..<(i+l)))
            i += l
        }
        return sets
    }
}

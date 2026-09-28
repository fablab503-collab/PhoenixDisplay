// Minimal receiver: connects to a Phoenix sender and reports what arrives.
import Foundation
import Network

let host = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "127.0.0.1"
var buffer = Data()
var frames = 0, bytes = 0, gotFormat = false
var hello: String = "(none)"
let start = Date()

let conn = NWConnection(host: NWEndpoint.Host(host), port: 51777, using: .tcp)
func framed(_ type: UInt8, _ payload: Data) -> Data {
    var out = Data()
    var len = UInt32(payload.count + 1).bigEndian
    withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
    out.append(type)
    out.append(payload)
    return out
}

conn.stateUpdateHandler = { st in
    if case .failed(let e) = st { print("FAILED: \(e)"); exit(2) }
    if case .ready = st {
        print("connected to \(host):51777")
        // Announce HEVC support so the sender can pick it and give us 5K.
        let caps = #"{"codecs":["h264","hevc"],"maxWidth":5120,"maxHeight":2880,"appVersion":"probe"}"#
        conn.send(content: framed(5, Data(caps.utf8)), completion: .contentProcessed { _ in })
    }
}
func pump() {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
        if let data { buffer.append(data); bytes += data.count }
        while buffer.count >= 5 {
            let len = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard buffer.count >= 4 + len else { break }
            let type = buffer[buffer.startIndex + 4]
            let payload = buffer.subdata(in: (buffer.startIndex+5)..<(buffer.startIndex+4+len))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex+4+len))
            switch type {
            case 1: hello = String(data: payload, encoding: .utf8) ?? "?"
            case 2: gotFormat = true; print("format: \(payload.count) bytes of SPS/PPS")
            case 3: frames += 1
            default: break
            }
        }
        if err != nil || done { return }
        pump()
    }
}
conn.start(queue: .global())
pump()
DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
    let secs = Date().timeIntervalSince(start)
    print("hello: \(hello)")
    print("format received: \(gotFormat)")
    print("frames: \(frames) in \(String(format: "%.1f", secs))s  (\(String(format: "%.1f", Double(frames)/secs)) fps)")
    print("bytes: \(bytes) (\(String(format: "%.1f", Double(bytes)*8/secs/1_000_000)) Mbps)")
    exit(frames > 0 && gotFormat ? 0 : 1)
}
RunLoop.main.run()

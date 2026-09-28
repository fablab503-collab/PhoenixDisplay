import Foundation
import Network
import Combine
import Darwin

/// One network path the stream could take, with its measured link rate.
struct Link: Identifiable, Hashable {
    enum Kind: String {
        case wifi = "Wi-Fi"
        case ethernet = "Ethernet"
        case thunderbolt = "Thunderbolt"
        case other = "Other"

        var symbol: String {
            switch self {
            case .wifi:        return "wifi"
            case .ethernet:    return "cable.coaxial"
            case .thunderbolt: return "bolt.horizontal.fill"
            case .other:       return "network"
            }
        }
    }

    let id: String            // interface name
    let kind: Kind
    let ip: String?
    /// Link rate in bits per second, straight from the interface. 0 = unknown.
    let bitsPerSecond: UInt64
    let isUp: Bool
    /// Extra detail for Thunderbolt: what is on the other end and how fast.
    var thunderboltPeer: String?

    var speedText: String {
        guard bitsPerSecond > 0 else { return "link speed unknown" }
        let g = Double(bitsPerSecond) / 1_000_000_000
        if g >= 1 { return String(format: "%.0f Gb/s", g) }
        return String(format: "%.0f Mb/s", Double(bitsPerSecond) / 1_000_000)
    }

    var detail: String {
        var parts: [String] = [kind.rawValue]
        if let ip { parts.append(ip) } else { parts.append("no address") }
        parts.append(speedText)
        if let p = thunderboltPeer { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    var title: String {
        switch kind {
        case .thunderbolt: return "Thunderbolt Bridge (\(id))"
        case .wifi:        return "Wi-Fi (\(id))"
        case .ethernet:    return "Ethernet (\(id))"
        case .other:       return id
        }
    }
}

/// Watches the real interfaces and their link rates, live.
@MainActor
final class LinkMonitor: ObservableObject {
    @Published private(set) var links: [Link] = []
    /// The interface macOS would actually use right now.
    @Published private(set) var activeInterface: String?
    @Published private(set) var thunderboltSummary: String?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "phoenix.links")
    private var timer: Timer?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let active = path.availableInterfaces.first?.name
            Task { @MainActor in
                self?.activeInterface = active
                self?.refresh()
            }
        }
        monitor.start(queue: queue)
        refresh()
        probeThunderbolt()
        // Link rates change when a cable is plugged in, and nothing notifies us.
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.probeThunderbolt()
            }
        }
    }

    deinit { monitor.cancel(); timer?.invalidate() }

    func link(named name: String) -> Link? { links.first { $0.id == name } }

    /// Reads addresses and link rates in one pass over getifaddrs.
    /// ifi_baudrate on the AF_LINK entry is the negotiated rate — 1 Gb/s on a
    /// gigabit port, 2.5 on a 2.5G adapter, whatever Wi-Fi last negotiated.
    private func refresh() {
        var addrs: [String: String] = [:]
        var rates: [String: UInt64] = [:]
        var flags: [String: Int32] = [:]

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return }
        defer { freeifaddrs(head) }
        var cur = head
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            let name = String(cString: p.pointee.ifa_name)
            flags[name] = Int32(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr else { continue }
            if sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1" { addrs[name] = ip }
                }
            } else if sa.pointee.sa_family == UInt8(AF_LINK), let data = p.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                if d.ifi_baudrate > 0 { rates[name] = UInt64(d.ifi_baudrate) }
            }
        }

        var found: [Link] = []
        for name in Set(addrs.keys).union(rates.keys).sorted() {
            if name == "lo0" || name.hasPrefix("awdl") || name.hasPrefix("llw")
                || name.hasPrefix("utun") || name.hasPrefix("gif") || name.hasPrefix("stf")
                || name.hasPrefix("anpi") || name.hasPrefix("ap") { continue }
            let kind = Self.kind(for: name)
            // Only list things that are actually usable or plugged in.
            let up = (flags[name].map { $0 & Int32(IFF_UP) != 0 } ?? false)
                  && (addrs[name] != nil || (rates[name] ?? 0) > 0)
            guard up else { continue }
            var l = Link(id: name, kind: kind, ip: addrs[name],
                         bitsPerSecond: rates[name] ?? 0, isUp: true)
            if kind == .thunderbolt { l.thunderboltPeer = thunderboltSummary }
            found.append(l)
        }
        // Thunderbolt first, then wired, then Wi-Fi: best route at the top.
        links = found.sorted { a, b in
            func rank(_ k: Link.Kind) -> Int {
                switch k { case .thunderbolt: return 0; case .ethernet: return 1
                           case .wifi: return 2; case .other: return 3 }
            }
            if rank(a.kind) != rank(b.kind) { return rank(a.kind) < rank(b.kind) }
            return a.bitsPerSecond > b.bitsPerSecond
        }
    }

    private static func kind(for name: String) -> Link.Kind {
        if name.hasPrefix("bridge") { return .thunderbolt }
        if name.hasPrefix("en") {
            // On Apple silicon en0 is Wi-Fi; Thunderbolt/USB adapters are higher.
            return name == "en0" ? .wifi : .ethernet
        }
        return .other
    }

    /// Asks the system whether a Thunderbolt device is actually attached, and
    /// at what rate. This is what tells 3 from 4 (20 vs 40 Gb/s).
    private func probeThunderbolt() {
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPThunderboltDataType", "-detailLevel", "mini"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return }

            // Pair each "Device connected" with the speed that follows it, and
            // with the device name that comes after, skipping this Mac itself.
            var summary: String?
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            var speed: String?
            for (i, l) in lines.enumerated() where l.hasPrefix("Speed:") {
                let s = l.replacingOccurrences(of: "Speed:", with: "").trimmingCharacters(in: .whitespaces)
                guard !s.hasPrefix("Up to") else { continue }     // nothing plugged in
                speed = s
                // The attached device's name appears a little further down.
                for j in i..<min(i + 12, lines.count) {
                    if lines[j].hasPrefix("Device Name:") {
                        let n = lines[j].replacingOccurrences(of: "Device Name:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if !n.contains("MacBook") && !n.contains("iMac Pro") {
                            summary = "\(n) at \(s)"
                        }
                    }
                }
                if summary == nil { summary = "device at \(s)" }
                break
            }
            if summary == nil, speed == nil { summary = nil }
            let final = summary
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.thunderboltSummary != final {
                    self.thunderboltSummary = final
                    self.refresh()
                }
            }
        }
    }
}

import Foundation
import Network
import Combine

/// A network interface the user can pin the stream to.
/// "Automatic" lets the system choose; everything else is a real interface
/// so Thunderbolt Bridge / a USB ethernet adapter / Wi-Fi can be forced.
struct TransportOption: Identifiable, Hashable {
    let id: String              // interface name, or "auto"
    let title: String
    let subtitle: String
    let interface: NWInterface?

    static let auto = TransportOption(id: "auto",
                                      title: "Automatic",
                                      subtitle: "Let macOS pick the best route",
                                      interface: nil)
}

@MainActor
final class TransportSelector: ObservableObject {
    @Published private(set) var options: [TransportOption] = [.auto]
    @Published var selectedID: String = "auto" {
        didSet { UserDefaults.standard.set(selectedID, forKey: "phoenix.transport") }
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "phoenix.transport.monitor")

    init() {
        selectedID = UserDefaults.standard.string(forKey: "phoenix.transport") ?? "auto"
        monitor.pathUpdateHandler = { [weak self] path in
            let found = path.availableInterfaces
            Task { @MainActor in self?.rebuild(found) }
        }
        monitor.start(queue: queue)
        rebuild(monitor.currentPath.availableInterfaces)
    }

    deinit { monitor.cancel() }

    var selected: TransportOption {
        options.first { $0.id == selectedID } ?? .auto
    }

    /// Builds NWParameters for the chosen route. Falls back to automatic when
    /// the pinned interface has gone away, rather than failing the connection.
    func parameters() -> NWParameters {
        let p = NWParameters.tcp
        if let tcp = p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
        }
        p.includePeerToPeer = true
        if let iface = selected.interface,
           monitor.currentPath.availableInterfaces.contains(where: { $0.name == iface.name }) {
            p.requiredInterface = iface
        }
        return p
    }

    /// Human-readable note about what the stream will actually use.
    var routeDescription: String {
        guard let iface = selected.interface else { return "Automatic" }
        return "\(iface.name) — \(Self.kindLabel(iface.type))"
    }

    private func rebuild(_ interfaces: [NWInterface]) {
        var list: [TransportOption] = [.auto]
        let addrs = Self.addressesByInterface()
        for iface in interfaces {
            // Skip loopback and Apple's awdl/llw peer-to-peer helpers.
            guard iface.type != .loopback else { continue }
            if iface.name.hasPrefix("awdl") || iface.name.hasPrefix("llw") { continue }
            let ip = addrs[iface.name]
            let kind = Self.kindLabel(iface.type)
            let sub: String
            if let ip { sub = "\(kind) · \(ip)" } else { sub = "\(kind) · no address" }
            list.append(TransportOption(id: iface.name,
                                        title: Self.friendlyName(iface),
                                        subtitle: sub,
                                        interface: iface))
        }
        options = list
        if !list.contains(where: { $0.id == selectedID }) { selectedID = "auto" }
    }

    static func kindLabel(_ t: NWInterface.InterfaceType) -> String {
        switch t {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .loopback: return "Loopback"
        default: return "Other"
        }
    }

    /// bridge0 is what Thunderbolt Bridge shows up as; label it plainly so the
    /// cable case is obvious in the picker.
    private static func friendlyName(_ iface: NWInterface) -> String {
        if iface.name.hasPrefix("bridge") { return "Thunderbolt Bridge (\(iface.name))" }
        if iface.type == .wifi { return "Wi-Fi (\(iface.name))" }
        if iface.type == .wiredEthernet { return "Ethernet (\(iface.name))" }
        return iface.name
    }

    /// IPv4 address per interface, read straight from getifaddrs.
    static func addressesByInterface() -> [String: String] {
        var out: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if ip != "127.0.0.1" { out[name] = ip }
            }
        }
        return out
    }

    /// Every local IPv4 address, for the "this Mac's addresses" hint.
    static func localAddresses() -> [String] {
        Array(addressesByInterface().values).sorted()
    }
}

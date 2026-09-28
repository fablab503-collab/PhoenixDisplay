import Foundation
import Network

let phoenixServiceType = "_phoenixdisplay._tcp"

// MARK: - Sender side (advertises, waits for a display to attach)

/// Holds the live connection so video frames can be written straight from the
/// encoder's thread. Version 2.0.0 hopped every single frame through the main
/// actor, which serialised the whole stream behind the UI and was the main
/// source of stutter.
final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var conn: NWConnection?
    private var inFlight = 0
    /// Frames dropped because the link was still busy with the previous one.
    private(set) var dropped = 0

    func set(_ c: NWConnection?) {
        lock.lock(); conn = c; inFlight = 0; lock.unlock()
    }

    /// Control messages always go. They are tiny and must not be lost.
    func sendReliable(_ data: Data) {
        lock.lock(); let c = conn; lock.unlock()
        c?.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Video frames are dropped rather than queued when the link is behind.
    /// A backlog only adds latency — the next frame is always more useful than
    /// a stale one.
    func sendFrame(_ data: Data, maxInFlight: Int = 2) {
        lock.lock()
        guard let c = conn, inFlight < maxInFlight else {
            if conn != nil { dropped &+= 1 }
            lock.unlock(); return
        }
        inFlight += 1
        lock.unlock()
        c.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.inFlight -= 1; self.lock.unlock()
        })
    }
}



@MainActor
final class NetSender: ObservableObject {
    enum State: Equatable {
        case idle
        case advertising
        case connected(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Fires once the receiver's capabilities are known (or the wait timed out,
    /// in which case caps is nil and the sender assumes an old H.264-only peer).
    var onConnect: ((Capabilities?) -> Void)?
    var onDisconnect: (() -> Void)?
    private var capsParser = PacketParser()
    private var capsDelivered = false
    /// Each accepted connection gets a number. Late events from a connection
    /// that has already been replaced must not touch the current one's state —
    /// a stale .cancelled arriving after the new link is up was wiping the
    /// negotiated capabilities, which silently dropped the codec to H.264.
    private var generation = 0

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "phoenix.net.sender", qos: .userInteractive)
    /// Shared with the encoder so frames never touch the main actor.
    let box = ConnectionBox()

    func start(name: String, parameters: NWParameters) {
        stop()
        do {
            let l = try NWListener(using: parameters, on: 51777)
            l.service = NWListener.Service(name: name, type: phoenixServiceType)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.adopt(conn) }
            }
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    switch st {
                    case .ready: if self?.connection == nil { self?.state = .advertising }
                    case .failed(let e): self?.state = .failed(e.localizedDescription)
                    default: break
                    }
                }
            }
            listener = l
            l.start(queue: queue)
            state = .advertising
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        connection?.cancel(); connection = nil
        box.set(nil)
        listener?.cancel();  listener = nil
        state = .idle
    }

    private func adopt(_ conn: NWConnection) {
        // One display at a time: a second attach replaces the first.
        connection?.cancel()
        connection = conn
        generation &+= 1
        let mine = generation
        conn.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                switch st {
                case .ready:
                    let who = conn.endpoint.debugDescription
                    self.box.set(conn)
                    self.state = .connected(who)
                    self.capsDelivered = false
                    self.capsParser = PacketParser()
                    self.readCaps(from: conn)
                    // Don't wait forever: an older receiver sends nothing at all.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self.deliverCaps(nil)
                    }
                case .failed(let e):
                    self.box.set(nil)
                    self.state = .failed(e.localizedDescription)
                    self.onDisconnect?()
                case .cancelled:
                    self.box.set(nil)
                    if case .connected = self.state { self.state = .advertising }
                    self.onDisconnect?()
                default: break
                }
            }
        }
        conn.start(queue: queue)
    }

    var isConnected: Bool { if case .connected = state { return true }; return false }

    /// Reads the capability packet the receiver sends immediately on connect.
    private func readCaps(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.capsParser.append(data)
                    while let pair = ((try? self.capsParser.next()) ?? nil) {
                        if pair.0 == .caps,
                           let caps = try? JSONDecoder().decode(Capabilities.self, from: pair.1) {
                            self.deliverCaps(caps)
                        }
                    }
                }
            }
            if error != nil || isDone { return }
            self.readCaps(from: conn)
        }
    }

    /// Only the first call counts — whichever arrives first, the packet or the timeout.
    private func deliverCaps(_ caps: Capabilities?) {
        guard !capsDelivered, isConnected else { return }
        capsDelivered = true
        onConnect?(caps)
    }

    func send(_ type: PacketType, _ payload: Data) {
        box.sendReliable(Packet.encode(type, payload))
    }
}

// MARK: - Receiver side (browses, then attaches to a chosen sender)

struct DiscoveredSender: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

@MainActor
final class NetReceiver: ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case browsing
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    @Published private(set) var state: State = .browsing
    @Published private(set) var found: [DiscoveredSender] = []

    /// Delivered on the main actor, already framed.
    var onPacket: ((PacketType, Data) -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private nonisolated let parser = PacketParser()
    private nonisolated let parserLock = NSLock()
    private let queue = DispatchQueue(label: "phoenix.net.receiver", qos: .userInteractive)

    func startBrowsing(parameters: NWParameters) {
        browser?.cancel()
        let desc = NWBrowser.Descriptor.bonjour(type: phoenixServiceType, domain: nil)
        let b = NWBrowser(for: desc, using: parameters)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.found = results.compactMap { r in
                    guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                    return DiscoveredSender(id: name, name: name, endpoint: r.endpoint)
                }.sorted { $0.name < $1.name }
            }
        }
        b.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                if case .failed(let e) = st { self?.state = .failed(e.localizedDescription) }
            }
        }
        browser = b
        b.start(queue: queue)
        state = .browsing
    }

    func connect(to sender: DiscoveredSender, parameters: NWParameters) {
        connect(endpoint: sender.endpoint, label: sender.name, parameters: parameters)
    }

    /// Manual fallback for when Bonjour is blocked but the IP is known.
    func connect(host: String, port: UInt16, parameters: NWParameters) {
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                     port: NWEndpoint.Port(rawValue: port) ?? 51777)
        connect(endpoint: ep, label: host, parameters: parameters)
    }

    private func connect(endpoint: NWEndpoint, label: String, parameters: NWParameters) {
        connection?.cancel()
        let c = NWConnection(to: endpoint, using: parameters)
        c.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .ready:
                    self.state = .connected(label)
                    // Tell the sender what this Mac can decode, so it can pick
                    // HEVC and give us a real 5K picture when both ends allow.
                    if let caps = try? JSONEncoder().encode(DecodeCapability.local()) {
                        let packet = Packet.encode(.caps, caps)
                        c.send(content: packet, completion: .contentProcessed { _ in })
                        // Send it again shortly after: if the sender was still
                        // wiring up its read loop, the first one can be missed,
                        // and the cost of a duplicate is nothing.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            c.send(content: packet, completion: .contentProcessed { _ in })
                        }
                    }
                    self.receive(on: c)
                case .failed(let e):
                    self.state = .failed(e.localizedDescription)
                case .cancelled:
                    if case .connected = self.state { self.state = .browsing }
                default: break
                }
            }
        }
        connection = c
        state = .connecting(label)
        c.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel(); connection = nil
        state = .browsing
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                // Framing happens on the network queue; only finished packets
                // reach the main actor.
                let packets = self.drain(data)
                if !packets.isEmpty {
                    Task { @MainActor in
                        for (t, p) in packets { self.onPacket?(t, p) }
                    }
                }
            }
            if let error {
                Task { @MainActor in self.state = .failed(error.localizedDescription) }
                return
            }
            if isDone {
                Task { @MainActor in self.state = .browsing }
                return
            }
            self.receive(on: conn)
        }
    }

    /// Runs on the network queue. The parser is only ever touched there.
    private nonisolated func drain(_ data: Data) -> [(PacketType, Data)] {
        parserLock.lock(); defer { parserLock.unlock() }
        parser.append(data)
        var out: [(PacketType, Data)] = []
        while let pair = ((try? parser.next()) ?? nil) { out.append(pair) }
        return out
    }
}

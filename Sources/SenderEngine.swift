import Foundation
import CoreGraphics
import Combine

enum DisplayMode: String, CaseIterable, Identifiable {
    case mirror, extend
    var id: String { rawValue }
    var title: String { self == .mirror ? "Mirror this Mac" : "Use as a separate display" }
    var detail: String {
        self == .mirror ? "Show the same picture as this Mac"
                        : "Add a second desktop you can drag windows onto"
    }
    var symbol: String { self == .mirror ? "rectangle.on.rectangle" : "rectangle.split.2x1" }
}

enum ScreenPosition: String, CaseIterable, Identifiable {
    case right, left, above, below
    var id: String { rawValue }
    var title: String {
        switch self {
        case .right: return "To the right"
        case .left:  return "To the left"
        case .above: return "Above"
        case .below: return "Below"
        }
    }
    var detail: String {
        switch self {
        case .right: return "Move the pointer off the right edge to reach it"
        case .left:  return "Move the pointer off the left edge to reach it"
        case .above: return "Move the pointer off the top edge to reach it"
        case .below: return "Move the pointer off the bottom edge to reach it"
        }
    }
    var symbol: String {
        switch self {
        case .right: return "rectangle.righthalf.inset.filled"
        case .left:  return "rectangle.lefthalf.inset.filled"
        case .above: return "rectangle.tophalf.inset.filled"
        case .below: return "rectangle.bottomhalf.inset.filled"
        }
    }
    var raw: PhoenixVDPosition {
        switch self {
        case .right: return .right
        case .left:  return .left
        case .above: return .above
        case .below: return .below
        }
    }
}

struct Preset: Identifiable, Hashable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    var label: String { "\(width) × \(height)" }

    /// 4096×2304 is Apple's hardware H.264 ceiling; nothing above it is offered
    /// because the encoder would simply refuse the session.
    static let all: [Preset] = [
        Preset(id: "native",  title: "Match this Mac",  width: 0,    height: 0),
        Preset(id: "5k",      title: "5K",              width: 5120, height: 2880),
        Preset(id: "4k",      title: "4K",              width: 3840, height: 2160),
        Preset(id: "1440p",   title: "1440p",           width: 2560, height: 1440),
        Preset(id: "1080p",   title: "1080p",           width: 1920, height: 1080),
        Preset(id: "720p",    title: "720p",            width: 1280, height: 720),
    ]
}

struct Quality: Identifiable, Hashable {
    let id: String
    let title: String
    let fps: Int
    let bitrate: Int
    var detail: String { "\(fps) fps · \(bitrate / 1_000_000) Mbps" }

    /// Peak demand, not the average: the encoder is allowed 1.8x for keyframes,
    /// and a link that cannot absorb the peak stutters even if the average fits.
    var peakBitsPerSecond: UInt64 { UInt64(Double(bitrate) * 1.8) }

    enum Headroom { case plenty, comfortable, tight, tooMuch, unknown }

    /// Can a given link actually carry this? nil link speed means unknown.
    func headroom(onLinkOf bitsPerSecond: UInt64) -> Headroom {
        guard bitsPerSecond > 0 else { return .unknown }
        let ratio = Double(peakBitsPerSecond) / Double(bitsPerSecond)
        if ratio <= 0.25 { return .plenty }
        if ratio <= 0.50 { return .comfortable }
        if ratio <= 0.85 { return .tight }
        return .tooMuch
    }
}

extension Quality.Headroom {
    var text: String {
        switch self {
        case .plenty:      return "plenty of headroom"
        case .comfortable: return "comfortable"
        case .tight:       return "tight — expect the odd stutter"
        case .tooMuch:     return "more than this link can carry"
        case .unknown:     return "link speed unknown"
        }
    }
    var isProblem: Bool { self == .tight || self == .tooMuch }
}

extension Quality {
    // Sized for 5120x2880 desktop content. Even the highest is well under a
    // gigabit link, so there is no reason to starve text.
    static let all: [Quality] = [
        Quality(id: "sharp",    title: "Sharp",    fps: 30, bitrate: 80_000_000),
        Quality(id: "balanced", title: "Balanced", fps: 45, bitrate: 100_000_000),
        Quality(id: "smooth",   title: "Smooth",   fps: 60, bitrate: 120_000_000),
    ]
}

/// Everything the sender needs, persisted so it survives a relaunch.
/// 1.4 forgot the mode on every launch, which is why it always came back
/// as Mirror; all three values are written to UserDefaults here.
@MainActor
final class PhoenixSettings: ObservableObject {
    @Published var mode: DisplayMode { didSet { save("phoenix.mode", mode.rawValue) } }
    @Published var presetID: String  { didSet { save("phoenix.preset", presetID) } }
    @Published var qualityID: String { didSet { save("phoenix.quality", qualityID) } }
    @Published var position: ScreenPosition { didSet { save("phoenix.position", position.rawValue) } }
    /// Put the menu bar on the streamed screen, so the iMac becomes the primary monitor.
    @Published var makeMain: Bool { didSet { UserDefaults.standard.set(makeMain, forKey: "phoenix.makeMain") } }

    init() {
        let d = UserDefaults.standard
        mode      = DisplayMode(rawValue: d.string(forKey: "phoenix.mode") ?? "") ?? .mirror
        presetID  = d.string(forKey: "phoenix.preset")  ?? "native"
        qualityID = d.string(forKey: "phoenix.quality") ?? "balanced"
        position  = ScreenPosition(rawValue: d.string(forKey: "phoenix.position") ?? "") ?? .right
        makeMain  = d.bool(forKey: "phoenix.makeMain")
    }

    private func save(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var preset: Preset  { Preset.all.first { $0.id == presetID } ?? Preset.all[0] }
    var quality: Quality { Quality.all.first { $0.id == qualityID } ?? Quality.all[1] }

    /// Resolved capture size, clamped to what the chosen codec can actually
    /// encode on this Mac. H.264 stops at 4096x2304; HEVC reaches 5K and beyond.
    func resolvedSize(codec: VideoCodec = .hevc, peerMax: (Int, Int)? = nil) -> (Int, Int) {
        var w = preset.width, h = preset.height
        if w == 0 || h == 0 {
            // CGDisplayPixelsWide returns the mode's POINT size, not pixels. On a
            // HiDPI panel that is half the real resolution, so capturing by it
            // would quietly halve the picture.
            let main = CGMainDisplayID()
            if let mode = CGDisplayCopyDisplayMode(main) {
                w = mode.pixelWidth
                h = mode.pixelHeight
            } else {
                w = Int(CGDisplayPixelsWide(main))
                h = Int(CGDisplayPixelsHigh(main))
            }
        }
        let encMax = EncodeCapability.maxSize(for: codec)
        var capW = encMax.width, capH = encMax.height
        if let peerMax {
            capW = min(capW, peerMax.0); capH = min(capH, peerMax.1)
        }
        let scale = min(1.0, Double(capW) / Double(w), Double(capH) / Double(h))
        if scale < 1.0 {
            w = Int((Double(w) * scale / 2).rounded()) * 2
            h = Int((Double(h) * scale / 2).rounded()) * 2
        }
        // H.264 wants even dimensions.
        return (w - (w % 2), h - (h % 2))
    }
}

@MainActor
final class SenderEngine: ObservableObject {
    @Published var status: String = "Ready"
    @Published var problem: String?
    @Published var streaming = false
    /// Set when extend was asked for but the system wouldn't give us a
    /// virtual display — the stream still runs, as a mirror.
    @Published var extendFellBack = false

    let net = NetSender()
    private let capturer = ScreenCapturer()
    private let encoder = VideoEncoder()
    /// macOS keeps a virtual desktop registered until the process exits, even
    /// after the object is released. So we make at most one per size and hold
    /// on to it, instead of creating a fresh one on every start.
    private var virtualDisplays: [String: PhoenixVD] = [:]
    private var activeVirtualKey: String?
    @Published var staleDesktopWarning = false
    /// What the two ends agreed on, shown in the UI so it is never a mystery.
    @Published var activeCodec: VideoCodec = .h264
    @Published var peerSummary: String?
    @Published var streamSize: String = ""

    private var settings: PhoenixSettings
    private var transport: TransportSelector
    /// What the connected receiver told us it can decode. Held for the life of
    /// the connection: a mid-stream settings change must NOT re-negotiate from
    /// nothing, or the codec silently drops to H.264 and the resolution with it.
    private var peerCaps: Capabilities?
    /// Guards against overlapping restarts when settings are changed quickly.
    private var restartToken = 0

    init(settings: PhoenixSettings, transport: TransportSelector) {
        self.settings = settings
        self.transport = transport

        let box = net.box
        encoder.onFormat = { sets in
            box.sendReliable(Packet.encode(.format, sets))
        }
        encoder.onFrame = { au, isKey in
            var payload = Data(capacity: au.count + 1)
            payload.append(isKey ? 1 : 0)
            payload.append(au)
            // A keyframe is worth waiting for; a delta frame is not.
            if isKey { box.sendReliable(Packet.encode(.frame, payload)) }
            else     { box.sendFrame(Packet.encode(.frame, payload)) }
        }
        encoder.onError = { [weak self] msg in
            Task { @MainActor in self?.problem = msg }
        }
        capturer.onFrame = { [weak self] sample in
            self?.encoder.encode(sample)
        }
        capturer.onError = { [weak self] msg in
            Task { @MainActor in
                self?.problem = msg
                self?.streaming = false
            }
        }
        net.onConnect  = { [weak self] caps in
            Task { @MainActor in await self?.beginStreaming(peer: caps) }
        }
        net.onDisconnect = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Only forget the peer once nothing is connected. A replaced
                // connection must not clear the live one's negotiation.
                if !self.net.isConnected { self.peerCaps = nil }
                self.endStreaming()
            }
        }
    }

    func startAdvertising() {
        problem = nil
        let name = Host.current().localizedName ?? "This Mac"
        net.start(name: name, parameters: transport.parameters())
        status = "Waiting for a display to connect"
    }

    func stop() {
        endStreaming()
        net.stop()
        status = "Ready"
    }

    /// Makes the streamed desktop the main display — the one with the menu bar.
    /// This is what lets the iMac act as the primary monitor.
    func applyMainDisplay() {
        guard let key = activeVirtualKey, let vd = virtualDisplays[key], vd.active else { return }
        if settings.makeMain {
            if !vd.makeMainDisplay() { problem = "macOS refused to move the menu bar to the streamed screen." }
        } else {
            _ = PhoenixVD.restoreBuiltInAsMain()
        }
    }

    /// Moves the extra desktop without restarting the stream.
    func applyPosition() {
        guard let key = activeVirtualKey, let vd = virtualDisplays[key], vd.active else { return }
        _ = vd.setPosition(settings.position.raw)
    }

    /// Re-applies mode/resolution without tearing the connection down.
    /// Reuses the capabilities already negotiated, and collapses a burst of
    /// changes into a single restart.
    func applySettings() {
        guard streaming || net.isConnected else { return }
        restartToken &+= 1
        let token = restartToken
        Task { @MainActor in
            endStreamingKeepingConnection()
            // Let the encoder and capture session actually tear down, and give
            // a rapid second change the chance to supersede this one.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard token == self.restartToken else { return }
            await self.beginStreaming(peer: self.peerCaps)
        }
    }

    private func beginStreaming(peer: Capabilities? = nil) async {
        problem = nil
        extendFellBack = false

        // Remember what the peer said, so a later settings change does not have
        // to re-negotiate from nothing.
        if let peer { peerCaps = peer }
        let effective = peer ?? peerCaps

        // Pick the codec: HEVC only when BOTH ends can do it. An older receiver
        // sends no capabilities at all, so it lands on H.264 automatically.
        let peerCodecs = effective?.decodes ?? [.h264]
        let codec: VideoCodec = (peerCodecs.contains(.hevc) && EncodeCapability.supportsHEVC) ? .hevc : .h264
        activeCodec = codec
        peerSummary = effective.map { "\($0.appVersion) · \($0.codecs.joined(separator: "/")) · up to \($0.maxWidth)×\($0.maxHeight)" }
            ?? "older receiver — H.264 only"

        let peerMax = effective.map { ($0.maxWidth, $0.maxHeight) }
        let (w, h) = settings.resolvedSize(codec: codec, peerMax: peerMax)
        let q = settings.quality

        var captureID: CGDirectDisplayID = 0

        if settings.mode == .extend {
            // This is the call that used to crash. It cannot any more: the
            // shim checks every selector and catches anything it missed.
            let key = "\(w)x\(h)"
            let vd: PhoenixVD?
            if let existing = virtualDisplays[key], existing.active {
                vd = existing
            } else {
                vd = PhoenixVD(name: "Phoenix Display",
                               width: UInt32(w), height: UInt32(h),
                               refreshRate: Double(q.fps), hiDPI: true,
                               position: settings.position.raw)
                if let vd, vd.active { virtualDisplays[key] = vd }
            }
            if let vd, vd.active {
                if let prev = activeVirtualKey, prev != key { staleDesktopWarning = true }
                activeVirtualKey = key
                _ = vd.setPosition(settings.position.raw)
                if settings.makeMain { _ = vd.makeMainDisplay() }
                captureID = vd.displayID
                // The window server needs a beat after a display config change
                // before ScreenCaptureKit will list the new display.
                try? await Task.sleep(nanoseconds: 600_000_000)
                status = vd.mirroredAnyway
                    ? "Streaming (macOS kept the new desktop mirrored)"
                    : "Streaming a separate desktop"
            } else {
                extendFellBack = true
                problem = vd?.failureReason ?? PhoenixVD.unavailableReason
                    ?? "A separate desktop is not available on this Mac."
                status = "Streaming (mirrored — separate desktop unavailable)"
            }
        } else {
            status = "Streaming"
        }

        let hello = Hello(name: Host.current().localizedName ?? "This Mac",
                          width: w, height: h, fps: q.fps,
                          mode: settings.mode.rawValue, codec: codec.rawValue)
        if let data = try? JSONEncoder().encode(hello) { net.send(.hello, data) }

        encoder.start(width: w, height: h, fps: q.fps, bitrate: q.bitrate, codec: codec)
        await capturer.start(displayID: captureID, width: w, height: h, fps: q.fps)
        streamSize = "\(w) × \(h) · \(codec.displayName) · \(q.fps) fps"
        streaming = true
    }

    private func endStreamingKeepingConnection() {
        capturer.stop()
        encoder.stop()
        // Deliberately not invalidating the virtual display: releasing it does
        // not remove the desktop until the app quits, so tearing it down here
        // would only leak another one on the next start.
        streaming = false
    }

    /// Called when the app is quitting — this is the only point where
    /// releasing the virtual displays actually has an effect.
    func shutdown() {
        endStreamingKeepingConnection()
        for (_, vd) in virtualDisplays { vd.invalidate() }
        virtualDisplays.removeAll()
        activeVirtualKey = nil
        net.stop()
    }

    private func endStreaming() {
        endStreamingKeepingConnection()
        status = "Waiting for a display to connect"
    }
}

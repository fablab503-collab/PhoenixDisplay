import SwiftUI

struct SendView: View {
    @Binding var screen: Screen
    @ObservedObject var hub: AppHub
    @ObservedObject var settings: PhoenixSettings
    @ObservedObject var transport: TransportSelector
    @ObservedObject var engine: SenderEngine
    @ObservedObject var links: LinkMonitor

    init(screen: Binding<Screen>, hub: AppHub) {
        _screen = screen
        self.hub = hub
        self.settings = hub.settings
        self.transport = hub.transport
        self.engine = hub.sender
        self.links = hub.links
    }

    /// The link the stream is actually on: the pinned one, or whatever macOS picked.
    private var activeLink: Link? {
        if transport.selectedID != "auto" { return links.link(named: transport.selectedID) }
        if let a = links.activeInterface, let l = links.link(named: a) { return l }
        return links.links.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusBlock
                    if let problem = engine.problem {
                        Banner(kind: engine.extendFellBack ? .warning : .error, text: problem)
                    }
                    if engine.staleDesktopWarning {
                        Banner(kind: .info,
                               text: "You changed the extended resolution. macOS keeps the old desktop until Phoenix Display quits — quit and reopen to clear it.")
                    }
                    section("Use as") {
                        ForEach(DisplayMode.allCases) { m in
                            Button {
                                settings.mode = m
                                engine.applySettings()
                            } label: {
                                BigChoice(symbol: m.symbol, title: m.title,
                                          detail: m.detail, selected: settings.mode == m)
                            }.buttonStyle(.plain)
                        }
                        if !PhoenixVD.isSupported() {
                            Banner(kind: .warning,
                                   text: (PhoenixVD.unavailableReason ?? "Separate displays are unavailable here.")
                                       + " Mirroring still works.")
                        }
                    }
                    if settings.mode == .extend {
                        section("Main screen") {
                            Button {
                                settings.makeMain.toggle()
                                engine.applyMainDisplay()
                            } label: {
                                BigChoice(symbol: settings.makeMain ? "menubar.dock.rectangle.badge.record" : "menubar.dock.rectangle",
                                          title: "Use the streamed screen as the main display",
                                          detail: settings.makeMain
                                            ? "Menu bar and new windows open there"
                                            : "Menu bar stays on this Mac",
                                          selected: settings.makeMain)
                            }.buttonStyle(.plain)
                            Text("Needed if you want to work on the other Mac's screen with this lid closed. Note a streamed screen always has some lag — fine for reading and reference, less so for fast pointer work.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        section("Where the extra screen sits") {
                            ForEach(ScreenPosition.allCases) { pos in
                                Button {
                                    settings.position = pos
                                    engine.applyPosition()
                                } label: {
                                    BigChoice(symbol: pos.symbol, title: pos.title,
                                              detail: pos.detail,
                                              selected: settings.position == pos)
                                }.buttonStyle(.plain)
                            }
                            Text("This sets the arrangement macOS uses, the same as dragging the screens in Displays settings.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    section("Connection") {
                        Button { transport.selectedID = "auto" } label: {
                            BigChoice(symbol: "wand.and.stars",
                                      title: "Automatic",
                                      detail: activeLink.map { "Using \($0.title) — \($0.speedText)" }
                                              ?? "Let macOS pick the best route",
                                      selected: transport.selectedID == "auto")
                        }.buttonStyle(.plain)

                        ForEach(links.links) { l in
                            Button { transport.selectedID = l.id } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: l.kind.symbol)
                                        .font(.system(size: 22))
                                        .frame(width: 44, height: 44)
                                        .foregroundStyle(transport.selectedID == l.id
                                                         ? AnyShapeStyle(Color.accentColor)
                                                         : AnyShapeStyle(.secondary))
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(l.title).font(.system(size: 16, weight: .semibold))
                                            if activeLink?.id == l.id {
                                                Text("IN USE")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.22),
                                                                in: Capsule())
                                                    .foregroundStyle(.green)
                                            }
                                        }
                                        Text(l.detail).font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if transport.selectedID == l.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                                .phoenixCard(selected: transport.selectedID == l.id)
                            }.buttonStyle(.plain)
                        }

                        if let tb = links.thunderboltSummary {
                            Banner(kind: .info, text: "Thunderbolt: \(tb). Turn on Thunderbolt Bridge in Network settings on both Macs to use it for the stream.")
                        }
                        HStack {
                            Text("Speeds are read live from each interface.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Full connection status…") { hub.openConnection() }
                                .font(.system(size: 11))
                        }
                    }
                    section("Resolution") {
                        ForEach(Preset.all) { p in
                            Button {
                                settings.presetID = p.id
                                engine.applySettings()
                            } label: {
                                BigChoice(symbol: "rectangle.inset.filled",
                                          title: p.title,
                                          detail: p.width == 0 ? resolvedLabel : p.label,
                                          selected: settings.presetID == p.id)
                            }.buttonStyle(.plain)
                        }
                        Text(codecNote)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    section("Quality") {
                        ForEach(Quality.all) { q in
                            let head = q.headroom(onLinkOf: activeLink?.bitsPerSecond ?? 0)
                            Button {
                                settings.qualityID = q.id
                                engine.applySettings()
                            } label: {
                                BigChoice(symbol: "speedometer", title: q.title,
                                          detail: "\(q.detail) · \(head.text)",
                                          selected: settings.qualityID == q.id)
                            }
                            .buttonStyle(.plain)
                            .opacity(head == .tooMuch ? 0.55 : 1)
                        }
                        Text(qualityNote).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { hub.startSending() }
    }

    private var resolvedLabel: String {
        let (w, h) = settings.resolvedSize(codec: engine.activeCodec)
        return "\(w) × \(h)"
    }

    /// Says plainly whether the current pick will hold up on this link.
    private var qualityNote: String {
        let (w, h) = settings.resolvedSize(codec: engine.activeCodec)
        let q = settings.quality
        guard let link = activeLink, link.bitsPerSecond > 0 else {
            return "\(w) × \(h) at \(q.fps) fps needs about \(q.bitrate / 1_000_000) Mbps. This link's speed is unknown."
        }
        let head = q.headroom(onLinkOf: link.bitsPerSecond)
        return "\(w) × \(h) at \(q.fps) fps needs about \(q.bitrate / 1_000_000) Mbps, peaking near "
             + "\(Int(q.peakBitsPerSecond / 1_000_000)) Mbps. \(link.title) gives \(link.speedText) — \(head.text)."
    }

    private var codecNote: String {
        if engine.activeCodec == .hevc {
            return "Streaming with HEVC, so a full 5120 × 2880 desktop is possible. H.264 would stop at 4096 × 2304."
        }
        return "Streaming with H.264, which tops out at 4096 × 2304. 5K needs HEVC at both ends — this receiver didn't offer it."
    }

    private func symbol(for opt: TransportOption) -> String {
        if opt.id == "auto" { return "wand.and.stars" }
        if opt.title.contains("Thunderbolt") { return "cable.connector" }
        if opt.title.contains("Wi-Fi") { return "wifi" }
        if opt.title.contains("Ethernet") { return "cable.coaxial" }
        return "network"
    }

    private var header: some View {
        HStack {
            Button { screen = .home } label: {
                Label("Back", systemImage: "chevron.left")
            }.buttonStyle(.plain)
            Spacer()
            Text("Sending this screen").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { hub.openConnection() } label: {
                Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
            .help("Live connection status")
            Button { hub.hideWindows() } label: {
                Label("Hide", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.plain)
            .help("Close the window and keep streaming from the menu bar")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(engine.streaming ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(engine.status).font(.system(size: 15, weight: .semibold))
            }
            Text("Route: \(transport.routeDescription)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !engine.streamSize.isEmpty {
                Text(engine.streamSize)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(engine.activeCodec == .hevc ? Color.accentColor : Color.secondary)
            }
            if let peer = engine.peerSummary {
                Text("Other Mac: \(peer)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            let addrs = TransportSelector.localAddresses()
            if !addrs.isEmpty {
                Text("This Mac: \(addrs.joined(separator: ", "))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoenixCard()
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

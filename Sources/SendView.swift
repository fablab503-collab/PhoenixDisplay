import SwiftUI

struct SendView: View {
    @Binding var screen: Screen
    @ObservedObject var settings: PhoenixSettings
    @ObservedObject var transport: TransportSelector
    @StateObject private var engine: SenderEngine

    init(screen: Binding<Screen>, settings: PhoenixSettings, transport: TransportSelector) {
        _screen = screen
        self.settings = settings
        self.transport = transport
        _engine = StateObject(wrappedValue: SenderEngine(settings: settings, transport: transport))
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
                        ForEach(transport.options) { opt in
                            Button {
                                transport.selectedID = opt.id
                            } label: {
                                BigChoice(symbol: symbol(for: opt),
                                          title: opt.title, detail: opt.subtitle,
                                          selected: transport.selectedID == opt.id)
                            }.buttonStyle(.plain)
                        }
                        Text("Pick a cable or Wi-Fi to pin the stream to it. Automatic follows whatever route macOS prefers.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
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
                            Button {
                                settings.qualityID = q.id
                                engine.applySettings()
                            } label: {
                                BigChoice(symbol: "speedometer", title: q.title,
                                          detail: q.detail, selected: settings.qualityID == q.id)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { engine.startAdvertising() }
        .onDisappear { engine.stop() }
    }

    private var resolvedLabel: String {
        let (w, h) = settings.resolvedSize(codec: engine.activeCodec)
        return "\(w) × \(h)"
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
            Text(" ").frame(width: 50)
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

import SwiftUI

/// The full connection picture, shown as a sheet from anywhere in the app and
/// summarised in the menu bar. Everything here is read live.
struct ConnectionView: View {
    @ObservedObject var links: LinkMonitor
    @ObservedObject var transport: TransportSelector
    @ObservedObject var settings: PhoenixSettings
    @ObservedObject var engine: SenderEngine
    var onClose: () -> Void

    private var activeLink: Link? {
        if transport.selectedID != "auto" { return links.link(named: transport.selectedID) }
        if let a = links.activeInterface, let l = links.link(named: a) { return l }
        return links.links.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connection").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nowBlock
                    routesBlock
                    if let tb = links.thunderboltSummary { thunderboltBlock(tb) }
                    demandBlock
                }
                .padding(20)
                .frame(maxWidth: 560)
            }
        }
        .frame(width: 600, height: 560)
    }

    // What is happening right now.
    private var nowBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(engine.streaming ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(engine.status).font(.system(size: 15, weight: .semibold))
            }
            if !engine.streamSize.isEmpty {
                row("Stream", engine.streamSize)
            }
            row("Route", activeLink.map { "\($0.title) · \($0.speedText)" } ?? "none")
            if let peer = engine.peerSummary { row("Other Mac", peer) }
            let addrs = TransportSelector.localAddresses()
            if !addrs.isEmpty { row("This Mac", addrs.joined(separator: ", ")) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoenixCard()
    }

    private var routesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AVAILABLE ROUTES").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if links.links.isEmpty {
                Text("No usable network interfaces found.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).phoenixCard()
            }
            ForEach(links.links) { l in
                Button { transport.selectedID = l.id } label: {
                    HStack(spacing: 14) {
                        Image(systemName: l.kind.symbol)
                            .font(.system(size: 20)).frame(width: 36)
                            .foregroundStyle(transport.selectedID == l.id
                                             ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(l.title).font(.system(size: 14, weight: .semibold))
                                if activeLink?.id == l.id {
                                    Text("IN USE").font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Color.green.opacity(0.22), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(l.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if transport.selectedID == l.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .phoenixCard(selected: transport.selectedID == l.id)
                }.buttonStyle(.plain)
            }
            Button { transport.selectedID = "auto" } label: {
                HStack(spacing: 14) {
                    Image(systemName: "wand.and.stars").font(.system(size: 20)).frame(width: 36)
                        .foregroundStyle(transport.selectedID == "auto"
                                         ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic").font(.system(size: 14, weight: .semibold))
                        Text("Follow whatever route macOS prefers")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if transport.selectedID == "auto" {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .phoenixCard(selected: transport.selectedID == "auto")
            }.buttonStyle(.plain)
        }
    }

    private func thunderboltBlock(_ tb: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THUNDERBOLT").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            let bridged = links.links.contains { $0.kind == .thunderbolt && $0.ip != nil }
            Banner(kind: bridged ? .info : .warning,
                   text: bridged
                     ? "\(tb). Thunderbolt Bridge has an address, so the cable can carry the stream."
                     : "\(tb) — but Thunderbolt Bridge has no address, so the cable is not carrying anything yet. Add Thunderbolt Bridge in System Settings ▸ Network on BOTH Macs.")
        }
    }

    private var demandBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WILL THE LINK CARRY IT").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            let (w, h) = settings.resolvedSize(codec: engine.activeCodec)
            let q = settings.quality
            let head = q.headroom(onLinkOf: activeLink?.bitsPerSecond ?? 0)
            VStack(alignment: .leading, spacing: 6) {
                row("Picture", "\(w) × \(h) · \(engine.activeCodec.displayName) · \(q.fps) fps")
                row("Average", "\(q.bitrate / 1_000_000) Mbps")
                row("Peak", "\(Int(q.peakBitsPerSecond / 1_000_000)) Mbps")
                row("This link", activeLink?.speedText ?? "unknown")
                HStack(spacing: 8) {
                    Image(systemName: head.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(head.isProblem ? Color.orange : Color.green)
                    Text(head.text).font(.system(size: 12, weight: .medium))
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .phoenixCard()
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

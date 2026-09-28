import SwiftUI

struct ReceiveView: View {
    @Binding var screen: Screen
    @ObservedObject var transport: TransportSelector
    @StateObject private var net  = NetReceiver()
    @StateObject private var pipe = VideoPipe()
    @State private var manualHost = ""
    @State private var fullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            if case .connected = net.state {
                videoScreen
            } else {
                browseScreen
            }
        }
        .onAppear {
            net.onPacket = { type, payload in pipe.handle(type, payload) }
            net.startBrowsing(parameters: transport.parameters())
        }
        .onDisappear { net.disconnect() }
    }

    // MARK: connected

    private var videoScreen: some View {
        ZStack(alignment: .top) {
            VideoView(pipe: pipe).ignoresSafeArea()
            if !fullScreen {
                HStack {
                    Button { net.disconnect() } label: {
                        Label("Disconnect", systemImage: "chevron.left")
                    }.buttonStyle(.plain)
                    Spacer()
                    Text(connectedLabel).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button { toggleFullScreen() } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var connectedLabel: String {
        if case .connected(let who) = net.state { return who }
        return ""
    }

    private func toggleFullScreen() {
        fullScreen.toggle()
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: browsing

    private var browseScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Button { screen = .home } label: {
                    Label("Back", systemImage: "chevron.left")
                }.buttonStyle(.plain)
                Spacer()
                Text("Use as display").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(" ").frame(width: 50)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if case .failed(let msg) = net.state {
                        Banner(kind: .error, text: msg)
                    }
                    if case .connecting(let who) = net.state {
                        Banner(kind: .info, text: "Connecting to \(who)…")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("MACS SENDING A SCREEN")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        if net.found.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Looking… make sure Phoenix Display is open on the other Mac and both are on the same network.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .phoenixCard()
                        } else {
                            ForEach(net.found) { s in
                                Button {
                                    pipe.reset()
                                    net.connect(to: s, parameters: transport.parameters())
                                } label: {
                                    BigChoice(symbol: "laptopcomputer",
                                              title: s.name,
                                              detail: "Tap to use this Mac's screen here")
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("CONNECTION").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(transport.options) { opt in
                            Button { transport.selectedID = opt.id } label: {
                                BigChoice(symbol: opt.id == "auto" ? "wand.and.stars" : "network",
                                          title: opt.title, detail: opt.subtitle,
                                          selected: transport.selectedID == opt.id)
                            }.buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("CONNECT BY ADDRESS")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        HStack {
                            TextField("192.168.0.10", text: $manualHost)
                                .textFieldStyle(.roundedBorder)
                            Button("Connect") {
                                guard !manualHost.isEmpty else { return }
                                pipe.reset()
                                net.connect(host: manualHost, port: 51777,
                                            parameters: transport.parameters())
                            }
                            .disabled(manualHost.isEmpty)
                        }
                        Text("Use this when Bonjour is blocked, for example across a Thunderbolt cable with no router in between.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

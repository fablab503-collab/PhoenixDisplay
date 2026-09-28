import SwiftUI
import AppKit

// MARK: - macOS 27 look

/// Liquid Glass where the OS has it, a plain material where it doesn't —
/// the iMac still runs Ventura, so every glass effect is opt-in by version.
extension View {
    @ViewBuilder
    func phoenixCard(selected: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.padding(14)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        } else {
            self.padding(14)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 16))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 2 : 1))
        }
    }

    @ViewBuilder
    func phoenixBackground() -> some View {
        self.background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            .background(
                LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                        Color(nsColor: .underPageBackgroundColor)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
    }
}

struct BigChoice: View {
    let symbol: String
    let title: String
    let detail: String
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .frame(width: 44, height: 44)
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .phoenixCard(selected: selected)
    }
}

struct Banner: View {
    enum Kind { case warning, error, info }
    let kind: Kind
    let text: String

    private var symbol: String {
        switch kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        case .info:    return "info.circle.fill"
        }
    }
    private var tint: Color {
        switch kind {
        case .warning: return .orange
        case .error:   return .red
        case .info:    return .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.3)))
    }
}

// MARK: - Root

enum Screen { case home, send, receive }

struct RootView: View {
    @StateObject private var settings  = PhoenixSettings()
    @StateObject private var transport = TransportSelector()
    @State private var screen: Screen = .home

    var body: some View {
        Group {
            switch screen {
            case .home:    HomeView(screen: $screen)
            case .send:    SendView(screen: $screen, settings: settings, transport: transport)
            case .receive: ReceiveView(screen: $screen, transport: transport)
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .phoenixBackground()
    }
}

struct HomeView: View {
    @Binding var screen: Screen

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            VStack(spacing: 6) {
                Image(systemName: "display.2")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text("Phoenix Display").font(.system(size: 30, weight: .bold))
                Text("Turn another Mac into a second screen.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button { screen = .send } label: {
                    BigChoice(symbol: "arrow.up.right.video",
                              title: "Send this screen",
                              detail: "Stream this Mac to another display")
                }.buttonStyle(.plain)

                Button { screen = .receive } label: {
                    BigChoice(symbol: "display",
                              title: "Use as display",
                              detail: "Show another Mac's screen here")
                }.buttonStyle(.plain)
            }
            .frame(maxWidth: 520)

            Spacer(minLength: 10)
        }
        .padding(30)
    }
}

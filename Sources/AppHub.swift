import SwiftUI
import AppKit
import Combine

/// One shared place for settings, transport and the sender engine, so the
/// menu bar can drive and report on the stream while no window exists.
@MainActor
final class AppHub: ObservableObject {
    static let shared = AppHub()

    let settings = PhoenixSettings()
    let transport = TransportSelector()
    lazy var sender: SenderEngine = SenderEngine(settings: settings, transport: transport)

    @Published var screen: Screen = .home
    /// True while the sender is advertising, whether or not a window is open.
    @Published var sending = false
    /// Start with no window at all — menu bar only.
    @Published var startMinimised: Bool {
        didSet { UserDefaults.standard.set(startMinimised, forKey: "phoenix.startMinimised") }
    }

    private var bag = Set<AnyCancellable>()

    private init() {
        startMinimised = UserDefaults.standard.bool(forKey: "phoenix.startMinimised")
        // Mirror the engine's own published changes so the menu bar redraws.
        sender.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    /// Begin advertising without needing a window on screen.
    func startSending() {
        guard !sending else { return }
        sender.startAdvertising()
        sending = true
    }

    func stopSending() {
        sender.stop()
        sending = false
    }

    /// Close every window. The app keeps running in the menu bar — this is the
    /// "shrink it to nothing" behaviour.
    func hideWindows() {
        for w in NSApp.windows where w.isVisible && !(w is NSPanel) {
            w.close()
        }
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Re-open the SwiftUI WindowGroup scene.
        if let existing = NSApp.windows.first(where: { $0.contentViewController != nil && !($0 is NSPanel) }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
    }

    var statusLine: String {
        if !sending { return "Not sending" }
        if sender.streaming { return sender.streamSize.isEmpty ? "Streaming" : sender.streamSize }
        return "Waiting for a display"
    }

    var symbolName: String {
        if !sending { return "display" }
        return sender.streaming ? "display.and.arrow.down" : "display.trianglebadge.exclamationmark"
    }
}

/// Keeps the app alive when the last window closes, so "minimise to nothing"
/// does not quit it.
final class PhoenixAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let hub = AppHub.shared
            if hub.startMinimised {
                // Give the scene a moment to exist before closing it.
                try? await Task.sleep(nanoseconds: 300_000_000)
                hub.hideWindows()
                hub.startSending()
            }
        }
    }
}

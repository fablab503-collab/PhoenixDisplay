import SwiftUI
import AppKit

@main
struct PhoenixDisplayApp: App {
    @NSApplicationDelegateAdaptor(PhoenixAppDelegate.self) private var delegate
    @StateObject private var hub = AppHub.shared

    var body: some Scene {
        WindowGroup("Phoenix Display") {
            RootView()
                .environmentObject(hub)
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("Hide Window (keep streaming)") { hub.hideWindows() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }

        // Menu bar presence, so the app can run with no window at all.
        MenuBarExtra {
            MenuBarView().environmentObject(hub)
        } label: {
            Image(systemName: hub.symbolName)
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var hub: AppHub

    var body: some View {
        Text(hub.statusLine)
        Divider()
        if hub.sending {
            Button("Stop sending") { hub.stopSending() }
        } else {
            Button("Start sending this screen") { hub.startSending() }
        }
        Button("Show window") { hub.showWindow() }
        Button("Hide window (keep streaming)") { hub.hideWindows() }
        Divider()
        Toggle("Start with no window", isOn: Binding(
            get: { hub.startMinimised },
            set: { hub.startMinimised = $0 }))
        Divider()
        Button("Quit Phoenix Display") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

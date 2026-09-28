import SwiftUI

@main
struct PhoenixDisplayApp: App {
    var body: some Scene {
        WindowGroup("Phoenix Display") {
            RootView()
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

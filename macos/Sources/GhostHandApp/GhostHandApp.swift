import SwiftUI

// Placeholder entry point; replaced by the menu bar app.
@main
struct GhostHandApp: App {
    var body: some Scene {
        MenuBarExtra("GhostHand", systemImage: "hand.raised") {
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

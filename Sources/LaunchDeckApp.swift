import SwiftUI

@main
struct LaunchDeckApp: App {
    // One shared manager backs both the window and the menu bar item.
    @StateObject private var manager = AppManager()

    var body: some Scene {
        // `Window` (not WindowGroup) = a single unique window, so reopening it
        // from the menu bar just brings the existing one forward.
        Window("Launch Deck", id: "main") {
            ContentView(manager: manager)
        }
        // Wide enough for 3 tile columns; tall enough that the current deck
        // (7 apps → 3 rows) shows without scrolling, with room for a few more.
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Launch Deck", systemImage: "gamecontroller.fill") {
            MenuBarContent(manager: manager)
        }
    }
}

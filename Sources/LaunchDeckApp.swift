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
        // One row per app (~46pt, ~86pt for an agent row): the current deck
        // of 9 fits without scrolling; the width is for the header's usage
        // strip and a name column that never truncates.
        .defaultSize(width: 860, height: 780)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Launch Deck", systemImage: "gamecontroller.fill") {
            MenuBarContent(manager: manager)
        }
    }
}

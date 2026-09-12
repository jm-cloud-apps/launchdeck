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
        // Wide enough for 3 tile columns plus the plan-usage strip on the
        // header line; tall enough that the current deck (9 apps → 3 rows,
        // one ~40pt taller for the agent tile) shows without scrolling.
        .defaultSize(width: 960, height: 620)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Launch Deck", systemImage: "gamecontroller.fill") {
            MenuBarContent(manager: manager)
        }
    }
}

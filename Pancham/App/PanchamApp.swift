import SwiftUI

@main
struct PanchamApp: App {
    @State private var prefs = Preferences.shared

    var body: some Scene {
        WindowGroup {
            RootView(prefs: prefs)
        }
        .commands {
            CommandGroup(replacing: .newItem) { EmptyView() }
        }
    }
}

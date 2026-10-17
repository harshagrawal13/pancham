import SwiftUI

@main
struct PanchamApp: App {
    @State private var prefs = Preferences.shared
    @State private var session = AuthSession()

    var body: some Scene {
        WindowGroup {
            RootView(prefs: prefs, session: session)
                .onOpenURL { url in prefs.pendingOpenURL = url }
        }
        // A file opened from Finder is handed to the window that's already open rather than a new one.
        // (A second window would find the account's cache already in use by the first: SyncEngine's lock.)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) { EmptyView() }
        }
    }
}

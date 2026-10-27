import SwiftUI

@main
struct NotchHiderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Menu bar only app; the status item is built in AppDelegate. Wallpaper-mode settings arrive in a later step.
        Settings { SettingsView() }
    }
}

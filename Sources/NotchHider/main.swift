import AppKit

// Menu bar only app: plain AppKit entry point, so no SwiftUI scene windows exist.
// The settings window is hosted by AppDelegate (SettingsView is still SwiftUI).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

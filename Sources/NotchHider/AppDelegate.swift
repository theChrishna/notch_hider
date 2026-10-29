import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let overlays = OverlayManager()
    private let wallpaper = WallpaperManager()
    private var lastSignature = Prefs.signature
    private var refreshWork: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var lastLog = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "NotchHider")
        let menu = NSMenu()
        menu.delegate = self
        add(menu, "Enable", #selector(toggleEnabled))
        add(menu, "Rounded corners", #selector(toggleCorners))
        add(menu, "Bottom corners too", #selector(toggleBottom))
        add(menu, "Apply to all screens", #selector(toggleAll))
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for (title, tag) in [("Wallpaper", 0), ("Overlay", 1)] {
            let i = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
            i.tag = tag; i.target = self; modeMenu.addItem(i)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        let radiusItem = NSMenuItem(title: "Corner radius", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for r in [8, 10, 12, 16, 20, 24, 28] {
            let i = NSMenuItem(title: "\(r) pt", action: #selector(setRadius(_:)), keyEquivalent: "")
            i.tag = r; i.target = self; sub.addItem(i)
        }
        radiusItem.submenu = sub
        menu.addItem(radiusItem)
        menu.addItem(.separator())
        add(menu, "Restore original wallpaper", #selector(restoreWallpaper))
        add(menu, "Settings…", #selector(openSettings))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Log screen geometry", action: #selector(logNow), keyEquivalent: "l").target = self
        menu.addItem(withTitle: "Copy last log", action: #selector(copyLog), keyEquivalent: "c").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchHider", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        // Event-driven only: no timers. Settings window writes UserDefaults; re-apply when they change.
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(changed(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(changed(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)

        wallpaper.onChange = { [weak self] in
            guard let self else { return }
            self.reconcileOverlays()
        }
        // The system posts this when the desktop picture changes (undocumented; we only log and re-check).
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(changed(_:)),
            name: NSNotification.Name("com.apple.desktop"), object: nil)

        let crashed = Prefs.cleanExit == false
        Prefs.cleanExit = false
        log("launch (previous run crashed: \(crashed))")
        if crashed && wallpaper.hasGeneratedWallpaperSet { offerRecovery() }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaper.restoreAll()
        overlays.removeAll()
        Prefs.cleanExit = true
    }

    private func offerRecovery() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "NotchHider didn't quit cleanly"
        alert.informativeText = "A generated wallpaper is still set. Restore your original wallpaper now?"
        alert.addButton(withTitle: "Restore original")
        alert.addButton(withTitle: "Keep and continue")
        if alert.runModal() == .alertFirstButtonReturn {
            wallpaper.restoreAll()
            Prefs.enabled = false
        }
    }

    // MARK: Coordination

    private func targets() -> [ScreenGeometry] {
        ScreenGeometry.all().filter { Prefs.allScreens || $0.hasNotch }
    }

    private func barDisplays() -> Set<CGDirectDisplayID> {
        guard Prefs.enabled else { return [] }
        return Prefs.mode == "overlay" ? Set(targets().map(\.displayID)) : wallpaper.needsOverlay
    }

    /// Single entry point after any event: restores, regenerates or removes things as settings dictate.
    private func refresh() {
        if !Prefs.enabled || Prefs.mode == "overlay" {
            wallpaper.restoreAll()
        } else {
            wallpaper.apply(targets: targets())
        }
        reconcileOverlays()
    }

    private func reconcileOverlays() {
        let bars = barDisplays()
        overlays.reconcile(barDisplays: bars, blackDisplays: bars.union(Prefs.enabled ? wallpaper.editedDisplays : []))
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector) {
        menu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.filter { $0.tag == -7 }.forEach(menu.removeItem)
        for (id, text) in wallpaper.status.sorted(by: { $0.key < $1.key }) {
            let name = ScreenGeometry.all().first { $0.displayID == id }?.name ?? "Display \(id)"
            let item = NSMenuItem(title: "\(name): \(text)", action: nil, keyEquivalent: "")
            item.tag = -7; item.isEnabled = false
            menu.insertItem(item, at: 0)
        }
        for item in menu.items {
            switch item.action {
            case #selector(toggleEnabled): item.state = Prefs.enabled ? .on : .off
            case #selector(toggleCorners): item.state = Prefs.cornersEnabled ? .on : .off
            case #selector(toggleBottom): item.state = Prefs.bottomCorners ? .on : .off
            case #selector(toggleAll): item.state = Prefs.allScreens ? .on : .off
            default:
                if item.title == "Mode" {
                    item.submenu?.items.forEach { $0.state = ($0.tag == 1) == (Prefs.mode == "overlay") ? .on : .off }
                } else {
                    item.submenu?.items.forEach { $0.state = Double($0.tag) == Prefs.cornerRadius ? .on : .off }
                }
            }
        }
    }

    @objc private func prefsChanged() {
        guard Prefs.signature != lastSignature else { return }
        lastSignature = Prefs.signature
        refresh()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func setMode(_ item: NSMenuItem) { Prefs.mode = item.tag == 1 ? "overlay" : "wallpaper"; prefsChanged() }
    @objc private func restoreWallpaper() { wallpaper.restoreAll(); Prefs.enabled = false; prefsChanged() }

    @objc private func toggleEnabled() { Prefs.enabled.toggle(); refresh() }
    @objc private func toggleCorners() { Prefs.cornersEnabled.toggle(); refresh() }
    @objc private func toggleBottom() { Prefs.bottomCorners.toggle(); refresh() }
    @objc private func toggleAll() { Prefs.allScreens.toggle(); refresh() }
    @objc private func setRadius(_ item: NSMenuItem) { Prefs.cornerRadius = Double(item.tag); refresh() }

    @objc private func changed(_ note: Notification) {
        // visibleFrame can lag the Space-change notification slightly; log once now and once shortly after.
        log(note.name.rawValue)
        refresh()
        // Coalesced follow-up: visibleFrame and the wallpaper URL can lag the notification slightly.
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.log("\(note.name.rawValue) (+0.5s)")
            self?.refresh()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @objc private func logNow() { log("manual") }

    @objc private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastLog, forType: .string)
    }

    private func log(_ reason: String) {
        let screens = ScreenGeometry.all()
        var out = "=== NotchHider geometry [\(reason)] \(Date()) — \(screens.count) screen(s) ===\n"
        out += screens.map(\.debugDescription).joined(separator: "\n")
        lastLog = out
        FileHandle.standardError.write(Data((out + "\n").utf8))
    }
}

# NotchHider

A menu bar utility for notched MacBooks (macOS 27, Apple Silicon). It paints the menu bar area pure black so the notch blends in, and adds concave rounded corners just below the menu bar so the black strip looks like part of the bezel.

> **Status:** work in progress. Done: screen/notch detection, corner overlays, wallpaper mode, overlay-bar mode, settings window, Mission Control option, crash recovery. Not done yet: launch at login, full-screen / auto-hide menu bar handling, screenshot exclusion, sandbox analysis. See [Known limitations](#known-limitations).

## Build and install

Only the Command Line Tools are needed (no Xcode).

```bash
./scripts/build_app.sh                       # builds build/NotchHider.app (ad-hoc signed, LSUIElement)
mkdir -p ~/Applications && rm -rf ~/Applications/NotchHider.app && cp -R build/NotchHider.app ~/Applications/
open ~/Applications/NotchHider.app
```

Relaunching an already-running copy (Finder, Spotlight) opens the settings window. `./scripts/make_icon.sh` regenerates the app icon from `Resources/AppIcon-source.jpg`.

## How it works

| Piece | What it does |
|---|---|
| `ScreenGeometry` | Per-display snapshot: menu bar height (`frame.maxY - visibleFrame.maxY`), `safeAreaInsets.top`, `auxiliaryTopLeft/RightArea`, notch rect. A display has a notch when the safe area is non-zero and both auxiliary areas exist. |
| `WallpaperManager` | **Wallpaper mode.** Reads the wallpaper and its options, redraws it at the screen's native pixel size using the same fill / fit / stretch / center rule, paints a black band the height of the menu bar, saves it to `~/Library/Application Support/NotchHider/` under a new filename each time (macOS caches by URL) and applies it. Originals and options are stored per display and restored on disable, restore or quit. |
| `OverlayManager` | **Overlay mode** (and the fallback): a black borderless click-through window over the menu bar, plus the concave corner windows. |
| `AppDelegate` / `main.swift` | Status item and menu, event wiring (screen changes, Space changes, wake, wallpaper-change notification), crash recovery. Event-driven, no timers. |
| `SettingsView` | Settings window (SwiftUI, hosted by `AppDelegate`). |

**Wallpaper mode falls back to the overlay bar** for wallpapers it can't edit: dynamic or multi-image HEIC, Apple built-in and aerial wallpapers, folders / rotating wallpapers, and files that are missing or unreadable. The menu shows the reason per display.

**Corners** are two small transparent click-through windows (four with "bottom corners") that draw a black square minus a quarter circle. They are only shown on displays where the menu bar is actually black.

**Window levels (measured on macOS 27.0.1, notched MacBook).** The menu bar is a Window Server window at layer 24; status items are at 25; Mission Control uses layers up to 20 (WindowManager 14–19, Dock 20). The overlay bar defaults to level **23**: below the menu bar items, above Mission Control. Allowed range is 21–24. Corners are at 25 and never overlap the menu bar.

**Mission Control.** By default the overlays use `.transient` collection behavior and are hidden by Mission Control. With *Keep overlays in Mission Control* on, they use `.stationary` and the bar is drawn as a window even in wallpaper mode (the wallpaper itself is blurred away in Mission Control).

## Verification checklist (manual)

Run these after building. Record outcomes in the table under [Known limitations](#known-limitations).

### 1. Wallpaper mode basics
1. Use a plain image wallpaper that exists on disk (not a dynamic or Apple built-in one; avoid Downloads / Desktop / Documents unless you accept the Files & Folders prompt). Mode → Wallpaper.
2. The menu's top line should read `wallpaper edited`, and a `.jpg` should appear in `~/Library/Application Support/NotchHider/`.
3. The menu bar is black across the full width and the notch is not distinguishable. Check light **and** dark appearance: menu bar text should be white.
4. Quit from the menu: the original wallpaper returns and the generated `.jpg` is deleted.

### 2. Lock screen (Ctrl+Cmd+Q) with the black band applied
1. With the band applied (step 1.2 shows `wallpaper edited`), wait about 5 seconds so macOS can refresh its lock-screen copy of the wallpaper.
2. Press **Ctrl+Cmd+Q**. NotchHider keeps running while the screen is locked.
3. Look at the very top edge of the lock screen and note each of these:
   - **a. Band present?** A solid black strip across the full width, about as tall as the notch (≈38 pt). *Yes* = the band reached the lock screen. *No* = the wallpaper image runs right up to the top edge.
   - **b. Notch hidden?** Can you still see where the notch ends and the screen begins, or does it disappear into the strip?
   - **c. Edge quality.** Is the strip's bottom edge crisp, or soft/blurry (the lock screen blurs the wallpaper)? Is it noticeably taller or shorter than the notch?
   - **d. Legibility.** Are the lock-screen clock, Wi-Fi and battery items readable (white on black), or lost against the strip?
   - **e. Corners.** Expect **no** concave corners (they are app windows and don't exist at the lock screen).
   - **f. Stale image?** Is it showing an old wallpaper rather than the current one?
4. Unlock. The band and corners should still be in place without relaunching.
5. Switch Mode → **Overlay**, lock again and repeat 3a: expect **no bar at all** (see limitations).

### 3. Login window after a restart
**Expectation to confirm:** Restart and Log Out both quit NotchHider first, and quitting restores the original wallpaper, so the login window will most likely show the **original** wallpaper with **no** band.
1. With the band applied, choose Apple menu → Restart (untick "Reopen windows when logging back in"). If auto-login is on you won't see a login window; use **Log Out** (Shift+Cmd+Q) instead.
2. At the login window, check the same items as in 2.3 (a–f). The main question is 3a: band or no band?
3. Log in and open NotchHider (there is no launch-at-login yet). Confirm the band is regenerated and the original wallpaper is still known (Quit restores it correctly).

**Variant: login window with the band left in place.** This shows what the login window does with the edited wallpaper.
1. With the band applied, run `pkill -9 NotchHider` (kills the app without restoring).
2. Log Out, check 2.3 (a–f) at the login window, log back in.
3. Open NotchHider: the crash-recovery prompt should offer to restore the original. Accept it and confirm the original wallpaper returns.

### 4. Revert check
Quit the app, lock the screen once more and confirm there is no black strip left at the top, i.e. the lock screen follows the restored wallpaper.

## Known limitations

**Lock screen and login window**

- **Overlay mode can never appear on the lock screen or login window.** `loginwindow` draws above all app windows, so the overlay bar and the corner windows are not visible there. Only wallpaper mode can affect what the lock screen shows, and only indirectly (see below).
- **Wallpaper mode on the lock screen: result not recorded yet.** It depends on how macOS derives its lock-screen image from the desktop picture, which I have not verified. Fill in the table after running checklist items 2 and 3:

| Test | Band present (a) | Notch hidden (b) | Edge (c) | Legible (d) | Notes |
|---|---|---|---|---|---|
| Lock screen, wallpaper mode (Ctrl+Cmd+Q) | _not yet tested_ | | | | |
| Lock screen, overlay mode | expected: none | | | | |
| Login window after restart / log out | _not yet tested_ (expected: original wallpaper, no band) | | | | |
| Login window with app killed (`pkill -9`) | _not yet tested_ | | | | |

- Quitting, logging out or restarting restores the original wallpaper by design, so the band is not expected to be present at the login window unless the app is killed first.

**Other**

- Menu bar text turning white relies on macOS tinting from the wallpaper under the menu bar. Expected to work in wallpaper mode; **not yet verified** in light and dark mode. In overlay mode the tint comes from the wallpaper underneath, so on a bright wallpaper in light mode the menu text will probably be black on black.
- Whether `setDesktopImageURL` applies to every Space or only the current one is unverified. The app re-checks on each Space change.
- If the original wallpaper file no longer exists (macOS may still display a cached copy), it can't be edited and the overlay bar is used instead.
- Centered wallpapers are approximate (they depend on image DPI). "Tile" is not supported.
- Menu bar height (38 pt) and safe-area height (37.5 pt) differ by 0.5 pt on the tested machine; the band uses the menu bar height.
- Not implemented yet: launch at login, hiding overlays in full-screen Spaces and with an auto-hidden menu bar (currently the top corners are hidden when the menu bar height reads 0), screenshot / recording exclusion, Stage Manager and clamshell checks, sandbox analysis (the app is currently unsandboxed with no entitlements).

## How to fully revert

1. Menu → **Restore original wallpaper** (this also disables NotchHider), or just **Quit**: both put the original wallpaper and options back and remove every overlay window.
2. If the app crashed or was force-quit, open it again and choose **Restore original** in the prompt. Or set your wallpaper again in System Settings.
3. To remove everything: delete `~/Applications/NotchHider.app`, `~/Library/Application Support/NotchHider/` and the preferences (`defaults delete com.example.NotchHider`).

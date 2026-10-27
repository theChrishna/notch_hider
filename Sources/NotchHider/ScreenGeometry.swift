import AppKit

/// Snapshot of everything we need to know about one display's menu bar and notch.
struct ScreenGeometry {
    let displayID: CGDirectDisplayID
    let name: String
    let frame: NSRect
    let visibleFrame: NSRect
    let backingScale: CGFloat
    let safeAreaTop: CGFloat
    let auxLeft: NSRect
    let auxRight: NSRect

    /// Height of the menu bar strip. 0 when the menu bar is auto-hidden or in a full-screen Space.
    var menuBarHeight: CGFloat { frame.maxY - visibleFrame.maxY }

    /// A notch exists when the safe area intrudes at the top and both side areas are reported.
    var hasNotch: Bool { safeAreaTop > 0 && !auxLeft.isEmpty && !auxRight.isEmpty }

    /// Horizontal gap between the two auxiliary areas, in screen coordinates.
    var notchRect: NSRect? {
        guard hasNotch else { return nil }
        return NSRect(x: auxLeft.maxX, y: frame.maxY - safeAreaTop,
                      width: auxRight.minX - auxLeft.maxX, height: safeAreaTop)
    }

    var pixelSize: CGSize { CGSize(width: frame.width * backingScale, height: frame.height * backingScale) }

    init(screen: NSScreen) {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        displayID = CGDirectDisplayID(id?.uint32Value ?? 0)
        name = screen.localizedName
        frame = screen.frame
        visibleFrame = screen.visibleFrame
        backingScale = screen.backingScaleFactor
        safeAreaTop = screen.safeAreaInsets.top
        auxLeft = screen.auxiliaryTopLeftArea ?? .zero
        auxRight = screen.auxiliaryTopRightArea ?? .zero
    }

    static func all() -> [ScreenGeometry] { NSScreen.screens.map(ScreenGeometry.init(screen:)) }

    var debugDescription: String {
        func r(_ x: NSRect) -> String {
            String(format: "(x:%.1f y:%.1f w:%.1f h:%.1f)", x.minX, x.minY, x.width, x.height)
        }
        var lines = [
            "Display \(displayID) \"\(name)\"  built-in:\(CGDisplayIsBuiltin(displayID) != 0)",
            "  frame:            \(r(frame))",
            "  visibleFrame:     \(r(visibleFrame))",
            "  backingScale:     \(backingScale)  -> pixels \(Int(pixelSize.width))x\(Int(pixelSize.height))",
            "  safeAreaInsets.top: \(safeAreaTop)",
            "  auxTopLeftArea:   \(r(auxLeft))",
            "  auxTopRightArea:  \(r(auxRight))",
            String(format: "  menuBarHeight:    %.1f pt (frame.maxY - visibleFrame.maxY)", menuBarHeight),
            "  hasNotch:         \(hasNotch)",
        ]
        if let n = notchRect { lines.append("  notchRect:        \(r(n))") }
        return lines.joined(separator: "\n")
    }
}

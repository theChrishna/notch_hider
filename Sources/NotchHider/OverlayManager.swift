import AppKit

/// Which screen corner a window sits in; knows how to draw the black inverted fillet for it.
enum ScreenCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }

    /// Square of side `r` minus a quarter disc, so the black hugs the screen corner and curves concavely.
    func path(radius r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        switch self {
        case .topLeft:      // disc centre at the square's bottom-right
            p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 0, y: r)); p.addLine(to: CGPoint(x: r, y: r))
            p.addArc(center: CGPoint(x: r, y: 0), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        case .topRight:     // centre at bottom-left
            p.move(to: CGPoint(x: r, y: 0)); p.addLine(to: CGPoint(x: r, y: r)); p.addLine(to: CGPoint(x: 0, y: r))
            p.addArc(center: .zero, radius: r, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        case .bottomLeft:   // centre at top-right
            p.move(to: CGPoint(x: 0, y: r)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: r, y: 0))
            p.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
        case .bottomRight:  // centre at top-left
            p.move(to: CGPoint(x: r, y: r)); p.addLine(to: CGPoint(x: r, y: 0)); p.addLine(to: CGPoint(x: 0, y: 0))
            p.addArc(center: CGPoint(x: 0, y: r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        }
        p.closeSubpath()
        return p
    }
}

private final class CornerWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// AppKit otherwise pushes windows below the menu bar; the overlay bar must sit exactly in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class CornerView: NSView {
    private let shape = CAShapeLayer()
    let corner: ScreenCorner

    init(corner: ScreenCorner) {
        self.corner = corner
        super.init(frame: .zero)
        wantsLayer = true
        shape.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(radius: CGFloat, scale: CGFloat) {
        shape.contentsScale = scale
        shape.frame = CGRect(x: 0, y: 0, width: radius, height: radius)
        shape.path = corner.path(radius: radius)
    }
}

/// Owns the transparent, click-through corner windows. Call `reconcile()` after any event that can change layout.
final class OverlayManager {
    private var windows: [CGDirectDisplayID: [ScreenCorner: CornerWindow]] = [:]
    private var bars: [CGDirectDisplayID: CornerWindow] = [:]

    /// `barDisplays`: displays that need the black overlay bar (overlay mode, or wallpaper-mode fallback).
    /// `blackDisplays`: displays whose menu bar is actually black right now; corners are only drawn there,
    /// so they never appear against a normal menu bar.
    func reconcile(barDisplays: Set<CGDirectDisplayID> = [], blackDisplays: Set<CGDirectDisplayID>) {
        reconcileBars(barDisplays)
        let wanted: [ScreenGeometry] = Prefs.enabled && Prefs.cornersEnabled
            ? ScreenGeometry.all().filter { (Prefs.allScreens || $0.hasNotch) && blackDisplays.contains($0.displayID) } : []
        let ids = Set(wanted.map(\.displayID))
        for id in windows.keys where !ids.contains(id) { removeWindows(for: id) }

        let radius = CGFloat(Prefs.cornerRadius)
        for geo in wanted {
            let corners = ScreenCorner.allCases.filter { $0.isTop || Prefs.bottomCorners }
            var set = windows[geo.displayID] ?? [:]
            for stale in set.keys where !corners.contains(stale) { set[stale]?.orderOut(nil); set[stale] = nil }
            for corner in corners {
                let win = set[corner] ?? makeWindow(corner: corner)
                set[corner] = win
                // Menu bar height 0 means it's hidden (full-screen Space or auto-hide): hide the top corners.
                if corner.isTop && geo.menuBarHeight <= 0 { win.orderOut(nil); continue }
                let x = corner.isLeft ? geo.frame.minX : geo.frame.maxX - radius
                let y = corner.isTop ? geo.frame.maxY - geo.menuBarHeight - radius : geo.frame.minY
                win.setFrame(NSRect(x: x, y: y, width: radius, height: radius), display: false)
                (win.contentView as? CornerView)?.update(radius: radius, scale: geo.backingScale)
                win.orderFrontRegardless()
            }
            windows[geo.displayID] = set
        }
    }

    func removeAll() {
        for id in Array(windows.keys) { removeWindows(for: id) }
        reconcileBars([])
    }

    private func reconcileBars(_ ids: Set<CGDirectDisplayID>) {
        let geos = Dictionary(uniqueKeysWithValues: ScreenGeometry.all().map { ($0.displayID, $0) })
        for id in Array(bars.keys) where !ids.contains(id) || geos[id] == nil || !Prefs.enabled {
            bars[id]?.orderOut(nil); bars[id]?.close(); bars[id] = nil
        }
        guard Prefs.enabled else { return }
        for id in ids {
            guard let geo = geos[id] else { continue }
            let h = geo.menuBarHeight > 0 ? geo.menuBarHeight : geo.safeAreaTop
            guard h > 0 else { bars[id]?.orderOut(nil); continue }
            let win = bars[id] ?? makeBar()
            bars[id] = win
            win.level = NSWindow.Level(rawValue: Prefs.barLevel)
            win.setFrame(NSRect(x: geo.frame.minX, y: geo.frame.maxY - h, width: geo.frame.width, height: h), display: true)
            win.orderFrontRegardless()
        }
    }

    private func makeBar() -> CornerWindow {
        let w = CornerWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return w
    }

    private func removeWindows(for id: CGDirectDisplayID) {
        windows[id]?.values.forEach { $0.orderOut(nil); $0.close() }
        windows[id] = nil
    }

    private func makeWindow(corner: ScreenCorner) -> CornerWindow {
        let w = CornerWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = CornerView(corner: corner)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        // Corners sit below the menu bar so they never cover its items; .statusBar keeps them above app windows.
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return w
    }
}

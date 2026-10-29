import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Desktop image options in a Codable form so originals survive a crash.
struct WallpaperOptions: Codable, Equatable {
    var scaling: UInt = NSImageScaling.scaleProportionallyUpOrDown.rawValue
    var allowClipping = true
    var fillColor: Data?

    init(_ dict: [NSWorkspace.DesktopImageOptionKey: Any]?) {
        guard let dict else { return }
        if let n = dict[.imageScaling] as? NSNumber { scaling = n.uintValue }
        if let c = dict[.allowClipping] as? NSNumber { allowClipping = c.boolValue }
        if let color = dict[.fillColor] as? NSColor {
            fillColor = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        }
    }

    var color: NSColor? {
        guard let fillColor else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: fillColor)
    }

    var dictionary: [NSWorkspace.DesktopImageOptionKey: Any] {
        var d: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: scaling), .allowClipping: NSNumber(value: allowClipping)]
        if let color { d[.fillColor] = color }
        return d
    }
}

/// What we know about one display's wallpaper: the user's original and the file we generated from it.
struct WallpaperRecord: Codable {
    var originalPath: String
    var options: WallpaperOptions
    var generatedPath: String?
    var key: String?
}

/// Edits wallpapers to paint the menu bar strip black. Event-driven: `apply` is called by the coordinator.
final class WallpaperManager {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NotchHider", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let ws = NSWorkspace.shared
    private let recordsKey = "wallpaperRecords"
    private var records: [String: WallpaperRecord]
    private let renderQueue = DispatchQueue(label: "NotchHider.render", qos: .userInitiated)
    private var busy = false, pendingTargets: [ScreenGeometry]?

    /// Human-readable per-display status, shown in the menu.
    private(set) var status: [CGDirectDisplayID: String] = [:]
    /// Displays whose wallpaper can't be edited; the coordinator draws the overlay bar there instead.
    private(set) var needsOverlay: Set<CGDirectDisplayID> = []
    /// Called when status / fallback set changed. Must only refresh overlays, never call `apply` (would loop).
    var onChange: (() -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let r = try? JSONDecoder().decode([String: WallpaperRecord].self, from: data) { records = r } else { records = [:] }
        purgeOrphans()
    }

    // MARK: Public

    /// True if any connected screen is currently showing a wallpaper we generated.
    var hasGeneratedWallpaperSet: Bool {
        NSScreen.screens.contains { s in
            guard let rec = records[Self.uuid(for: s)], let g = rec.generatedPath else { return false }
            return ws.desktopImageURL(for: s)?.path == g
        }
    }

    /// Displays whose current Space is showing our black-banded wallpaper right now (read live, so Space switches count).
    var editedDisplays: Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap { s in
            guard let g = records[Self.uuid(for: s)]?.generatedPath, ws.desktopImageURL(for: s)?.path == g else { return nil }
            return Self.displayID(of: s)
        })
    }

    func apply(targets: [ScreenGeometry]) {
        if busy { pendingTargets = targets; return }
        busy = true
        needsOverlay = []
        let targetIDs = Set(targets.map(\.displayID))

        // Screens that are no longer targets get their original back.
        for screen in NSScreen.screens where !targetIDs.contains(Self.displayID(of: screen)) { restore(screen) }

        var jobs: [Job] = []
        for geo in targets {
            guard let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == geo.displayID }) else { continue }
            if let job = prepare(geo: geo, screen: screen) { jobs.append(job) }
        }
        guard !jobs.isEmpty else { finish(); return }

        renderQueue.async { [weak self] in
            let results = jobs.map { job -> (Job, URL?) in (job, Self.renderAndSave(job)) }
            DispatchQueue.main.async { self?.commit(results) }
        }
    }

    func restoreAll() {
        for screen in NSScreen.screens { restore(screen) }
        status = [:]; needsOverlay = []
    }

    // MARK: Planning

    private struct Job {
        let geo: ScreenGeometry, screen: NSScreen, uuid: String
        let originalURL: URL, options: WallpaperOptions, barPx: Int, key: String, outURL: URL
    }

    private func prepare(geo: ScreenGeometry, screen: NSScreen) -> Job? {
        let id = geo.displayID, uuid = Self.uuid(for: screen)
        guard let current = ws.desktopImageURL(for: screen) else { return fallback(id, "no wallpaper URL") }

        var record = records[uuid]
        if let rec = record, rec.generatedPath == current.path {
            // Our own output is showing; the original is already known.
        } else if current.path.hasPrefix(Self.directory.path) {
            // One of our files, but not the one we expect (e.g. records lost). Without the original we can't regenerate.
            if record == nil { return fallback(id, "own file with unknown original — use Restore") }
        } else {
            // The user (or the system) picked something new: remember it as the original.
            if let old = record?.generatedPath { try? FileManager.default.removeItem(atPath: old) }
            record = WallpaperRecord(originalPath: current.path, options: WallpaperOptions(ws.desktopImageOptions(for: screen)))
            records[uuid] = record
            persist()
        }
        guard var rec = record else { return nil }
        let original = URL(fileURLWithPath: rec.originalPath)
        if let reason = Self.uneditableReason(original) {
            // Keep the original on record but don't touch the screen.
            records[uuid]?.generatedPath = nil; rec.generatedPath = nil
            return fallback(id, reason)
        }

        let bar = geo.menuBarHeight > 0 ? geo.menuBarHeight : geo.safeAreaTop
        guard bar > 0 else { status[id] = "menu bar hidden — waiting"; return nil }
        let barPx = Int(ceil(bar * geo.backingScale))
        let mod = (try? original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(Int(geo.pixelSize.width))x\(Int(geo.pixelSize.height))|\(barPx)|\(rec.options.scaling)|\(rec.options.allowClipping)|\(rec.originalPath)|\(mod)"

        if rec.key == key, let g = rec.generatedPath, g == current.path, FileManager.default.fileExists(atPath: g) {
            status[id] = "wallpaper edited (up to date)"
            return nil
        }
        // A new filename per change: macOS caches wallpapers by URL.
        let out = Self.directory.appendingPathComponent("\(uuid)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
        return Job(geo: geo, screen: screen, uuid: uuid, originalURL: original, options: rec.options, barPx: barPx, key: key, outURL: out)
    }

    private func fallback(_ id: CGDirectDisplayID, _ reason: String) -> Job? {
        status[id] = "using overlay bar — \(reason)"
        FileHandle.standardError.write(Data("[wallpaper] display \(id): fallback — \(reason)\n".utf8))
        needsOverlay.insert(id)
        return nil
    }

    // MARK: Commit / restore

    private func commit(_ results: [(Job, URL?)]) {
        for (job, url) in results {
            let id = job.geo.displayID
            guard let url else { _ = fallback(id, "couldn't render wallpaper"); continue }
            // Exact-size image, so 1:1 mapping regardless of the user's fill mode.
            let opts: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
                .allowClipping: NSNumber(value: true), .fillColor: NSColor.black]
            do {
                try ws.setDesktopImageURL(url, for: job.screen, options: opts)
                if let old = records[job.uuid]?.generatedPath, old != url.path { try? FileManager.default.removeItem(atPath: old) }
                records[job.uuid]?.generatedPath = url.path
                records[job.uuid]?.key = job.key
                status[id] = "wallpaper edited"
            } catch {
                try? FileManager.default.removeItem(at: url)
                _ = fallback(id, "set failed: \(error.localizedDescription)")
            }
        }
        persist()
        finish()
    }

    private func finish() {
        busy = false
        onChange?()
        // A request arrived mid-render: run it now against the newest geometry.
        if let next = pendingTargets { pendingTargets = nil; apply(targets: next) }
    }

    private func restore(_ screen: NSScreen) {
        let uuid = Self.uuid(for: screen)
        guard let rec = records[uuid] else { return }
        // Only touch the screen if our file is still the one showing; otherwise the user already changed it.
        if let g = rec.generatedPath, ws.desktopImageURL(for: screen)?.path == g {
            try? ws.setDesktopImageURL(URL(fileURLWithPath: rec.originalPath), for: screen, options: rec.options.dictionary)
        }
        if let g = rec.generatedPath { try? FileManager.default.removeItem(atPath: g) }
        records[uuid] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: recordsKey) }
    }

    private func purgeOrphans() {
        let keep = Set(records.values.compactMap(\.generatedPath))
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "jpg" && !keep.contains(f.path) { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: Identity

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        CGDirectDisplayID((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }

    /// Stable across reconnects, unlike CGDirectDisplayID.
    static func uuid(for screen: NSScreen) -> String {
        let id = displayID(of: screen)
        if let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, u) as String
        }
        return "display-\(id)"
    }

    // MARK: Editability

    /// nil if we can safely edit this file; otherwise why not.
    static func uneditableReason(_ url: URL) -> String? {
        // Actually open the file: unlike fileExists, a read triggers the macOS Files & Folders prompt
        // for protected locations (Downloads, Desktop, Documents) and reports why it failed.
        do { try FileHandle(forReadingFrom: url).close() } catch let e as NSError {
            if e.code == NSFileReadNoPermissionError {
                return "no permission to read \(url.deletingLastPathComponent().lastPathComponent)/ — allow it in System Settings ▸ Privacy & Security ▸ Files & Folders"
            }
            return "original file missing"
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { return "folder / rotating wallpaper" }
        let p = url.path
        if p.hasPrefix("/System/Library/Desktop Pictures") || p.contains("com.apple.wallpaper")
            || p.contains("Aerial") || p.contains("mobileAssets") || p.contains("MobileAsset") {
            return "Apple built-in / aerial wallpaper"
        }
        guard ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "gif", "bmp"].contains(url.pathExtension.lowercased()) else {
            return "unsupported file type (.\(url.pathExtension))"
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "unreadable image" }
        if CGImageSourceGetCount(src) > 1 { return "dynamic / multi-image wallpaper" }
        if let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            var dynamic = false
            CGImageMetadataEnumerateTagsUsingBlock(md, nil, nil) { _, tag in
                if let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, prefix == "apple_desktop" { dynamic = true; return false }
                return true
            }
            if dynamic { return "dynamic (light/dark/time) wallpaper" }
        }
        return nil
    }

    // MARK: Rendering (background queue)

    private static func renderAndSave(_ job: Job) -> URL? {
        guard let image = render(job) else { return nil }
        guard let dest = CGImageDestinationCreateWithURL(job.outURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? job.outURL : nil
    }

    private static func render(_ job: Job) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(job.originalURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // The thumbnail API applies EXIF orientation; plain CreateImageAtIndex doesn't.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph), kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        let W = Int(job.geo.pixelSize.width), H = Int(job.geo.pixelSize.height)
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let fill = (job.options.color ?? .black).usingColorSpace(.sRGB) ?? .black
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .high

        let iw = CGFloat(img.width), ih = CGFloat(img.height), fw = CGFloat(W), fh = CGFloat(H)
        let size: CGSize
        switch NSImageScaling(rawValue: job.options.scaling) ?? .scaleProportionallyUpOrDown {
        case .scaleAxesIndependently:            // Stretch
            size = CGSize(width: fw, height: fh)
        case .scaleNone:                         // Center: image's logical (DPI-aware) size at the screen's scale
            let dpi = (props[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
            let k = 72 / (dpi > 0 ? dpi : 72) * job.geo.backingScale
            size = CGSize(width: iw * k, height: ih * k)
        case .scaleProportionallyDown:           // shrink to fit only
            let s = min(1, min(fw / iw, fh / ih)); size = CGSize(width: iw * s, height: ih * s)
        default:                                 // UpOrDown: Fill Screen (clipping) or Fit to Screen
            let s = job.options.allowClipping ? max(fw / iw, fh / ih) : min(fw / iw, fh / ih)
            size = CGSize(width: iw * s, height: ih * s)
        }
        ctx.draw(img, in: CGRect(x: (fw - size.width) / 2, y: (fh - size.height) / 2, width: size.width, height: size.height))

        // Black band across the top: CG origin is bottom-left.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: fh - CGFloat(job.barPx), width: fw, height: CGFloat(job.barPx)))
        return ctx.makeImage()
    }
}

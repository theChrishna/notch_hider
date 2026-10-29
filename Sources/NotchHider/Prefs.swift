import Foundation

/// Thin UserDefaults-backed settings. SwiftUI's @AppStorage uses the same keys in the settings step.
enum Prefs {
    static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    static var cornersEnabled: Bool {
        get { defaults.object(forKey: "cornersEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cornersEnabled") }
    }
    static var cornerRadius: Double {
        get { defaults.object(forKey: "cornerRadius") as? Double ?? 20 }
        set { defaults.set(newValue, forKey: "cornerRadius") }
    }
    static var bottomCorners: Bool {
        get { defaults.bool(forKey: "bottomCorners") }
        set { defaults.set(newValue, forKey: "bottomCorners") }
    }
    static var allScreens: Bool {
        get { defaults.bool(forKey: "allScreens") }
        set { defaults.set(newValue, forKey: "allScreens") }
    }
    /// Keep the corners / overlay bar visible in Mission Control (.stationary) instead of hiding them (.transient).
    static var showInMissionControl: Bool {
        get { defaults.bool(forKey: "showInMissionControl") }
        set { defaults.set(newValue, forKey: "showInMissionControl") }
    }
    /// "wallpaper" or "overlay"
    static var mode: String {
        get { defaults.string(forKey: "mode") ?? "wallpaper" }
        set { defaults.set(newValue, forKey: "mode") }
    }
    /// Window level of the overlay bar. 23 = just below the menu bar (kCGMainMenuWindowLevel is 24).
    /// Clamped to 21...24: on macOS 27 Mission Control's own windows use layers up to 20, so a lower bar gets
    /// covered by its blur; 24 is the menu bar itself.
    static let barLevelRange = 21...24
    static var barLevel: Int {
        get { min(max(defaults.object(forKey: "barLevel") as? Int ?? 23, barLevelRange.lowerBound), barLevelRange.upperBound) }
        set { defaults.set(newValue, forKey: "barLevel") }
    }
    /// False from launch until a clean quit; true at next launch means the previous run crashed.
    static var cleanExit: Bool? {
        get { defaults.object(forKey: "cleanExit") as? Bool }
        set { defaults.set(newValue, forKey: "cleanExit") }
    }
    /// Changes whenever a setting that affects layout changes (ignores unrelated defaults writes).
    static var signature: String {
        "\(enabled)\(cornersEnabled)\(cornerRadius)\(bottomCorners)\(allScreens)\(mode)\(barLevel)\(showInMissionControl)"
    }
}

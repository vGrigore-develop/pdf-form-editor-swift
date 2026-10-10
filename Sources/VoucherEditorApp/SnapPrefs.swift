import Foundation

/// Snapping preferences, persisted in UserDefaults and read by the canvas on every drag.
/// The toolbar binds to the same keys with @AppStorage.
enum SnapPrefs {
    static let enabledKey = "snapEnabled"
    static let gridKey = "snapGridSize"
    static let showGridKey = "snapShowGrid"
    static let gridSizes: [Double] = [1, 2, 5, 10]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: true, gridKey: 1.0, showGridKey: false])
    }

    static var enabled: Bool {
        get { registerDefaults(); return UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var grid: Double {
        get { registerDefaults(); let g = UserDefaults.standard.double(forKey: gridKey); return g > 0 ? g : 1 }
        set { UserDefaults.standard.set(newValue, forKey: gridKey) }
    }
    static var showGrid: Bool {
        get { registerDefaults(); return UserDefaults.standard.bool(forKey: showGridKey) }
        set { UserDefaults.standard.set(newValue, forKey: showGridKey) }
    }
}

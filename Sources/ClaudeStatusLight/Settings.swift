import Foundation
import CoreGraphics

extension Notification.Name {
    /// Posted whenever a user-facing setting changes.
    static let statusLightSettingsChanged = Notification.Name("statusLightSettingsChanged")
}

enum ScreenCorner: Int, CaseIterable {
    case topLeft = 0, topRight, bottomLeft, bottomRight

    var label: String {
        switch self {
        case .topLeft:     return "Top Left"
        case .topRight:    return "Top Right"
        case .bottomLeft:  return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

/// User preferences, persisted in UserDefaults. Mutating a preference posts
/// `.statusLightSettingsChanged` so the app can re-apply it live.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let showMenuBar = "showMenuBar"
        static let showFloating = "showFloatingWindow"
        static let showDock = "showDockIcon"
        static let lockCorner = "lockToCorner"
        static let corner = "floatingCorner"
        static let greenBeatsYellow = "greenBeatsYellow"
        static let floatingX = "floatingOriginX"
        static let floatingY = "floatingOriginY"
    }

    private init() {
        defaults.register(defaults: [
            Key.showMenuBar: true,
            Key.showFloating: false,
            Key.showDock: false,
            Key.lockCorner: true,
            Key.corner: ScreenCorner.topRight.rawValue,
            Key.greenBeatsYellow: true,
        ])
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .statusLightSettingsChanged, object: nil)
    }

    var showMenuBar: Bool {
        get { defaults.bool(forKey: Key.showMenuBar) }
        set { store(newValue, Key.showMenuBar) }
    }
    var showFloatingWindow: Bool {
        get { defaults.bool(forKey: Key.showFloating) }
        set { store(newValue, Key.showFloating) }
    }
    var showDockIcon: Bool {
        get { defaults.bool(forKey: Key.showDock) }
        set { store(newValue, Key.showDock) }
    }
    var lockToCorner: Bool {
        get { defaults.bool(forKey: Key.lockCorner) }
        set { store(newValue, Key.lockCorner) }
    }
    var greenBeatsYellow: Bool {
        get { defaults.bool(forKey: Key.greenBeatsYellow) }
        set { store(newValue, Key.greenBeatsYellow) }
    }
    var corner: ScreenCorner {
        get { ScreenCorner(rawValue: defaults.integer(forKey: Key.corner)) ?? .topRight }
        set { store(newValue.rawValue, Key.corner) }
    }

    /// Custom position for the floating window when it isn't locked to a corner.
    /// Saved silently (no notification) so dragging doesn't churn the UI.
    var floatingOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Key.floatingX) != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: Key.floatingX),
                           y: defaults.double(forKey: Key.floatingY))
        }
        set {
            if let p = newValue {
                defaults.set(p.x, forKey: Key.floatingX)
                defaults.set(p.y, forKey: Key.floatingY)
            } else {
                defaults.removeObject(forKey: Key.floatingX)
                defaults.removeObject(forKey: Key.floatingY)
            }
        }
    }
}

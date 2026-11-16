import UIKit

/// The three themes of the official app, plus "follow the system" (iOS 12 is always light).
enum ThemeMode: Int {
    case light = 0, dim = 1, black = 2, system = 3
}

/// Every colour a view may use. Memberwise order is the order of the properties below.
struct Palette {
    let background, text, secondaryText, separator, border, surface, highlight, avatarPlaceholder: UIColor
    let accent, like, repost, danger, gold, grey: UIColor
    let overlay: UIColor            // dimming behind sheets and the drawer
    let isDark: Bool
}

extension UIColor {
    /// Colour from 0xRRGGBB.
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Colours that are the same in every theme.
private enum Fixed {
    static let accent = UIColor(hex: 0x1D9BF0)
    static let like = UIColor(hex: 0xF91880)
    static let repost = UIColor(hex: 0x00BA7C)
    static let danger = UIColor(hex: 0xF4212E)
    static let gold = UIColor(hex: 0xE2B719)
    static let grey = UIColor(hex: 0x829AAB)
}

extension Palette {
    static let light = Palette(
        background: UIColor(hex: 0xFFFFFF),
        text: UIColor(hex: 0x0F1419),
        secondaryText: UIColor(hex: 0x536471),
        separator: UIColor(hex: 0xEFF3F4),
        border: UIColor(hex: 0xCFD9DE),
        surface: UIColor(hex: 0xEFF3F4),
        highlight: UIColor(hex: 0xF7F9F9),
        avatarPlaceholder: UIColor(hex: 0xCFD9DE),
        accent: Fixed.accent,
        like: Fixed.like,
        repost: Fixed.repost,
        danger: Fixed.danger,
        gold: Fixed.gold,
        grey: Fixed.grey,
        overlay: UIColor(hex: 0x000000, alpha: 0.4),
        isDark: false
    )

    static let dim = Palette(
        background: UIColor(hex: 0x15202B),
        text: UIColor(hex: 0xF7F9F9),
        secondaryText: UIColor(hex: 0x8B98A5),
        separator: UIColor(hex: 0x38444D),
        border: UIColor(hex: 0x425364),
        surface: UIColor(hex: 0x273340),
        highlight: UIColor(hex: 0x1E2732),
        avatarPlaceholder: UIColor(hex: 0x3D5466),
        accent: Fixed.accent,
        like: Fixed.like,
        repost: Fixed.repost,
        danger: Fixed.danger,
        gold: Fixed.gold,
        grey: Fixed.grey,
        overlay: UIColor(hex: 0x5B7083, alpha: 0.4),
        isDark: true
    )

    static let black = Palette(
        background: UIColor(hex: 0x000000),
        text: UIColor(hex: 0xE7E9EA),
        secondaryText: UIColor(hex: 0x71767B),
        separator: UIColor(hex: 0x2F3336),
        border: UIColor(hex: 0x333639),
        surface: UIColor(hex: 0x202327),
        highlight: UIColor(hex: 0x16181C),
        avatarPlaceholder: UIColor(hex: 0x333639),
        accent: Fixed.accent,
        like: Fixed.like,
        repost: Fixed.repost,
        danger: Fixed.danger,
        gold: Fixed.gold,
        grey: Fixed.grey,
        overlay: UIColor(hex: 0x5B7083, alpha: 0.4),
        isDark: true
    )
}

/// The persisted theme choice and the palette in effect.
enum Theme {
    /// Posted when the mode changes, or when the effective palette of `.system` changes.
    static let didChange = Notification.Name("ThemeDidChange")

    private static let modeKey = "themeMode"
    /// The `.system` palette, refreshed by `resolve(for:)`; nil until first needed.
    private static var systemCache: Palette?

    /// Persisted in UserDefaults; a missing or unknown value means `.system`.
    static var mode: ThemeMode {
        get {
            let stored = UserDefaults.standard.object(forKey: modeKey) as? Int
            return stored.flatMap { ThemeMode(rawValue: $0) } ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// The palette in effect now.
    static var palette: Palette {
        switch mode {
        case .light:
            return Palette.light
        case .dim:
            return Palette.dim
        case .black:
            return Palette.black
        case .system:
            return systemPalette
        }
    }

    /// Recomputes the `.system` palette from the traits (the App layer passes the window's traits).
    static func resolve(for traits: UITraitCollection?) {
        let previous = palette
        systemCache = paletteForSystem(traits)
        // Other modes ignore the system style, so only `.system` announces a change.
        if mode == .system && palette.isDark != previous.isDark {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Status bar style for the palette in effect: dark text only on the light theme.
    static var statusBarStyle: UIStatusBarStyle {
        if palette.isDark {
            return .lightContent
        }
        if #available(iOS 13.0, *) {
            return .darkContent
        }
        return .default
    }

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: weight)
    }

    private static var systemPalette: Palette {
        if let cached = systemCache {
            return cached
        }
        let fresh = paletteForSystem(UIScreen.main.traitCollection)
        systemCache = fresh
        return fresh
    }

    private static func paletteForSystem(_ traits: UITraitCollection?) -> Palette {
        // iOS 12 has no system dark style, so it always gets the light palette.
        if #available(iOS 13.0, *), traits?.userInterfaceStyle == .dark {
            return Palette.black
        }
        return Palette.light
    }
}

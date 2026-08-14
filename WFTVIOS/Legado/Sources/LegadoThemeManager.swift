import UIKit

class LegadoThemeManager {
    static let shared = LegadoThemeManager()
    
    private let themeKey = "app_theme"
    
    enum LegadoTheme: Int {
        case system = 0
        case light = 1
        case dark = 2
        
        var title: String {
            switch self {
            case .system: return "自动"
            case .light: return "白天"
            case .dark: return "黑夜"
            }
        }
    }
    
    var currentTheme: LegadoTheme {
        get {
            let value = UserDefaults.standard.integer(forKey: themeKey)
            return LegadoTheme(rawValue: value) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
            applyTheme()
        }
    }
    
    private init() {}
    
    func applyTheme() {
        let style: UIUserInterfaceStyle
        switch currentTheme {
        case .system:
            style = .unspecified
        case .light:
            style = .light
        case .dark:
            style = .dark
        }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

import Foundation
import SwiftUI
import Combine
import UIKit

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    
    @Published var currentTheme: ColorScheme?
    @Published var selectedTheme: Theme = .system
    
    private let userDefaults = UserDefaults.standard
    private let themeKey = "WFTV_Theme"
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        loadTheme()
        setupSystemThemeObserver()
    }
    
    // MARK: - Theme Management
    private func loadTheme() {
        if let themeString = userDefaults.string(forKey: themeKey),
           let theme = Theme(rawValue: themeString) {
            selectedTheme = theme
            applyTheme(theme)
        } else {
            // 默认使用浅色主题
            selectedTheme = .light
            applyTheme(.light)
        }
    }
    
    private func saveTheme(_ theme: Theme) {
        userDefaults.set(theme.rawValue, forKey: themeKey)
    }
    
    private func setupSystemThemeObserver() {
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard self?.selectedTheme == .system else { return }
                self?.updateSystemThemeIfNeeded()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)
            .sink { [weak self] _ in
                guard self?.selectedTheme == .system else { return }
                self?.updateSystemThemeIfNeeded()
            }
            .store(in: &cancellables)
    }
    
    func setTheme(_ theme: Theme) {
        selectedTheme = theme
        applyTheme(theme)
        saveTheme(theme)
    }
    
    private func applyTheme(_ theme: Theme) {
        let applyBlock = {
            switch theme {
            case .light:
                self.currentTheme = .light
            case .dark:
                self.currentTheme = .dark
            case .system:
                // 交给系统实时决定，避免“自动”被当前强制主题锁住。
                self.currentTheme = nil
            }
        }
        if Thread.isMainThread {
            applyBlock()
        } else {
            DispatchQueue.main.async(execute: applyBlock)
        }
    }
    
    private func updateSystemThemeIfNeeded() {
        let updateBlock = {
            guard self.selectedTheme == .system else { return }
            if self.currentTheme != nil {
                self.currentTheme = nil
            }
        }
        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async(execute: updateBlock)
        }
    }
    
    func getCurrentTheme() -> Theme {
        return selectedTheme
    }

    func refreshSystemThemeIfNeeded() {
        guard selectedTheme == .system else { return }
        updateSystemThemeIfNeeded()
    }
    
    // MARK: - Helper Methods
    private func effectiveColorScheme() -> ColorScheme {
        if let currentTheme {
            return currentTheme
        }
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            return window.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }

    func isDarkMode() -> Bool {
        return effectiveColorScheme() == .dark
    }
    
    func isLightMode() -> Bool {
        return effectiveColorScheme() == .light
    }
    
    func isSystemMode() -> Bool {
        return selectedTheme == .system
    }
    
    // MARK: - Color Schemes
    func getBackgroundColor() -> Color {
        switch currentTheme {
        case .light:
            return Color(.systemBackground)
        case .dark:
            return Color(red: 18/255, green: 18/255, blue: 20/255) // 更深的背景色 #121214
        case .none:
            return Color(.systemBackground)
        @unknown default:
            return Color(.systemBackground)
        }
    }
    
    func getSecondaryBackgroundColor() -> Color {
        switch currentTheme {
        case .light:
            return Color(.secondarySystemBackground)
        case .dark:
            return Color(red: 28/255, green: 28/255, blue: 30/255) // 次级背景色 #1C1C1E
        case .none:
            return Color(.secondarySystemBackground)
        @unknown default:
            return Color(.secondarySystemBackground)
        }
    }
    
    func getCardBackgroundColor() -> Color {
        switch currentTheme {
        case .light:
            return Color(.systemBackground)
        case .dark:
            return Color(red: 38/255, green: 38/255, blue: 40/255) // 卡片背景 #262628
        case .none:
            return Color(.systemBackground)
        @unknown default:
            return Color(.systemBackground)
        }
    }
    
    func getTertiaryBackgroundColor() -> Color {
        switch currentTheme {
        case .light:
            return Color(.tertiarySystemBackground)
        case .dark:
            return Color(red: 58/255, green: 58/255, blue: 60/255) // 第三级背景 #3A3A3C
        case .none:
            return Color(.tertiarySystemBackground)
        @unknown default:
            return Color(.tertiarySystemBackground)
        }
    }
    
    func getTextColor() -> Color {
        switch currentTheme {
        case .light:
            return Color(.label)
        case .dark:
            return Color.white // 深色模式下使用白色文字
        case .none:
            return Color(.label)
        @unknown default:
            return Color(.label)
        }
    }
    
    func getSecondaryTextColor() -> Color {
        switch currentTheme {
        case .light:
            return Color(.secondaryLabel)
        case .dark:
            return Color(white: 0.8) // 深色模式下使用稍暗的白色
        case .none:
            return Color(.secondaryLabel)
        @unknown default:
            return Color(.secondaryLabel)
        }
    }
    
    func getAccentColor() -> Color {
        switch currentTheme {
        case .light:
            return Color.blue
        case .dark:
            return Color(red: 0.4, green: 0.7, blue: 1.0) // 深色模式下使用更亮的蓝色
        case .none:
            return Color.blue
        @unknown default:
            return Color.blue
        }
    }
    
    // 新增：获取分割线颜色
    func getSeparatorColor() -> Color {
        switch currentTheme {
        case .light:
            return Color(.separator)
        case .dark:
            return Color(red: 84/255, green: 84/255, blue: 88/255) // #545458
        case .none:
            return Color(.separator)
        @unknown default:
            return Color(.separator)
        }
    }
    
    // 新增：获取按钮背景色
    func getButtonBackgroundColor() -> Color {
        switch currentTheme {
        case .light:
            return Color(.systemGray6)
        case .dark:
            return Color(red: 48/255, green: 48/255, blue: 50/255) // 按钮背景 #303032
        case .none:
            return Color(.systemGray6)
        @unknown default:
            return Color(.systemGray6)
        }
    }
} 

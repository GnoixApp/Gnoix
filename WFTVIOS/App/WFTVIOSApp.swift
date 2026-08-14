//
//  WFTVIOSApp.swift
//  WFTVIOS
//
//  Created by 小猪佩圆 on 2025/7/6.
//

import SwiftUI

@main
struct WFTVIOSApp: App {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var contentSourceManager = ContentSourceManager.shared
    @StateObject private var preferencesManager = UserPreferencesManager()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .environmentObject(contentSourceManager)
                .environmentObject(preferencesManager)
                .preferredColorScheme(themeManager.currentTheme)
                .onAppear {
                    // 初始化默认内容源
                    if contentSourceManager.sources.isEmpty {
                        contentSourceManager.addDefaultSource()
                    }
                    
                    // 从偏好设置恢复主题，避免重复设置
                    let savedTheme = preferencesManager.preferences.theme
                    if themeManager.selectedTheme != savedTheme {
                        themeManager.setTheme(savedTheme)
                    }
                }
                .onChange(of: themeManager.selectedTheme) { newTheme in
                    // 当主题改变时，同步到偏好设置
                    if preferencesManager.preferences.theme != newTheme {
                        preferencesManager.setTheme(newTheme)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // 应用激活时仅在需要时刷新系统主题，避免重复触发整树重绘
                    themeManager.refreshSystemThemeIfNeeded()
                }
        }
    }
}

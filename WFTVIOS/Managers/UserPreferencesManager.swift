import Foundation
import Combine
import UIKit

class UserPreferencesManager: ObservableObject {
    @Published var preferences: UserPreferences
    @Published private(set) var reduceTransparency: Bool
    
    private let userDefaults = UserDefaults.standard
    private let preferencesKey = "WFTV_UserPreferences"
    private let reduceTransparencyKey = "WFTV_ReduceTransparency"
    private let cacheCleanupQueue = DispatchQueue(label: "cn.oily.wftv.cache.cleanup", qos: .utility)
    
    init() {
        if let data = userDefaults.data(forKey: preferencesKey),
           let decodedPreferences = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            self.preferences = decodedPreferences
        } else {
            self.preferences = UserPreferences()
        }
        self.reduceTransparency = userDefaults.bool(forKey: reduceTransparencyKey)
    }
    
    // MARK: - Save Preferences
    private func savePreferences() {
        if let encoded = try? JSONEncoder().encode(preferences) {
            userDefaults.set(encoded, forKey: preferencesKey)
        }
    }
    
    // MARK: - Auto Play
    func setAutoPlay(_ enabled: Bool) {
        preferences.autoPlay = enabled
        savePreferences()
    }
    
    // MARK: - Video Quality
    func setVideoQuality(_ quality: VideoQuality) {
        preferences.quality = quality
        savePreferences()
    }
    
    // MARK: - Theme
    func setTheme(_ theme: Theme) {
        preferences.theme = theme
        savePreferences()
    }
    
    // MARK: - Selected Source
    func setSelectedSourceId(_ sourceId: UUID?) {
        preferences.selectedSourceId = sourceId
        savePreferences()
    }
    
    // MARK: - Selected Category
    func setSelectedCategoryId(_ categoryId: String?) {
        preferences.selectedCategoryId = categoryId
        savePreferences()
    }
    
    // MARK: - Selected Custom Web Page
    func setSelectedCustomWebPageId(_ pageId: UUID?) {
        preferences.selectedCustomWebPageId = pageId
        savePreferences()
    }
    
    // MARK: - Cache Management
    func clearCache(completion: (() -> Void)? = nil) {
        cacheCleanupQueue.async {
            // 清理URLCache
            URLCache.shared.removeAllCachedResponses()
            
            // 清理应用临时导出目录与历史遗留导出文件
            let tempDirectory = FileManager.default.temporaryDirectory
            let legacyFileNames = Set(["book.txt", "book.epub"])
            do {
                let tempFiles = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
                for file in tempFiles {
                    let fileName = file.lastPathComponent.lowercased()
                    let shouldRemove =
                        file == AppTempPaths.exportDirectoryURL ||
                        fileName.hasPrefix("wftv_") ||
                        legacyFileNames.contains(fileName)
                    if shouldRemove {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            } catch {
                print("清理缓存失败: \(error)")
            }

            DispatchQueue.main.async {
                completion?()
            }
        }
    }
    
    // MARK: - Cache Size
    func getCacheSize() -> String {
        let cacheSize = URLCache.shared.currentDiskUsage
        return ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)
    }
    
    // MARK: - Custom Web Pages
    func addCustomWebPage(_ webPage: CustomWebPage) {
        preferences.customWebPages.append(webPage)
        savePreferences()
    }
    
    func removeCustomWebPage(_ webPage: CustomWebPage) {
        preferences.customWebPages.removeAll { $0.id == webPage.id }
        savePreferences()
    }
    
    func updateCustomWebPage(_ webPage: CustomWebPage) {
        if let index = preferences.customWebPages.firstIndex(where: { $0.id == webPage.id }) {
            preferences.customWebPages[index] = webPage
            savePreferences()
        }
    }
    
    func toggleCustomWebPageEnabled(_ webPage: CustomWebPage) {
        if let index = preferences.customWebPages.firstIndex(where: { $0.id == webPage.id }) {
            preferences.customWebPages[index].isEnabled.toggle()
            savePreferences()
        }
    }
    
    var enabledCustomWebPages: [CustomWebPage] {
        return preferences.customWebPages.filter { $0.isEnabled }
    }
    
    var selectedCustomWebPage: CustomWebPage? {
        if let selectedId = preferences.selectedCustomWebPageId {
            return enabledCustomWebPages.first { $0.id == selectedId }
        }
        return enabledCustomWebPages.first
    }
    
    // MARK: - Local Book Parse Mode
    var useLocalBookParse: Bool {
        return preferences.useLocalBookParse
    }
    
    func setLocalBookParse(_ enabled: Bool) {
        preferences.useLocalBookParse = enabled
        savePreferences()
    }

    // MARK: - Transparency
    var shouldReduceTransparency: Bool {
        reduceTransparency || UIAccessibility.isReduceTransparencyEnabled
    }

    func setReduceTransparency(_ enabled: Bool) {
        guard reduceTransparency != enabled else { return }
        reduceTransparency = enabled
        userDefaults.set(enabled, forKey: reduceTransparencyKey)
    }

    static func shouldReduceTransparencyFromStorage() -> Bool {
        let storedReduceTransparency = UserDefaults.standard.bool(forKey: "WFTV_ReduceTransparency")
        return storedReduceTransparency || UIAccessibility.isReduceTransparencyEnabled
    }
}

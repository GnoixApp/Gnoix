import Foundation
import Combine

class ContentSourceManager: ObservableObject {
    static let shared = ContentSourceManager()
    private static let verboseLoggingEnabled = false

    struct SourceMergeResult {
        var added: Int = 0
        var updated: Int = 0
        var skipped: Int = 0

        var imported: Int {
            added + updated
        }
    }
    
    @Published var sources: [ContentSource] = []
    @Published var selectedSource: ContentSource?
    @Published var liveSources: [LiveSource] = []
    
    private let userDefaults = UserDefaults.standard
    private let sourcesKey = "WFTV_ContentSources"
    private let selectedSourceKey = "WFTV_SelectedSource"
    private let liveSourcesKey = "WFTV_LiveSources"

    private func log(_ message: @autoclosure () -> String) {
        guard Self.verboseLoggingEnabled else { return }
        print(message())
    }
    
    init() {
        loadSources()
        loadSelectedSource()
        loadLiveSources()
    }
    
    // MARK: - Load/Save Sources
    private func loadSources() {
        if let data = userDefaults.data(forKey: sourcesKey),
           let decodedSources = try? JSONDecoder().decode([ContentSource].self, from: data) {
            sources = decodedSources
        }
    }
    
    private func saveSources() {
        if let encoded = try? JSONEncoder().encode(sources) {
            userDefaults.set(encoded, forKey: sourcesKey)
        }
    }
    
    private func loadSelectedSource() {
        if let data = userDefaults.data(forKey: selectedSourceKey),
           let decodedSource = try? JSONDecoder().decode(ContentSource.self, from: data) {
            selectedSource = decodedSource
        } else if let firstSource = sources.first {
            selectedSource = firstSource
        }
    }
    
    private func saveSelectedSource() {
        if let source = selectedSource,
           let encoded = try? JSONEncoder().encode(source) {
            userDefaults.set(encoded, forKey: selectedSourceKey)
        }
    }
    
    // MARK: - Source Management
    func addSource(_ source: ContentSource) {
        let newKey = sourceDedupKey(source)
        guard !sources.contains(where: { sourceDedupKey($0) == newKey }) else {
            return
        }
        sources.append(source)
        saveSources()
        
        if selectedSource == nil {
            selectedSource = source
            saveSelectedSource()
        }
    }
    
    func removeSource(_ source: ContentSource) {
        sources.removeAll { $0.id == source.id }
        saveSources()
        
        if selectedSource?.id == source.id {
            selectedSource = sources.first
            saveSelectedSource()
        }
    }
    
    func updateSource(_ source: ContentSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
            saveSources()
            
            if selectedSource?.id == source.id {
                selectedSource = source
                saveSelectedSource()
            }
        }
    }
    
    func selectSource(_ source: ContentSource) {
        selectedSource = source
        saveSelectedSource()
    }
    
    func toggleSource(_ source: ContentSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index].isActive.toggle()
            saveSources()
            
            if selectedSource?.id == source.id && !sources[index].isActive {
                selectedSource = sources.first { $0.isActive }
                saveSelectedSource()
            }
        }
    }
    
    // MARK: - Default Source
    func addDefaultSource() {
        let defaultSource = ContentSource(
            name: "默认源",
            url: "https://json.heimuer.xyz/api.php/provide/vod/",
            isActive: true
        )
        addSource(defaultSource)
    }
    
    // MARK: - Import Sources from JSON
    func importSources(from jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8),
              let importedSources = try? JSONDecoder().decode([ContentSource].self, from: data) else {
            return false
        }
        _ = mergeContentSources(importedSources)
        return true
    }
    
    // MARK: - Import Sources from URL (Subscription Format)
    func importSources(from url: URL) async throws {
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Debug: Print raw JSON for troubleshooting
        if let jsonString = String(data: data, encoding: .utf8) {
            log("[ContentSourceManager] Raw JSON preview: \(jsonString.prefix(500))...")
        }
        
        let subscriptionResponse: EnhancedSubscriptionResponse
        do {
            subscriptionResponse = try JSONDecoder().decode(EnhancedSubscriptionResponse.self, from: data)
        } catch let decodingError as DecodingError {
            // Detailed error logging
            switch decodingError {
            case .keyNotFound(let key, let context):
                log("[ContentSourceManager] Key not found: \(key.stringValue) in \(context.codingPath)")
            case .typeMismatch(let type, let context):
                log("[ContentSourceManager] Type mismatch: expected \(type) at \(context.codingPath), value: \(context.debugDescription)")
            case .valueNotFound(let type, let context):
                log("[ContentSourceManager] Value not found: expected \(type) at \(context.codingPath)")
            case .dataCorrupted(let context):
                log("[ContentSourceManager] Data corrupted: \(context.debugDescription)")
            @unknown default:
                log("[ContentSourceManager] Unknown decoding error: \(decodingError)")
            }
            throw decodingError
        } catch {
            throw error
        }
        
        var newSources: [ContentSource] = []
        
        // 1. 处理影视源 (type=1 和 type=3)
        let sites = subscriptionResponse.sites
        for rawSite in sites {
            if rawSite.type == 1 {
                // 标准采集源
                if let source = parseStandardSite(rawSite) {
                    newSources.append(source)
                }
            } else if rawSite.type == 3 {
                // 特殊源 (type=3) - 暂时跳过不处理
                // type=3 需要特殊的播放器或插件支持（如 drpy2、XBPQ、Python 脚本等）
                log("[ContentSourceManager] Skipping type=3 source '\(rawSite.name)' - requires special plugin support")
            }
        }
        
        // 2. 处理直播源 (type=0)
        if let lives = subscriptionResponse.lives {
            for liveSource in lives {
                let source = ContentSource(
                    name: liveSource.name,
                    url: liveSource.url,
                    isActive: true,
                    sourceType: .live,
                    liveSource: liveSource
                )
                newSources.append(source)
            }
        }
        
        let newSourcesSnapshot = newSources
        let newLiveSourcesSnapshot = subscriptionResponse.lives ?? []
        
        await MainActor.run {
            _ = self.mergeContentSources(newSourcesSnapshot)
            _ = self.mergeLiveSources(newLiveSourcesSnapshot)
        }
    }

    @discardableResult
    func mergeContentSources(_ importedSources: [ContentSource]) -> SourceMergeResult {
        var result = SourceMergeResult()
        guard !importedSources.isEmpty else { return result }

        var keyToIndex: [String: Int] = [:]
        for (index, source) in sources.enumerated() {
            keyToIndex[sourceDedupKey(source)] = index
        }

        for incoming in importedSources {
            let trimmedName = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedURL = incoming.fullURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty && trimmedURL.isEmpty {
                result.skipped += 1
                continue
            }

            let dedupKey = sourceDedupKey(incoming)
            if let index = keyToIndex[dedupKey], index < sources.count {
                sources[index].name = incoming.name
                sources[index].url = incoming.url
                sources[index].isActive = incoming.isActive
                sources[index].sourceType = incoming.sourceType
                sources[index].liveSource = incoming.liveSource
                if selectedSource?.id == sources[index].id {
                    selectedSource = sources[index]
                }
                result.updated += 1
            } else {
                sources.append(incoming)
                keyToIndex[dedupKey] = sources.count - 1
                result.added += 1
            }
        }

        if result.imported > 0 {
            saveSources()
            if selectedSource == nil {
                selectedSource = sources.first(where: { $0.isActive }) ?? sources.first
            }
            saveSelectedSource()
        }
        return result
    }
    
    // MARK: - Parse Standard Site (type=1)
    private func parseStandardSite(_ rawSite: RawSite) -> ContentSource? {
        guard rawSite.type == 1 else { return nil }
        
        let apiURL = rawSite.api
        guard !apiURL.isEmpty else { return nil }
        
        // 处理 URL，确保包含完整的 API 路径
        let processedURL: String
        if apiURL.contains("api.php") {
            if apiURL.contains("/provide/vod/") {
                processedURL = apiURL
            } else if apiURL.hasSuffix("api.php") {
                processedURL = apiURL + "/provide/vod/"
            } else {
                processedURL = apiURL + "/provide/vod/"
            }
        } else {
            let baseURL = apiURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            processedURL = baseURL + "/api.php/provide/vod/"
        }
        
        let sourceName = rawSite.name.isEmpty ? rawSite.key : rawSite.name
        
        return ContentSource(
            name: sourceName,
            url: processedURL,
            isActive: true,
            sourceType: .vod
        )
    }
    
    // MARK: - Export Sources to JSON
    func exportSources() -> String? {
        guard let data = try? JSONEncoder().encode(sources) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    // MARK: - Validation
    func validateSource(_ source: ContentSource) -> Bool {
        guard !source.name.isEmpty,
              !source.url.isEmpty else {
            return false
        }
        
        guard URL(string: source.fullURL) != nil else {
            return false
        }
        
        return true
    }
    
    // MARK: - Helper Methods
    func getActiveSources() -> [ContentSource] {
        return sources.filter { $0.isActive }
    }
    
    func getSource(by id: UUID) -> ContentSource? {
        return sources.first { $0.id == id }
    }
    
    func isSourceSelected(_ source: ContentSource) -> Bool {
        return selectedSource?.id == source.id
    }
    
    func clearAllSources() {
        // 清除所有影视源
        sources.removeAll()
        selectedSource = nil
        saveSources()
        saveSelectedSource()
        
        // 清除所有直播源
        liveSources.removeAll()
        saveLiveSources()
    }
    
    // MARK: - Helper Methods for Subscription Import
    // Note: Using simplified W-TV logic - only type 1 sources, api as complete URL, name/key as name
    
    // MARK: - Live Sources Management
    func loadLiveSources() {
        if let data = userDefaults.data(forKey: liveSourcesKey),
           let decodedSources = try? JSONDecoder().decode([LiveSource].self, from: data) {
            liveSources = decodedSources
        }
    }
    
    func saveLiveSources() {
        if let encoded = try? JSONEncoder().encode(liveSources) {
            userDefaults.set(encoded, forKey: liveSourcesKey)
        }
    }
    
    func addLiveSource(_ source: LiveSource) {
        let newKey = liveSourceDedupKey(source)
        guard !liveSources.contains(where: { liveSourceDedupKey($0) == newKey }) else {
            return
        }
        liveSources.append(source)
        saveLiveSources()
    }

    @discardableResult
    func mergeLiveSources(_ importedSources: [LiveSource]) -> SourceMergeResult {
        var result = SourceMergeResult()
        guard !importedSources.isEmpty else { return result }

        var keyToIndex: [String: Int] = [:]
        for (index, source) in liveSources.enumerated() {
            keyToIndex[liveSourceDedupKey(source)] = index
        }

        for incoming in importedSources {
            let trimmedName = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedURL = incoming.fullURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty && trimmedURL.isEmpty {
                result.skipped += 1
                continue
            }

            let dedupKey = liveSourceDedupKey(incoming)
            if let index = keyToIndex[dedupKey], index < liveSources.count {
                liveSources[index] = incoming
                result.updated += 1
            } else {
                liveSources.append(incoming)
                keyToIndex[dedupKey] = liveSources.count - 1
                result.added += 1
            }
        }

        if result.imported > 0 {
            saveLiveSources()
        }
        return result
    }
    
    func removeLiveSource(_ source: LiveSource) {
        liveSources.removeAll { $0.id == source.id }
        saveLiveSources()
    }

    private func sourceDedupKey(_ source: ContentSource) -> String {
        let normalizedURL = normalizedURLKey(source.fullURL)
        if normalizedURL == "<empty>" {
            let nameKey = source.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return "\(source.sourceType.rawValue)|name:\(nameKey)"
        }
        return "\(source.sourceType.rawValue)|url:\(normalizedURL)"
    }

    private func liveSourceDedupKey(_ source: LiveSource) -> String {
        let normalizedURL = normalizedURLKey(source.fullURL)
        if normalizedURL == "<empty>" {
            let nameKey = source.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return "live|name:\(nameKey)"
        }
        return "live|url:\(normalizedURL)"
    }

    private func normalizedURLKey(_ rawURL: String) -> String {
        var normalized = rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return "<empty>"
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

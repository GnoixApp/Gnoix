import Foundation

class PlayHistoryManager: ObservableObject {
    static let shared = PlayHistoryManager()
    @Published private(set) var history: [PlayHistoryItem] = []
    private static let verboseLoggingEnabled = false
    private let ioQueue = DispatchQueue(label: "com.wftv.playhistory.io", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?
    private let saveDebounceSeconds: TimeInterval = 0.35
    private let maxHistoryCount = 500

    // 新格式 JSON 文件路径
    private let historyFilePath: String = {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return "\(documentsPath)/wftv_history.json"
    }()

    // 旧格式文本文件路径（迁移使用）
    private let legacyHistoryFilePath: String = {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return "\(documentsPath)/wftv_history.txt"
    }()

    private init() {
        log("[PlayHistoryManager] 历史记录 JSON 文件路径: \(historyFilePath)")
        log("[PlayHistoryManager] 历史记录 Legacy 文件路径: \(legacyHistoryFilePath)")
        loadAsync()
    }

    func add(item: PlayHistoryItem) {
        // 去重：同源 + 同 video.id 只保留最新，避免跨源同 ID 覆盖
        let itemKey = historyIdentity(video: item.video)
        history.removeAll { historyIdentity(video: $0.video) == itemKey }
        history.insert(item, at: 0)
        if history.count > maxHistoryCount {
            history.removeLast(history.count - maxHistoryCount)
        }
        log("[PlayHistoryManager] 添加历史记录: \(item.video.title)，当前总数: \(history.count)")
        scheduleSave()
    }

    func historyItem(for video: Video) -> PlayHistoryItem? {
        let itemKey = historyIdentity(video: video)
        return history.first(where: { historyIdentity(video: $0.video) == itemKey })
    }

    func clear() {
        history.removeAll()
        scheduleSave()
    }

    func remove(atOffsets offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        scheduleSave()
    }
    
    // 强制重置历史记录（用于修复损坏的数据）
    func resetHistory() {
        log("[PlayHistoryManager] 重置历史记录")
        cancelPendingSave()
        removeFileIfExists(atPath: historyFilePath)
        removeFileIfExists(atPath: legacyHistoryFilePath)
        history.removeAll()
    }

    private func removeFileIfExists(atPath path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
            log("[PlayHistoryManager] 历史记录文件已删除: \(path)")
        } catch {
            log("[PlayHistoryManager] 删除历史记录文件失败(\(path)): \(error)")
        }
    }

    private func scheduleSave() {
        let snapshot = history
        pendingSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.persist(snapshot)
        }
        pendingSaveWorkItem = workItem
        ioQueue.asyncAfter(deadline: .now() + saveDebounceSeconds, execute: workItem)
    }

    private func cancelPendingSave() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
    }

    private func persist(_ snapshot: [PlayHistoryItem]) {
        do {
            let records = snapshot.map(StoredHistoryRecord.init(from:))
            let data = try JSONEncoder().encode(records)
            let url = URL(fileURLWithPath: historyFilePath)
            try data.write(to: url, options: .atomic)
            log("[PlayHistoryManager] 保存成功，共 \(snapshot.count) 条记录到文件: \(historyFilePath)")
        } catch {
            log("[PlayHistoryManager] 保存失败: \(error)")
        }
    }

    private func loadAsync() {
        ioQueue.async { [weak self] in
            guard let self else { return }

            if let loaded = self.loadFromJSONFile() {
                DispatchQueue.main.async {
                    self.mergeLoadedHistoryIfNeeded(loaded)
                    self.log("[PlayHistoryManager] 成功加载 JSON 历史记录 \(loaded.count) 条")
                    self.log("[PlayHistoryManager] 初始化完成，历史记录数量: \(self.history.count)")
                }
                return
            }

            if let loadedLegacy = self.loadFromLegacyFile() {
                DispatchQueue.main.async {
                    self.mergeLoadedHistoryIfNeeded(loadedLegacy)
                    self.log("[PlayHistoryManager] 成功加载 Legacy 历史记录 \(loadedLegacy.count) 条")
                    self.log("[PlayHistoryManager] 初始化完成，历史记录数量: \(self.history.count)")
                }
                self.migrateLegacyToJSONIfNeeded(loadedLegacy)
                return
            }

            DispatchQueue.main.async {
                self.log("[PlayHistoryManager] 历史记录文件不存在")
                self.log("[PlayHistoryManager] 初始化完成，历史记录数量: \(self.history.count)")
            }
        }
    }

    private func mergeLoadedHistoryIfNeeded(_ loaded: [PlayHistoryItem]) {
        guard !loaded.isEmpty else { return }

        if history.isEmpty {
            history = loaded
            return
        }

        var merged = history
        var existingKeys = Set(history.map { historyIdentity(video: $0.video) })
        for item in loaded {
            let key = historyIdentity(video: item.video)
            if existingKeys.insert(key).inserted {
                merged.append(item)
            }
        }
        merged.sort { $0.playedAt > $1.playedAt }
        if merged.count > maxHistoryCount {
            merged.removeLast(merged.count - maxHistoryCount)
        }
        history = merged
    }

    private func loadFromJSONFile() -> [PlayHistoryItem]? {
        guard FileManager.default.fileExists(atPath: historyFilePath) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: historyFilePath))
            let records = try JSONDecoder().decode([StoredHistoryRecord].self, from: data)
            return records.map(\.toHistoryItem)
        } catch {
            log("[PlayHistoryManager] JSON 加载失败: \(error)")
            return nil
        }
    }

    private func loadFromLegacyFile() -> [PlayHistoryItem]? {
        guard FileManager.default.fileExists(atPath: legacyHistoryFilePath) else {
            return nil
        }

        do {
            let content = try String(contentsOfFile: legacyHistoryFilePath, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            let loadedHistory = lines.compactMap(parseLegacyLine(_:))
            return loadedHistory
        } catch {
            log("[PlayHistoryManager] Legacy 加载失败: \(error)")
            return nil
        }
    }

    private func parseLegacyLine(_ line: String) -> PlayHistoryItem? {
        let parts = line.components(separatedBy: "|")
        guard parts.count >= 5,
              let videoId = Int(parts[0]),
              let timestamp = Double(parts[4]) else {
            return nil
        }

        let videoTitle = parts[1]
        let videoCover = parts[2].isEmpty ? nil : parts[2]
        let sourceApi = parts[3].isEmpty ? nil : parts[3]
        let playedAt = Date(timeIntervalSince1970: timestamp)

        var video = Video(id: videoId, title: videoTitle, cover: videoCover)
        video.sourceApi = sourceApi

        var lastEpisode: Episode? = nil
        if parts.count >= 7 && !parts[5].isEmpty {
            let episodeTitle = parts[5]
            let episodeUrl = parts[6]
            let episodeNumber = (parts.count >= 8 && !parts[7].isEmpty) ? Int(parts[7]) : nil
            lastEpisode = Episode(title: episodeTitle, playUrl: episodeUrl, episodeNumber: episodeNumber)
        }

        return PlayHistoryItem(
            id: UUID(),
            video: video,
            playedAt: playedAt,
            lastEpisode: lastEpisode,
            lastPlaybackTime: nil,
            duration: nil
        )
    }

    private func migrateLegacyToJSONIfNeeded(_ loadedLegacy: [PlayHistoryItem]) {
        guard !loadedLegacy.isEmpty else { return }

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.persist(loadedLegacy)
            self.removeFileIfExists(atPath: self.legacyHistoryFilePath)
        }
    }

    private func historyIdentity(video: Video) -> String {
        let source = normalizeSourceApi(video.sourceApi)
        return "\(source)#\(video.id)"
    }

    private func normalizeSourceApi(_ source: String?) -> String {
        guard var value = source?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return "<unknown-source>"
        }
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value.lowercased()
    }

    private func log(_ message: @autoclosure () -> String) {
        guard Self.verboseLoggingEnabled else { return }
        print(message())
    }
}

private struct StoredEpisodeRecord: Codable {
    let title: String
    let playUrl: String
    let episodeNumber: Int?

    init(from episode: Episode) {
        self.title = episode.title
        self.playUrl = episode.playUrl
        self.episodeNumber = episode.episodeNumber
    }

    var toEpisode: Episode {
        Episode(title: title, playUrl: playUrl, episodeNumber: episodeNumber)
    }
}

private struct StoredHistoryRecord: Codable {
    let id: UUID
    let videoId: Int
    let videoTitle: String
    let videoCover: String?
    let sourceApi: String?
    let playedAt: Date
    let lastEpisode: StoredEpisodeRecord?
    let lastPlaybackTime: Double?
    let duration: Double?

    init(from item: PlayHistoryItem) {
        self.id = item.id
        self.videoId = item.video.id
        self.videoTitle = item.video.title
        self.videoCover = item.video.cover
        self.sourceApi = item.video.sourceApi
        self.playedAt = item.playedAt
        self.lastEpisode = item.lastEpisode.map(StoredEpisodeRecord.init(from:))
        self.lastPlaybackTime = item.lastPlaybackTime
        self.duration = item.duration
    }

    var toHistoryItem: PlayHistoryItem {
        var video = Video(id: videoId, title: videoTitle, cover: videoCover)
        video.sourceApi = sourceApi
        return PlayHistoryItem(
            id: id,
            video: video,
            playedAt: playedAt,
            lastEpisode: lastEpisode?.toEpisode,
            lastPlaybackTime: lastPlaybackTime,
            duration: duration
        )
    }
}

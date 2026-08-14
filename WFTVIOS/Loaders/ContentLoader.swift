import Foundation
import Combine

// MARK: - Enhanced Content Parser
// ─────────────────────────────────────────────────────────────────────────────
// EnhancedContentParser 完全保留，原逻辑不变，不作任何修改。
// ─────────────────────────────────────────────────────────────────────────────
class EnhancedContentParser {

    static func parseCategoryListResponse(from data: Data) throws -> CategoryListResponse {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(CategoryListResponse.self, from: data)
        } catch {
            if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return try parseCategoriesToResponse(from: jsonObject)
            }
            throw ContentError.parsingError("Failed to parse category response: \(error)")
        }
    }

    static func parseVideoListResponse(from data: Data) throws -> VideoListResponse {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(VideoListResponse.self, from: data)
        } catch {
            if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return try parseVideosToResponse(from: jsonObject)
            }
            throw ContentError.parsingError("Failed to parse video response: \(error)")
        }
    }

    private static func parseCategoriesToResponse(from json: [String: Any]) throws -> CategoryListResponse {
        let code = json["code"] as? Int ?? 0
        let msg = json["msg"] as? String ?? ""
        let page = parseStringOrInt(json["page"])
        let pagecount = parseStringOrInt(json["pagecount"])
        let limit = parseStringOrInt(json["limit"])
        let total = parseStringOrInt(json["total"])

        var categories: [Category] = []
        if let classArray = json["class"] as? [[String: Any]] {
            categories = parseCategories(from: classArray)
        } else if let typeArray = json["type"] as? [[String: Any]] {
            categories = parseCategories(from: typeArray)
        } else if let listArray = json["list"] as? [[String: Any]] {
            categories = parseCategories(from: listArray)
        }

        var videos: [Video] = []
        if let listArray = json["list"] as? [[String: Any]] {
            videos = parseVideos(from: listArray)
        }

        return CategoryListResponse.create(
            code: code, msg: msg, page: page, pagecount: pagecount,
            limit: limit, total: total, list: videos.isEmpty ? nil : videos, categories: categories
        )
    }

    private static func parseVideosToResponse(from json: [String: Any]) throws -> VideoListResponse {
        let code = json["code"] as? Int ?? 0
        let msg = json["msg"] as? String ?? ""
        let page = json["page"] as? Int ?? (Int(json["page"] as? String ?? "1") ?? 1)
        let pagecount = json["pagecount"] as? Int ?? 1
        let limit = json["limit"] as? String ?? "20"
        let total = json["total"] as? Int ?? 0
        var videos: [Video] = []
        if let listArray = json["list"] as? [[String: Any]] {
            videos = parseVideos(from: listArray)
        }
        return VideoListResponse(
            code: code, msg: msg, page: page, pagecount: pagecount,
            limit: limit, total: total, list: videos
        )
    }

    private static func parseCategories(from array: [[String: Any]]) -> [Category] {
        array.compactMap { dict in
            guard let typeId = dict["type_id"] as? Int,
                  let typeName = dict["type_name"] as? String else { return nil }
            let typePid = dict["type_pid"] as? Int
            return Category(name: typeName, typeId: typeId, typePid: typePid)
        }
    }

    private static func parseVideos(from array: [[String: Any]]) -> [Video] {
        array.compactMap { parseVideo(from: $0) }
    }

    static func parseVideo(from dict: [String: Any]) -> Video? {
        guard let vodId = dict["vod_id"] as? Int,
              let vodName = dict["vod_name"] as? String else { return nil }
        var video = Video(id: vodId, title: vodName)
        video.description = dict["vod_content"] as? String ?? dict["vod_blurb"] as? String
        video.cover = dict["vod_pic"] as? String
        video.year = dict["vod_year"] as? String
        video.area = dict["vod_area"] as? String
        video.category = dict["vod_class"] as? String
        video.language = dict["vod_lang"] as? String
        video.score = dict["vod_score"] as? String
        video.director = dict["vod_director"] as? String
        video.actors = dict["vod_actor"] as? String
        video.source = dict["vod_play_from"] as? String
        video.typeId = dict["type_id"] as? Int
        video.typeName = dict["type_name"] as? String
        video.vodEn = dict["vod_en"] as? String
        video.vodTime = dict["vod_time"] as? String
        video.vodRemarks = dict["vod_remarks"] as? String

        if let playUrlString = dict["vod_play_url"] as? String {
            video.playUrl = playUrlString
            video.playSources = parsePlaySources(from: playUrlString, sourceNames: video.source)
            video.playUrls = parsePlayUrls(from: playUrlString)
        }
        return video
    }

    static func parsePlaySources(from playUrlString: String, sourceNames: String?) -> [PlaySource] {
        var playSources: [PlaySource] = []
        let sourceNameArray = sourceNames?.components(separatedBy: "$$$") ?? []
        let sourceUrlArray = playUrlString.components(separatedBy: "$$$")
        for (index, sourceUrls) in sourceUrlArray.enumerated() {
            let sourceName = index < sourceNameArray.count ? sourceNameArray[index] : "播放源\(index + 1)"
            let episodes = parseEpisodesFromSource(sourceUrls, sourceName: sourceName)
            if !episodes.isEmpty {
                playSources.append(PlaySource(name: sourceName, episodes: episodes))
            }
        }
        return playSources
    }

    static func parsePlayUrls(from playUrlString: String) -> [PlayUrl] {
        var playUrls: [PlayUrl] = []
        let firstSource = playUrlString.components(separatedBy: "$$$").first ?? playUrlString
        let episodes = firstSource.components(separatedBy: "#")
        for episode in episodes {
            let trimmed = episode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let dollarIndex = trimmed.firstIndex(of: "$") {
                let quality = String(trimmed[..<dollarIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                var url = String(trimmed[trimmed.index(after: dollarIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    url = processPlayUrl(url, sourceName: "default")
                    playUrls.append(PlayUrl(name: quality, url: url, type: nil))
                }
            } else if trimmed.hasPrefix("http") {
                var url = trimmed
                url = processPlayUrl(url, sourceName: "default")
                playUrls.append(PlayUrl(name: "默认", url: url, type: nil))
            }
        }
        return playUrls
    }

    private static func parseEpisodesFromSource(_ sourceUrls: String, sourceName: String) -> [Episode] {
        var episodes: [Episode] = []
        let episodeStrings = sourceUrls.components(separatedBy: "#")
        for (index, episodeString) in episodeStrings.enumerated() {
            let trimmed = episodeString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let dollarIndex = trimmed.firstIndex(of: "$") {
                let episodeTitle = String(trimmed[..<dollarIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                var episodeUrl = String(trimmed[trimmed.index(after: dollarIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !episodeUrl.isEmpty {
                    episodeUrl = processPlayUrl(episodeUrl, sourceName: sourceName)
                    episodes.append(Episode(title: episodeTitle.isEmpty ? "第\(index + 1)集" : episodeTitle, playUrl: episodeUrl, episodeNumber: index + 1))
                }
            } else if trimmed.hasPrefix("http") {
                var episodeUrl = trimmed
                episodeUrl = processPlayUrl(episodeUrl, sourceName: sourceName)
                episodes.append(Episode(title: "第\(index + 1)集", playUrl: episodeUrl, episodeNumber: index + 1))
            }
        }
        return episodes
    }

    private static func processPlayUrl(_ url: String, sourceName: String) -> String {
        var processedUrl = url
        if sourceName.lowercased().contains("m3u8") {
            if !processedUrl.hasSuffix(".m3u8") && !processedUrl.contains(".m3u8") {
                if processedUrl.contains("/play/") && !processedUrl.contains("index.m3u8") {
                    processedUrl = processedUrl + "/index.m3u8"
                }
            }
        }
        return processedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseStringOrInt(_ value: Any?) -> StringOrInt {
        if let intVal = value as? Int { return .int(intVal) }
        if let strVal = value as? String { return .string(strVal) }
        return .string("0")
    }
}

// MARK: - CategoryListResponse helper
extension CategoryListResponse {
    static func create(code: Int, msg: String, page: StringOrInt, pagecount: StringOrInt,
                       limit: StringOrInt, total: StringOrInt, list: [Video]?, categories: [Category]) -> CategoryListResponse {
        CategoryListResponse(code: code, msg: msg, page: page, pagecount: pagecount,
                             limit: limit, total: total, list: list, categories: categories)
    }
}

// MARK: - Content Loader
// ─────────────────────────────────────────────────────────────────────────────
// 重构目标：
// 1. 泛型 fetch<T> 方法统一所有网络请求（async/await，附带简单重试）
// 2. loadCategories / loadVideos / searchVideos / loadVideoDetail / loadHomeVideos
//    全部改为 async throws，直接调用 fetch
// 3. loadLiveSources / loadEnhancedSubscription 保留 Combine publisher（UI层仍需）
// 4. 清理所有 print 语句
// 5. 移除 executeWithRetry 那套复杂手动 retry 逻辑，改用 Task.detached 简单重试
// ─────────────────────────────────────────────────────────────────────────────
class ContentLoader: ObservableObject {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    // MARK: - Published State (kept for UI compatibility)
    @Published var isLoading = false
    @Published var error: ContentError?
    @Published var networkStatus: NetworkStatus = .uncertain

    private var networkObserver: NSObjectProtocol?

    init() {
        setupNetworkObserver()
    }

    deinit {
        if let observer = networkObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupNetworkObserver() {
        networkObserver = NotificationCenter.default.addObserver(
            forName: .networkStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleNetworkStatusChange()
        }
        handleNetworkStatusChange()
    }

    private func handleNetworkStatusChange() {
        let isConnected = NetworkMonitor.shared.isConnected
        networkStatus = isConnected ? .connected : .disconnected
    }

    private enum LoaderRequestError: Error {
        case httpStatus(Int)
    }

    // MARK: - Generic Fetch (async/await with network retry only)
    private func fetchData(url: URL) async throws -> Data {
        try await withRetry(maxAttempts: 3) {
            let (data, response) = try await Self.session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw LoaderRequestError.httpStatus(httpResponse.statusCode)
            }
            return data
        }
    }

    /// Simple retry wrapper with exponential-ish backoff.
    private func withRetry<T>(_ operation: @escaping () async throws -> T, maxAttempts: Int = 3) async throws -> T {
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                if error is CancellationError {
                    throw error
                }

                let isLastAttempt = attempt == maxAttempts - 1
                if !shouldRetry(error) || isLastAttempt {
                    throw error
                }

                let delay = UInt64(pow(1.5, Double(attempt)) * 500_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw ContentError.networkError("Unknown")
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if error is DecodingError {
            return false
        }

        if let requestError = error as? LoaderRequestError {
            switch requestError {
            case .httpStatus(let code):
                return code == 408 || code == 429 || (500...599).contains(code)
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }

        return false
    }

    // MARK: - Map Error Helper
    private func mapURLError(_ error: Error) -> ContentError {
        if let requestError = error as? LoaderRequestError {
            switch requestError {
            case .httpStatus(let code):
                return ContentError.networkError("HTTP 请求失败（状态码 \(code)）")
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return ContentError.networkError("请求超时，请重试或更换内容源")
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost:
                return ContentError.networkError("网络不可用或内容源无效")
            default:
                return ContentError.networkError(urlError.localizedDescription)
            }
        }
        return ContentError.networkError(error.localizedDescription)
    }

    // MARK: - Public API: Async Methods

    /// 加载分类列表
    func loadCategories(from source: ContentSource) async throws -> [Category] {
        let urlString = "\(source.fullURL)?ac=list"
        guard let url = URL(string: urlString) else {
            throw ContentError.invalidURL(urlString)
        }
        do {
            let data = try await fetchData(url: url)
            let response: CategoryListResponse
            do {
                response = try JSONDecoder().decode(CategoryListResponse.self, from: data)
            } catch is DecodingError {
                response = try EnhancedContentParser.parseCategoryListResponse(from: data)
            }
            guard response.code == 1 else {
                throw ContentError.noData(response.msg)
            }
            return response.categories
        } catch let error as ContentError {
            throw error
        } catch {
            throw mapURLError(error)
        }
    }

    /// 加载分类下视频列表
    func loadVideos(from source: ContentSource, category: Category, page: Int = 1) async throws -> VideoListResponse {
        var components = URLComponents(string: source.fullURL)
        components?.queryItems = [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "t", value: String(category.typeId)),
            URLQueryItem(name: "pg", value: String(page))
        ]
        guard let url = components?.url else {
            throw ContentError.invalidURL(source.fullURL)
        }
        return try await loadVideoList(url: url, source: source)
    }

    /// 搜索视频
    func searchVideos(from source: ContentSource, keyword: String, page: Int = 1) async throws -> VideoListResponse {
        var components = URLComponents(string: source.fullURL)
        components?.queryItems = [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "wd", value: keyword),
            URLQueryItem(name: "pg", value: String(page))
        ]
        guard let url = components?.url else {
            throw ContentError.invalidURL(source.fullURL)
        }
        return try await loadVideoList(url: url, source: source)
    }

    /// 加载视频详情
    func loadVideoDetail(from source: ContentSource, videoId: String) async throws -> Video {
        var components = URLComponents(string: source.fullURL)
        components?.queryItems = [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "ids", value: videoId)
        ]
        guard let url = components?.url else {
            throw ContentError.invalidURL(source.fullURL)
        }
        do {
            let data = try await fetchData(url: url)
            let response: VideoListResponse
            do {
                response = try JSONDecoder().decode(VideoListResponse.self, from: data)
            } catch is DecodingError {
                response = try EnhancedContentParser.parseVideoListResponse(from: data)
            }
            guard response.code == 1 else {
                throw ContentError.noData(response.msg)
            }
            guard let video = response.list.first else {
                throw ContentError.noData("未找到该视频")
            }
            var updated = video
            updated.sourceApi = source.fullURL
            return updated
        } catch let error as ContentError {
            throw error
        } catch {
            throw mapURLError(error)
        }
    }

    /// 加载首页视频
    func loadHomeVideos(from source: ContentSource, page: Int = 1) async throws -> VideoListResponse {
        var components = URLComponents(string: source.fullURL)
        components?.queryItems = [
            URLQueryItem(name: "ac", value: "list"),
            URLQueryItem(name: "pg", value: String(page))
        ]
        guard let url = components?.url else {
            throw ContentError.invalidURL(source.fullURL)
        }
        do {
            let data = try await fetchData(url: url)
            let response: VideoListResponse
            do {
                response = try JSONDecoder().decode(VideoListResponse.self, from: data)
            } catch is DecodingError {
                response = try EnhancedContentParser.parseVideoListResponse(from: data)
            }
            guard response.code == 1 else {
                throw ContentError.noData(response.msg)
            }
            return response
        } catch let error as ContentError {
            throw error
        } catch {
            throw mapURLError(error)
        }
    }

    // MARK: - Private Shared Helper
    private func loadVideoList(url: URL, source: ContentSource) async throws -> VideoListResponse {
        do {
            let data = try await fetchData(url: url)
            let response: VideoListResponse
            do {
                response = try JSONDecoder().decode(VideoListResponse.self, from: data)
            } catch is DecodingError {
                response = try EnhancedContentParser.parseVideoListResponse(from: data)
            }
            guard response.code == 1 else {
                throw ContentError.noData(response.msg)
            }
            return injectSourceApi(into: response, source: source)
        } catch let error as ContentError {
            throw error
        } catch {
            throw mapURLError(error)
        }
    }

    private func injectSourceApi(into response: VideoListResponse, source: ContentSource) -> VideoListResponse {
        var updated = response
        updated.list = response.list.map { video in
            var v = video
            v.sourceApi = source.fullURL
            return v
        }
        return updated
    }

    // MARK: - Combine Publishers (kept for UI compatibility)

    func loadLiveSources(from sources: [LiveSource]) -> AnyPublisher<[LiveChannel], ContentError> {
        guard !sources.isEmpty else {
            return Just([]).setFailureType(to: ContentError.self).eraseToAnyPublisher()
        }

        var publishers: [AnyPublisher<[LiveChannel], ContentError>] = []
        for source in sources where source.isEnabled {
            guard let url = URL(string: source.url) else { continue }

            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: TimeInterval(source.timeout ?? 20))
            request.setValue(source.ua ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")

            let publisher = Self.session.dataTaskPublisher(for: request)
                .map(\.data)
                .tryMap { data -> [LiveChannel] in
                    guard let content = self.decodeLiveText(data: data) else {
                        throw ContentError.parsingError("无法解码直播源内容")
                    }
                    return self.parseLiveContent(content, sourceName: source.name)
                }
                .catch { _ in Just([]).setFailureType(to: ContentError.self) }
                .eraseToAnyPublisher()

            publishers.append(publisher)
        }

        return Publishers.MergeMany(publishers)
            .collect()
            .map { channelsArray in
                let merged = channelsArray.flatMap { $0 }
                var seen = Set<String>()
                return merged.filter { channel in
                    let key = channel.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !seen.contains(key) else { return false }
                    seen.insert(key)
                    return true
                }
            }
            .eraseToAnyPublisher()
    }

    func loadEnhancedSubscription(from source: ContentSource) -> AnyPublisher<EnhancedSubscriptionResponse, ContentError> {
        let urlString = "\(source.fullURL)?ac=list"
        guard let url = URL(string: urlString) else {
            return Fail(error: ContentError.invalidURL(urlString)).eraseToAnyPublisher()
        }
        return Self.session.dataTaskPublisher(for: url)
            .map(\.data)
            .decode(type: EnhancedSubscriptionResponse.self, decoder: JSONDecoder())
            .mapError { error in
                if let urlError = error as? URLError {
                    return ContentError.networkError(urlError.localizedDescription)
                }
                if let decodingError = error as? DecodingError {
                    return ContentError.parsingError("Failed to parse subscription: \(decodingError)")
                }
                return ContentError.networkError(error.localizedDescription)
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Live Source Parsing

    private func decodeLiveText(data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8, .unicode, .utf16LittleEndian, .utf16BigEndian,
            String.Encoding(rawValue: 0x80000632), // GB18030
            String.Encoding(rawValue: 0x620),       // GB2312
            String.Encoding(rawValue: 0x4)           // big5
        ]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text.replacingOccurrences(of: "\u{FEFF}", with: "")
            }
        }
        return nil
    }

    private func parseLiveContent(_ content: String, sourceName: String) -> [LiveChannel] {
        if content.contains("#EXTM3U") || content.contains("#EXTINF") {
            return parseM3UContent(content, sourceName: sourceName)
        }
        return parseTxtLiveContent(content, sourceName: sourceName)
    }

    private func parseM3UContent(_ content: String, sourceName: String) -> [LiveChannel] {
        var channels: [LiveChannel] = []
        var currentInfo: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXTINF:") {
                currentInfo = [:]
                let infoString = String(trimmed.dropFirst(8))
                let parts = infoString.components(separatedBy: ",")
                if parts.count > 1 {
                    currentInfo["channelName"] = parts[1].trimmingCharacters(in: .whitespaces).isEmpty
                        ? "未知频道" : parts[1].trimmingCharacters(in: .whitespaces)
                }
                if let range = infoString.range(of: "tvg-name=\"", options: .caseInsensitive),
                   let end = infoString[range.upperBound...].range(of: "\"") {
                    currentInfo["tvgName"] = String(infoString[range.upperBound..<end.lowerBound])
                }
                if let range = infoString.range(of: "tvg-logo=\"", options: .caseInsensitive),
                   let end = infoString[range.upperBound...].range(of: "\"") {
                    currentInfo["logo"] = String(infoString[range.upperBound..<end.lowerBound])
                }
                if let range = infoString.range(of: "group-title=\"", options: .caseInsensitive),
                   let end = infoString[range.upperBound...].range(of: "\"") {
                    currentInfo["group"] = String(infoString[range.upperBound..<end.lowerBound])
                }
            } else if trimmed.hasPrefix("http") || trimmed.hasPrefix("rtmp") || trimmed.hasPrefix("rtsp") {
                channels.append(LiveChannel(
                    id: UUID().uuidString,
                    name: currentInfo["channelName"] ?? currentInfo["tvgName"] ?? "未知频道",
                    url: trimmed, logo: currentInfo["logo"],
                    group: currentInfo["group"], sourceName: sourceName
                ))
            }
        }
        return channels
    }

    private func parseTxtLiveContent(_ content: String, sourceName: String) -> [LiveChannel] {
        var channels: [LiveChannel] = []
        var currentGroup = "其他"
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") && !line.lowercased().contains("#genre#") { continue }
            if line.lowercased().contains("#genre#") {
                currentGroup = line.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "其他"
                continue
            }
            guard let commaIndex = line.firstIndex(of: ",") else { continue }
            let name = String(line[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = String(line[line.index(after: commaIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, isLikelyLiveURL(url) else { continue }
            channels.append(LiveChannel(name: name, url: url, logo: nil, group: currentGroup, sourceName: sourceName))
        }
        return channels
    }

    private func isLikelyLiveURL(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("rtmp://") || lowered.hasPrefix("rtsp://")
    }

    // MARK: - Helpers
    func clearError() { error = nil }
    func setLoading(_ loading: Bool) { isLoading = loading }
}

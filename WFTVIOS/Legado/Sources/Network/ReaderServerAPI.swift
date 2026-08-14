import Foundation
import UIKit

private let verboseReaderServerLoggingEnabled = false

@inline(__always)
private func readerServerLog(_ message: @autoclosure () -> String) {
    guard verboseReaderServerLoggingEnabled else { return }
    Swift.print(message())
}

class ReaderServerAPI {
    static let shared = ReaderServerAPI()
    private let localAPI = LocalReaderAPI.shared
    private let sourceDiagnosticStorageKey = "source_failure_diagnostics_v1"
    private let maxSourceDiagnosticRecords = 300

    private enum SecureKey {
        static let token = "server_token"
        static let username = "server_username"
        static let password = "server_password"
        static let session = "server_session"
    }

    private init() {
        migrateLegacyCredentials()
    }
    
    private var baseUrl: String {
        get { UserDefaults.standard.string(forKey: "server_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "server_url") }
    }
    
    private var token: String {
        get {
            return SecureStore.value(for: SecureKey.token)
                ?? UserDefaults.standard.string(forKey: SecureKey.token)
                ?? ""
        }
        set {
            SecureStore.set(newValue, for: SecureKey.token)
            UserDefaults.standard.removeObject(forKey: SecureKey.token)
        }
    }
    
    private var username: String {
        get {
            return SecureStore.value(for: SecureKey.username)
                ?? UserDefaults.standard.string(forKey: SecureKey.username)
                ?? ""
        }
        set {
            SecureStore.set(newValue, for: SecureKey.username)
            UserDefaults.standard.removeObject(forKey: SecureKey.username)
        }
    }
    
    private var password: String {
        get {
            return SecureStore.value(for: SecureKey.password)
                ?? UserDefaults.standard.string(forKey: SecureKey.password)
                ?? ""
        }
        set {
            SecureStore.set(newValue, for: SecureKey.password)
            UserDefaults.standard.removeObject(forKey: SecureKey.password)
        }
    }
    
    private var sessionCookie: String? {
        get {
            if let value = SecureStore.value(for: SecureKey.session) {
                return value
            }
            return UserDefaults.standard.string(forKey: SecureKey.session)
        }
        set {
            SecureStore.set(newValue, for: SecureKey.session)
            UserDefaults.standard.removeObject(forKey: SecureKey.session)
        }
    }
    
    private var hasSuccessfullyLoggedIn: Bool {
        get { UserDefaults.standard.bool(forKey: "server_logged_in") }
        set { UserDefaults.standard.set(newValue, forKey: "server_logged_in") }
    }
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    
    var isConfigured: Bool {
        if !BookParseManager.shared.isServerMode {
            return true
        }
        return !baseUrl.isEmpty
    }

    var configuredServerURL: String {
        return baseUrl
    }

    var configuredUsername: String {
        return username
    }

    var configuredPassword: String {
        return password
    }

    var isLoggedIn: Bool {
        if !BookParseManager.shared.isServerMode {
            return true
        }
        return !token.isEmpty || sessionCookie != nil || hasSuccessfullyLoggedIn
    }
    
    func configure(url: String, token: String = "") {
        var cleanUrl = url.hasSuffix("/") ? String(url.dropLast()) : url
        if cleanUrl.hasSuffix("/reader3") {
            cleanUrl = String(cleanUrl.dropLast(8))
        }
        if !cleanUrl.hasPrefix("http://") && !cleanUrl.hasPrefix("https://") {
            cleanUrl = "https://" + cleanUrl
        }
        self.baseUrl = cleanUrl
        self.token = token
    }
    
    func configure(url: String, username: String, password: String) {
        var cleanUrl = url.hasSuffix("/") ? String(url.dropLast()) : url
        if cleanUrl.hasSuffix("/reader3") {
            cleanUrl = String(cleanUrl.dropLast(8))
        }
        if !cleanUrl.hasPrefix("http://") && !cleanUrl.hasPrefix("https://") {
            cleanUrl = "https://" + cleanUrl
        }
        self.baseUrl = cleanUrl
        self.username = username
        self.password = password
        self.token = ""
        self.sessionCookie = nil
    }
    
    func logout() {
        self.token = ""
    }

    private func migrateLegacyCredentials() {
        migrateLegacyValue(for: SecureKey.token)
        migrateLegacyValue(for: SecureKey.username)
        migrateLegacyValue(for: SecureKey.password)
        migrateLegacyValue(for: SecureKey.session)
    }

    private func migrateLegacyValue(for key: String) {
        guard SecureStore.value(for: key) == nil else { return }
        guard let legacyValue = UserDefaults.standard.string(forKey: key), !legacyValue.isEmpty else { return }
        SecureStore.set(legacyValue, for: key)
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    private func getAPIUrl() -> String {
        if baseUrl.contains("/reader3") {
            return baseUrl
        }
        var url = baseUrl
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }
        return "\(url)/reader3"
    }
    
    func getAssetUrl(_ path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        var base = baseUrl
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://" + base
        }
        if base.hasSuffix("/reader3") {
            base = String(base.dropLast(8))
        }
        if path.hasPrefix("/") {
            return base + path
        }
        return base + "/" + path
    }
    
    private func normalizeSourceUrl(_ sourceUrl: String) -> String {
        var url = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") {
            url = String(url.dropLast())
        }
        if let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return encoded
        }
        return url
    }

    private func firstNonEmptyString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
                continue
            }
            if let value = dict[key] as? NSNumber {
                let text = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseBookSourceUrl(from dict: [String: Any], fallback: String? = nil) -> String? {
        if let resolved = firstNonEmptyString(in: dict, keys: ["origin", "bookSourceUrl", "sourceUrl", "bookSource", "source", "sourceURL"]) {
            return resolved
        }
        return normalizedOptionalString(fallback)
    }

    private func parseBookOriginName(from dict: [String: Any]) -> String? {
        firstNonEmptyString(in: dict, keys: ["originName", "bookSourceName", "sourceName"])
    }

    private func parseBookTocUrl(from dict: [String: Any]) -> String? {
        firstNonEmptyString(in: dict, keys: ["tocUrl", "tocURL", "chapterUrl", "catalogUrl"])
    }

    func getSourceDiagnostics() -> [SourceDiagnosticRecord] {
        guard let data = UserDefaults.standard.data(forKey: sourceDiagnosticStorageKey),
              let records = try? JSONDecoder().decode([SourceDiagnosticRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.lastFailedAt > $1.lastFailedAt }
    }

    func clearSourceDiagnostics() {
        UserDefaults.standard.removeObject(forKey: sourceDiagnosticStorageKey)
    }

    private func recordSourceFailure(
        endpoint: String,
        sourceUrl: String,
        bookUrl: String,
        chapterUrl: String? = nil,
        reason: String,
        error: Error? = nil,
        requestBody: [String: Any]? = nil,
        responsePreview: String? = nil
    ) {
        let normalizedSource = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBook = bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty || !normalizedBook.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        var records = getSourceDiagnostics()
        let key = [
            endpoint,
            normalizedSource,
            normalizedBook,
            chapterUrl ?? "",
            reason
        ].joined(separator: "|")

        let requestBodyPreview = jsonStringPreview(from: requestBody)
        let cleanedResponsePreview = clipped(responsePreview)
        let errorSummary = error.map { clipped(String(describing: $0)) ?? String(describing: $0) }

        if let index = records.firstIndex(where: { $0.key == key }) {
            var existing = records[index]
            existing.failureCount += 1
            existing.lastFailedAt = now
            existing.lastError = errorSummary ?? existing.lastError
            existing.requestBodyPreview = requestBodyPreview ?? existing.requestBodyPreview
            existing.responsePreview = cleanedResponsePreview ?? existing.responsePreview
            records[index] = existing
        } else {
            let record = SourceDiagnosticRecord(
                key: key,
                endpoint: endpoint,
                sourceUrl: normalizedSource,
                bookUrl: normalizedBook,
                chapterUrl: chapterUrl,
                reason: reason,
                failureCount: 1,
                firstFailedAt: now,
                lastFailedAt: now,
                lastError: errorSummary,
                requestBodyPreview: requestBodyPreview,
                responsePreview: cleanedResponsePreview
            )
            records.append(record)
        }

        records.sort { $0.lastFailedAt > $1.lastFailedAt }
        if records.count > maxSourceDiagnosticRecords {
            records = Array(records.prefix(maxSourceDiagnosticRecords))
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: sourceDiagnosticStorageKey)
        }
    }

    private func jsonStringPreview(from object: [String: Any]?) -> String? {
        guard let object else { return nil }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return clipped(raw)
    }

    private func clipped(_ value: String?, maxLength: Int = 600) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxLength {
            return trimmed
        }
        return String(trimmed.prefix(maxLength))
    }
    
    private func request(endpoint: String, method: String = "GET", body: [String: Any]? = nil, retryCount: Int = 0) async throws -> Data {
        let apiUrl = getAPIUrl()
        
        var urlString = "\(apiUrl)\(endpoint)"
        if !token.isEmpty {
            urlString += urlString.contains("?") ? "&accessToken=\(token)" : "?accessToken=\(token)"
        }
        
        guard let url = URL(string: urlString) else {
            throw ServerError.invalidURL
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let body = body {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await session.data(for: urlRequest)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                if !username.isEmpty && !password.isEmpty && retryCount == 0 {
                    try await reauthenticate()
                    return try await request(endpoint: endpoint, method: method, body: body, retryCount: retryCount + 1)
                }
                throw ServerError.unauthorized
            }
            
            if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
                if let str = String(data: data, encoding: .utf8),
                   str.contains("NEED_LOGIN") || str.contains("请登录") {
                    if !username.isEmpty && !password.isEmpty && retryCount == 0 {
                        try await reauthenticate()
                        return try await request(endpoint: endpoint, method: method, body: body, retryCount: retryCount + 1)
                    }
                }
                throw ServerError.httpError(statusCode: httpResponse.statusCode)
            }
        }
        
        return data
    }
    
    // MARK: - Auth
    
    func login(username: String, password: String) async throws -> LoginResponse {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.login(username: username, password: password)
        }
        self.username = username
        self.password = password
        self.token = ""
        
        let loginData = try await request(endpoint: "/login", method: "POST", body: [
            "username": username,
            "password": password,
            "isLogin": true
        ])
        
        if let json = try? JSONSerialization.jsonObject(with: loginData) as? [String: Any] {
            if let data = json["data"] as? [String: Any],
               let accessToken = data["accessToken"] as? String, !accessToken.isEmpty {
                self.token = accessToken
                hasSuccessfullyLoggedIn = true
                readerServerLog("Login succeeded and token stored")
            }
            
            return LoginResponse(
                ok: json["isSuccess"] as? Bool,
                token: (json["data"] as? [String: Any])?["accessToken"] as? String,
                msg: nil,
                isSuccess: json["isSuccess"] as? Bool,
                errorMsg: json["errorMsg"] as? String
            )
        }
        
        return try JSONDecoder().decode(LoginResponse.self, from: loginData)
    }
    
    func reauthenticate() async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.reauthenticate()
            return
        }
        guard !username.isEmpty && !password.isEmpty else { return }
        self.token = ""
        _ = try await login(username: username, password: password)
    }
    
    func getUserInfo() async throws -> UserInfo {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getUserInfo()
        }
        let data = try await request(endpoint: "/getUserInfo")
        
        if let str = String(data: data, encoding: .utf8), str.isEmpty || str == "null" {
            throw ServerError.decodingError
        }
        
        if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let userData = result["data"] as? [String: Any],
               let username = userData["username"] as? String ?? userData["userName"] as? String ?? userData["nickName"] as? String {
                return UserInfo(username: username, nickName: userData["nickName"] as? String, userName: userData["userName"] as? String, nickname: userData["nickname"] as? String)
            }
            if result["isSuccess"] as? Bool == true {
                return UserInfo(username: "已登录用户", nickName: nil, userName: nil, nickname: nil)
            }
        }
        
        throw ServerError.decodingError
    }
    
    // MARK: - Book Source
    
    func getBookSources() async throws -> [BookSourceResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getBookSources()
        }
        let data = try await request(endpoint: "/getBookSources")
        
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("getBookSources response: \(str.prefix(500))")
        }
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = result["data"] as? [[String: Any]] else {
            return []
        }
        
        for source in sources {
            if let url = source["bookSourceUrl"] as? String {
                readerServerLog("Server has book source: \(url)")
            }
        }
        
        return sources.compactMap { dict -> BookSourceResponse? in
            guard let bookSourceUrl = dict["bookSourceUrl"] as? String,
                  let bookSourceName = dict["bookSourceName"] as? String else { return nil }
            return BookSourceResponse(
                bookSourceUrl: bookSourceUrl,
                bookSourceName: bookSourceName,
                bookSourceGroup: dict["bookSourceGroup"] as? String,
                enabled: dict["enabled"] as? Bool ?? true,
                exploreUrl: dict["exploreUrl"] as? String,
                searchUrl: dict["searchUrl"] as? String,
                header: dict["header"] as? String,
                ruleSearch: dict["ruleSearch"] as? String,
                ruleExplore: dict["ruleExplore"] as? String,
                ruleBookInfo: dict["ruleBookInfo"] as? String,
                ruleToc: dict["ruleToc"] as? String,
                ruleContent: dict["ruleContent"] as? String
            )
        }
    }
    
    func saveBookSource(_ source: BookSourceResponse) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.saveBookSource(source)
            return
        }
        var dict: [String: Any] = [
            "bookSourceUrl": source.bookSourceUrl,
            "bookSourceName": source.bookSourceName,
            "enabled": source.enabled
        ]
        if let group = source.bookSourceGroup { dict["bookSourceGroup"] = group }
        if let explore = source.exploreUrl { dict["exploreUrl"] = explore }
        if let search = source.searchUrl { dict["searchUrl"] = search }
        if let header = source.header { dict["header"] = header }
        if let ruleSearch = source.ruleSearch { dict["ruleSearch"] = ruleSearch }
        if let ruleExplore = source.ruleExplore { dict["ruleExplore"] = ruleExplore }
        if let ruleBookInfo = source.ruleBookInfo { dict["ruleBookInfo"] = ruleBookInfo }
        if let ruleToc = source.ruleToc { dict["ruleToc"] = ruleToc }
        if let ruleContent = source.ruleContent { dict["ruleContent"] = ruleContent }
        
        _ = try await request(endpoint: "/saveBookSource", method: "POST", body: dict)
    }
    
    func deleteBookSource(sourceUrl: String) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.deleteBookSource(sourceUrl: sourceUrl)
            return
        }
        _ = try await request(endpoint: "/deleteBookSource", method: "POST", body: ["bookSourceUrl": sourceUrl])
    }
    
    // MARK: - Search
    
    func search(keyword: String, page: Int = 1, bookSourceUrl: String? = nil) async throws -> [BookInfoResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.search(keyword: keyword, page: page, bookSourceUrl: bookSourceUrl)
        }
        var body: [String: Any] = ["key": keyword]
        if let sourceUrl = bookSourceUrl {
            body["bookSourceUrl"] = sourceUrl
        }
        
        let data = try await request(endpoint: "/searchBook", method: "POST", body: body)
        
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("searchBook response: \(str.prefix(500))")
        }
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let books = result["data"] as? [[String: Any]] else {
            return []
        }
        
        readerServerLog("Found \(books.count) books from search")
        if let firstBook = books.first {
            readerServerLog("First book keys: \(firstBook.keys.joined(separator: ", "))")
            if let origin = firstBook["origin"] as? String {
                readerServerLog("First book origin: \(origin)")
            }
        }
        
        return parseBookList(books)
    }
    
    func searchMulti(keyword: String, bookSourceGroup: String? = nil, concurrentCount: Int = 18, lastIndex: Int = -1) async throws -> (list: [BookInfoResponse], lastIndex: Int) {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.searchMulti(keyword: keyword, bookSourceGroup: bookSourceGroup, concurrentCount: concurrentCount, lastIndex: lastIndex)
        }
        var body: [String: Any] = [
            "key": keyword,
            "concurrentCount": concurrentCount,
            "lastIndex": lastIndex
        ]
        if let group = bookSourceGroup {
            body["bookSourceGroup"] = group
        }
        
        let data = try await request(endpoint: "/searchBookMulti", method: "POST", body: body)
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseData = result["data"] as? [String: Any] else {
            return ([], -1)
        }
        
        let newLastIndex = responseData["lastIndex"] as? Int ?? -1
        let books = responseData["list"] as? [[String: Any]] ?? []
        
        return (parseBookList(books), newLastIndex)
    }
    
    private func parseBookList(_ books: [[String: Any]]) -> [BookInfoResponse] {
        return books.compactMap { dict -> BookInfoResponse? in
            guard let name = dict["bookName"] as? String ?? dict["name"] as? String,
                  let bookUrl = dict["bookUrl"] as? String ?? dict["url"] as? String else { return nil }
            
            var coverUrl = dict["coverUrl"] as? String
            if let cover = coverUrl, !cover.isEmpty {
                coverUrl = getAssetUrl(cover)
            }
            
            var response = BookInfoResponse(
                name: name,
                author: dict["author"] as? String ?? "",
                bookUrl: bookUrl,
                sourceUrl: parseBookSourceUrl(from: dict),
                coverUrl: coverUrl,
                intro: dict["intro"] as? String,
                kind: dict["kind"] as? String,
                latestChapter: dict["latestChapterTitle"] as? String,
                tocUrl: parseBookTocUrl(from: dict),
                wordCount: dict["wordCount"] as? String,
                chapterCount: dict["totalChapterNum"] as? Int,
                type: dict["type"] as? Int ?? 0,
                durChapterIndex: dict["durChapterIndex"] as? Int ?? 0,
                durChapterPos: dict["durChapterPos"] as? Int ?? 0,
                durChapterTime: dict["durChapterTime"] as? Int64 ?? 0,
                totalChapterNum: dict["totalChapterNum"] as? Int ?? 0
            )
            response.originName = parseBookOriginName(from: dict)
            return response
        }
    }
    
    // MARK: - Book Info
    
    func getBookInfo(bookUrl: String, sourceUrl: String) async throws -> BookInfoResponse {
        let requestSourceUrl = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSourceUrl = normalizeSourceUrl(sourceUrl)

        if !BookParseManager.shared.isServerMode {
            do {
                return try await localAPI.getBookInfo(bookUrl: bookUrl, sourceUrl: sourceUrl)
            } catch {
                recordSourceFailure(
                    endpoint: "/getBookInfo_local",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    reason: "request_failed_local",
                    error: error,
                    requestBody: [
                        "url": bookUrl,
                        "bookUrl": bookUrl,
                        "bookSourceUrl": requestSourceUrl
                    ]
                )
                throw error
            }
        }
        readerServerLog("getBookInfo called with bookUrl: \(bookUrl), sourceUrl: \(sourceUrl)")
        
        var body: [String: Any] = [
            "url": bookUrl,
            "bookUrl": bookUrl
        ]
        if !requestSourceUrl.isEmpty {
            body["bookSourceUrl"] = requestSourceUrl
            body["sourceUrl"] = requestSourceUrl
        }
        
        var responsePreview: String?
        do {
            let data = try await request(endpoint: "/getBookInfo", method: "POST", body: body)
            if let str = String(data: data, encoding: .utf8) {
                responsePreview = String(str.prefix(200))
                readerServerLog("getBookInfo response: \(str.prefix(200))")
            }
            
            guard let resultAny = try? JSONSerialization.jsonObject(with: data) else {
                recordSourceFailure(
                    endpoint: "/getBookInfo",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    reason: "decode_failed",
                    requestBody: body,
                    responsePreview: responsePreview
                )
                throw ServerError.decodingError
            }

            let book: [String: Any]?
            if let result = resultAny as? [String: Any] {
                if let dataBook = result["data"] as? [String: Any] {
                    book = dataBook
                } else if let innerBook = result["book"] as? [String: Any] {
                    book = innerBook
                } else {
                    book = result
                }
            } else if let list = resultAny as? [[String: Any]] {
                book = list.first
            } else {
                book = nil
            }

            guard let book else {
                recordSourceFailure(
                    endpoint: "/getBookInfo",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    reason: "decode_failed",
                    requestBody: body,
                    responsePreview: responsePreview
                )
                throw ServerError.decodingError
            }
            return BookInfoResponse(
                name: book["bookName"] as? String ?? "",
                author: book["author"] as? String ?? "",
                bookUrl: book["bookUrl"] as? String ?? bookUrl,
                sourceUrl: parseBookSourceUrl(from: book, fallback: sourceUrl),
                coverUrl: book["coverUrl"] as? String,
                intro: book["intro"] as? String,
                kind: book["kind"] as? String,
                latestChapter: book["latestChapterTitle"] as? String,
                tocUrl: parseBookTocUrl(from: book),
                wordCount: book["wordCount"] as? String,
                chapterCount: book["totalChapterNum"] as? Int,
                type: book["type"] as? Int ?? 0,
                durChapterIndex: book["durChapterIndex"] as? Int ?? 0,
                durChapterPos: book["durChapterPos"] as? Int ?? 0,
                durChapterTime: book["durChapterTime"] as? Int64 ?? 0,
                totalChapterNum: book["totalChapterNum"] as? Int ?? 0
            )
        } catch {
            recordSourceFailure(
                endpoint: "/getBookInfo",
                sourceUrl: cleanSourceUrl,
                bookUrl: bookUrl,
                reason: "request_failed",
                error: error,
                requestBody: body,
                responsePreview: responsePreview
            )
            throw error
        }
    }
    
    // MARK: - TOC
    
    func getChapterList(
        bookUrl: String,
        sourceUrl: String,
        bookNameHint: String? = nil,
        authorHint: String? = nil
    ) async throws -> [ChapterResponse] {
        let cleanSourceUrl = normalizeSourceUrl(sourceUrl)
        if !BookParseManager.shared.isServerMode {
            do {
                return try await localAPI.getChapterList(
                    bookUrl: bookUrl,
                    sourceUrl: sourceUrl,
                    bookNameHint: bookNameHint,
                    authorHint: authorHint
                )
            } catch {
                recordSourceFailure(
                    endpoint: "/getChapterList_local",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    reason: "request_failed_local",
                    error: error,
                    requestBody: [
                        "url": bookUrl,
                        "bookSourceUrl": sourceUrl
                    ]
                )
                throw error
            }
        }
        readerServerLog("========================================")
        readerServerLog("【获取小说目录请求】")
        readerServerLog("========================================")
        readerServerLog("请求地址: /getChapterList")
        readerServerLog("请求方法: POST")
        readerServerLog("请求头: Content-Type: application/json")
        
        var requestBody: [String: Any] = [
            "url": bookUrl
        ]
        if !sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestBody["bookSourceUrl"] = sourceUrl
        }
        
        readerServerLog("--- 请求主体参数 (Request Body) ---")
        if let jsonData = try? JSONSerialization.data(withJSONObject: requestBody, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            readerServerLog(jsonString)
        }
        readerServerLog("-----------------------------------")
        
        var lastResponsePreview: String?

        func requestChapterList(refresh: Int) async throws -> [[String: Any]] {
            var body = requestBody
            if refresh > 0 {
                body["refresh"] = refresh
            }
            let data = try await request(endpoint: "/getChapterList", method: "POST", body: body)
            readerServerLog("--- 响应数据 (Response) ---")
            if let str = String(data: data, encoding: .utf8) {
                lastResponsePreview = String(str.prefix(500))
                readerServerLog("Response: \(str.prefix(500))")
            }
            readerServerLog("-----------------------------------")

            guard let resultAny = try? JSONSerialization.jsonObject(with: data) else {
                recordSourceFailure(
                    endpoint: "/getChapterList",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    reason: "decode_failed_refresh_\(refresh)",
                    requestBody: body,
                    responsePreview: lastResponsePreview
                )
                return []
            }

            if let result = resultAny as? [String: Any] {
                let isSuccess = result["isSuccess"] as? Bool ?? true
                guard isSuccess else {
                    recordSourceFailure(
                        endpoint: "/getChapterList",
                        sourceUrl: cleanSourceUrl,
                        bookUrl: bookUrl,
                        reason: "api_failed_refresh_\(refresh)",
                        requestBody: body,
                        responsePreview: lastResponsePreview
                    )
                    return []
                }
                if let directData = result["data"] as? [[String: Any]] {
                    return directData
                }
                if let genericList = result["data"] as? [Any] {
                    return genericList.compactMap { $0 as? [String: Any] }
                }
                let directChapterFields = result["title"] != nil || result["chapterName"] != nil
                if directChapterFields {
                    return [result]
                }
                return []
            }

            if let list = resultAny as? [[String: Any]] {
                return list
            }
            if let genericList = resultAny as? [Any] {
                return genericList.compactMap { $0 as? [String: Any] }
            }
            return []
        }

        do {
            var chapters = try await requestChapterList(refresh: 0)
            if chapters.isEmpty {
                readerServerLog("目录为空，触发 refresh=1 重试")
                chapters = try await requestChapterList(refresh: 1)
            }

            guard !chapters.isEmpty else {
                readerServerLog("获取目录失败: 目录为空")
                recordSourceFailure(
                    endpoint: "/getChapterList",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    reason: "empty_after_refresh",
                    requestBody: requestBody,
                    responsePreview: lastResponsePreview
                )
                return []
            }
            
            readerServerLog("✅ 成功获取目录: \(chapters.count) 章")
            readerServerLog("========================================")
            return parseChapterList(chapters)
        } catch {
            recordSourceFailure(
                endpoint: "/getChapterList",
                sourceUrl: cleanSourceUrl,
                bookUrl: bookUrl,
                reason: "request_failed",
                error: error,
                requestBody: requestBody,
                responsePreview: lastResponsePreview
            )
            throw error
        }
    }
    
    private func parseChapterList(_ chapters: [[String: Any]]) -> [ChapterResponse] {
        return chapters.enumerated().compactMap { fallbackIndex, dict -> ChapterResponse? in
            guard let title = dict["title"] as? String ?? dict["chapterName"] as? String,
                  let url = dict["url"] as? String ?? dict["chapterUrl"] as? String else { return nil }
            return ChapterResponse(
                title: title,
                url: url,
                // reader 服务端 getBookContent 依赖连续章节下标，使用稳定的本地序号避免“获取章节链接失败”。
                index: fallbackIndex,
                isVip: dict["isVip"] as? Bool ?? false,
                isPay: dict["isPay"] as? Bool ?? false
            )
        }
    }
    
    // MARK: - Find Alternative Sources (换源)
    
    func findAlternativeSources(bookName: String, author: String? = nil) async throws -> [BookInfoResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.findAlternativeSources(bookName: bookName, author: author)
        }
        readerServerLog("========== findAlternativeSources ==========")
        readerServerLog("bookName: \(bookName)")
        
        let data = try await request(endpoint: "/searchBook", method: "POST", body: ["key": bookName])
        
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("Search response: \(str.prefix(500))")
        }
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let books = result["data"] as? [[String: Any]] else {
            return []
        }
        
        // Filter by author if available
        var filteredBooks = books
        if let author = author, !author.isEmpty {
            filteredBooks = books.filter { dict in
                let bookAuthor = dict["author"] as? String ?? ""
                return bookAuthor.contains(author) || author.contains(bookAuthor)
            }
        }
        
        return filteredBooks.compactMap { dict -> BookInfoResponse? in
            guard let name = dict["bookName"] as? String ?? dict["name"] as? String,
                  let bookUrl = dict["bookUrl"] as? String ?? dict["url"] as? String else { return nil }
            
            var coverUrl = dict["coverUrl"] as? String
            if let cover = coverUrl, !cover.isEmpty {
                coverUrl = getAssetUrl(cover)
            }
            
            return BookInfoResponse(
                name: name,
                author: dict["author"] as? String ?? "",
                bookUrl: bookUrl,
                sourceUrl: parseBookSourceUrl(from: dict),
                coverUrl: coverUrl,
                intro: dict["intro"] as? String,
                kind: dict["kind"] as? String,
                latestChapter: dict["latestChapterTitle"] as? String,
                tocUrl: parseBookTocUrl(from: dict),
                wordCount: dict["wordCount"] as? String,
                chapterCount: dict["totalChapterNum"] as? Int,
                type: dict["type"] as? Int ?? 0,
                durChapterIndex: dict["durChapterIndex"] as? Int ?? 0,
                durChapterPos: dict["durChapterPos"] as? Int ?? 0,
                durChapterTime: dict["durChapterTime"] as? Int64 ?? 0,
                totalChapterNum: dict["totalChapterNum"] as? Int ?? 0
            )
        }
    }
    
    // MARK: - Content
    
    func getChapterContent(bookUrl: String, sourceUrl: String, chapterUrl: String, index: Int = 0) async throws -> ChapterContent {
        let cleanSourceUrl = normalizeSourceUrl(sourceUrl)
        if !BookParseManager.shared.isServerMode {
            do {
                return try await localAPI.getChapterContent(
                    bookUrl: bookUrl,
                    sourceUrl: sourceUrl,
                    chapterUrl: chapterUrl,
                    index: index
                )
            } catch {
                recordSourceFailure(
                    endpoint: "/getBookContent_local",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    chapterUrl: chapterUrl,
                    reason: "request_failed_local",
                    error: error,
                    requestBody: [
                        "url": bookUrl,
                        "index": index,
                        "chapterUrl": chapterUrl,
                        "bookSourceUrl": sourceUrl
                    ]
                )
                throw error
            }
        }
        readerServerLog("========================================")
        readerServerLog("【获取小说正文请求】")
        readerServerLog("========================================")
        readerServerLog("请求地址: /getBookContent")
        readerServerLog("请求方法: POST")
        readerServerLog("请求头: Content-Type: application/json")
        
        // 请求主体参数 - 与 reader 服务端兼容
        let requestBody: [String: Any] = [
            "url": bookUrl,
            "index": index,
            "chapterUrl": chapterUrl,
            "bookSourceUrl": sourceUrl
        ]
        
        readerServerLog("--- 请求主体参数 (Request Body) ---")
        if let jsonData = try? JSONSerialization.data(withJSONObject: requestBody, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            readerServerLog(jsonString)
        }
        readerServerLog("-----------------------------------")
        readerServerLog("bookUrl: \(bookUrl)")
        readerServerLog("sourceUrl: \(sourceUrl)")
        readerServerLog("chapterUrl: \(chapterUrl)")
        readerServerLog("index: \(index)")
        
        let baseForResolve = chapterUrl.isEmpty ? bookUrl : chapterUrl
        var lastResponsePreview: String?

        func requestChapterPayload(refresh: Int) async throws -> (content: String, imageUrls: [String]?) {
            var body = requestBody
            if refresh > 0 {
                body["refresh"] = refresh
            }
            let data = try await request(endpoint: "/getBookContent", method: "POST", body: body)
            readerServerLog("--- 响应数据 (Response) ---")
            if let str = String(data: data, encoding: .utf8) {
                lastResponsePreview = String(str.prefix(1000))
                readerServerLog("Response: \(str.prefix(1000))")
            }
            readerServerLog("-----------------------------------")

            guard let resultAny = try? JSONSerialization.jsonObject(with: data) else {
                if let raw = String(data: data, encoding: .utf8),
                   !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let parsed = parseChapterPayload(raw, baseURL: baseForResolve)
                    return (parsed.content, parsed.imageUrls.isEmpty ? nil : parsed.imageUrls)
                }
                recordSourceFailure(
                    endpoint: "/getBookContent",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    chapterUrl: chapterUrl,
                    reason: "decode_failed_refresh_\(refresh)",
                    requestBody: body,
                    responsePreview: lastResponsePreview
                )
                return ("", nil)
            }
            let payload: Any
            if let result = resultAny as? [String: Any] {
                if result["isSuccess"] as? Bool == false {
                    recordSourceFailure(
                        endpoint: "/getBookContent",
                        sourceUrl: cleanSourceUrl,
                        bookUrl: bookUrl,
                        chapterUrl: chapterUrl,
                        reason: "api_failed_refresh_\(refresh)",
                        requestBody: body,
                        responsePreview: lastResponsePreview
                    )
                }
                payload = result["data"] ?? result
            } else {
                payload = resultAny
            }
            let parsed = parseChapterPayload(payload, baseURL: baseForResolve)
            return (parsed.content, parsed.imageUrls.isEmpty ? nil : parsed.imageUrls)
        }

        do {
            var first = try await requestChapterPayload(refresh: 0)
            if first.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (first.imageUrls?.isEmpty ?? true) {
                readerServerLog("首次正文为空，触发 refresh=1 重试")
                first = try await requestChapterPayload(refresh: 1)
            }

            let content = first.content
            let imageUrls = first.imageUrls
            readerServerLog("正文长度: \(content.count) 字符")
            if let imageUrls, !imageUrls.isEmpty {
                readerServerLog("发现 \(imageUrls.count) 张图片")
            }
            
            // If content is empty but we found images, treat as comic
            if content.isEmpty && imageUrls != nil && !(imageUrls?.isEmpty ?? true) {
                readerServerLog("检测到漫画模式: \(imageUrls?.count ?? 0) 张图片")
            }
            
            if content.isEmpty {
                readerServerLog("获取正文失败: 内容为空")
                recordSourceFailure(
                    endpoint: "/getBookContent",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    chapterUrl: chapterUrl,
                    reason: "empty_after_refresh",
                    requestBody: requestBody,
                    responsePreview: lastResponsePreview
                )
            } else {
                readerServerLog("✅ 成功获取正文: \(content.count) 字符")
            }
            readerServerLog("========================================")
            
            var chapterContent = ChapterContent(content: content)
            chapterContent.url = chapterUrl
            chapterContent.imageUrls = imageUrls
            return chapterContent
        } catch {
            recordSourceFailure(
                endpoint: "/getBookContent",
                sourceUrl: cleanSourceUrl,
                bookUrl: bookUrl,
                chapterUrl: chapterUrl,
                reason: "request_failed",
                error: error,
                requestBody: requestBody,
                responsePreview: lastResponsePreview
            )
            throw error
        }
    }
    
    private func parseChapterPayload(_ payload: Any, baseURL: String) -> (content: String, imageUrls: [String]) {
        var textCandidates: [String] = []
        var imageCandidates: [String] = []
        collectChapterPayload(from: payload, baseURL: baseURL, textCandidates: &textCandidates, imageCandidates: &imageCandidates)

        var content = textCandidates.max(by: { $0.count < $1.count }) ?? ""
        content = normalizeChapterText(content)
        let images = uniqueStrings(imageCandidates)
        return (content, images)
    }

    private func collectChapterPayload(
        from payload: Any,
        baseURL: String,
        textCandidates: inout [String],
        imageCandidates: inout [String]
    ) {
        switch payload {
        case let string as String:
            let normalized = normalizeJSONStringContainer(string)
            if looksLikeJSONPayload(normalized),
               let data = normalized.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                collectChapterPayload(from: object, baseURL: baseURL, textCandidates: &textCandidates, imageCandidates: &imageCandidates)
                return
            }

            if let directImage = directImageURL(from: normalized, baseURL: baseURL) {
                imageCandidates.append(directImage)
            }

            if let urls = extractImageUrls(from: normalized, baseURL: baseURL) {
                imageCandidates.append(contentsOf: urls)
            }
            if !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textCandidates.append(normalized)
            }

        case let dict as [String: Any]:
            let textPriorityKeys = [
                "content", "body", "text", "html", "article", "chapterContent",
                "chapter", "data", "result", "msg", "message", "value"
            ]
            let imageKeys = [
                "imageUrls", "images", "imgs", "picUrls", "pictures", "imageList", "imgList",
                "picList", "urlList", "comicImages", "pages", "photos"
            ]

            for key in imageKeys {
                guard let value = dict[key] else { continue }
                collectChapterPayload(from: value, baseURL: baseURL, textCandidates: &textCandidates, imageCandidates: &imageCandidates)
            }

            for key in textPriorityKeys {
                guard let value = dict[key] else { continue }
                collectChapterPayload(from: value, baseURL: baseURL, textCandidates: &textCandidates, imageCandidates: &imageCandidates)
            }

            for (key, value) in dict where !textPriorityKeys.contains(key) && !imageKeys.contains(key) {
                collectChapterPayload(from: value, baseURL: baseURL, textCandidates: &textCandidates, imageCandidates: &imageCandidates)
            }

        case let array as [Any]:
            for item in array {
                collectChapterPayload(from: item, baseURL: baseURL, textCandidates: &textCandidates, imageCandidates: &imageCandidates)
            }

        default:
            break
        }
    }

    private func normalizeJSONStringContainer(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")),
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return trimmed
        }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeJSONPayload(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    private func normalizeChapterText(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let decoded = decodeHTMLEntities(raw)
        let text: String
        if containsHTMLMarkup(decoded) {
            text = formatHTMLToReadableText(decoded)
        } else {
            text = decoded
        }
        return text
            .replacingOccurrences(of: "\\r\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsHTMLMarkup(_ content: String) -> Bool {
        content.range(of: "<\\s*/?\\s*[a-zA-Z][^>]*>", options: .regularExpression) != nil
    }

    private func formatHTMLToReadableText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "</?(div|p|br|hr|h\\d|article|dd|dl|li|ul|ol|tr|table|section|blockquote)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<img[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeHTMLEntities(text)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&ldquo;", with: "\"")
            .replacingOccurrences(of: "&rdquo;", with: "\"")
            .replacingOccurrences(of: "&lsquo;", with: "'")
            .replacingOccurrences(of: "&rsquo;", with: "'")
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            if !result.contains(value) {
                result.append(value)
            }
        }
        return result
    }

    private func directImageURL(from text: String, baseURL: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let lower = raw.lowercased()
        let isLikelyImagePath = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".svg"].contains {
            lower.contains($0)
        }
        guard isLikelyImagePath else { return nil }

        let base = URL(string: baseURL)
        return resolveImageURL(raw, base: base)
    }

    private func extractImageUrls(from content: String, baseURL: String) -> [String]? {
        var urls: [String] = []
        let base = URL(string: baseURL)
        
        // Match src="..." or src='...'
        let patterns = [
            #"src\s*=\s*["']([^"']+)["']"#,
            #"data-src\s*=\s*["']([^"']+)["']"#,
            #"data-original\s*=\s*["']([^"']+)["']"#,
            #"!\[[^\]]*]\(([^)]+)\)"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(content.startIndex..., in: content)
                let matches = regex.matches(in: content, options: [], range: range)
                
                for match in matches {
                    if let urlRange = Range(match.range(at: 1), in: content) {
                        let raw = String(content[urlRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let resolved = resolveImageURL(raw, base: base)
                        guard let resolved else { continue }
                        if !urls.contains(resolved) {
                            urls.append(resolved)
                        }
                    }
                }
            }
        }

        // Fallback: plain text image links
        if let plainRegex = try? NSRegularExpression(
            pattern: #"((https?:)?//[^\s"'<>]+?\.(?:jpg|jpeg|png|gif|webp|bmp|svg)(?:\?[^\s"'<>]*)?)"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(content.startIndex..., in: content)
            let matches = plainRegex.matches(in: content, options: [], range: range)
            for match in matches {
                guard let valueRange = Range(match.range(at: 1), in: content) else { continue }
                let raw = String(content[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = resolveImageURL(raw, base: base)
                guard let resolved else { continue }
                if !urls.contains(resolved) {
                    urls.append(resolved)
                }
            }
        }
        
        return urls.isEmpty ? nil : urls
    }

    private func resolveImageURL(_ rawValue: String, base: URL?) -> String? {
        var raw = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")

        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("data:") || raw.lowercased().hasPrefix("javascript:") {
            return nil
        }

        if raw.hasPrefix("__API_ROOT__") || raw.lowercased().hasPrefix("__api_root__") {
            raw = raw.replacingOccurrences(of: "__API_ROOT__", with: "")
                .replacingOccurrences(of: "__api_root__", with: "")
            if raw.isEmpty {
                return nil
            }
            if !raw.hasPrefix("/") {
                raw = "/\(raw)"
            }
            return getAssetUrl(raw)
        }

        if raw.hasPrefix("//") {
            return "https:\(raw)"
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        if raw.hasPrefix("/") {
            return getAssetUrl(raw)
        }
        if let absolute = URL(string: raw, relativeTo: base)?.absoluteURL.absoluteString {
            return absolute
        }
        if raw.contains(".") && !raw.contains(" ") {
            return getAssetUrl(raw)
        }
        return nil
    }

    // MARK: - Bookshelf
    
    func getBookshelf() async throws -> [BookInfoResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getBookshelf()
        }
        let data = try await request(endpoint: "/getBookshelf")
        
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("getBookshelf response: \(str.prefix(500))")
        }
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let books = result["data"] as? [[String: Any]] else {
            return []
        }
        return books.compactMap { dict -> BookInfoResponse? in
            guard let name = firstNonEmptyString(in: dict, keys: ["bookName", "name", "title"]),
                  let bookUrl = firstNonEmptyString(in: dict, keys: ["bookUrl", "url"]) else { return nil }
            
            var coverUrl = dict["coverUrl"] as? String
            if let cover = coverUrl, !cover.isEmpty {
                coverUrl = getAssetUrl(cover)
            }
            
            let sourceUrl = parseBookSourceUrl(from: dict)
            readerServerLog("Book from shelf: \(name), bookUrl: \(bookUrl), sourceUrl: \(sourceUrl ?? "nil")")
            var response = BookInfoResponse(
                name: name,
                author: dict["author"] as? String ?? "",
                bookUrl: bookUrl,
                sourceUrl: sourceUrl,
                coverUrl: coverUrl,
                intro: dict["intro"] as? String,
                kind: dict["kind"] as? String,
                latestChapter: dict["latestChapterTitle"] as? String,
                tocUrl: parseBookTocUrl(from: dict),
                wordCount: dict["wordCount"] as? String,
                chapterCount: dict["totalChapterNum"] as? Int,
                type: dict["type"] as? Int ?? 0,
                durChapterIndex: dict["durChapterIndex"] as? Int ?? 0,
                durChapterPos: dict["durChapterPos"] as? Int ?? 0,
                durChapterTime: dict["durChapterTime"] as? Int64 ?? 0,
                totalChapterNum: dict["totalChapterNum"] as? Int ?? 0
            )
            response.originName = parseBookOriginName(from: dict)
            return response
        }
    }
    
    func isInBookshelf(bookUrl: String) -> Bool {
        if !BookParseManager.shared.isServerMode {
            return localAPI.isInBookshelf(bookUrl: bookUrl)
        }
        let bookshelf = DatabaseManager.shared.getAllBooks()
        return bookshelf.contains { $0.bookUrl == bookUrl }
    }
    
    func addToBookshelf(book: BookInfoResponse) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.addToBookshelf(book: book)
            return
        }
        let body: [String: Any] = [
            "bookUrl": book.bookUrl,
            "origin": book.sourceUrl ?? "",
            "name": book.name,
            "author": book.author,
            "coverUrl": book.coverUrl ?? "",
            "intro": book.intro ?? "",
            "kind": book.kind ?? "",
            "latestChapterTitle": book.latestChapter ?? "",
            "tocUrl": book.tocUrl ?? ""
        ]
        _ = try await request(endpoint: "/saveBook", method: "POST", body: body)
    }
    
    func refreshBook(bookUrl: String, sourceUrl: String) async throws -> BookInfoResponse {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.refreshBook(bookUrl: bookUrl, sourceUrl: sourceUrl)
        }
        readerServerLog("refreshBook called with bookUrl: \(bookUrl), sourceUrl: \(sourceUrl)")
        
        let requestSourceUrl = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let data = try await request(endpoint: "/refreshBook", method: "POST", body: [
            "bookUrl": bookUrl,
            "sourceUrl": requestSourceUrl
        ])
        
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("refreshBook response: \(str.prefix(300))")
        }
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let book = result["data"] as? [String: Any] else {
            throw ServerError.decodingError
        }
        
        var coverUrl = book["coverUrl"] as? String
        if let cover = coverUrl, !cover.isEmpty {
            coverUrl = getAssetUrl(cover)
        }
        
        return BookInfoResponse(
            name: book["bookName"] as? String ?? "",
            author: book["author"] as? String ?? "",
            bookUrl: book["bookUrl"] as? String ?? bookUrl,
            sourceUrl: parseBookSourceUrl(from: book, fallback: sourceUrl),
            coverUrl: coverUrl,
            intro: book["intro"] as? String,
            kind: book["kind"] as? String,
            latestChapter: book["latestChapterTitle"] as? String,
            tocUrl: parseBookTocUrl(from: book),
            wordCount: book["wordCount"] as? String,
            chapterCount: book["totalChapterNum"] as? Int,
            type: book["type"] as? Int ?? 0,
            durChapterIndex: book["durChapterIndex"] as? Int ?? 0,
            durChapterPos: book["durChapterPos"] as? Int ?? 0,
            durChapterTime: book["durChapterTime"] as? Int64 ?? 0,
            totalChapterNum: book["totalChapterNum"] as? Int ?? 0
        )
    }
    
    func removeFromBookshelf(bookUrl: String, sourceUrl: String) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.removeFromBookshelf(bookUrl: bookUrl, sourceUrl: sourceUrl)
            return
        }
        _ = try await request(endpoint: "/deleteBook", method: "POST", body: [
            "bookUrl": bookUrl,
            "sourceUrl": sourceUrl
        ])
    }
    
    func saveBook(book: Book) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.saveBook(book: book)
            return
        }
        let body: [String: Any] = [
            "bookUrl": book.bookUrl,
            "name": book.name,
            "author": book.author,
            "origin": book.origin,
            "coverUrl": book.coverUrl ?? "",
            "intro": book.intro ?? "",
            "kind": book.kind ?? "",
            "tocUrl": book.tocUrl
        ]
        _ = try await request(endpoint: "/saveBook", method: "POST", body: body)
    }
    
    func saveBookInfo(_ bookInfo: BookInfoResponse) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.saveBookInfo(bookInfo)
            return
        }
        let body: [String: Any] = [
            "bookUrl": bookInfo.bookUrl,
            "name": bookInfo.name,
            "author": bookInfo.author,
            "origin": bookInfo.sourceUrl ?? "",
            "coverUrl": bookInfo.coverUrl ?? "",
            "intro": bookInfo.intro ?? "",
            "kind": bookInfo.kind ?? "",
            "tocUrl": bookInfo.tocUrl ?? ""
        ]
        _ = try await request(endpoint: "/saveBook", method: "POST", body: body)
    }
    
    // MARK: - Reading Progress
    
    func saveBookProgress(bookUrl: String, sourceUrl: String, chapterIndex: Int, chapterPos: Int) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.saveBookProgress(bookUrl: bookUrl, sourceUrl: sourceUrl, chapterIndex: chapterIndex, chapterPos: chapterPos)
            return
        }
        let body: [String: Any] = [
            "bookUrl": bookUrl,
            "sourceUrl": sourceUrl,
            "durChapterIndex": chapterIndex,
            "durChapterPos": chapterPos,
            "durChapterTime": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        _ = try await request(endpoint: "/saveBookProgress", method: "POST", body: body)
    }

    // MARK: - Source Switching (换源)
    
    func searchBookSources(bookUrl: String, bookSourceGroup: String? = nil, lastIndex: Int = 0) async throws -> (sources: [SearchBook], lastIndex: Int) {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.searchBookSources(bookUrl: bookUrl, bookSourceGroup: bookSourceGroup, lastIndex: lastIndex)
        }
        readerServerLog("========================================")
        readerServerLog("【搜索备选书源请求】")
        readerServerLog("========================================")
        readerServerLog("请求地址: /searchBookSource")
        readerServerLog("请求方法: POST")
        readerServerLog("bookUrl: \(bookUrl), lastIndex: \(lastIndex)")
        
        var body: [String: Any] = [
            "url": bookUrl,
            "lastIndex": lastIndex
        ]
        if let group = bookSourceGroup {
            body["bookSourceGroup"] = group
        }
        
        let data = try await request(endpoint: "/searchBookSource", method: "POST", body: body)
        
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("Search sources response: \(str.prefix(500))")
        }
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = result["data"] as? [String: Any],
              let sourcesArray = dataDict["list"] as? [[String: Any]] else {
            readerServerLog("解析备选书源失败")
            return ([], lastIndex)
        }
        
        let newLastIndex = dataDict["lastIndex"] as? Int ?? 0
        readerServerLog("Found \(sourcesArray.count) alternative sources, newLastIndex: \(newLastIndex)")
        
        let sources = sourcesArray.compactMap { dict -> SearchBook? in
            guard let name = dict["bookName"] as? String ?? dict["name"] as? String,
                  let bookUrl = dict["bookUrl"] as? String else { return nil }
            
            var coverUrl = dict["coverUrl"] as? String
            if let cover = coverUrl, !cover.isEmpty {
                coverUrl = getAssetUrl(cover)
            }
            
            let latencyTime = dict["time"] as? Int ?? 0
            
            return SearchBook(
                bookUrl: bookUrl,
                bookSourceUrl: dict["bookSourceUrl"] as? String ?? dict["origin"] as? String ?? "",
                name: name,
                author: dict["author"] as? String ?? "",
                coverUrl: coverUrl,
                intro: dict["intro"] as? String,
                kind: dict["kind"] as? String,
                latestChapter: dict["latestChapterTitle"] as? String,
                wordCount: dict["wordCount"] as? String,
                origin: dict["origin"] as? String,
                originName: dict["originName"] as? String,
                time: latencyTime
            )
        }
        
        readerServerLog("Parsed \(sources.count) valid sources")
        readerServerLog("========================================")
        
        return (sources, newLastIndex)
    }
    
    func switchToSource(bookUrl: String, newUrl: String, bookSourceUrl: String) async throws -> Book {
        let cleanSourceUrl = normalizeSourceUrl(bookSourceUrl)
        if !BookParseManager.shared.isServerMode {
            do {
                return try await localAPI.switchToSource(bookUrl: bookUrl, newUrl: newUrl, bookSourceUrl: bookSourceUrl)
            } catch {
                recordSourceFailure(
                    endpoint: "/setBookSource_local",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    reason: "switch_failed_local",
                    error: error,
                    requestBody: [
                        "bookUrl": bookUrl,
                        "newUrl": newUrl,
                        "bookSourceUrl": bookSourceUrl
                    ]
                )
                throw error
            }
        }
        // 与 reader 上游思路保持一致：换源前先验证候选源是否可读。
        _ = try await validateSwitchCandidate(bookUrl: bookUrl, newUrl: newUrl, bookSourceUrl: bookSourceUrl)
        readerServerLog("========================================")
        readerServerLog("【换源请求】")
        readerServerLog("========================================")
        readerServerLog("请求地址: /setBookSource")
        readerServerLog("请求方法: POST")
        readerServerLog("请求头: Content-Type: application/json")
        
        let requestBody: [String: Any] = [
            "bookUrl": bookUrl,
            "newUrl": newUrl,
            "bookSourceUrl": bookSourceUrl
        ]
        
        readerServerLog("--- 请求主体参数 (Request Body) ---")
        if let jsonData = try? JSONSerialization.data(withJSONObject: requestBody, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            readerServerLog(jsonString)
        }
        readerServerLog("-----------------------------------")
        
        let data = try await request(endpoint: "/setBookSource", method: "POST", body: requestBody)
        
        readerServerLog("--- 响应数据 (Response) ---")
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("Response: \(str)")
        }
        readerServerLog("-----------------------------------")
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isSuccess = result["isSuccess"] as? Bool, isSuccess,
              let bookData = result["data"] as? [String: Any] else {
            let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["errorMsg"] as? String ?? "切换书源失败"
            recordSourceFailure(
                endpoint: "/setBookSource",
                sourceUrl: cleanSourceUrl,
                bookUrl: bookUrl,
                reason: "switch_failed",
                requestBody: requestBody,
                responsePreview: String(data: data, encoding: .utf8)
            )
            readerServerLog("❌ 切换书源失败: \(errorMsg)")
            throw NSError(domain: "ReaderServerAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        readerServerLog("✅ 切换书源成功")
        
        var coverUrl = bookData["coverUrl"] as? String
        if let cover = coverUrl, !cover.isEmpty {
            coverUrl = getAssetUrl(cover)
        }
        
        let bookName = bookData["name"] as? String ?? bookData["bookName"] as? String ?? ""
        
        readerServerLog("新书籍信息: name=\(bookName), bookUrl=\(bookData["bookUrl"] as? String ?? newUrl)")
        readerServerLog("========================================")
        
        return Book(
            bookUrl: bookData["bookUrl"] as? String ?? newUrl,
            tocUrl: bookData["tocUrl"] as? String ?? "",
            origin: bookData["origin"] as? String ?? bookSourceUrl,
            originName: bookData["originName"] as? String ?? "",
            name: bookName,
            author: bookData["author"] as? String ?? "",
            kind: bookData["kind"] as? String,
            coverUrl: coverUrl,
            intro: bookData["intro"] as? String,
            type: bookData["type"] as? Int ?? 0,
            totalChapterNum: bookData["totalChapterNum"] as? Int ?? 0,
            durChapterIndex: bookData["durChapterIndex"] as? Int ?? 0,
            durChapterPos: bookData["durChapterPos"] as? Int ?? 0,
            durChapterTime: bookData["durChapterTime"] as? Int64 ?? 0
        )
    }

    func validateSwitchCandidate(bookUrl: String, newUrl: String, bookSourceUrl: String) async throws -> (chapterCount: Int, probeCount: Int) {
        let cleanSourceUrl = normalizeSourceUrl(bookSourceUrl)
        if !BookParseManager.shared.isServerMode {
            do {
                return try await localAPI.validateSwitchCandidate(bookUrl: bookUrl, newUrl: newUrl, bookSourceUrl: bookSourceUrl)
            } catch {
                recordSourceFailure(
                    endpoint: "/validateSwitchCandidate_local",
                    sourceUrl: cleanSourceUrl,
                    bookUrl: bookUrl,
                    reason: "validate_failed_local",
                    error: error,
                    requestBody: [
                        "bookUrl": bookUrl,
                        "newUrl": newUrl,
                        "bookSourceUrl": bookSourceUrl
                    ]
                )
                throw error
            }
        }

        let info = try await getBookInfo(bookUrl: newUrl, sourceUrl: bookSourceUrl)
        let resolvedBookUrl = info.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? newUrl : info.bookUrl
        let chapters = try await getChapterList(bookUrl: resolvedBookUrl, sourceUrl: bookSourceUrl)

        guard !chapters.isEmpty else {
            throw NSError(
                domain: "ReaderServerAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "目录为空，暂不可用于换源"]
            )
        }

        let probes = probeChapters(from: chapters)
        var lastError: Error?
        for chapter in probes {
            do {
                let content = try await getChapterContent(
                    bookUrl: resolvedBookUrl,
                    sourceUrl: bookSourceUrl,
                    chapterUrl: "",
                    index: chapter.index
                )
                if isReadableChapter(content) {
                    return (chapters.count, probes.count)
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw NSError(
                domain: "ReaderServerAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "目录可加载，但正文解析失败: \(lastError.localizedDescription)"]
            )
        }

        throw NSError(
            domain: "ReaderServerAPI",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "目录可加载，但正文为空或疑似未解析"]
        )
    }
    
    func getAvailableBookSources(bookUrl: String, refresh: Bool = false) async throws -> [BookInfoResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getAvailableBookSources(bookUrl: bookUrl, refresh: refresh)
        }
        readerServerLog("========== getAvailableBookSources ==========")
        readerServerLog("bookUrl: \(bookUrl)")
        
        let data = try await request(endpoint: "/getAvailableBookSource", method: "POST", body: [
            "url": bookUrl,
            "refresh": refresh ? 1 : 0
        ])
        
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("Available sources response: \(str.prefix(500))")
        }
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = result["data"] as? [[String: Any]] else {
            return []
        }
        
        return sources.compactMap { dict -> BookInfoResponse? in
            guard let name = dict["bookName"] as? String ?? dict["name"] as? String,
                  let bookUrl = dict["bookUrl"] as? String else { return nil }
            
            var coverUrl = dict["coverUrl"] as? String
            if let cover = coverUrl, !cover.isEmpty {
                coverUrl = getAssetUrl(cover)
            }
            
            var response = BookInfoResponse(
                name: name,
                author: dict["author"] as? String ?? "",
                bookUrl: bookUrl,
                sourceUrl: parseBookSourceUrl(from: dict),
                coverUrl: coverUrl,
                intro: dict["intro"] as? String,
                kind: dict["kind"] as? String,
                latestChapter: dict["latestChapterTitle"] as? String,
                tocUrl: parseBookTocUrl(from: dict),
                wordCount: dict["wordCount"] as? String,
                chapterCount: dict["totalChapterNum"] as? Int,
                type: dict["type"] as? Int ?? 0,
                durChapterIndex: dict["durChapterIndex"] as? Int ?? 0,
                durChapterPos: dict["durChapterPos"] as? Int ?? 0,
                durChapterTime: dict["durChapterTime"] as? Int64 ?? 0,
                totalChapterNum: dict["totalChapterNum"] as? Int ?? 0
            )
            response.originName = parseBookOriginName(from: dict)
            return response
        }
    }

    func setBookSource(bookUrl: String, newUrl: String, sourceUrl: String) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.setBookSource(bookUrl: bookUrl, newUrl: newUrl, sourceUrl: sourceUrl)
            return
        }
        readerServerLog("========== setBookSource ==========")
        readerServerLog("bookUrl: \(bookUrl), newUrl: \(newUrl), sourceUrl: \(sourceUrl)")
        
        let data = try await request(endpoint: "/setBookSource", method: "POST", body: [
            "bookUrl": bookUrl,
            "newUrl": newUrl,
            "bookSourceUrl": sourceUrl
        ])
        
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("Set source response: \(str.prefix(200))")
        }
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isSuccess = result["isSuccess"] as? Bool, isSuccess else {
            let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["errorMsg"] as? String ?? "Unknown error"
            throw NSError(domain: "ReaderServerAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
    }

    private func probeChapters(from chapters: [ChapterResponse]) -> [ChapterResponse] {
        guard !chapters.isEmpty else { return [] }

        var indexes: [Int] = [0, min(2, chapters.count - 1), chapters.count / 2, max(chapters.count - 1, 0)]
        indexes = Array(Set(indexes)).sorted()

        var probes: [ChapterResponse] = []
        for idx in indexes where idx >= 0 && idx < chapters.count {
            let chapter = chapters[idx]
            let url = chapter.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                probes.append(chapter)
            }
        }

        if probes.isEmpty, let first = chapters.first {
            probes.append(first)
        }
        return probes
    }

    private func isReadableChapter(_ content: ChapterContent) -> Bool {
        if let images = content.imageUrls, !images.isEmpty {
            return true
        }

        let trimmed = content.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isLikelyRawJSONText(trimmed) {
            return false
        }

        let compact = trimmed.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return compact.count >= 20
    }

    private func isLikelyRawJSONText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonWrapped = (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        guard jsonWrapped else { return false }

        let lowered = trimmed.lowercased()
        return lowered.contains("\"content\"") ||
            lowered.contains("\"data\"") ||
            lowered.contains("\"chapter\"") ||
            lowered.contains("\"images\"") ||
            lowered.contains("\"imageurls\"")
    }
    
    // MARK: - RSS Sources
    
    func getRssSources() async throws -> [RssSourceResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getRssSources()
        }
        let data = try await request(endpoint: "/getRssSources")
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = result["data"] as? [[String: Any]] else {
            return []
        }
        return sources.compactMap { dict -> RssSourceResponse? in
            guard let url = dict["url"] as? String ?? dict["rssUrl"] as? String else { return nil }
            return RssSourceResponse(
                url: url,
                title: dict["title"] as? String ?? dict["rssName"] as? String ?? "",
                group: dict["group"] as? String,
                enabled: dict["enabled"] as? Bool ?? true,
                header: dict["header"] as? String,
                ruleFindUrl: dict["ruleFindUrl"] as? String,
                ruleList: dict["ruleList"] as? String,
                ruleTitle: dict["ruleTitle"] as? String,
                ruleContent: dict["ruleContent"] as? String,
                ruleImage: dict["ruleImage"] as? String,
                ruleLink: dict["ruleLink"] as? String,
                rulePubDate: dict["rulePubDate"] as? String
            )
        }
    }
    
    func saveRssSource(_ source: RssSourceResponse) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.saveRssSource(source)
            return
        }
        var dict: [String: Any] = [
            "url": source.url,
            "title": source.title,
            "enabled": source.enabled
        ]
        if let group = source.group { dict["group"] = group }
        if let header = source.header { dict["header"] = header }
        if let ruleFindUrl = source.ruleFindUrl { dict["ruleFindUrl"] = ruleFindUrl }
        if let ruleList = source.ruleList { dict["ruleList"] = ruleList }
        if let ruleTitle = source.ruleTitle { dict["ruleTitle"] = ruleTitle }
        if let ruleContent = source.ruleContent { dict["ruleContent"] = ruleContent }
        if let ruleImage = source.ruleImage { dict["ruleImage"] = ruleImage }
        if let ruleLink = source.ruleLink { dict["ruleLink"] = ruleLink }
        if let rulePubDate = source.rulePubDate { dict["rulePubDate"] = rulePubDate }
        
        _ = try await request(endpoint: "/saveRssSource", method: "POST", body: dict)
    }
    
    func deleteRssSource(url: String) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.deleteRssSource(url: url)
            return
        }
        _ = try await request(endpoint: "/deleteRssSource", method: "POST", body: ["url": url])
    }
    
    func getRssArticles(rssUrl: String, articleUrl: String? = nil) async throws -> [RssArticleResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getRssArticles(rssUrl: rssUrl, articleUrl: articleUrl)
        }
        var body: [String: Any] = ["rssUrl": rssUrl]
        if let articleUrl = articleUrl {
            body["url"] = articleUrl
        }
        
        let data = try await request(endpoint: "/getRssArticles", method: "POST", body: body)
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let articles = result["data"] as? [[String: Any]] else {
            return []
        }
        
        readerServerLog("Found \(articles.count) articles")
        
        return articles.compactMap { dict -> RssArticleResponse? in
            guard let title = dict["title"] as? String else { return nil }
            return RssArticleResponse(
                title: title,
                url: dict["url"] as? String ?? "",
                author: dict["author"] as? String,
                content: dict["content"] as? String ?? dict["html"] as? String,
                pubDate: dict["pubDate"] as? String,
                imageUrl: dict["image"] as? String
            )
        }
    }
    
    // MARK: - Book Groups
    
    func getBookGroups() async throws -> [BookGroupResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getBookGroups()
        }
        let data = try await request(endpoint: "/getBookGroups")
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = result["data"] as? [[String: Any]] else {
            return []
        }
        return groups.compactMap { dict -> BookGroupResponse? in
            guard let groupId = dict["groupId"] as? Int64 ?? dict["id"] as? Int64 else { return nil }
            return BookGroupResponse(
                id: groupId,
                name: dict["groupName"] as? String ?? dict["name"] as? String ?? "",
                bookCount: dict["bookCount"] as? Int ?? 0
            )
        }
    }
    
    // MARK: - Replace Rules
    
    func getReplaceRules() async throws -> [ReplaceRuleResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getReplaceRules()
        }
        let data = try await request(endpoint: "/getReplaceRules")
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = result["data"] as? [[String: Any]] else {
            return []
        }
        return rules.compactMap { dict -> ReplaceRuleResponse? in
            guard let id = dict["id"] as? Int else { return nil }
            return ReplaceRuleResponse(
                id: id,
                name: dict["name"] as? String ?? "",
                rule: dict["rule"] as? String ?? "",
                replacement: dict["replacement"] as? String ?? "",
                enabled: dict["enabled"] as? Bool ?? true,
                order: dict["order"] as? Int ?? 0
            )
        }
    }
    
    // MARK: - Explore
    
    func explore(sourceUrl: String, url: String, page: Int = 1) async throws -> [BookInfoResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.explore(sourceUrl: sourceUrl, url: url, page: page)
        }
        let data = try await request(endpoint: "/exploreBook", method: "POST", body: [
            "bookSourceUrl": sourceUrl,
            "ruleFindUrl": url,
            "page": page
        ])
        
        #if DEBUG
        if let str = String(data: data, encoding: .utf8) {
            readerServerLog("explore response: \(str.prefix(500))")
        }
        #endif
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let books = result["data"] as? [[String: Any]] else {
            return []
        }
        
        #if DEBUG
        readerServerLog("Found \(books.count) books from explore")
        if let firstBook = books.first {
            readerServerLog("First book keys: \(firstBook.keys.joined(separator: ", "))")
            if let origin = firstBook["origin"] as? String {
                readerServerLog("First book origin: \(origin)")
            }
        }
        #endif
        
        return books.compactMap { dict -> BookInfoResponse? in
            guard let name = dict["bookName"] as? String ?? dict["name"] as? String,
                  let bookUrl = dict["bookUrl"] as? String else { return nil }
            
            var coverUrl = dict["coverUrl"] as? String
            if let cover = coverUrl, !cover.isEmpty {
                coverUrl = getAssetUrl(cover)
            }
            
            var response = BookInfoResponse(
                name: name,
                author: dict["author"] as? String ?? "",
                bookUrl: bookUrl,
                sourceUrl: parseBookSourceUrl(from: dict, fallback: sourceUrl),
                coverUrl: coverUrl,
                intro: dict["intro"] as? String,
                kind: dict["kind"] as? String,
                latestChapter: dict["latestChapterTitle"] as? String,
                tocUrl: parseBookTocUrl(from: dict),
                wordCount: dict["wordCount"] as? String,
                chapterCount: dict["totalChapterNum"] as? Int,
                type: dict["type"] as? Int ?? 0,
                durChapterIndex: dict["durChapterIndex"] as? Int ?? 0,
                durChapterPos: dict["durChapterPos"] as? Int ?? 0,
                durChapterTime: dict["durChapterTime"] as? Int64 ?? 0,
                totalChapterNum: dict["totalChapterNum"] as? Int ?? 0
            )
            response.originName = parseBookOriginName(from: dict)
            return response
        }
    }
    
    // MARK: - Bookmarks
    
    func getBookmarks() async throws -> [Bookmark] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getBookmarks()
        }
        let data = try await request(endpoint: "/getBookmarks")
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bookmarks = result["data"] as? [[String: Any]] else {
            return []
        }
        return bookmarks.compactMap { dict -> Bookmark? in
            guard let bookName = dict["bookName"] as? String else { return nil }
            return Bookmark(
                bookName: bookName,
                bookAuthor: dict["bookAuthor"] as? String ?? "",
                chapterIndex: dict["chapterIndex"] as? Int ?? 0,
                chapterName: dict["chapterName"] as? String ?? "",
                bookText: dict["bookText"] as? String ?? "",
                content: dict["content"] as? String ?? "",
                createTime: dict["createTime"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000)
            )
        }
    }
    
    func saveBookmark(_ bookmark: Bookmark) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.saveBookmark(bookmark)
            return
        }
        let body: [String: Any] = [
            "bookName": bookmark.bookName,
            "bookAuthor": bookmark.bookAuthor,
            "chapterIndex": bookmark.chapterIndex,
            "chapterName": bookmark.chapterName,
            "bookText": bookmark.bookText,
            "content": bookmark.content
        ]
        _ = try await request(endpoint: "/saveBookmark", method: "POST", body: body)
    }
    
    func saveBookmarks(_ bookmarks: [Bookmark]) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.saveBookmarks(bookmarks)
            return
        }
        let body: [String: Any] = [
            "bookmarks": bookmarks.map { bookmark -> [String: Any] in
                return [
                    "bookName": bookmark.bookName,
                    "bookAuthor": bookmark.bookAuthor,
                    "chapterIndex": bookmark.chapterIndex,
                    "chapterName": bookmark.chapterName,
                    "bookText": bookmark.bookText,
                    "content": bookmark.content
                ]
            }
        ]
        _ = try await request(endpoint: "/saveBookmarks", method: "POST", body: body)
    }
    
    func deleteBookmark(bookmark: Bookmark) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.deleteBookmark(bookmark: bookmark)
            return
        }
        let body: [String: Any] = [
            "bookName": bookmark.bookName,
            "bookAuthor": bookmark.bookAuthor,
            "chapterIndex": bookmark.chapterIndex
        ]
        _ = try await request(endpoint: "/deleteBookmark", method: "POST", body: body)
    }
    
    func deleteBookmarks(_ bookmarks: [Bookmark]) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.deleteBookmarks(bookmarks)
            return
        }
        let body: [String: Any] = [
            "bookmarks": bookmarks.map { bookmark -> [String: Any] in
                return [
                    "bookName": bookmark.bookName,
                    "bookAuthor": bookmark.bookAuthor,
                    "chapterIndex": bookmark.chapterIndex
                ]
            }
        ]
        _ = try await request(endpoint: "/deleteBookmarks", method: "POST", body: body)
    }
    
    // MARK: - Book Groups
    
    func addBookGroupMulti(groupId: Int64, books: [BookInfoResponse]) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.addBookGroupMulti(groupId: groupId, books: books)
            return
        }
        let body: [String: Any] = [
            "groupId": groupId,
            "bookList": books.map { book -> [String: Any] in
                return [
                    "bookUrl": book.bookUrl,
                    "origin": book.sourceUrl ?? ""
                ]
            }
        ]
        _ = try await request(endpoint: "/addBookGroupMulti", method: "POST", body: body)
    }
    
    func removeBookGroupMulti(groupId: Int64, books: [BookInfoResponse]) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.removeBookGroupMulti(groupId: groupId, books: books)
            return
        }
        let body: [String: Any] = [
            "groupId": groupId,
            "bookList": books.map { book -> [String: Any] in
                return [
                    "bookUrl": book.bookUrl,
                    "origin": book.sourceUrl ?? ""
                ]
            }
        ]
        _ = try await request(endpoint: "/removeBookGroupMulti", method: "POST", body: body)
    }
    
    // MARK: - Book Cache
    
    func cacheBook(bookUrl: String) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.cacheBook(bookUrl: bookUrl)
            return
        }
        _ = try await request(endpoint: "/cacheBook", method: "POST", body: ["url": bookUrl])
    }
    
    func deleteBookCache(bookUrl: String) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.deleteBookCache(bookUrl: bookUrl)
            return
        }
        _ = try await request(endpoint: "/deleteBookCache", method: "POST", body: ["bookUrl": bookUrl])
    }
    
    // MARK: - Export
    
    func exportBook(bookUrl: String, isEpub: Bool = false) async throws -> URL {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.exportBook(bookUrl: bookUrl, isEpub: isEpub)
        }
        let endpoint = isEpub ? "/exportBook" : "/exportBook"
        let data = try await request(endpoint: endpoint, method: "POST", body: [
            "url": bookUrl,
            "isEpub": isEpub ? 1 : 0
        ])
        
        let fileName = isEpub ? "book.epub" : "book.txt"
        let fileURL = try AppTempPaths.makeExportFileURL(fileName: fileName)
        
        try data.write(to: fileURL)
        return fileURL
    }
    
    // MARK: - Reading History
    
    func getReadingHistory() async throws -> [BookInfoResponse] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getReadingHistory()
        }
        let data = try await request(endpoint: "/getReadingHistory")
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let books = result["data"] as? [[String: Any]] else {
            return []
        }
        return books.compactMap { dict -> BookInfoResponse? in
            guard let bookUrl = dict["bookUrl"] as? String else { return nil }
            return BookInfoResponse(
                name: dict["name"] as? String ?? "",
                author: dict["author"] as? String ?? "",
                bookUrl: bookUrl,
                sourceUrl: parseBookSourceUrl(from: dict),
                coverUrl: dict["coverUrl"] as? String,
                intro: dict["intro"] as? String,
                kind: dict["kind"] as? String,
                latestChapter: dict["lastChapterTitle"] as? String,
                tocUrl: parseBookTocUrl(from: dict),
                wordCount: nil,
                chapterCount: dict["totalChapterNum"] as? Int,
                type: dict["type"] as? Int ?? 0,
                durChapterIndex: dict["durChapterIndex"] as? Int ?? 0,
                durChapterPos: dict["durChapterPos"] as? Int ?? 0,
                durChapterTime: dict["durChapterTime"] as? Int64 ?? 0,
                totalChapterNum: dict["totalChapterNum"] as? Int ?? 0
            )
        }
    }
    
    // MARK: - User Config
    
    func getUserConfig() async throws -> [String: Any] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getUserConfig()
        }
        let data = try await request(endpoint: "/getUserConfig")
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = result["data"] as? [String: Any] else {
            return [:]
        }
        return config
    }
    
    func saveUserConfig(_ config: [String: Any]) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.saveUserConfig(config)
            return
        }
        _ = try await request(endpoint: "/saveUserConfig", method: "POST", body: config)
    }
    
    // MARK: - Book Config
    
    func getBookConfig(bookUrl: String) async throws -> [String: Any] {
        if !BookParseManager.shared.isServerMode {
            return try await localAPI.getBookConfig(bookUrl: bookUrl)
        }
        let data = try await request(endpoint: "/getBookConfig", method: "POST", body: ["url": bookUrl])
        
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = result["data"] as? [String: Any] else {
            return [:]
        }
        return config
    }
    
    func saveBookConfig(bookUrl: String, config: [String: Any]) async throws {
        if !BookParseManager.shared.isServerMode {
            try await localAPI.saveBookConfig(bookUrl: bookUrl, config: config)
            return
        }
        var body = config
        body["url"] = bookUrl
        _ = try await request(endpoint: "/saveBookConfig", method: "POST", body: body)
    }
}

// MARK: - Response Models

struct SourceDiagnosticRecord: Codable {
    let key: String
    let endpoint: String
    let sourceUrl: String
    let bookUrl: String
    let chapterUrl: String?
    let reason: String
    var failureCount: Int
    let firstFailedAt: TimeInterval
    var lastFailedAt: TimeInterval
    var lastError: String?
    var requestBodyPreview: String?
    var responsePreview: String?
}

struct RssSourceResponse {
    let url: String
    let title: String
    let group: String?
    let enabled: Bool
    let header: String?
    let ruleFindUrl: String?
    let ruleList: String?
    let ruleTitle: String?
    let ruleContent: String?
    let ruleImage: String?
    let ruleLink: String?
    let rulePubDate: String?
}

struct RssArticleResponse {
    let title: String
    let url: String
    let author: String?
    let content: String?
    let pubDate: String?
    let imageUrl: String?
}

struct BookGroupResponse {
    let id: Int64
    let name: String
    let bookCount: Int
}

struct ReplaceRuleResponse {
    let id: Int
    let name: String
    let rule: String
    let replacement: String
    let enabled: Bool
    let order: Int
}

// MARK: - Response Models

struct LoginResponse: Codable {
    let ok: Bool?
    let token: String?
    let msg: String?
    let isSuccess: Bool?
    let errorMsg: String?
}

struct UserInfo: Codable {
    let username: String
    let nickName: String?
    let userName: String?
    let nickname: String?
    
    var displayName: String {
        return nickName ?? userName ?? nickname ?? username
    }
}

struct BookSourceResponse {
    let bookSourceUrl: String
    let bookSourceName: String
    let bookSourceGroup: String?
    let enabled: Bool
    let exploreUrl: String?
    let searchUrl: String?
    let header: String?
    let ruleSearch: String?
    let ruleExplore: String?
    let ruleBookInfo: String?
    let ruleToc: String?
    let ruleContent: String?
}

struct BookInfoResponse {
    let name: String
    let author: String
    let bookUrl: String
    let sourceUrl: String?
    let coverUrl: String?
    let intro: String?
    let kind: String?
    let latestChapter: String?
    let tocUrl: String?
    let wordCount: String?
    let chapterCount: Int?
    let type: Int
    var originName: String? = nil
    var durChapterIndex: Int = 0
    var durChapterPos: Int = 0
    var durChapterTime: Int64 = 0
    var totalChapterNum: Int = 0
}

struct ChapterResponse {
    let title: String
    let url: String
    let index: Int
    let isVip: Bool
    let isPay: Bool
}

enum ServerError: Error {
    case invalidURL
    case invalidResponse
    case unauthorized
    case httpError(statusCode: Int)
    case decodingError
    
    var localizedDescription: String {
        switch self {
        case .invalidURL: return "无效的URL"
        case .invalidResponse: return "服务器响应无效"
        case .unauthorized: return "请先登录"
        case .httpError(let code): return "HTTP错误: \(code)"
        case .decodingError: return "数据解析失败"
        }
    }
}

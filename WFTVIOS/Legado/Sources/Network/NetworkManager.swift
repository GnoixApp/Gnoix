import Foundation

class NetworkManager {
    static let shared = NetworkManager()

    private var session: URLSession = URLSession(configuration: .default)
    private var cookieStorage: [String: [String: String]] = [:]
    private let cookieStorageLock = NSLock()
    private let maxRetries = 3
    private let retryDelay: UInt64 = 1_000_000_000
    private final class RedirectControlDelegate: NSObject, URLSessionTaskDelegate {
        let followRedirects: Bool

        init(followRedirects: Bool) {
            self.followRedirects = followRedirects
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(followRedirects ? request : nil)
        }
    }

    private init() {
        rebuildSession(protocolClasses: nil)
    }

    private func rebuildSession(protocolClasses: [AnyClass]?) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.waitsForConnectivity = true
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: config)
    }

    // Test hook: allows injecting URLProtocol subclasses for deterministic network stubbing.
    func setProtocolClassesForTesting(_ protocolClasses: [AnyClass]?) {
        rebuildSession(protocolClasses: protocolClasses)
    }

    func fetch(url: String, headers: [String: String]? = nil, retries: Int? = nil, charset: String? = nil) async throws -> String {
        try await request(url: url, method: "GET", headers: headers, body: nil, retries: retries, charset: charset)
    }

    func request(
        url: String,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: String? = nil,
        retries: Int? = nil,
        charset: String? = nil
    ) async throws -> String {
        let detailed = try await requestDetailed(
            url: url,
            method: method,
            headers: headers,
            body: body,
            retries: retries,
            charset: charset,
            allowNon200: false
        )
        return detailed.body
    }

    func requestDetailed(
        url: String,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: String? = nil,
        retries: Int? = nil,
        charset: String? = nil,
        allowNon200: Bool = false,
        timeout: TimeInterval? = nil,
        followRedirects: Bool = true
    ) async throws -> NetworkResponse {
        let maxAttempts = retries ?? maxRetries
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await requestOnceDetailed(
                    url: url,
                    method: method,
                    headers: headers,
                    body: body,
                    charset: charset,
                    allowNon200: allowNon200,
                    timeout: timeout,
                    followRedirects: followRedirects
                )
            } catch let error as NetworkError {
                lastError = error
                if !shouldRetry(error: error), attempt == maxAttempts {
                    throw error
                }
            } catch let urlError as URLError {
                lastError = urlError
                if !shouldRetry(urlError: urlError), attempt == maxAttempts {
                    throw urlError
                }
            } catch {
                lastError = error
                if attempt == maxAttempts {
                    throw error
                }
            }

            if attempt < maxAttempts {
                let delay = retryDelay * UInt64(attempt)
                try await Task.sleep(nanoseconds: delay)
            }
        }

        throw lastError ?? NetworkError.unknown
    }

    private func requestOnceDetailed(
        url: String,
        method: String,
        headers: [String: String]?,
        body: String?,
        charset: String?,
        allowNon200: Bool,
        timeout: TimeInterval?,
        followRedirects: Bool
    ) async throws -> NetworkResponse {
        guard let requestUrl = URL(string: url) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = method.uppercased()
        if let timeout, timeout > 0 {
            request.timeoutInterval = timeout
        }

        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let host = requestUrl.host {
            let cookies = cookiesForHost(host)
            if !cookies.isEmpty {
                let cookieString = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
                request.setValue(cookieString, forHTTPHeaderField: "Cookie")
            }
        }

        if request.httpMethod == "POST" {
            applyRequestBody(body, to: &request)
        }

        let redirectDelegate = RedirectControlDelegate(followRedirects: followRedirects)
        let (data, response) = try await session.data(for: request, delegate: redirectDelegate)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        if !allowNon200, httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
            throw NetworkError.httpError(statusCode: httpResponse.statusCode)
        }

        let bodyText = decodeResponseString(data: data, response: httpResponse, forcedCharset: charset)
        var mappedHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            guard let key = key as? String else { continue }
            mappedHeaders[key] = "\(value)"
        }
        let finalURL = httpResponse.url?.absoluteString ?? url
        return NetworkResponse(
            url: finalURL,
            statusCode: httpResponse.statusCode,
            headers: mappedHeaders,
            body: bodyText
        )
    }

    private func applyRequestBody(_ body: String?, to request: inout URLRequest) {
        guard let body, !body.isEmpty else { return }

        let contentType = request.value(forHTTPHeaderField: "Content-Type")?.lowercased()

        if let contentType, !contentType.isEmpty {
            request.httpBody = body.data(using: .utf8)
            return
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = trimmed.data(using: .utf8)
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data(using: .utf8)
        }
    }

    private func decodeResponseString(data: Data, response: HTTPURLResponse, forcedCharset: String?) -> String {
        var candidateCharsets: [String] = []
        if let forcedCharset, !forcedCharset.isEmpty {
            candidateCharsets.append(forcedCharset)
        }
        if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           let range = contentType.range(of: "charset=") {
            let charset = String(contentType[range.upperBound...]).components(separatedBy: ";").first ?? ""
            if !charset.isEmpty {
                candidateCharsets.append(charset)
            }
        }

        candidateCharsets.append(contentsOf: ["utf-8", "gb18030", "gbk", "gb2312"])

        for charset in candidateCharsets {
            if let encoding = stringEncoding(from: charset),
               let responseString = String(data: data, encoding: encoding) {
                return responseString
            }
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func stringEncoding(from charset: String) -> String.Encoding? {
        let normalized = charset
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")

        switch normalized {
        case "utf8", "utf-8":
            return .utf8
        case "gb18030", "gbk", "gb2312":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        case "big5":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5.rawValue)
                )
            )
        default:
            return nil
        }
    }

    private func shouldRetry(error: NetworkError) -> Bool {
        switch error {
        case .httpError(let statusCode):
            return statusCode >= 500
        default:
            return true
        }
    }

    private func shouldRetry(urlError: URLError) -> Bool {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    func post(url: String, body: [String: String]?, headers: [String: String]? = nil) async throws -> String {
        let bodyString = body?.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")

        var mergedHeaders = headers ?? [:]
        if mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        }

        return try await request(url: url, method: "POST", headers: mergedHeaders, body: bodyString)
    }

    func downloadData(url: String) async throws -> Data {
        guard let requestUrl = URL(string: url) else {
            throw NetworkError.invalidURL
        }

        let (data, _) = try await session.data(from: requestUrl)
        return data
    }

    func saveCookies(from url: String, cookies: [String: String]) {
        guard let host = URL(string: url)?.host else { return }
        cookieStorageLock.lock()
        cookieStorage[host] = cookies
        cookieStorageLock.unlock()
    }

    func getCookies(for url: String) -> [String: String] {
        guard let host = URL(string: url)?.host else { return [:] }
        return cookiesForHost(host)
    }

    func clearCookies() {
        cookieStorageLock.lock()
        cookieStorage.removeAll()
        cookieStorageLock.unlock()
    }

    private func cookiesForHost(_ host: String) -> [String: String] {
        cookieStorageLock.lock()
        let cookies = cookieStorage[host] ?? [:]
        cookieStorageLock.unlock()
        return cookies
    }
}

struct NetworkResponse {
    let url: String
    let statusCode: Int
    let headers: [String: String]
    let body: String
}

enum NetworkError: Error {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError
    case unknown
}

import Foundation
import XCTest
import SwiftSoup
import ZIPFoundation
@testable import WFIOS

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            let error = NSError(domain: "MockURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No handler configured"])
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class WFTVIOSTests: XCTestCase {
    private struct SourceProbe {
        let name: String
        let url: String
        let header: String?
        let searchUrl: String?
        let searchListRule: String?
        let raw: String
    }

    private struct ProbeRunResult {
        let source: SourceProbe
        let ok: Bool
        let category: String
        let statusCode: Int?
        let elementCount: Int
        let durationMs: Int
        let message: String
    }

    override func setUp() {
        super.setUp()
        NetworkManager.shared.setProtocolClassesForTesting([MockURLProtocol.self])
        BookParseManager.shared.mode = .local
        RuleAnalyzer.shared.resetVariables()
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        NetworkManager.shared.setProtocolClassesForTesting(nil)
        RuleAnalyzer.shared.resetVariables()
        super.tearDown()
    }

    private func bodyString(from request: URLRequest?) -> String {
        guard let request else { return "" }
        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            return bodyString
        }
        guard let stream = request.httpBodyStream else { return "" }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount > 0 {
                data.append(buffer, count: readCount)
            } else {
                break
            }
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func addZipEntry(archive: Archive, path: String, data: Data) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            let end = min(start + size, data.count)
            return data.subdata(in: start..<end)
        }
    }

    private func valueAsString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func loadSourceProbes(from data: Data) throws -> [SourceProbe] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { item in
            let name = valueAsString(item["bookSourceName"]) ?? "未命名书源"
            let url = valueAsString(item["bookSourceUrl"]) ?? ""
            let header = valueAsString(item["header"])
            let searchUrl = valueAsString(item["searchUrl"])
            let searchRule = item["ruleSearch"] as? [String: Any]
            let searchListRule = valueAsString(searchRule?["bookList"])
            guard let rawData = try? JSONSerialization.data(withJSONObject: item),
                  let raw = String(data: rawData, encoding: .utf8) else {
                return nil
            }
            return SourceProbe(
                name: name,
                url: url,
                header: header,
                searchUrl: searchUrl,
                searchListRule: searchListRule,
                raw: raw
            )
        }
    }

    private func containsPattern(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func containsAnyPattern(_ text: String, patterns: [String]) -> Bool {
        patterns.contains { containsPattern(text, pattern: $0) }
    }

    private func fetchHTML(
        descriptor: RuleRequestDescriptor,
        timeout: TimeInterval = 12
    ) async throws -> (statusCode: Int, body: String) {
        guard let url = URL(string: descriptor.url) else {
            throw NSError(domain: "compat", code: -1, userInfo: [NSLocalizedDescriptionKey: "invalid url"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = descriptor.method
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        descriptor.headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body = descriptor.body, !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, String(data: data, encoding: .utf8) ?? "")
    }

    private func runSearchProbe(_ source: SourceProbe, keyword: String) async -> ProbeRunResult {
        let started = Date()
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty,
              let listRule = source.searchListRule, !listRule.isEmpty else {
            return ProbeRunResult(
                source: source,
                ok: false,
                category: "no_rule",
                statusCode: nil,
                elementCount: 0,
                durationMs: 0,
                message: "缺少 searchUrl 或 ruleSearch.bookList"
            )
        }

        do {
            let descriptor = RuleURLRequestBuilder.build(
                ruleUrl: searchUrl,
                baseUrl: source.url,
                keyword: keyword,
                page: 1,
                defaultHeaders: RuleURLRequestBuilder.parseHeaderMap(source.header),
                sourceKey: source.url,
                sourceHeader: source.header,
                sourceComment: nil,
                sourceName: source.name
            )

            if descriptor.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let duration = Int(Date().timeIntervalSince(started) * 1000)
                return ProbeRunResult(
                    source: source,
                    ok: false,
                    category: "empty_url",
                    statusCode: nil,
                    elementCount: 0,
                    durationMs: duration,
                    message: "构建后的请求 URL 为空"
                )
            }

            let response = try await fetchHTML(descriptor: descriptor)
            let status = response.statusCode
            guard (200...299).contains(status) else {
                let duration = Int(Date().timeIntervalSince(started) * 1000)
                return ProbeRunResult(
                    source: source,
                    ok: false,
                    category: "http_error",
                    statusCode: status,
                    elementCount: 0,
                    durationMs: duration,
                    message: "HTTP \(status)"
                )
            }

            let elements = try RuleAnalyzer.shared.analyzeList(html: response.body, rule: listRule, baseUrl: descriptor.url)
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            if elements.isEmpty {
                return ProbeRunResult(
                    source: source,
                    ok: false,
                    category: "empty_list",
                    statusCode: status,
                    elementCount: 0,
                    durationMs: duration,
                    message: "解析完成但列表为空"
                )
            }
            return ProbeRunResult(
                source: source,
                ok: true,
                category: "ok",
                statusCode: status,
                elementCount: elements.count,
                durationMs: duration,
                message: "success"
            )
        } catch {
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            return ProbeRunResult(
                source: source,
                ok: false,
                category: "request_error",
                statusCode: nil,
                elementCount: 0,
                durationMs: duration,
                message: error.localizedDescription
            )
        }
    }

    func testLocalParserChainWithRuleUrlPostOption() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let searchEndpoint = "https://mock.reader/search"

        let searchRule = SearchRule(
            bookList: ".item",
            name: ".name@text",
            author: ".author@text",
            intro: ".intro@text",
            coverUrl: ".cover@src",
            bookUrl: "a@href",
            kind: ".kind@text",
            wordCount: nil,
            lastChapter: ".latest@text",
            checkKeyWord: nil
        )
        let infoRule = BookInfoRule(
            name: "h1@text",
            author: ".author@text",
            intro: ".intro@text",
            coverUrl: ".cover@src",
            tocUrl: ".toc@href",
            kind: ".kind@text",
            lastChapter: ".latest@text",
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: ".content@text",
            title: "h2@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: "\(searchEndpoint),{\"method\":\"POST\",\"headers\":{\"X-Test\":\"1\"},\"body\":\"kw={{key}}\"}",
            header: "{\"X-Source\":\"local\"}",
            ruleSearch: String(data: try JSONEncoder().encode(searchRule), encoding: .utf8),
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )

        try await api.saveBookSource(sourceResponse)

        let requestQueue = DispatchQueue(label: "wftvios.tests.request.queue")
        var capturedRequests: [URLRequest] = []

        MockURLProtocol.handler = { request in
            requestQueue.sync {
                capturedRequests.append(request)
            }

            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let path = url.path
            let html: String
            if path == "/search" {
                html = """
                <html><body>
                <div class='item'>
                  <a href='/book/1'>详情</a>
                  <span class='name'>三体</span>
                  <span class='author'>刘慈欣</span>
                  <span class='intro'>科幻经典</span>
                  <img class='cover' src='/cover.jpg' />
                  <span class='kind'>科幻</span>
                  <span class='latest'>第三部</span>
                </div>
                </body></html>
                """
            } else if path == "/book/1" {
                html = """
                <html><body>
                  <h1>三体</h1>
                  <span class='author'>刘慈欣</span>
                  <div class='intro'>地球往事三部曲</div>
                  <img class='cover' src='/cover.jpg' />
                  <a class='toc' href='/book/1/toc'>目录</a>
                  <span class='kind'>科幻</span>
                  <span class='latest'>第三部</span>
                </body></html>
                """
            } else if path == "/book/1/toc" {
                html = """
                <html><body>
                  <div class='chapter'><a href='/book/1/c1'>第一章</a><span class='name'>第一章</span></div>
                  <div class='chapter'><a href='/book/1/c2'>第二章</a><span class='name'>第二章</span></div>
                </body></html>
                """
            } else if path == "/book/1/c1" {
                html = """
                <html><body>
                  <h2>第一章</h2>
                  <div class='content'>地球往事开始。</div>
                </body></html>
                """
            } else if path == "/book/1/c2" {
                html = """
                <html><body>
                  <h2>第二章</h2>
                  <div class='content'>故事继续。</div>
                </body></html>
                """
            } else {
                html = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let searchResults = try await api.search(keyword: "三体", page: 1, bookSourceUrl: sourceURL)
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(searchResults.first?.name, "三体")
        XCTAssertEqual(searchResults.first?.author, "刘慈欣")

        guard let first = searchResults.first else {
            XCTFail("missing search result")
            return
        }

        let info = try await api.getBookInfo(bookUrl: first.bookUrl, sourceUrl: sourceURL)
        XCTAssertEqual(info.name, "三体")
        XCTAssertEqual(info.author, "刘慈欣")
        XCTAssertTrue((info.tocUrl ?? "").contains("/book/1/toc"))

        let chapters = try await api.getChapterList(bookUrl: info.bookUrl, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters.first?.title, "第一章")

        let content = try await api.getChapterContent(
            bookUrl: info.bookUrl,
            sourceUrl: sourceURL,
            chapterUrl: chapters[0].url,
            index: 0
        )
        XCTAssertTrue(content.content.contains("地球往事"))

        let searchRequest = requestQueue.sync {
            capturedRequests.first { $0.url?.path == "/search" }
        }

        XCTAssertEqual(searchRequest?.httpMethod, "POST")
        XCTAssertEqual(searchRequest?.value(forHTTPHeaderField: "X-Test"), "1")
        XCTAssertEqual(searchRequest?.value(forHTTPHeaderField: "X-Source"), "local")
        let searchBody = bodyString(from: searchRequest)
        let decodedBody = searchBody.removingPercentEncoding ?? searchBody
        XCTAssertTrue(decodedBody.contains("kw=三体"))

        try await api.removeFromBookshelf(bookUrl: info.bookUrl, sourceUrl: sourceURL)
        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(info.bookUrl)
    }

    func testLocalParserSupportsTocAndContentPagination() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookId = UUID().uuidString.lowercased()
        let bookUrl = "https://mock.reader/\(bookId)"

        let infoRule = BookInfoRule(
            name: "h1@text",
            author: ".author@text",
            intro: ".intro@text",
            coverUrl: nil,
            tocUrl: ".toc@href",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: ".next@href",
            isVip: ".vip@text",
            preUpdateJs: nil,
            updateTime: ".ut@text"
        )
        let contentRule = ContentRule(
            content: ".content@text",
            title: "h2@text",
            nextContentUrl: ".next-page@href",
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Paging Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )

        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let path = url.path
            let html: String
            if path == "/\(bookId)" {
                html = """
                <html><body>
                  <h1>分页测试书</h1>
                  <span class='author'>测试作者</span>
                  <div class='intro'>测试目录与正文分页</div>
                  <a class='toc' href='/\(bookId)/toc-1'>目录</a>
                </body></html>
                """
            } else if path == "/\(bookId)/toc-1" {
                html = """
                <html><body>
                  <div class='chapter'>
                    <a href='/\(bookId)/c1'>第一章</a>
                    <span class='name'>第一章</span>
                    <span class='vip'>false</span>
                    <span class='ut'>2026-03-23</span>
                  </div>
                  <a class='next' href='/\(bookId)/toc-2'>下一页</a>
                </body></html>
                """
            } else if path == "/\(bookId)/toc-2" {
                html = """
                <html><body>
                  <div class='chapter'>
                    <a href='/\(bookId)/c2'>第二章</a>
                    <span class='name'>第二章</span>
                    <span class='vip'>true</span>
                    <span class='ut'>2026-03-24</span>
                  </div>
                </body></html>
                """
            } else if path == "/\(bookId)/c1" {
                html = """
                <html><body>
                  <h2>第一章</h2>
                  <div class='content'>上半部分</div>
                  <a class='next-page' href='/\(bookId)/c1-2'>下一页</a>
                </body></html>
                """
            } else if path == "/\(bookId)/c1-2" {
                html = """
                <html><body>
                  <h2>第一章</h2>
                  <div class='content'>下半部分</div>
                </body></html>
                """
            } else if path == "/\(bookId)/c2" {
                html = """
                <html><body>
                  <h2>第二章</h2>
                  <div class='content'>第二章正文</div>
                </body></html>
                """
            } else {
                html = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookUrl, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第一章")
        XCTAssertEqual(chapters[1].title, "第二章")
        XCTAssertEqual(chapters[1].isVip, true)

        let firstContent = try await api.getChapterContent(
            bookUrl: bookUrl,
            sourceUrl: sourceURL,
            chapterUrl: chapters[0].url,
            index: 0
        )
        XCTAssertTrue(firstContent.content.contains("上半部分"))
        XCTAssertTrue(firstContent.content.contains("下半部分"))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookUrl)
    }

    func testChapterFlowSanitizesRefererFragmentMarker() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let rawSourceURL = "https://mock.reader/source/\(UUID().uuidString)#🎃"
        let bookURL = "https://mock.reader/book/referer-marker"

        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: "#content@text",
            title: "h1@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )
        let sourceResponse = BookSourceResponse(
            bookSourceUrl: rawSourceURL,
            bookSourceName: "Mock Referer Marker Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        let requestQueue = DispatchQueue(label: "wftvios.tests.referer-marker.queue")
        var capturedRequests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requestQueue.sync {
                capturedRequests.append(request)
            }

            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }
            let html: String
            if url.path == "/book/referer-marker" {
                html = """
                <html><body>
                  <div class='chapter'><a href='/book/referer-marker/c1'>第一章</a><span class='name'>第一章</span></div>
                </body></html>
                """
            } else {
                html = "<html><body><h1>章节</h1><div id='content'>正文</div></body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: rawSourceURL)
        XCTAssertEqual(chapters.count, 1)

        let tocRequest = requestQueue.sync {
            capturedRequests.first { $0.url?.path == "/book/referer-marker" }
        }
        let referer = tocRequest?.value(forHTTPHeaderField: "Referer") ?? ""
        XCTAssertFalse(referer.contains("#"))
        XCTAssertFalse(referer.contains("🎃"))
        XCTAssertTrue(referer.hasPrefix("https://mock.reader/source/"))

        try await api.deleteBookSource(sourceUrl: rawSourceURL)
        db.deleteBook(bookURL)
    }

    func testChapterFlowSkipsGarbageNextTocUrl() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/noisy-next"

        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: #"##href="([^"]+)"[^>]*>下一页<##$1###"#,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: "#content@text",
            title: "h1@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )
        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Noisy Next Toc",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        let requestQueue = DispatchQueue(label: "wftvios.tests.noisy-next.queue")
        var capturedRequests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requestQueue.sync {
                capturedRequests.append(request)
            }

            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            if url.path == "/book/noisy-next" {
                let html = """
                <html><body>
                  <div class='chapter'><a href='/book/noisy-next/c1'>第一章</a><span class='name'>第一章</span></div>
                  <a href="/a/返回 书名：噪声书 分类 状态：连载 作者：测试 章节目录 在线阅读 简介 这是很长很长的一段误匹配文本 继续延长 继续延长 继续延长 继续延长">下一页</a>
                </body></html>
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (response, Data(html.utf8))
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data("<html><body>bad request</body></html>".utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters.first?.title, "第一章")

        let requestCount = requestQueue.sync { capturedRequests.count }
        XCTAssertEqual(requestCount, 1)

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testContentKeepsFetchedPageWhenNextPageReturns404() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/content-partial-\(UUID().uuidString)"

        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: ".content@text",
            title: "h1@text",
            nextContentUrl: ".next-page@href",
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )
        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Partial Content Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            if url.path == "/book/toc" {
                let html = """
                <html><body>
                  <div class='chapter'>
                    <a href='/chapter/1'>第一章</a>
                    <span class='name'>第一章</span>
                  </div>
                </body></html>
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (response, Data(html.utf8))
            }

            if url.path == "/chapter/1" {
                let html = """
                <html><body>
                  <h1>第一章</h1>
                  <div class='content'>第一页正文</div>
                  <a class='next-page' href='/chapter/1-2'>下一页</a>
                </body></html>
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (response, Data(html.utf8))
            }

            if url.path == "/chapter/1-2" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (response, Data("not found".utf8))
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data("<html><body></body></html>".utf8))
        }

        let chapter = ChapterResponse(title: "第一章", url: "https://mock.reader/chapter/1", index: 0, isVip: false, isPay: false)
        db.deleteChapters(forBookUrl: bookURL)
        var chapterRecord = BookChapter()
        chapterRecord.url = chapter.url
        chapterRecord.title = chapter.title
        chapterRecord.index = 0
        chapterRecord.bookUrl = bookURL
        db.saveChapters([chapterRecord])

        let content = try await api.getChapterContent(
            bookUrl: bookURL,
            sourceUrl: sourceURL,
            chapterUrl: chapter.url,
            index: 0
        )
        XCTAssertTrue(content.content.contains("第一页正文"))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
        db.deleteChapters(forBookUrl: bookURL)
    }

    func testContentRuleMergesMultipleParagraphNodes() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/content-merge"

        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: ".chapter-content@p@text",
            title: "h1@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )
        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Multi Paragraph Content",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let html: String
            if url.path == "/book/content-merge" {
                html = """
                <html><body>
                  <div class='chapter'><a href='/book/content-merge/c1'>第一章</a><span class='name'>第一章</span></div>
                </body></html>
                """
            } else if url.path == "/book/content-merge/c1" {
                html = """
                <html><body>
                  <h1>第一章</h1>
                  <div class='chapter-content'>
                    <p>第一句。</p>
                    <p>第二句。</p>
                    <p>第三句。</p>
                  </div>
                </body></html>
                """
            } else {
                html = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 1)

        let content = try await api.getChapterContent(
            bookUrl: bookURL,
            sourceUrl: sourceURL,
            chapterUrl: chapters[0].url,
            index: 0
        )
        XCTAssertTrue(content.content.contains("第一句。"))
        XCTAssertTrue(content.content.contains("第二句。"))
        XCTAssertTrue(content.content.contains("第三句。"))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testChapterFlowStopsPagingWhenNoIncrementalChapters() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/duplicate-pages"

        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: "a.next@href",
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: "#content@text",
            title: "h1@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )
        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Duplicate Toc Pages",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        let queue = DispatchQueue(label: "wftvios.tests.duplicate-pages.queue")
        var visitedPaths: [String] = []
        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }
            queue.sync { visitedPaths.append(url.path) }

            let html: String
            switch url.path {
            case "/book/duplicate-pages":
                html = """
                <html><body>
                  <div class='chapter'><a href='/book/duplicate-pages/c1'>第一章</a><span class='name'>第一章</span></div>
                  <div class='chapter'><a href='/book/duplicate-pages/c2'>第二章</a><span class='name'>第二章</span></div>
                  <a class='next' href='/book/duplicate-pages_1'>下一页</a>
                </body></html>
                """
            case "/book/duplicate-pages_1":
                html = """
                <html><body>
                  <div class='chapter'><a href='/book/duplicate-pages/c1'>第一章</a><span class='name'>第一章</span></div>
                  <div class='chapter'><a href='/book/duplicate-pages/c2'>第二章</a><span class='name'>第二章</span></div>
                  <a class='next' href='/book/duplicate-pages_2'>下一页</a>
                </body></html>
                """
            case "/book/duplicate-pages_2":
                html = """
                <html><body>
                  <div class='chapter'><a href='/book/duplicate-pages/c3'>第三章</a><span class='name'>第三章</span></div>
                </body></html>
                """
            default:
                html = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第一章")
        XCTAssertEqual(chapters[1].title, "第二章")

        let paths = queue.sync { visitedPaths }
        XCTAssertTrue(paths.contains("/book/duplicate-pages"))
        XCTAssertTrue(paths.contains("/book/duplicate-pages_1"))
        XCTAssertFalse(paths.contains("/book/duplicate-pages_2"))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testSearchRuleFieldErrorDoesNotBreakWholeResult() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let searchRule = SearchRule(
            bookList: ".item",
            name: ".name@text",
            author: ".author@text",
            intro: ".intro@text",
            coverUrl: nil,
            bookUrl: "a@href",
            kind: "{{$.categoryInfoV4##\\d.*?\\:(.*?)\\:.*?(,|$)##$1$2}}",
            wordCount: nil,
            lastChapter: nil,
            checkKeyWord: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Search Rule Tolerant Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: "/search?kw={{key}}",
            header: nil,
            ruleSearch: String(data: try JSONEncoder().encode(searchRule), encoding: .utf8),
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: nil,
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }
            let body: String
            if url.path == "/search" {
                body = """
                <html><body>
                  <div class='item'>
                    <a href='/book/1337'>详情</a>
                    <span class='name'>术式是嵌合蚁</span>
                    <span class='author'>木头桩子</span>
                    <span class='intro'>测试简介</span>
                  </div>
                </body></html>
                """
            } else {
                body = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(body.utf8))
        }

        let results = try await api.search(keyword: "术式是嵌合蚁", page: 1, bookSourceUrl: sourceURL)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "术式是嵌合蚁")
        XCTAssertEqual(results.first?.author, "木头桩子")
        XCTAssertTrue(results.first?.bookUrl.contains("/book/1337") == true)

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(results.first?.bookUrl ?? "")
    }

    func testSearchBookURLTemplateDoesNotSerializeRequestOptions() async throws {
        let api = LocalReaderAPI.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let searchRule = SearchRule(
            bookList: "$.data[*]",
            name: "$.novelName",
            author: "$.authorName",
            intro: "$.summary",
            coverUrl: nil,
            bookUrl: "/novel/{{$.novelId}}?isSearch=1",
            kind: nil,
            wordCount: nil,
            lastChapter: nil,
            checkKeyWord: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock JSON Search URL Template Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: "/search?page={{page}}&keyword={{key}}",
            header: nil,
            ruleSearch: String(data: try JSONEncoder().encode(searchRule), encoding: .utf8),
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: nil,
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }
            let body: String
            if url.path == "/search" {
                body = """
                {"code":200,"data":[{"novelId":"dBnPpk","novelName":"谍影谜云","authorName":"深蓝的国度","summary":"简介"}]}
                """
            } else {
                body = "{\"code\":404,\"data\":[]}"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            return (response, Data(body.utf8))
        }

        let results = try await api.search(keyword: "谍影谜云", page: 1, bookSourceUrl: sourceURL)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.bookUrl, "https://mock.reader/novel/dBnPpk?isSearch=1")
        XCTAssertFalse(results.first?.bookUrl.contains(",{") == true)

        try await api.deleteBookSource(sourceUrl: sourceURL)
    }

    func testChapterFlowResolvesBookInfoInitTocTemplate() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let initialBookURL = "https://mock.reader/novel?sort=1&page=1&categoryId=penRe7"
        let matchedBookURL = "https://mock.reader/novel/dBnPpk?isSearch=1"
        let expectedTocURL = "https://mock.reader/novel/dBnPpk/chapters?readNum=1"

        let searchRule = SearchRule(
            bookList: "$.data[*]",
            name: "$.novelName",
            author: "$.authorName",
            intro: "$.summary",
            coverUrl: nil,
            bookUrl: "/novel/{{$.novelId}}?isSearch=1",
            kind: nil,
            wordCount: nil,
            lastChapter: nil,
            checkKeyWord: nil
        )
        let infoRule = BookInfoRule(
            name: "$.novelName",
            author: "$.authorName",
            intro: "$.summary",
            coverUrl: nil,
            tocUrl: "/novel/{{$.novelId}}/chapters?readNum=1",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: "$.data"
        )
        let tocRule = TocRule(
            chapterList: "$.data.list[*]",
            chapterName: "$.chapterName",
            chapterUrl: "$.path",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock JMLLDSC Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: "/search?page={{page}}&keyword={{key}}",
            header: nil,
            ruleSearch: String(data: try JSONEncoder().encode(searchRule), encoding: .utf8),
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        let queue = DispatchQueue(label: "wftvios.tests.jmlldsc.toc-template")
        var visited: [String] = []

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }
            queue.sync {
                visited.append(url.absoluteString)
            }

            let body: String
            if url.path == "/novel",
               url.query?.contains("sort=1") == true,
               url.query?.contains("categoryId=penRe7") == true {
                body = """
                {"code":200,"data":[{"novelId":"other","novelName":"其他书","authorName":"路人"},{"novelId":"dBnPpk","novelName":"谍影谜云","authorName":"深蓝的国度"}]}
                """
            } else if url.path == "/search" {
                body = """
                {"code":200,"data":[{"novelId":"dBnPpk","novelName":"谍影谜云","authorName":"深蓝的国度","summary":"简介"}]}
                """
            } else if url.path == "/novel/dBnPpk" {
                body = """
                {"code":200,"data":{"novelId":"dBnPpk","novelName":"谍影谜云","authorName":"深蓝的国度","summary":"简介"}}
                """
            } else if url.path == "/novel/dBnPpk/chapters" {
                body = """
                {"code":200,"data":{"list":[{"chapterName":"第一章","path":"https://mock.reader/read/dBnPpk/1"},{"chapterName":"第二章","path":"https://mock.reader/read/dBnPpk/2"}]}}
                """
            } else {
                body = "{\"code\":404,\"data\":[]}"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            return (response, Data(body.utf8))
        }

        let info = try await api.getBookInfo(bookUrl: matchedBookURL, sourceUrl: sourceURL)
        XCTAssertEqual(info.tocUrl, expectedTocURL)

        let chapters = try await api.getChapterList(
            bookUrl: initialBookURL,
            sourceUrl: sourceURL,
            bookNameHint: "谍影谜云",
            authorHint: "深蓝的国度"
        )
        XCTAssertEqual(chapters.count, 2)
        guard chapters.count >= 2 else {
            XCTFail("expected 2 chapters, got \(chapters.count)")
            try await api.deleteBookSource(sourceUrl: sourceURL)
            db.deleteBook(initialBookURL)
            db.deleteBook(matchedBookURL)
            return
        }
        XCTAssertEqual(chapters[0].title, "第一章")
        XCTAssertEqual(chapters[1].title, "第二章")

        let visitedRequests = queue.sync { visited }
        XCTAssertTrue(visitedRequests.contains(where: { $0.contains("/search?") }))
        XCTAssertTrue(visitedRequests.contains(where: { $0.contains("/novel/dBnPpk/chapters?readNum=1") }))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(initialBookURL)
        db.deleteBook(matchedBookURL)
    }

    func testTocChapterUrlRequestTemplateWithJsonPlaceholder() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/abc"

        let infoRule = BookInfoRule(
            name: "h1@text",
            author: ".author@text",
            intro: ".intro@text",
            coverUrl: nil,
            tocUrl: ".toc@href",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: "@Json:$.data.chapters[*]",
            chapterName: "@Json:$.title",
            chapterUrl: "https://mock.reader/api/chapter,{\"method\":\"POST\",\"headers\":{\"X-Req\":\"1\"},\"body\":{\"bookId\":\"{{baseUrl.match(/book\\/(\\w+)\\/toc/)[1]}}\",\"serial\":\"{{$.serialID}}\"}}",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: "@Json:$.data.content",
            title: "@Json:$.data.title",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Toc Request Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        let requestQueue = DispatchQueue(label: "wftvios.tests.chapter-template.queue")
        var capturedRequests: [URLRequest] = []

        MockURLProtocol.handler = { request in
            requestQueue.sync {
                capturedRequests.append(request)
            }

            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let responseBody: String
            switch url.path {
            case "/book/abc":
                responseBody = """
                <html><body>
                  <h1>模板目录测试</h1>
                  <span class='author'>测试作者</span>
                  <a class='toc' href='/book/abc/toc'>目录</a>
                </body></html>
                """
            case "/book/abc/toc":
                responseBody = """
                {"data":{"chapters":[{"title":"第一章","serialID":"101"},{"title":"第二章","serialID":"102"}]}}
                """
            case "/api/chapter":
                let body = self.bodyString(from: request)
                let decoded = body.removingPercentEncoding ?? body
                let serial = decoded.contains("\"serial\":\"102\"") ? "102" : "101"
                responseBody = """
                {"data":{"title":"第\(serial)章","content":"正文\(serial)"}}
                """
            default:
                responseBody = "{}"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            return (response, Data(responseBody.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第一章")
        XCTAssertTrue(chapters[0].url.contains("/api/chapter"))

        let content = try await api.getChapterContent(
            bookUrl: bookURL,
            sourceUrl: sourceURL,
            chapterUrl: chapters[0].url,
            index: 0
        )
        XCTAssertTrue(content.content.contains("正文101"))

        let chapterRequest = requestQueue.sync {
            capturedRequests.first { $0.url?.path == "/api/chapter" }
        }
        XCTAssertEqual(chapterRequest?.httpMethod, "POST")
        XCTAssertEqual(chapterRequest?.value(forHTTPHeaderField: "X-Req"), "1")
        let chapterBody = bodyString(from: chapterRequest)
        let decodedBody = chapterBody.removingPercentEncoding ?? chapterBody
        XCTAssertTrue(decodedBody.contains("\"bookId\":\"abc\""))
        XCTAssertTrue(decodedBody.contains("\"serial\":\"101\""))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testChapterFlowRecoversDetailUrlFromRankListBeforeRefreshingBookInfo() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://bookshelf.html5.qq.com/mock-\(UUID().uuidString)"
        let initialBookURL = "https://bookshelf.html5.qq.com/qbread/api/rank/list?groupid=1504&start=1&count=20&sub=%E7%A5%9E%E8%AF%9D%E4%BF%AE%E7%9C%9F"

        let exploreRule = ExploreRule(
            bookList: "$.rows[*]",
            name: "$.resourceName",
            author: "$.author",
            intro: nil,
            coverUrl: nil,
            bookUrl: "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid={{$.resourceID}}",
            kind: nil,
            wordCount: nil,
            lastChapter: nil
        )
        let infoRule = BookInfoRule(
            name: "$.resourceName",
            author: "$.author",
            intro: nil,
            coverUrl: nil,
            tocUrl: "https://bookshelf.html5.qq.com/qbread/api/book/all-chapter?bookId={{$.resourceID}}",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: "$.data.bookInfo"
        )
        let tocRule = TocRule(
            chapterList: "$.rows[*]",
            chapterName: "$.serialName",
            chapterUrl: "https://bookshelf.html5.qq.com/qbread/read/{{$.serialID}}",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock QQ Rank Recovery Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: String(data: try JSONEncoder().encode(exploreRule), encoding: .utf8),
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        let queue = DispatchQueue(label: "wftvios.tests.qq-rank-recover")
        var visited: [String] = []

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            queue.sync {
                visited.append(url.absoluteString)
            }

            let body: String
            if url.path == "/qbread/api/rank/list" {
                body = """
                {"rows":[{"resourceID":"111","resourceName":"别的书","author":"路人"},{"resourceID":"123456","resourceName":"从杀猪开始修仙","author":"张老西"}]}
                """
            } else if url.path == "/qbread/api/novel/intro-info", url.query?.contains("bookid=123456") == true {
                body = """
                {"data":{"bookInfo":{"resourceID":"123456","resourceName":"从杀猪开始修仙","author":"张老西"}}}
                """
            } else if url.path == "/qbread/api/book/all-chapter", url.query?.contains("bookId=123456") == true {
                body = """
                {"rows":[{"serialName":"第一章","serialID":"1"},{"serialName":"第二章","serialID":"2"}]}
                """
            } else if url.path == "/qbread/api/book/all-chapter" {
                body = """
                {"ret":422,"code":422,"message":"Validation Failed","data":{"code":"invalid_param","errors":[{"field":"bookId","message":"should not be empty"}]}}
                """
            } else {
                body = "{}"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            return (response, Data(body.utf8))
        }

        let chapters = try await api.getChapterList(
            bookUrl: initialBookURL,
            sourceUrl: sourceURL,
            bookNameHint: "从杀猪开始修仙",
            authorHint: "张老西"
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters.first?.title, "第一章")
        XCTAssertEqual(chapters.last?.title, "第二章")

        let visitedRequests = queue.sync { visited }
        XCTAssertTrue(visitedRequests.contains(where: { $0.contains("/qbread/api/novel/intro-info?bookid=123456") }))
        XCTAssertTrue(visitedRequests.contains(where: { $0.contains("/qbread/api/book/all-chapter?bookId=123456") }))
        XCTAssertFalse(
            visitedRequests.contains(where: {
                $0.range(of: #"/qbread/api/book/all-chapter\?bookId=(?:$|&)"#, options: .regularExpression) != nil
            })
        )

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(initialBookURL)
    }

    func testChapterFlowSearchRecoverySkipsInvalidNanBookIdCandidate() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://bookshelf.html5.qq.com"
        let initialBookURL = "https://bookshelf.html5.qq.com/qbread/api/rank/list?groupid=1502&start=1&count=20&sub=%E5%8F%B2%E8%AF%97%E5%A5%87%E5%B9%BB"

        let searchRule = SearchRule(
            bookList: "$.booklist[*]",
            name: "$.title",
            author: "$.author",
            intro: nil,
            coverUrl: nil,
            bookUrl: "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid={{$.bid}}",
            kind: nil,
            wordCount: nil,
            lastChapter: nil,
            checkKeyWord: nil
        )
        let infoRule = BookInfoRule(
            name: "$.resourceName",
            author: "$.author",
            intro: nil,
            coverUrl: nil,
            tocUrl: "https://bookshelf.html5.qq.com/qbread/api/book/all-chapter?bookId={{$.resourceID}}",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: "$.data.bookInfo"
        )
        let tocRule = TocRule(
            chapterList: "$.rows[*]",
            chapterName: "$.serialName",
            chapterUrl: "https://bookshelf.html5.qq.com/qbread/read/{{$.serialID}}",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock QQ Search Recovery Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: "https://newopensearch.reader.qq.com/wechat?keyword={{key}}&start={{page-1}}&end=19",
            header: nil,
            ruleSearch: String(data: try JSONEncoder().encode(searchRule), encoding: .utf8),
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        let queue = DispatchQueue(label: "wftvios.tests.qq-search-recover")
        var visited: [String] = []

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }
            queue.sync {
                visited.append(url.absoluteString)
            }

            let body: String
            if url.host == "newopensearch.reader.qq.com", url.path == "/wechat" {
                body = """
                {"booklist":[
                    {"title":"掌控时光之龙","author":"唐宋元明氢","bid":"nan"},
                    {"title":"掌控时光之龙","author":"唐宋元明氢","bid":"98765"}
                ]}
                """
            } else if url.path == "/qbread/api/rank/list" {
                body = """
                {"rows":[{"resourceID":"111","resourceName":"别的书","author":"路人"}]}
                """
            } else if url.path == "/qbread/api/novel/intro-info", url.query?.contains("bookid=98765") == true {
                body = """
                {"data":{"bookInfo":{"resourceID":"98765","resourceName":"掌控时光之龙","author":"唐宋元明氢"}}}
                """
            } else if url.path == "/qbread/api/novel/intro-info", url.query?.contains("bookid=nan") == true {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json; charset=utf-8"]
                )!
                return (response, Data("{\"code\":500}".utf8))
            } else if url.path == "/qbread/api/book/all-chapter", url.query?.contains("bookId=98765") == true {
                body = """
                {"rows":[{"serialName":"第一章","serialID":"1"},{"serialName":"第二章","serialID":"2"}]}
                """
            } else {
                body = "{}"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            return (response, Data(body.utf8))
        }

        let chapters = try await api.getChapterList(
            bookUrl: initialBookURL,
            sourceUrl: sourceURL,
            bookNameHint: "掌控时光之龙",
            authorHint: "唐宋元明氢"
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters.first?.title, "第一章")
        XCTAssertEqual(chapters.last?.title, "第二章")

        let visitedRequests = queue.sync { visited }
        XCTAssertFalse(visitedRequests.contains(where: { $0.contains("bookid=nan") }))
        XCTAssertTrue(visitedRequests.contains(where: { $0.contains("bookid=98765") }))
        XCTAssertTrue(visitedRequests.contains(where: { $0.contains("bookId=98765") }))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(initialBookURL)
    }

    func testChapterFlowSearchRecoverySupportsMultilineJsBookUrlRule() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://bookshelf.html5.qq.com"
        let initialBookURL = "https://bookshelf.html5.qq.com/qbread/api/rank/list?groupid=1501&start=1&count=20&sub=%E9%AB%98%E6%AD%A6%E4%B8%96%E7%95%8C"

        let searchRule = SearchRule(
            bookList: "$.booklist[*]",
            name: "$.title",
            author: "$.author",
            intro: nil,
            coverUrl: nil,
            bookUrl: """
            $.bid
            <js>1100000000+parseInt(result)</js>
            https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid={{result}}
            """,
            kind: nil,
            wordCount: nil,
            lastChapter: nil,
            checkKeyWord: nil
        )
        let infoRule = BookInfoRule(
            name: "$.resourceName",
            author: "$.author",
            intro: nil,
            coverUrl: nil,
            tocUrl: "https://bookshelf.html5.qq.com/qbread/api/book/all-chapter?bookId={{$.resourceID}}",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: "$.data.bookInfo"
        )
        let tocRule = TocRule(
            chapterList: "$.rows[*]",
            chapterName: "$.serialName",
            chapterUrl: "https://bookshelf.html5.qq.com/qbread/read/{{$.serialID}}",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock QQ Multiline JS Search Recovery Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: "https://newopensearch.reader.qq.com/wechat?keyword={{key}}&start={{page-1}}&end=19",
            header: nil,
            ruleSearch: String(data: try JSONEncoder().encode(searchRule), encoding: .utf8),
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        let queue = DispatchQueue(label: "wftvios.tests.qq-search-recover.multiline")
        var visited: [String] = []

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }
            queue.sync {
                visited.append(url.absoluteString)
            }

            let body: String
            if url.host == "newopensearch.reader.qq.com", url.path == "/wechat" {
                body = """
                {"booklist":[
                    {"title":"从玄君七章开始","author":"衔雨","bid":"42536692"}
                ]}
                """
            } else if url.path == "/qbread/api/rank/list" {
                body = """
                {"rows":[{"resourceID":"111","resourceName":"别的书","author":"路人"}]}
                """
            } else if url.path == "/qbread/api/novel/intro-info", url.query?.contains("bookid=1142536692") == true {
                body = """
                {"data":{"bookInfo":{"resourceID":"1142536692","resourceName":"从玄君七章开始","author":"衔雨"}}}
                """
            } else if url.path == "/qbread/api/novel/intro-info", url.query?.contains("bookid=nan") == true {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json; charset=utf-8"]
                )!
                return (response, Data("{\"code\":500}".utf8))
            } else if url.path == "/qbread/api/book/all-chapter", url.query?.contains("bookId=1142536692") == true {
                body = """
                {"rows":[{"serialName":"第一章","serialID":"1"},{"serialName":"第二章","serialID":"2"}]}
                """
            } else {
                body = "{}"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            return (response, Data(body.utf8))
        }

        let chapters = try await api.getChapterList(
            bookUrl: initialBookURL,
            sourceUrl: sourceURL,
            bookNameHint: "从玄君七章开始",
            authorHint: "衔雨"
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters.first?.title, "第一章")
        XCTAssertEqual(chapters.last?.title, "第二章")

        let visitedRequests = queue.sync { visited }
        XCTAssertTrue(visitedRequests.contains(where: { $0.contains("bookid=1142536692") }))
        XCTAssertFalse(visitedRequests.contains(where: { $0.contains("bookid=nan") }))
        XCTAssertTrue(visitedRequests.contains(where: { $0.contains("bookId=1142536692") }))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(initialBookURL)
    }

    func testRuleAnalyzerInlineJsPipelineUsesElementContextForJsonStep() throws {
        let analyzer = RuleAnalyzer.shared
        let payload = #"{"bid":"42536692","title":"从玄君七章开始"}"#

        guard let element = try SwiftSoup.parseBodyFragment("<div></div>").body()?.children().first() else {
            XCTFail("failed to create element")
            return
        }
        try element.attr("data-json", payload)
        try element.text(payload)

        let rule = """
        $.bid
        <js>1100000000+parseInt(result)</js>
        https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid={{result}}
        """

        let resolved = try analyzer.analyzeElement(
            element: element,
            rule: rule,
            baseUrl: "https://bookshelf.html5.qq.com"
        )
        XCTAssertEqual(
            resolved,
            "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid=1142536692"
        )
    }

    func testRuleAnalyzerJSONPathLookupAcceptsCaseAndSeparatorVariants() {
        let analyzer = RuleAnalyzer.shared
        let payload = #"{"data":{"resourceId":"12345","book_id":"67890"}}"#

        let resourceID = analyzer.analyzeElementText(html: payload, rule: "$.data.resourceID")
        let bookId = analyzer.analyzeElementText(html: payload, rule: "$.data.bookId")

        XCTAssertEqual(resourceID, "12345")
        XCTAssertEqual(bookId, "67890")
    }

    func testChapterFlowDefersDetailPageSnippetAndRefreshesRealToc() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/24680.html"

        let infoRule = BookInfoRule(
            name: "h1@text",
            author: nil,
            intro: nil,
            coverUrl: nil,
            tocUrl: ".toc-link@href",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: ".chapter a",
            chapterName: "text",
            chapterUrl: "href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Detail Snippet Refresh Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let html: String
            switch path {
            case "/book/24680.html":
                html = """
                <html><body>
                  <h1>测试书</h1>
                  <a class='toc-link' href='/book/24680/page-1.html'>查看更多章节</a>
                  <div class='chapter'><a href='/book/24680/9991.html'>第九十九章 末尾</a></div>
                  <div class='chapter'><a href='/book/24680/9992.html'>第一百章 收官</a></div>
                </body></html>
                """
            case "/book/24680/page-1.html":
                html = """
                <html><body>
                  <div class='chapter'><a href='/book/24680/1.html'>第一章 开始</a></div>
                  <div class='chapter'><a href='/book/24680/2.html'>第二章 继续</a></div>
                  <div class='chapter'><a href='/book/24680/3.html'>第三章 深入</a></div>
                  <div class='chapter'><a href='/book/24680/4.html'>第四章 终点</a></div>
                </body></html>
                """
            default:
                html = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: bookURL)!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 4)
        XCTAssertEqual(chapters.first?.title, "第一章 开始")
        XCTAssertEqual(chapters.last?.title, "第四章 终点")

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testChapterFlowDoesNotTreatNumericChapterUrlsAsDetailPages() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/24680/page-1.html"

        let tocRule = TocRule(
            chapterList: ".chapter a",
            chapterName: "text",
            chapterUrl: "href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Numeric Chapter URL Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let html: String
            if path == "/book/24680/page-1.html" {
                html = """
                <html><body>
                  <div class='chapter'><a href='/book/24680/1.html'>第一章</a></div>
                  <div class='chapter'><a href='/book/24680/2.html'>第二章</a></div>
                  <div class='chapter'><a href='/book/24680/3.html'>第三章</a></div>
                  <div class='chapter'><a href='/book/24680/4.html'>第四章</a></div>
                  <div class='chapter'><a href='/book/24680/5.html'>第五章</a></div>
                  <div class='chapter'><a href='/book/24680/6.html'>第六章</a></div>
                  <div class='chapter'><a href='/book/24680/7.html'>第七章</a></div>
                  <div class='chapter'><a href='/book/24680/8.html'>第八章</a></div>
                  <div class='chapter'><a href='/book/24680/9.html'>第九章</a></div>
                  <div class='chapter'><a href='/book/24680/10.html'>第十章</a></div>
                </body></html>
                """
            } else {
                html = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: bookURL)!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 10)
        XCTAssertEqual(chapters.first?.title, "第一章")
        XCTAssertEqual(chapters.last?.title, "第十章")

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testLocalParserAppliesSourceRegexFilter() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookId = "source-regex-book-\(UUID().uuidString)"
        let bookUrl = "https://mock.reader/\(bookId)"

        let infoRule = BookInfoRule(
            name: "h1@text",
            author: ".author@text",
            intro: ".intro@text",
            coverUrl: nil,
            tocUrl: ".toc@href",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: ".content@text",
            title: "h2@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: "##广告弹窗",
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock SourceRegex Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let path = url.path
            let html: String
            if path == "/\(bookId)" {
                html = """
                <html><body>
                  <h1>过滤测试书</h1>
                  <span class='author'>测试作者</span>
                  <div class='intro'>测试 sourceRegex</div>
                  <a class='toc' href='/source-regex-toc'>目录</a>
                </body></html>
                """
            } else if path == "/source-regex-toc" {
                html = """
                <html><body>
                  <div class='chapter'>
                    <a href='/source-regex-chapter-1'>第一章</a>
                    <span class='name'>第一章</span>
                  </div>
                </body></html>
                """
            } else if path == "/source-regex-chapter-1" {
                html = """
                <html><body>
                  <h2>第一章</h2>
                  <div class='content'>正文开始\n广告弹窗\n正文结束</div>
                </body></html>
                """
            } else {
                html = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookUrl, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 1)

        let content = try await api.getChapterContent(
            bookUrl: bookUrl,
            sourceUrl: sourceURL,
            chapterUrl: chapters[0].url,
            index: 0
        )
        XCTAssertTrue(content.content.contains("正文开始"))
        XCTAssertTrue(content.content.contains("正文结束"))
        XCTAssertFalse(content.content.contains("广告弹窗"))

        try await api.removeFromBookshelf(bookUrl: bookUrl, sourceUrl: sourceURL)
        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookUrl)
    }

    func testTocPreUpdateJsRunsBeforeChapterListParsing() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookUrl = "https://mock.reader/pre-update-book-\(UUID().uuidString)"

        let infoRule = BookInfoRule(
            name: "h1@text",
            author: ".author@text",
            intro: ".intro@text",
            coverUrl: nil,
            tocUrl: ".toc@href",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: "result.replace(/data-chapter/g, 'chapter')",
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: ".content@text",
            title: "h2@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Toc PreUpdate Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let path = url.path
            let html: String
            if path.contains("pre-update-book") {
                html = """
                <html><body>
                  <h1>PreUpdate 测试</h1>
                  <span class='author'>测试作者</span>
                  <a class='toc' href='/pre-update-toc'>目录</a>
                </body></html>
                """
            } else if path == "/pre-update-toc" {
                html = """
                <html><body>
                  <div class='data-chapter'>
                    <a href='/pre-update-chapter-1'>第一章</a>
                    <span class='name'>第一章</span>
                  </div>
                </body></html>
                """
            } else if path == "/pre-update-chapter-1" {
                html = """
                <html><body>
                  <h2>第一章</h2>
                  <div class='content'>正文内容</div>
                </body></html>
                """
            } else {
                html = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookUrl, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters.first?.title, "第一章")

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookUrl)
    }

    func testContentWebJsRunsBeforeContentRuleParsing() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookUrl = "https://mock.reader/content-webjs-book-\(UUID().uuidString)"

        let infoRule = BookInfoRule(
            name: "h1@text",
            author: ".author@text",
            intro: ".intro@text",
            coverUrl: nil,
            tocUrl: ".toc@href",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: ".content@text",
            title: "h2@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: "result.replace(/id='payload'/g, \"class='content'\")",
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Content WebJs Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let path = url.path
            let html: String
            if path.contains("content-webjs-book") {
                html = """
                <html><body>
                  <h1>WebJs 测试</h1>
                  <span class='author'>测试作者</span>
                  <a class='toc' href='/content-webjs-toc'>目录</a>
                </body></html>
                """
            } else if path == "/content-webjs-toc" {
                html = """
                <html><body>
                  <div class='chapter'>
                    <a href='/content-webjs-chapter-1'>第一章</a>
                    <span class='name'>第一章</span>
                  </div>
                </body></html>
                """
            } else if path == "/content-webjs-chapter-1" {
                html = """
                <html><body>
                  <h2>第一章</h2>
                  <div id='payload'>webJs 转换后可见正文</div>
                </body></html>
                """
            } else {
                html = "<html><body>not found</body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookUrl, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 1)

        let content = try await api.getChapterContent(
            bookUrl: bookUrl,
            sourceUrl: sourceURL,
            chapterUrl: chapters[0].url,
            index: 0
        )
        XCTAssertTrue(content.content.contains("webJs 转换后可见正文"))

        try await api.removeFromBookshelf(bookUrl: bookUrl, sourceUrl: sourceURL)
        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookUrl)
    }

    func testCoverURLResolverHandlesRelativeAndEncodedPaths() {
        let book = Book(
            bookUrl: "https://example.com/book/123/index.html",
            origin: "https://example.com",
            name: "测试书",
            author: "测试作者",
            coverUrl: "/covers/第 一 章.jpg?v=1 2"
        )
        let resolved = book.resolvedCoverURL()?.absoluteString ?? ""
        XCTAssertTrue(resolved.hasPrefix("https://example.com/covers/"))
        XCTAssertTrue(resolved.contains("%E7%AC%AC%20%E4%B8%80%20%E7%AB%A0.jpg"))

        var searchBook = SearchBook()
        searchBook.bookSourceUrl = "https://demo.site/source"
        searchBook.coverUrl = "//img.demo.site/covers/a b.png"
        let searchResolved = searchBook.resolvedCoverURL()?.absoluteString ?? ""
        XCTAssertEqual(searchResolved, "https://img.demo.site/covers/a%20b.png")
    }

    func testRuleUrlBuilderDynamicExpressionsAndOptions() {
        let descriptor = RuleURLRequestBuilder.build(
            ruleUrl: "https://mock.reader/search/<hot,new>?kw={{key}}&next={{page+1}}, {\"method\":\"POST\",\"retry\":2,\"charset\":\"gbk\",\"body\":\"kw={{key}}\",\"js\":\"result + '&from=js'\"}",
            baseUrl: "https://mock.reader",
            keyword: "三体",
            page: 2
        )

        XCTAssertEqual(descriptor.method, "POST")
        XCTAssertEqual(descriptor.retries, 2)
        XCTAssertEqual(descriptor.charset?.lowercased(), "gbk")
        XCTAssertTrue(descriptor.url.contains("/new?"))
        XCTAssertTrue(descriptor.url.contains("next=3"))
        XCTAssertTrue(descriptor.url.contains("from=js"))
        XCTAssertTrue((descriptor.body ?? "").contains("%E4%B8%89%E4%BD%93"))
    }

    func testRuleUrlBuilderCookieAndJavaHelpers() {
        let props: [HTTPCookiePropertyKey: Any] = [
            .domain: "qidian.com",
            .path: "/",
            .name: "_csrfToken",
            .value: "token123",
            .secure: "FALSE",
            .expires: Date().addingTimeInterval(3600)
        ]
        let cookie = HTTPCookie(properties: props)
        if let cookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        let descriptor = RuleURLRequestBuilder.build(
            ruleUrl: "/rank?page={{page}}&_csrfToken={{cookie.getKey(\"https://qidian.com\",\"_csrfToken\")}}&p={{java.put(\"page\",page)}}&p2={{java.get(\"page\")}}&host={{java.toURL(source.getKey()).host}}",
            baseUrl: "https://m.qidian.com",
            page: 3
        )

        XCTAssertTrue(descriptor.url.contains("page=3"))
        XCTAssertTrue(descriptor.url.contains("_csrfToken=token123"))
        XCTAssertTrue(descriptor.url.contains("p=3"))
        XCTAssertTrue(descriptor.url.contains("p2=3"))
        XCTAssertTrue(descriptor.url.contains("host=m.qidian.com"))

        if let cookie {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    func testRuleUrlBuilderCryptoJavaHelpers() {
        let desDescriptor = RuleURLRequestBuilder.build(
            ruleUrl: #"@js:"https://x.com/?v="+java.desEncodeToBase64String("hello","12345678","DES/ECB/PKCS5Padding","")"#,
            baseUrl: "https://x.com"
        )
        let desQueryValue = URLComponents(string: desDescriptor.url)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value
        XCTAssertEqual(desQueryValue, "uhbGoCVxJa8=")

        let aesDescriptor = RuleURLRequestBuilder.build(
            ruleUrl: #"@js:java.aesBase64DecodeToString("CrmyNAzlhtf+PS2Axon2/eTBwlOgT/hCvE8h93tymRA=","f041c49714d39908","AES/CBC/PKCS5Padding","0123456789abcdef")"#,
            baseUrl: "https://x.com"
        )
        XCTAssertEqual(aesDescriptor.url, "https://example.com/ch/1")
    }

    func testWebBookContentEscapedHTMLGetsNormalized() async throws {
        var source = BookSource()
        source.bookSourceUrl = "https://mock.reader"
        source.bookSourceName = "Mock Content Source"
        source.ruleContent = ContentRule(
            content: ".content@text",
            title: "h1@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        MockURLProtocol.handler = { request in
            let html = """
            <html><body>
              <h1>第一章</h1>
              <div class='content'>&lt;p&gt;正文第一段&lt;/p&gt;&lt;br/&gt;&lt;p&gt;正文第二段&lt;/p&gt;</div>
            </body></html>
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.reader/chapter/1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let content = try await WebBook.shared.getContent(
            chapterUrl: "https://mock.reader/chapter/1",
            source: source
        )

        XCTAssertEqual(content.title, "第一章")
        XCTAssertTrue(content.content.contains("正文第一段"))
        XCTAssertTrue(content.content.contains("正文第二段"))
        XCTAssertFalse(content.content.contains("<p>"))
        XCTAssertFalse(content.content.contains("&lt;p&gt;"))
    }

    func testReadEngineRemoteBookDoesNotAutoAddToShelf() async throws {
        let engine = ReadBookEngine.shared
        let db = DatabaseManager.shared
        let bookUrl = "https://auto-add-test.local/\(UUID().uuidString)"

        db.deleteBook(bookUrl)
        engine.reset()

        let book = Book(
            bookUrl: bookUrl,
            origin: "https://auto-add-source.local",
            name: "临时测试书籍",
            author: "测试"
        )
        engine.openBook(book, source: nil, resetIndex: true)

        try await Task.sleep(nanoseconds: 600_000_000)

        let existsInShelf = db.getAllBooks().contains { $0.bookUrl == bookUrl }
        XCTAssertFalse(existsInShelf)

        engine.close()
        db.deleteBook(bookUrl)
    }

    func testLocalChapterFlowDoesNotAutoAddBookWhenFetchingToc() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/not-in-shelf-\(UUID().uuidString)"

        db.deleteBook(bookURL)

        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock No Auto Add Toc Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            let html = """
            <html><body>
              <div class='chapter'><a href='/book/not-in-shelf/c1'>第一章</a><span class='name'>第一章</span></div>
            </body></html>
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.reader/book/not-in-shelf")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 1)

        let existsInShelf = db.getAllBooks().contains { $0.bookUrl == bookURL }
        XCTAssertFalse(existsInShelf)

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testWebBookContentTextRuleFallsBackToHTMLParagraphFormatting() async throws {
        let source = BookSource(
            bookSourceUrl: "https://mock.reader",
            bookSourceName: "Mock Text Rule HTML Fallback",
            ruleContent: ContentRule(
                content: ".content@text",
                title: "h1@text",
                nextContentUrl: nil,
                nextContentBtn: nil,
                webJs: nil,
                replaceRegex: nil,
                sourceRegex: nil,
                imageStyle: nil
            )
        )

        MockURLProtocol.handler = { request in
            let html = """
            <html><body>
              <h1>第一章</h1>
              <div class='content'><p>正文第一段</p><p>正文第二段</p></div>
            </body></html>
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.reader/chapter/paragraph")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let content = try await WebBook.shared.getContent(
            chapterUrl: "https://mock.reader/chapter/paragraph",
            source: source
        )

        XCTAssertTrue(content.content.contains("正文第一段"))
        XCTAssertTrue(content.content.contains("正文第二段"))
        XCTAssertTrue(content.content.contains("\n"))
    }

    func testWebBookSearchFallsBackAuthorAndCoverWhenRulesMiss() async throws {
        let source = BookSource(
            bookSourceUrl: "https://mock.reader",
            bookSourceName: "Mock Search Fallback Source",
            searchUrl: "/search?kw={{key}}",
            ruleSearch: SearchRule(
                bookList: ".item",
                name: ".title@text",
                author: ".missing-author@text",
                intro: nil,
                coverUrl: ".missing-cover@src",
                bookUrl: "a.title@href",
                kind: nil,
                wordCount: nil,
                lastChapter: nil,
                checkKeyWord: nil
            )
        )

        MockURLProtocol.handler = { request in
            let html = """
            <html><body>
              <div class='item'>
                <a class='title' href='/book/100'>测试小说</a>
                <p>作者：测试作者</p>
                <img data-src='/images/book-100.jpg' />
              </div>
            </body></html>
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.reader/search?kw=test")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let results = try await WebBook.shared.searchBook(keyword: "测试小说", source: source)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.author, "测试作者")
        XCTAssertEqual(results.first?.coverUrl, "https://mock.reader/images/book-100.jpg")
    }

    func testWebBookBookInfoFallsBackToMetaAuthorAndCoverWhenRulesMiss() async throws {
        let source = BookSource(
            bookSourceUrl: "https://mock.reader",
            bookSourceName: "Mock BookInfo Fallback Source",
            ruleBookInfo: BookInfoRule(
                name: "h1@text",
                author: ".missing-author@text",
                intro: nil,
                coverUrl: ".missing-cover@src",
                tocUrl: "a.toc@href",
                kind: nil,
                lastChapter: nil,
                wordCount: nil,
                variables: nil,
                initJs: nil
            )
        )

        MockURLProtocol.handler = { request in
            let html = """
            <html><head>
              <meta name='author' content='测试作者' />
              <meta property='og:image' content='https://cdn.mock.reader/covers/book-100.jpg' />
            </head><body>
              <h1>测试小说</h1>
              <a class='toc' href='/book/100/toc'>目录</a>
            </body></html>
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.reader/book/100")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let info = try await WebBook.shared.getBookInfo(
            bookUrl: "https://mock.reader/book/100",
            source: source
        )

        XCTAssertEqual(info.author, "测试作者")
        XCTAssertEqual(info.coverUrl, "https://cdn.mock.reader/covers/book-100.jpg")
        XCTAssertEqual(info.name, "测试小说")
    }

    func testChapterFlowDeduplicatesTrackingQueryVariantChapterURLs() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/100"

        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Chapter Dedup Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            let html = """
            <html><body>
              <div class='chapter'><a href='/book/100/c1.html?from=feed'><span class='name'>第一章 起点</span></a><span class='name'>第一章 起点</span></div>
              <div class='chapter'><a href='/book/100/c1.html?utm_source=share'><span class='name'>第一章 起点</span></a><span class='name'>第一章 起点</span></div>
              <div class='chapter'><a href='/book/100/c2.html?ref=home'><span class='name'>第二章 继续</span></a><span class='name'>第二章 继续</span></div>
            </body></html>
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.reader/book/100/toc")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第一章 起点")
        XCTAssertEqual(chapters[1].title, "第二章 继续")

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testChapterFlowKeepsDistinctChapterIDsInQueryParameters() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/200"

        let tocRule = TocRule(
            chapterList: ".chapter",
            chapterName: ".name@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Query Chapter ID Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            let html = """
            <html><body>
              <div class='chapter'><a href='/chapter?bookId=200&id=1&from=feed'><span class='name'>第一章</span></a><span class='name'>第一章</span></div>
              <div class='chapter'><a href='/chapter?bookId=200&id=2&utm_source=share'><span class='name'>第二章</span></a><span class='name'>第二章</span></div>
            </body></html>
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.reader/book/200/toc")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters[0].url.contains("id=1"))
        XCTAssertTrue(chapters[1].url.contains("id=2"))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testNetworkManagerRespectsForcedCharset() async throws {
        let text = "中文章节"
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let data = text.data(using: gbEncoding) ?? Data()

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.reader/charset")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, data)
        }

        let result = try await NetworkManager.shared.request(
            url: "https://mock.reader/charset",
            method: "GET",
            headers: nil,
            body: nil,
            retries: 1,
            charset: "gbk"
        )
        XCTAssertEqual(result, text)
    }

    func testRuleAnalyzerCompositeOperators() throws {
        let html = """
        <html><body>
          <div class='book'>
            <span class='name'>三体</span>
            <a class='link' href='/book/1'>详情</a>
          </div>
        </body></html>
        """
        let document = try SwiftSoup.parse(html)
        guard let body = document.body() else {
            XCTFail("missing body")
            return
        }

        let analyzer = RuleAnalyzer.shared
        let fallback = try analyzer.analyzeElement(element: body, rule: ".missing@text||.name@text")
        XCTAssertEqual(fallback, "三体")

        let joined = try analyzer.analyzeElement(element: body, rule: ".name@text%%-%%.link@text")
        XCTAssertEqual(joined, "三体-详情")

        let chained = try analyzer.analyzeElement(element: body, rule: ".book&&.name@text")
        XCTAssertEqual(chained, "三体")
    }

    func testRuleAnalyzerPutGetTextNodesAndCssPrefix() throws {
        let html = """
        <html><body>
          <div class='book'>
            <span class='id'>42</span>
            <h1 class='name'>三体</h1>
            <div class='intro'>地球往事<span>（附录）</span></div>
          </div>
        </body></html>
        """
        let document = try SwiftSoup.parse(html)
        guard let body = document.body() else {
            XCTFail("missing body")
            return
        }

        let analyzer = RuleAnalyzer.shared
        _ = try analyzer.analyzeElement(
            element: body,
            rule: "@put:{bookId:.id@text,intro:.intro@textNodes}"
        )

        let intro = try analyzer.analyzeElement(element: body, rule: "@get:{intro}")
        XCTAssertEqual(intro, "地球往事")

        let cssPrefixed = try analyzer.analyzeElement(element: body, rule: "@css:.name@text")
        XCTAssertEqual(cssPrefixed, "三体")

        let descriptor = RuleURLRequestBuilder.build(
            ruleUrl: "https://mock.reader/book/@get:{bookId}?p={{page+1}}",
            baseUrl: "https://mock.reader",
            page: 1
        )
        XCTAssertTrue(descriptor.url.contains("/book/42"))
        XCTAssertTrue(descriptor.url.contains("p=2"))
    }

    func testRuleAnalyzerStandaloneJavaScriptChapterListRule() throws {
        let payload = """
        {"list":[{"name":"正文卷","bookChapters":[{"name":"第一章","bookid":"100","id":"1","wordCount":1234,"updateDate":"2026-01-01"},{"name":"第二章","bookid":"100","id":"2","wordCount":1456,"updateDate":"2026-01-02"}]}]}
        """
        let script = """
        let v = [],
                list = [];
        JSON.parse(result).list.map($=>{
        V = $.name;
        if(v[v.length-1]!=V&&!/^\\s*$/.test(V)){
                v.push(V)
                list.push({
                                name: '📖['+V+']📖',
                                volume: true
                        })
                }
        $.bookChapters.map($=>{
                return list.push({
                                name: $.name,
                                url: `https://readbook-service-freebook.cread.com/cx/itf/chapterRead?bookId=${$.bookid}&chapterId=${$.id}`,
                                info: `章节字数：${$.wordCount}　更新时间：${$.updateDate}`
                        });
        });
        });
        v.length<2?list.filter($=>!$.volume):list
        """

        let baseURL = "https://readbook-service-freebook.cread.com"
        let rules = [
            "@js:\n\(script)",
            "js:\n\(script)",
            "\u{FEFF}@js：\n\(script)"
        ]

        for rule in rules {
            let elements = try RuleAnalyzer.shared.analyzeList(html: payload, rule: rule, baseUrl: baseURL)
            XCTAssertGreaterThanOrEqual(elements.count, 2)

            let titles = try elements.map {
                try RuleAnalyzer.shared.analyzeElement(element: $0, rule: "name", baseUrl: baseURL)
            }
            XCTAssertTrue(titles.contains("第一章"))
            XCTAssertTrue(titles.contains("第二章"))

            let urls = try elements.map {
                try RuleAnalyzer.shared.analyzeElement(element: $0, rule: "url", baseUrl: baseURL)
            }
            XCTAssertTrue(urls.contains(where: { $0.contains("chapterRead?bookId=100&chapterId=1") }))
            XCTAssertTrue(urls.contains(where: { $0.contains("chapterRead?bookId=100&chapterId=2") }))
        }
    }

    func testRuleAnalyzerIndexExcludeWithColonSeparatedList() throws {
        let html = """
        <html><body>
          <div class="listmain">
            <dd>书名</dd>
            <dd>作者</dd>
            <dd>正文</dd>
            <dd><a href="/1.html">第一章 初见</a></dd>
            <dd><a href="/2.html">第二章 继续</a></dd>
            <dd><a href="/3.html">第三章 尾声</a></dd>
          </div>
        </body></html>
        """

        let elements = try RuleAnalyzer.shared.analyzeList(
            html: html,
            rule: "class.listmain@dd!0:1:2:3",
            baseUrl: "https://mock.reader/book/1/"
        )
        XCTAssertEqual(elements.count, 2)

        let titles = try elements.map { try $0.text() }
        XCTAssertEqual(titles, ["第二章 继续", "第三章 尾声"])
    }

    func testRuleAnalyzerJsonPathRowsAutoFlattensArrayItems() throws {
        let payload = """
        {"rows":[{"title":"第一章","url":"/c1"},{"title":"第二章","url":"/c2"}]}
        """

        let elements = try RuleAnalyzer.shared.analyzeList(
            html: payload,
            rule: "@Json:$.rows",
            baseUrl: "https://mock.reader/book/1/"
        )
        XCTAssertEqual(elements.count, 2)

        let titles = try elements.map {
            try RuleAnalyzer.shared.analyzeElement(element: $0, rule: "$.title", baseUrl: "")
        }
        XCTAssertEqual(titles, ["第一章", "第二章"])
    }

    func testLegacyRegexChapterListRuleParsesWithColonAndAndChain() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/16/16820/"

        let infoRule = BookInfoRule(
            name: "h1@text",
            author: nil,
            intro: nil,
            coverUrl: nil,
            tocUrl: "a.toc@href",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: #":正文卷[\s\S]*?</dl>&&href\s*=\"([^\"]+)\"[^>]*>([^<]+)<"#,
            chapterName: "$2",
            chapterUrl: "$1",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: "#content@text",
            title: "h1@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Legacy Regex Toc",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let html: String
            if url.path.hasPrefix("/book/16/16820"), !url.path.hasSuffix(".html") {
                html = """
                <html><body>
                  <h1>岁月间</h1>
                  <a class="toc" href="/book/16/16820/">目录</a>
                  <div class="listmain">
                    <h2>正文卷</h2>
                    <dl>
                      <dd><a href="/book/16/16820/1.html">第一章 初见</a></dd>
                      <dd><a href="/book/16/16820/2.html">第二章 同窗</a></dd>
                    </dl>
                  </div>
                </body></html>
                """
            } else {
                html = "<html><body><h1>章节</h1><div id='content'>正文</div></body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 2)
        guard chapters.count >= 2 else {
            XCTFail("expected >=2 chapters, got \(chapters.count)")
            try await api.deleteBookSource(sourceUrl: sourceURL)
            db.deleteBook(bookURL)
            return
        }
        XCTAssertEqual(chapters[0].title, "第一章 初见")
        XCTAssertEqual(chapters[1].title, "第二章 同窗")
        XCTAssertTrue(chapters[0].url.hasSuffix("/book/16/16820/1.html"))
        XCTAssertTrue(chapters[1].url.hasSuffix("/book/16/16820/2.html"))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testChapterFlowRejectsNoisyNavigationTocList() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "https://mock.reader/book/noisy/"

        let infoRule = BookInfoRule(
            name: "h1@text",
            author: nil,
            intro: nil,
            coverUrl: nil,
            tocUrl: "a.toc@href",
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: "class.listmain@dd",
            chapterName: "a@text",
            chapterUrl: "a@href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: "#content@text",
            title: "h1@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Noisy Toc Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let html: String
            if url.path.hasPrefix("/book/noisy") {
                html = """
                <html><body>
                  <h1>噪声目录测试</h1>
                  <a class="toc" href="/book/noisy/">目录</a>
                  <div class="listmain">
                    <dd><a href="/m/cate.html">分类</a></dd>
                    <dd><a href="/m/cat/qj/index.html">全本</a></dd>
                    <dd><a href="/m/cat/zx/index.html">最新</a></dd>
                    <dd><a href="/m/book/2013/6.html">《某书》TXT免费下载</a></dd>
                    <dd><a href="/download/227.html">RAR/ZIP格式下载</a></dd>
                    <dd><a href="/book/noisy/1.html">第一章 正常章节</a></dd>
                  </div>
                </body></html>
                """
            } else {
                html = "<html><body><h1>章节</h1><div id='content'>正文</div></body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertTrue(chapters.isEmpty)

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testChapterFlowSynthesizesSingleChapterForDirectContentSource() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "http://m.mock9191.com#"
        let bookURL = "http://m.mock9191.com/m/book/2021/7321.html"

        let infoRule = BookInfoRule(
            name: "tag.h2@text",
            author: "tag.p@text",
            intro: "class.intro_info.0@html",
            coverUrl: nil,
            tocUrl: nil,
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: "class.ablum_read",
            chapterName: "tag.a@text",
            chapterUrl: "",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: "class.downButton@title&&class.downButton@href",
            title: nil,
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock 9191",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let html: String
            if url.path == "/m/book/2021/7321.html" {
                html = """
                <html><body>
                  <h2>青铜王座</h2>
                  <div class="ablum_read">
                    <a href="/m/cate.html">分类</a>
                    <a href="/m/cat/qj/index.html">全本</a>
                    <a href="/m/book/2021/7319.html">《傲视九重》TXT免费下载</a>
                    <a href="/download/7321.html">RAR/ZIP格式下载</a>
                  </div>
                  <a class="downButton" title="RAR/ZIP格式下载" href="/download/7321.html">下载</a>
                </body></html>
                """
            } else if url.path == "/download/7321.html" {
                html = "<html><body><p>mock download page</p></body></html>"
            } else {
                html = "<html><body>ok</body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 1)
        guard let firstChapter = chapters.first else {
            XCTFail("Expected one synthesized fallback chapter")
            return
        }
        XCTAssertEqual(firstChapter.title, "正文")
        XCTAssertEqual(firstChapter.url, bookURL)

        let content = try await api.getChapterContent(
            bookUrl: bookURL,
            sourceUrl: sourceURL,
            chapterUrl: firstChapter.url,
            index: firstChapter.index
        )
        XCTAssertFalse(content.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(content.content.contains("RAR/ZIP格式下载"))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testChapterFlowRejectsRelatedBooksPretendingAsToc() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let bookURL = "http://www.zzs5.net/txt/151980.html"

        let infoRule = BookInfoRule(
            name: "h1@text",
            author: nil,
            intro: nil,
            coverUrl: nil,
            tocUrl: nil,
            kind: nil,
            lastChapter: nil,
            wordCount: nil,
            variables: nil,
            initJs: nil
        )
        let tocRule = TocRule(
            chapterList: ".list a",
            chapterName: "text",
            chapterUrl: "href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let contentRule = ContentRule(
            content: "#content@text",
            title: "h1@text",
            nextContentUrl: nil,
            nextContentBtn: nil,
            webJs: nil,
            replaceRegex: nil,
            sourceRegex: nil,
            imageStyle: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Related Books Toc",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: String(data: try JSONEncoder().encode(infoRule), encoding: .utf8),
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: String(data: try JSONEncoder().encode(contentRule), encoding: .utf8)
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }

            let html: String
            if url.absoluteString.contains("/txt/151980.html") {
                html = """
                <html><body>
                  <h1>像素游戏成真了，但我是通缉榜一</h1>
                  <div class="list">
                    <a href="http://www.zzs5.net/book/151980/">第405章 任务链来了</a>
                    <a href="http://www.zzs5.net/txt/8819.html">柯南里的捡尸人</a>
                    <a href="http://www.zzs5.net/txt/11455.html">全职高手</a>
                    <a href="http://www.zzs5.net/txt/11472.html">英雄联盟之王者荣耀</a>
                    <a href="http://www.zzs5.net/txt/16852.html">超凡黎明</a>
                    <a href="http://www.zzs5.net/txt/17000.html">无尽世界直播系统</a>
                    <a href="http://www.zzs5.net/txt/17777.html">我能提取熟练度</a>
                    <a href="http://www.zzs5.net/txt/18888.html">神级卡徒</a>
                  </div>
                </body></html>
                """
            } else {
                html = "<html><body><h1>章节</h1><div id='content'>正文</div></body></html>"
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertTrue(chapters.isEmpty)

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testChapterFlowSanitizesNavigationLinksFromAutoFallbackToc() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "http://wap.80zw.la/"
        let bookURL = "http://wap.80zw.la/11366/"

        let tocRule = TocRule(
            chapterList: ".book_last dd a",
            chapterName: "text",
            chapterUrl: "href",
            isVolume: nil,
            volumeName: nil,
            chapterSize: nil,
            nextTocUrl: nil,
            isVip: nil,
            preUpdateJs: nil,
            updateTime: nil
        )
        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock 80ZW Toc Sanitize Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: nil,
            header: nil,
            ruleSearch: nil,
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: String(data: try JSONEncoder().encode(tocRule), encoding: .utf8),
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            let html = """
            <html><body>
              <div class='other_list'>
                <a href='/11366/page-1.html'>查看更多章节>></a>
                <a href='/11366/page-1.html'>开始阅读</a>
                <a href='/class5-1.html'>百合之恋</a>
                <a href='/11366/49599451.html'>第八百四十六章 黑的预见</a>
                <a href='/11366/49616847.html'>第八百四十七章 黑的预见</a>
              </div>
            </body></html>
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: bookURL)!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let chapters = try await api.getChapterList(bookUrl: bookURL, sourceUrl: sourceURL)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第八百四十六章 黑的预见")
        XCTAssertEqual(chapters[1].title, "第八百四十七章 黑的预见")
        XCTAssertFalse(chapters.contains(where: { $0.title.contains("开始阅读") }))
        XCTAssertFalse(chapters.contains(where: { $0.title.contains("查看更多章节") }))
        XCTAssertFalse(chapters.contains(where: { $0.title.contains("百合之恋") }))

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(bookURL)
    }

    func testSearchRecoverBookUrlTemplateRuleDoesNotThrowSelectorError() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let searchRule = SearchRule(
            bookList: "@Json:$.data[*]",
            name: "$.novelName",
            author: "$.authorName",
            intro: nil,
            coverUrl: nil,
            bookUrl: "/novel/{{$.novelId}}?isSearch=1",
            kind: nil,
            wordCount: nil,
            lastChapter: nil,
            checkKeyWord: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Mock Template BookUrl Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: "/search?keyword={{key}}",
            header: nil,
            ruleSearch: String(data: try JSONEncoder().encode(searchRule), encoding: .utf8),
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: nil,
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw NSError(domain: "MockURLProtocol", code: -2)
            }
            let body: String
            if url.path == "/search" {
                body = """
                {"data":[{"novelId":"1142536692","novelName":"掌控时光之龙","authorName":"唐宋元明氢"}]}
                """
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            return (response, Data(body.utf8))
        }

        let results = try await api.search(keyword: "掌控时光之龙", page: 1, bookSourceUrl: sourceURL)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(
            results[0].bookUrl.contains("/novel/1142536692?isSearch=1"),
            "unexpected bookUrl: \(results[0].bookUrl)"
        )

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook(results.first?.bookUrl ?? "")
    }

    func testSearchRetryOptionFromRuleUrl() async throws {
        let api = LocalReaderAPI.shared
        let db = DatabaseManager.shared

        let sourceURL = "https://mock.reader/source/\(UUID().uuidString)"
        let searchRule = SearchRule(
            bookList: ".item",
            name: ".name@text",
            author: ".author@text",
            intro: nil,
            coverUrl: nil,
            bookUrl: "a@href",
            kind: nil,
            wordCount: nil,
            lastChapter: nil,
            checkKeyWord: nil
        )

        let sourceResponse = BookSourceResponse(
            bookSourceUrl: sourceURL,
            bookSourceName: "Retry Source",
            bookSourceGroup: "test",
            enabled: true,
            exploreUrl: nil,
            searchUrl: "https://mock.reader/retry,{\"retry\":2}",
            header: nil,
            ruleSearch: String(data: try JSONEncoder().encode(searchRule), encoding: .utf8),
            ruleExplore: nil,
            ruleBookInfo: nil,
            ruleToc: nil,
            ruleContent: nil
        )
        try await api.saveBookSource(sourceResponse)

        let queue = DispatchQueue(label: "wftvios.tests.retry.queue")
        var requestCount = 0
        MockURLProtocol.handler = { request in
            let currentCount = queue.sync { () -> Int in
                requestCount += 1
                return requestCount
            }

            let statusCode = currentCount == 1 ? 500 : 200
            let html = """
            <html><body>
              <div class='item'>
                <a href='/book/retry-ok'>详情</a>
                <span class='name'>重试成功</span>
                <span class='author'>测试作者</span>
              </div>
            </body></html>
            """

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.reader/retry")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(html.utf8))
        }

        let results = try await api.search(keyword: "重试", page: 1, bookSourceUrl: sourceURL)
        XCTAssertEqual(queue.sync { requestCount }, 2)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "重试成功")

        try await api.deleteBookSource(sourceUrl: sourceURL)
        db.deleteBook("https://mock.reader/book/retry-ok")
    }

    func testLocalBookmarkAndConfigRoundTrip() async throws {
        let api = LocalReaderAPI.shared

        let mark = Bookmark(
            bookName: "测试书",
            bookAuthor: "测试作者",
            chapterIndex: 3,
            chapterName: "第三章",
            bookText: "片段",
            content: "正文片段",
            createTime: Int64(Date().timeIntervalSince1970 * 1000)
        )

        try await api.saveBookmark(mark)
        let bookmarks = try await api.getBookmarks()
        XCTAssertTrue(bookmarks.contains(where: { $0.id == mark.id }))

        try await api.deleteBookmark(bookmark: mark)
        let afterDelete = try await api.getBookmarks()
        XCTAssertFalse(afterDelete.contains(where: { $0.id == mark.id }))

        let userConfig: [String: Any] = ["fontSize": 20, "lineSpacing": 1.5]
        try await api.saveUserConfig(userConfig)
        let loadedUserConfig = try await api.getUserConfig()
        XCTAssertEqual(loadedUserConfig["fontSize"] as? Int, 20)

        let bookUrl = "https://local.test/book/\(UUID().uuidString)"
        let bookConfig: [String: Any] = ["theme": "dark", "progress": 12]
        try await api.saveBookConfig(bookUrl: bookUrl, config: bookConfig)
        let loadedBookConfig = try await api.getBookConfig(bookUrl: bookUrl)
        XCTAssertEqual(loadedBookConfig["theme"] as? String, "dark")
        XCTAssertEqual(loadedBookConfig["progress"] as? Int, 12)
    }
    
    func testTxtTocParserProducesRangesForMatchedChapters() {
        let content = """
        前言
        这是前言内容
        第一章 起点
        这里是第一章正文
        第二章 发展
        这里是第二章正文
        """
        
        let chapters = TxtTocParser.shared.parseToc(content: content)
        XCTAssertGreaterThanOrEqual(chapters.count, 2)
        
        guard chapters.count >= 2 else { return }
        
        XCTAssertNotNil(chapters[0].start)
        XCTAssertNotNil(chapters[0].end)
        XCTAssertNotNil(chapters[1].start)
        XCTAssertNotNil(chapters[1].end)

        guard let firstMainChapter = chapters.first(where: { $0.title.contains("第一章") }) else {
            XCTFail("未找到第一章")
            return
        }

        let firstChapterContent = TxtTocParser.shared.getChapterContent(chapter: firstMainChapter, fullContent: content)
        XCTAssertTrue(firstChapterContent.contains("这里是第一章正文"))
        XCTAssertFalse(firstChapterContent.contains("第二章"))
    }
    
    func testTxtTocParserFallbackSplitContainsRanges() {
        let content = String(repeating: "这是没有目录规则的一段连续正文。", count: 10000)
        let chapters = TxtTocParser.shared.parseToc(content: content)
        
        XCTAssertFalse(chapters.isEmpty)
        XCTAssertNotNil(chapters.first?.start)
        XCTAssertNotNil(chapters.first?.end)
    }

    func testEpubLocalParserReadsSpineChapters() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-local-\(UUID().uuidString)")
            .appendingPathExtension("epub")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let archive = try Archive(url: tempFile, accessMode: .create)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>本地EPUB测试书</dc:title>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
            <item id="img" href="cover.jpg" media-type="image/jpeg"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """

        let chapter1 = """
        <html><head><title>第一章</title></head><body><h1>第一章</h1><p>第一章正文 &amp; 测试。</p></body></html>
        """
        let chapter2 = """
        <html><head><title>第二章</title></head><body><h1>第二章</h1><p>第二章正文。</p></body></html>
        """
        let nav = """
        <html><body><nav><a href="chapter1.xhtml">第一章</a></nav></body></html>
        """

        try addZipEntry(archive: archive, path: "META-INF/container.xml", data: Data(containerXML.utf8))
        try addZipEntry(archive: archive, path: "OEBPS/content.opf", data: Data(opf.utf8))
        try addZipEntry(archive: archive, path: "OEBPS/chapter1.xhtml", data: Data(chapter1.utf8))
        try addZipEntry(archive: archive, path: "OEBPS/chapter2.xhtml", data: Data(chapter2.utf8))
        try addZipEntry(archive: archive, path: "OEBPS/nav.xhtml", data: Data(nav.utf8))
        try addZipEntry(archive: archive, path: "OEBPS/cover.jpg", data: Data([0xFF, 0xD8, 0xFF, 0xD9]))

        let parsedIndex = try EpubLocalParser.shared.parseBookIndex(fileURL: tempFile)
        XCTAssertEqual(parsedIndex.title, "本地EPUB测试书")
        XCTAssertEqual(parsedIndex.chapters.count, 2)
        XCTAssertEqual(parsedIndex.chapters[0].title, "第一章")
        XCTAssertEqual(parsedIndex.chapters[1].title, "第二章")

        let firstContent = try EpubLocalParser.shared.readChapterContent(
            fileURL: tempFile,
            chapterPath: parsedIndex.chapters[0].path
        )
        XCTAssertTrue(firstContent.contains("第一章正文"))

        let parsed = try EpubLocalParser.shared.parseBook(fileURL: tempFile)
        XCTAssertEqual(parsed.chapters.count, 2)
    }

    func testParseModeSwitch() {
        BookParseManager.shared.setServerMode(false)
        XCTAssertFalse(BookParseManager.shared.isServerMode)

        BookParseManager.shared.setServerMode(true)
        XCTAssertTrue(BookParseManager.shared.isServerMode)

        BookParseManager.shared.setServerMode(false)
    }

    func testLegadoSourceCompatibilitySampleReport() async throws {
        NetworkManager.shared.setProtocolClassesForTesting(nil)
        let datasetURL = URL(string: "https://gcore.jsdelivr.net/gh/mumuceo/file01/202601/5842_bd6ad73881fe620e7a8f718874278a9f.json")!
        let (data, _) = try await URLSession.shared.data(from: datasetURL)
        let sources = try loadSourceProbes(from: data)
        XCTAssertFalse(sources.isEmpty)

        let unsupportedHardPatterns = [
            "JavaImporter",
            "Packages\\.",
            "org\\.jsoup\\.Jsoup"
        ]
        let supportedBridgePatterns = [
            "java\\.ajax\\(",
            "java\\.ajaxAll\\(",
            "java\\.connect\\(",
            "java\\.getString\\(",
            "java\\.getStringList\\(",
            "java\\.getElement\\(",
            "java\\.getElements\\(",
            "java\\.toNumChapter\\(",
            "java\\.md5Encode\\(",
            "java\\.HMacHex\\(",
            "java\\.desEncodeToBase64String\\(",
            "java\\.aesBase64DecodeToString\\(",
            "java\\.webView\\(",
            "java\\.encodeURI\\("
        ]

        let staticSummary: [String: Any] = [
            "total_sources": sources.count,
            "sources_with_search_rule": sources.filter { ($0.searchUrl ?? "").isEmpty == false && ($0.searchListRule ?? "").isEmpty == false }.count,
            "sources_with_java_or_js": sources.filter { containsAnyPattern($0.raw, patterns: ["java\\.", "@js:", "<js>"]) }.count,
            "sources_hit_supported_bridge": sources.filter { containsAnyPattern($0.raw, patterns: supportedBridgePatterns) }.count,
            "sources_hit_hard_unsupported": sources.filter { containsAnyPattern($0.raw, patterns: unsupportedHardPatterns) }.count
        ]

        let candidates = sources.filter {
            guard let searchUrl = $0.searchUrl, !searchUrl.isEmpty,
                  let listRule = $0.searchListRule, !listRule.isEmpty else {
                return false
            }
            return searchUrl.contains("{{key}}") || searchUrl.lowercased().contains("search") || searchUrl.lowercased().contains("query")
        }

        let lightCandidates = candidates.filter {
            !containsAnyPattern($0.raw, patterns: ["java\\.ajax\\(", "java\\.connect\\(", "java\\.ajaxAll\\("])
        }
        let jsCandidates = candidates.filter {
            containsAnyPattern($0.raw, patterns: ["java\\.ajax\\(", "java\\.connect\\(", "java\\.ajaxAll\\(", "@js:", "<js>"])
        }

        let mergedSample = Array(lightCandidates.prefix(12)) + Array(jsCandidates.prefix(6))
        var seenSampleKeys = Set<String>()
        let sampled = mergedSample.filter { probe in
            let key = "\(probe.name)|\(probe.url)"
            return seenSampleKeys.insert(key).inserted
        }
        XCTAssertFalse(sampled.isEmpty)

        var probeResults: [ProbeRunResult] = []
        for source in sampled {
            let result = await runSearchProbe(source, keyword: "斗罗")
            probeResults.append(result)
        }

        let successCount = probeResults.filter(\.ok).count
        let categoryCount = Dictionary(grouping: probeResults, by: { $0.category }).mapValues(\.count)
        let avgDuration = probeResults.isEmpty ? 0 : probeResults.map(\.durationMs).reduce(0, +) / probeResults.count

        let report: [String: Any] = [
            "dataset_url": datasetURL.absoluteString,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "static_summary": staticSummary,
            "runtime_sample": [
                "sample_size": sampled.count,
                "success_count": successCount,
                "success_rate": sampled.isEmpty ? 0 : Double(successCount) / Double(sampled.count),
                "avg_duration_ms": avgDuration,
                "failure_categories": categoryCount
            ],
            "sample_details": probeResults.map { item in
                [
                    "source": item.source.name,
                    "url": item.source.url,
                    "ok": item.ok,
                    "category": item.category,
                    "status": item.statusCode ?? NSNull(),
                    "elements": item.elementCount,
                    "duration_ms": item.durationMs,
                    "message": item.message
                ] as [String: Any]
            }
        ]

        let reportPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legado_source_compat_report.json")

        if let reportData = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try reportData.write(to: reportPath)
            print("[CompatReport] saved=\(reportPath.path)")
            if let srcRoot = ProcessInfo.processInfo.environment["SRCROOT"] {
                let hostPath = URL(fileURLWithPath: srcRoot).appendingPathComponent("compat_report_latest.json")
                try? reportData.write(to: hostPath)
                print("[CompatReport] host_saved=\(hostPath.path)")
            }
            if let jsonText = String(data: reportData, encoding: .utf8) {
                let attachment = XCTAttachment(string: jsonText)
                attachment.name = "legado_source_compat_report"
                attachment.lifetime = .keepAlways
                add(attachment)
                print("[CompatReportJSON]\(jsonText)")
            }
        }
        print("[CompatReport] static=\(staticSummary)")
        print("[CompatReport] runtime sample=\(successCount)/\(sampled.count), avg=\(avgDuration)ms, categories=\(categoryCount)")
    }
}

import Foundation
import SwiftSoup
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

class WebBook {
    static let shared = WebBook()

    private let analyzer = RuleAnalyzer.shared
    private let network = NetworkManager.shared
    private let cleaner = ContentCleaner.shared
    private let verboseChapterDebugLoggingEnabled = false
    private var regexCache: [String: NSRegularExpression] = [:]
    private let regexCacheLock = NSLock()

    private init() {}

    private func cachedRegex(
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        regexCacheLock.lock()
        if let cached = regexCache[key] {
            regexCacheLock.unlock()
            return cached
        }
        regexCacheLock.unlock()

        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        regexCacheLock.lock()
        regexCache[key] = compiled
        regexCacheLock.unlock()
        return compiled
    }

    func searchBook(keyword: String, source: BookSource) async throws -> [SearchBook] {
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            return []
        }
        analyzer.resetVariables()

        let descriptor = RuleURLRequestBuilder.build(
            ruleUrl: searchUrl,
            baseUrl: source.bookSourceUrl,
            keyword: keyword,
            page: 1,
            defaultHeaders: sourceHeaders(source),
            sourceKey: source.bookSourceUrl,
            sourceHeader: source.header,
            sourceComment: nil,
            sourceName: source.bookSourceName
        )
        let html = try await network.request(
            url: descriptor.url,
            method: descriptor.method,
            headers: descriptor.headers,
            body: descriptor.body,
            retries: descriptor.retries ?? 1,
            charset: descriptor.charset
        )

        return try parseBookList(html: html, source: source, baseUrl: descriptor.url, keyword: keyword)
    }

    func getBookInfo(bookUrl: String, source: BookSource) async throws -> Book {
        analyzer.resetVariables()
        let descriptor = RuleURLRequestBuilder.build(
            ruleUrl: bookUrl,
            baseUrl: source.bookSourceUrl,
            defaultHeaders: sourceHeaders(source),
            sourceKey: source.bookSourceUrl,
            sourceHeader: source.header,
            sourceComment: nil,
            sourceName: source.bookSourceName
        )

        let html = try await network.request(
            url: descriptor.url,
            method: descriptor.method,
            headers: descriptor.headers,
            body: descriptor.body,
            retries: descriptor.retries ?? 1,
            charset: descriptor.charset
        )

        return try parseBookInfo(html: html, url: descriptor.url, source: source)
    }

    func getChapterList(tocUrl: String, bookUrl: String, source: BookSource) async throws -> [BookChapter] {
        let traceID = String(UUID().uuidString.prefix(8))
        let traceTag = "toc:\(traceID)"
        logChapterDebug("[\(traceTag)] START getChapterList")
        logChapterDebug("[\(traceTag)] input bookUrl=\(bookUrl)")
        logChapterDebug("[\(traceTag)] input tocUrl=\(tocUrl)")
        logChapterDebug("[\(traceTag)] sourceUrl=\(source.bookSourceUrl) sourceName=\(source.bookSourceName)")
        logChapterDebug("[\(traceTag)] sourceConfig=\n\(prettySourceConfig(source))")

        let targetUrl = tocUrl.isEmpty ? bookUrl : tocUrl
        var currentRuleUrl = targetUrl
        var visitedUrls = Set<String>()
        var seenChapterKeys = Set<String>()
        var mergedChapters: [BookChapter] = []
        let maxPages = 50
        var pageCount = 0

        while !currentRuleUrl.isEmpty && pageCount < maxPages {
            logChapterDebug("[\(traceTag)] page=\(pageCount) preparing ruleUrl=\(currentRuleUrl)")
            let descriptor = RuleURLRequestBuilder.build(
                ruleUrl: currentRuleUrl,
                baseUrl: source.bookSourceUrl,
                defaultHeaders: sourceHeaders(source),
                sourceKey: source.bookSourceUrl,
                sourceHeader: source.header,
                sourceComment: nil,
                sourceName: source.bookSourceName
            )
            logChapterDebug(
                "[\(traceTag)] page=\(pageCount) request url=\(descriptor.url) method=\(descriptor.method) retries=\(descriptor.retries ?? 1) charset=\(descriptor.charset ?? "nil") bodyLength=\(descriptor.body?.count ?? 0)"
            )
            if let headerData = try? JSONSerialization.data(withJSONObject: descriptor.headers, options: [.prettyPrinted, .sortedKeys]),
               let headerText = String(data: headerData, encoding: .utf8),
               !headerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logChapterDebug("[\(traceTag)] page=\(pageCount) requestHeaders=\n\(headerText)")
            }

            let visitKey = normalizeVisitKey(descriptor.url)
            if visitedUrls.contains(visitKey) {
                logChapterDebug("[\(traceTag)] page=\(pageCount) stop: visited url loop detected -> \(descriptor.url)")
                break
            }
            visitedUrls.insert(visitKey)

            let html = try await network.request(
                url: descriptor.url,
                method: descriptor.method,
                headers: descriptor.headers,
                body: descriptor.body,
                retries: descriptor.retries ?? 1,
                charset: descriptor.charset
            )
            logChapterDebug("[\(traceTag)] page=\(pageCount) responseLength=\(html.count)")
            logChapterDebug("[\(traceTag)] page=\(pageCount) responsePreview=\(previewText(html, maxLength: 260))")

            let preprocessedHTML = applyPageScriptIfNeeded(
                html,
                script: source.ruleToc?.preUpdateJs,
                baseUrl: descriptor.url
            )
            if preprocessedHTML != html {
                logChapterDebug("[\(traceTag)] page=\(pageCount) preUpdateJs applied htmlLength \(html.count) -> \(preprocessedHTML.count)")
            } else if let preJs = source.ruleToc?.preUpdateJs, !preJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logChapterDebug("[\(traceTag)] page=\(pageCount) preUpdateJs configured but html unchanged")
            }

            let pageResult: (chapters: [BookChapter], nextTocUrl: String?)
            do {
                pageResult = try parseChapterListPage(
                    html: preprocessedHTML,
                    bookUrl: bookUrl,
                    baseUrl: descriptor.url,
                    source: source,
                    startIndex: mergedChapters.count,
                    traceTag: traceTag,
                    pageIndex: pageCount
                )
            } catch {
                logChapterDebug("[\(traceTag)] page=\(pageCount) parseChapterListPage FAILED: \(error)")
                throw error
            }
            let uniquePageChapters = pageResult.chapters.filter { chapter in
                seenChapterKeys.insert(chapterDedupKey(chapter)).inserted
            }
            mergedChapters.append(contentsOf: uniquePageChapters)
            if uniquePageChapters.count < pageResult.chapters.count {
                logChapterDebug("[\(traceTag)] page=\(pageCount) droppedDuplicates=\(pageResult.chapters.count - uniquePageChapters.count)")
            }
            logChapterDebug(
                "[\(traceTag)] page=\(pageCount) parsedChapters=\(pageResult.chapters.count) new=\(uniquePageChapters.count) merged=\(mergedChapters.count)"
            )
            let pageSample = uniquePageChapters.prefix(3).map {
                "{idx:\($0.index), title:\($0.title), url:\($0.url), volume:\($0.isVolume)}"
            }.joined(separator: ", ")
            if !pageSample.isEmpty {
                logChapterDebug("[\(traceTag)] page=\(pageCount) sample=[\(pageSample)]")
            }

            // 与 Legado 一致，翻页结果若没有新增章节，通常意味着命中了重复目录页，提前终止避免长时间空跑。
            if !mergedChapters.isEmpty, uniquePageChapters.isEmpty {
                logChapterDebug("[\(traceTag)] page=\(pageCount) no incremental chapters, stop paging")
                break
            }

            guard let nextTocUrl = pageResult.nextTocUrl, !nextTocUrl.isEmpty else {
                logChapterDebug("[\(traceTag)] page=\(pageCount) no nextTocUrl, stop paging")
                break
            }
            logChapterDebug("[\(traceTag)] page=\(pageCount) nextTocUrl=\(nextTocUrl)")
            currentRuleUrl = nextTocUrl
            pageCount += 1
        }

        let beforeDedup = mergedChapters.count
        var deduplicated = deduplicateChapters(mergedChapters)
        let afterDedup = deduplicated.count
        deduplicated = reorderChaptersIfNeeded(deduplicated)
        for index in deduplicated.indices {
            deduplicated[index].index = index
        }
        logChapterDebug("[\(traceTag)] dedup \(beforeDedup) -> \(afterDedup), final=\(deduplicated.count)")
        let finalSample = deduplicated.prefix(5).map {
            "{idx:\($0.index), title:\($0.title), url:\($0.url), volume:\($0.isVolume)}"
        }.joined(separator: ", ")
        if !finalSample.isEmpty {
            logChapterDebug("[\(traceTag)] finalSample=[\(finalSample)]")
        }
        logChapterDebug("[\(traceTag)] END getChapterList")
        return deduplicated
    }

    func getContent(chapterUrl: String, source: BookSource) async throws -> ChapterContent {
        var currentRuleUrl = chapterUrl
        var visitedUrls = Set<String>()
        var pageContents: [String] = []
        var pageImageURLs: [String] = []
        var title = ""
        var unresolvedNextUrl: String?
        let maxPages = 20
        var pageCount = 0

        while !currentRuleUrl.isEmpty && pageCount < maxPages {
            let descriptor = RuleURLRequestBuilder.build(
                ruleUrl: currentRuleUrl,
                baseUrl: source.bookSourceUrl,
                defaultHeaders: sourceHeaders(source),
                sourceKey: source.bookSourceUrl,
                sourceHeader: source.header,
                sourceComment: nil,
                sourceName: source.bookSourceName
            )
            let visitKey = normalizeVisitKey(descriptor.url)
            if visitedUrls.contains(visitKey) {
                break
            }
            visitedUrls.insert(visitKey)

            do {
                let html = try await network.request(
                    url: descriptor.url,
                    method: descriptor.method,
                    headers: descriptor.headers,
                    body: descriptor.body,
                    retries: descriptor.retries ?? 1,
                    charset: descriptor.charset
                )

                let preprocessedHTML = applyPageScriptIfNeeded(
                    html,
                    script: source.ruleContent?.webJs,
                    baseUrl: descriptor.url
                )

                let pageContent = try parseContentPage(html: preprocessedHTML, url: descriptor.url, source: source)
                if title.isEmpty {
                    title = pageContent.title
                }
                if !pageContent.content.isEmpty {
                    pageContents.append(pageContent.content)
                }
                if let images = pageContent.imageUrls, !images.isEmpty {
                    pageImageURLs.append(contentsOf: images)
                }

                guard let nextUrl = pageContent.nextUrl, !nextUrl.isEmpty else {
                    unresolvedNextUrl = nil
                    break
                }
                unresolvedNextUrl = nextUrl
                currentRuleUrl = nextUrl
                pageCount += 1
            } catch {
                // 某些站点正文第一页可用，但“下一页”链接偶发 404/超时，保留已抓到内容并终止翻页。
                if !pageContents.isEmpty || !pageImageURLs.isEmpty {
                    unresolvedNextUrl = nil
                    break
                }
                throw error
            }
        }

        var merged = ChapterContent()
        merged.url = chapterUrl
        merged.title = title
        merged.content = pageContents.joined(separator: "\n")
        merged.nextUrl = unresolvedNextUrl
        let rawMergedContentForImageExtraction = merged.content
        if !pageImageURLs.isEmpty {
            merged.imageUrls = uniqueStrings(pageImageURLs)
        }

        if let replaceRegex = source.ruleContent?.replaceRegex {
            merged.content = applyReplaceRule(content: merged.content, rule: replaceRegex)
        }
        if let sourceRegex = source.ruleContent?.sourceRegex {
            merged.content = applySourceRegex(content: merged.content, rule: sourceRegex)
        }

        merged = cleaner.cleanChapter(merged)
        merged = normalizeChapterContent(merged, baseUrl: chapterUrl)

        // 优先使用清洗前原始 HTML/页面提取到的图片 URL，避免清洗规则改写路径导致 404。
        var rawImagesFromOriginalHTML: [String] = []
        if containsHTMLMarkup(rawMergedContentForImageExtraction) {
            rawImagesFromOriginalHTML = extractImageUrls(from: rawMergedContentForImageExtraction, baseUrl: chapterUrl)
        }
        let authoritativeImages = uniqueStrings(pageImageURLs + rawImagesFromOriginalHTML)
        if !authoritativeImages.isEmpty {
            merged.imageUrls = authoritativeImages
        }
        return merged
    }

    private func sourceHeaders(_ source: BookSource) -> [String: String] {
        var headers = RuleURLRequestBuilder.parseHeaderMap(source.header)
        if let existingRefererKey = headers.keys.first(where: { $0.lowercased() == "referer" }) {
            let sanitized = sanitizeRefererHeader(headers[existingRefererKey] ?? "")
            if let sanitized {
                headers[existingRefererKey] = sanitized
            } else {
                headers.removeValue(forKey: existingRefererKey)
            }
        } else if let referer = sanitizeRefererHeader(source.bookSourceUrl) {
            headers["Referer"] = referer
        }
        return headers
    }

    private func sanitizeRefererHeader(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }

        // 书源中常带有调试标记 fragment（例如 #🎃），需移除后再作为 Referer。
        components.fragment = nil
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        guard let normalized = components.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty,
              !normalized.contains("\r"),
              !normalized.contains("\n") else {
            return nil
        }
        return normalized
    }

    private func parseBookList(html: String, source: BookSource, baseUrl: String, keyword: String? = nil) throws -> [SearchBook] {
        guard let rule = source.ruleSearch else { return [] }

        var results: [SearchBook] = []
        let elements = try analyzer.analyzeList(html: html, rule: rule.bookList ?? "", baseUrl: baseUrl)

        for element in elements {
            var book = SearchBook()
            book.bookSourceUrl = source.bookSourceUrl
            book.origin = source.bookSourceUrl
            book.originName = source.bookSourceName

            if let nameRule = rule.name {
                book.name = (try? analyzer.analyzeElement(element: element, rule: nameRule, baseUrl: baseUrl)) ?? ""
            }

            if let authorRule = rule.author {
                book.author = (try? analyzer.analyzeElement(element: element, rule: authorRule, baseUrl: baseUrl)) ?? ""
            }
            if book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                book.author = fallbackAuthorFromElement(element)
            }

            if let coverRule = rule.coverUrl {
                let coverUrl = (try? analyzer.analyzeElement(element: element, rule: coverRule, baseUrl: baseUrl)) ?? ""
                if !coverUrl.isEmpty {
                    book.coverUrl = analyzer.extractUrl(url: coverUrl, baseUrl: baseUrl)
                }
            }
            if (book.coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               let fallbackCover = fallbackCoverURLFromElement(element, baseUrl: baseUrl) {
                book.coverUrl = fallbackCover
            }

            if let introRule = rule.intro {
                book.intro = (try? analyzer.analyzeElement(element: element, rule: introRule, baseUrl: baseUrl)) ?? ""
            }

            if let bookUrlRule = rule.bookUrl {
                book.bookUrl = resolveBookURLRule(
                    rule: bookUrlRule,
                    element: element,
                    baseUrl: baseUrl,
                    source: source
                )
            }

            if let kindRule = rule.kind {
                book.kind = (try? analyzer.analyzeElement(element: element, rule: kindRule, baseUrl: baseUrl)) ?? ""
            }

            if let wordCountRule = rule.wordCount {
                book.wordCount = (try? analyzer.analyzeElement(element: element, rule: wordCountRule, baseUrl: baseUrl)) ?? ""
            }

            if let lastChapterRule = rule.lastChapter {
                book.latestChapter = (try? analyzer.analyzeElement(element: element, rule: lastChapterRule, baseUrl: baseUrl)) ?? ""
            }

            if let checkKeyWordRule = rule.checkKeyWord,
               let keyword,
               !keyword.isEmpty {
                let keyMatchedText = (try? analyzer.analyzeElement(element: element, rule: checkKeyWordRule, baseUrl: baseUrl)) ?? ""
                if !keyMatchedText.isEmpty && !keyMatchedText.localizedCaseInsensitiveContains(keyword) {
                    continue
                }
            }

            if !book.name.isEmpty && !book.bookUrl.isEmpty {
                results.append(book)
            }
        }

        return results
    }

    private func parseBookInfo(html: String, url: String, source: BookSource) throws -> Book {
        guard let rule = source.ruleBookInfo else {
            throw ParserError.noRule
        }

        var book = Book(bookUrl: url)
        book.bookUrl = url
        book.origin = source.bookSourceUrl
        book.originName = source.bookSourceName
        book.tocUrl = url

        let infoPayload = resolveBookInfoPayload(
            html: html,
            baseUrl: url,
            initRule: rule.initJs
        )

        let name = extractRuleValue(html: infoPayload, baseUrl: url, rule: rule.name)
        if !name.isEmpty { book.name = name }

        let author = extractRuleValue(html: infoPayload, baseUrl: url, rule: rule.author)
        if !author.isEmpty { book.author = author }

        let intro = extractRuleValue(html: infoPayload, baseUrl: url, rule: rule.intro)
        if !intro.isEmpty { book.intro = intro }

        let cover = extractRuleValue(html: infoPayload, baseUrl: url, rule: rule.coverUrl)
        if !cover.isEmpty {
            book.coverUrl = analyzer.extractUrl(url: cover, baseUrl: url)
        }

        if book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            book.author = extractFallbackAuthorFromHTML(html)
        }
        if (book.coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let fallbackCover = extractFallbackCoverURLFromHTML(html, baseUrl: url) {
            book.coverUrl = fallbackCover
        }

        let resolvedTocRule = resolveBookInfoTocRule(
            rule: rule.tocUrl,
            payload: infoPayload,
            baseUrl: url
        )
        var toc = extractRuleValue(html: infoPayload, baseUrl: url, rule: resolvedTocRule)
        if toc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedRule = resolvedTocRule.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeURLText(trimmedRule) {
                toc = trimmedRule
            }
        }
        if !toc.isEmpty {
            book.tocUrl = analyzer.extractUrl(url: toc, baseUrl: url)
        }

        let kind = extractRuleValue(html: infoPayload, baseUrl: url, rule: rule.kind)
        if !kind.isEmpty { book.kind = kind }

        let last = extractRuleValue(html: infoPayload, baseUrl: url, rule: rule.lastChapter)
        if !last.isEmpty { book.latestChapterTitle = last }

        return book
    }

    private func fallbackAuthorFromElement(_ element: Element) -> String {
        let selectorCandidates = [
            ".author", ".writer", "[itemprop=author]",
            "[class*=author]", "[id*=author]"
        ]
        for selector in selectorCandidates {
            if let node = try? element.select(selector).first(),
               let text = try? node.text() {
                let candidate = sanitizeAuthorCandidate(text)
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }

        let attributeKeys = ["data-author", "author", "data-writer", "writer"]
        for key in attributeKeys {
            if let value = try? element.attr(key) {
                let candidate = sanitizeAuthorCandidate(value)
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }

        let fullText = (try? element.text()) ?? ""
        return extractAuthorFromText(fullText)
    }

    private func fallbackCoverURLFromElement(_ element: Element, baseUrl: String) -> String? {
        let selectors = [
            "img.cover", "img[data-cover]", "img[data-original]",
            "img[data-src]", "img[src]"
        ]
        for selector in selectors {
            guard let nodes = try? element.select(selector).array(), !nodes.isEmpty else { continue }
            for image in nodes.prefix(12) {
                if let cover = resolveCoverURLFromImageElement(image, baseUrl: baseUrl) {
                    return cover
                }
            }
        }
        return nil
    }

    private func extractFallbackAuthorFromHTML(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }

        let metaSelectors = [
            "meta[name=author]",
            "meta[property='book:author']",
            "meta[property='og:novel:author']",
            "meta[property='og:book:author']",
            "meta[property='og:author']"
        ]
        for selector in metaSelectors {
            if let node = try? doc.select(selector).first(),
               let value = try? node.attr("content") {
                let candidate = sanitizeAuthorCandidate(value)
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }

        let authorSelectors = [".author", ".writer", "[itemprop=author]", "[class*=author]", "[id*=author]"]
        for selector in authorSelectors {
            if let node = try? doc.select(selector).first(),
               let text = try? node.text() {
                let candidate = sanitizeAuthorCandidate(text)
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }

        let bodyText = (try? doc.text()) ?? ""
        return extractAuthorFromText(bodyText)
    }

    private func extractFallbackCoverURLFromHTML(_ html: String, baseUrl: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html, baseUrl) else { return nil }

        let metaSelectors = [
            "meta[property='og:image']",
            "meta[name='og:image']",
            "meta[name='twitter:image']",
            "link[rel='image_src']"
        ]
        for selector in metaSelectors {
            if let node = try? doc.select(selector).first() {
                let content = (try? node.attr("content")) ?? ""
                let href = (try? node.attr("href")) ?? ""
                let raw = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? content : href
                if let normalized = normalizeCoverURLCandidate(raw, baseUrl: baseUrl) {
                    return normalized
                }
            }
        }

        let imageSelectors = [
            ".cover img", "#fmimg img", ".book-cover img", ".bookimg img",
            ".book-info img", ".info img", ".pic img",
            "img#cover", "img.cover", "img[src*='cover']",
            "img[data-src*='cover']", "img[src]"
        ]
        for selector in imageSelectors {
            guard let images = try? doc.select(selector).array(), !images.isEmpty else { continue }
            for image in images.prefix(20) {
                if let cover = resolveCoverURLFromImageElement(image, baseUrl: baseUrl) {
                    return cover
                }
            }
        }

        return nil
    }

    private func resolveCoverURLFromImageElement(_ image: Element, baseUrl: String) -> String? {
        let attributeKeys = ["src", "data-src", "data-original", "data-lazy-src", "original-src", "data-cover"]
        for key in attributeKeys {
            let raw = ((try? image.attr(key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized = normalizeCoverURLCandidate(raw, baseUrl: baseUrl) {
                return normalized
            }
        }
        return nil
    }

    private func normalizeCoverURLCandidate(_ raw: String, baseUrl: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("data:image")
            || lowered.hasPrefix("javascript:")
            || lowered.hasPrefix("about:blank") {
            return nil
        }
        let suspiciousTokens = ["logo", "icon", "avatar", "loading", "spinner", "ads", "banner"]
        if suspiciousTokens.contains(where: { lowered.contains($0) }) && !lowered.contains("cover") {
            return nil
        }

        let normalized = analyzer.extractUrl(url: trimmed, baseUrl: baseUrl).trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func extractAuthorFromText(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let patterns = [
            #"(?:作者|Author)\s*[:：]\s*([^\s\|｜\/,，;；]{1,40})"#,
            #"(?i)\bby\s+([A-Za-z][A-Za-z0-9 ._-]{1,40})"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let candidate = sanitizeAuthorCandidate(String(text[valueRange]))
            if !candidate.isEmpty {
                return candidate
            }
        }
        return ""
    }

    private func sanitizeAuthorCandidate(_ raw: String) -> String {
        var cleaned = raw
            .replacingOccurrences(of: #"(?i)\b(author|作者)\s*[:：]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        if let range = cleaned.range(of: #"[|｜\/,，;；\n\r\t]"#, options: .regularExpression) {
            cleaned = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.count > 40 {
            return ""
        }
        return cleaned
    }

    private func parseChapterListPage(
        html: String,
        bookUrl: String,
        baseUrl: String,
        source: BookSource,
        startIndex: Int,
        traceTag: String = "toc",
        pageIndex: Int = 0
    ) throws -> (chapters: [BookChapter], nextTocUrl: String?) {
        guard let rule = source.ruleToc else { return ([], nil) }

        let listRule = normalizeListRule(rule.chapterList ?? "")
        logChapterDebug("[\(traceTag)] page=\(pageIndex) tocRules chapterList=\(rule.chapterList ?? "")")
        logChapterDebug("[\(traceTag)] page=\(pageIndex) tocRules chapterName=\(rule.chapterName ?? "")")
        logChapterDebug("[\(traceTag)] page=\(pageIndex) tocRules chapterUrl=\(rule.chapterUrl ?? "")")
        logChapterDebug("[\(traceTag)] page=\(pageIndex) tocRules isVolume=\(rule.isVolume ?? "")")
        logChapterDebug("[\(traceTag)] page=\(pageIndex) tocRules volumeName=\(rule.volumeName ?? "")")
        logChapterDebug("[\(traceTag)] page=\(pageIndex) tocRules nextTocUrl=\(rule.nextTocUrl ?? "")")
        logChapterDebug("[\(traceTag)] page=\(pageIndex) normalizedListRule reverse=\(listRule.reverse) rule=\(listRule.rule)")

        var chapters: [BookChapter] = []
        if !listRule.rule.isEmpty {
            if isRegexChapterListRule(listRule.rule) {
                chapters = parseChapterListFromRegexRule(
                    listRule: listRule.rule,
                    tocRule: rule,
                    html: html,
                    bookUrl: bookUrl,
                    baseUrl: baseUrl,
                    startIndex: startIndex
                )
                logChapterDebug("[\(traceTag)] page=\(pageIndex) regexChapterRows=\(chapters.count)")
            } else {
                let elements = try analyzer.analyzeList(html: html, rule: listRule.rule, baseUrl: baseUrl)
                logChapterDebug("[\(traceTag)] page=\(pageIndex) listElements=\(elements.count)")

                for (index, element) in elements.enumerated() {
                    var chapter = BookChapter()
                    chapter.bookUrl = bookUrl
                    chapter.index = startIndex + index
                    chapter.baseUrl = baseUrl

                    if let titleRule = rule.chapterName {
                        chapter.title = (try? analyzer.analyzeElement(element: element, rule: titleRule, baseUrl: baseUrl)) ?? ""
                    }

                    chapter.title = sanitizedChapterTitle(chapter.title)

                    if chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let volumeNameRule = rule.volumeName,
                       !volumeNameRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        chapter.title = (try? analyzer.analyzeElement(element: element, rule: volumeNameRule, baseUrl: baseUrl)) ?? ""
                        chapter.title = sanitizedChapterTitle(chapter.title)
                    }

                    if let urlRule = rule.chapterUrl {
                        chapter.url = resolveChapterURLRule(
                            rule: urlRule,
                            element: element,
                            baseUrl: baseUrl,
                            source: source
                        )
                    }

                    if let isVolumeRule = rule.isVolume {
                        let volumeCheck = try analyzer.analyzeElement(element: element, rule: isVolumeRule, baseUrl: baseUrl)
                        chapter.isVolume = parseBooleanValue(volumeCheck)
                    }

                    if let isVipRule = rule.isVip {
                        let vipCheck = (try? analyzer.analyzeElement(element: element, rule: isVipRule, baseUrl: baseUrl)) ?? ""
                        let isVip = parseBooleanValue(vipCheck)
                        chapter.isVip = isVip
                        chapter.isPay = isVip
                    }

                    if let updateTimeRule = rule.updateTime {
                        let updateTime = (try? analyzer.analyzeElement(element: element, rule: updateTimeRule, baseUrl: baseUrl)) ?? ""
                        if !updateTime.isEmpty {
                            chapter.tag = updateTime
                        }
                    }

                    applyChapterJSONPayloadFallback(
                        element: element,
                        chapter: &chapter,
                        baseUrl: baseUrl
                    )

                    if chapter.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chapter.isVolume {
                        if let href = try? element.attr("href"), !href.isEmpty {
                            chapter.url = analyzer.extractUrl(url: href, baseUrl: baseUrl)
                        } else if let dataHref = try? element.attr("data-href"), !dataHref.isEmpty {
                            chapter.url = analyzer.extractUrl(url: dataHref, baseUrl: baseUrl)
                        } else if let dataUrl = try? element.attr("data-url"), !dataUrl.isEmpty {
                            chapter.url = analyzer.extractUrl(url: dataUrl, baseUrl: baseUrl)
                        }
                    }

                    if chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let fallbackTitle = (try? element.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                        chapter.title = sanitizedChapterTitle(fallbackTitle)
                    }

                    if chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chapter.url.isEmpty {
                        chapter.title = "第\(chapter.index + 1)章"
                    }

                    if !chapter.title.isEmpty {
                        if chapter.url.isEmpty && !chapter.isVolume {
                            chapter.url = baseUrl
                        } else if chapter.url.isEmpty && chapter.isVolume {
                            chapter.url = "\(chapter.title)\(chapter.index)"
                        }
                        chapters.append(chapter)
                    }
                }
            }
        }

        if listRule.reverse {
            chapters.reverse()
            logChapterDebug("[\(traceTag)] page=\(pageIndex) reversed chapters due to rule prefix")
        }

        if chapters.isEmpty {
            logChapterDebug("[\(traceTag)] page=\(pageIndex) primary rule produced 0 chapter, try JSON payload fallback")
            chapters = parseChapterListFromJSONPayload(
                html: html,
                bookUrl: bookUrl,
                baseUrl: baseUrl,
                startIndex: startIndex
            )
            logChapterDebug("[\(traceTag)] page=\(pageIndex) JSON payload fallback count=\(chapters.count)")
        }

        let beforeAuto = chapters
        let shouldSkipAutoFallbackForDirectContent =
            listRule.rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "body" &&
            (rule.chapterUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            !chapters.isEmpty
        if shouldSkipAutoFallbackForDirectContent {
            logChapterDebug("[\(traceTag)] page=\(pageIndex) skip auto fallback for direct-content toc rule")
        } else if shouldTriggerAutoChapterFallback(chapters, baseUrl: baseUrl) {
            logChapterDebug("[\(traceTag)] page=\(pageIndex) trigger auto HTML fallback")
            let auto = parseChapterListFromHTMLAutoDetection(
                html: html,
                bookUrl: bookUrl,
                baseUrl: baseUrl,
                startIndex: startIndex
            )
            logChapterDebug("[\(traceTag)] page=\(pageIndex) auto fallback count=\(auto.count)")
            chapters = chooseBetterChapterList(primary: chapters, fallback: auto, baseUrl: baseUrl)
            let primaryScore = chapterQualityScore(beforeAuto, baseUrl: baseUrl)
            let fallbackScore = chapterQualityScore(auto, baseUrl: baseUrl)
            logChapterDebug(
                "[\(traceTag)] page=\(pageIndex) choose list primaryScore=\(primaryScore) fallbackScore=\(fallbackScore) chosenCount=\(chapters.count)"
            )
        }

        var nextTocUrl = resolveNextTocURL(
            html: html,
            baseUrl: baseUrl,
            nextRule: rule.nextTocUrl
        )
        if nextTocUrl == nil {
            nextTocUrl = resolveNextTocURLByHTMLFallback(html: html, baseUrl: baseUrl)
            if let fallbackNext = nextTocUrl {
                logChapterDebug("[\(traceTag)] page=\(pageIndex) html fallback nextTocUrl=\(fallbackNext)")
            }
        }
        logChapterDebug("[\(traceTag)] page=\(pageIndex) resolved nextTocUrl=\(nextTocUrl ?? "nil")")
        return (chapters, nextTocUrl)
    }

    private func isRegexChapterListRule(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix(":") {
            return true
        }
        if let firstPart = trimmed.components(separatedBy: "&&").first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           firstPart.hasPrefix(":") {
            return true
        }
        return false
    }

    private func parseChapterListFromRegexRule(
        listRule: String,
        tocRule: TocRule,
        html: String,
        bookUrl: String,
        baseUrl: String,
        startIndex: Int
    ) -> [BookChapter] {
        let rows = regexCaptureRows(from: listRule, html: html)
        guard !rows.isEmpty else { return [] }

        var chapters: [BookChapter] = []
        for captures in rows {
            var chapter = BookChapter()
            chapter.bookUrl = bookUrl
            chapter.baseUrl = baseUrl
            chapter.index = startIndex + chapters.count

            let titleRaw = regexCaptureValue(from: tocRule.chapterName, captures: captures)
            chapter.title = sanitizedChapterTitle(titleRaw)

            if chapter.title.isEmpty, captures.count > 2 {
                chapter.title = sanitizedChapterTitle(captures[2])
            } else if chapter.title.isEmpty, let last = captures.last {
                chapter.title = sanitizedChapterTitle(last)
            }

            var chapterURL = regexCaptureValue(from: tocRule.chapterUrl, captures: captures)
            if chapterURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, captures.count > 1 {
                chapterURL = captures[1]
            }
            let trimmedURL = chapterURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedURL.isEmpty {
                chapter.url = analyzer.extractUrl(url: trimmedURL, baseUrl: baseUrl)
            }

            if let isVolumeRule = tocRule.isVolume, !isVolumeRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let rawVolume = regexCaptureValue(from: isVolumeRule, captures: captures)
                chapter.isVolume = parseBooleanValue(rawVolume)
            }

            if let isVipRule = tocRule.isVip, !isVipRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let rawVip = regexCaptureValue(from: isVipRule, captures: captures)
                let isVip = parseBooleanValue(rawVip)
                chapter.isVip = isVip
                chapter.isPay = isVip
            }

            if let updateTimeRule = tocRule.updateTime, !updateTimeRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let updateTime = regexCaptureValue(from: updateTimeRule, captures: captures)
                if !updateTime.isEmpty {
                    chapter.tag = updateTime
                }
            }

            if chapter.title.isEmpty && !chapter.url.isEmpty {
                chapter.title = "第\(chapter.index + 1)章"
            }
            if chapter.url.isEmpty && !chapter.isVolume {
                chapter.url = baseUrl
            } else if chapter.url.isEmpty && chapter.isVolume {
                chapter.url = "\(chapter.title)\(chapter.index)"
            }

            if !chapter.title.isEmpty {
                chapters.append(chapter)
            }
        }
        return chapters
    }

    private func regexCaptureRows(from listRule: String, html: String) -> [[String]] {
        let parts = listRule
            .components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [] }

        var sources: [String] = [html]
        for (index, rawPart) in parts.enumerated() {
            var pattern = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if pattern.hasPrefix(":") {
                pattern.removeFirst()
                pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !pattern.isEmpty else { continue }

            let isLast = index == parts.count - 1
            if isLast {
                var rows: [[String]] = []
                for source in sources {
                    rows.append(contentsOf: regexCaptureRows(in: source, pattern: pattern))
                }
                return rows
            }

            var nextSources: [String] = []
            for source in sources {
                let matches = regexCaptureRows(in: source, pattern: pattern)
                for row in matches {
                    if row.count > 1 {
                        let captures = row.dropFirst().map {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        }.filter { !$0.isEmpty }
                        if !captures.isEmpty {
                            nextSources.append(contentsOf: captures)
                            continue
                        }
                    }
                    if let full = row.first?.trimmingCharacters(in: .whitespacesAndNewlines), !full.isEmpty {
                        nextSources.append(full)
                    }
                }
            }
            sources = nextSources
            if sources.isEmpty { return [] }
        }
        return []
    }

    private func regexCaptureRows(in text: String, pattern: String) -> [[String]] {
        guard let regex = cachedRegex(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }

        var rows: [[String]] = []
        for match in matches {
            var row: [String] = []
            for index in 0..<match.numberOfRanges {
                guard let range = Range(match.range(at: index), in: text) else {
                    row.append("")
                    continue
                }
                row.append(String(text[range]))
            }
            if !row.isEmpty {
                rows.append(row)
            }
        }
        return rows
    }

    private func regexCaptureValue(from expression: String?, captures: [String]) -> String {
        guard let expression = expression?.trimmingCharacters(in: .whitespacesAndNewlines), !expression.isEmpty else {
            return ""
        }

        let segments = expression.components(separatedBy: "##")
        let head = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var value: String

        if head == "$" {
            value = captures.first ?? ""
        } else if head.hasPrefix("$"), let index = Int(head.dropFirst()), index >= 0, index < captures.count {
            value = captures[index]
        } else {
            value = head
        }

        if segments.count > 2 {
            var offset = 1
            while offset + 1 < segments.count {
                let pattern = segments[offset]
                let replacement = segments[offset + 1]
                if let regex = cachedRegex(pattern: pattern) {
                    let range = NSRange(value.startIndex..., in: value)
                    value = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
                }
                offset += 2
            }
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveNextTocURL(
        html: String,
        baseUrl: String,
        nextRule: String?
    ) -> String? {
        let directValue = extractRuleValue(html: html, baseUrl: baseUrl, rule: nextRule)
        let directResolved = resolveNextTocURL(from: directValue, baseUrl: baseUrl)

        let candidates = extractNextTocCandidates(
            html: html,
            baseUrl: baseUrl,
            nextRule: nextRule
        )
        guard !candidates.isEmpty else { return directResolved }

        let normalizedCurrent = normalizeVisitKey(baseUrl)
        if let selectedIndex = candidates.firstIndex(where: { $0.isSelected }),
           selectedIndex + 1 < candidates.count {
            let candidate = candidates[selectedIndex + 1].url
            if normalizeVisitKey(candidate) != normalizedCurrent {
                return candidate
            }
        }
        if let currentIndex = candidates.firstIndex(where: { normalizeVisitKey($0.url) == normalizedCurrent }),
           currentIndex + 1 < candidates.count {
            let candidate = candidates[currentIndex + 1].url
            if normalizeVisitKey(candidate) != normalizedCurrent {
                return candidate
            }
        }

        if let directResolved, normalizeVisitKey(directResolved) != normalizedCurrent {
            return directResolved
        }
        return candidates.first(where: { normalizeVisitKey($0.url) != normalizedCurrent })?.url
    }

    private func resolveNextTocURLByHTMLFallback(html: String, baseUrl: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html, baseUrl),
              let anchors = try? doc.select("a[href]").array(),
              !anchors.isEmpty else {
            return nil
        }

        let normalizedCurrent = normalizeVisitKey(baseUrl)
        let maxScanCount = min(anchors.count, 2500)
        var allCandidates: [String] = []
        var tocEntryCandidates: [String] = []
        var nextTextCandidates: [String] = []
        var seen = Set<String>()

        for anchor in anchors.prefix(maxScanCount) {
            let rawHref = ((try? anchor.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawHref.isEmpty else { continue }
            let loweredHref = rawHref.lowercased()
            if loweredHref.hasPrefix("javascript:")
                || loweredHref.hasPrefix("#")
                || loweredHref.hasPrefix("mailto:")
                || loweredHref.hasPrefix("tel:") {
                continue
            }

            let resolved = analyzer.extractUrl(url: rawHref, baseUrl: baseUrl)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else { continue }
            let key = normalizeVisitKey(resolved)
            guard !key.isEmpty, key != normalizedCurrent, seen.insert(key).inserted else { continue }
            allCandidates.append(resolved)

            let text = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let classAttr = ((try? anchor.attr("class")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let idAttr = ((try? anchor.attr("id")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if isLikelyTocEntryAnchorText(text), isLikelyTocIndexURL(resolved) {
                tocEntryCandidates.append(resolved)
            }
            if isLikelyNextPageAnchorText(text: text, classAttr: classAttr, idAttr: idAttr) {
                nextTextCandidates.append(resolved)
            }
        }

        let isDetailPage = isLikelyBookDetailPageURL(baseUrl)
        if isDetailPage, let tocEntry = tocEntryCandidates.first {
            return tocEntry
        }

        let paginationCandidates = nextTextCandidates + allCandidates
        if let inferred = inferNextTocURLByUnderscorePage(baseUrl: baseUrl, candidates: paginationCandidates) {
            return inferred
        }

        if let nextCandidate = nextTextCandidates.first(where: { normalizeVisitKey($0) != normalizedCurrent }) {
            return nextCandidate
        }

        return nil
    }

    private func isLikelyBookDetailPageURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else { return false }
        let path = components.percentEncodedPath.lowercased()
        return path.contains("/book/") && path.hasSuffix(".html")
    }

    private func isLikelyTocEntryAnchorText(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        guard !compact.isEmpty else { return false }

        let markers = [
            "查看更多章节", "查看全部章节", "全部章节",
            "更多章节", "章节目录", "查看目录", "阅读目录"
        ]
        return markers.contains(where: { compact.contains($0.lowercased()) })
    }

    private func isLikelyTocIndexURL(_ urlString: String) -> Bool {
        let lowered = urlString.lowercased()
        if isLikelyChapterURL(lowered) {
            return false
        }
        guard let components = URLComponents(string: lowered) else { return false }
        let path = components.percentEncodedPath
        if path == "/" {
            return false
        }
        if path.hasSuffix("/") && path.count > 1 {
            return true
        }
        if path.contains("/book/") && !path.contains(".html") {
            return true
        }
        if path.range(of: #"/\d+/\d+/?$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func isLikelyNextPageAnchorText(text: String, classAttr: String, idAttr: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        let markers = ["下一页", "下页", "next", "nextpage", "后页", "»", "›"]
        if markers.contains(where: { compact.contains($0.lowercased()) }) {
            return true
        }

        let identity = "\(classAttr) \(idAttr)".lowercased()
        if identity.contains("next") && (identity.contains("page") || identity.contains("fy")) {
            return true
        }
        return false
    }

    private func inferNextTocURLByUnderscorePage(baseUrl: String, candidates: [String]) -> String? {
        guard let baseComponents = URLComponents(string: baseUrl),
              let baseHost = baseComponents.host?.lowercased() else {
            return nil
        }

        let basePath = trimmedPathWithoutTrailingSlash(baseComponents.percentEncodedPath)
        guard !basePath.isEmpty, !basePath.lowercased().hasSuffix(".html"),
              let (basePrefix, currentPage) = splitUnderscorePagePath(basePath) else {
            return nil
        }

        var best: (page: Int, url: String)?
        for candidate in candidates {
            guard let components = URLComponents(string: candidate),
                  components.host?.lowercased() == baseHost else {
                continue
            }
            let path = trimmedPathWithoutTrailingSlash(components.percentEncodedPath)
            guard !path.isEmpty,
                  let (candidatePrefix, page) = splitUnderscorePagePath(path),
                  candidatePrefix == basePrefix,
                  page > currentPage else {
                continue
            }

            if page == currentPage + 1 {
                return candidate
            }
            if let bestPage = best?.page {
                if page < bestPage {
                    best = (page, candidate)
                }
            } else {
                best = (page, candidate)
            }
        }

        return best?.url
    }

    private func trimmedPathWithoutTrailingSlash(_ rawPath: String) -> String {
        guard !rawPath.isEmpty else { return "" }
        var path = rawPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private func splitUnderscorePagePath(_ path: String) -> (prefix: String, page: Int)? {
        guard !path.isEmpty else { return nil }
        let pattern = #"^(.*?)(?:_(\d+))?$"#
        guard let regex = cachedRegex(pattern: pattern),
              let match = regex.firstMatch(in: path, options: [], range: NSRange(path.startIndex..., in: path)),
              match.numberOfRanges >= 2,
              let prefixRange = Range(match.range(at: 1), in: path) else {
            return nil
        }

        let prefix = String(path[prefixRange])
        guard !prefix.isEmpty else { return nil }

        if match.numberOfRanges > 2,
           let pageRange = Range(match.range(at: 2), in: path),
           let page = Int(path[pageRange]),
           page > 0 {
            return (prefix, page)
        }
        return (prefix, 1)
    }

    private struct NextTocCandidate {
        let url: String
        let isSelected: Bool
    }

    private func extractNextTocCandidates(
        html: String,
        baseUrl: String,
        nextRule: String?
    ) -> [NextTocCandidate] {
        guard let rawRule = nextRule?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRule.isEmpty else {
            return []
        }

        let parts = rawRule.components(separatedBy: "@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return [] }

        let tailRule = parts.last ?? ""
        let listRule = parts.dropLast().joined(separator: "@")
        guard !listRule.isEmpty,
              let elements = try? analyzer.analyzeList(html: html, rule: listRule, baseUrl: baseUrl),
              !elements.isEmpty else {
            return []
        }

        var result: [NextTocCandidate] = []
        var seen = Set<String>()
        for element in elements {
            let rawValue: String
            switch tailRule.lowercased() {
            case "text":
                rawValue = (try? element.text()) ?? ""
            case "textnodes", "owntext":
                rawValue = element.ownText()
            case "html":
                rawValue = (try? element.html()) ?? ""
            default:
                rawValue = (try? element.attr(tailRule)) ?? ""
            }

            guard let resolved = resolveNextTocURL(from: rawValue, baseUrl: baseUrl) else { continue }
            let key = normalizeVisitKey(resolved)
            guard seen.insert(key).inserted else { continue }

            let selected = element.hasAttr("selected") || element.hasClass("selected")
            result.append(NextTocCandidate(url: resolved, isSelected: selected))
        }
        return result
    }

    private func resolveNextTocURL(from rawValue: String, baseUrl: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if ["[]", "{}", "null", "undefined", "false", "0", "\"\"", "''"].contains(lowered) {
            return nil
        }

        if looksLikeJSONPayload(trimmed),
           let json = parseJSONObjectPayload(from: trimmed),
           let candidate = firstNextTocURLCandidate(in: json, baseUrl: baseUrl) {
            return candidate
        }

        let resolved = analyzer.extractUrl(url: trimmed, baseUrl: baseUrl)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return nil }
        guard !isLikelyGarbageNextTocURL(resolved) else { return nil }

        let normalizedBase = normalizeVisitKey(baseUrl)
        let normalizedResolved = normalizeVisitKey(resolved)
        if normalizedResolved == normalizedBase {
            return nil
        }
        if normalizedResolved.contains("%5B%5D") || normalizedResolved.contains("/[]") {
            return nil
        }
        return resolved
    }

    private func firstNextTocURLCandidate(in node: Any, baseUrl: String) -> String? {
        if let text = node as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let lowered = trimmed.lowercased()
            if ["[]", "{}", "null", "undefined", "false", "0", "\"\"", "''"].contains(lowered) {
                return nil
            }

            let resolved = analyzer.extractUrl(url: trimmed, baseUrl: baseUrl)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else { return nil }
            guard !isLikelyGarbageNextTocURL(resolved) else { return nil }
            if normalizeVisitKey(resolved) == normalizeVisitKey(baseUrl) {
                return nil
            }
            if resolved.contains("%5B%5D") || resolved.contains("/[]") {
                return nil
            }
            return resolved
        }

        if let array = node as? [Any] {
            for item in array {
                if let found = firstNextTocURLCandidate(in: item, baseUrl: baseUrl) {
                    return found
                }
            }
            return nil
        }

        if let dict = node as? [String: Any] {
            let prioritizedKeys = ["nextTocUrl", "nextUrl", "next", "url", "href", "link", "path"]
            for key in prioritizedKeys {
                if let value = dict[key], let found = firstNextTocURLCandidate(in: value, baseUrl: baseUrl) {
                    return found
                }
            }
            for value in dict.values {
                if let found = firstNextTocURLCandidate(in: value, baseUrl: baseUrl) {
                    return found
                }
            }
        }

        return nil
    }

    private func isLikelyGarbageNextTocURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.count > 1800 {
            return true
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") {
            return true
        }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if decoded.rangeOfCharacter(from: .newlines) != nil {
            return true
        }
        let metaTextMarkers = ["下一页", "上一页", "章节目录", "书名：", "作者：", "分类", "状态：", "在线阅读", "简介", "返回 "]
        if metaTextMarkers.contains(where: decoded.contains) {
            return true
        }
        let whitespaceCount = decoded.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.whitespaces.contains(scalar) {
                count += 1
            }
        }
        if whitespaceCount >= 10 {
            return true
        }

        let suspiciousMarkers = ["书名：", "类别：", "状态：", "作者：", "章节目录", "在线阅读", "简介", "返回 "]
        if decoded.count > 240, suspiciousMarkers.contains(where: decoded.contains) {
            return true
        }

        if let components = URLComponents(string: trimmed) {
            let decodedPath = components.percentEncodedPath.removingPercentEncoding ?? components.path
            let lastSegment = decodedPath.split(separator: "/").last.map(String.init) ?? ""
            if lastSegment.count > 180, !lastSegment.contains(".") {
                return true
            }
        }

        return false
    }

    private func applyChapterJSONPayloadFallback(
        element: Element,
        chapter: inout BookChapter,
        baseUrl: String
    ) {
        guard let payload = chapterPayloadDict(from: element) else { return }

        if chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = firstStringValue(
                in: payload,
                keys: ["name", "title", "chapterName", "chapter_title", "text", "label"]
            )
            chapter.title = sanitizedChapterTitle(title)
        }

        if chapter.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chapter.isVolume {
            let rawURL = firstStringValue(
                in: payload,
                keys: ["url", "link", "href", "chapterUrl", "chapter_url", "surl"]
            )
            if !rawURL.isEmpty {
                chapter.url = analyzer.extractUrl(url: rawURL, baseUrl: baseUrl)
            }
        }

        let volumeFlag = firstStringValue(in: payload, keys: ["isVolume", "volume", "is_vol", "isvolume"])
        if !volumeFlag.isEmpty {
            chapter.isVolume = parseBooleanValue(volumeFlag)
        }

        let existingTag = chapter.tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existingTag.isEmpty {
            chapter.tag = firstStringValue(in: payload, keys: ["info", "tag", "updateTime", "update_time"])
        }
    }

    private func chapterPayloadDict(from element: Element) -> [String: Any]? {
        guard let raw = try? element.attr("data-json") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    private func parseContentPage(html: String, url: String, source: BookSource) throws -> ChapterContent {
        guard let rule = source.ruleContent else {
            throw ParserError.noRule
        }

        var content = ChapterContent()
        content.url = url

        let parsedTitle = extractRuleValue(html: html, baseUrl: url, rule: rule.title)
        if !parsedTitle.isEmpty {
            content.title = sanitizedPlainText(parsedTitle)
        }

        let parsedContent = extractRuleValue(html: html, baseUrl: url, rule: rule.content)
        let mergedListContent = extractMergedListContent(html: html, baseUrl: url, rule: rule.content)
        let htmlStructuredContent = extractStructuredHTMLFallbackContent(
            html: html,
            baseUrl: url,
            rule: rule.content
        )
        content.content = preferRichContent(primary: parsedContent, fallback: mergedListContent)
        if shouldPreferHTMLStructuredContent(primary: content.content, htmlStructured: htmlStructuredContent) {
            content.content = htmlStructuredContent
        }

        if content.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let extracted = extractReadableTextFromJSONPayload(html, baseUrl: url) {
            content.content = extracted.text
            if !extracted.imageUrls.isEmpty {
                content.imageUrls = extracted.imageUrls
            }
        }

        // 兜底：部分站点正文规则返回文本时，图片地址可能丢失。
        // 再按正文选择器直接抓取 img/a/source 中的图片 URL，保证漫画模式可用。
        if content.imageUrls?.isEmpty ?? true {
            let selectorImages = extractImageUrlsFromContentRuleElements(
                html: html,
                baseUrl: url,
                rule: rule.content
            )
            if !selectorImages.isEmpty {
                content.imageUrls = selectorImages
            }
        }

        let nextRule = (rule.nextContentUrl?.isEmpty == false) ? rule.nextContentUrl : rule.nextContentBtn
        if let nextRule {
            let nextUrl = extractRuleValue(html: html, baseUrl: url, rule: nextRule)
            if !nextUrl.isEmpty {
                content.nextUrl = analyzer.extractUrl(url: nextUrl, baseUrl: url)
            }
        }
        return content
    }

    private func extractStructuredHTMLFallbackContent(html: String, baseUrl: String, rule: String?) -> String {
        guard let rawRule = rule?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRule.isEmpty else {
            return ""
        }

        if let selectorRule = stripTextRuleSuffix(from: rawRule),
           let mergedHTML = extractStructuredHTMLFromElements(
               html: html,
               baseUrl: baseUrl,
               selectorRule: selectorRule
           ) {
            return formatHTMLToReadableText(mergedHTML)
        }

        guard let htmlRule = makeHTMLFallbackRule(from: rawRule) else { return "" }
        let htmlValue = extractRuleValue(html: html, baseUrl: baseUrl, rule: htmlRule)
        guard !htmlValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard containsHTMLMarkup(htmlValue) else { return "" }
        return formatHTMLToReadableText(htmlValue)
    }

    private func stripTextRuleSuffix(from rawRule: String) -> String? {
        let lowered = rawRule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffixes = ["@textnodes", "@owntext", "@text"]
        for suffix in suffixes {
            guard lowered.hasSuffix(suffix) else { continue }
            let dropCount = suffix.count
            let endIndex = rawRule.index(rawRule.endIndex, offsetBy: -dropCount)
            let prefix = String(rawRule[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty else { return nil }
            return prefix
        }
        return nil
    }

    private func makeHTMLFallbackRule(from rawRule: String) -> String? {
        guard let prefix = stripTextRuleSuffix(from: rawRule) else { return nil }
        return "\(prefix)@html"
    }

    private func extractStructuredHTMLFromElements(html: String, baseUrl: String, selectorRule: String) -> String? {
        guard !selectorRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let elements = try? analyzer.analyzeList(html: html, rule: selectorRule, baseUrl: baseUrl),
              !elements.isEmpty else {
            return nil
        }
        let fragments = elements.compactMap { try? $0.html() }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !fragments.isEmpty else { return nil }
        let merged = fragments.joined(separator: "\n")
        guard containsHTMLMarkup(merged) else { return nil }
        return merged
    }

    private func shouldPreferHTMLStructuredContent(primary: String, htmlStructured: String) -> Bool {
        let cleanPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanStructured = htmlStructured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanStructured.isEmpty else { return false }
        if cleanPrimary.isEmpty { return true }
        if cleanStructured == cleanPrimary { return false }

        let primaryLineCount = cleanPrimary
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        let structuredLineCount = cleanStructured
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count

        if structuredLineCount >= 2 && primaryLineCount <= 1 {
            return true
        }
        if structuredLineCount > primaryLineCount && cleanStructured.count > cleanPrimary.count {
            return true
        }
        if cleanStructured.count > cleanPrimary.count, cleanStructured.contains(cleanPrimary) {
            return true
        }
        return false
    }

    private func extractRuleValue(html: String, baseUrl: String, rule: String?) -> String {
        guard let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            return ""
        }

        if rule.lowercased().hasPrefix("@xpath:") || rule.hasPrefix("//") || rule.lowercased().hasPrefix("@json:") || rule.hasPrefix("$") {
            return analyzer.analyzeElementText(html: html, rule: rule, baseUrl: baseUrl)
        }

        do {
            let doc = try SwiftSoup.parse(html, baseUrl)
            if let body = doc.body(),
               let value = try? analyzer.analyzeElement(element: body, rule: rule, baseUrl: baseUrl),
               !value.isEmpty {
                return value
            }

            if let element = try doc.select(rule).first() {
                return (try? element.text()) ?? ""
            }
        } catch {
            return ""
        }

        return ""
    }

    private func resolveBookInfoPayload(html: String, baseUrl: String, initRule: String?) -> String {
        guard let initRule = initRule?.trimmingCharacters(in: .whitespacesAndNewlines),
              !initRule.isEmpty else {
            return html
        }
        let payload = extractRuleValue(html: html, baseUrl: baseUrl, rule: initRule)
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? html : trimmed
    }

    private func resolveBookInfoTocRule(rule: String?, payload: String, baseUrl: String) -> String {
        guard let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            return ""
        }
        guard rule.contains("{{"), rule.contains("}}") else {
            return rule
        }
        return resolveJSONPathPlaceholders(in: rule, payload: payload, baseUrl: baseUrl)
    }

    private func looksLikeURLText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("://") || trimmed.hasPrefix("//") || trimmed.hasPrefix("/")
    }

    private func extractMergedListContent(html: String, baseUrl: String, rule: String?) -> String {
        guard let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rule.isEmpty else {
            return ""
        }

        let parts = rule.components(separatedBy: "@").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard parts.count >= 2 else { return "" }

        let tail = parts.last?.lowercased() ?? ""
        guard ["text", "html", "textnodes", "owntext"].contains(tail) else {
            return ""
        }

        let listRule = parts.dropLast().joined(separator: "@")
        guard !listRule.isEmpty,
              let elements = try? analyzer.analyzeList(html: html, rule: listRule, baseUrl: baseUrl),
              elements.count > 1 else {
            return ""
        }

        var chunks: [String] = []
        for element in elements {
            let piece: String
            switch tail {
            case "html":
                piece = (try? element.html()) ?? ""
            case "textnodes", "owntext":
                piece = element.ownText()
            default:
                piece = (try? element.text()) ?? ""
            }
            let cleaned = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                chunks.append(cleaned)
            }
        }
        guard !chunks.isEmpty else { return "" }
        return chunks.joined(separator: "\n")
    }

    private func extractImageUrlsFromContentRuleElements(html: String, baseUrl: String, rule: String?) -> [String] {
        guard let selectorRule = contentSelectorRule(from: rule),
              let elements = try? analyzer.analyzeList(html: html, rule: selectorRule, baseUrl: baseUrl),
              !elements.isEmpty else {
            return []
        }

        var result: [String] = []
        for element in elements {
            appendImageCandidates(from: element, baseUrl: baseUrl, into: &result)
            if let descendants = try? element.select("img,source,a").array() {
                for node in descendants {
                    appendImageCandidates(from: node, baseUrl: baseUrl, into: &result)
                }
            }
        }
        return uniqueStrings(result)
    }

    private func contentSelectorRule(from rule: String?) -> String? {
        guard let raw = rule?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let lowered = raw.lowercased()
        if lowered.hasPrefix("@xpath:") || raw.hasPrefix("//") || lowered.hasPrefix("@json:") || raw.hasPrefix("$") {
            return nil
        }

        let firstSegment = raw
            .components(separatedBy: "&&")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        guard !firstSegment.isEmpty else { return nil }
        if firstSegment.contains("{{") || firstSegment.contains("}}") {
            return nil
        }

        if let atIndex = firstSegment.lastIndex(of: "@") {
            let prefix = String(firstSegment[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                return prefix
            }
        }
        return firstSegment
    }

    private func appendImageCandidates(from element: Element, baseUrl: String, into result: inout [String]) {
        let attributeKeys = [
            "src", "data-src", "data-original", "data-lazy-src", "data-srcset", "srcset", "href"
        ]
        for key in attributeKeys {
            let raw = (try? element.attr(key)) ?? ""
            appendImageURL(raw, baseUrl: baseUrl, into: &result)
        }
    }

    private func appendImageURL(_ raw: String, baseUrl: String, into result: inout [String]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        for candidate in splitSrcsetCandidatesIfNeeded(trimmed) {
            let resolved = analyzer.extractUrl(url: candidate, baseUrl: baseUrl)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else { continue }
            guard isLikelyImageURL(resolved) else { continue }
            if !result.contains(resolved) {
                result.append(resolved)
            }
        }
    }

    private func splitSrcsetCandidatesIfNeeded(_ raw: String) -> [String] {
        let normalized = raw.replacingOccurrences(of: "&amp;", with: "&")
        if normalized.contains(",") {
            let parts = normalized
                .split(separator: ",")
                .map { item in
                    item.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(whereSeparator: \.isWhitespace)
                        .first
                        .map(String.init) ?? ""
                }
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                return parts
            }
        }
        return [normalized]
    }

    private func isLikelyImageURL(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        let lowered = (value.removingPercentEncoding ?? value).lowercased()
        if lowered.hasPrefix("javascript:") || lowered.hasPrefix("data:") {
            return false
        }
        let pattern = #"\.(jpg|jpeg|png|gif|webp|bmp|avif|heic|heif)(\?|#|$)"#
        return lowered.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func preferRichContent(primary: String, fallback: String) -> String {
        let cleanPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanPrimary.isEmpty { return cleanFallback }
        if cleanFallback.isEmpty { return cleanPrimary }

        let primaryLineCount = cleanPrimary
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        let fallbackLineCount = cleanFallback
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count

        if fallbackLineCount >= 2 && primaryLineCount <= 1 && cleanFallback.count > cleanPrimary.count {
            return cleanFallback
        }
        if fallbackLineCount > primaryLineCount && cleanFallback.count >= cleanPrimary.count * 2 {
            return cleanFallback
        }
        return cleanPrimary
    }

    private func applyReplaceRule(content: String, rule: String) -> String {
        var result = content
        let regexParts = rule.components(separatedBy: "##")

        for i in stride(from: 0, to: regexParts.count - 1, by: 2) {
            let pattern = regexParts[i]
            let replacement = regexParts.count > i + 1 ? regexParts[i + 1] : ""

            if let regex = cachedRegex(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }

        return result
    }

    private func applySourceRegex(content: String, rule: String) -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return content }

        let pattern: String
        if trimmedRule.hasPrefix("##") {
            pattern = String(trimmedRule.dropFirst(2))
        } else {
            pattern = trimmedRule
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return content
        }

        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "")
    }

    private func normalizeListRule(_ rule: String) -> (rule: String, reverse: Bool) {
        var trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        var reverse = false
        if trimmed.hasPrefix("-") {
            reverse = true
            trimmed.removeFirst()
        } else if trimmed.hasPrefix("+") {
            trimmed.removeFirst()
        }
        return (trimmed.trimmingCharacters(in: .whitespacesAndNewlines), reverse)
    }

    private func parseBooleanValue(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "true", "yes", "y", "t", "vip", "pay", "paid", "volume"].contains(normalized)
    }

    private func deduplicateChapters(_ chapters: [BookChapter]) -> [BookChapter] {
        var seenPrimary = Set<String>()
        var result: [BookChapter] = []
        for chapter in chapters {
            let primaryKey = chapterDedupKey(chapter)
            if !primaryKey.isEmpty, !seenPrimary.insert(primaryKey).inserted {
                continue
            }
            result.append(chapter)
        }
        return result
    }

    private func chapterDedupKey(_ chapter: BookChapter) -> String {
        let normalizedURL = normalizeChapterURLForDedup(chapter.url).lowercased()
        let normalizedTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedURL.isEmpty {
            return normalizedTitle.isEmpty ? "" : "\(normalizedTitle)|\(chapter.isVolume)"
        }
        return "\(normalizedURL)|\(normalizedTitle)|\(chapter.isVolume)"
    }

    private func normalizeChapterURLForDedup(_ rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if looksLikeRequestRule(trimmed) {
            return trimmed
        }
        guard var components = URLComponents(string: trimmed) else {
            return trimmed
        }

        components.fragment = nil
        if let host = components.host, !host.isEmpty {
            components.host = host.lowercased()
        }

        var normalizedPath = components.percentEncodedPath
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        components.percentEncodedPath = normalizedPath

        if let items = components.queryItems, !items.isEmpty {
            let keptItems = items.filter { item in
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !name.isEmpty else { return false }
                return !isLikelyTrackingQueryName(name)
            }
            components.queryItems = keptItems.isEmpty ? nil : keptItems.sorted(by: { $0.name < $1.name })
        }

        return components.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
    }

    private func isLikelyTrackingQueryName(_ name: String) -> Bool {
        if name.hasPrefix("utm_") {
            return true
        }
        let tokens = [
            "from", "source", "src", "spm", "ref", "referer",
            "share", "channel", "timestamp", "ts", "scene"
        ]
        return tokens.contains(name)
    }

    private func reorderChaptersIfNeeded(_ chapters: [BookChapter]) -> [BookChapter] {
        guard chapters.count >= 6 else { return chapters }

        let measured = chapters.enumerated().compactMap { item -> (index: Int, number: Int)? in
            guard let number = chapterSequenceNumber(for: item.element) else { return nil }
            return (item.offset, number)
        }
        guard measured.count >= max(6, chapters.count / 3) else { return chapters }

        let originalNumbers = measured.sorted { $0.index < $1.index }.map(\.number)
        let originalScore = monotonicScore(originalNumbers)

        var candidate = chapters
        if monotonicDirection(of: originalNumbers) == .descending {
            candidate = Array(chapters.reversed())
        }

        let candidateMeasured = candidate.enumerated().map { item in
            (index: item.offset, chapter: item.element, number: chapterSequenceNumber(for: item.element))
        }

        let sortableCount = candidateMeasured.reduce(into: 0) { count, item in
            if item.number != nil { count += 1 }
        }
        guard sortableCount >= max(6, candidate.count / 3) else { return candidate }

        let sortedCandidate = candidateMeasured.sorted { lhs, rhs in
            switch (lhs.number, rhs.number) {
            case let (l?, r?):
                if l != r { return l < r }
                return lhs.index < rhs.index
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return lhs.index < rhs.index
            }
        }.map(\.chapter)

        let sortedNumbers = sortedCandidate.compactMap { chapterSequenceNumber(for: $0) }
        let sortedScore = monotonicScore(sortedNumbers)

        if sortedScore > originalScore + max(3, sortedNumbers.count / 8) {
            return sortedCandidate
        }
        return candidate
    }

    private enum ChapterDirection {
        case ascending
        case descending
        case mixed
    }

    private func monotonicDirection(of numbers: [Int]) -> ChapterDirection {
        guard numbers.count >= 4 else { return .mixed }
        var asc = 0
        var desc = 0
        for idx in 1..<numbers.count {
            if numbers[idx] > numbers[idx - 1] { asc += 1 }
            if numbers[idx] < numbers[idx - 1] { desc += 1 }
        }
        if asc >= desc * 2 { return .ascending }
        if desc >= asc * 2 { return .descending }
        return .mixed
    }

    private func monotonicScore(_ numbers: [Int]) -> Int {
        guard numbers.count >= 2 else { return 0 }
        var asc = 0
        var desc = 0
        for idx in 1..<numbers.count {
            if numbers[idx] >= numbers[idx - 1] {
                asc += 1
            } else {
                desc += 1
            }
        }
        return asc - desc
    }

    private func chapterSequenceNumber(for chapter: BookChapter) -> Int? {
        if let titleNumber = extractChapterNumber(from: chapter.title) {
            return titleNumber
        }
        return extractTailNumber(from: chapter.url)
    }

    private func extractChapterNumber(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns = [
            "第\\s*([零〇○一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟\\d]+)\\s*[章节回卷集话部篇幕]",
            "^\\s*([0-9]{1,6})\\s*[\\.、\\-\\s]",
            "(?i)chapter\\s*([0-9]{1,6})"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: trimmed) else {
                continue
            }
            let raw = String(trimmed[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int(raw), number > 0 {
                return number
            }
            if let number = chineseNumberToInt(raw), number > 0 {
                return number
            }
        }
        return nil
    }

    private func extractTailNumber(from rawURL: String) -> Int? {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "(\\d{1,7})(?!.*\\d)") else { return nil }
        let nsRange = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Int(value[range])
    }

    private func chineseNumberToInt(_ text: String) -> Int? {
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "○": 0,
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9,
            "壹": 1, "贰": 2, "叁": 3, "肆": 4, "伍": 5,
            "陆": 6, "柒": 7, "捌": 8, "玖": 9
        ]
        let units: [Character: Int] = [
            "十": 10, "拾": 10,
            "百": 100, "佰": 100,
            "千": 1000, "仟": 1000,
            "万": 10000
        ]

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if let direct = Int(cleaned) { return direct }

        var total = 0
        var section = 0
        var number = 0

        for char in cleaned {
            if let digit = digits[char] {
                number = digit
                continue
            }
            guard let unit = units[char] else { continue }
            if unit == 10000 {
                section = (section + number) * unit
                total += section
                section = 0
                number = 0
            } else {
                let value = number == 0 ? 1 : number
                section += value * unit
                number = 0
            }
        }
        let value = total + section + number
        return value > 0 ? value : nil
    }

    private func normalizeVisitKey(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveChapterURLRule(
        rule: String,
        element: Element,
        baseUrl: String,
        source: BookSource
    ) -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return "" }

        if looksLikeRequestRule(trimmedRule) {
            let resolvedRule = resolveJSONPathPlaceholders(in: trimmedRule, element: element, baseUrl: baseUrl)
            let descriptor = RuleURLRequestBuilder.build(
                ruleUrl: resolvedRule,
                baseUrl: baseUrl,
                defaultHeaders: sourceHeaders(source),
                sourceKey: source.bookSourceUrl,
                sourceHeader: source.header,
                sourceComment: nil,
                sourceName: source.bookSourceName
            )
            return serializeRequestRule(descriptor)
        }

        guard let parsedValue = try? analyzer.analyzeElement(element: element, rule: trimmedRule, baseUrl: baseUrl),
              !parsedValue.isEmpty else {
            return ""
        }

        if looksLikeRequestRule(parsedValue) {
            let resolvedRule = resolveJSONPathPlaceholders(in: parsedValue, element: element, baseUrl: baseUrl)
            let descriptor = RuleURLRequestBuilder.build(
                ruleUrl: resolvedRule,
                baseUrl: baseUrl,
                defaultHeaders: sourceHeaders(source),
                sourceKey: source.bookSourceUrl,
                sourceHeader: source.header,
                sourceComment: nil,
                sourceName: source.bookSourceName
            )
            return serializeRequestRule(descriptor)
        }

        return analyzer.extractUrl(url: parsedValue, baseUrl: baseUrl)
    }

    private func resolveBookURLRule(
        rule: String,
        element: Element,
        baseUrl: String,
        source: BookSource
    ) -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return "" }

        if looksLikeRequestRule(trimmedRule) {
            let resolvedRule = resolveJSONPathPlaceholders(in: trimmedRule, element: element, baseUrl: baseUrl)
            let descriptor = RuleURLRequestBuilder.build(
                ruleUrl: resolvedRule,
                baseUrl: baseUrl,
                defaultHeaders: sourceHeaders(source),
                sourceKey: source.bookSourceUrl,
                sourceHeader: source.header,
                sourceComment: nil,
                sourceName: source.bookSourceName
            )
            return serializeRequestRule(descriptor)
        }

        let parsedValue = (try? analyzer.analyzeElement(element: element, rule: trimmedRule, baseUrl: baseUrl)) ?? ""
        if !parsedValue.isEmpty {
            if looksLikeRequestRule(parsedValue) {
                let resolvedRule = resolveJSONPathPlaceholders(in: parsedValue, element: element, baseUrl: baseUrl)
                let descriptor = RuleURLRequestBuilder.build(
                    ruleUrl: resolvedRule,
                    baseUrl: baseUrl,
                    defaultHeaders: sourceHeaders(source),
                    sourceKey: source.bookSourceUrl,
                    sourceHeader: source.header,
                    sourceComment: nil,
                    sourceName: source.bookSourceName
                )
                return serializeRequestRule(descriptor)
            }
            return analyzer.extractUrl(url: parsedValue, baseUrl: baseUrl)
        }

        let resolvedFallback = resolveJSONPathPlaceholders(in: trimmedRule, element: element, baseUrl: baseUrl)
        if looksLikeRequestRule(resolvedFallback) {
            let descriptor = RuleURLRequestBuilder.build(
                ruleUrl: resolvedFallback,
                baseUrl: baseUrl,
                defaultHeaders: sourceHeaders(source),
                sourceKey: source.bookSourceUrl,
                sourceHeader: source.header,
                sourceComment: nil,
                sourceName: source.bookSourceName
            )
            return serializeRequestRule(descriptor)
        }

        if resolvedFallback.contains("://") || resolvedFallback.hasPrefix("/") || resolvedFallback.hasPrefix("//") {
            return analyzer.extractUrl(url: resolvedFallback, baseUrl: baseUrl)
        }
        return ""
    }

    private func looksLikeRequestRule(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if lowered.contains("@post->") { return true }
        if lowered.contains("@header:{") { return true }
        if trimmed.contains(",{"), (trimmed.contains("://") || trimmed.hasPrefix("//") || trimmed.hasPrefix("/")) {
            return true
        }
        return false
    }

    private func resolveJSONPathPlaceholders(in rawRule: String, element: Element, baseUrl: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{([\\w\\W]*?)\\}\\}") else {
            return rawRule
        }

        var result = rawRule
        let nsRange = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, options: [], range: nsRange)
        if matches.isEmpty { return result }

        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range, in: result),
                  let expressionRange = Range(match.range(at: 1), in: result) else { continue }

            let expression = String(result[expressionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredExpression = expression.lowercased()
            let isJSONPath = expression == "$" || expression.hasPrefix("$.") || loweredExpression.hasPrefix("@json:")
            guard isJSONPath else { continue }

            var candidates: [String] = [expression]
            if loweredExpression.hasPrefix("@json:") {
                let stripped = String(expression.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    candidates.append(stripped)
                }
            } else if expression.hasPrefix("$") {
                candidates.append("@Json:\(expression)")
            }

            var value = ""
            for candidate in candidates where !candidate.isEmpty {
                value = (try? analyzer.analyzeElement(element: element, rule: candidate, baseUrl: baseUrl)) ?? ""
                if !value.isEmpty {
                    break
                }
            }
            result.replaceSubrange(fullRange, with: value)
        }

        return result
    }

    private func resolveJSONPathPlaceholders(in rawRule: String, payload: String, baseUrl: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{([\\w\\W]*?)\\}\\}") else {
            return rawRule
        }

        var result = rawRule
        let nsRange = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, options: [], range: nsRange)
        if matches.isEmpty { return result }

        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range, in: result),
                  let expressionRange = Range(match.range(at: 1), in: result) else { continue }

            let expression = String(result[expressionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredExpression = expression.lowercased()
            let isJSONPath = expression == "$" || expression.hasPrefix("$.") || loweredExpression.hasPrefix("@json:")
            guard isJSONPath else { continue }

            var candidates: [String] = [expression]
            if loweredExpression.hasPrefix("@json:") {
                let stripped = String(expression.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    candidates.append(stripped)
                }
            } else if expression.hasPrefix("$") {
                candidates.append("@Json:\(expression)")
            }

            var value = ""
            for candidate in candidates where !candidate.isEmpty {
                value = analyzer.analyzeElementText(html: payload, rule: candidate, baseUrl: baseUrl)
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
            }
            result.replaceSubrange(fullRange, with: value)
        }

        return result
    }

    private func serializeRequestRule(_ descriptor: RuleRequestDescriptor) -> String {
        var options: [String: Any] = [:]
        let method = descriptor.method.uppercased()
        if method != "GET" {
            options["method"] = method
        }
        if let body = descriptor.body, !body.isEmpty {
            options["body"] = body
        }
        if !descriptor.headers.isEmpty {
            options["headers"] = descriptor.headers
        }
        if let retries = descriptor.retries {
            options["retry"] = retries
        }
        if let charset = descriptor.charset, !charset.isEmpty {
            options["charset"] = charset
        }

        guard !options.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: options),
              let json = String(data: data, encoding: .utf8) else {
            return descriptor.url
        }
        return "\(descriptor.url),\(json)"
    }

    private func applyPageScriptIfNeeded(_ html: String, script: String?, baseUrl: String) -> String {
        let normalizedScript = normalizePageScript(script)
        guard !normalizedScript.isEmpty else { return html }
#if canImport(JavaScriptCore)
        guard let context = JSContext() else { return html }

        RuleURLRequestBuilder.prepareJavaScriptContext(
            context,
            key: nil,
            encodedKey: nil,
            page: 1,
            baseUrl: baseUrl,
            result: html,
            sourceKey: baseUrl,
            sourceHeader: nil,
            sourceComment: nil,
            sourceName: nil,
            defaultHeaders: [:],
            elementContext: nil
        )
        context.setObject(html, forKeyedSubscript: "html" as NSString)
        context.setObject(html, forKeyedSubscript: "source" as NSString)

        let candidates = [
            normalizedScript,
            "(function(){\(normalizedScript)})()",
            "(function(){ return (\(normalizedScript)); })()"
        ]

        for candidate in candidates {
            guard let value = context.evaluateScript(candidate),
                  !value.isUndefined,
                  !value.isNull,
                  let rendered = value.toString()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rendered.isEmpty else {
                continue
            }

            let lowered = rendered.lowercased()
            if ["undefined", "null", "true", "false", "[object object]"].contains(lowered) {
                continue
            }
            return rendered
        }
#endif
        return html
    }

    private func normalizePageScript(_ script: String?) -> String {
        guard var script = script?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else {
            return ""
        }
        if script.lowercased().hasPrefix("@js:") {
            script = String(script.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lower = script.lowercased()
        if lower.hasPrefix("<js>"), lower.hasSuffix("</js>"), script.count > 9 {
            let start = script.index(script.startIndex, offsetBy: 4)
            let end = script.index(script.endIndex, offsetBy: -5)
            script = String(script[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return script
    }
    
    private func normalizeChapterContent(_ content: ChapterContent, baseUrl: String) -> ChapterContent {
        var normalized = content
        var raw = normalized.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return normalized }

        if let extracted = extractReadableTextFromJSONPayload(raw, baseUrl: baseUrl) {
            raw = extracted.text
            if !extracted.imageUrls.isEmpty {
                normalized.imageUrls = extracted.imageUrls
            }
        }

        if containsHTMLMarkup(raw) {
            let images = extractImageUrls(from: raw, baseUrl: baseUrl)
            if !images.isEmpty {
                normalized.imageUrls = images
            }
            normalized.content = formatHTMLToReadableText(raw)
        } else {
            // 一些站点正文会先返回转义后的 HTML（如 &lt;p&gt;...）。
            // 先解码，再二次检测是否仍是 HTML 结构，确保不会把标签原样展示给读者。
            let decoded = decodeHTMLEntities(in: raw)
            if containsHTMLMarkup(decoded) {
                let images = extractImageUrls(from: decoded, baseUrl: baseUrl)
                if !images.isEmpty {
                    normalized.imageUrls = images
                }
                normalized.content = formatHTMLToReadableText(decoded)
            } else {
                normalized.content = decoded
            }
        }
        
        normalized.content = normalized.content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    private func sanitizedPlainText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return looksLikeJSONLikeText(trimmed) ? "" : trimmed
    }

    private func sanitizedChapterTitle(_ raw: String) -> String {
        let cleaned = sanitizedPlainText(raw)
        guard !cleaned.isEmpty else { return "" }
        if cleaned.count > 120, cleaned.contains("{"), cleaned.contains(":") {
            return ""
        }
        return cleaned
    }

    private func looksLikeJSONLikeText(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let unwrapped = unwrapJSONStringContainer(trimmed)
        if looksLikeJSONPayload(unwrapped) {
            return true
        }
        let lowered = unwrapped.lowercased()
        if (lowered.contains("\"code\"") || lowered.contains("\"data\"") || lowered.contains("\"msg\""))
            && (unwrapped.contains("{") || unwrapped.contains("[")) {
            return true
        }
        return false
    }

    private func parseChapterListFromJSONPayload(
        html: String,
        bookUrl: String,
        baseUrl: String,
        startIndex: Int
    ) -> [BookChapter] {
        guard let object = parseJSONObjectPayload(from: html) else { return [] }
        let candidates = chapterArrayCandidates(in: object)
        guard let best = candidates.max(by: { $0.count < $1.count }) else { return [] }

        let titleKeys = ["title", "name", "chapterName", "chapter_title", "chapter", "text"]
        let urlKeys = ["url", "href", "link", "chapterUrl", "chapter_url"]

        var chapters: [BookChapter] = []
        for node in best {
            guard let dict = node as? [String: Any] else { continue }
            let title = sanitizedChapterTitle(firstStringValue(in: dict, keys: titleKeys))
            let rawURL = firstStringValue(in: dict, keys: urlKeys)
            let resolvedURL = rawURL.isEmpty ? "" : analyzer.extractUrl(url: rawURL, baseUrl: baseUrl)

            var chapter = BookChapter()
            chapter.bookUrl = bookUrl
            chapter.baseUrl = baseUrl
            chapter.index = startIndex + chapters.count
            chapter.url = resolvedURL.isEmpty ? rawURL : resolvedURL
            chapter.title = title

            if chapter.title.isEmpty && !chapter.url.isEmpty {
                chapter.title = "第\(chapter.index + 1)章"
            }

            if !chapter.title.isEmpty {
                if chapter.url.isEmpty {
                    chapter.url = baseUrl
                }
                chapters.append(chapter)
            }
        }

        var deduplicated = deduplicateChapters(chapters)
        for idx in deduplicated.indices {
            deduplicated[idx].index = startIndex + idx
        }
        return deduplicated
    }

    private func shouldTriggerAutoChapterFallback(_ chapters: [BookChapter], baseUrl: String) -> Bool {
        if chapters.isEmpty {
            return true
        }
        let nonVolume = chapters.filter { !$0.isVolume }
        guard !nonVolume.isEmpty else { return true }

        let validURLCount = countValidChapterURLs(nonVolume, baseUrl: baseUrl)
        if validURLCount == 0 {
            return true
        }

        let likelyTitleCount = countLikelyChapterTitles(nonVolume)
        if nonVolume.count >= 8 && (validURLCount <= 1 || likelyTitleCount <= 1) {
            return true
        }
        if nonVolume.count >= 20 && likelyTitleCount * 4 < nonVolume.count {
            return true
        }
        return false
    }

    private func parseChapterListFromHTMLAutoDetection(
        html: String,
        bookUrl: String,
        baseUrl: String,
        startIndex: Int
    ) -> [BookChapter] {
        guard let doc = try? SwiftSoup.parse(html, baseUrl),
              let anchors = try? doc.select("a[href]").array(),
              !anchors.isEmpty else {
            return []
        }

        let maxScanCount = min(anchors.count, 5000)
        let slice = anchors.prefix(maxScanCount)
        var candidates: [(title: String, url: String)] = []
        var seen = Set<String>()

        for anchor in slice {
            let rawHref = ((try? anchor.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawHref.isEmpty else { continue }
            let loweredHref = rawHref.lowercased()
            if loweredHref.hasPrefix("javascript:")
                || loweredHref.hasPrefix("#")
                || loweredHref.hasPrefix("mailto:")
                || loweredHref.hasPrefix("tel:") {
                continue
            }

            let resolvedURL = analyzer.extractUrl(url: rawHref, baseUrl: baseUrl).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolvedURL.isEmpty else { continue }
            if normalizeVisitKey(resolvedURL) == normalizeVisitKey(baseUrl) {
                continue
            }

            let titleRaw = (try? anchor.text()) ?? ""
            let title = sanitizedChapterTitle(titleRaw)
            guard !title.isEmpty, !isNoiseAnchorTitle(title) else { continue }

            let dedupeKey = "\(resolvedURL)|\(title)"
            if seen.insert(dedupeKey).inserted {
                candidates.append((title: title, url: resolvedURL))
            }
        }

        guard !candidates.isEmpty else { return [] }
        var preferred = candidates.filter { isLikelyChapterTitle($0.title) || isLikelyChapterURL($0.url) }
        if preferred.count < 6 {
            guard candidates.count >= 3 else { return [] }
            preferred = candidates
        }
        if preferred.count > 2000 {
            return []
        }

        var chapters: [BookChapter] = []
        for (offset, item) in preferred.enumerated() {
            var chapter = BookChapter()
            chapter.bookUrl = bookUrl
            chapter.baseUrl = baseUrl
            chapter.index = startIndex + offset
            chapter.title = item.title
            chapter.url = item.url
            chapters.append(chapter)
        }

        var deduplicated = deduplicateChapters(chapters)
        for idx in deduplicated.indices {
            deduplicated[idx].index = startIndex + idx
        }
        return deduplicated
    }

    private func chooseBetterChapterList(primary: [BookChapter], fallback: [BookChapter], baseUrl: String) -> [BookChapter] {
        guard !fallback.isEmpty else { return primary }
        guard !primary.isEmpty else { return fallback }

        let primaryScore = chapterQualityScore(primary, baseUrl: baseUrl)
        let fallbackScore = chapterQualityScore(fallback, baseUrl: baseUrl)

        if fallbackScore > primaryScore {
            return fallback
        }
        if fallback.count > primary.count * 2 && fallbackScore >= primaryScore {
            return fallback
        }
        return primary
    }

    private func chapterQualityScore(_ chapters: [BookChapter], baseUrl: String) -> Int {
        let nonVolume = chapters.filter { !$0.isVolume }
        guard !nonVolume.isEmpty else { return 0 }

        let validURLCount = countValidChapterURLs(nonVolume, baseUrl: baseUrl)
        let likelyTitleCount = countLikelyChapterTitles(nonVolume)
        var score = nonVolume.count * 2 + validURLCount * 3 + likelyTitleCount
        if validURLCount == 0 {
            score -= nonVolume.count
        }
        return score
    }

    private func countValidChapterURLs(_ chapters: [BookChapter], baseUrl: String) -> Int {
        var urlSet = Set<String>()
        for chapter in chapters {
            let url = normalizeVisitKey(chapter.url)
            guard !url.isEmpty, url != normalizeVisitKey(baseUrl) else { continue }
            urlSet.insert(url)
        }
        return urlSet.count
    }

    private func countLikelyChapterTitles(_ chapters: [BookChapter]) -> Int {
        chapters.reduce(into: 0) { partial, chapter in
            if isLikelyChapterTitle(chapter.title) {
                partial += 1
            }
        }
    }

    private func isLikelyChapterTitle(_ raw: String) -> Bool {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }

        let patterns = [
            #"第[\s0-9零一二三四五六七八九十百千万两〇○壹贰叁肆伍陆柒捌玖拾佰仟A-Za-z\-—:：]{1,24}[章节回卷集话部篇幕]"#,
            #"^(序章|楔子|引子|前言|后记|终章|尾声|番外|正文)"#,
            #"^\s*\d{1,5}[\.\-、\s_].{1,40}$"#,
            #"(?i)\bchapter\b"#
        ]

        for pattern in patterns {
            if title.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private func isLikelyChapterURL(_ raw: String) -> Bool {
        let value = raw.lowercased()
        let tokens = [
            "/chapter", "chapter/", "/chap/", "/read/", "chapterid=", "cid=",
            ".html", ".htm", ".xhtml", ".shtml", "/txt/"
        ]
        return tokens.contains(where: { value.contains($0) })
    }

    private func isNoiseAnchorTitle(_ raw: String) -> Bool {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return true }

        let exactNoise = Set([
            "上一页", "下一页", "首页", "尾页", "目录", "章节目录",
            "返回目录", "返回首页", "加入书架", "手机阅读", "下载",
            "投推荐票", "我要评论", "举报", "展开", "收起"
        ])
        if exactNoise.contains(title) {
            return true
        }

        let pageNavPattern = #"^(第?\s*\d+\s*页|[0-9]{1,4}|[<>«»‹›]+|\.{2,})$"#
        if title.range(of: pageNavPattern, options: .regularExpression) != nil {
            return true
        }

        let fuzzyNoise = ["登录", "注册", "搜索", "排行", "书架", "广告", "客服", "帮助"]
        return fuzzyNoise.contains(where: { title.contains($0) })
    }

    private func parseJSONObjectPayload(from raw: String) -> Any? {
        let unwrapped = unwrapJSONStringContainer(raw)
        guard looksLikeJSONPayload(unwrapped),
              let data = unwrapped.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    private func chapterArrayCandidates(in object: Any) -> [[Any]] {
        var result: [[Any]] = []
        collectChapterArrayCandidates(from: object, into: &result)
        return result
    }

    private func collectChapterArrayCandidates(from object: Any, into result: inout [[Any]]) {
        if let array = object as? [Any] {
            if isLikelyChapterArray(array) {
                result.append(array)
            }
            for item in array {
                collectChapterArrayCandidates(from: item, into: &result)
            }
            return
        }
        if let dict = object as? [String: Any] {
            for value in dict.values {
                collectChapterArrayCandidates(from: value, into: &result)
            }
        }
    }

    private func isLikelyChapterArray(_ array: [Any]) -> Bool {
        guard array.count >= 2 else { return false }
        let dictItems = array.compactMap { $0 as? [String: Any] }
        guard !dictItems.isEmpty else { return false }

        let titleKeys = ["title", "name", "chapterName", "chapter_title", "chapter", "text"]
        let urlKeys = ["url", "href", "link", "chapterUrl", "chapter_url"]
        let matchedCount = dictItems.reduce(into: 0) { partial, dict in
            let title = firstStringValue(in: dict, keys: titleKeys)
            let url = firstStringValue(in: dict, keys: urlKeys)
            if !title.isEmpty || !url.isEmpty {
                partial += 1
            }
        }
        return matchedCount >= max(2, dictItems.count / 2)
    }

    private func firstStringValue(in dict: [String: Any], keys: [String]) -> String {
        var lowerMap: [String: Any] = [:]
        for (key, value) in dict {
            let lowered = key.lowercased()
            if lowerMap[lowered] == nil {
                lowerMap[lowered] = value
            }
        }
        for key in keys {
            if let value = lowerMap[key.lowercased()] {
                let text = jsonNodeToString(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }
        return ""
    }

    private func jsonNodeToString(_ node: Any) -> String {
        switch node {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            return array
                .map { jsonNodeToString($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case let dict as [String: Any]:
            return extractBestTextFromJSONObject(dict)
        default:
            return ""
        }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        return result
    }

    private func extractReadableTextFromJSONPayload(_ raw: String, baseUrl: String) -> (text: String, imageUrls: [String])? {
        let unwrapped = unwrapJSONStringContainer(raw)
        guard looksLikeJSONPayload(unwrapped),
              let data = unwrapped.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }

        let text = sanitizedPlainText(extractBestTextFromJSONObject(object))
        let imageUrls = extractImageUrlsFromJSONObject(object, baseUrl: baseUrl)
        guard !text.isEmpty || !imageUrls.isEmpty else { return nil }
        return (text, imageUrls)
    }

    private func unwrapJSONStringContainer(_ raw: String) -> String {
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

    private func extractBestTextFromJSONObject(_ object: Any) -> String {
        switch object {
        case let text as String:
            return text
        case let array as [Any]:
            let pieces = array
                .map { extractBestTextFromJSONObject($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return pieces.joined(separator: "\n")
        case let dict as [String: Any]:
            let priorityKeys = [
                "content", "body", "text", "html", "article", "chapterContent",
                "chapter", "data", "result", "msg", "message", "value"
            ]

            var candidates: [String] = []
            for key in priorityKeys {
                guard let value = dict[key] else { continue }
                let text = extractBestTextFromJSONObject(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    candidates.append(text)
                }
            }

            if candidates.isEmpty {
                for value in dict.values {
                    let text = extractBestTextFromJSONObject(value).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        candidates.append(text)
                    }
                }
            }

            return candidates.max(by: { $0.count < $1.count }) ?? ""
        default:
            return ""
        }
    }

    private func extractImageUrlsFromJSONObject(_ object: Any, baseUrl: String) -> [String] {
        var collected: [String] = []
        collectImageURLs(from: object, into: &collected, baseUrl: baseUrl)

        var unique: [String] = []
        for item in collected {
            if !unique.contains(item) {
                unique.append(item)
            }
        }
        return unique
    }

    private func collectImageURLs(from object: Any, into result: inout [String], baseUrl: String) {
        switch object {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let lowered = trimmed.lowercased()
            let looksLikeImage = lowered.contains(".jpg")
                || lowered.contains(".jpeg")
                || lowered.contains(".png")
                || lowered.contains(".webp")
                || lowered.contains(".gif")
                || lowered.contains(".bmp")
            guard looksLikeImage else { return }
            let absolute = analyzer.extractUrl(url: trimmed, baseUrl: baseUrl)
            if !absolute.isEmpty {
                result.append(absolute)
            }
        case let array as [Any]:
            for item in array {
                collectImageURLs(from: item, into: &result, baseUrl: baseUrl)
            }
        case let dict as [String: Any]:
            for value in dict.values {
                collectImageURLs(from: value, into: &result, baseUrl: baseUrl)
            }
        default:
            return
        }
    }

    private func logChapterDebug(_ message: String) {
        guard verboseChapterDebugLoggingEnabled else { return }
        Swift.print("[ChapterDebug] \(message)")
    }

    private func prettySourceConfig(_ source: BookSource) -> String {
        let encoder = JSONEncoder()
        if #available(iOS 11.0, *) {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        guard let data = try? encoder.encode(source),
              let text = String(data: data, encoding: .utf8) else {
            return "<failed to encode source config>"
        }
        return text
    }

    private func previewText(_ value: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "<empty>" }

        let replaced = normalized.replacingOccurrences(of: "\n", with: "\\n")
        if replaced.count <= maxLength {
            return replaced
        }
        let prefix = String(replaced.prefix(maxLength))
        return "\(prefix)...(len=\(replaced.count))"
    }
    
    private func containsHTMLMarkup(_ content: String) -> Bool {
        return content.range(of: "<\\s*/?\\s*[a-zA-Z][^>]*>", options: .regularExpression) != nil
    }
    
    private func formatHTMLToReadableText(_ html: String) -> String {
        let decoded = decodeHTMLEntities(in: html)

        guard let doc = try? SwiftSoup.parseBodyFragment(decoded),
              let body = doc.body() else {
            return fallbackFormatHTMLToReadableText(decoded)
        }

        var output = ""
        for node in body.getChildNodes() {
            appendReadableText(from: node, into: &output)
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallbackFormatHTMLToReadableText(decoded)
        }

        return normalizeReadableText(output)
    }

    private func appendReadableText(from node: Node, into output: inout String) {
        if let textNode = node as? TextNode {
            let text = textNode.text()
            if !text.isEmpty {
                output += text
            }
            return
        }

        guard let element = node as? Element else { return }
        let tag = element.tagName().lowercased()
        let blockTags: Set<String> = [
            "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt",
            "fieldset", "figcaption", "figure", "footer", "form",
            "h1", "h2", "h3", "h4", "h5", "h6",
            "header", "hr", "li", "main", "nav", "ol", "p", "pre",
            "section", "table", "tr", "td", "th", "ul"
        ]
        let isLineBreak = tag == "br"
        let isVisualBreak = tag == "img"
        let isBlock = blockTags.contains(tag)

        if isLineBreak || isVisualBreak {
            if !output.hasSuffix("\n") {
                output += "\n"
            }
            return
        }

        if isBlock, !output.isEmpty, !output.hasSuffix("\n") {
            output += "\n"
        }

        for child in element.getChildNodes() {
            appendReadableText(from: child, into: &output)
        }

        if isBlock, !output.hasSuffix("\n") {
            output += "\n"
        }
    }

    private func normalizeReadableText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fallbackFormatHTMLToReadableText(_ html: String) -> String {
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
        return normalizeReadableText(decodeHTMLEntities(in: text))
    }
    
    private func decodeHTMLEntities(in text: String) -> String {
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
    
    private func extractImageUrls(from content: String, baseUrl: String) -> [String] {
        let patterns = [
            #"src\s*=\s*["']([^"']+)["']"#,
            #"data-src\s*=\s*["']([^"']+)["']"#,
            #"data-original\s*=\s*["']([^"']+)["']"#
        ]
        
        var result: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.matches(in: content, options: [], range: range)
            
            for match in matches {
                guard let valueRange = Range(match.range(at: 1), in: content) else { continue }
                let raw = String(content[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let absolute = analyzer.extractUrl(url: raw, baseUrl: baseUrl)
                guard !absolute.isEmpty else { continue }
                if !result.contains(absolute) {
                    result.append(absolute)
                }
            }
        }
        
        return result
    }
}

enum ParserError: Error {
    case noRule
    case parseError
}

import Foundation
import SwiftSoup

private let verboseLocalReaderLoggingEnabled = false

@inline(__always)
private func localReaderLog(_ message: @autoclosure () -> String) {
    guard verboseLocalReaderLoggingEnabled else { return }
    Swift.print(message())
}

final class LocalReaderAPI {
    static let shared = LocalReaderAPI()

    private let database = DatabaseManager.shared
    private let webBook = WebBook.shared
    private let analyzer = RuleAnalyzer.shared
    private let network = NetworkManager.shared
    private let rssManager = RSSManager.shared
    private let groupManager = BookGroupManager.shared

    private let userDefaults = UserDefaults.standard
    private let bookmarkStorageKey = "local_bookmarks"
    private let userConfigKey = "local_user_config"
    private let bookConfigPrefix = "local_book_config_"
    private let searchSourceTimeoutSeconds: Double = 9

    private init() {}

    // MARK: - Auth

    func login(username: String, password: String) async throws -> LoginResponse {
        return LoginResponse(ok: true, token: "local-mode", msg: "LOCAL_MODE", isSuccess: true, errorMsg: nil)
    }

    func reauthenticate() async throws {
        // Local mode does not require auth.
    }

    func getUserInfo() async throws -> UserInfo {
        return UserInfo(username: "local", nickName: "本地解析", userName: "local", nickname: "本地解析")
    }

    // MARK: - Book Sources

    func getBookSources() async throws -> [BookSourceResponse] {
        return database.getAllBookSources().map { source in
            BookSourceResponse(
                bookSourceUrl: source.bookSourceUrl,
                bookSourceName: source.bookSourceName,
                bookSourceGroup: source.bookSourceGroup,
                enabled: source.enabled,
                exploreUrl: source.exploreUrl,
                searchUrl: source.searchUrl,
                header: source.header,
                ruleSearch: encodeRule(source.ruleSearch),
                ruleExplore: encodeRule(source.ruleExplore),
                ruleBookInfo: encodeRule(source.ruleBookInfo),
                ruleToc: encodeRule(source.ruleToc),
                ruleContent: encodeRule(source.ruleContent)
            )
        }
    }

    func saveBookSource(_ source: BookSourceResponse) async throws {
        var local = database.getAllBookSources().first { normalize($0.bookSourceUrl) == normalize(source.bookSourceUrl) } ?? BookSource()
        local.bookSourceUrl = source.bookSourceUrl
        local.bookSourceName = source.bookSourceName
        local.bookSourceGroup = source.bookSourceGroup
        local.enabled = source.enabled
        local.exploreUrl = source.exploreUrl
        local.searchUrl = source.searchUrl
        local.header = source.header
        local.ruleSearch = decodeRule(source.ruleSearch)
        local.ruleExplore = decodeRule(source.ruleExplore)
        local.ruleBookInfo = decodeRule(source.ruleBookInfo)
        local.ruleToc = decodeRule(source.ruleToc)
        local.ruleContent = decodeRule(source.ruleContent)
        database.saveBookSource(local)
    }

    func deleteBookSource(sourceUrl: String) async throws {
        database.deleteBookSource(sourceUrl)
    }

    // MARK: - Search

    func search(keyword: String, page: Int = 1, bookSourceUrl: String? = nil) async throws -> [BookInfoResponse] {
        let allSources = enabledSources(requireSearch: true)
        let selectedSources: [BookSource]
        if let bookSourceUrl, !bookSourceUrl.isEmpty {
            if let source = sourceByUrl(bookSourceUrl) {
                selectedSources = [source]
            } else {
                return []
            }
        } else {
            selectedSources = allSources
        }

        var allResults: [SearchBook] = []
        if selectedSources.count == 1, let source = selectedSources.first {
            allResults = try await webBook.searchBook(keyword: keyword, source: source)
        } else {
            allResults = try await searchSources(keyword: keyword, sources: selectedSources)
        }

        let sourceNameMap = Dictionary(uniqueKeysWithValues: selectedSources.map { ($0.bookSourceUrl, $0.bookSourceName) })
        return allResults.map { toBookInfoResponse($0, sourceNameMap: sourceNameMap) }
    }

    func searchMulti(keyword: String, bookSourceGroup: String? = nil, concurrentCount: Int = 18, lastIndex: Int = -1) async throws -> (list: [BookInfoResponse], lastIndex: Int) {
        let sources = enabledSources(group: bookSourceGroup, requireSearch: true)
        guard !sources.isEmpty else { return ([], -1) }

        let start = max(lastIndex + 1, 0)
        guard start < sources.count else { return ([], -1) }

        let windowCount = max(1, concurrentCount)
        let end = min(start + windowCount, sources.count)
        let pageSources = Array(sources[start..<end])

        let results = try await searchSources(keyword: keyword, sources: pageSources)
        let sourceNameMap = Dictionary(uniqueKeysWithValues: sources.map { ($0.bookSourceUrl, $0.bookSourceName) })
        let mapped = results.map { toBookInfoResponse($0, sourceNameMap: sourceNameMap) }

        let nextLastIndex = end >= sources.count ? -1 : end - 1
        return (mapped, nextLastIndex)
    }

    // MARK: - Book Info

    func getBookInfo(bookUrl: String, sourceUrl: String) async throws -> BookInfoResponse {
        let source = try resolveSource(sourceUrl: sourceUrl, bookUrl: bookUrl)
        var info = try await webBook.getBookInfo(bookUrl: bookUrl, source: source)

        if info.bookUrl.isEmpty {
            info.bookUrl = bookUrl
        }
        if info.origin.isEmpty {
            info.origin = source.bookSourceUrl
        }
        if info.originName.isEmpty {
            info.originName = source.bookSourceName
        }

        if let stored = database.getBook(byBookUrl: info.bookUrl) {
            info.durChapterIndex = stored.durChapterIndex
            info.durChapterPos = stored.durChapterPos
            info.durChapterTime = stored.durChapterTime
            info.group = stored.group
            if info.coverUrl == nil { info.coverUrl = stored.coverUrl }
            if info.intro == nil { info.intro = stored.intro }
        }

        return toBookInfoResponse(info)
    }

    func refreshBook(bookUrl: String, sourceUrl: String) async throws -> BookInfoResponse {
        let refreshed = try await getBookInfo(bookUrl: bookUrl, sourceUrl: sourceUrl)
        try await saveBookInfo(refreshed)
        return refreshed
    }

    // MARK: - TOC & Content

    func getChapterList(
        bookUrl: String,
        sourceUrl: String,
        bookNameHint: String? = nil,
        authorHint: String? = nil
    ) async throws -> [ChapterResponse] {
        localReaderLog("[ChapterFlow] getChapterList START bookUrl=\(bookUrl) sourceUrl=\(sourceUrl)")
        let source = try resolveSource(sourceUrl: sourceUrl, bookUrl: bookUrl)
        localReaderLog("[ChapterFlow] source resolved name=\(source.bookSourceName) url=\(source.bookSourceUrl)")

        let existingBook = database.getBook(byBookUrl: bookUrl)
        let normalizedHintName = normalizedIdentityText(bookNameHint)
        let normalizedHintAuthor = normalizedIdentityText(authorHint)
        let hasIdentityHint = !normalizedHintName.isEmpty || !normalizedHintAuthor.isEmpty

        var allowCache = shouldUseBookURLAsChapterCacheKey(bookUrl)
        if allowCache {
            if let existingBook {
                let normalizedExistingName = normalizedIdentityText(existingBook.name)
                if !normalizedHintName.isEmpty,
                   !normalizedExistingName.isEmpty,
                   normalizedHintName != normalizedExistingName {
                    allowCache = false
                }

                let normalizedExistingAuthor = normalizedIdentityText(existingBook.author)
                if !normalizedHintAuthor.isEmpty,
                   !normalizedExistingAuthor.isEmpty,
                   normalizedHintAuthor != normalizedExistingAuthor {
                    allowCache = false
                }
            } else if hasIdentityHint {
                // 未入架书籍缺少稳定身份映射时，禁用目录缓存，避免同源串目录。
                allowCache = false
            }
        }
        if !allowCache {
            localReaderLog("[ChapterFlow] skip chapter cache for ambiguous bookUrl: \(bookUrl)")
            database.deleteChapters(forBookUrl: bookUrl)
        }

        let cached = allowCache ? database.getChapters(forBookUrl: bookUrl) : []
        if !cached.isEmpty {
            localReaderLog("[ChapterFlow] cache hit count=\(cached.count)")
            if containsInvalidChapterTitles(cached) || containsAbnormalChapterOrder(cached) {
                localReaderLog("[ChapterFlow] cache invalid -> clear and refetch")
                database.deleteChapters(forBookUrl: bookUrl)
            } else {
                localReaderLog("[ChapterFlow] return cached chapters")
                return cached.map {
                    ChapterResponse(title: $0.title, url: $0.url, index: $0.index, isVip: $0.isVip, isPay: $0.isPay)
                }
            }
        }

        let referenceName = firstNonEmptyText(bookNameHint, existingBook?.name)
        let referenceAuthor = firstNonEmptyText(authorHint, existingBook?.author)
        localReaderLog("[ChapterFlow] reference hints name=\(referenceName.isEmpty ? "<empty>" : referenceName) author=\(referenceAuthor.isEmpty ? "<empty>" : referenceAuthor)")
        var tocCandidates: [String] = []
        var latestError: Error?

        if let existingBook {
            tocCandidates.append(existingBook.tocUrl)
            tocCandidates.append(existingBook.bookUrl)
        }
        tocCandidates.append(bookUrl)

        // 首次尝试失败时，再抓取一次书籍详情补全 tocUrl，提升兼容性。
        var refreshedInfo: Book?
        var hasTriedRefreshInfo = false
        var hasTriedSearchRecovery = false

        while true {
            let orderedCandidates = uniqueNonEmpty(tocCandidates)
            localReaderLog("[ChapterFlow] toc candidates(\(orderedCandidates.count))=\(orderedCandidates)")
            for tocUrl in orderedCandidates {
                if !isLikelyTocCandidate(tocUrl) {
                    localReaderLog("[ChapterFlow] skip suspicious toc candidate: \(tocUrl.prefix(120))...")
                    continue
                }
                do {
                    localReaderLog("[ChapterFlow] trying tocUrl=\(tocUrl)")
                    let chapters = try await webBook.getChapterList(tocUrl: tocUrl, bookUrl: bookUrl, source: source)
                    if !chapters.isEmpty {
                        let cleanedChapters = sanitizeChapterList(chapters)
                        if cleanedChapters.count != chapters.count {
                            localReaderLog("[ChapterFlow] tocUrl=\(tocUrl) sanitized chapters \(chapters.count) -> \(cleanedChapters.count)")
                        }

                        if shouldDeferDetailPageTocResult(
                            tocUrl: tocUrl,
                            bookUrl: bookUrl,
                            source: source,
                            rawChapters: chapters,
                            cleanedChapters: cleanedChapters
                        ),
                           !hasTriedRefreshInfo {
                            localReaderLog("[ChapterFlow] tocUrl=\(tocUrl) looks like detail-page toc snippet, defer and try refresh book info")
                            continue
                        }

                        var resolvedChapters = cleanedChapters
                        if !isLikelyValidChapterResult(resolvedChapters, tocUrl: tocUrl, bookUrl: bookUrl) {
                            if let synthesized = synthesizeDirectContentFallbackChaptersIfNeeded(
                                source: source,
                                tocUrl: tocUrl,
                                bookUrl: bookUrl,
                                referenceName: referenceName,
                                chapters: chapters,
                                cleanedChapters: cleanedChapters
                            ) {
                                resolvedChapters = synthesized
                                localReaderLog("[ChapterFlow] tocUrl=\(tocUrl) looks non-serial, use direct-content fallback chapter")
                            } else {
                                localReaderLog("[ChapterFlow] tocUrl=\(tocUrl) returned suspicious chapters=\(cleanedChapters.count), ignore and continue")
                                continue
                            }
                        }

                        localReaderLog("[ChapterFlow] success tocUrl=\(tocUrl) chapters=\(resolvedChapters.count)")
                        if allowCache {
                            database.saveChapters(resolvedChapters)
                        } else {
                            localReaderLog("[ChapterFlow] skip saving chapters for ambiguous cache key")
                        }

                        var stored = existingBook ?? Book(bookUrl: bookUrl)
                        if stored.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            stored.name = referenceName
                        }
                        if stored.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            stored.author = referenceAuthor
                        }
                        if stored.tocUrl.isEmpty || normalize(stored.tocUrl) != normalize(tocUrl) {
                            stored.tocUrl = tocUrl
                        }
                        if stored.origin.isEmpty {
                            stored.origin = source.bookSourceUrl
                        }
                        if stored.originName.isEmpty {
                            stored.originName = source.bookSourceName
                        }
                        // 仅更新已在书架中的书籍，避免“阅读即自动入架”。
                        if existingBook != nil {
                            database.saveBook(stored)
                        }

                        return resolvedChapters.map {
                            ChapterResponse(title: $0.title, url: $0.url, index: $0.index, isVip: $0.isVip, isPay: $0.isPay)
                        }
                    } else {
                        localReaderLog("[ChapterFlow] tocUrl=\(tocUrl) returned 0 chapters")
                    }
                } catch {
                    localReaderLog("[ChapterFlow] tocUrl=\(tocUrl) failed: \(error)")
                    latestError = error
                }
            }

            if !hasTriedSearchRecovery {
                hasTriedSearchRecovery = true

                if !referenceName.isEmpty, let searchUrl = source.searchUrl, !searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let keywords = searchRecoverKeywords(name: referenceName, author: referenceAuthor)
                    localReaderLog("[ChapterFlow] search-recover keywords=\(keywords)")
                    var recoveredMatch: SearchBook?

                    for keyword in keywords {
                        do {
                            localReaderLog("[ChapterFlow] search-recover start keyword=\(keyword)")
                            let searchItems = try await webBook.searchBook(keyword: keyword, source: source)
                            localReaderLog("[ChapterFlow] search-recover candidates(keyword=\(keyword))=\(searchItems.count)")

                            var invalidSamples: [String] = []
                            let validItems = searchItems.compactMap { item -> SearchBook? in
                                guard let normalizedURL = normalizedSearchRecoverBookURL(item.bookUrl) else {
                                    if invalidSamples.count < 3 {
                                        invalidSamples.append(item.bookUrl)
                                    }
                                    return nil
                                }
                                var normalized = item
                                normalized.bookUrl = normalizedURL
                                return normalized
                            }
                            if validItems.count != searchItems.count {
                                localReaderLog("[ChapterFlow] search-recover filtered invalid bookUrl candidates \(searchItems.count) -> \(validItems.count)")
                                if !invalidSamples.isEmpty {
                                    localReaderLog("[ChapterFlow] search-recover invalid bookUrl samples=\(invalidSamples)")
                                }
                            }

                            let matched = validItems.first(where: { item in
                                isLikelySameBookName(item.name, referenceName: referenceName)
                                    && isLikelySameAuthor(item.author, referenceAuthor: referenceAuthor)
                            }) ?? validItems.first(where: { item in
                                isLikelySameBookName(item.name, referenceName: referenceName)
                            })

                            if let matched {
                                recoveredMatch = matched
                                break
                            }
                        } catch {
                            localReaderLog("[ChapterFlow] search-recover failed(keyword=\(keyword)): \(error)")
                        }
                    }

                    if let matched = recoveredMatch,
                       !matched.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        localReaderLog("[ChapterFlow] search-recover matched name=\(matched.name) bookUrl=\(matched.bookUrl)")
                        tocCandidates.append(matched.bookUrl)

                        if let recoveredInfo = try? await webBook.getBookInfo(bookUrl: matched.bookUrl, source: source) {
                            tocCandidates.append(recoveredInfo.tocUrl)
                            tocCandidates.append(recoveredInfo.bookUrl)
                            localReaderLog("[ChapterFlow] search-recover bookInfo tocUrl=\(recoveredInfo.tocUrl) bookUrl=\(recoveredInfo.bookUrl)")
                        }
                        continue
                    } else {
                        localReaderLog("[ChapterFlow] search-recover no matched result for referenceName=\(referenceName)")
                    }
                } else {
                    localReaderLog("[ChapterFlow] search-recover skipped (no referenceName or searchUrl)")
                }
            }

            if hasTriedRefreshInfo {
                localReaderLog("[ChapterFlow] already refreshed book info once, stop retry")
                break
            }
            hasTriedRefreshInfo = true

            do {
                localReaderLog("[ChapterFlow] refresh book info to recover tocUrl")
                var refreshTargetBookUrl = bookUrl
                if let recoveredBookUrl = await recoverBookInfoTargetURLFromListFeed(
                    listUrl: bookUrl,
                    source: source,
                    referenceName: referenceName,
                    referenceAuthor: referenceAuthor
                ) {
                    refreshTargetBookUrl = recoveredBookUrl
                    tocCandidates.append(recoveredBookUrl)
                    localReaderLog("[ChapterFlow] list-recover matched detail bookUrl=\(recoveredBookUrl)")
                }

                let info = try await webBook.getBookInfo(bookUrl: refreshTargetBookUrl, source: source)
                refreshedInfo = info
                if isLikelyTocCandidate(info.tocUrl) {
                    // 刷新拿到的 tocUrl 优先级最高，避免再次被详情页“片段目录”抢先命中。
                    tocCandidates.insert(info.tocUrl, at: 0)
                } else if !info.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    localReaderLog("[ChapterFlow] ignore suspicious tocUrl from bookInfo: \(info.tocUrl.prefix(120))...")
                }
                if isLikelyTocCandidate(info.bookUrl) {
                    tocCandidates.append(info.bookUrl)
                } else if !info.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    localReaderLog("[ChapterFlow] ignore suspicious bookUrl from bookInfo: \(info.bookUrl.prefix(120))...")
                }
                localReaderLog("[ChapterFlow] refreshed tocUrl=\(info.tocUrl) bookUrl=\(info.bookUrl)")
            } catch {
                localReaderLog("[ChapterFlow] refresh book info failed: \(error)")
                latestError = error
                break
            }
        }

        if var stored = existingBook, let refreshedInfo {
            if !refreshedInfo.tocUrl.isEmpty {
                stored.tocUrl = refreshedInfo.tocUrl
            }
            if stored.origin.isEmpty {
                stored.origin = source.bookSourceUrl
            }
            if stored.originName.isEmpty {
                stored.originName = source.bookSourceName
            }
            database.saveBook(stored)
        }

        if let latestError {
            localReaderLog("[ChapterFlow] END failed latestError=\(latestError)")
            throw latestError
        }

        if let fallbackChapters = synthesizeDirectContentFallbackChaptersIfNeeded(
            source: source,
            tocUrl: tocCandidates.first ?? "",
            bookUrl: bookUrl,
            referenceName: referenceName,
            chapters: [],
            cleanedChapters: []
        ) {
            localReaderLog("[ChapterFlow] END fallback to direct-content chapter")
            if allowCache {
                database.saveChapters(fallbackChapters)
            } else {
                localReaderLog("[ChapterFlow] skip saving fallback chapter for ambiguous cache key")
            }
            return fallbackChapters.map {
                ChapterResponse(title: $0.title, url: $0.url, index: $0.index, isVip: $0.isVip, isPay: $0.isPay)
            }
        }

        localReaderLog("[ChapterFlow] END with empty result")
        return []
    }

    func getChapterContent(bookUrl: String, sourceUrl: String, chapterUrl: String, index: Int = 0) async throws -> ChapterContent {
        let source = try resolveSource(sourceUrl: sourceUrl, bookUrl: bookUrl)
        let cachedSnapshot = toChapterResponses(database.getChapters(forBookUrl: bookUrl))
        var targetChapterUrl = chapterUrl

        if targetChapterUrl.isEmpty {
            if index >= 0 && index < cachedSnapshot.count {
                targetChapterUrl = cachedSnapshot[index].url
            }
        }

        if targetChapterUrl.isEmpty {
            let chapterResponses = try await getChapterList(bookUrl: bookUrl, sourceUrl: source.bookSourceUrl)
            if index >= 0 && index < chapterResponses.count {
                targetChapterUrl = chapterResponses[index].url
            }
        }

        guard !targetChapterUrl.isEmpty else {
            return ChapterContent(content: "")
        }

        do {
            var content = try await webBook.getContent(chapterUrl: targetChapterUrl, source: source)
            content.url = targetChapterUrl
            return content
        } catch {
            guard shouldRefreshChapterListAfterContentError(error) else {
                throw error
            }

            let chapterTitleHint = resolveChapterTitleHint(
                index: index,
                chapterUrl: chapterUrl,
                resolvedChapterUrl: targetChapterUrl,
                chapters: cachedSnapshot
            )

            // 某些站点章节链接会变更，404 时刷新目录并做多策略回退：
            // 索引、标题匹配、邻近章节，以及 http/https 互换。
            database.deleteChapters(forBookUrl: bookUrl)
            var refreshedChapters: [ChapterResponse] = []
            var refreshError: Error?
            do {
                refreshedChapters = try await getChapterList(bookUrl: bookUrl, sourceUrl: source.bookSourceUrl)
            } catch {
                refreshError = error
            }

            let retryCandidates = buildChapterRetryCandidates(
                index: index,
                chapterUrl: chapterUrl,
                resolvedChapterUrl: targetChapterUrl,
                chapterTitleHint: chapterTitleHint,
                cachedChapters: cachedSnapshot,
                refreshedChapters: refreshedChapters
            )

            var latestError: Error = refreshError ?? error
            for candidate in retryCandidates {
                do {
                    var content = try await webBook.getContent(chapterUrl: candidate, source: source)
                    content.url = candidate
                    return content
                } catch {
                    latestError = error
                }
            }

            guard retryCandidates.isEmpty else {
                throw latestError
            }
            if let refreshError {
                throw refreshError
            }
            guard !targetChapterUrl.isEmpty else {
                throw error
            }

            var retried = try await webBook.getContent(chapterUrl: targetChapterUrl, source: source)
            retried.url = targetChapterUrl
            return retried
        }
    }

    func findAlternativeSources(bookName: String, author: String? = nil) async throws -> [BookInfoResponse] {
        var allResults: [BookInfoResponse] = []
        var last = -1

        repeat {
            let page = try await searchMulti(keyword: bookName, bookSourceGroup: nil, concurrentCount: 18, lastIndex: last)
            var pageList = page.list
            if let author, !author.isEmpty {
                pageList = pageList.filter { item in
                    let itemAuthor = item.author
                    return itemAuthor.contains(author) || author.contains(itemAuthor)
                }
            }
            allResults.append(contentsOf: pageList)
            last = page.lastIndex
        } while last >= 0

        return allResults
    }

    // MARK: - Bookshelf

    func getBookshelf() async throws -> [BookInfoResponse] {
        return database.getAllBooks().map { toBookInfoResponse($0) }
    }

    func isInBookshelf(bookUrl: String) -> Bool {
        return database.hasBook(byBookUrl: bookUrl)
    }

    func addToBookshelf(book: BookInfoResponse) async throws {
        var localBook = database.getBook(byBookUrl: book.bookUrl) ?? Book(bookUrl: book.bookUrl)
        localBook.bookUrl = book.bookUrl
        localBook.origin = book.sourceUrl ?? localBook.origin
        localBook.originName = book.originName ?? localBook.originName
        localBook.name = book.name
        localBook.author = book.author
        if let cover = book.coverUrl, !cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            localBook.coverUrl = cover
        }
        if let intro = book.intro, !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            localBook.intro = intro
        }
        localBook.kind = book.kind
        if let tocUrl = book.tocUrl, !tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            localBook.tocUrl = tocUrl
        }
        localBook.latestChapterTitle = book.latestChapter
        localBook.totalChapterNum = book.totalChapterNum
        localBook.type = book.type
        localBook.durChapterTime = Int64(Date().timeIntervalSince1970 * 1000)
        database.saveBook(localBook)
    }

    func removeFromBookshelf(bookUrl: String, sourceUrl: String) async throws {
        database.deleteBook(bookUrl)
    }

    func saveBook(book: Book) async throws {
        database.saveBook(book)
    }

    func saveBookInfo(_ bookInfo: BookInfoResponse) async throws {
        var book = database.getBook(byBookUrl: bookInfo.bookUrl) ?? Book(bookUrl: bookInfo.bookUrl)
        book.bookUrl = bookInfo.bookUrl
        book.origin = bookInfo.sourceUrl ?? book.origin
        book.originName = bookInfo.originName ?? book.originName
        book.name = bookInfo.name
        book.author = bookInfo.author
        if let cover = bookInfo.coverUrl, !cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            book.coverUrl = cover
        }
        if let intro = bookInfo.intro, !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            book.intro = intro
        }
        book.kind = bookInfo.kind
        if let tocUrl = bookInfo.tocUrl, !tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            book.tocUrl = tocUrl
        }
        book.latestChapterTitle = bookInfo.latestChapter
        book.totalChapterNum = bookInfo.totalChapterNum
        book.type = bookInfo.type
        database.saveBook(book)
    }

    func saveBookProgress(bookUrl: String, sourceUrl: String, chapterIndex: Int, chapterPos: Int) async throws {
        guard var book = database.getBook(byBookUrl: bookUrl) else { return }
        book.durChapterIndex = chapterIndex
        book.durChapterPos = chapterPos
        book.durChapterTime = Int64(Date().timeIntervalSince1970 * 1000)
        database.saveBook(book)
    }

    // MARK: - Source Switching

    func searchBookSources(bookUrl: String, bookSourceGroup: String? = nil, lastIndex: Int = 0) async throws -> (sources: [SearchBook], lastIndex: Int) {
        let reference = database.getBook(byBookUrl: bookUrl)
        let nameKeyword = reference?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !nameKeyword.isEmpty else {
            throw NSError(
                domain: "LocalReaderAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "当前书籍缺少书名，无法换源，请先重新加入书架后重试"]
            )
        }
        let authorKeyword = reference?.author.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourcePool = enabledSources(group: bookSourceGroup, requireSearch: true)
        let sourceNameMap = Dictionary(uniqueKeysWithValues: sourcePool.map { ($0.bookSourceUrl, $0.bookSourceName) })
        let switchConcurrentCount = min(36, max(18, sourcePool.count))

        // 外部约定: 0 为首批；内部 searchMulti 约定: -1 为首批。
        let startIndex = lastIndex <= 0 ? -1 : lastIndex - 1
        let searchResult = try await searchMulti(
            keyword: nameKeyword,
            bookSourceGroup: bookSourceGroup,
            concurrentCount: switchConcurrentCount,
            lastIndex: startIndex
        )
        let mapped = searchResult.list.map { item -> SearchBook in
            let sourceUrl = item.sourceUrl ?? ""
            return SearchBook(
                bookUrl: item.bookUrl,
                bookSourceUrl: sourceUrl,
                name: item.name,
                author: item.author,
                coverUrl: item.coverUrl,
                intro: item.intro,
                kind: item.kind,
                latestChapter: item.latestChapter,
                wordCount: item.wordCount,
                origin: sourceUrl,
                originName: item.originName ?? sourceNameMap[sourceUrl],
                customInfo: nil,
                time: 0
            )
        }

        let filtered = filterSwitchCandidates(
            mapped,
            currentSourceUrl: reference?.origin ?? "",
            referenceName: nameKeyword,
            referenceAuthor: reference?.author ?? ""
        )

        let nextIndex = searchResult.lastIndex < 0 ? -1 : searchResult.lastIndex + 1
        return (filtered, nextIndex)
    }

    func switchToSource(bookUrl: String, newUrl: String, bookSourceUrl: String) async throws -> Book {
        // 先做可读性校验，避免“只搜到但不能读”的假成功换源。
        _ = try await validateSwitchCandidate(bookUrl: bookUrl, newUrl: newUrl, bookSourceUrl: bookSourceUrl)

        let source = try resolveSource(sourceUrl: bookSourceUrl, bookUrl: newUrl)
        var switched = try await webBook.getBookInfo(bookUrl: newUrl, source: source)

        let previous = database.getBook(byBookUrl: bookUrl)
        if let previous {
            switched.group = previous.group
            switched.readConfig = previous.readConfig
            switched.durChapterIndex = previous.durChapterIndex
            switched.durChapterPos = previous.durChapterPos
            switched.durChapterTime = previous.durChapterTime
        }

        if switched.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switched.bookUrl = newUrl
        }
        if switched.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switched.tocUrl = switched.bookUrl
        }
        if switched.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switched.name = previous?.name ?? switched.name
        }
        if switched.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switched.author = previous?.author ?? switched.author
        }
        if (switched.coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let oldCover = previous?.coverUrl,
           !oldCover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switched.coverUrl = oldCover
        }
        if (switched.intro?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let oldIntro = previous?.intro,
           !oldIntro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switched.intro = oldIntro
        }
        if (switched.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let oldKind = previous?.kind,
           !oldKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switched.kind = oldKind
        }

        switched.origin = source.bookSourceUrl
        switched.originName = source.bookSourceName

        let previousOrigin = previous?.origin ?? ""
        if let previous, normalize(previous.bookUrl) != normalize(switched.bookUrl) {
            database.deleteBook(previous.bookUrl)
            database.deleteChapters(forBookUrl: previous.bookUrl)
        }

        if normalize(previousOrigin) != normalize(switched.origin) {
            // 换源后目录缓存可能失效，强制清空以免正文 404。
            database.deleteChapters(forBookUrl: switched.bookUrl)
        }

        database.saveBook(switched)
        return switched
    }

    func validateSwitchCandidate(bookUrl: String, newUrl: String, bookSourceUrl: String) async throws -> (chapterCount: Int, probeCount: Int) {
        let info = try await getBookInfo(bookUrl: newUrl, sourceUrl: bookSourceUrl)
        let resolvedBookUrl = info.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? newUrl : info.bookUrl
        let chapters = try await getChapterList(bookUrl: resolvedBookUrl, sourceUrl: bookSourceUrl)

        guard !chapters.isEmpty else {
            throw NSError(
                domain: "LocalReaderAPI",
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
                    chapterUrl: chapter.url,
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
                domain: "LocalReaderAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "目录可加载，但正文解析失败: \(lastError.localizedDescription)"]
            )
        }

        throw NSError(
            domain: "LocalReaderAPI",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "目录可加载，但正文为空或疑似未解析"]
        )
    }

    func getAvailableBookSources(bookUrl: String, refresh: Bool = false) async throws -> [BookInfoResponse] {
        let searched = try await searchBookSources(bookUrl: bookUrl, lastIndex: 0)
        return searched.sources.map { source in
            BookInfoResponse(
                name: source.name,
                author: source.author,
                bookUrl: source.bookUrl,
                sourceUrl: source.bookSourceUrl,
                coverUrl: source.coverUrl,
                intro: source.intro,
                kind: source.kind,
                latestChapter: source.latestChapter,
                tocUrl: nil,
                wordCount: source.wordCount,
                chapterCount: nil,
                type: 0,
                originName: source.originName,
                durChapterIndex: 0,
                durChapterPos: 0,
                durChapterTime: 0,
                totalChapterNum: 0
            )
        }
    }

    func setBookSource(bookUrl: String, newUrl: String, sourceUrl: String) async throws {
        _ = try await switchToSource(bookUrl: bookUrl, newUrl: newUrl, bookSourceUrl: sourceUrl)
    }

    // MARK: - RSS

    func getRssSources() async throws -> [RssSourceResponse] {
        return rssManager.getAllStoredSources().map { source in
            RssSourceResponse(
                url: source.sourceUrl,
                title: source.sourceName,
                group: source.sourceGroup,
                enabled: source.enabled,
                header: nil,
                ruleFindUrl: nil,
                ruleList: source.ruleArticles,
                ruleTitle: source.ruleTitle,
                ruleContent: source.ruleContent,
                ruleImage: source.ruleImage,
                ruleLink: source.ruleUrl,
                rulePubDate: source.rulePubDate
            )
        }
    }

    func saveRssSource(_ source: RssSourceResponse) async throws {
        var model = RSSSource()
        model.sourceUrl = source.url
        model.sourceName = source.title
        model.sourceGroup = source.group
        model.enabled = source.enabled
        model.ruleArticles = source.ruleList
        model.ruleTitle = source.ruleTitle
        model.ruleUrl = source.ruleLink
        model.ruleImage = source.ruleImage
        model.ruleContent = source.ruleContent
        model.rulePubDate = source.rulePubDate

        if rssManager.getAllStoredSources().contains(where: { normalize($0.sourceUrl) == normalize(model.sourceUrl) }) {
            rssManager.updateSource(model)
        } else {
            rssManager.addSource(model)
        }
    }

    func deleteRssSource(url: String) async throws {
        rssManager.deleteSource(url)
    }

    func getRssArticles(rssUrl: String, articleUrl: String? = nil) async throws -> [RssArticleResponse] {
        let source = rssManager.getAllStoredSources().first(where: { normalize($0.sourceUrl) == normalize(rssUrl) }) ?? {
            var fallback = RSSSource()
            fallback.sourceUrl = rssUrl
            fallback.sourceName = rssUrl
            fallback.enabled = true
            return fallback
        }()

        var articles = await rssManager.fetchArticles(from: source)
        if let articleUrl, !articleUrl.isEmpty {
            articles = articles.filter { normalize($0.url) == normalize(articleUrl) }
        }

        return articles.map { article in
            RssArticleResponse(
                title: article.title,
                url: article.url,
                author: nil,
                content: article.content,
                pubDate: article.publishDate?.description,
                imageUrl: article.image
            )
        }
    }

    // MARK: - Book Groups

    func getBookGroups() async throws -> [BookGroupResponse] {
        return groupManager.getAllGroups().map {
            BookGroupResponse(id: $0.groupId, name: $0.groupName, bookCount: $0.bookCount)
        }
    }

    // MARK: - Replace Rules

    func getReplaceRules() async throws -> [ReplaceRuleResponse] {
        let rules = database.getAllReplaceRules()
        return rules.enumerated().map { index, rule in
            ReplaceRuleResponse(
                id: Int(rule.ruleId) ?? index,
                name: rule.groupName ?? "本地规则",
                rule: rule.pattern,
                replacement: rule.replacement,
                enabled: rule.isEnabled,
                order: index
            )
        }
    }

    // MARK: - Explore

    func explore(sourceUrl: String, url: String, page: Int = 1) async throws -> [BookInfoResponse] {
        guard let source = sourceByUrl(sourceUrl) else { return [] }
        
        let exploreRule = source.ruleExplore
        let searchRule = source.ruleSearch
        let useExploreRule = !(exploreRule?.bookList?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let selectedListRule = useExploreRule ? (exploreRule?.bookList ?? "") : (searchRule?.bookList ?? "")
        let normalizedListRule = normalizeListRule(selectedListRule)
        guard !normalizedListRule.rule.isEmpty else { return [] }
        
        let nameRule = useExploreRule ? exploreRule?.name : searchRule?.name
        let authorRule = useExploreRule ? exploreRule?.author : searchRule?.author
        let introRule = useExploreRule ? exploreRule?.intro : searchRule?.intro
        let kindRule = useExploreRule ? exploreRule?.kind : searchRule?.kind
        let lastChapterRule = useExploreRule ? exploreRule?.lastChapter : searchRule?.lastChapter
        let coverRule = useExploreRule ? exploreRule?.coverUrl : searchRule?.coverUrl
        let bookUrlRule = useExploreRule ? exploreRule?.bookUrl : searchRule?.bookUrl

        let descriptor = RuleURLRequestBuilder.build(
            ruleUrl: url,
            baseUrl: source.bookSourceUrl,
            page: page,
            defaultHeaders: RuleURLRequestBuilder.parseHeaderMap(source.header),
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
            retries: descriptor.retries,
            charset: descriptor.charset
        )

        let elements = try analyzer.analyzeList(html: html, rule: normalizedListRule.rule, baseUrl: descriptor.url)

        var books: [BookInfoResponse] = []
        for element in elements {
            var name = sanitizeExploreText((try? extractElementValue(element, nameRule, baseUrl: descriptor.url)) ?? "")
            if name.isEmpty {
                name = sanitizeExploreText((try? element.text()) ?? "")
            }
            let author = sanitizeExploreText((try? extractElementValue(element, authorRule, baseUrl: descriptor.url)) ?? "")
            if name.isEmpty {
                continue
            }
            var rawBookUrl = sanitizeExploreText((try? extractElementValue(element, bookUrlRule, baseUrl: descriptor.url)) ?? "")
            if rawBookUrl.isEmpty {
                rawBookUrl = fallbackElementLink(element, baseUrl: descriptor.url) ?? descriptor.url
            }

            let intro = normalizeInlineHTML(sanitizeExploreText((try? extractElementValue(element, introRule, baseUrl: descriptor.url)) ?? ""))
            let kind = normalizeInlineHTML(sanitizeExploreText((try? extractElementValue(element, kindRule, baseUrl: descriptor.url)) ?? ""))
            let latest = normalizeInlineHTML(sanitizeExploreText((try? extractElementValue(element, lastChapterRule, baseUrl: descriptor.url)) ?? ""))
            var cover = sanitizeExploreText((try? extractElementValue(element, coverRule, baseUrl: descriptor.url)) ?? "")
            if cover.isEmpty {
                cover = fallbackElementImage(element, baseUrl: descriptor.url) ?? ""
            }
            if !cover.isEmpty {
                cover = analyzer.extractUrl(url: cover, baseUrl: descriptor.url)
            }
            let coverUrl = cover.isEmpty ? nil : cover

            books.append(
                BookInfoResponse(
                    name: name,
                    author: author,
                    bookUrl: analyzer.extractUrl(url: rawBookUrl, baseUrl: descriptor.url),
                    sourceUrl: source.bookSourceUrl,
                    coverUrl: coverUrl,
                    intro: intro.isEmpty ? nil : intro,
                    kind: kind.isEmpty ? nil : kind,
                    latestChapter: latest.isEmpty ? nil : latest,
                    tocUrl: nil,
                    wordCount: nil,
                    chapterCount: nil,
                    type: 0,
                    originName: source.bookSourceName,
                    durChapterIndex: 0,
                    durChapterPos: 0,
                    durChapterTime: 0,
                    totalChapterNum: 0
                )
            )
        }
        
        if books.isEmpty && (source.bookUrlPattern?.isEmpty ?? true) {
            if let detail = try? await webBook.getBookInfo(bookUrl: descriptor.url, source: source),
               !detail.name.isEmpty {
                books.append(toBookInfoResponse(detail))
            }
        }
        
        if normalizedListRule.reverse {
            books.reverse()
        }

#if DEBUG
        if books.isEmpty {
            localReaderLog("[Explore][Empty] source=\(source.bookSourceName) request=\(descriptor.url)")
            localReaderLog("[Explore][Empty] categoryUrl=\(url)")
            localReaderLog("[Explore][Empty] listRule=\(normalizedListRule.rule)")
            localReaderLog("[Explore][Empty] elementCount=\(elements.count)")
        }
#endif

        return books
    }

    // MARK: - Bookmarks

    func getBookmarks() async throws -> [Bookmark] {
        guard let data = userDefaults.data(forKey: bookmarkStorageKey),
              let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            return []
        }
        return bookmarks.sorted { $0.createTime > $1.createTime }
    }

    func saveBookmark(_ bookmark: Bookmark) async throws {
        var bookmarks = try await getBookmarks()
        bookmarks.removeAll { $0.id == bookmark.id }
        bookmarks.insert(bookmark, at: 0)
        persistBookmarks(bookmarks)
    }

    func saveBookmarks(_ bookmarks: [Bookmark]) async throws {
        var current = try await getBookmarks()
        for bookmark in bookmarks {
            current.removeAll { $0.id == bookmark.id }
            current.append(bookmark)
        }
        persistBookmarks(current)
    }

    func deleteBookmark(bookmark: Bookmark) async throws {
        var bookmarks = try await getBookmarks()
        bookmarks.removeAll { $0.id == bookmark.id }
        persistBookmarks(bookmarks)
    }

    func deleteBookmarks(_ bookmarks: [Bookmark]) async throws {
        var current = try await getBookmarks()
        let ids = Set(bookmarks.map { $0.id })
        current.removeAll { ids.contains($0.id) }
        persistBookmarks(current)
    }

    // MARK: - Group Membership

    func addBookGroupMulti(groupId: Int64, books: [BookInfoResponse]) async throws {
        let existing = database.getAllBooks()
        for info in books {
            var book = existing.first(where: { normalize($0.bookUrl) == normalize(info.bookUrl) }) ?? Book(bookUrl: info.bookUrl)
            book.group = groupId
            if book.name.isEmpty { book.name = info.name }
            if book.author.isEmpty { book.author = info.author }
            if book.origin.isEmpty { book.origin = info.sourceUrl ?? "" }
            if book.originName.isEmpty { book.originName = info.originName ?? "" }
            database.saveBook(book)
        }
    }

    func removeBookGroupMulti(groupId: Int64, books: [BookInfoResponse]) async throws {
        let existing = database.getAllBooks()
        for info in books {
            guard var book = existing.first(where: { normalize($0.bookUrl) == normalize(info.bookUrl) }) else { continue }
            if book.group == groupId {
                book.group = 0
                database.saveBook(book)
            }
        }
    }

    // MARK: - Cache

    func cacheBook(bookUrl: String) async throws {
        // Local cache is handled by chapter/content fetch on demand.
    }

    func deleteBookCache(bookUrl: String) async throws {
        // Keep local DB content unchanged for now.
    }

    // MARK: - Export

    func exportBook(bookUrl: String, isEpub: Bool = false) async throws -> URL {
        if FileManager.default.fileExists(atPath: bookUrl) {
            let sourceURL = URL(fileURLWithPath: bookUrl)
            let fileName = isEpub ? "book.epub" : sourceURL.lastPathComponent
            let target = try AppTempPaths.makeExportFileURL(fileName: fileName)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: sourceURL, to: target)
            return target
        }

        let book = database.getBook(byBookUrl: bookUrl)
        let chapters = database.getChapters(forBookUrl: bookUrl)

        var text = ""
        if let book {
            text += "\(book.name)\n"
            text += "作者: \(book.author)\n\n"
            if let intro = book.intro, !intro.isEmpty {
                text += "简介:\n\(intro)\n\n"
            }
        }

        if let source = sourceByUrl(book?.origin ?? "") {
            for chapter in chapters {
                text += "\n\n\(chapter.title)\n"
                if let content = try? await webBook.getContent(chapterUrl: chapter.url, source: source) {
                    text += content.content + "\n"
                }
            }
        }

        if text.isEmpty {
            text = "未找到可导出的内容"
        }

        let fileName = isEpub ? "book.epub" : "book.txt"
        let fileURL = try AppTempPaths.makeExportFileURL(fileName: fileName)
        try text.data(using: .utf8)?.write(to: fileURL)
        return fileURL
    }

    // MARK: - Reading History

    func getReadingHistory() async throws -> [BookInfoResponse] {
        return database.getAllBooks().filter { $0.durChapterTime > 0 }.map { toBookInfoResponse($0) }
    }

    // MARK: - User Config

    func getUserConfig() async throws -> [String: Any] {
        guard let data = userDefaults.data(forKey: userConfigKey),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    func saveUserConfig(_ config: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: config)
        userDefaults.set(data, forKey: userConfigKey)
    }

    // MARK: - Book Config

    func getBookConfig(bookUrl: String) async throws -> [String: Any] {
        let key = bookConfigPrefix + normalize(bookUrl)
        guard let data = userDefaults.data(forKey: key),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    func saveBookConfig(bookUrl: String, config: [String: Any]) async throws {
        let key = bookConfigPrefix + normalize(bookUrl)
        let data = try JSONSerialization.data(withJSONObject: config)
        userDefaults.set(data, forKey: key)
    }

    // MARK: - Helpers

    private func enabledSources(group: String? = nil, requireSearch: Bool = false, requireExplore: Bool = false) -> [BookSource] {
        return database.getAllBookSources().filter { source in
            guard source.enabled else { return false }

            if let group, !group.isEmpty {
                let sourceGroup = source.bookSourceGroup ?? ""
                if !sourceGroup.contains(group) {
                    return false
                }
            }

            if requireSearch {
                guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else { return false }
            }

            if requireExplore {
                guard let exploreUrl = source.exploreUrl, !exploreUrl.isEmpty else { return false }
            }

            return true
        }
    }

    private func sourceByUrl(_ sourceUrl: String?) -> BookSource? {
        guard let sourceUrl, !sourceUrl.isEmpty else { return nil }
        let normalized = normalize(sourceUrl)
        let sources = database.getAllBookSources()
        if let exact = sources.first(where: { normalize($0.bookSourceUrl) == normalized }) {
            return exact
        }

        let canonical = canonicalSourceKey(sourceUrl)
        if canonical.isEmpty { return nil }
        return sources.first { canonicalSourceKey($0.bookSourceUrl) == canonical }
    }

    private func resolveSource(sourceUrl: String, bookUrl: String) throws -> BookSource {
        if let source = sourceByUrl(sourceUrl) {
            return source
        }

        if let book = database.getBook(byBookUrl: bookUrl),
           let source = sourceByUrl(book.origin) {
            return source
        }

        if let hostMatched = sourceByHost(bookUrl) {
            return hostMatched
        }

        let enabled = enabledSources()
        if enabled.count == 1, let fallback = enabled.first {
            return fallback
        }

        throw NSError(domain: "LocalReaderAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到可用书源，请先导入并启用书源"])
    }

    private func searchSources(keyword: String, sources: [BookSource]) async throws -> [SearchBook] {
        var merged: [SearchBook] = []
        await withTaskGroup(of: [SearchBook].self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return try await self.withTimeout(seconds: self.searchSourceTimeoutSeconds) {
                            try await self.webBook.searchBook(keyword: keyword, source: source)
                        }
                    } catch {
                        return []
                    }
                }
            }

            for await items in group {
                merged.append(contentsOf: items)
            }
        }
        return merged
    }

    private func withTimeout<T>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let duration = max(seconds, 0.1)
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                throw TimeoutError.timedOut
            }

            guard let first = try await group.next() else {
                throw TimeoutError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    private func toBookInfoResponse(_ book: Book) -> BookInfoResponse {
        return BookInfoResponse(
            name: book.name,
            author: book.author,
            bookUrl: book.bookUrl,
            sourceUrl: book.origin,
            coverUrl: book.coverUrl,
            intro: book.intro,
            kind: book.kind,
            latestChapter: book.latestChapterTitle,
            tocUrl: book.tocUrl,
            wordCount: nil,
            chapterCount: book.totalChapterNum,
            type: book.type,
            originName: book.originName,
            durChapterIndex: book.durChapterIndex,
            durChapterPos: book.durChapterPos,
            durChapterTime: book.durChapterTime,
            totalChapterNum: book.totalChapterNum
        )
    }

    private func toBookInfoResponse(_ search: SearchBook, sourceNameMap: [String: String]) -> BookInfoResponse {
        return BookInfoResponse(
            name: search.name,
            author: search.author,
            bookUrl: search.bookUrl,
            sourceUrl: search.bookSourceUrl,
            coverUrl: search.coverUrl,
            intro: search.intro,
            kind: search.kind,
            latestChapter: search.latestChapter,
            tocUrl: nil,
            wordCount: search.wordCount,
            chapterCount: nil,
            type: 0,
            originName: search.originName ?? sourceNameMap[search.bookSourceUrl],
            durChapterIndex: 0,
            durChapterPos: 0,
            durChapterTime: 0,
            totalChapterNum: 0
        )
    }

    private func normalize(_ value: String) -> String {
        return value.trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines) ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedIdentityText(_ value: String?) -> String {
        guard let value else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func canonicalSourceKey(_ value: String) -> String {
        let trimmed = normalize(value)
        guard !trimmed.isEmpty else { return "" }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate), let host = components.host?.lowercased() else {
            return trimmed.lowercased()
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = host

        var path = components.path
        while path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        components.path = path

        let normalizedQuery = components.percentEncodedQuery?.lowercased() ?? ""
        return "\(components.host ?? host)\(path)\(normalizedQuery.isEmpty ? "" : "?\(normalizedQuery)")"
    }

    private func sourceByHost(_ bookUrl: String) -> BookSource? {
        guard let host = URL(string: bookUrl)?.host?.lowercased(), !host.isEmpty else { return nil }
        return enabledSources().first { source in
            let sourceCandidate = source.bookSourceUrl.contains("://") ? source.bookSourceUrl : "https://\(source.bookSourceUrl)"
            guard let sourceHost = URL(string: sourceCandidate)?.host?.lowercased() else { return false }
            if sourceHost == host { return true }
            return host.hasSuffix(".\(sourceHost)") || sourceHost.hasSuffix(".\(host)")
        }
    }

    private func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = normalize(cleaned)
            guard seen.insert(key).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    private func filterSwitchCandidates(
        _ candidates: [SearchBook],
        currentSourceUrl: String,
        referenceName: String,
        referenceAuthor: String
    ) -> [SearchBook] {
        let currentSourceKey = canonicalSourceKey(currentSourceUrl)

        var deduped: [SearchBook] = []
        var seen = Set<String>()

        for item in candidates {
            let sourceUrl = item.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            let bookUrl = item.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceUrl.isEmpty, !bookUrl.isEmpty else { continue }

            let sourceKey = canonicalSourceKey(sourceUrl)
            let bookKey = normalize(bookUrl)

            if !currentSourceKey.isEmpty, sourceKey == currentSourceKey {
                continue
            }

            let dedupeKey = "\(sourceKey.isEmpty ? sourceUrl.lowercased() : sourceKey)|\(bookKey)"
            guard seen.insert(dedupeKey).inserted else { continue }
            deduped.append(item)
        }

        let strictMatched = deduped.filter { item in
            isLikelySameBookName(item.name, referenceName: referenceName) &&
            isLikelySameAuthor(item.author, referenceAuthor: referenceAuthor)
        }
        if !strictMatched.isEmpty {
            return strictMatched
        }

        let looseNameMatched = deduped.filter { item in
            isLikelySameBookName(item.name, referenceName: referenceName)
        }
        if !looseNameMatched.isEmpty {
            return looseNameMatched
        }

        return deduped
    }

    private func isLikelySameBookName(_ value: String, referenceName: String) -> Bool {
        let candidate = normalizedMatchText(value)
        let reference = normalizedMatchText(referenceName)
        guard !candidate.isEmpty, !reference.isEmpty else { return false }
        return candidate == reference
    }

    private func isLikelySameAuthor(_ value: String, referenceAuthor: String) -> Bool {
        let reference = normalizedMatchText(referenceAuthor)
        guard !reference.isEmpty else { return true }

        let candidate = normalizedMatchText(value)
        guard !candidate.isEmpty else { return false }

        if candidate == reference { return true }
        return candidate.contains(reference) || reference.contains(candidate)
    }

    private func normalizedMatchText(_ value: String) -> String {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return "" }

        let stripped = lowered.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped))
    }

    private func firstNonEmptyText(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private func searchRecoverKeywords(name: String, author: String) -> [String] {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return [] }

        var keywords: [String] = []
        if !cleanAuthor.isEmpty {
            keywords.append("\(cleanName) \(cleanAuthor)")
            keywords.append("\(cleanName)作者\(cleanAuthor)")
        }
        keywords.append(cleanName)
        keywords.append(cleanName.replacingOccurrences(of: " ", with: ""))
        return uniqueNonEmpty(keywords)
    }

    private func toChapterResponses(_ chapters: [BookChapter]) -> [ChapterResponse] {
        chapters.map {
            ChapterResponse(title: $0.title, url: $0.url, index: $0.index, isVip: $0.isVip, isPay: $0.isPay)
        }
    }

    private func resolveChapterTitleHint(
        index: Int,
        chapterUrl: String,
        resolvedChapterUrl: String,
        chapters: [ChapterResponse]
    ) -> String? {
        if index >= 0, index < chapters.count {
            let title = chapters[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }

        let urlCandidates = [chapterUrl, resolvedChapterUrl]
            .map { normalize($0) }
            .filter { !$0.isEmpty }
        if urlCandidates.isEmpty { return nil }

        if let matched = chapters.first(where: { urlCandidates.contains(normalize($0.url)) }) {
            let title = matched.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private func buildChapterRetryCandidates(
        index: Int,
        chapterUrl: String,
        resolvedChapterUrl: String,
        chapterTitleHint: String?,
        cachedChapters: [ChapterResponse],
        refreshedChapters: [ChapterResponse]
    ) -> [String] {
        var candidates: [String] = []

        if !chapterUrl.isEmpty {
            candidates.append(chapterUrl)
        }
        if !resolvedChapterUrl.isEmpty {
            candidates.append(resolvedChapterUrl)
        }

        candidates.append(contentsOf: chapterURLCandidates(index: index, titleHint: chapterTitleHint, chapters: refreshedChapters))
        candidates.append(contentsOf: chapterURLCandidates(index: index, titleHint: chapterTitleHint, chapters: cachedChapters))

        return withSchemeVariants(uniqueNonEmpty(candidates))
    }

    private func chapterURLCandidates(index: Int, titleHint: String?, chapters: [ChapterResponse]) -> [String] {
        guard !chapters.isEmpty else { return [] }
        var urls: [String] = []

        if index >= 0, index < chapters.count {
            urls.append(chapters[index].url)
        }

        let nearbyOffsets = [1, -1, 2, -2, 3, -3]
        for offset in nearbyOffsets {
            let candidateIndex = index + offset
            if candidateIndex >= 0, candidateIndex < chapters.count {
                urls.append(chapters[candidateIndex].url)
            }
        }

        if let titleHint {
            let hint = normalizedMatchText(titleHint)
            if !hint.isEmpty,
               let matched = chapters.first(where: { normalizedMatchText($0.title) == hint }) {
                urls.append(matched.url)
            }
        }

        return uniqueNonEmpty(urls)
    }

    private func withSchemeVariants(_ urls: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for url in urls {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = normalize(trimmed)
            if seen.insert(key).inserted {
                output.append(trimmed)
            }

            if let swapped = swapHTTPScheme(for: trimmed) {
                let swappedKey = normalize(swapped)
                if seen.insert(swappedKey).inserted {
                    output.append(swapped)
                }
            }
        }
        return output
    }

    private func recoverBookInfoTargetURLFromListFeed(
        listUrl: String,
        source: BookSource,
        referenceName: String,
        referenceAuthor: String
    ) async -> String? {
        guard isLikelyListFeedURL(listUrl) else { return nil }
        let cleanReferenceName = referenceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanReferenceName.isEmpty else { return nil }

        let descriptor = RuleURLRequestBuilder.build(
            ruleUrl: listUrl,
            baseUrl: source.bookSourceUrl,
            page: 1,
            defaultHeaders: RuleURLRequestBuilder.parseHeaderMap(source.header),
            sourceKey: source.bookSourceUrl,
            sourceHeader: source.header,
            sourceComment: nil,
            sourceName: source.bookSourceName
        )
        let requestUrl = descriptor.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestUrl.isEmpty else { return nil }

        let payload: String
        do {
            payload = try await network.request(
                url: descriptor.url,
                method: descriptor.method,
                headers: descriptor.headers,
                body: descriptor.body,
                retries: descriptor.retries,
                charset: descriptor.charset
            )
        } catch {
            localReaderLog("[ChapterFlow] list-recover request failed: \(error)")
            return nil
        }

        let ruleContexts: [(name: String, listRule: String, nameRule: String?, authorRule: String?, bookUrlRule: String?)] = [
            (
                name: "ruleExplore",
                listRule: source.ruleExplore?.bookList ?? "",
                nameRule: source.ruleExplore?.name,
                authorRule: source.ruleExplore?.author,
                bookUrlRule: source.ruleExplore?.bookUrl
            ),
            (
                name: "ruleSearch",
                listRule: source.ruleSearch?.bookList ?? "",
                nameRule: source.ruleSearch?.name,
                authorRule: source.ruleSearch?.author,
                bookUrlRule: source.ruleSearch?.bookUrl
            )
        ]

        for context in ruleContexts {
            let normalizedListRule = normalizeListRule(context.listRule).rule
            guard !normalizedListRule.isEmpty else { continue }

            let matched: String?
            do {
                matched = try findMatchedBookDetailURLFromListPayload(
                    payload,
                    requestUrl: requestUrl,
                    listRule: normalizedListRule,
                    nameRule: context.nameRule,
                    authorRule: context.authorRule,
                    bookUrlRule: context.bookUrlRule,
                    referenceName: cleanReferenceName,
                    referenceAuthor: referenceAuthor
                )
            } catch {
                continue
            }

            if let matched {
                localReaderLog("[ChapterFlow] list-recover matched via \(context.name)")
                return matched
            }
        }

        localReaderLog("[ChapterFlow] list-recover no match for name=\(cleanReferenceName)")
        return nil
    }

    private func findMatchedBookDetailURLFromListPayload(
        _ payload: String,
        requestUrl: String,
        listRule: String,
        nameRule: String?,
        authorRule: String?,
        bookUrlRule: String?,
        referenceName: String,
        referenceAuthor: String
    ) throws -> String? {
        var elements = try analyzer.analyzeList(html: payload, rule: listRule, baseUrl: requestUrl)
        if elements.isEmpty {
            let trimmedRule = listRule.trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredRule = trimmedRule.lowercased()
            if !loweredRule.hasPrefix("@json:"), trimmedRule.hasPrefix("$") {
                let jsonRule = "@Json:\(trimmedRule)"
                elements = (try? analyzer.analyzeList(html: payload, rule: jsonRule, baseUrl: requestUrl)) ?? []
            }
        }
        guard !elements.isEmpty else { return nil }

        struct Candidate {
            let element: Element
            let name: String
            let author: String
        }

        let candidates: [Candidate] = elements.compactMap { element in
            var name = sanitizeExploreText(extractElementValueWithJSONFallback(element, rule: nameRule, baseUrl: requestUrl))
            if name.isEmpty {
                name = sanitizeExploreText((try? element.text()) ?? "")
            }
            guard !name.isEmpty else { return nil }

            let author = sanitizeExploreText(extractElementValueWithJSONFallback(element, rule: authorRule, baseUrl: requestUrl))
            return Candidate(element: element, name: name, author: author)
        }

        guard !candidates.isEmpty else { return nil }

        let strict = candidates.filter { candidate in
            isLikelySameBookName(candidate.name, referenceName: referenceName)
                && isLikelySameAuthor(candidate.author, referenceAuthor: referenceAuthor)
        }
        let loose = candidates.filter { candidate in
            isLikelySameBookName(candidate.name, referenceName: referenceName)
        }

        let orderedMatches = strict + loose
        for candidate in orderedMatches {
            var detailBookUrl = sanitizeExploreText(extractElementValueWithJSONFallback(candidate.element, rule: bookUrlRule, baseUrl: requestUrl))
            if detailBookUrl.isEmpty {
                detailBookUrl = fallbackElementLink(candidate.element, baseUrl: requestUrl) ?? ""
            }
            guard !detailBookUrl.isEmpty else { continue }

            let resolved = analyzer.extractUrl(url: detailBookUrl, baseUrl: requestUrl).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else { continue }
            if normalize(resolved) == normalize(requestUrl) { continue }
            return resolved
        }

        let jsonFallbackCandidates = buildJSONFallbackCandidates(
            payload: payload,
            listRule: listRule,
            nameRule: nameRule,
            authorRule: authorRule,
            bookUrlRule: bookUrlRule,
            baseUrl: requestUrl
        )
        let jsonStrict = jsonFallbackCandidates.filter { candidate in
            isLikelySameBookName(candidate.name, referenceName: referenceName)
                && isLikelySameAuthor(candidate.author, referenceAuthor: referenceAuthor)
        }
        let jsonLoose = jsonFallbackCandidates.filter { candidate in
            isLikelySameBookName(candidate.name, referenceName: referenceName)
        }

        for candidate in (jsonStrict + jsonLoose) {
            let resolved = analyzer.extractUrl(url: candidate.bookUrl, baseUrl: requestUrl).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else { continue }
            if normalize(resolved) == normalize(requestUrl) { continue }
            return resolved
        }

        return nil
    }

    private func buildJSONFallbackCandidates(
        payload: String,
        listRule: String,
        nameRule: String?,
        authorRule: String?,
        bookUrlRule: String?,
        baseUrl: String
    ) -> [(name: String, author: String, bookUrl: String)] {
        guard let listObjects = jsonListObjects(from: payload, listRule: listRule), !listObjects.isEmpty else {
            return []
        }

        var results: [(name: String, author: String, bookUrl: String)] = []
        results.reserveCapacity(listObjects.count)

        for object in listObjects {
            let name = sanitizeExploreText(extractJSONRuleValue(nameRule, object: object))
            guard !name.isEmpty else { continue }
            let author = sanitizeExploreText(extractJSONRuleValue(authorRule, object: object))
            let rawBookUrl = sanitizeExploreText(extractJSONRuleValue(bookUrlRule, object: object))
            guard !rawBookUrl.isEmpty else { continue }
            let resolvedBookUrl = analyzer.extractUrl(url: rawBookUrl, baseUrl: baseUrl)
            if resolvedBookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            results.append((name: name, author: author, bookUrl: resolvedBookUrl))
        }
        return results
    }

    private func jsonListObjects(from payload: String, listRule: String) -> [[String: Any]]? {
        guard let data = payload.data(using: .utf8),
              let rootObject = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let normalizedRule = listRule
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@Json:", with: "", options: [.caseInsensitive, .anchored])

        guard normalizedRule.hasPrefix("$."),
              normalizedRule.hasSuffix("[*]") else {
            return nil
        }

        let start = normalizedRule.index(normalizedRule.startIndex, offsetBy: 2)
        let end = normalizedRule.index(normalizedRule.endIndex, offsetBy: -3)
        let path = String(normalizedRule[start..<end])
        let keys = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard !keys.isEmpty else { return nil }

        var cursor: Any = rootObject
        for key in keys {
            guard let dict = cursor as? [String: Any],
                  let next = dict[key] else {
                return nil
            }
            cursor = next
        }

        guard let array = cursor as? [Any] else { return nil }
        return array.compactMap { $0 as? [String: Any] }
    }

    private func extractJSONRuleValue(_ rule: String?, object: [String: Any]) -> String {
        guard let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            return ""
        }

        if let analyzed = analyzeJSONRuleValueWithRuleEngine(rule, object: object),
           !analyzed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return analyzed
        }

        if rule.contains("{{") && rule.contains("}}") {
            return replaceJSONTemplate(rule, object: object)
        }

        var normalizedRule = rule
        if normalizedRule.lowercased().hasPrefix("@json:") {
            normalizedRule = String(normalizedRule.dropFirst(6))
        }
        guard normalizedRule.hasPrefix("$.") else { return "" }

        let path = String(normalizedRule.dropFirst(2))
        let keys = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard !keys.isEmpty else { return "" }

        var cursor: Any = object
        for key in keys {
            guard let dict = cursor as? [String: Any],
                  let next = dict[key] else {
                return ""
            }
            cursor = next
        }
        return stringifyJSONValue(cursor)
    }

    private func analyzeJSONRuleValueWithRuleEngine(_ rule: String, object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let payload = String(data: data, encoding: .utf8),
              let element = try? SwiftSoup.parseBodyFragment("<div></div>").body()?.children().first() else {
            return nil
        }

        _ = try? element.attr("data-json", payload)
        _ = try? element.text(payload)
        return try? analyzer.analyzeElement(element: element, rule: rule, baseUrl: "")
    }

    private func replaceJSONTemplate(_ template: String, object: [String: Any]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*\$\.(\w+(?:\.\w+)*)\s*\}\}"#, options: []) else {
            return template
        }
        let nsRange = NSRange(template.startIndex..., in: template)
        let matches = regex.matches(in: template, options: [], range: nsRange)
        guard !matches.isEmpty else { return template }

        var output = template
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let wholeRange = Range(match.range(at: 0), in: output),
                  let pathRange = Range(match.range(at: 1), in: output) else {
                continue
            }
            let path = String(output[pathRange])
            let value = extractJSONPathValue(path, object: object)
            output.replaceSubrange(wholeRange, with: value)
        }
        return output
    }

    private func extractJSONPathValue(_ path: String, object: [String: Any]) -> String {
        let keys = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard !keys.isEmpty else { return "" }

        var cursor: Any = object
        for key in keys {
            guard let dict = cursor as? [String: Any],
                  let next = dict[key] else {
                return ""
            }
            cursor = next
        }
        return stringifyJSONValue(cursor)
    }

    private func stringifyJSONValue(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private func extractElementValueWithJSONFallback(_ element: Element, rule: String?, baseUrl: String) -> String {
        guard let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            return ""
        }

        if let primary = try? extractElementValue(element, rule, baseUrl: baseUrl),
           !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return primary
        }

        if !rule.lowercased().hasPrefix("@json:"), rule.hasPrefix("$") {
            let jsonRule = "@Json:\(rule)"
            if let fallback = try? extractElementValue(element, jsonRule, baseUrl: baseUrl),
               !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fallback
            }
        }
        return ""
    }

    private func swapHTTPScheme(for ruleURL: String) -> String? {
        let trimmed = ruleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let split = splitRuleURLAndOptions(trimmed)
        let lowerURL = split.url.lowercased()
        let swappedURL: String
        if lowerURL.hasPrefix("http://") {
            swappedURL = "https://" + split.url.dropFirst(7)
        } else if lowerURL.hasPrefix("https://") {
            swappedURL = "http://" + split.url.dropFirst(8)
        } else {
            return nil
        }
        return swappedURL + split.optionsSuffix
    }

    private func splitRuleURLAndOptions(_ value: String) -> (url: String, optionsSuffix: String) {
        guard let regex = try? NSRegularExpression(pattern: "\\s*,\\s*(?=\\{)") else {
            return (value, "")
        }
        let nsRange = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: nsRange),
              let commaRange = Range(match.range, in: value) else {
            return (value, "")
        }

        let urlPart = String(value[..<commaRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let options = String(value[commaRange.lowerBound...])
        return (urlPart, options)
    }

    private func shouldRefreshChapterListAfterContentError(_ error: Error) -> Bool {
        if let networkError = error as? NetworkError {
            if case .httpError(let statusCode) = networkError, statusCode == 404 {
                return true
            }
            return false
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("404")
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

    private func persistBookmarks(_ bookmarks: [Bookmark]) {
        if let data = try? JSONEncoder().encode(bookmarks) {
            userDefaults.set(data, forKey: bookmarkStorageKey)
        }
    }

    private func encodeRule<T: Encodable>(_ rule: T?) -> String? {
        guard let rule,
              let data = try? JSONEncoder().encode(rule) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func decodeRule<T: Decodable>(_ raw: String?) -> T? {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8) else {
            return nil
        }

        if let value = try? JSONDecoder().decode(T.self, from: data) {
            return value
        }

        if let object = try? JSONSerialization.jsonObject(with: data),
           let normalizedData = try? JSONSerialization.data(withJSONObject: object),
           let value = try? JSONDecoder().decode(T.self, from: normalizedData) {
            return value
        }

        return nil
    }

    private func extractElementValue(_ element: Element, _ rule: String?, baseUrl: String = "") throws -> String {
        guard let rule, !rule.isEmpty else { return "" }
        return try analyzer.analyzeElement(element: element, rule: rule, baseUrl: baseUrl)
    }

    private func containsInvalidChapterTitles(_ chapters: [BookChapter]) -> Bool {
        guard !chapters.isEmpty else { return false }
        let invalidCount = chapters.reduce(into: 0) { partial, chapter in
            if looksLikeJSONLikeText(chapter.title) {
                partial += 1
            }
        }
        // 只要有明显 JSON 目录脏数据，就触发重抓，避免用户一直看到原始 JSON 文本。
        return invalidCount > 0
    }

    private func containsAbnormalChapterOrder(_ chapters: [BookChapter]) -> Bool {
        let nonVolume = chapters.filter { !$0.isVolume }
        guard nonVolume.count >= 8 else { return false }

        let measured = nonVolume.compactMap { chapter -> Int? in
            chapterSequenceNumber(title: chapter.title, url: chapter.url)
        }
        guard measured.count >= max(6, nonVolume.count / 3) else { return false }

        var ascendingPairs = 0
        var descendingPairs = 0
        var earlyHugeDrop = false

        for idx in 1..<measured.count {
            let previous = measured[idx - 1]
            let current = measured[idx]
            if current >= previous {
                ascendingPairs += 1
            } else {
                descendingPairs += 1
                if idx <= 4, previous - current >= 10 {
                    earlyHugeDrop = true
                }
            }
        }

        if earlyHugeDrop {
            return true
        }
        if descendingPairs > ascendingPairs * 2 {
            return true
        }
        return false
    }

    private func sanitizeChapterList(_ chapters: [BookChapter]) -> [BookChapter] {
        guard chapters.count > 1 else { return chapters }

        var filtered: [BookChapter] = []
        filtered.reserveCapacity(chapters.count)

        for chapter in chapters {
            if chapter.isVolume {
                filtered.append(chapter)
                continue
            }

            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = chapter.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || url.isEmpty {
                continue
            }
            if isLikelyNavigationTitle(title) || isLikelyNonChapterMetaTitle(title) {
                continue
            }
            if hasInvalidChapterRequestPayload(url) {
                continue
            }

            let titleLooksLikeChapter = isLikelyChapterTitle(title)
            let looksLikePagination = isLikelyPaginationURL(url)
            let looksLikeCategory = isLikelyCategoryOrListURL(url)
            if looksLikePagination && !titleLooksLikeChapter {
                continue
            }
            if looksLikeCategory && !titleLooksLikeChapter {
                continue
            }

            if isLikelyNonChapterURL(url) && !titleLooksLikeChapter {
                continue
            }

            filtered.append(chapter)
        }

        guard !filtered.isEmpty else { return chapters }

        let originalNonVolumeCount = chapters.filter { !$0.isVolume }.count
        let filteredNonVolumeCount = filtered.filter { !$0.isVolume }.count
        if originalNonVolumeCount >= 6, filteredNonVolumeCount < max(2, originalNonVolumeCount / 3) {
            return chapters
        }

        var normalized: [BookChapter] = []
        normalized.reserveCapacity(filtered.count)
        var runningIndex = 0
        for var chapter in filtered {
            chapter.index = runningIndex
            runningIndex += 1
            normalized.append(chapter)
        }
        return normalized
    }

    private func isLikelyValidChapterResult(_ chapters: [BookChapter], tocUrl: String, bookUrl: String) -> Bool {
        let nonVolume = chapters.filter { !$0.isVolume }
        guard !nonVolume.isEmpty else { return false }

        let usable = nonVolume.filter { chapter in
            !chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return false }

        let suspiciousTitleCount = usable.reduce(into: 0) { partial, chapter in
            if isLikelyNonChapterMetaTitle(chapter.title) {
                partial += 1
            }
        }
        if usable.count >= 4, suspiciousTitleCount * 2 >= usable.count {
            return false
        }

        let suspiciousURLCount = usable.reduce(into: 0) { partial, chapter in
            if isLikelyNonChapterURL(chapter.url) {
                partial += 1
            }
        }
        if usable.count >= 4, suspiciousURLCount * 2 >= usable.count {
            return false
        }

        if usable.count >= 8 {
            let detailURLCount = usable.reduce(into: 0) { partial, chapter in
                if isLikelyBookDetailURL(chapter.url) {
                    partial += 1
                }
            }
            if detailURLCount >= max(3, usable.count / 3) {
                return false
            }

            if let baseBookId = extractPrimaryBookID(from: tocUrl) ?? extractPrimaryBookID(from: bookUrl) {
                let sameBookURLCount = usable.reduce(into: 0) { partial, chapter in
                    if chapter.url.contains(baseBookId) {
                        partial += 1
                    }
                }
                let chapterTitleLikeCount = usable.reduce(into: 0) { partial, chapter in
                    if isLikelyChapterTitle(chapter.title) {
                        partial += 1
                    }
                }

                // 防止“相关推荐/同类书单”误识别为目录：
                // 标题不像章节，且 URL 很少命中当前书籍 ID，则判为无效目录。
                if chapterTitleLikeCount <= 1, sameBookURLCount * 3 < usable.count {
                    return false
                }
            }
        }

        let normalizedURLs = usable
            .map { normalize($0.url) }
            .filter { !$0.isEmpty }
        let uniqueURLCount = Set(normalizedURLs).count
        if usable.count >= 3, uniqueURLCount <= 1 {
            return false
        }

        let invalidPayloadCount = usable.reduce(into: 0) { partial, chapter in
            if hasInvalidChapterRequestPayload(chapter.url) {
                partial += 1
            }
        }
        if invalidPayloadCount == usable.count {
            return false
        }

        let navCount = usable.reduce(into: 0) { partial, chapter in
            if isLikelyNavigationTitle(chapter.title) {
                partial += 1
            }
        }
        if usable.count >= 4, navCount * 2 >= usable.count {
            return false
        }

        let chapterLikeCount = usable.reduce(into: 0) { partial, chapter in
            if chapterSequenceNumber(title: chapter.title, url: chapter.url) != nil || isLikelyChapterURLPattern(chapter.url) {
                partial += 1
            }
        }
        if usable.count >= 3, chapterLikeCount == 0 {
            return false
        }

        // 单章短篇允许通过，但至少不能是明显导航/占位 URL。
        if usable.count == 1 {
            let first = usable[0]
            if isLikelyNavigationTitle(first.title) || hasInvalidChapterRequestPayload(first.url) {
                return false
            }
            let compactTitle = first.title
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if compactTitle.count > 120 {
                return false
            }
            let loweredTitle = compactTitle.lowercased()
            let nonChapterSignals = [
                "trang chủ", "mới nhất", "chuyên mục", "từ khóa", "tìm kiếm",
                "nhận thông báo", "copyright", "email:"
            ]
            let signalCount = nonChapterSignals.reduce(into: 0) { partial, token in
                if loweredTitle.contains(token) {
                    partial += 1
                }
            }
            if signalCount >= 2 {
                return false
            }
        }

        return true
    }

    private func synthesizeDirectContentFallbackChaptersIfNeeded(
        source: BookSource,
        tocUrl: String,
        bookUrl: String,
        referenceName: String,
        chapters: [BookChapter],
        cleanedChapters: [BookChapter]
    ) -> [BookChapter]? {
        guard supportsDirectContentFallbackForSource(source) else { return nil }

        let nonVolume = cleanedChapters.filter { !$0.isVolume }
        if !nonVolume.isEmpty {
            let chapterLikeCount = nonVolume.reduce(into: 0) { partial, chapter in
                if isLikelyChapterTitle(chapter.title)
                    || chapterSequenceNumber(title: chapter.title, url: chapter.url) != nil {
                    partial += 1
                }
            }
            if chapterLikeCount >= 2 {
                return nil
            }

            if nonVolume.count > 1 {
                let noisyCount = nonVolume.reduce(into: 0) { partial, chapter in
                    if isLikelyNavigationTitle(chapter.title)
                        || isLikelyNonChapterMetaTitle(chapter.title)
                        || isLikelyNonChapterURL(chapter.url)
                        || hasInvalidChapterRequestPayload(chapter.url) {
                        partial += 1
                    }
                }
                if noisyCount * 2 < nonVolume.count {
                    return nil
                }
            }
        }

        guard let fallbackURL = resolveDirectContentFallbackURL(
            tocUrl: tocUrl,
            bookUrl: bookUrl,
            parsedChapters: chapters
        ) else {
            return nil
        }

        var chapter = BookChapter()
        chapter.bookUrl = bookUrl
        chapter.baseUrl = fallbackURL
        chapter.index = 0
        chapter.title = directContentFallbackTitle(referenceName: referenceName)
        chapter.url = fallbackURL
        return [chapter]
    }

    private func supportsDirectContentFallbackForSource(_ source: BookSource) -> Bool {
        let chapterURLRule = source.ruleToc?.chapterUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard chapterURLRule.isEmpty else { return false }

        let contentRule = source.ruleContent?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !contentRule.isEmpty
    }

    private func resolveDirectContentFallbackURL(
        tocUrl: String,
        bookUrl: String,
        parsedChapters: [BookChapter]
    ) -> String? {
        let rawCandidates = [tocUrl, bookUrl] + parsedChapters.map(\.url)
        var seen = Set<String>()

        for raw in rawCandidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let normalized = normalize(trimmed)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }

            let lowered = (trimmed.removingPercentEncoding ?? trimmed).lowercased()
            if hasInvalidChapterRequestPayload(trimmed) {
                continue
            }
            if isLikelyListFeedURL(lowered)
                || isLikelyCategoryOrListURL(lowered)
                || isLikelyPaginationURL(lowered)
                || isLikelyNonChapterURL(lowered) {
                continue
            }
            return trimmed
        }
        return nil
    }

    private func directContentFallbackTitle(referenceName: String) -> String {
        let cleaned = referenceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return "正文"
        }
        if cleaned.count > 80 {
            return "正文"
        }
        return "正文"
    }

    private func shouldDeferDetailPageTocResult(
        tocUrl: String,
        bookUrl: String,
        source: BookSource,
        rawChapters: [BookChapter],
        cleanedChapters: [BookChapter]
    ) -> Bool {
        let normalizedToc = normalize(tocUrl)
        let normalizedBook = normalize(bookUrl)
        guard !normalizedToc.isEmpty, normalizedToc == normalizedBook else { return false }
        guard isLikelyBookDetailURL(tocUrl) else { return false }
        guard let tocRule = source.ruleBookInfo?.tocUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tocRule.isEmpty else {
            return false
        }

        let rawNonVolume = rawChapters.filter { !$0.isVolume }
        let cleanedNonVolume = cleanedChapters.filter { !$0.isVolume }
        guard !cleanedNonVolume.isEmpty else { return false }

        let removedNoiseCount = max(0, rawNonVolume.count - cleanedNonVolume.count)
        if removedNoiseCount >= 2 {
            return true
        }
        if cleanedNonVolume.count <= 3 && rawNonVolume.count <= 6 {
            return true
        }
        return false
    }

    private func isLikelyBookDetailURL(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return true }
        let path: String
        if let components = URLComponents(string: value) {
            path = components.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else {
            path = value
        }
        guard !path.isEmpty else { return false }
        if path.contains("/page-") { return false }

        // 仅识别“书籍详情页”形态，避免把章节 URL（如 /123/456.html）误判为详情页。
        let anchoredPatterns = [
            #"^/(?:txt|book|novel|info)/\d+(?:\.html?)?/?$"#,
            #"^/\d{3,}/?$"#,
            #"^/\d{3,}\.html?$"#
        ]
        return anchoredPatterns.contains { pattern in
            path.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func extractPrimaryBookID(from raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        let patterns = [
            #"/(?:txt|book|novel|info)/(\d{3,})(?:\.html|/|$)"#,
            #"[?&](?:bookid|bid|book_id|id)=(\d{3,})"#
        ]

        let nsRange = NSRange(value.startIndex..., in: value)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: value, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: value) else {
                continue
            }
            let bookId = String(value[range])
            if !bookId.isEmpty {
                return bookId
            }
        }
        return nil
    }

    private func isLikelyChapterTitle(_ raw: String) -> Bool {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        if extractChapterNumber(from: title) != nil {
            return true
        }

        let lowered = title.lowercased()
        let fuzzy = ["序章", "楔子", "引子", "后记", "番外", "尾声", "chapter"]
        return fuzzy.contains { lowered.contains($0.lowercased()) }
    }

    private func isLikelyNonChapterMetaTitle(_ raw: String) -> Bool {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return true }
        let lowered = title.lowercased()

        let exact: Set<String> = [
            "分类", "全本", "最新", "排行", "目录", "章节目录", "返回", "返回目录", "返回首页",
            "加入书架", "点击下载", "下载", "报错", "电脑版", "书架", "点击阅读", "开始阅读",
            "上一页", "下一页", "首页", "尾页"
        ]
        if exact.contains(title) { return true }

        let fuzzy = [
            "txt免费下载", "免费下载", "rar/zip", "rar", "zip", "作者：", "作者", "分类：",
            "状态：", "更新时间", "最新网址", "小说简介", "推荐地址", "手机阅读", "全文阅读", "无弹窗"
        ]
        if fuzzy.contains(where: { lowered.contains($0.lowercased()) }) {
            return true
        }

        if lowered.contains("txt") && lowered.contains("下载") {
            return true
        }
        if lowered.contains("rar") || lowered.contains("zip") {
            return true
        }

        let pageRangePattern = #"^第\s*\d+\s*-\s*\d+\s*章$"#
        if title.range(of: pageRangePattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func isLikelyNonChapterURL(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return true }

        if value.hasPrefix("javascript:") || value.hasPrefix("mailto:") {
            return true
        }

        let suspiciousTokens = [
            "/search", "search.php", "search.", "/download", "/down/",
            "/cat/", "/cate", "/rank/", "/class", "/top/", "favicon", "keywords="
        ]
        if suspiciousTokens.contains(where: { value.contains($0) }) {
            return true
        }
        return false
    }

    private func isLikelyCategoryOrListURL(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }

        let tokens = [
            "/class", "/top/", "/sort/", "/category", "/tag/", "/tags/",
            "/modules/article/search", "search.php", "groupid=", "sub=", "categoryid="
        ]
        return tokens.contains(where: { value.contains($0) })
    }

    private func isLikelyPaginationURL(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        let patterns = [
            #"/page[-_/]\d+(?:\.html)?(?:$|[?#])"#,
            #"[?&](?:page|p)=\d+(?:$|[&#])"#
        ]
        return patterns.contains { pattern in
            value.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func hasInvalidChapterRequestPayload(_ url: String) -> Bool {
        let lowered = url.lowercased()
        let decoded = lowered.removingPercentEncoding ?? lowered
        let compact = decoded.replacingOccurrences(of: "\\", with: "")

        if compact.contains("{{") && compact.contains("}}") {
            return true
        }
        if compact.contains("\"bookid\":\"\"") ||
            compact.contains("\"bookid\":null") ||
            compact.contains("\"chapterseqno\":[]") ||
            compact.contains("\"chapterseqno\":[null]") ||
            compact.contains("\"chapterseqno\":[\"\"]") {
            return true
        }
        if lowered.contains("%22bookid%22:%22%22") ||
            lowered.contains("%22bookid%22:null") ||
            lowered.contains("%22chapterseqno%22:%5b%5d") {
            return true
        }
        return false
    }

    private func isLikelyNavigationTitle(_ raw: String) -> Bool {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return true }

        let exact = Set([
            "分类", "全本", "最新", "排行", "上一页", "下一页", "首页", "尾页",
            "目录", "章节目录", "返回", "返回目录", "返回首页", "加入书架", "点击下载",
            "下载", "报错", "电脑版", "书架", "点击阅读", "开始阅读"
        ])
        if exact.contains(title) {
            return true
        }

        let fuzzy = ["排行榜", "推荐", "搜索", "登录", "注册", "收藏", "投票", "广告"]
        if fuzzy.contains(where: { title.contains($0) }) {
            return true
        }

        let navPattern = #"^(第?\s*\d+\s*页|[<>«»‹›]+|\.{2,})$"#
        return title.range(of: navPattern, options: .regularExpression) != nil
    }

    private func isLikelyChapterURLPattern(_ rawURL: String) -> Bool {
        let value = rawURL.lowercased()
        let tokens = [
            "/chapter", "chapter/", "/read/", "/book/", ".html", ".htm", ".xhtml",
            "chapterid=", "cid=", "serialid="
        ]
        return tokens.contains(where: { value.contains($0) })
    }

    private func isLikelyTocCandidate(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count > 1024 { return false }
        if trimmed.contains("\n") || trimmed.contains("\r") || trimmed.contains("\t") { return false }
        if trimmed.contains(" ") { return false }
        let lowered = (trimmed.removingPercentEncoding ?? trimmed).lowercased()
        if lowered.hasPrefix("@js:") || lowered.hasPrefix("javascript:") || lowered.hasPrefix("data:") {
            return false
        }
        if lowered.contains("{{") && lowered.contains("}}") {
            return false
        }
        if hasEmptyIdentifierParameter(in: lowered) {
            return false
        }
        if isLikelyListFeedURL(lowered) {
            return false
        }

        return true
    }

    private func isLikelyListFeedURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = (trimmed.removingPercentEncoding ?? trimmed).lowercased()
        let hasBookIdHint = hasBookIdentifierHint(in: lowered)

        let strongTokens = [
            "/rank/list", "/api/rank/", "groupid=", "categoryid=", "sub=", "filter_"
        ]
        if strongTokens.contains(where: { lowered.contains($0) }) {
            return !hasBookIdHint || hasEmptyIdentifierParameter(in: lowered)
        }

        let pagedList =
            (lowered.contains("start=") || lowered.contains("page=") || lowered.contains("offset="))
            && (lowered.contains("count=") || lowered.contains("limit="))
        if pagedList {
            return !hasBookIdHint
        }

        return false
    }

    private func shouldUseBookURLAsChapterCacheKey(_ rawBookURL: String) -> Bool {
        let trimmed = rawBookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = (trimmed.removingPercentEncoding ?? trimmed).lowercased()
        if hasEmptyIdentifierParameter(in: lowered) {
            return false
        }
        if isLikelyListFeedURL(lowered) {
            return false
        }
        return true
    }

    private func hasEmptyIdentifierParameter(in value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "")

        let queryPatterns = [
            #"[?&](?:bookid|book_id|bid|novelid|resourceid)=($|&|#)"#
        ]
        let nsRange = NSRange(normalized.startIndex..., in: normalized)
        for pattern in queryPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            if regex.firstMatch(in: normalized, options: [], range: nsRange) != nil {
                return true
            }
        }

        let invalidValuePatterns = [
            #"[?&](?:bookid|book_id|bid|novelid|resourceid|chapterid|serialid)=(?:nan|null|undefined|nil|none|n/a|na)(?:$|[&#])"#
        ]
        for pattern in invalidValuePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            if regex.firstMatch(in: normalized, options: [], range: nsRange) != nil {
                return true
            }
        }

        let payloadHints = [
            "\"bookid\":\"\"",
            "\"bookid\":null",
            "\"bookid\":\"nan\"",
            "\"book_id\":\"\"",
            "\"book_id\":null",
            "\"book_id\":\"nan\"",
            "\"resourceid\":\"\"",
            "\"resourceid\":null",
            "\"resourceid\":\"nan\""
        ]
        if payloadHints.contains(where: { normalized.contains($0) }) {
            return true
        }

        return false
    }

    private func isLikelySearchRecoverBookURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return isLikelyTocCandidate(trimmed)
    }

    private func normalizedSearchRecoverBookURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidates: [String] = [trimmed]
        if let extracted = firstHTTPURL(in: trimmed), extracted != trimmed {
            candidates.insert(extracted, at: 0)
        }

        for candidate in candidates {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let lowered = (normalized.removingPercentEncoding ?? normalized).lowercased()
            if lowered.contains("{{") && lowered.contains("}}") {
                continue
            }
            if hasEmptyIdentifierParameter(in: lowered) {
                continue
            }
            if isLikelyListFeedURL(lowered) {
                continue
            }
            return normalized
        }
        return nil
    }

    private func firstHTTPURL(in text: String) -> String? {
        let pattern = #"https?://[^\s"'<>()]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func hasBookIdentifierHint(in value: String) -> Bool {
        let tokens = [
            "bookid=", "book_id=", "bid=", "novelid=", "resourceid=", "chapterid=", "serialid=",
            "/book/", "/novel/", "/chapter", "/catalog", "all-chapter", "mulu", "dir"
        ]
        return tokens.contains(where: { value.contains($0) })
    }

    private func chapterSequenceNumber(title: String, url: String) -> Int? {
        if let titleNumber = extractChapterNumber(from: title) {
            return titleNumber
        }
        return extractTailNumber(from: url)
    }

    private func extractChapterNumber(from raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let patterns = [
            // 同时兼容简繁体章节后缀（如 “第1话 / 第1話 / 第1章節”），避免误判为非章节目录。
            "第\\s*([零〇○一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟\\d]+)\\s*[章节章節回囘卷集话話部篇幕節]",
            "^\\s*([0-9]{1,6})\\s*[\\.、\\-\\s]",
            "(?i)chapter\\s*([0-9]{1,6})"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let nsRange = NSRange(value.startIndex..., in: value)
            guard let match = regex.firstMatch(in: value, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: value) else {
                continue
            }

            let token = String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int(token), number > 0 {
                return number
            }
            if let number = chineseNumberToInt(token), number > 0 {
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
        let result = total + section + number
        return result > 0 ? result : nil
    }

    private func fallbackElementLink(_ element: Element, baseUrl: String) -> String? {
        let attrs = ["href", "data-href", "data-url"]
        for attr in attrs {
            let raw = ((try? element.attr(attr)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            return analyzer.extractUrl(url: raw, baseUrl: baseUrl)
        }
        if let anchor = try? element.select("a").first() {
            let raw = ((try? anchor.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            return analyzer.extractUrl(url: raw, baseUrl: baseUrl)
        }
        return nil
    }

    private func fallbackElementImage(_ element: Element, baseUrl: String) -> String? {
        let attrs = ["src", "data-src", "data-original"]
        for attr in attrs {
            let raw = ((try? element.attr(attr)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            return analyzer.extractUrl(url: raw, baseUrl: baseUrl)
        }
        if let image = try? element.select("img").first() {
            for attr in attrs {
                let raw = ((try? image.attr(attr)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                return analyzer.extractUrl(url: raw, baseUrl: baseUrl)
            }
        }
        return nil
    }

    private func sanitizeExploreText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !looksLikeJSONLikeText(trimmed) else { return "" }
        return trimmed
    }

    private func looksLikeJSONLikeText(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return true
        }
        if (trimmed.hasPrefix("\"{") && trimmed.hasSuffix("}\"")) || (trimmed.hasPrefix("\"[") && trimmed.hasSuffix("]\"")) {
            return true
        }
        let lowered = trimmed.lowercased()
        if (lowered.contains("\"code\"") || lowered.contains("\"data\"") || lowered.contains("\"msg\""))
            && (trimmed.contains("{") || trimmed.contains("[")) {
            return true
        }
        return false
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
    
    private func normalizeInlineHTML(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.contains("<") && trimmed.contains(">") else { return trimmed }
        do {
            let doc = try SwiftSoup.parseBodyFragment(trimmed)
            return (try doc.text()).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return trimmed
        }
    }
}

private enum TimeoutError: Error {
    case timedOut
}

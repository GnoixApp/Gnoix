import Foundation

class ReadBookEngine {
    static let shared = ReadBookEngine()
    private static let verboseLoggingEnabled = false

    var book: Book?
    private(set) var chapters: [BookChapter] = []
    private(set) var currentChapterIndex: Int = 0
    private(set) var currentContent: ChapterContent?
    var bookSource: BookSource?
    private var localFileContent: String = ""
    private var localChapterContents: [Int: String] = [:]
    private var localChapterCacheOrder: [Int] = []
    private var localEpubChapterPaths: [Int: String] = [:]
    private var localFileURL: URL?
    private var localFileExtension: String = ""
    private let localChapterCacheLimit: Int = 24
    private var remoteChapterContents: [Int: ChapterContent] = [:]
    private var remoteChapterCacheOrder: [Int] = []
    private let remoteChapterCacheLimit: Int = 16
    private var remoteChapterPreloadTasks: [Int: Task<Void, Never>] = [:]
    private var progressSaveTimer: Timer?
    private let progressSaveInterval: TimeInterval = 30
    
    private var currentLoadTaskId: Int64 = 0
    private var currentLocalContentTaskId: Int64 = 0
    private var currentRemoteContentTaskId: Int64 = 0

    var onChapterChanged: ((Int, String) -> Void)?
    var onContentLoaded: ((ChapterContent) -> Void)?
    var onProgressChanged: ((Int, Int) -> Void)?
    var onLoadFailed: ((String) -> Void)?

    private let database = DatabaseManager.shared
    private let txtTocParser = TxtTocParser.shared

    private init() {}

    private func log(_ message: @autoclosure () -> String) {
        guard Self.verboseLoggingEnabled else { return }
        print(message())
    }

    func openBook(_ book: Book, source: BookSource? = nil, resetIndex: Bool = false) {
        self.book = book
        self.bookSource = source
        currentLoadTaskId += 1
        
        if resetIndex {
            self.currentChapterIndex = 0
        } else {
            self.currentChapterIndex = book.durChapterIndex
        }
        
        chapters.removeAll()
        currentContent = nil
        localFileContent = ""
        localChapterContents.removeAll()
        localChapterCacheOrder.removeAll()
        localEpubChapterPaths.removeAll()
        cancelRemotePreloadTasks()
        remoteChapterContents.removeAll()
        remoteChapterCacheOrder.removeAll()
        localFileURL = nil
        localFileExtension = ""
        currentLocalContentTaskId = 0
        currentRemoteContentTaskId = 0
        
        startProgressSaveTimer()
        
        Task {
            await loadBookConfig()
        }
        
        loadChapters()
    }
    
    func reset() {
        self.book = nil
        self.bookSource = nil
        self.chapters.removeAll()
        self.currentContent = nil
        self.currentChapterIndex = 0
        self.localFileContent = ""
        self.localChapterContents.removeAll()
        self.localChapterCacheOrder.removeAll()
        self.localEpubChapterPaths.removeAll()
        cancelRemotePreloadTasks()
        self.remoteChapterContents.removeAll()
        self.remoteChapterCacheOrder.removeAll()
        self.localFileURL = nil
        self.localFileExtension = ""
        self.currentLocalContentTaskId = 0
        self.currentRemoteContentTaskId = 0
    }
    
    func reapplyContentCleanerToLoadedContent() {
        if book?.origin == Book.localTag {
            if let chapter = chapters[safe: currentChapterIndex],
               let raw = localChapterContents[currentChapterIndex] {
                publishLocalContent(chapter: chapter, content: raw)
                return
            }
        } else {
            for (index, chapterContent) in remoteChapterContents {
                remoteChapterContents[index] = cleanedChapterContent(chapterContent)
            }
            if let cached = remoteChapterContents[currentChapterIndex] {
                currentContent = cached
                onContentLoaded?(cached)
                return
            }
        }
        
        if let current = currentContent {
            let cleaned = cleanedChapterContent(current)
            currentContent = cleaned
            onContentLoaded?(cleaned)
        }
    }
    
    private func loadBookConfig() async {
        let globalConfig = loadConfigFromLocal()
        let baseConfig = book?.readConfig ?? ReadConfig()
        let resolvedConfig = applyGlobalReadConfig(globalConfig, to: baseConfig)

        await MainActor.run {
            guard var currentBook = self.book else { return }
            currentBook.readConfig = resolvedConfig
            self.book = currentBook
        }

        // 若本地全局配置为空，则以当前书籍配置回填一次，避免下次打开回落默认值。
        if globalConfig == nil {
            saveConfigToLocal(resolvedConfig)
        }
    }

    private func applyGlobalReadConfig(_ globalConfig: ReadConfig?, to baseConfig: ReadConfig) -> ReadConfig {
        guard let globalConfig else { return baseConfig }
        return globalConfig
    }
    
    func loadChapters() {
        guard let book = book else { return }

        if book.origin == Book.localTag {
            loadLocalChapters()
        } else {
            loadRemoteChapters()
        }
    }

    private func loadLocalChapters() {
        guard let book = book else { return }

        let taskId = currentLoadTaskId
        let bookUrl = book.bookUrl
        let fileURL = URL(fileURLWithPath: bookUrl)
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        let tocRule = makeLocalTxtTocRule(from: bookSource)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            var localChapters: [BookChapter] = []
            var parsedLocalFileContent = ""
            var parsedLocalEpubChapterPaths: [Int: String] = [:]
            var initialContents: [Int: String] = [:]
            var detectedCharset = ""
            var parsedBookTitle: String?

            if fileExtension == "epub" {
                do {
                    let parsedBook = try EpubLocalParser.shared.parseBookIndex(fileURL: fileURL)
                    localChapters = parsedBook.chapters.enumerated().map { index, chapter in
                        var item = BookChapter()
                        item.title = chapter.title
                        item.url = chapter.path
                        item.bookUrl = bookUrl
                        item.index = index
                        return item
                    }
                    parsedLocalEpubChapterPaths = Dictionary(
                        uniqueKeysWithValues: parsedBook.chapters.enumerated().map { ($0.offset, $0.element.path) }
                    )
                    if let title = parsedBook.title, !title.isEmpty {
                        parsedBookTitle = title
                    }
                } catch {
                    initialContents[0] = "EPUB 解析失败：\(error.localizedDescription)"
                }
            } else {
                let loadedText = loadLocalText(from: fileURL)
                parsedLocalFileContent = loadedText.content
                detectedCharset = loadedText.charsetName
                localChapters = txtTocParser.parseToc(content: parsedLocalFileContent, rule: tocRule)
            }

            if localChapters.isEmpty {
                var chapter = BookChapter()
                chapter.title = fileName
                chapter.url = bookUrl
                chapter.bookUrl = bookUrl
                chapter.index = 0
                localChapters.append(chapter)
                if initialContents[0] == nil, !parsedLocalFileContent.isEmpty {
                    initialContents[0] = parsedLocalFileContent
                }
            } else {
                for index in localChapters.indices {
                    if localChapters[index].url.isEmpty || localChapters[index].url == bookUrl {
                        localChapters[index].url = "\(bookUrl)#\(index)"
                    }
                    localChapters[index].bookUrl = bookUrl
                    localChapters[index].index = index
                }
            }
            
            let loadedLocalFileContent = parsedLocalFileContent
            let loadedLocalEpubChapterPaths = parsedLocalEpubChapterPaths
            let loadedInitialContents = initialContents
            let loadedDetectedCharset = detectedCharset
            let loadedParsedBookTitle = parsedBookTitle
            let loadedLocalChapters = localChapters

            await MainActor.run {
                guard self.currentLoadTaskId == taskId,
                      self.book?.bookUrl == bookUrl else {
                    return
                }

                self.localFileURL = fileURL
                self.localFileExtension = fileExtension
                self.localFileContent = loadedLocalFileContent
                self.localEpubChapterPaths = loadedLocalEpubChapterPaths
                self.localChapterContents.removeAll()
                self.localChapterCacheOrder.removeAll()
                for (index, content) in loadedInitialContents {
                    self.cacheLocalChapterContent(index: index, content: content)
                }

                if !loadedDetectedCharset.isEmpty {
                    self.book?.charset = loadedDetectedCharset
                }
                if let loadedParsedBookTitle,
                   self.book?.name.isEmpty == true {
                    self.book?.name = loadedParsedBookTitle
                }

                self.chapters = loadedLocalChapters
                if self.currentChapterIndex >= loadedLocalChapters.count {
                    self.currentChapterIndex = 0
                }

                guard self.currentLoadTaskId > 0 else { return }
                self.postChaptersLoaded(bookUrl: self.book?.bookUrl)
            }
        }
    }

    private func makeLocalTxtTocRule(from source: BookSource?) -> TxtTocRule? {
        guard let toc = source?.ruleToc else { return nil }
        let rule = TxtTocRule(
            bookName: nil,
            chapterList: toc.chapterList,
            chapterName: toc.chapterName,
            chapterUrl: toc.chapterUrl,
            isVolume: toc.isVolume,
            volumeName: toc.volumeName,
            chapterSize: toc.chapterSize,
            nextTocUrl: toc.nextTocUrl
        )
        let hasValue = [
            rule.chapterList,
            rule.chapterName,
            rule.chapterUrl,
            rule.isVolume,
            rule.volumeName,
            rule.chapterSize,
            rule.nextTocUrl
        ]
        .contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasValue ? rule : nil
    }

    private func loadRemoteChapters() {
        guard let book = book else { return }

        if BookParseManager.shared.isServerMode {
            loadServerChapters()
            return
        }

        if bookSource == nil {
            bookSource = resolveLocalBookSource(for: book)
        }

        guard bookSource != nil else {
            notifyChaptersLoadFailed("未找到匹配书源，请先检查本地书源配置")
            return
        }
        if let source = bookSource {
            if self.book?.origin.isEmpty == true {
                self.book?.origin = source.bookSourceUrl
            }
            if self.book?.originName.isEmpty == true {
                self.book?.originName = source.bookSourceName
            }
        }
        
        let taskId = currentLoadTaskId

        let allowCache = shouldUseChapterCache(for: book)
        if !allowCache {
            log("[ReadBookEngine] skip chapter cache for ambiguous bookUrl: \(book.bookUrl)")
        }
        chapters = allowCache ? database.getChapters(forBookUrl: book.bookUrl) : []

        if chapters.isEmpty {
            Task {
                do {
                    guard let source = bookSource else { return }
                    let chapterResponses = try await ReaderServerAPI.shared.getChapterList(
                        bookUrl: book.bookUrl,
                        sourceUrl: source.bookSourceUrl,
                        bookNameHint: book.name,
                        authorHint: book.author
                    )
                    chapters = chapterResponses.map { item in
                        BookChapter(
                            url: item.url,
                            title: item.title,
                            isVolume: false,
                            baseUrl: "",
                            bookUrl: book.bookUrl,
                            index: item.index,
                            isVip: item.isVip,
                            isPay: item.isPay
                        )
                    }
                    
                    if chapters.isEmpty {
                        await MainActor.run {
                            self.notifyChaptersLoadFailed("目录为空，可能是书源规则失效或需先刷新书籍信息")
                        }
                        return
                    }
                    
                    guard currentLoadTaskId == taskId else { return }
                    
                    await MainActor.run {
                        guard currentLoadTaskId == taskId else { return }
                        self.postChaptersLoaded(bookUrl: book.bookUrl)
                    }
                } catch {
                    log("Load chapters error: \(error)")
                    await MainActor.run {
                        self.notifyChaptersLoadFailed("加载目录失败: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            guard currentLoadTaskId == taskId else { return }
            postChaptersLoaded(bookUrl: book.bookUrl)
        }
    }

    private func shouldUseBookURLAsChapterCacheKey(_ rawBookURL: String) -> Bool {
        let trimmed = rawBookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = (trimmed.removingPercentEncoding ?? trimmed).lowercased()
        let listTokens = [
            "/rank/list", "/api/rank/", "groupid=", "categoryid=", "sub=",
            "start=", "count=", "limit=", "offset=", "page="
        ]
        if listTokens.contains(where: { lowered.contains($0) }) {
            return false
        }
        let invalidIdPattern = #"[?&](?:bookid|book_id|bid|novelid|resourceid)=(?:$|&|#|nan|null|undefined|nil|none|n/a|na)"#
        if lowered.range(of: invalidIdPattern, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    private func shouldUseChapterCache(for book: Book) -> Bool {
        guard shouldUseBookURLAsChapterCacheKey(book.bookUrl) else { return false }

        let hintName = normalizedIdentity(book.name)
        let hintAuthor = normalizedIdentity(book.author)
        let hasHint = !hintName.isEmpty || !hintAuthor.isEmpty

        guard let saved = database.getBook(byBookUrl: book.bookUrl) else {
            // 搜索/发现页临时书籍（未入架）不信任章节缓存，避免同源串目录。
            return !hasHint
        }

        let savedName = normalizedIdentity(saved.name)
        if !hintName.isEmpty, !savedName.isEmpty, hintName != savedName {
            return false
        }

        let savedAuthor = normalizedIdentity(saved.author)
        if !hintAuthor.isEmpty, !savedAuthor.isEmpty, hintAuthor != savedAuthor {
            return false
        }

        return true
    }

    private func normalizedIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    private func loadServerChapters() {
        guard let book = book else { return }
        guard let sourceUrl = ensureServerSourceURL(for: book) else {
            notifyChaptersLoadFailed("未找到匹配书源，无法加载目录")
            return
        }
        
        log("Loading server chapters for book: \(book.name), sourceUrl: \(sourceUrl)")
        
        let taskId = currentLoadTaskId
        let currentSourceUrl = sourceUrl
        let currentBookUrl = book.bookUrl
        
        Task {
            do {
                let serverChapters = try await ReaderServerAPI.shared.getChapterList(
                    bookUrl: currentBookUrl,
                    sourceUrl: currentSourceUrl,
                    bookNameHint: book.name,
                    authorHint: book.author
                )
                
                // 检查是否被新的加载任务取代
                guard currentLoadTaskId == taskId else {
                    log("Chapter loading cancelled, taskId mismatch")
                    return
                }
                
                log("Loaded \(serverChapters.count) chapters from server")
                
                if !serverChapters.isEmpty {
                    chapters = serverChapters.map { serverChapter in
                        var chapter = BookChapter()
                        chapter.title = serverChapter.title
                        chapter.url = serverChapter.url
                        chapter.bookUrl = currentBookUrl
                        chapter.index = serverChapter.index
                        return chapter
                    }
                }
                
                await MainActor.run {
                    // 再次检查是否被取代
                    guard currentLoadTaskId == taskId else {
                        log("Chapter loading cancelled after API, taskId mismatch")
                        return
                    }
                    
                    if self.chapters.isEmpty {
                        log("Warning: No chapters loaded from any source")
                        self.notifyChaptersLoadFailed("未找到书源，请先加入书架")
                    } else {
                        if self.currentChapterIndex >= self.chapters.count {
                            self.currentChapterIndex = 0
                        }
                        self.postChaptersLoaded(bookUrl: currentBookUrl)
                    }
                }
            } catch {
                // 检查是否被取消
                guard currentLoadTaskId == taskId else {
                    log("Chapter loading cancelled due to error, taskId mismatch")
                    return
                }
                
                log("Load server chapters error: \(error)")
                await MainActor.run {
                    self.notifyChaptersLoadFailed("加载章节失败: \(error.localizedDescription)")
                }
            }
        }
    }

    func goToChapter(_ index: Int) {
        guard index >= 0 && index < chapters.count else { return }

        currentChapterIndex = index
        let chapter = chapters[index]

        onChapterChanged?(index, chapter.title)

        if book?.origin == Book.localTag {
            loadLocalContent(chapter: chapter)
        } else if let cached = cachedRemoteChapterContent(index: chapter.index) {
            let cleaned = cleanedChapterContent(cached)
            currentContent = cleaned
            cacheRemoteChapterContent(index: chapter.index, content: cleaned)
            onContentLoaded?(cleaned)
        } else {
            currentRemoteContentTaskId += 1
            let taskId = currentRemoteContentTaskId
            loadRemoteContent(chapter: chapter, taskId: taskId)
        }

        saveProgress()
    }
    
    func loadContentDirectly(index: Int) {
        currentChapterIndex = index

        if let cached = cachedRemoteChapterContent(index: index) {
            let cleaned = cleanedChapterContent(cached)
            let chapterTitle = chapters[safe: index]?.title ?? cleaned.title
            onChapterChanged?(index, chapterTitle)
            currentContent = cleaned
            cacheRemoteChapterContent(index: index, content: cleaned)
            onContentLoaded?(cleaned)
            return
        }
        
        if BookParseManager.shared.isServerMode {
            currentRemoteContentTaskId += 1
            let taskId = currentRemoteContentTaskId
            loadServerContentDirectly(index: index, taskId: taskId)
        }
    }
    
    private func loadServerContentDirectly(index: Int, taskId: Int64) {
        guard let book = book else { return }
        guard let sourceUrl = ensureServerSourceURL(for: book) else {
            onLoadFailed?("加载正文失败: 未找到匹配书源")
            return
        }
        
        Task {
            do {
                let chapterContent = try await ReaderServerAPI.shared.getChapterContent(
                    bookUrl: book.bookUrl,
                    sourceUrl: sourceUrl,
                    chapterUrl: "",
                    index: index
                )
                let chapter = chapters[safe: index]
                let resolved = normalizedChapterContent(chapterContent, chapter: chapter)
                
                await MainActor.run {
                    guard self.currentRemoteContentTaskId == taskId,
                          self.currentChapterIndex == index else { return }
                    self.onChapterChanged?(index, resolved.title)
                    self.cacheRemoteChapterContent(index: index, content: resolved)
                    self.currentContent = resolved
                    self.onContentLoaded?(resolved)
                }
            } catch {
                log("Load content error: \(error)")
                await MainActor.run {
                    guard self.currentRemoteContentTaskId == taskId else { return }
                    self.onLoadFailed?("加载正文失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func loadLocalContent(chapter: BookChapter) {
        guard book != nil else { return }

        if let cached = cachedLocalChapterContent(index: chapter.index) {
            publishLocalContent(chapter: chapter, content: cached)
            return
        }

        if localFileExtension == "epub",
           let fileURL = localFileURL,
           let chapterPath = localEpubChapterPaths[chapter.index] {
            currentLocalContentTaskId += 1
            let contentTaskId = currentLocalContentTaskId
            let bookUrl = chapter.bookUrl

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let content = (try? EpubLocalParser.shared.readChapterContent(fileURL: fileURL, chapterPath: chapterPath)) ?? ""
                await MainActor.run {
                    guard self.currentLocalContentTaskId == contentTaskId,
                          self.book?.bookUrl == bookUrl else {
                        return
                    }
                    self.cacheLocalChapterContent(index: chapter.index, content: content)
                    self.publishLocalContent(chapter: chapter, content: content)
                }
            }
            return
        }

        var content = localFileContent
        if chapter.start != nil || chapter.end != nil {
            content = txtTocParser.getChapterContent(chapter: chapter, fullContent: localFileContent)
        }
        cacheLocalChapterContent(index: chapter.index, content: content)
        publishLocalContent(chapter: chapter, content: content)
    }

    private func loadRemoteContent(chapter: BookChapter, taskId: Int64) {
        if BookParseManager.shared.isServerMode {
            loadServerContent(chapter: chapter, taskId: taskId)
            return
        }
        
        if bookSource == nil {
            if let currentBook = book {
                bookSource = resolveLocalBookSource(for: currentBook)
            }
        }

        if bookSource == nil {
            Task {
                do {
                    let alternatives = try await ReaderServerAPI.shared.findAlternativeSources(
                        bookName: book?.name ?? "",
                        author: book?.author ?? ""
                    )
                    
                    if let firstSource = alternatives.first,
                       let sourceUrl = firstSource.sourceUrl,
                       let resolvedSource = self.database.getAllBookSources().first(where: { $0.bookSourceUrl == sourceUrl }) {
                        await MainActor.run {
                            guard self.currentRemoteContentTaskId == taskId,
                                  self.currentChapterIndex == chapter.index else { return }
                            self.book?.origin = sourceUrl
                            self.book?.bookUrl = firstSource.bookUrl
                            self.bookSource = resolvedSource
                            self.loadRemoteContent(chapter: chapter, taskId: taskId)
                        }
                    }
                } catch {
                    log("Search source error: \(error)")
                    await MainActor.run {
                        guard self.currentRemoteContentTaskId == taskId else { return }
                        self.onLoadFailed?("加载正文失败: 未找到可用书源")
                    }
                }
            }
            return
        }
        
        guard bookSource != nil else { return }

        Task {
            do {
                guard let currentBook = self.book,
                      let source = self.bookSource else { return }
                let content = try await ReaderServerAPI.shared.getChapterContent(
                    bookUrl: currentBook.bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    chapterUrl: chapter.url,
                    index: chapter.index
                )
                let resolved = normalizedChapterContent(content, chapter: chapter)
                await MainActor.run {
                    guard self.currentRemoteContentTaskId == taskId,
                          self.currentChapterIndex == chapter.index else { return }
                    self.cacheRemoteChapterContent(index: chapter.index, content: resolved)
                    self.currentContent = resolved
                    self.onContentLoaded?(resolved)
                }
            } catch {
                log("Load content error: \(error)")
                await MainActor.run {
                    guard self.currentRemoteContentTaskId == taskId else { return }
                    self.onLoadFailed?("加载正文失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func loadServerContent(chapter: BookChapter, taskId: Int64) {
        guard let book = book else { return }
        guard let sourceUrl = ensureServerSourceURL(for: book) else {
            onLoadFailed?("加载正文失败: 未找到匹配书源")
            return
        }
        
        Task {
            do {
                var chapterContent = try await ReaderServerAPI.shared.getChapterContent(
                    bookUrl: book.bookUrl,
                    sourceUrl: sourceUrl,
                    chapterUrl: "",
                    index: chapter.index
                )

                let isEmptyPayload = chapterContent.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (chapterContent.imageUrls?.isEmpty ?? true)
                if isEmptyPayload && chapter.index != self.currentChapterIndex {
                    chapterContent = try await ReaderServerAPI.shared.getChapterContent(
                        bookUrl: book.bookUrl,
                        sourceUrl: sourceUrl,
                        chapterUrl: "",
                        index: self.currentChapterIndex
                    )
                }
                let resolved = self.normalizedChapterContent(chapterContent, chapter: chapter)
                
                await MainActor.run {
                    guard self.currentRemoteContentTaskId == taskId,
                          self.currentChapterIndex == chapter.index else { return }
                    self.cacheRemoteChapterContent(index: chapter.index, content: resolved)
                    self.currentContent = resolved
                    self.onContentLoaded?(resolved)
                }
            } catch {
                log("Load server content error: \(error)")
                await MainActor.run {
                    guard self.currentRemoteContentTaskId == taskId else { return }
                    self.onLoadFailed?("加载正文失败: \(error.localizedDescription)")
                }
            }
        }
    }

    func nextChapter() {
        let nextIndex = currentChapterIndex + 1
        if nextIndex < chapters.count {
            goToChapter(nextIndex)
        }
    }

    func prevChapter() {
        let prevIndex = currentChapterIndex - 1
        if prevIndex >= 0 {
            goToChapter(prevIndex)
        }
    }

    func preloadChapter(index: Int) {
        guard index >= 0 && index < chapters.count else { return }
        guard book?.origin != Book.localTag else { return }
        if cachedRemoteChapterContent(index: index) != nil { return }
        if remoteChapterPreloadTasks[index] != nil { return }
        guard let chapter = chapters[safe: index] else { return }
        guard let currentBook = book else { return }
        let serverSourceUrl: String?
        if BookParseManager.shared.isServerMode {
            guard let resolved = ensureServerSourceURL(for: currentBook) else { return }
            serverSourceUrl = resolved
        } else {
            serverSourceUrl = nil
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let content: ChapterContent
                if BookParseManager.shared.isServerMode {
                    guard let sourceUrl = serverSourceUrl else {
                        await MainActor.run {
                            self.remoteChapterPreloadTasks[index] = nil
                        }
                        return
                    }
                    content = try await ReaderServerAPI.shared.getChapterContent(
                        bookUrl: currentBook.bookUrl,
                        sourceUrl: sourceUrl,
                        chapterUrl: "",
                        index: chapter.index
                    )
                } else {
                    guard let source = self.bookSource ?? self.resolveLocalBookSource(for: currentBook) else {
                        await MainActor.run {
                            self.remoteChapterPreloadTasks[index] = nil
                        }
                        return
                    }
                    content = try await ReaderServerAPI.shared.getChapterContent(
                        bookUrl: currentBook.bookUrl,
                        sourceUrl: source.bookSourceUrl,
                        chapterUrl: chapter.url,
                        index: chapter.index
                    )
                }

                let resolved = self.normalizedChapterContent(content, chapter: chapter)
                if !self.isChapterContentUsable(resolved) {
                    await MainActor.run {
                        self.remoteChapterPreloadTasks[index] = nil
                    }
                    return
                }

                await MainActor.run {
                    self.cacheRemoteChapterContent(index: index, content: resolved)
                    self.remoteChapterPreloadTasks[index] = nil
                }
            } catch {
                await MainActor.run {
                    self.remoteChapterPreloadTasks[index] = nil
                }
            }
        }

        remoteChapterPreloadTasks[index] = task
    }

    func hasCachedChapterContent(index: Int) -> Bool {
        guard index >= 0 else { return false }
        if book?.origin == Book.localTag {
            return localChapterContents[index] != nil
        }
        return remoteChapterContents[index] != nil
    }

    func saveProgress() {
        guard var book = book else { return }

        book.durChapterIndex = currentChapterIndex
        book.durChapterTime = Int64(Date().timeIntervalSince1970 * 1000)
        book.totalChapterNum = chapters.count

        if let chapter = chapters[safe: currentChapterIndex] {
            book.latestChapterTitle = chapter.title
        }

        self.book = book

        // 避免“阅读即自动入架”：仅当书籍本来就在书架中时才落库保存进度。
        let shouldPersistToShelf: Bool = {
            if book.origin == Book.localTag { return true }
            return database.hasBook(byBookUrl: book.bookUrl)
        }()

        if shouldPersistToShelf {
            database.saveBook(book)
        }
        
        if shouldPersistToShelf && BookParseManager.shared.isServerMode && book.origin != Book.localTag {
            guard let sourceUrl = ensureServerSourceURL(for: book) else { return }
            Task {
                do {
                    try await ReaderServerAPI.shared.saveBookProgress(
                        bookUrl: book.bookUrl,
                        sourceUrl: sourceUrl,
                        chapterIndex: currentChapterIndex,
                        chapterPos: book.durChapterPos
                    )
                } catch {
                    log("Save progress to server failed: \(error)")
                }
            }
        }
    }

    func updateReadConfig(_ config: ReadConfig) {
        book?.readConfig = config
        saveProgress()
        
        // 保存到本地
        saveConfigToLocal(config)
        
        // 保存到服务器
        guard let bookUrl = book?.bookUrl else { return }
        
        if ReaderServerAPI.shared.isLoggedIn {
            Task {
                do {
                    let configDict: [String: Any] = [
                        "textSize": config.textSize,
                        "bgColor": config.bgColor,
                        "textColor": config.textColor,
                        "lineSpacing": config.lineSpacing,
                        "paragraphSpacing": config.paragraphSpacing,
                        "charSpacing": config.charSpacing,
                        "bold": config.bold,
                        "fontFamily": config.fontFamily,
                        "pageMode": config.pageMode,
                        "keepScreenOn": config.keepScreenOn,
                        "readTheme": config.readTheme
                    ]
                    try await ReaderServerAPI.shared.saveBookConfig(bookUrl: bookUrl, config: configDict)
                } catch {
                    log("Save book config to server failed: \(error)")
                }
            }
        }
    }
    
    private func saveConfigToLocal(_ config: ReadConfig) {
        log("saveConfigToLocal: bgColor: \(config.bgColor)")
        if let data = try? JSONEncoder().encode(config) {
            log("saveConfigToLocal: encoded, size: \(data.count)")
            UserDefaults.standard.set(data, forKey: "globalReadConfig")
            UserDefaults.standard.synchronize()
            log("saveConfigToLocal: saved")
        }
    }
    
    private func loadConfigFromLocal() -> ReadConfig? {
        log("loadConfigFromLocal: checking UserDefaults...")
        if let data = UserDefaults.standard.data(forKey: "globalReadConfig") {
            log("loadConfigFromLocal: data found, size: \(data.count)")
            if let config = try? JSONDecoder().decode(ReadConfig.self, from: data) {
                log("loadConfigFromLocal: config decoded, bgColor: \(config.bgColor)")
                return config
            } else {
                log("loadConfigFromLocal: failed to decode")
            }
        } else {
            log("loadConfigFromLocal: no data found")
        }
        return nil
    }
    
    private func startProgressSaveTimer() {
        stopProgressSaveTimer()
        progressSaveTimer = Timer.scheduledTimer(withTimeInterval: progressSaveInterval, repeats: true) { [weak self] _ in
            self?.saveProgress()
        }
    }
    
    private func stopProgressSaveTimer() {
        progressSaveTimer?.invalidate()
        progressSaveTimer = nil
    }

    private func loadLocalText(from url: URL) -> (content: String, charsetName: String) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return ("", "")
        }

        let candidates: [(name: String, encoding: String.Encoding)] = [
            ("utf-8", .utf8),
            ("utf-16", .unicode),
            ("utf-16le", .utf16LittleEndian),
            ("utf-16be", .utf16BigEndian),
            ("gb18030", String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )),
            ("big5", String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5.rawValue)
                )
            ))
        ]

        var bestResult: (name: String, content: String, score: Int)?

        for candidate in candidates {
            guard let text = String(data: data, encoding: candidate.encoding) else { continue }
            let cleaned = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            let score = localTextQualityScore(cleaned)
            if bestResult == nil || score > bestResult!.score {
                bestResult = (candidate.name, cleaned, score)
            }
        }

        if let result = bestResult {
            return (result.content, result.name)
        }
        return ("", "")
    }

    private func localTextQualityScore(_ text: String) -> Int {
        if text.isEmpty { return Int.min }

        var score = text.count
        let replacementCount = text.filter { $0 == "\u{FFFD}" }.count
        score -= replacementCount * 200

        var controlCount = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar),
               scalar != "\n" && scalar != "\r" && scalar != "\t" {
                controlCount += 1
            }
        }
        score -= controlCount * 30

        return score
    }

    private func publishLocalContent(chapter: BookChapter, content: String) {
        let cleanedContent = ContentCleaner.shared.clean(content: content, scope: 2)
        var chapterContent = ChapterContent(content: cleanedContent)
        chapterContent.url = chapter.url
        chapterContent.title = chapter.title
        currentContent = chapterContent
        onContentLoaded?(chapterContent)
    }

    private func cachedLocalChapterContent(index: Int) -> String? {
        guard let content = localChapterContents[index] else { return nil }
        if let orderIndex = localChapterCacheOrder.firstIndex(of: index) {
            localChapterCacheOrder.remove(at: orderIndex)
        }
        localChapterCacheOrder.append(index)
        return content
    }

    private func cacheLocalChapterContent(index: Int, content: String) {
        localChapterContents[index] = content
        if let orderIndex = localChapterCacheOrder.firstIndex(of: index) {
            localChapterCacheOrder.remove(at: orderIndex)
        }
        localChapterCacheOrder.append(index)

        while localChapterCacheOrder.count > localChapterCacheLimit {
            let removed = localChapterCacheOrder.removeFirst()
            localChapterContents.removeValue(forKey: removed)
        }
    }

    private func cachedRemoteChapterContent(index: Int) -> ChapterContent? {
        guard let content = remoteChapterContents[index] else { return nil }
        if let orderIndex = remoteChapterCacheOrder.firstIndex(of: index) {
            remoteChapterCacheOrder.remove(at: orderIndex)
        }
        remoteChapterCacheOrder.append(index)
        return content
    }

    private func cacheRemoteChapterContent(index: Int, content: ChapterContent) {
        remoteChapterContents[index] = content
        if let orderIndex = remoteChapterCacheOrder.firstIndex(of: index) {
            remoteChapterCacheOrder.remove(at: orderIndex)
        }
        remoteChapterCacheOrder.append(index)

        while remoteChapterCacheOrder.count > remoteChapterCacheLimit {
            let removed = remoteChapterCacheOrder.removeFirst()
            remoteChapterContents.removeValue(forKey: removed)
        }
    }

    private func cancelRemotePreloadTasks() {
        for task in remoteChapterPreloadTasks.values {
            task.cancel()
        }
        remoteChapterPreloadTasks.removeAll()
    }

    private func normalizedChapterContent(_ content: ChapterContent, chapter: BookChapter?) -> ChapterContent {
        var resolved = cleanedChapterContent(content)
        if resolved.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.title = chapter?.title ?? resolved.title
        }
        if resolved.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.url = chapter?.url ?? resolved.url
        }
        return resolved
    }
    
    private func cleanedChapterContent(_ content: ChapterContent) -> ChapterContent {
        var resolved = content
        if !resolved.content.isEmpty {
            resolved.content = ContentCleaner.shared.clean(content: resolved.content, scope: 2)
        }
        return resolved
    }

    private func isChapterContentUsable(_ content: ChapterContent) -> Bool {
        let hasText = !content.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !(content.imageUrls?.isEmpty ?? true)
        return hasText || hasImages
    }

    func close() {
        stopProgressSaveTimer()
        saveProgress()
        book = nil
        chapters = []
        currentContent = nil
        bookSource = nil
        currentChapterIndex = 0
        localFileContent = ""
        localChapterContents.removeAll()
        localChapterCacheOrder.removeAll()
        localEpubChapterPaths.removeAll()
        cancelRemotePreloadTasks()
        remoteChapterContents.removeAll()
        remoteChapterCacheOrder.removeAll()
        localFileURL = nil
        localFileExtension = ""
        currentLocalContentTaskId = 0
        currentRemoteContentTaskId = 0
    }

    private func notifyChaptersLoadFailed(_ message: String) {
        onLoadFailed?(message)
        NotificationCenter.default.post(name: NSNotification.Name("ChaptersLoadFailed"), object: message)
    }

    private func postChaptersLoaded(bookUrl: String?) {
        let normalized = (bookUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        NotificationCenter.default.post(
            name: NSNotification.Name("ChaptersLoaded"),
            object: nil,
            userInfo: normalized.isEmpty ? nil : ["bookUrl": normalized]
        )
    }

    private func ensureServerSourceURL(for book: Book) -> String? {
        let currentOrigin = book.origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentOrigin.isEmpty, currentOrigin != Book.localTag {
            return currentOrigin
        }

        if let source = bookSource {
            let sourceUrl = source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceUrl.isEmpty {
                var updatedBook = book
                updatedBook.origin = sourceUrl
                if updatedBook.originName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updatedBook.originName = source.bookSourceName
                }
                self.book = updatedBook
                return sourceUrl
            }
        }

        if let matched = resolveLocalBookSource(for: book) {
            let sourceUrl = matched.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceUrl.isEmpty {
                var updatedBook = book
                updatedBook.origin = sourceUrl
                if updatedBook.originName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updatedBook.originName = matched.bookSourceName
                }
                self.book = updatedBook
                self.bookSource = matched
                return sourceUrl
            }
        }

        if let savedBook = database.getBook(byBookUrl: book.bookUrl) {
            let savedOrigin = savedBook.origin.trimmingCharacters(in: .whitespacesAndNewlines)
            if !savedOrigin.isEmpty, savedOrigin != Book.localTag {
                var updatedBook = book
                updatedBook.origin = savedOrigin
                if updatedBook.originName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updatedBook.originName = savedBook.originName
                }
                self.book = updatedBook
                return savedOrigin
            }
        }

        return nil
    }

    private func resolveLocalBookSource(for book: Book) -> BookSource? {
        let allSources = database.getAllBookSources()
        if allSources.isEmpty { return nil }

        let enabledSources = allSources.filter { $0.enabled }
        let candidateSources = enabledSources.isEmpty ? allSources : enabledSources

        let origin = normalizeURLString(book.origin)
        if !origin.isEmpty,
           let matched = candidateSources.first(where: { normalizeURLString($0.bookSourceUrl) == origin }) {
            return matched
        }

        if let savedBook = database.getBook(byBookUrl: book.bookUrl) {
            let savedOrigin = normalizeURLString(savedBook.origin)
            if !savedOrigin.isEmpty,
               let matched = candidateSources.first(where: { normalizeURLString($0.bookSourceUrl) == savedOrigin }) {
                return matched
            }
        }
        
        if !book.originName.isEmpty,
           let matched = candidateSources.first(where: { $0.bookSourceName == book.originName }) {
            return matched
        }

        let candidateHosts = [extractHost(from: book.origin), extractHost(from: book.bookUrl)].compactMap { $0 }
        if !candidateHosts.isEmpty {
            for host in candidateHosts {
                if let matched = candidateSources.first(where: { extractHost(from: $0.bookSourceUrl) == host }) {
                    return matched
                }
            }
        }

        return nil
    }

    private func normalizeURLString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let lowered = decoded.lowercased()
        return lowered.hasSuffix("/") ? String(lowered.dropLast()) : lowered
    }

    private func extractHost(from raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let host = URL(string: normalized)?.host?.lowercased(), !host.isEmpty {
            return host
        }

        if let host = URL(string: "https://\(normalized)")?.host?.lowercased(), !host.isEmpty {
            return host
        }

        return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

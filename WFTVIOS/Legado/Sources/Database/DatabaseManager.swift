import Foundation
import SQLite

class DatabaseManager {
    static let shared = DatabaseManager()

    private var db: Connection?
    private var didSetup = false
    private let setupLock = NSLock()
    private let dbPath: String

    // Tables
    let books = Table("books")
    let bookSources = Table("book_sources")
    let chapters = Table("chapters")
    let replaceRules = Table("replace_rules")
    let searchBooks = Table("search_books")
    let bookmarks = Table("bookmarks")

    // Book columns
    let bookUrl = Expression<String>("bookUrl")
    let tocUrl = Expression<String>("tocUrl")
    let origin = Expression<String>("origin")
    let originName = Expression<String>("originName")
    let name = Expression<String>("name")
    let author = Expression<String>("author")
    let kind = Expression<String?>("kind")
    let coverUrl = Expression<String?>("coverUrl")
    let customCoverUrl = Expression<String?>("customCoverUrl")
    let intro = Expression<String?>("intro")
    let customIntro = Expression<String?>("customIntro")
    let charset = Expression<String?>("charset")
    let type = Expression<Int>("type")
    let group = Expression<Int64>("group")
    let canUpdate = Expression<Bool>("canUpdate")
    let latestChapterTitle = Expression<String?>("latestChapterTitle")
    let totalChapterNum = Expression<Int>("totalChapterNum")
    let durChapterIndex = Expression<Int>("durChapterIndex")
    let durChapterPos = Expression<Int>("durChapterPos")
    let durChapterTime = Expression<Int64>("durChapterTime")
    let variable = Expression<String?>("variable")
    let readConfigJson = Expression<String?>("readConfig")

    // BookSource columns
    let bookSourceUrl = Expression<String>("bookSourceUrl")
    let bookSourceName = Expression<String>("bookSourceName")
    let bookSourceGroup = Expression<String?>("bookSourceGroup")
    let bookSourceType = Expression<Int>("bookSourceType")
    let bookUrlPattern = Expression<String?>("bookUrlPattern")
    let enabled = Expression<Bool>("enabled")
    let enabledExplore = Expression<Bool>("enabledExplore")
    let jsLib = Expression<String?>("jsLib")
    let enabledCookieJar = Expression<Bool?>("enabledCookieJar")
    let concurrentRate = Expression<String?>("concurrentRate")
    let header = Expression<String?>("header")
    let loginUrl = Expression<String?>("loginUrl")
    let loginUi = Expression<String?>("loginUi")
    let loginCheckJs = Expression<String?>("loginCheckJs")
    let coverDecodeJs = Expression<String?>("coverDecodeJs")
    let exploreUrl = Expression<String?>("exploreUrl")
    let searchUrl = Expression<String?>("searchUrl")
    let ruleSearchJson = Expression<String?>("ruleSearch")
    let ruleExploreJson = Expression<String?>("ruleExplore")
    let ruleBookInfoJson = Expression<String?>("ruleBookInfo")
    let ruleTocJson = Expression<String?>("ruleToc")
    let ruleContentJson = Expression<String?>("ruleContent")

    // Chapter columns
    let url = Expression<String>("url")
    let title = Expression<String>("title")
    let isVolume = Expression<Bool>("isVolume")
    let baseUrl = Expression<String>("baseUrl")
    let index = Expression<Int>("index")
    let isVip = Expression<Bool>("isVip")
    let isPay = Expression<Bool>("isPay")
    let resourceUrl = Expression<String?>("resourceUrl")
    let tag = Expression<String?>("tag")
    let wordCount = Expression<String?>("wordCount")
    let start = Expression<Int64?>("start")
    let end = Expression<Int64?>("end")

    // ReplaceRule columns
    let ruleId = Expression<String>("ruleId")
    let pattern = Expression<String>("pattern")
    let replacement = Expression<String>("replacement")
    let isEnabled = Expression<Bool>("isEnabled")
    let scope = Expression<Int>("scope")
    let groupName = Expression<String?>("groupName")

    private init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        dbPath = documentsPath.appendingPathComponent("legado.db").path
    }

    func setup() {
        setupLock.lock()
        defer { setupLock.unlock() }
        guard !didSetup else { return }

        do {
            db = try Connection(dbPath)
            createTables()
            migrateDatabase()
            didSetup = true
        } catch {
            print("Database setup error: \(error)")
        }
    }

    func prepareInBackground() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    private func readyDatabase() -> Connection? {
        if !didSetup {
            setup()
        }
        return db
    }

    private func migrateDatabase() {
        guard let db = db else { return }
        do {
            try migrateBooksCanUpdateColumnIfNeeded(on: db)
            try migrateChapterPrimaryKeyIfNeeded(on: db)
        } catch {
            print("Database migration error: \(error)")
        }
    }

    private func migrateBooksCanUpdateColumnIfNeeded(on db: Connection) throws {
        let columns = try db.prepare("PRAGMA table_info(books)")
        var hasCanUpdate = false
        for row in columns {
            if let name = row[1] as? String, name == "canUpdate" {
                hasCanUpdate = true
                break
            }
        }

        if !hasCanUpdate {
            try db.execute("ALTER TABLE books ADD COLUMN canUpdate BOOLEAN DEFAULT 1")
            print("Added canUpdate column to books table")
        }
    }

    private func migrateChapterPrimaryKeyIfNeeded(on db: Connection) throws {
        let columns = try db.prepare("PRAGMA table_info(chapters)")
        var pkColumns: [(name: String, order: Int)] = []
        for row in columns {
            guard let name = row[1] as? String else { continue }
            let order = intValue(from: row[5])
            if order > 0 {
                pkColumns.append((name: name, order: order))
            }
        }

        let sortedPK = pkColumns.sorted { $0.order < $1.order }.map(\.name)
        if sortedPK == ["bookUrl", "url"] {
            try db.execute("CREATE INDEX IF NOT EXISTS idx_chapters_bookUrl_index ON chapters(bookUrl, \"index\")")
            return
        }

        // Legacy schema: PRIMARY KEY(url)
        if sortedPK == ["url"] {
            try db.transaction {
                try db.execute("ALTER TABLE chapters RENAME TO chapters_legacy")
                try db.execute("""
                CREATE TABLE chapters (
                    url TEXT NOT NULL,
                    title TEXT NOT NULL,
                    isVolume INTEGER NOT NULL,
                    baseUrl TEXT NOT NULL,
                    bookUrl TEXT NOT NULL,
                    "index" INTEGER NOT NULL,
                    isVip INTEGER NOT NULL,
                    isPay INTEGER NOT NULL,
                    resourceUrl TEXT,
                    tag TEXT,
                    wordCount TEXT,
                    "start" INTEGER,
                    "end" INTEGER,
                    PRIMARY KEY (bookUrl, url)
                )
                """)
                try db.execute("""
                INSERT OR REPLACE INTO chapters
                (url, title, isVolume, baseUrl, bookUrl, "index", isVip, isPay, resourceUrl, tag, wordCount, "start", "end")
                SELECT url, title, isVolume, baseUrl, bookUrl, "index", isVip, isPay, resourceUrl, tag, wordCount, "start", "end"
                FROM chapters_legacy
                WHERE TRIM(IFNULL(bookUrl, '')) <> ''
                """)
                try db.execute("DROP TABLE chapters_legacy")
                try db.execute("CREATE INDEX IF NOT EXISTS idx_chapters_bookUrl_index ON chapters(bookUrl, \"index\")")
            }
            print("Migrated chapters primary key to (bookUrl, url)")
            return
        }

        if !sortedPK.isEmpty {
            print("Skip chapter primary key migration, detected PK: \(sortedPK)")
        }
        try db.execute("CREATE INDEX IF NOT EXISTS idx_chapters_bookUrl_index ON chapters(bookUrl, \"index\")")
    }

    private func intValue(from value: Binding?) -> Int {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Int64 {
            return Int(value)
        }
        if let value = value as? Double {
            return Int(value)
        }
        return 0
    }

    private func createTables() {
        guard let db = db else { return }

        do {
            try db.run(books.create(ifNotExists: true) { t in
                t.column(bookUrl, primaryKey: true)
                t.column(tocUrl)
                t.column(origin)
                t.column(originName)
                t.column(name)
                t.column(author)
                t.column(kind)
                t.column(coverUrl)
                t.column(customCoverUrl)
                t.column(intro)
                t.column(customIntro)
                t.column(charset)
                t.column(type)
                t.column(group)
                t.column(canUpdate)
                t.column(latestChapterTitle)
                t.column(totalChapterNum)
                t.column(durChapterIndex)
                t.column(durChapterPos)
                t.column(durChapterTime)
                t.column(variable)
                t.column(readConfigJson)
            })

            try db.run(bookSources.create(ifNotExists: true) { t in
                t.column(bookSourceUrl, primaryKey: true)
                t.column(bookSourceName)
                t.column(bookSourceGroup)
                t.column(bookSourceType)
                t.column(bookUrlPattern)
                t.column(enabled)
                t.column(enabledExplore)
                t.column(jsLib)
                t.column(enabledCookieJar)
                t.column(concurrentRate)
                t.column(header)
                t.column(loginUrl)
                t.column(loginUi)
                t.column(loginCheckJs)
                t.column(coverDecodeJs)
                t.column(exploreUrl)
                t.column(searchUrl)
                t.column(ruleSearchJson)
                t.column(ruleExploreJson)
                t.column(ruleBookInfoJson)
                t.column(ruleTocJson)
                t.column(ruleContentJson)
            })

            try db.execute("""
            CREATE TABLE IF NOT EXISTS chapters (
                url TEXT NOT NULL,
                title TEXT NOT NULL,
                isVolume INTEGER NOT NULL,
                baseUrl TEXT NOT NULL,
                bookUrl TEXT NOT NULL,
                "index" INTEGER NOT NULL,
                isVip INTEGER NOT NULL,
                isPay INTEGER NOT NULL,
                resourceUrl TEXT,
                tag TEXT,
                wordCount TEXT,
                "start" INTEGER,
                "end" INTEGER,
                PRIMARY KEY (bookUrl, url)
            )
            """)
            try db.execute("CREATE INDEX IF NOT EXISTS idx_chapters_bookUrl_index ON chapters(bookUrl, \"index\")")

            try db.run(replaceRules.create(ifNotExists: true) { t in
                t.column(ruleId, primaryKey: true)
                t.column(pattern)
                t.column(replacement)
                t.column(isEnabled)
                t.column(scope)
                t.column(groupName)
            })
        } catch {
            print("Create tables error: \(error)")
        }
    }

    // MARK: - Book Operations

    private func decodeBook(from row: Row) -> Book {
        var book = Book(
            bookUrl: row[bookUrl],
            tocUrl: row[tocUrl],
            origin: row[origin],
            originName: row[originName],
            name: row[name],
            author: row[author],
            kind: row[kind],
            coverUrl: row[coverUrl],
            customCoverUrl: row[customCoverUrl],
            intro: row[intro],
            customIntro: row[customIntro],
            charset: row[charset],
            type: row[type],
            group: row[group],
            canUpdate: row[canUpdate],
            latestChapterTitle: row[latestChapterTitle],
            totalChapterNum: row[totalChapterNum],
            durChapterIndex: row[durChapterIndex],
            durChapterPos: row[durChapterPos],
            durChapterTime: row[durChapterTime],
            variable: row[variable]
        )

        if let configJson = row[readConfigJson],
           let data = configJson.data(using: .utf8) {
            book.readConfig = try? JSONDecoder().decode(ReadConfig.self, from: data)
        }
        return book
    }

    private func normalizeBookURLForLookup(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        return decoded.lowercased()
    }

    func getBook(byBookUrl rawBookUrl: String) -> Book? {
        guard let db = readyDatabase() else { return nil }
        let trimmed = rawBookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            if let row = try db.pluck(books.filter(bookUrl == trimmed)) {
                return decodeBook(from: row)
            }
        } catch {
            print("Get book by URL error: \(error)")
        }

        let normalized = normalizeBookURLForLookup(trimmed)
        guard !normalized.isEmpty else { return nil }
        return getAllBooks().first {
            normalizeBookURLForLookup($0.bookUrl) == normalized
        }
    }

    func hasBook(byBookUrl rawBookUrl: String) -> Bool {
        return getBook(byBookUrl: rawBookUrl) != nil
    }

    func getAllBooks() -> [Book] {
        guard let db = readyDatabase() else { return [] }
        var result: [Book] = []

        do {
            for row in try db.prepare(books.order(durChapterTime.desc)) {
                result.append(decodeBook(from: row))
            }
        } catch {
            print("Get books error: \(error)")
        }

        return result
    }

    func getBooksCount(inGroup groupId: Int64) -> Int {
        guard let db = readyDatabase() else { return 0 }
        do {
            return try db.scalar(books.filter(group == groupId).count)
        } catch {
            return 0
        }
    }

    func getAllBooks(inGroup groupId: Int64? = nil) -> [Book] {
        guard let db = readyDatabase() else { return [] }
        var result: [Book] = []

        do {
            var query = books.order(durChapterTime.desc)
            if let gid = groupId {
                query = books.filter(group == gid).order(durChapterTime.desc)
            }
            for row in try db.prepare(query) {
                result.append(decodeBook(from: row))
            }
        } catch {
            print("Get books error: \(error)")
        }

        return result
    }

    func saveBook(_ book: Book) {
        guard let db = readyDatabase() else { return }

        do {
            var configJson: String?
            if let config = book.readConfig {
                configJson = String(data: try JSONEncoder().encode(config), encoding: .utf8)
            }

            let insert = books.upsert(
                bookUrl <- book.bookUrl,
                tocUrl <- book.tocUrl,
                origin <- book.origin,
                originName <- book.originName,
                name <- book.name,
                author <- book.author,
                kind <- book.kind,
                coverUrl <- book.coverUrl,
                customCoverUrl <- book.customCoverUrl,
                intro <- book.intro,
                customIntro <- book.customIntro,
                charset <- book.charset,
                type <- book.type,
                group <- book.group,
                canUpdate <- book.canUpdate,
                latestChapterTitle <- book.latestChapterTitle,
                totalChapterNum <- book.totalChapterNum,
                durChapterIndex <- book.durChapterIndex,
                durChapterPos <- book.durChapterPos,
                durChapterTime <- book.durChapterTime,
                variable <- book.variable,
                readConfigJson <- configJson,
                onConflictOf: bookUrl
            )
            try db.run(insert)
        } catch {
            print("Save book error: \(error)")
        }
    }

    func deleteBook(_ bookUrl: String) {
        guard let db = readyDatabase() else { return }

        do {
            let book = books.filter(self.bookUrl == bookUrl)
            try db.run(book.delete())

            let bookChapters = chapters.filter(self.bookUrl == bookUrl)
            try db.run(bookChapters.delete())
        } catch {
            print("Delete book error: \(error)")
        }
    }

    // MARK: - BookSource Operations

    func getAllBookSources() -> [BookSource] {
        guard let db = readyDatabase() else { return [] }
        var result: [BookSource] = []

        do {
            for row in try db.prepare(bookSources.order(bookSourceName)) {
                var source = BookSource(
                    bookSourceUrl: row[bookSourceUrl],
                    bookSourceName: row[bookSourceName],
                    bookSourceGroup: row[bookSourceGroup],
                    bookSourceType: row[bookSourceType],
                    bookUrlPattern: row[bookUrlPattern],
                    enabled: row[enabled],
                    enabledExplore: row[enabledExplore],
                    jsLib: row[jsLib],
                    enabledCookieJar: row[enabledCookieJar],
                    concurrentRate: row[concurrentRate],
                    header: row[header],
                    loginUrl: row[loginUrl],
                    loginUi: row[loginUi],
                    loginCheckJs: row[loginCheckJs],
                    coverDecodeJs: row[coverDecodeJs],
                    exploreUrl: row[exploreUrl],
                    searchUrl: row[searchUrl]
                )

                source.ruleSearch = decodeJson(row[ruleSearchJson])
                source.ruleExplore = decodeJson(row[ruleExploreJson])
                source.ruleBookInfo = decodeJson(row[ruleBookInfoJson])
                source.ruleToc = decodeJson(row[ruleTocJson])
                source.ruleContent = decodeJson(row[ruleContentJson])

                result.append(source)
            }
        } catch {
            print("Get book sources error: \(error)")
        }

        return result
    }

    func saveBookSource(_ source: BookSource) {
        guard let db = readyDatabase() else { return }

        do {
            let insert = bookSources.upsert(
                bookSourceUrl <- source.bookSourceUrl,
                bookSourceName <- source.bookSourceName,
                bookSourceGroup <- source.bookSourceGroup,
                bookSourceType <- source.bookSourceType,
                bookUrlPattern <- source.bookUrlPattern,
                enabled <- source.enabled,
                enabledExplore <- source.enabledExplore,
                jsLib <- source.jsLib,
                enabledCookieJar <- source.enabledCookieJar,
                concurrentRate <- source.concurrentRate,
                header <- source.header,
                loginUrl <- source.loginUrl,
                loginUi <- source.loginUi,
                loginCheckJs <- source.loginCheckJs,
                coverDecodeJs <- source.coverDecodeJs,
                exploreUrl <- source.exploreUrl,
                searchUrl <- source.searchUrl,
                ruleSearchJson <- encodeJson(source.ruleSearch),
                ruleExploreJson <- encodeJson(source.ruleExplore),
                ruleBookInfoJson <- encodeJson(source.ruleBookInfo),
                ruleTocJson <- encodeJson(source.ruleToc),
                ruleContentJson <- encodeJson(source.ruleContent),
                onConflictOf: bookSourceUrl
            )
            try db.run(insert)
        } catch {
            print("Save book source error: \(error)")
        }
    }

    func deleteBookSource(_ sourceUrl: String) {
        guard let db = readyDatabase() else { return }

        do {
            let source = bookSources.filter(bookSourceUrl == sourceUrl)
            try db.run(source.delete())
        } catch {
            print("Delete book source error: \(error)")
        }
    }

    // MARK: - Chapter Operations

    func getChapters(forBookUrl bookUrlValue: String) -> [BookChapter] {
        guard let db = readyDatabase() else { return [] }
        var result: [BookChapter] = []

        do {
            let query = chapters.filter(bookUrl == bookUrlValue).order(index)
            for row in try db.prepare(query) {
                let chapter = BookChapter(
                    url: row[url],
                    title: row[title],
                    isVolume: row[isVolume],
                    baseUrl: row[baseUrl],
                    bookUrl: row[bookUrl],
                    index: row[index],
                    isVip: row[isVip],
                    isPay: row[isPay],
                    resourceUrl: row[resourceUrl],
                    tag: row[tag],
                    wordCount: row[wordCount],
                    start: row[start],
                    end: row[end]
                )
                result.append(chapter)
            }
        } catch {
            print("Get chapters error: \(error)")
        }

        return result
    }

    func saveChapters(_ chapterList: [BookChapter]) {
        guard let db = readyDatabase() else { return }

        do {
            try db.transaction {
                let targets = Set(
                    chapterList
                        .map(\.bookUrl)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
                for target in targets {
                    try db.run(chapters.filter(bookUrl == target).delete())
                }

                for chapter in chapterList {
                    let insert = chapters.insert(
                        or: .replace,
                        url <- chapter.url,
                        title <- chapter.title,
                        isVolume <- chapter.isVolume,
                        baseUrl <- chapter.baseUrl,
                        bookUrl <- chapter.bookUrl,
                        index <- chapter.index,
                        isVip <- chapter.isVip,
                        isPay <- chapter.isPay,
                        resourceUrl <- chapter.resourceUrl,
                        tag <- chapter.tag,
                        wordCount <- chapter.wordCount,
                        start <- chapter.start,
                        end <- chapter.end
                    )
                    try db.run(insert)
                }
            }
        } catch {
            print("Save chapters error: \(error)")
        }
    }

    func deleteChapters(forBookUrl bookUrlValue: String) {
        guard let db = readyDatabase() else { return }
        do {
            try db.run(chapters.filter(bookUrl == bookUrlValue).delete())
        } catch {
            print("Delete chapters error: \(error)")
        }
    }

    // MARK: - Replace Rule Operations

    func getAllReplaceRules() -> [ReplaceRule] {
        guard let db = readyDatabase() else { return [] }
        var result: [ReplaceRule] = []

        do {
            for row in try db.prepare(replaceRules.order(groupName)) {
                let rule = ReplaceRule(
                    ruleId: row[ruleId],
                    pattern: row[pattern],
                    replacement: row[replacement],
                    isEnabled: row[isEnabled],
                    scope: row[scope],
                    groupName: row[groupName]
                )
                result.append(rule)
            }
        } catch {
            print("Get replace rules error: \(error)")
        }

        return result
    }

    func saveReplaceRule(_ rule: ReplaceRule) {
        guard let db = readyDatabase() else { return }

        do {
            let insert = replaceRules.upsert(
                ruleId <- rule.ruleId,
                pattern <- rule.pattern,
                replacement <- rule.replacement,
                isEnabled <- rule.isEnabled,
                scope <- rule.scope,
                groupName <- rule.groupName,
                onConflictOf: ruleId
            )
            try db.run(insert)
        } catch {
            print("Save replace rule error: \(error)")
        }
    }
    
    func deleteReplaceRule(_ ruleId: String) {
        guard let db = readyDatabase() else { return }
        
        do {
            let query = replaceRules.filter(self.ruleId == ruleId)
            try db.run(query.delete())
        } catch {
            print("Delete replace rule error: \(error)")
        }
    }
    
    func deleteAllReplaceRules() {
        guard let db = readyDatabase() else { return }
        
        do {
            try db.run(replaceRules.delete())
        } catch {
            print("Delete all replace rules error: \(error)")
        }
    }
    
    func clearAllHistory() {
        guard let db = readyDatabase() else { return }
        
        do {
            try db.run(books.update(
                durChapterIndex <- 0,
                durChapterPos <- 0,
                durChapterTime <- 0,
                latestChapterTitle <- ""
            ))
        } catch {
            print("Clear history error: \(error)")
        }
    }

    // MARK: - Helpers

    private func decodeJson<T: Decodable>(_ json: String?) -> T? {
        guard let json = json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encodeJson<T: Encodable>(_ value: T?) -> String? {
        guard let value = value,
              let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

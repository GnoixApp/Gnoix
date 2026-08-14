import Foundation

class LocalBookService {
    static let shared = LocalBookService()
    
    private let database = DatabaseManager.shared
    private let webBook = WebBook.shared
    
    private init() {}
    
    func getEnabledBookSources() -> [BookSource] {
        return database.getAllBookSources().filter { $0.enabled }
    }
    
    func searchBook(keyword: String) async throws -> [SearchBook] {
        var allResults: [SearchBook] = []
        let sources = getEnabledBookSources()
        
        try await withThrowingTaskGroup(of: [SearchBook].self) { group in
            for source in sources {
                group.addTask {
                    try await self.webBook.searchBook(keyword: keyword, source: source)
                }
            }
            
            for try await results in group {
                allResults.append(contentsOf: results)
            }
        }
        
        return allResults
    }
    
    func getBookInfo(bookUrl: String, source: BookSource) async throws -> Book {
        return try await webBook.getBookInfo(bookUrl: bookUrl, source: source)
    }
    
    func getChapterList(tocUrl: String, bookUrl: String, source: BookSource) async throws -> [BookChapter] {
        return try await webBook.getChapterList(tocUrl: tocUrl, bookUrl: bookUrl, source: source)
    }
    
    func addToBookshelf(book: Book, source: BookSource) {
        var bookToSave = book
        bookToSave.origin = source.bookSourceUrl
        bookToSave.originName = source.bookSourceName
        database.saveBook(bookToSave)
    }
}
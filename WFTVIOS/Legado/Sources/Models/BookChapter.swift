import Foundation

struct BookChapter: Codable, Identifiable {
    var id: String { url + title }
    var url: String = ""
    var title: String = ""
    var isVolume: Bool = false
    var baseUrl: String = ""
    var bookUrl: String = ""
    var index: Int = 0
    var isVip: Bool = false
    var isPay: Bool = false
    var resourceUrl: String?
    var tag: String?
    var wordCount: String?
    var start: Int64?
    var end: Int64?
    var variable: String?
}

struct ChapterContent: Codable {
    var url: String = ""
    var title: String = ""
    var content: String = ""
    var nextUrl: String?
    var prevUrl: String?
    var resourceUrls: [String: String]?
    var imageUrls: [String]?
    
    init(content: String = "", nextUrl: String = "") {
        self.content = content
        self.nextUrl = nextUrl.isEmpty ? nil : nextUrl
    }
    
    var isComic: Bool {
        return imageUrls != nil && !(imageUrls?.isEmpty ?? true)
    }
}

struct ReplaceRule: Codable, Identifiable {
    var id: String { ruleId }
    var ruleId: String = UUID().uuidString
    var pattern: String = ""
    var replacement: String = ""
    var isEnabled: Bool = true
    var scope: Int = 0
    var groupName: String?
}

struct SearchBook: Codable {
    var bookUrl: String = ""
    var bookSourceUrl: String = ""
    var name: String = ""
    var author: String = ""
    var coverUrl: String?
    var intro: String?
    var kind: String?
    var latestChapter: String?
    var wordCount: String?
    var origin: String?
    var originName: String?
    var customInfo: String?
    var time: Int = 0  // 响应延迟(毫秒)
}

struct Bookmark: Codable, Identifiable {
    var id: String { "\(bookName)-\(bookAuthor)-\(chapterIndex)" }
    var bookName: String = ""
    var bookAuthor: String = ""
    var chapterIndex: Int = 0
    var chapterName: String = ""
    var bookText: String = ""
    var content: String = ""
    var createTime: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
}

import Foundation

struct BookSource: Codable, Identifiable {
    var id: String { bookSourceUrl }
    var bookSourceUrl: String = ""
    var bookSourceName: String = ""
    var bookSourceGroup: String?
    var bookSourceType: Int = 0
    var bookUrlPattern: String?
    var enabled: Bool = true
    var enabledExplore: Bool = true
    var jsLib: String?
    var enabledCookieJar: Bool? = true
    var concurrentRate: String?
    var header: String?
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var coverDecodeJs: String?
    var exploreUrl: String?
    var searchUrl: String?
    var ruleSearch: SearchRule?
    var ruleExplore: ExploreRule?
    var ruleBookInfo: BookInfoRule?
    var ruleToc: TocRule?
    var ruleContent: ContentRule?

    enum CodingKeys: String, CodingKey {
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType
        case bookUrlPattern, enabled, enabledExplore, jsLib
        case enabledCookieJar, concurrentRate, header
        case loginUrl, loginUi, loginCheckJs, coverDecodeJs
        case exploreUrl, searchUrl
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent
    }
}

struct SearchRule: Codable {
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var coverUrl: String?
    var bookUrl: String?
    var kind: String?
    var wordCount: String?
    var lastChapter: String?
    var checkKeyWord: String?
}

struct ExploreRule: Codable {
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var coverUrl: String?
    var bookUrl: String?
    var kind: String?
    var wordCount: String?
    var lastChapter: String?
}

struct BookInfoRule: Codable {
    var name: String?
    var author: String?
    var intro: String?
    var coverUrl: String?
    var tocUrl: String?
    var kind: String?
    var lastChapter: String?
    var wordCount: String?
    var variables: String?
    var initJs: String?
    
    enum CodingKeys: String, CodingKey {
        case name, author, intro, coverUrl, tocUrl, kind, lastChapter, wordCount, variables
        case initJs = "init"
    }
}

struct TocRule: Codable {
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var isVolume: String?
    var volumeName: String?
    var chapterSize: String?
    var nextTocUrl: String?
    var isVip: String?
    var preUpdateJs: String?
    var updateTime: String?
}

struct ContentRule: Codable {
    var content: String?
    var title: String?
    var nextContentUrl: String?
    var nextContentBtn: String?
    var webJs: String?
    var replaceRegex: String?
    var sourceRegex: String?
    var imageStyle: String?
}

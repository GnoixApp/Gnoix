import Foundation

struct Book: Codable, Identifiable {
    var id: String { bookUrl }
    var bookUrl: String
    var tocUrl: String = ""
    var origin: String = "local"
    var originName: String = ""
    var name: String = ""
    var author: String = ""
    var kind: String?
    var coverUrl: String?
    var customCoverUrl: String?
    var intro: String?
    var customIntro: String?
    var charset: String?
    var type: Int = 0
    var group: Int64 = 0
    var canUpdate: Bool = true
    var latestChapterTitle: String?
    var totalChapterNum: Int = 0
    var durChapterIndex: Int = 0
    var durChapterPos: Int = 0
    var durChapterTime: Int64 = 0
    var variable: String?
    var readConfig: ReadConfig?
    
    var isComic: Bool {
        return type == 1
    }
    
    static let localTag = "local"
}

struct ReadConfig: Codable {
    var bgColor: Int = 0xFFEEEEEE
    var textColor: Int = 0xFF333333
    var textSize: Int = 18
    var lineSpacing: Float = 1.5
    var paragraphSpacing: Float = 1.8
    var charSpacing: Float = 0
    var bold: Bool = false
    var italic: Bool = false
    var fontFamily: String = "System"
    var pageMode: Int = 0
    var keepScreenOn: Bool = true
    var readTheme: String = "default"
    var turnSpeed: Float = 300
    var animationSpeed: Float = 0.3
    var useCache: Bool = true
    var convertSimpToTrad: Bool = false
    var convertTradToSimp: Bool = false
    
    var readMethod: String = "上下滑动"
    var clickMethod: String = "下一页"
    var pageType: String = "正常"
    var pageMode2: String = "自适应"
    var readWidth: Int = 600
    var autoReadingMethod: String = "像素滚动"
    var autoReadingPixel: Int = 50
    var autoReadingLineTime: Int = 300
    var selectionAction: String = "操作弹窗"
    var theme: Int = 0
    var themeType: String = "day"
    var autoTheme: Bool = false
    var contentBGImg: String?
    var customConfig: String = "默认"
    var customFontsMap: [String: String]?
}

enum PageMode: Int, CaseIterable {
    case scroll = 0
    case slide = 1
    case cover = 2
    case simulate = 3

    var title: String {
        switch self {
        case .scroll: return "滚动"
        case .slide: return "滑动"
        case .cover: return "覆盖"
        case .simulate: return "仿真"
        }
    }

    var description: String {
        switch self {
        case .scroll: return "上下滚动阅读"
        case .slide: return "左右滑动翻页"
        case .cover: return "覆盖切换"
        case .simulate: return "仿真翻页"
        }
    }
}

extension Book {
    func resolvedCoverURL() -> URL? {
        let candidates = [origin, tocUrl, bookUrl]
        return CoverURLResolver.resolve(raw: customCoverUrl ?? coverUrl, baseCandidates: candidates)
    }
}

extension SearchBook {
    func resolvedCoverURL() -> URL? {
        let candidates = [bookSourceUrl, origin ?? "", bookUrl]
        return CoverURLResolver.resolve(raw: coverUrl, baseCandidates: candidates)
    }
}

enum CoverURLResolver {
    private static let allowedURLCharacters: CharacterSet = {
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%")
    }()

    static func resolve(raw: String?, baseCandidates: [String]) -> URL? {
        guard var raw, !raw.isEmpty else { return nil }
        raw = sanitize(raw)
        guard !raw.isEmpty else { return nil }

        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return url
        }

        if raw.hasPrefix("/") && FileManager.default.fileExists(atPath: raw) {
            return URL(fileURLWithPath: raw)
        }

        if let absolute = absoluteURL(from: raw) {
            return absolute
        }

        let base = firstValidBase(from: baseCandidates)
        if raw.hasPrefix("//") {
            let scheme = base?.scheme ?? "https"
            return absoluteURL(from: "\(scheme):\(raw)")
        }

        guard let base else { return nil }
        let encodedRaw = percentEncoded(raw)
        return URL(string: encodedRaw, relativeTo: base)?.absoluteURL
    }

    private static func firstValidBase(from candidates: [String]) -> URL? {
        for item in candidates {
            let cleaned = sanitize(item)
            guard !cleaned.isEmpty else { continue }
            if let direct = URL(string: cleaned), direct.scheme != nil, direct.host != nil {
                return direct
            }
            if !cleaned.contains("://"),
               let httpsURL = URL(string: "https://\(cleaned)"),
               httpsURL.host != nil {
                return httpsURL
            }
            let encoded = percentEncoded(cleaned)
            if let url = URL(string: encoded), url.scheme != nil, url.host != nil {
                return url
            }
            if !encoded.contains("://"),
               let encodedHTTPS = URL(string: "https://\(encoded)"),
               encodedHTTPS.host != nil {
                return encodedHTTPS
            }
        }
        return nil
    }

    private static func absoluteURL(from value: String) -> URL? {
        if let direct = URL(string: value), direct.scheme != nil {
            return direct
        }
        let encoded = percentEncoded(value)
        if let encodedURL = URL(string: encoded), encodedURL.scheme != nil {
            return encodedURL
        }
        return nil
    }

    private static func sanitize(_ input: String) -> String {
        var output = input.trimmingCharacters(in: .whitespacesAndNewlines)
        output = output.replacingOccurrences(of: "&amp;", with: "&")
        output = output.replacingOccurrences(of: "\\/", with: "/")
        output = output.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return output
    }

    private static func percentEncoded(_ input: String) -> String {
        input.addingPercentEncoding(withAllowedCharacters: allowedURLCharacters) ?? input
    }
}

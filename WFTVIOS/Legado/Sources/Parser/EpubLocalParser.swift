import Foundation
import ZIPFoundation
import SwiftSoup

struct LocalEpubChapter {
    let title: String
    let path: String
    let content: String
}

struct LocalEpubChapterIndex {
    let title: String
    let path: String
}

struct ParsedLocalEpubBook {
    let title: String?
    let chapters: [LocalEpubChapter]
}

struct ParsedLocalEpubBookIndex {
    let title: String?
    let chapters: [LocalEpubChapterIndex]
}

enum LocalEpubParserError: LocalizedError {
    case openArchiveFailed
    case containerMissing
    case opfMissing
    case invalidPackage
    case noReadableChapters

    var errorDescription: String? {
        switch self {
        case .openArchiveFailed:
            return "无法打开 EPUB 文件"
        case .containerMissing:
            return "EPUB 缺少 container.xml"
        case .opfMissing:
            return "EPUB 缺少 OPF 清单"
        case .invalidPackage:
            return "EPUB 结构无效"
        case .noReadableChapters:
            return "EPUB 未找到可读章节"
        }
    }
}

final class EpubLocalParser {
    static let shared = EpubLocalParser()

    private init() {}

    func parseBook(fileURL: URL) throws -> ParsedLocalEpubBook {
        let parsedIndex = try parseBookIndex(fileURL: fileURL)
        var chapters: [LocalEpubChapter] = []

        for item in parsedIndex.chapters {
            guard let content = try? readChapterContent(fileURL: fileURL, chapterPath: item.path),
                  !content.isEmpty else {
                continue
            }
            chapters.append(LocalEpubChapter(title: item.title, path: item.path, content: content))
        }

        guard !chapters.isEmpty else {
            throw LocalEpubParserError.noReadableChapters
        }
        return ParsedLocalEpubBook(title: parsedIndex.title, chapters: chapters)
    }

    func parseBookIndex(fileURL: URL) throws -> ParsedLocalEpubBookIndex {
        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            throw LocalEpubParserError.openArchiveFailed
        }

        guard let containerData = entryData(at: "META-INF/container.xml", in: archive) else {
            throw LocalEpubParserError.containerMissing
        }
        guard let opfPath = parseContainerOPFPath(data: containerData) else {
            throw LocalEpubParserError.invalidPackage
        }
        guard let opfData = entryData(at: opfPath, in: archive) else {
            throw LocalEpubParserError.opfMissing
        }

        let packageInfo = parsePackageInfo(data: opfData)
        guard !packageInfo.manifest.isEmpty else {
            throw LocalEpubParserError.invalidPackage
        }

        let orderedItems = packageInfo.spine.compactMap { packageInfo.manifest[$0] }
        let candidateItems = orderedItems.isEmpty ? Array(packageInfo.manifest.values) : orderedItems
        let contentItems = candidateItems.filter { isReadableDocument(item: $0) }
        let opfDirectory = normalizedDirectory(of: opfPath)

        var chapters: [LocalEpubChapterIndex] = []
        var visitedChapterPaths = Set<String>()
        for (index, item) in contentItems.enumerated() {
            let chapterPath = normalizedPath(buildPath(base: opfDirectory, href: item.href))
            guard visitedChapterPaths.insert(chapterPath).inserted else {
                continue
            }
            guard !chapterPath.isEmpty, let data = entryData(at: chapterPath, in: archive) else {
                continue
            }
            guard let html = decodeText(data: data) else {
                continue
            }

            let chapterTitle = extractChapterTitle(fromHTML: html) ?? "第\(index + 1)章"
            chapters.append(LocalEpubChapterIndex(title: chapterTitle, path: chapterPath))
        }

        guard !chapters.isEmpty else {
            throw LocalEpubParserError.noReadableChapters
        }

        return ParsedLocalEpubBookIndex(title: packageInfo.bookTitle, chapters: chapters)
    }

    func readChapterContent(fileURL: URL, chapterPath: String) throws -> String {
        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            throw LocalEpubParserError.openArchiveFailed
        }

        guard let data = entryData(at: chapterPath, in: archive),
              let html = decodeText(data: data) else {
            throw LocalEpubParserError.noReadableChapters
        }
        let text = htmlToReadableText(html)
        guard !text.isEmpty else {
            throw LocalEpubParserError.noReadableChapters
        }
        return text
    }

    private func parseContainerOPFPath(data: Data) -> String? {
        let parser = XMLParser(data: data)
        let delegate = ContainerParserDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.fullPath
    }

    private func parsePackageInfo(data: Data) -> (manifest: [String: OPFManifestItem], spine: [String], bookTitle: String?) {
        let parser = XMLParser(data: data)
        let delegate = OPFParserDelegate()
        parser.delegate = delegate
        parser.parse()
        return (delegate.manifest, delegate.spine, delegate.bookTitle)
    }

    private func entryData(at path: String, in archive: Archive) -> Data? {
        let normalized = normalizedPath(path)
        guard !normalized.isEmpty else { return nil }

        var candidates: [String] = [normalized]
        if let decoded = normalized.removingPercentEncoding, !decoded.isEmpty {
            candidates.append(decoded)
        }
        let noLeadingSlash = normalized.hasPrefix("/") ? String(normalized.dropFirst()) : normalized
        if !noLeadingSlash.isEmpty {
            candidates.append(noLeadingSlash)
        }

        var visited = Set<String>()
        for candidate in candidates where visited.insert(candidate).inserted {
            guard let entry = archive[candidate] else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                }
                return data
            } catch {
                continue
            }
        }
        return nil
    }

    private func decodeText(data: Data) -> String? {
        let encodings: [(name: String, encoding: String.Encoding)] = [
            ("utf-8", .utf8),
            ("utf-16", .unicode),
            ("utf-16le", .utf16LittleEndian),
            ("utf-16be", .utf16BigEndian),
            ("gb18030", gb18030Encoding()),
            ("big5", big5Encoding())
        ]

        var bestResult: (text: String, score: Int)?
        for (_, encoding) in encodings {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let cleaned = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            let score = textQualityScore(cleaned)
            if bestResult == nil || score > bestResult!.score {
                bestResult = (cleaned, score)
            }
        }
        return bestResult?.text
    }

    private func htmlToReadableText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "</?(div|p|br|hr|h\\d|article|dd|dl|li|ul|ol|tr|table|section|blockquote)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = (try? Entities.unescape(text)) ?? text
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractChapterTitle(fromHTML html: String) -> String? {
        do {
            let doc = try SwiftSoup.parse(html)
            if let title = try doc.select("title").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return title
            }
            if let heading = try doc.select("h1, h2, h3").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines),
               !heading.isEmpty {
                return heading
            }
        } catch {
            return nil
        }
        return nil
    }

    private func normalizedDirectory(of path: String) -> String {
        let normalized = normalizedPath(path)
        guard let slash = normalized.lastIndex(of: "/") else {
            return ""
        }
        return String(normalized[..<slash])
    }

    private func buildPath(base: String, href: String) -> String {
        let cleanHref = href.components(separatedBy: "#").first?.components(separatedBy: "?").first ?? href
        guard !base.isEmpty else { return cleanHref }
        return "\(base)/\(cleanHref)"
    }

    private func normalizedPath(_ raw: String) -> String {
        let replaced = raw.replacingOccurrences(of: "\\", with: "/")
        let components = replaced.split(separator: "/")
        var stack: [Substring] = []
        for component in components {
            if component == "." || component.isEmpty {
                continue
            }
            if component == ".." {
                if !stack.isEmpty {
                    stack.removeLast()
                }
                continue
            }
            stack.append(component)
        }
        return stack.map(String.init).joined(separator: "/")
    }

    private func isReadableDocument(item: OPFManifestItem) -> Bool {
        if item.properties.contains("nav") {
            return false
        }

        let mediaType = item.mediaType.lowercased()
        if mediaType == "application/xhtml+xml" ||
            mediaType == "text/html" ||
            mediaType == "application/xml" ||
            mediaType == "text/xml" {
            return true
        }

        let ext = URL(fileURLWithPath: item.href).pathExtension.lowercased()
        if mediaType.isEmpty {
            return ext == "xhtml" || ext == "html" || ext == "htm" || ext == "xml"
        }
        return false
    }

    private func textQualityScore(_ text: String) -> Int {
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

    private func gb18030Encoding() -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
    }

    private func big5Encoding() -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )
        )
    }
}

private final class ContainerParserDelegate: NSObject, XMLParserDelegate {
    var fullPath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard normalizeElementName(elementName) == "rootfile",
              let path = attributeValue(attributeDict, key: "full-path"),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        fullPath = path
    }
}

private final class OPFParserDelegate: NSObject, XMLParserDelegate {
    var manifest: [String: OPFManifestItem] = [:]
    var spine: [String] = []
    var bookTitle: String?

    private var collectingTitle = false
    private var titleBuffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let name = normalizeElementName(elementName)
        switch name {
        case "item":
            guard let id = attributeValue(attributeDict, key: "id"),
                  let href = attributeValue(attributeDict, key: "href"),
                  !id.isEmpty,
                  !href.isEmpty else {
                return
            }
            let mediaType = attributeValue(attributeDict, key: "media-type") ?? ""
            let properties = Set(
                (attributeValue(attributeDict, key: "properties") ?? "")
                    .split(whereSeparator: { $0.isWhitespace })
                    .map { String($0).lowercased() }
            )
            manifest[id] = OPFManifestItem(href: href, mediaType: mediaType, properties: properties)
        case "itemref":
            guard let idref = attributeValue(attributeDict, key: "idref"),
                  !idref.isEmpty else {
                return
            }
            spine.append(idref)
        case "title":
            if bookTitle == nil {
                collectingTitle = true
                titleBuffer = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard collectingTitle else { return }
        titleBuffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard normalizeElementName(elementName) == "title", collectingTitle else { return }
        collectingTitle = false
        let title = titleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            bookTitle = title
        }
    }
}

private struct OPFManifestItem {
    let href: String
    let mediaType: String
    let properties: Set<String>
}

private func normalizeElementName(_ name: String) -> String {
    return name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
}

private func attributeValue(_ attributes: [String: String], key: String) -> String? {
    if let value = attributes[key] {
        return value
    }
    let lowercasedKey = key.lowercased()
    for (k, v) in attributes where k.lowercased() == lowercasedKey {
        return v
    }
    return nil
}

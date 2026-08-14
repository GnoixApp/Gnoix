import Foundation

struct TxtTocRule: Codable {
    var bookName: String?
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var isVolume: String?
    var volumeName: String?
    var chapterSize: String?
    var nextTocUrl: String?
}

class TxtTocParser {
    
    static let shared = TxtTocParser()
    
    private let chapterRegexes: [NSRegularExpression]
    private let volumeRegexes: [NSRegularExpression]
    private let tocRuleRegexes: [NSRegularExpression]
    
    private init() {
        chapterRegexes = [
            "^\\s*第[零〇○一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟0-9]+[章节回卷部篇幕集话].*$",
            "^\\s*(正文\\s*)?第\\s*[0-9]{1,6}\\s*[章节回卷部篇幕集话].*$",
            "^\\s*(序章|楔子|引子|前言|后记|终章|尾声|番外).*$",
            "^\\s*chapter\\s*[0-9ivxlcdm]+.*$",
            "^\\s*第\\s*[0-9]{1,6}\\s*节.*$",
            "^\\s*[0-9]{1,5}[、\\.．]\\s*.+$",
            "^\\s*\\[[^\\]]*第[0-9一二三四五六七八九十百千万零〇○]+[章节回卷部篇幕集话][^\\]]*\\]\\s*$",
            "^\\s*【[^】]*第[0-9一二三四五六七八九十百千万零〇○]+[章节回卷部篇幕集话][^】]*】\\s*$",
            "^\\s*卷\\s*[0-9一二三四五六七八九十百千万零〇○]+.*$",
            "^\\s*part\\s*[0-9ivxlcdm]+.*$"
        ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        
        volumeRegexes = [
            "^\\s*第[零〇○一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟0-9]+[卷部].*$",
            "^\\s*volume\\s*[0-9ivxlcdm]+.*$",
            "^\\s*part\\s*[0-9ivxlcdm]+.*$",
            "^\\s*第\\s*[0-9]{1,6}\\s*卷.*$"
        ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

        // legado 会基于规则命中数选择更适合的目录正则，这里做轻量移植。
        tocRuleRegexes = [
            "^\\s*第[零〇○一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟0-9]+[章节回卷部篇幕集话].*$",
            "^\\s*chapter\\s*[0-9ivxlcdm]+.*$",
            "^\\s*\\d{1,5}[、\\.．]\\s*.+$",
            "^\\s*(序章|楔子|引子|前言|后记|终章|尾声|番外).*$"
        ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }
    
    func parseToc(content: String, rule: TxtTocRule? = nil) -> [BookChapter] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let fallbackChunkSize = resolvedChapterSize(rule?.chapterSize, defaultValue: 12000)
        let oversizeSplitSize = max(32768, fallbackChunkSize * 8)
        let activeRegexes = buildActiveChapterRegexes(content: normalized, rule: rule)
        let fullLength = (normalized as NSString).length
        var headings: [(title: String, start: Int, isVolume: Bool)] = []

        normalized.enumerateSubstrings(in: normalized.startIndex..<normalized.endIndex, options: .byLines) { substring, lineRange, _, _ in
            guard let substring else { return }
            let trimmedLine = self.sanitizedHeadingTitle(substring)
            
            if trimmedLine.isEmpty || trimmedLine.count < 2 {
                return
            }
            if self.isNoiseHeading(trimmedLine) {
                return
            }
            
            let isVolume = self.isVolumeTitle(trimmedLine, rule: rule)
            let isChapter = isVolume || self.matches(trimmedLine, regexes: activeRegexes)
            guard isChapter else { return }
            guard self.isLikelyHeading(trimmedLine, isVolume: isVolume) else { return }

            let startOffset = lineRange.lowerBound.utf16Offset(in: normalized)
            if let last = headings.last,
               abs(startOffset - last.start) <= 40,
               self.normalizeComparableText(last.title) == self.normalizeComparableText(trimmedLine) {
                return
            }
            if let last = headings.last,
               abs(startOffset - last.start) <= 120,
               !self.hasExplicitChapterMarker(last.title),
               !self.hasExplicitChapterMarker(trimmedLine) {
                return
            }
            headings.append((title: trimmedLine, start: startOffset, isVolume: isVolume))
        }

        var chapters = buildChapters(from: headings, fullLength: fullLength, normalized: normalized)
        chapters = splitOversizedChapters(chapters, maxSize: oversizeSplitSize)
        chapters = mergeAbnormalTinyChapters(chapters, minSize: max(120, fallbackChunkSize / 80))
        chapters = reorderChaptersIfNeeded(chapters)
        
        if chapters.isEmpty {
            chapters = splitBySize(content: normalized, maxSize: fallbackChunkSize)
        }

        for index in chapters.indices {
            chapters[index].index = index
        }
        return chapters
    }
    
    private func buildActiveChapterRegexes(content: String, rule: TxtTocRule?) -> [NSRegularExpression] {
        if let custom = compileRuleRegex(rule?.chapterList) {
            return [custom]
        }
        var regexes = chapterRegexes
        if let best = selectBestTocRegex(content: content) {
            regexes.insert(best, at: 0)
        }
        return regexes
    }

    private func compileRuleRegex(_ raw: String?) -> NSRegularExpression? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return try? NSRegularExpression(pattern: raw, options: [.caseInsensitive])
    }

    private func selectBestTocRegex(content: String) -> NSRegularExpression? {
        let lines = content
            .split(whereSeparator: \.isNewline)
            .prefix(5000)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var best: (regex: NSRegularExpression, score: Int)?
        for regex in tocRuleRegexes {
            var score = 0
            for line in lines {
                if matches(line, regexes: [regex]) {
                    score += 1
                }
            }
            if best == nil || score > best!.score {
                best = (regex, score)
            }
        }
        guard let best, best.score >= 3 else { return nil }
        return best.regex
    }

    private func isVolumeTitle(_ line: String, rule: TxtTocRule?) -> Bool {
        if let custom = compileRuleRegex(rule?.isVolume), matches(line, regexes: [custom]) {
            return true
        }
        return matches(line, regexes: volumeRegexes)
    }

    private func buildChapters(
        from headings: [(title: String, start: Int, isVolume: Bool)],
        fullLength: Int,
        normalized: String
    ) -> [BookChapter] {
        guard !headings.isEmpty else { return [] }
        var chapters: [BookChapter] = []
        let nsContent = normalized as NSString

        // legado 的本地解析会保留章节前的前言内容，这里也补齐。
        if let first = headings.first, first.start > 0 {
            let prefix = nsContent.substring(with: NSRange(location: 0, length: first.start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                var preface = BookChapter()
                preface.title = "前言"
                preface.isVolume = false
                preface.start = 0
                preface.end = Int64(first.start)
                chapters.append(preface)
            }
        }

        for (index, heading) in headings.enumerated() {
            let nextStart = index + 1 < headings.count ? headings[index + 1].start : fullLength
            let start = min(max(heading.start, 0), fullLength)
            let end = min(max(nextStart, start), fullLength)
            guard end >= start else { continue }

            var chapter = BookChapter()
            chapter.title = heading.title
            chapter.isVolume = heading.isVolume
            chapter.start = Int64(start)
            chapter.end = Int64(end)
            chapters.append(chapter)
        }
        return chapters
    }

    private func splitOversizedChapters(_ chapters: [BookChapter], maxSize: Int = 102400) -> [BookChapter] {
        guard !chapters.isEmpty else { return chapters }
        var output: [BookChapter] = []

        for chapter in chapters {
            guard let start64 = chapter.start, let end64 = chapter.end else {
                output.append(chapter)
                continue
            }

            let start = Int(start64)
            let end = Int(end64)
            let length = max(0, end - start)
            guard !chapter.isVolume, length > maxSize else {
                output.append(chapter)
                continue
            }

            let pieceCount = Int(ceil(Double(length) / Double(maxSize)))
            guard pieceCount > 1 else {
                output.append(chapter)
                continue
            }

            for pieceIndex in 0..<pieceCount {
                let pieceStart = start + pieceIndex * maxSize
                let pieceEnd = min(end, pieceStart + maxSize)
                guard pieceEnd > pieceStart else { continue }

                var piece = chapter
                piece.start = Int64(pieceStart)
                piece.end = Int64(pieceEnd)
                piece.title = "\(chapter.title)(\(pieceIndex + 1))"
                output.append(piece)
            }
        }

        return output
    }

    private func splitBySize(content: String, maxSize: Int = 12000) -> [BookChapter] {
        var chapters: [BookChapter] = []
        let nsContent = content as NSString
        var currentIndex = 0
        var chapterIndex = 0
        
        while currentIndex < nsContent.length {
            let endIndex = min(currentIndex + maxSize, nsContent.length)
            let chapterContent = nsContent.substring(with: NSRange(location: currentIndex, length: endIndex - currentIndex))
            
            let firstLine = chapterContent.components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "第 \(chapterIndex + 1) 章"
            
            var chapter = BookChapter()
            chapter.title = firstLine.trimmingCharacters(in: .whitespaces)
            chapter.index = chapterIndex
            chapter.start = Int64(currentIndex)
            chapter.end = Int64(endIndex)
            
            chapters.append(chapter)
            
            currentIndex = endIndex
            chapterIndex += 1
        }
        
        return chapters
    }
    
    func getChapterContent(chapter: BookChapter, fullContent: String) -> String {
        if let start = chapter.start, let end = chapter.end {
            let nsContent = fullContent as NSString
            let fullLength = nsContent.length
            let startIdx = min(max(Int(start), 0), fullLength)
            let endIdx = min(max(Int(end), startIdx), fullLength)
            if startIdx <= endIdx {
                let raw = nsContent.substring(with: NSRange(location: startIdx, length: endIdx - startIdx))
                return normalizeLocalChapterContent(raw, chapterTitle: chapter.title)
            }
        }
        return normalizeLocalChapterContent(fullContent, chapterTitle: chapter.title)
    }

    private func matches(_ line: String, regexes: [NSRegularExpression]) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        for regex in regexes {
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private func normalizeLocalChapterContent(_ raw: String, chapterTitle: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")

        var lines = text.components(separatedBy: .newlines)
        if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let first = lines[firstIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if isLikelyDuplicatedTitle(firstLine: first, chapterTitle: chapterTitle) {
                lines.remove(at: firstIndex)
            }
        }
        text = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: #"^[\n\s　]+"#, with: "　　", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text
    }

    private func resolvedChapterSize(_ raw: String?, defaultValue: Int) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw),
              value >= 4000,
              value <= 300000 else {
            return defaultValue
        }
        return value
    }

    private func sanitizedHeadingTitle(_ raw: String) -> String {
        var title = raw
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > 120 {
            title = String(title.prefix(120))
        }
        return title
    }

    private func isNoiseHeading(_ title: String) -> Bool {
        let exactNoise = Set([
            "上一页", "下一页", "首页", "尾页", "目录", "章节目录", "返回目录",
            "加入书架", "投推荐票", "举报", "登录", "注册", "搜索", "广告"
        ])
        if exactNoise.contains(title) {
            return true
        }
        let fuzzyNoise = ["最新网址", "手机版", "收藏", "推荐票", "打赏", "评论", "下载"]
        return fuzzyNoise.contains(where: { title.contains($0) })
    }

    private func isLikelyHeading(_ title: String, isVolume: Bool) -> Bool {
        if title.count > 80 {
            return false
        }
        if title.contains("http://") || title.contains("https://") {
            return false
        }
        if title.contains("<") || title.contains(">") {
            return false
        }
        if !isVolume && title.count > 24 && (title.contains("。") || title.contains("，") || title.contains("；")) {
            return false
        }
        if title.filter({ $0 == " " || $0 == "\u{3000}" }).count >= 10 {
            return false
        }
        return true
    }

    private func hasExplicitChapterMarker(_ title: String) -> Bool {
        if extractChapterNumber(from: title) != nil {
            return true
        }
        let lowered = title.lowercased()
        if lowered.contains("chapter") || lowered.contains("volume") || lowered.contains("part") {
            return true
        }
        return title.contains("第") && (title.contains("章") || title.contains("节") || title.contains("回"))
    }

    private func mergeAbnormalTinyChapters(_ chapters: [BookChapter], minSize: Int) -> [BookChapter] {
        guard chapters.count >= 2 else { return chapters }
        var merged: [BookChapter] = []

        for chapter in chapters {
            guard let start = chapter.start, let end = chapter.end else {
                merged.append(chapter)
                continue
            }

            let length = Int(max(0, end - start))
            let isTiny = !chapter.isVolume && length > 0 && length <= minSize
            let keepAsStandalone = isStandaloneShortChapterTitle(chapter.title)

            if isTiny, !keepAsStandalone {
                if var last = merged.last, !last.isVolume {
                    last.end = chapter.end
                    merged[merged.count - 1] = last
                    continue
                }
                if !merged.isEmpty {
                    continue
                }
            }
            merged.append(chapter)
        }

        if merged.count >= 2, let first = merged.first {
            let firstLength = Int(max(0, (first.end ?? 0) - (first.start ?? 0)))
            if !first.isVolume,
               firstLength > 0,
               firstLength <= minSize,
               !isStandaloneShortChapterTitle(first.title) {
                var output = merged
                output.removeFirst()
                if !output.isEmpty {
                    output[0].start = first.start
                }
                return output
            }
        }

        return merged
    }

    private func isStandaloneShortChapterTitle(_ title: String) -> Bool {
        if hasExplicitChapterMarker(title) {
            return true
        }
        let exact = Set(["序章", "楔子", "引子", "前言", "后记", "终章", "尾声", "番外"])
        if exact.contains(title.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return true
        }
        return false
    }

    private func reorderChaptersIfNeeded(_ chapters: [BookChapter]) -> [BookChapter] {
        guard chapters.count >= 6 else { return chapters }
        if chapters.contains(where: { $0.isVolume }) {
            return chapters
        }

        let firstNumberedIndex = chapters.firstIndex(where: { extractChapterNumber(from: $0.title) != nil }) ?? 0
        if firstNumberedIndex >= chapters.count - 1 {
            return chapters
        }
        let prefix = Array(chapters.prefix(firstNumberedIndex))
        let candidates = Array(chapters.dropFirst(firstNumberedIndex))
        guard candidates.count >= 4 else { return chapters }

        let measured = candidates.enumerated().compactMap { item -> (index: Int, number: Int)? in
            guard let number = extractChapterNumber(from: item.element.title) else { return nil }
            return (item.offset, number)
        }
        guard measured.count >= max(4, candidates.count / 3) else { return chapters }

        let numbers = measured.sorted { $0.index < $1.index }.map(\.number)
        let direction = monotonicDirection(of: numbers)
        if direction == .descending {
            return prefix + Array(candidates.reversed())
        }
        if direction == .ascending {
            return chapters
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            let l = extractChapterNumber(from: lhs.title) ?? Int.max
            let r = extractChapterNumber(from: rhs.title) ?? Int.max
            if l != r { return l < r }
            return lhs.index < rhs.index
        }
        let sortedNumbers = sortedCandidates.compactMap { extractChapterNumber(from: $0.title) }
        let originalScore = monotonicScore(numbers)
        let sortedScore = monotonicScore(sortedNumbers)

        guard sortedScore > originalScore + max(3, sortedNumbers.count / 8) else {
            return chapters
        }
        return prefix + sortedCandidates
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
            if numbers[idx] >= numbers[idx - 1] { asc += 1 } else { desc += 1 }
        }
        return asc - desc
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

    private func isLikelyDuplicatedTitle(firstLine: String, chapterTitle: String) -> Bool {
        let normalizedFirst = normalizeComparableText(firstLine)
        let normalizedTitle = normalizeComparableText(chapterTitle)
        guard !normalizedFirst.isEmpty, !normalizedTitle.isEmpty else { return false }
        if normalizedFirst == normalizedTitle { return true }
        if normalizedFirst.count <= 20 && normalizedTitle.contains(normalizedFirst) { return true }
        if normalizedTitle.count <= 20 && normalizedFirst.contains(normalizedTitle) { return true }
        return false
    }

    private func normalizeComparableText(_ value: String) -> String {
        let stripped = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}一-龥]+"#, with: "", options: .regularExpression)
        return stripped
    }
}

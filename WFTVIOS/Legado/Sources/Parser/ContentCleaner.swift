import Foundation

class ContentCleaner {
    static let shared = ContentCleaner()
    
    private var replaceRules: [ReplaceRule] = []
    private let rulesLock = NSLock()
    private var regexCache: [String: NSRegularExpression] = [:]
    private let regexCacheLock = NSLock()
    private var rulesObserver: NSObjectProtocol?
    
    private init() {
        rulesObserver = NotificationCenter.default.addObserver(
            forName: .replaceRulesChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.loadRules()
        }
    }
    
    deinit {
        if let observer = rulesObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func loadRules() {
        let rules = DatabaseManager.shared.getAllReplaceRules().filter { $0.isEnabled }
        rulesLock.lock()
        replaceRules = rules
        rulesLock.unlock()
        
        regexCacheLock.lock()
        regexCache.removeAll()
        regexCacheLock.unlock()
    }
    
    func clean(content: String, scope: Int = 0) -> String {
        rulesLock.lock()
        let hasLoadedRules = !replaceRules.isEmpty
        rulesLock.unlock()
        
        if !hasLoadedRules {
            loadRules()
        }
        rulesLock.lock()
        let currentRules = replaceRules
        rulesLock.unlock()
        
        var result = content
        
        let applicableRules = currentRules.filter { rule in
            scope == 0 || rule.scope == 0 || rule.scope == scope
        }
        
        for rule in applicableRules {
            result = applyRule(content: result, pattern: rule.pattern, replacement: rule.replacement)
        }
        
        return result
    }
    
    private func applyRule(content: String, pattern: String, replacement: String) -> String {
        guard !pattern.isEmpty else { return content }
        let normalizedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedReplacement.hasPrefix("@js:") else { return content }
        
        guard let regex = compiledRegex(pattern: pattern) else {
            return content
        }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: replacement)
    }

    private func compiledRegex(pattern: String) -> NSRegularExpression? {
        let cacheKey = "i|s|\(pattern)"
        regexCacheLock.lock()
        if let cached = regexCache[cacheKey] {
            regexCacheLock.unlock()
            return cached
        }
        regexCacheLock.unlock()

        guard let compiled = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        regexCacheLock.lock()
        regexCache[cacheKey] = compiled
        regexCacheLock.unlock()
        return compiled
    }
    
    func cleanBookInfo(_ book: Book) -> Book {
        var cleanedBook = book
        
        if let intro = book.intro {
            cleanedBook.intro = clean(content: intro, scope: 1)
        }
        
        return cleanedBook
    }
    
    func cleanChapter(_ content: ChapterContent) -> ChapterContent {
        var cleaned = content
        cleaned.content = clean(content: content.content, scope: 2)
        return cleaned
    }
}

struct ReplaceRuleImportResult {
    let importedCount: Int
    let skippedJSCount: Int
}

class ReplaceRuleManager {
    static let shared = ReplaceRuleManager()
    
    private let database = DatabaseManager.shared
    
    private struct ParsedRulesResult {
        let rules: [ReplaceRule]
        let skippedJSCount: Int
    }
    
    private init() {}
    
    func getAllRules() -> [ReplaceRule] {
        return database.getAllReplaceRules()
    }
    
    func saveRule(_ rule: ReplaceRule) {
        database.saveReplaceRule(rule)
        notifyRulesChanged()
    }
    
    func deleteRule(_ ruleId: String) {
        database.deleteReplaceRule(ruleId)
        notifyRulesChanged()
    }
    
    func deleteAllRules() {
        database.deleteAllReplaceRules()
        notifyRulesChanged()
    }
    
    func importRules(from jsonString: String) -> Int {
        return importRulesDetailed(from: jsonString).importedCount
    }
    
    func importRulesDetailed(from jsonString: String) -> ReplaceRuleImportResult {
        let parsed = parseRules(from: jsonString)
        guard !parsed.rules.isEmpty else {
            return ReplaceRuleImportResult(importedCount: 0, skippedJSCount: parsed.skippedJSCount)
        }
        
        let existingRules = database.getAllReplaceRules()
        var ruleIdByFingerprint: [String: String] = [:]
        for existing in existingRules {
            ruleIdByFingerprint[fingerprint(of: existing)] = existing.ruleId
        }
        
        var importedCount = 0
        for var rule in parsed.rules {
            rule.pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.pattern.isEmpty else { continue }
            
            let key = fingerprint(of: rule)
            if let existingId = ruleIdByFingerprint[key] {
                rule.ruleId = existingId
            } else if rule.ruleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rule.ruleId = UUID().uuidString
            }
            
            database.saveReplaceRule(rule)
            ruleIdByFingerprint[key] = rule.ruleId
            importedCount += 1
        }
        
        if importedCount > 0 {
            notifyRulesChanged()
        }
        return ReplaceRuleImportResult(importedCount: importedCount, skippedJSCount: parsed.skippedJSCount)
    }
    
    func exportRules(prettyPrinted: Bool = true) -> String? {
        let rules = getAllRules()
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        
        guard let data = try? encoder.encode(rules),
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }
    
    private func notifyRulesChanged() {
        ContentCleaner.shared.loadRules()
        NotificationCenter.default.post(name: .replaceRulesChanged, object: nil)
    }
    
    private func parseRules(from rawText: String) -> ParsedRulesResult {
        guard let data = rawText.data(using: .utf8) else {
            return sanitizeAndFilterUnsupportedRules(parseRulesFromTextLines(rawText))
        }
        
        if let direct = try? JSONDecoder().decode([ReplaceRule].self, from: data), !direct.isEmpty {
            return sanitizeAndFilterUnsupportedRules(direct)
        }
        
        if let object = try? JSONSerialization.jsonObject(with: data),
           let parsed = parseRulesFromJSONObject(object),
           !parsed.isEmpty {
            return sanitizeAndFilterUnsupportedRules(parsed)
        }
        
        return sanitizeAndFilterUnsupportedRules(parseRulesFromTextLines(rawText))
    }
    
    private func parseRulesFromJSONObject(_ object: Any) -> [ReplaceRule]? {
        if let array = object as? [[String: Any]] {
            return array.compactMap(ruleFromDictionary)
        }
        
        if let dict = object as? [String: Any] {
            let keys = ["rules", "data", "replaceRules", "list"]
            for key in keys {
                if let nested = dict[key] as? [[String: Any]] {
                    return nested.compactMap(ruleFromDictionary)
                }
            }
            if let single = ruleFromDictionary(dict) {
                return [single]
            }
        }
        
        return nil
    }
    
    private func ruleFromDictionary(_ dict: [String: Any]) -> ReplaceRule? {
        guard let pattern = firstNonEmptyString(
            in: dict,
            keys: ["pattern", "rule", "regex", "regExp", "match"]
        ) else {
            return nil
        }
        
        var rule = ReplaceRule()
        rule.ruleId = firstNonEmptyString(in: dict, keys: ["ruleId", "id", "_id"]) ?? UUID().uuidString
        rule.pattern = pattern
        rule.replacement = firstString(in: dict, keys: ["replacement", "replace", "replaceText", "replacementText"]) ?? ""
        rule.isEnabled = firstBool(in: dict, keys: ["isEnabled", "enabled", "enable"]) ?? true
        rule.scope = min(max(firstInt(in: dict, keys: ["scope", "useScope", "mode"]) ?? 0, 0), 2)
        if let groupName = firstNonEmptyString(in: dict, keys: ["groupName", "group", "name", "title"]) {
            rule.groupName = groupName
        }
        
        return rule
    }
    
    private func parseRulesFromTextLines(_ rawText: String) -> [ReplaceRule] {
        let lines = rawText.components(separatedBy: .newlines)
        var rules: [ReplaceRule] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }
            
            let parts = trimmed.components(separatedBy: "##")
            guard let pattern = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty else {
                continue
            }
            
            var rule = ReplaceRule()
            rule.pattern = pattern
            rule.replacement = parts.count > 1 ? parts[1...].joined(separator: "##") : ""
            rule.isEnabled = true
            rule.scope = 0
            rules.append(rule)
        }
        
        return rules
    }
    
    private func sanitizeRules(_ rules: [ReplaceRule]) -> [ReplaceRule] {
        return rules.compactMap { item in
            let pattern = item.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { return nil }
            
            var normalized = item
            normalized.pattern = pattern
            normalized.scope = min(max(item.scope, 0), 2)
            if normalized.ruleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.ruleId = UUID().uuidString
            }
            if let group = normalized.groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
                normalized.groupName = group
            } else {
                normalized.groupName = nil
            }
            return normalized
        }
    }
    
    private func sanitizeAndFilterUnsupportedRules(_ rules: [ReplaceRule]) -> ParsedRulesResult {
        let normalized = sanitizeRules(rules)
        var filtered: [ReplaceRule] = []
        var skippedJSCount = 0
        
        for rule in normalized {
            if isUnsupportedJavaScriptRule(rule) {
                skippedJSCount += 1
                continue
            }
            filtered.append(rule)
        }
        
        return ParsedRulesResult(rules: filtered, skippedJSCount: skippedJSCount)
    }
    
    private func isUnsupportedJavaScriptRule(_ rule: ReplaceRule) -> Bool {
        let replacement = rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return replacement.hasPrefix("@js:")
    }
    
    private func fingerprint(of rule: ReplaceRule) -> String {
        let group = rule.groupName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(rule.pattern)|\(rule.replacement)|\(rule.scope)|\(group)"
    }
    
    private func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                return value
            }
            if let number = dict[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }
    
    private func firstNonEmptyString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = firstString(in: dict, keys: [key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
    
    private func firstBool(in dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool {
                return value
            }
            if let value = dict[key] as? NSNumber {
                return value.boolValue
            }
            if let text = dict[key] as? String {
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["1", "true", "yes", "on"].contains(normalized) { return true }
                if ["0", "false", "no", "off"].contains(normalized) { return false }
            }
        }
        return nil
    }
    
    private func firstInt(in dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key] as? Int {
                return value
            }
            if let value = dict[key] as? Int64 {
                return Int(value)
            }
            if let value = dict[key] as? NSNumber {
                return value.intValue
            }
            if let text = dict[key] as? String, let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }
}

extension Notification.Name {
    static let replaceRulesChanged = Notification.Name("replaceRulesChanged")
}

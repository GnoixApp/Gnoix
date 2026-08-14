import Foundation
import SwiftSoup
import Kanna
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

class RuleAnalyzer {
    static let shared = RuleAnalyzer()

    private let variableLock = NSLock()
    private var variables: [String: String] = [:]

    private init() {}

    func resetVariables() {
        variableLock.lock()
        variables.removeAll()
        variableLock.unlock()
    }

    func replaceGetTokens(in text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        guard let regex = try? NSRegularExpression(pattern: "@get:\\{([^{}]+)\\}") else {
            return text
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        if matches.isEmpty { return text }

        var output = text
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range, in: output),
                  let keyRange = Range(match.range(at: 1), in: output) else { continue }
            let rawKey = String(output[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimQuotes(rawKey)
            let value = getVariable(key)
            output.replaceSubrange(fullRange, with: value)
        }
        return output
    }

    func analyzeList(html: String, rule: String, baseUrl: String = "") throws -> [Element] {
        let trimmedRule = normalizeStandaloneRule(rule)
        if let listJs = extractStandaloneJavaScriptRule(from: trimmedRule) {
            let jsValue = evaluateJavaScript(script: listJs, result: html, element: nil, baseUrl: baseUrl) ?? ""
            return elementsFromJavaScriptListValue(jsValue, baseUrl: baseUrl)
        }
        if hasPrefix("@XPath:", in: trimmedRule) || trimmedRule.hasPrefix("//") {
            let xpathRule = hasPrefix("@XPath:", in: trimmedRule) ? String(trimmedRule.dropFirst(7)) : trimmedRule
            return try xpathSelect(html: html, xpath: xpathRule)
        } else if hasPrefix("@Json:", in: trimmedRule) || trimmedRule.hasPrefix("$") {
            let jsonPath = hasPrefix("@Json:", in: trimmedRule) ? String(trimmedRule.dropFirst(6)) : trimmedRule
            return try jsonPathSelect(json: html, path: jsonPath)
        }

        let cssRule = normalizeCssPrefix(trimmedRule)
        let doc = try SwiftSoup.parse(html, baseUrl)
        guard let body = doc.body() else { return [] }
        do {
            return try selectElements(from: [body], rule: cssRule)
        } catch {
            if let listJs = extractStandaloneJavaScriptRuleLoosely(from: trimmedRule) {
                let jsValue = evaluateJavaScript(script: listJs, result: html, element: nil, baseUrl: baseUrl) ?? ""
                return elementsFromJavaScriptListValue(jsValue, baseUrl: baseUrl)
            }
            throw error
        }
    }

    private func normalizeStandaloneRule(_ rule: String) -> String {
        var trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
        }
        trimmed = trimmed
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "：", with: ":")
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractStandaloneJavaScriptRule(from rule: String) -> String? {
        let trimmed = normalizeStandaloneRule(rule)
        guard !trimmed.isEmpty else { return nil }

        if let pureJs = extractPureJsBlock(from: trimmed) {
            return pureJs
        }
        if let jsCall = splitAtJsSuffix(in: trimmed), jsCall.prefixRule.isEmpty {
            return jsCall.script
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("js:") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let regex = try? NSRegularExpression(pattern: #"^\s*@?\s*js\s*:\s*([\w\W]*)$"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: rule, options: [], range: NSRange(rule.startIndex..., in: rule)),
           match.numberOfRanges > 1,
           let scriptRange = Range(match.range(at: 1), in: rule) {
            return String(rule[scriptRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func extractStandaloneJavaScriptRuleLoosely(from rule: String) -> String? {
        let normalized = normalizeStandaloneRule(rule)
        guard !normalized.isEmpty else { return nil }

        if let strict = extractStandaloneJavaScriptRule(from: normalized) {
            return strict
        }

        let lower = normalized.lowercased()
        if lower.hasPrefix("@js"), let colon = normalized.firstIndex(of: ":") {
            let script = String(normalized[normalized.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return script.isEmpty ? nil : script
        }
        if lower.hasPrefix("js"), let colon = normalized.firstIndex(of: ":") {
            let script = String(normalized[normalized.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return script.isEmpty ? nil : script
        }

        return nil
    }

    private func elementsFromJavaScriptListValue(_ raw: String, baseUrl: String) -> [Element] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let jsonObject = parseJSONObject(trimmed) {
            if let array = jsonObject as? [Any] {
                return array.compactMap { makeJSONElement(node: $0) }
            }
            if let dict = jsonObject as? [String: Any] {
                let commonListKeys = ["list", "data", "items", "result", "books", "chapters"]
                for key in commonListKeys {
                    if let array = dict[key] as? [Any], !array.isEmpty {
                        return array.compactMap { makeJSONElement(node: $0) }
                    }
                }
                if let single = makeJSONElement(node: dict) {
                    return [single]
                }
            }
        }

        if let doc = try? SwiftSoup.parse(trimmed, baseUrl), let body = doc.body() {
            return body.children().array()
        }
        return []
    }

    func analyzeElementText(html: String, rule: String, baseUrl: String = "") -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasPrefix("@XPath:", in: trimmedRule) || trimmedRule.hasPrefix("//") {
            let xpathRule = hasPrefix("@XPath:", in: trimmedRule) ? String(trimmedRule.dropFirst(7)) : trimmedRule
            return xpathFirst(html: html, xpath: xpathRule)
        } else if hasPrefix("@Json:", in: trimmedRule) || trimmedRule.hasPrefix("$") {
            let jsonPath = hasPrefix("@Json:", in: trimmedRule) ? String(trimmedRule.dropFirst(6)) : trimmedRule
            return jsonPathString(json: html, path: jsonPath)
        }

        do {
            let doc = try SwiftSoup.parse(html)
            if let body = doc.body(),
               let value = try? analyzeElementCore(element: body, rule: trimmedRule, allowSideEffects: true, baseUrl: baseUrl),
               !value.isEmpty {
                return value
            }

            if let body = doc.body(),
               let first = try selectElements(from: [body], rule: normalizeCssPrefix(trimmedRule)).first {
                return (try? first.text()) ?? ""
            }
        } catch {
            print("Parse error: \(error)")
        }
        return ""
    }

    func analyzeElement(element: Element, rule: String, baseUrl: String = "") throws -> String {
        return try analyzeElementCore(element: element, rule: rule, allowSideEffects: true, baseUrl: baseUrl)
    }

    private func analyzeElementCore(element: Element, rule: String, allowSideEffects: Bool, baseUrl: String) throws -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRule.isEmpty {
            return try element.text()
        }

        var normalizedRule = normalizeCssPrefix(trimmedRule)
        if allowSideEffects {
            normalizedRule = try applyPutDirectives(in: normalizedRule, element: element, baseUrl: baseUrl)
        }
        let getOnlyValue = resolveGetOnlyValue(from: normalizedRule)
        if !getOnlyValue.isEmpty || normalizedRule.hasPrefix("@get:{") {
            return getOnlyValue
        }

        let hadGetToken = normalizedRule.contains("@get:{")
        normalizedRule = replaceGetTokens(in: normalizedRule)
        if hadGetToken && !normalizedRule.contains("@") && !normalizedRule.contains("##") {
            return normalizedRule
        }

        let replaceDirective = parseReplaceDirective(from: normalizedRule)
        normalizedRule = replaceDirective.rule

        if let inlineJsValue = try evaluateInlineJsPipeline(
            element: element,
            rule: normalizedRule,
            allowSideEffects: allowSideEffects,
            baseUrl: baseUrl
        ) {
            return applyReplaceDirective(inlineJsValue, directive: replaceDirective)
        }

        if let jsCall = splitAtJsSuffix(in: normalizedRule) {
            let baseValue: String
            if jsCall.prefixRule.isEmpty {
                baseValue = (try? element.text()) ?? ""
            } else {
                baseValue = try analyzeElementCore(element: element, rule: jsCall.prefixRule, allowSideEffects: false, baseUrl: baseUrl)
            }
            let jsValue = evaluateJavaScript(script: jsCall.script, result: baseValue, element: element, baseUrl: baseUrl) ?? baseValue
            return applyReplaceDirective(jsValue, directive: replaceDirective)
        }

        if let pureJs = extractPureJsBlock(from: normalizedRule) {
            let seed = (try? element.text()) ?? ""
            let jsValue = evaluateJavaScript(script: pureJs, result: seed, element: element, baseUrl: baseUrl) ?? seed
            return applyReplaceDirective(jsValue, directive: replaceDirective)
        }

        if let composed = try evaluateCompositeRule(element: element, rule: normalizedRule, allowSideEffects: allowSideEffects, baseUrl: baseUrl) {
            return applyReplaceDirective(composed, directive: replaceDirective)
        }

        let parts = splitTopLevel(normalizedRule, by: "@")
        if parts.count == 1 {
            let value = try getElementContent(element: element, rule: normalizedRule, baseUrl: baseUrl)
            return applyReplaceDirective(value, directive: replaceDirective)
        }

        var currentElement: Element = element
        for part in parts.dropLast() {
            let selector = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if selector.isEmpty {
                continue
            }
            if let next = try selectElement(element: currentElement, rule: selector) {
                currentElement = next
            } else {
                return ""
            }
        }

        let value = try getElementContent(element: currentElement, rule: parts.last ?? "", baseUrl: baseUrl)
        return applyReplaceDirective(value, directive: replaceDirective)
    }

    private func evaluateCompositeRule(element: Element, rule: String, allowSideEffects: Bool, baseUrl: String) throws -> String? {
        let orParts = splitTopLevel(rule, by: "||")
        if orParts.count > 1 {
            for part in orParts {
                let value = try analyzeElementCore(element: element, rule: part, allowSideEffects: allowSideEffects, baseUrl: baseUrl)
                if !value.isEmpty {
                    return value
                }
            }
            return ""
        }

        let mergeParts = splitTopLevel(rule, by: "%%")
        if mergeParts.count > 1 {
            var values: [String] = []
            for part in mergeParts {
                if let literal = resolveLiteralSegment(part, element: element) {
                    values.append(literal)
                } else {
                    let value = try analyzeElementCore(element: element, rule: part, allowSideEffects: allowSideEffects, baseUrl: baseUrl)
                    values.append(value)
                }
            }
            return values.joined()
        }

        let andParts = splitTopLevel(rule, by: "&&")
        if andParts.count > 1 {
            return try evaluateAndRule(element: element, parts: andParts, allowSideEffects: allowSideEffects, baseUrl: baseUrl)
        }

        return nil
    }

    private func resolveLiteralSegment(_ part: String, element: Element) -> String? {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2) ||
            (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2) {
            return String(trimmed.dropFirst().dropLast())
        }

        let likelyRuleTokens = ["@", ".", "#", "[", "]", "/", "$", "(", ")", ":"]
        if likelyRuleTokens.contains(where: { trimmed.contains($0) }) || ["text", "html", "tag"].contains(trimmed) {
            return nil
        }

        if let selected = try? element.select(trimmed), selected.first() != nil {
            return nil
        }

        return trimmed
    }

    private func evaluateAndRule(element: Element, parts: [String], allowSideEffects: Bool, baseUrl: String) throws -> String {
        var current = element
        for index in parts.indices {
            let part = parts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty {
                continue
            }

            if index == parts.count - 1 {
                return try analyzeElementCore(element: current, rule: part, allowSideEffects: allowSideEffects, baseUrl: baseUrl)
            }

            if let next = try selectElement(element: current, rule: part) {
                current = next
                continue
            }

            let value = try analyzeElementCore(element: current, rule: part, allowSideEffects: allowSideEffects, baseUrl: baseUrl)
            guard !value.isEmpty else { return "" }
            if let parsed = try? SwiftSoup.parse(value).body()?.children().first() {
                current = parsed
            } else {
                return value
            }
        }
        return ""
    }

    private func splitTopLevel(_ rule: String, by delimiter: String) -> [String] {
        guard !rule.isEmpty, !delimiter.isEmpty else { return [rule] }

        var result: [String] = []
        var buffer = ""
        var singleQuoteOpen = false
        var doubleQuoteOpen = false
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var index = rule.startIndex

        while index < rule.endIndex {
            let char = rule[index]

            if !singleQuoteOpen && !doubleQuoteOpen {
                if char == "(" {
                    parenDepth += 1
                } else if char == ")" {
                    parenDepth = max(0, parenDepth - 1)
                } else if char == "[" {
                    bracketDepth += 1
                } else if char == "]" {
                    bracketDepth = max(0, bracketDepth - 1)
                } else if char == "{" {
                    braceDepth += 1
                } else if char == "}" {
                    braceDepth = max(0, braceDepth - 1)
                }
            }

            if char == "'" && !doubleQuoteOpen {
                singleQuoteOpen.toggle()
            } else if char == "\"" && !singleQuoteOpen {
                doubleQuoteOpen.toggle()
            }

            let canSplit = !singleQuoteOpen && !doubleQuoteOpen && parenDepth == 0 && bracketDepth == 0 && braceDepth == 0
            if canSplit && rule[index...].hasPrefix(delimiter) {
                result.append(buffer)
                buffer.removeAll(keepingCapacity: true)
                index = rule.index(index, offsetBy: delimiter.count)
                continue
            }

            buffer.append(char)
            index = rule.index(after: index)
        }

        result.append(buffer)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func analyzeAttribute(element: Element, rule: String) throws -> String {
        let parts = splitTopLevel(rule, by: "@")
        let selector = parts.first ?? ""
        let attr = parts.count > 1 ? parts[1] : "href"

        guard let selectedElement = try selectElement(element: element, rule: selector) else {
            return ""
        }

        if attr == "text" {
            return try selectedElement.text()
        } else if attr == "html" {
            return try selectedElement.html()
        } else {
            return try selectedElement.attr(attr)
        }
    }

    private func xpathSelect(html: String, xpath: String) throws -> [Element] {
        let doc = try HTML(html: html, encoding: .utf8)
        let xpathDoc = doc.xpath(xpath)

        var elements: [Element] = []
        for node in xpathDoc {
            if let htmlStr = node.toHTML,
               let el = try? SwiftSoup.parse(htmlStr).body()?.children().first() {
                elements.append(el)
            }
        }
        return elements
    }

    private func xpathFirst(html: String, xpath: String) -> String {
        do {
            let doc = try HTML(html: html, encoding: .utf8)
            if let node = doc.xpath(xpath).first {
                return node.text ?? node.content ?? ""
            }
        } catch {
            print("XPath error: \(error)")
        }
        return ""
    }

    private func jsonPathSelect(json: String, path: String) throws -> [Element] {
        guard let jsonObject = parseJSONObject(json) else {
            return []
        }
        let nodes = jsonPathNodes(from: jsonObject, path: path)
        var elements: [Element] = []
        for node in nodes {
            if let array = node as? [Any] {
                // 兼容 Legado: $.rows 也应当迭代数组项（不强制写 $.rows[*]）。
                let flattened = array.compactMap { makeJSONElement(node: $0) }
                if !flattened.isEmpty {
                    elements.append(contentsOf: flattened)
                    continue
                }
            }
            if let element = makeJSONElement(node: node) {
                elements.append(element)
            }
        }
        return elements
    }

    private func jsonPathString(json: String, path: String) -> String {
        guard let jsonObject = parseJSONObject(json) else {
            return ""
        }
        let nodes = jsonPathNodes(from: jsonObject, path: path)
        guard let first = nodes.first else { return "" }
        return jsonNodeToString(first)
    }

    private func parseJSONObject(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private enum JSONPathToken {
        case child(String)
        case wildcard
        case index(Int)
        case indexWildcard
        case filter(String)
        case recursive(String)
        case recursiveWildcard
    }

    private func jsonPathNodes(from object: Any, path: String) -> [Any] {
        let tokens = parseJSONPath(path)
        if tokens.isEmpty {
            return [object]
        }

        var current: [Any] = [object]
        for token in tokens {
            switch token {
            case .child(let key):
                current = current.flatMap { node in
                    if let dict = node as? [String: Any] {
                        if let direct = dict[key] {
                            return [direct]
                        }
                        if let fuzzy = fuzzyLookupJSONValue(in: dict, key: key) {
                            return [fuzzy]
                        }
                        return []
                    }
                    if let array = node as? [Any] {
                        return array.compactMap { item in
                            guard let dict = item as? [String: Any] else { return nil }
                            if let direct = dict[key] {
                                return direct
                            }
                            return fuzzyLookupJSONValue(in: dict, key: key)
                        }
                    }
                    return []
                }
            case .wildcard:
                current = current.flatMap { node in
                    if let dict = node as? [String: Any] {
                        return Array(dict.values)
                    }
                    if let array = node as? [Any] {
                        return array
                    }
                    return []
                }
            case .index(let index):
                current = current.compactMap { node in
                    guard let array = node as? [Any], !array.isEmpty else { return nil }
                    let normalized = index >= 0 ? index : array.count + index
                    guard normalized >= 0 && normalized < array.count else { return nil }
                    return array[normalized]
                }
            case .indexWildcard:
                current = current.flatMap { node in
                    if let array = node as? [Any] {
                        return array
                    }
                    return []
                }
            case .filter(let expression):
                current = current.flatMap { node in
                    if let array = node as? [Any] {
                        return array.filter { evaluateJSONPathFilter(expression: expression, node: $0) }
                    }
                    if let dict = node as? [String: Any],
                       evaluateJSONPathFilter(expression: expression, node: dict) {
                        return [dict]
                    }
                    return []
                }
            case .recursive(let key):
                current = current.flatMap { recursiveCollect(node: $0, key: key) }
            case .recursiveWildcard:
                current = current.flatMap { recursiveCollect(node: $0, key: "*") }
            }
        }
        return current
    }

    private func recursiveCollect(node: Any, key: String) -> [Any] {
        var result: [Any] = []
        let normalizedTarget = normalizeJSONLookupKey(key)
        if let dict = node as? [String: Any] {
            for (k, value) in dict {
                if key == "*" || normalizeJSONLookupKey(k) == normalizedTarget {
                    result.append(value)
                }
                result.append(contentsOf: recursiveCollect(node: value, key: key))
            }
        } else if let array = node as? [Any] {
            for value in array {
                if key == "*" {
                    result.append(value)
                }
                result.append(contentsOf: recursiveCollect(node: value, key: key))
            }
        }
        return result
    }

    private func parseJSONPath(_ path: String) -> [JSONPathToken] {
        var cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("@json:") {
            cleaned = String(cleaned.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned == "$" {
            return []
        }
        if !cleaned.hasPrefix("$") {
            cleaned = "$." + cleaned
        }

        var tokens: [JSONPathToken] = []
        var index = cleaned.index(after: cleaned.startIndex)

        while index < cleaned.endIndex {
            if cleaned[index...].hasPrefix("..") {
                index = cleaned.index(index, offsetBy: 2)
                if index < cleaned.endIndex, cleaned[index] == "*" {
                    tokens.append(.recursiveWildcard)
                    index = cleaned.index(after: index)
                    continue
                }
                let name = readJSONIdentifier(from: cleaned, index: &index)
                if !name.isEmpty {
                    tokens.append(.recursive(name))
                }
                continue
            }

            let ch = cleaned[index]
            if ch == "." {
                index = cleaned.index(after: index)
                if index < cleaned.endIndex, cleaned[index] == "*" {
                    tokens.append(.wildcard)
                    index = cleaned.index(after: index)
                    continue
                }
                let name = readJSONIdentifier(from: cleaned, index: &index)
                if !name.isEmpty {
                    tokens.append(.child(name))
                }
                continue
            }

            if ch == "[" {
                let start = cleaned.index(after: index)
                guard let end = findJSONPathBracketEnd(in: cleaned, from: start) else { break }
                let content = String(cleaned[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if content == "*" {
                    tokens.append(.indexWildcard)
                } else if content.hasPrefix("?("), content.hasSuffix(")"), content.count > 3 {
                    let expression = String(content.dropFirst(2).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !expression.isEmpty {
                        tokens.append(.filter(expression))
                    }
                } else if let idx = Int(content) {
                    tokens.append(.index(idx))
                } else if (content.hasPrefix("'") && content.hasSuffix("'")) ||
                    (content.hasPrefix("\"") && content.hasSuffix("\"")) {
                    let name = String(content.dropFirst().dropLast())
                    tokens.append(.child(name))
                }
                index = cleaned.index(after: end)
                continue
            }

            index = cleaned.index(after: index)
        }

        return tokens
    }

    private func readJSONIdentifier(from text: String, index: inout String.Index) -> String {
        let start = index
        while index < text.endIndex {
            let ch = text[index]
            if ch == "." || ch == "[" || ch == "]" {
                break
            }
            index = text.index(after: index)
        }
        return String(text[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findJSONPathBracketEnd(in text: String, from start: String.Index) -> String.Index? {
        var singleQuoteOpen = false
        var doubleQuoteOpen = false
        var parenDepth = 0
        var bracketDepth = 1
        var cursor = start

        while cursor < text.endIndex {
            let ch = text[cursor]
            if ch == "'" && !doubleQuoteOpen {
                singleQuoteOpen.toggle()
            } else if ch == "\"" && !singleQuoteOpen {
                doubleQuoteOpen.toggle()
            }

            if !singleQuoteOpen && !doubleQuoteOpen {
                if ch == "(" {
                    parenDepth += 1
                } else if ch == ")" {
                    parenDepth = max(0, parenDepth - 1)
                } else if ch == "[" {
                    bracketDepth += 1
                } else if ch == "]" {
                    bracketDepth -= 1
                    if bracketDepth == 0 && parenDepth == 0 {
                        return cursor
                    }
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private func evaluateJSONPathFilter(expression: String, node: Any) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let orParts = splitFilterExpression(trimmed, separator: "||")
        if orParts.count > 1 {
            return orParts.contains { evaluateJSONPathFilter(expression: $0, node: node) }
        }
        let andParts = splitFilterExpression(trimmed, separator: "&&")
        if andParts.count > 1 {
            return andParts.allSatisfy { evaluateJSONPathFilter(expression: $0, node: node) }
        }

        if let regex = try? NSRegularExpression(pattern: #"^@\.([A-Za-z0-9_\-\.]+)\s*=~\s*/(.+)/([a-zA-Z]*)$"#, options: []),
           let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges == 4,
           let keyRange = Range(match.range(at: 1), in: trimmed),
           let patternRange = Range(match.range(at: 2), in: trimmed),
           let flagsRange = Range(match.range(at: 3), in: trimmed) {
            let keyPath = String(trimmed[keyRange])
            let pattern = String(trimmed[patternRange])
            let flags = String(trimmed[flagsRange]).lowercased()
            guard let value = jsonValue(for: keyPath, in: node) else { return false }
            let target = jsonNodeToString(value)
            var options: NSRegularExpression.Options = []
            if flags.contains("i") {
                options.insert(.caseInsensitive)
            }
            guard let filterRegex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
            return filterRegex.firstMatch(in: target, options: [], range: NSRange(target.startIndex..., in: target)) != nil
        }

        if let regex = try? NSRegularExpression(pattern: #"^@\.([A-Za-z0-9_\-\.]+)\s*(==|=|!=)\s*(.+)$"#, options: []),
           let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges == 4,
           let keyRange = Range(match.range(at: 1), in: trimmed),
           let opRange = Range(match.range(at: 2), in: trimmed),
           let valueRange = Range(match.range(at: 3), in: trimmed) {
            let keyPath = String(trimmed[keyRange])
            let op = String(trimmed[opRange])
            let rhsRaw = String(trimmed[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = parseJSONFilterLiteral(rhsRaw)
            guard let lhs = jsonValue(for: keyPath, in: node) else { return false }
            let equals = compareJSONFilterValues(lhs: lhs, rhs: rhs)
            return op == "!=" ? !equals : equals
        }

        if let regex = try? NSRegularExpression(pattern: #"^@\.([A-Za-z0-9_\-\.]+)$"#, options: []),
           let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges == 2,
           let keyRange = Range(match.range(at: 1), in: trimmed) {
            let keyPath = String(trimmed[keyRange])
            if let value = jsonValue(for: keyPath, in: node) {
                let stringValue = jsonNodeToString(value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !(stringValue.isEmpty || stringValue == "false" || stringValue == "null" || stringValue == "0")
            }
        }

        return false
    }

    private func splitFilterExpression(_ expression: String, separator: String) -> [String] {
        guard !expression.isEmpty, !separator.isEmpty else { return [expression] }
        var output: [String] = []
        var buffer = ""
        var singleQuoteOpen = false
        var doubleQuoteOpen = false
        var slashRegexOpen = false
        var index = expression.startIndex

        while index < expression.endIndex {
            let ch = expression[index]

            if ch == "'" && !doubleQuoteOpen && !slashRegexOpen {
                singleQuoteOpen.toggle()
            } else if ch == "\"" && !singleQuoteOpen && !slashRegexOpen {
                doubleQuoteOpen.toggle()
            } else if ch == "/" && !singleQuoteOpen && !doubleQuoteOpen {
                slashRegexOpen.toggle()
            }

            let canSplit = !singleQuoteOpen && !doubleQuoteOpen && !slashRegexOpen
            if canSplit && expression[index...].hasPrefix(separator) {
                output.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                buffer.removeAll(keepingCapacity: true)
                index = expression.index(index, offsetBy: separator.count)
                continue
            }

            buffer.append(ch)
            index = expression.index(after: index)
        }
        output.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        return output.filter { !$0.isEmpty }
    }

    private func jsonValue(for keyPath: String, in node: Any) -> Any? {
        let keys = keyPath.split(separator: ".").map(String.init)
        guard !keys.isEmpty else { return nil }
        var current: Any? = node
        for key in keys {
            if let dict = current as? [String: Any] {
                if let direct = dict[key] {
                    current = direct
                    continue
                }
                if let fuzzy = fuzzyLookupJSONValue(in: dict, key: key) {
                    current = fuzzy
                    continue
                }
                return nil
            } else {
                return nil
            }
        }
        return current
    }

    private func fuzzyLookupJSONValue(in dict: [String: Any], key: String) -> Any? {
        let normalizedTarget = normalizeJSONLookupKey(key)
        guard !normalizedTarget.isEmpty else { return nil }
        for (dictKey, value) in dict {
            if normalizeJSONLookupKey(dictKey) == normalizedTarget {
                return value
            }
        }
        return nil
    }

    private func normalizeJSONLookupKey(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return "" }
        let scalars = lowered.unicodeScalars.filter { scalar in
            scalar != "_" && scalar != "-" && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func parseJSONFilterLiteral(_ raw: String) -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2) ||
            (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2) {
            return String(trimmed.dropFirst().dropLast())
        }
        let lower = trimmed.lowercased()
        if lower == "true" { return true }
        if lower == "false" { return false }
        if lower == "null" { return NSNull() }
        if let int = Int(trimmed) { return int }
        if let double = Double(trimmed) { return double }
        return trimmed
    }

    private func compareJSONFilterValues(lhs: Any, rhs: Any) -> Bool {
        if lhs is NSNull, rhs is NSNull { return true }
        if lhs is NSNull || rhs is NSNull { return false }

        if let l = lhs as? NSNumber, let r = rhs as? NSNumber {
            return l.doubleValue == r.doubleValue
        }
        if let l = lhs as? Int, let r = rhs as? Int {
            return l == r
        }
        if let l = lhs as? Double, let r = rhs as? Double {
            return l == r
        }
        if let l = lhs as? Bool, let r = rhs as? Bool {
            return l == r
        }

        return jsonNodeToString(lhs) == jsonNodeToString(rhs)
    }

    private func jsonNodeToString(_ node: Any) -> String {
        if let value = node as? String { return value }
        if let number = node as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if JSONSerialization.isValidJSONObject(node),
           let data = try? JSONSerialization.data(withJSONObject: node),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }
        return "\(node)"
    }

    private func makeJSONElement(node: Any) -> Element? {
        let payload = jsonNodeToString(node)
        let payloadEscaped = escapeHTMLAttribute(payload)
        let inner: String

        if let dict = node as? [String: Any] {
            inner = dictToHTML(dict)
        } else if let array = node as? [Any] {
            inner = array.enumerated().map { idx, item in
                let tag = "item\(idx)"
                let value = escapeHTMLText(jsonNodeToString(item))
                return "<\(tag)>\(value)</\(tag)>"
            }.joined()
        } else {
            inner = escapeHTMLText(payload)
        }

        let html = "<div data-json=\"\(payloadEscaped)\">\(inner)</div>"
        return try? SwiftSoup.parseBodyFragment(html).body()?.children().first()
    }

    private func dictToHTML(_ dict: [String: Any]) -> String {
        dict.map { key, value in
            let safeKey = safeTagName(key)
            let text = escapeHTMLText(jsonNodeToString(value))
            return "<\(safeKey)>\(text)</\(safeKey)>"
        }.joined()
    }

    private func safeTagName(_ key: String) -> String {
        let sanitized = key.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        if sanitized.isEmpty { return "item" }
        if let first = sanitized.first, first.isNumber {
            return "k_\(sanitized)"
        }
        return sanitized
    }

    private func escapeHTMLText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeHTMLAttribute(_ text: String) -> String {
        escapeHTMLText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func selectElement(element: Element, rule: String) throws -> Element? {
        if rule.isEmpty {
            return element
        }
        return try selectElements(from: [element], rule: rule).first
    }

    private enum ElementCombineMode {
        case append
        case firstNonEmpty
        case interleave
    }

    private func selectElements(from roots: [Element], rule: String) throws -> [Element] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return roots }

        let (parts, mode) = splitElementCompositeRule(trimmed)
        if parts.count == 1 {
            return try evaluateElementChain(from: roots, rule: parts[0])
        }

        switch mode {
        case .firstNonEmpty:
            for part in parts {
                let items = try evaluateElementChain(from: roots, rule: part)
                if !items.isEmpty {
                    return items
                }
            }
            return []
        case .interleave:
            let groups = try parts.map { try evaluateElementChain(from: roots, rule: $0) }
            guard let maxCount = groups.map(\.count).max(), maxCount > 0 else { return [] }
            var merged: [Element] = []
            for i in 0..<maxCount {
                for group in groups where i < group.count {
                    merged.append(group[i])
                }
            }
            return deduplicateElements(merged)
        case .append:
            var merged: [Element] = []
            for part in parts {
                merged.append(contentsOf: try evaluateElementChain(from: roots, rule: part))
            }
            return deduplicateElements(merged)
        }
    }

    private func splitElementCompositeRule(_ rule: String) -> ([String], ElementCombineMode) {
        let orParts = splitTopLevel(rule, by: "||")
        if orParts.count > 1 {
            return (orParts, .firstNonEmpty)
        }
        let mergeParts = splitTopLevel(rule, by: "%%")
        if mergeParts.count > 1 {
            return (mergeParts, .interleave)
        }
        let andParts = splitTopLevel(rule, by: "&&")
        if andParts.count > 1 {
            return (andParts, .append)
        }
        return ([rule], .append)
    }

    private func evaluateElementChain(from roots: [Element], rule: String) throws -> [Element] {
        let chainParts = splitTopLevel(rule, by: "@")
        var current = roots
        for part in chainParts {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            var next: [Element] = []
            for root in current {
                next.append(contentsOf: try selectElementsSingle(on: root, token: token))
            }
            current = deduplicateElements(next)
            if current.isEmpty {
                break
            }
        }
        return current
    }

    private struct SelectorToken {
        let mode: SelectorMode
        let query: String
        let indexExpression: String?
        let exclude: Bool
    }

    private enum SelectorMode {
        case css
        case className
        case id
        case tag
        case text
        case children
    }

    private func selectElementsSingle(on root: Element, token: String) throws -> [Element] {
        let parsed = parseSelectorToken(token)

        var selected: [Element]
        switch parsed.mode {
        case .children:
            selected = root.children().array()
        case .className:
            selected = selectElementsByClassExpression(on: root, expression: parsed.query)
        case .id:
            if let found = try? root.getElementById(parsed.query) {
                selected = [found]
            } else {
                selected = []
            }
        case .tag:
            selected = (try? root.getElementsByTag(parsed.query).array()) ?? []
        case .text:
            selected = (try? root.getElementsContainingOwnText(parsed.query).array()) ?? []
        case .css:
            if parsed.query.isEmpty {
                selected = [root]
            } else {
                selected = try root.select(parsed.query).array()
            }
        }

        return applyIndexExpression(
            selected,
            expression: parsed.indexExpression,
            exclude: parsed.exclude
        )
    }

    private func selectElementsByClassExpression(on root: Element, expression: String) -> [Element] {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Legado 常见写法: class.lb fk -> 需要同时命中 lb 与 fk 两个 class。
        var normalized = trimmed
        if !normalized.contains(where: { $0.isWhitespace }),
           normalized.contains("."),
           !normalized.hasPrefix(".") {
            normalized = normalized.replacingOccurrences(of: ".", with: " ")
        }

        let classNames = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let first = classNames.first else { return [] }
        let candidates = (try? root.getElementsByClass(first).array()) ?? []
        guard classNames.count > 1 else { return candidates }

        let required = Array(classNames.dropFirst())
        return candidates.filter { element in
            required.allSatisfy { element.hasClass($0) }
        }
    }

    private func parseSelectorToken(_ rawToken: String) -> SelectorToken {
        var token = normalizeCssPrefix(rawToken).trimmingCharacters(in: .whitespacesAndNewlines)
        var indexExpression: String?
        var exclude = false

        if let bracket = trailingBracketRange(in: token) {
            let expr = String(token[token.index(after: bracket.lowerBound)..<token.index(before: bracket.upperBound)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            token.removeSubrange(bracket)
            if !expr.isEmpty {
                if expr.hasPrefix("!") {
                    exclude = true
                    indexExpression = String(expr.dropFirst())
                } else {
                    indexExpression = expr
                }
            }
        }

        if indexExpression == nil,
           let bangRange = trailingBangIndexRange(in: token) {
            let expr = String(token[bangRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isIndexExpression(expr) {
                exclude = true
                indexExpression = expr
                token = String(token[..<bangRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if indexExpression == nil,
           let dotRange = token.range(of: #"\.(-?\d+(?::-?\d+(?::-?\d+)?)?)$"#, options: .regularExpression) {
            let expr = String(token[token.index(after: dotRange.lowerBound)..<dotRange.upperBound])
            if isIndexExpression(expr) {
                indexExpression = expr
                token = String(token[..<dotRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let prefixRegex = #"^(class|id|tag|text|children)\.(.+)$"#
        if let regex = try? NSRegularExpression(pattern: prefixRegex, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
           match.numberOfRanges == 3,
           let kindRange = Range(match.range(at: 1), in: token),
           let queryRange = Range(match.range(at: 2), in: token) {
            let kind = String(token[kindRange]).lowercased()
            let query = String(token[queryRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case "class":
                return SelectorToken(mode: .className, query: query, indexExpression: indexExpression, exclude: exclude)
            case "id":
                return SelectorToken(mode: .id, query: query, indexExpression: indexExpression, exclude: exclude)
            case "tag":
                return SelectorToken(mode: .tag, query: query, indexExpression: indexExpression, exclude: exclude)
            case "text":
                return SelectorToken(mode: .text, query: query, indexExpression: indexExpression, exclude: exclude)
            case "children":
                return SelectorToken(mode: .children, query: query, indexExpression: indexExpression, exclude: exclude)
            default:
                break
            }
        }

        if token.lowercased() == "children" {
            return SelectorToken(mode: .children, query: "", indexExpression: indexExpression, exclude: exclude)
        }

        return SelectorToken(mode: .css, query: token, indexExpression: indexExpression, exclude: exclude)
    }

    private func trailingBracketRange(in token: String) -> Range<String.Index>? {
        guard let last = token.last, last == "]" else { return nil }
        var depth = 0
        var idx = token.index(before: token.endIndex)
        while true {
            let ch = token[idx]
            if ch == "]" {
                depth += 1
            } else if ch == "[" {
                depth -= 1
                if depth == 0 {
                    return idx..<token.endIndex
                }
            }
            if idx == token.startIndex { break }
            idx = token.index(before: idx)
        }
        return nil
    }

    private func trailingBangIndexRange(in token: String) -> Range<String.Index>? {
        var singleQuoteOpen = false
        var doubleQuoteOpen = false
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0

        var idx = token.index(before: token.endIndex)
        while true {
            let ch = token[idx]
            if ch == "'" && !doubleQuoteOpen {
                singleQuoteOpen.toggle()
            } else if ch == "\"" && !singleQuoteOpen {
                doubleQuoteOpen.toggle()
            }

            if !singleQuoteOpen && !doubleQuoteOpen {
                if ch == ")" {
                    parenDepth += 1
                } else if ch == "(" {
                    parenDepth = max(0, parenDepth - 1)
                } else if ch == "]" {
                    bracketDepth += 1
                } else if ch == "[" {
                    bracketDepth = max(0, bracketDepth - 1)
                } else if ch == "}" {
                    braceDepth += 1
                } else if ch == "{" {
                    braceDepth = max(0, braceDepth - 1)
                }
            }

            if ch == "!" && !singleQuoteOpen && !doubleQuoteOpen && parenDepth == 0 && bracketDepth == 0 && braceDepth == 0 {
                let next = token.index(after: idx)
                return idx..<next
            }

            if idx == token.startIndex { break }
            idx = token.index(before: idx)
        }
        return nil
    }

    private func isIndexExpression(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 兼容 Legado 的多种索引写法：
        // 1) 0,1,2
        // 2) 0:10 / 0:10:2
        // 3) 0:1:2:3 (部分书源用 ":" 作为索引列表分隔符)
        let pattern = #"^-?\d+(?::-?\d+)*(?:\s*,\s*-?\d+(?::-?\d+)*)*$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    private func applyIndexExpression(_ elements: [Element], expression: String?, exclude: Bool) -> [Element] {
        guard let expression,
              !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !elements.isEmpty else {
            return elements
        }

        let indices = resolveIndices(expression: expression, count: elements.count)
        if indices.isEmpty {
            return exclude ? elements : []
        }

        if exclude {
            let blocked = Set(indices)
            return elements.enumerated().compactMap { idx, element in
                blocked.contains(idx) ? nil : element
            }
        }

        var output: [Element] = []
        var seen = Set<Int>()
        for idx in indices where idx >= 0 && idx < elements.count {
            if seen.insert(idx).inserted {
                output.append(elements[idx])
            }
        }
        return output
    }

    private func resolveIndices(expression: String, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let segments = expression
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [Int] = []
        for segment in segments {
            if segment.contains(":") {
                let parts = segment.split(separator: ":", omittingEmptySubsequences: false)
                let partValues = parts.compactMap { Int(String($0)) }

                // Legado 常见写法: 0:1:2:3... 表示“排除这些索引”，不是 range。
                if parts.count > 3, partValues.count == parts.count {
                    for raw in partValues {
                        let normalized = raw >= 0 ? raw : count + raw
                        if normalized >= 0 && normalized < count {
                            result.append(normalized)
                        }
                    }
                    continue
                }

                if parts.count >= 2 {
                    let startRaw = Int(String(parts[0]))
                    let endRaw = Int(String(parts[1]))
                    let stepRaw = parts.count > 2 ? Int(String(parts[2])) : nil
                    let step = max(1, abs(stepRaw ?? 1))

                    let start = normalizeRangeBoundary(startRaw, defaultValue: 0, count: count)
                    let end = normalizeRangeBoundary(endRaw, defaultValue: count - 1, count: count)

                    if start <= end {
                        var cursor = start
                        while cursor <= end {
                            result.append(cursor)
                            cursor += step
                        }
                    } else {
                        var cursor = start
                        while cursor >= end {
                            result.append(cursor)
                            cursor -= step
                        }
                    }
                }
            } else if let index = Int(segment) {
                let normalized = index >= 0 ? index : count + index
                if normalized >= 0 && normalized < count {
                    result.append(normalized)
                }
            }
        }

        return result
    }

    private func normalizeRangeBoundary(_ raw: Int?, defaultValue: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let fallback = min(max(defaultValue, 0), count - 1)
        guard let raw else { return fallback }
        if raw >= 0 {
            return min(max(raw, 0), count - 1)
        }
        let converted = count + raw
        return min(max(converted, 0), count - 1)
    }

    private func deduplicateElements(_ elements: [Element]) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        var output: [Element] = []
        for element in elements {
            let key = ObjectIdentifier(element)
            if seen.insert(key).inserted {
                output.append(element)
            }
        }
        return output
    }

    private func getElementContent(element: Element, rule: String, baseUrl: String) throws -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRule.isEmpty {
            return try element.text()
        }

        if trimmedRule == "text" {
            return try element.text()
        } else if trimmedRule == "textNodes" || trimmedRule == "@textNodes" || trimmedRule == "ownText" {
            return element.ownText()
        } else if trimmedRule == "html" {
            return try element.html()
        } else if trimmedRule == "all" {
            return try element.outerHtml()
        } else if trimmedRule == "tag" {
            return element.tagName()
        }

        if trimmedRule.lowercased().hasPrefix("js:") {
            let script = String(trimmedRule.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            let seed = (try? element.text()) ?? ""
            return evaluateJavaScript(script: script, result: seed, element: element, baseUrl: baseUrl) ?? ""
        }

        if hasPrefix("@Json:", in: trimmedRule) || trimmedRule.hasPrefix("$") {
            let jsonPath = hasPrefix("@Json:", in: trimmedRule) ? String(trimmedRule.dropFirst(6)) : trimmedRule
            let payload = extractJSONPayload(from: element)
            return jsonPathString(json: payload, path: jsonPath)
        }

        let selected = try selectElements(from: [element], rule: trimmedRule)
        if !selected.isEmpty {
            if selected.count > 1 {
                return try selected.map { try $0.text() }.joined(separator: "\n")
            }
            if let first = selected.first {
                return try first.text()
            }
        }

        if let attrValue = try? element.attr(trimmedRule), !attrValue.isEmpty {
            return attrValue
        }

        return try element.text()
    }

    private func extractJSONPayload(from element: Element) -> String {
        if let jsonPayload = try? element.attr("data-json"), !jsonPayload.isEmpty {
            return jsonPayload
        }

        let text = ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if (text.hasPrefix("{") && text.hasSuffix("}")) || (text.hasPrefix("[") && text.hasSuffix("]")) {
            return text
        }

        return (try? element.outerHtml()) ?? text
    }

    private func normalizeCssPrefix(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("@css:") {
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lower.hasPrefix("@@") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func hasPrefix(_ prefix: String, in value: String) -> Bool {
        value.lowercased().hasPrefix(prefix.lowercased())
    }

    private struct InlineJsSegment {
        let isScript: Bool
        let value: String
    }

    private func evaluateInlineJsPipeline(
        element: Element,
        rule: String,
        allowSideEffects: Bool,
        baseUrl: String
    ) throws -> String? {
        guard let segments = parseInlineJsSegments(rule), segments.contains(where: { $0.isScript }) else {
            return nil
        }

        let extracted = extractJSONPayload(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = extracted
        if payload.isEmpty {
            payload = ((try? element.outerHtml()) ?? (try? element.text())) ?? ""
        }
        for segment in segments {
            let trimmed = segment.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if segment.isScript {
                payload = evaluateJavaScript(script: trimmed, result: payload, element: element, baseUrl: baseUrl) ?? payload
                continue
            }
            payload = try evaluateInlineRuleSegment(
                element: element,
                payload: payload,
                segment: trimmed,
                allowSideEffects: allowSideEffects,
                baseUrl: baseUrl
            )
        }
        return payload
    }

    private func parseInlineJsSegments(_ rule: String) -> [InlineJsSegment]? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().contains("<js>"), trimmed.lowercased().contains("</js>") else {
            return nil
        }

        var segments: [InlineJsSegment] = []
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            guard let open = trimmed.range(of: "<js>", options: [.caseInsensitive], range: cursor..<trimmed.endIndex) else {
                let tail = String(trimmed[cursor..<trimmed.endIndex])
                if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(InlineJsSegment(isScript: false, value: tail))
                }
                break
            }
            let leading = String(trimmed[cursor..<open.lowerBound])
            if !leading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(InlineJsSegment(isScript: false, value: leading))
            }

            guard let close = trimmed.range(of: "</js>", options: [.caseInsensitive], range: open.upperBound..<trimmed.endIndex) else {
                let tail = String(trimmed[open.lowerBound..<trimmed.endIndex])
                if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(InlineJsSegment(isScript: false, value: tail))
                }
                break
            }

            let script = String(trimmed[open.upperBound..<close.lowerBound])
            segments.append(InlineJsSegment(isScript: true, value: script))
            cursor = close.upperBound
        }

        return segments.isEmpty ? nil : segments
    }

    private func evaluateInlineRuleSegment(
        element: Element,
        payload: String,
        segment: String,
        allowSideEffects: Bool,
        baseUrl: String
    ) throws -> String {
        let replaced = replaceGetTokens(in: segment).replacingOccurrences(of: "{{result}}", with: payload)

        if looksLikeLiteralInlineSegment(replaced) {
            return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if replaced.lowercased().hasPrefix("@js:") {
            let script = String(replaced.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return evaluateJavaScript(script: script, result: payload, element: element, baseUrl: baseUrl) ?? payload
        }

        let directValue = try analyzeElementCore(
            element: element,
            rule: replaced,
            allowSideEffects: allowSideEffects,
            baseUrl: baseUrl
        )
        if !directValue.isEmpty {
            return directValue
        }

        if let body = try? SwiftSoup.parse(payload, baseUrl).body() {
            let value = try analyzeElementCore(
                element: body,
                rule: replaced,
                allowSideEffects: allowSideEffects,
                baseUrl: baseUrl
            )
            if !value.isEmpty {
                return value
            }
        }

        let value = analyzeElementText(html: payload, rule: replaced, baseUrl: baseUrl)
        if !value.isEmpty {
            return value
        }
        return replaced
    }

    private func looksLikeLiteralInlineSegment(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.contains("://") || trimmed.hasPrefix("//") || trimmed.hasPrefix("/") {
            return true
        }
        if trimmed.contains("@") || trimmed.contains("##") || trimmed.hasPrefix("$") {
            return false
        }
        let selectorTokens = ["class.", "id.", "tag.", "children", "[", "]", ".", "#"]
        return !selectorTokens.contains(where: { trimmed.contains($0) })
    }

    private func applyPutDirectives(in rule: String, element: Element, baseUrl: String) throws -> String {
        var output = rule
        let marker = "@put:{"

        while let markerRange = output.range(of: marker) {
            let payloadStart = markerRange.upperBound
            guard let payloadEnd = findMatchingBrace(in: output, from: payloadStart) else {
                break
            }

            let payload = String(output[payloadStart..<payloadEnd])
            let assignments = parsePutAssignments(payload)
            for assignment in assignments {
                guard !assignment.key.isEmpty else { continue }
                let valueRule = trimQuotes(assignment.value)
                let resolvedValue = try resolvePutValue(element: element, valueRule: valueRule, baseUrl: baseUrl)
                setVariable(assignment.key, value: resolvedValue)
            }

            let removeEnd = output.index(after: payloadEnd)
            output.removeSubrange(markerRange.lowerBound..<removeEnd)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvePutValue(element: Element, valueRule: String, baseUrl: String) throws -> String {
        let trimmedValue = valueRule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty { return "" }

        let analyzed = try analyzeElementCore(element: element, rule: trimmedValue, allowSideEffects: false, baseUrl: baseUrl)
        if !analyzed.isEmpty {
            return analyzed
        }
        return replaceGetTokens(in: trimmedValue)
    }

    private func parsePutAssignments(_ payload: String) -> [(key: String, value: String)] {
        let entries = splitTopLevel(payload, by: ",")
        var result: [(key: String, value: String)] = []

        for entry in entries {
            guard let splitIndex = firstTopLevelIndex(of: ":", in: entry) else { continue }
            let keyRange = entry.startIndex..<splitIndex
            let valueRange = entry.index(after: splitIndex)..<entry.endIndex

            let rawKey = String(entry[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(entry[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawKey.isEmpty || rawValue.isEmpty { continue }

            result.append((key: trimQuotes(rawKey), value: rawValue))
        }
        return result
    }

    private func firstTopLevelIndex(of character: Character, in text: String) -> String.Index? {
        var singleQuoteOpen = false
        var doubleQuoteOpen = false
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0

        for idx in text.indices {
            let ch = text[idx]

            if !singleQuoteOpen && !doubleQuoteOpen {
                if ch == "(" {
                    parenDepth += 1
                } else if ch == ")" {
                    parenDepth = max(0, parenDepth - 1)
                } else if ch == "[" {
                    bracketDepth += 1
                } else if ch == "]" {
                    bracketDepth = max(0, bracketDepth - 1)
                } else if ch == "{" {
                    braceDepth += 1
                } else if ch == "}" {
                    braceDepth = max(0, braceDepth - 1)
                }
            }

            if ch == "'" && !doubleQuoteOpen {
                singleQuoteOpen.toggle()
            } else if ch == "\"" && !singleQuoteOpen {
                doubleQuoteOpen.toggle()
            }

            if ch == character &&
                !singleQuoteOpen &&
                !doubleQuoteOpen &&
                parenDepth == 0 &&
                bracketDepth == 0 &&
                braceDepth == 0 {
                return idx
            }
        }
        return nil
    }

    private func firstTopLevelRange(of token: String, in text: String) -> Range<String.Index>? {
        guard !token.isEmpty else { return nil }
        var singleQuoteOpen = false
        var doubleQuoteOpen = false
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0

        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "'" && !doubleQuoteOpen {
                singleQuoteOpen.toggle()
            } else if ch == "\"" && !singleQuoteOpen {
                doubleQuoteOpen.toggle()
            }

            if !singleQuoteOpen && !doubleQuoteOpen {
                if ch == "(" {
                    parenDepth += 1
                } else if ch == ")" {
                    parenDepth = max(0, parenDepth - 1)
                } else if ch == "[" {
                    bracketDepth += 1
                } else if ch == "]" {
                    bracketDepth = max(0, bracketDepth - 1)
                } else if ch == "{" {
                    braceDepth += 1
                } else if ch == "}" {
                    braceDepth = max(0, braceDepth - 1)
                }
            }

            let canMatch = !singleQuoteOpen && !doubleQuoteOpen && parenDepth == 0 && bracketDepth == 0 && braceDepth == 0
            if canMatch && text[idx...].hasPrefix(token) {
                let end = text.index(idx, offsetBy: token.count)
                return idx..<end
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private func findMatchingBrace(in text: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var singleQuoteOpen = false
        var doubleQuoteOpen = false
        var index = start

        while index < text.endIndex {
            let ch = text[index]
            if ch == "'" && !doubleQuoteOpen {
                singleQuoteOpen.toggle()
            } else if ch == "\"" && !singleQuoteOpen {
                doubleQuoteOpen.toggle()
            }

            if !singleQuoteOpen && !doubleQuoteOpen {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func resolveGetOnlyValue(from rule: String) -> String {
        guard rule.hasPrefix("@get:{"), rule.hasSuffix("}") else { return "" }
        let keyStart = rule.index(rule.startIndex, offsetBy: 6)
        let key = String(rule[keyStart..<rule.index(before: rule.endIndex)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return getVariable(trimQuotes(key))
    }

    private func trimQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private struct ReplaceDirective {
        let rule: String
        let regex: String?
        let replacement: String
        let replaceFirst: Bool
    }

    private func parseReplaceDirective(from rule: String) -> ReplaceDirective {
        let parts = rule.components(separatedBy: "##")
        guard parts.count > 1 else {
            return ReplaceDirective(rule: rule, regex: nil, replacement: "", replaceFirst: false)
        }
        let head = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = parts.count > 1 ? parts[1] : nil
        let replacement = parts.count > 2 ? parts[2] : ""
        let replaceFirst = parts.count > 3
        return ReplaceDirective(rule: head, regex: regex, replacement: replacement, replaceFirst: replaceFirst)
    }

    private func applyReplaceDirective(_ value: String, directive: ReplaceDirective) -> String {
        guard let regex = directive.regex,
              !regex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return value
        }

        if let expression = try? NSRegularExpression(pattern: regex, options: []) {
            let range = NSRange(value.startIndex..., in: value)
            if directive.replaceFirst, let first = expression.firstMatch(in: value, options: [], range: range) {
                return expression.stringByReplacingMatches(in: value, options: [], range: first.range, withTemplate: directive.replacement)
            }
            return expression.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: directive.replacement)
        }

        if directive.replaceFirst {
            return value.replacingOccurrences(of: regex, with: directive.replacement, options: [], range: value.range(of: regex))
        }
        return value.replacingOccurrences(of: regex, with: directive.replacement)
    }

    private func splitAtJsSuffix(in rule: String) -> (prefixRule: String, script: String)? {
        guard let range = firstTopLevelRange(of: "@js:", in: rule) else {
            return nil
        }
        let prefix = String(rule[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let script = String(rule[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return nil }
        return (prefix, script)
    }

    private func extractPureJsBlock(from rule: String) -> String? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("<js>") && trimmed.lowercased().hasSuffix("</js>") else {
            return nil
        }
        guard let start = trimmed.range(of: "<js>", options: [.caseInsensitive]),
              let end = trimmed.range(of: "</js>", options: [.caseInsensitive, .backwards]),
              start.upperBound <= end.lowerBound else {
            return nil
        }
        return String(trimmed[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func evaluateJavaScript(script: String, result: String, element: Element?, baseUrl: String) -> String? {
#if canImport(JavaScriptCore)
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let context = JSContext() else {
            return nil
        }

        RuleURLRequestBuilder.prepareJavaScriptContext(
            context,
            key: nil,
            encodedKey: nil,
            page: 1,
            baseUrl: baseUrl,
            result: result,
            sourceKey: baseUrl,
            sourceHeader: nil,
            sourceComment: nil,
            sourceName: nil,
            defaultHeaders: [:],
            elementContext: element
        )

        let candidates = [
            script,
            "(function(){\(script)})()",
            "(function(){ return (\(script)); })()"
        ]

        for candidate in candidates {
            guard let value = context.evaluateScript(candidate),
                  !value.isUndefined,
                  !value.isNull else {
                continue
            }
            if let normalized = normalizeJSValue(value) {
                return normalized
            }
        }
#endif
        return nil
    }

#if canImport(JavaScriptCore)
    private func normalizeJSValue(_ value: JSValue) -> String? {
        if value.isString {
            return value.toString()
        }
        if value.isBoolean {
            return value.toBool() ? "true" : "false"
        }
        if value.isNumber {
            let number = value.toDouble()
            if number.isFinite, number.rounded(.towardZero) == number {
                return String(Int64(number))
            }
            return String(number)
        }
        if let object = value.toObject(),
           JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return value.toString()
    }
#endif

    private func setVariable(_ key: String, value: String) {
        variableLock.lock()
        variables[key] = value
        variableLock.unlock()
    }

    private func getVariable(_ key: String) -> String {
        variableLock.lock()
        let value = variables[key] ?? ""
        variableLock.unlock()
        return value
    }

    func extractUrl(url: String, baseUrl: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }

        guard let base = URL(string: baseUrl) else { return url }

        if trimmed.hasPrefix("//") {
            return (base.scheme ?? "https") + ":" + trimmed
        }

        if let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }

        return base.deletingLastPathComponent().appendingPathComponent(trimmed).absoluteString
    }
}

import Foundation
import SwiftSoup
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

#if canImport(JavaScriptCore)
@objc protocol JavaElementExport: JSExport {
    func text() -> String
    func html() -> String
    func outerHtml() -> String
    func attr(_ name: String) -> String
    func select(_ query: String) -> JavaElementBox
    func toString() -> String
}

@objc final class JavaElementBox: NSObject, JavaElementExport {
    private let rawHTML: String

    init(element: Element) {
        rawHTML = (try? element.outerHtml()) ?? ""
        super.init()
    }

    init(html: String) {
        rawHTML = html
        super.init()
    }

    func text() -> String {
        guard let element = asElement() else { return "" }
        return (try? element.text()) ?? ""
    }

    func html() -> String {
        guard let element = asElement() else { return rawHTML }
        return (try? element.html()) ?? rawHTML
    }

    func outerHtml() -> String {
        rawHTML
    }

    func attr(_ name: String) -> String {
        guard let element = asElement() else { return "" }
        return (try? element.attr(name)) ?? ""
    }

    func select(_ query: String) -> JavaElementBox {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let element = asElement() else {
            return JavaElementBox(html: "")
        }
        if let selected = try? element.select(trimmed).first() {
            return JavaElementBox(element: selected)
        }
        return JavaElementBox(html: "")
    }

    func toString() -> String {
        text()
    }

    override var description: String {
        text()
    }

    func asElement() -> Element? {
        if let body = try? SwiftSoup.parseBodyFragment(rawHTML).body(),
           let first = body.children().first() {
            return first
        }
        return nil
    }
}

@objc protocol JavaResponseExport: JSExport {
    func body() -> String
    func url() -> String
    func header(_ name: String) -> String
    func code() -> Int
    func toString() -> String
}

@objc final class JavaResponseBox: NSObject, JavaResponseExport {
    private let responseURL: String
    private let responseBody: String
    private let responseHeaders: [String: String]
    private let statusCode: Int

    init(url: String, body: String, headers: [String: String] = [:], statusCode: Int = 200) {
        responseURL = url
        responseBody = body
        responseHeaders = headers
        self.statusCode = statusCode
        super.init()
    }

    func body() -> String {
        responseBody
    }

    func url() -> String {
        responseURL
    }

    func header(_ name: String) -> String {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return "" }
        if let value = responseHeaders.first(where: { $0.key.lowercased() == target })?.value {
            return value
        }
        if target == "location" {
            return responseURL
        }
        return ""
    }

    func code() -> Int {
        statusCode
    }

    func toString() -> String {
        responseBody
    }
}
#endif

struct RuleRequestDescriptor {
    let url: String
    let method: String
    let headers: [String: String]
    let body: String?
    let retries: Int?
    let charset: String?
}

enum RuleURLRequestBuilder {
    private static let javaStateLock = NSLock()
    private static var javaState: [String: String] = [:]
    private static let sourceStateLock = NSLock()
    private static var sourceRuntimeState: [String: JavaSourceRuntimeState] = [:]

    private struct JavaSourceRuntimeState {
        var baseHeaders: [String: String]
        var loginHeaders: [String: String]
        var loginInfoMap: [String: String]
        var variableBookMap: [String: String]
    }

    static func build(
        ruleUrl: String,
        baseUrl: String,
        keyword: String? = nil,
        page: Int = 1,
        defaultHeaders: [String: String] = [:],
        sourceKey: String? = nil,
        sourceHeader: String? = nil,
        sourceComment: String? = nil,
        sourceName: String? = nil
    ) -> RuleRequestDescriptor {
        let getResolvedRule = RuleAnalyzer.shared.replaceGetTokens(in: ruleUrl)
        let encodedKeyword = keyword?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let runtimeSourceKey = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? sourceKey! : baseUrl
        let replacedRule = evaluateDynamicRule(
            getResolvedRule,
            key: keyword,
            encodedKey: encodedKeyword,
            page: page,
            baseUrl: baseUrl,
            sourceKey: runtimeSourceKey,
            sourceHeader: sourceHeader,
            sourceComment: sourceComment,
            sourceName: sourceName
        ) ?? getResolvedRule

        var headers = defaultHeaders
        var method = "GET"
        var body: String?
        var retries: Int?
        var charset: String?
        var optionJs: String?

        var (rawRulePart, optionPart) = splitRuleAndOption(replacedRule)

        let (ruleWithoutHeader, inlineHeaders) = extractInlineHeaders(from: rawRulePart)
        rawRulePart = ruleWithoutHeader
        headers.merge(inlineHeaders) { _, new in new }

        if let range = rawRulePart.range(of: "@post->") {
            method = "POST"
            let head = String(rawRulePart[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyPart = String(rawRulePart[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            rawRulePart = head
            body = bodyPart.isEmpty ? nil : bodyPart
        }

        if let optionPart {
            let options = parseJSONObject(optionPart)
            if let methodString = options["method"] as? String, !methodString.isEmpty {
                method = methodString.uppercased()
            }
            if let optionHeaders = normalizeHeaders(options["headers"] ?? options["header"]) {
                headers.merge(optionHeaders) { _, new in new }
            }
            if let optionBody = stringifyBody(options["body"]) {
                body = optionBody
            }
            if let retryValue = parseInt(options["retry"]) {
                retries = max(1, retryValue)
            }
            if let charsetValue = options["charset"] as? String, !charsetValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                charset = charsetValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let jsValue = options["js"] as? String, !jsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                optionJs = jsValue
            }
        }

        let usedKeyPlaceholder = getResolvedRule.contains("{{key}}")
        rawRulePart = evaluateDynamicRule(
            rawRulePart,
            key: keyword,
            encodedKey: encodedKeyword,
            page: page,
            baseUrl: baseUrl,
            sourceKey: runtimeSourceKey,
            sourceHeader: sourceHeader,
            sourceComment: sourceComment,
            sourceName: sourceName
        ) ?? rawRulePart
        rawRulePart = RuleAnalyzer.shared.replaceGetTokens(in: rawRulePart)

        if let keyword, !keyword.isEmpty {
            let bodyUsedPlaceholder = body?.contains("{{key}}") == true
            body = evaluateDynamicRule(
                body,
                key: keyword,
                encodedKey: encodedKeyword,
                page: page,
                baseUrl: baseUrl,
                sourceKey: runtimeSourceKey,
                sourceHeader: sourceHeader,
                sourceComment: sourceComment,
                sourceName: sourceName
            )
            body = body.map { RuleAnalyzer.shared.replaceGetTokens(in: $0) }

            if !usedKeyPlaceholder && !bodyUsedPlaceholder {
                if method == "POST" {
                    if body == nil || body?.isEmpty == true {
                        body = "searchKey=\(encodedKeyword ?? keyword)"
                    }
                } else {
                    rawRulePart = appendQuery(rawRulePart, query: "searchKey=\(encodedKeyword ?? keyword)")
                }
            }
        } else {
            body = evaluateDynamicRule(
                body,
                key: nil,
                encodedKey: nil,
                page: page,
                baseUrl: baseUrl,
                sourceKey: runtimeSourceKey,
                sourceHeader: sourceHeader,
                sourceComment: sourceComment,
                sourceName: sourceName
            )
            body = body.map { RuleAnalyzer.shared.replaceGetTokens(in: $0) }
        }

        let absoluteUrl = makeAbsoluteUrl(rawRulePart, baseUrl: baseUrl)
        var finalUrl = absoluteUrl
        if let optionJs {
            let jsResult = evaluateJavaScript(
                optionJs,
                key: keyword,
                encodedKey: encodedKeyword,
                page: page,
                baseUrl: baseUrl,
                result: absoluteUrl,
                sourceKey: runtimeSourceKey,
                sourceHeader: sourceHeader,
                sourceComment: sourceComment,
                sourceName: sourceName,
                defaultHeaders: headers,
                elementContext: nil
            )
            if let jsResult, !jsResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalUrl = makeAbsoluteUrl(jsResult, baseUrl: baseUrl)
            }
        }

        return RuleRequestDescriptor(url: finalUrl, method: method, headers: headers, body: body, retries: retries, charset: charset)
    }

    static func parseHeaderMap(_ raw: String?) -> [String: String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }

        let object = parseJSONObject(raw)
        if !object.isEmpty {
            return object.reduce(into: [:]) { partialResult, item in
                partialResult[item.key] = "\(item.value)"
            }
        }

        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        if normalized.isEmpty {
            return [:]
        }

        var result: [String: String] = [:]
        normalized.split(separator: ",").forEach { pair in
            let parts = pair.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return result
    }

    private static func splitRuleAndOption(_ rule: String) -> (String, String?) {
        guard let regex = try? NSRegularExpression(pattern: "\\s*,\\s*(?=\\{)") else {
            return (rule.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let nsRange = NSRange(rule.startIndex..., in: rule)
        guard let match = regex.firstMatch(in: rule, options: [], range: nsRange),
              let matchRange = Range(match.range, in: rule) else {
            return (rule.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        let head = String(rule[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let option = String(rule[matchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, option.isEmpty ? nil : option)
    }

    private static func extractInlineHeaders(from rulePart: String) -> (String, [String: String]) {
        guard let regex = try? NSRegularExpression(pattern: "@Header:\\{[^\\}]*\\}", options: .caseInsensitive) else {
            return (rulePart, [:])
        }

        let nsRange = NSRange(rulePart.startIndex..., in: rulePart)
        let matches = regex.matches(in: rulePart, options: [], range: nsRange)
        if matches.isEmpty {
            return (rulePart, [:])
        }

        var headers: [String: String] = [:]
        var sanitized = rulePart
        for match in matches.reversed() {
            guard let range = Range(match.range, in: sanitized) else { continue }
            let token = String(sanitized[range])
            let jsonPart = token.replacingOccurrences(of: "@Header:", with: "", options: .caseInsensitive)
            headers.merge(parseHeaderMap(jsonPart)) { _, new in new }
            sanitized.removeSubrange(range)
        }

        return (sanitized.trimmingCharacters(in: .whitespacesAndNewlines), headers)
    }

    private static func applyPlaceholders(to input: String?, key: String?, page: Int) -> String? {
        guard var text = input else { return nil }
        if let key {
            text = text.replacingOccurrences(of: "{{key}}", with: key)
        }

        let pageMappings: [(String, String)] = [
            ("{{page}}", String(page)),
            ("{{page1}}", String(page)),
            ("{{page-1}}", String(max(1, page - 1))),
            ("{{page+1}}", String(page + 1))
        ]

        for (target, value) in pageMappings {
            text = text.replacingOccurrences(of: target, with: value)
        }
        return text
    }

    private static func evaluateDynamicRule(
        _ input: String?,
        key: String?,
        encodedKey: String?,
        page: Int,
        baseUrl: String,
        sourceKey: String?,
        sourceHeader: String?,
        sourceComment: String?,
        sourceName: String?
    ) -> String? {
        guard var text = input, !text.isEmpty else { return input }

        text = evaluateJSBlocks(
            in: text,
            key: key,
            encodedKey: encodedKey,
            page: page,
            baseUrl: baseUrl,
            sourceKey: sourceKey,
            sourceHeader: sourceHeader,
            sourceComment: sourceComment,
            sourceName: sourceName
        )
        text = evaluateAtJsPrefix(
            in: text,
            key: key,
            encodedKey: encodedKey,
            page: page,
            baseUrl: baseUrl,
            sourceKey: sourceKey,
            sourceHeader: sourceHeader,
            sourceComment: sourceComment,
            sourceName: sourceName
        )
        text = evaluateExpressionPlaceholders(
            in: text,
            key: key,
            encodedKey: encodedKey,
            page: page,
            baseUrl: baseUrl,
            sourceKey: sourceKey,
            sourceHeader: sourceHeader,
            sourceComment: sourceComment,
            sourceName: sourceName
        )
        text = replacePageAlternatives(in: text, page: page)
        text = applyPlaceholders(to: text, key: encodedKey ?? key, page: page) ?? text
        return text
    }

    private static func evaluateJSBlocks(
        in text: String,
        key: String?,
        encodedKey: String?,
        page: Int,
        baseUrl: String,
        sourceKey: String?,
        sourceHeader: String?,
        sourceComment: String?,
        sourceName: String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<js>([\\w\\W]*?)</js>", options: [.caseInsensitive]) else {
            return text
        }

        var output = text
        let nsRange = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: nsRange)
        if matches.isEmpty {
            return output
        }

        for match in matches.reversed() {
            guard let blockRange = Range(match.range, in: output),
                  match.numberOfRanges > 1,
                  let codeRange = Range(match.range(at: 1), in: output) else { continue }
            let code = String(output[codeRange])
            let value = evaluateJavaScript(
                code,
                key: key,
                encodedKey: encodedKey,
                page: page,
                baseUrl: baseUrl,
                result: output,
                sourceKey: sourceKey,
                sourceHeader: sourceHeader,
                sourceComment: sourceComment,
                sourceName: sourceName,
                defaultHeaders: parseHeaderMap(sourceHeader),
                elementContext: nil
            ) ?? ""
            output.replaceSubrange(blockRange, with: value)
        }
        return output
    }

    private static func evaluateAtJsPrefix(
        in text: String,
        key: String?,
        encodedKey: String?,
        page: Int,
        baseUrl: String,
        sourceKey: String?,
        sourceHeader: String?,
        sourceComment: String?,
        sourceName: String?
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("@js:") else { return text }
        let script = String(trimmed.dropFirst(4))
        let value = evaluateJavaScript(
            script,
            key: key,
            encodedKey: encodedKey,
            page: page,
            baseUrl: baseUrl,
            result: trimmed,
            sourceKey: sourceKey,
            sourceHeader: sourceHeader,
            sourceComment: sourceComment,
            sourceName: sourceName,
            defaultHeaders: parseHeaderMap(sourceHeader),
            elementContext: nil
        )
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
    }

    private static func evaluateExpressionPlaceholders(
        in text: String,
        key: String?,
        encodedKey: String?,
        page: Int,
        baseUrl: String,
        sourceKey: String?,
        sourceHeader: String?,
        sourceComment: String?,
        sourceName: String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{([\\w\\W]*?)\\}\\}", options: []) else {
            return text
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        if matches.isEmpty {
            return text
        }

        var output = ""
        var cursor = text.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  match.numberOfRanges > 1,
                  let expRange = Range(match.range(at: 1), in: text) else { continue }
            output += String(text[cursor..<fullRange.lowerBound])
            let expression = String(text[expRange])
            let replacement = evaluateExpression(
                expression,
                key: key,
                encodedKey: encodedKey,
                page: page,
                baseUrl: baseUrl,
                result: text,
                sourceKey: sourceKey,
                sourceHeader: sourceHeader,
                sourceComment: sourceComment,
                sourceName: sourceName
            )
            output += replacement
            cursor = fullRange.upperBound
        }

        output += String(text[cursor...])
        return output
    }

    private static func evaluateExpression(
        _ expression: String,
        key: String?,
        encodedKey: String?,
        page: Int,
        baseUrl: String,
        result: String?,
        sourceKey: String?,
        sourceHeader: String?,
        sourceComment: String?,
        sourceName: String?
    ) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        switch trimmed {
        case "key":
            return encodedKey ?? key ?? ""
        case "keyRaw":
            return key ?? ""
        case "page", "page1":
            return String(page)
        case "page-1":
            return String(max(1, page - 1))
        case "page+1":
            return String(page + 1)
        default:
            return evaluateJavaScript(
                trimmed,
                key: key,
                encodedKey: encodedKey,
                page: page,
                baseUrl: baseUrl,
                result: result,
                sourceKey: sourceKey,
                sourceHeader: sourceHeader,
                sourceComment: sourceComment,
                sourceName: sourceName,
                defaultHeaders: parseHeaderMap(sourceHeader),
                elementContext: nil
            ) ?? ""
        }
    }

    private static func replacePageAlternatives(in text: String, page: Int) -> String {
        guard page > 0,
              let regex = try? NSRegularExpression(pattern: "<([^<>]+)>", options: []) else {
            return text
        }

        var output = text
        let nsRange = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: nsRange)
        if matches.isEmpty {
            return output
        }

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: output),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: output) else { continue }
            let raw = String(output[valueRange])
            if raw.contains("/") || raw.contains("=") || raw.contains("http") {
                continue
            }
            let options = raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !options.isEmpty else { continue }
            let idx = min(max(page - 1, 0), options.count - 1)
            output.replaceSubrange(fullRange, with: options[idx])
        }

        return output
    }

    private static func evaluateJavaScript(
        _ script: String,
        key: String?,
        encodedKey: String?,
        page: Int,
        baseUrl: String,
        result: String?,
        sourceKey: String?,
        sourceHeader: String?,
        sourceComment: String?,
        sourceName: String?,
        defaultHeaders: [String: String],
        elementContext: Element?
    ) -> String? {
#if canImport(JavaScriptCore)
        guard let context = JSContext() else { return nil }
        prepareJavaScriptContext(
            context,
            key: key,
            encodedKey: encodedKey,
            page: page,
            baseUrl: baseUrl,
            result: result,
            sourceKey: sourceKey,
            sourceHeader: sourceHeader,
            sourceComment: sourceComment,
            sourceName: sourceName,
            defaultHeaders: defaultHeaders,
            elementContext: elementContext
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
            if let stringValue = normalizeJSValue(value) {
                return stringValue
            }
        }
#endif
        return nil
    }

#if canImport(JavaScriptCore)
    static func prepareJavaScriptContext(
        _ context: JSContext,
        key: String?,
        encodedKey: String?,
        page: Int,
        baseUrl: String,
        result: String?,
        sourceKey: String?,
        sourceHeader: String?,
        sourceComment: String?,
        sourceName: String?,
        defaultHeaders: [String: String],
        elementContext: Element?
    ) {
        context.exceptionHandler = { _, _ in }
        context.setObject(key ?? "", forKeyedSubscript: "key" as NSString)
        context.setObject(encodedKey ?? key ?? "", forKeyedSubscript: "keyEncoded" as NSString)
        context.setObject(page, forKeyedSubscript: "page" as NSString)
        context.setObject(baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        let sourceKeyValue = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? sourceKey! : baseUrl
        let sourceHeaderValue = resolveRuntimeSourceHeader(
            rawSourceHeader: sourceHeader ?? "",
            baseUrl: baseUrl,
            sourceKey: sourceKeyValue,
            sourceComment: sourceComment,
            sourceName: sourceName
        )
        let sourceCommentValue = sourceComment ?? ""
        let sourceNameValue = sourceName ?? ""
        _ = ensureSourceState(
            sourceKey: sourceKeyValue,
            sourceHeader: sourceHeaderValue,
            defaultHeaders: defaultHeaders
        )
        let sourceHeaderJSON = sourceHeaderString(
            sourceKey: sourceKeyValue,
            sourceHeader: sourceHeaderValue,
            defaultHeaders: defaultHeaders
        )
        let resultValue = result ?? ""
        context.setObject(resultValue, forKeyedSubscript: "result" as NSString)
        context.setObject(resultValue, forKeyedSubscript: "src" as NSString)
        context.setObject(sourceKeyValue, forKeyedSubscript: "__source_key" as NSString)
        context.setObject(sourceHeaderJSON, forKeyedSubscript: "__source_header" as NSString)
        context.setObject(sourceCommentValue, forKeyedSubscript: "__source_comment" as NSString)
        context.setObject(sourceNameValue, forKeyedSubscript: "__source_name" as NSString)

        let cookieGetKeyBlock: @convention(block) (String, String) -> String = { siteURL, key in
            resolveCookieValue(siteURL: siteURL.isEmpty ? baseUrl : siteURL, key: key)
        }
        let cookieGetBlock: @convention(block) (String, String) -> String = { siteURL, key in
            resolveCookieValue(siteURL: siteURL.isEmpty ? baseUrl : siteURL, key: key)
        }
        let cookieRemoveBlock: @convention(block) (String) -> String = { siteURL in
            removeCookie(siteURL: siteURL.isEmpty ? baseUrl : siteURL)
            return ""
        }
        let sourceHeaderBlock: @convention(block) () -> String = {
            sourceHeaderString(
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderValue,
                defaultHeaders: defaultHeaders
            )
        }
        let sourcePutLoginHeaderBlock: @convention(block) (Any?) -> String = { payload in
            putSourceLoginHeader(
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderValue,
                defaultHeaders: defaultHeaders,
                payload: payload
            )
        }
        let sourceRemoveLoginHeaderBlock: @convention(block) (String?) -> String = { headerName in
            removeSourceLoginHeader(
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderValue,
                defaultHeaders: defaultHeaders,
                headerName: headerName
            )
        }
        let sourceLoginInfoGetBlock: @convention(block) (String) -> String = { key in
            sourceLoginInfoValue(sourceKey: sourceKeyValue, key: key)
        }
        let sourceLoginInfoPutBlock: @convention(block) (String, Any?) -> String = { key, value in
            putSourceLoginInfo(sourceKey: sourceKeyValue, key: key, value: value)
        }
        let sourceLoginInfoRemoveBlock: @convention(block) (String) -> String = { key in
            removeSourceLoginInfo(sourceKey: sourceKeyValue, key: key)
        }
        let sourceLoginInfoKeysBlock: @convention(block) () -> [String] = {
            sourceLoginInfoKeys(sourceKey: sourceKeyValue)
        }
        let sourceVariableBookGetBlock: @convention(block) (String) -> String = { key in
            sourceVariableBookValue(sourceKey: sourceKeyValue, key: key)
        }
        let sourceVariableBookPutBlock: @convention(block) (String, Any?) -> String = { key, value in
            putSourceVariableBook(sourceKey: sourceKeyValue, key: key, value: value)
        }
        let sourceVariableBookRemoveBlock: @convention(block) (String) -> String = { key in
            removeSourceVariableBook(sourceKey: sourceKeyValue, key: key)
        }
        let sourceVariableBookKeysBlock: @convention(block) () -> [String] = {
            sourceVariableBookKeys(sourceKey: sourceKeyValue)
        }

        let javaPutBlock: @convention(block) (String, String) -> String = { key, value in
            setJavaVariable(key: key, value: value)
            return value
        }
        let javaGetBlock: @convention(block) (String) -> String = { key in
            getJavaVariable(key: key)
        }
        let javaGetStringBlock: @convention(block) (String, Any?) -> String = { path, payload in
            resolveJavaGetString(
                path: path,
                payload: payload,
                fallbackPayload: resultValue,
                baseUrl: baseUrl,
                elementContext: elementContext
            )
        }
        let javaGetStringListBlock: @convention(block) (String, Any?) -> [String] = { path, payload in
            resolveJavaGetStringList(
                path: path,
                payload: payload,
                fallbackPayload: resultValue,
                baseUrl: baseUrl,
                elementContext: elementContext
            )
        }
        let javaGetElementsBlock: @convention(block) (String, Any?) -> [JavaElementBox] = { rule, payload in
            resolveJavaGetElements(
                rule: rule,
                payload: payload,
                fallbackPayload: resultValue,
                baseUrl: baseUrl,
                elementContext: elementContext
            )
        }
        let javaGetElementBlock: @convention(block) (String, Any?) -> Any = { rule, payload in
            let elements = resolveJavaGetElements(
                rule: rule,
                payload: payload,
                fallbackPayload: resultValue,
                baseUrl: baseUrl,
                elementContext: elementContext
            )
            if let first = elements.first {
                return first
            }
            return ""
        }
        let javaTimeFormatBlock: @convention(block) (String) -> String = { value in
            formatTimestamp(value)
        }
        let javaTimeFormatUTCBlock: @convention(block) (String) -> String = { value in
            formatTimestamp(value, useUTC: true)
        }
        let javaHostBlock: @convention(block) (String) -> String = { raw in
            URL(string: raw)?.host ?? URL(string: "https://\(raw)")?.host ?? ""
        }
        let javaToNumChapterBlock: @convention(block) (String) -> String = { value in
            toNumChapter(value)
        }
        let javaAjaxBlock: @convention(block) (String) -> String = { raw in
            let resolvedDefaults = sourceHeaders(
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderValue,
                defaultHeaders: defaultHeaders
            )
            return performJavaAjax(
                rawRule: raw,
                baseUrl: baseUrl,
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderString(
                    sourceKey: sourceKeyValue,
                    sourceHeader: sourceHeaderValue,
                    defaultHeaders: defaultHeaders
                ),
                sourceComment: sourceCommentValue,
                sourceName: sourceNameValue,
                defaultHeaders: resolvedDefaults
            ).body
        }
        let javaAjaxResponseBlock: @convention(block) (String) -> JavaResponseBox = { raw in
            let resolvedDefaults = sourceHeaders(
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderValue,
                defaultHeaders: defaultHeaders
            )
            let response = performJavaAjax(
                rawRule: raw,
                baseUrl: baseUrl,
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderString(
                    sourceKey: sourceKeyValue,
                    sourceHeader: sourceHeaderValue,
                    defaultHeaders: defaultHeaders
                ),
                sourceComment: sourceCommentValue,
                sourceName: sourceNameValue,
                defaultHeaders: resolvedDefaults
            )
            return JavaResponseBox(
                url: response.url,
                body: response.body,
                headers: response.headers,
                statusCode: response.statusCode
            )
        }
        let javaHttpGetResponseBlock: @convention(block) (String, Any?) -> JavaResponseBox = { raw, headersPayload in
            let resolvedDefaults = sourceHeaders(
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderValue,
                defaultHeaders: defaultHeaders
            )
            let response = performJavaConnectRequest(
                rawRule: raw,
                optionsPayload: [
                    "method": "GET",
                    "headers": dictionaryFromJavaPayload(headersPayload)
                ],
                baseUrl: baseUrl,
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderString(
                    sourceKey: sourceKeyValue,
                    sourceHeader: sourceHeaderValue,
                    defaultHeaders: defaultHeaders
                ),
                sourceComment: sourceCommentValue,
                sourceName: sourceNameValue,
                defaultHeaders: resolvedDefaults
            )
            return JavaResponseBox(
                url: response.url,
                body: response.body,
                headers: response.headers,
                statusCode: response.statusCode
            )
        }
        let javaAjaxAllBlock: @convention(block) (Any?) -> [JavaResponseBox] = { list in
            let resolvedDefaults = sourceHeaders(
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderValue,
                defaultHeaders: defaultHeaders
            )
            let urls = stringArray(from: list)
            return urls.map { raw in
                let response = performJavaAjax(
                    rawRule: raw,
                    baseUrl: baseUrl,
                    sourceKey: sourceKeyValue,
                    sourceHeader: sourceHeaderString(
                        sourceKey: sourceKeyValue,
                        sourceHeader: sourceHeaderValue,
                        defaultHeaders: defaultHeaders
                    ),
                    sourceComment: sourceCommentValue,
                    sourceName: sourceNameValue,
                    defaultHeaders: resolvedDefaults
                )
                return JavaResponseBox(
                    url: response.url,
                    body: response.body,
                    headers: response.headers,
                    statusCode: response.statusCode
                )
            }
        }
        let javaConnectRequestBlock: @convention(block) (String, Any?) -> JavaResponseBox = { raw, optionsPayload in
            let resolvedDefaults = sourceHeaders(
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderValue,
                defaultHeaders: defaultHeaders
            )
            let response = performJavaConnectRequest(
                rawRule: raw,
                optionsPayload: optionsPayload,
                baseUrl: baseUrl,
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderString(
                    sourceKey: sourceKeyValue,
                    sourceHeader: sourceHeaderValue,
                    defaultHeaders: defaultHeaders
                ),
                sourceComment: sourceCommentValue,
                sourceName: sourceNameValue,
                defaultHeaders: resolvedDefaults
            )
            return JavaResponseBox(
                url: response.url,
                body: response.body,
                headers: response.headers,
                statusCode: response.statusCode
            )
        }
        let javaMD5Block: @convention(block) (String) -> String = { input in
            md5Hex(input)
        }
        let javaHmacHexBlock: @convention(block) (String, String, String) -> String = { text, algorithm, secret in
            hmacHex(text: text, algorithm: algorithm, key: secret)
        }
        let javaHmacBase64Block: @convention(block) (String, String, String) -> String = { text, algorithm, secret in
            hmacBase64(text: text, algorithm: algorithm, key: secret)
        }
        let javaBase64EncodeBlock: @convention(block) (String) -> String = { input in
            base64Encode(input)
        }
        let javaBase64DecodeBlock: @convention(block) (String) -> String = { input in
            base64DecodeToString(input)
        }
        let javaBase64DecodeToByteArrayBlock: @convention(block) (String) -> [Int] = { input in
            base64DecodeToByteArray(input)
        }
        let javaHexDecodeToStringBlock: @convention(block) (String) -> String = { input in
            hexDecodeToString(input)
        }
        let javaSymmetricDecryptBlock: @convention(block) (String, String, Any?, Any?) -> String = { text, transformation, keyPayload, ivPayload in
            symmetricBase64Decrypt(
                text: text,
                transformation: transformation,
                keyPayload: keyPayload,
                ivPayload: ivPayload
            )
        }
        let javaDesEncodeToBase64Block: @convention(block) (String, String, String, String) -> String = { text, key, transformation, iv in
            desEncodeToBase64String(text: text, key: key, transformation: transformation, iv: iv)
        }
        let javaAesBase64DecodeToStringBlock: @convention(block) (String, String, String, String) -> String = { text, key, transformation, iv in
            aesBase64DecodeToString(text: text, key: key, transformation: transformation, iv: iv)
        }
        let javaEncodeURIBlock: @convention(block) (String) -> String = { raw in
            encodeURI(raw)
        }
        let javaEncodeURIComponentBlock: @convention(block) (String) -> String = { raw in
            encodeURIComponent(raw)
        }
        let javaRandomUUIDBlock: @convention(block) () -> String = {
            UUID().uuidString
        }
        let javaLogBlock: @convention(block) (Any?) -> String = { message in
            let text = stringifyJavaPayload(message, fallback: "")
            if !text.isEmpty {
                print("[LegadoJS] \(text)")
            }
            return text
        }
        let javaToastBlock: @convention(block) (Any?) -> String = { message in
            stringifyJavaPayload(message, fallback: "")
        }
        let javaGetCookieBlock: @convention(block) (String, String?) -> String = { siteURL, cookieKey in
            if let cookieKey, !cookieKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return resolveCookieValue(siteURL: siteURL.isEmpty ? baseUrl : siteURL, key: cookieKey)
            }
            return buildCookieHeader(siteURL: siteURL.isEmpty ? baseUrl : siteURL)
        }
        let javaInitUrlBlock: @convention(block) () -> String = {
            return baseUrl
        }
        let javaRefreshTocUrlBlock: @convention(block) () -> String = {
            let cached = getJavaVariable(key: "tocUrl")
            if !cached.isEmpty { return cached }
            return sourceKeyValue
        }
        let javaRefreshBookUrlBlock: @convention(block) () -> String = {
            let cached = getJavaVariable(key: "bookUrl")
            if !cached.isEmpty { return cached }
            return sourceKeyValue
        }
        let javaWebViewBlock: @convention(block) (Any?, Any?, Any?) -> String = { arg1, arg2, _ in
            let raw1 = stringifyJavaPayload(arg1, fallback: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            let raw2 = stringifyJavaPayload(arg2, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = (!raw2.isEmpty && raw2.lowercased() != "null") ? raw2 : raw1
            let target = (!candidate.isEmpty && candidate.lowercased() != "null") ? candidate : baseUrl
            let resolvedDefaults = sourceHeaders(
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderValue,
                defaultHeaders: defaultHeaders
            )
            return performJavaAjax(
                rawRule: target,
                baseUrl: baseUrl,
                sourceKey: sourceKeyValue,
                sourceHeader: sourceHeaderString(
                    sourceKey: sourceKeyValue,
                    sourceHeader: sourceHeaderValue,
                    defaultHeaders: defaultHeaders
                ),
                sourceComment: sourceCommentValue,
                sourceName: sourceNameValue,
                defaultHeaders: resolvedDefaults
            ).body
        }

        context.setObject(cookieGetKeyBlock, forKeyedSubscript: "__cookie_get_key" as NSString)
        context.setObject(cookieGetBlock, forKeyedSubscript: "__cookie_get" as NSString)
        context.setObject(cookieRemoveBlock, forKeyedSubscript: "__cookie_remove" as NSString)
        context.setObject(sourceHeaderBlock, forKeyedSubscript: "__source_header_get" as NSString)
        context.setObject(sourcePutLoginHeaderBlock, forKeyedSubscript: "__source_put_login_header" as NSString)
        context.setObject(sourceRemoveLoginHeaderBlock, forKeyedSubscript: "__source_remove_login_header" as NSString)
        context.setObject(sourceLoginInfoGetBlock, forKeyedSubscript: "__source_login_info_get" as NSString)
        context.setObject(sourceLoginInfoPutBlock, forKeyedSubscript: "__source_login_info_put" as NSString)
        context.setObject(sourceLoginInfoRemoveBlock, forKeyedSubscript: "__source_login_info_remove" as NSString)
        context.setObject(sourceLoginInfoKeysBlock, forKeyedSubscript: "__source_login_info_keys" as NSString)
        context.setObject(sourceVariableBookGetBlock, forKeyedSubscript: "__source_variable_book_get" as NSString)
        context.setObject(sourceVariableBookPutBlock, forKeyedSubscript: "__source_variable_book_put" as NSString)
        context.setObject(sourceVariableBookRemoveBlock, forKeyedSubscript: "__source_variable_book_remove" as NSString)
        context.setObject(sourceVariableBookKeysBlock, forKeyedSubscript: "__source_variable_book_keys" as NSString)
        context.setObject(javaPutBlock, forKeyedSubscript: "__java_put" as NSString)
        context.setObject(javaGetBlock, forKeyedSubscript: "__java_get" as NSString)
        context.setObject(javaGetStringBlock, forKeyedSubscript: "__java_get_string" as NSString)
        context.setObject(javaGetStringListBlock, forKeyedSubscript: "__java_get_string_list" as NSString)
        context.setObject(javaGetElementsBlock, forKeyedSubscript: "__java_get_elements" as NSString)
        context.setObject(javaGetElementBlock, forKeyedSubscript: "__java_get_element" as NSString)
        context.setObject(javaTimeFormatBlock, forKeyedSubscript: "__java_time_format" as NSString)
        context.setObject(javaTimeFormatUTCBlock, forKeyedSubscript: "__java_time_format_utc" as NSString)
        context.setObject(javaHostBlock, forKeyedSubscript: "__java_host" as NSString)
        context.setObject(javaToNumChapterBlock, forKeyedSubscript: "__java_to_num_chapter" as NSString)
        context.setObject(javaAjaxBlock, forKeyedSubscript: "__java_ajax" as NSString)
        context.setObject(javaAjaxResponseBlock, forKeyedSubscript: "__java_ajax_response" as NSString)
        context.setObject(javaHttpGetResponseBlock, forKeyedSubscript: "__java_http_get_response" as NSString)
        context.setObject(javaAjaxAllBlock, forKeyedSubscript: "__java_ajax_all" as NSString)
        context.setObject(javaConnectRequestBlock, forKeyedSubscript: "__java_connect_request" as NSString)
        context.setObject(javaMD5Block, forKeyedSubscript: "__java_md5" as NSString)
        context.setObject(javaHmacHexBlock, forKeyedSubscript: "__java_hmac_hex" as NSString)
        context.setObject(javaHmacBase64Block, forKeyedSubscript: "__java_hmac_b64" as NSString)
        context.setObject(javaBase64EncodeBlock, forKeyedSubscript: "__java_b64_encode" as NSString)
        context.setObject(javaBase64DecodeBlock, forKeyedSubscript: "__java_b64_decode" as NSString)
        context.setObject(javaBase64DecodeToByteArrayBlock, forKeyedSubscript: "__java_b64_decode_bytes" as NSString)
        context.setObject(javaHexDecodeToStringBlock, forKeyedSubscript: "__java_hex_decode_to_string" as NSString)
        context.setObject(javaSymmetricDecryptBlock, forKeyedSubscript: "__java_symmetric_decrypt" as NSString)
        context.setObject(javaDesEncodeToBase64Block, forKeyedSubscript: "__java_des_encode_b64" as NSString)
        context.setObject(javaAesBase64DecodeToStringBlock, forKeyedSubscript: "__java_aes_decode_b64" as NSString)
        context.setObject(javaEncodeURIBlock, forKeyedSubscript: "__java_encode_uri" as NSString)
        context.setObject(javaEncodeURIComponentBlock, forKeyedSubscript: "__java_encode_uri_component" as NSString)
        context.setObject(javaRandomUUIDBlock, forKeyedSubscript: "__java_uuid" as NSString)
        context.setObject(javaLogBlock, forKeyedSubscript: "__java_log" as NSString)
        context.setObject(javaToastBlock, forKeyedSubscript: "__java_toast" as NSString)
        context.setObject(javaGetCookieBlock, forKeyedSubscript: "__java_get_cookie" as NSString)
        context.setObject(javaInitUrlBlock, forKeyedSubscript: "__java_init_url" as NSString)
        context.setObject(javaRefreshTocUrlBlock, forKeyedSubscript: "__java_refresh_toc_url" as NSString)
        context.setObject(javaRefreshBookUrlBlock, forKeyedSubscript: "__java_refresh_book_url" as NSString)
        context.setObject(javaWebViewBlock, forKeyedSubscript: "__java_webview" as NSString)

        context.evaluateScript(
            """
            var cookie = {
              getKey: function(url, key) { return __cookie_get_key(String(url || ''), String(key || '')); },
              get: function(url, key) { return __cookie_get(String(url || ''), String(key || '')); },
              removeCookie: function(url) { return __cookie_remove(String(url || '')); }
            };
            var __createNativeMap = function(getter, putter, remover, keysGetter) {
              return {
                get: function(k) { return getter(String(k || '')); },
                put: function(k, v) { return putter(String(k || ''), v); },
                remove: function(k) { return remover(String(k || '')); },
                containsKey: function(k) { return this.get(k) !== ''; },
                keySet: function() { return keysGetter(); },
                clear: function() {
                  var keys = keysGetter();
                  for (var i = 0; i < keys.length; i++) {
                    remover(String(keys[i] || ''));
                  }
                },
                putAll: function(mapObj) {
                  if (!mapObj) return;
                  for (var k in mapObj) {
                    if (Object.prototype.hasOwnProperty.call(mapObj, k)) {
                      putter(String(k || ''), mapObj[k]);
                    }
                  }
                }
              };
            };

            var source = {
              key: String(__source_key || baseUrl || ''),
              bookSourceUrl: String(__source_key || baseUrl || ''),
              header: String(__source_header_get()),
              bookSourceComment: String(__source_comment || ''),
              bookSourceName: String(__source_name || ''),
              getKey: function() { return this.key; },
              getSource: function() { return this; },
              getLoginInfoMap: function() {
                return __createNativeMap(__source_login_info_get, __source_login_info_put, __source_login_info_remove, __source_login_info_keys);
              },
              getVariableBook: function() {
                return __createNativeMap(__source_variable_book_get, __source_variable_book_put, __source_variable_book_remove, __source_variable_book_keys);
              },
              putLoginHeader: function(payload) {
                this.header = String(__source_put_login_header(payload));
                return this.header;
              },
              removeLoginHeader: function(name) {
                this.header = String(__source_remove_login_header(name == null ? null : String(name)));
                return this.header;
              }
            };
            var java = {
              put: function(k, v) { return __java_put(String(k || ''), String(v == null ? '' : v)); },
              get: function(k, headers) {
                if (arguments.length <= 1) {
                  return __java_get(String(k || ''));
                }
                return __java_http_get_response(String(k || ''), headers);
              },
              getString: function(path, payload) { return __java_get_string(String(path || ''), payload == null ? String(result || src || '') : payload); },
              getStringList: function(path, payload) { return __java_get_string_list(String(path || ''), payload == null ? result : payload); },
              getElements: function(rule, payload) { return __java_get_elements(String(rule || ''), payload == null ? result : payload); },
              getElement: function(rule, payload) { return __java_get_element(String(rule || ''), payload == null ? result : payload); },
              setContent: function(v) { result = String(v == null ? '' : v); src = result; return result; },
              timeFormat: function(v) { return __java_time_format(String(v == null ? '' : v)); },
              timeFormatUTC: function(v) { return __java_time_format_utc(String(v == null ? '' : v)); },
              toNumChapter: function(text) { return __java_to_num_chapter(String(text || '')); },
              ajax: function(urlStr) { return __java_ajax(String(urlStr || '')); },
              ajaxAll: function(urlList) { return __java_ajax_all(urlList); },
              getStrResponse: function(urlStr) { return __java_ajax_response(String(urlStr || '')); },
              md5Encode: function(text) { return __java_md5(String(text == null ? '' : text)); },
              HMacHex: function(text, algorithm, key) { return __java_hmac_hex(String(text == null ? '' : text), String(algorithm || ''), String(key || '')); },
              HMacBase64: function(text, algorithm, key) { return __java_hmac_b64(String(text == null ? '' : text), String(algorithm || ''), String(key || '')); },
              base64Encode: function(text) { return __java_b64_encode(String(text == null ? '' : text)); },
              base64Decode: function(text) { return __java_b64_decode(String(text == null ? '' : text)); },
              base64DecodeToByteArray: function(text) { return __java_b64_decode_bytes(String(text == null ? '' : text)); },
              hexDecodeToString: function(text) { return __java_hex_decode_to_string(String(text == null ? '' : text)); },
              createSymmetricCrypto: function(transformation, key, iv) {
                return {
                  decryptStr: function(text) {
                    return __java_symmetric_decrypt(
                      String(text == null ? '' : text),
                      String(transformation || 'AES/CBC/PKCS5Padding'),
                      key,
                      iv
                    );
                  }
                };
              },
              desEncodeToBase64String: function(text, key, transformation, iv) {
                return __java_des_encode_b64(
                  String(text == null ? '' : text),
                  String(key || ''),
                  String(transformation || 'DES/ECB/PKCS5Padding'),
                  String(iv || '')
                );
              },
              aesBase64DecodeToString: function(text, key, transformation, iv) {
                return __java_aes_decode_b64(
                  String(text == null ? '' : text),
                  String(key || ''),
                  String(transformation || 'AES/CBC/PKCS5Padding'),
                  String(iv || '')
                );
              },
              encodeURI: function(text) { return __java_encode_uri(String(text == null ? '' : text)); },
              encodeURIComponent: function(text) { return __java_encode_uri_component(String(text == null ? '' : text)); },
              randomUUID: function() { return __java_uuid(); },
              log: function(msg) { return __java_log(msg); },
              toast: function(msg) { return __java_toast(msg); },
              longToast: function(msg) { return __java_toast(msg); },
              getCookie: function(url, key) { return __java_get_cookie(String(url || ''), key == null ? null : String(key)); },
              initUrl: function() { return __java_init_url(); },
              refreshTocUrl: function() { return __java_refresh_toc_url(); },
              refreshBookUrl: function() { return __java_refresh_book_url(); },
              post: function(url, body, headers) {
                var opt = { method: 'POST' };
                if (body != null) opt.body = String(body);
                if (headers != null) opt.headers = headers;
                return __java_ajax_response(String(url || '') + ',' + JSON.stringify(opt));
              },
              webView: function(arg1, arg2, arg3) { return __java_webview(arg1, arg2, arg3); },
              toURL: function(v) { var raw = String(v || ''); return { host: __java_host(raw) }; },
              connect: function(v) {
                var rawUrl = String(v || '');
                var options = { method: 'GET', headers: {} };
                var cachedResponse = null;
                var ensureResponse = function() {
                  cachedResponse = __java_connect_request(rawUrl, options);
                  return cachedResponse;
                };
                var resetResponse = function() {
                  cachedResponse = null;
                };
                var buildDataBody = function(dataValue) {
                  if (dataValue == null) return '';
                  if (typeof dataValue === 'string') return dataValue;
                  if (Array.isArray(dataValue)) {
                    return dataValue.map(function(item) { return String(item == null ? '' : item); }).join('&');
                  }
                  var pairs = [];
                  for (var key in dataValue) {
                    if (!Object.prototype.hasOwnProperty.call(dataValue, key)) continue;
                    pairs.push(encodeURIComponent(String(key)) + '=' + encodeURIComponent(String(dataValue[key] == null ? '' : dataValue[key])));
                  }
                  return pairs.join('&');
                };
                var api = {
                  raw: function() { return this; },
                  request: function() { return ensureResponse(); },
                  execute: function() { return ensureResponse(); },
                  url: function() { return ensureResponse().url(); },
                  body: function() { return ensureResponse().body(); },
                  text: function() { return ensureResponse().body(); },
                  code: function() { return ensureResponse().code(); },
                  statusCode: function() { return ensureResponse().code(); },
                  method: function(v2) { options.method = String(v2 || 'GET').toUpperCase(); resetResponse(); return this; },
                  header: function(name, value) {
                    if (arguments.length === 1) {
                      return ensureResponse().header(String(name || ''));
                    }
                    options.headers[String(name || '')] = String(value == null ? '' : value);
                    resetResponse();
                    return this;
                  },
                  headers: function(mapObj) {
                    if (!mapObj) return this;
                    for (var h in mapObj) {
                      if (Object.prototype.hasOwnProperty.call(mapObj, h)) {
                        options.headers[String(h || '')] = String(mapObj[h] == null ? '' : mapObj[h]);
                      }
                    }
                    resetResponse();
                    return this;
                  },
                  userAgent: function(v2) { options.headers['User-Agent'] = String(v2 == null ? '' : v2); resetResponse(); return this; },
                  referrer: function(v2) { options.headers['Referer'] = String(v2 == null ? '' : v2); resetResponse(); return this; },
                  cookie: function(v2) { options.headers['Cookie'] = String(v2 == null ? '' : v2); resetResponse(); return this; },
                  data: function(k, v2) {
                    if (arguments.length === 1) {
                      options.data = k;
                    } else {
                      if (!options.data || typeof options.data !== 'object' || Array.isArray(options.data)) {
                        options.data = {};
                      }
                      options.data[String(k || '')] = String(v2 == null ? '' : v2);
                    }
                    if (!options.method || String(options.method).toUpperCase() === 'GET') {
                      options.method = 'POST';
                    }
                    resetResponse();
                    return this;
                  },
                  requestBody: function(v2) { options.body = String(v2 == null ? '' : v2); resetResponse(); return this; },
                  postData: function(v2) {
                    options.body = buildDataBody(v2);
                    options.method = 'POST';
                    resetResponse();
                    return this;
                  },
                  timeout: function(v2) { options.timeout = v2; return this; },
                  ignoreContentType: function(v2) { options.ignoreContentType = v2 == null ? true : !!v2; return this; },
                  ignoreHttpErrors: function(v2) { options.ignoreHttpErrors = v2 == null ? true : !!v2; return this; },
                  followRedirects: function(v2) { options.followRedirects = v2 == null ? true : !!v2; return this; },
                  get: function() { options.method = 'GET'; return ensureResponse(); },
                  post: function() { options.method = 'POST'; return ensureResponse(); }
                };
                return api;
              }
            };
            """
        )
    }

    private static func normalizeJSValue(_ value: JSValue) -> String? {
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

    private static func setJavaVariable(key: String, value: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        javaStateLock.lock()
        javaState[trimmedKey] = value
        javaStateLock.unlock()
    }

    private static func getJavaVariable(key: String) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return "" }
        javaStateLock.lock()
        let value = javaState[trimmedKey] ?? ""
        javaStateLock.unlock()
        return value
    }

    private static func normalizedSourceStateKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "__default_source__"
        }
        return trimmed.lowercased()
    }

    @discardableResult
    private static func ensureSourceState(
        sourceKey: String,
        sourceHeader: String,
        defaultHeaders: [String: String]
    ) -> JavaSourceRuntimeState {
        let key = normalizedSourceStateKey(sourceKey)
        let baseHeaders = mergeHeaders(defaultHeaders, parseHeaderMap(sourceHeader))
        sourceStateLock.lock()
        var state = sourceRuntimeState[key] ?? JavaSourceRuntimeState(
            baseHeaders: baseHeaders,
            loginHeaders: [:],
            loginInfoMap: [:],
            variableBookMap: [:]
        )
        if !baseHeaders.isEmpty || state.baseHeaders.isEmpty {
            state.baseHeaders = baseHeaders
        }
        sourceRuntimeState[key] = state
        sourceStateLock.unlock()
        return state
    }

    private static func sourceHeaders(
        sourceKey: String,
        sourceHeader: String,
        defaultHeaders: [String: String]
    ) -> [String: String] {
        let key = normalizedSourceStateKey(sourceKey)
        _ = ensureSourceState(sourceKey: sourceKey, sourceHeader: sourceHeader, defaultHeaders: defaultHeaders)
        sourceStateLock.lock()
        let state = sourceRuntimeState[key]
        sourceStateLock.unlock()
        let base = state?.baseHeaders ?? mergeHeaders(defaultHeaders, parseHeaderMap(sourceHeader))
        let login = state?.loginHeaders ?? [:]
        return mergeHeaders(base, login)
    }

    private static func sourceHeaderString(
        sourceKey: String,
        sourceHeader: String,
        defaultHeaders: [String: String]
    ) -> String {
        let headers = sourceHeaders(sourceKey: sourceKey, sourceHeader: sourceHeader, defaultHeaders: defaultHeaders)
        return headerJSONString(headers)
    }

    private static func headerJSONString(_ headers: [String: String]) -> String {
        guard !headers.isEmpty else { return "{}" }
        if JSONSerialization.isValidJSONObject(headers),
           let data = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    private static func resolveRuntimeSourceHeader(
        rawSourceHeader: String,
        baseUrl: String,
        sourceKey: String,
        sourceComment: String?,
        sourceName: String?
    ) -> String {
        let trimmed = rawSourceHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let evaluated = evaluateDynamicRule(
            trimmed,
            key: nil,
            encodedKey: nil,
            page: 1,
            baseUrl: baseUrl,
            sourceKey: sourceKey,
            sourceHeader: nil,
            sourceComment: sourceComment,
            sourceName: sourceName
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed

        let parsed = parseHeaderMap(evaluated)
        if !parsed.isEmpty {
            return headerJSONString(parsed)
        }

        let fallbackParsed = parseHeaderMap(trimmed)
        if !fallbackParsed.isEmpty {
            return headerJSONString(fallbackParsed)
        }
        return evaluated
    }

    private static func putSourceLoginHeader(
        sourceKey: String,
        sourceHeader: String,
        defaultHeaders: [String: String],
        payload: Any?
    ) -> String {
        let key = normalizedSourceStateKey(sourceKey)
        _ = ensureSourceState(sourceKey: sourceKey, sourceHeader: sourceHeader, defaultHeaders: defaultHeaders)
        sourceStateLock.lock()
        var state = sourceRuntimeState[key] ?? JavaSourceRuntimeState(baseHeaders: [:], loginHeaders: [:], loginInfoMap: [:], variableBookMap: [:])
        let mapped = headersFromJavaPayload(payload)
        if !mapped.isEmpty {
            state.loginHeaders.merge(mapped) { _, new in new }
        } else {
            let text = stringifyJavaPayload(payload, fallback: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                state.loginHeaders["Cookie"] = normalizeSetCookieHeader(text)
            }
        }
        sourceRuntimeState[key] = state
        sourceStateLock.unlock()
        return headerJSONString(mergeHeaders(state.baseHeaders, state.loginHeaders))
    }

    private static func removeSourceLoginHeader(
        sourceKey: String,
        sourceHeader: String,
        defaultHeaders: [String: String],
        headerName: String?
    ) -> String {
        let key = normalizedSourceStateKey(sourceKey)
        _ = ensureSourceState(sourceKey: sourceKey, sourceHeader: sourceHeader, defaultHeaders: defaultHeaders)
        sourceStateLock.lock()
        var state = sourceRuntimeState[key] ?? JavaSourceRuntimeState(baseHeaders: [:], loginHeaders: [:], loginInfoMap: [:], variableBookMap: [:])
        let trimmed = headerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            state.loginHeaders.removeAll()
        } else if let found = state.loginHeaders.keys.first(where: { $0.lowercased() == trimmed.lowercased() }) {
            state.loginHeaders.removeValue(forKey: found)
        }
        sourceRuntimeState[key] = state
        sourceStateLock.unlock()
        return headerJSONString(mergeHeaders(state.baseHeaders, state.loginHeaders))
    }

    private static func sourceLoginInfoValue(sourceKey: String, key: String) -> String {
        let stateKey = normalizedSourceStateKey(sourceKey)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        sourceStateLock.lock()
        let value = sourceRuntimeState[stateKey]?.loginInfoMap[trimmed] ?? ""
        sourceStateLock.unlock()
        return value
    }

    @discardableResult
    private static func putSourceLoginInfo(sourceKey: String, key: String, value: Any?) -> String {
        let stateKey = normalizedSourceStateKey(sourceKey)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        sourceStateLock.lock()
        var state = sourceRuntimeState[stateKey] ?? JavaSourceRuntimeState(baseHeaders: [:], loginHeaders: [:], loginInfoMap: [:], variableBookMap: [:])
        let text = stringifyJavaPayload(value, fallback: "")
        state.loginInfoMap[trimmed] = text
        sourceRuntimeState[stateKey] = state
        sourceStateLock.unlock()
        return text
    }

    @discardableResult
    private static func removeSourceLoginInfo(sourceKey: String, key: String) -> String {
        let stateKey = normalizedSourceStateKey(sourceKey)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        sourceStateLock.lock()
        var state = sourceRuntimeState[stateKey] ?? JavaSourceRuntimeState(baseHeaders: [:], loginHeaders: [:], loginInfoMap: [:], variableBookMap: [:])
        let old = state.loginInfoMap.removeValue(forKey: trimmed) ?? ""
        sourceRuntimeState[stateKey] = state
        sourceStateLock.unlock()
        return old
    }

    private static func sourceLoginInfoKeys(sourceKey: String) -> [String] {
        let stateKey = normalizedSourceStateKey(sourceKey)
        sourceStateLock.lock()
        let keys = sourceRuntimeState[stateKey]?.loginInfoMap.keys.sorted() ?? []
        sourceStateLock.unlock()
        return keys
    }

    private static func sourceVariableBookValue(sourceKey: String, key: String) -> String {
        let stateKey = normalizedSourceStateKey(sourceKey)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        sourceStateLock.lock()
        let value = sourceRuntimeState[stateKey]?.variableBookMap[trimmed] ?? ""
        sourceStateLock.unlock()
        return value
    }

    @discardableResult
    private static func putSourceVariableBook(sourceKey: String, key: String, value: Any?) -> String {
        let stateKey = normalizedSourceStateKey(sourceKey)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        sourceStateLock.lock()
        var state = sourceRuntimeState[stateKey] ?? JavaSourceRuntimeState(baseHeaders: [:], loginHeaders: [:], loginInfoMap: [:], variableBookMap: [:])
        let text = stringifyJavaPayload(value, fallback: "")
        state.variableBookMap[trimmed] = text
        sourceRuntimeState[stateKey] = state
        sourceStateLock.unlock()
        return text
    }

    @discardableResult
    private static func removeSourceVariableBook(sourceKey: String, key: String) -> String {
        let stateKey = normalizedSourceStateKey(sourceKey)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        sourceStateLock.lock()
        var state = sourceRuntimeState[stateKey] ?? JavaSourceRuntimeState(baseHeaders: [:], loginHeaders: [:], loginInfoMap: [:], variableBookMap: [:])
        let old = state.variableBookMap.removeValue(forKey: trimmed) ?? ""
        sourceRuntimeState[stateKey] = state
        sourceStateLock.unlock()
        return old
    }

    private static func sourceVariableBookKeys(sourceKey: String) -> [String] {
        let stateKey = normalizedSourceStateKey(sourceKey)
        sourceStateLock.lock()
        let keys = sourceRuntimeState[stateKey]?.variableBookMap.keys.sorted() ?? []
        sourceStateLock.unlock()
        return keys
    }

    private static func headersFromJavaPayload(_ payload: Any?) -> [String: String] {
        if let direct = normalizeHeaders(payload) {
            return direct
        }
        let text = stringifyJavaPayload(payload, fallback: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }
        let parsed = parseHeaderMap(text)
        if !parsed.isEmpty {
            return parsed
        }
        return [:]
    }

    private static func normalizeSetCookieHeader(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let compact = trimmed.replacingOccurrences(of: "\r\n", with: "\n")
        let tokens = compact
            .components(separatedBy: "\n")
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let attrRegex = try? NSRegularExpression(pattern: ";\\s*(path|domain|expires|max-age|httponly|secure|samesite)=[^;]*", options: [.caseInsensitive])
        let bareAttrRegex = try? NSRegularExpression(pattern: ";\\s*(httponly|secure)", options: [.caseInsensitive])
        var cookies: [String] = []
        for token in tokens {
            var candidate = token
            if let attrRegex {
                let nsRange = NSRange(candidate.startIndex..., in: candidate)
                candidate = attrRegex.stringByReplacingMatches(in: candidate, options: [], range: nsRange, withTemplate: "")
            }
            if let bareAttrRegex {
                let nsRange = NSRange(candidate.startIndex..., in: candidate)
                candidate = bareAttrRegex.stringByReplacingMatches(in: candidate, options: [], range: nsRange, withTemplate: "")
            }
            candidate = candidate.replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains("="), !candidate.isEmpty {
                cookies.append(candidate)
            }
        }
        if cookies.isEmpty {
            return trimmed
        }
        return Array(Set(cookies)).joined(separator: "; ")
    }

    private static func normalizeURLForCookie(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.host != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private static func resolveCookieValue(siteURL: String, key: String) -> String {
        let cookieKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookieKey.isEmpty else { return "" }

        let normalizedSite = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSite.isEmpty {
            let stored = NetworkManager.shared.getCookies(for: normalizedSite)
            if let value = stored[cookieKey], !value.isEmpty {
                return value
            }
        }

        guard let targetURL = normalizeURLForCookie(normalizedSite) else { return "" }
        if let cookies = HTTPCookieStorage.shared.cookies(for: targetURL) {
            if let matched = cookies.first(where: { $0.name == cookieKey })?.value, !matched.isEmpty {
                return matched
            }
        }

        guard let host = targetURL.host?.lowercased() else { return "" }
        let allCookies = HTTPCookieStorage.shared.cookies ?? []
        for cookie in allCookies where cookie.name == cookieKey {
            let cookieDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if host == cookieDomain || host.hasSuffix(".\(cookieDomain)") {
                return cookie.value
            }
        }
        return ""
    }

    private static func removeCookie(siteURL: String) {
        let normalizedSite = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSite.isEmpty {
            NetworkManager.shared.saveCookies(from: normalizedSite, cookies: [:])
        }

        guard let targetURL = normalizeURLForCookie(normalizedSite) else { return }
        let storage = HTTPCookieStorage.shared
        if let cookies = storage.cookies(for: targetURL) {
            for cookie in cookies {
                storage.deleteCookie(cookie)
            }
        }
    }

    private static func formatTimestamp(_ raw: String, useUTC: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let number = Double(trimmed.replacingOccurrences(of: ",", with: "")) else { return trimmed }

        let seconds: TimeInterval
        if number > 10_000_000_000 {
            seconds = number / 1000.0
        } else {
            seconds = number
        }

        guard seconds.isFinite, seconds > 0 else { return trimmed }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = useUTC ? TimeZone(secondsFromGMT: 0) : TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func toNumChapter(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        guard let regex = try? NSRegularExpression(pattern: "第([零一二两三四五六七八九十百千万〇\\d]+)章") else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        if matches.isEmpty { return text }

        var output = text
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range, in: output),
                  let valueRange = Range(match.range(at: 1), in: output) else {
                continue
            }

            let rawNumber = String(output[valueRange])
            let number = Int(rawNumber) ?? chineseNumberToInt(rawNumber)
            guard let number else { continue }
            output.replaceSubrange(fullRange, with: "第\(number)章")
        }
        return output
    }

    private static func chineseNumberToInt(_ text: String) -> Int? {
        let digitMap: [Character: Int] = [
            "零": 0, "〇": 0,
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let unitMap: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10_000]

        var total = 0
        var section = 0
        var number = 0

        for char in text {
            if let digit = digitMap[char] {
                number = digit
                continue
            }

            if let unit = unitMap[char] {
                if unit == 10_000 {
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
        }

        let value = total + section + number
        return value > 0 ? value : nil
    }

    private static func buildCookieHeader(siteURL: String) -> String {
        guard let targetURL = normalizeURLForCookie(siteURL) else { return "" }
        guard let cookies = HTTPCookieStorage.shared.cookies(for: targetURL), !cookies.isEmpty else {
            return ""
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func mergeHeaders(_ lhs: [String: String], _ rhs: [String: String]) -> [String: String] {
        var merged = lhs
        merged.merge(rhs) { _, new in new }
        return merged
    }

    private struct JavaAjaxResult {
        let url: String
        let statusCode: Int
        let headers: [String: String]
        let body: String
    }

    private static func performJavaAjax(
        rawRule: String,
        baseUrl: String,
        sourceKey: String,
        sourceHeader: String,
        sourceComment: String,
        sourceName: String,
        defaultHeaders: [String: String]
    ) -> JavaAjaxResult {
        let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return JavaAjaxResult(url: "", statusCode: 0, headers: [:], body: "")
        }

        let descriptor = build(
            ruleUrl: trimmed,
            baseUrl: baseUrl,
            defaultHeaders: defaultHeaders,
            sourceKey: sourceKey,
            sourceHeader: sourceHeader,
            sourceComment: sourceComment,
            sourceName: sourceName
        )

        let semaphore = DispatchSemaphore(value: 0)
        final class JavaAjaxBox {
            var url: String = ""
            var statusCode: Int = 0
            var headers: [String: String] = [:]
            var body: String = ""
        }
        let box = JavaAjaxBox()
        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            if let response = try? await NetworkManager.shared.requestDetailed(
                url: descriptor.url,
                method: descriptor.method,
                headers: descriptor.headers,
                body: descriptor.body,
                retries: descriptor.retries,
                charset: descriptor.charset,
                allowNon200: true
            ) {
                box.url = response.url
                box.statusCode = response.statusCode
                box.headers = response.headers
                box.body = response.body
            }
        }
        _ = semaphore.wait(timeout: .now() + 45)
        return JavaAjaxResult(
            url: box.url.isEmpty ? descriptor.url : box.url,
            statusCode: box.statusCode,
            headers: box.headers,
            body: box.body
        )
    }

    private static func performJavaConnectRequest(
        rawRule: String,
        optionsPayload: Any?,
        baseUrl: String,
        sourceKey: String,
        sourceHeader: String,
        sourceComment: String,
        sourceName: String,
        defaultHeaders: [String: String]
    ) -> JavaAjaxResult {
        let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return JavaAjaxResult(url: "", statusCode: 0, headers: [:], body: "")
        }

        let options = dictionaryFromJavaPayload(optionsPayload)
        let descriptor = build(
            ruleUrl: trimmed,
            baseUrl: baseUrl,
            defaultHeaders: defaultHeaders,
            sourceKey: sourceKey,
            sourceHeader: sourceHeader,
            sourceComment: sourceComment,
            sourceName: sourceName
        )

        var requestURL = descriptor.url
        var method = descriptor.method
        var headers = descriptor.headers
        var body = descriptor.body
        var retries = descriptor.retries
        var charset = descriptor.charset
        var allowNon200 = true
        var followRedirects = true
        var timeout: TimeInterval?

        if let forcedMethod = options["method"] as? String,
           !forcedMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            method = forcedMethod.uppercased()
        }

        if let overrideHeaders = normalizeHeaders(options["headers"] ?? options["header"]) {
            headers.merge(overrideHeaders) { _, new in new }
        }

        if let userAgent = options["userAgent"] as? String, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }
        if let referrer = options["referrer"] as? String, !referrer.isEmpty {
            headers["Referer"] = referrer
        }
        if let cookie = options["cookie"] as? String, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }

        var bodyFromDataOnly = false
        if let explicitBody = stringifyBody(options["body"] ?? options["requestBody"] ?? options["postData"]) {
            body = explicitBody
            bodyFromDataOnly = false
        } else if let formData = options["data"], let encoded = formBody(from: formData), !encoded.isEmpty {
            body = encoded
            bodyFromDataOnly = true
            if method == "GET" {
                requestURL = appendQuery(requestURL, query: encoded)
                body = nil
            }
        }

        if method != "GET", bodyFromDataOnly, headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        }

        if let retryValue = parseInt(options["retry"] ?? options["retries"]) {
            retries = max(1, retryValue)
        }
        if let charsetValue = options["charset"] as? String,
           !charsetValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            charset = charsetValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let explicitURL = options["url"] as? String,
           !explicitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestURL = makeAbsoluteUrl(explicitURL, baseUrl: baseUrl)
        }
        if let ignoreErrors = parseBool(options["ignoreHttpErrors"] ?? options["ignoreHttpError"]) {
            allowNon200 = ignoreErrors
        }
        if let follow = parseBool(options["followRedirects"] ?? options["followRedirect"]) {
            followRedirects = follow
        }
        if let timeoutValue = parseDouble(options["timeout"]), timeoutValue > 0 {
            // Jsoup/Legado timeout is milliseconds.
            timeout = max(0.25, timeoutValue / 1000.0)
        }

        let semaphore = DispatchSemaphore(value: 0)
        final class JavaAjaxBox {
            var url: String = ""
            var statusCode: Int = 0
            var headers: [String: String] = [:]
            var body: String = ""
        }
        let box = JavaAjaxBox()
        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            if let response = try? await NetworkManager.shared.requestDetailed(
                url: requestURL,
                method: method,
                headers: headers,
                body: body,
                retries: retries,
                charset: charset,
                allowNon200: allowNon200,
                timeout: timeout,
                followRedirects: followRedirects
            ) {
                box.url = response.url
                box.statusCode = response.statusCode
                box.headers = response.headers
                box.body = response.body
            }
        }
        _ = semaphore.wait(timeout: .now() + 45)
        return JavaAjaxResult(
            url: box.url.isEmpty ? requestURL : box.url,
            statusCode: box.statusCode,
            headers: box.headers,
            body: box.body
        )
    }

    private static func formBody(from payload: Any) -> String? {
        if let string = payload as? String {
            return string
        }
        if let map = payload as? [String: Any] {
            let pairs = map.map { key, value -> String in
                let encodedKey = encodeURIComponent(key)
                let encodedValue = encodeURIComponent(stringifyBody(value) ?? "")
                return "\(encodedKey)=\(encodedValue)"
            }
            return pairs.joined(separator: "&")
        }
        if let map = payload as? [String: String] {
            let pairs = map.map { key, value in
                "\(encodeURIComponent(key))=\(encodeURIComponent(value))"
            }
            return pairs.joined(separator: "&")
        }
        if let array = payload as? [[String: Any]] {
            let pairs = array.compactMap { dict -> String? in
                let key = stringifyBody(dict["key"] ?? dict["name"]) ?? ""
                guard !key.isEmpty else { return nil }
                let value = stringifyBody(dict["value"]) ?? ""
                return "\(encodeURIComponent(key))=\(encodeURIComponent(value))"
            }
            return pairs.joined(separator: "&")
        }
#if canImport(JavaScriptCore)
        if let jsValue = payload as? JSValue {
            if let array = jsValue.toArray() {
                return formBody(from: array)
            }
            if let object = jsValue.toObject() {
                return formBody(from: object)
            }
        }
#endif
        if let array = payload as? [Any] {
            let items = array.compactMap { stringifyBody($0) }.filter { !$0.isEmpty }
            return items.joined(separator: "&")
        }
        return stringifyBody(payload)
    }

    private static func dictionaryFromJavaPayload(_ payload: Any?) -> [String: Any] {
        guard let payload else { return [:] }

        if let map = payload as? [String: Any] {
            return map
        }
        if let map = payload as? [String: String] {
            return map.reduce(into: [:]) { partial, item in
                partial[item.key] = item.value
            }
        }
#if canImport(JavaScriptCore)
        if let jsValue = payload as? JSValue {
            if let object = jsValue.toObject() as? [String: Any] {
                return object
            }
            if let array = jsValue.toArray() {
                return ["data": array]
            }
            if let raw = jsValue.toString(), !raw.isEmpty {
                let parsed = parseJSONObject(raw)
                if !parsed.isEmpty {
                    return parsed
                }
            }
        }
#endif
        if let text = payload as? String {
            return parseJSONObject(text)
        }
        return [:]
    }

    private static func resolveJavaGetString(
        path: String,
        payload: Any?,
        fallbackPayload: String,
        baseUrl: String,
        elementContext: Element?
    ) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadText = stringifyJavaPayload(payload, fallback: fallbackPayload)

        if trimmedPath.isEmpty {
            return payloadText
        }

        if trimmedPath.hasPrefix("$") {
            return resolveJSONString(path: trimmedPath, payload: payloadText)
        }

        let roots = resolveJavaRoots(payload: payload, fallbackPayload: fallbackPayload, baseUrl: baseUrl, elementContext: elementContext)
        if let first = roots.first,
           let value = try? RuleAnalyzer.shared.analyzeElement(element: first, rule: trimmedPath, baseUrl: baseUrl),
           !value.isEmpty {
            return value
        }

        let htmlValue = RuleAnalyzer.shared.analyzeElementText(html: payloadText, rule: trimmedPath, baseUrl: baseUrl)
        if !htmlValue.isEmpty {
            return htmlValue
        }

        return resolveJSONString(path: trimmedPath, payload: payloadText)
    }

    private static func resolveJavaGetStringList(
        path: String,
        payload: Any?,
        fallbackPayload: String,
        baseUrl: String,
        elementContext: Element?
    ) -> [String] {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return [] }

        let payloadText = stringifyJavaPayload(payload, fallback: fallbackPayload)
        if trimmedPath.hasPrefix("$") {
            return resolveJSONStringList(path: trimmedPath, payload: payloadText)
        }

        let roots = resolveJavaRoots(payload: payload, fallbackPayload: fallbackPayload, baseUrl: baseUrl, elementContext: elementContext)
        if !roots.isEmpty {
            let values = roots.compactMap { root -> String? in
                let value = try? RuleAnalyzer.shared.analyzeElement(element: root, rule: trimmedPath, baseUrl: baseUrl)
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            if !values.isEmpty {
                return values
            }
        }

        let parsed = RuleAnalyzer.shared.analyzeElementText(html: payloadText, rule: trimmedPath, baseUrl: baseUrl)
        if !parsed.isEmpty {
            return parsed.split(separator: "\n").map { String($0) }
        }
        return []
    }

    private static func resolveJavaGetElements(
        rule: String,
        payload: Any?,
        fallbackPayload: String,
        baseUrl: String,
        elementContext: Element?
    ) -> [JavaElementBox] {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return [] }

        var htmlCandidates: [String] = []
        let roots = resolveJavaRoots(payload: payload, fallbackPayload: fallbackPayload, baseUrl: baseUrl, elementContext: elementContext)
        if !roots.isEmpty {
            for root in roots {
                if let html = try? root.outerHtml(), !html.isEmpty {
                    htmlCandidates.append(html)
                }
            }
        } else {
            let fallbackHTML = stringifyJavaPayload(payload, fallback: fallbackPayload)
            if !fallbackHTML.isEmpty {
                htmlCandidates.append(fallbackHTML)
            }
        }

        var output: [JavaElementBox] = []
        var seen = Set<String>()
        for html in htmlCandidates {
            let elements = (try? RuleAnalyzer.shared.analyzeList(html: html, rule: trimmedRule, baseUrl: baseUrl)) ?? []
            for element in elements {
                let outer = (try? element.outerHtml()) ?? ""
                if seen.insert(outer).inserted {
                    output.append(JavaElementBox(element: element))
                }
            }
        }
        return output
    }

    private static func resolveJavaRoots(
        payload: Any?,
        fallbackPayload: String,
        baseUrl: String,
        elementContext: Element?
    ) -> [Element] {
        if payload == nil {
            if let elementContext {
                return [elementContext]
            }
            if let body = try? SwiftSoup.parse(fallbackPayload, baseUrl).body() {
                return [body]
            }
            return []
        }

        if let box = payload as? JavaElementBox, let element = box.asElement() {
            return [element]
        }

        if let array = payload as? [JavaElementBox] {
            return array.compactMap { $0.asElement() }
        }

        if let array = payload as? [Any] {
            let mapped = array.compactMap { item -> Element? in
                if let box = item as? JavaElementBox {
                    return box.asElement()
                }
                if let string = item as? String,
                   let body = try? SwiftSoup.parse(string, baseUrl).body() {
                    return body
                }
                return nil
            }
            if !mapped.isEmpty {
                return mapped
            }
        }

        let payloadText = stringifyJavaPayload(payload, fallback: fallbackPayload)
        if let body = try? SwiftSoup.parse(payloadText, baseUrl).body() {
            return [body]
        }
        return []
    }

    private static func stringifyJavaPayload(_ payload: Any?, fallback: String) -> String {
        guard let payload else { return fallback }
        if let string = payload as? String {
            return string
        }
        if let box = payload as? JavaElementBox {
            return box.outerHtml()
        }
        if let array = payload as? [JavaElementBox] {
            return array.map { $0.outerHtml() }.joined(separator: "\n")
        }
        if let array = payload as? [Any] {
            return array.map { stringifyJavaPayload($0, fallback: "") }.joined(separator: "\n")
        }
#if canImport(JavaScriptCore)
        if let value = payload as? JSValue {
            if value.isString {
                return value.toString() ?? fallback
            }
            if value.isArray, let array = value.toArray() {
                return array.map { stringifyJavaPayload($0, fallback: "") }.joined(separator: "\n")
            }
            if value.isObject, let object = value.toObject() {
                if JSONSerialization.isValidJSONObject(object),
                   let data = try? JSONSerialization.data(withJSONObject: object),
                   let string = String(data: data, encoding: .utf8) {
                    return string
                }
            }
        }
#endif
        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(payload)"
    }

    private static func stringArray(from payload: Any?) -> [String] {
        guard let payload else { return [] }
        if let array = payload as? [String] {
            return array
        }
        if let array = payload as? [Any] {
            return array.map { stringifyJavaPayload($0, fallback: "") }.filter { !$0.isEmpty }
        }
#if canImport(JavaScriptCore)
        if let jsValue = payload as? JSValue, let array = jsValue.toArray() {
            return array.map { stringifyJavaPayload($0, fallback: "") }.filter { !$0.isEmpty }
        }
#endif
        if let text = payload as? String, !text.isEmpty {
            return [text]
        }
        return []
    }

    private static func encodeURI(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? raw
    }

    private static func encodeURIComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private static func md5Hex(_ input: String) -> String {
#if canImport(CryptoKit)
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
#elseif canImport(CommonCrypto)
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_MD5(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
#else
        return input
#endif
    }

    private static func hmacHex(text: String, algorithm: String, key: String) -> String {
#if canImport(CommonCrypto)
        let upper = algorithm.uppercased()
        let alg: CCHmacAlgorithm
        let length: Int
        switch upper {
        case "HMACSHA1", "SHA1":
            alg = CCHmacAlgorithm(kCCHmacAlgSHA1)
            length = Int(CC_SHA1_DIGEST_LENGTH)
        case "HMACSHA224", "SHA224":
            alg = CCHmacAlgorithm(kCCHmacAlgSHA224)
            length = Int(CC_SHA224_DIGEST_LENGTH)
        case "HMACSHA384", "SHA384":
            alg = CCHmacAlgorithm(kCCHmacAlgSHA384)
            length = Int(CC_SHA384_DIGEST_LENGTH)
        case "HMACSHA512", "SHA512":
            alg = CCHmacAlgorithm(kCCHmacAlgSHA512)
            length = Int(CC_SHA512_DIGEST_LENGTH)
        case "HMACMD5", "MD5":
            alg = CCHmacAlgorithm(kCCHmacAlgMD5)
            length = Int(CC_MD5_DIGEST_LENGTH)
        default:
            alg = CCHmacAlgorithm(kCCHmacAlgSHA256)
            length = Int(CC_SHA256_DIGEST_LENGTH)
        }

        let keyData = Data(key.utf8)
        let textData = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: length)
        keyData.withUnsafeBytes { keyBytes in
            textData.withUnsafeBytes { textBytes in
                CCHmac(
                    alg,
                    keyBytes.baseAddress,
                    keyData.count,
                    textBytes.baseAddress,
                    textData.count,
                    &digest
                )
            }
        }
        return digest.map { String(format: "%02x", $0) }.joined()
#else
        return ""
#endif
    }

    private static func hmacBase64(text: String, algorithm: String, key: String) -> String {
#if canImport(CommonCrypto)
        let upper = algorithm.uppercased()
        let alg: CCHmacAlgorithm
        let length: Int
        switch upper {
        case "HMACSHA1", "SHA1":
            alg = CCHmacAlgorithm(kCCHmacAlgSHA1)
            length = Int(CC_SHA1_DIGEST_LENGTH)
        case "HMACSHA224", "SHA224":
            alg = CCHmacAlgorithm(kCCHmacAlgSHA224)
            length = Int(CC_SHA224_DIGEST_LENGTH)
        case "HMACSHA384", "SHA384":
            alg = CCHmacAlgorithm(kCCHmacAlgSHA384)
            length = Int(CC_SHA384_DIGEST_LENGTH)
        case "HMACSHA512", "SHA512":
            alg = CCHmacAlgorithm(kCCHmacAlgSHA512)
            length = Int(CC_SHA512_DIGEST_LENGTH)
        case "HMACMD5", "MD5":
            alg = CCHmacAlgorithm(kCCHmacAlgMD5)
            length = Int(CC_MD5_DIGEST_LENGTH)
        default:
            alg = CCHmacAlgorithm(kCCHmacAlgSHA256)
            length = Int(CC_SHA256_DIGEST_LENGTH)
        }

        let keyData = Data(key.utf8)
        let textData = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: length)
        keyData.withUnsafeBytes { keyBytes in
            textData.withUnsafeBytes { textBytes in
                CCHmac(
                    alg,
                    keyBytes.baseAddress,
                    keyData.count,
                    textBytes.baseAddress,
                    textData.count,
                    &digest
                )
            }
        }
        return Data(digest).base64EncodedString()
#else
        return ""
#endif
    }

    private static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private static func base64DecodeToString(_ text: String) -> String {
        guard let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) else {
            return ""
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return ""
    }

    private static func base64DecodeToByteArray(_ text: String) -> [Int] {
        guard let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) else {
            return []
        }
        return data.map { Int($0) }
    }

    private static func hexDecodeToString(_ text: String) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)

        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let pair = String(cleaned[index..<next])
            guard let byte = UInt8(pair, radix: 16) else { return "" }
            bytes.append(byte)
            index = next
        }
        let data = Data(bytes)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return ""
    }

    private static func dataFromJavaBytePayload(_ payload: Any?) -> Data? {
        guard let payload else { return nil }
        if let data = payload as? Data {
            return data
        }
        if let array = payload as? [Int] {
            let bytes = array.map { UInt8(clamping: $0) }
            return Data(bytes)
        }
        if let array = payload as? [NSNumber] {
            let bytes = array.map { UInt8(clamping: $0.intValue) }
            return Data(bytes)
        }
        if let text = payload as? String {
            return Data(text.utf8)
        }
#if canImport(JavaScriptCore)
        if let jsValue = payload as? JSValue {
            if let array = jsValue.toArray() {
                let bytes = array.compactMap { item -> UInt8? in
                    if let num = item as? NSNumber { return UInt8(clamping: num.intValue) }
                    if let int = item as? Int { return UInt8(clamping: int) }
                    if let string = item as? String, let int = Int(string) { return UInt8(clamping: int) }
                    return nil
                }
                if !bytes.isEmpty {
                    return Data(bytes)
                }
            }
            if let string = jsValue.toString(), !string.isEmpty {
                return Data(string.utf8)
            }
        }
#endif
        return nil
    }

    private static func symmetricBase64Decrypt(
        text: String,
        transformation: String,
        keyPayload: Any?,
        ivPayload: Any?
    ) -> String {
#if canImport(CommonCrypto)
        guard let encrypted = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) else {
            return ""
        }
        guard let keyData = dataFromJavaBytePayload(keyPayload), !keyData.isEmpty else {
            return ""
        }
        let parsed = parseTransformation(transformation, defaultAlgorithm: .aes)
        guard parsed.algorithm.isValidKeyLength(keyData.count) else {
            return ""
        }

        var options: CCOptions = 0
        if parsed.mode == .ecb {
            options |= CCOptions(kCCOptionECBMode)
        }
        if parsed.padding != .noPadding {
            options |= CCOptions(kCCOptionPKCS7Padding)
        }

        var ivData: Data?
        if parsed.mode == .cbc {
            if let parsedIV = dataFromJavaBytePayload(ivPayload), parsedIV.count == parsed.algorithm.blockSize {
                ivData = parsedIV
            }
        }

        let outputCapacity = encrypted.count + parsed.algorithm.blockSize
        var output = Data(count: outputCapacity)
        var outputLength: size_t = 0

        let status = output.withUnsafeMutableBytes { outBytes in
            encrypted.withUnsafeBytes { inputBytes in
                keyData.withUnsafeBytes { keyBytes in
                    if let ivData {
                        return ivData.withUnsafeBytes { ivBytes in
                            CCCrypt(
                                CCOperation(kCCDecrypt),
                                parsed.algorithm.cc,
                                options,
                                keyBytes.baseAddress,
                                keyData.count,
                                ivBytes.baseAddress,
                                inputBytes.baseAddress,
                                encrypted.count,
                                outBytes.baseAddress,
                                outputCapacity,
                                &outputLength
                            )
                        }
                    } else {
                        return CCCrypt(
                            CCOperation(kCCDecrypt),
                            parsed.algorithm.cc,
                            options,
                            keyBytes.baseAddress,
                            keyData.count,
                            nil,
                            inputBytes.baseAddress,
                            encrypted.count,
                            outBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return "" }
        output.count = outputLength
        if let utf8 = String(data: output, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: output, encoding: .isoLatin1) {
            return latin1
        }
        return ""
#else
        return ""
#endif
    }

    private enum CryptoAlgorithm {
        case aes
        case des

        var cc: CCAlgorithm {
            switch self {
            case .aes:
                return CCAlgorithm(kCCAlgorithmAES)
            case .des:
                return CCAlgorithm(kCCAlgorithmDES)
            }
        }

        var blockSize: Int {
            switch self {
            case .aes:
                return kCCBlockSizeAES128
            case .des:
                return kCCBlockSizeDES
            }
        }

        func isValidKeyLength(_ length: Int) -> Bool {
            switch self {
            case .aes:
                return length == kCCKeySizeAES128 || length == kCCKeySizeAES192 || length == kCCKeySizeAES256
            case .des:
                return length == kCCKeySizeDES
            }
        }
    }

    private enum CryptoMode: String {
        case ecb = "ECB"
        case cbc = "CBC"
    }

    private enum CryptoPadding: String {
        case pkcs5 = "PKCS5PADDING"
        case pkcs7 = "PKCS7PADDING"
        case noPadding = "NOPADDING"
    }

    private struct CryptoTransformation {
        let algorithm: CryptoAlgorithm
        let mode: CryptoMode
        let padding: CryptoPadding
    }

    private static func parseTransformation(_ transformation: String, defaultAlgorithm: CryptoAlgorithm) -> CryptoTransformation {
        let trimmed = transformation.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/").map { String($0).uppercased() }

        let algorithm: CryptoAlgorithm
        if let first = parts.first {
            switch first {
            case "AES":
                algorithm = .aes
            case "DES":
                algorithm = .des
            default:
                algorithm = defaultAlgorithm
            }
        } else {
            algorithm = defaultAlgorithm
        }

        let mode = parts.count > 1 ? (CryptoMode(rawValue: parts[1]) ?? .ecb) : .ecb
        let padding = parts.count > 2 ? (CryptoPadding(rawValue: parts[2]) ?? .pkcs5) : .pkcs5
        return CryptoTransformation(algorithm: algorithm, mode: mode, padding: padding)
    }

    private static func runCrypt(
        operation: CCOperation,
        input: Data,
        key: Data,
        transformation: String,
        iv: String,
        defaultAlgorithm: CryptoAlgorithm
    ) -> Data? {
#if canImport(CommonCrypto)
        let parsed = parseTransformation(transformation, defaultAlgorithm: defaultAlgorithm)
        guard parsed.algorithm.isValidKeyLength(key.count) else { return nil }

        var options: CCOptions = 0
        if parsed.mode == .ecb {
            options |= CCOptions(kCCOptionECBMode)
        }
        if parsed.padding != .noPadding {
            options |= CCOptions(kCCOptionPKCS7Padding)
        }

        let ivData: Data?
        if parsed.mode == .cbc {
            let rawIV = Data(iv.utf8)
            if rawIV.count == parsed.algorithm.blockSize {
                ivData = rawIV
            } else {
                ivData = nil
            }
        } else {
            ivData = nil
        }

        let outputCapacity = input.count + parsed.algorithm.blockSize
        var output = Data(count: outputCapacity)
        var outputLength: size_t = 0

        let status = output.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    if let ivData {
                        return ivData.withUnsafeBytes { ivBytes in
                            CCCrypt(
                                operation,
                                parsed.algorithm.cc,
                                options,
                                keyBytes.baseAddress,
                                key.count,
                                ivBytes.baseAddress,
                                inputBytes.baseAddress,
                                input.count,
                                outBytes.baseAddress,
                                outputCapacity,
                                &outputLength
                            )
                        }
                    } else {
                        return CCCrypt(
                            operation,
                            parsed.algorithm.cc,
                            options,
                            keyBytes.baseAddress,
                            key.count,
                            nil,
                            inputBytes.baseAddress,
                            input.count,
                            outBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        output.count = outputLength
        return output
#else
        return nil
#endif
    }

    private static func desEncodeToBase64String(text: String, key: String, transformation: String, iv: String) -> String {
#if canImport(CommonCrypto)
        guard let encrypted = runCrypt(
            operation: CCOperation(kCCEncrypt),
            input: Data(text.utf8),
            key: Data(key.utf8),
            transformation: transformation,
            iv: iv,
            defaultAlgorithm: .des
        ) else {
            return ""
        }
        return encrypted.base64EncodedString()
#else
        return ""
#endif
    }

    private static func aesBase64DecodeToString(text: String, key: String, transformation: String, iv: String) -> String {
#if canImport(CommonCrypto)
        guard let encrypted = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]),
              let decrypted = runCrypt(
                operation: CCOperation(kCCDecrypt),
                input: encrypted,
                key: Data(key.utf8),
                transformation: transformation,
                iv: iv,
                defaultAlgorithm: .aes
              ) else {
            return ""
        }
        if let utf8 = String(data: decrypted, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: decrypted, encoding: .isoLatin1) {
            return latin1
        }
        return ""
#else
        return ""
#endif
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

    private static func resolveJSONString(path: String, payload: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "" }

        if !trimmedPath.hasPrefix("$") {
            return getJavaVariable(key: trimmedPath)
        }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return ""
        }

        let tokens = parseJSONPathTokens(trimmedPath)
        var current: [Any] = [object]

        for token in tokens {
            switch token {
            case .child(let key):
                current = current.flatMap { node in
                    if let dict = node as? [String: Any], let value = dict[key] {
                        return [value]
                    }
                    if let array = node as? [Any] {
                        return array.compactMap { item in
                            (item as? [String: Any])?[key]
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
                    let resolved = index >= 0 ? index : array.count + index
                    guard resolved >= 0 && resolved < array.count else { return nil }
                    return array[resolved]
                }
            case .indexWildcard:
                current = current.flatMap { ($0 as? [Any]) ?? [] }
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

        guard let first = current.first else { return "" }
        return jsonNodeToString(first)
    }

    private static func resolveJSONStringList(path: String, payload: String) -> [String] {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return [] }

        if !trimmedPath.hasPrefix("$") {
            let value = getJavaVariable(key: trimmedPath)
            return value.isEmpty ? [] : [value]
        }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let tokens = parseJSONPathTokens(trimmedPath)
        var current: [Any] = [object]

        for token in tokens {
            switch token {
            case .child(let key):
                current = current.flatMap { node in
                    if let dict = node as? [String: Any], let value = dict[key] {
                        return [value]
                    }
                    if let array = node as? [Any] {
                        return array.compactMap { item in
                            (item as? [String: Any])?[key]
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
                    let resolved = index >= 0 ? index : array.count + index
                    guard resolved >= 0 && resolved < array.count else { return nil }
                    return array[resolved]
                }
            case .indexWildcard:
                current = current.flatMap { ($0 as? [Any]) ?? [] }
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

        return current.map { jsonNodeToString($0) }
    }

    private static func recursiveCollect(node: Any, key: String) -> [Any] {
        var result: [Any] = []
        if let dict = node as? [String: Any] {
            for (k, value) in dict {
                if key == "*" || k == key {
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

    private static func parseJSONPathTokens(_ path: String) -> [JSONPathToken] {
        var cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("@json:") {
            cleaned = String(cleaned.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned == "$" { return [] }
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
                    tokens.append(.child(String(content.dropFirst().dropLast())))
                }
                index = cleaned.index(after: end)
                continue
            }

            index = cleaned.index(after: index)
        }
        return tokens
    }

    private static func readJSONIdentifier(from text: String, index: inout String.Index) -> String {
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

    private static func findJSONPathBracketEnd(in text: String, from start: String.Index) -> String.Index? {
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

    private static func evaluateJSONPathFilter(expression: String, node: Any) -> Bool {
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
            let rhs = parseJSONFilterLiteral(String(trimmed[valueRange]))
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

    private static func splitFilterExpression(_ expression: String, separator: String) -> [String] {
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

    private static func jsonValue(for keyPath: String, in node: Any) -> Any? {
        let keys = keyPath.split(separator: ".").map(String.init)
        guard !keys.isEmpty else { return nil }
        var current: Any? = node
        for key in keys {
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else {
                return nil
            }
        }
        return current
    }

    private static func parseJSONFilterLiteral(_ raw: String) -> Any {
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

    private static func compareJSONFilterValues(lhs: Any, rhs: Any) -> Bool {
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

    private static func jsonNodeToString(_ node: Any) -> String {
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

    private static func parseJSONObject(_ raw: String) -> [String: Any] {
        if let object = parseJSONObjectData(raw.data(using: .utf8)) {
            return object
        }

        let normalizedQuotes = raw.replacingOccurrences(of: "'", with: "\"")
        if let object = parseJSONObjectData(normalizedQuotes.data(using: .utf8)) {
            return object
        }

        return [:]
    }

    private static func parseJSONObjectData(_ data: Data?) -> [String: Any]? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func normalizeHeaders(_ value: Any?) -> [String: String]? {
        guard let value else { return nil }

        if let map = value as? [String: Any] {
            return map.reduce(into: [:]) { partialResult, item in
                partialResult[item.key] = "\(item.value)"
            }
        }

        if let map = value as? [String: String] {
            return map
        }

        if let stringValue = value as? String {
            let parsed = parseHeaderMap(stringValue)
            return parsed.isEmpty ? nil : parsed
        }

        return nil
    }

    private static func stringifyBody(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(value)"
    }

    private static func parseInt(_ value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        switch value {
        case let doubleValue as Double:
            return doubleValue
        case let floatValue as Float:
            return Double(floatValue)
        case let intValue as Int:
            return Double(intValue)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func parseBool(_ value: Any?) -> Bool? {
        switch value {
        case let boolValue as Bool:
            return boolValue
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "y", "on"].contains(normalized) {
                return true
            }
            if ["0", "false", "no", "n", "off"].contains(normalized) {
                return false
            }
            return nil
        default:
            return nil
        }
    }

    private static func appendQuery(_ url: String, query: String) -> String {
        guard !query.isEmpty else { return url }
        return url.contains("?") ? "\(url)&\(query)" : "\(url)?\(query)"
    }

    private static func makeAbsoluteUrl(_ url: String, baseUrl: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }

        if trimmed.hasPrefix("//") {
            let scheme = URL(string: baseUrl)?.scheme ?? "https"
            return "\(scheme):\(trimmed)"
        }

        if let absolute = URL(string: trimmed, relativeTo: URL(string: baseUrl))?.absoluteURL {
            return absolute.absoluteString
        }

        return trimmed
    }
}

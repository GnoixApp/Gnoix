import Foundation
import SwiftSoup

class RuleEvaluator {
    static let shared = RuleEvaluator()
    
    private let analyzer = RuleAnalyzer.shared
    
    private init() {}
    
    func evalRule(rule: String, html: String, baseUrl: String = "", variables: [String: Any] = [:]) -> String {
        var processedRule = rule
        for (key, value) in variables {
            processedRule = processedRule.replacingOccurrences(of: "{{\(key)}}", with: "\(value)")
        }
        
        return analyzer.analyzeElementText(html: html, rule: processedRule, baseUrl: baseUrl)
    }
    
    func evalElements(rule: String, html: String, baseUrl: String = "", variables: [String: Any] = [:]) throws -> [Element] {
        var processedRule = rule
        for (key, value) in variables {
            processedRule = processedRule.replacingOccurrences(of: "{{\(key)}}", with: "\(value)")
        }
        
        return try analyzer.analyzeList(html: html, rule: processedRule, baseUrl: baseUrl)
    }
}

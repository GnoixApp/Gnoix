import Foundation
import FeedKit

struct RSSSource: Codable, Identifiable {
    var id: String { sourceUrl }
    var sourceUrl: String = ""
    var sourceName: String = ""
    var sourceGroup: String?
    var enabled: Bool = true
    var customOrder: Int = 0
    var lastUpdateTime: Int64 = 0
    var ruleArticles: String?
    var ruleTitle: String?
    var ruleUrl: String?
    var ruleImage: String?
    var ruleContent: String?
    var rulePubDate: String?
    var ruleCategory: String?
}

struct RSSArticle: Codable, Identifiable {
    var id: String { url }
    var url: String = ""
    var title: String = ""
    var image: String?
    var content: String?
    var publishDate: Date?
    var category: String?
    var sourceUrl: String = ""
    var read: Bool = false
    var star: Bool = false
}

class RSSManager {
    static let shared = RSSManager()
    
    private let database = DatabaseManager.shared
    private var sources: [RSSSource] = []
    private let rssSourcesKey = "rss_sources"
    
    private init() {
        loadSources()
    }
    
    private func loadSources() {
        if let data = UserDefaults.standard.data(forKey: rssSourcesKey),
           let loaded = try? JSONDecoder().decode([RSSSource].self, from: data) {
            sources = loaded
        }
    }
    
    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: rssSourcesKey)
        }
    }
    
    func getAllSources() -> [RSSSource] {
        return sources.filter { $0.enabled }.sorted { $0.customOrder < $1.customOrder }
    }

    func getAllStoredSources() -> [RSSSource] {
        return sources.sorted { $0.customOrder < $1.customOrder }
    }
    
    func getSources(inGroup group: String?) -> [RSSSource] {
        return sources.filter { $0.enabled && $0.sourceGroup == group }
    }
    
    func addSource(_ source: RSSSource) {
        sources.append(source)
        saveSources()
    }
    
    func deleteSource(_ sourceUrl: String) {
        sources.removeAll { $0.sourceUrl == sourceUrl }
        saveSources()
    }
    
    func updateSource(_ source: RSSSource) {
        if let index = sources.firstIndex(where: { $0.sourceUrl == source.sourceUrl }) {
            sources[index] = source
            saveSources()
        }
    }
    
    func refreshAll() async -> [String: [RSSArticle]] {
        var results: [String: [RSSArticle]] = [:]
        
        for source in getAllSources() {
            let articles = await fetchArticles(from: source)
            results[source.sourceUrl] = articles
        }
        
        return results
    }
    
    func fetchArticles(from source: RSSSource) async -> [RSSArticle] {
        guard let url = URL(string: source.sourceUrl) else { return [] }
        
        return await withCheckedContinuation { continuation in
            let parser = FeedParser(URL: url)
            parser.parseAsync { result in
                var articles: [RSSArticle] = []
                
                switch result {
                case .success(let feed):
                    if let rssFeed = feed.rssFeed {
                        for item in rssFeed.items ?? [] {
                            var article = RSSArticle()
                            article.title = item.title ?? ""
                            article.url = item.link ?? ""
                            article.content = item.description ?? item.content?.contentEncoded
                            article.publishDate = item.pubDate
                            article.sourceUrl = source.sourceUrl
                            
                            if let enclosure = item.enclosure, enclosure.attributes?.type?.hasPrefix("image") == true {
                                article.image = enclosure.attributes?.url
                            }
                            
                            articles.append(article)
                        }
                    } else if let atomFeed = feed.atomFeed {
                        for entry in atomFeed.entries ?? [] {
                            var article = RSSArticle()
                            article.title = entry.title ?? ""
                            article.url = entry.links?.first?.attributes?.href ?? ""
                            article.content = entry.content?.value
                            article.publishDate = entry.published
                            article.sourceUrl = source.sourceUrl
                            articles.append(article)
                        }
                    }
                case .failure:
                    break
                }
                
                continuation.resume(returning: articles)
            }
        }
    }
    
    func importFromJson(_ jsonString: String) -> Int {
        guard let data = jsonString.data(using: .utf8) else { return 0 }
        
        if let sources = try? JSONDecoder().decode([RSSSource].self, from: data) {
            for source in sources {
                if !self.sources.contains(where: { $0.sourceUrl == source.sourceUrl }) {
                    self.sources.append(source)
                }
            }
            saveSources()
            return sources.count
        }
        
        return 0
    }
    
    func exportToJson() -> String? {
        guard let data = try? JSONEncoder().encode(sources),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}

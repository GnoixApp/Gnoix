import Foundation

struct ReadStats: Codable {
    var totalReadTime: Int64 = 0
    var todayReadTime: Int64 = 0
    var readDate: String = ""
    var totalChapterCount: Int = 0
    var totalBookCount: Int = 0
    var finishedBookCount: Int = 0
    var lastReadTime: Int64 = 0
    var dailyStats: [DailyStat] = []
}

struct DailyStat: Codable {
    var date: String = ""
    var readTime: Int64 = 0
    var chapterCount: Int = 0
}

class ReadStatsManager {
    static let shared = ReadStatsManager()
    
    private let statsKey = "read_stats"
    private var currentStats: ReadStats!
    private var sessionStartTime: Int64 = 0
    
    private init() {
        loadStats()
    }
    
    private func loadStats() {
        if let data = UserDefaults.standard.data(forKey: statsKey),
           let stats = try? JSONDecoder().decode(ReadStats.self, from: data) {
            currentStats = stats
        } else {
            currentStats = ReadStats()
        }
        
        checkAndResetDaily()
    }
    
    private func saveStats() {
        if let data = try? JSONEncoder().encode(currentStats) {
            UserDefaults.standard.set(data, forKey: statsKey)
        }
    }
    
    private func checkAndResetDaily() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        
        if currentStats.readDate != today {
            currentStats.todayReadTime = 0
            currentStats.readDate = today
            saveStats()
        }
    }
    
    func startReading() {
        sessionStartTime = Int64(Date().timeIntervalSince1970 * 1000)
    }
    
    func stopReading() {
        guard sessionStartTime > 0 else { return }
        
        let sessionTime = Int64(Date().timeIntervalSince1970 * 1000) - sessionStartTime
        currentStats.totalReadTime += sessionTime
        currentStats.todayReadTime += sessionTime
        currentStats.lastReadTime = Int64(Date().timeIntervalSince1970 * 1000)
        sessionStartTime = 0
        
        checkAndResetDaily()
        saveStats()
    }
    
    func addChapterRead() {
        currentStats.totalChapterCount += 1
        checkAndResetDaily()
        saveStats()
    }
    
    func setTotalBookCount(_ count: Int) {
        currentStats.totalBookCount = count
        saveStats()
    }
    
    func incrementFinishedBooks() {
        currentStats.finishedBookCount += 1
        saveStats()
    }
    
    func getStats() -> ReadStats {
        checkAndResetDaily()
        return currentStats
    }
    
    func getTodayReadTime() -> String {
        let seconds = currentStats.todayReadTime / 1000
        if seconds < 60 {
            return "\(seconds)秒"
        } else if seconds < 3600 {
            return "\(seconds / 60)分钟"
        } else {
            return "\(seconds / 3600)小时\(seconds % 3600 / 60)分钟"
        }
    }
    
    func getTotalReadTime() -> String {
        let seconds = currentStats.totalReadTime / 1000
        if seconds < 3600 {
            return "\(seconds / 60)分钟"
        } else if seconds < 86400 {
            return "\(seconds / 3600)小时\(seconds % 3600 / 60)分钟"
        } else {
            let days = seconds / 86400
            let hours = (seconds % 86400) / 3600
            return "\(days)天\(hours)小时"
        }
    }
    
    func getReadProgress() -> String {
        let chapters = currentStats.totalChapterCount
        let books = currentStats.totalBookCount
        return "已读 \(chapters) 章，\(books) 本书"
    }
    
    func clearStats() {
        currentStats = ReadStats()
        saveStats()
    }
}

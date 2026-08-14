import Foundation

struct BookGroup: Codable, Identifiable {
    var id: String { String(groupId) }
    var groupId: Int64 = 0
    var groupName: String = ""
    var groupOrder: Int = 0
    var bookCount: Int = 0
}

class BookGroupManager {
    static let shared = BookGroupManager()
    
    private let database = DatabaseManager.shared
    private let groupsKey = "book_groups"
    private var cachedGroups: [BookGroup] = []
    
    private init() {
        loadGroups()
    }
    
    private func loadGroups() {
        if let data = UserDefaults.standard.data(forKey: groupsKey),
           let groups = try? JSONDecoder().decode([BookGroup].self, from: data) {
            cachedGroups = groups
        } else {
            cachedGroups = [
                BookGroup(groupId: 0, groupName: "默认", groupOrder: 0),
                BookGroup(groupId: 1, groupName: "收藏", groupOrder: 1),
                BookGroup(groupId: 2, groupName: "完本", groupOrder: 2)
            ]
            saveGroups()
        }
    }
    
    private func saveGroups() {
        if let data = try? JSONEncoder().encode(cachedGroups) {
            UserDefaults.standard.set(data, forKey: groupsKey)
        }
    }
    
    func getAllGroups() -> [BookGroup] {
        var groups = cachedGroups
        for i in 0..<groups.count {
            groups[i].bookCount = database.getBooksCount(inGroup: Int64(groups[i].groupId))
        }
        return groups
    }
    
    func addGroup(name: String) {
        let maxId = cachedGroups.map { $0.groupId }.max() ?? 0
        let newGroup = BookGroup(groupId: maxId + 1, groupName: name, groupOrder: cachedGroups.count)
        cachedGroups.append(newGroup)
        saveGroups()
    }
    
    func deleteGroup(_ groupId: Int64) {
        cachedGroups.removeAll { $0.groupId == groupId }
        
        let books = database.getAllBooks()
        for var book in books where book.group == groupId {
            book.group = 0
            database.saveBook(book)
        }
        
        saveGroups()
    }
    
    func renameGroup(_ groupId: Int64, newName: String) {
        if let index = cachedGroups.firstIndex(where: { $0.groupId == groupId }) {
            cachedGroups[index].groupName = newName
            saveGroups()
        }
    }
    
    func getGroupName(for groupId: Int64) -> String {
        return cachedGroups.first { $0.groupId == groupId }?.groupName ?? "默认"
    }
}

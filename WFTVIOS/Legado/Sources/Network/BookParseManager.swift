import Foundation

class BookParseManager {
    static let shared = BookParseManager()

    enum ParseMode: String {
        case server
        case local
    }

    private let modeKey = "book_parse_mode"

    private init() {}

    var mode: ParseMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modeKey),
                  let mode = ParseMode(rawValue: raw) else {
                return .server
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            NotificationCenter.default.post(name: .bookParseModeChanged, object: newValue)
        }
    }

    var isServerMode: Bool {
        mode == .server
    }

    func setServerMode(_ isServerMode: Bool) {
        mode = isServerMode ? .server : .local
    }
}

extension Notification.Name {
    static let bookParseModeChanged = Notification.Name("bookParseModeChanged")
}

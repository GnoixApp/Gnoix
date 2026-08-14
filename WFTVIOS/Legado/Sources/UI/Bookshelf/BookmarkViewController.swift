import UIKit
import SnapKit

class BookmarkViewController: UIViewController {

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.delegate = self
        tv.dataSource = self
        tv.register(BookmarkCell.self, forCellReuseIdentifier: "BookmarkCell")
        return tv
    }()
    
    private var bookmarks: [Bookmark] = []
    private var filteredBookmarks: [Bookmark] = []
    private var selectedBook: BookInfoResponse?
    private var isLoading = false
    private let documentImportQueue = DispatchQueue(label: "cn.oily.bookmark.import", qos: .userInitiated)

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadBookmarks()
    }
    
    private func setupUI() {
        title = "书签管理"
        view.backgroundColor = .systemBackground
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain,
            target: self,
            action: #selector(importBookmarks)
        )
        
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
    
    private func loadBookmarks() {
        guard ReaderServerAPI.shared.isLoggedIn else {
            showLoginAlert()
            return
        }
        
        isLoading = true
        
        Task {
            do {
                let loadedBookmarks = try await ReaderServerAPI.shared.getBookmarks()
                await MainActor.run {
                    self.bookmarks = loadedBookmarks
                    self.filteredBookmarks = loadedBookmarks
                    self.tableView.reloadData()
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.showError(error.localizedDescription)
                    self.isLoading = false
                }
            }
        }
    }
    
    @objc private func importBookmarks() {
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        documentPicker.delegate = self
        present(documentPicker, animated: true)
    }
    
    private func showLoginAlert() {
        let alert = UIAlertController(title: "提示", message: "请先连接服务器", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
    
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "错误", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
    
    private func deleteBookmark(_ bookmark: Bookmark) {
        Task {
            do {
                try await ReaderServerAPI.shared.deleteBookmark(bookmark: bookmark)
                await MainActor.run {
                    self.bookmarks.removeAll { $0.id == bookmark.id }
                    self.filteredBookmarks.removeAll { $0.id == bookmark.id }
                    self.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }
}

extension BookmarkViewController: UITableViewDelegate, UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredBookmarks.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BookmarkCell", for: indexPath) as! BookmarkCell
        let bookmark = filteredBookmarks[indexPath.row]
        cell.configure(with: bookmark)
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let bookmark = filteredBookmarks[indexPath.row]
        
        NotificationCenter.default.post(
            name: NSNotification.Name("JumpToBookmark"),
            object: nil,
            userInfo: ["bookmark": bookmark]
        )
        
        navigationController?.popViewController(animated: true)
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            guard let self = self else { return }
            let bookmark = self.filteredBookmarks[indexPath.row]
            self.deleteBookmark(bookmark)
            completion(true)
        }
        deleteAction.image = UIImage(systemName: "trash")
        
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
}

extension BookmarkViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importBookmarksFromFile(url)
    }

    private func importBookmarksFromFile(_ url: URL) {
        documentImportQueue.async { [weak self] in
            guard let self else { return }

            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let importedBookmarks = try Self.parseBookmarks(from: data)
                DispatchQueue.main.async {
                    self.uploadImportedBookmarks(importedBookmarks)
                }
            } catch {
                DispatchQueue.main.async {
                    self.showError("读取文件失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func parseBookmarks(from data: Data) throws -> [Bookmark] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(
                domain: "cn.oily.WFTVIOS.BookmarkImport",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "文件格式不正确"]
            )
        }
        return json.compactMap { dict -> Bookmark? in
            guard let bookName = dict["bookName"] as? String else { return nil }
            return Bookmark(
                bookName: bookName,
                bookAuthor: dict["bookAuthor"] as? String ?? "",
                chapterIndex: dict["chapterIndex"] as? Int ?? 0,
                chapterName: dict["chapterName"] as? String ?? "",
                bookText: dict["bookText"] as? String ?? "",
                content: dict["content"] as? String ?? "",
                createTime: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }
    }

    private func uploadImportedBookmarks(_ importedBookmarks: [Bookmark]) {
        guard !importedBookmarks.isEmpty else {
            showError("文件中没有可导入的书签")
            return
        }

        Task {
            do {
                try await ReaderServerAPI.shared.saveBookmarks(importedBookmarks)
                await MainActor.run {
                    self.loadBookmarks()
                }
            } catch {
                await MainActor.run {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }
}

class BookmarkCell: UITableViewCell {
    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    
    private let bookNameLabel = UILabel()
    private let chapterLabel = UILabel()
    private let contentLabel = UILabel()
    private let dateLabel = UILabel()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        bookNameLabel.font = .systemFont(ofSize: 16, weight: .medium)
        chapterLabel.font = .systemFont(ofSize: 14)
        chapterLabel.textColor = .secondaryLabel
        contentLabel.font = .systemFont(ofSize: 14)
        contentLabel.textColor = .tertiaryLabel
        contentLabel.numberOfLines = 2
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .tertiaryLabel
        
        let stack = UIStackView(arrangedSubviews: [bookNameLabel, chapterLabel, contentLabel, dateLabel])
        stack.axis = .vertical
        stack.spacing = 4
        
        contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(12)
        }
    }
    
    func configure(with bookmark: Bookmark) {
        bookNameLabel.text = "\(bookmark.bookName) - \(bookmark.bookAuthor)"
        chapterLabel.text = bookmark.chapterName
        contentLabel.text = bookmark.content.isEmpty ? bookmark.bookText : bookmark.content
        
        let date = Date(timeIntervalSince1970: Double(bookmark.createTime) / 1000)
        dateLabel.text = Self.displayDateFormatter.string(from: date)
    }
}

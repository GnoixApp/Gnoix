import UIKit
import SnapKit
import Kingfisher

class BookshelfViewController: UIViewController {

    private var books: [Book] = []
    private let database = DatabaseManager.shared
    private var isListMode: Bool = false
    private var isManagingBooks: Bool = false
    private var selectedBookUrls: Set<String> = []
    private var parseModeChangedObserver: NSObjectProtocol?
    private var lastServerRefreshTime: TimeInterval = 0
    private let serverRefreshInterval: TimeInterval = 8
    private let serverBooksCacheKey = "bookshelf.server.cache.v1"
    private var lastLoadTriggerTime: TimeInterval = 0
    private let minAppearReloadInterval: TimeInterval = 0.35
    private var hasLoadedInitially = false
    private var latestLocalLoadToken = UUID()
    private weak var modeBarButton: UIBarButtonItem?
    private let documentImportQueue = DispatchQueue(label: "cn.oily.bookshelf.import", qos: .userInitiated)

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 10, left: 10, bottom: 20, right: 10)

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.delegate = self
        cv.dataSource = self
        cv.alwaysBounceVertical = true
        cv.contentInsetAdjustmentBehavior = .always
        cv.register(BookCell.self, forCellWithReuseIdentifier: BookCell.identifier)
        cv.refreshControl = refreshControl
        return cv
    }()

    private lazy var emptyView: UIView = {
        let view = UIView()
        view.isHidden = true

        let iconView = UIImageView(image: UIImage(systemName: "books.vertical.fill"))
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = "书架还没有书"
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)

        let messageLabel = UILabel()
        messageLabel.text = "去发现页挑一本，或者直接导入本地 TXT / EPUB"
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.textColor = .secondaryLabel
        messageLabel.font = .systemFont(ofSize: 14)

        let actionButton = UIButton(type: .system)
        actionButton.setTitle("去找书", for: .normal)
        actionButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        actionButton.setTitleColor(.white, for: .normal)
        actionButton.backgroundColor = .systemBlue
        actionButton.layer.cornerRadius = 18
        if #available(iOS 15.0, *) {
            var config = actionButton.configuration ?? UIButton.Configuration.plain()
            config.baseForegroundColor = .white
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            actionButton.configuration = config
        } else {
            actionButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        }
        actionButton.addTarget(self, action: #selector(searchBookTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, messageLabel, actionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12

        view.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(20)
            make.trailing.lessThanOrEqualToSuperview().offset(-20)
        }

        iconView.snp.makeConstraints { make in
            make.width.height.equalTo(54)
        }

        return view
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(refreshBooks), for: .valueChanged)
        return control
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNavigation()
        observeParseModeChanges()
        loadBooks()
        hasLoadedInitially = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        updateNavigationBarAppearance()
        setupNavigation()
        if shouldReloadOnAppear() {
            loadBooks()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.navigationBar.sizeToFit()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func updateNavigationBarAppearance() {
        guard let nav = navigationController else { return }
        nav.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        nav.navigationBar.standardAppearance = appearance
        nav.navigationBar.scrollEdgeAppearance = appearance
        nav.navigationBar.compactAppearance = appearance
    }

    private func shouldReloadOnAppear() -> Bool {
        guard hasLoadedInitially else { return true }
        let now = Date().timeIntervalSince1970
        return (now - lastLoadTriggerTime) >= minAppearReloadInterval
    }

    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        title = "书架"

        view.addSubview(collectionView)
        view.addSubview(emptyView)

        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        emptyView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func setupNavigation() {
        if isManagingBooks {
            let selectAllTitle = selectedBookUrls.count == books.count && !books.isEmpty ? "取消全选" : "全选"
            let selectAllButton = UIBarButtonItem(
                title: selectAllTitle,
                style: .plain,
                target: self,
                action: #selector(selectAllTapped)
            )
            let deleteButton = UIBarButtonItem(
                title: "删除",
                style: .plain,
                target: self,
                action: #selector(deleteSelectedTapped)
            )
            deleteButton.tintColor = .systemRed
            deleteButton.isEnabled = !selectedBookUrls.isEmpty

            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "完成",
                style: .plain,
                target: self,
                action: #selector(toggleManageMode)
            )
            navigationItem.rightBarButtonItems = [deleteButton, selectAllButton]
            title = selectedBookUrls.isEmpty ? "管理书架" : "已选 \(selectedBookUrls.count) 本"
            return
        }

        title = "书架"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "管理",
            style: .plain,
            target: self,
            action: #selector(toggleManageMode)
        )

        let addButton = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addBookTapped)
        )

        let searchButton = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            style: .plain,
            target: self,
            action: #selector(searchBookTapped)
        )

        let modeButton = UIBarButtonItem(
            image: UIImage(systemName: isListMode ? "square.grid.2x2" : "list.bullet"),
            style: .plain,
            target: self,
            action: #selector(toggleDisplayMode)
        )
        modeBarButton = modeButton

        let toolsButton = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            style: .plain,
            target: self,
            action: #selector(showNovelToolsMenu(_:))
        )

        navigationItem.rightBarButtonItems = [addButton, searchButton, modeButton, toolsButton]
    }
    
    @objc private func refreshBooks() {
        loadBooks(forceRemote: true)
    }

    @objc private func toggleDisplayMode() {
        isListMode.toggle()

        let iconName = isListMode ? "square.grid.2x2" : "list.bullet"
        modeBarButton?.image = UIImage(systemName: iconName)

        for case let cell as BookCell in collectionView.visibleCells {
            cell.setDisplayMode(isListMode)
        }
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            UIView.performWithoutAnimation {
                layout.invalidateLayout()
                collectionView.performBatchUpdates(nil)
            }
        }
    }

    @objc private func toggleManageMode() {
        isManagingBooks.toggle()
        selectedBookUrls.removeAll()
        collectionView.allowsMultipleSelection = isManagingBooks
        if !isManagingBooks {
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }
        setupNavigation()
        collectionView.reloadData()
    }

    @objc private func selectAllTapped() {
        if selectedBookUrls.count == books.count {
            selectedBookUrls.removeAll()
        } else {
            selectedBookUrls = Set(books.map(\.bookUrl))
        }
        applySelectionStateToVisibleCells()
        setupNavigation()
    }

    @objc private func deleteSelectedTapped() {
        let targets = books.filter { selectedBookUrls.contains($0.bookUrl) }
        guard !targets.isEmpty else { return }

        let alert = UIAlertController(
            title: "批量删除",
            message: "确定删除已选的 \(targets.count) 本书吗？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.deleteBooks(targets)
        })
        present(alert, animated: true)
    }

    private func loadBooks(forceRemote: Bool = false) {
        lastLoadTriggerTime = Date().timeIntervalSince1970

        if BookParseManager.shared.isServerMode {
            let cachedServerBooks = cachedServerBooksSnapshot()
            if !cachedServerBooks.isEmpty {
                applyBooks(cachedServerBooks)
            } else if forceRemote {
                applyBooks([], forceReload: true)
            }

            if forceRemote || shouldRefreshFromServer() || cachedServerBooks.isEmpty {
                loadBooksFromServer()
            } else {
                refreshControl.endRefreshing()
            }
        } else {
            let loadToken = UUID()
            latestLocalLoadToken = loadToken
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let localBooks = self.database.getAllBooks()
                DispatchQueue.main.async {
                    guard self.latestLocalLoadToken == loadToken else { return }
                    self.applyBooks(localBooks)
                }
            }
        }
    }
    
    private func loadBooksFromServer() {
        lastServerRefreshTime = Date().timeIntervalSince1970
        Task {
            do {
                let localSnapshot: [Book] = await MainActor.run {
                    self.database.getAllBooks().sorted { $0.durChapterTime > $1.durChapterTime }
                }
                let serverBooks = try await ReaderServerAPI.shared.getBookshelf()
                
                await MainActor.run {
                    let localByURL = Dictionary(uniqueKeysWithValues: localSnapshot.map { ($0.bookUrl, $0) })
                    let mappedBooks = serverBooks.map { serverBook -> Book in
                        var book = Book(
                            bookUrl: serverBook.bookUrl,
                            tocUrl: serverBook.tocUrl ?? "",
                            origin: serverBook.sourceUrl ?? "",
                            originName: serverBook.originName ?? "",
                            name: serverBook.name,
                            author: serverBook.author,
                            kind: serverBook.kind,
                            coverUrl: serverBook.coverUrl,
                            intro: serverBook.intro,
                            type: serverBook.type,
                            totalChapterNum: serverBook.totalChapterNum,
                            durChapterIndex: serverBook.durChapterIndex,
                            durChapterPos: serverBook.durChapterPos,
                            durChapterTime: serverBook.durChapterTime
                        )
                        book.durChapterTime = serverBook.durChapterTime
                        if let local = localByURL[serverBook.bookUrl] {
                            if (book.coverUrl ?? "").isEmpty {
                                book.coverUrl = local.coverUrl
                            }
                            if (book.customCoverUrl ?? "").isEmpty {
                                book.customCoverUrl = local.customCoverUrl
                            }
                            if (book.intro ?? "").isEmpty {
                                book.intro = local.intro
                            }
                        }
                        return book
                    }
                    let sorted = mappedBooks.sorted { $0.durChapterTime > $1.durChapterTime }
                    self.cacheServerBooks(sorted)
                    self.applyBooks(sorted)
                }
            } catch {
                await MainActor.run {
                    self.selectedBookUrls.removeAll()
                    self.refreshControl.endRefreshing()
                    self.setupNavigation()
                }
            }
        }
    }

    private func shouldRefreshFromServer() -> Bool {
        guard books.isEmpty == false else { return true }
        let now = Date().timeIntervalSince1970
        return (now - lastServerRefreshTime) >= serverRefreshInterval
    }

    private func cachedServerBooksSnapshot() -> [Book] {
        guard let data = UserDefaults.standard.data(forKey: serverBooksCacheKey),
              let cached = try? JSONDecoder().decode([Book].self, from: data) else {
            return []
        }
        return cached.sorted { $0.durChapterTime > $1.durChapterTime }
    }

    private func cacheServerBooks(_ books: [Book]) {
        guard let data = try? JSONEncoder().encode(books) else { return }
        UserDefaults.standard.set(data, forKey: serverBooksCacheKey)
    }

    @objc private func addBookTapped() {
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.text, .epub])
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        present(documentPicker, animated: true)
    }

    @objc private func searchBookTapped() {
        let searchVC = BookSearchViewController()
        navigationController?.pushViewController(searchVC, animated: true)
    }

    @objc private func showNovelToolsMenu(_ sender: UIBarButtonItem) {
        let alert = UIAlertController(title: "小说工具", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "替换净化", style: .default) { [weak self] _ in
            let vc = ReplaceRuleViewController()
            self?.navigationController?.pushViewController(vc, animated: true)
        })

        alert.addAction(UIAlertAction(title: "RSS订阅", style: .default) { [weak self] _ in
            let vc = RSSSourceViewController()
            self?.navigationController?.pushViewController(vc, animated: true)
        })

        alert.addAction(UIAlertAction(title: "书签管理", style: .default) { [weak self] _ in
            let vc = BookmarkViewController()
            self?.navigationController?.pushViewController(vc, animated: true)
        })

        alert.addAction(UIAlertAction(title: "阅读记录", style: .default) { [weak self] _ in
            let vc = ReadingHistoryViewController()
            self?.navigationController?.pushViewController(vc, animated: true)
        })

        alert.addAction(UIAlertAction(title: "分组管理", style: .default) { [weak self] _ in
            let vc = BookGroupViewController()
            self?.navigationController?.pushViewController(vc, animated: true)
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = sender
        }

        present(alert, animated: true)
    }
    
    private func observeParseModeChanges() {
        parseModeChangedObserver = NotificationCenter.default.addObserver(
            forName: .bookParseModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadBooks(forceRemote: true)
        }
    }

    private func deleteBooks(_ targets: [Book]) {
        Task {
            var failed: [String] = []
            for book in targets {
                do {
                    try await ReaderServerAPI.shared.removeFromBookshelf(
                        bookUrl: book.bookUrl,
                        sourceUrl: book.origin
                    )
                } catch {
                    failed.append(book.name)
                }
            }

            await MainActor.run {
                self.isManagingBooks = false
                self.selectedBookUrls.removeAll()
                self.collectionView.allowsMultipleSelection = false
                self.setupNavigation()
                self.loadBooks(forceRemote: true)

                if !failed.isEmpty {
                    let msg = "以下书籍删除失败：\n" + failed.joined(separator: "\n")
                    let alert = UIAlertController(title: "部分删除失败", message: msg, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    private func pruneInvalidSelections() {
        let current = Set(books.map(\.bookUrl))
        selectedBookUrls = selectedBookUrls.intersection(current)
        if isManagingBooks && books.isEmpty {
            isManagingBooks = false
        }
        setupNavigation()
    }

    private func applyBooks(_ updatedBooks: [Book], forceReload: Bool = false) {
        let previousBooks = books
        books = updatedBooks
        pruneInvalidSelections()
        emptyView.isHidden = !books.isEmpty
        refreshControl.endRefreshing()

        if forceReload {
            collectionView.reloadData()
            applySelectionStateToVisibleCells()
            return
        }

        let previousURLs = previousBooks.map(\.bookUrl)
        let updatedURLs = updatedBooks.map(\.bookUrl)
        guard previousURLs == updatedURLs else {
            collectionView.reloadData()
            applySelectionStateToVisibleCells()
            return
        }

        var changedIndexPaths: [IndexPath] = []
        for index in updatedBooks.indices {
            let oldBook = previousBooks[index]
            let newBook = updatedBooks[index]
            if hasVisualDiff(old: oldBook, new: newBook) {
                changedIndexPaths.append(IndexPath(item: index, section: 0))
            }
        }

        if changedIndexPaths.isEmpty {
            applySelectionStateToVisibleCells()
            return
        }

        collectionView.reloadItems(at: changedIndexPaths)
        applySelectionStateToVisibleCells()
    }

    private func hasVisualDiff(old: Book, new: Book) -> Bool {
        if old.name != new.name { return true }
        if old.author != new.author { return true }
        if old.originName != new.originName { return true }
        if old.origin != new.origin { return true }
        if old.coverUrl != new.coverUrl { return true }
        if old.customCoverUrl != new.customCoverUrl { return true }
        if old.durChapterIndex != new.durChapterIndex { return true }
        if old.totalChapterNum != new.totalChapterNum { return true }
        if old.latestChapterTitle != new.latestChapterTitle { return true }
        if old.durChapterTime != new.durChapterTime { return true }
        return false
    }

    private func applySelectionStateToVisibleCells() {
        guard isManagingBooks else { return }
        for item in books.indices {
            let indexPath = IndexPath(item: item, section: 0)
            let book = books[item]
            if selectedBookUrls.contains(book.bookUrl) {
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            } else {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }
    }

    deinit {
        if let observer = parseModeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

extension BookshelfViewController: UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return books.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BookCell.identifier, for: indexPath) as! BookCell
        cell.configure(with: books[indexPath.item], isListMode: isListMode)
        let selected = selectedBookUrls.contains(books[indexPath.item].bookUrl)
        cell.setManagingState(isManaging: isManagingBooks, isSelected: selected)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let availableWidth = collectionView.bounds.width
            - collectionView.adjustedContentInset.left
            - collectionView.adjustedContentInset.right

        if isListMode {
            return CGSize(width: availableWidth - 20, height: 120)
        }

        let targetWidth: CGFloat = 110.0
        let columns: CGFloat = max(3, floor((availableWidth - 20) / targetWidth))
        let spacing: CGFloat = 8 * (columns - 1)
        let horizontalInsets: CGFloat = 20
        let itemWidth = floor((availableWidth - horizontalInsets - spacing) / columns)
        return CGSize(width: itemWidth, height: itemWidth * 1.72)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let book = books[indexPath.item]
        if isManagingBooks {
            if selectedBookUrls.contains(book.bookUrl) {
                selectedBookUrls.remove(book.bookUrl)
                collectionView.deselectItem(at: indexPath, animated: false)
            } else {
                selectedBookUrls.insert(book.bookUrl)
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            }
            setupNavigation()
            collectionView.reloadItems(at: [indexPath])
            return
        }
        let readerVC = ReaderViewController(book: book)
        readerVC.modalPresentationStyle = .fullScreen
        present(readerVC, animated: true)
    }
    
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard isManagingBooks, indexPath.item < books.count else { return }
        selectedBookUrls.remove(books[indexPath.item].bookUrl)
        setupNavigation()
        collectionView.reloadItems(at: [indexPath])
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isManagingBooks else { return nil }
        let book = books[indexPath.item]

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let deleteAction = UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deleteBook(book)
            }

            let infoAction = UIAction(title: "详情", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.showBookInfo(book)
            }

            return UIMenu(title: "", children: [infoAction, deleteAction])
        }
    }

    private func deleteBook(_ book: Book) {
        let alert = UIAlertController(title: "确认删除", message: "确定要删除《\(book.name)》吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.deleteFromServer(book: book)
        })
        present(alert, animated: true)
    }
    
    private func deleteFromServer(book: Book) {
        Task {
            do {
                try await ReaderServerAPI.shared.removeFromBookshelf(
                    bookUrl: book.bookUrl,
                    sourceUrl: book.origin
                )
                await MainActor.run {
                    self.loadBooks(forceRemote: true)
                }
            } catch {
                print("Delete from server failed: \(error)")
            }
        }
    }

    private func showBookInfo(_ book: Book) {
        let infoVC = BookInfoViewController(book: book)
        navigationController?.pushViewController(infoVC, animated: true)
    }
}

extension BookshelfViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importLocalBook(from: url)
    }

    private func importLocalBook(from url: URL) {
        documentImportQueue.async { [weak self] in
            guard let self else { return }
            guard url.startAccessingSecurityScopedResource() else {
                DispatchQueue.main.async {
                    self.showImportError(message: "无法访问所选文件")
                }
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let booksPath = documentsPath.appendingPathComponent("Books", isDirectory: true)
                try FileManager.default.createDirectory(at: booksPath, withIntermediateDirectories: true)

                let destinationUrl = booksPath.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destinationUrl.path) {
                    try FileManager.default.removeItem(at: destinationUrl)
                }
                try FileManager.default.copyItem(at: url, to: destinationUrl)

                let book = Book(
                    bookUrl: destinationUrl.path,
                    origin: Book.localTag,
                    name: url.deletingPathExtension().lastPathComponent
                )

                DispatchQueue.main.async {
                    self.database.saveBook(book)
                    self.loadBooks(forceRemote: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.showImportError(message: error.localizedDescription)
                }
            }
        }
    }

    private func showImportError(message: String) {
        let alert = UIAlertController(title: "导入失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

import UIKit
import SnapKit
import Kingfisher

class ExploreBookListViewController: UIViewController {

    private let category: ExploreCategory
    private let source: Any
    private let isServerMode: Bool
    
    private var books: [BookInfoResponse] = []
    private var localBooks: [BookInfoResponse] = []
    private let serverAPI = ReaderServerAPI.shared
    private let database = DatabaseManager.shared
    
    private var currentPage = 1
    private var isInitialLoading = false
    private var isLoadingMore = false
    private var hasMore = true
    private var loadTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var seenBookKeys: Set<String> = []
    private var autoLoadMoreRounds = 0
    private let maxAutoLoadMoreRounds = 2
    private var lastLoadMoreTriggerTime: TimeInterval = 0
    private let minLoadMoreInterval: TimeInterval = 0.35
    private static let listDensityStorageKey = "explore.book_list_density_v1"

    private enum ListDensity: String {
        case comfortable
        case compact

        var rowHeight: CGFloat {
            switch self {
            case .comfortable: return 172
            case .compact: return 146
            }
        }

        var toggleIconName: String {
            switch self {
            case .comfortable: return "rectangle.compress.vertical"
            case .compact: return "rectangle.expand.vertical"
            }
        }

        var cellDensity: BookListCell.LayoutDensity {
            switch self {
            case .comfortable: return .comfortable
            case .compact: return .compact
            }
        }

        var next: ListDensity {
            switch self {
            case .comfortable: return .compact
            case .compact: return .comfortable
            }
        }
    }

    private var listDensity: ListDensity = {
        if let raw = UserDefaults.standard.string(forKey: ExploreBookListViewController.listDensityStorageKey),
           let density = ListDensity(rawValue: raw) {
            return density
        }
        return .comfortable
    }()

    private enum LoadMoreTrigger {
        case scroll
        case auto
    }
    
    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.delegate = self
        tv.dataSource = self
        tv.register(BookListCell.self, forCellReuseIdentifier: BookListCell.identifier)
        tv.rowHeight = 172
        tv.estimatedRowHeight = 172
        tv.backgroundColor = .clear
        tv.separatorStyle = .none
        tv.contentInsetAdjustmentBehavior = .automatic
        return tv
    }()

    private lazy var densityToggleButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            image: nil,
            style: .plain,
            target: self,
            action: #selector(toggleListDensity)
        )
        return button
    }()
    
    private lazy var footerIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()
    
    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private lazy var loadingFooterView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 56))
        view.addSubview(footerIndicator)
        footerIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        return view
    }()
    
    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.text = "暂无内容"
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }()

    init(category: ExploreCategory, source: Any, isServerMode: Bool) {
        self.category = category
        self.source = source
        self.isServerMode = isServerMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNavigation()
        applyListDensity(animated: false)
        loadBooks()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Push 到详情页时保留当前列表与封面状态，避免返回后出现空白封面。
        guard isMovingFromParent || isBeingDismissed else { return }
        cancelLoadingTasks()
        cancelAllImageDownloads()
    }
    
    private func cancelLoadingTasks() {
        loadTask?.cancel()
        loadMoreTask?.cancel()
        loadTask = nil
        loadMoreTask = nil
    }

    private func cancelAllImageDownloads() {
        for cell in tableView.visibleCells {
            if let bookCell = cell as? BookListCell {
                bookCell.cancelImageDownload()
            }
        }
    }

    private func setupUI() {
        title = category.name
        view.backgroundColor = .systemGroupedBackground

        view.addSubview(tableView)
        view.addSubview(loadingIndicator)
        view.addSubview(emptyLabel)

        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        loadingIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(20)
            make.trailing.lessThanOrEqualToSuperview().offset(-20)
        }
        
        tableView.tableFooterView = UIView(frame: .zero)
    }

    private func setupNavigation() {
        navigationItem.rightBarButtonItem = densityToggleButton
        updateDensityToggleButtonAppearance()
    }

    @objc private func toggleListDensity() {
        listDensity = listDensity.next
        UserDefaults.standard.set(listDensity.rawValue, forKey: Self.listDensityStorageKey)
        applyListDensity(animated: true)
        showToast("已切换为\(listDensity == .compact ? "紧凑" : "舒适")布局")
    }

    private func updateDensityToggleButtonAppearance() {
        densityToggleButton.image = UIImage(systemName: listDensity.toggleIconName)
        densityToggleButton.accessibilityLabel = listDensity == .comfortable ? "切换到紧凑布局" : "切换到舒适布局"
        densityToggleButton.tintColor = listDensity == .comfortable ? .systemBlue : .systemTeal
    }

    private func applyListDensity(animated: Bool) {
        updateDensityToggleButtonAppearance()
        tableView.rowHeight = listDensity.rowHeight
        tableView.estimatedRowHeight = listDensity.rowHeight

        let updates = {
            for case let cell as BookListCell in self.tableView.visibleCells {
                cell.setDensity(self.listDensity.cellDensity, animated: animated)
            }
            self.tableView.beginUpdates()
            self.tableView.endUpdates()
        }

        if animated {
            UIView.animate(withDuration: 0.18, animations: updates)
        } else {
            updates()
        }
    }

    // MARK: - 数据加载
    private func loadBooks() {
        loadTask?.cancel()
        loadMoreTask?.cancel()
        loadTask = nil
        loadMoreTask = nil
        isInitialLoading = true
        isLoadingMore = false
        loadingIndicator.startAnimating()
        footerIndicator.stopAnimating()
        tableView.tableFooterView = UIView(frame: .zero)
        emptyLabel.isHidden = true
        currentPage = 1
        hasMore = true
        autoLoadMoreRounds = 0
        lastLoadMoreTriggerTime = 0
        seenBookKeys.removeAll()
        books.removeAll()
        localBooks.removeAll()
        tableView.reloadData()
        isServerMode ? loadServerBooks() : loadLocalBooks()
    }
    
    private func loadServerBooks() {
        var sourceUrl = ""
        if let s = source as? BookSourceResponse { sourceUrl = s.bookSourceUrl }
        else if let s = source as? BookSource { sourceUrl = s.bookSourceUrl }
        let page = currentPage
        
        loadTask = Task {
            do {
                let books = try await serverAPI.explore(sourceUrl: sourceUrl, url: category.url, page: page)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.books.removeAll()
                    _ = self.appendUniqueBooks(books, into: &self.books)
                    self.isInitialLoading = false
                    self.loadingIndicator.stopAnimating()
                    self.emptyLabel.isHidden = !self.books.isEmpty
                    self.emptyLabel.text = self.books.isEmpty ? "暂无内容，可能是当前书源规则不匹配" : "暂无内容"
                    self.hasMore = !self.books.isEmpty
                    self.tableView.reloadData()
                    self.autoLoadMoreIfNeeded()
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.isInitialLoading = false
                    self.loadingIndicator.stopAnimating()
                    self.emptyLabel.isHidden = false
                    self.emptyLabel.text = "加载失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadLocalBooks() {
        let sourceMeta = currentSourceMeta()
        let sourceUrl = sourceMeta.url
        guard !sourceUrl.isEmpty else {
            isInitialLoading = false
            loadingIndicator.stopAnimating()
            emptyLabel.isHidden = false
            emptyLabel.text = "书源地址为空，无法加载分类书籍"
            return
        }
        let page = currentPage
        
        loadTask = Task {
            do {
                let results = try await serverAPI.explore(sourceUrl: sourceUrl, url: category.url, page: page)
                if Task.isCancelled { return }
                await MainActor.run {
                    let mapped = results.map { self.normalizeLocalBookInfo($0, fallbackSourceUrl: sourceUrl, fallbackOriginName: sourceMeta.name) }
                    self.localBooks.removeAll()
                    _ = self.appendUniqueBooks(mapped, into: &self.localBooks)
                    self.isInitialLoading = false
                    self.hasMore = !self.localBooks.isEmpty
                    self.loadingIndicator.stopAnimating()
                    self.emptyLabel.isHidden = !self.localBooks.isEmpty
                    self.emptyLabel.text = self.localBooks.isEmpty ? "暂无内容，可能是当前书源规则不匹配" : "暂无内容"
                    self.tableView.reloadData()
                    self.autoLoadMoreIfNeeded()
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.isInitialLoading = false
                    self.loadingIndicator.stopAnimating()
                    self.emptyLabel.isHidden = false
                    self.emptyLabel.text = "加载失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func addToBookshelf(_ bookInfo: BookInfoResponse) {
        Task {
            do {
                try await serverAPI.addToBookshelf(book: bookInfo)
                await MainActor.run { self.showToast("《\(bookInfo.name)》已入库") }
            } catch {
                await MainActor.run { self.showToast("错误: \(error.localizedDescription)") }
            }
        }
    }
    
    private func showToast(_ message: String) {
        let toast = UILabel()
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        toast.textColor = .white
        toast.textAlignment = .center
        toast.font = .systemFont(ofSize: 13)
        toast.text = message
        toast.layer.cornerRadius = 18
        toast.clipsToBounds = true
        view.addSubview(toast)
        toast.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-60)
            make.height.equalTo(36)
            make.width.greaterThanOrEqualTo(120)
        }
        UIView.animate(withDuration: 0.3) { toast.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 1.2) { toast.alpha = 0 } completion: { _ in toast.removeFromSuperview() }
        }
    }
}

// MARK: - TableView 代理
extension ExploreBookListViewController: UITableViewDelegate, UITableViewDataSource, UIScrollViewDelegate {
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offsetY = scrollView.contentOffset.y
        let contentHeight = scrollView.contentSize.height
        let frameHeight = scrollView.frame.height

        guard contentHeight > frameHeight else { return }
        
        if offsetY > contentHeight - frameHeight - 100 {
            loadMoreIfNeeded(trigger: .scroll)
        }
    }
    
    private func loadMoreIfNeeded(trigger: LoadMoreTrigger) {
        let itemCount = isServerMode ? books.count : localBooks.count
        guard !isInitialLoading, !isLoadingMore, hasMore, itemCount > 0 else { return }
        if case .auto = trigger, autoLoadMoreRounds >= maxAutoLoadMoreRounds { return }

        let now = Date().timeIntervalSince1970
        guard now - lastLoadMoreTriggerTime >= minLoadMoreInterval else { return }
        lastLoadMoreTriggerTime = now
        if case .auto = trigger { autoLoadMoreRounds += 1 }
        
        footerIndicator.startAnimating()
        tableView.tableFooterView = loadingFooterView
        isLoadingMore = true
        
        loadMoreBooks()
    }
    
    private func loadMoreBooks() {
        let nextPage = currentPage + 1
        let sourceMeta = currentSourceMeta()
        let sourceUrl = sourceMeta.url
        
        loadMoreTask = Task {
            do {
                let result = try await serverAPI.explore(
                    sourceUrl: sourceUrl,
                    url: category.url,
                    page: nextPage
                )
                if Task.isCancelled { return }
                
                await MainActor.run {
                    if result.isEmpty {
                        self.hasMore = false
                    } else {
                        let appendedCount: Int
                        if self.isServerMode {
                            appendedCount = self.appendUniqueBooks(result, into: &self.books)
                        } else {
                            let mapped = result.map { book -> BookInfoResponse in
                                self.normalizeLocalBookInfo(book, fallbackSourceUrl: sourceUrl, fallbackOriginName: sourceMeta.name)
                            }
                            appendedCount = self.appendUniqueBooks(mapped, into: &self.localBooks)
                        }

                        if appendedCount == 0 {
                            self.hasMore = false
                        } else {
                            self.currentPage = nextPage
                            self.hasMore = true
                            self.tableView.reloadData()
                        }
                    }
                    self.isLoadingMore = false
                    self.footerIndicator.stopAnimating()
                    self.tableView.tableFooterView = UIView(frame: .zero)
                    self.autoLoadMoreIfNeeded()
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.isLoadingMore = false
                    self.footerIndicator.stopAnimating()
                    self.tableView.tableFooterView = UIView(frame: .zero)
                    self.showToast("加载更多失败，请稍后重试")
                }
            }
        }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isServerMode ? books.count : localBooks.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        listDensity.rowHeight
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        listDensity.rowHeight
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: BookListCell.identifier, for: indexPath) as! BookListCell
        if isServerMode {
            let b = books[indexPath.row]
            cell.configure(
                name: b.name,
                author: b.author ?? "",
                sourceName: b.originName,
                latestChapter: b.latestChapter,
                kind: b.kind,
                wordCount: b.wordCount,
                sourceUrl: b.sourceUrl,
                bookUrl: b.bookUrl,
                coverUrl: b.coverUrl,
                intro: b.intro
            )
        } else {
            let b = localBooks[indexPath.row]
            cell.configure(
                name: b.name,
                author: b.author,
                sourceName: b.originName,
                latestChapter: b.latestChapter,
                kind: b.kind,
                wordCount: b.wordCount,
                sourceUrl: b.sourceUrl,
                bookUrl: b.bookUrl,
                coverUrl: b.coverUrl,
                intro: b.intro
            )
        }
        cell.setDensity(listDensity.cellDensity, animated: false)
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let book: Book
        if isServerMode {
            let b = books[indexPath.row]
            book = Book(bookUrl: b.bookUrl, origin: b.sourceUrl ?? "", originName: b.originName ?? "", name: b.name, author: b.author ?? "", kind: b.kind, coverUrl: b.coverUrl, intro: b.intro, latestChapterTitle: b.latestChapter)
        } else {
            let b = localBooks[indexPath.row]
            book = Book(
                bookUrl: b.bookUrl,
                tocUrl: b.tocUrl ?? "",
                origin: b.sourceUrl ?? "",
                originName: b.originName ?? "",
                name: b.name,
                author: b.author,
                kind: b.kind,
                coverUrl: b.coverUrl,
                intro: b.intro,
                latestChapterTitle: b.latestChapter,
                totalChapterNum: b.totalChapterNum,
                durChapterIndex: b.durChapterIndex,
                durChapterPos: b.durChapterPos,
                durChapterTime: b.durChapterTime
            )
        }
        let bookInfoVC = BookInfoViewController(book: book)
        navigationController?.pushViewController(bookInfoVC, animated: true)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? BookListCell)?.cancelImageDownload()
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let add = UIContextualAction(style: .normal, title: "收藏") { [weak self] _, _, comp in
            guard let self = self else {
                comp(true)
                return
            }
            if self.isServerMode {
                self.addToBookshelf(self.books[indexPath.row])
            } else {
                self.addToBookshelf(self.localBooks[indexPath.row])
            }
            comp(true)
        }
        add.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [add])
    }

    private func currentSourceMeta() -> (url: String, name: String?) {
        if let s = source as? BookSource {
            return (s.bookSourceUrl, s.bookSourceName)
        }
        if let s = source as? BookSourceResponse {
            return (s.bookSourceUrl, s.bookSourceName)
        }
        return ("", nil)
    }

    private func normalizeLocalBookInfo(_ book: BookInfoResponse, fallbackSourceUrl: String, fallbackOriginName: String?) -> BookInfoResponse {
        var normalized = BookInfoResponse(
            name: book.name,
            author: book.author,
            bookUrl: book.bookUrl,
            sourceUrl: (book.sourceUrl?.isEmpty == false) ? book.sourceUrl : fallbackSourceUrl,
            coverUrl: book.coverUrl,
            intro: book.intro,
            kind: book.kind,
            latestChapter: book.latestChapter,
            tocUrl: book.tocUrl,
            wordCount: book.wordCount,
            chapterCount: book.chapterCount,
            type: book.type,
            originName: book.originName,
            durChapterIndex: book.durChapterIndex,
            durChapterPos: book.durChapterPos,
            durChapterTime: book.durChapterTime,
            totalChapterNum: book.totalChapterNum
        )
        if normalized.originName?.isEmpty ?? true {
            normalized.originName = fallbackOriginName
        }
        return normalized
    }

    private func autoLoadMoreIfNeeded() {
        guard hasMore, !isInitialLoading, !isLoadingMore else { return }
        let itemCount = isServerMode ? books.count : localBooks.count
        guard itemCount > 0 else { return }

        let visibleHeight = tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom
        guard visibleHeight > 0 else { return }

        if tableView.contentSize.height <= visibleHeight + 12 {
            loadMoreIfNeeded(trigger: .auto)
        }
    }

    private func appendUniqueBooks(_ incoming: [BookInfoResponse], into target: inout [BookInfoResponse]) -> Int {
        guard !incoming.isEmpty else { return 0 }
        if seenBookKeys.isEmpty && !target.isEmpty {
            seenBookKeys = Set(target.map(bookIdentityKey))
        }
        var appended = 0

        for item in incoming {
            let key = bookIdentityKey(item)
            if seenBookKeys.insert(key).inserted {
                target.append(item)
                appended += 1
            }
        }
        return appended
    }

    private func bookIdentityKey(_ book: BookInfoResponse) -> String {
        let normalizedURL = book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isReliableBookIdentityURL(normalizedURL) {
            return normalizedURL
        }
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let author = (book.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = (book.sourceUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(name)|\(author)|\(source)"
    }

    private func isReliableBookIdentityURL(_ url: String) -> Bool {
        guard !url.isEmpty else { return false }
        if url.contains("{{") || url.contains("}}") { return false }

        let lowered = url.lowercased()
        let listLikeMarkers = [
            "sort=",
            "page=",
            "categoryid=",
            "groupid=",
            "start=",
            "count=",
            "offset=",
            "channel=",
            "type="
        ]
        if listLikeMarkers.contains(where: { lowered.contains($0) }) {
            return false
        }
        return true
    }
}

// MARK: - 分类书籍 Cell
class BookListCell: UITableViewCell {
    static let identifier = "BookListCell"
    private static let cardNormalBackgroundColor = UIColor { trait in
        trait.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .white
    }
    private static let cardHighlightedBackgroundColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.82)
            : UIColor.systemGray6
    }

    enum LayoutDensity {
        case comfortable
        case compact
    }
    
    private let cardView: UIView = {
        let view = UIView()
        view.backgroundColor = BookListCell.cardNormalBackgroundColor
        view.layer.cornerRadius = 16
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }()
    
    private let coverImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        iv.backgroundColor = .tertiarySystemFill
        return iv
    }()
    
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16, weight: .semibold)
        l.numberOfLines = 2
        return l
    }()
    
    private let authorLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabel
        return l
    }()

    private let sourceLabel: PaddingLabel = {
        let label = PaddingLabel(insets: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8))
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .systemBlue
        label.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.14)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let latestLabel: PaddingLabel = {
        let label = PaddingLabel(insets: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8))
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .systemOrange
        label.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        return label
    }()
    
    private let introLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = .tertiaryLabel
        l.numberOfLines = 2
        return l
    }()

    private let metaLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    private var currentDensity: LayoutDensity = .comfortable
    private var coverTopConstraint: Constraint?
    private var coverBottomConstraint: Constraint?
    private var coverWidthConstraint: Constraint?
    private var titleTopConstraint: Constraint?
    private var authorTopConstraint: Constraint?
    private var sourceTopConstraint: Constraint?
    private var introTopConstraint: Constraint?
    private var sourceHeightConstraint: Constraint?
    private var latestHeightConstraint: Constraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setup() {
        backgroundColor = .clear
        selectionStyle = .none

        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        latestLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        latestLabel.setContentHuggingPriority(.required, for: .horizontal)
        
        contentView.addSubview(cardView)
        cardView.addSubview(coverImageView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(authorLabel)
        cardView.addSubview(sourceLabel)
        cardView.addSubview(latestLabel)
        cardView.addSubview(metaLabel)
        cardView.addSubview(introLabel)
        
        cardView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 5, left: 6, bottom: 5, right: 6))
        }
        
        coverImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            coverTopConstraint = make.top.equalToSuperview().offset(10).constraint
            coverBottomConstraint = make.bottom.equalToSuperview().offset(-10).constraint
            coverWidthConstraint = make.width.equalTo(92).constraint
        }
        
        titleLabel.snp.makeConstraints { make in
            titleTopConstraint = make.top.equalToSuperview().offset(12).constraint
            make.leading.equalTo(coverImageView.snp.trailing).offset(12)
            make.trailing.equalToSuperview().offset(-14)
        }
        
        authorLabel.snp.makeConstraints { make in
            authorTopConstraint = make.top.equalTo(titleLabel.snp.bottom).offset(3).constraint
            make.leading.trailing.equalTo(titleLabel)
        }

        sourceLabel.snp.makeConstraints { make in
            sourceTopConstraint = make.top.equalTo(authorLabel.snp.bottom).offset(6).constraint
            make.leading.equalTo(titleLabel)
            sourceHeightConstraint = make.height.greaterThanOrEqualTo(18).priority(750).constraint
            make.trailing.lessThanOrEqualToSuperview().offset(-14)
        }

        latestLabel.snp.makeConstraints { make in
            make.centerY.equalTo(sourceLabel)
            make.leading.greaterThanOrEqualTo(sourceLabel.snp.trailing).offset(6)
            make.trailing.lessThanOrEqualToSuperview().offset(-14)
            latestHeightConstraint = make.height.greaterThanOrEqualTo(18).priority(750).constraint
        }

        metaLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(titleLabel)
            make.top.equalTo(sourceLabel.snp.bottom).offset(7)
        }
        
        introLabel.snp.makeConstraints { make in
            introTopConstraint = make.top.equalTo(metaLabel.snp.bottom).offset(8).constraint
            make.leading.trailing.equalTo(titleLabel)
            make.bottom.lessThanOrEqualToSuperview().offset(-12)
        }

        setDensity(.comfortable, animated: false)
    }
    
    func configure(
        name: String,
        author: String,
        sourceName: String?,
        latestChapter: String?,
        kind: String?,
        wordCount: String?,
        sourceUrl: String?,
        bookUrl: String?,
        coverUrl: String?,
        intro: String?
    ) {
        titleLabel.text = name
        let cleanAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        authorLabel.text = cleanAuthor.isEmpty ? "作者 · 未知" : "作者 · \(cleanAuthor)"

        var source = (sourceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty, let host = URL(string: sourceUrl ?? "")?.host, !host.isEmpty {
            source = host
        }
        if source.isEmpty {
            source = "来源未知"
        }
        sourceLabel.text = source
        sourceLabel.isHidden = false

        let latest = (latestChapter ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if latest.isEmpty {
            latestLabel.isHidden = true
            latestLabel.text = nil
        } else {
            latestLabel.isHidden = false
            latestLabel.text = "最新 \(latest)"
        }

        let cleanKind = (kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanWords = (wordCount ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var metaItems: [String] = []
        if !cleanKind.isEmpty { metaItems.append("分类 \(cleanKind)") }
        if !cleanWords.isEmpty { metaItems.append("字数 \(cleanWords)") }
        metaLabel.text = metaItems.isEmpty ? "暂无分类/字数信息" : metaItems.joined(separator: "  ·  ")

        introLabel.text = intro?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? intro?.trimmingCharacters(in: .whitespacesAndNewlines)
            : "暂无简介"

        let cover = CoverURLResolver.resolve(raw: coverUrl, baseCandidates: [sourceUrl ?? "", bookUrl ?? ""])
        CoverImageLoader.setImage(
            on: coverImageView,
            url: cover,
            placeholder: CoverImageLoader.defaultPlaceholder,
            refererCandidates: [sourceUrl ?? "", bookUrl ?? ""]
        )
    }
    
    func cancelImageDownload() {
        coverImageView.kf.cancelDownloadTask()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverImageView.kf.cancelDownloadTask()
        coverImageView.image = CoverImageLoader.defaultPlaceholder
        titleLabel.text = nil
        authorLabel.text = nil
        sourceLabel.text = nil
        sourceLabel.isHidden = false
        latestLabel.text = nil
        latestLabel.isHidden = true
        metaLabel.text = nil
        introLabel.text = nil
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        let updates = {
            self.cardView.transform = highlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
            self.cardView.backgroundColor = highlighted
                ? BookListCell.cardHighlightedBackgroundColor
                : BookListCell.cardNormalBackgroundColor
        }
        if animated {
            UIView.animate(withDuration: 0.12, animations: updates)
        } else {
            updates()
        }
    }

    func setDensity(_ density: LayoutDensity, animated: Bool) {
        guard density != currentDensity else { return }
        currentDensity = density

        let apply = {
            switch density {
            case .comfortable:
                self.coverTopConstraint?.update(offset: 10)
                self.coverBottomConstraint?.update(offset: -10)
                self.coverWidthConstraint?.update(offset: 92)
                self.titleTopConstraint?.update(offset: 12)
                self.authorTopConstraint?.update(offset: 3)
                self.sourceTopConstraint?.update(offset: 6)
                self.introTopConstraint?.update(offset: 8)
                self.sourceHeightConstraint?.update(offset: 18)
                self.latestHeightConstraint?.update(offset: 18)
                self.titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
                self.titleLabel.numberOfLines = 2
                self.metaLabel.font = .systemFont(ofSize: 11, weight: .medium)
                self.introLabel.font = .systemFont(ofSize: 12)
                self.introLabel.numberOfLines = 2

            case .compact:
                self.coverTopConstraint?.update(offset: 8)
                self.coverBottomConstraint?.update(offset: -8)
                self.coverWidthConstraint?.update(offset: 76)
                self.titleTopConstraint?.update(offset: 10)
                self.authorTopConstraint?.update(offset: 2)
                self.sourceTopConstraint?.update(offset: 4)
                self.introTopConstraint?.update(offset: 6)
                self.sourceHeightConstraint?.update(offset: 16)
                self.latestHeightConstraint?.update(offset: 16)
                self.titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
                self.titleLabel.numberOfLines = 1
                self.metaLabel.font = .systemFont(ofSize: 10, weight: .medium)
                self.introLabel.font = .systemFont(ofSize: 11)
                self.introLabel.numberOfLines = 1
            }
            self.layoutIfNeeded()
        }

        if animated {
            UIView.animate(withDuration: 0.18, animations: apply)
        } else {
            apply()
        }
    }
}

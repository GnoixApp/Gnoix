import UIKit
import SnapKit
import Kingfisher

class BookSearchViewController: UIViewController {

    private struct SearchQuery {
        let raw: String
        let backendKeyword: String
        let titleTerms: [String]
        let authorTerms: [String]
    }

    private var searchResults: [SearchBook] = []
    private var serverSources: [BookSourceResponse] = []
    private var concurrentCount: Int = 24
    
    // 分页相关
    private var currentPage: Int = 1
    private var isLoadingMore: Bool = false
    private var hasMoreData: Bool = true
    private var currentKeyword: String = ""
    private var currentBackendKeyword: String = ""
    private var currentQuery: SearchQuery?
    private var lastIndex: Int = -1
    private var searchRequestId: Int = 0
    private var searchTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var concurrentBarButton: UIBarButtonItem?
    
    // 下拉加载更多
    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(loadMoreData), for: .valueChanged)
        return rc
    }()
    
    private lazy var searchBar: UISearchBar = {
        let sb = UISearchBar()
        sb.placeholder = "搜索书名/作者（支持 作者:关键词）"
        sb.delegate = self
        sb.searchBarStyle = .minimal
        return sb
    }()

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.delegate = self
        tv.dataSource = self
        tv.register(BookSearchCell.self, forCellReuseIdentifier: BookSearchCell.identifier)
        tv.rowHeight = 154
        tv.separatorStyle = .none
        tv.refreshControl = refreshControl
        tv.alwaysBounceVertical = true
        tv.backgroundColor = .clear
        return tv
    }()

    private lazy var footerIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private lazy var loadingFooterView: UIView = {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 54))
        container.addSubview(footerIndicator)
        footerIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        return container
    }()

    private lazy var emptyView: UILabel = {
        let label = UILabel()
        label.text = "输入书名进行搜索"
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }()

    private lazy var loadingView: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadBookSources()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelSearchTasks()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelSearchTasks()
        }
    }

    deinit {
        cancelSearchTasks()
    }

    private func setupUI() {
        let modeText = BookParseManager.shared.isServerMode ? "搜索(服务器)" : "搜索(本地解析)"
        title = modeText
        view.backgroundColor = .systemGroupedBackground
        
        let settingsButton = UIBarButtonItem(
            title: "并发 \(concurrentCount)",
            style: .plain,
            target: self,
            action: #selector(showConcurrentPicker)
        )
        concurrentBarButton = settingsButton
        navigationItem.rightBarButtonItem = settingsButton

        view.addSubview(searchBar)
        view.addSubview(tableView)
        view.addSubview(emptyView)
        view.addSubview(loadingView)

        searchBar.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview()
        }

        tableView.snp.makeConstraints { make in
            make.top.equalTo(searchBar.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview()
        }

        emptyView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        loadingView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        updateConcurrentButtonState()
    }

    @objc private func showConcurrentPicker() {
        let alert = UIAlertController(title: "选择并发数", message: nil, preferredStyle: .actionSheet)
        
        let counts = [12, 18, 24, 30, 36, 42, 48, 54, 60]
        for count in counts {
            alert.addAction(UIAlertAction(title: "\(count)并发线程", style: .default) { [weak self] _ in
                self?.concurrentCount = count
                self?.updateConcurrentButtonState()
            })
        }
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: 80, width: 1, height: 1)
        }
        
        present(alert, animated: true)
    }
    
    private func loadBookSources() {
        loadServerSources()
    }
    
    private func loadServerSources() {
        Task {
            do {
                let sources = try await ReaderServerAPI.shared.getBookSources()
                await MainActor.run {
                    self.serverSources = sources.filter { source in
                        guard source.enabled else { return false }
                        guard let searchUrl = source.searchUrl else { return false }
                        return !searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    self.updateConcurrentButtonState()
                }
            } catch {
                print("Load server sources error: \(error)")
                await MainActor.run {
                    self.serverSources = []
                    self.updateConcurrentButtonState()
                }
            }
        }
    }

    private func search(keyword: String) {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return }
        let query = parseSearchQuery(trimmedKeyword)
        guard !query.backendKeyword.isEmpty else { return }

        cancelSearchTasks()
        let requestId = searchRequestId

        // 重置分页状态
        currentPage = 1
        hasMoreData = true
        lastIndex = -1
        currentKeyword = trimmedKeyword
        currentBackendKeyword = query.backendKeyword
        currentQuery = query
        searchResults = []
        
        loadingView.startAnimating()
        emptyView.isHidden = true
        tableView.reloadData()

        searchMultiSource(requestId: requestId)
    }
    
    @objc private func loadMoreData() {
        let started = loadMoreIfNeeded()
        if !started {
            refreshControl.endRefreshing()
        }
    }

    @discardableResult
    private func loadMoreIfNeeded() -> Bool {
        guard !isLoadingMore,
              hasMoreData,
              !currentBackendKeyword.isEmpty else {
            return false
        }

        isLoadingMore = true
        footerIndicator.startAnimating()
        tableView.tableFooterView = loadingFooterView
        loadMoreFromServer()
        return true
    }

    private func loadMoreFromServer() {
        let requestId = searchRequestId
        loadMoreTask?.cancel()
        loadMoreTask = Task {
            do {
                let result = try await ReaderServerAPI.shared.searchMulti(
                    keyword: currentBackendKeyword,
                    bookSourceGroup: nil,
                    concurrentCount: concurrentCount,
                    lastIndex: lastIndex
                )
                
                let newBooks = self.filterSearchBooks(
                    result.list.map { self.makeSearchBook(from: $0) },
                    by: self.currentQuery
                )
                
                await MainActor.run {
                    guard self.searchRequestId == requestId else { return }
                    self.lastIndex = result.lastIndex
                    self.hasMoreData = self.lastIndex >= 0
                    self.appendUniqueSearchBooks(newBooks)
                    self.currentPage += 1
                    self.isLoadingMore = false
                    self.refreshControl.endRefreshing()
                    self.footerIndicator.stopAnimating()
                    self.tableView.tableFooterView = UIView(frame: .zero)
                    self.emptyView.isHidden = !self.searchResults.isEmpty
                    self.emptyView.text = self.searchResults.isEmpty
                        ? (self.hasMoreData ? "当前批次未命中，下拉可继续加载更多书源" : "未找到相关书籍")
                        : (self.hasMoreData
                            ? "已找到 \(self.searchResults.count) 本，下拉可继续加载更多"
                            : "检索完成，共 \(self.searchResults.count) 本")
                    self.tableView.reloadData()
                    self.autoLoadMoreIfNeeded()
                    self.loadMoreTask = nil
                }
            } catch {
                await MainActor.run {
                    guard self.searchRequestId == requestId else { return }
                    self.isLoadingMore = false
                    self.refreshControl.endRefreshing()
                    self.footerIndicator.stopAnimating()
                    self.tableView.tableFooterView = UIView(frame: .zero)
                    if error is CancellationError || Task.isCancelled {
                        self.emptyView.isHidden = !self.searchResults.isEmpty
                        self.loadMoreTask = nil
                        return
                    }
                    self.emptyView.isHidden = !self.searchResults.isEmpty
                    self.emptyView.text = self.searchResults.isEmpty
                        ? "搜索失败，请稍后重试"
                        : "部分书源检索失败，已展示可用结果"
                    self.loadMoreTask = nil
                }
            }
        }
    }
    
    private func searchMultiSource(requestId: Int) {
        guard !serverSources.isEmpty else {
            loadingView.stopAnimating()
            emptyView.isHidden = false
            emptyView.text = "暂无可用书源，请先在书源管理中启用书源"
            return
        }
        
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ReaderServerAPI.shared.searchMulti(
                    keyword: self.currentBackendKeyword,
                    bookSourceGroup: nil,
                    concurrentCount: concurrentCount,
                    lastIndex: -1
                )
                
                let firstBatch = self.filterSearchBooks(
                    result.list.map { self.makeSearchBook(from: $0) },
                    by: self.currentQuery
                )
                
                await MainActor.run {
                    guard self.searchRequestId == requestId else { return }
                    self.lastIndex = result.lastIndex
                    self.hasMoreData = self.lastIndex >= 0
                    self.searchResults = []
                    self.appendUniqueSearchBooks(firstBatch)
                    self.loadingView.stopAnimating()
                    self.emptyView.isHidden = !self.searchResults.isEmpty
                    self.emptyView.text = self.searchResults.isEmpty
                        ? (self.hasMoreData ? "当前批次未命中，下拉可继续加载更多书源" : "未找到相关书籍")
                        : (self.hasMoreData
                            ? "已找到 \(self.searchResults.count) 本，下拉可继续加载更多"
                            : "检索完成，共 \(self.searchResults.count) 本")
                    self.tableView.reloadData()
                    self.autoLoadMoreIfNeeded()
                    self.searchTask = nil
                }
            } catch {
                await MainActor.run {
                    guard self.searchRequestId == requestId else { return }
                    if error is CancellationError || Task.isCancelled {
                        self.searchTask = nil
                        return
                    }
                    self.loadingView.stopAnimating()
                    self.emptyView.isHidden = false
                    self.emptyView.text = "搜索失败: \(error.localizedDescription)"
                    self.searchTask = nil
                }
            }
        }
    }

    private func makeSearchBook(from book: BookInfoResponse) -> SearchBook {
        let sourceUrl = book.sourceUrl ?? ""
        let sourceName = book.originName
            ?? serverSources.first(where: { $0.bookSourceUrl == sourceUrl })?.bookSourceName
            ?? sourceUrl
        
        var sb = SearchBook()
        sb.name = book.name
        sb.author = book.author
        sb.bookUrl = book.bookUrl
        sb.bookSourceUrl = sourceUrl
        sb.origin = sourceUrl
        sb.originName = sourceName
        sb.coverUrl = book.coverUrl
        sb.intro = book.intro
        sb.kind = book.kind
        sb.latestChapter = book.latestChapter
        sb.wordCount = book.wordCount
        return sb
    }

    private func cancelSearchTasks() {
        searchRequestId += 1
        searchTask?.cancel()
        loadMoreTask?.cancel()
        searchTask = nil
        loadMoreTask = nil
        isLoadingMore = false
        loadingView.stopAnimating()
        refreshControl.endRefreshing()
        footerIndicator.stopAnimating()
        tableView.tableFooterView = UIView(frame: .zero)
    }

    private func appendUniqueSearchBooks(_ books: [SearchBook]) {
        var existingKeys = Set(searchResults.map(searchBookKey(_:)))
        for item in books {
            let key = searchBookKey(item)
            if existingKeys.insert(key).inserted {
                searchResults.append(item)
            }
        }
    }

    private func searchBookKey(_ book: SearchBook) -> String {
        let source = book.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let url = book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isReliableBookIdentityURL(url) {
            return "\(source)|\(url)"
        }
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(source)|\(name)|\(author)"
    }

    private func updateConcurrentButtonState() {
        concurrentBarButton?.title = "并发 \(concurrentCount)"
        concurrentBarButton?.isEnabled = !serverSources.isEmpty
    }

    private func autoLoadMoreIfNeeded() {
        guard hasMoreData, !isLoadingMore, !loadingView.isAnimating else { return }
        guard !currentBackendKeyword.isEmpty else { return }
        guard !searchResults.isEmpty else { return }

        let visibleHeight = tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom
        guard visibleHeight > 0 else { return }

        if tableView.contentSize.height <= visibleHeight + 12 {
            _ = loadMoreIfNeeded()
        }
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

    private func parseSearchQuery(_ raw: String) -> SearchQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return SearchQuery(raw: "", backendKeyword: "", titleTerms: [], authorTerms: [])
        }

        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;；|/"))

        var titlePart = trimmed
        var authorPart = ""

        let lowered = trimmed.lowercased()
        if let range = lowered.range(of: "author:") {
            let prefixLength = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefixLength)
            let keywordStart = trimmed.index(start, offsetBy: "author:".count)
            titlePart = String(trimmed[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            authorPart = String(trimmed[keywordStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let range = trimmed.range(of: "作者:") {
            titlePart = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            authorPart = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let titleTerms = titlePart
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let authorTerms = authorPart
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let backendKeyword: String = {
            if titleTerms.count > 1 || authorTerms.count > 1 {
                let merged = titleTerms + authorTerms
                return merged.max(by: { $0.count < $1.count }) ?? trimmed
            }
            if !titlePart.isEmpty {
                return titlePart
            }
            if !authorPart.isEmpty {
                return authorPart
            }
            return trimmed
        }()

        return SearchQuery(
            raw: trimmed,
            backendKeyword: backendKeyword,
            titleTerms: titleTerms,
            authorTerms: authorTerms
        )
    }

    private func filterSearchBooks(_ books: [SearchBook], by query: SearchQuery?) -> [SearchBook] {
        guard let query else { return books }
        guard !(query.titleTerms.isEmpty && query.authorTerms.isEmpty) else { return books }
        return books.filter { matchesSearchQuery(book: $0, query: query) }
    }

    private func matchesSearchQuery(book: SearchBook, query: SearchQuery) -> Bool {
        let normalizedName = normalizedSearchText(book.name)
        let normalizedAuthor = normalizedSearchText(book.author)

        for term in query.titleTerms {
            let needle = normalizedSearchText(term)
            if needle.isEmpty { continue }
            if !normalizedName.contains(needle) && !normalizedAuthor.contains(needle) {
                return false
            }
        }

        for term in query.authorTerms {
            let needle = normalizedSearchText(term)
            if needle.isEmpty { continue }
            if !normalizedAuthor.contains(needle) {
                return false
            }
        }
        return true
    }

    private func normalizedSearchText(_ value: String) -> String {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return "" }
        let stripped = lowered.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped))
    }
}

extension BookSearchViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        if let keyword = searchBar.text {
            search(keyword: keyword)
        }
    }
}

extension BookSearchViewController: UITableViewDelegate, UITableViewDataSource {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offsetY = scrollView.contentOffset.y
        let contentHeight = scrollView.contentSize.height
        let frameHeight = scrollView.frame.height
        guard contentHeight > frameHeight else { return }

        if offsetY > contentHeight - frameHeight - 100 {
            _ = loadMoreIfNeeded()
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return searchResults.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: BookSearchCell.identifier, for: indexPath) as! BookSearchCell
        let searchBook = searchResults[indexPath.row]
        cell.configure(with: searchBook)
        cell.onAddToShelf = { [weak self] in
            self?.addToShelf(searchBook: searchBook)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let searchBook = searchResults[indexPath.row]
        
        // 搜索结果点击进入书籍详情页
        let book = Book(
            bookUrl: searchBook.bookUrl,
            origin: searchBook.bookSourceUrl,
            originName: searchBook.originName ?? searchBook.origin ?? "",
            name: searchBook.name,
            author: searchBook.author,
            kind: searchBook.kind,
            coverUrl: searchBook.coverUrl,
            intro: searchBook.intro,
            latestChapterTitle: searchBook.latestChapter
        )
        
        let bookInfoVC = BookInfoViewController(book: book)
        navigationController?.pushViewController(bookInfoVC, animated: true)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? BookSearchCell)?.cancelImageDownload()
    }
    
    private func addToShelf(searchBook: SearchBook) {
        addToServerShelf(searchBook: searchBook)
    }
    
    private func addToServerShelf(searchBook: SearchBook) {
        Task {
            do {
                let bookInfo = BookInfoResponse(
                    name: searchBook.name,
                    author: searchBook.author,
                    bookUrl: searchBook.bookUrl,
                    sourceUrl: searchBook.bookSourceUrl,
                    coverUrl: searchBook.coverUrl,
                    intro: searchBook.intro,
                    kind: searchBook.kind,
                    latestChapter: searchBook.latestChapter,
                    tocUrl: nil,
                    wordCount: nil,
                    chapterCount: nil,
                    type: 0
                )
                
                try await ReaderServerAPI.shared.addToBookshelf(book: bookInfo)
                
                await MainActor.run {
                    self.showToast("《\(searchBook.name)》已加入书架")
                }
            } catch {
                await MainActor.run {
                    self.showToast("加入书架失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showToast(_ message: String) {
        let toastLabel = UILabel()
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        toastLabel.textColor = .white
        toastLabel.textAlignment = .center
        toastLabel.font = .systemFont(ofSize: 14)
        toastLabel.text = message
        toastLabel.alpha = 0
        toastLabel.layer.cornerRadius = 20
        toastLabel.clipsToBounds = true
        
        view.addSubview(toastLabel)
        toastLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-50)
            make.height.equalTo(40)
            make.width.greaterThanOrEqualTo(150)
        }
        
        UIView.animate(withDuration: 0.3, animations: {
            toastLabel.alpha = 1
        }) { _ in
            UIView.animate(withDuration: 0.3, delay: 1.5, options: [], animations: {
                toastLabel.alpha = 0
            }) { _ in
                toastLabel.removeFromSuperview()
            }
        }
    }
}

class BookSearchCell: UITableViewCell {
    static let identifier = "BookSearchCell"
    private static let cardNormalBackgroundColor = UIColor { trait in
        trait.userInterfaceStyle == .dark ? .secondarySystemBackground : .white
    }

    var onAddToShelf: (() -> Void)?

    private let cardView: UIView = {
        let view = UIView()
        view.backgroundColor = BookSearchCell.cardNormalBackgroundColor
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 0
        view.clipsToBounds = true
        return view
    }()

    private let coverImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 0
        iv.layer.maskedCorners = []
        iv.backgroundColor = .clear
        return iv
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.numberOfLines = 2
        return label
    }()

    private let authorLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        return label
    }()

    private let sourceTag: PaddingLabel = {
        let label = PaddingLabel(insets: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .systemBlue
        label.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        label.clipsToBounds = true
        label.layer.cornerRadius = 8
        return label
    }()

    private let introLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .tertiaryLabel
        label.numberOfLines = 2
        return label
    }()

    private let metaLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var addButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("加入书架", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        button.tintColor = .systemBlue
        button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        button.layer.cornerRadius = 12
        button.addTarget(self, action: #selector(addButtonTapped), for: .touchUpInside)
        return button
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(cardView)
        cardView.addSubview(coverImageView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(authorLabel)
        cardView.addSubview(sourceTag)
        cardView.addSubview(metaLabel)
        cardView.addSubview(introLabel)
        cardView.addSubview(addButton)

        cardView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2))
        }

        coverImageView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(92)
        }

        addButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-12)
            make.top.equalToSuperview().offset(12)
            make.width.equalTo(74)
            make.height.equalTo(26)
        }

        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(8)
            make.leading.equalTo(coverImageView.snp.trailing).offset(12)
            make.trailing.equalTo(addButton.snp.leading).offset(-8)
        }

        authorLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(3)
            make.leading.equalTo(titleLabel)
            make.trailing.lessThanOrEqualTo(addButton.snp.leading).offset(-8)
        }

        sourceTag.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel)
            make.top.equalTo(authorLabel.snp.bottom).offset(6)
            make.height.greaterThanOrEqualTo(18)
            make.trailing.lessThanOrEqualTo(addButton.snp.leading).offset(-8)
        }

        metaLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel)
            make.trailing.equalToSuperview().offset(-12)
            make.top.equalTo(sourceTag.snp.bottom).offset(6)
        }

        introLabel.snp.makeConstraints { make in
            make.top.equalTo(metaLabel.snp.bottom).offset(6)
            make.leading.trailing.equalTo(titleLabel)
            make.bottom.lessThanOrEqualToSuperview().offset(-8)
        }
    }
    
    @objc private func addButtonTapped() {
        onAddToShelf?()
    }

    func configure(with book: SearchBook) {
        titleLabel.text = book.name
        authorLabel.text = book.author.isEmpty ? "作者 · 未知" : "作者 · \(book.author)"
        introLabel.text = (book.intro?.isEmpty == false ? book.intro : "暂无简介")

        let sourceName = resolvedSourceName(book: book)
        sourceTag.text = sourceName
        sourceTag.isHidden = sourceName.isEmpty

        let kind = (book.kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = (book.wordCount ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let latest = (book.latestChapter ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var metaItems: [String] = []
        if !kind.isEmpty { metaItems.append("分类 \(kind)") }
        if !words.isEmpty { metaItems.append("字数 \(words)") }
        if !latest.isEmpty { metaItems.append("更新 \(latest)") }
        metaLabel.text = metaItems.isEmpty ? "暂无分类/字数/更新信息" : metaItems.joined(separator: "  ·  ")

        CoverImageLoader.setImage(
            on: coverImageView,
            url: book.resolvedCoverURL(),
            placeholder: CoverImageLoader.defaultPlaceholder,
            refererCandidates: [book.bookSourceUrl, book.origin ?? "", book.bookUrl]
        )
    }

    private func resolvedSourceName(book: SearchBook) -> String {
        if let originName = book.originName, !originName.isEmpty {
            return originName
        }
        if let host = URL(string: book.bookSourceUrl)?.host, !host.isEmpty {
            return host
        }
        if let origin = book.origin, !origin.isEmpty {
            return origin
        }
        return ""
    }

    func cancelImageDownload() {
        coverImageView.kf.cancelDownloadTask()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelImageDownload()
        coverImageView.image = CoverImageLoader.defaultPlaceholder
        titleLabel.text = nil
        authorLabel.text = nil
        sourceTag.text = nil
        introLabel.text = nil
        metaLabel.text = nil
        onAddToShelf = nil
    }
}

import UIKit
import SnapKit
import Kingfisher

class BookInfoViewController: UIViewController {

    private var book: Book
    private var chaptersLoadedObserver: NSObjectProtocol?
    private var chaptersLoadFailedObserver: NSObjectProtocol?
    private var wasAutoAddedToShelf = false
    private var isChaptersLoaded = false
    private let verboseLoggingEnabled = false

    private func log(_ message: @autoclosure () -> String) {
        guard verboseLoggingEnabled else { return }
        Swift.print(message())
    }

    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.alwaysBounceVertical = true
        return sv
    }()

    private lazy var contentView = UIView()

    private lazy var coverImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        iv.backgroundColor = .secondarySystemFill
        iv.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(coverTapped))
        iv.addGestureRecognizer(tap)
        return iv
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()

    private lazy var authorLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    private lazy var infoLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.numberOfLines = 1
        return label
    }()

    private lazy var readButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("加载目录中...", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = .systemGray
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.isEnabled = false
        button.addTarget(self, action: #selector(readTapped), for: .touchUpInside)
        return button
    }()

    private lazy var introLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    private lazy var chapterHeaderLabel: UILabel = {
        let label = UILabel()
        label.text = "目录"
        label.font = .systemFont(ofSize: 16, weight: .bold)
        label.isHidden = true
        return label
    }()
    
    private lazy var chapterTableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "ChapterCell")
        tv.rowHeight = 44
        tv.isHidden = true
        tv.tag = 100
        return tv
    }()
    
    private lazy var chapterLoadingView: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()
    
    private var chapters: [BookChapter] = []
    
    private lazy var canUpdateSwitch: UISwitch = {
        let sw = UISwitch()
        sw.addTarget(self, action: #selector(canUpdateChanged), for: .valueChanged)
        return sw
    }()
    
    private lazy var groupButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("设置分组", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.backgroundColor = .secondarySystemFill
        button.layer.cornerRadius = 8
        button.addTarget(self, action: #selector(groupTapped), for: .touchUpInside)
        return button
    }()

    private lazy var sourceLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .systemGray
        label.textAlignment = .center
        return label
    }()

    private lazy var changeSourceButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("换源", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.backgroundColor = .secondarySystemFill
        button.layer.cornerRadius = 8
        button.addTarget(self, action: #selector(changeSourceTapped), for: .touchUpInside)
        return button
    }()

    init(book: Book) {
        self.book = book
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        configureData()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // 检查是否需要加载目录
        let engine = ReadBookEngine.shared
        
        // 如果书籍相同且已有章节，不重复加载
        if shouldReuseLoadedChapters(engineBook: engine.book, targetBook: book) && !engine.chapters.isEmpty {
            updateChapterInfo()
            return
        }
        
        // 延迟加载，确保UI已准备好
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.autoLoadChapters()
        }
    }
    
    private func autoLoadChapters() {
        log("[BookInfo] autoLoadChapters called for: \(book.name), origin: \(book.origin)")
        
        // 重置按钮状态
        isChaptersLoaded = false
        readButton.isEnabled = false
        readButton.backgroundColor = .systemGray
        readButton.setTitle("加载目录中...", for: .normal)
        
        // 检查不是本地书籍
        guard book.origin != Book.localTag else { 
            log("[BookInfo] Skipping - local tag")
            isChaptersLoaded = true
            readButton.isEnabled = true
            readButton.backgroundColor = .systemBlue
            readButton.setTitle("开始阅读", for: .normal)
            return 
        }
        
        // 显示目录加载状态
        chapters = []
        chapterTableView.reloadData()
        chapterLoadingView.startAnimating()
        chapterHeaderLabel.text = "目录"
        chapterHeaderLabel.isHidden = false
        chapterTableView.isHidden = false
        
        // 清理之前的observer
        cleanupObservers()
        
        let engine = ReadBookEngine.shared

        chaptersLoadedObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("ChaptersLoaded"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            if let loadedBookUrl = notification.userInfo?["bookUrl"] as? String {
                let currentBookUrl = self.book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentBookUrl.isEmpty,
                   loadedBookUrl.trimmingCharacters(in: .whitespacesAndNewlines) != currentBookUrl {
                    return
                }
            }
            if engine.book?.bookUrl == self.book.bookUrl {
                self.cleanupObservers()
                self.updateChapterInfo()
            }
        }
        
        chaptersLoadFailedObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("ChaptersLoadFailed"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            self.cleanupObservers()
            self.chapterLoadingView.stopAnimating()
            self.chapterHeaderLabel.text = "目录加载失败"
        }

        engine.openBook(book)
    }
    
    private func cleanupObservers() {
        if let observer = chaptersLoadedObserver {
            NotificationCenter.default.removeObserver(observer)
            chaptersLoadedObserver = nil
        }
        if let observer = chaptersLoadFailedObserver {
            NotificationCenter.default.removeObserver(observer)
            chaptersLoadFailedObserver = nil
        }
    }
    
    private func updateChapterInfo() {
        let engine = ReadBookEngine.shared
        chapterLoadingView.stopAnimating()
        
        if engine.chapters.count > 0 {
            isChaptersLoaded = true
            chapters = engine.chapters
            chapterHeaderLabel.isHidden = false
            chapterTableView.isHidden = false
            book.totalChapterNum = engine.chapters.count
            if let latestTitle = engine.chapters.last?.title {
                book.latestChapterTitle = latestTitle
            }
            
            chapterHeaderLabel.text = "目录 (\(chapters.count)章)"
            chapterTableView.reloadData()
            
            // 启用开始阅读按钮
            readButton.isEnabled = true
            readButton.backgroundColor = .systemBlue
            readButton.setTitle("开始阅读", for: .normal)
            
            configureData()
        } else {
            chapterHeaderLabel.isHidden = false
            chapterTableView.isHidden = false
            chapterHeaderLabel.text = "目录为空"
            readButton.setTitle("目录加载失败", for: .normal)
        }
    }

    private func shouldReuseLoadedChapters(engineBook: Book?, targetBook: Book) -> Bool {
        guard let engineBook else { return false }
        let engineURL = normalizedIdentityText(engineBook.bookUrl)
        let targetURL = normalizedIdentityText(targetBook.bookUrl)
        guard !engineURL.isEmpty, engineURL == targetURL else { return false }

        let engineOrigin = normalizedIdentityText(engineBook.origin)
        let targetOrigin = normalizedIdentityText(targetBook.origin)
        if !engineOrigin.isEmpty, !targetOrigin.isEmpty, engineOrigin != targetOrigin {
            return false
        }

        let engineToc = normalizedIdentityText(engineBook.tocUrl)
        let targetToc = normalizedIdentityText(targetBook.tocUrl)
        if !engineToc.isEmpty || !targetToc.isEmpty {
            guard !engineToc.isEmpty, engineToc == targetToc else { return false }
        }

        let engineName = normalizedIdentityText(engineBook.name)
        let targetName = normalizedIdentityText(targetBook.name)
        guard !engineName.isEmpty, !targetName.isEmpty, engineName == targetName else {
            return false
        }

        let engineAuthor = normalizedIdentityText(engineBook.author)
        let targetAuthor = normalizedIdentityText(targetBook.author)
        if !engineAuthor.isEmpty || !targetAuthor.isEmpty {
            guard !engineAuthor.isEmpty, !targetAuthor.isEmpty, engineAuthor == targetAuthor else {
                return false
            }
        }
        return true
    }

    private func normalizedIdentityText(_ raw: String) -> String {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return "" }
        let filtered = lowered.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(filtered))
    }
    
    deinit {
        if let observer = chaptersLoadedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = chaptersLoadFailedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupUI() {
        title = "书籍详情"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "ellipsis.circle"),
                style: .plain,
                target: self,
                action: #selector(showMoreActions(_:))
            ),
            UIBarButtonItem(
                image: UIImage(systemName: "trash"),
                style: .plain,
                target: self,
                action: #selector(deleteTapped)
            )
        ]

        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        contentView.addSubview(coverImageView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(authorLabel)
        contentView.addSubview(infoLabel)
        contentView.addSubview(sourceLabel)
        contentView.addSubview(changeSourceButton)
        contentView.addSubview(readButton)
        contentView.addSubview(chapterHeaderLabel)
        contentView.addSubview(chapterTableView)
        contentView.addSubview(chapterLoadingView)
        contentView.addSubview(introLabel)

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.width.equalTo(view)
        }

        coverImageView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(20)
            make.centerX.equalToSuperview()
            make.size.equalTo(CGSize(width: 120, height: 160))
        }

        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(coverImageView.snp.bottom).offset(16)
            make.leading.equalToSuperview().offset(20)
            make.trailing.equalToSuperview().offset(-20)
        }

        authorLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalTo(titleLabel)
        }

        infoLabel.snp.makeConstraints { make in
            make.top.equalTo(authorLabel.snp.bottom).offset(4)
            make.leading.trailing.equalTo(titleLabel)
        }

        sourceLabel.snp.makeConstraints { make in
            make.top.equalTo(infoLabel.snp.bottom).offset(8)
            make.leading.trailing.equalTo(titleLabel)
        }

        changeSourceButton.snp.makeConstraints { make in
            make.top.equalTo(sourceLabel.snp.bottom).offset(8)
            make.centerX.equalToSuperview()
            make.width.equalTo(100)
            make.height.equalTo(32)
        }

        readButton.snp.makeConstraints { make in
            make.top.equalTo(changeSourceButton.snp.bottom).offset(20)
            make.leading.equalToSuperview().offset(40)
            make.trailing.equalToSuperview().offset(-40)
            make.height.equalTo(44)
        }

        chapterHeaderLabel.snp.makeConstraints { make in
            make.top.equalTo(readButton.snp.bottom).offset(20)
            make.leading.equalToSuperview().offset(20)
            make.trailing.equalToSuperview().offset(-20)
        }

        chapterLoadingView.snp.makeConstraints { make in
            make.centerY.equalTo(chapterHeaderLabel)
            make.trailing.equalToSuperview().offset(-20)
        }

        chapterTableView.snp.makeConstraints { make in
            make.top.equalTo(chapterHeaderLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(300)
        }

        introLabel.snp.makeConstraints { make in
            make.top.equalTo(chapterTableView.snp.bottom).offset(20)
            make.leading.equalToSuperview().offset(20)
            make.trailing.equalToSuperview().offset(-20)
            make.bottom.equalToSuperview().offset(-20)
        }
    }

    @objc private func showMoreActions(_ sender: UIBarButtonItem) {
        let alert = UIAlertController(title: "更多操作", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "缓存全书", style: .default) { [weak self] _ in
            self?.cacheCurrentBook()
        })

        alert.addAction(UIAlertAction(title: "删除缓存", style: .destructive) { [weak self] _ in
            self?.deleteCurrentBookCache()
        })

        alert.addAction(UIAlertAction(title: "导出 TXT", style: .default) { [weak self] _ in
            self?.exportCurrentBook(isEpub: false)
        })

        alert.addAction(UIAlertAction(title: "导出 EPUB", style: .default) { [weak self] _ in
            self?.exportCurrentBook(isEpub: true)
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = sender
        }
        present(alert, animated: true)
    }

    private func cacheCurrentBook() {
        Task {
            do {
                try await ReaderServerAPI.shared.cacheBook(bookUrl: book.bookUrl)
                await MainActor.run {
                    self.showAlert("已开始缓存", "系统将按当前书源逐章缓存内容")
                }
            } catch {
                await MainActor.run {
                    self.showAlert("缓存失败", error.localizedDescription)
                }
            }
        }
    }

    private func deleteCurrentBookCache() {
        Task {
            do {
                try await ReaderServerAPI.shared.deleteBookCache(bookUrl: book.bookUrl)
                await MainActor.run {
                    self.showAlert("已删除缓存", "当前书籍缓存已清理")
                }
            } catch {
                await MainActor.run {
                    self.showAlert("删除失败", error.localizedDescription)
                }
            }
        }
    }

    private func exportCurrentBook(isEpub: Bool) {
        Task {
            do {
                let fileURL = try await ReaderServerAPI.shared.exportBook(bookUrl: book.bookUrl, isEpub: isEpub)
                await MainActor.run {
                    let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                    if let popover = activityVC.popoverPresentationController {
                        popover.sourceView = self.view
                        popover.sourceRect = CGRect(
                            x: self.view.bounds.midX,
                            y: self.view.bounds.midY,
                            width: 1,
                            height: 1
                        )
                    }
                    self.present(activityVC, animated: true)
                }
            } catch {
                await MainActor.run {
                    self.showAlert("导出失败", error.localizedDescription)
                }
            }
        }
    }

    @objc private func deleteTapped() {
        let alert = UIAlertController(title: "确认删除", message: "确定要删除《\(book.name)》吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            
            Task {
                do {
                    try await ReaderServerAPI.shared.removeFromBookshelf(
                        bookUrl: self.book.bookUrl,
                        sourceUrl: self.book.origin
                    )
                } catch {
                    self.log("Delete from server failed: \(error)")
                }
            }
            DatabaseManager.shared.deleteBook(self.book.bookUrl)
            self.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
    
    @objc private func coverTapped() {
        let alert = UIAlertController(title: "更换封面", message: nil, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "从相册选择", style: .default) { [weak self] _ in
            self?.pickImageFromGallery()
        })
        
        if book.customCoverUrl != nil {
            alert.addAction(UIAlertAction(title: "恢复默认封面", style: .destructive) { [weak self] _ in
                self?.resetCover()
            })
        }
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func pickImageFromGallery() {
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        present(picker, animated: true)
    }
    
    private func resetCover() {
        book.customCoverUrl = nil
        coverImageView.image = CoverImageLoader.defaultPlaceholder
        DatabaseManager.shared.saveBook(book)
    }
    
    @objc private func canUpdateChanged(_ sender: UISwitch) {
        book.canUpdate = sender.isOn
        DatabaseManager.shared.saveBook(book)
    }

    @objc private func changeSourceTapped() {
        guard !book.bookUrl.isEmpty else {
            showAlert("无法换源", "书籍URL无效")
            return
        }

        let vc = SourceListViewController(book: book) { [weak self] source in
            guard let self = self else { return }
            
            let loading = UIAlertController(title: "切换书源", message: "正在切换到: \(source.name)", preferredStyle: .alert)
            loading.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                self?.dismiss(animated: true)
            })
            self.present(loading, animated: true)

            Task {
                do {
                    if !ReaderServerAPI.shared.isInBookshelf(bookUrl: self.book.bookUrl) {
                        throw NSError(
                            domain: "BookInfoViewController",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "请先手动加入书架后再换源"]
                        )
                    }
                    
                    let newBook = try await ReaderServerAPI.shared.switchToSource(
                        bookUrl: self.book.bookUrl,
                        newUrl: source.bookUrl,
                        bookSourceUrl: source.bookSourceUrl
                    )

                    await MainActor.run {
                        let oldName = self.book.name
                        let oldAuthor = self.book.author
                        self.book.bookUrl = newBook.bookUrl
                        self.book.origin = newBook.origin
                        self.book.originName = newBook.originName
                        if !newBook.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.book.tocUrl = newBook.tocUrl
                        }
                        let switchedName = newBook.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.book.name = switchedName.isEmpty ? oldName : newBook.name
                        let switchedAuthor = newBook.author.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.book.author = switchedAuthor.isEmpty ? oldAuthor : newBook.author
                        if let cover = newBook.coverUrl,
                           !cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.book.coverUrl = cover
                        }
                        if let intro = newBook.intro,
                           !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.book.intro = intro
                        }
                        self.book.kind = newBook.kind
                        self.book.totalChapterNum = newBook.totalChapterNum

                        DatabaseManager.shared.saveBook(self.book)

                        self.cleanupObservers()

                        // 重置本地章节状态
                        self.chapters = []
                        self.chapterTableView.reloadData()
                        self.chapterHeaderLabel.text = "目录"
                        self.chapterLoadingView.stopAnimating()

                        // 重置阅读进度
                        self.book.durChapterIndex = 0
                        self.book.durChapterPos = 0
                        DatabaseManager.shared.saveBook(self.book)

                        // 强制 engine 重新加载，清理旧状态
                        ReadBookEngine.shared.reset()

                        loading.dismiss(animated: true) {
                            self.configureData()
                            self.showAlert("换源成功", "已切换到: \(source.name)")
                        }
                    }
                } catch {
                    await MainActor.run {
                        loading.dismiss(animated: true) {
                            self.showAlert("切换失败", error.localizedDescription)
                        }
                    }
                }
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
    
    @objc private func groupTapped() {
        let alert = UIAlertController(title: "设置分组", message: nil, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "默认分组", style: .default) { [weak self] _ in
            self?.setGroup(0)
        })
        
        alert.addAction(UIAlertAction(title: "收藏", style: .default) { [weak self] _ in
            self?.setGroup(1)
        })
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func setGroup(_ groupId: Int64) {
        book.group = groupId
        groupButton.setTitle(BookGroupManager.shared.getGroupName(for: groupId), for: .normal)
        DatabaseManager.shared.saveBook(book)
    }

    private func configureData() {
        titleLabel.text = book.name
        authorLabel.text = book.author

        var infoTexts: [String] = []
        if let kind = book.kind {
            infoTexts.append(kind)
        }
        if book.totalChapterNum > 0 {
            infoTexts.append("\(book.totalChapterNum)章")
        }
        if let latestChapter = book.latestChapterTitle {
            infoTexts.append("最新: \(latestChapter)")
        }
        infoLabel.text = infoTexts.joined(separator: " · ")

        introLabel.text = book.intro ?? "暂无简介"

        CoverImageLoader.setImage(
            on: coverImageView,
            url: book.resolvedCoverURL(),
            placeholder: CoverImageLoader.defaultPlaceholder,
            refererCandidates: [book.origin, book.tocUrl, book.bookUrl]
        )

        if book.durChapterIndex > 0 {
            readButton.setTitle("继续阅读", for: .normal)
        }

        if book.origin != Book.localTag {
            changeSourceButton.isHidden = false
        } else {
            changeSourceButton.isHidden = true
        }
        
        canUpdateSwitch.isOn = book.canUpdate
        groupButton.setTitle(BookGroupManager.shared.getGroupName(for: book.group), for: .normal)
    }

    @objc private func readTapped() {
        let engine = ReadBookEngine.shared
        
        // 如果目录已加载，直接进入阅读
        if shouldReuseLoadedChapters(engineBook: engine.book, targetBook: book) && !engine.chapters.isEmpty {
            let readerVC = ReaderViewController(book: book, wasAutoAddedToShelf: wasAutoAddedToShelf)
            readerVC.modalPresentationStyle = .fullScreen
            present(readerVC, animated: true)
            return
        }
        
        // 需要加载目录
        if book.origin != Book.localTag && !book.origin.isEmpty {
            // 清理之前的 observer
            if let observer = chaptersLoadedObserver {
                NotificationCenter.default.removeObserver(observer)
                chaptersLoadedObserver = nil
            }
            if let observer = chaptersLoadFailedObserver {
                NotificationCenter.default.removeObserver(observer)
                chaptersLoadFailedObserver = nil
            }
            
            // 不需要先加入书架，直接开始阅读
            startReading(engine: engine)
        } else {
            // Local book or no server
            engine.openBook(book)
            let readerVC = ReaderViewController(book: book)
            readerVC.modalPresentationStyle = .fullScreen
            present(readerVC, animated: true)
        }
    }
    
    private func startReading(engine: ReadBookEngine) {
        // Show loading
        let loadingAlert = UIAlertController(title: "加载中", message: "正在获取章节和内容...\n请稍候", preferredStyle: .alert)
        loadingAlert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.cleanupObservers()
            self?.dismiss(animated: true)
        })
        present(loadingAlert, animated: true)

        // Listen for chapters loaded
        chaptersLoadedObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("ChaptersLoaded"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            if let loadedBookUrl = notification.userInfo?["bookUrl"] as? String {
                let currentBookUrl = self.book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentBookUrl.isEmpty,
                   loadedBookUrl.trimmingCharacters(in: .whitespacesAndNewlines) != currentBookUrl {
                    return
                }
            }
            // 验证是当前书籍的章节加载完成
            guard engine.book?.bookUrl == self.book.bookUrl else { return }
            
            self.cleanupObservers()
            
            // 自动加入书架后保留在书架中（不删除）
            self.wasAutoAddedToShelf = false
            
            loadingAlert.dismiss(animated: true) {
                let readerVC = ReaderViewController(book: self.book, wasAutoAddedToShelf: self.wasAutoAddedToShelf)
                readerVC.modalPresentationStyle = .fullScreen
                self.present(readerVC, animated: true)
            }
        }
        
        chaptersLoadFailedObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("ChaptersLoadFailed"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            
            self.cleanupObservers()
            loadingAlert.dismiss(animated: true) {
                if let message = notification.object as? String {
                    let errorAlert = UIAlertController(title: "加载失败", message: message, preferredStyle: .alert)
                    errorAlert.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(errorAlert, animated: true)
                }
            }
        }

        // Server mode with source switching
        engine.openBook(book)
    }
}

extension BookInfoViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        
        guard let image = info[.originalImage] as? UIImage else { return }
        
        coverImageView.image = image
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension BookInfoViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return chapters.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ChapterCell", for: indexPath)
        let chapter = chapters[indexPath.row]
        cell.textLabel?.text = chapter.title
        cell.textLabel?.font = .systemFont(ofSize: 14)
        
        if indexPath.row == book.durChapterIndex {
            cell.textLabel?.textColor = .systemBlue
        } else {
            cell.textLabel?.textColor = .label
        }
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        // 设置目标章节索引
        book.durChapterIndex = indexPath.row
        
        // 跳转到指定章节
        let engine = ReadBookEngine.shared
        engine.goToChapter(indexPath.row)
        
        let readerVC = ReaderViewController(book: book, wasAutoAddedToShelf: wasAutoAddedToShelf)
        readerVC.modalPresentationStyle = .fullScreen
        present(readerVC, animated: true)
    }
}

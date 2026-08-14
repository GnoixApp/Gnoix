import UIKit
import SnapKit
import AVFoundation
import Kingfisher

class ReaderViewController: UIViewController, UITextViewDelegate, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching {
    private static let verboseLoggingEnabled = false
    private static let comicSourceDetectionStorageKey = "reader_detected_comic_source_scores_v1"
    private static let comicSourceDetectionMaxScore = 30

    private func log(_ message: @autoclosure () -> String) {
        guard Self.verboseLoggingEnabled else { return }
        Swift.print(message())
    }

    private static func normalizedComicSourceKey(_ sourceUrl: String) -> String {
        sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadComicSourceScores() -> [String: Int] {
        guard let stored = UserDefaults.standard.dictionary(forKey: comicSourceDetectionStorageKey) else {
            return [:]
        }
        var result: [String: Int] = [:]
        for (key, raw) in stored {
            let score: Int?
            if let number = raw as? NSNumber {
                score = number.intValue
            } else if let value = raw as? Int {
                score = value
            } else if let text = raw as? String {
                score = Int(text)
            } else {
                score = nil
            }
            guard let score, score > 0 else { continue }
            result[key] = score
        }
        return result
    }

    private static func recordDetectedComicSource(sourceUrl: String, delta: Int = 1) {
        let key = normalizedComicSourceKey(sourceUrl)
        guard !key.isEmpty, key != Book.localTag.lowercased() else { return }
        var scores = loadComicSourceScores()
        let current = scores[key] ?? 0
        scores[key] = min(current + max(delta, 1), comicSourceDetectionMaxScore)
        UserDefaults.standard.set(scores, forKey: comicSourceDetectionStorageKey)
    }

    private var book: Book
    private var bookSource: BookSource?
    private let engine = ReadBookEngine.shared
    private let converter = ChineseConverter.shared
    private var wasAutoAddedToShelf = false
    private var chaptersObserver: NSObjectProtocol?
    private var bookmarkJumpObserver: NSObjectProtocol?
    private var replaceRulesObserver: NSObjectProtocol?
    private var pendingBookmarkHighlightText: String?
    
    private var isTTSPlaying = false
    private var isPreloadingNextChapter = false
    private var ttsPanel: TTSPanelViewController?
    private var isTTSPanelHidden = false
    private var lastTTSParagraphIndex = 0  // 记录最后播放的段落索引
    private let ttsParagraphProgressKeyPrefix = "reader_tts_paragraph_progress_v1"
    
    private var paragraphRanges: [NSRange] = []
    private var textColor: UIColor = .black
    private var pageLabels: [UILabel] = []  // 存储分页模式的每页label
    private var paragraphToPageMap: [Int: Int] = [:]  // 段落索引到页码的映射
    
    private var isTTSActive: Bool {
        return TTSService.shared.isPlaying || isTTSPlaying
    }
    
    private var currentConfig: ReadConfig {
        return engine.book?.readConfig ?? createDefaultConfig()
    }
    
    private var isMenuVisible = false
    private var currentTheme: Int = 0
    private var shouldJumpToFirstPage = false  // 标记是否需要跳转到第一页
    private var shouldJumpToLastPage = false   // 标记是否需要跳转到最后一页
    private let pagingRenderQueue = DispatchQueue(label: "cn.oily.reader.paging.render", qos: .userInitiated)
    private let scrollRenderQueue = DispatchQueue(label: "cn.oily.reader.scroll.render", qos: .userInitiated)
    private var pagingRenderTaskId: Int64 = 0
    private var scrollRenderTaskId: Int64 = 0
    private var lastBoundaryChapterSwitchTime: TimeInterval = 0
    private var pendingChapterSwitchDirection: ChapterSwitchDirection?
    
    private var currentPageMode: Int {
        return currentConfig.pageMode
    }

    private struct PagingBuildResult {
        let attributedText: NSAttributedString
        let pageRanges: [NSRange]
        let paragraphMap: [Int: Int]
        let pageWidth: CGFloat
        let pageHeight: CGFloat
    }

    private struct ScrollBuildResult {
        let attributedText: NSAttributedString
        let paragraphRanges: [NSRange]
    }

    private enum ChapterSwitchDirection {
        case next
        case previous
    }

    private enum PageTurnPhase {
        case inChapter
        case chapterSwitch
    }

    private var isComicImmersiveMode: Bool {
        if engine.currentContent?.isComic == true {
            return true
        }
        if comicCollectionView != nil && !comicCollectionView.isHidden {
            return true
        }
        return false
    }

    override var prefersStatusBarHidden: Bool {
        return isComicImmersiveMode
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return isMenuVisible ? .darkContent : (currentTheme == 1 ? .lightContent : .darkContent)
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return false
    }

    private func refreshStatusBarAppearance() {
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
    }

    private lazy var textView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.showsVerticalScrollIndicator = false
        tv.alwaysBounceVertical = false
        tv.bounces = false
        tv.delegate = self
        tv.backgroundColor = .clear
        tv.isPagingEnabled = false
        return tv
    }()
    
    private lazy var pageView: UIScrollView = {
        let sv = UIScrollView()
        sv.isPagingEnabled = true
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.delegate = self
        sv.isHidden = true
        sv.bounces = false
        sv.alwaysBounceHorizontal = false
        sv.decelerationRate = .fast
        sv.delaysContentTouches = false
        return sv
    }()
    
    private var pageContentView: UIView = {
        let v = UIView()
        return v
    }()
    
    private var comicCollectionView: UICollectionView!
    private var comicImageUrls: [String] = []
    private var comicImageHeightCache: [String: CGFloat] = [:]
    private var comicImageReferer: String?
    private var comicPrefetchTasks: [String: DownloadTask] = [:]
    private let comicPrefetchWindowSize = 8
    private let comicPrefetchEnabled = true
    private let maxComicPrefetchTaskCount = 6
    private var comicLayoutInvalidationWorkItem: DispatchWorkItem?
    private var preheatedChapterIndexes: Set<Int> = []
    private var headerUrlLabel: UILabel!

    private lazy var headerView: UIView = {
        let view = UIView()
        
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .light))
        
        let backBtn = UIButton(type: .system)
        backBtn.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backBtn.setTitle(" 返回", for: .normal)
        backBtn.titleLabel?.font = .systemFont(ofSize: 16)
        backBtn.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        
        let titleLbl = UILabel()
        titleLbl.font = .systemFont(ofSize: 15)
        titleLbl.textAlignment = .center
        titleLbl.numberOfLines = 1
        titleLbl.lineBreakMode = .byTruncatingTail
        titleLbl.text = book.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "正文" : book.name
        self.headerTitleLabel = titleLbl
        
        let sourceBtn = UIButton(type: .system)
        sourceBtn.setTitle("换源", for: .normal)
        sourceBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        if #available(iOS 15.0, *) {
            var config = sourceBtn.configuration ?? UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            sourceBtn.configuration = config
        } else {
            sourceBtn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        }
        sourceBtn.layer.cornerRadius = 17
        sourceBtn.layer.borderWidth = 1
        sourceBtn.layer.borderColor = UIColor.systemGray4.cgColor
        sourceBtn.addTarget(self, action: #selector(switchSourceTapped), for: .touchUpInside)
        self.sourceButton = sourceBtn
        
        let moreBtn = UIButton(type: .system)
        moreBtn.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreBtn.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold),
            forImageIn: .normal
        )
        if #available(iOS 15.0, *) {
            var config = moreBtn.configuration ?? UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            moreBtn.configuration = config
        } else {
            moreBtn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        }
        moreBtn.layer.cornerRadius = 17
        moreBtn.layer.borderWidth = 1
        moreBtn.layer.borderColor = UIColor.systemGray4.cgColor
        moreBtn.addTarget(self, action: #selector(moreTapped(_:)), for: .touchUpInside)
        self.moreButton = moreBtn
        
        let urlLbl = UILabel()
        urlLbl.font = .systemFont(ofSize: 13)
        urlLbl.textColor = .secondaryLabel
        urlLbl.textAlignment = .center
        urlLbl.lineBreakMode = .byTruncatingMiddle
        self.headerUrlLabel = urlLbl
        
        view.addSubview(blur)
        view.addSubview(backBtn)
        view.addSubview(titleLbl)
        view.addSubview(sourceBtn)
        view.addSubview(moreBtn)
        view.addSubview(urlLbl)
        
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }
        
        backBtn.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.top.equalTo(view.safeAreaLayoutGuide).offset(8)
            make.width.equalTo(64)
        }
        
        moreBtn.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-12)
            make.centerY.equalTo(backBtn)
            make.width.height.equalTo(34)
        }
        
        sourceBtn.snp.makeConstraints { make in
            make.trailing.equalTo(moreBtn.snp.leading).offset(-8)
            make.centerY.equalTo(backBtn)
            make.height.equalTo(34)
        }
        
        titleLbl.snp.makeConstraints { make in
            make.leading.equalTo(backBtn.snp.trailing).offset(4)
            make.trailing.equalTo(sourceBtn.snp.leading).offset(-10)
            make.top.equalTo(view.safeAreaLayoutGuide).offset(8)
            make.height.lessThanOrEqualTo(20)
        }

        urlLbl.snp.makeConstraints { make in
            make.leading.equalTo(titleLbl)
            make.trailing.equalTo(titleLbl)
            make.top.equalTo(titleLbl.snp.bottom).offset(1)
            make.height.lessThanOrEqualTo(20)
            make.bottom.lessThanOrEqualToSuperview().offset(-3)
        }
        
        return view
    }()
    
    private var headerTitleLabel: UILabel?
    private var sourceButton: UIButton?
    private var moreButton: UIButton?
    private var headerHeightConstraint: Constraint?
    //加载动画
    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.hidesWhenStopped = true
        indicator.color = .gray // 根据你的主题可以调整颜色
        return indicator
    }()

    private lazy var addToShelfButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "bookmark.fill"), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
        btn.layer.cornerRadius = 22
        btn.clipsToBounds = true
        btn.addTarget(self, action: #selector(addToShelfTapped), for: .touchUpInside)
        return btn
    }()
    
    private lazy var ttsButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "speaker.wave.2.fill"), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.8)
        btn.layer.cornerRadius = 22
        btn.clipsToBounds = true
        btn.addTarget(self, action: #selector(ttsTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var themeFloatingButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "paintpalette.fill"), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.88)
        btn.layer.cornerRadius = 22
        btn.clipsToBounds = true
        btn.addTarget(self, action: #selector(toggleTheme), for: .touchUpInside)
        return btn
    }()

    private lazy var footerView: UIView = {
        let view = UIView()
        
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .light))
        
        let prevBtn = UIButton(type: .system)
        prevBtn.setTitle("◀ 上一章", for: .normal)
        prevBtn.titleLabel?.font = .systemFont(ofSize: 14)
        prevBtn.addTarget(self, action: #selector(prevChapterTapped), for: .touchUpInside)
        
        let chapterLbl = UILabel()
        chapterLbl.font = .systemFont(ofSize: 13)
        chapterLbl.textAlignment = .center
        chapterLbl.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(showChapterList))
        chapterLbl.addGestureRecognizer(tap)
        self.footerChapterLabel = chapterLbl
        
        let nextBtn = UIButton(type: .system)
        nextBtn.setTitle("下一章 ▶", for: .normal)
        nextBtn.titleLabel?.font = .systemFont(ofSize: 14)
        nextBtn.addTarget(self, action: #selector(nextChapterTapped), for: .touchUpInside)
        
        view.addSubview(blur)
        view.addSubview(prevBtn)
        view.addSubview(chapterLbl)
        view.addSubview(nextBtn)
        
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }
        
        prevBtn.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(40)
            make.centerY.equalToSuperview()
        }
        
        chapterLbl.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        
        nextBtn.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-40)
            make.centerY.equalToSuperview()
        }
        
        return view
    }()
    
    private var footerChapterLabel: UILabel?
    
    private var isPagingMode: Bool {
        // 只要不是 0 (滚动)，就进入分页模式布局
        return currentConfig.pageMode != 0
    }

    init(book: Book, wasAutoAddedToShelf: Bool = false) {
        self.book = book
        self.wasAutoAddedToShelf = wasAutoAddedToShelf
        super.init(nibName: nil, bundle: nil)
        self.hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func createDefaultConfig() -> ReadConfig {
        var config = ReadConfig()
        config.textSize = 18
        config.bgColor = 0xFFEEEEEE
        config.textColor = 0xFF333333
        config.lineSpacing = 1.5
        config.paragraphSpacing = 1.8
        config.pageMode = 0
        return config
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 彻底清空当前导航项与按钮，防止外层 BarButtonItem 在阅读界面残留
        navigationItem.title = ""
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: UIView())
        navigationItem.rightBarButtonItems = []
        navigationItem.hidesBackButton = true
        extendedLayoutIncludesOpaqueBars = true
        
        // 1. 更新本地书籍对象的时间戳（13位毫秒级时间戳，这是该后端的标准）
        let currentTime = Int64(Date().timeIntervalSince1970 * 1000)
        book.durChapterTime = currentTime

        // 保留临时加入书架的书籍（不删除），以便后续获取正文
        wasAutoAddedToShelf = false
        
        // 初始化漫画阅读器
        setupComicCollectionView()
        
        // 1. 先盖房子（初始化UI和约束）
        setupUI()
        setupGestures()
        setupEngine()
        registerBookmarkJumpObserver()
        registerReplaceRulesObserver()
        
        // 2. 再进家具（读取本地配置并加载书籍）
        loadBookSource()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let targetHeight = max(72, view.safeAreaInsets.top + 52)
        headerHeightConstraint?.update(offset: targetHeight)
    }
    
    private func setupComicCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        
        comicCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        comicCollectionView.backgroundColor = .clear
        comicCollectionView.delegate = self
        comicCollectionView.dataSource = self
        comicCollectionView.prefetchDataSource = self
        comicCollectionView.isPrefetchingEnabled = comicPrefetchEnabled
        comicCollectionView.register(ComicImageCell.self, forCellWithReuseIdentifier: ComicImageCell.identifier)
        comicCollectionView.isHidden = true
        comicCollectionView.showsVerticalScrollIndicator = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: UIView())
        navigationItem.rightBarButtonItems = []
        navigationController?.setNavigationBarHidden(true, animated: false)
        refreshStatusBarAppearance()
        registerChaptersObserver()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshStatusBarAppearance()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        engine.saveProgress()
        let isLeavingReader = isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true
        guard isLeavingReader else { return }

        stopTTS()
        cancelComicPrefetchTasks()
        preheatedChapterIndexes.removeAll()
        chaptersObserver.map { NotificationCenter.default.removeObserver($0) }
        chaptersObserver = nil
    }

    deinit {
        chaptersObserver.map { NotificationCenter.default.removeObserver($0) }
        bookmarkJumpObserver.map { NotificationCenter.default.removeObserver($0) }
        replaceRulesObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    private func setupUI() {
        view.backgroundColor = UIColor(hex: currentConfig.bgColor)
        navigationController?.setNavigationBarHidden(true, animated: false)
        
        view.addSubview(textView)
        view.addSubview(pageView)
        view.addSubview(comicCollectionView)
        pageView.addSubview(pageContentView)
        view.addSubview(headerView)
        view.addSubview(footerView)
        
        textView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.bottom.equalToSuperview()
        }
        
        pageView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.bottom.equalToSuperview()
        }
        
        comicCollectionView.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.trailing.bottom.equalToSuperview()
        }
        
        pageContentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.height.equalTo(pageView)
        }
        
        headerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            headerHeightConstraint = make.height.equalTo(124).constraint
        }
        
        footerView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalToSuperview()
            make.height.equalTo(50)
        }
        
        view.addSubview(addToShelfButton)
        addToShelfButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-70)
            make.size.equalTo(44)
        }

        view.addSubview(themeFloatingButton)
        themeFloatingButton.snp.makeConstraints { make in
            make.trailing.equalTo(addToShelfButton)
            make.bottom.equalTo(addToShelfButton.snp.top).offset(-12)
            make.size.equalTo(44)
        }

        view.addSubview(ttsButton)
        ttsButton.snp.makeConstraints { make in
            make.trailing.equalTo(themeFloatingButton)
            make.bottom.equalTo(themeFloatingButton.snp.top).offset(-12)
            make.size.equalTo(44)
        }
        // 加载动画
        view.addSubview(loadingIndicator)
        loadingIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        headerView.alpha = 0
        headerView.isHidden = true
        footerView.alpha = 0
        footerView.isHidden = true
        addToShelfButton.alpha = 0
        themeFloatingButton.alpha = 0
        ttsButton.alpha = 0
        
        applyTheme()

        if #available(iOS 11.0, *) {
            textView.contentInsetAdjustmentBehavior = .automatic
            pageView.contentInsetAdjustmentBehavior = .automatic
            comicCollectionView.contentInsetAdjustmentBehavior = .never
        }
    }

    private func setupEngine() {
        engine.onContentLoaded = { [weak self] content in
            DispatchQueue.main.async {
                self?.updateHeaderTitle(preferred: content.title)
                self?.updateUrlLabel()
                self?.displayContent(content)
                self?.applyPendingBookmarkHighlightIfNeeded()
            }
        }

        engine.onChapterChanged = { [weak self] index, title in
            DispatchQueue.main.async {
                self?.updateHeaderTitle(preferred: title)
                self?.updateProgress()
                self?.updateUrlLabel()
                self?.lastHighlightedPageIndex = -1
                self?.lastTTSParagraphIndex = self?.restoreTTSParagraphProgress(for: index) ?? 0
                TTSService.shared.currentParagraphIndex = self?.lastTTSParagraphIndex ?? 0
            }
        }
        
        engine.onLoadFailed = { [weak self] errorMessage in
            DispatchQueue.main.async {
                self?.loadingIndicator.stopAnimating()
                self?.showErrorInContent(errorMessage)
            }
        }
        
        // 监听章节加载完成，支持多次换源/重载时重复触发。
        registerChaptersObserver(removeExisting: true)
    }

    private func registerChaptersObserver(removeExisting: Bool = false) {
        if removeExisting, let observer = chaptersObserver {
            NotificationCenter.default.removeObserver(observer)
            chaptersObserver = nil
        }
        if chaptersObserver != nil {
            return
        }

        chaptersObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ChaptersLoaded"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let loadedBookUrl = notification.userInfo?["bookUrl"] as? String {
                let currentBookUrl = (self.engine.book?.bookUrl ?? self.book.bookUrl)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentBookUrl.isEmpty,
                   loadedBookUrl.trimmingCharacters(in: .whitespacesAndNewlines) != currentBookUrl {
                    return
                }
            }
            guard !self.engine.chapters.isEmpty else { return }
            let safeIndex = min(max(self.engine.currentChapterIndex, 0), self.engine.chapters.count - 1)
            self.engine.goToChapter(safeIndex)
        }
    }

    private func registerBookmarkJumpObserver() {
        bookmarkJumpObserver.map { NotificationCenter.default.removeObserver($0) }
        bookmarkJumpObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("JumpToBookmark"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let bookmark = notification.userInfo?["bookmark"] as? Bookmark else { return }
            self.handleJumpToBookmark(bookmark)
        }
    }
    
    private func registerReplaceRulesObserver() {
        replaceRulesObserver.map { NotificationCenter.default.removeObserver($0) }
        replaceRulesObserver = NotificationCenter.default.addObserver(
            forName: .replaceRulesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.reapplyContentCleanerToLoadedContent()
            self.showToast(" 已应用最新净化规则 ")
        }
    }

    private func handleJumpToBookmark(_ bookmark: Bookmark) {
        let currentName = normalizedBookIdentityText(resolvedCurrentBookName())
        let bookmarkName = normalizedBookIdentityText(bookmark.bookName)
        if !currentName.isEmpty, !bookmarkName.isEmpty, currentName != bookmarkName {
            return
        }

        if !book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let currentAuthor = normalizedBookIdentityText(book.author)
            let bookmarkAuthor = normalizedBookIdentityText(bookmark.bookAuthor)
            if !currentAuthor.isEmpty, !bookmarkAuthor.isEmpty, currentAuthor != bookmarkAuthor {
                return
            }
        }

        guard !engine.chapters.isEmpty else {
            showAlert("跳转失败", "当前目录尚未加载完成")
            return
        }

        let targetIndex = min(max(bookmark.chapterIndex, 0), engine.chapters.count - 1)
        let highlightText = bookmark.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? bookmark.bookText
            : bookmark.content
        let trimmedHighlight = highlightText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBookmarkHighlightText = trimmedHighlight.isEmpty ? nil : String(trimmedHighlight.prefix(120))

        if targetIndex == engine.currentChapterIndex {
            applyPendingBookmarkHighlightIfNeeded()
        } else {
            loadingIndicator.startAnimating()
            engine.goToChapter(targetIndex)
        }

        showToast(" 已跳转到书签章节 ")
    }

    private func applyPendingBookmarkHighlightIfNeeded() {
        guard let highlight = pendingBookmarkHighlightText,
              !highlight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              engine.currentContent != nil else {
            return
        }
        highlightParagraph(at: 0, text: highlight)
        pendingBookmarkHighlightText = nil
    }

    private func resolvedCurrentBookName() -> String {
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let engineName = (engine.book?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return engineName.isEmpty ? "未知书籍" : engineName
    }

    private func normalizedBookIdentityText(_ raw: String) -> String {
        raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ttsProgressBookIdentifier() -> String {
        let bookUrl = normalizedBookIdentityText(book.bookUrl)
        if !bookUrl.isEmpty {
            return bookUrl
        }
        let name = normalizedBookIdentityText(book.name)
        let author = normalizedBookIdentityText(book.author)
        return "\(name)#\(author)"
    }

    private func ttsParagraphProgressStorageKey(chapterIndex: Int) -> String {
        "\(ttsParagraphProgressKeyPrefix)|\(ttsProgressBookIdentifier())|\(chapterIndex)"
    }

    private func persistTTSParagraphProgress(_ paragraphIndex: Int, for chapterIndex: Int?) {
        let chapter = chapterIndex ?? engine.currentChapterIndex
        guard chapter >= 0 else { return }
        UserDefaults.standard.set(max(0, paragraphIndex), forKey: ttsParagraphProgressStorageKey(chapterIndex: chapter))
    }

    private func restoreTTSParagraphProgress(for chapterIndex: Int?) -> Int {
        let chapter = chapterIndex ?? engine.currentChapterIndex
        guard chapter >= 0 else { return 0 }
        let key = ttsParagraphProgressStorageKey(chapterIndex: chapter)
        guard UserDefaults.standard.object(forKey: key) != nil else { return 0 }
        return max(0, UserDefaults.standard.integer(forKey: key))
    }

    private var lastContentOffsetX: CGFloat = 0
    
    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        textView.addGestureRecognizer(tap)
        
        let pageTap = UITapGestureRecognizer(target: self, action: #selector(handlePageTap(_:)))
        pageView.addGestureRecognizer(pageTap)
        
        let comicTap = UITapGestureRecognizer(target: self, action: #selector(handleComicTap(_:)))
        comicTap.cancelsTouchesInView = false
        comicCollectionView.addGestureRecognizer(comicTap)

        let comicSwipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleComicSwipe(_:)))
        comicSwipeLeft.direction = .left
        comicSwipeLeft.cancelsTouchesInView = false
        comicCollectionView.addGestureRecognizer(comicSwipeLeft)

        let comicSwipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleComicSwipe(_:)))
        comicSwipeRight.direction = .right
        comicSwipeRight.cancelsTouchesInView = false
        comicCollectionView.addGestureRecognizer(comicSwipeRight)
    }

    private func loadBookSource() {
        preheatedChapterIndexes.removeAll()
        applyGlobalReadConfigToCurrentBookConfig()

        if book.origin != Book.localTag {
            let sources = DatabaseManager.shared.getAllBookSources()
            bookSource = sources.first { $0.bookSourceUrl == book.origin }
        }
        
        if book.readConfig == nil {
            book.readConfig = createDefaultConfig()
        }
        updateHeaderTitle(preferred: book.name)
        applyTheme()
        // 【新增】显示动画
        loadingIndicator.startAnimating()
        
        // 先加载章节列表
        registerChaptersObserver()
        engine.openBook(book, source: bookSource)
    }

    private func applyGlobalReadConfigToCurrentBookConfig() {
        if let data = UserDefaults.standard.data(forKey: "globalReadConfig"),
           let globalConfig = try? JSONDecoder().decode(ReadConfig.self, from: data) {
            // 全局配置强制覆盖：所有小说（含发现页临时阅读）统一同一套阅读设置。
            book.readConfig = globalConfig
            return
        }

        let fallback = book.readConfig ?? createDefaultConfig()
        book.readConfig = fallback
        if let data = try? JSONEncoder().encode(fallback) {
            UserDefaults.standard.set(data, forKey: "globalReadConfig")
        }
    }

    private func displayContent(_ content: ChapterContent) {
        let imageCount = content.imageUrls?.count ?? 0
        log("[ReaderViewController] displayContent textLength=\(content.content.count) imageCount=\(imageCount) isComic=\(content.isComic)")

        // 清除之前的朗读高亮
        clearParagraphHighlight()
        lastHighlightedPageIndex = -1
        
        // 检查是否是漫画模式
        if content.isComic {
            displayComicContent(content)
            return
        }
        
        ttsButton.isHidden = false
        comicCollectionView.isHidden = true
        comicImageUrls.removeAll()
        comicImageHeightCache.removeAll()
        comicImageReferer = nil
        cancelComicPrefetchTasks()
        
        // 原有文字内容处理逻辑
        let chapterTitle = engine.chapters[safe: engine.currentChapterIndex]?.title ?? "正文"
        
        // 拼接标题，并在后面加两个换行符
        var text = chapterTitle + "\n\n" + content.content

        // var text = content.content
        
        let config = currentConfig
        
        if config.convertSimpToTrad {
            text = converter.toTraditional(text)
        } else if config.convertTradToSimp {
            text = converter.toSimplified(text)
        }
        
        let formattedText = formatContent(text)
        
        if isPagingMode {
            setupPagingMode(text: formattedText)
        } else {
            setupScrollMode(text: formattedText)
        }
        
        let idx = engine.currentChapterIndex
        let total = engine.chapters.count
        footerChapterLabel?.text = "\(idx + 1) / \(total)"
        triggerChapterPreheat(isComic: false)
        refreshStatusBarAppearance()
    }
    
    private func ensureParagraphRanges() {
        let currentText = textView.text ?? ""
        if currentText.isEmpty || paragraphRanges.count == 0 {
            // 重新构建段落范围
            let fs = CGFloat(currentConfig.textSize > 0 ? currentConfig.textSize : 18)
            let tc = textColor
            
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = CGFloat(currentConfig.lineSpacing - 1) * fs * 0.5
            ps.paragraphSpacing = CGFloat(currentConfig.paragraphSpacing - 1) * fs
            ps.firstLineHeadIndent = fs
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fs),
                .foregroundColor: tc,
                .paragraphStyle: ps
            ]
            
            buildParagraphRanges(from: currentText, with: attrs)
        }
    }
    
    private func displayComicContent(_ content: ChapterContent) {
        guard let imageUrls = content.imageUrls, !imageUrls.isEmpty else {
            var emptyContent = ChapterContent()
            emptyContent.url = content.url
            emptyContent.title = content.title
            emptyContent.content = "无法加载漫画内容"
            displayContent(emptyContent)
            return
        }
        
        ttsButton.isHidden = true
        cancelComicPrefetchTasks()
        comicLayoutInvalidationWorkItem?.cancel()
        comicLayoutInvalidationWorkItem = nil
        comicImageHeightCache.removeAll()
        comicImageUrls = normalizedComicImageUrls(imageUrls)
        guard !comicImageUrls.isEmpty else {
            var emptyContent = ChapterContent()
            emptyContent.url = content.url
            emptyContent.title = content.title
            emptyContent.content = "漫画图片地址无效，无法加载"
            displayContent(emptyContent)
            return
        }
        recordDetectedComicSourceIfNeeded(content: content, resolvedImageCount: comicImageUrls.count)
        comicImageReferer = currentComicReferer(for: content)

        textView.isHidden = true
        pageView.isHidden = true
        comicCollectionView.isHidden = false
        view.layoutIfNeeded()
        let firstResolvedURL = comicImageUrls.first.map { ComicImageCell.resolveImageURLString($0) } ?? "<none>"
        log("[ReaderViewController] comicView frame=\(comicCollectionView.frame) firstUrl=\(firstResolvedURL)")
        comicCollectionView.setContentOffset(.zero, animated: false)
        comicCollectionView.collectionViewLayout.invalidateLayout()
        comicCollectionView.reloadData()
        if comicPrefetchEnabled {
            prefetchComicImages(around: 0)
        }
        
        let idx = engine.currentChapterIndex
        let total = engine.chapters.count
        footerChapterLabel?.text = "\(idx + 1) / \(total)"
        triggerChapterPreheat(isComic: true)
        loadingIndicator.stopAnimating()
        refreshStatusBarAppearance()
    }

    private func normalizedComicImageUrls(_ urls: [String]) -> [String] {
        var result: [String] = []
        var seenResolved: Set<String> = []
        for raw in urls {
            let rawClean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawClean.isEmpty else { continue }
            let resolved = ComicImageCell.resolveImageURLString(rawClean)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else { continue }
            if seenResolved.insert(resolved).inserted {
                // 保留原始字符串，便于 Cell 解析 `url,{"headers":...}` 的兼容格式。
                result.append(rawClean)
            }
        }
        return result
    }

    private func currentComicReferer(for content: ChapterContent) -> String? {
        if let chapterUrl = engine.chapters[safe: engine.currentChapterIndex]?.url,
           !chapterUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return chapterUrl
        }
        if !content.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content.url
        }
        if !book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return book.bookUrl
        }
        return nil
    }

    private func currentSourceURLsForComicDetection() -> [String] {
        let candidates = [
            book.origin,
            engine.book?.origin ?? "",
            bookSource?.bookSourceUrl ?? ""
        ]
        var output: [String] = []
        var seen: Set<String> = []
        for value in candidates {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            guard key != Book.localTag.lowercased() else { continue }
            guard seen.insert(key).inserted else { continue }
            output.append(normalized)
        }
        return output
    }

    private func recordDetectedComicSourceIfNeeded(content: ChapterContent, resolvedImageCount: Int) {
        guard resolvedImageCount > 0 else { return }
        let text = content.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // 仅在“章节主体明显以图片为主”时记录，避免误把普通图文章节打成漫画源。
        let isImageDominant = resolvedImageCount >= 2 || text.isEmpty
        guard isImageDominant else { return }

        let delta = resolvedImageCount >= 3 ? 2 : 1
        for sourceUrl in currentSourceURLsForComicDetection() {
            Self.recordDetectedComicSource(sourceUrl: sourceUrl, delta: delta)
        }
    }

    private func cancelComicPrefetchTasks() {
        for (_, task) in comicPrefetchTasks {
            task.cancel()
        }
        comicPrefetchTasks.removeAll()
    }

    private func prefetchComicImages(around index: Int, windowSize: Int? = nil) {
        guard comicPrefetchEnabled else { return }
        guard !comicImageUrls.isEmpty else { return }
        let resolvedWindow = max(windowSize ?? comicPrefetchWindowSize, 1)
        let start = max(0, index)
        let end = min(comicImageUrls.count, start + resolvedWindow)
        guard start < end else { return }

        for i in start..<end {
            if comicPrefetchTasks.count >= maxComicPrefetchTaskCount {
                break
            }
            let rawURLString = comicImageUrls[i]
            let request = ComicImageCell.resolvedRequest(from: rawURLString, fallbackReferer: comicImageReferer)
            let cacheKey = request.urlString
            if comicPrefetchTasks[cacheKey] != nil { continue }
            let cacheType = ImageCache.default.imageCachedType(forKey: cacheKey)
            if cacheType != .none { continue }
            guard let url = URL(string: request.urlString) else { continue }

            var options: KingfisherOptionsInfo = [
                .backgroundDecode,
                .cacheOriginalImage,
                .downloader(ComicImageCell.downloader()),
                .requestModifier(ComicImageCell.requestModifier(for: request.referer))
            ]
            let task = KingfisherManager.shared.retrieveImage(
                with: url,
                options: options
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.comicPrefetchTasks[cacheKey] = nil
                }
            }
            if let task {
                comicPrefetchTasks[cacheKey] = task
            }
        }
    }

    private func cancelPrefetchComicImages(for indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard indexPath.item >= 0, indexPath.item < comicImageUrls.count else { continue }
            let rawURLString = comicImageUrls[indexPath.item]
            let request = ComicImageCell.resolvedRequest(from: rawURLString, fallbackReferer: comicImageReferer)
            let cacheKey = request.urlString
            comicPrefetchTasks[cacheKey]?.cancel()
            comicPrefetchTasks[cacheKey] = nil
        }
    }

    private func scheduleComicLayoutInvalidation() {
        guard comicLayoutInvalidationWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.comicCollectionView.collectionViewLayout.invalidateLayout()
            self?.comicLayoutInvalidationWorkItem = nil
        }
        comicLayoutInvalidationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func triggerChapterPreheat(isComic: Bool) {
        let currentIndex = engine.currentChapterIndex
        guard currentIndex >= 0 else { return }

        let forwardCount = isComic ? 3 : 2
        let backwardCount = 1

        for offset in 1...forwardCount {
            let target = currentIndex + offset
            guard target < engine.chapters.count else { continue }
            if preheatedChapterIndexes.contains(target) { continue }
            preheatedChapterIndexes.insert(target)
            engine.preloadChapter(index: target)
        }

        for offset in 1...backwardCount {
            let target = currentIndex - offset
            guard target >= 0 else { continue }
            if preheatedChapterIndexes.contains(target) { continue }
            preheatedChapterIndexes.insert(target)
            engine.preloadChapter(index: target)
        }

        // 保持集合规模稳定，避免长时间阅读导致集合无限增长
        preheatedChapterIndexes = preheatedChapterIndexes.filter {
            $0 >= currentIndex - 3 && $0 <= currentIndex + 8
        }
    }
    
    private func setupScrollMode(text: String) {
        textView.isHidden = false
        pageView.isHidden = true
        textView.bounces = false
        
        let config = currentConfig
        let fs = CGFloat(config.textSize > 0 ? config.textSize : 18)
        let tc = UIColor(hex: config.textColor)
        textColor = tc
        
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = CGFloat(config.lineSpacing - 1) * fs * 0.5
        ps.paragraphSpacing = CGFloat(config.paragraphSpacing - 1) * fs
        ps.firstLineHeadIndent = fs
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fs),
            .foregroundColor: tc,
            .paragraphStyle: ps
        ]

        scrollRenderTaskId += 1
        let taskId = scrollRenderTaskId
        scrollRenderQueue.async { [weak self] in
            guard let self else { return }
            let result = self.buildScrollResult(text: text, attrs: attrs)
            DispatchQueue.main.async {
                guard self.scrollRenderTaskId == taskId else { return }
                self.textView.attributedText = result.attributedText
                self.paragraphRanges = result.paragraphRanges
                self.textView.setContentOffset(.zero, animated: false)
                self.loadingIndicator.stopAnimating()
            }
        }
    }

    private func buildScrollResult(text: String, attrs: [NSAttributedString.Key: Any]) -> ScrollBuildResult {
        let attributedText = NSAttributedString(string: text, attributes: attrs)
        let ranges = paragraphRangesForText(text)
        return ScrollBuildResult(attributedText: attributedText, paragraphRanges: ranges)
    }
    
    private func setupPagingMode(text: String) {
        textView.isHidden = true
        pageView.isHidden = true

        pageContentView.subviews.forEach { $0.removeFromSuperview() }
        pageLabels.removeAll()
        paragraphToPageMap.removeAll()

        let pageWidth = pageView.bounds.width
        let pageHeight = pageView.bounds.height
        guard pageWidth > 0, pageHeight > 0 else {
            loadingIndicator.stopAnimating()
            return
        }

        let config = currentConfig
        let fs = CGFloat(config.textSize > 0 ? config.textSize : 18)
        let tc = UIColor(hex: config.textColor)
        let lineSpacing = CGFloat(config.lineSpacing - 1) * fs * 0.5
        let paragraphSpacing = CGFloat(config.paragraphSpacing - 1) * fs
        let isBold = config.bold

        pagingRenderTaskId += 1
        let taskId = pagingRenderTaskId

        pagingRenderQueue.async { [weak self] in
            guard let self else { return }
            let buildResult = self.buildPagingResult(
                text: text,
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                fontSize: fs,
                textColor: tc,
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                bold: isBold
            )

            DispatchQueue.main.async {
                guard self.pagingRenderTaskId == taskId else { return }
                self.applyPagingBuildResult(buildResult)
                self.loadingIndicator.stopAnimating()
            }
        }
    }

    private func buildPagingResult(
        text: String,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        fontSize: CGFloat,
        textColor: UIColor,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        bold: Bool
    ) -> PagingBuildResult {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = paragraphSpacing

        let fullAttrText = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular),
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ])

        if let firstLineEnd = text.firstIndex(of: "\n") {
            let titleRange = NSRange(text.startIndex..<firstLineEnd, in: text)
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.alignment = .center
            titleStyle.paragraphSpacing = fontSize * 2
            fullAttrText.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: fontSize + 6), range: titleRange)
            fullAttrText.addAttribute(.paragraphStyle, value: titleStyle, range: titleRange)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(fullAttrText as CFAttributedString)
        let renderRect = CGRect(x: 16, y: 16, width: pageWidth - 32, height: pageHeight - 32)
        let nsText = text as NSString

        var pageOffset = 0
        var pageCount = 0
        var paragraphIndex = 0
        var pageRanges: [NSRange] = []
        var paragraphMap: [Int: Int] = [:]

        while pageOffset < fullAttrText.length {
            let path = CGPath(rect: renderRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(pageOffset, 0), path, nil)
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            if visibleRange.length <= 0 { break }

            let nsRange = NSRange(location: pageOffset, length: visibleRange.length)
            pageRanges.append(nsRange)

            let pageText = nsText.substring(with: nsRange)
            let lines = pageText.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && paragraphIndex > 0 {
                    paragraphMap[paragraphIndex] = pageCount
                }
                paragraphIndex += 1
            }

            pageOffset += visibleRange.length
            pageCount += 1
        }

        return PagingBuildResult(
            attributedText: fullAttrText,
            pageRanges: pageRanges,
            paragraphMap: paragraphMap,
            pageWidth: pageWidth,
            pageHeight: pageHeight
        )
    }

    private func applyPagingBuildResult(_ result: PagingBuildResult) {
        pageContentView.subviews.forEach { $0.removeFromSuperview() }
        pageLabels.removeAll()
        paragraphToPageMap = result.paragraphMap

        let renderRect = CGRect(x: 16, y: 16, width: result.pageWidth - 32, height: result.pageHeight - 32)
        let ranges: [NSRange]
        if result.pageRanges.isEmpty, result.attributedText.length > 0 {
            ranges = [NSRange(location: 0, length: result.attributedText.length)]
        } else {
            ranges = result.pageRanges
        }

        for (pageIndex, range) in ranges.enumerated() {
            let pageContainer = UIView(frame: CGRect(
                x: CGFloat(pageIndex) * result.pageWidth,
                y: 0,
                width: result.pageWidth,
                height: result.pageHeight
            ))
            let label = UILabel(frame: renderRect)
            label.numberOfLines = 0
            label.attributedText = result.attributedText.attributedSubstring(from: range)
            pageContainer.addSubview(label)
            pageContentView.addSubview(pageContainer)
            pageLabels.append(label)
        }

        let finalContentWidth = result.pageWidth * CGFloat(max(1, ranges.count))
        pageView.contentSize = CGSize(width: finalContentWidth, height: result.pageHeight)

        if shouldJumpToLastPage {
            shouldJumpToLastPage = false
            let lastPageX = max(0, finalContentWidth - result.pageWidth)
            pageView.contentOffset = CGPoint(x: lastPageX, y: 0)
        } else {
            pageView.contentOffset = .zero
            shouldJumpToFirstPage = false
        }

        pageContentView.snp.remakeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(finalContentWidth)
            make.height.equalTo(result.pageHeight)
        }

        pageView.isHidden = false
        applyChapterSwitchTransitionIfNeeded()
        log("[ReaderViewController] setupPagingMode: \(pageLabels.count) pages, \(paragraphToPageMap.count) paragraphs mapped")
    }

    private func applyChapterSwitchTransitionIfNeeded() {
        guard let direction = pendingChapterSwitchDirection else { return }
        pendingChapterSwitchDirection = nil
        applyPageTurnTransition(direction: direction, phase: .chapterSwitch)
    }

    private func applyPageTurnTransition(direction: ChapterSwitchDirection, phase: PageTurnPhase) {
        let transition = CATransition()
        switch currentPageMode {
        case PageMode.cover.rawValue:
            transition.type = .moveIn
        case PageMode.simulate.rawValue:
            transition.type = .reveal
        default:
            transition.type = .push
        }
        transition.subtype = direction == .next ? .fromRight : .fromLeft
        transition.duration = pageTurnDuration(phase: phase)
        transition.timingFunction = pageTurnTimingFunction()
        let key = phase == .chapterSwitch ? "chapter-switch-transition" : "in-chapter-turn-transition"
        pageView.layer.add(transition, forKey: key)
    }

    private func pageTurnDuration(phase: PageTurnPhase) -> CFTimeInterval {
        let speedMs = max(120, min(900, currentConfig.turnSpeed))
        let base = Double(speedMs) / 1000.0

        let modeFactor: Double
        switch currentPageMode {
        case PageMode.cover.rawValue:
            modeFactor = 0.95
        case PageMode.simulate.rawValue:
            modeFactor = 1.10
        default:
            modeFactor = 0.85
        }

        let phaseFactor: Double = (phase == .chapterSwitch) ? 1.0 : 0.85
        return max(0.12, min(0.75, base * modeFactor * phaseFactor))
    }

    private func pageTurnTimingFunction() -> CAMediaTimingFunction {
        switch currentPageMode {
        case PageMode.cover.rawValue:
            return CAMediaTimingFunction(name: .linear)
        case PageMode.simulate.rawValue:
            return CAMediaTimingFunction(name: .easeInEaseOut)
        default:
            return CAMediaTimingFunction(name: .easeOut)
        }
    }

    private func formatContent(_ content: String) -> String {
        let result = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paras = result.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return paras.joined(separator: "\n")
    }
    
    private func buildParagraphRanges(from text: String, with attrs: [NSAttributedString.Key: Any]) {
        let attributedString = NSMutableAttributedString(string: text, attributes: attrs)
        textView.attributedText = attributedString
        paragraphRanges = paragraphRangesForText(text)
    }

    private func paragraphRangesForText(_ text: String) -> [NSRange] {
        var result: [NSRange] = []
        var currentLocation = 0
        let lines = text.components(separatedBy: "\n")
        var isFirst = true

        for line in lines {
            let lineLength = (line as NSString).length
            if isFirst {
                isFirst = false
                currentLocation += lineLength + 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let trimmedLength = (trimmed as NSString).length
                result.append(NSRange(location: currentLocation, length: trimmedLength))
            }
            currentLocation += lineLength + 1
        }
        return result
    }

    private func applyTheme() {
        let config = currentConfig
        let bg = UIColor(hex: config.bgColor)
        let tc = UIColor(hex: config.textColor)
        textColor = tc
        // 重点：强制让整个 View 和 TextView 变色
        self.view.backgroundColor = bg
        self.textView.backgroundColor = bg
        currentTheme = 0
        
        
        let fs = CGFloat(config.textSize > 0 ? config.textSize : 18)
        
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = CGFloat(config.lineSpacing - 1) * fs * 0.5
        ps.paragraphSpacing = CGFloat(config.paragraphSpacing - 1) * fs
        ps.firstLineHeadIndent = fs
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fs),
            .foregroundColor: tc,
            .paragraphStyle: ps
        ]
        
        textView.font = UIFont.systemFont(ofSize: fs)
        textView.textColor = tc
        textView.typingAttributes = attrs
        
        let currentText = textView.text ?? ""
        if !currentText.isEmpty {
            let attrText = NSMutableAttributedString(string: currentText, attributes: attrs)
            textView.attributedText = attrText
        }
        
        pageView.backgroundColor = bg
        pageContentView.backgroundColor = bg
        comicCollectionView.backgroundColor = bg
        
        headerView.subviews.compactMap { $0 as? UIButton }.forEach { $0.tintColor = tc }
        footerView.subviews.compactMap { $0 as? UIButton }.forEach { $0.tintColor = tc }
        sourceButton?.layer.borderColor = tc.withAlphaComponent(0.25).cgColor
        moreButton?.layer.borderColor = tc.withAlphaComponent(0.25).cgColor
        headerTitleLabel?.textColor = tc
        footerChapterLabel?.textColor = tc.withAlphaComponent(0.7)
        themeFloatingButton.backgroundColor = UIColor.systemPurple.withAlphaComponent(currentTheme == 1 ? 0.72 : 0.88)
        
        refreshStatusBarAppearance()
    }
    
    @objc private func toggleTheme() {
        let themeVC = ThemePickerViewController()
        themeVC.selectedBgColor = currentConfig.bgColor
        themeVC.onThemeSelected = { [weak self] (bgColor: Int, textColor: Int) in
            guard let self = self else { return }
            var newConfig = self.currentConfig
            newConfig.bgColor = bgColor
            newConfig.textColor = textColor
            self.engine.updateReadConfig(newConfig)
            self.applyTheme()
            
            if let content = self.engine.currentContent {
                self.displayContent(content)
            }
        }
        
        themeVC.modalPresentationStyle = .pageSheet
        if let sheet = themeVC.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(themeVC, animated: true)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !isPagingMode else { return }
        
        let x = gesture.location(in: view).x
        let w = view.bounds.width
        
        if isMenuVisible {
            if gesture.location(in: view).y < headerView.frame.maxY || gesture.location(in: view).y > footerView.frame.minY { 
                return 
            }
        }

        if x < w / 3 {
            handleScrollModeTapTurn(next: false)
        } else if x > w * 2 / 3 {
            handleScrollModeTapTurn(next: true)
        } else {
            toggleMenu()
        }
    }
    
    @objc private func handlePageTap(_ gesture: UITapGestureRecognizer) {
        guard isPagingMode else { return }
        
        let pointInView = gesture.location(in: self.view)
        let w = self.view.bounds.width
        let h = self.view.bounds.height
        
        let headerH = headerView.frame.height
        let footerH = footerView.frame.height
        
        if isMenuVisible {
            if pointInView.y < headerH || pointInView.y > h - footerH {
                return
            }
            toggleMenu()
            return
        }
        
        if pointInView.x <= w / 3 {
            turnPageInPagingMode(next: false, fromTap: true)
        } else if pointInView.x >= w * 2 / 3 {
            turnPageInPagingMode(next: true, fromTap: true)
        } else {
            toggleMenu()
        }
    }

    private func handleScrollModeTapTurn(next: Bool) {
        guard !textView.isHidden else {
            if next {
                nextChapterTapped()
            } else {
                prevChapterTapped()
            }
            return
        }

        let inset = textView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, textView.contentSize.height - textView.bounds.height + inset.bottom)
        let currentY = textView.contentOffset.y
        let visibleHeight = max(40, textView.bounds.height - inset.top - inset.bottom)
        let step = scrollModeTapStep(next: next, visibleHeight: visibleHeight)
        let targetY = next ? min(maxY, currentY + step) : max(minY, currentY - step)

        if abs(targetY - currentY) < 1 {
            if next {
                nextChapterTapped()
            } else {
                prevChapterTapped()
            }
            return
        }

        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: targetY), animated: true)
    }

    private func scrollModeTapStep(next: Bool, visibleHeight: CGFloat) -> CGFloat {
        let fallback = max(80, visibleHeight * 0.88)
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        guard layoutManager.numberOfGlyphs > 0 else { return fallback }

        let insets = textView.textContainerInset
        let horizontalPadding = textContainer.lineFragmentPadding * 2
        let containerWidth = textView.bounds.width - insets.left - insets.right - horizontalPadding
        guard containerWidth > 0 else { return fallback }

        let contentY = max(0, textView.contentOffset.y - insets.top)
        let visibleRect = CGRect(
            x: max(0, textView.contentOffset.x - insets.left),
            y: contentY,
            width: containerWidth,
            height: visibleHeight
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard glyphRange.length > 0 else { return fallback }

        let glyphIndex: Int
        if next {
            glyphIndex = max(glyphRange.location, NSMaxRange(glyphRange) - 1)
        } else {
            glyphIndex = glyphRange.location
        }

        var lineRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
        let lineHeight = max(18, ceil(lineRect.height))
        return max(80, min(visibleHeight, visibleHeight - lineHeight))
    }

    private func turnPageInPagingMode(next: Bool, fromTap: Bool) {
        let width = pageView.bounds.width
        guard width > 0 else { return }

        let pageCount = max(1, Int(round(pageView.contentSize.width / width)))
        let currentIndex = max(0, min(pageCount - 1, Int(round(pageView.contentOffset.x / width))))
        let targetIndex = next ? (currentIndex + 1) : (currentIndex - 1)

        if targetIndex < 0 {
            prevChapterTapped()
            return
        }
        if targetIndex >= pageCount {
            nextChapterTapped()
            return
        }

        let targetOffset = CGPoint(x: CGFloat(targetIndex) * width, y: 0)
        if fromTap && currentPageMode != PageMode.slide.rawValue {
            let direction: ChapterSwitchDirection = next ? .next : .previous
            applyPageTurnTransition(direction: direction, phase: .inChapter)
            pageView.setContentOffset(targetOffset, animated: false)
        } else {
            pageView.setContentOffset(targetOffset, animated: true)
        }
    }
    
    @objc private func handleComicTap(_ gesture: UITapGestureRecognizer) {
        let pointInView = gesture.location(in: self.view)
        let w = self.view.bounds.width
        if pointInView.x > w / 3 && pointInView.x < w * 2 / 3 {
            toggleMenu()
        }
    }

    @objc private func handleComicSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard !comicCollectionView.isHidden else { return }
        guard !isMenuVisible else { return }

        switch gesture.direction {
        case .left:
            nextChapterTapped()
        case .right:
            prevChapterTapped()
        default:
            break
        }
    }
    
    private func toggleMenu() {
        isMenuVisible.toggle()
        
        if isMenuVisible {
            updateHeaderTitle()
            updateUrlLabel()
            headerView.isHidden = false
            footerView.isHidden = false
            headerView.transform = CGAffineTransform(translationX: 0, y: -60)
            footerView.transform = CGAffineTransform(translationX: 0, y: 60)
        }
        
        UIView.animate(withDuration: TimeInterval(0.2)) {
            self.headerView.alpha = self.isMenuVisible ? 1 : 0
            self.footerView.alpha = self.isMenuVisible ? 1 : 0
            self.addToShelfButton.alpha = self.isMenuVisible ? 1 : 0
            self.themeFloatingButton.alpha = self.isMenuVisible ? 1 : 0
            self.ttsButton.alpha = self.isMenuVisible ? 1 : 0
            self.headerView.transform = self.isMenuVisible ? .identity : CGAffineTransform(translationX: 0, y: -60)
            self.footerView.transform = self.isMenuVisible ? .identity : CGAffineTransform(translationX: 0, y: 60)
        } completion: { _ in
            if !self.isMenuVisible {
                self.headerView.isHidden = true
                self.footerView.isHidden = true
            }
        }
        
        refreshStatusBarAppearance()
    }

    @objc private func backTapped() {
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }
    
    @objc private func addToShelfTapped() {
        guard ReaderServerAPI.shared.isConfigured else {
            let alert = UIAlertController(title: "提示", message: "请先配置服务器", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            present(alert, animated: true)
            return
        }
        
        Task {
            do {
                let bookInfo = BookInfoResponse(
                    name: book.name,
                    author: book.author,
                    bookUrl: book.bookUrl,
                    sourceUrl: book.origin,
                    coverUrl: book.coverUrl,
                    intro: book.intro,
                    kind: book.kind,
                    latestChapter: nil,
                    tocUrl: book.tocUrl,
                    wordCount: nil,
                    chapterCount: nil,
                    type: book.type
                )
                try await ReaderServerAPI.shared.addToBookshelf(book: bookInfo)
                
                await MainActor.run {
                    self.addToShelfButton.isHidden = true
                    let alert = UIAlertController(title: "提示", message: "《\(book.name)》已加入书架", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(alert, animated: true)
                }
            } catch {
                await MainActor.run {
                    let alert = UIAlertController(title: "错误", message: "加入书架失败: \(error.localizedDescription)", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }
    
    @objc private func showChapterList() {
        let tocVC = ChapterListViewController(engine: engine)
        tocVC.modalPresentationStyle = .pageSheet
        if let sheet = tocVC.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(tocVC, animated: true)
    }
    
    @objc private func ttsTapped() {
        log("[ReaderViewController] ttsTapped: isTTSPanelHidden=\(isTTSPanelHidden), isPlaying=\(TTSService.shared.isPlaying), lastParagraph=\(lastTTSParagraphIndex)")
        
        // 如果TTS正在播放，打开面板继续
        if TTSService.shared.isPlaying {
            isTTSPanelHidden = false
            createTTSPanel()
            return
        }
        
        // TTS已停止（可能自然结束或被中断），从最后记录的段落继续
        lastTTSParagraphIndex = restoreTTSParagraphProgress(for: engine.currentChapterIndex)
        TTSService.shared.currentParagraphIndex = lastTTSParagraphIndex
        
        // 创建新面板开始朗读
        createTTSPanel()
    }
    
    private func createTTSPanel() {
        // 设置TTSService的回调，让ReaderViewController可以直接接收段落变化
        TTSService.shared.onParagraphChanged = { [weak self] index, text in
            self?.log("[ReaderViewController] onParagraphChanged called: index=\(index), text=\(text.prefix(20))")
            self?.lastTTSParagraphIndex = index  // 记录当前段落
            self?.persistTTSParagraphProgress(index, for: self?.engine.currentChapterIndex)
            DispatchQueue.main.async {
                self?.highlightParagraph(at: index, text: text)
            }
        }
        
        TTSService.shared.onPlaybackStopped = { [weak self] in
            self?.log("[ReaderViewController] onPlaybackStopped called")
            DispatchQueue.main.async {
                self?.clearParagraphHighlight()
                self?.ttsPanel = nil
                self?.isTTSPanelHidden = false
                self?.persistTTSParagraphProgress(self?.lastTTSParagraphIndex ?? 0, for: self?.engine.currentChapterIndex)
                self?.updateTTSButtonStyle(isPlaying: false)
            }
        }
        
        let panel = TTSPanelViewController(engine: engine, button: nil, isTTSPlaying: TTSService.shared.isPlaying, startParagraphIndex: lastTTSParagraphIndex)
        panel.onChapterChanged = { [weak self] in
            self?.log("[ReaderViewController] onChapterChanged called")
        }
        panel.onDismiss = { [weak self] in
            self?.log("[ReaderViewController] TTS panel dismissed, isPlaying: \(TTSService.shared.isPlaying)")
            // 面板被关闭时，如果TTS还在播放，标记为隐藏状态
            if TTSService.shared.isPlaying {
                self?.isTTSPanelHidden = true
                self?.updateTTSButtonStyle(isPlaying: true)
            } else {
                self?.isTTSPanelHidden = false
                self?.updateTTSButtonStyle(isPlaying: false)
            }
            self?.ttsPanel = nil
        }
        
        ttsPanel = panel
        present(panel, animated: true)
    }
    
    private func updateTTSButtonStyle(isPlaying: Bool) {
        if isPlaying {
            // TTS正在播放时，显示不同的样式（红色背景表示正在朗读）
            ttsButton.setImage(UIImage(systemName: "speaker.wave.3.fill"), for: .normal)
            ttsButton.backgroundColor = UIColor.systemRed
            // 确保按钮可见
            ttsButton.isHidden = false
            ttsButton.alpha = 1.0
        } else {
            // TTS停止时，恢复默认样式
            ttsButton.setImage(UIImage(systemName: "speaker.wave.2.fill"), for: .normal)
            ttsButton.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.8)
            // 恢复菜单显示状态
            if !isMenuVisible {
                ttsButton.alpha = 0
            }
        }
    }
    
    private func highlightParagraph(at index: Int, text: String) {
        log("[ReaderViewController] highlightParagraph: index=\(index), text=\(text.prefix(30)), isPagingMode=\(isPagingMode)")
        
        // 清除之前的高亮
        clearParagraphHighlight()
        
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if isPagingMode {
            // 分页模式 - 在当前页查找并高亮
            highlightInPagingMode(paragraphIndex: index, text: trimmedText)
        } else {
            // 滚动模式 - 使用textView
            highlightInScrollMode(text: trimmedText)
        }
    }
    
    private func highlightInScrollMode(text: String) {
        let currentText = textView.text ?? ""
        
        // 尝试精确匹配
        if let range = currentText.range(of: text) {
            let nsRange = NSRange(range, in: currentText)
            applyHighlightScrollMode(nsRange)
            return
        }
        
        // 尝试部分匹配
        let paragraphs = currentText.components(separatedBy: "\n")
        for para in paragraphs {
            let trimmedPara = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPara.isEmpty && text.contains(trimmedPara.prefix(30)) {
                if let range = currentText.range(of: para) {
                    let nsRange = NSRange(range, in: currentText)
                    applyHighlightScrollMode(nsRange)
                    return
                }
            }
        }
        
        log("[ReaderViewController] could not find text in scroll mode")
    }
    
    private func applyHighlightScrollMode(_ range: NSRange) {
        guard range.location + range.length <= (textView.text?.count ?? 0) else { return }
        
        let textStorage = textView.textStorage
        let attributedString = NSMutableAttributedString(attributedString: textStorage)
        attributedString.addAttribute(.foregroundColor, value: UIColor.red, range: range)
        textView.textStorage.setAttributedString(attributedString)
        
        // 滚动到该位置
        let rect = textView.layoutManager.boundingRect(forGlyphRange: range, in: textView.textContainer)
        let visibleRect = CGRect(x: 0, y: rect.origin.y - 50, width: textView.bounds.width, height: textView.bounds.height)
        textView.scrollRectToVisible(visibleRect, animated: true)
    }
    
    private var lastHighlightedPageIndex: Int = -1
    
    private func highlightInPagingMode(paragraphIndex: Int, text: String) {
        clearPagingModeHighlights()
        
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        var bestMatch: (pageIndex: Int, label: UILabel, nsRange: NSRange?)?
        
        for (pageIndex, label) in pageLabels.enumerated() {
            guard let labelText = label.text else { continue }
            let cleanLabelText = labelText.replacingOccurrences(of: " ", with: "")
            
            // 精确匹配
            if let range = labelText.range(of: trimmedText) {
                let nsRange = NSRange(range, in: labelText)
                bestMatch = (pageIndex, label, nsRange)
                break
            }
            
            // 模糊匹配 - 去除空格后比较
            if let range = cleanLabelText.range(of: trimmedText.replacingOccurrences(of: " ", with: "")) {
                let nsRange = NSRange(range, in: labelText)
                bestMatch = (pageIndex, label, nsRange)
                break
            }
        }
        
        // 如果没有找到匹配，使用 paragraphToPageMap
        if bestMatch == nil {
            if let mappedPage = paragraphToPageMap[paragraphIndex], mappedPage < pageLabels.count {
                let label = pageLabels[mappedPage]
                bestMatch = (mappedPage, label, nil)
            } else if paragraphIndex < pageLabels.count {
                // 使用段落索引作为页码（更稳定的备选方案）
                let label = pageLabels[paragraphIndex]
                bestMatch = (paragraphIndex, label, nil)
            }
        }
        
        if let match = bestMatch {
            // 如果目标页和当前页不同，才跳转
            let currentPage = Int(pageView.contentOffset.x / pageView.bounds.width)
            if match.pageIndex != currentPage || lastHighlightedPageIndex != match.pageIndex {
                lastHighlightedPageIndex = match.pageIndex
                highlightPage(match.pageIndex, label: match.label, nsRange: match.nsRange)
            } else {
                // 同一页，只更新高亮
                if let range = match.nsRange {
                    highlightPage(match.pageIndex, label: match.label, nsRange: range)
                }
            }
        } else {
            log("[ReaderViewController] could not find text in any page")
        }
    }
    
    private func highlightPage(_ pageIndex: Int, label: UILabel, nsRange: NSRange?) {
        if let range = nsRange {
            if let attrText = label.attributedText?.mutableCopy() as? NSMutableAttributedString {
                attrText.addAttribute(.foregroundColor, value: UIColor.red, range: range)
                label.attributedText = attrText
            }
        }
        
        // 滚动到该页
        let pageWidth = pageView.bounds.width
        pageView.setContentOffset(CGPoint(x: CGFloat(pageIndex) * pageWidth, y: 0), animated: true)
        log("[ReaderViewController] highlighted page \(pageIndex)")
    }
    
    private func clearParagraphHighlight() {
        if isPagingMode {
            // 分页模式 - 清除所有页面的高亮
            clearPagingModeHighlights()
        } else {
            // 滚动模式 - 清除textView的高亮
            let textStorage = textView.textStorage
            let attributedString = NSMutableAttributedString(attributedString: textStorage)
            let fullRange = NSRange(location: 0, length: attributedString.length)
            attributedString.addAttribute(.foregroundColor, value: textColor, range: fullRange)
            textView.textStorage.setAttributedString(attributedString)
        }
    }
    
    private func clearPagingModeHighlights() {
        let tc = textColor
        for label in pageLabels {
            if let attrText = label.attributedText?.mutableCopy() as? NSMutableAttributedString {
                let fullRange = NSRange(location: 0, length: attrText.length)
                attrText.addAttribute(.foregroundColor, value: tc, range: fullRange)
                label.attributedText = attrText
            }
        }
    }
    
    private func startTTS() {
        guard let content = engine.currentContent else { return }
        
        let text = content.content
        TTSService.shared.speak(text: text) { [weak self] success in
            if success {
                self?.isTTSPlaying = true
                self?.ttsButton.setImage(UIImage(systemName: "speaker.slash.fill"), for: .normal)
            } else {
                self?.showTTSError()
            }
        }
    }
    
    private func stopTTS() {
        persistTTSParagraphProgress(lastTTSParagraphIndex, for: engine.currentChapterIndex)
        TTSService.shared.stop()
        isTTSPlaying = false
        ttsButton.setImage(UIImage(systemName: "speaker.wave.2.fill"), for: .normal)
    }
    
    private func showTTSError() {
        let alert = UIAlertController(
            title: "朗读失败",
            message: "无法使用语音朗读",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    @objc private func moreTapped(_ sender: UIButton) {
        showMoreMenu(from: sender)
    }

    private func showMoreMenu(from sourceView: UIView?) {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "阅读设置", style: .default) { [weak self] _ in
            self?.settingsTapped()
        })
        alert.addAction(UIAlertAction(title: "添加书签", style: .default) { [weak self] _ in
            self?.addBookmarkTapped()
        })
        alert.addAction(UIAlertAction(title: "书签列表", style: .default) { [weak self] _ in
            self?.showBookmarkList()
        })
        alert.addAction(UIAlertAction(title: "净化测试", style: .default) { [weak self] _ in
            self?.runRuleTestFromReaderMenu()
        })
        alert.addAction(UIAlertAction(title: "打开原网页", style: .default) { [weak self] _ in
            self?.openSourceWebpage()
        })
        alert.addAction(UIAlertAction(title: "章节目录", style: .default) { [weak self] _ in
            self?.showChapterList()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView ?? moreButton ?? self.view
            popover.sourceRect = (sourceView ?? moreButton)?.bounds ?? CGRect(
                x: self.view.bounds.midX,
                y: self.view.bounds.maxY - 80,
                width: 1,
                height: 1
            )
        }
        present(alert, animated: true)
    }

    @objc private func addBookmarkTapped() {
        guard let chapter = engine.chapters[safe: engine.currentChapterIndex] else {
            showAlert("提示", "当前章节未加载完成")
            return
        }

        let excerpt = currentBookmarkExcerpt()
        let bookmark = Bookmark(
            bookName: resolvedCurrentBookName(),
            bookAuthor: book.author,
            chapterIndex: engine.currentChapterIndex,
            chapterName: chapter.title,
            bookText: excerpt,
            content: excerpt,
            createTime: Int64(Date().timeIntervalSince1970 * 1000)
        )

        Task {
            do {
                try await ReaderServerAPI.shared.saveBookmark(bookmark)
                await MainActor.run {
                    self.showToast(" 已添加书签 ")
                }
            } catch {
                await MainActor.run {
                    self.showAlert("添加失败", error.localizedDescription)
                }
            }
        }
    }

    @objc private func showBookmarkList() {
        let vc = BookmarkViewController()
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func runRuleTestFromReaderMenu() {
        performRuleTest(using: nil)
    }

    private func performRuleTest(using selectedRange: NSRange?) {
        let enabledRuleCount = ReplaceRuleManager.shared.getAllRules().filter { $0.isEnabled }.count
        guard enabledRuleCount > 0 else {
            showAlert("提示", "当前没有启用的净化规则，请先在“替换净化”中启用规则")
            return
        }

        let original = selectedReaderText(range: selectedRange) ?? fallbackRuleTestText()
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty else {
            showAlert("提示", "请先选中一段正文，或等待正文加载完成")
            return
        }

        ContentCleaner.shared.loadRules()
        let cleaned = ContentCleaner.shared.clean(content: trimmedOriginal, scope: 2)
        let resultVC = ReaderRuleTestResultViewController(
            originalText: trimmedOriginal,
            resultText: cleaned
        )
        navigationController?.pushViewController(resultVC, animated: true)
    }

    private func selectedReaderText(range: NSRange?) -> String? {
        let text = textView.text ?? ""
        guard !text.isEmpty else { return nil }

        let resolvedRange: NSRange
        if let range {
            resolvedRange = range
        } else {
            resolvedRange = textView.selectedRange
        }

        let utf16Length = text.utf16.count
        guard resolvedRange.length > 0,
              resolvedRange.location != NSNotFound,
              resolvedRange.location + resolvedRange.length <= utf16Length,
              let swiftRange = Range(resolvedRange, in: text) else {
            return nil
        }

        return String(text[swiftRange])
    }

    private func fallbackRuleTestText() -> String {
        let contentText = engine.currentContent?.content ?? ""
        let lines = contentText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let first = lines.first {
            return String(first.prefix(240))
        }
        return String(contentText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
    }

    private func currentBookmarkExcerpt() -> String {
        let rawText = (engine.currentContent?.content ?? textView.text ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = rawText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = lines.first {
            return String(first.prefix(80))
        }

        let fallback = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty {
            return String(fallback.prefix(80))
        }

        return "第\(engine.currentChapterIndex + 1)章"
    }

    @objc private func settingsTapped() {
        let vc = ReaderSettingsViewController(engine: engine)
        vc.onConfigChanged = { [weak self] in
            self?.applyTheme()
            if let c = self?.engine.currentContent { self?.displayContent(c) }
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }
    
    @objc private func switchSourceTapped() {
        let vc = SourceListViewController(book: book, isComicReadingContext: isComicReadingContext()) { [weak self] source in
            self?.changeToSource(source)
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }
    
    private func showSourceSelection(_ sources: [SearchBook]) {
        let vc = SourceListViewController(sources: sources, isComicReadingContext: isComicReadingContext()) { [weak self] source in
            self?.changeToSource(source)
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    private func isComicReadingContext() -> Bool {
        if isComicImmersiveMode {
            return true
        }
        let kindText = book.kind?.lowercased() ?? ""
        if kindText.contains("漫画") || kindText.contains("comic") || kindText.contains("manga") {
            return true
        }
        return false
    }

    private func changeToSource(_ source: SearchBook) {
        guard !source.bookSourceUrl.isEmpty else {
            showAlert("切换失败", "书源URL无效")
            return
        }
        
        // 仅允许手动加入书架，避免换源流程自动入架。
        if !ReaderServerAPI.shared.isInBookshelf(bookUrl: book.bookUrl) {
            let alert = UIAlertController(
                title: "提示",
                message: "换源需要书籍已在书架中，请先手动点击“加入书架”。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            present(alert, animated: true)
            return
        }
        
        doSwitchSource(source: source)
    }
    
    private func doSwitchSource(source: SearchBook) {
        let sourceDisplayName = source.originName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (source.originName ?? "")
            : source.name
        let loading = UIAlertController(title: "切换书源", message: "正在切换到: \(sourceDisplayName)\n书源URL: \(source.bookSourceUrl)", preferredStyle: .alert)
        loading.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(loading, animated: true)

        Task {
            do {
                let newBook = try await ReaderServerAPI.shared.switchToSource(
                    bookUrl: book.bookUrl,
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
                    self.book.name = switchedName.isEmpty ? (oldName.isEmpty ? source.name : oldName) : newBook.name
                    let switchedAuthor = newBook.author.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.book.author = switchedAuthor.isEmpty ? oldAuthor : newBook.author
                    self.book.kind = newBook.kind
                    self.book.coverUrl = newBook.coverUrl
                    self.book.intro = newBook.intro
                    self.book.type = newBook.type
                    self.book.totalChapterNum = newBook.totalChapterNum
                    self.bookSource = DatabaseManager.shared.getAllBookSources().first {
                        $0.bookSourceUrl == self.book.origin
                    }
                    self.updateHeaderTitle(preferred: self.book.name)
                    
                    loading.dismiss(animated: true) {
                        SourceListViewController.recordReadableSource(sourceUrl: source.bookSourceUrl, delta: 2)
                        self.registerChaptersObserver(removeExisting: true)
                        self.loadingIndicator.startAnimating()
                        self.engine.openBook(self.book, source: self.bookSource, resetIndex: false)
                        self.refreshUI()
                        let switchedSourceName = self.book.originName.isEmpty ? (source.originName ?? "未知书源") : self.book.originName
                        self.showToast(" 已切换到书源: \(switchedSourceName) ")
                    }
                }
            } catch {
                await MainActor.run {
                    loading.dismiss(animated: false) {
                        SourceListViewController.recordFailedSource(sourceUrl: source.bookSourceUrl, delta: 3)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.showAlert("切换失败", error.localizedDescription)
                        }
                    }
                }
            }
        }
    }
    
    private func refreshUI() {
        title = book.name
        updateHeaderTitle(preferred: book.name)
        updateUrlLabel()
        
        NotificationCenter.default.post(name: NSNotification.Name("BookSourceChanged"), object: nil, userInfo: [
            "bookUrl": book.bookUrl,
            "origin": book.origin
        ])
    }

    private var errorLabel: UILabel?

    private func showErrorInContent(_ message: String) {
        if errorLabel == nil {
            let label = UILabel()
            label.font = .systemFont(ofSize: 16)
            label.textColor = .systemRed
            label.textAlignment = .center
            label.numberOfLines = 0
            label.backgroundColor = .systemBackground
            label.layer.cornerRadius = 8
            label.clipsToBounds = true
            label.tag = 888
            textView.addSubview(label)
            label.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.leading.trailing.equalToSuperview().inset(40)
            }
            errorLabel = label
        }
        errorLabel?.text = message
        errorLabel?.isHidden = false
    }

    @objc private func prevChapterTapped() { 
        if engine.currentChapterIndex > 0 {
            let target = engine.currentChapterIndex - 1
            pendingChapterSwitchDirection = .previous
            shouldJumpToLastPage = true  // 跳转到上一章的最后一页
            if !engine.hasCachedChapterContent(index: target) {
                loadingIndicator.startAnimating()
            }
            engine.prevChapter()
        }
    }
    
    @objc private func nextChapterTapped() {
        if engine.currentChapterIndex < engine.chapters.count - 1 {
            let target = engine.currentChapterIndex + 1
            pendingChapterSwitchDirection = .next
            shouldJumpToFirstPage = true 
            if !engine.hasCachedChapterContent(index: target) {
                loadingIndicator.startAnimating()
            }
            engine.nextChapter()
        }
    }
    
    @objc private func openSourceWebpage() {
        guard let book = engine.book,
              let chapter = engine.chapters[safe: engine.currentChapterIndex] else { return }
        
        var urlString = chapter.url
        
        // 如果是相对路径，拼接域名
        if !urlString.hasPrefix("http") {
            let baseUrl = chapter.baseUrl.isEmpty ? book.origin : chapter.baseUrl
            if baseUrl.hasSuffix("/") {
                urlString = String(baseUrl.dropLast()) + urlString
            } else {
                urlString = baseUrl + urlString
            }
        }
        
        guard let url = URL(string: urlString) else {
            let alert = UIAlertController(title: "错误", message: "无法打开链接", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            present(alert, animated: true)
            return
        }
        
        UIApplication.shared.open(url)
    }

    private func updateProgress() {
        let idx = engine.currentChapterIndex
        let total = engine.chapters.count
        footerChapterLabel?.text = "\(idx + 1) / \(total)"
    }

    private func updateHeaderTitle(preferred: String? = nil) {
        let preferredTitle = preferred?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preferredTitle.isEmpty {
            headerTitleLabel?.text = preferredTitle
            headerTitleLabel?.isHidden = false
            return
        }
        if let chapterTitle = engine.chapters[safe: engine.currentChapterIndex]?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !chapterTitle.isEmpty {
            headerTitleLabel?.text = chapterTitle
            headerTitleLabel?.isHidden = false
            return
        }
        let bookTitle = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        headerTitleLabel?.text = bookTitle.isEmpty ? "正文" : bookTitle
        headerTitleLabel?.isHidden = false
    }
    
    private func updateUrlLabel() {
        guard let chapter = engine.chapters[safe: engine.currentChapterIndex] else {
            headerUrlLabel?.text = nil
            return
        }
        
        var urlString = chapter.url
        if !urlString.hasPrefix("http") {
            let baseUrl = chapter.baseUrl.isEmpty ? (engine.book?.origin ?? "") : chapter.baseUrl
            if baseUrl.hasSuffix("/") {
                urlString = String(baseUrl.dropLast()) + urlString
            } else {
                urlString = baseUrl + urlString
            }
        }
        
        headerUrlLabel?.text = urlString
    }
    
    private func showAlert(_ title: String, _ msg: String) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "确定", style: .default))
        present(a, animated: true)
    }
    
    private func showToast(_ message: String) {
        let toast = UILabel()
        toast.text = message
        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        toast.textAlignment = .center
        toast.font = .systemFont(ofSize: 14)
        toast.layer.cornerRadius = 8
        toast.clipsToBounds = true
        toast.alpha = 0
        
        view.addSubview(toast)
        toast.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-100)
            make.width.lessThanOrEqualToSuperview().offset(-40)
            make.height.equalTo(36)
        }
        
        // 添加内边距
        toast.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(100)
        }
        
        UIView.animate(withDuration: 0.3, animations: {
            toast.alpha = 1
        }) { _ in
            UIView.animate(withDuration: 0.3, delay: 2.0, options: [], animations: {
                toast.alpha = 0
            }) { _ in
                toast.removeFromSuperview()
            }
        }
    }

    private func triggerBoundaryChapterSwitchIfNeeded(velocityX: CGFloat, translationX: CGFloat? = nil) {
        let now = Date().timeIntervalSince1970
        guard now - lastBoundaryChapterSwitchTime > 0.28 else { return }

        let translation = translationX ?? 0
        let width = max(pageView.bounds.width, view.bounds.width)
        let translationThreshold = max(34, width * 0.06)
        let velocityThreshold: CGFloat = currentPageMode == PageMode.slide.rawValue ? 0.22 : 0.16
        let goNext = velocityX > velocityThreshold || translation < -translationThreshold
        let goPrev = velocityX < -velocityThreshold || translation > translationThreshold

        if goNext && engine.currentChapterIndex < engine.chapters.count - 1 {
            lastBoundaryChapterSwitchTime = now
            nextChapterTapped()
        } else if goPrev && engine.currentChapterIndex > 0 {
            lastBoundaryChapterSwitchTime = now
            prevChapterTapped()
        }
    }

    private func pageBoundaryState(for scrollView: UIScrollView) -> (isFirst: Bool, isLast: Bool, maxOffsetX: CGFloat) {
        let maxOffsetX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let x = scrollView.contentOffset.x
        let tolerance: CGFloat = 1
        let isFirst = x <= tolerance
        let isLast = x >= (maxOffsetX - tolerance)
        return (isFirst, isLast, maxOffsetX)
    }
}

extension ReaderViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return true
    }
}

extension ReaderViewController {
    @available(iOS 16.0, *)
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let testAction = UIAction(
            title: "净化测试",
            image: UIImage(systemName: "wand.and.stars")
        ) { [weak self] _ in
            self?.performRuleTest(using: range)
        }
        return UIMenu(children: suggestedActions + [testAction])
    }
}

extension ReaderViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 记录滚动位置
        lastContentOffsetX = scrollView.contentOffset.x
    }
    
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard isPagingMode, scrollView === pageView else { return }
        
        let w = scrollView.bounds.width
        guard w > 0 else { return }
        let translationX = scrollView.panGestureRecognizer.translation(in: scrollView).x
        let velocityThreshold: CGFloat = currentPageMode == PageMode.slide.rawValue ? 0.25 : 0.18
        let translationThreshold = max(34, w * 0.06)
        
        let isSinglePage = scrollView.contentSize.width <= w + 1
        if isSinglePage {
            targetContentOffset.pointee.x = 0
            triggerBoundaryChapterSwitchIfNeeded(velocityX: velocity.x, translationX: translationX)
            return
        }
        let boundary = pageBoundaryState(for: scrollView)
        
        if boundary.isLast,
           engine.currentChapterIndex < engine.chapters.count - 1,
           (velocity.x > velocityThreshold || translationX < -translationThreshold) {
            targetContentOffset.pointee.x = scrollView.contentOffset.x
            
            DispatchQueue.main.async {
                self.nextChapterTapped()
            }
        } else if boundary.isFirst,
                  engine.currentChapterIndex > 0,
                  (velocity.x < -velocityThreshold || translationX > translationThreshold) {
            targetContentOffset.pointee.x = scrollView.contentOffset.x
            
            DispatchQueue.main.async {
                self.prevChapterTapped()
            }
        }
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard isPagingMode, scrollView === pageView else { return }
        guard !decelerate else { return }

        let w = scrollView.bounds.width
        guard w > 0 else { return }
        let isSinglePage = scrollView.contentSize.width <= w + 1
        guard isSinglePage else { return }

        let velocityX = scrollView.panGestureRecognizer.velocity(in: scrollView).x
        let translationX = scrollView.panGestureRecognizer.translation(in: scrollView).x
        triggerBoundaryChapterSwitchIfNeeded(velocityX: velocityX, translationX: translationX)
    }
}

extension UIColor {
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

private final class ReaderRuleTestResultViewController: UIViewController {

    private let originalText: String
    private let resultText: String

    private lazy var textView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.alwaysBounceVertical = true
        tv.font = .systemFont(ofSize: 14)
        return tv
    }()

    init(originalText: String, resultText: String) {
        self.originalText = originalText
        self.resultText = resultText
        super.init(nibName: nil, bundle: nil)
        title = "净化测试"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }

        let summary = originalText == resultText ? "（结果：规则未改变文本）" : "（结果：已应用净化规则）"
        textView.text = "【原文】\n\(originalText)\n\n【净化后】\(summary)\n\(resultText)"
    }
}

extension String {
    func height(withFont font: UIFont, width: CGFloat) -> CGFloat {
        let constraintRect = CGSize(width: width, height: .greatestFiniteMagnitude)
        let boundingBox = self.boundingRect(
            with: constraintRect,
            options: .usesLineFragmentOrigin,
            attributes: [.font: font],
            context: nil
        )
        return ceil(boundingBox.height)
    }
}

// MARK: - UICollectionView DataSource & Delegate

extension ReaderViewController {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return comicImageUrls.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ComicImageCell.identifier, for: indexPath) as! ComicImageCell
        let url = comicImageUrls[indexPath.item]
        cell.configure(with: url, referer: comicImageReferer) { [weak self, weak collectionView] size in
            guard let self, let collectionView else { return }
            guard size.width > 0, size.height > 0 else { return }
            
            let width = max(collectionView.bounds.width, 1)
            let fittedHeight = max(120, floor(width * (size.height / size.width)))
            let previous = self.comicImageHeightCache[url] ?? 0
            guard abs(previous - fittedHeight) > 0.5 else { return }
            self.comicImageHeightCache[url] = fittedHeight
            // 尺寸变化后统一节流触发布局重算，避免后续图片长期停留在默认高度。
            self.scheduleComicLayoutInvalidation()
        }
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collectionView.bounds.width
        let url = comicImageUrls[indexPath.item]
        let height = comicImageHeightCache[url] ?? (width * 1.4)
        return CGSize(width: width, height: height)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if comicPrefetchEnabled {
            prefetchComicImages(around: indexPath.item)
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard comicPrefetchEnabled else { return }
        let nextIndex = indexPaths.map(\.item).max() ?? 0
        prefetchComicImages(around: nextIndex)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        guard comicPrefetchEnabled else { return }
        cancelPrefetchComicImages(for: indexPaths)
    }
}

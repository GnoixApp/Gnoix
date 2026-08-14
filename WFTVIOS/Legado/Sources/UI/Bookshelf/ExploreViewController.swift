import UIKit
import SnapKit

fileprivate func adaptiveUIColor(light: UIColor, dark: UIColor) -> UIColor {
    UIColor { trait in
        trait.userInterfaceStyle == .dark ? dark : light
    }
}

// 必须定义在全局作用域
struct ExploreCategory {
    let name: String
    let url: String
    let isGroupHeader: Bool
}

private enum ExploreSourceItem {
    case local(BookSource)
    case server(BookSourceResponse)

    var name: String {
        switch self {
        case .local(let source):
            return source.bookSourceName
        case .server(let source):
            return source.bookSourceName
        }
    }

    var exploreUrl: String? {
        switch self {
        case .local(let source):
            return source.exploreUrl
        case .server(let source):
            return source.exploreUrl
        }
    }

    var cacheKey: String {
        switch self {
        case .local(let source):
            return "local::\(source.bookSourceUrl)"
        case .server(let source):
            return "server::\(source.bookSourceUrl)"
        }
    }

    var sourceUrl: String {
        switch self {
        case .local(let source):
            return source.bookSourceUrl
        case .server(let source):
            return source.bookSourceUrl
        }
    }

    var rawValue: Any {
        switch self {
        case .local(let source):
            return source
        case .server(let source):
            return source
        }
    }
}

class ExploreViewController: UIViewController {
    private static let sourcePriorityStorageKey = "reader_source_readability_priority_v1"
    private static let manualSourcePriorityStorageKey = "explore_manual_source_priority_offset_v1"
    private static let comicSourceDetectionStorageKey = "reader_detected_comic_source_scores_v1"
    private static let manualPriorityStep = 500
    private static let maxManualPriorityOffset = 3_000
    private static let minManualPriorityOffset = -3_000
    private static let comicSourceDetectionThreshold = 2

    // MARK: - 属性
    private var sources: [ExploreSourceItem] = []
    private var selectedSourceIndex: Int = 0
    private var selectedSourceCacheKey: String?
    private var currentCategories: [ExploreCategory] = []
    private var categoryCache: [String: [ExploreCategory]] = [:]
    private var lastLoadedServerMode: Bool?
    private var parseModeChangedObserver: NSObjectProtocol?
    private var sourceLoadTask: Task<Void, Never>?
    private var sourceLoadToken = UUID()
    private let database = DatabaseManager.shared
    private let serverAPI = ReaderServerAPI.shared
    private var sourcePriorityScores: [String: Int] = [:]
    private var sourceRiskScores: [String: Int] = [:]
    private var sourceManualOffsets: [String: Int] = [:]
    private var sourceComicScores: [String: Int] = [:]
    
    private var isServerMode: Bool { return BookParseManager.shared.isServerMode }

    // MARK: - UI 控件
    private lazy var sourceTableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.delegate = self
        tv.dataSource = self
        tv.register(SourceListCell.self, forCellReuseIdentifier: SourceListCell.identifier)
        
        // 使用系统背景色，支持深色模式
        tv.backgroundColor = .clear
        tv.backgroundView = nil
        tv.separatorStyle = .none
        tv.showsVerticalScrollIndicator = false
        
        // 顶部留白收紧，给内容区更多可视空间
        tv.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 24, right: 0)
        return tv
    }()
    
    private lazy var categoryCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 6, left: 14, bottom: 18, right: 14)
        
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.delegate = self
        cv.dataSource = self
        cv.register(CategoryGridCell.self, forCellWithReuseIdentifier: CategoryGridCell.identifier)
        
        // 使用系统背景色，支持深色模式
        cv.backgroundColor = .clear
        cv.backgroundView = nil
        cv.alwaysBounceVertical = true
        return cv
    }()

    private lazy var sourcePanelView: UIView = {
        let view = UIView()
        view.backgroundColor = adaptiveUIColor(
            light: UIColor(red: 0.90, green: 0.93, blue: 0.97, alpha: 1),
            dark: .secondarySystemGroupedBackground
        )
        view.layer.cornerRadius = 20
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }()

    private lazy var categoryPanelView: UIView = {
        let view = UIView()
        view.backgroundColor = adaptiveUIColor(
            light: UIColor(red: 0.95, green: 0.97, blue: 0.99, alpha: 1),
            dark: .tertiarySystemGroupedBackground
        )
        view.layer.cornerRadius = 20
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }()

    private lazy var categoryTitleLabel: UILabel = {
        let label = UILabel()
        label.text = "分类"
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .label
        return label
    }()

    private lazy var categorySubtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.text = "请选择书源"
        label.numberOfLines = 1
        return label
    }()

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        setupUI()
        observeParseModeChanges()
        loadBookSources()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        title = nil
        if sources.isEmpty || lastLoadedServerMode != isServerMode {
            loadBookSources()
        } else {
            refreshSourceOrderFromRuntimeSignals()
            reselectCurrentSourceIfNeeded()
        }
        
        // 【核心沉浸】导航栏彻底透明化，无分割线，无底色
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground() 
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.compactAppearance = appearance
    }

    private func setupUI() {
        // 根视图背景使用系统背景色，支持深色模式
        view.backgroundColor = .systemGroupedBackground 
        
        view.addSubview(sourcePanelView)
        view.addSubview(categoryPanelView)
        sourcePanelView.addSubview(sourceTableView)
        categoryPanelView.addSubview(categoryTitleLabel)
        categoryPanelView.addSubview(categorySubtitleLabel)
        categoryPanelView.addSubview(categoryCollectionView)
        
        sourcePanelView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(0)
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom).offset(-8)
            make.width.equalToSuperview().multipliedBy(0.34).priority(750)
            make.width.greaterThanOrEqualTo(128)
            make.width.lessThanOrEqualTo(236)
        }

        sourceTableView.snp.makeConstraints { make in
            make.edges.equalTo(sourcePanelView)
        }

        categoryPanelView.snp.makeConstraints { make in
            make.top.equalTo(sourcePanelView)
            make.bottom.equalTo(sourcePanelView)
            make.trailing.equalToSuperview().offset(-8)
            make.leading.equalTo(sourcePanelView.snp.trailing).offset(8)
        }

        categoryTitleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(10)
            make.leading.equalToSuperview().offset(14)
            make.trailing.lessThanOrEqualToSuperview().offset(-14)
        }

        categorySubtitleLabel.snp.makeConstraints { make in
            make.top.equalTo(categoryTitleLabel.snp.bottom).offset(2)
            make.leading.equalTo(categoryTitleLabel)
            make.trailing.equalToSuperview().offset(-14)
        }

        categoryCollectionView.snp.makeConstraints { make in
            make.top.equalTo(categorySubtitleLabel.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    // MARK: - 数据处理
    private func loadBookSources() {
        sourceLoadTask?.cancel()
        sourceLoadTask = nil
        let loadToken = UUID()
        sourceLoadToken = loadToken

        let previousSelectedKey = selectedSourceCacheKey
        lastLoadedServerMode = isServerMode
        categoryCache.removeAll()
        currentCategories = []
        reloadSourceRankingSignals()

        if isServerMode {
            loadServerSources(previousSelectedKey: previousSelectedKey, token: loadToken)
        } else {
            let localSources = database.getAllBookSources().filter(isLocalExploreSourceAvailable(_:))
            sources = sortSourcesForDisplay(localSources.map { .local($0) })
            sourceTableView.reloadData()
            if let previousSelectedKey,
               let index = sources.firstIndex(where: { $0.cacheKey == previousSelectedKey }) {
                selectSource(at: index)
            } else if !sources.isEmpty {
                selectSource(at: 0)
            } else {
                selectedSourceIndex = 0
                selectedSourceCacheKey = nil
                categorySubtitleLabel.text = "暂无可用书源"
                categoryCollectionView.reloadData()
            }
        }
    }

    private func reselectCurrentSourceIfNeeded() {
        guard selectedSourceIndex >= 0, selectedSourceIndex < sources.count else { return }
        let indexPath = IndexPath(row: selectedSourceIndex, section: 0)
        sourceTableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
    }
    
    private func loadServerSources(previousSelectedKey: String?, token: UUID) {
        sourceLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let serverSources = try await self.serverAPI.getBookSources()
                if Task.isCancelled { return }
                await MainActor.run {
                    guard token == self.sourceLoadToken, self.isServerMode else { return }

                    let filteredSources = serverSources.filter(self.isServerExploreSourceAvailable(_:))
                    self.reloadSourceRankingSignals()
                    self.sources = self.sortSourcesForDisplay(filteredSources.map { .server($0) })
                    self.sourceTableView.reloadData()
                    if let previousSelectedKey,
                       let index = self.sources.firstIndex(where: { $0.cacheKey == previousSelectedKey }) {
                        self.selectSource(at: index)
                    } else if !self.sources.isEmpty {
                        self.selectSource(at: 0)
                    } else {
                        self.selectedSourceIndex = 0
                        self.selectedSourceCacheKey = nil
                        self.categorySubtitleLabel.text = "暂无可用书源"
                        self.categoryCollectionView.reloadData()
                    }
                }
            } catch {
                if Task.isCancelled { return }
                #if DEBUG
                print("Explore source load error: \(error)")
                #endif
            }
        }
    }

    private func refreshSourceOrderFromRuntimeSignals() {
        guard !sources.isEmpty else { return }
        let previousSelectedKey = selectedSourceCacheKey
        reloadSourceRankingSignals()
        let sorted = sortSourcesForDisplay(sources)
        let oldKeys = sources.map(\.cacheKey)
        let newKeys = sorted.map(\.cacheKey)
        sources = sorted
        if oldKeys != newKeys {
            sourceTableView.reloadData()
        }
        if let previousSelectedKey,
           let index = sources.firstIndex(where: { $0.cacheKey == previousSelectedKey }) {
            selectedSourceIndex = index
        }
    }

    private func isLocalExploreSourceAvailable(_ source: BookSource) -> Bool {
        source.enabled && source.enabledExplore && isValidExploreURL(source.exploreUrl)
    }

    private func isServerExploreSourceAvailable(_ source: BookSourceResponse) -> Bool {
        source.enabled && isValidExploreURL(source.exploreUrl)
    }

    private func isValidExploreURL(_ exploreUrl: String?) -> Bool {
        guard let raw = exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        let lower = raw.lowercased()
        if lower.hasPrefix("@js:") || lower.hasPrefix("@json:") || lower.hasPrefix("@java") {
            return false
        }
        return true
    }

    private func reloadSourceRankingSignals() {
        sourcePriorityScores = loadSourcePriorityScores()
        sourceRiskScores = loadSourceRiskScores()
        sourceManualOffsets = loadSourceManualOffsets()
        sourceComicScores = loadSourceComicScores()
    }

    private func intValue(from raw: Any?) -> Int? {
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let value = raw as? Int {
            return value
        }
        if let text = raw as? String {
            return Int(text)
        }
        return nil
    }

    private func loadSourcePriorityScores() -> [String: Int] {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.sourcePriorityStorageKey) else {
            return [:]
        }
        var result: [String: Int] = [:]
        for (key, value) in stored {
            guard let score = intValue(from: value) else { continue }
            let lookupKeys = sourceLookupKeys(for: key)
            if lookupKeys.isEmpty {
                continue
            }
            for normalizedKey in lookupKeys {
                let previous = result[normalizedKey]
                result[normalizedKey] = max(previous ?? score, score)
            }
        }
        return result
    }

    private func loadSourceManualOffsets() -> [String: Int] {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.manualSourcePriorityStorageKey) else {
            return [:]
        }
        var result: [String: Int] = [:]
        for (key, value) in stored {
            guard let offset = intValue(from: value), offset != 0 else { continue }
            let normalizedOffset = min(max(offset, Self.minManualPriorityOffset), Self.maxManualPriorityOffset)
            for lookupKey in sourceLookupKeys(for: key) {
                if let existing = result[lookupKey] {
                    if abs(normalizedOffset) > abs(existing) {
                        result[lookupKey] = normalizedOffset
                    }
                } else {
                    result[lookupKey] = normalizedOffset
                }
            }
        }
        return result
    }

    private func loadSourceComicScores() -> [String: Int] {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.comicSourceDetectionStorageKey) else {
            return [:]
        }
        var result: [String: Int] = [:]
        for (key, value) in stored {
            guard let score = intValue(from: value), score > 0 else { continue }
            for lookupKey in sourceLookupKeys(for: key) {
                let previous = result[lookupKey] ?? 0
                result[lookupKey] = max(previous, score)
            }
        }
        return result
    }

    private func canonicalSourcePriorityKey(_ sourceUrl: String) -> String {
        sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func sourceManualOffset(for source: ExploreSourceItem) -> Int {
        let keys = sourceLookupKeys(for: source.sourceUrl)
        var resolved = 0
        var hasResolved = false
        for key in keys {
            guard let value = sourceManualOffsets[key] else { continue }
            if !hasResolved || abs(value) > abs(resolved) {
                resolved = value
                hasResolved = true
            }
        }
        return hasResolved ? resolved : 0
    }

    private func sourceComicScore(for source: ExploreSourceItem) -> Int {
        let keys = sourceLookupKeys(for: source.sourceUrl)
        var score = 0
        for key in keys {
            score = max(score, sourceComicScores[key] ?? 0)
        }
        return score
    }

    private func isSourceDetectedComic(_ source: ExploreSourceItem) -> Bool {
        sourceComicScore(for: source) >= Self.comicSourceDetectionThreshold
    }

    private func hasManualOffset(for source: ExploreSourceItem) -> Bool {
        sourceManualOffset(for: source) != 0
    }

    private enum ManualPriorityAdjustAction {
        case boost
        case reduce
        case reset
    }

    private func removeManualPriorityAdjustment(for sourceUrl: String) {
        let canonicalKey = canonicalSourcePriorityKey(sourceUrl)
        guard !canonicalKey.isEmpty else { return }
        var stored = UserDefaults.standard.dictionary(forKey: Self.manualSourcePriorityStorageKey) ?? [:]
        guard stored[canonicalKey] != nil else { return }
        stored.removeValue(forKey: canonicalKey)
        UserDefaults.standard.set(stored, forKey: Self.manualSourcePriorityStorageKey)
    }

    private func applyManualPriorityAdjustment(
        _ action: ManualPriorityAdjustAction,
        for source: ExploreSourceItem
    ) {
        let canonicalKey = canonicalSourcePriorityKey(source.sourceUrl)
        guard !canonicalKey.isEmpty else { return }

        var stored = UserDefaults.standard.dictionary(forKey: Self.manualSourcePriorityStorageKey) ?? [:]
        let current = intValue(from: stored[canonicalKey]) ?? 0
        let nextValue: Int
        switch action {
        case .boost:
            nextValue = min(current + Self.manualPriorityStep, Self.maxManualPriorityOffset)
        case .reduce:
            nextValue = max(current - Self.manualPriorityStep, Self.minManualPriorityOffset)
        case .reset:
            nextValue = 0
        }

        if nextValue == 0 {
            stored.removeValue(forKey: canonicalKey)
        } else {
            stored[canonicalKey] = nextValue
        }
        UserDefaults.standard.set(stored, forKey: Self.manualSourcePriorityStorageKey)

        refreshSourceOrderFromRuntimeSignals()
        reselectCurrentSourceIfNeeded()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func confirmDisableSource(_ source: ExploreSourceItem) {
        let alert = UIAlertController(
            title: "禁用书源",
            message: "确认禁用「\(source.name)」？禁用后它将从发现列表移除，可在书源管理中重新启用。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认禁用", style: .destructive) { [weak self] _ in
            self?.disableSource(source)
        })
        present(alert, animated: true)
    }

    private func disableSource(_ source: ExploreSourceItem) {
        removeManualPriorityAdjustment(for: source.sourceUrl)
        switch source {
        case .local(let localSource):
            var updated = localSource
            updated.enabled = false
            updated.enabledExplore = false
            database.saveBookSource(updated)
            loadBookSources()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .server(let serverSource):
            Task { [weak self] in
                guard let self else { return }
                let disabled = BookSourceResponse(
                    bookSourceUrl: serverSource.bookSourceUrl,
                    bookSourceName: serverSource.bookSourceName,
                    bookSourceGroup: serverSource.bookSourceGroup,
                    enabled: false,
                    exploreUrl: serverSource.exploreUrl,
                    searchUrl: serverSource.searchUrl,
                    header: serverSource.header,
                    ruleSearch: serverSource.ruleSearch,
                    ruleExplore: serverSource.ruleExplore,
                    ruleBookInfo: serverSource.ruleBookInfo,
                    ruleToc: serverSource.ruleToc,
                    ruleContent: serverSource.ruleContent
                )
                do {
                    try await self.serverAPI.saveBookSource(disabled)
                    await MainActor.run {
                        self.loadBookSources()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                } catch {
                    await MainActor.run {
                        let message = (error as NSError).localizedDescription
                        let alert = UIAlertController(title: "禁用失败", message: message, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "知道了", style: .default))
                        self.present(alert, animated: true)
                    }
                }
            }
        }
    }

    private func loadSourceRiskScores() -> [String: Int] {
        let records = serverAPI.getSourceDiagnostics()
        let now = Date().timeIntervalSince1970
        let cutoff24h = now - 24 * 60 * 60
        let cutoff7d = now - 7 * 24 * 60 * 60
        var result: [String: Int] = [:]

        for record in records {
            let keys = sourceLookupKeys(for: record.sourceUrl)
            guard !keys.isEmpty else { continue }
            let failureCount = min(max(record.failureCount, 1), 8)
            let weight: Int
            if record.lastFailedAt >= cutoff24h {
                weight = 3
            } else if record.lastFailedAt >= cutoff7d {
                weight = 1
            } else {
                weight = 0
            }
            guard weight > 0 else { continue }
            for key in keys {
                result[key, default: 0] += failureCount * weight
            }
        }

        for (key, value) in result {
            result[key] = min(max(value, 0), 120)
        }
        return result
    }

    private func sourceLookupKeys(for sourceUrl: String) -> [String] {
        let trimmed = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var keys: [String] = []
        var seen: Set<String> = []

        func appendVariant(_ candidate: String) {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return }
            if seen.insert(normalized).inserted {
                keys.append(normalized)
            }
            if normalized.hasSuffix("/") {
                let noSlash = String(normalized.dropLast())
                if !noSlash.isEmpty, seen.insert(noSlash).inserted {
                    keys.append(noSlash)
                }
            } else {
                let withSlash = normalized + "/"
                if seen.insert(withSlash).inserted {
                    keys.append(withSlash)
                }
            }
            let withoutScheme = normalized.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
            if !withoutScheme.isEmpty, seen.insert(withoutScheme).inserted {
                keys.append(withoutScheme)
            }
        }

        appendVariant(trimmed)
        if let decoded = trimmed.removingPercentEncoding, decoded != trimmed {
            appendVariant(decoded)
        }
        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            var hostPath = host
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if !path.isEmpty {
                hostPath += "/\(path)"
            }
            if let query = url.query?.lowercased(), !query.isEmpty {
                hostPath += "?\(query)"
            }
            appendVariant(hostPath)
            appendVariant(host)
        }

        return keys
    }

    private func sourcePriorityScore(for source: ExploreSourceItem) -> Int {
        let keys = sourceLookupKeys(for: source.sourceUrl)
        var bestScore: Int?
        for key in keys {
            if let score = sourcePriorityScores[key] {
                bestScore = max(bestScore ?? score, score)
            }
        }
        return bestScore ?? 0
    }

    private func sourceRiskPenalty(for source: ExploreSourceItem) -> Int {
        let keys = sourceLookupKeys(for: source.sourceUrl)
        var maxPenalty = 0
        for key in keys {
            if let score = sourceRiskScores[key] {
                maxPenalty = max(maxPenalty, score)
            }
        }
        return maxPenalty
    }

    private func sourceHealthRank(for source: ExploreSourceItem) -> Int {
        let risk = sourceRiskPenalty(for: source)
        if risk >= 10 { return 2 }
        if risk >= 3 { return 1 }
        return 0
    }

    private func effectivePriorityScore(for source: ExploreSourceItem) -> Int {
        sourcePriorityScore(for: source) + sourceManualOffset(for: source) - sourceRiskPenalty(for: source) * 2
    }

    private func sortSourcesForDisplay(_ items: [ExploreSourceItem]) -> [ExploreSourceItem] {
        let indexed = Array(items.enumerated())
        let sorted = indexed.sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            let leftHealth = sourceHealthRank(for: left)
            let rightHealth = sourceHealthRank(for: right)
            if leftHealth != rightHealth {
                return leftHealth < rightHealth
            }
            let leftScore = effectivePriorityScore(for: left)
            let rightScore = effectivePriorityScore(for: right)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            let nameCompare = left.name.localizedCompare(right.name)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            return lhs.offset < rhs.offset
        }
        return sorted.map(\.element)
    }

    private func selectSource(at index: Int) {
        guard index < sources.count else { return }
        selectedSourceIndex = index
        selectedSourceCacheKey = sources[index].cacheKey
        sourceTableView.selectRow(at: IndexPath(row: index, section: 0), animated: true, scrollPosition: .none)

        let selectedSource = sources[index]
        if let cached = categoryCache[selectedSource.cacheKey] {
            currentCategories = cached
        } else {
            let parsed = parseExploreCategories(from: selectedSource.exploreUrl)
            categoryCache[selectedSource.cacheKey] = parsed
            currentCategories = parsed
        }
        categorySubtitleLabel.text = "\(selectedSource.name) · \(currentCategories.count) 个分类"
        categoryCollectionView.reloadData()
    }

    private func parseExploreCategories(from exploreUrl: String?) -> [ExploreCategory] {
        guard let url = exploreUrl, !url.isEmpty else { return [] }
        var categories: [ExploreCategory] = []
        
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUrl.hasPrefix("[") || trimmedUrl.hasPrefix("{") {
            if let data = trimmedUrl.data(using: .utf8),
               let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in jsonArray {
                    let name = (item["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                    let u = (item["url"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                    guard !name.isEmpty else { continue }
                    let isGroupHeader = u.isEmpty && !name.isEmpty
                    categories.append(ExploreCategory(name: name, url: u, isGroupHeader: isGroupHeader))
                }
            }
        } else {
            let normalized = trimmedUrl.replacingOccurrences(of: "\\n", with: "\n")
            normalized.components(separatedBy: "\n").forEach { line in
                let parts = line.components(separatedBy: "::")
                let name = parts.count >= 1 ? parts[0].trimmingCharacters(in: .whitespaces) : ""
                let u = parts.count >= 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                guard !name.isEmpty else { return }
                let isGroupHeader = u.isEmpty && !name.isEmpty
                categories.append(ExploreCategory(name: name, url: u, isGroupHeader: isGroupHeader))
            }
        }
        return categories
    }

    private func observeParseModeChanges() {
        parseModeChangedObserver = NotificationCenter.default.addObserver(
            forName: .bookParseModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadBookSources()
        }
    }
    
    deinit {
        sourceLoadTask?.cancel()
        if let observer = parseModeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - UITableView 代理 (左侧)
extension ExploreViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return sources.count }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SourceListCell.identifier, for: indexPath) as! SourceListCell
        let source = sources[indexPath.row]
        cell.configure(name: source.name, isComic: isSourceDetectedComic(source))
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { selectSource(at: indexPath.row) }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { return 56 }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.row < sources.count else { return nil }
        let source = sources[indexPath.row]

        let boostAction = UIContextualAction(style: .normal, title: "置顶") { [weak self] _, _, completion in
            self?.applyManualPriorityAdjustment(.boost, for: source)
            completion(true)
        }
        boostAction.backgroundColor = .systemBlue

        let reduceAction = UIContextualAction(style: .normal, title: "降权") { [weak self] _, _, completion in
            self?.applyManualPriorityAdjustment(.reduce, for: source)
            completion(true)
        }
        reduceAction.backgroundColor = .systemOrange

        let config = UISwipeActionsConfiguration(actions: [reduceAction, boostAction])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.row < sources.count else { return nil }
        let source = sources[indexPath.row]
        guard hasManualOffset(for: source) else { return nil }

        let resetAction = UIContextualAction(style: .normal, title: "重置") { [weak self] _, _, completion in
            self?.applyManualPriorityAdjustment(.reset, for: source)
            completion(true)
        }
        resetAction.backgroundColor = .systemGray

        let config = UISwipeActionsConfiguration(actions: [resetAction])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPath.row < sources.count else { return nil }
        let source = sources[indexPath.row]

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }

            let boostTitle = self.sourceManualOffset(for: source) > 0 ? "继续置顶" : "手动置顶"
            let boost = UIAction(title: boostTitle, image: UIImage(systemName: "arrow.up.to.line")) { _ in
                self.applyManualPriorityAdjustment(.boost, for: source)
            }
            let reduce = UIAction(title: "手动降权", image: UIImage(systemName: "arrow.down.to.line")) { _ in
                self.applyManualPriorityAdjustment(.reduce, for: source)
            }
            let reset = UIAction(
                title: "恢复自动排序",
                image: UIImage(systemName: "arrow.counterclockwise"),
                attributes: self.hasManualOffset(for: source) ? [] : [.disabled]
            ) { _ in
                self.applyManualPriorityAdjustment(.reset, for: source)
            }

            let disable = UIAction(
                title: "手动禁用",
                image: UIImage(systemName: "nosign"),
                attributes: .destructive
            ) { _ in
                self.confirmDisableSource(source)
            }

            return UIMenu(title: source.name, children: [boost, reduce, reset, disable])
        }
    }
}

// MARK: - UICollectionView 代理 (右侧)
extension ExploreViewController: UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 
        return currentCategories.count 
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CategoryGridCell.identifier, for: indexPath) as! CategoryGridCell
        let category = currentCategories[indexPath.item]
        cell.configure(name: category.name, isGroupHeader: category.isGroupHeader)
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let category = currentCategories[indexPath.item]
        let horizontalInset: CGFloat = 28
        let spacing: CGFloat = 12
        let usableWidth = max(collectionView.bounds.width - horizontalInset, 140)
        if category.isGroupHeader {
            return CGSize(width: usableWidth, height: 38)
        }
        let minItemWidth: CGFloat = 118
        let maxColumns = Int((usableWidth + spacing) / (minItemWidth + spacing))
        let columns = max(2, min(6, maxColumns))
        let totalSpacing = CGFloat(max(columns - 1, 0)) * spacing
        let width = floor((usableWidth - totalSpacing) / CGFloat(columns))
        return CGSize(width: max(98, width), height: 44)
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let category = currentCategories[indexPath.item]
        guard !category.url.isEmpty else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard selectedSourceIndex < sources.count else { return }
        let source = sources[selectedSourceIndex].rawValue
        let vc = ExploreBookListViewController(category: category, source: source, isServerMode: isServerMode)
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - Cell 实现 (去背景纯沉浸)

class SourceListCell: UITableViewCell {
    static let identifier = "SourceListCell"
    private let capsuleView = UIView()
    private let titleLabel = UILabel()
    private let activeDot = UIView() // 用一个小圆点代替死板的竖条，更轻量
    private let comicBadgeLabel = UILabel()
    private var titleTrailingToBadgeConstraint: Constraint?
    private var titleTrailingToContainerConstraint: Constraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        capsuleView.layer.cornerRadius = 12
        capsuleView.layer.cornerCurve = .continuous
        capsuleView.backgroundColor = adaptiveUIColor(light: .white, dark: .systemBackground)
        contentView.addSubview(capsuleView)
        
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textAlignment = .left
        titleLabel.numberOfLines = 2
        titleLabel.textColor = .secondaryLabel
        capsuleView.addSubview(titleLabel)
        
        activeDot.backgroundColor = .systemBlue
        activeDot.layer.cornerRadius = 3
        activeDot.isHidden = true
        capsuleView.addSubview(activeDot)

        comicBadgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        comicBadgeLabel.text = "漫"
        comicBadgeLabel.textAlignment = .center
        comicBadgeLabel.textColor = .systemOrange
        comicBadgeLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.2)
        comicBadgeLabel.layer.cornerRadius = 7
        comicBadgeLabel.clipsToBounds = true
        comicBadgeLabel.isHidden = true
        capsuleView.addSubview(comicBadgeLabel)
        
        capsuleView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(18)
            make.top.bottom.equalToSuperview().inset(8)
            titleTrailingToBadgeConstraint = make.trailing.lessThanOrEqualTo(comicBadgeLabel.snp.leading).offset(-6).constraint
            titleTrailingToContainerConstraint = make.trailing.equalToSuperview().offset(-10).constraint
        }
        comicBadgeLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-8)
            make.centerY.equalToSuperview()
            make.width.equalTo(20)
            make.height.equalTo(14)
        }
        activeDot.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
            make.size.equalTo(6)
        }

        // 默认按非漫画布局，名称占满行宽，不给徽标预留空位。
        titleTrailingToBadgeConstraint?.deactivate()
        titleTrailingToContainerConstraint?.activate()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    func configure(name: String, isComic: Bool) {
        titleLabel.text = name
        comicBadgeLabel.isHidden = !isComic
        if isComic {
            titleTrailingToContainerConstraint?.deactivate()
            titleTrailingToBadgeConstraint?.activate()
        } else {
            titleTrailingToBadgeConstraint?.deactivate()
            titleTrailingToContainerConstraint?.activate()
        }
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        // 选中时强调色差，未选中保持弱层级底色。
        titleLabel.textColor = selected ? .label : .secondaryLabel
        titleLabel.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .regular)
        activeDot.isHidden = !selected
        capsuleView.backgroundColor = selected
            ? UIColor.systemBlue.withAlphaComponent(0.16)
            : adaptiveUIColor(light: .white, dark: .systemBackground)
    }
}

class CategoryGridCell: UICollectionViewCell {
    static let identifier = "CategoryGridCell"
    private let nameLabel = UILabel()
    private var isGroupHeaderStyle = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.layer.cornerCurve = .continuous
        contentView.backgroundColor = adaptiveUIColor(light: .white, dark: .secondarySystemBackground)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textAlignment = .center
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(nameLabel)
        nameLabel.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)) }
    }
    
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override var isSelected: Bool {
        didSet { updateAppearance() }
    }

    func configure(name: String, isGroupHeader: Bool = false) {
        isGroupHeaderStyle = isGroupHeader
        nameLabel.text = name
        if isGroupHeader {
            nameLabel.textAlignment = .left
            nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            nameLabel.textColor = .label
            contentView.backgroundColor = adaptiveUIColor(
                light: UIColor(red: 0.88, green: 0.91, blue: 0.96, alpha: 1),
                dark: .quaternarySystemFill
            )
            transform = .identity
        } else {
            nameLabel.textAlignment = .center
            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            updateAppearance()
        }
    }

    private func updateAppearance() {
        guard !isGroupHeaderStyle else { return }
        let isActive = isHighlighted || isSelected
        if isActive {
            contentView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.16)
            nameLabel.textColor = .systemBlue
            transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
        } else {
            contentView.backgroundColor = adaptiveUIColor(light: .white, dark: .secondarySystemBackground)
            nameLabel.textColor = .label
            transform = .identity
        }
    }
}

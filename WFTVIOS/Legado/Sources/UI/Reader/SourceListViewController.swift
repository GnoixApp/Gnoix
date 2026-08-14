import UIKit
import SnapKit

fileprivate enum SourceValidationState {
    case pending
    case checking
    case passed(chapterCount: Int)
    case failed(reason: String)

    var isFinished: Bool {
        switch self {
        case .passed, .failed:
            return true
        default:
            return false
        }
    }
}

private struct SourceValidationResult {
    let readable: Bool
    let chapterCount: Int
    let message: String
}

private struct SourceSearchBatchResult {
    let matched: [SearchBook]
    let filteredOut: Int
    let finalLastIndex: Int
    let noMore: Bool
    let rounds: Int
}

private struct SourceSearchRoundUpdate {
    let matched: [SearchBook]
    let filteredOut: Int
    let currentLastIndex: Int
    let noMore: Bool
    let rounds: Int
}

class SourceListViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    private static let sourcePriorityStorageKey = "reader_source_readability_priority_v1"
    private static let maxPriorityScore = 10_000
    private static let minPriorityScore = -3_000

    private var book: Book?
    private var currentBookUrl: String = ""
    private var currentSourceUrl: String = ""
    private var sources: [SearchBook] = []
    private var onSelect: ((SearchBook) -> Void)?
    private let isComicReadingContext: Bool
    private var isSearching = false
    private var lastIndex = 0
    private var hasMoreSources = true

    private var validationStates: [String: SourceValidationState] = [:]
    private var validationQueue: [String] = []
    private var validationRunningTasks: [UUID: Task<Void, Never>] = [:]
    private let validationConcurrency = 6
    private let initialAutoPageTargetCount = 12
    private let autoSearchMaxRounds = 20
    private var validationGeneration: Int = 0
    private var validationTotal = 0
    private var validationCompleted = 0
    private var validationPassed = 0
    private var pendingSelectionKey: String?
    private var filteredOutByStrictMatchCount: Int = 0
    private var sourcePriorityScores: [String: Int] = SourceListViewController.loadSourcePriorityScores()
    private var diagnosticPenaltyScores: [String: Int] = [:]
    private var sourceSearchTask: Task<Void, Never>?
    private var sourceSearchRequestId: Int = 0

    private lazy var searchStatusView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground

        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = UIColor.systemGray5
        progressView.progress = 0.0
        progressView.tag = 100
        view.addSubview(progressView)

        let statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.tag = 101
        view.addSubview(statusLabel)

        let detailLabel = UILabel()
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.tag = 102
        view.addSubview(detailLabel)

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.tag = 103
        view.addSubview(spinner)

        progressView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(12)
            make.leading.trailing.equalToSuperview().inset(16)
        }

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(progressView.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(16)
        }

        detailLabel.snp.makeConstraints { make in
            make.top.equalTo(statusLabel.snp.bottom).offset(4)
            make.centerX.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(34)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
            make.bottom.equalToSuperview().offset(-10)
        }

        spinner.snp.makeConstraints { make in
            make.centerY.equalTo(detailLabel)
            make.trailing.equalTo(detailLabel.snp.leading).offset(-6)
            make.width.height.equalTo(14)
        }

        return view
    }()

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.delegate = self
        tv.dataSource = self
        tv.register(SourceCell.self, forCellReuseIdentifier: SourceCell.identifier)
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 86
        tv.keyboardDismissMode = .onDrag
        return tv
    }()

    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.text = "未找到其他书源"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15)
        label.isHidden = true
        return label
    }()

    private var statusProgressView: UIProgressView? {
        searchStatusView.viewWithTag(100) as? UIProgressView
    }

    private var statusLabel: UILabel? {
        searchStatusView.viewWithTag(101) as? UILabel
    }

    private var detailLabel: UILabel? {
        searchStatusView.viewWithTag(102) as? UILabel
    }

    private var statusSpinner: UIActivityIndicatorView? {
        searchStatusView.viewWithTag(103) as? UIActivityIndicatorView
    }

    init(book: Book, isComicReadingContext: Bool = false, onSelect: @escaping (SearchBook) -> Void) {
        self.book = book
        self.onSelect = onSelect
        self.isComicReadingContext = isComicReadingContext
        super.init(nibName: nil, bundle: nil)
    }

    init(sources: [SearchBook], isComicReadingContext: Bool = false, onSelect: @escaping (SearchBook) -> Void) {
        self.sources = sources
        self.onSelect = onSelect
        self.isComicReadingContext = isComicReadingContext
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        sourceSearchTask?.cancel()
        sourceSearchTask = nil
        validationRunningTasks.values.forEach { $0.cancel() }
        validationRunningTasks.removeAll()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelRunningSearchWork()
            cancelValidationWork()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        reloadDiagnosticPenaltyScores()
        sortSourcesByPriorityAndState()
        tableView.reloadData()

        if book != nil {
            startSearch()
        }
    }

    private func setupUI() {
        title = "换源（可读优先）"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancelTapped))

        if book != nil {
            currentBookUrl = book?.bookUrl ?? ""
            currentSourceUrl = SourceListViewController.normalizedSourcePriorityKey(book?.origin ?? "")
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "加载更多", style: .plain, target: self, action: #selector(loadMoreTapped))
        }

        view.addSubview(searchStatusView)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)

        searchStatusView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview()
        }

        tableView.snp.makeConstraints { make in
            make.top.equalTo(searchStatusView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        if book == nil {
            searchStatusView.isHidden = true
            tableView.snp.remakeConstraints { make in
                make.top.equalTo(view.safeAreaLayoutGuide)
                make.leading.trailing.bottom.equalToSuperview()
            }
        }
    }

    @objc private func cancelTapped() {
        cancelRunningSearchWork()
        cancelValidationWork()
        dismiss(animated: true)
    }

    @objc private func loadMoreTapped() {
        guard book != nil, !isSearching, hasMoreSources else { return }
        let searchStartIndex = lastIndex
        sourceSearchRequestId += 1
        let requestId = sourceSearchRequestId

        isSearching = true
        navigationItem.rightBarButtonItem?.isEnabled = false

        startIndeterminateProgress(
            status: "正在加载更多候选书源",
            detail: "当前已找到 \(sources.count) 个"
        )

        sourceSearchTask = Task {
            do {
                let result = try await fetchSourcesUntilEnoughPage(
                    from: lastIndex,
                    targetCount: initialAutoPageTargetCount,
                    onRound: { [weak self] update in
                        guard let self else { return }
                        guard self.sourceSearchRequestId == requestId else { return }
                        self.filteredOutByStrictMatchCount += update.filteredOut
                        self.lastIndex = update.currentLastIndex
                        self.hasMoreSources = !update.noMore
                        self.navigationItem.rightBarButtonItem?.title = update.noMore ? "没有更多" : "加载更多"

                        var newlyAddedCount = 0
                        for candidate in update.matched {
                            let added = self.mergeSources([candidate])
                            guard !added.isEmpty else { continue }
                            newlyAddedCount += added.count
                            self.sortSourcesByPriorityAndState()
                            self.tableView.reloadData()
                            self.emptyLabel.isHidden = true
                            self.enqueueValidation(for: added, resetCounters: false)
                        }

                        if newlyAddedCount > 0 {
                            self.updateStatus(
                                status: "已新增 \(newlyAddedCount) 个候选",
                                detail: "当前共 \(self.sources.count) 个，已开始逐条检测可读性",
                                progress: self.statusProgressView?.progress ?? 0,
                                animate: false,
                                showSpinner: true
                            )
                        } else if update.rounds > 1 {
                            self.detailLabel?.text = "已扫描 \(update.rounds) 页，继续搜索中"
                        }
                    }
                )

                await MainActor.run {
                    guard self.sourceSearchRequestId == requestId else { return }
                    self.isSearching = false
                    self.sourceSearchTask = nil
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                    self.stopIndeterminateProgress()

                    self.filteredOutByStrictMatchCount = result.filteredOut
                    self.lastIndex = result.finalLastIndex
                    let noMore = result.noMore || (result.finalLastIndex == searchStartIndex && result.matched.isEmpty)
                    self.hasMoreSources = !noMore
                    self.navigationItem.rightBarButtonItem?.title = noMore ? "没有更多" : "加载更多"

                    if result.matched.isEmpty {
                        self.updateValidationSummaryStatus()
                    }

                    if noMore {
                        self.detailLabel?.text = self.filteredOutByStrictMatchCount > 0
                            ? "已过滤 \(self.filteredOutByStrictMatchCount) 个书名不一致或作者不匹配结果"
                            : "已扫描到末尾，可读源会自动标记"
                    } else if result.rounds > 1 && !result.matched.isEmpty {
                        self.detailLabel?.text = "已连续扫描 \(result.rounds) 页，候选持续更新中"
                    }
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    await MainActor.run {
                        guard self.sourceSearchRequestId == requestId else { return }
                        self.isSearching = false
                        self.sourceSearchTask = nil
                        self.navigationItem.rightBarButtonItem?.isEnabled = true
                        self.stopIndeterminateProgress()
                    }
                    return
                }
                await MainActor.run {
                    guard self.sourceSearchRequestId == requestId else { return }
                    self.isSearching = false
                    self.sourceSearchTask = nil
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                    self.stopIndeterminateProgress()
                    self.updateStatus(
                        status: "加载失败",
                        detail: error.localizedDescription,
                        progress: self.statusProgressView?.progress ?? 0,
                        animate: false,
                        showSpinner: false
                    )
                }
            }
        }
    }

    private func startSearch() {
        guard let book = book, !isSearching else { return }
        sourceSearchTask?.cancel()
        sourceSearchRequestId += 1
        let requestId = sourceSearchRequestId

        resetValidationTracking()
        filteredOutByStrictMatchCount = 0
        isSearching = true
        sources.removeAll()
        lastIndex = 0
        hasMoreSources = true
        navigationItem.rightBarButtonItem?.title = "加载更多"
        tableView.reloadData()
        emptyLabel.isHidden = true

        startIndeterminateProgress(
            status: "正在搜索: \(book.name)",
            detail: "搜索后将自动校验目录和正文可读性"
        )

        sourceSearchTask = Task {
            do {
                let result = try await fetchSourcesUntilEnoughPage(
                    from: 0,
                    targetCount: initialAutoPageTargetCount,
                    onRound: { [weak self] update in
                        guard let self else { return }
                        guard self.sourceSearchRequestId == requestId else { return }
                        self.filteredOutByStrictMatchCount += update.filteredOut
                        self.lastIndex = update.currentLastIndex
                        self.hasMoreSources = !update.noMore
                        self.navigationItem.rightBarButtonItem?.title = update.noMore ? "没有更多" : "加载更多"

                        var newlyAddedCount = 0
                        for candidate in update.matched {
                            let added = self.mergeSources([candidate])
                            guard !added.isEmpty else { continue }
                            newlyAddedCount += added.count
                            self.sortSourcesByPriorityAndState()
                            self.tableView.reloadData()
                            self.emptyLabel.isHidden = true
                            self.enqueueValidation(for: added, resetCounters: false)
                        }

                        if newlyAddedCount > 0 {
                            self.updateStatus(
                                status: "已找到 \(self.sources.count) 个候选书源",
                                detail: "新结果实时加入，并逐条检测可读性",
                                progress: self.statusProgressView?.progress ?? 0,
                                animate: false,
                                showSpinner: true
                            )
                        } else if update.rounds > 1 {
                            self.detailLabel?.text = "已扫描 \(update.rounds) 页，继续查找中"
                        }
                    }
                )

                await MainActor.run {
                    guard self.sourceSearchRequestId == requestId else { return }
                    self.stopIndeterminateProgress()
                    self.filteredOutByStrictMatchCount = result.filteredOut
                    self.lastIndex = result.finalLastIndex
                    self.isSearching = false
                    self.sourceSearchTask = nil

                    let noMore = result.noMore
                    self.hasMoreSources = !noMore
                    self.navigationItem.rightBarButtonItem?.title = noMore ? "没有更多" : "加载更多"

                    if self.sources.isEmpty {
                        let noMatchDetail = self.filteredOutByStrictMatchCount > 0
                            ? "已过滤 \(self.filteredOutByStrictMatchCount) 个书名不一致或作者不匹配结果"
                            : (noMore ? "没有更多可搜索书源" : "继续自动扫描中，可稍后点“加载更多”")
                        self.updateStatus(
                            status: "未找到匹配书源",
                            detail: noMatchDetail,
                            progress: 0,
                            animate: false,
                            showSpinner: false
                        )
                        self.emptyLabel.isHidden = false
                    } else {
                        self.emptyLabel.isHidden = true
                        self.tableView.reloadData()
                        self.updateValidationSummaryStatus()
                        if result.rounds > 1 {
                            self.detailLabel?.text = "已连续扫描 \(result.rounds) 页，当前候选 \(self.sources.count) 个（实时更新）"
                        }
                    }
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    await MainActor.run {
                        guard self.sourceSearchRequestId == requestId else { return }
                        self.stopIndeterminateProgress()
                        self.isSearching = false
                        self.sourceSearchTask = nil
                        self.navigationItem.rightBarButtonItem?.isEnabled = true
                    }
                    return
                }
                await MainActor.run {
                    guard self.sourceSearchRequestId == requestId else { return }
                    self.stopIndeterminateProgress()
                    self.isSearching = false
                    self.sourceSearchTask = nil
                    self.updateStatus(
                        status: "搜索失败",
                        detail: error.localizedDescription,
                        progress: 0,
                        animate: false,
                        showSpinner: false
                    )
                }
            }
        }
    }

    private func fetchSourcesUntilEnoughPage(
        from initialLastIndex: Int,
        targetCount: Int,
        onRound: (@MainActor (SourceSearchRoundUpdate) -> Void)? = nil
    ) async throws -> SourceSearchBatchResult {
        var cursor = max(0, initialLastIndex)
        var rounds = 0
        var filteredOut = 0
        var matched: [SearchBook] = []
        var noMore = false

        repeat {
            try Task.checkCancellation()
            let (rawResults, newLastIndex) = try await ReaderServerAPI.shared.searchBookSources(
                bookUrl: currentBookUrl,
                lastIndex: cursor
            )
            try Task.checkCancellation()
            rounds += 1

            let strictFiltered = strictMatchFilter(rawResults)
            filteredOut += strictFiltered.filteredOut
            if !strictFiltered.matched.isEmpty {
                matched.append(contentsOf: strictFiltered.matched)
            }

            noMore = shouldStopLoading(
                newLastIndex: newLastIndex,
                previousIndex: cursor,
                batchCount: rawResults.count
            )
            cursor = newLastIndex

            if let onRound {
                try Task.checkCancellation()
                await onRound(
                    SourceSearchRoundUpdate(
                        matched: strictFiltered.matched,
                        filteredOut: strictFiltered.filteredOut,
                        currentLastIndex: cursor,
                        noMore: noMore,
                        rounds: rounds
                    )
                )
            }

            if noMore || matched.count >= max(1, targetCount) || rounds >= autoSearchMaxRounds {
                break
            }
        } while true

        return SourceSearchBatchResult(
            matched: matched,
            filteredOut: filteredOut,
            finalLastIndex: cursor,
            noMore: noMore,
            rounds: rounds
        )
    }

    private func sourceKey(_ source: SearchBook) -> String {
        return "\(source.bookSourceUrl)|\(source.bookUrl)"
    }

    private func normalizeStrictMatchText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalizedSpaces = trimmed.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return normalizedSpaces.lowercased()
    }

    private func strictMatchFilter(_ candidates: [SearchBook]) -> (matched: [SearchBook], filteredOut: Int) {
        guard let book else { return (candidates, 0) }

        let targetName = normalizeStrictMatchText(book.name)
        let targetAuthor = normalizeStrictMatchText(book.author)
        guard !targetName.isEmpty else { return (candidates, 0) }

        let matched = candidates.filter { candidate in
            let candidateName = normalizeStrictMatchText(candidate.name)
            guard candidateName == targetName else { return false }
            let candidateAuthor = normalizeStrictMatchText(candidate.author)
            guard !targetAuthor.isEmpty else { return true }
            guard !candidateAuthor.isEmpty else { return false }
            return candidateAuthor.contains(targetAuthor) || targetAuthor.contains(candidateAuthor)
        }
        return (matched, max(candidates.count - matched.count, 0))
    }

    private func preferredSource(existing: SearchBook, candidate: SearchBook) -> SearchBook {
        let existingTime = existing.time > 0 ? existing.time : Int.max
        let candidateTime = candidate.time > 0 ? candidate.time : Int.max
        if candidateTime < existingTime { return candidate }
        if existingTime < candidateTime { return existing }

        let existingInfoScore =
            (existing.originName?.isEmpty == false ? 1 : 0) +
            (existing.latestChapter?.isEmpty == false ? 1 : 0) +
            (existing.intro?.isEmpty == false ? 1 : 0)
        let candidateInfoScore =
            (candidate.originName?.isEmpty == false ? 1 : 0) +
            (candidate.latestChapter?.isEmpty == false ? 1 : 0) +
            (candidate.intro?.isEmpty == false ? 1 : 0)
        return candidateInfoScore >= existingInfoScore ? candidate : existing
    }

    private func deduplicatedSources(_ candidates: [SearchBook]) -> [SearchBook] {
        var map: [String: SearchBook] = [:]
        var order: [String] = []
        for candidate in candidates {
            let key = sourceKey(candidate)
            if let existing = map[key] {
                map[key] = preferredSource(existing: existing, candidate: candidate)
            } else {
                map[key] = candidate
                order.append(key)
            }
        }
        return order.compactMap { map[$0] }
    }

    private func mergeSources(_ incoming: [SearchBook]) -> [SearchBook] {
        var added: [SearchBook] = []
        for candidate in incoming {
            let key = sourceKey(candidate)
            if let idx = sources.firstIndex(where: { sourceKey($0) == key }) {
                sources[idx] = preferredSource(existing: sources[idx], candidate: candidate)
            } else {
                sources.append(candidate)
                added.append(candidate)
            }
        }
        return added
    }

    private func source(for key: String) -> SearchBook? {
        return sources.first { sourceKey($0) == key }
    }

    private func rowIndex(for key: String) -> Int? {
        return sources.firstIndex { sourceKey($0) == key }
    }

    private func resetValidationTracking() {
        validationGeneration += 1
        pendingSelectionKey = nil
        validationRunningTasks.values.forEach { $0.cancel() }
        validationRunningTasks.removeAll()
        validationQueue.removeAll()
        validationStates.removeAll()
        validationTotal = 0
        validationCompleted = 0
        validationPassed = 0
    }

    private func cancelValidationWork() {
        validationGeneration += 1
        pendingSelectionKey = nil
        validationRunningTasks.values.forEach { $0.cancel() }
        validationRunningTasks.removeAll()
        validationQueue.removeAll()
    }

    private func cancelRunningSearchWork() {
        sourceSearchRequestId += 1
        sourceSearchTask?.cancel()
        sourceSearchTask = nil
        isSearching = false
        navigationItem.rightBarButtonItem?.isEnabled = true
        stopIndeterminateProgress()
    }

    private func enqueueValidation(for newSources: [SearchBook], resetCounters: Bool) {
        if resetCounters {
            resetValidationTracking()
        }

        var added = 0
        for source in newSources {
            let key = sourceKey(source)
            if validationStates[key] == nil {
                validationStates[key] = .pending
                validationQueue.append(key)
                validationTotal += 1
                added += 1
            }
        }

        tableView.reloadData()
        if added > 0 {
            updateValidationSummaryStatus()
            scheduleValidationIfNeeded()
        } else {
            updateValidationSummaryStatus()
        }
    }

    private func scheduleValidationIfNeeded() {
        while validationRunningTasks.count < validationConcurrency {
            guard let candidate = dequeueNextValidationCandidate(generation: validationGeneration) else {
                break
            }
            startSingleValidation(for: candidate, generation: validationGeneration)
        }
        updateValidationSummaryStatus()
    }

    private func startSingleValidation(for candidate: SearchBook, generation: Int) {
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.validateSource(candidate)
            await MainActor.run {
                guard generation == self.validationGeneration else { return }
                self.validationRunningTasks.removeValue(forKey: taskID)
                self.applyValidationResult(result, for: candidate, generation: generation)
                self.scheduleValidationIfNeeded()
            }
        }
        validationRunningTasks[taskID] = task
    }

    private func dequeueNextValidationCandidate(generation: Int) -> SearchBook? {
        guard generation == validationGeneration else { return nil }

        while !validationQueue.isEmpty {
            let key = validationQueue.removeFirst()
            guard let state = validationStates[key] else { continue }
            guard case .pending = state else { continue }
            guard let candidate = source(for: key) else { continue }

            validationStates[key] = .checking
            if let row = rowIndex(for: key) {
                tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
            }
            updateValidationSummaryStatus(activeSourceKey: key)
            return candidate
        }

        return nil
    }

    private func validateSource(_ source: SearchBook) async -> SourceValidationResult {
        let baseBookUrl = currentBookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? source.bookUrl : currentBookUrl

        do {
            let report = try await ReaderServerAPI.shared.validateSwitchCandidate(
                bookUrl: baseBookUrl,
                newUrl: source.bookUrl,
                bookSourceUrl: source.bookSourceUrl
            )
            return SourceValidationResult(
                readable: true,
                chapterCount: report.chapterCount,
                message: "目录 \(report.chapterCount) 章，正文可读"
            )
        } catch {
            return SourceValidationResult(
                readable: false,
                chapterCount: 0,
                message: error.localizedDescription
            )
        }
    }

    private func applyValidationResult(_ result: SourceValidationResult, for source: SearchBook, generation: Int) {
        guard generation == validationGeneration else { return }

        let key = sourceKey(source)
        let previousState = validationStates[key] ?? .pending
        if !previousState.isFinished {
            validationCompleted += 1
        }

        if result.readable {
            if !previousState.isFinished {
                validationPassed += 1
            }
            validationStates[key] = .passed(chapterCount: result.chapterCount)
            boostSourcePriority(for: source)
        } else {
            validationStates[key] = .failed(reason: result.message)
            penalizeSourcePriority(for: source, delta: 1)
        }

        reloadDiagnosticPenaltyScores()
        let moved = sortSourcesByPriorityAndState()
        if moved {
            tableView.reloadData()
        } else if let row = rowIndex(for: key) {
            tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
        }

        let shouldAutoSelect = pendingSelectionKey == key && result.readable
        let shouldShowPendingError = pendingSelectionKey == key && !result.readable

        if shouldAutoSelect {
            pendingSelectionKey = nil
            completeSelection(source)
            return
        }

        if shouldShowPendingError {
            pendingSelectionKey = nil
            showAlert("该书源暂不可读", result.message)
        }

        updateValidationSummaryStatus()
    }

    private func prioritizeValidation(for key: String) {
        if let idx = validationQueue.firstIndex(of: key) {
            validationQueue.remove(at: idx)
            validationQueue.insert(key, at: 0)
        }
        updateValidationSummaryStatus(activeSourceKey: key)
        scheduleValidationIfNeeded()
    }

    private func completeSelection(_ source: SearchBook) {
        dismiss(animated: true) {
            self.onSelect?(source)
        }
    }

    private func updateValidationSummaryStatus(activeSourceKey: String? = nil) {
        guard !isSearching else { return }

        let failedCount = max(validationCompleted - validationPassed, 0)
        let checkingCount = validationStates.values.reduce(into: 0) { count, state in
            if case .checking = state {
                count += 1
            }
        }
        let activeName: String = {
            guard let activeSourceKey, let active = source(for: activeSourceKey) else { return "" }
            let name = active.originName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { return name }
            if let host = URL(string: active.bookSourceUrl)?.host, !host.isEmpty { return host }
            return active.bookSourceUrl
        }()

        if validationTotal <= 0 {
            updateStatus(
                status: "等待校验",
                detail: sources.isEmpty ? "暂无候选书源" : "准备开始校验",
                progress: 0,
                animate: false,
                showSpinner: false
            )
            return
        }

        let progress = Float(validationCompleted) / Float(max(validationTotal, 1))
        if validationCompleted < validationTotal {
            let statusText = activeName.isEmpty
                ? "并发校验中 \(validationCompleted)/\(validationTotal)"
                : "正在校验: \(activeName)"
            let detailText = "并发 \(checkingCount)/\(validationConcurrency) | 可读 \(validationPassed) | 失败 \(failedCount)"
            updateStatus(
                status: statusText,
                detail: detailText,
                progress: progress,
                animate: true,
                showSpinner: true
            )
        } else {
            let detailText = hasMoreSources
                ? "可读 \(validationPassed) 个 | 失败 \(failedCount) 个，可继续加载更多"
                : "可读 \(validationPassed) 个 | 失败 \(failedCount) 个，已校验完成"
            updateStatus(
                status: "书源校验完成",
                detail: detailText,
                progress: 1,
                animate: true,
                showSpinner: false
            )
        }
    }

    private func updateStatus(status: String, detail: String, progress: Float, animate: Bool, showSpinner: Bool) {
        _ = animate
        statusLabel?.text = status
        detailLabel?.text = detail
        statusProgressView?.setProgress(max(0, min(1, progress)), animated: false)

        if showSpinner {
            statusSpinner?.startAnimating()
        } else {
            statusSpinner?.stopAnimating()
        }
    }

    private func startIndeterminateProgress(status: String, detail: String) {
        statusLabel?.text = status
        detailLabel?.text = detail
        statusSpinner?.startAnimating()
        statusProgressView?.setProgress(max(statusProgressView?.progress ?? 0, 0.02), animated: false)
    }

    private func stopIndeterminateProgress() {
        statusSpinner?.stopAnimating()
    }

    private func shouldStopLoading(newLastIndex: Int, previousIndex: Int, batchCount: Int) -> Bool {
        if newLastIndex < 0 { return true }
        if batchCount == 0 && newLastIndex == previousIndex { return true }
        return false
    }

    private static func loadSourcePriorityScores() -> [String: Int] {
        guard let stored = UserDefaults.standard.dictionary(forKey: sourcePriorityStorageKey) else {
            return [:]
        }
        var result: [String: Int] = [:]
        for (key, value) in stored {
            if let number = value as? NSNumber {
                result[key] = number.intValue
            } else if let intValue = value as? Int {
                result[key] = intValue
            } else if let text = value as? String, let intValue = Int(text) {
                result[key] = intValue
            }
        }
        return result
    }

    static func recordReadableSource(sourceUrl: String, delta: Int = 1) {
        let key = normalizedSourcePriorityKey(sourceUrl)
        guard !key.isEmpty else { return }
        var scores = loadSourcePriorityScores()
        let current = scores[key] ?? 0
        scores[key] = min(current + max(delta, 1), maxPriorityScore)
        UserDefaults.standard.set(scores, forKey: sourcePriorityStorageKey)
    }

    static func recordFailedSource(sourceUrl: String, delta: Int = 1) {
        let key = normalizedSourcePriorityKey(sourceUrl)
        guard !key.isEmpty else { return }
        var scores = loadSourcePriorityScores()
        let current = scores[key] ?? 0
        scores[key] = max(current - max(delta, 1), minPriorityScore)
        UserDefaults.standard.set(scores, forKey: sourcePriorityStorageKey)
    }

    private func saveSourcePriorityScores() {
        UserDefaults.standard.set(sourcePriorityScores, forKey: SourceListViewController.sourcePriorityStorageKey)
    }

    private static func normalizedSourcePriorityKey(_ sourceUrl: String) -> String {
        sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedSourcePriorityKey(_ sourceUrl: String) -> String {
        SourceListViewController.normalizedSourcePriorityKey(sourceUrl)
    }

    private func sourcePriorityScore(for source: SearchBook) -> Int {
        sourcePriorityScores[normalizedSourcePriorityKey(source.bookSourceUrl)] ?? 0
    }

    private func diagnosticPenalty(for source: SearchBook) -> Int {
        diagnosticPenaltyScores[normalizedSourcePriorityKey(source.bookSourceUrl)] ?? 0
    }

    private func effectivePriorityScore(for source: SearchBook) -> Int {
        sourcePriorityScore(for: source) - diagnosticPenalty(for: source)
    }

    private func boostSourcePriority(for source: SearchBook) {
        SourceListViewController.recordReadableSource(sourceUrl: source.bookSourceUrl)
        sourcePriorityScores = SourceListViewController.loadSourcePriorityScores()
        saveSourcePriorityScores()
    }

    private func penalizeSourcePriority(for source: SearchBook, delta: Int) {
        SourceListViewController.recordFailedSource(sourceUrl: source.bookSourceUrl, delta: delta)
        sourcePriorityScores = SourceListViewController.loadSourcePriorityScores()
        saveSourcePriorityScores()
    }

    private func reloadDiagnosticPenaltyScores() {
        let records = ReaderServerAPI.shared.getSourceDiagnostics()
        let now = Date().timeIntervalSince1970
        let cutoff24h = now - 24 * 60 * 60
        let cutoff7d = now - 7 * 24 * 60 * 60
        var result: [String: Int] = [:]

        for record in records {
            let key = normalizedSourcePriorityKey(record.sourceUrl)
            guard !key.isEmpty else { continue }

            let count = min(max(record.failureCount, 1), 6)
            let weight: Int
            if record.lastFailedAt >= cutoff24h {
                weight = 3
            } else if record.lastFailedAt >= cutoff7d {
                weight = 1
            } else {
                weight = 0
            }
            guard weight > 0 else { continue }
            result[key, default: 0] += count * weight
        }

        for (key, value) in result {
            result[key] = min(max(value, 0), 60)
        }
        diagnosticPenaltyScores = result
    }

    private func looksLikeComicSource(_ source: SearchBook) -> Bool {
        let candidates = [
            source.kind ?? "",
            source.originName ?? "",
            source.name
        ]
        let keywords = ["漫画", "comic", "manhua", "manga", "acg", "动漫"]
        for raw in candidates {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !text.isEmpty else { continue }
            if keywords.contains(where: { text.contains($0) }) {
                return true
            }
        }
        return false
    }

    private func isCurrentSource(_ source: SearchBook) -> Bool {
        guard !currentSourceUrl.isEmpty else { return false }
        return normalizedSourcePriorityKey(source.bookSourceUrl) == currentSourceUrl
    }

    private func stateRank(for source: SearchBook) -> Int {
        switch validationStates[sourceKey(source)] ?? .pending {
        case .passed:
            return 0
        case .checking:
            return 1
        case .pending:
            return 2
        case .failed:
            return 3
        }
    }

    @discardableResult
    private func sortSourcesByPriorityAndState() -> Bool {
        guard !sources.isEmpty else { return false }

        let originalKeys = sources.map(sourceKey)
        let indexed = Array(sources.enumerated())
        let sorted = indexed.sorted { lhs, rhs in
            let lhsSource = lhs.element
            let rhsSource = rhs.element

            let lhsRank = stateRank(for: lhsSource)
            let rhsRank = stateRank(for: rhsSource)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            let lhsScore = effectivePriorityScore(for: lhsSource)
            let rhsScore = effectivePriorityScore(for: rhsSource)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }

            let lhsTime = lhsSource.time > 0 ? lhsSource.time : Int.max
            let rhsTime = rhsSource.time > 0 ? rhsSource.time : Int.max
            if lhsTime != rhsTime {
                return lhsTime < rhsTime
            }

            return lhs.offset < rhs.offset
        }
        sources = sorted.map(\.element)

        let newKeys = sources.map(sourceKey)
        return newKeys != originalKeys
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    // MARK: - UITableView

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sources.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SourceCell.identifier, for: indexPath) as! SourceCell
        let source = sources[indexPath.row]
        let state = validationStates[sourceKey(source)] ?? .pending
        let isPendingSelection = pendingSelectionKey == sourceKey(source)
        let priorityScore = sourcePriorityScore(for: source)
        let riskPenalty = diagnosticPenalty(for: source)
        let isComicSource = looksLikeComicSource(source)
        cell.configure(
            with: source,
            state: state,
            isPendingSelection: isPendingSelection,
            isCurrentSource: isCurrentSource(source),
            priorityScore: priorityScore,
            riskPenalty: riskPenalty,
            isComicReadingContext: isComicReadingContext,
            isComicSource: isComicSource
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let source = sources[indexPath.row]

        guard book != nil else {
            completeSelection(source)
            return
        }

        let key = sourceKey(source)
        let state = validationStates[key] ?? .pending

        switch state {
        case .passed:
            completeSelection(source)

        case .failed(let reason):
            showAlert("该书源暂不可读", reason)

        case .pending:
            pendingSelectionKey = key
            prioritizeValidation(for: key)
            updateStatus(
                status: "正在优先校验你选中的书源",
                detail: "校验通过后会自动开始换源",
                progress: statusProgressView?.progress ?? 0,
                animate: false,
                showSpinner: true
            )

        case .checking:
            pendingSelectionKey = key
            updateStatus(
                status: "正在校验你选中的书源",
                detail: "校验通过后会自动开始换源",
                progress: statusProgressView?.progress ?? 0,
                animate: false,
                showSpinner: true
            )
        }
    }
}

class SourceCell: UITableViewCell {
    static let identifier = "SourceCell"

    private let sourceNameLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.numberOfLines = 1
        return label
    }()

    private let bookInfoLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        return label
    }()

    private let sourceUrlLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabel
        label.numberOfLines = 1
        return label
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textAlignment = .right
        label.numberOfLines = 1
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        return label
    }()

    private let comicBadgeLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textAlignment = .center
        label.text = "漫"
        label.textColor = .systemTeal
        label.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.12)
        label.layer.cornerRadius = 6
        label.clipsToBounds = true
        label.isHidden = true
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        contentView.addSubview(sourceNameLabel)
        contentView.addSubview(bookInfoLabel)
        contentView.addSubview(sourceUrlLabel)
        contentView.addSubview(statusLabel)
        contentView.addSubview(comicBadgeLabel)

        sourceNameLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(12)
            make.leading.equalToSuperview().offset(16)
            make.trailing.lessThanOrEqualTo(statusLabel.snp.leading).offset(-8)
        }

        statusLabel.snp.makeConstraints { make in
            make.centerY.equalTo(sourceNameLabel)
            make.trailing.equalToSuperview().offset(-40)
            make.width.greaterThanOrEqualTo(66)
        }

        comicBadgeLabel.snp.makeConstraints { make in
            make.leading.equalTo(sourceNameLabel.snp.trailing).offset(6)
            make.centerY.equalTo(sourceNameLabel)
            make.width.equalTo(18)
            make.height.equalTo(12)
            make.trailing.lessThanOrEqualTo(statusLabel.snp.leading).offset(-6)
        }

        bookInfoLabel.snp.makeConstraints { make in
            make.top.equalTo(sourceNameLabel.snp.bottom).offset(4)
            make.leading.equalToSuperview().offset(16)
            make.trailing.equalToSuperview().offset(-16)
        }

        sourceUrlLabel.snp.makeConstraints { make in
            make.top.equalTo(bookInfoLabel.snp.bottom).offset(4)
            make.leading.equalToSuperview().offset(16)
            make.trailing.equalToSuperview().offset(-16)
            make.bottom.equalToSuperview().offset(-12)
        }

        accessoryType = .disclosureIndicator
        selectionStyle = .default
    }

    fileprivate func configure(
        with source: SearchBook,
        state: SourceValidationState,
        isPendingSelection: Bool,
        isCurrentSource: Bool,
        priorityScore: Int,
        riskPenalty: Int,
        isComicReadingContext: Bool,
        isComicSource: Bool
    ) {
        let sourceName: String
        if let originName = source.originName, !originName.isEmpty {
            sourceName = originName
        } else if let url = URL(string: source.bookSourceUrl), let host = url.host {
            sourceName = host
        } else {
            sourceName = source.bookSourceUrl
        }
        sourceNameLabel.text = isCurrentSource ? "当前 · \(sourceName)" : sourceName
        comicBadgeLabel.isHidden = !(isComicReadingContext && isComicSource)

        var info = source.name
        if !source.author.isEmpty {
            info += " - \(source.author)"
        }
        bookInfoLabel.text = info

        if let latestChapter = source.latestChapter, !latestChapter.isEmpty {
            sourceUrlLabel.text = "最新: \(latestChapter)"
        } else {
            sourceUrlLabel.text = source.bookUrl
        }

        switch state {
        case .pending:
            if isCurrentSource {
                statusLabel.text = "当前"
                statusLabel.textColor = .systemBlue
                statusLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
            } else if riskPenalty >= 6 {
                statusLabel.text = "风险\(min(riskPenalty, 99))"
                statusLabel.textColor = .systemRed
                statusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.08)
            } else if priorityScore > 0 {
                statusLabel.text = "优先\(min(priorityScore, 99))"
                statusLabel.textColor = .systemGreen
                statusLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.08)
            } else if priorityScore < 0 {
                statusLabel.text = "降权\(min(abs(priorityScore), 99))"
                statusLabel.textColor = .secondaryLabel
                statusLabel.backgroundColor = UIColor.systemGray5
            } else if source.time > 0 {
                statusLabel.text = source.time < 1000
                    ? "\(source.time)ms"
                    : String(format: "%.1fs", Double(source.time) / 1000.0)
                statusLabel.textColor = .secondaryLabel
                statusLabel.backgroundColor = .clear
            } else {
                statusLabel.text = "待校验"
                statusLabel.textColor = .secondaryLabel
                statusLabel.backgroundColor = .clear
            }
            accessoryType = .disclosureIndicator

        case .checking:
            statusLabel.text = isPendingSelection ? "校验中..." : "检测中"
            statusLabel.textColor = .systemBlue.withAlphaComponent(0.95)
            statusLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
            accessoryType = .none

        case .passed(let chapterCount):
            statusLabel.text = chapterCount > 0 ? "可读(\(chapterCount)章)" : "可读"
            statusLabel.textColor = .systemGreen
            statusLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.10)
            accessoryType = .disclosureIndicator

        case .failed:
            statusLabel.text = "不可读"
            statusLabel.textColor = .systemRed
            statusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.08)
            accessoryType = .none
        }
    }
}

import UIKit
import SnapKit

class BookSourceViewController: UIViewController {

    fileprivate struct BookSourceSubscription: Codable, Identifiable {
        var id: UUID = UUID()
        var name: String
        var url: String
        var createdAt: TimeInterval
        var lastUpdatedAt: TimeInterval?
        var lastResult: String?
    }

    fileprivate struct SourceImportResult {
        var added: Int = 0
        var updated: Int = 0
        var deduplicated: Int = 0
        var skippedInvalid: Int = 0

        var importedCount: Int {
            added + updated
        }
    }

    fileprivate struct SourceHealthCheckResult {
        var totalEnabled: Int = 0
        var checkedCount: Int = 0
        var skippedChecked: Int = 0
        var successCount: Int = 0
        var disabledCount: Int = 0
        var failedItems: [(name: String, reason: String)] = []
    }

    private var bookSources: [BookSource] = []
    private var serverSources: [BookSourceResponse] = []
    private var subscriptions: [BookSourceSubscription] = []
    private var parseModeChangedObserver: NSObjectProtocol?
    private let database = DatabaseManager.shared
    private let serverAPI = ReaderServerAPI.shared
    private let subscriptionsUserDefaultsKey = "book_source_subscriptions_v1"
    private let healthCheckedKeysUserDefaultsKey = "book_source_health_checked_keys_v1"
    private var checkedSourceKeys: Set<String> = []
    private var sourceFailureSummaryByKey: [String: SourceFailureSummary] = [:]
    private var failureRecordsBySourceKey: [String: [SourceDiagnosticRecord]] = [:]
    private let autoDisableRecentFailureThreshold = 3
    private let autoDisableTotalFailureThreshold = 8
    private let documentImportQueue = DispatchQueue(label: "cn.oily.booksource.import", qos: .userInitiated)
    
    private struct SourceFailureSummary {
        var totalFailures: Int = 0
        var recentFailures24h: Int = 0
        var lastFailedAt: TimeInterval = 0
        var latestReason: String = ""
    }
    
    private var isServerMode: Bool {
        return BookParseManager.shared.isServerMode
    }

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "SourceCell")
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 64
        return tv
    }()
    
    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(refreshSources), for: .valueChanged)
        return rc
    }()
    
    private lazy var emptyStateLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 14)
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        loadSubscriptions()
        loadHealthCheckMarks()
        setupUI()
        observeParseModeChanges()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadSources()
    }

    private func setupUI() {
        title = isServerMode ? "书源(服务器)" : "书源(本地解析)"
        view.backgroundColor = .systemBackground
        
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        tableView.refreshControl = refreshControl
        configureNavigationItems()
        updateEmptyState()
    }
    
    private func configureNavigationItems() {
        let refreshButton = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self,
            action: #selector(refreshSources)
        )
        
        guard !isServerMode else {
            navigationItem.rightBarButtonItems = [refreshButton]
            return
        }
        
        let addButton = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addSourceTapped)
        )
        let manageButton = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            style: .plain,
            target: self,
            action: #selector(showLocalManageActions)
        )
        navigationItem.rightBarButtonItems = [addButton, manageButton, refreshButton]
    }
    
    private func observeParseModeChanges() {
        parseModeChangedObserver = NotificationCenter.default.addObserver(
            forName: .bookParseModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.title = self?.isServerMode == true ? "书源(服务器)" : "书源(本地解析)"
            self?.configureNavigationItems()
            self?.loadSources()
        }
    }
    
    private func loadSources() {
        refreshFailureDiagnostics()
        if isServerMode {
            loadFromServer()
        } else {
            pruneHealthCheckMarks()
            bookSources = database.getAllBookSources()
            tableView.reloadData()
            refreshControl.endRefreshing()
            updateEmptyState()
        }
    }
    
    private func loadFromServer() {
        Task {
            do {
                let sources = try await serverAPI.getBookSources()
                await MainActor.run {
                    self.serverSources = sources
                    self.tableView.reloadData()
                    self.refreshControl.endRefreshing()
                    self.updateEmptyState()
                }
            } catch {
                await MainActor.run {
                    self.showAlert(title: "错误", message: "加载失败: \(error.localizedDescription)")
                    self.refreshControl.endRefreshing()
                    self.updateEmptyState()
                }
            }
        }
    }
    
    @objc private func refreshSources() {
        loadSources()
    }
    
    @objc private func showLocalManageActions() {
        guard !isServerMode else { return }
        
        let duplicateGroupCount = countDuplicateGroups()
        let duplicateActionTitle = duplicateGroupCount > 0
            ? "删除重复书源（\(duplicateGroupCount)组）"
            : "删除重复书源"
        
        let alert = UIAlertController(title: "本地书源管理", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "书源订阅", style: .default) { [weak self] _ in
            self?.showSubscriptionsManager()
        })
        alert.addAction(UIAlertAction(title: "检测书源并禁用失效项", style: .default) { [weak self] _ in
            self?.confirmSourceHealthCheck()
        })
        alert.addAction(UIAlertAction(title: "重置检测标记", style: .default) { [weak self] _ in
            self?.confirmResetSourceHealthCheckMarks()
        })
        alert.addAction(UIAlertAction(title: "查看失败统计", style: .default) { [weak self] _ in
            self?.showFailureDiagnosticsSummary()
        })
        alert.addAction(UIAlertAction(title: "按失败统计禁用异常书源", style: .destructive) { [weak self] _ in
            self?.confirmAutoDisableByDiagnostics()
        })
        alert.addAction(UIAlertAction(title: "清空失败统计", style: .default) { [weak self] _ in
            self?.confirmClearFailureDiagnostics()
        })
        alert.addAction(UIAlertAction(title: duplicateActionTitle, style: .default) { [weak self] _ in
            self?.confirmRemoveDuplicateSources()
        })
        alert.addAction(UIAlertAction(title: "清空全部本地书源", style: .destructive) { [weak self] _ in
            self?.confirmClearAllLocalSources()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.dropFirst().first
        }
        
        present(alert, animated: true)
    }

    @objc private func addSourceTapped() {
        guard !isServerMode else {
            showAlert(title: "提示", message: "服务器模式下不支持本地导入，请切换到本地解析")
            return
        }
        
        let alert = UIAlertController(title: "添加书源", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "添加示例书源(测试用)", style: .default) { [weak self] _ in
            self?.addDemoSources()
        })

        alert.addAction(UIAlertAction(title: "从URL导入", style: .default) { [weak self] _ in
            self?.showUrlImportDialog()
        })

        alert.addAction(UIAlertAction(title: "管理URL订阅", style: .default) { [weak self] _ in
            self?.showSubscriptionsManager()
        })

        alert.addAction(UIAlertAction(title: "从剪贴板导入", style: .default) { [weak self] _ in
            if let jsonString = UIPasteboard.general.string {
                self?.importSource(jsonString: jsonString)
            } else {
                self?.showAlert(title: "提示", message: "剪贴板为空")
            }
        })

        alert.addAction(UIAlertAction(title: "从文件导入", style: .default) { [weak self] _ in
            self?.importFromFile()
        })

        alert.addAction(UIAlertAction(title: "手动输入JSON", style: .default) { [weak self] _ in
            self?.showJsonInputDialog()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }

        present(alert, animated: true)
    }

    private func importFromFile() {
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = true
        present(documentPicker, animated: true)
    }

    private func showUrlImportDialog() {
        let alert = UIAlertController(title: "从URL导入书源", message: "请输入书源URL地址", preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "https://example.com/bookSource.json"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self] _ in
            if let urlString = alert.textFields?.first?.text, !urlString.isEmpty {
                self?.importSourceFromUrl(urlString: urlString)
            }
        })

        present(alert, animated: true)
    }

    private func showJsonInputDialog() {
        let alert = UIAlertController(title: "输入书源JSON", message: "请粘贴书源JSON内容", preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "请输入JSON内容"
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self] _ in
            if let jsonString = alert.textFields?.first?.text, !jsonString.isEmpty {
                self?.importSource(jsonString: jsonString)
            }
        })

        present(alert, animated: true)
    }

    private func showSubscriptionsManager() {
        guard !isServerMode else {
            showAlert(title: "提示", message: "服务器模式下不支持本地订阅")
            return
        }

        let vc = BookSourceSubscriptionViewController(subscriptions: subscriptions)
        vc.onSubscriptionsChanged = { [weak self] updated in
            guard let self else { return }
            self.subscriptions = updated
            self.saveSubscriptions()
        }
        vc.onUpdateSubscription = { [weak self] subscription in
            guard let self else {
                return SourceImportResult()
            }
            return try await self.updateSubscription(subscription)
        }
        vc.onRunHealthCheck = { [weak self] in
            guard let self else {
                return SourceHealthCheckResult()
            }
            return await self.performSourceHealthCheck()
        }
        navigationController?.pushViewController(vc, animated: true)
    }

    private func loadSubscriptions() {
        guard let data = UserDefaults.standard.data(forKey: subscriptionsUserDefaultsKey),
              let decoded = try? JSONDecoder().decode([BookSourceSubscription].self, from: data) else {
            subscriptions = []
            return
        }
        subscriptions = decoded
    }

    private func saveSubscriptions() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        UserDefaults.standard.set(data, forKey: subscriptionsUserDefaultsKey)
    }

    private func loadHealthCheckMarks() {
        guard let array = UserDefaults.standard.array(forKey: healthCheckedKeysUserDefaultsKey) as? [String] else {
            checkedSourceKeys = []
            return
        }
        checkedSourceKeys = Set(array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private func saveHealthCheckMarks() {
        UserDefaults.standard.set(Array(checkedSourceKeys), forKey: healthCheckedKeysUserDefaultsKey)
    }

    private func hasCheckedMark(for sourceUrl: String) -> Bool {
        let key = normalizedSourceKey(sourceUrl)
        return !key.isEmpty && checkedSourceKeys.contains(key)
    }

    private func clearHealthCheckMark(for sourceUrl: String) {
        let key = normalizedSourceKey(sourceUrl)
        guard !key.isEmpty else { return }
        checkedSourceKeys.remove(key)
    }

    private func pruneHealthCheckMarks() {
        let validKeys = Set(database.getAllBookSources().map { normalizedSourceKey($0.bookSourceUrl) }.filter { !$0.isEmpty })
        let oldCount = checkedSourceKeys.count
        checkedSourceKeys = checkedSourceKeys.intersection(validKeys)
        if checkedSourceKeys.count != oldCount {
            saveHealthCheckMarks()
        }
    }

    private func importSourceFromUrl(urlString: String) {
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized) else {
            showAlert(title: "错误", message: "无效的URL")
            return
        }

        let loadingAlert = UIAlertController(title: "正在导入...", message: nil, preferredStyle: .alert)
        present(loadingAlert, animated: true)

        Task {
            do {
                let data = try await downloadSourceData(from: url)
                let result = try importSourceData(data)
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        self.loadSources()
                        self.showAlert(
                            title: "导入完成",
                            message: self.importResultMessage(result)
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        self.showAlert(title: "错误", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func updateSubscription(_ subscription: BookSourceSubscription) async throws -> SourceImportResult {
        guard let url = URL(string: subscription.url) else {
            throw NSError(domain: "BookSourceSubscription", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "订阅地址无效"
            ])
        }
        let data = try await downloadSourceData(from: url)
        let result = try importSourceData(data)

        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index].lastUpdatedAt = Date().timeIntervalSince1970
            subscriptions[index].lastResult = importResultMessage(result)
            saveSubscriptions()
        }
        await MainActor.run {
            self.loadSources()
        }
        return result
    }

    private func downloadSourceData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "BookSourceImport", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "下载失败，请检查订阅地址"
            ])
        }
        guard !data.isEmpty else {
            throw NSError(domain: "BookSourceImport", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "订阅内容为空"
            ])
        }
        return data
    }

    private func importSourceData(_ data: Data) throws -> SourceImportResult {
        let decodedSources = try decodeImportedSources(from: data)
        guard !decodedSources.isEmpty else {
            throw NSError(domain: "BookSourceImport", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "未解析到有效书源"
            ])
        }
        return mergeAndSaveSources(decodedSources)
    }

    private func decodeImportedSources(from data: Data) throws -> [BookSource] {
        let decoder = JSONDecoder()
        if let sources = try? decoder.decode([BookSource].self, from: data) {
            return sources
        }
        if let source = try? decoder.decode(BookSource.self, from: data) {
            return [source]
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw NSError(domain: "BookSourceImport", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "无法解析JSON"
            ])
        }

        if let dict = object as? [String: Any] {
            let candidateKeys = ["bookSources", "sources", "data", "list", "result"]
            for key in candidateKeys {
                guard let array = dict[key] as? [[String: Any]] else { continue }
                let arrayData = try JSONSerialization.data(withJSONObject: array)
                if let decoded = try? decoder.decode([BookSource].self, from: arrayData), !decoded.isEmpty {
                    return decoded
                }
            }
        }

        throw NSError(domain: "BookSourceImport", code: -5, userInfo: [
            NSLocalizedDescriptionKey: "不支持的书源JSON格式"
        ])
    }

    private func mergeAndSaveSources(_ importedSources: [BookSource]) -> SourceImportResult {
        var result = SourceImportResult()
        var didChangeCheckMarks = false
        var existingByKey: [String: BookSource] = [:]
        for source in database.getAllBookSources() {
            existingByKey[normalizedSourceKey(source.bookSourceUrl)] = source
        }

        for raw in importedSources {
            guard var incoming = sanitizeImportedSource(raw) else {
                result.skippedInvalid += 1
                continue
            }
            let key = normalizedSourceKey(incoming.bookSourceUrl)
            guard !key.isEmpty else {
                result.skippedInvalid += 1
                continue
            }

            if let existing = existingByKey[key] {
                let merged = mergeSource(existing: existing, incoming: incoming)
                database.saveBookSource(merged)
                existingByKey[key] = merged
                if sourceHash(existing) == sourceHash(merged) {
                    continue
                }
                result.updated += 1
                if hasCheckedMark(for: merged.bookSourceUrl) {
                    clearHealthCheckMark(for: merged.bookSourceUrl)
                    didChangeCheckMarks = true
                }
            } else {
                if incoming.bookSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    incoming.bookSourceName = "订阅书源"
                }
                database.saveBookSource(incoming)
                existingByKey[key] = incoming
                result.added += 1
                if hasCheckedMark(for: incoming.bookSourceUrl) {
                    clearHealthCheckMark(for: incoming.bookSourceUrl)
                    didChangeCheckMarks = true
                }
            }
        }

        result.deduplicated = deduplicateSourcesSilently()
        if result.deduplicated > 0 {
            pruneHealthCheckMarks()
        } else if didChangeCheckMarks {
            saveHealthCheckMarks()
        }
        return result
    }

    private func sanitizeImportedSource(_ source: BookSource) -> BookSource? {
        var normalized = source
        normalized.bookSourceUrl = source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.bookSourceName = source.bookSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.bookSourceUrl.isEmpty else { return nil }
        if normalized.bookSourceName.isEmpty {
            if let host = URL(string: normalized.bookSourceUrl)?.host, !host.isEmpty {
                normalized.bookSourceName = host
            } else {
                normalized.bookSourceName = normalized.bookSourceUrl
            }
        }
        return normalized
    }

    private func mergeSource(existing: BookSource, incoming: BookSource) -> BookSource {
        var merged = existing
        merged.bookSourceName = pickNonEmpty(incoming.bookSourceName, fallback: existing.bookSourceName)
        merged.bookSourceGroup = pickOptionalNonEmpty(incoming.bookSourceGroup, fallback: existing.bookSourceGroup)
        merged.bookSourceType = incoming.bookSourceType != 0 ? incoming.bookSourceType : existing.bookSourceType
        merged.bookUrlPattern = pickOptionalNonEmpty(incoming.bookUrlPattern, fallback: existing.bookUrlPattern)
        merged.jsLib = pickOptionalNonEmpty(incoming.jsLib, fallback: existing.jsLib)
        merged.concurrentRate = pickOptionalNonEmpty(incoming.concurrentRate, fallback: existing.concurrentRate)
        merged.header = pickOptionalNonEmpty(incoming.header, fallback: existing.header)
        merged.loginUrl = pickOptionalNonEmpty(incoming.loginUrl, fallback: existing.loginUrl)
        merged.loginUi = pickOptionalNonEmpty(incoming.loginUi, fallback: existing.loginUi)
        merged.loginCheckJs = pickOptionalNonEmpty(incoming.loginCheckJs, fallback: existing.loginCheckJs)
        merged.coverDecodeJs = pickOptionalNonEmpty(incoming.coverDecodeJs, fallback: existing.coverDecodeJs)
        merged.exploreUrl = pickOptionalNonEmpty(incoming.exploreUrl, fallback: existing.exploreUrl)
        merged.searchUrl = pickOptionalNonEmpty(incoming.searchUrl, fallback: existing.searchUrl)
        merged.enabledCookieJar = incoming.enabledCookieJar ?? existing.enabledCookieJar
        merged.ruleSearch = incoming.ruleSearch ?? existing.ruleSearch
        merged.ruleExplore = incoming.ruleExplore ?? existing.ruleExplore
        merged.ruleBookInfo = incoming.ruleBookInfo ?? existing.ruleBookInfo
        merged.ruleToc = incoming.ruleToc ?? existing.ruleToc
        merged.ruleContent = incoming.ruleContent ?? existing.ruleContent
        return merged
    }

    private func pickNonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func pickOptionalNonEmpty(_ value: String?, fallback: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return fallback
        }
        return value
    }

    private func sourceHash(_ source: BookSource) -> String {
        var parts: [String] = []
        parts.append(source.bookSourceUrl)
        parts.append(source.bookSourceName)
        parts.append(source.bookSourceGroup ?? "")
        parts.append(String(source.bookSourceType))
        parts.append(source.bookUrlPattern ?? "")
        parts.append(source.searchUrl ?? "")
        parts.append(source.exploreUrl ?? "")
        parts.append(source.header ?? "")
        parts.append(source.loginUrl ?? "")
        parts.append(source.ruleSearch?.bookList ?? "")
        parts.append(source.ruleExplore?.bookList ?? "")
        parts.append(source.ruleBookInfo?.name ?? "")
        parts.append(source.ruleToc?.chapterList ?? "")
        parts.append(source.ruleContent?.content ?? "")
        return parts.joined(separator: "|")
    }

    private func deduplicateSourcesSilently() -> Int {
        let allSources = database.getAllBookSources()
        guard !allSources.isEmpty else { return 0 }

        let sortedSources = allSources.sorted { lhs, rhs in
            let leftScore = sourceQualityScore(lhs)
            let rightScore = sourceQualityScore(rhs)
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.bookSourceName < rhs.bookSourceName
        }

        var keptSourceURLs: Set<String> = []
        var keptURLKeys: Set<String> = []
        var keptNameKeys: Set<String> = []

        for source in sortedSources {
            let urlKey = normalizedSourceKey(source.bookSourceUrl)
            let nameKey = normalizedSourceNameKey(source.bookSourceName)
            let duplicatedByURL = !urlKey.isEmpty && keptURLKeys.contains(urlKey)
            let duplicatedByName = !nameKey.isEmpty && keptNameKeys.contains(nameKey)

            if duplicatedByURL || duplicatedByName {
                database.deleteBookSource(source.bookSourceUrl)
                continue
            }

            keptSourceURLs.insert(source.bookSourceUrl)
            if !urlKey.isEmpty { keptURLKeys.insert(urlKey) }
            if !nameKey.isEmpty { keptNameKeys.insert(nameKey) }
        }
        return max(allSources.count - keptSourceURLs.count, 0)
    }

    private func importResultMessage(_ result: SourceImportResult) -> String {
        var lines: [String] = []
        lines.append("新增: \(result.added)")
        lines.append("更新: \(result.updated)")
        if result.deduplicated > 0 {
            lines.append("去重移除: \(result.deduplicated)")
        }
        if result.skippedInvalid > 0 {
            lines.append("跳过无效: \(result.skippedInvalid)")
        }
        return lines.joined(separator: "\n")
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    private func importSource(jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else {
            showAlert(title: "错误", message: "无效的JSON格式")
            return
        }
        do {
            let result = try importSourceData(data)
            loadSources()
            showAlert(title: "导入完成", message: importResultMessage(result))
        } catch {
            showAlert(title: "错误", message: error.localizedDescription)
        }
    }
    
    private func confirmRemoveDuplicateSources() {
        let groups = countDuplicateGroups()
        if groups == 0 {
            showAlert(title: "提示", message: "未发现重复书源")
            return
        }
        
        let alert = UIAlertController(
            title: "删除重复书源",
            message: "检测到 \(groups) 组重复书源（URL或名称重复），将自动保留信息更完整的一条，其余删除。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除重复项", style: .destructive) { [weak self] _ in
            self?.removeDuplicateSources()
        })
        present(alert, animated: true)
    }
    
    private func removeDuplicateSources() {
        let allSources = database.getAllBookSources()
        if allSources.isEmpty {
            showAlert(title: "提示", message: "当前没有本地书源")
            return
        }

        let sortedSources = allSources.sorted { lhs, rhs in
            let leftScore = sourceQualityScore(lhs)
            let rightScore = sourceQualityScore(rhs)
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.bookSourceName < rhs.bookSourceName
        }

        var keptURLKeys: Set<String> = []
        var keptNameKeys: Set<String> = []
        var removeSet: Set<String> = []

        for source in sortedSources {
            let urlKey = normalizedSourceKey(source.bookSourceUrl)
            let nameKey = normalizedSourceNameKey(source.bookSourceName)
            let duplicatedByURL = !urlKey.isEmpty && keptURLKeys.contains(urlKey)
            let duplicatedByName = !nameKey.isEmpty && keptNameKeys.contains(nameKey)
            if duplicatedByURL || duplicatedByName {
                removeSet.insert(source.bookSourceUrl)
                continue
            }
            if !urlKey.isEmpty { keptURLKeys.insert(urlKey) }
            if !nameKey.isEmpty { keptNameKeys.insert(nameKey) }
        }

        if removeSet.isEmpty {
            showAlert(title: "提示", message: "未发现重复书源")
            return
        }
        
        for sourceUrl in removeSet {
            database.deleteBookSource(sourceUrl)
        }

        pruneHealthCheckMarks()
        loadSources()
        showAlert(title: "完成", message: "已删除 \(removeSet.count) 个重复书源")
    }
    
    private func confirmClearAllLocalSources() {
        let count = database.getAllBookSources().count
        if count == 0 {
            showAlert(title: "提示", message: "当前没有可清空的本地书源")
            return
        }
        
        let alert = UIAlertController(
            title: "清空本地书源",
            message: "将删除全部 \(count) 个本地书源。此操作不可撤销。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认清空", style: .destructive) { [weak self] _ in
            self?.clearAllLocalSources()
        })
        present(alert, animated: true)
    }
    
    private func clearAllLocalSources() {
        let allSources = database.getAllBookSources()
        for source in allSources {
            database.deleteBookSource(source.bookSourceUrl)
        }
        loadSources()
        showAlert(title: "完成", message: "已清空本地书源")
    }

    private func confirmSourceHealthCheck() {
        let enabledSources = database.getAllBookSources().filter { $0.enabled }
        let enabledCount = enabledSources.count
        guard enabledCount > 0 else {
            showAlert(title: "提示", message: "当前没有启用中的书源")
            return
        }
        let pendingCount = enabledSources.filter { !hasCheckedMark(for: $0.bookSourceUrl) }.count
        let skippedCount = enabledCount - pendingCount
        guard pendingCount > 0 else {
            showAlert(title: "提示", message: "启用书源都已检测过，已自动跳过。\n如需重新全量检测，请先重置检测标记。")
            return
        }

        let alert = UIAlertController(
            title: "检测书源",
            message: "启用书源: \(enabledCount)\n待检测: \(pendingCount)\n跳过已检测: \(skippedCount)\n\n检测失败会自动禁用。是否继续？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "开始检测", style: .default) { [weak self] _ in
            self?.runSourceHealthCheckWithHUD()
        })
        present(alert, animated: true)
    }

    private func confirmResetSourceHealthCheckMarks() {
        let checkedCount = checkedSourceKeys.count
        if checkedCount == 0 {
            showAlert(title: "提示", message: "当前没有检测标记")
            return
        }
        let alert = UIAlertController(
            title: "重置检测标记",
            message: "将清除 \(checkedCount) 个检测标记，后续会重新检测这些书源。是否继续？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认重置", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.checkedSourceKeys.removeAll()
            UserDefaults.standard.removeObject(forKey: self.healthCheckedKeysUserDefaultsKey)
            self.showAlert(title: "完成", message: "检测标记已重置")
        })
        present(alert, animated: true)
    }

    private func runSourceHealthCheckWithHUD() {
        let loading = UIAlertController(
            title: "书源检测中",
            message: "正在检测并禁用失效书源...",
            preferredStyle: .alert
        )
        present(loading, animated: true)

        Task { [weak self] in
            guard let self else { return }
            let result = await self.performSourceHealthCheck { progressText in
                loading.message = progressText
            }
            await MainActor.run {
                loading.dismiss(animated: true) {
                    self.showAlert(title: "书源检测结果", message: self.sourceHealthCheckResultMessage(result))
                }
            }
        }
    }

    private func performSourceHealthCheck(
        progress: ((String) -> Void)? = nil
    ) async -> SourceHealthCheckResult {
        let enabledSources = database.getAllBookSources().filter { $0.enabled }
        var result = SourceHealthCheckResult()
        result.totalEnabled = enabledSources.count
        guard !enabledSources.isEmpty else { return result }

        let pendingSources = enabledSources.filter { !hasCheckedMark(for: $0.bookSourceUrl) }
        result.checkedCount = pendingSources.count
        result.skippedChecked = enabledSources.count - pendingSources.count
        guard !pendingSources.isEmpty else { return result }

        let maxConcurrentChecks = min(24, max(1, pendingSources.count))
        var successCount = 0
        var failedResults: [(source: BookSource, reason: String)] = []
        var completedCount = 0
        var iterator = pendingSources.makeIterator()
        var checkedKeysThisRound: Set<String> = []

        await withTaskGroup(of: (BookSource, (ok: Bool, reason: String)).self) { group in
            for _ in 0..<maxConcurrentChecks {
                guard let source = iterator.next() else { break }
                group.addTask {
                    let probe = await self.checkSourceHealth(source)
                    return (source, probe)
                }
            }

            while let (source, probeResult) = await group.next() {
                completedCount += 1
                let sourceKey = normalizedSourceKey(source.bookSourceUrl)
                if !sourceKey.isEmpty {
                    checkedKeysThisRound.insert(sourceKey)
                }

                if probeResult.ok {
                    successCount += 1
                } else {
                    failedResults.append((source, probeResult.reason))
                }

                if let progress {
                    await MainActor.run {
                        progress("并发检测中 \(completedCount)/\(pendingSources.count)\n最近完成: \(source.bookSourceName)")
                    }
                }

                if let nextSource = iterator.next() {
                    group.addTask {
                        let probe = await self.checkSourceHealth(nextSource)
                        return (nextSource, probe)
                    }
                }
            }
        }

        await MainActor.run {
            for item in failedResults {
                var updated = item.source
                updated.enabled = false
                database.saveBookSource(updated)
            }
            checkedSourceKeys.formUnion(checkedKeysThisRound)
            saveHealthCheckMarks()
            loadSources()
        }

        result.successCount = successCount
        result.disabledCount = failedResults.count
        result.failedItems = failedResults.map { ($0.source.bookSourceName, $0.reason) }
        return result
    }

    private func sourceHealthCheckResultMessage(_ result: SourceHealthCheckResult) -> String {
        if result.totalEnabled == 0 {
            return "当前没有启用中的书源。"
        }
        if result.checkedCount == 0 {
            return "本次无需检测。\n启用书源: \(result.totalEnabled)\n跳过已检测: \(result.skippedChecked)"
        }

        var message = "检测完成\n启用书源: \(result.totalEnabled)\n本次检测: \(result.checkedCount)\n跳过已检测: \(result.skippedChecked)\n成功: \(result.successCount)\n禁用: \(result.disabledCount)"
        if !result.failedItems.isEmpty {
            let previewLines = result.failedItems.prefix(6).map { "- \($0.name)（\($0.reason)）" }
            message += "\n\n失败详情:\n" + previewLines.joined(separator: "\n")
            if result.failedItems.count > 6 {
                message += "\n… 其余 \(result.failedItems.count - 6) 个请重新启用后单独测试"
            }
        }
        return message
    }

    private func showFailureDiagnosticsSummary() {
        refreshFailureDiagnostics()
        guard !sourceFailureSummaryByKey.isEmpty else {
            showAlert(title: "失败统计", message: "暂无失败记录")
            return
        }

        let localSourceMap = Dictionary(uniqueKeysWithValues: database.getAllBookSources().map {
            (normalizedSourceKey($0.bookSourceUrl), $0)
        })

        let sorted = sourceFailureSummaryByKey.sorted { lhs, rhs in
            if lhs.value.recentFailures24h != rhs.value.recentFailures24h {
                return lhs.value.recentFailures24h > rhs.value.recentFailures24h
            }
            if lhs.value.totalFailures != rhs.value.totalFailures {
                return lhs.value.totalFailures > rhs.value.totalFailures
            }
            return lhs.value.lastFailedAt > rhs.value.lastFailedAt
        }

        let lines = sorted.prefix(12).map { key, summary -> String in
            let name = localSourceMap[key]?.bookSourceName ?? key
            let recentText = summary.recentFailures24h > 0 ? "24h:\(summary.recentFailures24h)" : "24h:0"
            return "• \(name)\n  总失败:\(summary.totalFailures)  \(recentText)  最近:\(relativeTimeText(from: summary.lastFailedAt))\n  原因:\(summary.latestReason)"
        }

        var message = lines.joined(separator: "\n\n")
        if sorted.count > 12 {
            message += "\n\n… 还有 \(sorted.count - 12) 个失败书源"
        }
        let disableCandidates = diagnosticDisableCandidates()
        if !disableCandidates.isEmpty {
            message += "\n\n建议禁用: \(disableCandidates.count) 个高失败书源"
        }
        message += "\n\n自动禁用阈值：24小时≥\(autoDisableRecentFailureThreshold) 或总失败≥\(autoDisableTotalFailureThreshold)"

        let alert = UIAlertController(title: "失败统计", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        if !disableCandidates.isEmpty {
            alert.addAction(UIAlertAction(title: "一键禁用异常源", style: .destructive) { [weak self] _ in
                self?.autoDisableByDiagnostics(disableCandidates.map { $0.0 })
            })
        }
        present(alert, animated: true)
    }

    private func showFailureDiagnosticsForSource(name: String, sourceUrl: String) {
        refreshFailureDiagnostics()
        let key = normalizedSourceKey(sourceUrl)
        guard let records = failureRecordsBySourceKey[key], !records.isEmpty else {
            showAlert(title: "失败记录", message: "该书源暂无失败记录")
            return
        }

        let lines = records.prefix(8).map { record in
            let reason = friendlyFailureReason(record.reason)
            return "• \(record.endpoint) · \(reason)\n  次数:\(record.failureCount)  最近:\(relativeTimeText(from: record.lastFailedAt))"
        }
        var message = lines.joined(separator: "\n\n")
        if records.count > 8 {
            message += "\n\n… 还有 \(records.count - 8) 条记录"
        }
        showAlert(title: "\(name) 失败记录", message: message)
    }

    private func confirmAutoDisableByDiagnostics() {
        refreshFailureDiagnostics()
        let candidates = diagnosticDisableCandidates()

        guard !candidates.isEmpty else {
            showAlert(title: "按失败统计禁用", message: "暂无达到阈值的启用书源")
            return
        }

        let preview = candidates.prefix(8).map { source, summary in
            "• \(source.bookSourceName)（总:\(summary.totalFailures) / 24h:\(summary.recentFailures24h)）"
        }.joined(separator: "\n")

        var message = "将禁用 \(candidates.count) 个异常书源。\n\n\(preview)"
        if candidates.count > 8 {
            message += "\n… 其余 \(candidates.count - 8) 个"
        }
        message += "\n\n是否继续？"

        let alert = UIAlertController(title: "按失败统计禁用", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认禁用", style: .destructive) { [weak self] _ in
            self?.autoDisableByDiagnostics(candidates.map { $0.0 })
        })
        present(alert, animated: true)
    }

    private func diagnosticDisableCandidates() -> [(BookSource, SourceFailureSummary)] {
        let localSources = database.getAllBookSources()
        return localSources.compactMap { source -> (BookSource, SourceFailureSummary)? in
            guard source.enabled else { return nil }
            let key = normalizedSourceKey(source.bookSourceUrl)
            guard let summary = sourceFailureSummaryByKey[key] else { return nil }
            let shouldDisable = summary.recentFailures24h >= autoDisableRecentFailureThreshold
                || summary.totalFailures >= autoDisableTotalFailureThreshold
            return shouldDisable ? (source, summary) : nil
        }
    }

    private func autoDisableByDiagnostics(_ sources: [BookSource]) {
        guard !sources.isEmpty else { return }
        for source in sources {
            var updated = source
            updated.enabled = false
            database.saveBookSource(updated)
        }
        loadSources()
        showAlert(title: "完成", message: "已禁用 \(sources.count) 个高失败书源")
    }

    private func confirmClearFailureDiagnostics() {
        refreshFailureDiagnostics()
        guard !sourceFailureSummaryByKey.isEmpty else {
            showAlert(title: "清空失败统计", message: "当前没有可清空的失败记录")
            return
        }
        let alert = UIAlertController(
            title: "清空失败统计",
            message: "将删除当前所有失败统计记录。此操作不可撤销。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认清空", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.serverAPI.clearSourceDiagnostics()
            self.refreshFailureDiagnostics()
            self.tableView.reloadData()
            self.showAlert(title: "完成", message: "失败统计已清空")
        })
        present(alert, animated: true)
    }

    private struct SourceHealthProbeResult {
        let probe: String
        let ok: Bool
        let reason: String
    }

    private func checkSourceHealth(_ source: BookSource) async -> (ok: Bool, reason: String) {
        let searchAvailable = !(source.searchUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !(source.ruleSearch?.bookList?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let categoryURL = firstExploreCategoryURL(from: source.exploreUrl)
        let exploreAvailable = !(categoryURL?.isEmpty ?? true)

        guard searchAvailable || exploreAvailable else {
            return (false, "缺少可检测规则")
        }

        var latestReason = "规则解析失败"
        let maxAttempts = 2
        for attempt in 0..<maxAttempts {
            // 首轮给足超时；第二轮只做快速兜底，避免长尾拖慢整体完成时间。
            let timeout = attempt == 0 ? 12.0 : 6.0
            let probeResults = await runSourceHealthProbes(
                source: source,
                searchAvailable: searchAvailable,
                categoryURL: categoryURL,
                timeout: timeout
            )

            if probeResults.contains(where: { $0.ok }) {
                return (true, "")
            }

            let reasons = probeResults
                .map(\.reason)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let preferred = preferredFailureReason(from: reasons) {
                latestReason = preferred
            }

            if !shouldRetryHealthProbe(attempt: attempt, maxAttempts: maxAttempts, reasons: reasons) {
                break
            }
        }

        return (false, latestReason)
    }

    private func runSourceHealthProbes(
        source: BookSource,
        searchAvailable: Bool,
        categoryURL: String?,
        timeout: Double
    ) async -> [SourceHealthProbeResult] {
        await withTaskGroup(of: SourceHealthProbeResult.self, returning: [SourceHealthProbeResult].self) { group in
            if searchAvailable {
                group.addTask {
                    do {
                        let searchList = try await self.withTimeout(seconds: timeout) {
                            try await WebBook.shared.searchBook(keyword: "斗罗", source: source)
                        }
                        if !searchList.isEmpty {
                            return SourceHealthProbeResult(probe: "search", ok: true, reason: "")
                        }
                        return SourceHealthProbeResult(probe: "search", ok: false, reason: "搜索为空")
                    } catch is CancellationError {
                        return SourceHealthProbeResult(probe: "search", ok: false, reason: "请求取消")
                    } catch SourceCheckTimeoutError.timedOut {
                        return SourceHealthProbeResult(probe: "search", ok: false, reason: "请求超时")
                    } catch {
                        return SourceHealthProbeResult(
                            probe: "search",
                            ok: false,
                            reason: Self.sanitizeProbeReason(error.localizedDescription)
                        )
                    }
                }
            }

            if let categoryURL, !categoryURL.isEmpty {
                group.addTask {
                    do {
                        let exploreList = try await self.withTimeout(seconds: timeout) {
                            try await ReaderServerAPI.shared.explore(sourceUrl: source.bookSourceUrl, url: categoryURL, page: 1)
                        }
                        if !exploreList.isEmpty {
                            return SourceHealthProbeResult(probe: "explore", ok: true, reason: "")
                        }
                        return SourceHealthProbeResult(probe: "explore", ok: false, reason: "发现为空")
                    } catch is CancellationError {
                        return SourceHealthProbeResult(probe: "explore", ok: false, reason: "请求取消")
                    } catch SourceCheckTimeoutError.timedOut {
                        return SourceHealthProbeResult(probe: "explore", ok: false, reason: "请求超时")
                    } catch {
                        return SourceHealthProbeResult(
                            probe: "explore",
                            ok: false,
                            reason: Self.sanitizeProbeReason(error.localizedDescription)
                        )
                    }
                }
            }

            var results: [SourceHealthProbeResult] = []
            while let result = await group.next() {
                results.append(result)
                if result.ok {
                    group.cancelAll()
                }
            }
            return results
        }
    }

    private func shouldRetryHealthProbe(attempt: Int, maxAttempts: Int, reasons: [String]) -> Bool {
        guard attempt + 1 < maxAttempts else { return false }
        guard !reasons.isEmpty else { return false }

        // 仅在疑似网络层或超时类失败时重试，减少无效重试造成的尾部变慢。
        let retryHints = [
            "请求超时",
            "请求失败",
            "网络",
            "timed out",
            "timeout",
            "cannot",
            "couldn"
        ]
        return reasons.contains { reason in
            let lower = reason.lowercased()
            return retryHints.contains(where: { lower.contains($0.lowercased()) })
        }
    }

    private func preferredFailureReason(from reasons: [String]) -> String? {
        if let timeout = reasons.first(where: { $0.contains("超时") }) {
            return timeout
        }
        if let network = reasons.first(where: { $0.contains("请求") || $0.lowercased().contains("network") }) {
            return network
        }
        return reasons.first
    }

    private func firstExploreCategoryURL(from exploreUrl: String?) -> String? {
        guard let raw = exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        if lower.hasPrefix("@js:") || lower.hasPrefix("@json:") || lower.hasPrefix("@java") {
            return nil
        }

        if raw.hasPrefix("[") || raw.hasPrefix("{") {
            guard let data = raw.data(using: .utf8),
                  let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            for item in jsonArray {
                if let url = (item["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !url.isEmpty {
                    return url
                }
            }
            return nil
        }

        let normalized = raw.replacingOccurrences(of: "\\n", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "::")
            if parts.count >= 2 {
                let url = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty { return url }
                continue
            }
            if trimmed.contains("://") || trimmed.hasPrefix("/") {
                return trimmed
            }
        }
        return nil
    }

    nonisolated private static func sanitizeProbeReason(_ reason: String) -> String {
        let cleaned = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "网络或规则异常" }
        if cleaned.count > 26 {
            return String(cleaned.prefix(26)) + "..."
        }
        return cleaned
    }

    private enum SourceCheckTimeoutError: Error {
        case timedOut
    }

    private func withTimeout<T>(
        seconds: Double,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let duration = max(seconds, 0.1)
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                throw SourceCheckTimeoutError.timedOut
            }

            guard let first = try await group.next() else {
                throw SourceCheckTimeoutError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
    
    private func refreshFailureDiagnostics() {
        let records = serverAPI.getSourceDiagnostics()
        var summaryMap: [String: SourceFailureSummary] = [:]
        var groupedRecords: [String: [SourceDiagnosticRecord]] = [:]
        let now = Date().timeIntervalSince1970
        let cutoff24h = now - 24 * 60 * 60
        
        for record in records {
            let key = normalizedSourceKey(record.sourceUrl)
            guard !key.isEmpty else { continue }
            
            var summary = summaryMap[key] ?? SourceFailureSummary()
            summary.totalFailures += max(record.failureCount, 1)
            if record.lastFailedAt >= cutoff24h {
                summary.recentFailures24h += max(record.failureCount, 1)
            }
            if record.lastFailedAt >= summary.lastFailedAt {
                summary.lastFailedAt = record.lastFailedAt
                summary.latestReason = friendlyFailureReason(record.reason)
            }
            summaryMap[key] = summary
            groupedRecords[key, default: []].append(record)
        }
        
        for (key, value) in groupedRecords {
            groupedRecords[key] = value.sorted { $0.lastFailedAt > $1.lastFailedAt }
        }
        
        sourceFailureSummaryByKey = summaryMap
        failureRecordsBySourceKey = groupedRecords
    }

    private func friendlyFailureReason(_ reason: String) -> String {
        if reason.contains("empty_after_refresh") { return "刷新后仍为空" }
        if reason.contains("decode_failed") { return "响应解析失败" }
        if reason.contains("request_failed") { return "请求失败" }
        if reason.contains("api_failed") { return "接口返回失败" }
        return reason
    }

    private func relativeTimeText(from timestamp: TimeInterval) -> String {
        guard timestamp > 0 else { return "未知" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }
    
    private func countDuplicateGroups() -> Int {
        var urlMap: [String: Int] = [:]
        var nameMap: [String: Int] = [:]
        for source in database.getAllBookSources() {
            let urlKey = normalizedSourceKey(source.bookSourceUrl)
            if !urlKey.isEmpty {
                urlMap[urlKey, default: 0] += 1
            }
            let nameKey = normalizedSourceNameKey(source.bookSourceName)
            if !nameKey.isEmpty {
                nameMap[nameKey, default: 0] += 1
            }
        }
        let urlGroups = urlMap.values.filter { $0 > 1 }.count
        let nameGroups = nameMap.values.filter { $0 > 1 }.count
        return urlGroups + nameGroups
    }
    
    private func normalizedSourceKey(_ sourceUrl: String) -> String {
        let trimmed = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        
        if let url = URL(string: decoded), let host = url.host {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let query = url.query?.lowercased() ?? ""
            if query.isEmpty {
                return "\(host.lowercased())/\(path.lowercased())"
            }
            return "\(host.lowercased())/\(path.lowercased())?\(query)"
        }
        
        if let url = URL(string: "https://\(decoded)"), let host = url.host {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let query = url.query?.lowercased() ?? ""
            if query.isEmpty {
                return "\(host.lowercased())/\(path.lowercased())"
            }
            return "\(host.lowercased())/\(path.lowercased())?\(query)"
        }
        
        return decoded
            .lowercased()
            .replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func normalizedSourceNameKey(_ sourceName: String) -> String {
        sourceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
    
    private func sourceQualityScore(_ source: BookSource) -> Int {
        var score = 0
        if source.enabled { score += 20 }
        if source.enabledExplore { score += 8 }
        if !(source.searchUrl?.isEmpty ?? true) { score += 8 }
        if !(source.exploreUrl?.isEmpty ?? true) { score += 8 }
        if source.ruleSearch != nil { score += 5 }
        if source.ruleExplore != nil { score += 5 }
        if source.ruleBookInfo != nil { score += 5 }
        if source.ruleToc != nil { score += 5 }
        if source.ruleContent != nil { score += 5 }
        return score
    }
    
    private func updateEmptyState() {
        let isEmpty = isServerMode ? serverSources.isEmpty : bookSources.isEmpty
        if isEmpty {
            if isServerMode {
                emptyStateLabel.text = "暂无服务器书源\n下拉刷新重试"
            } else {
                emptyStateLabel.text = "暂无本地书源\n点击右上角 + 导入书源"
            }
            tableView.backgroundView = emptyStateLabel
        } else {
            tableView.backgroundView = nil
        }
    }
    
    private func addDemoSources() {
        let alert = UIAlertController(
            title: "添加示例书源",
            message: "示例书源可能因网站变动而失效。建议从网络搜索获取最新的书源JSON导入。\n\n常用书源网站：\n- GitHub搜索 legieno\n- 阅读官方论坛\n\n是否继续添加示例？",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加笔趣阁", style: .default) { [weak self] _ in
            self?.addBiqugeSource()
        })
        
        present(alert, animated: true)
    }
    
    private func addBiqugeSource() {
        let demoSource = """
        {
            "bookSourceName": "笔趣阁",
            "bookSourceUrl": "https://www.xbiquge.so",
            "bookSourceGroup": "测试",
            "bookSourceType": 0,
            "enabled": true,
            "enabledExplore": true,
            "exploreUrl": "玄幻小说::/sort/1/\\n仙侠小说::/sort/2/\\n都市小说::/sort/3/\\n历史小说::/sort/4/\\n科幻小说::/sort/5/",
            "searchUrl": "/search.php?keyword={{key}}",
            "ruleSearch": {
                "bookList": ".result-list .result-game-item",
                "name": ".result-game-item-desc a",
                "author": ".result-game-item-info-tag span:nth-child(2)",
                "bookUrl": ".result-game-item-desc a@href",
                "coverUrl": "",
                "intro": ".result-game-item-desc"
            },
            "ruleExplore": {
                "bookList": ".novel-list .item",
                "name": ".title@text",
                "author": ".author@text",
                "bookUrl": "a@href",
                "coverUrl": "img@src",
                "intro": ".desc@text"
            },
            "ruleBookInfo": {
                "info": "#info",
                "name": "h1",
                "author": ".author@text",
                "coverUrl": "#fmimg img@src",
                "intro": "#intro",
                "chapterListUrl": "#list a@href",
                "chapterUrl": ""
            },
            "ruleToc": {
                "chapterList": "#list dl dd a",
                "chapterName": "text",
                "chapterUrl": "@href"
            },
            "ruleContent": {
                "content": "#content",
                "nextContentUrl": ".page-break a:last-child@href",
                "nextContentBtn": ""
            }
        }
        """
        
        importSource(jsonString: demoSource)
    }
    
    deinit {
        if let observer = parseModeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

extension BookSourceViewController: UITableViewDelegate, UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isServerMode ? serverSources.count : bookSources.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceCell", for: indexPath)
        
        if isServerMode {
            let source = serverSources[indexPath.row]
            let key = normalizedSourceKey(source.bookSourceUrl)
            let summary = sourceFailureSummaryByKey[key]
            var config = cell.defaultContentConfiguration()
            config.text = source.bookSourceName
            if let summary {
                config.secondaryText = "\(source.bookSourceUrl)\n失败\(summary.totalFailures)次 · 24h \(summary.recentFailures24h) · \(relativeTimeText(from: summary.lastFailedAt))"
                config.secondaryTextProperties.numberOfLines = 2
            } else {
                config.secondaryText = source.bookSourceUrl
                config.secondaryTextProperties.numberOfLines = 1
            }

            let isHighRisk = (summary?.recentFailures24h ?? 0) >= autoDisableRecentFailureThreshold
                || (summary?.totalFailures ?? 0) >= autoDisableTotalFailureThreshold
            if source.enabled && isHighRisk {
                config.image = UIImage(systemName: "exclamationmark.triangle.fill")
                config.imageProperties.tintColor = .systemOrange
            } else if source.enabled {
                config.image = UIImage(systemName: "checkmark.circle.fill")
                config.imageProperties.tintColor = .systemGreen
            } else {
                config.image = UIImage(systemName: "circle")
                config.imageProperties.tintColor = .secondaryLabel
            }

            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
        } else {
            let source = bookSources[indexPath.row]
            let key = normalizedSourceKey(source.bookSourceUrl)
            let summary = sourceFailureSummaryByKey[key]
            var config = cell.defaultContentConfiguration()
            config.text = source.bookSourceName
            if let summary {
                config.secondaryText = "\(source.bookSourceUrl)\n失败\(summary.totalFailures)次 · 24h \(summary.recentFailures24h) · \(relativeTimeText(from: summary.lastFailedAt))"
                config.secondaryTextProperties.numberOfLines = 2
            } else {
                config.secondaryText = source.bookSourceUrl
                config.secondaryTextProperties.numberOfLines = 1
            }

            let isHighRisk = (summary?.recentFailures24h ?? 0) >= autoDisableRecentFailureThreshold
                || (summary?.totalFailures ?? 0) >= autoDisableTotalFailureThreshold
            if source.enabled && isHighRisk {
                config.image = UIImage(systemName: "exclamationmark.triangle.fill")
                config.imageProperties.tintColor = .systemOrange
            } else if source.enabled {
                config.image = UIImage(systemName: "checkmark.circle.fill")
                config.imageProperties.tintColor = .systemGreen
            } else {
                config.image = UIImage(systemName: "circle")
                config.imageProperties.tintColor = .secondaryLabel
            }

            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        if isServerMode {
            let source = serverSources[indexPath.row]
            showServerSourceDetailMenu(source: source)
        } else {
            showSourceDetailMenu(source: bookSources[indexPath.row])
        }
    }
    
    private func showServerSourceDetailMenu(source: BookSourceResponse) {
        let alert = UIAlertController(title: source.bookSourceName, message: source.bookSourceUrl, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "查看失败记录", style: .default) { [weak self] _ in
            self?.showFailureDiagnosticsForSource(name: source.bookSourceName, sourceUrl: source.bookSourceUrl)
        })

        alert.addAction(UIAlertAction(title: "复制书源URL", style: .default) { _ in
            UIPasteboard.general.string = source.bookSourceUrl
        })
        
        alert.addAction(UIAlertAction(title: source.enabled ? "禁用" : "启用", style: .default) { [weak self] _ in
            Task {
                do {
                    let response = BookSourceResponse(
                        bookSourceUrl: source.bookSourceUrl,
                        bookSourceName: source.bookSourceName,
                        bookSourceGroup: source.bookSourceGroup,
                        enabled: !source.enabled,
                        exploreUrl: source.exploreUrl,
                        searchUrl: source.searchUrl,
                        header: source.header,
                        ruleSearch: source.ruleSearch,
                        ruleExplore: source.ruleExplore,
                        ruleBookInfo: source.ruleBookInfo,
                        ruleToc: source.ruleToc,
                        ruleContent: source.ruleContent
                    )
                    try await self?.serverAPI.saveBookSource(response)
                    await MainActor.run {
                        self?.loadSources()
                    }
                } catch {
                    await MainActor.run {
                        self?.showAlert(title: "错误", message: "操作失败: \(error.localizedDescription)")
                    }
                }
            }
        })

        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            Task {
                do {
                    try await self?.serverAPI.deleteBookSource(sourceUrl: source.bookSourceUrl)
                    await MainActor.run {
                        self?.loadSources()
                    }
                } catch {
                    await MainActor.run {
                        self?.showAlert(title: "错误", message: "删除失败: \(error.localizedDescription)")
                    }
                }
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(alert, animated: true)
    }

    private func showSourceDetailMenu(source: BookSource) {
        let alert = UIAlertController(title: source.bookSourceName, message: source.bookSourceUrl, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "查看失败记录", style: .default) { [weak self] _ in
            self?.showFailureDiagnosticsForSource(name: source.bookSourceName, sourceUrl: source.bookSourceUrl)
        })

        alert.addAction(UIAlertAction(title: "测试书源", style: .default) { [weak self] _ in
            let testVC = BookSourceTestViewController(bookSource: source)
            self?.navigationController?.pushViewController(testVC, animated: true)
        })

        alert.addAction(UIAlertAction(title: "复制书源URL", style: .default) { _ in
            UIPasteboard.general.string = source.bookSourceUrl
        })

        alert.addAction(UIAlertAction(title: "导出书源JSON", style: .default) { [weak self] _ in
            self?.exportSource(source: source)
        })

        alert.addAction(UIAlertAction(title: source.enabled ? "禁用" : "启用", style: .default) { [weak self] _ in
            var updatedSource = source
            updatedSource.enabled = !source.enabled
            self?.database.saveBookSource(updatedSource)
            self?.loadSources()
        })

        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.database.deleteBookSource(source.bookSourceUrl)
            self?.loadSources()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(alert, animated: true)
    }

    private func exportSource(source: BookSource) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(source)
            guard let jsonString = String(data: data, encoding: .utf8) else { return }

            let activityVC = UIActivityViewController(activityItems: [jsonString], applicationActivities: nil)
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            }
            present(activityVC, animated: true)
        } catch {
            showAlert(title: "错误", message: "导出失败")
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isServerMode else { return nil }
        guard indexPath.row < bookSources.count else { return nil }
        let source = bookSources[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            self?.database.deleteBookSource(source.bookSourceUrl)
            self?.loadSources()
            completion(true)
        }

        let toggleAction = UIContextualAction(style: .normal, title: source.enabled ? "禁用" : "启用") { [weak self] _, _, completion in
            var updatedSource = source
            updatedSource.enabled = !source.enabled
            self?.database.saveBookSource(updatedSource)
            self?.loadSources()
            completion(true)
        }
        toggleAction.backgroundColor = .systemBlue

        return UISwipeActionsConfiguration(actions: [deleteAction, toggleAction])
    }
}

extension BookSourceViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            importSourceFromFile(url)
        }
    }

    private func importSourceFromFile(_ url: URL) {
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
                let decodedSources = try self.decodeImportedSources(from: data)
                guard !decodedSources.isEmpty else {
                    throw NSError(
                        domain: "cn.oily.WFTVIOS.BookSourceImport",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "未解析到有效书源"]
                    )
                }
                DispatchQueue.main.async {
                    let result = self.mergeAndSaveSources(decodedSources)
                    self.loadSources()
                    self.showAlert(title: "导入完成", message: self.importResultMessage(result))
                }
            } catch {
                DispatchQueue.main.async {
                    self.showAlert(title: "错误", message: "读取文件失败: \(error.localizedDescription)")
                }
            }
        }
    }
}

private class BookSourceSubscriptionViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    typealias Subscription = BookSourceViewController.BookSourceSubscription
    typealias ImportResult = BookSourceViewController.SourceImportResult
    typealias HealthCheckResult = BookSourceViewController.SourceHealthCheckResult

    private var subscriptions: [Subscription]
    var onSubscriptionsChanged: (([Subscription]) -> Void)?
    var onUpdateSubscription: ((Subscription) async throws -> ImportResult)?
    var onRunHealthCheck: (() async -> HealthCheckResult)?

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.delegate = self
        tv.dataSource = self
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 66
        return tv
    }()

    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.text = "暂无订阅\n点击右上角添加 URL"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 14)
        return label
    }()

    init(subscriptions: [Subscription]) {
        self.subscriptions = subscriptions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "书源订阅"
        view.backgroundColor = .systemBackground
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addSubscriptionTapped)
        )
        updateEmptyState()
    }

    private func updateEmptyState() {
        tableView.backgroundView = subscriptions.isEmpty ? emptyLabel : nil
    }

    @objc private func addSubscriptionTapped() {
        let alert = UIAlertController(title: "添加URL订阅", message: "更新时将自动导入并去重", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com/bookSource.json"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "订阅名称（可选）"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self] _ in
            guard let self else { return }
            let rawURL = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawName = alert.textFields?.dropFirst().first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.addSubscription(url: rawURL, name: rawName)
        })
        present(alert, animated: true)
    }

    private func addSubscription(url rawURL: String, name rawName: String) {
        guard let url = URL(string: rawURL), url.scheme != nil else {
            showAlert(title: "错误", message: "请输入有效URL")
            return
        }
        let normalizedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedKey(for: normalizedURL)
        let displayName: String = {
            if !rawName.isEmpty { return rawName }
            return url.host ?? "订阅"
        }()

        if let idx = subscriptions.firstIndex(where: { normalizedKey(for: $0.url) == key }) {
            subscriptions[idx].url = normalizedURL
            subscriptions[idx].name = displayName
        } else {
            subscriptions.append(
                Subscription(
                    name: displayName,
                    url: normalizedURL,
                    createdAt: Date().timeIntervalSince1970,
                    lastUpdatedAt: nil,
                    lastResult: nil
                )
            )
        }
        persistChanges()
    }

    private func normalizedKey(for url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        return decoded
            .lowercased()
            .replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func persistChanges() {
        subscriptions.sort { lhs, rhs in
            let l = lhs.lastUpdatedAt ?? lhs.createdAt
            let r = rhs.lastUpdatedAt ?? rhs.createdAt
            return l > r
        }
        onSubscriptionsChanged?(subscriptions)
        tableView.reloadData()
        updateEmptyState()
    }

    private func runUpdate(for subscription: Subscription, completion: @escaping (Bool) -> Void) {
        guard let onUpdateSubscription else {
            completion(false)
            return
        }

        let loading = UIAlertController(title: "更新订阅", message: "正在拉取并导入书源...", preferredStyle: .alert)
        present(loading, animated: true)

        Task {
            do {
                let result = try await onUpdateSubscription(subscription)
                await MainActor.run {
                    if let idx = self.subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                        self.subscriptions[idx].lastUpdatedAt = Date().timeIntervalSince1970
                        self.subscriptions[idx].lastResult = "新增\(result.added) / 更新\(result.updated)"
                        self.persistChanges()
                    }
                    loading.dismiss(animated: true) {
                        self.showAlert(title: "更新完成", message: "新增: \(result.added)\n更新: \(result.updated)\n去重: \(result.deduplicated)")
                        completion(true)
                    }
                }
            } catch {
                await MainActor.run {
                    loading.dismiss(animated: true) {
                        self.showAlert(title: "更新失败", message: error.localizedDescription)
                        completion(false)
                    }
                }
            }
        }
    }

    private func runSourceHealthCheck(completion: @escaping (Bool) -> Void) {
        guard let onRunHealthCheck else {
            completion(false)
            return
        }

        let loading = UIAlertController(title: "检测书源", message: "正在检测并禁用无效书源...", preferredStyle: .alert)
        present(loading, animated: true)

        Task {
            let result = await onRunHealthCheck()
            await MainActor.run {
                loading.dismiss(animated: true) {
                    self.showAlert(title: "检测结果", message: self.healthCheckResultMessage(result))
                    completion(true)
                }
            }
        }
    }

    private func healthCheckResultMessage(_ result: HealthCheckResult) -> String {
        if result.totalEnabled == 0 {
            return "当前没有启用中的书源。"
        }
        if result.checkedCount == 0 {
            return "本次无需检测。\n启用书源: \(result.totalEnabled)\n跳过已检测: \(result.skippedChecked)"
        }

        var message = "检测完成\n启用书源: \(result.totalEnabled)\n本次检测: \(result.checkedCount)\n跳过已检测: \(result.skippedChecked)\n成功: \(result.successCount)\n禁用: \(result.disabledCount)"
        if !result.failedItems.isEmpty {
            let lines = result.failedItems.prefix(5).map { "- \($0.name)（\($0.reason)）" }
            message += "\n\n失败详情:\n" + lines.joined(separator: "\n")
            if result.failedItems.count > 5 {
                message += "\n… 其余 \(result.failedItems.count - 5) 个"
            }
        }
        return message
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        subscriptions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "SubscriptionCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let item = subscriptions[indexPath.row]
        var text = item.name
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = item.url
        }
        cell.textLabel?.text = text
        cell.textLabel?.numberOfLines = 1

        var detail = item.url
        if let lastUpdated = item.lastUpdatedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            detail += "\n上次更新: \(formatter.string(from: Date(timeIntervalSince1970: lastUpdated)))"
        }
        if let result = item.lastResult, !result.isEmpty {
            detail += "\n\(result)"
        }
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.numberOfLines = 3
        cell.accessoryType = .none
        return cell
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < subscriptions.count else { return nil }
        let item = subscriptions[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            self.subscriptions.removeAll { $0.id == item.id }
            self.persistChanges()
            completion(true)
        }

        let updateAction = UIContextualAction(style: .normal, title: "更新") { [weak self] _, _, completion in
            self?.runUpdate(for: item, completion: completion)
        }
        updateAction.backgroundColor = .systemBlue

        let checkAction = UIContextualAction(style: .normal, title: "检测") { [weak self] _, _, completion in
            self?.runSourceHealthCheck(completion: completion)
        }
        checkAction.backgroundColor = .systemTeal

        let config = UISwipeActionsConfiguration(actions: [deleteAction, updateAction, checkAction])
        config.performsFirstActionWithFullSwipe = false
        return config
    }
}

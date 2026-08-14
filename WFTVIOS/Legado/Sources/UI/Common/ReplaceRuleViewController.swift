import UIKit
import SnapKit

class ReplaceRuleViewController: UIViewController {

    private var replaceRules: [ReplaceRule] = []
    private var serverRules: [ReplaceRuleResponse] = []
    private let replaceRuleManager = ReplaceRuleManager.shared
    private let serverAPI = ReaderServerAPI.shared
    private let documentImportQueue = DispatchQueue(label: "cn.oily.replacerule.import", qos: .userInitiated)
    private var isUsingServer: Bool { BookParseManager.shared.isServerMode }

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "RuleCell")
        tv.refreshControl = refreshControl
        return tv
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(refreshRules), for: .valueChanged)
        return control
    }()

    private lazy var emptyView: UILabel = {
        let label = UILabel()
        label.text = "暂无替换规则\n可添加规则来净化正文广告和噪音"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadRules()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadRules()
    }

    private func setupUI() {
        title = "替换净化"
        view.backgroundColor = .systemBackground

        if isUsingServer {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "arrow.clockwise"),
                style: .plain,
                target: self,
                action: #selector(refreshRules)
            )
        } else {
            let addButton = UIBarButtonItem(
                image: UIImage(systemName: "plus"),
                style: .plain,
                target: self,
                action: #selector(addRuleTapped)
            )
            let testButton = UIBarButtonItem(
                title: "测试",
                style: .plain,
                target: self,
                action: #selector(runGlobalRuleTest)
            )
            navigationItem.rightBarButtonItems = [addButton, testButton]

            navigationItem.leftBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up.on.square"),
                style: .plain,
                target: self,
                action: #selector(importExportTapped)
            )
        }

        view.addSubview(tableView)
        view.addSubview(emptyView)

        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        emptyView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(40)
        }
    }

    @objc private func refreshRules() {
        loadRules()
    }

    @objc private func importExportTapped() {
        let alert = UIAlertController(title: "导入/导出", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "规则测试", style: .default) { [weak self] _ in
            self?.runGlobalRuleTest()
        })

        alert.addAction(UIAlertAction(title: "从URL导入", style: .default) { [weak self] _ in
            self?.importFromURL()
        })

        alert.addAction(UIAlertAction(title: "从剪贴板导入", style: .default) { [weak self] _ in
            self?.importFromClipboard()
        })

        alert.addAction(UIAlertAction(title: "从文件导入", style: .default) { [weak self] _ in
            self?.importFromFile()
        })

        alert.addAction(UIAlertAction(title: "导出全部", style: .default) { [weak self] _ in
            self?.exportRules()
        })
        
        alert.addAction(UIAlertAction(title: "清空全部规则", style: .destructive) { [weak self] _ in
            self?.confirmClearAllRules()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.leftBarButtonItem
        }

        present(alert, animated: true)
    }

    private func loadRules() {
        refreshControl.beginRefreshing()

        if isUsingServer {
            loadRulesFromServer()
            return
        }

        replaceRules = replaceRuleManager.getAllRules().sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled && !rhs.isEnabled
            }
            let lhsGroup = lhs.groupName ?? ""
            let rhsGroup = rhs.groupName ?? ""
            if lhsGroup != rhsGroup {
                return lhsGroup.localizedCompare(rhsGroup) == .orderedAscending
            }
            return lhs.pattern.localizedCompare(rhs.pattern) == .orderedAscending
        }

        tableView.reloadData()
        emptyView.isHidden = !replaceRules.isEmpty
        refreshControl.endRefreshing()
    }

    private func loadRulesFromServer() {
        Task {
            do {
                let loadedRules = try await serverAPI.getReplaceRules()
                await MainActor.run {
                    self.serverRules = loadedRules.sorted { $0.order < $1.order }
                    self.tableView.reloadData()
                    self.emptyView.isHidden = !self.serverRules.isEmpty
                    self.refreshControl.endRefreshing()
                }
            } catch {
                await MainActor.run {
                    self.refreshControl.endRefreshing()
                    self.showAlert(title: "错误", message: "加载替换规则失败: \(error.localizedDescription)")
                    self.emptyView.isHidden = false
                }
            }
        }
    }

    @objc private func addRuleTapped() {
        showRuleEditor(rule: nil)
    }

    @objc private func runGlobalRuleTest() {
        presentRuleTest(rule: nil)
    }

    private func importFromURL() {
        let alert = UIAlertController(title: "从URL导入", message: "请输入规则文件地址", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "https://example.com/rules.json"
            textField.keyboardType = .URL
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self] _ in
            guard let self else { return }
            guard let urlString = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !urlString.isEmpty,
                  let url = URL(string: urlString) else {
                self.showAlert(title: "错误", message: "无效的URL")
                return
            }

            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let jsonString = String(data: data, encoding: .utf8) else {
                        await MainActor.run {
                            self.showAlert(title: "错误", message: "文件编码不支持")
                        }
                        return
                    }
                    self.importRulesInBackground(
                        rawText: jsonString,
                        emptyFallback: "未识别到可导入规则，请检查格式"
                    )
                } catch {
                    await MainActor.run {
                        self.showAlert(title: "错误", message: "导入失败: \(error.localizedDescription)")
                    }
                }
            }
        })

        present(alert, animated: true)
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string else {
            showAlert(title: "提示", message: "剪贴板为空")
            return
        }

        importRulesInBackground(rawText: text, emptyFallback: "未识别到可导入规则，请检查内容")
    }

    private func importFromFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText])
        picker.delegate = self
        present(picker, animated: true)
    }

    private func exportRules() {
        guard let jsonString = replaceRuleManager.exportRules(prettyPrinted: true) else {
            showAlert(title: "提示", message: "没有可导出的规则")
            return
        }

        let activityVC = UIActivityViewController(activityItems: [jsonString], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(activityVC, animated: true)
    }
    
    private func confirmClearAllRules() {
        let alert = UIAlertController(
            title: "清空规则",
            message: "将删除全部本地净化规则，此操作不可恢复。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.replaceRuleManager.deleteAllRules()
            self.loadRules()
            self.showAlert(title: "完成", message: "已清空全部净化规则")
        })
        present(alert, animated: true)
    }
    
    private func buildImportSummary(result: ReplaceRuleImportResult, emptyFallback: String) -> (title: String, message: String) {
        if result.importedCount > 0 && result.skippedJSCount > 0 {
            return (
                "成功",
                "已导入 \(result.importedCount) 条规则\n已跳过 \(result.skippedJSCount) 条不兼容规则（@js）"
            )
        }
        if result.importedCount > 0 {
            return ("成功", "已导入 \(result.importedCount) 条规则")
        }
        if result.skippedJSCount > 0 {
            return ("提示", "已跳过 \(result.skippedJSCount) 条不兼容规则（@js），未导入可用规则")
        }
        return ("提示", emptyFallback)
    }

    private func showRuleEditor(rule: ReplaceRule?) {
        let isEditing = rule != nil
        let alert = UIAlertController(
            title: isEditing ? "编辑规则" : "添加规则",
            message: "格式示例: 广告.*##\n作用域: 0全局 1简介 2正文",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "正则表达式"
            textField.text = rule?.pattern
        }

        alert.addTextField { textField in
            textField.placeholder = "替换内容（留空=删除匹配）"
            textField.text = rule?.replacement
        }

        alert.addTextField { textField in
            textField.placeholder = "分组（可选）"
            textField.text = rule?.groupName
        }

        alert.addTextField { textField in
            textField.placeholder = "作用域（0全局/1简介/2正文）"
            textField.keyboardType = .numberPad
            textField.text = String(rule?.scope ?? 0)
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            guard let self else { return }

            let pattern = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pattern.isEmpty else {
                self.showAlert(title: "错误", message: "请输入正则表达式")
                return
            }

            guard self.validateRegex(pattern) else {
                self.showAlert(title: "错误", message: "正则表达式无效，请检查语法")
                return
            }

            let replacement = alert.textFields?[1].text ?? ""
            let groupRaw = alert.textFields?[2].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let scopeRaw = alert.textFields?[3].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            let scope = min(max(Int(scopeRaw) ?? 0, 0), 2)

            var updated = rule ?? ReplaceRule()
            updated.pattern = pattern
            updated.replacement = replacement
            updated.groupName = groupRaw.isEmpty ? nil : groupRaw
            updated.scope = scope
            if rule == nil {
                updated.isEnabled = true
            }

            self.replaceRuleManager.saveRule(updated)
            self.loadRules()
        })

        present(alert, animated: true)
    }

    private func validateRegex(_ pattern: String) -> Bool {
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])) != nil
    }

    private func showRuleActions(_ rule: ReplaceRule) {
        let alert = UIAlertController(title: "规则操作", message: rule.pattern, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: rule.isEnabled ? "禁用" : "启用", style: .default) { [weak self] _ in
            self?.toggleRule(rule)
        })

        alert.addAction(UIAlertAction(title: "测试本条规则", style: .default) { [weak self] _ in
            self?.presentRuleTest(rule: rule)
        })

        alert.addAction(UIAlertAction(title: "编辑", style: .default) { [weak self] _ in
            self?.showRuleEditor(rule: rule)
        })

        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.deleteRule(rule)
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }

        present(alert, animated: true)
    }

    private func toggleRule(_ rule: ReplaceRule) {
        var updated = rule
        updated.isEnabled.toggle()
        replaceRuleManager.saveRule(updated)
        loadRules()
    }

    private func deleteRule(_ rule: ReplaceRule) {
        replaceRuleManager.deleteRule(rule.ruleId)
        loadRules()
    }

    private func presentRuleTest(rule: ReplaceRule?) {
        let title = rule == nil ? "规则测试" : "测试本条规则"
        let message = rule == nil ? "输入原文，系统会按已启用规则执行净化" : "输入测试文本，查看本条规则替换结果"
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "示例: 本章内容含广告推广词"
            textField.clearButtonMode = .whileEditing
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "开始测试", style: .default) { [weak self] _ in
            guard let self else { return }
            let input = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !input.isEmpty else {
                self.showAlert(title: "提示", message: "请输入测试文本")
                return
            }

            let output: String
            let resultTitle: String
            if let rule {
                output = self.testRule(rule, content: input)
                resultTitle = "单条规则测试"
            } else {
                ContentCleaner.shared.loadRules()
                output = ContentCleaner.shared.clean(content: input, scope: 2)
                resultTitle = "全局净化测试"
            }

            let vc = RuleTestResultViewController(
                titleText: resultTitle,
                originalText: input,
                resultText: output
            )
            self.navigationController?.pushViewController(vc, animated: true)
        })

        present(alert, animated: true)
    }

    private func testRule(_ rule: ReplaceRule, content: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: rule.pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return "正则表达式无效"
        }

        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: rule.replacement)
    }

    private func scopeLabel(_ scope: Int) -> String {
        switch scope {
        case 1: return "简介"
        case 2: return "正文"
        default: return "全局"
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

extension ReplaceRuleViewController: UITableViewDelegate, UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isUsingServer ? serverRules.count : replaceRules.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if isUsingServer {
            return "替换规则（服务器） · \(serverRules.count)"
        }
        return "替换规则 · \(replaceRules.count)"
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if isUsingServer {
            return "服务器模式仅支持查看，编辑请在服务端完成"
        }
        return "左上角可导入/导出；右上角“测试”可快速验证净化效果"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RuleCell", for: indexPath)
        var config = cell.defaultContentConfiguration()

        if isUsingServer {
            let rule = serverRules[indexPath.row]
            config.text = rule.rule
            config.secondaryText = rule.replacement.isEmpty ? "(删除匹配内容)" : "→ \(rule.replacement)"
            config.image = UIImage(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
            config.imageProperties.tintColor = rule.enabled ? .systemGreen : .secondaryLabel
            config.secondaryTextProperties.numberOfLines = 2
            cell.accessoryType = .none
        } else {
            let rule = replaceRules[indexPath.row]
            config.text = rule.pattern

            var secondary = rule.replacement.isEmpty ? "(删除匹配内容)" : "→ \(rule.replacement)"
            secondary += "  • 作用域: \(scopeLabel(rule.scope))"
            if let group = rule.groupName, !group.isEmpty {
                secondary += "  • 分组: \(group)"
            }
            config.secondaryText = secondary
            config.secondaryTextProperties.numberOfLines = 3
            config.image = UIImage(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
            config.imageProperties.tintColor = rule.isEnabled ? .systemGreen : .secondaryLabel
            cell.accessoryType = .disclosureIndicator
        }

        cell.contentConfiguration = config
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if isUsingServer {
            showAlert(title: "提示", message: "服务器模式下无法编辑，请前往服务器管理替换规则")
            return
        }

        let rule = replaceRules[indexPath.row]
        showRuleActions(rule)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isUsingServer else { return nil }

        let rule = replaceRules[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            self?.deleteRule(rule)
            completion(true)
        }

        let toggleAction = UIContextualAction(style: .normal, title: rule.isEnabled ? "禁用" : "启用") { [weak self] _, _, completion in
            self?.toggleRule(rule)
            completion(true)
        }
        toggleAction.backgroundColor = .systemBlue

        return UISwipeActionsConfiguration(actions: [deleteAction, toggleAction])
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isUsingServer else { return nil }

        let rule = replaceRules[indexPath.row]
        let testAction = UIContextualAction(style: .normal, title: "测试") { [weak self] _, _, completion in
            self?.presentRuleTest(rule: rule)
            completion(true)
        }
        testAction.backgroundColor = .systemOrange
        return UISwipeActionsConfiguration(actions: [testAction])
    }
}

extension ReplaceRuleViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        loadImportedRuleText(from: url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let rawText):
                self.importRulesInBackground(rawText: rawText, emptyFallback: "未识别到可导入规则，请检查文件格式")
            case .failure(let error):
                self.showAlert(title: "错误", message: "读取文件失败: \(error.localizedDescription)")
            }
        }
    }

    private func loadImportedRuleText(from url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        documentImportQueue.async {
            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                guard let rawText = String(data: data, encoding: .utf8) else {
                    throw NSError(
                        domain: "cn.oily.WFTVIOS.ReplaceRuleImport",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "文件编码不支持"]
                    )
                }
                DispatchQueue.main.async {
                    completion(.success(rawText))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func importRulesInBackground(rawText: String, emptyFallback: String) {
        documentImportQueue.async { [weak self] in
            guard let self else { return }
            let importResult = self.replaceRuleManager.importRulesDetailed(from: rawText)
            DispatchQueue.main.async {
                let summary = self.buildImportSummary(result: importResult, emptyFallback: emptyFallback)
                self.showAlert(title: summary.title, message: summary.message)
                self.loadRules()
            }
        }
    }
}

private final class RuleTestResultViewController: UIViewController {

    private let originalText: String
    private let resultText: String

    private lazy var textView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.alwaysBounceVertical = true
        tv.font = .systemFont(ofSize: 14)
        return tv
    }()

    init(titleText: String, originalText: String, resultText: String) {
        self.originalText = originalText
        self.resultText = resultText
        super.init(nibName: nil, bundle: nil)
        self.title = titleText
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

        let text = "【原文】\n\(originalText)\n\n【净化后】\n\(resultText)"
        textView.text = text
    }
}

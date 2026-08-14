import UIKit
import SnapKit

class RSSSourceViewController: UIViewController {

    private var rssSources: [RSSSource] = []
    private var serverRssSources: [RssSourceResponse] = []
    private let rssManager = RSSManager.shared
    private let serverAPI = ReaderServerAPI.shared
    
    private var isServerMode: Bool {
        return BookParseManager.shared.isServerMode
    }

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "SourceCell")
        return tv
    }()
    
    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(refreshSources), for: .valueChanged)
        return rc
    }()

    private lazy var emptyView: UILabel = {
        let label = UILabel()
        label.text = "暂无订阅源\n点击右上角添加RSS订阅源"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadSources()
    }

    private func setupUI() {
        title = "订阅管理"
        view.backgroundColor = .systemBackground

        if !isServerMode {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "plus"),
                style: .plain,
                target: self,
                action: #selector(addSourceTapped)
            )

            navigationItem.leftBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up.on.square"),
                style: .plain,
                target: self,
                action: #selector(importExportTapped)
            )
        }

        view.addSubview(tableView)
        view.addSubview(emptyView)
        tableView.refreshControl = refreshControl

        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        emptyView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(40)
        }
    }

    private func loadSources() {
        if isServerMode {
            loadFromServer()
        } else {
            rssSources = rssManager.getAllSources()
            tableView.reloadData()
            emptyView.isHidden = !rssSources.isEmpty
        }
    }
    
    private func loadFromServer() {
        Task {
            do {
                let sources = try await serverAPI.getRssSources()
                await MainActor.run {
                    self.serverRssSources = sources
                    self.tableView.reloadData()
                    self.emptyView.isHidden = !sources.isEmpty
                    self.refreshControl.endRefreshing()
                }
            } catch {
                await MainActor.run {
                    self.showAlert(title: "错误", message: "加载失败: \(error.localizedDescription)")
                    self.refreshControl.endRefreshing()
                }
            }
        }
    }
    
    @objc private func refreshSources() {
        loadSources()
    }

    @objc private func addSourceTapped() {
        let alert = UIAlertController(title: "添加订阅源", message: nil, preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "订阅源名称"
        }

        alert.addTextField { textField in
            textField.placeholder = "RSS链接"
            textField.keyboardType = .URL
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text, !name.isEmpty,
                  let url = alert.textFields?[1].text, !url.isEmpty else {
                return
            }

            var source = RSSSource()
            source.sourceName = name
            source.sourceUrl = url
            source.enabled = true
            source.customOrder = self?.rssSources.count ?? 0

            self?.rssManager.addSource(source)
            self?.loadSources()
        })

        present(alert, animated: true)
    }

    @objc private func importExportTapped() {
        let alert = UIAlertController(title: "导入/导出", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "从URL导入", style: .default) { [weak self] _ in
            self?.importFromUrl()
        })

        alert.addAction(UIAlertAction(title: "从剪贴板导入", style: .default) { [weak self] _ in
            self?.importFromClipboard()
        })

        alert.addAction(UIAlertAction(title: "导出全部", style: .default) { [weak self] _ in
            self?.exportSources()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.leftBarButtonItem
        }

        present(alert, animated: true)
    }

    private func importFromUrl() {
        let alert = UIAlertController(title: "从URL导入", message: "请输入订阅源URL", preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "https://example.com/feed.xml"
            textField.keyboardType = .URL
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self] _ in
            guard let urlString = alert.textFields?.first?.text, !urlString.isEmpty,
                  let url = URL(string: urlString) else {
                return
            }

            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let jsonString = String(data: data, encoding: .utf8) {
                        let count = RSSManager.shared.importFromJson(jsonString)
                        await MainActor.run { [weak self] in
                            self?.showAlert(title: "成功", message: "已导入 \(count) 个订阅源")
                            self?.loadSources()
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.showAlert(title: "错误", message: "导入失败")
                    }
                }
            }
        })

        present(alert, animated: true)
    }

    private func importFromClipboard() {
        guard let jsonString = UIPasteboard.general.string else {
            showAlert(title: "提示", message: "剪贴板为空")
            return
        }

        let count = rssManager.importFromJson(jsonString)
        showAlert(title: "成功", message: "已导入 \(count) 个订阅源")
        loadSources()
    }

    private func exportSources() {
        guard let jsonString = rssManager.exportToJson() else {
            showAlert(title: "提示", message: "没有可导出的订阅源")
            return
        }

        let activityVC = UIActivityViewController(activityItems: [jsonString], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = view
        }
        present(activityVC, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    private func showSourceDetail(_ source: RSSSource) {
        let alert = UIAlertController(title: source.sourceName, message: source.sourceUrl, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "刷新", style: .default) { [weak self] _ in
            self?.refreshSource(source)
        })

        alert.addAction(UIAlertAction(title: source.enabled ? "禁用" : "启用", style: .default) { [weak self] _ in
            var updated = source
            updated.enabled = !source.enabled
            self?.rssManager.updateSource(updated)
            self?.loadSources()
        })

        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.rssManager.deleteSource(source.sourceUrl)
            self?.loadSources()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(alert, animated: true)
    }

    private func refreshSource(_ source: RSSSource) {
        Task {
            let articles = await rssManager.fetchArticles(from: source)
            await MainActor.run {
                self.showAlert(title: "完成", message: "获取到 \(articles.count) 篇文章")
            }
        }
    }
}

extension RSSSourceViewController: UITableViewDelegate, UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isServerMode ? serverRssSources.count : rssSources.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SourceCell", for: indexPath)
        
        if isServerMode {
            let source = serverRssSources[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = source.title
            config.secondaryText = source.url
            config.image = UIImage(systemName: source.enabled ? "dot.radiowaves.up.and.down" : "circle")
            config.imageProperties.tintColor = source.enabled ? .systemBlue : .secondaryLabel
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
        } else {
            let source = rssSources[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = source.sourceName
            config.secondaryText = source.sourceUrl
            config.image = UIImage(systemName: source.enabled ? "dot.radiowaves.up.and.down" : "circle")
            config.imageProperties.tintColor = source.enabled ? .systemBlue : .secondaryLabel
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        if isServerMode {
            let source = serverRssSources[indexPath.row]
            showServerSourceMenu(source)
        } else {
            showSourceDetail(rssSources[indexPath.row])
        }
    }
    
    private func showServerSourceMenu(_ source: RssSourceResponse) {
        let alert = UIAlertController(title: source.title, message: source.url, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "查看文章", style: .default) { [weak self] _ in
            let vc = RssArticlesViewController(rssSource: source)
            self?.navigationController?.pushViewController(vc, animated: true)
        })
        
        alert.addAction(UIAlertAction(title: "复制URL", style: .default) { _ in
            UIPasteboard.general.string = source.url
        })

        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            Task {
                do {
                    try await self?.serverAPI.deleteRssSource(url: source.url)
                    await MainActor.run {
                        self?.loadSources()
                    }
                } catch {
                    await MainActor.run {
                        self?.showAlert(title: "错误", message: "删除失败")
                    }
                }
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if isServerMode {
            let source = serverRssSources[indexPath.row]
            let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
                Task {
                    do {
                        try await self?.serverAPI.deleteRssSource(url: source.url)
                        await MainActor.run {
                            self?.loadSources()
                        }
                    } catch {
                        await MainActor.run {
                            self?.showAlert(title: "错误", message: "删除失败")
                        }
                    }
                }
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [deleteAction])
        } else {
            let source = rssSources[indexPath.row]
            let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
                self?.rssManager.deleteSource(source.sourceUrl)
                self?.loadSources()
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [deleteAction])
        }
    }
}

import UIKit
import SnapKit

class SettingsViewController: UIViewController {

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        return tv
    }()

    private let sections = [
        ["服务器连接"],
        ["主题"],
        ["数据管理"],
        ["关于"]
    ]

    private let sectionTitles = ["阅读服务器", "显示", "其他", "其他"]

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        title = "设置"
        view.backgroundColor = .systemBackground

        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
}

extension SettingsViewController: UITableViewDelegate, UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sectionTitles[section]
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var cellTitle = sections[indexPath.section][indexPath.row]

        if indexPath.section == 3 && indexPath.row == 0 {
            cellTitle += " (\(LegadoThemeManager.shared.currentTheme.title))"
        }

        var config = cell.defaultContentConfiguration()
        config.text = cellTitle

        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            config.image = UIImage(systemName: "list.bullet.rectangle")
        case (1, 0):
            config.image = UIImage(systemName: "moon.fill")
        case (2, 0):
            config.image = UIImage(systemName: "externaldrive")
        case (3, 0):
            config.image = UIImage(systemName: "info.circle")
        default:
            break
        }

        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            let vc = ServerConnectViewController()
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)
        case (1, 0):
            showThemeSelector(at: indexPath)
        case (2, 0):
            showDataManagement(at: indexPath)
        case (3, 0):
            showAbout()
        default:
            break
        }
    }

    private func presentActionSheet(_ alert: UIAlertController, at indexPath: IndexPath) {
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
        }
        present(alert, animated: true)
    }

    private func showThemeSelector(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "主题", message: nil, preferredStyle: .actionSheet)
        
        let themes: [LegadoThemeManager.LegadoTheme] = [.system, .light, .dark]
        
        for theme in themes {
            let action = UIAlertAction(title: theme.title, style: .default) { [weak self] _ in
                LegadoThemeManager.shared.currentTheme = theme
                self?.tableView.reloadData()
            }
            if LegadoThemeManager.shared.currentTheme == theme {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentActionSheet(alert, at: indexPath)
    }

    private func showDataManagement(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "数据管理", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "导出书架", style: .default) { _ in
            self.exportBookshelf()
        })

        alert.addAction(UIAlertAction(title: "清空阅读历史", style: .destructive) { _ in
            self.clearHistory()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        presentActionSheet(alert, at: indexPath)
    }

    private func exportBookshelf() {
        let books = DatabaseManager.shared.getAllBooks()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        do {
            let data = try encoder.encode(books)
            guard let json = String(data: data, encoding: .utf8) else { return }

            let activityVC = UIActivityViewController(activityItems: [json], applicationActivities: nil)
            present(activityVC, animated: true)
        } catch {
            print("Export error: \(error)")
        }
    }

    private func clearHistory() {
        let alert = UIAlertController(title: "确认", message: "确定要清空阅读历史吗?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .destructive) { [weak self] _ in
            DatabaseManager.shared.clearAllHistory()
            let successAlert = UIAlertController(title: "完成", message: "阅读历史已清空", preferredStyle: .alert)
            successAlert.addAction(UIAlertAction(title: "确定", style: .default))
            self?.present(successAlert, animated: true)
        })
        present(alert, animated: true)
    }

    private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let alert = UIAlertController(title: "Legado阅读", message: "iOS版阅读器\n版本: \(version)\n\n基于 gedoor/legado 开发", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

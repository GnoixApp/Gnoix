import UIKit
import SnapKit

class ReaderSettingsViewController: UIViewController {

    private let engine: ReadBookEngine
    var onConfigChanged: (() -> Void)?

    private var readConfig: ReadConfig

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        return tv
    }()

    init(engine: ReadBookEngine) {
        self.engine = engine
        self.readConfig = engine.book?.readConfig ?? ReadConfig()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        title = "阅读设置"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(doneTapped))

        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    private func persistConfig() {
        engine.updateReadConfig(readConfig)
        onConfigChanged?()
    }
}

extension ReaderSettingsViewController: UITableViewDelegate, UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        return 4
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return 2
        case 2: return 3
        case 3: return 2
        default: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "字号"
        case 1: return "间距"
        case 2: return "翻页"
        case 3: return "显示"
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        cell.accessoryView = nil

        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                config.text = "字体大小"
                config.secondaryText = "\(readConfig.textSize)pt"
            } else {
                config.text = "粗体"
                let switchView = UISwitch()
                switchView.isOn = readConfig.bold
                switchView.addTarget(self, action: #selector(boldChanged(_:)), for: .valueChanged)
                cell.accessoryView = switchView
            }

        case 1:
            if indexPath.row == 0 {
                config.text = "行间距"
                config.secondaryText = String(format: "%.1f", readConfig.lineSpacing)
            } else {
                config.text = "段间距"
                config.secondaryText = String(format: "%.1f", readConfig.paragraphSpacing)
            }

        case 2:
            if indexPath.row == 0 {
                config.text = "翻页模式"
                config.secondaryText = PageMode(rawValue: readConfig.pageMode)?.title ?? "滚动"
            } else if indexPath.row == 1 {
                config.text = "简→繁"
                let switchView = UISwitch()
                switchView.isOn = readConfig.convertSimpToTrad
                switchView.addTarget(self, action: #selector(simpToTradChanged(_:)), for: .valueChanged)
                cell.accessoryView = switchView
            } else {
                config.text = "繁→简"
                let switchView = UISwitch()
                switchView.isOn = readConfig.convertTradToSimp
                switchView.addTarget(self, action: #selector(tradToSimpChanged(_:)), for: .valueChanged)
                cell.accessoryView = switchView
            }

        case 3:
            if indexPath.row == 0 {
                config.text = "保持亮屏"
                let switchView = UISwitch()
                switchView.isOn = readConfig.keepScreenOn
                switchView.addTarget(self, action: #selector(keepScreenOnChanged(_:)), for: .valueChanged)
                cell.accessoryView = switchView
            } else {
                config.text = "主题"
                config.secondaryText = getThemeName()
            }

        default:
            break
        }

        cell.contentConfiguration = config
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            showTextSizePicker(at: indexPath)
        case (1, 0):
            showLineSpacingPicker(at: indexPath)
        case (1, 1):
            showParagraphSpacingPicker(at: indexPath)
        case (2, 0):
            showPageModePicker(at: indexPath)
        case (3, 1):
            showThemePicker(at: indexPath)
        default:
            break
        }
    }

    private func getThemeName() -> String {
        switch readConfig.bgColor {
        case 0xFFEEEEEE: return "白天"
        case 0xFF333333: return "夜间"
        case 0xFFEFE0D5: return "护眼"
        default: return "自定义"
        }
    }

    @objc private func boldChanged(_ sender: UISwitch) {
        readConfig.bold = sender.isOn
        persistConfig()
    }

    @objc private func keepScreenOnChanged(_ sender: UISwitch) {
        readConfig.keepScreenOn = sender.isOn
        UIApplication.shared.isIdleTimerDisabled = sender.isOn
        persistConfig()
    }

    @objc private func simpToTradChanged(_ sender: UISwitch) {
        readConfig.convertSimpToTrad = sender.isOn
        if sender.isOn {
            readConfig.convertTradToSimp = false
        }
        tableView.reloadSections(IndexSet(integer: 2), with: .none)
        persistConfig()
    }

    @objc private func tradToSimpChanged(_ sender: UISwitch) {
        readConfig.convertTradToSimp = sender.isOn
        if sender.isOn {
            readConfig.convertSimpToTrad = false
        }
        tableView.reloadSections(IndexSet(integer: 2), with: .none)
        persistConfig()
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

    private func showPageModePicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "翻页模式", message: nil, preferredStyle: .actionSheet)

        for mode in PageMode.allCases {
            let isSelected = readConfig.pageMode == mode.rawValue
            let title = isSelected ? "✓ \(mode.title)" : mode.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.readConfig.pageMode = mode.rawValue
                self?.tableView.reloadData()
                self?.persistConfig()
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentActionSheet(alert, at: indexPath)
    }

    private func showTextSizePicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "字体大小", message: nil, preferredStyle: .actionSheet)

        for size in stride(from: 12, through: 32, by: 2) {
            alert.addAction(UIAlertAction(title: "\(size)pt", style: .default) { [weak self] _ in
                self?.readConfig.textSize = size
                self?.tableView.reloadData()
                self?.persistConfig()
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentActionSheet(alert, at: indexPath)
    }

    private func showLineSpacingPicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "行间距", message: nil, preferredStyle: .actionSheet)

        for spacing in stride(from: 1.0, through: 2.5, by: 0.25) {
            alert.addAction(UIAlertAction(title: String(format: "%.2f", spacing), style: .default) { [weak self] _ in
                self?.readConfig.lineSpacing = Float(spacing)
                self?.tableView.reloadData()
                self?.persistConfig()
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentActionSheet(alert, at: indexPath)
    }

    private func showParagraphSpacingPicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "段间距", message: nil, preferredStyle: .actionSheet)

        for spacing in stride(from: 1.0, through: 3.0, by: 0.25) {
            alert.addAction(UIAlertAction(title: String(format: "%.2f", spacing), style: .default) { [weak self] _ in
                self?.readConfig.paragraphSpacing = Float(spacing)
                self?.tableView.reloadData()
                self?.persistConfig()
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentActionSheet(alert, at: indexPath)
    }

    private func showThemePicker(at indexPath: IndexPath) {
        let alert = UIAlertController(title: "主题", message: nil, preferredStyle: .actionSheet)

        let themes: [(String, Int, Int)] = [
            ("白天", 0xFFEEEEEE, 0xFF333333),
            ("夜间", 0xFF333333, 0xFFEEEEEE),
            ("护眼", 0xFFEFE0D5, 0xFF5D4D3C)
        ]

        for (name, bg, text) in themes {
            alert.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                self?.readConfig.bgColor = bg
                self?.readConfig.textColor = text
                self?.tableView.reloadData()
                self?.persistConfig()
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentActionSheet(alert, at: indexPath)
    }
}

import UIKit
import SnapKit

class ChapterListViewController: UIViewController {

    private let engine: ReadBookEngine
    
    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "ChapterCell")
        return tv
    }()
    
    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.hidesWhenStopped = true
        return indicator
    }()
    
    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.text = "正在加载章节..."
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }()

    init(engine: ReadBookEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "目录"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .done, target: self, action: #selector(closeTapped))
        setupUI()
        setupObservers()
    }
    
    @objc private func closeTapped() {
        dismiss(animated: true)
    }
    
    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chaptersLoaded(_:)),
            name: NSNotification.Name("ChaptersLoaded"),
            object: nil
        )
    }
    
    @objc private func chaptersLoaded(_ notification: Notification) {
        if let loadedBookUrl = notification.userInfo?["bookUrl"] as? String {
            let currentBookUrl = engine.book?.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !currentBookUrl.isEmpty,
               loadedBookUrl.trimmingCharacters(in: .whitespacesAndNewlines) != currentBookUrl {
                return
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.loadingIndicator.stopAnimating()
            self?.tableView.reloadData()
            
            if self?.engine.chapters.isEmpty == true {
                self?.emptyLabel.text = "无法加载章节\n\n可能原因：\n• 服务器缺少对应书源\n• 书源配置不正确\n• 网络问题\n\n请检查服务器书源是否正确配置"
                self?.emptyLabel.isHidden = false
            } else {
                self?.emptyLabel.isHidden = true
            }
        }
    }

    private func setupUI() {
        title = "目录"
        view.backgroundColor = .systemBackground

        view.addSubview(tableView)
        view.addSubview(loadingIndicator)
        view.addSubview(emptyLabel)

        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        loadingIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        
        emptyLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(40)
        }

        if engine.chapters.isEmpty {
            loadingIndicator.startAnimating()
            emptyLabel.isHidden = false
        }

        let currentIndex = engine.currentChapterIndex
        if currentIndex > 0 && currentIndex < engine.chapters.count {
            tableView.scrollToRow(at: IndexPath(row: currentIndex, section: 0), at: .middle, animated: false)
        }
    }
}

extension ChapterListViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return engine.chapters.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ChapterCell", for: indexPath)
        let chapter = engine.chapters[indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = chapter.title

        if indexPath.row == engine.currentChapterIndex {
            config.textProperties.color = .systemBlue
            config.textProperties.font = .systemFont(ofSize: 16, weight: .medium)
        } else {
            config.textProperties.color = .label
            config.textProperties.font = .systemFont(ofSize: 15)
        }

        cell.contentConfiguration = config
        cell.selectionStyle = .default

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        engine.goToChapter(indexPath.row)
        navigationController?.popViewController(animated: true)
    }
}

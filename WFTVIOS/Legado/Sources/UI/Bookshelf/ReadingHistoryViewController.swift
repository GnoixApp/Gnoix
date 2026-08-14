import UIKit
import SnapKit

class ReadingHistoryViewController: UIViewController {

    private var historyBooks: [BookInfoResponse] = []
    
    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "HistoryCell")
        tv.rowHeight = 100
        return tv
    }()
    
    private lazy var emptyView: UILabel = {
        let label = UILabel()
        label.text = "暂无阅读历史"
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }()
    
    private lazy var loadingView: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadHistory()
    }
    
    private func setupUI() {
        title = "阅读历史"
        view.backgroundColor = .systemBackground
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "清空",
            style: .plain,
            target: self,
            action: #selector(clearHistory)
        )
        
        view.addSubview(tableView)
        view.addSubview(emptyView)
        view.addSubview(loadingView)
        
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        emptyView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        
        loadingView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
    }
    
    private func loadHistory() {
        guard ReaderServerAPI.shared.isLoggedIn else {
            showLoginAlert()
            return
        }
        
        loadingView.startAnimating()
        
        Task {
            do {
                let history = try await ReaderServerAPI.shared.getReadingHistory()
                await MainActor.run {
                    self.historyBooks = history
                    self.loadingView.stopAnimating()
                    self.emptyView.isHidden = !history.isEmpty
                    self.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.loadingView.stopAnimating()
                    self.showError(error.localizedDescription)
                }
            }
        }
    }
    
    @objc private func clearHistory() {
        let alert = UIAlertController(title: "清空阅读历史", message: "确定要清空所有阅读历史吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .destructive) { [weak self] _ in
            self?.historyBooks = []
            self?.tableView.reloadData()
            self?.emptyView.isHidden = false
        })
        present(alert, animated: true)
    }
    
    private func showLoginAlert() {
        let alert = UIAlertController(title: "提示", message: "请先连接服务器", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
    
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "错误", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

extension ReadingHistoryViewController: UITableViewDelegate, UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return historyBooks.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HistoryCell", for: indexPath)
        let book = historyBooks[indexPath.row]
        
        var config = cell.defaultContentConfiguration()
        config.text = book.name
        config.secondaryText = book.author
        config.image = UIImage(systemName: "book.closed")
        
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let book = historyBooks[indexPath.row]
        
        var bookModel = Book(bookUrl: book.bookUrl)
        bookModel.name = book.name
        bookModel.author = book.author
        bookModel.coverUrl = book.coverUrl
        bookModel.origin = book.sourceUrl ?? ""
        bookModel.originName = book.originName ?? ""
        
        let vc = BookInfoViewController(book: bookModel)
        navigationController?.pushViewController(vc, animated: true)
    }
}

import UIKit
import SnapKit

class RssArticlesViewController: UIViewController {

    private let rssSource: RssSourceResponse
    private var articles: [RssArticleResponse] = []
    private let serverAPI = ReaderServerAPI.shared
    
    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "ArticleCell")
        return tv
    }()
    
    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    init(rssSource: RssSourceResponse) {
        self.rssSource = rssSource
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadArticles()
    }

    private func setupUI() {
        title = rssSource.title
        view.backgroundColor = .systemBackground

        view.addSubview(tableView)
        view.addSubview(loadingIndicator)

        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        loadingIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
    }

    private func loadArticles() {
        loadingIndicator.startAnimating()
        
        Task {
            do {
                let result = try await serverAPI.getRssArticles(rssUrl: rssSource.url)
                await MainActor.run {
                    self.articles = result
                    self.loadingIndicator.stopAnimating()
                    self.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.loadingIndicator.stopAnimating()
                }
            }
        }
    }
}

extension RssArticlesViewController: UITableViewDelegate, UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return articles.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ArticleCell", for: indexPath)
        let article = articles[indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = article.title
        config.secondaryText = article.pubDate
        config.secondaryTextProperties.numberOfLines = 1
        config.secondaryTextProperties.color = .secondaryLabel

        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

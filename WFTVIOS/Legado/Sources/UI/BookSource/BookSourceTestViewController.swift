import UIKit
import SnapKit

class BookSourceTestViewController: UIViewController {

    private var bookSource: BookSource?

    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.alwaysBounceVertical = true
        return sv
    }()

    private lazy var contentView = UIView()

    private lazy var sourceNameLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 18, weight: .bold)
        return label
    }()

    private lazy var sourceUrlLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        return label
    }()

    private lazy var searchTextField: UITextField = {
        let tf = UITextField()
        tf.placeholder = "输入搜索关键词"
        tf.borderStyle = .roundedRect
        tf.returnKeyType = .search
        tf.delegate = self
        return tf
    }()

    private lazy var searchButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("测试搜索", for: .normal)
        btn.addTarget(self, action: #selector(testSearch), for: .touchUpInside)
        return btn
    }()

    private lazy var tocTestButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("测试目录", for: .normal)
        btn.addTarget(self, action: #selector(testToc), for: .touchUpInside)
        return btn
    }()

    private lazy var contentTestButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("测试正文", for: .normal)
        btn.addTarget(self, action: #selector(testContent), for: .touchUpInside)
        return btn
    }()

    private lazy var resultTextView: UITextView = {
        let tv = UITextView()
        tv.font = .systemFont(ofSize: 12)
        tv.isEditable = false
        tv.backgroundColor = .systemGray6
        tv.layer.cornerRadius = 8
        return tv
    }()

    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private lazy var loadingLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }()

    init(bookSource: BookSource) {
        self.bookSource = bookSource
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        configureWithBookSource()
    }

    private func setupUI() {
        title = "测试书源"
        view.backgroundColor = .systemBackground

        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.width.equalTo(scrollView)
        }

        contentView.addSubview(sourceNameLabel)
        contentView.addSubview(sourceUrlLabel)
        contentView.addSubview(searchTextField)
        contentView.addSubview(searchButton)
        contentView.addSubview(tocTestButton)
        contentView.addSubview(contentTestButton)
        contentView.addSubview(resultTextView)
        contentView.addSubview(loadingIndicator)
        contentView.addSubview(loadingLabel)

        sourceNameLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(20)
            make.leading.trailing.equalToSuperview().inset(16)
        }

        sourceUrlLabel.snp.makeConstraints { make in
            make.top.equalTo(sourceNameLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(16)
        }

        searchTextField.snp.makeConstraints { make in
            make.top.equalTo(sourceUrlLabel.snp.bottom).offset(20)
            make.leading.equalToSuperview().offset(16)
            make.trailing.equalTo(searchButton.snp.leading).offset(-8)
            make.height.equalTo(40)
        }

        searchButton.snp.makeConstraints { make in
            make.centerY.equalTo(searchTextField)
            make.trailing.equalToSuperview().offset(-16)
            make.width.equalTo(80)
        }

        tocTestButton.snp.makeConstraints { make in
            make.top.equalTo(searchTextField.snp.bottom).offset(16)
            make.leading.equalToSuperview().offset(16)
            make.width.equalTo(80)
        }

        contentTestButton.snp.makeConstraints { make in
            make.top.equalTo(searchTextField.snp.bottom).offset(16)
            make.leading.equalTo(tocTestButton.snp.trailing).offset(16)
            make.width.equalTo(80)
        }

        resultTextView.snp.makeConstraints { make in
            make.top.equalTo(tocTestButton.snp.bottom).offset(20)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(400)
            make.bottom.equalToSuperview().offset(-20)
        }

        loadingIndicator.snp.makeConstraints { make in
            make.center.equalTo(resultTextView)
        }

        loadingLabel.snp.makeConstraints { make in
            make.centerX.equalTo(resultTextView)
            make.top.equalTo(loadingIndicator.snp.bottom).offset(8)
        }
    }

    private func configureWithBookSource() {
        guard let source = bookSource else { return }
        sourceNameLabel.text = source.bookSourceName
        sourceUrlLabel.text = source.bookSourceUrl
    }

    private func showLoading(_ message: String) {
        loadingLabel.text = message
        loadingLabel.isHidden = false
        loadingIndicator.startAnimating()
        resultTextView.isHidden = true
    }

    private func hideLoading() {
        loadingLabel.isHidden = true
        loadingIndicator.stopAnimating()
        resultTextView.isHidden = false
    }

    private func showResult(_ text: String) {
        resultTextView.text = text
    }

    @objc private func testSearch() {
        guard let source = bookSource else { return }
        guard let keyword = searchTextField.text, !keyword.isEmpty else {
            showResult("请输入搜索关键词")
            return
        }

        showLoading("搜索中...")
        searchTextField.resignFirstResponder()

        Task {
            do {
                let results = try await WebBook.shared.searchBook(keyword: keyword, source: source)
                await MainActor.run {
                    self.hideLoading()
                    self.showResult("找到 \(results.count) 本书:\n\n" + results.prefix(10).enumerated().map { index, book in
                        "\(index + 1). \(book.name) - \(book.author)"
                    }.joined(separator: "\n"))
                }
            } catch {
                await MainActor.run {
                    self.hideLoading()
                    self.showResult("搜索失败: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func testToc() {
        guard let source = bookSource else { return }

        showLoading("获取目录中...")
        tocTestButton.isEnabled = false

        Task {
            do {
                let chapters = try await WebBook.shared.getChapterList(tocUrl: source.bookSourceUrl, bookUrl: source.bookSourceUrl, source: source)

                await MainActor.run {
                    self.hideLoading()
                    self.tocTestButton.isEnabled = true
                    self.showResult("获取到 \(chapters.count) 章:\n\n" + chapters.prefix(20).enumerated().map { index, chapter in
                        "\(index + 1). \(chapter.title)"
                    }.joined(separator: "\n"))
                }
            } catch {
                await MainActor.run {
                    self.hideLoading()
                    self.tocTestButton.isEnabled = true
                    self.showResult("获取目录失败: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func testContent() {
        guard let source = bookSource else { return }

        showLoading("获取正文中...")
        contentTestButton.isEnabled = false

        Task {
            do {
                let content = try await WebBook.shared.getContent(chapterUrl: source.bookSourceUrl, source: source)

                await MainActor.run {
                    self.hideLoading()
                    self.contentTestButton.isEnabled = true
                    var result = "标题: \(content.title)\n\n内容:\n"
                    result += String(content.content.prefix(500))
                    if content.content.count > 1000 {
                        result += "..."
                    }
                    self.showResult(result)
                }
            } catch {
                await MainActor.run {
                    self.hideLoading()
                    self.contentTestButton.isEnabled = true
                    self.showResult("获取正文失败: \(error.localizedDescription)")
                }
            }
        }
    }
}

extension BookSourceTestViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        testSearch()
        return true
    }
}

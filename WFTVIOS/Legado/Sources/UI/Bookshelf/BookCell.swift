import UIKit
import SnapKit
import Kingfisher

enum CoverImageLoader {
    static let options: KingfisherOptionsInfo = [
        .cacheOriginalImage,
        .keepCurrentImageWhileLoading,
        .transition(.fade(0.18)),
        .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(1)))
    ]
    private static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    static let defaultPlaceholder: UIImage? = {
        let size = CGSize(width: 120, height: 160)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor(red: 0.86, green: 0.92, blue: 0.99, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            cg.setFillColor(UIColor.white.withAlphaComponent(0.16).cgColor)
            cg.fillEllipse(in: CGRect(x: -36, y: -28, width: 128, height: 128))
            cg.fillEllipse(in: CGRect(x: 56, y: 78, width: 92, height: 92))

            let iconConfig = UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
            let icon = UIImage(systemName: "book.closed.fill", withConfiguration: iconConfig)?
                .withTintColor(.white.withAlphaComponent(0.86), renderingMode: .alwaysOriginal)
            let iconRect = CGRect(x: (size.width - 34) / 2, y: (size.height - 34) / 2 - 1, width: 34, height: 34)
            icon?.draw(in: iconRect)
        }
    }()

    @MainActor
    static func setImage(
        on imageView: UIImageView,
        url: URL?,
        placeholder: UIImage?,
        refererCandidates: [String] = []
    ) {
        imageView.kf.cancelDownloadTask()
        guard let url else {
            imageView.image = placeholder
            return
        }

        let modifier = requestModifier(for: url, refererCandidates: refererCandidates)
        var resolvedOptions = options
        if let modifier {
            resolvedOptions.append(.requestModifier(modifier))
        }

        imageView.kf.setImage(with: url, placeholder: placeholder, options: resolvedOptions) { result in
            switch result {
            case .success:
                break
            case .failure:
                guard modifier != nil else {
                    imageView.image = placeholder
                    return
                }
                // 兼容部分拒绝 Referer 的站点：失败后退化为无 Referer 再试一次。
                imageView.kf.setImage(with: url, placeholder: placeholder, options: options) { fallbackResult in
                    if case .failure = fallbackResult {
                        imageView.image = placeholder
                    }
                }
            }
        }
    }

    private static func requestModifier(for url: URL, refererCandidates: [String]) -> AnyModifier? {
        let referer = firstValidReferer(from: refererCandidates) ?? fallbackReferer(for: url)
        guard let referer, !referer.isEmpty else { return nil }

        return AnyModifier { request in
            var modified = request
            modified.setValue(referer, forHTTPHeaderField: "Referer")
            modified.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
            return modified
        }
    }

    private static func firstValidReferer(from candidates: [String]) -> String? {
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let normalized = normalizedURLString(from: trimmed) {
                return normalized
            }
        }
        return nil
    }

    private static func fallbackReferer(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)/"
    }

    private static func normalizedURLString(from raw: String) -> String? {
        if let url = URL(string: raw), url.scheme != nil, url.host != nil {
            return url.absoluteString
        }

        if !raw.contains("://"),
           let url = URL(string: "https://\(raw)"),
           url.host != nil {
            return url.absoluteString
        }

        return nil
    }
}

class BookCell: UICollectionViewCell {
    static let identifier = "BookCell"
    private static let defaultCoverPlaceholder = CoverImageLoader.defaultPlaceholder

    private let cardView: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 14
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.withAlphaComponent(0.08).cgColor
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.08
        view.layer.shadowRadius = 10
        view.layer.shadowOffset = CGSize(width: 0, height: 5)
        return view
    }()

    private let coverImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 10
        iv.backgroundColor = .secondarySystemFill
        return iv
    }()

    private let selectedMaskView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.17)
        view.layer.cornerRadius = 14
        view.isHidden = true
        return view
    }()

    private let selectedBadgeView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBlue
        view.layer.cornerRadius = 12
        view.layer.borderWidth = 1.5
        view.layer.borderColor = UIColor.white.cgColor
        view.isHidden = true
        return view
    }()

    private let selectedBadgeIcon: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "checkmark"))
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private let progressContainer: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.88)
        view.layer.cornerRadius = 11
        view.clipsToBounds = true
        return view
    }()

    private let progressLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        return label
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label
        label.numberOfLines = 2
        return label
    }()

    private let authorLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private var isCurrentListMode = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        contentView.backgroundColor = .clear

        contentView.addSubview(cardView)
        cardView.addSubview(coverImageView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(authorLabel)
        coverImageView.addSubview(progressContainer)
        progressContainer.addSubview(progressLabel)
        contentView.addSubview(selectedMaskView)
        contentView.addSubview(selectedBadgeView)
        selectedBadgeView.addSubview(selectedBadgeIcon)

        cardView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(1.5)
        }

        selectedMaskView.snp.makeConstraints { make in
            make.edges.equalTo(cardView)
        }

        selectedBadgeView.snp.makeConstraints { make in
            make.top.equalTo(cardView).offset(8)
            make.trailing.equalTo(cardView).offset(-8)
            make.width.height.equalTo(24)
        }

        selectedBadgeIcon.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(12)
        }

        progressContainer.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(4)
            make.trailing.equalToSuperview().offset(-4)
            make.height.equalTo(18)
            make.width.greaterThanOrEqualTo(40)
        }

        progressLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
        }

        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        authorLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        applyLayout(isListMode: false)
    }

    private func applyLayout(isListMode: Bool) {
        guard isCurrentListMode != isListMode || titleLabel.text == nil else { return }
        isCurrentListMode = isListMode

        if isListMode {
            coverImageView.snp.remakeConstraints { make in
                make.leading.top.bottom.equalTo(cardView)
                make.width.equalTo(82)
            }

            titleLabel.snp.remakeConstraints { make in
                make.top.equalTo(cardView).offset(12)
                make.leading.equalTo(coverImageView.snp.trailing).offset(12)
                make.trailing.equalTo(cardView).offset(-12)
            }

            authorLabel.snp.remakeConstraints { make in
                make.top.equalTo(titleLabel.snp.bottom).offset(6)
                make.leading.equalTo(titleLabel)
                make.trailing.equalTo(titleLabel)
                make.bottom.lessThanOrEqualTo(cardView).offset(-12)
            }

            coverImageView.layer.cornerRadius = cardView.layer.cornerRadius
            coverImageView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            coverImageView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            titleLabel.numberOfLines = 2
            titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
            authorLabel.font = .systemFont(ofSize: 12)
        } else {
            coverImageView.snp.remakeConstraints { make in
                make.top.leading.trailing.equalTo(cardView)
                make.height.equalTo(coverImageView.snp.width).multipliedBy(1.36)
            }

            titleLabel.snp.remakeConstraints { make in
                make.top.equalTo(coverImageView.snp.bottom).offset(6)
                make.leading.trailing.equalTo(cardView).inset(10)
            }

            authorLabel.snp.remakeConstraints { make in
                make.top.equalTo(titleLabel.snp.bottom).offset(2)
                make.leading.trailing.equalTo(titleLabel)
                make.bottom.equalTo(cardView).offset(-6)
            }

            coverImageView.layer.cornerRadius = cardView.layer.cornerRadius
            coverImageView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            coverImageView.layer.contentsRect = CGRect(x: 0, y: 0.04, width: 1, height: 0.96)
            titleLabel.numberOfLines = 1
            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            authorLabel.font = .systemFont(ofSize: 11)
        }
    }

    func setDisplayMode(_ isListMode: Bool) {
        applyLayout(isListMode: isListMode)
    }

    func setManagingState(isManaging: Bool, isSelected: Bool) {
        selectedMaskView.isHidden = !(isManaging && isSelected)
        selectedBadgeView.isHidden = !isManaging
        selectedBadgeView.backgroundColor = isSelected ? .systemBlue : UIColor.systemGray4
        cardView.layer.borderColor = isSelected
            ? UIColor.systemBlue.withAlphaComponent(0.45).cgColor
            : UIColor.separator.withAlphaComponent(0.08).cgColor
    }

    func configure(with book: Book, isListMode: Bool = false) {
        applyLayout(isListMode: isListMode)

        titleLabel.text = book.name
        authorLabel.text = book.author.isEmpty ? "未知作者" : book.author

        let chapterInfo = book.durChapterIndex
        let totalInfo = book.totalChapterNum
        if totalInfo > 0 && chapterInfo >= 0 {
            let percent = Int((CGFloat(chapterInfo + 1) / CGFloat(totalInfo)) * 100)
            progressLabel.text = isListMode ? "\(chapterInfo + 1)/\(totalInfo)" : "\(percent)%"
            progressContainer.isHidden = false
        } else {
            progressContainer.isHidden = true
            progressLabel.text = nil
        }

        let placeholder = Self.defaultCoverPlaceholder
        let coverURL = book.resolvedCoverURL()
        CoverImageLoader.setImage(
            on: coverImageView,
            url: coverURL,
            placeholder: placeholder,
            refererCandidates: [book.origin, book.tocUrl, book.bookUrl]
        )
        if coverURL == nil {
            setLocalFallbackIfNeeded(book: book)
        }
    }

    private func setLocalFallbackIfNeeded(book: Book) {
        guard FileManager.default.fileExists(atPath: book.bookUrl) else { return }
        let localURL = URL(fileURLWithPath: book.bookUrl)
        let symbol = localURL.pathExtension.lowercased() == "epub" ? "book.fill" : "doc.text.fill"
        coverImageView.image = UIImage(systemName: symbol)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverImageView.kf.cancelDownloadTask()
        coverImageView.image = Self.defaultCoverPlaceholder
        titleLabel.text = nil
        authorLabel.text = nil
        progressLabel.text = nil
        progressContainer.isHidden = true
        setManagingState(isManaging: false, isSelected: false)
    }
}

final class PaddingLabel: UILabel {
    private let insets: UIEdgeInsets

    init(insets: UIEdgeInsets) {
        self.insets = insets
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }
}

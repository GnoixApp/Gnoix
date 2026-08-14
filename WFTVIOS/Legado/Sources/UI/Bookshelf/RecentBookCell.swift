import UIKit
import SnapKit
import Kingfisher

class RecentBookCell: UICollectionViewCell {
    
    private let coverImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 6
        iv.backgroundColor = .secondarySystemFill
        return iv
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        contentView.addSubview(coverImageView)
        contentView.addSubview(titleLabel)
        
        coverImageView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(100)
        }
        
        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(coverImageView.snp.bottom).offset(4)
            make.leading.trailing.equalToSuperview()
        }
    }
    
    func configure(with book: Book) {
        titleLabel.text = book.name

        CoverImageLoader.setImage(
            on: coverImageView,
            url: book.resolvedCoverURL(),
            placeholder: CoverImageLoader.defaultPlaceholder,
            refererCandidates: [book.origin, book.tocUrl, book.bookUrl]
        )
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        coverImageView.kf.cancelDownloadTask()
        coverImageView.image = CoverImageLoader.defaultPlaceholder
    }
}

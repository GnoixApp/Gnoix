import UIKit
import SnapKit

class ThemePickerViewController: UIViewController {
    
    var selectedBgColor: Int = 0xFFEEEEEE
    var onThemeSelected: ((Int, Int) -> Void)?
    
    private let themes: [(name: String, bg: Int, text: Int)] = [
        ("白天", 0xFFEEEEEE, 0xFF333333),
        ("夜间", 0xFF1E1E1E, 0xFFCCCCCC),
        ("护眼", 0xFFEFE0D5, 0xFF5D4D3C),
        ("深灰", 0xFF2D2D2D, 0xFF888888),
        ("墨绿", 0xFF2F3F30, 0xFFB8C9B0),
        ("淡蓝", 0xFFE3F2FD, 0xFF1565C0),
        ("粉红", 0xFFFCE4EC, 0xFFC2185B),
        ("紫罗兰", 0xFFEDE7F6, 0xFF512DA8),
        ("咖啡", 0xFFEFEBE9, 0xFF4E342E),
        ("清新", 0xFFE8F5E9, 0xFF2E7D32),
        ("Safari白", 0xFFFAFAFA, 0xFF333333),
        ("Safari黄", 0xFFFFF8E1, 0xFF5D4037),
        ("Safari灰", 0xFFF5F5F5, 0xFF424242),
        ("Safari棕", 0xFFEFEBE9, 0xFF4E342E),
        ("Safari蓝", 0xFFE3F2FD, 0xFF1565C0),
        ("Sepia", 0xFFF4ECD8, 0xFF5B4636),
        ("黎明", 0xFFFFFDE7, 0xFF3E2723),
        ("黄昏", 0xFF3E2723, 0xFFEFEBE9),
        ("原野", 0xFFE8F5E9, 0xFF1B5E20),
        ("海洋", 0xFFE0F7FA, 0xFF006064),
        ("沙漠", 0xFFFFF3E0, 0xFFE65100),
        ("夜空", 0xFF0D1B2A, 0xFFB0BEC5),
        ("月白", 0xFFECEFF1, 0xFF263238),
        ("晨光", 0xFFFFF8E1, 0xFF8D6E63)
    ]
    
    private var themeMap: [Int: (name: String, bg: Int, text: Int)] = [:]
    
    override func viewDidLoad() {
        super.viewDidLoad()
        for theme in themes {
            themeMap[theme.bg] = theme
        }
        setupUI()
    }
    
    private func setupUI() {
        view.backgroundColor = .systemBackground
        
        let titleLabel = UILabel()
        titleLabel.text = "阅读主题"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(16)
            make.centerX.equalToSuperview()
            make.height.equalTo(24)
        }
        
        let gridView = createGridView()
        view.addSubview(gridView)
        gridView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().offset(-20)
        }
    }
    
    private func createGridView() -> UIView {
        let container = UIView()
        
        let itemWidth: CGFloat = (UIScreen.main.bounds.width - 32 - 40) / 5
        let itemHeight = itemWidth + 20
        let rows = (themes.count + 4) / 5
        
        container.snp.makeConstraints { make in
            make.height.equalTo(CGFloat(rows) * (itemHeight + 10))
        }
        
        for (index, theme) in themes.enumerated() {
            let row = index / 5
            let col = index % 5
            
            let itemView = createThemeItem(name: theme.name, bg: theme.bg, text: theme.text)
            container.addSubview(itemView)
            
            itemView.snp.makeConstraints { make in
                make.width.equalTo(itemWidth)
                make.height.equalTo(itemHeight)
                make.leading.equalToSuperview().offset(CGFloat(col) * (itemWidth + 10))
                make.top.equalToSuperview().offset(CGFloat(row) * (itemHeight + 10))
            }
        }
        
        return container
    }
    
    private func createThemeItem(name: String, bg: Int, text: Int) -> UIView {
        let container = UIView()
        
        let colorView = UIView()
        colorView.backgroundColor = UIColor(argb: bg)
        colorView.layer.cornerRadius = 6
        colorView.layer.borderWidth = selectedBgColor == bg ? 2 : 1
        colorView.layer.borderColor = selectedBgColor == bg ? UIColor.systemBlue.cgColor : UIColor.systemGray4.cgColor
        
        container.addSubview(colorView)
        colorView.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.centerX.equalToSuperview()
            make.width.equalToSuperview().offset(-4)
            make.height.equalTo(colorView.snp.width).multipliedBy(0.7)
        }
        
        let label = UILabel()
        label.text = "Aa"
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = UIColor(argb: text)
        label.textAlignment = .center
        
        colorView.addSubview(label)
        label.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        
        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textAlignment = .center
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.8
        
        container.addSubview(nameLabel)
        nameLabel.snp.makeConstraints { make in
            make.top.equalTo(colorView.snp.bottom).offset(4)
            make.leading.trailing.equalToSuperview()
        }
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(themeTapped(_:)))
        container.tag = Int(bg)
        container.addGestureRecognizer(tap)
        
        return container
    }
    
    @objc private func themeTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view else { return }
        let bgColor = view.tag
        
        print("Theme tapped, bgColor: \(bgColor)")
        
        if let theme = themeMap[bgColor] {
            print("Theme found: \(theme.name), bg: \(theme.bg), text: \(theme.text)")
            selectedBgColor = bgColor
            onThemeSelected?(theme.bg, theme.text)
            
            for subview in view.superview?.subviews ?? [] {
                if let colorView = subview.subviews.first(where: { $0 is UIView && $0.subviews.count > 0 }) {
                    colorView.layer.borderWidth = 1
                    colorView.layer.borderColor = UIColor.systemGray4.cgColor
                }
            }
            if let colorView = view.subviews.first {
                colorView.layer.borderWidth = 2
                colorView.layer.borderColor = UIColor.systemBlue.cgColor
            }
        }
    }
}

extension UIColor {
    convenience init(argb: Int) {
        var value = argb
        if value < 0 {
            value = Int(UInt32(bitPattern: Int32(value)))
        }
        let uint = UInt32(value)
        let alpha = CGFloat((uint >> 24) & 0xFF) / 255.0
        let red = CGFloat((uint >> 16) & 0xFF) / 255.0
        let green = CGFloat((uint >> 8) & 0xFF) / 255.0
        let blue = CGFloat(uint & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

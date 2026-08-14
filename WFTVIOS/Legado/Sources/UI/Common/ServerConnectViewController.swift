import UIKit
import SnapKit

class ServerConnectViewController: UIViewController {

    private lazy var modeSegment: UISegmentedControl = {
        let segment = UISegmentedControl(items: ["服务器API", "本地解析"])
        segment.selectedSegmentIndex = BookParseManager.shared.isServerMode ? 0 : 1
        segment.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        return segment
    }()

    private lazy var serverTextField: UITextField = {
        let tf = UITextField()
        tf.placeholder = "服务器地址，如 https://reader.oily.cn:7443#账号#密码"
        tf.borderStyle = .roundedRect
        tf.keyboardType = .URL
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        return tf
    }()

    private lazy var connectButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("保存", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        return button
    }()

    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 14)
        return label
    }()

    private let serverAPI = ReaderServerAPI.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadCurrentConfig()
    }

    private func setupUI() {
        title = "阅读服务器"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancelTapped))

        view.addSubview(modeSegment)
        view.addSubview(serverTextField)
        view.addSubview(connectButton)
        view.addSubview(statusLabel)

        modeSegment.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(20)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(32)
        }

        serverTextField.snp.makeConstraints { make in
            make.top.equalTo(modeSegment.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(44)
        }

        connectButton.snp.makeConstraints { make in
            make.top.equalTo(serverTextField.snp.bottom).offset(20)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(44)
        }

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(connectButton.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(16)
        }
    }

    private func loadCurrentConfig() {
        modeSegment.selectedSegmentIndex = BookParseManager.shared.isServerMode ? 0 : 1
        applyModeUI()

        guard BookParseManager.shared.isServerMode else {
            statusLabel.text = "当前解析模式: 本地解析"
            statusLabel.textColor = .systemGreen
            return
        }

        if ReaderServerAPI.shared.isConfigured {
            let baseUrl = serverAPI.configuredServerURL
            let username = serverAPI.configuredUsername
            let password = serverAPI.configuredPassword
            
            if !baseUrl.isEmpty && !username.isEmpty && !password.isEmpty {
                serverTextField.text = "\(baseUrl)#\(username)#\(password)"
            } else if !baseUrl.isEmpty {
                serverTextField.text = baseUrl
            }
            statusLabel.text = "当前服务器: \(baseUrl)"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.text = "未配置服务器"
            statusLabel.textColor = .secondaryLabel
        }
    }

    @objc private func modeChanged() {
        BookParseManager.shared.setServerMode(modeSegment.selectedSegmentIndex == 0)
        applyModeUI()
        loadCurrentConfig()
    }

    private func applyModeUI() {
        let isServerMode = modeSegment.selectedSegmentIndex == 0
        serverTextField.isHidden = !isServerMode
        connectButton.isHidden = !isServerMode
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func connectTapped() {
        guard modeSegment.selectedSegmentIndex == 0 else {
            BookParseManager.shared.setServerMode(false)
            statusLabel.text = "已切换到本地解析"
            statusLabel.textColor = .systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.dismiss(animated: true)
            }
            return
        }

        guard let input = serverTextField.text, !input.isEmpty else {
            statusLabel.text = "请输入服务器地址"
            statusLabel.textColor = .systemRed
            return
        }

        // 解析格式: https://reader.oily.cn:7443#账号#密码
        let parts = input.components(separatedBy: "#")
        
        var serverUrl: String
        var username: String
        var password: String
        
        if parts.count >= 3 {
            serverUrl = parts[0]
            username = parts[1]
            password = parts[2]
        } else if parts.count == 2 {
            serverUrl = parts[0]
            username = parts[1]
            password = ""
        } else {
            serverUrl = input
            username = ""
            password = ""
        }
        
        // 清理URL
        serverUrl = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !serverUrl.isEmpty else {
            statusLabel.text = "服务器地址格式不正确"
            statusLabel.textColor = .systemRed
            return
        }

        if username.isEmpty {
            BookParseManager.shared.setServerMode(true)
            serverAPI.configure(url: serverUrl)
            statusLabel.text = "已保存服务器地址"
            statusLabel.textColor = .systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.dismiss(animated: true)
            }
            return
        }

        serverAPI.configure(url: serverUrl, username: username, password: password)
        
        statusLabel.text = "正在登录..."
        statusLabel.textColor = .systemOrange
        connectButton.isEnabled = false
        
        // 执行登录
        Task {
            do {
                let response = try await serverAPI.login(username: username, password: password)
                
                await MainActor.run {
                    if response.isSuccess == true || response.ok == true || response.token != nil {
                        BookParseManager.shared.setServerMode(true)
                        self.statusLabel.text = "登录成功: \(username)"
                        self.statusLabel.textColor = .systemGreen
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.dismiss(animated: true)
                        }
                    } else {
                        self.statusLabel.text = "登录失败: \(response.errorMsg ?? "未知错误")"
                        self.statusLabel.textColor = .systemRed
                        self.connectButton.isEnabled = true
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusLabel.text = "登录失败: \(error.localizedDescription)"
                    self.statusLabel.textColor = .systemRed
                    self.connectButton.isEnabled = true
                }
            }
        }
    }
}

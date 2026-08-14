import UIKit
import SnapKit

class TTSPanelViewController: UIViewController {
    private static let verboseLoggingEnabled = false

    private func log(_ message: @autoclosure () -> String) {
        guard Self.verboseLoggingEnabled else { return }
        Swift.print(message())
    }

    private let engine: ReadBookEngine
    private var isPlaying = false
    private var paragraphs: [String] = []
    private var currentParagraphIndex = 0
    private var startParagraphIndex = 0
    private var isLoadingVoices = false
    private var ttsButton: UIButton?
    private var styleButton: UIButton?
    
    var onParagraphChanged: ((Int, String) -> Void)?
    var onChapterChanged: (() -> Void)?
    var onDismiss: (() -> Void)?
    
    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "语音朗读"
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        return label
    }()

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        button.tintColor = .systemGray3
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var prevButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        button.setTitle(" 上一段", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.tintColor = .label
        button.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var playButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .medium)
        button.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .systemBlue
        button.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var nextButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        button.setTitle("下一段 ", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.tintColor = .label
        button.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        return button
    }()
    
    private let progressLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        return label
    }()
    
    private lazy var voiceButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("选择语音", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.tintColor = .label
        button.addTarget(self, action: #selector(voiceTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var rateSlider: UISlider = {
        let slider = UISlider()
        slider.minimumValue = 0.3
        slider.maximumValue = 1.5
        slider.value = TTSService.shared.currentRate
        slider.addTarget(self, action: #selector(rateChanged), for: .valueChanged)
        return slider
    }()
    
    private let rateLabel: UILabel = {
        let label = UILabel()
        label.text = "语速"
        label.font = .systemFont(ofSize: 14)
        return label
    }()
    
    private let rateValueLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        return label
    }()
    
    private lazy var settingsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }()
    
    init(engine: ReadBookEngine, button: UIButton?, isTTSPlaying: Bool = false, startParagraphIndex: Int = 0) {
        self.engine = engine
        self.ttsButton = button
        self.isPlaying = isTTSPlaying
        self.currentParagraphIndex = startParagraphIndex
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        // 允许手势dismiss
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupRemoteCommands()
        
        // 加载内容
        if let content = engine.currentContent {
            paragraphs = splitIntoParagraphs(content.content)
            if paragraphs.isEmpty {
                paragraphs = [content.content]
            }
        }
        if currentParagraphIndex >= paragraphs.count {
            currentParagraphIndex = 0
        }
        
        // 加载语音配置
        loadVoices()
        
        // 只更新播放按钮状态，不触发任何回调
        updatePlayButton()
        
        // 如果需要开始播放
        if isPlaying {
            // TTS已经在播放，不需要做任何事，状态已经同步
        } else if startParagraphIndex > 0 && startParagraphIndex < paragraphs.count {
            // 从指定段落开始播放
            currentParagraphIndex = startParagraphIndex
            isPlaying = true
            playCurrentParagraph()
        }
    }
    
    private func setupRemoteCommands() {
        TTSService.shared.onNextParagraph = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.nextTapped()
            }
        }
        
        TTSService.shared.onPrevParagraph = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.prevTapped()
            }
        }
    }
    
    private func setupUI() {
        view.backgroundColor = .systemBackground
        
        view.addSubview(containerView)
        
        containerView.addSubview(titleLabel)
        containerView.addSubview(closeButton)
        containerView.addSubview(prevButton)
        containerView.addSubview(playButton)
        containerView.addSubview(nextButton)
        containerView.addSubview(progressLabel)
        containerView.addSubview(settingsStack)
        
        containerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(20)
            make.centerX.equalToSuperview()
        }
        
        closeButton.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.trailing.equalToSuperview().offset(-16)
            make.size.equalTo(30)
        }
        
        let controlsStack = UIStackView(arrangedSubviews: [prevButton, playButton, nextButton])
        controlsStack.axis = .horizontal
        controlsStack.alignment = .center
        controlsStack.distribution = .equalSpacing
        
        containerView.addSubview(controlsStack)
        controlsStack.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(30)
            make.centerX.equalToSuperview()
            make.width.equalTo(280)
        }
        
        progressLabel.snp.makeConstraints { make in
            make.top.equalTo(controlsStack.snp.bottom).offset(8)
            make.centerX.equalToSuperview()
        }
        
        settingsStack.snp.makeConstraints { make in
            make.top.equalTo(progressLabel.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        
        // 1. 语音行
        let voiceRow = UIStackView(arrangedSubviews: [voiceLabel, voiceButton])
        voiceRow.distribution = .equalSpacing
        // 新增：统一行高
        voiceRow.snp.makeConstraints { make in
            make.height.equalTo(30)
        }

        // 2. 风格行
        let styleLabel: UILabel = {
            let label = UILabel()
            label.text = "风格"
            label.font = .systemFont(ofSize: 14)
            return label
        }()

        styleButton = {
            let button = UIButton(type: .system)
            button.setTitle("无", for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14)
            button.tintColor = .label
            button.contentHorizontalAlignment = .trailing
            button.addTarget(self, action: #selector(styleTapped), for: .touchUpInside)
            return button
        }()

        let styleRow = UIStackView(arrangedSubviews: [styleLabel, styleButton!])
        styleRow.distribution = .equalSpacing
        styleButton!.snp.makeConstraints { $0.width.greaterThanOrEqualTo(100) }
        // 新增：统一行高
        styleRow.snp.makeConstraints { make in
            make.height.equalTo(30)
        }

        // 3. 语速行（核心修改：包装成容器）
        let rateContainer = UIStackView()
        rateContainer.axis = .vertical
        rateContainer.spacing = 4 // 语速标签和滑块的内部间距

        let rateRow = UIStackView(arrangedSubviews: [rateLabel, rateValueLabel])
        rateRow.distribution = .equalSpacing
        rateValueLabel.snp.makeConstraints { $0.width.equalTo(40) }
        // 新增：统一行高
        rateRow.snp.makeConstraints { make in
            make.height.equalTo(30)
        }

        // 将语速行和滑块添加到容器
        rateContainer.addArrangedSubview(rateRow)
        rateContainer.addArrangedSubview(rateSlider)

        // 统一settingsStack的子视图（替换原来的rateRow和rateSlider）
        settingsStack.spacing = 8 // 显式确认行间距
        settingsStack.addArrangedSubview(voiceRow)
        settingsStack.addArrangedSubview(styleRow)
        settingsStack.addArrangedSubview(rateContainer) // 关键替换

        updateRateLabel()
        updateStyleButton()
    }
    
    private func updateStyleButton() {
        let currentStyle = TTSService.shared.currentStyle
        styleButton?.setTitle(currentStyle.isEmpty ? "无" : currentStyle, for: .normal)
    }
    
    private var voiceLabel: UILabel = {
        let label = UILabel()
        label.text = "语音"
        label.font = .systemFont(ofSize: 14)
        return label
    }()
    
    private func loadContent() {
        if let chapter = engine.chapters[safe: engine.currentChapterIndex] {
            TTSService.shared.setChapterInfo(current: engine.currentChapterIndex, total: engine.chapters.count)
            TTSService.shared.setBookTitle(engine.book?.name ?? "小说朗读")
        }
        
        if let content = engine.currentContent {
            paragraphs = splitIntoParagraphs(content.content)
            if paragraphs.isEmpty {
                paragraphs = [content.content]
            }
            
            // 总是保持当前段落索引不变，让TTS继续从当前位置播放
            // 不要重置为0
            updateContentDisplay()
        }
        
        loadVoices()
    }
    
    private func loadVoices() {
        TTSService.shared.getHttpVoices { [weak self] voices in
            DispatchQueue.main.async {
                self?.voiceButton.setTitle(TTSService.shared.currentVoiceDisplayName, for: .normal)
                self?.updateStyleButton()
            }
        }
    }
    
    private func splitIntoParagraphs(_ text: String) -> [String] {
        var result: [String] = []
        
        let lines = text.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if !containsChinese(trimmed) { continue }
            
            if trimmed.count < 200 {
                result.append(trimmed)
            } else {
                var current = ""
                let words = trimmed.components(separatedBy: "。")
                for word in words {
                    if current.isEmpty {
                        current = word
                    } else if current.count + word.count < 200 {
                        current += "。" + word
                    } else {
                        if !current.isEmpty && containsChinese(current) {
                            result.append(current)
                        }
                        current = word
                    }
                }
                if !current.isEmpty && containsChinese(current) {
                    result.append(current)
                }
            }
        }
        
        return result
    }
    
    private func containsChinese(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0xF900...0xFAFF).contains(scalar.value) {
                return true
            }
        }
        return false
    }
    
    private func updateContentDisplay() {
        guard isViewLoaded && view.window != nil else {
            // View dismissed, still notify via TTSService callback
            if !paragraphs.isEmpty && currentParagraphIndex < paragraphs.count {
                TTSService.shared.onParagraphChanged?(currentParagraphIndex, paragraphs[currentParagraphIndex])
            }
            return
        }
        
        guard !paragraphs.isEmpty else {
            progressLabel.text = ""
            prevButton.isEnabled = false
            nextButton.isEnabled = false
            prevButton.alpha = 0.3
            nextButton.alpha = 0.3
            onParagraphChanged?(currentParagraphIndex, "")
            TTSService.shared.onParagraphChanged?(currentParagraphIndex, "")
            log("[TTSPanel] updateContentDisplay - empty, calling callbacks")
            return
        }
        
        let currentText = paragraphs[currentParagraphIndex]
        progressLabel.text = "\(currentParagraphIndex + 1) / \(paragraphs.count)"
        
        prevButton.isEnabled = currentParagraphIndex > 0
        nextButton.isEnabled = currentParagraphIndex < paragraphs.count - 1
        
        prevButton.alpha = prevButton.isEnabled ? 1.0 : 0.3
        nextButton.alpha = nextButton.isEnabled ? 1.0 : 0.3
        
        log("[TTSPanel] updateContentDisplay: index=\(currentParagraphIndex), text=\(currentText.prefix(20))")
        
        // 如果面板的isPlaying为true但TTS实际已停止，同步状态
        if isPlaying && !TTSService.shared.isPlaying {
            isPlaying = false
        }
        
        // 如果TTS正在播放中，不要触发段落变化回调
        if isPlaying && TTSService.shared.isPlaying {
            // TTS正在播放，只更新UI，不触发回调
            return
        }
        
        onParagraphChanged?(currentParagraphIndex, currentText)
        TTSService.shared.onParagraphChanged?(currentParagraphIndex, currentText)
    }
    
    private func updateUI() {
        updatePlayButton()
        updateRateLabel()
        
        voiceButton.setTitle(TTSService.shared.currentVoiceDisplayName, for: .normal)
    }
    
    private func updatePlayButton() {
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .medium)
        let imageName = isPlaying ? "pause.circle.fill" : "play.circle.fill"
        playButton.setImage(UIImage(systemName: imageName, withConfiguration: config), for: .normal)
        
        let buttonConfig = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        ttsButton?.setImage(UIImage(systemName: imageName, withConfiguration: buttonConfig), for: .normal)
    }
    
    private func updateRateLabel() {
        let rate = rateSlider.value
        var text = "正常"
        if rate < 0.4 { text = "慢" }
        else if rate < 0.6 { text = "正常" }
        else if rate < 0.9 { text = "较快" }
        else { text = "快速" }
        rateValueLabel.text = text
    }
    
    @objc private func closeTapped() {
        TTSService.shared.currentParagraphIndex = currentParagraphIndex
        if currentParagraphIndex < paragraphs.count {
            TTSService.shared.onParagraphChanged?(currentParagraphIndex, paragraphs[currentParagraphIndex])
        }
        TTSService.shared.stop()
        dismiss(animated: true)
        onDismiss?()
    }
    
    @objc private func playPauseTapped() {
        if isPlaying {
            TTSService.shared.pause()
            TTSService.shared.updateNowPlayingPlaybackState(isPlaying: false, rate: TTSService.shared.currentRate)
            isPlaying = false
        } else {
            if TTSService.shared.isPlaying {
                TTSService.shared.resume()
                TTSService.shared.updateNowPlayingPlaybackState(isPlaying: true, rate: TTSService.shared.currentRate)
            } else {
                playCurrentParagraph()
            }
        }
        updatePlayButton()
    }
    
    private func playCurrentParagraph() {
        guard !paragraphs.isEmpty else { return }
        
        TTSService.shared.currentParagraphIndex = currentParagraphIndex
        let text = paragraphs[currentParagraphIndex]
        
        TTSService.shared.onSpeechFinished = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isPlaying = false
                self.updatePlayButton()
                TTSService.shared.updateNowPlayingPlaybackState(isPlaying: false, rate: TTSService.shared.currentRate)
                
                if self.currentParagraphIndex < self.paragraphs.count - 1 {
                    self.currentParagraphIndex += 1
                    TTSService.shared.currentParagraphIndex = self.currentParagraphIndex
                    self.updateContentDisplay()
                    self.playCurrentParagraph()
                } else {
                    self.goToNextChapter()
                }
            }
        }
        
        TTSService.shared.speak(text: text) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.isPlaying = true
                    self?.updatePlayButton()
                    
                    let chapterTitle = self?.engine.chapters[safe: self?.engine.currentChapterIndex ?? 0]?.title ?? ""
                    let bookTitle = self?.engine.book?.name ?? "小说朗读"
                    let rate = TTSService.shared.currentRate
                    let paragraphIndex = self?.currentParagraphIndex ?? 0
                    let paragraphPreview = self?.paragraphs[safe: paragraphIndex].map { String($0.prefix(20)) } ?? ""
                    
                    TTSService.shared.setBookTitle(bookTitle)
                    TTSService.shared.updateNowPlayingInfo(
                        title: "第\(paragraphIndex + 1)段: \(paragraphPreview)...",
                        chapter: chapterTitle,
                        rate: rate
                    )
                    TTSService.shared.updateNowPlayingPlaybackState(isPlaying: true, rate: rate)
                    
                    if self?.currentParagraphIndex ?? 0 < (self?.paragraphs.count ?? 0) - 1 {
                        var textsToPrefetch: [String] = []
                        for i in 1...3 {
                            let nextIdx = (self?.currentParagraphIndex ?? 0) + i
                            if nextIdx < (self?.paragraphs.count ?? 0) {
                                if let nextText = self?.paragraphs[nextIdx] {
                                    textsToPrefetch.append(nextText)
                                }
                            }
                        }
                        if !textsToPrefetch.isEmpty {
                            TTSService.shared.prefetchAudio(texts: textsToPrefetch)
                        }
                    }
                    } else {
                    self?.isPlaying = false
                    self?.updatePlayButton()
                }
            }
        }
    }
    
    private func goToNextChapter() {
        if engine.currentChapterIndex < engine.chapters.count - 1 {
            let nextIndex = engine.currentChapterIndex + 1
            engine.goToChapter(nextIndex)
            onChapterChanged?()
            TTSService.shared.onChapterChanged?(engine.currentChapterIndex, engine.chapters.count)
            
            func tryPlayNextChapter(controller: TTSPanelViewController) {
                let content = controller.engine.currentContent
                log("goToNextChapter: currentContent url: \(content?.url ?? "nil")")
                
                if let content = content, !content.content.isEmpty {
                    controller.paragraphs = controller.splitIntoParagraphs(content.content)
                    if controller.paragraphs.isEmpty {
                        controller.paragraphs = [content.content]
                    }
                    controller.currentParagraphIndex = 0
                    controller.updateContentDisplay()
                    controller.updateUI()
                    
                    controller.isPlaying = true
                    controller.playCurrentParagraph()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        tryPlayNextChapter(controller: controller)
                    }
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                tryPlayNextChapter(controller: self)
            }
        } else {
            isPlaying = false
            updatePlayButton()
        }
    }
    
    @objc private func prevTapped() {
        if currentParagraphIndex > 0 {
            TTSService.shared.stop(notify: false)
            currentParagraphIndex -= 1
            TTSService.shared.currentParagraphIndex = currentParagraphIndex
            updateContentDisplay()
            if isPlaying {
                playCurrentParagraph()
            }
        } else if engine.currentChapterIndex > 0 {
            let prevIndex = engine.currentChapterIndex - 1
            engine.goToChapter(prevIndex)
            loadContent()
            if isPlaying {
                playCurrentParagraph()
            }
        }
    }
    
    @objc private func nextTapped() {
        if currentParagraphIndex < paragraphs.count - 1 {
            TTSService.shared.stop(notify: false)
            currentParagraphIndex += 1
            TTSService.shared.currentParagraphIndex = currentParagraphIndex
            updateContentDisplay()
            if isPlaying {
                playCurrentParagraph()
            }
        } else {
            goToNextChapter()
        }
    }
    
    @objc private func styleTapped() {
        let styles = TTSService.shared.getStylesForCurrentVoice()
        let alert = UIAlertController(title: "选择风格", message: nil, preferredStyle: .actionSheet)
        
        let noneAction = UIAlertAction(title: "无", style: .default) { [weak self] _ in
            TTSService.shared.currentStyle = ""
            self?.updateStyleButton()
        }
        if TTSService.shared.currentStyle.isEmpty {
            noneAction.setValue(true, forKey: "checked")
        }
        alert.addAction(noneAction)
        
        for style in styles {
            let action = UIAlertAction(title: style, style: .default) { [weak self] _ in
                TTSService.shared.currentStyle = style
                self?.updateStyleButton()
            }
            if TTSService.shared.currentStyle == style {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController, let styleButton = styleButton {
            popover.sourceView = styleButton
            popover.sourceRect = styleButton.bounds
        }
        present(alert, animated: true)
    }
    
    @objc private func voiceTapped() {
        guard !isLoadingVoices else { return }
        isLoadingVoices = true
        
        voiceButton.isEnabled = false
        voiceButton.setTitle("加载中...", for: .normal)
        
        TTSService.shared.getHttpVoices { [weak self] voices in
            DispatchQueue.main.async {
                self?.isLoadingVoices = false
                self?.voiceButton.isEnabled = true
                self?.showVoicePicker(voices: voices)
            }
        }
    }
    
    private func showVoicePicker(voices: [String]) {
        let alert = UIAlertController(title: "选择语音", message: nil, preferredStyle: .actionSheet)
        
        for voice in voices {
            let action = UIAlertAction(title: voice, style: .default) { [weak self] _ in
                TTSService.shared.setVoiceByDisplayName(voice)
                self?.voiceButton.setTitle(voice, for: .normal)
                
                let styles = TTSService.shared.getStylesForCurrentVoice()
                if !styles.isEmpty {
                    TTSService.shared.currentStyle = styles[0]
                }
                self?.updateStyleButton()
            }
            if TTSService.shared.currentVoiceDisplayName == voice {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        alert.popoverPresentationController?.sourceView = voiceButton
        alert.popoverPresentationController?.sourceRect = voiceButton.bounds
        
        present(alert, animated: true)
    }
    
    @objc private func rateChanged() {
        TTSService.shared.currentRate = rateSlider.value
        updateRateLabel()
    }
}

// 补充安全下标扩展（避免原代码崩溃）
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

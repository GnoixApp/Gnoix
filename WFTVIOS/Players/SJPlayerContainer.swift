import SwiftUI
import UIKit
import SJVideoPlayer

// MARK: - SJVideoPlayer Container
// 优化特性：
// 1. 网络状态监听
// 2. 错误重连集成
// 3. 选集功能（仅全屏时显示）
// 4. 下一集按钮
// 5. 显示当前播放剧名和集数

struct SJPlayerContainer: UIViewControllerRepresentable {
    let url: String
    let episodes: [Episode]
    let currentEpisode: Episode?
    let videoTitle: String?
    let resumeTime: Double?
    var onError: ((String) -> Void)?
    var onRetry: (() -> Void)?
    var onSelectEpisode: ((Episode) -> Void)?
    var onBufferingStateChanged: ((Bool) -> Void)?
    var onPlaybackProgress: ((Double, Double) -> Void)?
    
    func makeUIViewController(context: Context) -> SJPlayerContainerViewController {
        let vc = SJPlayerContainerViewController()
        vc.episodes = episodes
        vc.currentEpisode = currentEpisode
        vc.videoTitle = videoTitle
        vc.onBufferingStateChanged = onBufferingStateChanged
        vc.onPlaybackProgress = onPlaybackProgress
        vc.onError = onError
        vc.onRetry = onRetry
        vc.onSelectEpisode = onSelectEpisode
        vc.updateResumeTimeIfNeeded(resumeTime)
        vc.updateURL(with: url)
        return vc
    }
    
    func updateUIViewController(_ uiViewController: SJPlayerContainerViewController, context: Context) {
        let wasFullscreen = uiViewController.player.isFullscreen
        
        uiViewController.episodes = episodes
        uiViewController.currentEpisode = currentEpisode
        uiViewController.videoTitle = videoTitle
        uiViewController.onBufferingStateChanged = onBufferingStateChanged
        uiViewController.onPlaybackProgress = onPlaybackProgress
        
        if !episodes.isEmpty && episodes.count > 1 {
            uiViewController.refreshControlButtons()
        }
        
        uiViewController.updateTitleDisplay()
        uiViewController.updateURL(with: url, keepFullscreen: wasFullscreen)
        uiViewController.updateResumeTimeIfNeeded(resumeTime)
    }
}

class SJPlayerContainerViewController: UIViewController {
    private static let verboseLoggingEnabled = false
    fileprivate let player = SJVideoPlayer()
    private var currentURL: String?
    private var networkObserver: NSObjectProtocol?
    
    var episodes: [Episode] = []
    var currentEpisode: Episode?
    var videoTitle: String?
    var onError: ((String) -> Void)?
    var onRetry: (() -> Void)?
    var onSelectEpisode: ((Episode) -> Void)?
    var onBufferingStateChanged: ((Bool) -> Void)?
    var onPlaybackProgress: ((Double, Double) -> Void)?
    
    private var retryCount = 0
    private let maxRetryCount = 3
    private var retryTimer: Timer?
    private var episodeSelectionView: EpisodeSelectionView?
    private var isShowingEpisodeSelection = false
    private var isBuffering = false
    private var pendingResumeTime: Double?
    private var isApplyingResumeTime = false
    private var lastAppliedResumeSignature: String?
    private var lastReportedPlaybackTime: Double = 0
    private var lastKnownDuration: Double = 0
    
    private let nextEpisodeButtonTag: SJEdgeControlButtonItemTag = 10002

    private func log(_ message: @autoclosure () -> String) {
        guard Self.verboseLoggingEnabled else { return }
        print(message())
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(player.view)
        player.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            player.view.topAnchor.constraint(equalTo: view.topAnchor),
            player.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            player.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            player.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        setupPlayer()
        setupGesture()
        setupNetworkObserver()
        setupRotationObserver()
    }
    
    private func setupPlayer() {
        player.defaultEdgeControlLayer.isHiddenBottomProgressIndicator = true
        player.shouldTriggerRotation = { _ in return true }
        player.rotationManager?.isDisabledAutorotation = false
        player.rotationManager?.autorotationSupportedOrientations = .all
        // 禁用自动旋转/全屏，让用户手动控制
        player.defaultEdgeControlLayer.automaticallyPerformRotationOrFitOnScreen = true
        bindPlaybackObservers()
    }

    private func bindPlaybackObservers() {
        player.playbackObserver.assetStatusDidChangeExeBlock = { [weak self] _ in
            self?.handleAssetStatusChange()
        }
        player.playbackObserver.timeControlStatusDidChangeExeBlock = { [weak self] _ in
            self?.handleTimeControlStatusChange()
        }
        player.playbackObserver.currentTimeDidChangeExeBlock = { [weak self] _ in
            self?.handleCurrentTimeChange()
        }
        player.playbackObserver.durationDidChangeExeBlock = { [weak self] _ in
            self?.handleDurationChange()
        }
        player.playbackObserver.playbackDidFinishExeBlock = { [weak self] _ in
            self?.handlePlaybackDidFinish()
        }
    }
    
    private func setupRotationObserver() {
        player.rotationObserver.onRotatingChanged = { [weak self] mgr, isRotating in
            guard let self = self, !isRotating else { return }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.log("[SJPlayer] Rotation completed, refreshing buttons")
                self.refreshControlButtons()
                if self.isShowingEpisodeSelection {
                    self.reinstallEpisodeSelectionView()
                }
            }
        }
    }
    
    // MARK: - 刷新控制按钮
    func refreshControlButtons() {
        let isFullscreen = player.isFullscreen
        log("[SJPlayer] refreshControlButtons - isFullscreen: \(isFullscreen), episodes: \(episodes.count)")
        
        if isFullscreen && episodes.count > 1 {
            addEpisodeButton()
            addNextEpisodeButton()
        } else {
            removeEpisodeButton()
            removeNextEpisodeButton()
        }
        
        if !isFullscreen && isShowingEpisodeSelection {
            hideEpisodeSelection()
        }
        
        // 强制显示控制层
        player.controlLayerNeedAppear()
    }
    
    // MARK: - 标题显示 - 通过 URLAsset 设置
    func updateTitleDisplay() {
        // 每次更新 URL 时已经通过 urlAsset.title 设置了标题
        // 这里只需要刷新一下
        log("[SJPlayer] updateTitleDisplay called")
    }
    
    // MARK: - 选集按钮 - 放到底部进度条左边
    private let episodeButtonTag: SJEdgeControlButtonItemTag = 10001
    
    func addEpisodeButton() {
        let bottomAdapter = player.defaultEdgeControlLayer.bottomAdapter
        
        // 检查是否已经存在
        if bottomAdapter.item(forTag: episodeButtonTag) != nil {
            log("[SJPlayer] Episode button already exists")
            return
        }
        
        guard episodes.count > 1 else { 
            log("[SJPlayer] Not enough episodes: \(episodes.count)")
            return 
        }
        
        log("[SJPlayer] Adding episode button to bottom adapter")
        
        let title = NSAttributedString(
            string: "选集",
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.white
            ]
        )
        
        let episodeItem = SJEdgeControlButtonItem(
            title: title,
            target: self,
            action: #selector(episodeButtonTapped),
            tag: episodeButtonTag
        )
        
        // 添加到第一个位置（进度条左边）
        bottomAdapter.insert(episodeItem, at: 0)
        bottomAdapter.reload()
        log("[SJPlayer] Episode button added at index 0")
    }
    
    @objc private func episodeButtonTapped() {
        log("[SJPlayer] episodeButtonTapped called!")
        showEpisodeSelection()
    }
    
    func removeEpisodeButton() {
        let bottomAdapter = player.defaultEdgeControlLayer.bottomAdapter
        if bottomAdapter.item(forTag: episodeButtonTag) != nil {
            bottomAdapter.removeItem(forTag: episodeButtonTag)
            bottomAdapter.reload()
            log("[SJPlayer] Episode button removed")
        }
    }
    
    // MARK: - 下一集按钮
    func addNextEpisodeButton() {
        let bottomAdapter = player.defaultEdgeControlLayer.bottomAdapter
        
        guard bottomAdapter.item(forTag: nextEpisodeButtonTag) == nil else { return }
        guard episodes.count > 1 else { return }
        
        log("[SJPlayer] Adding next episode button")
        
        let nextImage = UIImage(systemName: "forward.end.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        
        // 使用 target-action 方式
        let nextItem = SJEdgeControlButtonItem(
            image: nextImage,
            target: self,
            action: #selector(nextEpisodeButtonTapped),
            tag: nextEpisodeButtonTag
        )
        
        // 添加到底部控制栏
        bottomAdapter.add(nextItem)
        bottomAdapter.reload()
        log("[SJPlayer] Next button added")
    }
    
    @objc private func nextEpisodeButtonTapped() {
        log("[SJPlayer] nextEpisodeButtonTapped called!")
        playNextEpisode()
    }
    
    func removeNextEpisodeButton() {
        let bottomAdapter = player.defaultEdgeControlLayer.bottomAdapter
        if bottomAdapter.item(forTag: nextEpisodeButtonTag) != nil {
            bottomAdapter.removeItem(forTag: nextEpisodeButtonTag)
            bottomAdapter.reload()
            log("[SJPlayer] Next button removed")
        }
    }
    
    @objc private func playNextEpisode() {
        guard let currentEp = currentEpisode,
              let currentIndex = episodes.firstIndex(where: { $0.playUrl == currentEp.playUrl }),
              currentIndex < episodes.count - 1 else {
            log("[SJPlayer] Already at last episode or cannot find current episode")
            return
        }
        
        let nextEpisode = episodes[currentIndex + 1]
        let wasFullscreen = player.isFullscreen
        
        currentEpisode = nextEpisode
        
        // 立即更新标题
        updateTitleDisplay()
        
        // 更新 URL
        updateURL(with: nextEpisode.playUrl, keepFullscreen: wasFullscreen)
        
        // 通知外部更新 UI
        onSelectEpisode?(nextEpisode)
        
        log("[SJPlayer] Play next episode: \(nextEpisode.title)")
    }
    
    @objc private func showEpisodeSelection() {
        log("[SJPlayer] showEpisodeSelection called, episodes: \(episodes.count)")
        
        guard !episodes.isEmpty else { 
            log("[SJPlayer] episodes is empty")
            return 
        }
        
        if isShowingEpisodeSelection {
            log("[SJPlayer] Already showing, hiding")
            hideEpisodeSelection()
            return
        }
        
        log("[SJPlayer] Showing episode selection")
        isShowingEpisodeSelection = true
        
        // 隐藏播放器控制层
        player.controlLayerNeedDisappear()
        
        // 延迟显示选集视图，等待控制层隐藏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.reinstallEpisodeSelectionView()
        }
    }
    
    private func reinstallEpisodeSelectionView() {
        episodeSelectionView?.removeFromSuperview()
        
        let selectionView = EpisodeSelectionView(episodes: episodes, currentEpisode: currentEpisode)
        selectionView.onSelectEpisode = { [weak self] episode in
            self?.selectEpisode(episode)
        }
        selectionView.onClose = { [weak self] in
            self?.hideEpisodeSelection()
        }
        
        self.episodeSelectionView = selectionView
        
        // 添加到 keyWindow 上
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            log("[SJPlayer] No key window found")
            return
        }
        
        selectionView.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(selectionView)
        
        NSLayoutConstraint.activate([
            selectionView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            selectionView.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            selectionView.bottomAnchor.constraint(equalTo: window.bottomAnchor),
            selectionView.topAnchor.constraint(equalTo: window.topAnchor)
        ])
        
        log("[SJPlayer] Episode selection view added to window")
        
        // 直接显示，不需要动画
        selectionView.alpha = 1
    }
    
    private func selectEpisode(_ episode: Episode) {
        let wasFullscreen = player.isFullscreen
        
        currentEpisode = episode
        
        // 立即更新标题
        updateTitleDisplay()
        
        // 更新 URL
        updateURL(with: episode.playUrl, keepFullscreen: wasFullscreen)
        
        // 关闭选集面板
        hideEpisodeSelection()
        
        // 通知外部
        onSelectEpisode?(episode)
        
        log("[SJPlayer] Selected episode: \(episode.title)")
    }
    
    private func hideEpisodeSelection() {
        guard let selectionView = episodeSelectionView else { return }
        
        isShowingEpisodeSelection = false
        
        UIView.animate(withDuration: 0.3, animations: {
            selectionView.alpha = 0
        }) { _ in
            selectionView.removeFromSuperview()
            self.episodeSelectionView = nil
            self.log("[SJPlayer] Episode selection view hidden")
        }
        
        player.controlLayerNeedDisappear()
    }
    
    private func setupGesture() {
        player.gestureRecognizerShouldTrigger = { [weak self] player, type, location in
            guard let self = self else { return false }
            
            if type == .doubleTap {
                let viewWidth = self.player.view.bounds.width
                if location.x < viewWidth / 2 {
                    self.player.seek(toTime: max(0, self.player.currentTime - 10), completionHandler: nil)
                } else {
                    self.player.seek(toTime: min(self.player.duration, self.player.currentTime + 10), completionHandler: nil)
                }
                return false
            }
            return true
        }
    }
    
    private func setupNetworkObserver() {
        networkObserver = NotificationCenter.default.addObserver(
            forName: .networkReconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleNetworkReconnect()
        }
    }

    private func handleAssetStatusChange() {
        lastKnownDuration = max(lastKnownDuration, player.duration)
        if player.isPlaybackFailed || player.assetStatus == .failed {
            handlePlaybackFailure()
            return
        }
        if player.assetStatus == .readyToPlay {
            retryCount = 0
            applyPendingResumeIfPossible()
        }
    }

    private func handleTimeControlStatusChange() {
        switch player.timeControlStatus {
        case .waitingToPlay:
            if !player.isPlaybackFailed {
                setBufferingState(true)
            }
        case .playing:
            setBufferingState(false)
            retryCount = 0
            applyPendingResumeIfPossible()
        case .paused:
            setBufferingState(false)
        @unknown default:
            setBufferingState(false)
        }
    }

    private func handleDurationChange() {
        lastKnownDuration = max(player.duration, 0)
        applyPendingResumeIfPossible()
    }

    private func handleCurrentTimeChange() {
        lastKnownDuration = max(lastKnownDuration, player.duration)
        guard pendingResumeTime == nil, !isApplyingResumeTime else { return }
        reportPlaybackProgressIfNeeded(force: false)
    }

    private func handlePlaybackDidFinish() {
        setBufferingState(false)
        lastKnownDuration = max(lastKnownDuration, player.duration)
        reportPlaybackProgress(currentTime: 0, duration: lastKnownDuration)
    }

    private func handlePlaybackFailure() {
        setBufferingState(false)
        stopRetryTimer()

        guard retryCount < maxRetryCount else {
            onError?("当前线路播放失败，请切换播放源或稍后重试")
            return
        }

        retryCount += 1
        let delay = TimeInterval(min(retryCount * 2, 10))
        onError?("播放失败，正在重试 (\(retryCount)/\(maxRetryCount))...")
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.reloadCurrentSource()
        }
    }

    private func setBufferingState(_ buffering: Bool) {
        guard isBuffering != buffering else { return }
        isBuffering = buffering
        onBufferingStateChanged?(buffering)
    }

    private func reportPlaybackProgressIfNeeded(force: Bool) {
        let currentTime = max(0, player.currentTime)
        let duration = max(player.duration, lastKnownDuration)
        guard currentTime.isFinite, duration.isFinite || duration == 0 else { return }

        if !force {
            if currentTime < 15 {
                return
            }
            if lastReportedPlaybackTime > 0, abs(currentTime - lastReportedPlaybackTime) < 15 {
                return
            }
        }

        reportPlaybackProgress(currentTime: currentTime, duration: duration)
    }

    private func reportPlaybackProgress(currentTime: Double, duration: Double) {
        lastReportedPlaybackTime = max(0, currentTime)
        onPlaybackProgress?(max(0, currentTime), max(0, duration))
    }

    private func normalizeResumeTime(_ time: Double?, duration: Double?) -> Double? {
        guard let time, time.isFinite, time >= 5 else { return nil }
        guard let duration, duration.isFinite, duration > 0 else {
            return time
        }

        let clampedTime = min(time, max(duration - 1, 0))
        if duration > 60, (duration - clampedTime) < 15 || (clampedTime / duration) > 0.98 {
            return nil
        }
        return clampedTime
    }

    func updateResumeTimeIfNeeded(_ resumeTime: Double?) {
        let normalizedResumeTime = normalizeResumeTime(resumeTime, duration: lastKnownDuration > 0 ? lastKnownDuration : nil)
        guard pendingResumeTime != normalizedResumeTime else { return }
        pendingResumeTime = normalizedResumeTime
        applyPendingResumeIfPossible()
    }

    private func applyPendingResumeIfPossible() {
        guard player.assetStatus == .readyToPlay,
              let currentURL,
              let resumeTime = normalizeResumeTime(pendingResumeTime, duration: max(player.duration, lastKnownDuration)),
              !isApplyingResumeTime else {
            return
        }

        let signature = "\(currentURL)#\(Int((resumeTime * 10).rounded()))"
        guard lastAppliedResumeSignature != signature else { return }

        lastAppliedResumeSignature = signature
        pendingResumeTime = nil
        isApplyingResumeTime = true
        setBufferingState(true)
        player.seek(toTime: resumeTime) { [weak self] _ in
            guard let self else { return }
            self.isApplyingResumeTime = false
            self.lastReportedPlaybackTime = resumeTime
            self.setBufferingState(self.player.timeControlStatus == .waitingToPlay)
        }
    }
    
    func updateURL(with urlString: String, keepFullscreen: Bool = false) {
        guard urlString != currentURL, let url = URL(string: urlString) else { return }
        
        stopRetryTimer()
        retryCount = 0
        currentURL = urlString
        lastAppliedResumeSignature = nil
        lastReportedPlaybackTime = 0
        lastKnownDuration = 0
        setBufferingState(true)
        
        guard let asset = SJVideoPlayerURLAsset(url: url) else { return }
        
        // 设置标题 - 通过 URLAsset 的 title 属性
        if let vTitle = videoTitle, let episode = currentEpisode {
            asset.title = "\(vTitle) - \(episode.title)"
            log("[SJPlayer] Setting title: \(vTitle) - \(episode.title)")
        } else if let vTitle = videoTitle {
            asset.title = vTitle
            log("[SJPlayer] Setting title: \(vTitle)")
        }
        
        player.urlAsset = asset
        player.play()
        
        if keepFullscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                if !self.player.isFullscreen {
                    self.log("[SJPlayer] Restoring fullscreen after URL update")
                    self.player.rotate(.landscapeLeft, animated: true)
                }
            }
        }
    }
    
    private func handleNetworkReconnect() {
        if !player.isPlaying {
            reloadCurrentSource()
        }
    }
    
    private func reloadCurrentSource() {
        guard let urlString = currentURL, let url = URL(string: urlString) else { return }
        setBufferingState(true)
        let asset = SJVideoPlayerURLAsset(url: url)
        player.urlAsset = asset
        player.play()
        onRetry?()
    }
    
    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }
    
    func prepareForNewSource() {
        stopRetryTimer()
        reportPlaybackProgressIfNeeded(force: true)
        player.pause()
        player.urlAsset = nil
        retryCount = 0
        currentURL = nil
        pendingResumeTime = nil
        lastAppliedResumeSignature = nil
        lastReportedPlaybackTime = 0
        lastKnownDuration = 0
        setBufferingState(false)
    }
    
    deinit {
        stopRetryTimer()
        prepareForNewSource()
        if let observer = networkObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        player.vc_viewDidAppear()
        
        // 立即刷新一次
        refreshControlButtonsAndShow()
        
        // 持续刷新几次确保按钮添加成功
        for i in 1...3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [weak self] in
                self?.refreshControlButtonsAndShow()
            }
        }
        
        updateTitleDisplay()
    }
    
    private func refreshControlButtonsAndShow() {
        log("[SJPlayer] refreshControlButtonsAndShow called")
        
        // 强制显示控制层
        player.controlLayerNeedAppear()
        
        // 刷新按钮
        refreshControlButtons()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        reportPlaybackProgressIfNeeded(force: true)
        player.pause()
        player.vc_viewWillDisappear()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player.vc_viewDidDisappear()
    }
}

// MARK: - Episode Selection View
class EpisodeSelectionView: UIView {
    private let episodes: [Episode]
    private let currentEpisode: Episode?
    private var filteredEpisodes: [Episode] = []
    private var groups: [EpisodeGroup] = []
    private var selectedGroupId: String = "all"
    
    private var collectionView: UICollectionView!
    private var groupCollectionView: UICollectionView!
    private let containerView = UIView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let dimOverlayView = UIView()
    private let grabberView = UIView()
    private let headerView = UIView()
    private let subtitleLabel = UILabel()
    private var groupCollectionHeightConstraint: NSLayoutConstraint?
    
    var onSelectEpisode: ((Episode) -> Void)?
    var onClose: (() -> Void)?
    
    init(episodes: [Episode], currentEpisode: Episode?) {
        self.episodes = episodes
        self.currentEpisode = currentEpisode
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        let shouldReduceTransparency = UserPreferencesManager.shouldReduceTransparencyFromStorage()
        backgroundColor = .clear
        
        dimOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        dimOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dimOverlayView)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tapGesture.cancelsTouchesInView = false
        addGestureRecognizer(tapGesture)
        
        containerView.backgroundColor = .clear
        containerView.layer.cornerRadius = 16
        containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.masksToBounds = true
        addSubview(containerView)
        
        blurView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(blurView)
        blurView.effect = shouldReduceTransparency ? nil : UIBlurEffect(style: .systemUltraThinMaterialDark)
        blurView.backgroundColor = shouldReduceTransparency ? UIColor.black.withAlphaComponent(0.9) : .clear
        
        grabberView.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        grabberView.layer.cornerRadius = 2.5
        grabberView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(grabberView)
        
        headerView.backgroundColor = UIColor.white.withAlphaComponent(0.04)
        headerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(headerView)
        
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = UIColor.white.withAlphaComponent(0.86)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(closeButton)
        
        let titleLabel = UILabel()
        titleLabel.text = "选集"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 19, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)
        
        subtitleLabel.text = "共 \(episodes.count) 集"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(subtitleLabel)
        
        let groupLayout = UICollectionViewFlowLayout()
        groupLayout.scrollDirection = .horizontal
        groupLayout.minimumLineSpacing = 8
        groupLayout.minimumInteritemSpacing = 8
        groupLayout.sectionInset = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        groupCollectionView = UICollectionView(frame: .zero, collectionViewLayout: groupLayout)
        groupCollectionView.backgroundColor = .clear
        groupCollectionView.delegate = self
        groupCollectionView.dataSource = self
        groupCollectionView.showsHorizontalScrollIndicator = false
        groupCollectionView.alwaysBounceHorizontal = true
        groupCollectionView.register(EpisodeGroupChipCell.self, forCellWithReuseIdentifier: "EpisodeGroupChipCell")
        groupCollectionView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(groupCollectionView)
        
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 10, left: 14, bottom: 14, right: 14)
        
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.register(EpisodeCell.self, forCellWithReuseIdentifier: "EpisodeCell")
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.showsVerticalScrollIndicator = true
        collectionView.alwaysBounceVertical = true
        containerView.addSubview(collectionView)
        
        let groupHeight = groupCollectionView.heightAnchor.constraint(equalToConstant: 38)
        groupCollectionHeightConstraint = groupHeight
        
        NSLayoutConstraint.activate([
            dimOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimOverlayView.topAnchor.constraint(equalTo: topAnchor),
            dimOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.68),
            
            blurView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: containerView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            
            grabberView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            grabberView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: 44),
            grabberView.heightAnchor.constraint(equalToConstant: 5),
            
            headerView.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 8),
            headerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 62),
            
            closeButton.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -16),
            
            groupCollectionView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            groupCollectionView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            groupCollectionView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            groupHeight,
            
            collectionView.topAnchor.constraint(equalTo: groupCollectionView.bottomAnchor, constant: 2),
            collectionView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        rebuildGroups()
        
        DispatchQueue.main.async { [weak self] in
            self?.groupCollectionView.reloadData()
            self?.collectionView.reloadData()
            self?.scrollToCurrentEpisode()
        }
    }
    
    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        if !containerView.frame.contains(location) {
            onClose?()
        }
    }
    
    private func scrollToCurrentEpisode() {
        guard let currentEpisode = currentEpisode,
              let index = filteredEpisodes.firstIndex(where: { $0.playUrl == currentEpisode.playUrl }),
              filteredEpisodes.indices.contains(index) else { return }
        
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }
    
    @objc private func closeTapped() {
        onClose?()
    }
    
    private func rebuildGroups() {
        groups = buildEpisodeGroups(from: episodes)
        if !groups.contains(where: { $0.id == selectedGroupId }) {
            selectedGroupId = "all"
        }
        applySelectedGroup()
        groupCollectionHeightConstraint?.constant = groups.count > 1 ? 38 : 0
        subtitleLabel.text = "共 \(filteredEpisodes.count) 集"
    }
    
    private func applySelectedGroup() {
        guard let group = groups.first(where: { $0.id == selectedGroupId }) else {
            filteredEpisodes = episodes
            return
        }
        
        switch group.rule {
        case .all:
            filteredEpisodes = episodes
        case .indexRange(let range):
            filteredEpisodes = episodes.enumerated().compactMap { index, episode in
                range.contains(index) ? episode : nil
            }
        case .keyword(let token):
            filteredEpisodes = episodes.filter { episode in
                normalized(episode.title).contains(normalized(token))
            }
        }
        
        if filteredEpisodes.isEmpty {
            filteredEpisodes = episodes
        }
    }
    
    private func buildEpisodeGroups(from episodes: [Episode]) -> [EpisodeGroup] {
        guard !episodes.isEmpty else {
            return [EpisodeGroup(id: "all", title: "全部", rule: .all)]
        }
        
        var result: [EpisodeGroup] = [
            EpisodeGroup(id: "all", title: "全部", rule: .all)
        ]
        
        let seasonTokens = extractSeasonTokens(from: episodes)
        if seasonTokens.count >= 2 {
            for token in seasonTokens {
                result.append(
                    EpisodeGroup(
                        id: "season_\(normalized(token))",
                        title: token,
                        rule: .keyword(token)
                    )
                )
            }
            return result
        }
        
        if episodes.count > 24 {
            let chunkSize: Int
            if episodes.count <= 72 {
                chunkSize = 18
            } else if episodes.count <= 160 {
                chunkSize = 24
            } else {
                chunkSize = 32
            }
            
            var start = 0
            while start < episodes.count {
                let end = min(start + chunkSize - 1, episodes.count - 1)
                let title = "\(start + 1)-\(end + 1)"
                result.append(
                    EpisodeGroup(
                        id: "range_\(start)_\(end)",
                        title: title,
                        rule: .indexRange(start...end)
                    )
                )
                start += chunkSize
            }
        }
        
        return result
    }
    
    private func extractSeasonTokens(from episodes: [Episode]) -> [String] {
        let pattern = "(第[一二三四五六七八九十百0-9]+季|S\\s?\\d{1,2}|Season\\s?\\d{1,2})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        
        var tokens: [String] = []
        var normalizedSet = Set<String>()
        
        for episode in episodes {
            let text = episode.title
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let matchRange = Range(match.range, in: text) else { continue }
            
            let token = String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedToken = normalized(token)
            guard !normalizedToken.isEmpty, !normalizedSet.contains(normalizedToken) else { continue }
            
            normalizedSet.insert(normalizedToken)
            tokens.append(token)
            
            if tokens.count >= 8 { break }
        }
        
        return tokens
    }
    
    private func normalized(_ value: String) -> String {
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}

private struct EpisodeGroup {
    enum Rule {
        case all
        case indexRange(ClosedRange<Int>)
        case keyword(String)
    }
    
    let id: String
    let title: String
    let rule: Rule
}

// MARK: - UICollectionView DataSource & Delegate
extension EpisodeSelectionView: UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if collectionView === groupCollectionView {
            return groups.count
        }
        return filteredEpisodes.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === groupCollectionView {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EpisodeGroupChipCell", for: indexPath) as! EpisodeGroupChipCell
            let group = groups[indexPath.item]
            let isSelected = selectedGroupId == group.id
            cell.configure(title: group.title, selected: isSelected)
            return cell
        } else {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EpisodeCell", for: indexPath) as! EpisodeCell
            let episode = filteredEpisodes[indexPath.item]
            let isCurrent = episode.playUrl == currentEpisode?.playUrl
            cell.configure(with: episode, isCurrent: isCurrent)
            return cell
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === groupCollectionView {
            let group = groups[indexPath.item]
            guard selectedGroupId != group.id else { return }
            
            selectedGroupId = group.id
            applySelectedGroup()
            subtitleLabel.text = "共 \(filteredEpisodes.count) 集"
            groupCollectionView.reloadData()
            self.collectionView.reloadData()
            scrollToCurrentEpisode()
        } else {
            let episode = filteredEpisodes[indexPath.item]
            onSelectEpisode?(episode)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        if collectionView === groupCollectionView {
            let title = groups[indexPath.item].title as NSString
            let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
            let textWidth = ceil(title.size(withAttributes: [.font: font]).width)
            return CGSize(width: textWidth + 26, height: 30)
        } else {
            let sectionInset: CGFloat = 14 * 2
            let spacing: CGFloat = 8
            let availableWidth = max(220, collectionView.bounds.width - sectionInset)
            let columns: CGFloat
            switch availableWidth {
            case 920...: columns = 8
            case 760..<920: columns = 7
            case 620..<760: columns = 6
            case 500..<620: columns = 5
            default: columns = 4
            }
            let width = floor((availableWidth - spacing * (columns - 1)) / columns)
            return CGSize(width: width, height: 42)
        }
    }
}

class EpisodeGroupChipCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        contentView.layer.cornerRadius = 15
        contentView.layer.borderWidth = 1
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textAlignment = .center
        contentView.addSubview(titleLabel)
        
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }
    
    func configure(title: String, selected: Bool) {
        titleLabel.text = title
        if selected {
            contentView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
            contentView.layer.borderColor = UIColor.systemBlue.cgColor
            titleLabel.textColor = .white
        } else {
            contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
            titleLabel.textColor = UIColor.white.withAlphaComponent(0.86)
        }
    }
}

// MARK: - Episode Cell
class EpisodeCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        contentView.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textAlignment = .center
        titleLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.72
        
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6)
        ])
        
        contentView.layer.cornerRadius = 9
        contentView.layer.borderWidth = 1
        contentView.layer.masksToBounds = true
    }
    
    func configure(with episode: Episode, isCurrent: Bool) {
        titleLabel.text = episode.title
        
        if isCurrent {
            contentView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
            contentView.layer.borderColor = UIColor.systemBlue.cgColor
            titleLabel.textColor = .white
        } else {
            contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
            titleLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        }
    }
    
    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.1) {
                self.contentView.alpha = self.isHighlighted ? 0.7 : 1.0
            }
        }
    }
}

import SwiftUI
import Combine
import UIKit
import SJVideoPlayer
import Kingfisher

struct FullscreenLivePlayerView: View {
    let initialChannel: LiveChannel
    let allChannels: [LiveChannel]
    @StateObject private var viewModel = FullscreenLivePlayerViewModel()
    @EnvironmentObject var preferencesManager: UserPreferencesManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // 使用新的播放器组件
            LivePlayerContainer(
                channel: viewModel.currentChannel ?? initialChannel,
                channels: allChannels,
                reduceTransparency: preferencesManager.shouldReduceTransparency,
                onLoadingStateChanged: { isLoading in
                    viewModel.updateLoadingState(isLoading)
                },
                onPlaybackErrorChanged: { message in
                    viewModel.updateErrorState(message)
                },
                onChannelSwitch: { channel in
                    viewModel.switchToChannel(channel)
                },
                onDismiss: {
                    dismiss()
                }
            )
            
            // 加载指示器
            if viewModel.isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("正在加载频道...")
                        .foregroundColor(.white)
                        .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.7))
            }

            if let errorMessage = viewModel.errorMessage, !viewModel.isLoading {
                VStack {
                    Spacer()

                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.72))
                        .clipShape(Capsule())
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            viewModel.setup(with: initialChannel)
        }
    }
}

// MARK: - Live Player Container

struct LivePlayerContainer: UIViewControllerRepresentable {
    let channel: LiveChannel
    let channels: [LiveChannel]
    let reduceTransparency: Bool
    var onLoadingStateChanged: ((Bool) -> Void)?
    var onPlaybackErrorChanged: ((String?) -> Void)?
    var onChannelSwitch: ((LiveChannel) -> Void)?
    var onDismiss: (() -> Void)?
    
    func makeUIViewController(context: Context) -> UIViewController {
        // 使用现有的 SJPlayerContainerViewController 但添加频道列表功能
        let vc = LivePlayerViewController()
        vc.initialChannel = channel
        vc.allChannels = channels
        vc.reduceTransparency = reduceTransparency
        vc.onLoadingStateChanged = onLoadingStateChanged
        vc.onPlaybackErrorChanged = onPlaybackErrorChanged
        vc.onChannelSwitch = onChannelSwitch
        vc.onDismiss = onDismiss
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // 更新频道
        if let vc = uiViewController as? LivePlayerViewController {
            vc.reduceTransparency = reduceTransparency
            vc.onLoadingStateChanged = onLoadingStateChanged
            vc.onPlaybackErrorChanged = onPlaybackErrorChanged
            vc.updateChannelIfNeeded(channel)
        }
    }
}

import UIKit
import SJVideoPlayer

// MARK: - Live Player View Controller (UIKit)

class LivePlayerViewController: UIViewController {
    private static let verboseLoggingEnabled = false
    // MARK: - Properties
    var initialChannel: LiveChannel?
    var currentChannel: LiveChannel?
    var allChannels: [LiveChannel] = []
    var reduceTransparency: Bool = false
    var onLoadingStateChanged: ((Bool) -> Void)?
    var onPlaybackErrorChanged: ((String?) -> Void)?
    var onChannelSwitch: ((LiveChannel) -> Void)?
    var onDismiss: (() -> Void)?
    
    private let player = SJVideoPlayer()
    private var channelListVC: ChannelListViewController?
    private var backdropView: UIView?
    private let channelListWidth: CGFloat = 360
    private let channelListButtonTag: SJEdgeControlButtonItemTag = 91001
    private var hasAutoPresentedChannelList = false
    private let failureActionButton = UIButton(type: .system)
    private var channelListWidthConstraint: NSLayoutConstraint?
    private var isChannelListAnimating = false
    private var canDismissChannelListByBackdrop = false
    private var pendingPresentWorkItem: DispatchWorkItem?
    private weak var channelListOverlayHostView: UIView?
    private var backdropTapGesture: UITapGestureRecognizer?
    private var isPlaybackLoading = false
    private var lastPlaybackErrorMessage: String?

    private func log(_ message: @autoclosure () -> String) {
        guard Self.verboseLoggingEnabled else { return }
        print(message())
    }

    deinit {
        pendingPresentWorkItem?.cancel()
        pendingPresentWorkItem = nil
        if let gesture = backdropTapGesture {
            backdropView?.removeGestureRecognizer(gesture)
        }
        backdropTapGesture = nil
        channelListOverlayHostView = nil
        channelListVC?.view.removeFromSuperview()
        channelListVC = nil
        player.pause()
        player.urlAsset = nil
    }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupPlayer()
        
        if let channel = initialChannel {
            playChannel(channel)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        player.vc_viewDidAppear()
        
        // 尝试添加按钮
        addChannelListButton()
        
        // 延迟再次尝试添加
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.addChannelListButton()
        }

        if !hasAutoPresentedChannelList {
            hasAutoPresentedChannelList = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.presentChannelList()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
            player.pause()
        }
        player.vc_viewWillDisappear()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
            player.pause()
        }
        player.vc_viewDidDisappear()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        channelListWidthConstraint?.constant = resolvedChannelListWidth(in: overlayHostView)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.channelListWidthConstraint?.constant = self.resolvedChannelListWidth(in: self.overlayHostView)
            self.view.layoutIfNeeded()
        })
    }

    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    
    // MARK: - Setup
    private func setupPlayer() {
        view.addSubview(player.view)
        player.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            player.view.topAnchor.constraint(equalTo: view.topAnchor),
            player.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            player.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            player.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // 配置播放器
        player.defaultEdgeControlLayer.isHiddenBottomProgressIndicator = true
        player.shouldTriggerRotation = { _ in return true }
        
        // 自动选择 Rotation(旋转) 或 FitOnScreen(充满全屏)
        // - 当视频宽 > 高时，自动旋转到横屏全屏
        player.defaultEdgeControlLayer.automaticallyPerformRotationOrFitOnScreen = true
        
        // 直接添加频道列表按钮
        addChannelListButton()
        setupFailureActionButton()
        observePlaybackState()
        
        // 配置双击快进/快退
        player.gestureRecognizerShouldTrigger = { [weak self] player, type, location in
            guard let self = self else { return false }
            if self.channelListVC != nil || self.isChannelListAnimating {
                // 切台面板显示时禁止播放器手势抢占触摸事件
                return false
            }
            
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
    
    private var channelListItem: SJEdgeControlButtonItem?
    
    private func addChannelListButton() {
        let topAdapter = player.defaultEdgeControlLayer.topAdapter
        
        // 避免重复添加
        if topAdapter.item(forTag: channelListButtonTag) != nil {
            return
        }
        
        // 使用文字按钮，控制层中更稳定、可见性更高
        let title = NSAttributedString(
            string: "切台",
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
        )
        let item = SJEdgeControlButtonItem(
            title: title,
            target: self,
            action: #selector(showChannelList),
            tag: channelListButtonTag
        )
        item.insets = SJEdgeInsetsMake(8, 8)
        item.resetsAppearIntervalWhenPerformingItemAction = false
        
        // 插到标题(fill)前，避免被标题项挤掉
        topAdapter.insert(item, at: 1)
        topAdapter.reload()
        
        channelListItem = item
        log("[LivePlayer] Channel list button added to top adapter")
    }
    
    // MARK: - Actions
    @objc private func showChannelList() {
        log("[LivePlayer] Show channel list tapped, channels count: \(allChannels.count)")

        // 点击“切台”时只负责打开，避免误触发关闭
        if channelListVC != nil || isChannelListAnimating {
            return
        }
        
        // 显示播放器控制层
        player.controlLayerNeedAppear()

        pendingPresentWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.presentChannelList()
        }
        pendingPresentWorkItem = workItem
        
        // 延迟显示频道列表
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func presentChannelList() {
        guard channelListVC == nil, !isChannelListAnimating else { return }
        isChannelListAnimating = true
        canDismissChannelListByBackdrop = false
        let hostView = overlayHostView
        channelListOverlayHostView = hostView

        let backdrop = UIView()
        backdrop.backgroundColor = .black
        backdrop.alpha = 0
        backdrop.isUserInteractionEnabled = true
        backdrop.layer.zPosition = 1000
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: hostView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: hostView.trailingAnchor)
        ])
        backdropView = backdrop
        
        if let oldGesture = backdropTapGesture {
            backdropView?.removeGestureRecognizer(oldGesture)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(backdropTapped(_:)))
        tap.cancelsTouchesInView = true
        backdrop.addGestureRecognizer(tap)
        backdropTapGesture = tap

        // 创建频道列表
        let channelListVC = ChannelListViewController()
        channelListVC.reduceTransparency = reduceTransparency
        channelListVC.channels = allChannels
        channelListVC.currentChannel = currentChannel
        channelListVC.onChannelSelected = { [weak self] channel in
            self?.playChannel(channel)
            self?.onChannelSwitch?(channel)
        }
        channelListVC.onClose = { [weak self] in
            self?.hideChannelList()
        }

        // 不作为子控制器挂载，避免横屏时 SJRotationFullscreenViewController 层级冲突
        channelListVC.loadViewIfNeeded()
        channelListVC.view.translatesAutoresizingMaskIntoConstraints = false
        channelListVC.view.isUserInteractionEnabled = true
        channelListVC.view.layer.zPosition = 1001
        hostView.addSubview(channelListVC.view)
        hostView.bringSubviewToFront(channelListVC.view)
        
        let widthConstraint = channelListVC.view.widthAnchor.constraint(equalToConstant: resolvedChannelListWidth(in: hostView))
        channelListWidthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            channelListVC.view.topAnchor.constraint(equalTo: hostView.topAnchor),
            channelListVC.view.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            channelListVC.view.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            widthConstraint
        ])
        // 动画显示
        channelListVC.view.transform = CGAffineTransform(translationX: widthConstraint.constant, y: 0)
        UIView.animate(withDuration: 0.25, animations: {
            backdrop.alpha = 0.35
            channelListVC.view.transform = .identity
        }) { [weak self] _ in
            self?.isChannelListAnimating = false
            self?.canDismissChannelListByBackdrop = true
        }
        
        self.channelListVC = channelListVC
        log("[LivePlayer] Channel list added to window")
    }
    
    private func hideChannelList() {
        guard let vc = channelListVC, !isChannelListAnimating else { return }
        isChannelListAnimating = true
        canDismissChannelListByBackdrop = false
        let backdrop = backdropView
        let translationX = channelListWidthConstraint?.constant ?? channelListWidth

        // 动画隐藏
        UIView.animate(withDuration: 0.25, animations: {
            backdrop?.alpha = 0
            vc.view.transform = CGAffineTransform(translationX: translationX, y: 0)
        }) { [weak self] _ in
            backdrop?.removeFromSuperview()
            vc.view.removeFromSuperview()
            guard let self else { return }
            self.backdropTapGesture = nil
            self.channelListOverlayHostView = nil
            self.backdropView = nil
            self.channelListVC = nil
            self.channelListWidthConstraint = nil
            self.isChannelListAnimating = false
            self.log("[LivePlayer] Channel list hidden")
        }
    }
    
    // MARK: - Playback
    func playChannel(_ channel: LiveChannel) {
        if currentChannel?.url == channel.url {
            channelListVC?.currentChannel = channel
            channelListVC?.updateCurrentChannel(from: currentChannel)
            return
        }

        let previousChannel = currentChannel
        currentChannel = channel
        updateFailureActionVisibility(failed: false, message: nil)
        reportLoadingState(true)
        reportPlaybackError(nil)
        
        if let url = URL(string: channel.url) {
            let asset = SJVideoPlayerURLAsset(url: url)
            player.urlAsset = asset
            player.play()
        } else {
            reportLoadingState(false)
            reportPlaybackError("频道地址无效，请切换其他频道")
            updateFailureActionVisibility(failed: true, message: "地址无效，点击切台")
        }
        
        // 确保频道列表按钮已添加
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.addChannelListButton()
        }
        
        // 更新列表中的当前频道
        channelListVC?.currentChannel = channel
        channelListVC?.updateCurrentChannel(from: previousChannel)
    }
    
    func updateChannelIfNeeded(_ channel: LiveChannel) {
        guard channel.url != currentChannel?.url else { return }
        playChannel(channel)
    }

    private func setupFailureActionButton() {
        failureActionButton.translatesAutoresizingMaskIntoConstraints = false
        failureActionButton.setTitle("加载失败，点击切台", for: .normal)
        failureActionButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        failureActionButton.setTitleColor(.white, for: .normal)
        failureActionButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        failureActionButton.layer.cornerRadius = 16
        failureActionButton.layer.borderWidth = 1
        failureActionButton.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        if #available(iOS 15.0, *) {
            var config = failureActionButton.configuration ?? UIButton.Configuration.plain()
            config.baseForegroundColor = .white
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            failureActionButton.configuration = config
        } else {
            failureActionButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        }
        failureActionButton.addTarget(self, action: #selector(failureActionTapped), for: .touchUpInside)
        failureActionButton.isHidden = true

        overlayHostView.addSubview(failureActionButton)
        NSLayoutConstraint.activate([
            failureActionButton.centerXAnchor.constraint(equalTo: overlayHostView.centerXAnchor),
            failureActionButton.bottomAnchor.constraint(equalTo: overlayHostView.safeAreaLayoutGuide.bottomAnchor, constant: -18)
        ])
    }

    private func observePlaybackState() {
        player.playbackObserver.assetStatusDidChangeExeBlock = { [weak self] _ in
            self?.handleAssetStatusChange()
        }
        player.playbackObserver.timeControlStatusDidChangeExeBlock = { [weak self] _ in
            self?.handleTimeControlStatusChange()
        }
    }

    private func handleAssetStatusChange() {
        DispatchQueue.main.async {
            let failed = self.player.isPlaybackFailed || self.player.assetStatus == .failed
            if failed {
                self.reportLoadingState(false)
                self.reportPlaybackError("当前频道加载失败，请切换其他频道")
                self.updateFailureActionVisibility(failed: true, message: "加载失败，点击切台")
                self.addChannelListButton()
                self.player.controlLayerNeedAppear()
                return
            }

            if self.player.assetStatus == .readyToPlay {
                self.reportPlaybackError(nil)
                self.updateFailureActionVisibility(failed: false, message: nil)
            }
        }
    }

    private func handleTimeControlStatusChange() {
        DispatchQueue.main.async {
            switch self.player.timeControlStatus {
            case .waitingToPlay:
                if !(self.player.isPlaybackFailed || self.player.assetStatus == .failed) {
                    self.reportLoadingState(true)
                }
            case .playing:
                self.reportLoadingState(false)
                self.reportPlaybackError(nil)
                self.updateFailureActionVisibility(failed: false, message: nil)
            case .paused:
                if self.player.assetStatus == .readyToPlay {
                    self.reportLoadingState(false)
                }
            @unknown default:
                self.reportLoadingState(false)
            }
        }
    }

    private func updateFailureActionVisibility(failed: Bool, message: String?) {
        failureActionButton.isHidden = !failed
        if let message, !message.isEmpty {
            failureActionButton.setTitle(message, for: .normal)
        }
    }

    @objc private func failureActionTapped() {
        showChannelList()
    }

    @objc private func backdropTapped(_ gesture: UITapGestureRecognizer) {
        guard canDismissChannelListByBackdrop else { return }
        hideChannelList()
    }

    private var overlayHostView: UIView {
        return player.presentView
    }

    private func resolvedChannelListWidth(in hostView: UIView) -> CGFloat {
        let horizontalSafeArea = hostView.safeAreaInsets.left + hostView.safeAreaInsets.right
        let availableWidth = max(240, hostView.bounds.width - horizontalSafeArea)
        let ratioWidth = availableWidth * 0.46
        let clamped = min(420, max(280, ratioWidth))
        return min(clamped, availableWidth - 20)
    }

    private func reportLoadingState(_ isLoading: Bool) {
        guard isPlaybackLoading != isLoading else { return }
        isPlaybackLoading = isLoading
        onLoadingStateChanged?(isLoading)
    }

    private func reportPlaybackError(_ message: String?) {
        guard lastPlaybackErrorMessage != message else { return }
        lastPlaybackErrorMessage = message
        onPlaybackErrorChanged?(message)
    }
}

// MARK: - Channel List View Controller

class ChannelListViewController: UIViewController {
    var channels: [LiveChannel] = [] {
        didSet {
            rebuildGroups()
        }
    }
    var currentChannel: LiveChannel?
    var reduceTransparency: Bool = false
    var onChannelSelected: ((LiveChannel) -> Void)?
    var onClose: (() -> Void)?
    
    private let groupTableView = UITableView()
    private let channelTableView = UITableView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let separatorLine = UIView()
    private let contentStack = UIStackView()
    private var groups: [String] = []
    private var groupedChannels: [String: [LiveChannel]] = [:]
    private var selectedGroup: String = "全部"
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        view.backgroundColor = .clear
        view.layer.cornerRadius = 18
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        view.layer.masksToBounds = true
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor

        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.effect = reduceTransparency ? nil : UIBlurEffect(style: .systemUltraThinMaterialDark)
        blurView.backgroundColor = reduceTransparency ? UIColor.black.withAlphaComponent(0.9) : .clear
        view.addSubview(blurView)

        headerView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        titleLabel.text = "频道切换"
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)

        subtitleLabel.text = "左侧分类 · 右侧频道"
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(subtitleLabel)

        closeButton.setImage(UIImage(systemName: "chevron.right.circle.fill"), for: .normal)
        closeButton.tintColor = UIColor.white.withAlphaComponent(0.88)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(closeButton)

        separatorLine.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separatorLine)

        contentStack.axis = .horizontal
        contentStack.spacing = 0
        contentStack.alignment = .fill
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        let groupContainer = UIView()
        groupContainer.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        groupContainer.translatesAutoresizingMaskIntoConstraints = false

        groupTableView.delegate = self
        groupTableView.dataSource = self
        groupTableView.register(GroupTableViewCell.self, forCellReuseIdentifier: "GroupCell")
        groupTableView.rowHeight = 40
        groupTableView.backgroundColor = .clear
        groupTableView.separatorStyle = .none
        groupTableView.tableFooterView = UIView()
        groupTableView.showsVerticalScrollIndicator = false
        groupContainer.addSubview(groupTableView)
        groupTableView.translatesAutoresizingMaskIntoConstraints = false

        channelTableView.delegate = self
        channelTableView.dataSource = self
        channelTableView.register(ChannelTableViewCell.self, forCellReuseIdentifier: "ChannelCell")
        channelTableView.rowHeight = 58
        channelTableView.backgroundColor = .clear
        channelTableView.separatorStyle = .none
        channelTableView.tableFooterView = UIView()
        channelTableView.showsVerticalScrollIndicator = false

        contentStack.addArrangedSubview(groupContainer)
        contentStack.addArrangedSubview(channelTableView)
        
        // Constraints
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: view.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 58),
            
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            separatorLine.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            separatorLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1),
            
            contentStack.topAnchor.constraint(equalTo: separatorLine.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            groupContainer.widthAnchor.constraint(equalToConstant: 106),

            groupTableView.topAnchor.constraint(equalTo: groupContainer.topAnchor),
            groupTableView.leadingAnchor.constraint(equalTo: groupContainer.leadingAnchor),
            groupTableView.trailingAnchor.constraint(equalTo: groupContainer.trailingAnchor),
            groupTableView.bottomAnchor.constraint(equalTo: groupContainer.bottomAnchor)
        ])

        rebuildGroups()
    }
    
    @objc private func closeTapped() {
        onClose?()
    }

    private func normalizedGroupName(from raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "其他" : trimmed
    }

    private func rebuildGroups() {
        groupedChannels = Dictionary(grouping: channels, by: { normalizedGroupName(from: $0.group) })
        let sortedGroupNames = groupedChannels.keys.sorted()
        groups = ["全部"] + sortedGroupNames

        if let currentChannel {
            let currentGroup = normalizedGroupName(from: currentChannel.group)
            if groups.contains(currentGroup) {
                selectedGroup = currentGroup
            } else {
                selectedGroup = "全部"
            }
        } else if !groups.contains(selectedGroup) {
            selectedGroup = "全部"
        }

        guard isViewLoaded else { return }
        groupTableView.reloadData()
        channelTableView.reloadData()
        selectCurrentGroupRow(animated: false)
    }

    private var visibleChannels: [LiveChannel] {
        if selectedGroup == "全部" { return channels }
        return groupedChannels[selectedGroup] ?? []
    }

    private func selectCurrentGroupRow(animated: Bool) {
        guard let row = groups.firstIndex(of: selectedGroup) else { return }
        let indexPath = IndexPath(row: row, section: 0)
        groupTableView.selectRow(at: indexPath, animated: animated, scrollPosition: .none)
    }
    
    func updateCurrentChannel(from previousChannel: LiveChannel?) {
        if let currentChannel {
            let currentGroup = normalizedGroupName(from: currentChannel.group)
            if groups.contains(currentGroup) {
                selectedGroup = currentGroup
            }
        }

        let shouldReloadGroups = previousChannel?.group != currentChannel?.group
        if shouldReloadGroups {
            groupTableView.reloadData()
        }
        channelTableView.reloadData()
        selectCurrentGroupRow(animated: true)
    }
}

// MARK: - UITableView DataSource & Delegate

extension ChannelListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView === groupTableView {
            return groups.count
        }
        return visibleChannels.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView === groupTableView {
            let cell = tableView.dequeueReusableCell(withIdentifier: "GroupCell", for: indexPath) as! GroupTableViewCell
            let groupName = groups[indexPath.row]
            let count = groupName == "全部" ? channels.count : (groupedChannels[groupName]?.count ?? 0)
            cell.configure(
                text: "\(groupName) (\(count))",
                selected: groupName == selectedGroup
            )
            return cell
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "ChannelCell", for: indexPath) as! ChannelTableViewCell
            let channel = visibleChannels[indexPath.row]
            let isCurrent = currentChannel?.id == channel.id
            cell.configure(with: channel, isCurrent: isCurrent)
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView === groupTableView {
            selectedGroup = groups[indexPath.row]
            groupTableView.reloadData()
            channelTableView.reloadData()
        } else {
            tableView.deselectRow(at: indexPath, animated: true)
            let channel = visibleChannels[indexPath.row]
            onChannelSelected?(channel)
        }
    }
}

class GroupTableViewCell: UITableViewCell {
    private let titleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .none

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 1
        titleLabel.textAlignment = .left
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 5),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -5)
        ])
    }

    func configure(text: String, selected: Bool) {
        titleLabel.text = text
        titleLabel.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        titleLabel.textColor = selected ? .white : UIColor.white.withAlphaComponent(0.82)
        contentView.backgroundColor = selected ? UIColor.systemBlue.withAlphaComponent(0.55) : .clear
    }
}

// MARK: - Channel Table View Cell

class ChannelTableViewCell: UITableViewCell {
    private let cardView: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 10
        v.layer.masksToBounds = true
        return v
    }()

    private let iconImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.tintColor = .gray
        iv.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        iv.layer.cornerRadius = 6
        iv.clipsToBounds = true
        return iv
    }()
    
    private let nameLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13)
        label.textColor = .white
        return label
    }()
    
    private let groupLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 10)
        label.textColor = UIColor.white.withAlphaComponent(0.7)
        return label
    }()
    
    private let playingIndicator: UIImageView = {
        let iv = UIImageView()
        iv.image = UIImage(systemName: "play.circle.fill")
        iv.tintColor = .systemBlue
        iv.isHidden = true
        return iv
    }()

    private let defaultIcon = UIImage(systemName: "tv")
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .none
        
        contentView.addSubview(cardView)
        cardView.addSubview(iconImageView)
        cardView.addSubview(nameLabel)
        cardView.addSubview(groupLabel)
        cardView.addSubview(playingIndicator)
        
        cardView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        groupLabel.translatesAutoresizingMaskIntoConstraints = false
        playingIndicator.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),

            iconImageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 10),
            iconImageView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 34),
            iconImageView.heightAnchor.constraint(equalToConstant: 34),
            
            nameLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: playingIndicator.leadingAnchor, constant: -8),
            
            groupLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            groupLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            groupLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            
            playingIndicator.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -10),
            playingIndicator.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            playingIndicator.widthAnchor.constraint(equalToConstant: 18),
            playingIndicator.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconImageView.kf.cancelDownloadTask()
        iconImageView.image = defaultIcon
        nameLabel.text = nil
        groupLabel.text = nil
        playingIndicator.isHidden = true
    }
    
    func configure(with channel: LiveChannel, isCurrent: Bool) {
        nameLabel.text = channel.name
        nameLabel.font = isCurrent ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        nameLabel.textColor = isCurrent ? .white : UIColor.white.withAlphaComponent(0.95)
        
        groupLabel.text = channel.group
        groupLabel.isHidden = channel.group?.isEmpty ?? true
        groupLabel.textColor = isCurrent ? UIColor.white.withAlphaComponent(0.9) : UIColor.white.withAlphaComponent(0.68)
        
        playingIndicator.isHidden = !isCurrent
        cardView.backgroundColor = isCurrent ? UIColor.systemBlue.withAlphaComponent(0.35) : UIColor.white.withAlphaComponent(0.06)
        cardView.layer.borderWidth = isCurrent ? 1 : 0
        cardView.layer.borderColor = isCurrent ? UIColor.systemBlue.withAlphaComponent(0.75).cgColor : UIColor.clear.cgColor
        
        // Icon
        iconImageView.image = defaultIcon
        if let logoURL = channel.logo, let url = URL(string: logoURL) {
            let processor = DownsamplingImageProcessor(size: CGSize(width: 34, height: 34))
            iconImageView.kf.indicatorType = .activity
            iconImageView.kf.setImage(
                with: url,
                placeholder: defaultIcon,
                options: [
                    .processor(processor),
                    .scaleFactor(UIScreen.main.scale),
                    .cacheOriginalImage,
                    .transition(.fade(0.15)),
                    .backgroundDecode
                ]
            )
        }
    }
}

// MARK: - View Model

class FullscreenLivePlayerViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var currentChannel: LiveChannel?
    @Published var errorMessage: String?
    
    func setup(with channel: LiveChannel) {
        currentChannel = channel
        isLoading = true
        errorMessage = nil
    }
    
    func switchToChannel(_ channel: LiveChannel) {
        currentChannel = channel
        isLoading = true
        errorMessage = nil
    }

    func updateLoadingState(_ isLoading: Bool) {
        self.isLoading = isLoading
    }

    func updateErrorState(_ message: String?) {
        errorMessage = message
        if message != nil {
            isLoading = false
        }
    }
}

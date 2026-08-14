import SwiftUI
import Combine
import Kingfisher

struct DetailView: View {
    let video: Video
    let sourceApi: String?
    let startEpisode: Episode?
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    @StateObject var contentLoader = ContentLoader()
    @StateObject var networkMonitor = NetworkMonitor.shared
    
    @State var videoDetail: Video?
    @State var playUrls: [PlayUrl] = []
    @State var episodes: [Episode] = []
    @State var selectedPlayUrl: PlayUrl?
    @State var selectedEpisode: Episode?
    @State var errorMessage: String?
    @State var currentPlayUrl: String = ""
    @State var playerErrorMessage: String?
    @State var pendingResumeTime: Double?
    @State var latestPlaybackTime: Double = 0
    @State var latestPlaybackDuration: Double = 0
    @State var hasObservedPlaybackProgress = false
    
    @State var playSources: [PlaySource] = []
    @State var selectedPlaySource: PlaySource?
    
    @State var cancellables = Set<AnyCancellable>()
    @State var initialEpisodeSet = false
    @State var showFullDescription = false
    @State var scrollOffset: CGFloat = 0
    @State var hasAppeared = false
    
    private var displayVideo: Video {
        videoDetail ?? video
    }
    
    var body: some View {
        ZStack {
            themeManager.getBackgroundColor()
                .ignoresSafeArea()
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: ScrollOffsetPreferenceKey.self,
                                       value: proxy.frame(in: .named("scroll")).minY)
                    }
                    .frame(height: 0)
                    
                    // 区域1：播放器（黑色背景）
                    HeroPlayerSection(
                        video: displayVideo,
                        currentPlayUrl: currentPlayUrl,
                        episodes: episodes,
                        selectedEpisode: selectedEpisode,
                        resumeTime: pendingResumeTime,
                        playerErrorMessage: playerErrorMessage,
                        onEpisodeSelect: { episode in
                            withAnimation {
                                selectedEpisode = episode
                                currentPlayUrl = episode.playUrl
                            }
                        },
                        onPlaybackProgress: { currentTime, duration in
                            latestPlaybackTime = currentTime
                            latestPlaybackDuration = duration
                            hasObservedPlaybackProgress = true
                            persistPlaybackHistory(for: selectedEpisode, currentTime: currentTime, duration: duration)
                        },
                        onBufferingStateChanged: { _ in },
                        onPlayerError: { message in
                            playerErrorMessage = message
                        },
                        onPlayerRetry: {
                            playerErrorMessage = nil
                        }
                    )
                    .background(Color.black)
                    
                    // 区域2：标题及以下（主题色）
                    VStack(alignment: .leading, spacing: 24) {
                        // 标题和元信息
                        TitleSection(video: displayVideo)
                        
                        // 标签
                        TagsSection(video: displayVideo)
                        
                        // 简介
                        DescriptionSection(
                            description: displayVideo.description,
                            isExpanded: $showFullDescription
                        )
                        
                        // 播放源选择
                        if playSources.count > 1 {
                            PlaySourceSection(
                                sources: playSources,
                                selectedSource: $selectedPlaySource,
                                onSourceSelect: { source in
                                    withAnimation {
                                        selectedPlaySource = source
                                        episodes = source.episodes
                                        if let first = source.episodes.first {
                                            selectedEpisode = first
                                            currentPlayUrl = first.playUrl
                                        }
                                    }
                                }
                            )
                        }
                        
                        // 分集列表
                        if !episodes.isEmpty {
                            EpisodesSection(
                                episodes: episodes,
                                selectedEpisode: $selectedEpisode,
                                onEpisodeSelect: { episode in
                                    withAnimation {
                                        selectedEpisode = episode
                                        currentPlayUrl = episode.playUrl
                                    }
                                }
                            )
                        }
                        
                        // 详细信息
                        DetailInfoSection(video: displayVideo)
                        
                        // 当前播放链接
                        if let episode = selectedEpisode {
                            CurrentEpisodeLinkSection(episode: episode)
                        }
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .background(themeManager.getBackgroundColor())
                }
            }
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                scrollOffset = value
            }
            
            // 导航栏
            DetailNavigationBar(
                title: displayVideo.title,
                scrollOffset: scrollOffset,
                onBack: {
                    // 返回操作由系统自动处理
                },
                onDismiss: onDismiss
            )
        }
        .onAppear {
            // 防止重复执行
            guard !hasAppeared else { return }
            hasAppeared = true
            
            var videoWithSource = video
            videoWithSource.sourceApi = resolvedSourceApiForHistory()
            let storedHistoryItem = PlayHistoryManager.shared.historyItem(for: videoWithSource)
            
            // 自动选中 startEpisode 或历史记录中的上次播放集数
            if let initialEpisode = startEpisode ?? storedHistoryItem?.lastEpisode {
                selectedEpisode = initialEpisode
                currentPlayUrl = initialEpisode.playUrl
                initialEpisodeSet = true
            }
            pendingResumeTime = normalizedPlaybackTime(
                storedHistoryItem?.lastPlaybackTime,
                duration: storedHistoryItem?.duration
            )
            
            // 首次进入详情时为新视频创建历史记录，已有进度则保留原记录
            if storedHistoryItem == nil {
                savePlaybackHistory(lastEpisode: selectedEpisode, currentTime: nil, duration: nil)
            }
            
            // 如果 video 已有详细信息，则直接用
            if (video.description != nil && ((video.episodes != nil && !(video.episodes?.isEmpty ?? true)) || (video.playUrls != nil && !(video.playUrls?.isEmpty ?? true)) || (video.playSources != nil && !(video.playSources?.isEmpty ?? true)))) {
                self.videoDetail = video
                self.updatePlaySourcesAndEpisodes(from: video)
            } else {
                loadVideoDetail()
            }
        }
        .onDisappear {
            if hasObservedPlaybackProgress {
                persistPlaybackHistory(
                    for: selectedEpisode,
                    currentTime: latestPlaybackTime,
                    duration: latestPlaybackDuration
                )
            }
            currentPlayUrl = ""
        }
        .onChange(of: selectedEpisode) { newEpisode in
            latestPlaybackTime = 0
            latestPlaybackDuration = 0
            hasObservedPlaybackProgress = false
            playerErrorMessage = nil
            updatePendingResumeTime(for: newEpisode)
            if initialEpisodeSet {
                initialEpisodeSet = false
                return
            }
            savePlaybackHistory(lastEpisode: newEpisode, currentTime: nil, duration: nil)
        }
    }
    
    func loadVideoDetail() {
        let source = resolvedSourceForPlayback()
        guard let realSource = source else { return }

        Task { @MainActor in
            do {
                var detail = try await contentLoader.loadVideoDetail(from: realSource, videoId: String(video.id))
                detail.sourceApi = realSource.fullURL
                self.videoDetail = detail
                self.updatePlaySourcesAndEpisodes(from: detail)
            } catch {
                // 网络错误时的错误处理
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func normalizeSourceApi(_ source: String?) -> String? {
        guard var value = source?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value.lowercased()
    }

    private func sourceMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let left = normalizeSourceApi(lhs), let right = normalizeSourceApi(rhs) else { return false }
        return left == right
    }

    private func resolvedSourceForPlayback() -> ContentSource? {
        let preferredSourceApi = sourceApi ?? video.sourceApi
        if let preferredSourceApi, !preferredSourceApi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contentSourceManager.sources.first(where: { sourceMatches($0.fullURL, preferredSourceApi) })
        }
        return contentSourceManager.selectedSource
    }

    private func resolvedSourceApiForHistory() -> String? {
        if let resolvedSource = resolvedSourceForPlayback() {
            return resolvedSource.fullURL
        }
        if let sourceApi, !sourceApi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceApi
        }
        if let sourceFromVideo = video.sourceApi, !sourceFromVideo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceFromVideo
        }
        return contentSourceManager.selectedSource?.fullURL
    }

    func updatePlaySourcesAndEpisodes(from detail: Video) {
        var parsedSources: [PlaySource] = detail.playSources ?? []
        if parsedSources.isEmpty, let playFrom = detail.source, let playUrl = detail.playUrl {
            parsedSources = Video(id: 0, title: "").parsePlaySources(from: playUrl, sourceNames: playFrom)
        }

        self.playSources = parsedSources
        
        // 优先选择包含 m3u8 的播放源
        if let m3u8Source = parsedSources.first(where: { source in
            source.episodes.contains { $0.playUrl.lowercased().contains("m3u8") }
        }) {
            self.selectedPlaySource = m3u8Source
        } else {
            self.selectedPlaySource = parsedSources.first
        }
        self.episodes = self.selectedPlaySource?.episodes ?? []

        let preferredEpisode = startEpisode ?? storedHistoryItem(for: detail)?.lastEpisode
        if let preferredEpisode {
            var matchedEpisode = self.episodes.first(where: { $0.playUrl == preferredEpisode.playUrl })
            if matchedEpisode == nil {
                matchedEpisode = self.episodes.first(where: { $0.title == preferredEpisode.title })
            }
            if matchedEpisode == nil, let epNumber = preferredEpisode.episodeNumber {
                matchedEpisode = self.episodes.first(where: { $0.episodeNumber == epNumber })
            }

            if let episode = matchedEpisode {
                self.selectedEpisode = episode
                self.currentPlayUrl = episode.playUrl
            } else if let first = self.episodes.first {
                self.selectedEpisode = first
                self.currentPlayUrl = first.playUrl
            }
        } else if let first = self.episodes.first {
            self.selectedEpisode = first
            self.currentPlayUrl = first.playUrl
        }

        updatePendingResumeTime(for: selectedEpisode)
    }

    private func storedHistoryItem(for candidateVideo: Video? = nil) -> PlayHistoryItem? {
        var historyVideo = candidateVideo ?? (videoDetail ?? video)
        historyVideo.sourceApi = resolvedSourceApiForHistory()
        return PlayHistoryManager.shared.historyItem(for: historyVideo)
    }

    private func savePlaybackHistory(lastEpisode: Episode?, currentTime: Double?, duration: Double?) {
        var historyVideo = videoDetail ?? video
        historyVideo.sourceApi = resolvedSourceApiForHistory()
        PlayHistoryManager.shared.add(
            item: PlayHistoryItem(
                video: historyVideo,
                lastEpisode: lastEpisode,
                lastPlaybackTime: normalizedPlaybackTime(currentTime, duration: duration),
                duration: normalizedDuration(duration)
            )
        )
    }

    private func persistPlaybackHistory(for episode: Episode?, currentTime: Double, duration: Double) {
        guard episode != nil else { return }
        savePlaybackHistory(lastEpisode: episode, currentTime: currentTime, duration: duration)
    }

    private func updatePendingResumeTime(for episode: Episode?) {
        guard let historyItem = storedHistoryItem(),
              episodeMatches(historyItem.lastEpisode, episode) else {
            pendingResumeTime = nil
            return
        }
        pendingResumeTime = normalizedPlaybackTime(
            historyItem.lastPlaybackTime,
            duration: historyItem.duration
        )
    }

    private func normalizedPlaybackTime(_ currentTime: Double?, duration: Double?) -> Double? {
        guard let currentTime, currentTime.isFinite, currentTime >= 5 else { return nil }
        guard let duration, duration.isFinite, duration > 0 else { return currentTime }

        let clampedTime = min(currentTime, max(duration - 1, 0))
        if duration > 60, (duration - clampedTime) < 15 || (clampedTime / duration) > 0.98 {
            return nil
        }
        return clampedTime
    }

    private func normalizedDuration(_ duration: Double?) -> Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    private func episodeMatches(_ lhs: Episode?, _ rhs: Episode?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs.playUrl == rhs.playUrl {
            return true
        }
        if lhs.title == rhs.title {
            return true
        }
        if let lhsNumber = lhs.episodeNumber, let rhsNumber = rhs.episodeNumber {
            return lhsNumber == rhsNumber
        }
        return false
    }
}

// MARK: - Scroll Offset Preference Key
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Hero Player Section
struct HeroPlayerSection: View {
    let video: Video
    let currentPlayUrl: String
    let episodes: [Episode]
    let selectedEpisode: Episode?
    let resumeTime: Double?
    let playerErrorMessage: String?
    let onEpisodeSelect: (Episode) -> Void
    let onPlaybackProgress: (Double, Double) -> Void
    let onBufferingStateChanged: (Bool) -> Void
    let onPlayerError: (String) -> Void
    let onPlayerRetry: () -> Void
    
    private var playerHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene?.windows.first
        let topSafeArea = window?.safeAreaInsets.top ?? 0
        let screenWidth = window?.bounds.width ?? UIScreen.main.bounds.width
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad {
            let targetHeight = screenWidth * 0.45 + topSafeArea
            return min(max(320, targetHeight), 540)
        } else {
            return min(280, max(220, screenWidth * 9.0 / 16.0 + topSafeArea))
        }
    }

    private var shouldUseNativePlayer: Bool {
        let normalized = currentPlayUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized.hasPrefix("rtmp://") || normalized.hasPrefix("rtsp://") {
            return true
        }

        let pathFromURL = URLComponents(string: normalized)?.path.lowercased() ?? normalized
        let purePath = pathFromURL.split(separator: "?").first?.split(separator: "#").first.map(String.init) ?? pathFromURL
        return purePath.hasSuffix(".m3u8") || purePath.hasSuffix(".mp4") || purePath.hasSuffix(".flv")
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // 纯黑色背景
            Color.black
            
            if currentPlayUrl.isEmpty {
                // 封面图
                KFImage(URL(string: video.cover ?? ""))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: playerHeight)
                    .clipped()
                
                // 顶部黑色渐变
                LinearGradient(
                    colors: [.black.opacity(0.5), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: 100)
                
                // 底部渐变遮罩
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.4), location: 0.6),
                        .init(color: .black.opacity(0.9), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 150)
            } else {
                // 播放器
                if shouldUseNativePlayer {
                    SJPlayerContainer(
                        url: currentPlayUrl,
                        episodes: episodes,
                        currentEpisode: selectedEpisode,
                        videoTitle: video.title,
                        resumeTime: resumeTime,
                        onError: onPlayerError,
                        onRetry: onPlayerRetry,
                        onSelectEpisode: onEpisodeSelect,
                        onBufferingStateChanged: onBufferingStateChanged,
                        onPlaybackProgress: onPlaybackProgress
                    )
                    .id("player_\(video.id)")
                    .frame(height: playerHeight)
                } else {
                    WebPlayerView(url: currentPlayUrl)
                        .frame(height: playerHeight)
                }

                if let playerErrorMessage, !playerErrorMessage.isEmpty {
                    VStack {
                        HStack {
                            Text(playerErrorMessage)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.72))
                                .clipShape(Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
            }
        }
        .frame(height: playerHeight)
        .background(Color.black)
    }
}

// MARK: - Detail Navigation Bar
struct DetailNavigationBar: View {
    let title: String
    let scrollOffset: CGFloat
    let onBack: () -> Void
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.presentationMode) var presentationMode
    
    private var showTitle: Bool {
        scrollOffset < -200
    }
    
    private var backgroundOpacity: Double {
        min(1.0, max(0, (-scrollOffset - 150) / 100))
    }
    
    private var safeAreaTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets.top ?? 0
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // 左侧占位
                Color.clear
                    .frame(width: 0, height: 0)
                
                Spacer()
                
                if showTitle {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                Spacer()
                
                // 右侧占位
                Color.clear
                    .frame(width: 32, height: 32)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            Spacer()
        }
        .frame(height: 60)
        .background(
            themeManager.getBackgroundColor()
                .opacity(backgroundOpacity)
                .background(backgroundOpacity > 0 ? Color(.systemBackground).opacity(0.8) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.2), value: showTitle)
    }
}

// MARK: - Title Section
struct TitleSection: View {
    let video: Video
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(video.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(2)
            
            HStack(spacing: 12) {
                if let year = video.year, !year.isEmpty {
                    MetaTag(text: year)
                }
                if let area = video.area, !area.isEmpty {
                    MetaTag(text: area)
                }
                if let lang = video.language, !lang.isEmpty {
                    MetaTag(text: lang)
                }
                if let score = video.score, !score.isEmpty, score != "0.0" {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                        Text(score)
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }
}

struct MetaTag: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(6)
    }
}

// MARK: - Tags Section
struct TagsSection: View {
    let video: Video
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let typeName = video.typeName, !typeName.isEmpty {
                    TagChip(text: typeName, color: .blue)
                }
                if let category = video.category, !category.isEmpty {
                    TagChip(text: category, color: .purple)
                }
                if let remarks = video.vodRemarks, !remarks.isEmpty {
                    TagChip(text: remarks, color: .green)
                }
                if let total = video.vodTotal, total > 0 {
                    TagChip(text: "\(total)集", color: .orange)
                }
            }
        }
    }
}

struct TagChip: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(color.opacity(0.15))
            .cornerRadius(20)
    }
}

// MARK: - Description Section
struct DescriptionSection: View {
    let description: String?
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let desc = description, !desc.isEmpty {
                Text(desc)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .animation(.easeInOut(duration: 0.3), value: isExpanded)
                
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "收起" : "展开更多")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.accentColor)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Play Source Section
struct PlaySourceSection: View {
    let sources: [PlaySource]
    @Binding var selectedSource: PlaySource?
    let onSourceSelect: (PlaySource) -> Void
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放源")
                .font(.title3)
                .fontWeight(.bold)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(sources) { source in
                        PlaySourceChip(
                            source: source,
                            isSelected: selectedSource?.id == source.id
                        ) {
                            onSourceSelect(source)
                        }
                    }
                }
            }
        }
    }
}

struct PlaySourceChip: View {
    let source: PlaySource
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(source.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .bold : .medium)
                    .foregroundColor(isSelected ? .white : .primary)
                
                Text("\(source.episodes.count) 集")
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
                .background(
                    isSelected ?
                    AnyView(LinearGradient(
                        colors: [Color.red, Color.red.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )) :
                    AnyView(Color.gray.opacity(0.15))
                )
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Episodes Section
struct EpisodesSection: View {
    let episodes: [Episode]
    @Binding var selectedEpisode: Episode?
    let onEpisodeSelect: (Episode) -> Void
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showGrid = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("分集")
                    .font(.title3)
                    .fontWeight(.bold)
                
                Spacer()
                
                // 切换视图模式
                Button(action: { showGrid.toggle() }) {
                    Image(systemName: showGrid ? "list.bullet" : "square.grid.2x2")
                        .foregroundColor(.secondary)
                }
            }
            
            if showGrid {
                // 网格视图
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 10) {
                    ForEach(episodes) { episode in
                        EpisodeGridItem(
                            episode: episode,
                            isSelected: selectedEpisode?.id == episode.id
                        ) {
                            onEpisodeSelect(episode)
                        }
                    }
                }
            } else {
                // 横向滚动列表
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(episodes) { episode in
                            EpisodeCard(
                                episode: episode,
                                isSelected: selectedEpisode?.id == episode.id
                            ) {
                                onEpisodeSelect(episode)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct EpisodeCard: View {
    let episode: Episode
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.red.opacity(0.2) : Color.gray.opacity(0.15))
                        .frame(width: 100, height: 70)
                    
                    if isSelected {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    } else {
                        Text("\(episode.episodeNumber ?? 0)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                    }
                }
                
                Text(episode.title)
                    .font(.caption)
                    .foregroundColor(isSelected ? .red : .primary)
                    .lineLimit(1)
                    .frame(width: 100)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct EpisodeGridItem: View {
    let episode: Episode
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text("\(episode.episodeNumber ?? 0)")
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .medium)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .background(
                    isSelected ?
                    Color.red :
                    Color.gray.opacity(0.15)
                )
                .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Detail Info Section
struct DetailInfoSection: View {
    let video: Video
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("详细信息")
                .font(.title3)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 0) {
                if let director = video.director, !director.isEmpty {
                    InfoRow(icon: "video.fill", color: .blue, title: "导演", value: director)
                    Divider().padding(.leading, 34)
                }
                
                if let actors = video.actors, !actors.isEmpty {
                    InfoRow(icon: "person.2.fill", color: .purple, title: "主演", value: actors)
                    Divider().padding(.leading, 34)
                }
                
                if let category = video.category, !category.isEmpty {
                    InfoRow(icon: "tv.fill", color: .orange, title: "类型", value: category)
                }
            }
            .padding(16)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
        }
    }
}

struct InfoRow: View {
    let icon: String
    let color: Color
    let title: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 22)
            
            Text(title)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .frame(width: 50, alignment: .leading)
            
            Text(value)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Current Episode Link Section
struct CurrentEpisodeLinkSection: View {
    @EnvironmentObject var themeManager: ThemeManager
    let episode: Episode
    @State private var showCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "link")
                    .foregroundColor(.secondary)
                Text("当前播放链接")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 12) {
                Text(episode.playUrl)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Spacer()
                
                Button(action: {
                    UIPasteboard.general.string = episode.playUrl
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopied = false
                    }
                }) {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline)
                        .foregroundColor(showCopied ? .green : .accentColor)
                }
            }
            .padding(12)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
        }
    }
}

#Preview {
    NavigationView {
        DetailView(
            video: Video(id: 1, title: "测试视频"),
            sourceApi: nil,
            startEpisode: nil
        )
        .environmentObject(ThemeManager())
        .environmentObject(ContentSourceManager())
    }
}

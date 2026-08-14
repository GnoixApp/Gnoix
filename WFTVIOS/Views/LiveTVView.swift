import SwiftUI
import Combine
import Kingfisher

// MARK: - Live TV View Model
class LiveTVViewModel: ObservableObject {
    @Published var channels: [LiveChannel] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedChannel: LiveChannel?
    @Published var groupedChannels: [String: [LiveChannel]] = [:]
    @Published var selectedGroup: String = "全部"
    @Published var availableGroups: [String] = ["全部"]
    @Published var showFullscreenPlayer = false
    
    private var cancellables = Set<AnyCancellable>()
    private let contentLoader = ContentLoader()
    private var lastLoadedSourcesKey: String = ""
    
    func loadChannels(from liveSources: [LiveSource], force: Bool = false) {
        guard !liveSources.isEmpty else {
            self.channels = []
            self.groupedChannels = [:]
            self.availableGroups = ["全部"]
            self.errorMessage = "暂无已启用直播源，请到设置里启用或导入直播源"
            self.lastLoadedSourcesKey = ""
            return
        }

        let loadKey = liveSources
            .map { "\($0.id.uuidString)|\($0.name)|\($0.url)|\($0.isEnabled)" }
            .sorted()
            .joined(separator: "||")
        if !force, loadKey == lastLoadedSourcesKey, !channels.isEmpty {
            return
        }
        lastLoadedSourcesKey = loadKey
        
        isLoading = true
        errorMessage = nil
        
        contentLoader.loadLiveSources(from: liveSources)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isLoading = false
                    if case .failure(let error) = completion {
                        self?.errorMessage = error.localizedDescription
                    }
                },
                receiveValue: { [weak self] channels in
                    self?.channels = channels
                    self?.groupChannels(channels)
                    if channels.isEmpty {
                        self?.errorMessage = "直播源已加载，但未解析到频道。请检查源格式（M3U/TXT）或编码。"
                    } else {
                        self?.errorMessage = nil
                    }
                }
            )
            .store(in: &cancellables)
    }
    
    private func groupChannels(_ channels: [LiveChannel]) {
        var groups: [String: [LiveChannel]] = [:]
        groups["全部"] = channels
        
        for channel in channels {
            let group = channel.group ?? "其他"
            if groups[group] == nil {
                groups[group] = []
            }
            groups[group]?.append(channel)
        }
        
        self.groupedChannels = groups
        self.availableGroups = ["全部"] + groups.keys
            .filter { $0 != "全部" }
            .sorted()
        if !availableGroups.contains(selectedGroup) {
            selectedGroup = "全部"
        }
    }
    
    func selectChannel(_ channel: LiveChannel) {
        selectedChannel = channel
        showFullscreenPlayer = true
    }
    
    var filteredChannels: [LiveChannel] {
        if selectedGroup == "全部" {
            return channels
        }
        return groupedChannels[selectedGroup] ?? []
    }
    
}

// MARK: - Live TV View
struct LiveTVView: View {
    var embedded: Bool = false
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    @EnvironmentObject var preferencesManager: UserPreferencesManager
    @ObservedObject var viewModel: LiveTVViewModel
    @State private var showGroupSidebar = false
    @State private var renderedChannelLimit = 120

    private let columns = 2
    private let spacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 16
    private let channelInitialRenderCount = 120
    private let channelRenderBatchSize = 80

    private var shouldReduceTransparency: Bool {
        preferencesManager.shouldReduceTransparency
    }

    private var cardWidth: CGFloat {
        (UIScreen.main.bounds.width - horizontalPadding * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    private var displayedChannels: [LiveChannel] {
        let limit = min(renderedChannelLimit, viewModel.filteredChannels.count)
        return Array(viewModel.filteredChannels.prefix(limit))
    }

    private var hasMoreChannelsToRender: Bool {
        displayedChannels.count < viewModel.filteredChannels.count
    }

    init(embedded: Bool = false, viewModel: LiveTVViewModel = LiveTVViewModel()) {
        self.embedded = embedded
        self.viewModel = viewModel
    }
    
    var body: some View {
        Group {
            if embedded {
                liveContent
            } else {
                NavigationView {
                    liveContent
                        .navigationTitle("电视直播")
                        .navigationBarTitleDisplayMode(.large)
                        .toolbarBackground(.visible, for: .navigationBar)
                }
                .ignoresSafeArea(.all)
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
        .fullScreenCover(isPresented: $viewModel.showFullscreenPlayer) {
            if let channel = viewModel.selectedChannel {
                FullscreenLivePlayerView(
                    initialChannel: channel,
                    allChannels: viewModel.channels
                )
                .environmentObject(contentSourceManager)
                .environmentObject(preferencesManager)
            }
        }
        .onAppear {
            loadChannels(force: false)
        }
        .onChange(of: contentSourceManager.liveSources) { _ in
            loadChannels(force: true)
        }
        .onChange(of: viewModel.selectedGroup) { _ in
            resetRenderedChannels()
        }
        .onChange(of: viewModel.channels.count) { _ in
            resetRenderedChannels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveToggleCategoryPanel)) { _ in
            guard embedded else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showGroupSidebar.toggle()
            }
        }
    }

    private var liveContent: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            
            if !viewModel.channels.isEmpty {
                channelGridView
            }

            if showGroupSidebar && !viewModel.availableGroups.isEmpty {
                groupSidebar
                    .zIndex(20)
            }
            
            // 空状态
            if viewModel.channels.isEmpty && !viewModel.isLoading {
                emptyStateView
            }
            
            // 加载中
            if viewModel.isLoading {
                loadingView
            }
            
            // 错误提示
            if let error = viewModel.errorMessage {
                errorView(error: error)
            }
        }
    }
    
    private var groupSidebar: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showGroupSidebar = false
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("直播分类")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text("\(viewModel.availableGroups.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.14))
                        )
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showGroupSidebar = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.availableGroups, id: \.self) { group in
                            let isSelected = viewModel.selectedGroup == group
                            Button {
                                viewModel.selectedGroup = group
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showGroupSidebar = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(group)
                                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                        .lineLimit(1)
                                        .foregroundColor(isSelected ? .white : .white.opacity(0.86))
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.white)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? Color.blue.opacity(0.9) : Color.white.opacity(0.12))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(width: 210)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        shouldReduceTransparency
                        ? AnyShapeStyle(Color.black.opacity(0.88))
                        : AnyShapeStyle(Material.regular)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.24))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, x: 4, y: 10)
            .padding(.leading, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Card Grid
    private var channelGridView: some View {
        ScrollView {
            let gridItems = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: spacing)]

            LazyVGrid(columns: gridItems, spacing: spacing) {
                ForEach(Array(displayedChannels.enumerated()), id: \.element.id) { index, channel in
                    Button {
                        viewModel.selectChannel(channel)
                    } label: {
                        LiveChannelGridCard(channel: channel)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        loadMoreRenderedChannelsIfNeeded(currentIndex: index)
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)

            if hasMoreChannelsToRender {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("加载更多频道...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 16)
            }
        }
    }
    
    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "tv")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text("暂无直播频道")
                .font(.title2)
                .foregroundColor(.gray)
            
            Text("请先导入包含直播源的订阅")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.7))
                .padding(.top, 8)
            
            NavigationLink(destination: SettingsView()) {
                Text("去设置")
                    .foregroundColor(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
            .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
    
    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("正在加载直播源...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).opacity(0.9))
    }
    
    // MARK: - Error View
    private func errorView(error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            
            Text(error)
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("重试") {
                loadChannels(force: true)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 30)
            .padding(.vertical, 12)
            .background(Color.blue)
            .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).opacity(0.95))
    }
    
    // MARK: - Helper Methods
    private func loadChannels(force: Bool) {
        let enabledSources = contentSourceManager.liveSources.filter { $0.isEnabled }
        viewModel.loadChannels(from: enabledSources, force: force)
    }

    private func resetRenderedChannels() {
        renderedChannelLimit = channelInitialRenderCount
    }

    private func loadMoreRenderedChannelsIfNeeded(currentIndex: Int) {
        let triggerIndex = max(0, displayedChannels.count - 16)
        guard currentIndex >= triggerIndex else { return }
        guard hasMoreChannelsToRender else { return }

        renderedChannelLimit = min(
            renderedChannelLimit + channelRenderBatchSize,
            viewModel.filteredChannels.count
        )
    }
}

// MARK: - Channel Grid Card
struct LiveChannelGridCard: View {
    let channel: LiveChannel
    var cardWidth: CGFloat? = nil
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let logoURL = channel.logo, let url = URL(string: logoURL) {
                    KFImage(url)
                        .placeholder {
                            ZStack {
                                Color.gray.opacity(0.14)
                                Image(systemName: "tv")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                        .scaleFactor(UIScreen.main.scale)
                        .backgroundDecode()
                        .cancelOnDisappear(true)
                        .fade(duration: 0.15)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Color.blue.opacity(0.5), Color.indigo.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "tv")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
            }

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.42), location: 0.35),
                    .init(color: .black.opacity(0.82), location: 1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 7) {
                Text(channel.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .foregroundColor(.white)

                if let group = channel.group, !group.isEmpty {
                    HStack(spacing: 6) {
                        Text(group)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.22))
                            .clipShape(Capsule())
                        Spacer(minLength: 0)
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.blue.opacity(0.9))
                            .clipShape(Circle())
                    }
                }
                
                if !channel.sourceName.isEmpty {
                    Text(channel.sourceName)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.white.opacity(0.82))
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: cardWidth ?? .infinity)
        .frame(height: 180)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground).opacity(0.9))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Preview
struct LiveTVView_Previews: PreviewProvider {
    static var previews: some View {
        LiveTVView()
            .environmentObject(ContentSourceManager.shared)
            .environmentObject(UserPreferencesManager())
    }
}

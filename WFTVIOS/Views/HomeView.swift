import SwiftUI
import Kingfisher

extension Notification.Name {
    static let liveToggleCategoryPanel = Notification.Name("liveToggleCategoryPanel")
}

struct HomeView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    @EnvironmentObject var preferencesManager: UserPreferencesManager
    @StateObject private var contentLoader = ContentLoader()
    @StateObject private var liveTVViewModel = LiveTVViewModel()
    
    @State private var categories: [Category] = []
    @State private var videos: [Video] = []
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var selectedCategory: Category?
    @State private var isLoading = false
    @State private var isLoadingMore = false // 新增：分页加载状态
    @State private var errorMessage: String?
    @State private var hasLoaded = false // 标记是否已加载过数据
    @State private var showErrorAlert = false
    @State private var selectedURL: String?
    @State private var selectedVideo: Video?
    @State private var currentCategoryIndex: Int = 0
    @State private var isCategoryExpanded = false
    @State private var showSourcePicker = false
    @State private var swipeDirection: Edge = .trailing
    @State private var isSwiping = false
    @State private var initialLoadSerial = 0
    @State private var videoLoadSerial = 0
    @State private var categoryContentVersion = 0
    @State private var homeSection: HomeSection = .vod
    
    @State private var categoryLoadTask: Task<Void, Never>?
    @State private var videoLoadTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    
    @Namespace private var topID // 新增：用于滚动到顶部

    private enum HomeSection: String, CaseIterable {
        case vod = "点播"
        case live = "直播"
    }
    
    private let categorySwipeMinDistance: CGFloat = 10
    private let categorySwipeIntentThreshold: CGFloat = 10
    private let categorySwipeCommitThreshold: CGFloat = 95
    private let categorySwipeDirectionBias: CGFloat = 1.2
    
    private struct HomeGridLayout {
        let columns: [GridItem]
        let horizontalPadding: CGFloat
        let spacing: CGFloat
        let cardHeight: CGFloat
        let columnCount: Int
        let isPad: Bool
    }

    private func computeGridLayout(availableWidth: CGFloat) -> HomeGridLayout {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let hPadding: CGFloat = isPad ? (availableWidth >= 1000 ? 28 : 22) : 16
        let spacing: CGFloat = isPad ? 18 : 14
        
        let columnCount: Int
        if isPad {
            if availableWidth >= 1200 {
                columnCount = 5
            } else if availableWidth >= 900 {
                columnCount = 4
            } else if availableWidth >= 600 {
                columnCount = 3
            } else {
                columnCount = 2
            }
        } else {
            if availableWidth >= 600 {
                columnCount = 4
            } else if availableWidth >= 420 {
                columnCount = 3
            } else {
                columnCount = 2
            }
        }
        
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let contentWidth = max(0, availableWidth - (hPadding * 2) - totalSpacing)
        let cardWidth = max(120, contentWidth / CGFloat(columnCount))
        let cardHeight = cardWidth * 1.42
        
        let items = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
        return HomeGridLayout(
            columns: items,
            horizontalPadding: hPadding,
            spacing: spacing,
            cardHeight: cardHeight,
            columnCount: columnCount,
            isPad: isPad
        )
    }
    
    private var currentCategoryName: String {
        if let category = categories[safe: currentCategoryIndex] {
            return category.name
        }
        return "视频"
    }

    private var shouldReduceTransparency: Bool {
        preferencesManager.shouldReduceTransparency
    }

    private func toggleCategoryPanel() {
        if homeSection == .vod {
            withAnimation(.spring()) {
                isCategoryExpanded.toggle()
            }
        } else {
            NotificationCenter.default.post(name: .liveToggleCategoryPanel, object: nil)
        }
    }

    private func toggleHomeSection() {
        homeSection = homeSection == .vod ? .live : .vod
    }
    
    // 新增：分类加载成功回调
    var onCategoriesLoaded: (() -> Void)? = nil
    var onSearchTapped: (() -> Void)? = nil
    var onHistoryTapped: (() -> Void)? = nil
    
    init(onCategoriesLoaded: (() -> Void)? = nil, onSearchTapped: (() -> Void)? = nil, onHistoryTapped: (() -> Void)? = nil) {
        self.onCategoriesLoaded = onCategoriesLoaded
        self.onSearchTapped = onSearchTapped
        self.onHistoryTapped = onHistoryTapped
    }
    
    private func closeCategorySidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCategoryExpanded = false
        }
    }
    
    // MARK: - 分类侧边栏
    private var categorySidebar: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    closeCategorySidebar()
                }
            categorySidebarPanel
        }
        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
    }
    
    private var categorySidebarPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            categorySidebarHeader
            categorySidebarList
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
    
    private var categorySidebarHeader: some View {
        HStack(spacing: 8) {
            Text("分类")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            
            Text("\(categories.count)")
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
                closeCategorySidebar()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
    
    private var categorySidebarList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    categorySidebarRow(category: category, index: index)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
    
    private func categorySidebarRow(category: Category, index: Int) -> some View {
        let isSelected = currentCategoryIndex == index
        return Button(action: {
            selectCategory(category)
            closeCategorySidebar()
        }) {
            HStack(spacing: 8) {
                Text(category.name)
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
                    .fill(isSelected ? themeManager.getAccentColor().opacity(0.92) : Color.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? 0.18 : 0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var vodActionsMenu: some View {
        Menu {
            Button {
                showSourcePicker = true
            } label: {
                Label("内容源", systemImage: "line.3.horizontal.decrease.circle")
            }

            Button {
                onHistoryTapped?()
            } label: {
                Label("播放历史", systemImage: "clock.arrow.circlepath")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.getBackgroundColor()
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    if homeSection == .vod {
                        contentList
                    } else {
                        LiveTVView(embedded: true, viewModel: liveTVViewModel)
                            .environmentObject(contentSourceManager)
                    }
                }
                
                if homeSection == .vod && isCategoryExpanded && !categories.isEmpty {
                    categorySidebar
                        .zIndex(20)
                }
            }
            .navigationTitle(homeSection == .vod ? currentCategoryName : "直播")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        toggleCategoryPanel()
                    }) {
                        Image(systemName: homeSection == .vod && isCategoryExpanded ? "xmark" : "line.3.horizontal")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: {
                            toggleHomeSection()
                        }) {
                            Image(systemName: homeSection == .vod ? "tv" : "film")
                                .font(.system(size: 15, weight: .semibold))
                        }

                        if homeSection == .vod {
                            Button(action: {
                                onSearchTapped?()
                            }) {
                                Image(systemName: "magnifyingglass")
                            }

                            vodActionsMenu
                        }
                    }
                    .font(.system(size: 16, weight: .medium))
                }
            }
            .sheet(isPresented: $showSourcePicker) {
                NavigationStack {
                    List {
                        ForEach(contentSourceManager.sources, id: \.id) { source in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name)
                                        .font(.body)
                                        .foregroundColor(contentSourceManager.selectedSource?.id == source.id ? themeManager.getAccentColor() : .primary)
                                    
                                    Text(source.url)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                                
                                if contentSourceManager.selectedSource?.id == source.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(themeManager.getAccentColor())
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                contentSourceManager.selectSource(source)
                                showSourcePicker = false
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let source = contentSourceManager.sources[index]
                                contentSourceManager.removeSource(source)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle("选择内容源")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") {
                                showSourcePicker = false
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if contentSourceManager.selectedSource != nil && !hasLoaded {
                loadInitialData()
            }
        }
        .onChange(of: homeSection) { section in
            if section == .live {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCategoryExpanded = false
                }
            }
        }
        .onChange(of: contentSourceManager.selectedSource) { newSource in
            hasLoaded = false
            cancelPendingRequests()
            if newSource != nil {
                loadInitialData()
            } else {
                categories = []
                videos = []
                isLoading = false
                isLoadingMore = false
            }
        }
        .alert("错误", isPresented: $showErrorAlert) {
            Button("确定") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    
    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "tv.slash")
                .font(.system(size: 50, weight: .light))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("暂无内容")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("当前分类下没有找到影片")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button(action: {
                loadInitialData()
            }) {
                Text("重新加载")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(themeManager.getAccentColor())
                    .cornerRadius(20)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
    
    // MARK: - Category Selector
    private var categorySelector: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        CategoryButton(
                            category: category,
                            isSelected: selectedCategory?.id == category.id
                        ) {
                            selectCategory(category)
                        }
                        .id("category_\(index)")
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
            .background(themeManager.getBackgroundColor())
            .onChange(of: currentCategoryIndex) { newIndex in
                // 确保当前选中的分类显示在屏幕内
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo("category_\(newIndex)", anchor: .center)
                }
            }
        }
    }
    
    // MARK: - Content List
    private var contentList: some View {
        GeometryReader { geometry in
            let layout = computeGridLayout(availableWidth: geometry.size.width)
            
            ZStack {
                if categories.isEmpty && isLoading {
                    // 全局初始加载骨架屏（分类尚未返回）
                    initialSkeletonView(layout: layout)
                        .transition(.opacity)
                } else if categories.isEmpty && !isLoading {
                    emptyStateView
                } else {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        if index == currentCategoryIndex {
                            categoryContentView(for: category, at: index, layout: layout)
                                .id("category_content_\(category.id.uuidString)_\(categoryContentVersion)")
                                .transition(.opacity)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.easeInOut(duration: 0.2), value: currentCategoryIndex)
            .ignoresSafeArea(edges: .bottom)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: categorySwipeMinDistance)
                    .onChanged { value in
                        handleCategorySwipeChanged(value)
                    }
                    .onEnded { value in
                        handleCategorySwipeEnded(value)
                    }
            )
        }
    }

    private func handleCategorySwipeChanged(_ value: DragGesture.Value) {
        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        let hasHorizontalIntent = horizontal > categorySwipeIntentThreshold &&
            horizontal > vertical * categorySwipeDirectionBias

        if hasHorizontalIntent && !isSwiping {
            // 一旦识别到横向意图，立即禁用卡片点击，避免误触播放
            isSwiping = true
        }
    }

    private func handleCategorySwipeEnded(_ value: DragGesture.Value) {
        defer {
            // 延迟恢复点击，避免手势结束瞬间触发 NavigationLink
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                self.isSwiping = false
            }
        }

        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        guard horizontal > categorySwipeIntentThreshold else { return }
        guard horizontal > vertical * categorySwipeDirectionBias else { return }
        guard horizontal > categorySwipeCommitThreshold else { return }

        if value.translation.width > 0 && currentCategoryIndex > 0 {
            swipeDirection = .leading
            let newIndex = currentCategoryIndex - 1
            withAnimation(.easeInOut(duration: 0.2)) {
                currentCategoryIndex = newIndex
            }
            selectCategory(categories[newIndex])
        } else if value.translation.width < 0 && currentCategoryIndex < categories.count - 1 {
            swipeDirection = .trailing
            let newIndex = currentCategoryIndex + 1
            withAnimation(.easeInOut(duration: 0.2)) {
                currentCategoryIndex = newIndex
            }
            selectCategory(categories[newIndex])
        }
    }

    // MARK: - Initial Skeleton View (During Category Loading)
    private func initialSkeletonView(layout: HomeGridLayout) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // 骨架屏顶部模拟分类胶囊栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color.gray.opacity(0.18))
                                .frame(width: CGFloat([58, 72, 64, 80, 56, 68][i % 6]), height: 34)
                                .shimmering()
                        }
                    }
                    .padding(.horizontal, layout.horizontalPadding)
                }
                .padding(.vertical, 10)
                
                // 骨架屏网格
                LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                    ForEach(0..<(layout.columnCount * 3), id: \.self) { _ in
                        VideoCardSkeleton(cardHeight: layout.cardHeight)
                    }
                }
                .padding(.horizontal, layout.horizontalPadding)
                
                Color.clear.frame(height: 120)
            }
        }
    }
    
    // MARK: - Category Content View
    private func categoryContentView(for category: Category, at index: Int, layout: HomeGridLayout) -> some View {
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    let isCurrentCategory = selectedCategory?.id == category.id
                    let showSkeleton = (isLoading && videos.isEmpty) || !isCurrentCategory
                    
                    if showSkeleton {
                        // --- 骨架屏 ---
                        LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                            ForEach(0..<(layout.columnCount * 3), id: \.self) { _ in
                                VideoCardSkeleton(cardHeight: layout.cardHeight)
                            }
                        }
                        .padding(.horizontal, layout.horizontalPadding)
                        .transition(.opacity.animation(.easeInOut))
                    } else if videos.isEmpty && !isLoading && isCurrentCategory {
                        // --- 空状态 ---
                        emptyStateView
                    } else if isCurrentCategory {
                        // --- 实际内容 ---
                        let videoList = videos.enumerated().map { (index, video) in (index, video) }
                        LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                            ForEach(videoList, id: \.0) { index, video in
                                NavigationLink(destination: DetailView(video: video, sourceApi: video.sourceApi ?? "", startEpisode: nil)) {
                                    VideoCard(video: video, cardHeight: layout.cardHeight)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .allowsHitTesting(!isSwiping)
                                .onAppear {
                                    // 滚动到底部时加载更多
                                    if index == videos.count - 3 && currentPage < totalPages && !isLoadingMore {
                                        loadMoreVideos()
                                    }
                                }
                            }
                            // 加载更多指示器
                            if isLoadingMore {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("加载更多...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                            }
                        }
                        .padding(.horizontal, layout.horizontalPadding)
                    }
                    
                    // 底部占位 - 给底部安全区域留位置
                    Color.clear.frame(height: 120)
                }
            }
        }
    }
    
    // MARK: - Data Loading
    private func cancelPendingRequests() {
        categoryLoadTask?.cancel()
        videoLoadTask?.cancel()
        loadMoreTask?.cancel()
        categoryLoadTask = nil
        videoLoadTask = nil
        loadMoreTask = nil
    }

    private func loadInitialData() {
        guard let source = contentSourceManager.selectedSource else { return }
        cancelPendingRequests()
        initialLoadSerial += 1
        let loadSerial = initialLoadSerial
        let sourceId = source.id

        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        currentPage = 1
        totalPages = 1
        videos = []

        categoryLoadTask = Task {
            do {
                let loadedCategories = try await contentLoader.loadCategories(from: source)
                await MainActor.run {
                    guard loadSerial == self.initialLoadSerial,
                          self.contentSourceManager.selectedSource?.id == sourceId else { return }
                    self.categories = loadedCategories
                    self.hasLoaded = true

                    // 恢复之前选中的分类，如果没有则选择第一个
                    if let (savedCategory, savedIndex) = self.resolveSavedCategory(in: loadedCategories, source: source) {
                        self.selectedCategory = savedCategory
                        self.currentCategoryIndex = savedIndex
                        self.loadVideosForCategoryInternal(source: source, category: savedCategory)
                    } else if let firstCategory = loadedCategories.first {
                        self.selectedCategory = firstCategory
                        self.currentCategoryIndex = 0
                        self.loadVideosForCategoryInternal(source: source, category: firstCategory)
                    } else {
                        self.isLoading = false
                    }

                    if !loadedCategories.isEmpty {
                        self.onCategoriesLoaded?()
                    }
                    self.categoryLoadTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.categoryLoadTask?.isCancelled == true {
                        self.categoryLoadTask = nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard loadSerial == self.initialLoadSerial,
                          self.contentSourceManager.selectedSource?.id == sourceId else { return }
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.showErrorAlert = true
                    }
                    self.categoryLoadTask = nil
                }
            }
        }
    }
    
    private func loadVideosForCategory(_ category: Category) {
        guard let source = contentSourceManager.selectedSource else { return }

        isLoading = true
        isLoadingMore = false
        currentPage = 1
        videos = [] // 新增：切换分类时清空视频列表，防止旧卡片闪烁
        loadVideosForCategoryInternal(source: source, category: category)
    }
    
    private func loadVideosForCategoryInternal(source: ContentSource, category: Category) {
        videoLoadSerial += 1
        videoLoadTask?.cancel()
        loadMoreTask?.cancel()
        loadMoreTask = nil
        let loadSerial = videoLoadSerial
        let sourceId = source.id
        let categoryId = category.id
        let requestedPage = currentPage

        videoLoadTask = Task {
            do {
                let response = try await contentLoader.loadVideos(from: source, category: category, page: currentPage)
                await MainActor.run {
                    guard loadSerial == self.videoLoadSerial,
                          self.contentSourceManager.selectedSource?.id == sourceId,
                          self.selectedCategory?.id == categoryId else { return }
                    self.isLoading = false
                    self.isLoadingMore = false
                    if requestedPage == 1 {
                        // 第一页，替换整个列表
                        self.videos = response.list
                    } else {
                        // 加载更多，追加到现有列表
                        let existingIDs = Set(self.videos.map(\.id))
                        let deduplicated = response.list.filter { !existingIDs.contains($0.id) }
                        self.videos.append(contentsOf: deduplicated)
                    }
                    self.totalPages = response.pagecount
                    self.videoLoadTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.videoLoadTask?.isCancelled == true {
                        self.videoLoadTask = nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard loadSerial == self.videoLoadSerial,
                          self.contentSourceManager.selectedSource?.id == sourceId,
                          self.selectedCategory?.id == categoryId else { return }
                    self.isLoading = false
                    self.isLoadingMore = false
                    self.errorMessage = error.localizedDescription
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.showErrorAlert = true
                    }
                    self.videoLoadTask = nil
                }
            }
        }
    }
    
    private func loadMoreVideos() {
        guard let source = contentSourceManager.selectedSource,
              let category = selectedCategory,
              currentPage < totalPages,
              !isLoadingMore else { return }
        videoLoadSerial += 1
        let loadSerial = videoLoadSerial
        let sourceId = source.id
        let categoryId = category.id
        let requestedPage = currentPage + 1
        isLoadingMore = true
        currentPage = requestedPage
        loadMoreTask?.cancel()
        loadMoreTask = Task {
            do {
                let response = try await contentLoader.loadVideos(from: source, category: category, page: requestedPage)
                await MainActor.run {
                    guard loadSerial == self.videoLoadSerial,
                          self.contentSourceManager.selectedSource?.id == sourceId,
                          self.selectedCategory?.id == categoryId else { return }
                    self.isLoadingMore = false
                    let existingIDs = Set(self.videos.map(\.id))
                    let deduplicated = response.list.filter { !existingIDs.contains($0.id) }
                    self.videos.append(contentsOf: deduplicated)
                    self.totalPages = response.pagecount
                    self.loadMoreTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.loadMoreTask?.isCancelled == true {
                        self.isLoadingMore = false
                        self.loadMoreTask = nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard loadSerial == self.videoLoadSerial,
                          self.contentSourceManager.selectedSource?.id == sourceId,
                          self.selectedCategory?.id == categoryId else { return }
                    self.isLoadingMore = false
                    self.currentPage = max(1, requestedPage - 1)
                    self.errorMessage = error.localizedDescription
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.showErrorAlert = true
                    }
                    self.loadMoreTask = nil
                }
            }
        }
    }
    
    // MARK: - Category Selection Methods
    private func selectCategory(_ category: Category) {
        // 切分类时递增版本号，强制刷新当前页面内容视图
        categoryContentVersion += 1
        selectedCategory = category
        preferencesManager.setSelectedCategoryId(categoryPreferenceToken(for: category))
        
        // 更新TabView的选中索引
        if let index = categories.firstIndex(where: { $0.id == category.id }) {
            currentCategoryIndex = index
        }
        
        loadVideosForCategory(category)
    }

    private func categoryPreferenceToken(for category: Category) -> String {
        let sourceKey = normalizedSourceKey(contentSourceManager.selectedSource?.fullURL ?? "")
        return "\(sourceKey)#\(category.typeId)"
    }

    private func resolveSavedCategory(in categories: [Category], source: ContentSource) -> (Category, Int)? {
        guard let savedToken = preferencesManager.preferences.selectedCategoryId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !savedToken.isEmpty else {
            return nil
        }

        let currentSourceKey = normalizedSourceKey(source.fullURL)
        if let separatorIndex = savedToken.lastIndex(of: "#") {
            let savedSourceKey = String(savedToken[..<separatorIndex])
            let typeIdPart = String(savedToken[savedToken.index(after: separatorIndex)...])
            guard savedSourceKey == currentSourceKey, let savedTypeId = Int(typeIdPart) else {
                return nil
            }
            if let index = categories.firstIndex(where: { $0.typeId == savedTypeId }) {
                return (categories[index], index)
            }
            return nil
        }

        // 兼容旧格式：仅保存 typeId（字符串）
        if let savedTypeId = Int(savedToken),
           let index = categories.firstIndex(where: { $0.typeId == savedTypeId }) {
            return (categories[index], index)
        }

        return nil
    }

    private func normalizedSourceKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

// MARK: - Category Button
struct CategoryButton: View {
    @EnvironmentObject var themeManager: ThemeManager
    let category: Category
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(category.name)
                .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isSelected ? themeManager.getAccentColor() : themeManager.getButtonBackgroundColor())
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Shimmer Effect
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let size = geo.size
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: Color.white.opacity(0.12), location: 0.35),
                            .init(color: Color.white.opacity(0.32), location: 0.5),
                            .init(color: Color.white.opacity(0.12), location: 0.65),
                            .init(color: .clear, location: 1.0)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: max(size.width * 2, 200), height: size.height)
                    .offset(x: -size.width + (phase * size.width * 2))
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 1.0
                }
            }
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Video Card
struct VideoCard: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var preferencesManager: UserPreferencesManager
    let video: Video
    var cardHeight: CGFloat? = nil

    private var shouldReduceTransparency: Bool {
        preferencesManager.shouldReduceTransparency
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // 图片部分 - 占满整个卡片
            KFImage(URL(string: video.cover ?? ""))
                .placeholder {
                    ZStack {
                        Color.gray.opacity(0.12)
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .fade(duration: 0.25)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: cardHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // 信息部分 - 覆盖在图片底部，使用渐变透明背景
            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 0)
                
                HStack(alignment: .center) {
                    // 左侧：年份和评分
                    HStack(spacing: 6) {
                        // 年份显示
                        if let year = video.year, !year.isEmpty {
                            Text(year)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                                .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 0)
                        }
                        
                        // 评分显示
                        if let score = video.score, !score.isEmpty, score != "0.0" {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                                Text(score)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 0)
                        }
                    }
                    
                    Spacer()
                    
                    // 右侧：更新状态
                    if let remarks = video.vodRemarks, !remarks.isEmpty {
                        Text(remarks)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        shouldReduceTransparency
                                        ? AnyShapeStyle(Color.black.opacity(0.76))
                                        : AnyShapeStyle(Material.ultraThin)
                                    )
                            )
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // 渐变透明背景 - 增强对比度，让文字更清晰
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.4), location: 0.25),
                        .init(color: .black.opacity(0.85), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(
                    RoundedCorner(radius: 12, corners: [.bottomLeft, .bottomRight])
                )
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.08))
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
        )
    }
}

// MARK: - Video Card Skeleton
struct VideoCardSkeleton: View {
    @EnvironmentObject var themeManager: ThemeManager
    var cardHeight: CGFloat? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            // 背景卡片底色
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.16))
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: cardHeight)

            // 文字/状态占位 - 与真实卡片结构完全对齐
            VStack(alignment: .leading, spacing: 6) {
                // 标题占位：两行
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.24))
                    .frame(width: 80, height: 14)

                HStack(alignment: .center) {
                    // 左侧年份/评分占位
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.24))
                        .frame(width: 48, height: 12)
                    
                    Spacer()
                    
                    // 右侧更新状态占位
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.24))
                        .frame(width: 44, height: 16)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.2), location: 0.25),
                        .init(color: .black.opacity(0.55), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(
                    RoundedCorner(radius: 12, corners: [.bottomLeft, .bottomRight])
                )
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.getCardBackgroundColor())
                .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
        )
        .shimmering()
    }
}

// 辅助扩展：只圆角底部
struct RoundedCorner: Shape {
    var radius: CGFloat = 10.0
    var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

#Preview {
    HomeView()
        .environmentObject(ThemeManager())
        .environmentObject(ContentSourceManager())
        .environmentObject(UserPreferencesManager())
} 

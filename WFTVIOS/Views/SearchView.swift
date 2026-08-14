import SwiftUI

private struct SearchSourceResult: Identifiable {
    let id: UUID
    let sourceName: String
    let sourceApi: String
    var keyword: String
    var videos: [Video]
    var currentPage: Int
    var totalPages: Int
    var totalCount: Int

    var hasMorePages: Bool {
        currentPage < totalPages
    }
}

struct SearchView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    @StateObject private var contentLoader = ContentLoader()
    
    @State private var searchText = ""
    @State private var searchResults: [SearchSourceResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var sourceOrder: [UUID] = []
    @State private var totalSourceCount = 0
    @State private var finishedSourceCount = 0
    @State private var searchTasks: [Task<Void, Never>] = []
    @State private var searchSessionID = UUID()
    
    var onDismiss: (() -> Void)? = nil
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 搜索栏
                searchBar
                
                // 搜索结果
                if hasSearched {
                    searchResultsView
                } else {
                    // 默认显示热门搜索建议
                    searchSuggestionsView
                }
            }
            .background(themeManager.getBackgroundColor())
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if onDismiss != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") {
                            onDismiss?()
                        }
                    }
                }
            }
        }
        .onDisappear {
            cancelSearchRequests()
        }
        .ignoresSafeArea(.all)
    }
    
    // MARK: - Search Bar
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            
            TextField("输入影视名称...", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .onSubmit {
                    performSearch()
                }
            
            if !searchText.isEmpty {
                Button(action: {
                    cancelSearchRequests()
                    searchText = ""
                    searchResults.removeAll()
                    sourceOrder.removeAll()
                    totalSourceCount = 0
                    finishedSourceCount = 0
                    isLoading = false
                    hasSearched = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
            }
            // 新增：搜索按钮
            Button(action: {
                performSearch()
            }) {
                Text("搜索")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.gray
                            : themeManager.getAccentColor()
                    )
                    .cornerRadius(8)
            }
            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(themeManager.getSecondaryBackgroundColor())
        .cornerRadius(10)
        .padding(.horizontal)
    }
    
    // MARK: - Search Suggestions
    private var searchSuggestionsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("热门搜索")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 12)], spacing: 12) {
                ForEach(hotSearchKeywords, id: \.self) { keyword in
                    Button(action: {
                        searchText = keyword
                        performSearch()
                    }) {
                        Text(keyword)
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(themeManager.getSecondaryBackgroundColor())
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .padding(.top)
    }
    
    // MARK: - Search Results
    private var searchResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if hasSearched {
                    HStack(spacing: 8) {
                        Text("已检索 \(finishedSourceCount)/\(totalSourceCount) 个源")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer(minLength: 8)
                        Text("命中 \(totalHitCount) 条")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(themeManager.getAccentColor())
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(themeManager.getSecondaryBackgroundColor())
                    .cornerRadius(12)
                }

                if isLoading && orderedSearchResults.isEmpty {
                    ProgressView("正在聚合各视频源结果...")
                        .padding(.top, 20)
                        .frame(maxWidth: .infinity)
                } else if orderedSearchResults.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        
                        Text("未找到相关内容")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        
                        Text("请尝试其他关键词")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 30)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(orderedSearchResults) { result in
                            SearchResultSection(
                                sourceID: result.id,
                                sourceName: result.sourceName,
                                sourceApi: result.sourceApi,
                                keyword: result.keyword,
                                videos: result.videos,
                                currentPage: result.currentPage,
                                totalPages: result.totalPages,
                                totalCount: result.totalCount
                            )
                        }
                    }
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.9)
                            Text("继续加载更多源结果...")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()
        }
    }
    
    // MARK: - Search Logic
    private func performSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }

        cancelSearchRequests()
        let sessionID = UUID()
        searchSessionID = sessionID

        isLoading = true
        hasSearched = true
        searchResults.removeAll()
        sourceOrder.removeAll()
        errorMessage = nil

        let activeSources = contentSourceManager.getActiveSources().filter { $0.sourceType == .vod }
        sourceOrder = activeSources.map(\.id)
        totalSourceCount = activeSources.count
        finishedSourceCount = 0

        guard !activeSources.isEmpty else {
            isLoading = false
            return
        }

        for source in activeSources {
            let task = Task {
                do {
                    let response = try await contentLoader.searchVideos(from: source, keyword: keyword)
                    let videos = response.list.map { video -> Video in
                        var updatedVideo = video
                        if updatedVideo.sourceApi?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ?? true {
                            updatedVideo.sourceApi = source.fullURL
                        }
                        return updatedVideo
                    }

                    await MainActor.run {
                        guard searchSessionID == sessionID else { return }
                        finishedSourceCount += 1
                        if !videos.isEmpty {
                            upsertResult(
                                source: source,
                                keyword: keyword,
                                videos: videos,
                                currentPage: response.page,
                                totalPages: response.pagecount,
                                totalCount: response.total
                            )
                        }
                        if finishedSourceCount >= totalSourceCount {
                            isLoading = false
                            searchTasks.removeAll()
                        }
                    }
                } catch is CancellationError {
                    // 搜索会在新一轮请求时主动取消，取消场景不提示错误。
                } catch {
                    await MainActor.run {
                        guard searchSessionID == sessionID else { return }
                        finishedSourceCount += 1
                        if errorMessage == nil {
                            errorMessage = error.localizedDescription
                        }
                        if finishedSourceCount >= totalSourceCount {
                            isLoading = false
                            searchTasks.removeAll()
                        }
                    }
                }
            }
            searchTasks.append(task)
        }
    }

    private var orderedSearchResults: [SearchSourceResult] {
        let orderMap = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($1, $0) })
        return searchResults.sorted {
            orderMap[$0.id, default: Int.max] < orderMap[$1.id, default: Int.max]
        }
    }

    private var totalHitCount: Int {
        orderedSearchResults.reduce(0) { $0 + $1.videos.count }
    }

    private func upsertResult(
        source: ContentSource,
        keyword: String,
        videos: [Video],
        currentPage: Int,
        totalPages: Int,
        totalCount: Int
    ) {
        if let index = searchResults.firstIndex(where: { $0.id == source.id }) {
            searchResults[index].keyword = keyword
            searchResults[index].videos = videos
            searchResults[index].currentPage = max(currentPage, 1)
            searchResults[index].totalPages = max(totalPages, 1)
            searchResults[index].totalCount = max(totalCount, videos.count)
        } else {
            searchResults.append(
                SearchSourceResult(
                    id: source.id,
                    sourceName: source.name,
                    sourceApi: source.fullURL,
                    keyword: keyword,
                    videos: videos,
                    currentPage: max(currentPage, 1),
                    totalPages: max(totalPages, 1),
                    totalCount: max(totalCount, videos.count)
                )
            )
        }
    }

    private func cancelSearchRequests() {
        searchSessionID = UUID()
        searchTasks.forEach { $0.cancel() }
        searchTasks.removeAll()
    }
    
    // MARK: - Hot Search Keywords
    private var hotSearchKeywords: [String] {
        return [
            "复仇者联盟",
            "权力的游戏",
            "速度与激情",
            "哈利波特",
            "指环王",
            "星球大战",
            "泰坦尼克号",
            "阿凡达",
            "盗梦空间",
            "肖申克的救赎"
        ]
    }
}

// MARK: - Search Result Section
struct SearchResultSection: View {
    @EnvironmentObject var themeManager: ThemeManager
    let sourceID: UUID
    let sourceName: String
    let sourceApi: String
    let keyword: String
    let videos: [Video]
    let currentPage: Int
    let totalPages: Int
    let totalCount: Int

    private var previewVideos: [Video] {
        Array(videos.prefix(6))
    }

    private var loadedCount: Int {
        videos.count
    }

    private var expectedCount: Int {
        max(totalCount, loadedCount)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(sourceName)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(loadedCount) 条")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(themeManager.getAccentColor())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(themeManager.getSecondaryBackgroundColor())
                    .cornerRadius(999)
            }
            .padding(.horizontal)

            Text("已加载第 \(currentPage)/\(max(totalPages, 1)) 页")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)], spacing: 12) {
                ForEach(previewVideos) { video in
                    NavigationLink(destination: SearchDetailLoaderView(video: video, sourceName: sourceName, sourceApi: sourceApi)) {
                        SearchResultCard(video: video)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            
            if videos.count > 6 || currentPage < totalPages {
                NavigationLink(
                    destination: SearchResultListView(
                        sourceID: sourceID,
                        sourceName: sourceName,
                        sourceApi: sourceApi,
                        keyword: keyword,
                        initialVideos: videos,
                        initialPage: currentPage,
                        initialTotalPages: totalPages,
                        initialTotalCount: totalCount
                    )
                ) {
                    HStack(spacing: 8) {
                        Text("查看更多")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(themeManager.getAccentColor())
                        Spacer()
                        Text("已加载 \(loadedCount)/\(expectedCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(themeManager.getSecondaryBackgroundColor())
                    .cornerRadius(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(themeManager.getCardBackgroundColor().opacity(0.75))
        .cornerRadius(14)
    }
}

// MARK: - Search Result Card
struct SearchResultCard: View {
    @EnvironmentObject var themeManager: ThemeManager
    let video: Video
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面图片
            AsyncImage(url: URL(string: video.cover ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    )
            }
            .frame(height: 100)
            .clipped()
            .cornerRadius(8)
            
            // 标题
            Text(video.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .foregroundColor(.primary)
            
            // 年份和评分
            HStack {
                if let year = video.year {
                    Text(year)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let score = video.score {
                    Spacer()
                    Text(score)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }
            // 新增：更新状态
            if let remarks = video.vodRemarks, !remarks.isEmpty {
                Text(remarks)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.getAccentColor())
                    .lineLimit(1)
            }
        }
        .padding(6)
        .background(themeManager.getCardBackgroundColor())
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Search Result List View
struct SearchResultListView: View {
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    @StateObject private var contentLoader = ContentLoader()

    let sourceID: UUID
    let sourceName: String
    let sourceApi: String
    let keyword: String

    @State private var videos: [Video]
    @State private var currentPage: Int
    @State private var totalPages: Int
    @State private var totalCount: Int
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?

    init(
        sourceID: UUID,
        sourceName: String,
        sourceApi: String,
        keyword: String,
        initialVideos: [Video],
        initialPage: Int,
        initialTotalPages: Int,
        initialTotalCount: Int
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.sourceApi = sourceApi
        self.keyword = keyword
        _videos = State(initialValue: initialVideos)
        _currentPage = State(initialValue: max(initialPage, 1))
        _totalPages = State(initialValue: max(initialTotalPages, 1))
        _totalCount = State(initialValue: max(initialTotalCount, initialVideos.count))
    }

    private var canLoadMore: Bool {
        currentPage < totalPages
    }

    private var loadedText: String {
        "已加载 \(videos.count)/\(max(totalCount, videos.count))"
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(loadedText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)], spacing: 12) {
                    ForEach(videos) { video in
                        NavigationLink(destination: DetailView(video: video, sourceApi: video.sourceApi ?? sourceApi, startEpisode: nil)) {
                            SearchResultCard(video: video)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                if canLoadMore {
                    VStack(spacing: 8) {
                        if isLoadingMore {
                            ProgressView("正在加载更多...")
                        } else {
                            Text("下滑到底自动加载更多")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .onAppear {
                                    loadMoreIfNeeded()
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                if let loadMoreError {
                    VStack(spacing: 8) {
                        Text(loadMoreError)
                            .font(.footnote)
                            .foregroundColor(.red)
                        Button("重试加载更多") {
                            loadMoreIfNeeded(forceRetry: true)
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .padding()
        }
        .navigationTitle("全部结果 - \(sourceName)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if canLoadMore {
                loadMoreIfNeeded(forceRetry: true)
            }
        }
    }

    private func normalizeSource(_ value: String?) -> String? {
        guard var normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return nil
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.lowercased()
    }

    private func resolveSource() -> ContentSource? {
        if let byID = contentSourceManager.getSource(by: sourceID) {
            return byID
        }
        let target = normalizeSource(sourceApi)
        return contentSourceManager.sources.first(where: { normalizeSource($0.fullURL) == target })
    }

    private func loadMoreIfNeeded(forceRetry: Bool = false) {
        guard (canLoadMore || forceRetry), !isLoadingMore else { return }
        guard let source = resolveSource() else {
            loadMoreError = "未找到对应内容源，请返回重新搜索"
            return
        }
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isLoadingMore = true
        loadMoreError = nil
        let nextPage = currentPage + 1

        Task {
            do {
                let response = try await contentLoader.searchVideos(from: source, keyword: keyword, page: nextPage)
                let incoming = response.list.map { video -> Video in
                    var patched = video
                    if patched.sourceApi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        patched.sourceApi = source.fullURL
                    }
                    return patched
                }

                await MainActor.run {
                    mergeVideos(incoming)
                    currentPage = max(response.page, nextPage)
                    totalPages = max(response.pagecount, currentPage)
                    totalCount = max(response.total, videos.count)
                    isLoadingMore = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    isLoadingMore = false
                }
            } catch {
                await MainActor.run {
                    loadMoreError = "加载失败：\(error.localizedDescription)"
                    isLoadingMore = false
                }
            }
        }
    }

    private func mergeVideos(_ incoming: [Video]) {
        guard !incoming.isEmpty else { return }
        var seen = Set(videos.map { searchVideoKey(for: $0) })
        for video in incoming {
            let key = searchVideoKey(for: video)
            if seen.insert(key).inserted {
                videos.append(video)
            }
        }
    }

    private func searchVideoKey(for video: Video) -> String {
        let sourcePart = normalizeSource(video.sourceApi) ?? normalizeSource(sourceApi) ?? "unknown"
        return "\(video.id)#\(sourcePart)"
    }
}

// MARK: - Search Detail Loader View
struct SearchDetailLoaderView: View {
    let video: Video
    let sourceName: String
    let sourceApi: String?
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    @StateObject private var contentLoader = ContentLoader()
    @State private var detailVideo: Video? = nil
    @State private var isLoading = true
    @State private var errorType: ErrorType? = nil
    @State private var detailTask: Task<Void, Never>? = nil
    @State private var detailRequestID = UUID()
    
    enum ErrorType {
        case notFound
        case noData
        case network
    }
    
    var body: some View {
        Group {
            if let detailVideo = detailVideo {
                DetailView(video: detailVideo, sourceApi: detailVideo.sourceApi, startEpisode: nil)
            } else if isLoading {
                VStack {
                    ProgressView("加载详情中...")
                        .padding()
                }
            } else if let errorType = errorType {
                VStack(spacing: 16) {
                    if errorType == .notFound {
                        Text("未找到内容源")
                            .foregroundColor(.secondary)
                    } else if errorType == .noData {
                        Text("暂无详情，资源暂不可用")
                            .foregroundColor(.secondary)
                    } else {
                        Text("加载失败，请检查网络或稍后重试")
                            .foregroundColor(.red)
                        Button("重试") {
                            retryLoadDetail()
                        }
                        .padding(.top, 8)
                    }
                }
                .padding()
            }
        }
        .onAppear {
            loadDetail()
        }
        .onDisappear {
            detailTask?.cancel()
            detailTask = nil
        }
    }
    
    private func loadDetail() {
        isLoading = true
        errorType = nil
        guard let source = resolveSource() else {
            self.errorType = .notFound
            self.isLoading = false
            return
        }
        let videoIdStr = String(video.id)
        detailTask?.cancel()
        let requestID = UUID()
        detailRequestID = requestID
        detailTask = Task {
            do {
                var detail = try await contentLoader.loadVideoDetail(from: source, videoId: videoIdStr)
                detail.sourceApi = source.fullURL
                await MainActor.run {
                    guard detailRequestID == requestID else { return }
                    self.detailVideo = detail
                    self.isLoading = false
                }
            } catch is CancellationError {
                // 页面切换或重试会触发取消，忽略即可。
            } catch {
                await MainActor.run {
                    guard detailRequestID == requestID else { return }
                    let desc = error.localizedDescription
                    if desc.contains("无数据") {
                        self.errorType = .noData
                    } else if desc.contains("未找到内容源") {
                        self.errorType = .notFound
                    } else {
                        self.errorType = .network
                    }
                    self.isLoading = false
                }
            }
        }
    }
    
    private func retryLoadDetail() {
        self.detailVideo = nil
        self.isLoading = true
        self.errorType = nil
        loadDetail()
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

    private func sourceMatches(_ source: ContentSource, api: String?) -> Bool {
        guard let target = normalizeSourceApi(api), let current = normalizeSourceApi(source.fullURL) else {
            return false
        }
        return target == current
    }

    private func resolveSource() -> ContentSource? {
        let preferredApi = video.sourceApi ?? sourceApi
        if let preferredApi, !preferredApi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contentSourceManager.sources.first(where: { sourceMatches($0, api: preferredApi) })
        }
        return contentSourceManager.sources.first(where: { $0.name == sourceName })
    }
}

#Preview {
    SearchView()
        .environmentObject(ThemeManager())
        .environmentObject(ContentSourceManager())
} 

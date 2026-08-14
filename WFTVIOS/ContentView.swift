import SwiftUI
import Kingfisher

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    @EnvironmentObject var preferencesManager: UserPreferencesManager
    @State private var selectedTab = 0
    private let homeOnCategoriesLoaded: () -> Void = {}
    @State private var hasCustomPages = false
    @State private var currentCustomPageName = "自定义"
    @State private var showSearch = false
    @State private var showHistory = false
    @State private var selectedVideo: Video?
    @State private var showDetail = false
    @State private var selectedHistoryItem: PlayHistoryItem?
    @State private var hasLoadedBookshelf = false
    @State private var hasLoadedExplore = false
    @State private var hasLoadedCustomPage = false
    
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(onCategoriesLoaded: homeOnCategoriesLoaded, onSearchTapped: {
                showSearch = true
            }, onHistoryTapped: {
                showHistory = true
            })
            .tabItem {
                Image(systemName: "play.rectangle")
                Text("视频")
            }
            .tag(0)
            
            Group {
                if hasLoadedBookshelf || selectedTab == 1 {
                    BookshelfViewControllerRepresentable()
                        .ignoresSafeArea()
                        .onAppear { hasLoadedBookshelf = true }
                } else {
                    Color.clear
                }
            }
                .tabItem {
                    Image(systemName: "books.vertical")
                    Text("小说")
                }
                .tag(1)
            
            Group {
                if hasLoadedExplore || selectedTab == 2 {
                    ExploreViewControllerRepresentable()
                        .ignoresSafeArea()
                        .onAppear { hasLoadedExplore = true }
                } else {
                    Color.clear
                }
            }
                .tabItem {
                    Image(systemName: "sparkles")
                    Text("发现")
                }
                .tag(2)
            
            if hasCustomPages {
                Group {
                    if hasLoadedCustomPage || selectedTab == 3 {
                        CustomWebView()
                            .ignoresSafeArea()
                            .onAppear { hasLoadedCustomPage = true }
                    } else {
                        Color.clear
                    }
                }
                    .tabItem {
                        Image(systemName: "globe")
                        Text(getCurrentCustomPageName())
                    }
                    .tag(3)
            }
            
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("设置")
                }
                .tag(hasCustomPages ? 4 : 3)
        }
        .accentColor(themeManager.getAccentColor())
        .ignoresSafeArea(.all)
        .onAppear {
            if contentSourceManager.selectedSource == nil && !contentSourceManager.sources.isEmpty {
                if let firstSource = contentSourceManager.sources.first {
                    contentSourceManager.selectSource(firstSource)
                }
            }
            hasCustomPages = !preferencesManager.enabledCustomWebPages.isEmpty
            updateCurrentCustomPageName()
            markCurrentTabLoadedIfNeeded(selectedTab)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToCustomPage"))) { notification in
            if let page = notification.object as? CustomWebPage {
                currentCustomPageName = page.name
            }
        }
        .onChange(of: preferencesManager.enabledCustomWebPages) { pages in
            let newHasCustomPages = !pages.isEmpty
            if hasCustomPages != newHasCustomPages {
                withAnimation(.easeInOut(duration: 0.3)) {
                    hasCustomPages = newHasCustomPages
                }
                if !newHasCustomPages && selectedTab == 3 {
                    selectedTab = 0
                }
            }
            updateCurrentCustomPageName()
        }
        .onChange(of: contentSourceManager.selectedSource) { _ in
            selectedTab = 0
        }
        .onChange(of: contentSourceManager.sources) { sources in
            if contentSourceManager.selectedSource == nil && !sources.isEmpty {
                if let firstSource = sources.first {
                    contentSourceManager.selectSource(firstSource)
                }
            }
        }
        .onChange(of: selectedTab) { tab in
            markCurrentTabLoadedIfNeeded(tab)
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView(onDismiss: {
                showSearch = false
            })
        }
        .sheet(isPresented: $showHistory) {
            NavigationView {
                HistoryViewWrapper(
                    onSelect: { item in
                        selectedHistoryItem = item
                        showHistory = false
                        selectedVideo = item.video
                        showDetail = true
                    }
                )
                .environmentObject(themeManager)
            }
        }
        .sheet(isPresented: $showDetail) {
            ZStack {
                if let video = selectedVideo {
                    let historyItem = selectedHistoryItem ?? PlayHistoryManager.shared.history.first(where: {
                        $0.video.id == video.id && sourceMatches($0.video.sourceApi, video.sourceApi)
                    })
                    let sourceApi = historyItem?.video.sourceApi ?? resolvedSourceApi(for: video)
                    let lastEp = historyItem?.lastEpisode

                    DetailView(video: video, sourceApi: sourceApi, startEpisode: lastEp, onDismiss: {
                        showDetail = false
                    })
                        .environmentObject(themeManager)
                        .environmentObject(contentSourceManager)
                        .environmentObject(preferencesManager)
                } else {
                    Color.black.edgesIgnoringSafeArea(.all)
                }
            }
        }
        .onChange(of: showDetail) { isShowing in
            if !isShowing {
                selectedVideo = nil
                selectedHistoryItem = nil
            }
        }
    }
    
    private func getCurrentCustomPageName() -> String {
        return currentCustomPageName
    }
    
    private func updateCurrentCustomPageName() {
        if preferencesManager.enabledCustomWebPages.isEmpty {
            currentCustomPageName = "自定义"
        } else {
            currentCustomPageName = preferencesManager.selectedCustomWebPage?.name ?? "自定义"
        }
    }

    private func markCurrentTabLoadedIfNeeded(_ tab: Int) {
        switch tab {
        case 1:
            hasLoadedBookshelf = true
        case 2:
            hasLoadedExplore = true
        case 3 where hasCustomPages:
            hasLoadedCustomPage = true
        default:
            break
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
        guard let left = normalizeSourceApi(lhs), let right = normalizeSourceApi(rhs) else {
            return false
        }
        return left == right
    }

    private func resolvedSourceApi(for video: Video) -> String? {
        if let sourceApi = video.sourceApi,
           let matched = contentSourceManager.sources.first(where: { sourceMatches($0.fullURL, sourceApi) }) {
            return matched.fullURL
        }
        return video.sourceApi ?? contentSourceManager.selectedSource?.fullURL
    }
}

struct HistoryViewWrapper: View {
    @ObservedObject var manager = PlayHistoryManager.shared
    @EnvironmentObject var themeManager: ThemeManager
    var onSelect: ((PlayHistoryItem) -> Void)?
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(manager.history) { item in
                    Button(action: {
                        onSelect?(item)
                    }) {
                        HStack(alignment: .center, spacing: 14) {
                            KFImage(URL(string: item.video.cover ?? ""))
                                .placeholder {
                                    Color.gray.opacity(0.15)
                                }
                                .resizable()
                                .aspectRatio(1, contentMode: .fill)
                                .frame(width: 80, height: 80)
                                .clipped()
                                .cornerRadius(10)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.video.title)
                                    .font(.headline)
                                    .foregroundColor(themeManager.getTextColor())
                                    .lineLimit(2)
                                if let ep = item.lastEpisode {
                                    Text("上次看到：\(ep.title)")
                                        .font(.subheadline)
                                        .foregroundColor(themeManager.getAccentColor())
                                }
                                Text(item.playedAt, style: .date)
                                    .font(.caption2)
                                    .foregroundColor(themeManager.getSecondaryTextColor())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(themeManager.getCardBackgroundColor())
                        .cornerRadius(14)
                        .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 2)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
        }
        .background(themeManager.getBackgroundColor())
        .navigationTitle("播放历史")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") {
                    manager.clear()
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .environmentObject(ContentSourceManager())
        .environmentObject(UserPreferencesManager())
}

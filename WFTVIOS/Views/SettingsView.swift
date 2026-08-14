import SwiftUI
import UniformTypeIdentifiers

// MARK: - Enhanced Settings View
struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    @EnvironmentObject var preferencesManager: UserPreferencesManager
    
    // MARK: - State
    @State private var showingAddSource = false
    @State private var showingImportSheet = false
    @State private var importText = ""
    @State private var importURLString = ""
    @State private var importMethod: ImportMethod = .text
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showSourceSwitchToast = false
    @State private var showingClearCacheAlert = false
    @State private var cacheSize = "计算中..."
    @State private var showingAddCustomWebPage = false
    @State private var showingServerConnect = false
    @State private var showingBookSourceManagement = false
    @State private var showingReplaceRuleManagement = false
    @State private var showingRSSManagement = false
    @State private var showingBookmarkManagement = false
    @State private var showingReadingHistory = false
    @State private var showingBookGroupManagement = false
    @State private var isServerParseMode = BookParseManager.shared.isServerMode
    @State private var showingAddLiveSource = false
    @State private var showingConfigExporter = false
    @State private var showingConfigImporter = false
    @State private var exportConfigDocument: AppConfigBackupDocument?

    private let bookSourceSubscriptionsUserDefaultsKey = "book_source_subscriptions_v1"
    private let bookSourceHealthCheckedKeysUserDefaultsKey = "book_source_health_checked_keys_v1"
    
    var body: some View {
        NavigationView {
            List {
                // 主题设置
                themeSection
                
                // 小说设置
                legadoSection
                
                // 内容源管理
                contentSourceSection
                
                // 直播源管理
                liveSourceSection
                
                // 自定义页面设置
                customWebPageSection
                
                // 存储管理
                storageSection
                
                // 关于
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(isPresented: $showingAddSource) {
            AddSourceView()
        }
        .sheet(isPresented: $showingImportSheet) {
            ImportSourcesView(
                importText: $importText,
                importURLString: $importURLString,
                importMethod: $importMethod
            ) {
                await importSources()
            }
        }
        .sheet(isPresented: $showingAddLiveSource) {
            AddLiveSourceView()
        }
        .alert("提示", isPresented: $showingAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
        }
        .alert("清理缓存", isPresented: $showingClearCacheAlert) {
            Button("取消", role: .cancel) { }
            Button("确定", role: .destructive) {
                preferencesManager.clearCache {
                    updateCacheSize()
                    alertMessage = "缓存已清理"
                    showingAlert = true
                }
            }
        } message: {
            Text("确定要清理所有缓存数据吗？这将删除已下载的图片和临时文件。")
        }
        .alert("清除所有内容源", isPresented: $showingClearAllSourcesAlert) {
            Button("取消", role: .cancel) { }
            Button("确定", role: .destructive) {
                contentSourceManager.clearAllSources()
                alertMessage = "已清除所有内容源"
                showingAlert = true
            }
        } message: {
            Text("确定要清除所有影视源和直播源吗？此操作不可恢复。")
        }
        .sheet(isPresented: $showingAddCustomWebPage) {
            AddCustomWebPageView()
        }
        .sheet(isPresented: $showingServerConnect) {
            ServerConnectViewControllerRepresentable()
        }
        .sheet(isPresented: $showingBookSourceManagement) {
            BookSourceViewControllerRepresentable()
                .ignoresSafeArea()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingReplaceRuleManagement) {
            ReplaceRuleViewControllerRepresentable()
                .ignoresSafeArea()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingRSSManagement) {
            RSSSourceViewControllerRepresentable()
                .ignoresSafeArea()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingBookmarkManagement) {
            BookmarkViewControllerRepresentable()
                .ignoresSafeArea()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingReadingHistory) {
            ReadingHistoryViewControllerRepresentable()
                .ignoresSafeArea()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingBookGroupManagement) {
            BookGroupViewControllerRepresentable()
                .ignoresSafeArea()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fileExporter(
            isPresented: $showingConfigExporter,
            document: exportConfigDocument,
            contentType: .json,
            defaultFilename: backupFilename()
        ) { result in
            switch result {
            case .success:
                alertMessage = "配置导出成功"
            case .failure(let error):
                alertMessage = "导出失败：\(error.localizedDescription)"
            }
            showingAlert = true
            exportConfigDocument = nil
        }
        .fileImporter(
            isPresented: $showingConfigImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleConfigImportResult(result)
        }
        .onAppear {
            updateCacheSize()
            syncThemeSettings()
            isServerParseMode = BookParseManager.shared.isServerMode
        }
        .onChange(of: isServerParseMode) { newValue in
            BookParseManager.shared.setServerMode(newValue)
        }
    }
    
    // MARK: - Theme Section
    private var themeSection: some View {
        Section("外观主题") {
            Picker("主题", selection: Binding(
                get: { themeManager.getCurrentTheme() },
                set: { newTheme in
                    if themeManager.getCurrentTheme() != newTheme {
                        themeManager.setTheme(newTheme)
                    }
                }
            )) {
                ForEach([Theme.system, Theme.light, Theme.dark], id: \.self) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(SegmentedPickerStyle())

            Text("自动会跟随手机的深色/浅色模式")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle(isOn: Binding(
                get: { preferencesManager.reduceTransparency },
                set: { preferencesManager.setReduceTransparency($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("降低透明效果")
                    Text("减少磨砂/材质特效，优先保证交互流畅")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Legado Section
    private var legadoSection: some View {
        Section(header: Text("小说解析").font(.caption)) {
            Picker("解析方式", selection: $isServerParseMode) {
                Text("服务器API").tag(true)
                Text("本地解析").tag(false)
            }
            .pickerStyle(.segmented)
            
            Button(action: {
                showingServerConnect = true
            }) {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundColor(.blue)
                    Text("阅读服务器")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(isServerParseMode ? "服务器模式" : "本地模式")
                        .font(.caption)
                        .foregroundColor(isServerParseMode ? .green : .orange)
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            Button(action: {
                showingBookSourceManagement = true
            }) {
                HStack {
                    Image(systemName: "books.vertical")
                        .foregroundColor(.green)
                    Text("书源管理")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            Button(action: {
                showingReplaceRuleManagement = true
            }) {
                HStack {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.purple)
                    Text("替换净化")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                showingRSSManagement = true
            }) {
                HStack {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .foregroundColor(.cyan)
                    Text("RSS订阅")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                showingBookmarkManagement = true
            }) {
                HStack {
                    Image(systemName: "bookmark")
                        .foregroundColor(.orange)
                    Text("书签管理")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                showingReadingHistory = true
            }) {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.indigo)
                    Text("阅读记录")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                showingBookGroupManagement = true
            }) {
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.teal)
                    Text("分组管理")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    // MARK: - Content Source Section
    private var contentSourceSection: some View {
        Section(header: Text("内容源管理").font(.caption)) {
            Button(action: {
                showingAddSource = true
            }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                    Text("添加内容源")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            Button(action: {
                showingImportSheet = true
            }) {
                HStack {
                    Image(systemName: "square.and.arrow.down.fill")
                        .foregroundColor(.blue)
                    Text("导入内容源")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                exportAllConfigToFile()
            }) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.indigo)
                    Text("导出整包配置")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("影视/直播/小说书源")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                showingConfigImporter = true
            }) {
                HStack {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .foregroundColor(.mint)
                    Text("导入整包配置")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("从文件恢复")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    // MARK: - Live Source Section
    private var liveSourceSection: some View {
        Section(header: Text("直播源管理").font(.caption)) {
            Button(action: {
                showingAddLiveSource = true
            }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                    Text("添加直播源")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if !contentSourceManager.liveSources.isEmpty {
                ForEach(contentSourceManager.liveSources) { source in
                    LiveSourceRow(
                        source: source,
                        isOn: Binding(
                            get: { source.isEnabled },
                            set: { newValue in
                                if let index = contentSourceManager.liveSources.firstIndex(where: { $0.id == source.id }) {
                                    contentSourceManager.liveSources[index].isEnabled = newValue
                                    contentSourceManager.saveLiveSources()
                                }
                            }
                        )
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            contentSourceManager.removeLiveSource(source)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } else {
                Text("暂无直播源")
                    .foregroundColor(.secondary)
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
    }
    
    // MARK: - Custom Web Page Section
    private var customWebPageSection: some View {
        Section("自定义页面") {
            Button("添加自定义页面") {
                showingAddCustomWebPage = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            
            if !preferencesManager.preferences.customWebPages.isEmpty {
                Picker("当前显示页面", selection: Binding(
                    get: {
                        preferencesManager.selectedCustomWebPage?.id ?? preferencesManager.preferences.customWebPages.first?.id ?? UUID()
                    },
                    set: { selectedId in
                        if let selectedPage = preferencesManager.preferences.customWebPages.first(where: { $0.id == selectedId }) {
                            preferencesManager.setSelectedCustomWebPageId(selectedPage.id)
                            NotificationCenter.default.post(
                                name: NSNotification.Name("SwitchToCustomPage"),
                                object: selectedPage
                            )
                        }
                    }
                )) {
                    ForEach(preferencesManager.preferences.customWebPages) { page in
                        Text(page.name).tag(page.id)
                    }
                }
                .pickerStyle(.menu)
            }
            
            if !preferencesManager.preferences.customWebPages.isEmpty {
                ForEach(preferencesManager.preferences.customWebPages) { webPage in
                    CustomWebPageRow(
                        webPage: webPage,
                        onToggle: {
                            preferencesManager.toggleCustomWebPageEnabled(webPage)
                        },
                        onDelete: {
                            preferencesManager.removeCustomWebPage(webPage)
                        }
                    )
                }
            }
        }
    }
    
    @State private var showingClearAllSourcesAlert = false
    
    // MARK: - Storage Section
    private var storageSection: some View {
        Section("存储管理") {
            HStack {
                Text("缓存大小")
                Spacer()
                Text(cacheSize)
                    .foregroundColor(.secondary)
            }
            
            Button(action: {
                showingClearCacheAlert = true
            }) {
                HStack {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                    Text("清理缓存")
                        .foregroundColor(.red)
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.red.opacity(0.1))
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
            
            // 清除所有源按钮
            Button(action: {
                showingClearAllSourcesAlert = true
            }) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("清除所有内容源")
                        .foregroundColor(.orange)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(contentSourceManager.sources.count) 影视 + \(contentSourceManager.liveSources.count) 直播")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    // MARK: - About Section
    private var aboutSection: some View {
        Section("关于应用") {
            HStack {
                Text("版本")
                Spacer()
                Text("1.0.1")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("开发者")
                Spacer()
                Text("晚风TV团队")
                    .foregroundColor(.secondary)
            }
            
            Link(destination: URL(string: "https://github.com/oilycn/W-TV")!) {
                HStack {
                    Image(systemName: "link.circle.fill")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                        Text("查看源代码和更新")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.blue)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)
            }
        }
    }
    
    // MARK: - Helper Methods
    private func importSources() async {
        if importMethod == .text {
            if contentSourceManager.importSources(from: importText) {
                alertMessage = "导入成功"
            } else {
                alertMessage = "导入失败，请检查JSON格式"
            }
        } else {
            guard let url = URL(string: importURLString) else {
                alertMessage = "无效的URL地址"
                showingAlert = true
                return
            }
            
            do {
                try await contentSourceManager.importSources(from: url)
                alertMessage = "导入成功"
            } catch {
                alertMessage = "导入失败: \(error.localizedDescription)"
            }
        }
        showingAlert = true
        importText = ""
        importURLString = ""
    }
    
    private func exportSources() {
        if let exportData = contentSourceManager.exportSources() {
            UIPasteboard.general.string = exportData
            alertMessage = "内容源已复制到剪贴板"
        } else {
            alertMessage = "导出失败"
        }
        showingAlert = true
    }

    private func exportAllConfigToFile() {
        let backup = AppConfigBackup(
            version: 1,
            exportedAt: Date().timeIntervalSince1970,
            contentSources: contentSourceManager.sources,
            liveSources: contentSourceManager.liveSources,
            bookSources: DatabaseManager.shared.getAllBookSources(),
            bookSourceHealthCheckedKeys: UserDefaults.standard.array(forKey: bookSourceHealthCheckedKeysUserDefaultsKey) as? [String] ?? [],
            bookSourceSubscriptionsData: UserDefaults.standard.data(forKey: bookSourceSubscriptionsUserDefaultsKey)
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(backup)
            exportConfigDocument = AppConfigBackupDocument(data: data)
            showingConfigExporter = true
        } catch {
            alertMessage = "导出失败：\(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func backupFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "wftv_config_\(formatter.string(from: Date()))"
    }

    private func handleConfigImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alertMessage = "导入失败：\(error.localizedDescription)"
            showingAlert = true
        case .success(let urls):
            guard let url = urls.first else { return }
            importAllConfig(from: url)
        }
    }

    private func importAllConfig(from url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let backup = try JSONDecoder().decode(AppConfigBackup.self, from: data)
            let summary = applyBackup(backup)
            alertMessage = "导入完成\n影视源：新增 \(summary.contentSources.added) / 更新 \(summary.contentSources.updated)\n直播源：新增 \(summary.liveSources.added) / 更新 \(summary.liveSources.updated)\n书源：新增 \(summary.bookSourcesAdded) / 更新 \(summary.bookSourcesUpdated)\n检测标记恢复：\(summary.restoredHealthMarks)\n订阅恢复：\(summary.restoredSubscriptions)"
            showingAlert = true
        } catch {
            alertMessage = "导入失败：\(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func applyBackup(_ backup: AppConfigBackup) -> AppConfigImportSummary {
        var summary = AppConfigImportSummary()
        summary.contentSources = contentSourceManager.mergeContentSources(backup.contentSources)
        summary.liveSources = contentSourceManager.mergeLiveSources(backup.liveSources)

        let database = DatabaseManager.shared
        var existingBookSourceKeys = Set(
            database.getAllBookSources()
                .map { normalizedBookSourceKey($0.bookSourceUrl) }
                .filter { !$0.isEmpty }
        )
        for source in backup.bookSources {
            let key = normalizedBookSourceKey(source.bookSourceUrl)
            guard !key.isEmpty else { continue }
            if existingBookSourceKeys.contains(key) {
                summary.bookSourcesUpdated += 1
            } else {
                summary.bookSourcesAdded += 1
                existingBookSourceKeys.insert(key)
            }
            database.saveBookSource(source)
        }

        let normalizedMarks = backup.bookSourceHealthCheckedKeys
            .map { normalizedBookSourceKey($0) }
            .filter { !$0.isEmpty }
        if !normalizedMarks.isEmpty {
            let existingMarks = Set(UserDefaults.standard.array(forKey: bookSourceHealthCheckedKeysUserDefaultsKey) as? [String] ?? [])
            let mergedMarks = Array(existingMarks.union(normalizedMarks))
            UserDefaults.standard.set(mergedMarks, forKey: bookSourceHealthCheckedKeysUserDefaultsKey)
            summary.restoredHealthMarks = mergedMarks.count
        }

        if let subscriptionsData = backup.bookSourceSubscriptionsData, !subscriptionsData.isEmpty {
            UserDefaults.standard.set(subscriptionsData, forKey: bookSourceSubscriptionsUserDefaultsKey)
            summary.restoredSubscriptions = true
        }

        return summary
    }

    private func normalizedBookSourceKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
    
    private func updateCacheSize() {
        cacheSize = preferencesManager.getCacheSize()
    }
    
    private func syncThemeSettings() {
        let currentTheme = themeManager.getCurrentTheme()
        if preferencesManager.preferences.theme != currentTheme {
            preferencesManager.setTheme(currentTheme)
        }
    }

    private struct AppConfigImportSummary {
        var contentSources = ContentSourceManager.SourceMergeResult()
        var liveSources = ContentSourceManager.SourceMergeResult()
        var bookSourcesAdded: Int = 0
        var bookSourcesUpdated: Int = 0
        var restoredHealthMarks: Int = 0
        var restoredSubscriptions: Bool = false
    }
}

private struct AppConfigBackup: Codable {
    let version: Int
    let exportedAt: TimeInterval
    let contentSources: [ContentSource]
    let liveSources: [LiveSource]
    let bookSources: [BookSource]
    let bookSourceHealthCheckedKeys: [String]
    let bookSourceSubscriptionsData: Data?
}

private struct AppConfigBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let raw = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = raw
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Import Method Enum
enum ImportMethod: String, CaseIterable, Identifiable {
    case text = "文本"
    case url = "URL"
    
    var id: String { self.rawValue }
}

// MARK: - Content Source Row
struct ContentSourceRow: View {
    let source: ContentSource
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                Circle()
                    .fill(isSelected ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.green : Color.gray, lineWidth: 1.5)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            
            Text(source.name)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
            
            if isSelected {
                Text("使用中")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green)
                    .cornerRadius(4)
            } else if source.isActive {
                Text("活跃")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
            
            Spacer()
            
            Text(source.url)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 100)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.green.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Live Source Row
struct LiveSourceRow: View {
    let source: LiveSource
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Text(source.name)
                .font(.subheadline)
                .lineLimit(1)
            
            Text(source.url)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .scaleEffect(0.8)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Custom Web Page Row
struct CustomWebPageRow: View {
    let webPage: CustomWebPage
    let onToggle: () -> Void
    let onDelete: () -> Void
    
    @State private var showingDeleteAlert = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(webPage.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(webPage.isEnabled ? .primary : .secondary)
                
                Text(webPage.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { webPage.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            
            Button(action: {
                showingDeleteAlert = true
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.caption)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 8)
        .alert("删除页面", isPresented: $showingDeleteAlert) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("确定要删除「\(webPage.name)」吗？")
        }
    }
}

// MARK: - Add Source View
struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var name = ""
    @State private var url = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("源名称", text: $name)
                    TextField("API URL", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }
                
                Section("说明") {
                    Text("• 影视源：用于播放电影、电视剧等点播内容")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("添加内容源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("添加") {
                        saveSource()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
            .alert("提示", isPresented: $showingAlert) {
                Button("确定") {
                    if alertMessage.contains("成功") {
                        dismiss()
                    }
                }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    private func saveSource() {
        let source = ContentSource(
            name: name,
            url: url,
            isActive: true
        )
        
        contentSourceManager.addSource(source)
        alertMessage = "添加成功"
        showingAlert = true
    }
}

// MARK: - Add Live Source View
struct AddLiveSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var contentSourceManager: ContentSourceManager
    
    @State private var name = ""
    @State private var url = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("直播源名称", text: $name)
                    TextField("直播源地址（M3U/TXT）", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }
                
                Section("说明") {
                    Text("• 支持直接填写 M3U 或 TXT 直播列表地址")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("• 添加后可在直播页按分类浏览频道")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("添加直播源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("添加") {
                        saveLiveSource()
                    }
                    .disabled(trimmedName.isEmpty || trimmedURL.isEmpty)
                }
            }
            .alert("提示", isPresented: $showingAlert) {
                Button("确定") {
                    if alertMessage.contains("成功") {
                        dismiss()
                    }
                }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    private func saveLiveSource() {
        guard URL(string: trimmedURL) != nil else {
            alertMessage = "直播源地址无效，请检查后重试"
            showingAlert = true
            return
        }
        
        let hasDuplicate = contentSourceManager.liveSources.contains {
            $0.name == trimmedName || $0.url == trimmedURL
        }
        if hasDuplicate {
            alertMessage = "已存在同名或同地址直播源"
            showingAlert = true
            return
        }
        
        let source = LiveSource(name: trimmedName, url: trimmedURL)
        contentSourceManager.addLiveSource(source)
        alertMessage = "直播源添加成功"
        showingAlert = true
    }
}

// MARK: - Import Sources View
struct ImportSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager
    @Binding var importText: String
    @Binding var importURLString: String
    @Binding var importMethod: ImportMethod
    let onImport: () async -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("导入方式", selection: $importMethod) {
                        Text("文本导入").tag(ImportMethod.text)
                        Text("URL导入").tag(ImportMethod.url)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                if importMethod == .text {
                    Section("JSON配置文本") {
                        TextEditor(text: $importText)
                            .frame(minHeight: 200)
                            .font(.system(.body, design: .monospaced))
                    }
                } else {
                    Section("订阅URL") {
                        TextField("https://example.com/sources.json", text: $importURLString)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                    }
                }
                
                Section("说明") {
                    Text("• 支持标准JSON格式的内容源配置")
                    Text("• 导入的内容源将添加到现有列表中")
                    Text("• 重复的内容源将被自动跳过")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("导入内容源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("导入") {
                        Task {
                            await onImport()
                            dismiss()
                        }
                    }
                    .disabled(importMethod == .text ? importText.isEmpty : importURLString.isEmpty)
                }
            }
        }
    }
}

// MARK: - Preview
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(ThemeManager.shared)
            .environmentObject(ContentSourceManager.shared)
            .environmentObject(UserPreferencesManager())
    }
}

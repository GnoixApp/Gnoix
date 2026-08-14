import SwiftUI
import WebKit

struct CustomWebView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var preferencesManager: UserPreferencesManager
    @State private var selectedWebPage: CustomWebPage?
    @State private var showingAddWebPage = false
    @State private var showingFullscreen = false
    @State private var showingPageSelector = false
    
    var body: some View {
        NavigationView {
            VStack {
                if preferencesManager.enabledCustomWebPages.isEmpty {
                    // 空状态
                    emptyStateView
                } else {
                    // 有自定义页面时直接显示web视图
                    VStack(spacing: 0) {
                        // Web视图容器
                        if let selectedPage = selectedWebPage {
                            ZStack {
                                WebPlayerView(url: selectedPage.url)
                                    .navigationBarHidden(true)
                                
                                // 全屏按钮 - 位于右下角，不重叠web内容
                                VStack {
                                    Spacer()
                                    
                                    HStack {
                                        Spacer()
                                        
                                        Button(action: {
                                            showingFullscreen = true
                                        }) {
                                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                .font(.system(size: 16, weight: .light))
                                                .foregroundColor(.white.opacity(0.8))
                                                .frame(width: 32, height: 32)
                                                .background(
                                                    Circle()
                                                        .fill(
                                                            preferencesManager.shouldReduceTransparency
                                                            ? AnyShapeStyle(Color.black.opacity(0.72))
                                                            : AnyShapeStyle(Material.ultraThin)
                                                        )
                                                        .opacity(0.8)
                                                )
                                                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                                        }
                                        .padding(.bottom, 20)
                                        .padding(.trailing, 16)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("自定义页面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingAddWebPage = true
                    }) {
                        Image(systemName: "plus")
                            .foregroundColor(themeManager.getAccentColor())
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddWebPage) {
            AddCustomWebPageView()
        }
        .fullScreenCover(isPresented: $showingFullscreen) {
            if let selectedPage = selectedWebPage {
                FullscreenWebView(webPage: selectedPage, isPresented: $showingFullscreen)
                    .environmentObject(themeManager)
                    .environmentObject(preferencesManager)
            }
        }
        .onAppear {
            // 使用持久化的选中页面
            if selectedWebPage == nil {
                selectedWebPage = preferencesManager.selectedCustomWebPage
                // 如果没有保存的选中页面，使用第一个页面并保存
                if selectedWebPage == nil && !preferencesManager.enabledCustomWebPages.isEmpty {
                    selectedWebPage = preferencesManager.enabledCustomWebPages.first
                    preferencesManager.setSelectedCustomWebPageId(selectedWebPage?.id)
                }
                // 通知ContentView当前选中的页面
                if let currentPage = selectedWebPage {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SwitchToCustomPage"),
                        object: currentPage
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToCustomPage"))) { notification in
            if let page = notification.object as? CustomWebPage {
                withAnimation(.easeInOut(duration: 0.3)) {
                    selectedWebPage = page
                }
                // 保存选中状态（如果不是从设置页面触发的话）
                if preferencesManager.preferences.selectedCustomWebPageId != page.id {
                    preferencesManager.setSelectedCustomWebPageId(page.id)
                }
            }
        }
        .onChange(of: preferencesManager.enabledCustomWebPages) { pages in
            // 如果当前选中的页面被删除或禁用，选择第一个可用的
            if let selected = selectedWebPage,
               !pages.contains(where: { $0.id == selected.id }) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    selectedWebPage = pages.first
                }
            } else if selectedWebPage == nil && !pages.isEmpty {
                // 新添加页面时，立即选中最新添加的页面（通常是最后一个）
                withAnimation(.easeInOut(duration: 0.3)) {
                    selectedWebPage = pages.last
                }
            }
        }
    }
    
    // MARK: - Page Selector Methods
    private func createPageSelectorButtons() -> [ActionSheet.Button] {
        var buttons: [ActionSheet.Button] = []
        
        // 为每个启用的页面创建按钮
        for page in preferencesManager.enabledCustomWebPages {
            let isSelected = selectedWebPage?.id == page.id
            let buttonTitle = isSelected ? "✓ \(page.name)" : page.name
            
            buttons.append(.default(Text(buttonTitle)) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    selectedWebPage = page
                }
            })
        }
        
        // 添加取消按钮
        buttons.append(.cancel(Text("取消")))
        
        return buttons
    }
    
    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                Text("暂无自定义页面")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("点击右上角的 + 按钮添加您的第一个自定义web页面")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Button(action: {
                showingAddWebPage = true
            }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("添加自定义页面")
                        .fontWeight(.medium)
                }
                .foregroundColor(.white)
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(themeManager.getAccentColor())
                .cornerRadius(25)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.getBackgroundColor())
    }
    
    // MARK: - Page Selector
    private var pageSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(preferencesManager.enabledCustomWebPages) { page in
                    Button(action: {
                        selectedWebPage = page
                    }) {
                        Text(page.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                selectedWebPage?.id == page.id ?
                                themeManager.getAccentColor() :
                                Color.secondary.opacity(0.2)
                            )
                            .foregroundColor(
                                selectedWebPage?.id == page.id ?
                                .white :
                                .primary
                            )
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(themeManager.getBackgroundColor())
    }
}

// MARK: - Add Custom Web Page View
struct AddCustomWebPageView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var preferencesManager: UserPreferencesManager
    @Environment(\.presentationMode) var presentationMode
    
    @State private var name = ""
    @State private var url = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("页面信息")) {
                    TextField("页面名称", text: $name)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    TextField("页面URL", text: $url)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("预设页面")) {
                    presetWebPages
                }
            }
            .navigationTitle("添加自定义页面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveWebPage()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
        .alert("提示", isPresented: $showingAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    // MARK: - Preset Web Pages
    private var presetWebPages: some View {
        VStack(spacing: 8) {
            PresetWebPageRow(
                name: "哔哩哔哩",
                url: "https://m.bilibili.com",
                iconName: "tv.fill"
            ) { name, url in
                self.name = name
                self.url = url
            }
            
            PresetWebPageRow(
                name: "YouTube",
                url: "https://m.youtube.com",
                iconName: "play.rectangle.fill"
            ) { name, url in
                self.name = name
                self.url = url
            }
            
            PresetWebPageRow(
                name: "爱奇艺",
                url: "https://m.iqiyi.com",
                iconName: "tv.circle.fill"
            ) { name, url in
                self.name = name
                self.url = url
            }
            
            PresetWebPageRow(
                name: "腾讯视频",
                url: "https://m.v.qq.com",
                iconName: "play.tv.fill"
            ) { name, url in
                self.name = name
                self.url = url
            }
        }
    }
    
    // MARK: - Save Web Page
    private func saveWebPage() {
        // 验证URL格式
        guard let _ = URL(string: url) else {
            alertMessage = "请输入有效的URL地址"
            showingAlert = true
            return
        }
        
        // 检查是否已存在相同名称或URL的页面
        let existingPages = preferencesManager.preferences.customWebPages
        if existingPages.contains(where: { $0.name == name }) {
            alertMessage = "已存在相同名称的页面"
            showingAlert = true
            return
        }
        
        if existingPages.contains(where: { $0.url == url }) {
            alertMessage = "已存在相同URL的页面"
            showingAlert = true
            return
        }
        
        // 创建新的自定义页面
        let newWebPage = CustomWebPage(name: name, url: url)
        preferencesManager.addCustomWebPage(newWebPage)
        
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Preset Web Page Row
struct PresetWebPageRow: View {
    let name: String
    let url: String
    let iconName: String
    let onSelect: (String, String) -> Void
    
    var body: some View {
        Button(action: {
            onSelect(name, url)
        }) {
            HStack {
                Image(systemName: iconName)
                    .foregroundColor(.blue)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text(url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    CustomWebView()
        .environmentObject(ThemeManager())
        .environmentObject(UserPreferencesManager())
}

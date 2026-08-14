import SwiftUI
import WebKit

struct FullscreenWebView: View {
    let webPage: CustomWebPage
    @Binding var isPresented: Bool
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var preferencesManager: UserPreferencesManager
    
    @State private var buttonOpacity: Double = 1.0
    @State private var fadeTimer: Timer?
    
    var body: some View {
        ZStack {
            // 真正全屏的WebView - 覆盖整个屏幕包括安全区域
            FullscreenWebPlayerView(url: webPage.url)
                .ignoresSafeArea(.all, edges: .all)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 退出按钮 - 位于右上角，一直显示但会变淡
            VStack {
                HStack {
                    Spacer()
                    
                    Button(action: {
                        fadeTimer?.invalidate()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isPresented = false
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(buttonOpacity * 0.9))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(
                                        preferencesManager.shouldReduceTransparency
                                        ? AnyShapeStyle(Color.black.opacity(0.72))
                                        : AnyShapeStyle(Material.ultraThin)
                                    )
                                    .opacity(buttonOpacity * 0.7)
                            )
                            .shadow(color: .black.opacity(0.2 * buttonOpacity), radius: 3, x: 0, y: 1)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 12) // 在安全区域内
                    .padding(.trailing, 16)
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded { _ in
                                // 点击按钮时恢复完全不透明
                                restoreButtonOpacity()
                            }
                    )
                }
                
                Spacer()
            }
            .animation(.easeInOut(duration: 0.5), value: buttonOpacity)
        }
        .background(Color.black) // 确保背景是黑色
        .statusBarHidden(true) // 隐藏状态栏
        .navigationBarHidden(true) // 隐藏导航栏
        .ignoresSafeArea(.all, edges: .all) // 忽略所有安全区域
        .onAppear {
            startFadeTimer()
        }
        .onDisappear {
            fadeTimer?.invalidate()
        }
    }
    
    private func startFadeTimer() {
        // 取消之前的定时器
        fadeTimer?.invalidate()
        
        // 4秒后开始变淡
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 1.0)) {
                buttonOpacity = 0.15 // 更淡，几乎不可见但仍可点击
            }
        }
    }
    
    private func restoreButtonOpacity() {
        // 恢复完全不透明
        fadeTimer?.invalidate()
        withAnimation(.easeInOut(duration: 0.3)) {
            buttonOpacity = 1.0
        }
        // 重新开始计时
        startFadeTimer()
    }
}

struct FullscreenWebPlayerView: UIViewRepresentable {
    let url: String
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = true
        
        // 设置背景色为黑色
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.isOpaque = false
        
        // 确保WebView占满整个容器
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        // 设置内容模式
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
        if let url = URL(string: url) {
            let request = URLRequest(url: url)
            webView.load(request)
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url = URL(string: url), uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
        
        // 确保WebView始终占满容器
        uiView.scrollView.contentInsetAdjustmentBehavior = .never
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 页面加载完成后，注入CSS来隐藏可能的边距
            let css = """
                body {
                    margin: 0 !important;
                    padding: 0 !important;
                    background-color: black !important;
                }
                * {
                    -webkit-user-select: none;
                    -webkit-touch-callout: none;
                }
            """
            
            let script = "var style = document.createElement('style'); style.innerHTML = '\(css)'; document.head.appendChild(style);"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("WebView navigation failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    FullscreenWebView(
        webPage: CustomWebPage(name: "测试页面", url: "https://www.bilibili.com"),
        isPresented: .constant(true)
    )
    .environmentObject(ThemeManager())
    .environmentObject(UserPreferencesManager())
}

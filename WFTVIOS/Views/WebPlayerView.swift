import SwiftUI
import WebKit

// MARK: - Enhanced WebPlayerView
// 优化特性：
// 1. 加载状态显示
// 2. 错误处理和恢复
// 3. 网络状态监听
// 4. URL 验证

struct WebPlayerView: UIViewRepresentable {
    let url: String
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.setWebView(webView)
        
        if let validURL = context.coordinator.validateURL(url) {
            let request = URLRequest(url: validURL)
            webView.load(request)
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let validURL = context.coordinator.validateURL(url), uiView.url != validURL {
            let request = URLRequest(url: validURL)
            uiView.load(request)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebPlayerView
        @Published var isLoading = false
        @Published var errorMessage: String?
        @Published var canRetry = false
        
        private var networkObserver: NSObjectProtocol?
        private var retryTimer: Timer?
        private weak var webView: WKWebView?
        
        init(parent: WebPlayerView) {
            self.parent = parent
            super.init()
            setupNetworkObserver()
        }
        
        deinit {
            removeNetworkObserver()
            stopRetryTimer()
        }
        
        // MARK: - URL Validation
        func validateURL(_ urlString: String) -> URL? {
            guard !urlString.isEmpty else { return nil }
            
            var cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !cleanURL.hasPrefix("http://") && !cleanURL.hasPrefix("https://") {
                cleanURL = "https://" + cleanURL
            }
            
            return URL(string: cleanURL)
        }
        
        // MARK: - WebView Access
        func setWebView(_ webView: WKWebView) {
            self.webView = webView
        }
        
        // MARK: - Network Observer
        private func setupNetworkObserver() {
            networkObserver = NotificationCenter.default.addObserver(
                forName: .networkReconnected,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleNetworkReconnect()
            }
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleNetworkDisconnected),
                name: .networkDisconnected,
                object: nil
            )
        }
        
        private func removeNetworkObserver() {
            if let observer = networkObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            NotificationCenter.default.removeObserver(self, name: .networkDisconnected, object: nil)
        }
        
        @objc private func handleNetworkDisconnected() {
            canRetry = true
        }
        
        private func handleNetworkReconnect() {
            if canRetry {
                reloadCurrentURL()
                canRetry = false
            }
        }
        
        // MARK: - Retry Logic
        private func retryLoading() {
            stopRetryTimer()
            
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.reloadCurrentURL()
            }
        }
        
        private func stopRetryTimer() {
            retryTimer?.invalidate()
            retryTimer = nil
        }
        
        private func reloadCurrentURL() {
            guard let webView = webView, let validURL = validateURL(parent.url) else {
                return
            }
            
            isLoading = true
            errorMessage = nil
            
            let request = URLRequest(url: validURL)
            webView.load(request)
        }
        
        // MARK: - WKNavigationDelegate
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
            errorMessage = nil
        }
        
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            isLoading = false
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            errorMessage = nil
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            
            let nsError = error as NSError
            
            switch nsError.code {
            case NSURLErrorCancelled:
                errorMessage = nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                errorMessage = "网络连接失败，请检查网络设置"
                canRetry = true
            case NSURLErrorTimedOut:
                errorMessage = "请求超时，正在重试..."
                canRetry = true
                retryLoading()
            default:
                errorMessage = "加载失败: \(error.localizedDescription)"
                canRetry = true
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            
            let nsError = error as NSError
            
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                errorMessage = "网络连接失败，请检查网络设置"
                canRetry = true
            case NSURLErrorTimedOut:
                errorMessage = "请求超时，正在重试..."
                canRetry = true
                retryLoading()
            default:
                errorMessage = "加载失败: \(error.localizedDescription)"
                canRetry = true
            }
        }
    }
}

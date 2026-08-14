import UIKit
import SnapKit
import Kingfisher

private let comicImageCellDefaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
private let comicImageCellRequestTimeout: TimeInterval = 45
private let comicImageCellProxyPrefix = "https://proxy.oily.cn/proxy/"

class ComicImageCell: UICollectionViewCell {
    static let identifier = "ComicImageCell"
    struct ResolvedImageRequest {
        let urlString: String
        let referer: String?
    }

    private static let comicDownloader: ImageDownloader = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = comicImageCellRequestTimeout
        configuration.timeoutIntervalForResource = max(comicImageCellRequestTimeout * 2, 60)
        configuration.httpMaximumConnectionsPerHost = 2
        if #available(iOS 11.0, *) {
            configuration.waitsForConnectivity = true
        }
        let downloader = ImageDownloader(name: "cn.oily.reader.comic")
        downloader.sessionConfiguration = configuration
        downloader.downloadTimeout = comicImageCellRequestTimeout
        return downloader
    }()
    private var currentURLString: String?
    
    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.backgroundColor = .systemBackground
        return iv
    }()
    
    private let loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        contentView.addSubview(imageView)
        contentView.addSubview(loadingIndicator)
        
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        loadingIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
    }
    
    func configure(with urlString: String, referer: String? = nil, onImageSizeResolved: ((CGSize) -> Void)? = nil) {
        currentURLString = urlString
        loadingIndicator.startAnimating()
        imageView.kf.cancelDownloadTask()

        let resolvedRequest = Self.resolvedRequest(from: urlString, fallbackReferer: referer)
        let resolvedURLString = resolvedRequest.urlString
        guard let url = URL(string: resolvedURLString) else {
            loadingIndicator.stopAnimating()
            imageView.image = UIImage(systemName: "photo")
            return
        }

        let effectiveReferer = resolvedRequest.referer

        var options: KingfisherOptionsInfo = [
            .cacheOriginalImage,
            .transition(.none),
            .backgroundDecode
        ]
        let targetSize = CGSize(
            width: max(bounds.width, UIScreen.main.bounds.width),
            height: max(bounds.height, UIScreen.main.bounds.width * 1.4)
        )
        options.append(.processor(DownsamplingImageProcessor(size: targetSize)))
        options.append(.scaleFactor(UIScreen.main.scale))
        options.append(.retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(1))))
        options.append(.downloader(Self.downloader()))
        options.append(.requestModifier(Self.requestModifier(for: effectiveReferer)))

        let placeholder = UIImage(systemName: "photo")
        imageView.kf.setImage(with: url, placeholder: placeholder, options: options) { [weak self] result in
            guard let self, self.currentURLString == urlString else { return }
            switch result {
            case .success(let value):
                self.loadingIndicator.stopAnimating()
                onImageSizeResolved?(value.image.size)
            case .failure(let error):
                print("[ComicImageCell] primary load failed url=\(url.absoluteString) error=\(error)")
                // 部分站点会拒绝带 Referer 的请求，失败后退化为无 Referer 再试一次。
                if effectiveReferer == nil {
                    self.loadingIndicator.stopAnimating()
                    return
                }

                let fallbackOptions: KingfisherOptionsInfo = [
                    .cacheOriginalImage,
                    .transition(.none),
                    .backgroundDecode,
                    .processor(DownsamplingImageProcessor(size: targetSize)),
                    .scaleFactor(UIScreen.main.scale),
                    .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(1))),
                    .downloader(Self.downloader()),
                    .requestModifier(Self.requestModifier(for: nil))
                ]
                self.imageView.kf.setImage(with: url, placeholder: placeholder, options: fallbackOptions) { [weak self] fallbackResult in
                    self?.loadingIndicator.stopAnimating()
                    guard let self, self.currentURLString == urlString else { return }
                    if case .success(let value) = fallbackResult {
                        onImageSizeResolved?(value.image.size)
                    } else if case .failure(let fallbackError) = fallbackResult {
                        print("[ComicImageCell] fallback load failed url=\(url.absoluteString) error=\(fallbackError)")
                    }
                }
            }
        }
    }

    static func resolveImageURLString(_ rawValue: String) -> String {
        let (rawURLValue, _) = splitLegacyURLPayload(rawValue)

        var value = rawURLValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        if value.hasPrefix("__API_ROOT__") || value.lowercased().hasPrefix("__api_root__") {
            value = value
                .replacingOccurrences(of: "__API_ROOT__", with: "")
                .replacingOccurrences(of: "__api_root__", with: "")
            if !value.hasPrefix("/") {
                value = "/\(value)"
            }
            return ReaderServerAPI.shared.getAssetUrl(value)
        }

        if value.hasPrefix("//") {
            return "https:\(value)"
        }
        if value.hasPrefix("/") {
            return ReaderServerAPI.shared.getAssetUrl(value)
        }
        if let scheme = URL(string: value)?.scheme, !scheme.isEmpty {
            return proxiedURLStringIfNeeded(encodedURLString(value))
        }
        if BookParseManager.shared.isServerMode {
            return proxiedURLStringIfNeeded(encodedURLString(ReaderServerAPI.shared.getAssetUrl(value)))
        }
        return proxiedURLStringIfNeeded(encodedURLString(value))
    }

    static func requestModifier(for referer: String?) -> AnyModifier {
        let cleanReferer = referer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AnyModifier { request in
            var modified = request
            if !cleanReferer.isEmpty {
                modified.setValue(cleanReferer, forHTTPHeaderField: "Referer")
            }
            modified.setValue(comicImageCellDefaultUserAgent, forHTTPHeaderField: "User-Agent")
            modified.timeoutInterval = comicImageCellRequestTimeout
            return modified
        }
    }

    private static func encodedURLString(_ value: String) -> String {
        // `[` `]` 在路径中会导致 Foundation 对已有 `%xx` 产生二次编码（%20 -> %2520），
        // 这里显式排除方括号，先编码成 `%5B` `%5D`，避免图片地址失真。
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#@!$&'()*+,;=%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func resolvedRequest(from rawValue: String, fallbackReferer: String?) -> ResolvedImageRequest {
        let request = resolveImageRequest(from: rawValue)
        let effectiveReferer = isProxiedURLString(request.urlString)
            ? nil
            : (request.refererOverride ?? fallbackReferer)
        return ResolvedImageRequest(urlString: request.urlString, referer: effectiveReferer)
    }

    static func downloader() -> ImageDownloader {
        comicDownloader
    }

    static func resolveImageRequest(from rawValue: String) -> (urlString: String, refererOverride: String?) {
        let (rawURLValue, rawPayloadValue) = splitLegacyURLPayload(rawValue)
        let urlString = resolveImageURLString(rawURLValue)
        let refererOverride = parseRefererOverride(from: rawPayloadValue)
        return (urlString, refererOverride)
    }

    private static func splitLegacyURLPayload(_ rawValue: String) -> (url: String, payload: String?) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard let commaIndex = normalized.firstIndex(of: ",") else {
            return (normalized, nil)
        }

        let payload = String(normalized[normalized.index(after: commaIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerPayload = payload.lowercased()
        let looksLikePayload =
            payload.hasPrefix("{") ||
            lowerPayload.hasPrefix("%7b") ||
            lowerPayload.contains("\"headers\"") ||
            lowerPayload.contains("'headers'")
        guard looksLikePayload else {
            return (normalized, nil)
        }

        let urlPart = String(normalized[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (urlPart, payload.isEmpty ? nil : payload)
    }

    private static func parseRefererOverride(from payload: String?) -> String? {
        guard let payload = payload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            return nil
        }

        let decoded = (payload.removingPercentEncoding ?? payload)
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        if let data = decoded.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            if let referer = extractRefererValue(from: json) {
                return referer
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"(?i)referer"\s*:\s*"([^"]+)""#, options: []),
           let match = regex.firstMatch(in: decoded, options: [], range: NSRange(decoded.startIndex..., in: decoded)),
           let range = Range(match.range(at: 1), in: decoded) {
            let referer = String(decoded[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return referer.isEmpty ? nil : referer
        }
        return nil
    }

    private static func extractRefererValue(from json: [String: Any]) -> String? {
        if let headers = json["headers"] as? [String: Any] {
            if let direct = headers["Referer"] as? String, !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return direct
            }
            if let lower = headers["referer"] as? String, !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return lower
            }
            for (key, value) in headers where key.lowercased() == "referer" {
                if let referer = value as? String, !referer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return referer
                }
            }
        }
        if let direct = json["Referer"] as? String, !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return direct
        }
        if let lower = json["referer"] as? String, !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lower
        }
        return nil
    }

    private static func proxiedURLStringIfNeeded(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host?.lowercased() else {
            return value
        }
        if host == "proxy.oily.cn" {
            return value
        }
        let shouldProxy = host == "cangcuc.com" || host.hasSuffix(".cangcuc.com")
        guard shouldProxy else {
            return value
        }
        return comicImageCellProxyPrefix + value
    }

    private static func isProxiedURLString(_ value: String) -> Bool {
        guard let host = URL(string: value)?.host?.lowercased() else { return false }
        return host == "proxy.oily.cn"
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        currentURLString = nil
        imageView.kf.cancelDownloadTask()
        imageView.image = nil
    }
}

import Foundation
import AVFoundation
import MediaPlayer
import UIKit

class TTSService: NSObject {
    static let shared = TTSService()
    private static let verboseLoggingEnabled = false
    
    private let baseURL = "https://tts.oily.cn"
    private let apiKeyStoreKey = "TTSAPIKey"
    private let defaultAPIKey = "woshishabiyuanyuan"
    private var cachedAPIKey: String?
    
    private var apiKey: String? {
        if let cached = cachedAPIKey, !cached.isEmpty {
            return cached
        }
        if let key = SecureStore.value(for: apiKeyStoreKey), !key.isEmpty {
            cachedAPIKey = key
            return key
        }
        if let legacy = UserDefaults.standard.string(forKey: apiKeyStoreKey), !legacy.isEmpty {
            SecureStore.set(legacy, for: apiKeyStoreKey)
            UserDefaults.standard.removeObject(forKey: apiKeyStoreKey)
            cachedAPIKey = legacy
            return legacy
        }
        return nil
    }
    
    var useHttpTTS: Bool {
        let hasApiKey = isHttpConfigured
        if !UserDefaults.standard.bool(forKey: "UseHttpTTSSet") && hasApiKey {
            UserDefaults.standard.set(true, forKey: "UseHttpTTS")
            UserDefaults.standard.set(true, forKey: "UseHttpTTSSet")
        }
        return UserDefaults.standard.bool(forKey: "UseHttpTTS") && hasApiKey
    }
    
    var isHttpConfigured: Bool {
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }
    
    private var audioPlayer: AVAudioPlayer?
    private enum PlaybackBackend {
        case http
        case local
    }
    private var activePlaybackBackend: PlaybackBackend?
    private var prefetchedAudioCache: [String: Data] = [:]
    private var pendingPrefetchTexts: [String] = []
    private var prefetchInFlight: Set<String> = []
    private let prefetchStateQueue = DispatchQueue(label: "cn.oily.tts.prefetch.state")
    private var currentCompletion: ((Bool) -> Void)?
    private let maxPrefetchCount = 3

    private func log(_ message: @autoclosure () -> String) {
        guard Self.verboseLoggingEnabled else { return }
        print(message())
    }
    
    func prefetchAudio(texts: [String]) {
        enqueuePrefetchTexts(texts)
        processPrefetchQueue()
    }

    private func processPrefetchQueue() {
        guard let text = dequeueNextPrefetchText() else { return }
        fetchAudio(text: text, isPrefetch: true)
    }

    func getPrefetchedData(for text: String) -> Data? {
        let data = consumePrefetchedData(for: text)
        if data != nil {
            processPrefetchQueue()
        }
        return data
    }

    func hasPrefetchedData(for text: String) -> Bool {
        return hasPrefetchedAudio(for: text)
    }

    func clearPrefetch() {
        clearPrefetchState()
    }
    
    func prefetchAudio(text: String) {
        prefetchAudio(texts: [text])
    }

    private func enqueuePrefetchTexts(_ texts: [String]) {
        prefetchStateQueue.sync {
            for rawText in texts {
                let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard prefetchedAudioCache[text] == nil,
                      !pendingPrefetchTexts.contains(text),
                      !prefetchInFlight.contains(text) else { continue }
                pendingPrefetchTexts.append(text)
            }
        }
    }

    private func dequeueNextPrefetchText() -> String? {
        prefetchStateQueue.sync {
            guard prefetchedAudioCache.count + prefetchInFlight.count < maxPrefetchCount else {
                return nil
            }

            while !pendingPrefetchTexts.isEmpty {
                let text = pendingPrefetchTexts.removeFirst()
                if prefetchedAudioCache[text] != nil || prefetchInFlight.contains(text) {
                    continue
                }
                prefetchInFlight.insert(text)
                return text
            }
            return nil
        }
    }

    private func completePrefetch(text: String, data: Data?) {
        prefetchStateQueue.sync {
            prefetchInFlight.remove(text)
            if let data {
                prefetchedAudioCache[text] = data
            }
        }
    }

    private func consumePrefetchedData(for text: String) -> Data? {
        prefetchStateQueue.sync {
            prefetchedAudioCache.removeValue(forKey: text)
        }
    }

    private func hasPrefetchedAudio(for text: String) -> Bool {
        prefetchStateQueue.sync {
            prefetchedAudioCache[text] != nil
        }
    }

    private func clearPrefetchState() {
        prefetchStateQueue.sync {
            prefetchedAudioCache.removeAll()
            pendingPrefetchTexts.removeAll()
            prefetchInFlight.removeAll()
        }
    }

    private func prefetchedCount() -> Int {
        prefetchStateQueue.sync {
            prefetchedAudioCache.count
        }
    }
    
    private func fetchAudio(text: String, isPrefetch: Bool = false, completion: ((Data?) -> Void)? = nil) {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            completion?(nil)
            return
        }
        
        var voiceToUse = selectedVoice
        if voiceToUse.isEmpty {
            voiceToUse = "zh-CN-XiaoxiaoNeural"
        }
        
        let rateValue = Int((selectedRate - 0.5) * 200)
        
        var queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "t", value: text),
            URLQueryItem(name: "v", value: voiceToUse),
            URLQueryItem(name: "r", value: String(rateValue))
        ]
        
        if !selectedStyle.isEmpty {
            queryItems.append(URLQueryItem(name: "s", value: selectedStyle))
        }
        
        var components = URLComponents(string: "\(baseURL)/tts")!
        components.queryItems = queryItems
        
        guard let url = components.url else {
            completion?(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count >= 100 else {
                completion?(nil)
                if isPrefetch {
                    self?.completePrefetch(text: text, data: nil)
                    self?.processPrefetchQueue()
                }
                return
            }
            
            if isPrefetch {
                self?.completePrefetch(text: text, data: data)
                self?.processPrefetchQueue()
            } else {
                completion?(data)
            }
        }.resume()
    }
    
    private func playWithPrefetch(text: String, completion: @escaping (Bool) -> Void) {
        log("playWithPrefetch called, hasPrefetch: \(hasPrefetchedData(for: text))")
        if let data = getPrefetchedData(for: text) {
            log("Using prefetched data")
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                
                audioPlayer = try AVAudioPlayer(data: data)
                audioPlayer?.delegate = self
                audioPlayer?.prepareToPlay()
                audioPlayer?.play()
                completion(true)
            } catch {
                log("Play prefetch error: \(error)")
                speakWithHTTP(text: text, completion: completion)
            }
        } else {
            log("No prefetch, calling speakWithHTTP")
            speakWithHTTP(text: text, completion: completion)
        }
    }
    
    private var localTTSEngine: AVSpeechSynthesizer?
    private var localTTSCompletion: (() -> Void)?
    private var currentChapterIndex = 0
    private var totalChapters = 0
    var currentParagraphIndex = 0  // Track current paragraph
    
    var onSpeechFinished: (() -> Void)?
    var onChapterChanged: ((Int, Int) -> Void)?
    var onParagraphChanged: ((Int, String) -> Void)?
    var onPlaybackStopped: (() -> Void)?
    
    func setChapterInfo(current: Int, total: Int) {
        currentChapterIndex = current
        totalChapters = total
    }
    
    private var selectedRate: Float = 0.5
    private var selectedVoice: String = {
        return UserDefaults.standard.string(forKey: "TTSVoice") ?? "zh-CN-XiaoxiaoNeural"
    }()
    private var voiceNameToId: [String: String] = [:]
    private var voiceStyleList: [String: [String]] = [:]
    private var selectedStyle: String = {
        return UserDefaults.standard.string(forKey: "TTSStyle") ?? ""
    }()
    
    var currentStyle: String {
        get { selectedStyle }
        set { 
            selectedStyle = newValue
            UserDefaults.standard.set(newValue, forKey: "TTSStyle")
            clearPrefetch()
        }
    }
    
    func getStylesForCurrentVoice() -> [String] {
        let displayName = currentVoiceDisplayName
        return voiceStyleList[displayName] ?? []
    }
    
    var currentVoiceDisplayName: String {
        return voiceNameToId.first(where: { $0.value == selectedVoice })?.key ?? selectedVoice
    }
    
    var currentRate: Float {
        get { 
            let rate = UserDefaults.standard.float(forKey: "TTSRate")
            return rate > 0 ? rate : 0.5
        }
        set { 
            UserDefaults.standard.set(newValue, forKey: "TTSRate")
        }
    }
    
    var currentVoice: String {
        get { selectedVoice }
        set { 
            selectedVoice = newValue
            UserDefaults.standard.set(newValue, forKey: "TTSVoice")
        }
    }
    
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false) || (localTTSEngine?.isSpeaking ?? false)
    }
    
    override init() {
        super.init()
        migrateLegacyAPIKeyIfNeeded()
        ensureDefaultAPIKeyIfNeeded()
        setupAudioSession()
        setupRemoteCommandCenter()
        setupInterruptionHandling()
    }

    private func migrateLegacyAPIKeyIfNeeded() {
        guard SecureStore.value(for: apiKeyStoreKey) == nil else { return }
        guard let legacy = UserDefaults.standard.string(forKey: apiKeyStoreKey), !legacy.isEmpty else { return }
        SecureStore.set(legacy, for: apiKeyStoreKey)
        UserDefaults.standard.removeObject(forKey: apiKeyStoreKey)
        cachedAPIKey = legacy
    }

    private func ensureDefaultAPIKeyIfNeeded() {
        if let key = SecureStore.value(for: apiKeyStoreKey), !key.isEmpty {
            cachedAPIKey = key
            return
        }
        SecureStore.set(defaultAPIKey, for: apiKeyStoreKey)
        cachedAPIKey = defaultAPIKey
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothHFP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            log("Failed to setup audio session: \(error)")
        }
    }

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            log("[TTSService] Audio interruption began")
            pause()
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                log("[TTSService] Audio interruption ended, resuming")
                resume()
                onInterruptionEnded?()
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            log("[TTSService] Audio route changed: device unavailable, pausing")
            pause()
        default:
            break
        }
    }

    @objc private func handleAppDidEnterBackground() {
        log("[TTSService] App entered background")
    }

    @objc private func handleAppWillEnterForeground() {
        log("[TTSService] App will enter foreground")
    }

    var onInterruptionEnded: (() -> Void)?
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            if self?.isPlaying == true {
                self?.pause()
            } else {
                self?.resume()
            }
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNextParagraph?()
            return .success
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevParagraph?()
            return .success
        }
    }
    
    var onNextParagraph: (() -> Void)?
    var onPrevParagraph: (() -> Void)?
    
    func getHttpVoices(completion: @escaping ([String]) -> Void) {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            completion(["晓辰", "晓伊", "晓悠"])
            return
        }
        
        let urlString = "\(baseURL)/voices?l=zh&f=1"
        guard let url = URL(string: urlString) else {
            completion(["晓辰", "晓伊", "晓悠"])
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data else {
                    completion(["晓辰 (女)", "晓伊 (女)", "晓悠 (男)"])
                    self?.voiceNameToId["晓辰 (女)"] = "zh-CN-XiaochenNeural"
                    self?.voiceNameToId["晓伊 (女)"] = "zh-CN-XiaoyiNeural"
                    self?.voiceNameToId["晓悠 (男)"] = "zh-CN-XiaoyouNeural"
                    self?.voiceStyleList["晓辰 (女)"] = ["livecommercial"]
                    self?.voiceStyleList["晓伊 (女)"] = ["chat", "customerservice"]
                    self?.voiceStyleList["晓悠 (男)"] = ["newscast"]
                    return
                }
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    var voices: [String] = []
                    self?.voiceNameToId.removeAll()
                    self?.voiceStyleList.removeAll()
                    
                    for voice in json {
                        if let localName = voice["LocalName"] as? String,
                           let shortName = voice["ShortName"] as? String,
                           let gender = voice["Gender"] as? String {
                            let genderText = gender == "Female" ? "女" : "男"
                            let displayName = "\(localName) (\(genderText))"
                            voices.append(displayName)
                            self?.voiceNameToId[displayName] = shortName
                            
                            if let styleList = voice["StyleList"] as? [String] {
                                self?.voiceStyleList[displayName] = styleList
                            }
                        }
                    }
                    
                    if !voices.isEmpty {
                        completion(voices)
                        return
                    }
                }
                
                completion(["晓辰", "晓伊", "晓悠"])
            }
        }.resume()
    }
    
    func setVoiceByDisplayName(_ displayName: String) {
        if let id = voiceNameToId[displayName] {
            selectedVoice = id
            UserDefaults.standard.set(id, forKey: "TTSVoice")
        } else {
            selectedVoice = displayName
            UserDefaults.standard.set(displayName, forKey: "TTSVoice")
        }
        clearPrefetch()
    }
    
    func speak(text: String, completion: @escaping (Bool) -> Void) {
        log("TTS speak called, prefetchCount: \(prefetchedCount())")
        currentCompletion = completion
        
        if useHttpTTS {
            playWithPrefetch(text: text, completion: completion)
        } else {
            speakWithLocal(text: text, completion: completion)
        }
    }
    
    func stop(notify: Bool = true) {
        audioPlayer?.stop()
        audioPlayer = nil
        clearPrefetch()
        localTTSEngine?.stopSpeaking(at: .immediate)
        localTTSEngine = nil
        activePlaybackBackend = nil
        currentCompletion = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if notify {
            onPlaybackStopped?()
        }
    }
    
    func pause() {
        switch activePlaybackBackend {
        case .http:
            audioPlayer?.pause()
        case .local:
            localTTSEngine?.pauseSpeaking(at: .immediate)
        case .none:
            if audioPlayer != nil {
                audioPlayer?.pause()
            } else {
                localTTSEngine?.pauseSpeaking(at: .immediate)
            }
        }
    }
    
    func resume() {
        switch activePlaybackBackend {
        case .http:
            audioPlayer?.play()
        case .local:
            localTTSEngine?.continueSpeaking()
        case .none:
            if audioPlayer != nil {
                audioPlayer?.play()
            } else {
                localTTSEngine?.continueSpeaking()
            }
        }
    }
    
    private var bookTitle: String = "小说朗读"
    private var currentParagraphText: String = ""
    
    func setBookTitle(_ title: String) {
        bookTitle = title
    }
    
    func updateNowPlayingInfo(title: String, chapter: String, rate: Float) {
        currentParagraphText = title
        
        let estimatedDuration = Double(title.count) / 5.0 / Double(rate)
        
        let nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: bookTitle,
            MPMediaItemPropertyAlbumTitle: chapter,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPMediaItemPropertyPlaybackDuration: estimatedDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func updateNowPlayingPlaybackState(isPlaying: Bool, rate: Float) {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func speakWithHTTP(text: String, completion: @escaping (Bool) -> Void) {
        log("speakWithHTTP started")
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            log("No API key")
            completion(false)
            return
        }
        
        var voiceToUse = selectedVoice
        if voiceToUse.isEmpty {
            voiceToUse = "zh-CN-XiaoxiaoNeural"
        }
        
        let rateValue = Int((selectedRate - 0.5) * 200)
        
        var queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "t", value: text),
            URLQueryItem(name: "v", value: voiceToUse),
            URLQueryItem(name: "r", value: String(rateValue))
        ]
        
        if !selectedStyle.isEmpty {
            queryItems.append(URLQueryItem(name: "s", value: selectedStyle))
        }
        
        var components = URLComponents(string: "\(baseURL)/tts")!
        components.queryItems = queryItems
        
        guard let url = components.url else {
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.log("TTS HTTP error: \(error.localizedDescription)")
                    completion(false)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.log("TTS HTTP: invalid response")
                    completion(false)
                    return
                }
                
                guard httpResponse.statusCode == 200 else {
                    self?.log("TTS HTTP: status code \(httpResponse.statusCode)")
                    completion(false)
                    return
                }
                
                guard let data = data, !data.isEmpty else {
                    self?.log("TTS HTTP: no data")
                    completion(false)
                    return
                }
                
                if data.count < 100 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let error = json["error"] as? String {
                            self?.log("TTS API error: \(error)")
                            completion(false)
                            return
                        }
                    }
                }
                
                do {
                    self?.log("Creating audio player with data size: \(data.count)")
                    self?.audioPlayer = try AVAudioPlayer(data: data)
                    self?.activePlaybackBackend = .http
                    self?.audioPlayer?.delegate = self
                    self?.audioPlayer?.prepareToPlay()
                    self?.audioPlayer?.play()
                    self?.log("Audio started playing")
                    completion(true)
                } catch {
                    self?.log("TTS audio player error: \(error)")
                    completion(false)
                }
            }
        }.resume()
    }
    
    private func speakWithLocal(text: String, completion: @escaping (Bool) -> Void) {
        activePlaybackBackend = .local
        localTTSCompletion = { [weak self] in
            self?.localTTSCompletion = nil
            self?.onSpeechFinished?()
            completion(true)
        }
        
        if localTTSEngine == nil {
            localTTSEngine = AVSpeechSynthesizer()
            localTTSEngine?.delegate = self
        }
        
        if localTTSEngine?.isSpeaking == true {
            localTTSEngine?.stopSpeaking(at: .immediate)
        }
        
        let cleanedText = text.replacingOccurrences(of: "\n", with: " ")
        let utterance = AVSpeechUtterance(string: cleanedText)
        
        let chineseVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        if let voice = chineseVoices.first {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * selectedRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        localTTSEngine?.speak(utterance)
    }
}

extension TTSService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onSpeechFinished?()
        currentCompletion?(flag)
        currentCompletion = nil
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        log("Audio decode error: \(error?.localizedDescription ?? "unknown")")
        currentCompletion?(false)
        currentCompletion = nil
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onSpeechFinished?()
        localTTSCompletion?()
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onSpeechFinished?()
        localTTSCompletion?()
    }
}

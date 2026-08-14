import Foundation

// MARK: - Content Source Models
struct ContentSource: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var isActive: Bool
    var sourceType: SourceType = .vod  // 新增：源类型
    var liveSource: LiveSource?  // 新增：直播源数据
    
    // MARK: - Source Type
    enum SourceType: String, CaseIterable, Codable {
        case vod  // 视频点播源
        case live  // 直播源
        case special  // 特殊源（type=3）
        
        var displayName: String {
            switch self {
            case .vod: return "影视源"
            case .live: return "直播源"
            case .special: return "特殊源"
            }
        }
    }
    
    init(name: String, url: String, isActive: Bool = true, sourceType: SourceType = .vod, liveSource: LiveSource? = nil) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.isActive = isActive
        self.sourceType = sourceType
        self.liveSource = liveSource
    }
    
    var fullURL: String {
        return url
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, url, isActive, sourceType, liveSource
    }
    
    // 自定义解码以支持新字段
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        url = try container.decode(String.self, forKey: .url)
        
        // 解析源类型
        if let typeValue = try? container.decode(String.self, forKey: .sourceType) {
            sourceType = SourceType(rawValue: typeValue) ?? .vod
        } else {
            sourceType = .vod
        }
        
        // 解析直播源数据
        liveSource = try container.decodeIfPresent(LiveSource.self, forKey: .liveSource)
    }
    
    // 自定义编码器
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(sourceType, forKey: .sourceType)
        try container.encodeIfPresent(liveSource, forKey: .liveSource)
    }
}

// MARK: - Subscription Models (for external JSON format)
struct SubscriptionResponse: Decodable {
    let sites: [RawSite]
    let lives: [LiveSource]?
    let spider: String?
    let wallpaper: String?
    let warningText: String?
}

struct EnhancedSubscriptionResponse: Decodable {
    let sites: [RawSite]
    let lives: [LiveSource]?
    let spider: String?
    let wallpaper: String?
    let warningText: String?
    
    init(sites: [RawSite], lives: [LiveSource]? = nil, spider: String? = nil, wallpaper: String? = nil, warningText: String? = nil) {
        self.sites = sites
        self.lives = lives
        self.spider = spider
        self.wallpaper = wallpaper
        self.warningText = warningText
    }
}

// MARK: - Live Source Models
struct LiveSource: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let type: Int
    let url: String
    let playerType: Int?
    let ua: String?
    let epg: String?
    let logo: String?
    let timeout: Int?
    
    var isActive: Bool = true
    var fullURL: String { url }
    
    var isEnabled: Bool {
        get { isActive }
        set { isActive = newValue }
    }
    
    init(name: String, url: String, type: Int = 0, playerType: Int? = nil, ua: String? = nil, epg: String? = nil, logo: String? = nil, timeout: Int? = nil) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.type = type
        self.playerType = playerType
        self.ua = ua
        self.epg = epg
        self.logo = logo
        self.timeout = timeout
    }
    
    // Custom decoding to handle missing id field from JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Generate new UUID if not present in JSON
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(Int.self, forKey: .type)
        url = try container.decode(String.self, forKey: .url)
        playerType = try container.decodeIfPresent(Int.self, forKey: .playerType)
        ua = try container.decodeIfPresent(String.self, forKey: .ua)
        epg = try container.decodeIfPresent(String.self, forKey: .epg)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        timeout = try container.decodeIfPresent(Int.self, forKey: .timeout)
        // 解码isActive，如果不存在则默认为true
        isActive = (try? container.decode(Bool.self, forKey: .isActive)) ?? true
    }
    
    // Custom encoding to include isActive
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(playerType, forKey: .playerType)
        try container.encodeIfPresent(ua, forKey: .ua)
        try container.encodeIfPresent(epg, forKey: .epg)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encodeIfPresent(timeout, forKey: .timeout)
        try container.encode(isActive, forKey: .isActive)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, type, url, playerType, ua, epg, logo, timeout, isActive
    }
}

struct LiveChannel: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let url: String
    let logo: String?
    let group: String?
    let sourceName: String
    
    init(id: String = UUID().uuidString, name: String, url: String, logo: String? = nil, group: String? = nil, sourceName: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.logo = logo
        self.group = group
        self.sourceName = sourceName
    }
}

struct RawSite: Decodable {
    let key: String
    let name: String
    let type: Int
    let api: String
    let ext: RawSiteExt?
    let searchable: Int?
    let quickSearch: Int?
    let filterable: Int?
    let changeable: Int?
    let indexs: Int?
    let gridview: String? // Changed from Int? to String? to handle values like "0-0-4.1"
    let style: RawSiteStyle?
    let playerType: StringOrInt? // Can be string or int
    let jar: String?
    let orderNum: Int?
    let playUrl: String?
    
    // Custom decoding to handle ext as either string or object
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        key = try container.decode(String.self, forKey: .key)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(Int.self, forKey: .type)
        api = try container.decode(String.self, forKey: .api)
        searchable = try container.decodeIfPresent(Int.self, forKey: .searchable)
        quickSearch = try container.decodeIfPresent(Int.self, forKey: .quickSearch)
        filterable = try container.decodeIfPresent(Int.self, forKey: .filterable)
        changeable = try container.decodeIfPresent(Int.self, forKey: .changeable)
        indexs = try container.decodeIfPresent(Int.self, forKey: .indexs)
        
        // Handle gridview which can be either string or number
        if let gridviewString = try? container.decode(String.self, forKey: .gridview) {
            gridview = gridviewString
        } else if let gridviewInt = try? container.decode(Int.self, forKey: .gridview) {
            gridview = String(gridviewInt)
        } else {
            gridview = nil
        }
        
        style = try container.decodeIfPresent(RawSiteStyle.self, forKey: .style)
        jar = try container.decodeIfPresent(String.self, forKey: .jar)
        orderNum = try container.decodeIfPresent(Int.self, forKey: .orderNum)
        playUrl = try container.decodeIfPresent(String.self, forKey: .playUrl)
        
        // Handle playerType which can be either string or int
        if let playerTypeString = try? container.decode(String.self, forKey: .playerType) {
            playerType = .string(playerTypeString)
        } else if let playerTypeInt = try? container.decode(Int.self, forKey: .playerType) {
            playerType = .int(playerTypeInt)
        } else {
            playerType = nil
        }
        
        // Handle ext field which can be either string or object
        if let extString = try? container.decode(String.self, forKey: .ext) {
            // If ext is a string, create a RawSiteExt with url set to the string
            ext = RawSiteExt(url: extString, dataKey: nil, dataIv: nil, deviceId: nil, version: nil)
        } else if let extObject = try? container.decode(RawSiteExt.self, forKey: .ext) {
            // If ext is an object, use it directly
            ext = extObject
        } else {
            // If ext is not present, set to nil
            ext = nil
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case key, name, type, api, ext, searchable, quickSearch, filterable, changeable, indexs, gridview, style, playerType, jar, orderNum, playUrl
    }
}

struct RawSiteExt: Decodable {
    let url: String?
    let dataKey: String?
    let dataIv: String?
    let deviceId: String?
    let version: String?
}

struct RawSiteStyle: Decodable {
    let type: String?
    let ratio: Double?
}

// MARK: - Video Models
struct Video: Codable, Identifiable, Equatable {
    let id: Int // Mapped from "vod_id"
    var title: String // Mapped from "vod_name"
    var description: String? // Mapped from "vod_content"
    var cover: String? // Mapped from "vod_pic"
    var year: String? // Mapped from "vod_year"
    var area: String? // Mapped from "vod_area"
    var category: String? // Mapped from "vod_class"
    var language: String? // Mapped from "vod_lang"
    var score: String? // Mapped from "vod_score"
    var director: String? // Mapped from "vod_director"
    var actors: String? // Mapped from "vod_actor"
    var episodes: [Episode]? // Mapped from vod_play_list
    var playUrls: [PlayUrl]? // Mapped from vod_play_url
    var playUrl: String? // Mapped from vod_play_url (single string format)
    var source: String? // Mapped from "vod_play_from"
    var playSources: [PlaySource]? // 新增：多播放源支持

    // Fields from list view
    var typeId: Int? // Mapped from "type_id"
    var typeName: String? // Mapped from "type_name"
    var vodEn: String? // Mapped from "vod_en"
    var vodTime: String? // Mapped from "vod_time"
    var vodRemarks: String? // Mapped from "vod_remarks"
    
    // 新增：视频来源API
    var sourceApi: String? // 标记来源API
    
    // Additional fields that might be present in API response
    var vodSub: String?
    var vodStatus: Int?
    var vodLetter: String?
    var vodColor: String?
    var vodTag: String?
    var vodPicThumb: String?
    var vodPicSlide: String?
    var vodPicScreenshot: String?
    var vodWriter: String?
    var vodBehind: String?
    var vodBlurb: String?
    var vodPubdate: String?
    var vodTotal: Int?
    var vodSerial: String?
    var vodTv: String?
    var vodWeekday: String?
    var vodVersion: String?
    var vodState: String?
    var vodAuthor: String?
    var vodJumpurl: String?
    var vodTpl: String?
    var vodTplPlay: String?
    var vodTplDown: String?
    var vodIsend: Int?
    var vodLock: Int?
    var vodLevel: Int?
    var vodCopyright: Int?
    var vodPoints: Int?
    var vodPointsPlay: Int?
    var vodPointsDown: Int?
    var vodHits: Int?
    var vodHitsDay: Int?
    var vodHitsWeek: Int?
    var vodHitsMonth: Int?
    var vodDuration: String?
    var vodUp: Int?
    var vodDown: Int?
    var vodScoreAll: Int?
    var vodScoreNum: Int?
    var vodTimeAdd: Int?
    var vodTimeHits: Int?
    var vodTimeMake: Int?
    var vodTrysee: Int?
    var vodDoubanId: Int?
    var vodDoubanScore: String?
    var vodReurl: String?
    var vodRelVod: String?
    var vodRelArt: String?
    var vodPwd: String?
    var vodPwdUrl: String?
    var vodPwdPlay: String?
    var vodPwdPlayUrl: String?
    var vodPwdDown: String?
    var vodPwdDownUrl: String?
    var vodPlot: Int?
    var vodPlotName: String?
    var vodPlotDetail: String?
    var vodPlayServer: String?
    var vodPlayNote: String?
    var vodDownFrom: String?
    var vodDownServer: String?
    var vodDownNote: String?
    var vodDownUrl: String?
    var typeId1: Int?
    var groupId: Int?
    
    enum CodingKeys: String, CodingKey {
        case id = "vod_id"
        case title = "vod_name"
        case description = "vod_content"
        case cover = "vod_pic"
        case year = "vod_year"
        case area = "vod_area"
        case category = "vod_class"
        case language = "vod_lang"
        case score = "vod_score"
        case director = "vod_director"
        case actors = "vod_actor"
        case episodes = "vod_play_list"
        case playUrls = "vod_play_url"
        case source = "vod_play_from"
        case typeId = "type_id"
        case typeName = "type_name"
        case vodEn = "vod_en"
        case vodTime = "vod_time"
        case vodRemarks = "vod_remarks"
        case sourceApi = "vod_play_from_api"
        case vodSub = "vod_sub"
        case vodStatus = "vod_status"
        case vodLetter = "vod_letter"
        case vodColor = "vod_color"
        case vodTag = "vod_tag"
        case vodPicThumb = "vod_pic_thumb"
        case vodPicSlide = "vod_pic_slide"
        case vodPicScreenshot = "vod_pic_screenshot"
        case vodWriter = "vod_writer"
        case vodBehind = "vod_behind"
        case vodBlurb = "vod_blurb"
        case vodPubdate = "vod_pubdate"
        case vodTotal = "vod_total"
        case vodSerial = "vod_serial"
        case vodTv = "vod_tv"
        case vodWeekday = "vod_weekday"
        case vodVersion = "vod_version"
        case vodState = "vod_state"
        case vodAuthor = "vod_author"
        case vodJumpurl = "vod_jumpurl"
        case vodTpl = "vod_tpl"
        case vodTplPlay = "vod_tpl_play"
        case vodTplDown = "vod_tpl_down"
        case vodIsend = "vod_isend"
        case vodLock = "vod_lock"
        case vodLevel = "vod_level"
        case vodCopyright = "vod_copyright"
        case vodPoints = "vod_points"
        case vodPointsPlay = "vod_points_play"
        case vodPointsDown = "vod_points_down"
        case vodHits = "vod_hits"
        case vodHitsDay = "vod_hits_day"
        case vodHitsWeek = "vod_hits_week"
        case vodHitsMonth = "vod_hits_month"
        case vodDuration = "vod_duration"
        case vodUp = "vod_up"
        case vodDown = "vod_down"
        case vodScoreAll = "vod_score_all"
        case vodScoreNum = "vod_score_num"
        case vodTimeAdd = "vod_time_add"
        case vodTimeHits = "vod_time_hits"
        case vodTimeMake = "vod_time_make"
        case vodTrysee = "vod_trysee"
        case vodDoubanId = "vod_douban_id"
        case vodDoubanScore = "vod_douban_score"
        case vodReurl = "vod_reurl"
        case vodRelVod = "vod_rel_vod"
        case vodRelArt = "vod_rel_art"
        case vodPwd = "vod_pwd"
        case vodPwdUrl = "vod_pwd_url"
        case vodPwdPlay = "vod_pwd_play"
        case vodPwdPlayUrl = "vod_pwd_play_url"
        case vodPwdDown = "vod_pwd_down"
        case vodPwdDownUrl = "vod_pwd_down_url"
        case vodPlot = "vod_plot"
        case vodPlotName = "vod_plot_name"
        case vodPlotDetail = "vod_plot_detail"
        case vodPlayServer = "vod_play_server"
        case vodPlayNote = "vod_play_note"
        case vodDownFrom = "vod_down_from"
        case vodDownServer = "vod_down_server"
        case vodDownNote = "vod_down_note"
        case vodDownUrl = "vod_down_url"
        case typeId1 = "type_id_1"
        case groupId = "group_id"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode basic fields with enhanced error handling
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        year = try container.decodeIfPresent(String.self, forKey: .year)
        area = try container.decodeIfPresent(String.self, forKey: .area)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        score = try container.decodeIfPresent(String.self, forKey: .score)
        director = try container.decodeIfPresent(String.self, forKey: .director)
        actors = try container.decodeIfPresent(String.self, forKey: .actors)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        
        // Enhanced play URL handling with multiple fallback strategies
        playUrl = try container.decodeIfPresent(String.self, forKey: .playUrls)
        
        // Parse vod_play_url string into PlaySource objects (支持多播放源)
        if let playUrlString = playUrl, !playUrlString.isEmpty {
            playSources = parsePlaySources(from: playUrlString, sourceNames: source)
            
            // 为了向后兼容，保留原有的 playUrls 解析逻辑
            playUrls = parsePlayUrls(from: playUrlString)
        } else {
            playSources = nil
            playUrls = nil
        }
        
        // Decode other fields with enhanced error handling
        episodes = try container.decodeIfPresent([Episode].self, forKey: .episodes)
        
        // Convert playUrls to episodes if no episodes exist
        if (episodes == nil || episodes?.isEmpty == true) && playUrls != nil && !playUrls!.isEmpty {
            episodes = playUrls!.enumerated().map { index, playUrl in
                Episode(title: "第\(index + 1)集", playUrl: playUrl.url, episodeNumber: index + 1)
            }
        }
        
        // Enhanced field parsing with type conversion support
        typeId = try container.decodeIfPresent(Int.self, forKey: .typeId)
        typeName = try container.decodeIfPresent(String.self, forKey: .typeName)
        vodEn = try container.decodeIfPresent(String.self, forKey: .vodEn)
        vodTime = try container.decodeIfPresent(String.self, forKey: .vodTime)
        vodRemarks = try container.decodeIfPresent(String.self, forKey: .vodRemarks)
        sourceApi = try container.decodeIfPresent(String.self, forKey: .sourceApi)
        
        // Set all other fields to nil for now to avoid parsing issues
        vodSub = nil
        vodStatus = nil
        vodLetter = nil
        vodColor = nil
        vodTag = nil
        vodPicThumb = nil
        vodPicSlide = nil
        vodPicScreenshot = nil
        vodWriter = nil
        vodBehind = nil
        vodBlurb = nil
        vodPubdate = nil
        vodTotal = nil
        vodSerial = nil
        vodTv = nil
        vodWeekday = nil
        vodVersion = nil
        vodState = nil
        vodAuthor = nil
        vodJumpurl = nil
        vodTpl = nil
        vodTplPlay = nil
        vodTplDown = nil
        vodIsend = nil
        vodLock = nil
        vodLevel = nil
        vodCopyright = nil
        vodPoints = nil
        vodPointsPlay = nil
        vodPointsDown = nil
        vodHits = nil
        vodHitsDay = nil
        vodHitsWeek = nil
        vodHitsMonth = nil
        vodDuration = nil
        vodUp = nil
        vodDown = nil
        vodScoreAll = nil
        vodScoreNum = nil
        vodTimeAdd = nil
        vodTimeHits = nil
        vodTimeMake = nil
        vodTrysee = nil
        vodDoubanId = nil
        vodDoubanScore = nil
        vodReurl = nil
        vodRelVod = nil
        vodRelArt = nil
        vodPwd = nil
        vodPwdUrl = nil
        vodPwdPlay = nil
        vodPwdPlayUrl = nil
        vodPwdDown = nil
        vodPwdDownUrl = nil
        vodPlot = nil
        vodPlotName = nil
        vodPlotDetail = nil
        vodPlayServer = nil
        vodPlayNote = nil
        vodDownFrom = nil
        vodDownServer = nil
        vodDownNote = nil
        vodDownUrl = nil
        typeId1 = nil
        groupId = nil
    }
    
    // MARK: - Helper Methods
    
    /// 测试多播放源解析功能
    static func testMultiSourceParsing() {
        let testPlayFrom = "jsyun$$$jsm3u8"
        let testPlayUrl = "第01集$https://vv.jisuzyv.com/play/oeE1GWme#第02集$https://vv.jisuzyv.com/play/PdRk8kOe#第03集$https://vv.jisuzyv.com/play/ZdPgrl6b$$$第01集$https://vv.jisuzyv.com/play/oeE1GWme/index.m3u8#第02集$https://vv.jisuzyv.com/play/PdRk8kOe/index.m3u8#第03集$https://vv.jisuzyv.com/play/ZdPgrl6b/index.m3u8"
        
        // 创建临时 Video 对象来测试解析
        let video = Video(id: 1, title: "测试视频")
        let playSources = video.parsePlaySources(from: testPlayUrl, sourceNames: testPlayFrom)
        
        // 测试智能 URL 处理
        let iframeTestUrl = "第01集$https://vv.jisuzyv.com/play/oeE1GWme#第02集$https://vv.jisuzyv.com/play/PdRk8kOe"
        let iframeEpisodes = video.parseEpisodesFromSource(iframeTestUrl, sourceName: "jsyun")
        
        let m3u8TestUrl = "第01集$https://vv.jisuzyv.com/play/oeE1GWme/index.m3u8#第02集$https://vv.jisuzyv.com/play/PdRk8kOe/index.m3u8"
        let m3u8Episodes = video.parseEpisodesFromSource(m3u8TestUrl, sourceName: "jsm3u8")
        
        let directVideoTestUrl = "第01集$https://example.com/video.mp4#第02集$https://example.com/video2.avi"
        let directVideoEpisodes = video.parseEpisodesFromSource(directVideoTestUrl, sourceName: "direct")
    }
    
    /// 解析多播放源数据
    /// - Parameters:
    ///   - playUrlString: vod_play_url 字段的原始字符串
    ///   - sourceNames: vod_play_from 字段的播放源名称
    /// - Returns: 解析后的播放源数组
    func parsePlaySources(from playUrlString: String, sourceNames: String?) -> [PlaySource] {
        var playSources: [PlaySource] = []
        
        // 1. 解析播放源名称
        let sourceNameArray = sourceNames?.components(separatedBy: "$$$") ?? []
        
        // 2. 按 $$$ 分割播放源URL
        let sourceUrlArray = playUrlString.components(separatedBy: "$$$")
        
        // 3. 遍历每个播放源
        for (index, sourceUrls) in sourceUrlArray.enumerated() {
            let sourceName = index < sourceNameArray.count ? sourceNameArray[index] : "播放源\(index + 1)"
            let episodes = parseEpisodesFromSource(sourceUrls, sourceName: sourceName)
            
            if !episodes.isEmpty {
                let playSource = PlaySource(name: sourceName, episodes: episodes)
                playSources.append(playSource)
            }
        }
        
        return playSources
    }
    
    /// 从单个播放源的URL字符串中解析分集
    /// - Parameters:
    ///   - sourceUrls: 单个播放源的URL字符串
    ///   - sourceName: 播放源名称，用于判断是否需要转换格式
    /// - Returns: 分集数组
    func parseEpisodesFromSource(_ sourceUrls: String, sourceName: String) -> [Episode] {
        var episodes: [Episode] = []
        
        // 按 # 分割分集
        let episodeStrings = sourceUrls.components(separatedBy: "#")
        
        for (index, episodeString) in episodeStrings.enumerated() {
            let trimmed = episodeString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // 按 $ 分割分集名和URL
                if let dollarIndex = trimmed.firstIndex(of: "$") {
                    let episodeTitle = String(trimmed[..<dollarIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                    var episodeUrl = String(trimmed[trimmed.index(after: dollarIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !episodeUrl.isEmpty {
                        // 智能处理 URL 格式
                        episodeUrl = processPlayUrl(episodeUrl, sourceName: sourceName)
                        
                        let episode = Episode(
                            title: episodeTitle.isEmpty ? "第\(index + 1)集" : episodeTitle,
                            playUrl: episodeUrl,
                            episodeNumber: index + 1
                        )
                        episodes.append(episode)
                    }
                } else {
                    // 如果没有 $ 分隔符，但有 http 链接，作为默认分集
                    if trimmed.hasPrefix("http") {
                        var episodeUrl = trimmed
                        // 智能处理 URL 格式
                        episodeUrl = processPlayUrl(episodeUrl, sourceName: sourceName)
                        
                        let episode = Episode(
                            title: "第\(index + 1)集",
                            playUrl: episodeUrl,
                            episodeNumber: index + 1
                        )
                        episodes.append(episode)
                    }
                }
            }
        }
        
        return episodes
    }
    
    /// 智能处理播放 URL
    /// - Parameters:
    ///   - url: 原始 URL
    ///   - sourceName: 播放源名称
    /// - Returns: 处理后的 URL
    private func processPlayUrl(_ url: String, sourceName: String) -> String {
        // 现在不做任何处理，直接返回原始链接
        return url
    }
    
    /// 判断是否需要将 URL 转换为 m3u8 格式
    /// - Parameters:
    ///   - sourceName: 播放源名称
    ///   - url: 原始 URL
    /// - Returns: 是否需要转换
    private func shouldConvertUrlToM3u8(sourceName: String, url: String) -> Bool {
        // 如果播放源名称包含 m3u8，说明这个源本身就是 m3u8 格式
        if sourceName.lowercased().contains("m3u8") {
            return false
        }
        
        // 如果 URL 包含特定的 iframe 特征，需要转换
        let iframePatterns = [
            "play/",
            "player/"
        ]
        
        for pattern in iframePatterns {
            if url.contains(pattern) {
                return true
            }
        }
        
        // 默认情况下，如果 URL 不包含明显的视频格式标识，则转换为 m3u8
        return !url.contains(".mp4") && !url.contains(".avi") && !url.contains(".mkv")
    }
    
    /// 原有的单播放源解析方法（保持向后兼容）
    private func parsePlayUrls(from playUrlString: String) -> [PlayUrl] {
        var playUrls: [PlayUrl] = []
        
        // 如果包含 $$$，说明是多播放源，只取第一个播放源
        let firstSource = playUrlString.components(separatedBy: "$$$").first ?? playUrlString
        
        // Split by # to get individual episodes
        let episodes = firstSource.components(separatedBy: "#")
        
        for episode in episodes {
            let trimmed = episode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Split by $ to get quality and URL
                if let dollarIndex = trimmed.firstIndex(of: "$") {
                    let quality = String(trimmed[..<dollarIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                    var url = String(trimmed[trimmed.index(after: dollarIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !url.isEmpty {
                        // 使用智能 URL 处理逻辑
                        url = processPlayUrl(url, sourceName: "default")
                        playUrls.append(PlayUrl(name: quality, url: url, type: nil))
                    }
                } else {
                    // If no $ separator, treat as URL with default quality
                    if trimmed.hasPrefix("http") {
                        var url = trimmed
                        // 使用智能 URL 处理逻辑
                        url = processPlayUrl(url, sourceName: "default")
                        playUrls.append(PlayUrl(name: "默认", url: url, type: nil))
                    }
                }
            }
        }
        
        return playUrls
    }
    
    // Custom initializer for previews and testing
    init(id: Int, title: String, description: String? = nil, cover: String? = nil, year: String? = nil, area: String? = nil, score: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.cover = cover
        self.year = year
        self.area = area
        self.score = score
        self.category = nil
        self.language = nil
        self.director = nil
        self.actors = nil
        self.episodes = nil
        self.playUrls = nil
        self.playUrl = nil
        self.source = nil
        self.playSources = nil
        self.typeId = nil
        self.typeName = nil
        self.vodEn = nil
        self.vodTime = nil
        self.vodRemarks = nil
        self.sourceApi = nil
        self.vodSub = nil
        self.vodStatus = nil
        self.vodLetter = nil
        self.vodColor = nil
        self.vodTag = nil
        self.vodPicThumb = nil
        self.vodPicSlide = nil
        self.vodPicScreenshot = nil
        self.vodWriter = nil
        self.vodBehind = nil
        self.vodBlurb = nil
        self.vodPubdate = nil
        self.vodTotal = nil
        self.vodSerial = nil
        self.vodTv = nil
        self.vodWeekday = nil
        self.vodVersion = nil
        self.vodState = nil
        self.vodAuthor = nil
        self.vodJumpurl = nil
        self.vodTpl = nil
        self.vodTplPlay = nil
        self.vodTplDown = nil
        self.vodIsend = nil
        self.vodLock = nil
        self.vodLevel = nil
        self.vodCopyright = nil
        self.vodPoints = nil
        self.vodPointsPlay = nil
        self.vodPointsDown = nil
        self.vodHits = nil
        self.vodHitsDay = nil
        self.vodHitsWeek = nil
        self.vodHitsMonth = nil
        self.vodDuration = nil
        self.vodUp = nil
        self.vodDown = nil
        self.vodScoreAll = nil
        self.vodScoreNum = nil
        self.vodTimeAdd = nil
        self.vodTimeHits = nil
        self.vodTimeMake = nil
        self.vodTrysee = nil
        self.vodDoubanId = nil
        self.vodDoubanScore = nil
        self.vodReurl = nil
        self.vodRelVod = nil
        self.vodRelArt = nil
        self.vodPwd = nil
        self.vodPwdUrl = nil
        self.vodPwdPlay = nil
        self.vodPwdPlayUrl = nil
        self.vodPwdDown = nil
        self.vodPwdDownUrl = nil
        self.vodPlot = nil
        self.vodPlotName = nil
        self.vodPlotDetail = nil
        self.vodPlayServer = nil
        self.vodPlayNote = nil
        self.vodDownFrom = nil
        self.vodDownServer = nil
        self.vodDownNote = nil
        self.vodDownUrl = nil
        self.typeId1 = nil
        self.groupId = nil
    }
}

// MARK: - 新增多播放源数据结构
struct PlaySource: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var episodes: [Episode]
    
    init(name: String, episodes: [Episode]) {
        self.id = UUID()
        self.name = name
        self.episodes = episodes
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, episodes
    }
}

struct Episode: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var playUrl: String
    var episodeNumber: Int?
    
    init(title: String, playUrl: String, episodeNumber: Int? = nil) {
        self.id = UUID()
        self.title = title
        self.playUrl = playUrl
        self.episodeNumber = episodeNumber
    }
    
    enum CodingKeys: String, CodingKey {
        case id, title, playUrl, episodeNumber
    }
}

struct PlayUrl: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var type: String?
    
    init(name: String, url: String, type: String? = nil) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.type = type
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, url, type
    }
}

// MARK: - Category Models
struct Category: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var typeId: Int
    var typePid: Int? // 改为可选
    
    init(name: String, typeId: Int, typePid: Int? = nil) {
        self.id = UUID()
        self.name = name
        self.typeId = typeId
        self.typePid = typePid
    }
    
    // 自定义解码器，自动生成UUID
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = UUID() // 自动生成UUID
        self.name = try container.decode(String.self, forKey: .name)
        self.typeId = try container.decode(Int.self, forKey: .typeId)
        self.typePid = try container.decodeIfPresent(Int.self, forKey: .typePid)
    }
    
    // 自定义编码器
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(typeId, forKey: .typeId)
        try container.encodeIfPresent(typePid, forKey: .typePid)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name = "type_name", typeId = "type_id", typePid = "type_pid"
    }
    // Equatable 自动合成，无需手写
}

// MARK: - API Response Models
struct CategoryListResponse: Codable {
    var code: Int
    var msg: String
    var page: StringOrInt
    var pagecount: StringOrInt
    var limit: StringOrInt
    var total: StringOrInt
    var list: [Video]? // 视频列表（可选，因为我们主要关心分类）
    var categories: [Category]

    enum CodingKeys: String, CodingKey {
        case code, msg, page, pagecount, limit, total, list
        case categories = "class"
    }
    
    // 添加自定义初始化器
    init(code: Int, msg: String, page: StringOrInt, pagecount: StringOrInt, limit: StringOrInt, total: StringOrInt, list: [Video]?, categories: [Category]) {
        self.code = code
        self.msg = msg
        self.page = page
        self.pagecount = pagecount
        self.limit = limit
        self.total = total
        self.list = list
        self.categories = categories
    }
}

struct VideoListResponse: Codable {
    var code: Int
    var msg: String
    var page: Int
    var pagecount: Int
    var limit: String
    var total: Int
    var list: [Video]

    enum CodingKeys: String, CodingKey {
        case code, msg, page, pagecount, limit, total, list
    }

    init(code: Int, msg: String, page: Int, pagecount: Int, limit: String, total: Int, list: [Video]) {
        self.code = code
        self.msg = msg
        self.page = page
        self.pagecount = pagecount
        self.limit = limit
        self.total = total
        self.list = list
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        msg = try container.decode(String.self, forKey: .msg)
        // 兼容数字和字符串
        if let intPage = try? container.decode(Int.self, forKey: .page) {
            page = intPage
        } else if let strPage = try? container.decode(String.self, forKey: .page), let intPage = Int(strPage) {
            page = intPage
        } else {
            page = 1 // 默认值
        }
        pagecount = try container.decode(Int.self, forKey: .pagecount)
        limit = try container.decode(String.self, forKey: .limit)
        total = try container.decode(Int.self, forKey: .total)
        list = try container.decode([Video].self, forKey: .list)
    }
}

// For detail endpoint, where the video object is at the top level with code/msg
struct VideoDetailAPIResponse: Codable {
    var code: Int
    var msg: String
    // All Video properties directly here, since it's not nested under a 'data' key
    let id: Int
    var title: String
    var description: String?
    var cover: String?
    var year: String?
    var area: String?
    var category: String?
    var language: String?
    var score: String?
    var director: String?
    var actors: String?
    var episodes: [Episode]?
    var playUrls: [PlayUrl]?
    var source: String?
    var typeId: Int?
    var typeName: String?
    var vodEn: String?
    var vodTime: String?
    var vodRemarks: String?

    enum CodingKeys: String, CodingKey {
        case code, msg
        case id = "vod_id"
        case title = "vod_name"
        case description = "vod_content"
        case cover = "vod_pic"
        case year = "vod_year"
        case area = "vod_area"
        case category = "vod_class"
        case language = "vod_lang"
        case score = "vod_score"
        case director = "vod_director"
        case actors = "vod_actor"
        case episodes = "vod_play_list"
        case playUrls = "vod_play_url"
        case source = "vod_play_from"
        case typeId = "type_id"
        case typeName = "type_name"
        case vodEn = "vod_en"
        case vodTime = "vod_time"
        case vodRemarks = "vod_remarks"
    }
}

// For playurls endpoint, where the playurls array is at the top level with code/msg
struct PlayUrlListAPIResponse: Codable {
    var code: Int
    var msg: String
    var list: [PlayUrl]

    enum CodingKeys: String, CodingKey {
        case code, msg, list
    }
}

// MARK: - Search Models
// Removed SearchResult and SearchResponse as VideoListResponse can be used.

// MARK: - User Preferences
struct UserPreferences: Codable {
    var selectedSourceId: UUID?
    var selectedCategoryId: String? // 保存选中的分类ID
    var selectedCustomWebPageId: UUID? // 保存选中的自定义页面ID
    var theme: Theme = .system
    var autoPlay: Bool = false
    var quality: VideoQuality = .auto
    var customWebPages: [CustomWebPage] = []
    var useLocalBookParse: Bool = true // 本地解析模式，默认开启
}

// MARK: - Custom Web Page Model
struct CustomWebPage: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var isEnabled: Bool
    
    init(name: String, url: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }
}

enum Theme: String, CaseIterable, Codable {
    case light = "light"
    case dark = "dark"
    case system = "system"
    
    var displayName: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "自动"
        }
    }
    
    var iconName: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }
}

enum VideoQuality: String, CaseIterable, Codable {
    case auto = "auto"
    case high = "high"
    case medium = "medium"
    case low = "low"
    
    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .high: return "高清"
        case .medium: return "标清"
        case .low: return "流畅"
        }
    }
    
    var iconName: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .high: return "4k.tv"
        case .medium: return "tv"
        case .low: return "wifi"
        }
    }
}

// MARK: - Error Models
enum ContentError: Error, LocalizedError {
    case networkError(String)
    case parsingError(String)
    case invalidURL(String)
    case noData(String)
    
    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "网络错误: \(message)"
        case .parsingError(let message):
            return "解析错误: \(message)"
        case .invalidURL(let message):
            return "无效URL: \(message)"
        case .noData(let message):
            return "无数据: \(message)"
        }
    }
} 

enum StringOrInt: Codable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.typeMismatch(StringOrInt.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a string or int"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let intVal):
            try container.encode(intVal)
        case .string(let strVal):
            try container.encode(strVal)
        }
    }
} 

import Foundation

struct PlayHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let video: Video
    let playedAt: Date
    var lastEpisode: Episode?
    var lastPlaybackTime: Double?
    var duration: Double?

    init(video: Video, lastEpisode: Episode? = nil, lastPlaybackTime: Double? = nil, duration: Double? = nil) {
        self.id = UUID()
        self.video = video
        self.playedAt = Date()
        self.lastEpisode = lastEpisode
        self.lastPlaybackTime = lastPlaybackTime
        self.duration = duration
    }
    
    // Custom initializer for loading from file
    init(
        id: UUID,
        video: Video,
        playedAt: Date,
        lastEpisode: Episode? = nil,
        lastPlaybackTime: Double? = nil,
        duration: Double? = nil
    ) {
        self.id = id
        self.video = video
        self.playedAt = playedAt
        self.lastEpisode = lastEpisode
        self.lastPlaybackTime = lastPlaybackTime
        self.duration = duration
    }
    
    enum CodingKeys: String, CodingKey {
        case id, video, playedAt, lastEpisode, lastPlaybackTime, duration
    }
}

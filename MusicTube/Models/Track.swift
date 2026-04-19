import Foundation

struct Track: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let duration: TimeInterval?
    let youtubeVideoID: String?
    let streamURL: URL?

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        youtubeVideoID: String? = nil,
        streamURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration
        self.youtubeVideoID = youtubeVideoID
        self.streamURL = streamURL
    }

    var youtubeWatchURL: URL? {
        guard let youtubeVideoID else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(youtubeVideoID)")
    }

    var youtubeEmbedURL: URL? {
        guard let youtubeVideoID else { return nil }
        return URL(string: "https://www.youtube.com/embed/\(youtubeVideoID)?playsinline=1&autoplay=1")
    }

    var playbackKey: String {
        youtubeVideoID ?? id
    }

    var formattedDuration: String? {
        Self.formatDuration(duration)
    }

    static func formatDuration(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }

        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum PlaylistKind: String, Hashable, Sendable {
    case standard
    case likedMusic
    case uploads
    case savedSongs
    case custom
}

struct Playlist: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let artworkURL: URL?
    let itemCount: Int
    let kind: PlaylistKind
}

enum MusicCollectionKind: String, Codable, Hashable, Sendable {
    case playlist
    case album
    case artist
}

struct MusicCollection: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let sourceID: String
    let title: String
    let subtitle: String
    let description: String
    let artworkURL: URL?
    let itemCount: Int
    let kind: MusicCollectionKind
    let queryHint: String

    init(
        id: String? = nil,
        sourceID: String,
        title: String,
        subtitle: String = "",
        description: String = "",
        artworkURL: URL? = nil,
        itemCount: Int = 0,
        kind: MusicCollectionKind,
        queryHint: String? = nil
    ) {
        self.sourceID = sourceID
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.artworkURL = artworkURL
        self.itemCount = itemCount
        self.kind = kind
        self.queryHint = queryHint ?? [title, subtitle]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        self.id = id ?? "\(kind.rawValue):\(sourceID)"
    }
}

struct SearchResponse: Hashable, Sendable {
    var songs: [Track]
    var playlists: [MusicCollection]
    var albums: [MusicCollection]
    var artists: [MusicCollection]
    var nextSongsContinuationToken: String?

    static let empty = SearchResponse(
        songs: [],
        playlists: [],
        albums: [],
        artists: [],
        nextSongsContinuationToken: nil
    )

    var isEmpty: Bool {
        songs.isEmpty && playlists.isEmpty && albums.isEmpty && artists.isEmpty
    }

    var totalResultCount: Int {
        songs.count + playlists.count + albums.count + artists.count
    }
}

extension Track {
    var isLikelyShortFormVideo: Bool {
        let searchText = normalizedMusicClassificationText
        if searchText.contains("shorts") || searchText.contains("#shorts") {
            return true
        }

        guard let duration else { return false }
        return duration > 0 && duration < 60
    }

    var isClearlyNonMusicContent: Bool {
        let searchText = normalizedMusicClassificationText

        let negativeKeywords = [
            "news", "breaking", "podcast", "interview", "episode", "sermon",
            "preaching", "speech", "lecture", "reaction", "review", "tutorial",
            "walkthrough", "gameplay", "vlog", "unboxing", "livestream",
            "trailer", "trending", "channel intro", "behind the scenes",
            "اخبار", "الأخبار", "عاجل", "نشرة", "برنامج", "حلقة",
            "مباشر", "لقاء", "مقابلة", "الفضائية", "فضائية", "قناة",
            "تعلن", "شركة", "تخفيض", "نفط", "طيران"
        ]

        return negativeKeywords.contains { searchText.contains($0) }
    }

    var isEligibleForMusicSuggestions: Bool {
        !isLikelyShortFormVideo && !isClearlyNonMusicContent
    }

    private var normalizedMusicClassificationText: String {
        "\(title) \(artist)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

extension Array where Element == Playlist {
    func mixAlbumCandidates(limit: Int = 8) -> [Playlist] {
        Array(suggestedMixCandidates().prefix(limit))
    }

    func suggestedMixCandidates() -> [Playlist] {
        let standardPlaylists = filter { playlist in
            (playlist.kind == .standard || playlist.kind == .custom) && playlist.itemCount > 0
        }

        let fallbackCollections = filter { playlist in
            playlist.kind == .uploads && playlist.itemCount > 0
        }

        let candidates = standardPlaylists.isEmpty ? fallbackCollections : standardPlaylists

        return candidates.sorted { lhs, rhs in
            if lhs.suggestedMixScore != rhs.suggestedMixScore {
                return lhs.suggestedMixScore > rhs.suggestedMixScore
            }

            if lhs.itemCount != rhs.itemCount {
                return lhs.itemCount > rhs.itemCount
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

private extension Playlist {
    var suggestedMixScore: Int {
        let searchableText = "\(title) \(description)".lowercased()
        let weightedKeywords: [(String, Int)] = [
            ("mix", 5),
            ("radio", 4),
            ("for you", 4),
            ("daily", 3),
            ("discover", 3),
            ("favorite", 2),
            ("favourite", 2),
            ("hits", 2),
            ("vibes", 2),
            ("chill", 1),
            ("party", 1)
        ]

        return weightedKeywords.reduce(into: 0) { partialResult, keyword in
            if searchableText.contains(keyword.0) {
                partialResult += keyword.1
            }
        }
    }
}

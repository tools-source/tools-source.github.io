import Foundation

struct Track: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let youtubeVideoID: String?
    let streamURL: URL?

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        artworkURL: URL? = nil,
        youtubeVideoID: String? = nil,
        streamURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
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
}

enum PlaylistKind: String, Hashable, Sendable {
    case standard
    case likedMusic
    case uploads
}

struct Playlist: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let artworkURL: URL?
    let itemCount: Int
    let kind: PlaylistKind
}

extension Array where Element == Playlist {
    func mixAlbumCandidates(limit: Int = 8) -> [Playlist] {
        Array(suggestedMixCandidates().prefix(limit))
    }

    func suggestedMixCandidates() -> [Playlist] {
        let standardPlaylists = filter { playlist in
            playlist.kind == .standard && playlist.itemCount > 0
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

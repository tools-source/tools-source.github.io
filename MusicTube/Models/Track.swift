import Foundation

struct Track: Identifiable, Hashable, Sendable {
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
        let standardPlaylists = filter { playlist in
            playlist.kind == .standard && playlist.itemCount > 0
        }

        let fallbackCollections = filter { playlist in
            playlist.kind != .standard && playlist.itemCount > 0
        }

        let orderedPlaylists = standardPlaylists + fallbackCollections
        guard orderedPlaylists.isEmpty == false else { return [] }
        return Array(orderedPlaylists.prefix(limit))
    }
}

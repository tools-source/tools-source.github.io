import Foundation

protocol AuthProviding {
    func restoreSession() async -> YouTubeSession?
    func signIn() async throws -> YouTubeSession
    func signOut() async
}

protocol MusicCatalogProviding {
    func loadHome(accessToken: String) async throws -> (featured: [Track], recent: [Track])
    func search(query: String, accessToken: String?) async throws -> SearchResponse
    func loadPlaylists(accessToken: String) async throws -> [Playlist]
    func loadPlaylistItems(for playlist: Playlist, accessToken: String) async throws -> [Track]
    func loadCollectionItems(for collection: MusicCollection, accessToken: String?) async throws -> [Track]
    func setLikeStatus(for track: Track, isLiked: Bool, accessToken: String) async throws
}

@MainActor
protocol PlaybackControlling: AnyObject {
    var nowPlaying: Track? { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    func play(track: Track)
    func resume()
    func pause()
    func seek(to time: TimeInterval)
}

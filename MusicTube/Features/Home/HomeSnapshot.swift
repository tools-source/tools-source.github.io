import Foundation

struct HomeSnapshot: Equatable, Sendable {
    var spotlightTrack: Track?
    var continueListening: [Track]
    var madeForYou: [IndexedTrackPresentation]
    var recentlyPlayed: [Track]
    var mixes: [Playlist]
    var contextualTracks: [Track]
    var statusMessage: String?
    var recommendationBlurb: String?
    var recommendationGenerationID: UUID
    var nowPlayingKey: String?
    var isPlaying: Bool
    var isLoading: Bool
    var hasLoaded: Bool
    var displayName: String?

    static let empty = HomeSnapshot(
        spotlightTrack: nil,
        continueListening: [],
        madeForYou: [],
        recentlyPlayed: [],
        mixes: [],
        contextualTracks: [],
        statusMessage: nil,
        recommendationBlurb: nil,
        recommendationGenerationID: UUID(),
        nowPlayingKey: nil,
        isPlaying: false,
        isLoading: false,
        hasLoaded: false,
        displayName: nil
    )
}

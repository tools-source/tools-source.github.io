import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum AuthState {
        case restoring
        case signedOut
        case signedIn
    }

    @Published private(set) var authState: AuthState = .restoring
    @Published private(set) var user: YouTubeUser?
    @Published private(set) var featuredTracks: [Track] = []
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published var searchResults: [Track] = []
    @Published var nowPlaying: Track?
    @Published var isPlaying: Bool = false
    @Published var searchQuery: String = ""
    @Published var isLoading: Bool = false
    @Published var isLoadingPlaylists: Bool = false
    @Published var isPlayerPresented: Bool = false
    @Published var isPreparingPlayback: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var hasNextTrack: Bool = false
    @Published private(set) var hasPreviousTrack: Bool = false
    @Published private(set) var hasLoadedHome = false
    @Published private(set) var hasLoadedLibrary = false

    private var session: YouTubeSession?
    private let authService: AuthProviding
    private let catalogService: MusicCatalogProviding
    private let playbackService: PlaybackService
    private var playlistCache: [String: [Track]] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var isRefreshingDashboard = false

    init(
        authService: AuthProviding,
        catalogService: MusicCatalogProviding,
        playbackService: PlaybackService
    ) {
        self.authService = authService
        self.catalogService = catalogService
        self.playbackService = playbackService

        playbackService.$nowPlaying
            .receive(on: DispatchQueue.main)
            .assign(to: \.nowPlaying, on: self)
            .store(in: &cancellables)

        playbackService.$isPlaying
            .receive(on: DispatchQueue.main)
            .assign(to: \.isPlaying, on: self)
            .store(in: &cancellables)

        playbackService.$isResolvingStream
            .receive(on: DispatchQueue.main)
            .assign(to: \.isPreparingPlayback, on: self)
            .store(in: &cancellables)

        playbackService.$playbackErrorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let message else { return }
                self?.errorMessage = message
            }
            .store(in: &cancellables)

        playbackService.$hasNextTrack
            .receive(on: DispatchQueue.main)
            .assign(to: \.hasNextTrack, on: self)
            .store(in: &cancellables)

        playbackService.$hasPreviousTrack
            .receive(on: DispatchQueue.main)
            .assign(to: \.hasPreviousTrack, on: self)
            .store(in: &cancellables)

        Task {
            await restoreSession()
        }
    }

    static func makeDefault() -> AppState {
        AppState(
            authService: YouTubeAuthService(),
            catalogService: YouTubeAPIService(),
            playbackService: PlaybackService()
        )
    }

    var homeMixAlbums: [Playlist] {
        playlists.mixAlbumCandidates()
    }

    func signIn() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let session = try await authService.signIn()
            self.session = session
            self.user = session.user
            authState = .signedIn
            await refreshDashboard()
        } catch {
            errorMessage = error.localizedDescription
            authState = .signedOut
        }
    }

    func signOut() async {
        await authService.signOut()
        playbackService.stop()
        session = nil
        user = nil
        featuredTracks = []
        recentTracks = []
        playlists = []
        searchResults = []
        nowPlaying = nil
        isPlaying = false
        isPlayerPresented = false
        isPreparingPlayback = false
        playlistCache = [:]
        errorMessage = nil
        hasLoadedHome = false
        hasLoadedLibrary = false
        isRefreshingDashboard = false
        authState = .signedOut
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    func refreshDashboard() async {
        guard isRefreshingDashboard == false else { return }

        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }

        await refreshLibrary()
        await refreshHome()
    }

    func refreshHome() async {
        guard let accessToken = session?.accessToken, isLoading == false else { return }

        isLoading = true
        defer {
            isLoading = false
            hasLoadedHome = true
        }

        if await buildHomeFromLoadedLibrary() {
            errorMessage = nil
            AppContainer.shared.carPlayManager?.refresh(using: self)
            return
        }

        do {
            let home = try await catalogService.loadHome(accessToken: accessToken)
            featuredTracks = home.featured
            recentTracks = home.recent
            errorMessage = nil
            AppContainer.shared.carPlayManager?.refresh(using: self)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func performSearch() async {
        _ = await search(query: searchQuery)
    }

    func search(query: String) async -> [Track] {
        guard let accessToken = session?.accessToken else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            searchResults = []
            return []
        }

        do {
            let results = try await catalogService.search(query: trimmed, accessToken: accessToken)
            searchResults = results
            errorMessage = nil
            return results
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func play(track: Track, queue: [Track]? = nil) {
        playbackService.play(track: track, queue: queue)
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    func playNextTrack() {
        playbackService.playNextTrack()
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    func playPreviousTrack() {
        playbackService.playPreviousTrack()
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    func refreshLibrary() async {
        guard let accessToken = session?.accessToken, isLoadingPlaylists == false else { return }

        isLoadingPlaylists = true
        defer {
            isLoadingPlaylists = false
            hasLoadedLibrary = true
        }

        do {
            let loadedPlaylists = try await catalogService.loadPlaylists(accessToken: accessToken)
            let validPlaylistIDs = Set(loadedPlaylists.map(\.id))
            playlists = loadedPlaylists
            playlistCache = playlistCache.filter { validPlaylistIDs.contains($0.key) }
            errorMessage = nil
            AppContainer.shared.carPlayManager?.refresh(using: self)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPlaylistItems(for playlist: Playlist, forceRefresh: Bool = false) async -> [Track] {
        if forceRefresh == false, let cached = playlistCache[playlist.id] {
            return cached
        }

        guard let accessToken = session?.accessToken else { return [] }

        do {
            let tracks = try await catalogService.loadPlaylistItems(
                for: playlist,
                accessToken: accessToken
            )
            playlistCache[playlist.id] = tracks
            errorMessage = nil
            return tracks
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func pause() {
        playbackService.pause()
    }

    func resumePlayback() {
        playbackService.resume()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            resumePlayback()
        }
    }

    func dismissPlayer() {
        isPlayerPresented = false
    }

    private func restoreSession() async {
        if let restored = await authService.restoreSession() {
            session = restored
            user = restored.user
            authState = .signedIn
            await refreshDashboard()
        } else {
            authState = .signedOut
        }
    }

    private func buildHomeFromLoadedLibrary() async -> Bool {
        guard playlists.isEmpty == false else { return false }

        let likedPlaylist = playlists.first(where: { $0.kind == .likedMusic })
        let likedPlaylistID = likedPlaylist?.id
        let mixAlbums = homeMixAlbums
            .filter { $0.id != likedPlaylistID }
            .prefix(4)

        guard likedPlaylist != nil || mixAlbums.isEmpty == false else {
            return false
        }

        let likedTracks: [Track]
        if let likedPlaylist {
            likedTracks = await loadPlaylistItems(for: likedPlaylist)
        } else {
            likedTracks = []
        }

        var mixTracks: [Track] = []
        for playlist in mixAlbums {
            let tracks = await loadPlaylistItems(for: playlist)
            mixTracks.append(contentsOf: Array(tracks.prefix(8)))
        }

        let featured = Array(deduplicatedTracks(likedTracks + mixTracks).prefix(25))
        let recent = Array(deduplicatedTracks(mixTracks + likedTracks).prefix(15))

        guard featured.isEmpty == false || recent.isEmpty == false else {
            return false
        }

        featuredTracks = featured
        recentTracks = recent
        return true
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenTrackIDs: Set<String> = []
        return tracks.filter { track in
            let identifier = track.youtubeVideoID ?? track.id
            return seenTrackIDs.insert(identifier).inserted
        }
    }
}

final class AppContainer {
    static let shared = AppContainer()
    weak var appState: AppState?
    weak var carPlayManager: CarPlayManager?

    private init() {}
}

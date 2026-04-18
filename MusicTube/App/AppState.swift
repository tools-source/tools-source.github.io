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
    @Published private(set) var suggestedMixes: [Playlist] = []
    @Published var searchResults: [Track] = []
    @Published var nowPlaying: Track?
    @Published var isPlaying: Bool = false
    @Published var searchQuery: String = ""
    @Published private(set) var recentSearches: [String] = []
    @Published private(set) var isSearching: Bool = false
    @Published var isLoading: Bool = false
    @Published var isLoadingPlaylists: Bool = false
    @Published var isPlayerPresented: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var homeStatusMessage: String?
    @Published private(set) var libraryStatusMessage: String?
    @Published private(set) var likedTrackIDs: Set<String> = []
    @Published private(set) var hasLoadedHome = false
    @Published private(set) var hasLoadedLibrary = false
    @Published private(set) var sleepTimerEndDate: Date?
    @Published private(set) var isDownloadingNowPlaying: Bool = false
    @Published private(set) var isDeletingAccountData: Bool = false

    private var session: YouTubeSession?
    private var sleepTimerTask: Task<Void, Never>?
    let downloadService = DownloadService.shared
    private let authService: AuthProviding
    private let catalogService: MusicCatalogProviding
    private let playbackService: PlaybackService
    private let localMusicProfileStore: LocalMusicProfileStore
    private var playlistCache: [String: [Track]] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var isRefreshingDashboard = false
    private var activeSearchRequestID: UUID?
    private let localLikedPlaylistID = "local-liked-songs"
    private let localReplayMixPlaylistID = "local-replay-mix"
    private let localFavoritesMixPlaylistID = "local-favorites-mix"

    init(
        authService: AuthProviding,
        catalogService: MusicCatalogProviding,
        playbackService: PlaybackService,
        localMusicProfileStore: LocalMusicProfileStore = .shared
    ) {
        self.authService = authService
        self.catalogService = catalogService
        self.playbackService = playbackService
        self.localMusicProfileStore = localMusicProfileStore

        playbackService.$nowPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self else { return }
                guard self.nowPlaying != track else { return }
                self.nowPlaying = track
                AppContainer.shared.carPlayManager?.refresh(using: self)
            }
            .store(in: &cancellables)

        playbackService.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                guard let self else { return }
                guard self.isPlaying != isPlaying else { return }
                self.isPlaying = isPlaying
                AppContainer.shared.carPlayManager?.refresh(using: self)
            }
            .store(in: &cancellables)

        playbackService.$playbackErrorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let message else { return }
                self?.errorMessage = message
            }
            .store(in: &cancellables)

        // Make appState available to CarPlay immediately — before the SwiftUI
        // .task modifier runs — so CarPlay doesn't show "sign in" on cold connect.
        AppContainer.shared.appState = self

        // Refresh CarPlay as soon as sign-in is confirmed so it gets real content.
        $authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, state == .signedIn else { return }
                AppContainer.shared.carPlayManager?.refresh(using: self)
            }
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

    var playbackEngine: PlaybackService {
        playbackService
    }

    var homeMixAlbums: [Playlist] {
        suggestedMixes
    }

    var likedSongsPlaylist: Playlist? {
        playlists.first(where: { $0.kind == .likedMusic })
    }

    var libraryPlaylists: [Playlist] {
        playlists.filter { $0.kind != .likedMusic }
    }

    var isUsingLocalLibraryFallback: Bool {
        playlists.contains(where: { $0.id.hasPrefix("local-") })
    }

    func isTrackLiked(_ track: Track) -> Bool {
        likedTrackIDs.contains(trackIdentifier(track))
    }

    func signIn() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let session = try await authService.signIn()
            self.session = session
            self.user = session.user
            syncLocalMusicProfileState()
            authState = .signedIn
            await refreshDashboard()
        } catch {
            errorMessage = error.localizedDescription
            authState = .signedOut
        }
    }

    func signOut() async {
        await authService.signOut()
        resetSignedInState()
    }

    func deleteCurrentAccountData() async {
        guard isDeletingAccountData == false else { return }

        isDeletingAccountData = true
        defer { isDeletingAccountData = false }

        await authService.signOut()
        downloadService.deleteAllDownloads()
        localMusicProfileStore.clearAllData()
        resetSignedInState()
    }

    func refreshDashboard() async {
        guard isRefreshingDashboard == false else { return }

        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }

        // Run library and home fetches concurrently — cuts load time roughly in half.
        // Home's remote fetch is independent of library; if it falls back to the local
        // library, playlists may not be populated yet, so it will show empty state until
        // the library fetch also completes (which then calls carPlayManager?.refresh).
        async let libraryFetch: Void = refreshLibrary()
        async let homeFetch: Void = refreshHome()
        _ = await (libraryFetch, homeFetch)
    }

    func refreshHome() async {
        guard let accessToken = session?.accessToken, isLoading == false else { return }

        isLoading = true
        defer {
            isLoading = false
            hasLoadedHome = true
        }

        var remoteHomeError: Error?

        do {
            let home = try await catalogService.loadHome(accessToken: accessToken)
            if home.featured.isEmpty == false || home.recent.isEmpty == false {
                featuredTracks = home.featured
                recentTracks = home.recent
                homeStatusMessage = nil
                // Show content immediately — mixes and stream prefetch run in the background
                // so they don't block the UI or compete with the home/library fetches.
                AppContainer.shared.carPlayManager?.refresh(using: self)
                Task {
                    await rebuildSuggestedMixes()
                    AppContainer.shared.carPlayManager?.refresh(using: self)
                }
                Task {
                    // Delay stream prefetch so it doesn't saturate the network during
                    // the initial load window (the logs showed it causing 10-15s delays).
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self.playbackService.prefetchStreams(for: Array((home.featured + home.recent).prefix(3)))
                }
                return
            }
        } catch {
            remoteHomeError = error
        }

        if await buildHomeFromLoadedLibrary() {
            homeStatusMessage = nil
            AppContainer.shared.carPlayManager?.refresh(using: self)
            return
        }

        featuredTracks = []
        recentTracks = []
        suggestedMixes = []
        playlistCache = playlistCache.filter { isSyntheticMixID($0.key) == false }

        if let remoteHomeError {
            homeStatusMessage = friendlyLibraryMessage(for: remoteHomeError)
        } else if let libraryStatusMessage, libraryStatusMessage.isEmpty == false {
            homeStatusMessage = libraryStatusMessage
        } else {
            homeStatusMessage = "Search and play a few songs to build your MusicTube For You picks."
        }
    }

    func performSearch() async {
        _ = await search(query: searchQuery)
    }

    func search(query: String) async -> [Track] {
        guard let accessToken = session?.accessToken else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            clearSearch()
            return []
        }

        let requestID = UUID()
        activeSearchRequestID = requestID
        isSearching = true

        do {
            let results = try await catalogService.search(query: trimmed, accessToken: accessToken)
            guard activeSearchRequestID == requestID else { return results }
            searchResults = results
            isSearching = false
            errorMessage = nil
            return results
        } catch {
            guard activeSearchRequestID == requestID else { return [] }
            searchResults = []
            isSearching = false
            errorMessage = error.localizedDescription
            return []
        }
    }

    func clearSearch() {
        activeSearchRequestID = nil
        isSearching = false
        searchResults = []
    }

    func recordRecentSearch(_ query: String) {
        let snapshot = localMusicProfileStore.recordSearch(query, for: currentProfileID)
        recentSearches = snapshot.recentSearches
    }

    func removeRecentSearch(_ query: String) {
        let snapshot = localMusicProfileStore.removeRecentSearch(query, for: currentProfileID)
        recentSearches = snapshot.recentSearches
    }

    func recentSearchTrackSuggestions(limit: Int = 18) async -> [Track] {
        guard let accessToken = session?.accessToken else { return [] }

        let suggestionQueries = Array(recentSearches.prefix(6))
        guard suggestionQueries.isEmpty == false else { return [] }

        let resultBuckets = await withTaskGroup(of: [Track]?.self) { group in
            for query in suggestionQueries {
                guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { continue }

                group.addTask {
                    do {
                        let results = try await self.catalogService.search(query: query, accessToken: accessToken)
                        let bucket = Array(results.prefix(12))
                        return bucket.isEmpty ? nil : bucket
                    } catch {
                        return nil
                    }
                }
            }

            var buckets: [[Track]] = []
            for await bucket in group {
                if let bucket {
                    buckets.append(bucket)
                }
            }
            return buckets
        }

        guard resultBuckets.isEmpty == false else { return [] }

        var suggestions: [Track] = []
        var seenTrackIDs: Set<String> = []
        var bucketOffsets = Array(repeating: 0, count: resultBuckets.count)

        while suggestions.count < limit {
            var appendedTrackThisRound = false

            for bucketIndex in resultBuckets.indices {
                while bucketOffsets[bucketIndex] < resultBuckets[bucketIndex].count {
                    let track = resultBuckets[bucketIndex][bucketOffsets[bucketIndex]]
                    bucketOffsets[bucketIndex] += 1

                    let identifier = trackIdentifier(track)
                    guard seenTrackIDs.insert(identifier).inserted else { continue }

                    suggestions.append(track)
                    appendedTrackThisRound = true
                    break
                }

                if suggestions.count >= limit {
                    break
                }
            }

            if appendedTrackThisRound == false {
                break
            }
        }

        return suggestions
    }

    func play(track: Track, queue: [Track]? = nil) {
        recordLocalPlayback(for: track)
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
            let prioritizedPlaylists = mergedLibraryPlaylists(remotePlaylists: loadedPlaylists)
            playlists = prioritizedPlaylists
            await hydrateLikedSongsPlaylistIfNeeded(forceRefresh: true)
            let validPlaylistIDs = Set(playlists.map(\.id) + suggestedMixes.map(\.id))
            playlistCache = playlistCache.filter { validPlaylistIDs.contains($0.key) }
            libraryStatusMessage = prioritizedPlaylists.isEmpty
                ? "Search and play songs to build your MusicTube library."
                : nil
            AppContainer.shared.carPlayManager?.refresh(using: self)
        } catch {
            let localPlaylists = mergedLibraryPlaylists(remotePlaylists: [])
            playlists = localPlaylists
            let validPlaylistIDs = Set(localPlaylists.map(\.id) + suggestedMixes.map(\.id))
            playlistCache = playlistCache.filter { validPlaylistIDs.contains($0.key) }
            libraryStatusMessage = localPlaylists.isEmpty
                ? "YouTube library sync is unavailable right now. Search and play songs to build your MusicTube library."
                : friendlyLibraryMessage(for: error)
        }
    }

    func loadPlaylistItems(for playlist: Playlist, forceRefresh: Bool = false) async -> [Track] {
        if isSyntheticMixID(playlist.id) || isLocalCollectionID(playlist.id) {
            if let cached = playlistCache[playlist.id] {
                return cached
            }

            if isLocalCollectionID(playlist.id) {
                _ = mergedLibraryPlaylists(remotePlaylists: playlists.filter { isLocalCollectionID($0.id) == false })
            } else {
                await rebuildSuggestedMixes()
            }
            return playlistCache[playlist.id] ?? []
        }

        let localLikedTracks = playlist.kind == .likedMusic
            ? localMusicProfileStore.snapshot(for: currentProfileID).likedTracks
            : []

        if forceRefresh == false, let cached = playlistCache[playlist.id] {
            return cached
        }

        guard let accessToken = session?.accessToken else {
            return playlist.kind == .likedMusic ? localLikedTracks : []
        }

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
            if playlist.kind == .likedMusic, localLikedTracks.isEmpty == false {
                let fallbackTracks = deduplicatedTracks(localLikedTracks)
                playlistCache[playlist.id] = fallbackTracks
                return fallbackTracks
            }
            return []
        }
    }

    func pause() {
        playbackService.pause()
    }

    func resumePlayback() {
        playbackService.resume()
    }

    func seek(to time: TimeInterval) {
        playbackService.seek(to: time)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            resumePlayback()
        }
    }

    func closeNowPlaying() {
        playbackService.stop()
        isPlayerPresented = false
    }

    func dismissPlayer() {
        isPlayerPresented = false
    }

    // MARK: Shuffle / Repeat

    func toggleShuffle() {
        playbackService.toggleShuffle()
    }

    func cycleRepeatMode() {
        playbackService.cycleRepeatMode()
    }

    // MARK: Sleep Timer

    func setSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        sleepTimerEndDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard Task.isCancelled == false else { return }
            await MainActor.run { [weak self] in
                self?.pause()
                self?.sleepTimerEndDate = nil
            }
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }

    // MARK: Download

    func downloadNowPlaying() {
        guard let track = nowPlaying else { return }
        downloadTrack(track)
    }

    func downloadTrack(_ track: Track) {
        guard !downloadService.isDownloaded(track), !downloadService.isDownloading(track) else { return }

        isDownloadingNowPlaying = true
        Task {
            defer { Task { @MainActor in self.isDownloadingNowPlaying = false } }
            do {
                if let streamURL = try await playbackService.resolveStreamURL(for: track) {
                    downloadService.startDownload(track: track, streamURL: streamURL)
                }
            } catch {
                print("[AppState] Failed to resolve stream for download: \(error.localizedDescription)")
            }
        }
    }

    private func restoreSession() async {
        if let restored = await authService.restoreSession() {
            session = restored
            user = restored.user
            syncLocalMusicProfileState()
            authState = .signedIn
            await refreshDashboard()
        } else {
            authState = .signedOut
        }
    }

    private func resetSignedInState() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        playbackService.stop()
        session = nil
        user = nil
        featuredTracks = []
        recentTracks = []
        playlists = []
        suggestedMixes = []
        searchResults = []
        nowPlaying = nil
        isPlaying = false
        searchQuery = ""
        isPlayerPresented = false
        isSearching = false
        isDownloadingNowPlaying = false
        playlistCache = [:]
        activeSearchRequestID = nil
        errorMessage = nil
        homeStatusMessage = nil
        libraryStatusMessage = nil
        likedTrackIDs = []
        recentSearches = []
        hasLoadedHome = false
        hasLoadedLibrary = false
        isRefreshingDashboard = false
        sleepTimerEndDate = nil
        authState = .signedOut
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    private func buildHomeFromLoadedLibrary() async -> Bool {
        guard playlists.isEmpty == false else { return false }

        let likedPlaylist = likedSongsPlaylist
        let candidateMixes = selectSuggestedMixSourcePlaylists(from: playlists)
        let likedPlaylistID = likedPlaylist?.id
        let mixAlbums = candidateMixes
            .filter { $0.id != likedPlaylistID }
            .prefix(6)

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
            mixTracks.append(contentsOf: randomizedTracks(from: tracks, limit: 16))
        }

        let featuredPool = deduplicatedTracks(
            randomizedTracks(from: likedTracks, limit: 40) + mixTracks.shuffled()
        )

        guard featuredPool.isEmpty == false else {
            return false
        }

        let featured = Array(featuredPool.prefix(32))
        let featuredIDs = Set(featured.map(trackIdentifier))
        let recent = Array(
            deduplicatedTracks(mixTracks.shuffled() + likedTracks.shuffled())
                .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                .prefix(28)
        )

        guard featured.isEmpty == false || recent.isEmpty == false else {
            return false
        }

        featuredTracks = featured
        recentTracks = recent
        await rebuildSuggestedMixes()
        return true
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenTrackIDs: Set<String> = []
        return tracks.filter { track in
            let identifier = trackIdentifier(track)
            return seenTrackIDs.insert(identifier).inserted
        }
    }

    private func prioritizeLibraryPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let likedPlaylists = playlists.filter { $0.kind == .likedMusic }
        let remainingPlaylists = playlists.filter { $0.kind != .likedMusic }
        return likedPlaylists + remainingPlaylists
    }

    private func selectSuggestedMixSourcePlaylists(from playlists: [Playlist], limit: Int = 8) -> [Playlist] {
        let candidates = playlists.suggestedMixCandidates()
        guard candidates.isEmpty == false else { return [] }

        let poolSize = min(candidates.count, max(limit * 2, limit))
        return Array(candidates.prefix(poolSize).shuffled().prefix(limit))
    }

    private func randomizedTracks(from tracks: [Track], limit: Int) -> [Track] {
        guard tracks.isEmpty == false else { return [] }
        return Array(tracks.shuffled().prefix(limit))
    }

    private func trackIdentifier(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private var currentProfileID: String {
        user?.id ?? "guest"
    }

    private func isSyntheticMixID(_ playlistID: String) -> Bool {
        playlistID.hasPrefix("suggested-mix-")
    }

    private func isLocalCollectionID(_ playlistID: String) -> Bool {
        playlistID.hasPrefix("local-")
    }

    private func syncLocalMusicProfileState() {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        likedTrackIDs = Set(snapshot.likedTracks.map(trackIdentifier))
        recentSearches = snapshot.recentSearches
    }

    private func recordLocalPlayback(for track: Track) {
        let _ = localMusicProfileStore.recordPlayback(of: track, for: currentProfileID)

        if libraryStatusMessage != nil || playlists.isEmpty || playlists.contains(where: { isLocalCollectionID($0.id) }) {
            playlists = mergedLibraryPlaylists(remotePlaylists: playlists.filter { isLocalCollectionID($0.id) == false })
            libraryStatusMessage = playlists.isEmpty
                ? "Search and play songs to build your MusicTube library."
                : "Using your MusicTube activity while YouTube library sync is unavailable."
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.homeStatusMessage != nil || self.featuredTracks.isEmpty {
                if await self.buildHomeFromLoadedLibrary() {
                    self.homeStatusMessage = nil
                    AppContainer.shared.carPlayManager?.refresh(using: self)
                }
            }
        }
    }

    func toggleLike(for track: Track) {
        let shouldLike = likedTrackIDs.contains(trackIdentifier(track)) == false

        guard let accessToken = session?.accessToken else {
            applyLocalLikeState(shouldLike, for: track)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.catalogService.setLikeStatus(for: track, isLiked: shouldLike, accessToken: accessToken)
                self.applyLocalLikeState(shouldLike, for: track)
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func mergedLibraryPlaylists(remotePlaylists: [Playlist]) -> [Playlist] {
        let remoteCollections = remotePlaylists.filter { isLocalCollectionID($0.id) == false }
        let hasRemoteLikedSongs = remoteCollections.contains(where: { $0.kind == .likedMusic })
        let localCollections = buildLocalProfilePlaylists(includeLikedSongs: hasRemoteLikedSongs == false)
        return prioritizeLibraryPlaylists(remoteCollections + localCollections)
    }

    private func buildLocalProfilePlaylists(includeLikedSongs: Bool) -> [Playlist] {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)

        var collections: [Playlist] = []

        if includeLikedSongs, snapshot.likedTracks.isEmpty == false {
            let likedTracks = Array(snapshot.likedTracks.prefix(100))
            playlistCache[localLikedPlaylistID] = likedTracks
            collections.append(
                Playlist(
                    id: localLikedPlaylistID,
                    title: "Liked Songs",
                    description: "Saved in MusicTube",
                    artworkURL: likedTracks.first?.artworkURL,
                    itemCount: likedTracks.count,
                    kind: .likedMusic
                )
            )
        } else {
            playlistCache.removeValue(forKey: localLikedPlaylistID)
        }

        if snapshot.recentTracks.isEmpty == false {
            let replayTracks = Array(snapshot.recentTracks.prefix(60))
            playlistCache[localReplayMixPlaylistID] = replayTracks
            collections.append(
                Playlist(
                    id: localReplayMixPlaylistID,
                    title: "Replay Mix",
                    description: "Built from your recent MusicTube plays",
                    artworkURL: replayTracks.first?.artworkURL,
                    itemCount: replayTracks.count,
                    kind: .standard
                )
            )
        } else {
            playlistCache.removeValue(forKey: localReplayMixPlaylistID)
        }

        let favoriteTracks = Array(deduplicatedTracks(snapshot.likedTracks + snapshot.topTracks).prefix(60))
        if favoriteTracks.isEmpty == false {
            playlistCache[localFavoritesMixPlaylistID] = favoriteTracks
            collections.append(
                Playlist(
                    id: localFavoritesMixPlaylistID,
                    title: "Favorites Mix",
                    description: "Made from the tracks you come back to most",
                    artworkURL: favoriteTracks.first?.artworkURL,
                    itemCount: favoriteTracks.count,
                    kind: .standard
                )
            )
        } else {
            playlistCache.removeValue(forKey: localFavoritesMixPlaylistID)
        }

        return collections
    }

    private func friendlyLibraryMessage(for error: Error) -> String {
        let message = error.localizedDescription.lowercased()

        if message.contains("quota") {
            let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
            if snapshot.hasContent {
                return "Using your MusicTube activity while YouTube library sync is temporarily unavailable."
            }

            return "YouTube library sync is temporarily unavailable. Search and play songs to build your MusicTube library."
        }

        return error.localizedDescription
    }

    private func hydrateLikedSongsPlaylistIfNeeded(forceRefresh: Bool) async {
        guard let likedPlaylist = likedSongsPlaylist else {
            syncLocalMusicProfileState()
            return
        }

        let tracks = await loadPlaylistItems(for: likedPlaylist, forceRefresh: forceRefresh)
        likedTrackIDs = Set(tracks.map(trackIdentifier))

        if let playlistIndex = playlists.firstIndex(where: { $0.id == likedPlaylist.id }) {
            playlists[playlistIndex] = Playlist(
                id: likedPlaylist.id,
                title: likedPlaylist.title,
                description: likedPlaylist.description,
                artworkURL: tracks.first?.artworkURL ?? (tracks.isEmpty ? nil : likedPlaylist.artworkURL),
                itemCount: tracks.count,
                kind: likedPlaylist.kind
            )
        }
    }

    func refreshLikedSongsPlaylistFromAccount() async {
        guard let likedPlaylist = likedSongsPlaylist else {
            syncLocalMusicProfileState()
            return
        }

        guard isLocalCollectionID(likedPlaylist.id) == false else {
            syncLocalMusicProfileState()
            return
        }

        await hydrateLikedSongsPlaylistIfNeeded(forceRefresh: true)
    }

    private func rebuildSuggestedMixes() async {
        let sourcePlaylists = selectSuggestedMixSourcePlaylists(from: playlists, limit: 6)

        // Load liked songs + all source playlists in parallel instead of sequentially.
        let likedPlaylistSnapshot = likedSongsPlaylist
        async let likedFetch: [Track] = {
            if let p = likedPlaylistSnapshot { return await self.loadPlaylistItems(for: p) }
            return []
        }()
        let playlistFetches: [[Track]] = await withTaskGroup(of: [Track].self) { group in
            for playlist in sourcePlaylists {
                group.addTask { await self.loadPlaylistItems(for: playlist) }
            }
            var results: [[Track]] = []
            for await tracks in group { results.append(tracks) }
            return results
        }
        let likedTracks = await likedFetch

        var sourcePools: [[Track]] = []
        if featuredTracks.isEmpty == false || recentTracks.isEmpty == false {
            sourcePools.append(deduplicatedTracks(featuredTracks.shuffled() + recentTracks.shuffled()))
        }
        if likedTracks.isEmpty == false {
            sourcePools.append(deduplicatedTracks(likedTracks.shuffled() + featuredTracks.shuffled()))
        }

        for tracks in playlistFetches {
            guard tracks.isEmpty == false else { continue }
            sourcePools.append(deduplicatedTracks(tracks.shuffled() + recentTracks.shuffled()))
        }

        let mixTitles = [
            "Daily Mix 1",
            "Daily Mix 2",
            "Replay Mix",
            "Discovery Mix",
            "Favorites Mix",
            "Late Night Mix"
        ]

        let mixes = Array(sourcePools.prefix(mixTitles.count).enumerated()).compactMap { index, pool -> Playlist? in
            let tracks = Array(deduplicatedTracks(pool).prefix(32))
            guard tracks.isEmpty == false else { return nil }

            let mixID = "suggested-mix-\(index + 1)"
            playlistCache[mixID] = tracks

            return Playlist(
                id: mixID,
                title: mixTitles[index],
                description: "Made for you",
                artworkURL: tracks.first?.artworkURL,
                itemCount: tracks.count,
                kind: .standard
            )
        }

        suggestedMixes = mixes
    }

    private func applyLocalLikeState(_ isLiked: Bool, for track: Track) {
        let _ = localMusicProfileStore.setLike(isLiked, for: track, profileID: currentProfileID)
        let identifier = trackIdentifier(track)
        if isLiked {
            likedTrackIDs.insert(identifier)
        } else {
            likedTrackIDs.remove(identifier)
        }
        updateLikedSongsPlaylistCache(for: track, isLiked: isLiked)
        playlists = mergedLibraryPlaylists(remotePlaylists: playlists.filter { isLocalCollectionID($0.id) == false })

        if libraryStatusMessage != nil || playlists.isEmpty {
            libraryStatusMessage = playlists.isEmpty
                ? "Tap the heart on a song to start building your Liked Songs."
                : "Using your MusicTube activity while YouTube library sync is unavailable."
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.featuredTracks.isEmpty || self.homeStatusMessage != nil || self.likedSongsPlaylist?.id == self.localLikedPlaylistID {
                if await self.buildHomeFromLoadedLibrary() {
                    self.homeStatusMessage = nil
                    AppContainer.shared.carPlayManager?.refresh(using: self)
                }
            }
        }
    }

    private func updateLikedSongsPlaylistCache(for track: Track, isLiked: Bool) {
        guard let likedPlaylist = likedSongsPlaylist else { return }

        let playlistID = likedPlaylist.id
        let identifier = trackIdentifier(track)
        let cachedTracks = playlistCache[playlistID] ?? []
        let wasPresent = cachedTracks.contains { trackIdentifier($0) == identifier }

        var updatedTracks = cachedTracks.filter { trackIdentifier($0) != identifier }
        if isLiked {
            updatedTracks.insert(track, at: 0)
        }
        updatedTracks = deduplicatedTracks(updatedTracks)

        if updatedTracks.isEmpty {
            playlistCache.removeValue(forKey: playlistID)
        } else {
            playlistCache[playlistID] = updatedTracks
        }

        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }

        let countDelta: Int
        switch (isLiked, wasPresent) {
        case (true, false):
            countDelta = 1
        case (false, true):
            countDelta = -1
        default:
            countDelta = 0
        }

        let currentPlaylist = playlists[playlistIndex]
        let updatedCount = max(currentPlaylist.itemCount + countDelta, 0)
        playlists[playlistIndex] = Playlist(
            id: currentPlaylist.id,
            title: currentPlaylist.title,
            description: currentPlaylist.description,
            artworkURL: updatedTracks.first?.artworkURL,
            itemCount: updatedTracks.isEmpty ? updatedCount : updatedTracks.count,
            kind: currentPlaylist.kind
        )
    }
}

final class AppContainer {
    static let shared = AppContainer()
    weak var appState: AppState?
    weak var carPlayManager: CarPlayManager?

    private init() {}
}

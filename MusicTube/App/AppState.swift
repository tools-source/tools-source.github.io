import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum AuthState {
        case restoring
        case guest
        case signedIn
    }

    @Published private(set) var authState: AuthState = .restoring
    @Published private(set) var user: YouTubeUser?
    @Published private(set) var featuredTracks: [Track] = []
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var suggestedMixes: [Playlist] = []
    @Published private(set) var savedCollections: [MusicCollection] = []
    @Published var searchResults: SearchResponse = .empty
    @Published var nowPlaying: Track?
    @Published var isPlaying = false
    @Published var searchQuery: String = ""
    @Published private(set) var recentSearches: [String] = []
    @Published private(set) var isSearching = false
    @Published var isLoading = false
    @Published var isLoadingPlaylists = false
    @Published var isPlayerPresented = false
    @Published var errorMessage: String?
    @Published private(set) var homeStatusMessage: String?
    @Published private(set) var libraryStatusMessage: String?
    @Published private(set) var likedTrackIDs: Set<String> = []
    @Published private(set) var savedTrackIDs: Set<String> = []
    @Published private(set) var hasLoadedHome = false
    @Published private(set) var hasLoadedLibrary = false
    @Published private(set) var sleepTimerEndDate: Date?
    @Published private(set) var isDownloadingNowPlaying = false
    @Published private(set) var isDeletingAccountData = false
    @Published private(set) var relatedTracks: [Track] = []
    @Published private(set) var isLoadingRelatedTracks = false
    @Published private(set) var isLoadingMoreRecommendations = false
    @Published private(set) var isLoadingMoreSearchResults = false
    @Published var isPlaylistPickerPresented = false
    @Published private(set) var playlistPickerTrack: Track?
    @Published private(set) var playlistPickerTargetPlaylist: Playlist?

    private var session: YouTubeSession?
    private var sleepTimerTask: Task<Void, Never>?
    private var relatedTracksTask: Task<Void, Never>?
    let downloadService = DownloadService.shared
    private let authService: AuthProviding
    private let catalogService: MusicCatalogProviding
    private let playbackService: PlaybackService
    private let localMusicProfileStore: LocalMusicProfileStore
    private var playlistCache: [String: [Track]] = [:]
    private var collectionCache: [String: [Track]] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var isRefreshingDashboard = false
    private var activeSearchRequestID: UUID?
    private var lastLikedSongsAccountSyncDate: Date?
    private let localLikedPlaylistID = "local-liked-songs"
    private let localSavedSongsPlaylistID = "local-saved-songs"
    private let localReplayMixPlaylistID = "local-replay-mix"
    private let localFavoritesMixPlaylistID = "local-favorites-mix"
    private let deviceProfileID = "device-local-profile"
    private let likedSongsAccountSyncCooldown: TimeInterval = 300

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
                self.refreshRelatedTracksTask(for: track)
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

        AppContainer.shared.appState = self

        $authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, state != .restoring else { return }
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

    var isYouTubeConnected: Bool {
        session != nil
    }

    var canLoadMoreSearchResults: Bool {
        searchResults.nextSongsContinuationToken?.isEmpty == false
    }

    var likedSongsPlaylist: Playlist? {
        playlists.first(where: { $0.kind == .likedMusic })
    }

    var savedSongsPlaylist: Playlist? {
        playlists.first(where: { $0.kind == .savedSongs })
    }

    var customPlaylists: [Playlist] {
        playlists.filter { $0.kind == .custom }
    }

    var savedPlaylistCollections: [MusicCollection] {
        savedCollections.filter { $0.kind == .playlist }
    }

    var savedAlbumCollections: [MusicCollection] {
        savedCollections.filter { $0.kind == .album }
    }

    var savedArtistCollections: [MusicCollection] {
        savedCollections.filter { $0.kind == .artist }
    }

    var libraryPlaylists: [Playlist] {
        playlists.filter { $0.kind != .likedMusic && $0.kind != .savedSongs }
    }

    var isUsingLocalLibraryFallback: Bool {
        playlists.contains(where: { isLocalCollectionID($0.id) })
    }

    func isTrackLiked(_ track: Track) -> Bool {
        likedTrackIDs.contains(trackIdentifier(track))
    }

    func isTrackSaved(_ track: Track) -> Bool {
        savedTrackIDs.contains(trackIdentifier(track))
    }

    func isCollectionSaved(_ collection: MusicCollection) -> Bool {
        savedCollections.contains(where: { $0.id == collection.id })
    }

    func signIn() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let session = try await authService.signIn()
            self.session = session
            self.user = session.user
            authState = .signedIn
            syncLocalMusicProfileState()
            await refreshDashboard()
        } catch {
            errorMessage = error.localizedDescription
            authState = .guest
        }
    }

    func signOut() async {
        await authService.signOut()
        session = nil
        user = nil
        authState = .guest
        clearRemoteState()
        syncLocalMusicProfileState()
        await refreshDashboard()
    }

    func deleteCurrentAccountData() async {
        guard isDeletingAccountData == false else { return }

        isDeletingAccountData = true
        defer { isDeletingAccountData = false }

        await authService.signOut()
        downloadService.deleteAllDownloads()
        localMusicProfileStore.clearAllData()

        session = nil
        user = nil
        authState = .guest
        resetAllLoadedState()
        syncLocalMusicProfileState()
        await refreshDashboard()
    }

    func refreshDashboard() async {
        guard isRefreshingDashboard == false else { return }

        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }

        // Load the library first so likes sync has priority and isn't competing with home hydration.
        await refreshLibrary()
        await refreshHome()
    }

    func refreshHome() async {
        guard isLoading == false else { return }

        isLoading = true
        defer {
            isLoading = false
            hasLoadedHome = true
        }

        var didFallBackFromExpiredSession = false

        if let accessToken = session?.accessToken {
            do {
                let home = try await catalogService.loadHome(accessToken: accessToken)
                let learnedTracks = await smartRecommendations(
                    limit: 24,
                    excluding: Set((home.featured + home.recent).map(trackIdentifier))
                )
                let mergedFeatured = curatedSuggestionTracks(
                    deduplicatedTracks(home.featured + learnedTracks + home.recent)
                )
                let featured = Array(mergedFeatured.prefix(60))
                let featuredIDs = Set(featured.map(trackIdentifier))
                let recent = Array(
                    curatedSuggestionTracks(
                        deduplicatedTracks(home.recent + learnedTracks.shuffled() + home.featured.shuffled())
                    )
                        .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                        .prefix(40)
                )

                featuredTracks = featured
                recentTracks = recent
                homeStatusMessage = nil

                AppContainer.shared.carPlayManager?.refresh(using: self)

                Task {
                    await rebuildSuggestedMixes()
                    AppContainer.shared.carPlayManager?.refresh(using: self)
                }

                Task {
                    self.playbackService.prefetchStreams(for: Array(featured.prefix(10)))
                }
                return
            } catch {
                if await handleAuthorizationFailureIfNeeded(for: error) {
                    didFallBackFromExpiredSession = true
                    homeStatusMessage = "Your YouTube session expired, so MusicTube is using on-device picks for now."
                }
                if await buildHomeFromLoadedLibrary() {
                    homeStatusMessage = "Using your MusicTube taste profile while YouTube recommendations reload."
                    AppContainer.shared.carPlayManager?.refresh(using: self)
                    return
                }
            }
        }

        if await buildHomeFromLoadedLibrary() {
            homeStatusMessage = hasPersonalizedRecommendationSignals()
                ? nil
                : starterRecommendationsStatusMessage(expiredSessionFallback: didFallBackFromExpiredSession)
            AppContainer.shared.carPlayManager?.refresh(using: self)
            return
        }

        if await buildStarterHome() {
            homeStatusMessage = starterRecommendationsStatusMessage(expiredSessionFallback: didFallBackFromExpiredSession)
            AppContainer.shared.carPlayManager?.refresh(using: self)
            return
        }

        featuredTracks = []
        recentTracks = []
        suggestedMixes = []
        playlistCache = playlistCache.filter { isSyntheticMixID($0.key) == false }
        homeStatusMessage = isYouTubeConnected
            ? "Reconnect YouTube or play more songs so MusicTube can rebuild your recommendations."
            : "Search and play a few songs so MusicTube can learn what you like."
    }

    func loadMoreRecommendedTracksIfNeeded() async {
        guard isLoadingMoreRecommendations == false else { return }

        isLoadingMoreRecommendations = true
        defer { isLoadingMoreRecommendations = false }

        let existingIDs = Set((featuredTracks + recentTracks).map(trackIdentifier))
        var moreTracks = await smartRecommendations(limit: 24, excluding: existingIDs)
        if moreTracks.isEmpty {
            moreTracks = await starterRecommendations(limit: 24, excluding: existingIDs)
        }
        guard moreTracks.isEmpty == false else { return }

        featuredTracks = curatedSuggestionTracks(deduplicatedTracks(featuredTracks + moreTracks))
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    func performSearch() async {
        _ = await search(query: searchQuery)
    }

    func search(query: String) async -> SearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            clearSearch()
            return .empty
        }

        let requestID = UUID()
        activeSearchRequestID = requestID
        isSearching = true
        isLoadingMoreSearchResults = false

        do {
            let results = try await catalogService.search(query: trimmed, accessToken: session?.accessToken)
            guard activeSearchRequestID == requestID else { return results }
            searchResults = results
            isSearching = false
            errorMessage = nil
            return results
        } catch {
            guard activeSearchRequestID == requestID else { return .empty }
            searchResults = .empty
            isSearching = false
            errorMessage = error.localizedDescription
            return .empty
        }
    }

    func clearSearch() {
        activeSearchRequestID = nil
        isSearching = false
        isLoadingMoreSearchResults = false
        searchResults = .empty
    }

    func loadMoreSearchResultsIfNeeded() async {
        guard isLoadingMoreSearchResults == false else { return }
        guard isSearching == false else { return }
        guard let continuation = searchResults.nextSongsContinuationToken, continuation.isEmpty == false else { return }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return }

        let requestID = activeSearchRequestID
        isLoadingMoreSearchResults = true
        defer { isLoadingMoreSearchResults = false }

        do {
            let moreResults = try await catalogService.loadMoreSearchResults(
                query: trimmedQuery,
                continuation: continuation,
                accessToken: session?.accessToken
            )
            guard activeSearchRequestID == requestID else { return }

            searchResults = SearchResponse(
                songs: deduplicatedTracks(searchResults.songs + moreResults.songs),
                playlists: searchResults.playlists,
                albums: searchResults.albums,
                artists: searchResults.artists,
                nextSongsContinuationToken: moreResults.nextSongsContinuationToken
            )
        } catch {
            guard activeSearchRequestID == requestID else { return }
            errorMessage = error.localizedDescription
        }
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
        let suggestionQueries = Array(recentSearches.prefix(6))
        guard suggestionQueries.isEmpty == false else { return [] }

        let resultBuckets = await withTaskGroup(of: [Track]?.self) { group in
            for query in suggestionQueries {
                guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { continue }

                group.addTask {
                    do {
                        let results = try await self.catalogService.search(query: query, accessToken: self.session?.accessToken)
                        let bucket = Array(results.songs.prefix(12))
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

        return curatedSuggestionTracks(suggestions)
    }

    func play(track: Track, queue: [Track]? = nil) {
        playbackService.play(track: track, queue: queue)
        AppContainer.shared.carPlayManager?.refresh(using: self)

        Task { @MainActor [weak self] in
            self?.recordLocalPlayback(for: track)
        }
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
        guard isLoadingPlaylists == false else { return }

        isLoadingPlaylists = true
        defer {
            isLoadingPlaylists = false
            hasLoadedLibrary = true
        }

        if let accessToken = session?.accessToken {
            do {
                let loadedPlaylists = try await catalogService.loadPlaylists(accessToken: accessToken)
                playlists = mergedLibraryPlaylists(remotePlaylists: loadedPlaylists)
                await hydrateLikedSongsPlaylistIfNeeded(forceRefresh: true)
                lastLikedSongsAccountSyncDate = Date()
                trimCachesToValidCollections()
                libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
                AppContainer.shared.carPlayManager?.refresh(using: self)
                return
            } catch {
                if await handleAuthorizationFailureIfNeeded(for: error) {
                    libraryStatusMessage = "Your YouTube session expired, so MusicTube is showing your on-device library."
                }
            }
        }

        let preservedLibraryStatus = libraryStatusMessage
        playlists = mergedLibraryPlaylists(remotePlaylists: [])
        trimCachesToValidCollections()
        libraryStatusMessage = preservedLibraryStatus ?? libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    func loadPlaylistItems(
        for playlist: Playlist,
        forceRefresh: Bool = false,
        surfaceErrors: Bool = true
    ) async -> [Track] {
        if isSyntheticMixID(playlist.id) || isLocalCollectionID(playlist.id) {
            if forceRefresh == false, let cached = playlistCache[playlist.id] {
                return cached
            }

            _ = mergedLibraryPlaylists(remotePlaylists: playlists.filter { isLocalCollectionID($0.id) == false })
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
            if surfaceErrors {
                errorMessage = nil
            }
            return tracks
        } catch {
            if surfaceErrors || shouldSuppressBackgroundCatalogError(error) == false {
                errorMessage = error.localizedDescription
            }
            if playlist.kind == .likedMusic, localLikedTracks.isEmpty == false {
                let fallbackTracks = deduplicatedTracks(localLikedTracks)
                playlistCache[playlist.id] = fallbackTracks
                return fallbackTracks
            }
            if let cached = playlistCache[playlist.id], cached.isEmpty == false {
                return cached
            }
            return []
        }
    }

    func loadCollectionItems(
        for collection: MusicCollection,
        forceRefresh: Bool = false,
        surfaceErrors: Bool = true
    ) async -> [Track] {
        if forceRefresh == false, let cached = collectionCache[collection.id] {
            return cached
        }

        do {
            let tracks = try await catalogService.loadCollectionItems(
                for: collection,
                accessToken: session?.accessToken
            )
            collectionCache[collection.id] = tracks
            if surfaceErrors {
                errorMessage = nil
            }
            return tracks
        } catch {
            if surfaceErrors || shouldSuppressBackgroundCatalogError(error) == false {
                errorMessage = error.localizedDescription
            }
            if let cached = collectionCache[collection.id], cached.isEmpty == false {
                return cached
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

    func toggleShuffle() {
        playbackService.toggleShuffle()
    }

    func cycleRepeatMode() {
        playbackService.cycleRepeatMode()
    }

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

    func downloadNowPlaying() {
        guard let track = nowPlaying else { return }
        downloadTrack(track)
    }

    func downloadTrack(_ track: Track, source: DownloadSource? = nil) {
        guard !downloadService.isDownloaded(track), !downloadService.isDownloading(track) else { return }

        isDownloadingNowPlaying = true
        Task {
            defer { Task { @MainActor in self.isDownloadingNowPlaying = false } }
            do {
                if let streamURL = try await playbackService.resolveStreamURL(for: track) {
                    downloadService.startDownload(track: track, streamURL: streamURL, source: source)
                }
            } catch {
                print("[AppState] Failed to resolve stream for download: \(error.localizedDescription)")
            }
        }
    }

    func downloadCollection(_ collection: MusicCollection) {
        let source = DownloadSource(id: collection.id, title: collection.title, kind: collection.kind)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let tracks = await self.loadCollectionItems(for: collection)
            guard tracks.isEmpty == false else { return }
            await self.downloadTracks(tracks, source: source)
        }
    }

    func downloadPlaylist(_ playlist: Playlist) {
        let source = DownloadSource(
            id: "playlist:\(playlist.id)",
            title: playlist.title,
            kind: .playlist
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let tracks = await self.loadPlaylistItems(for: playlist)
            guard tracks.isEmpty == false else { return }
            await self.downloadTracks(tracks, source: source)
        }
    }

    private func downloadTracks(_ tracks: [Track], source: DownloadSource?) async {
        let pendingTracks = tracks.filter {
            downloadService.isDownloaded($0) == false && downloadService.isDownloading($0) == false
        }
        guard pendingTracks.isEmpty == false else { return }

        await withTaskGroup(of: Void.self) { group in
            for track in pendingTracks {
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        if let streamURL = try await self.playbackService.resolveStreamURL(for: track) {
                            await MainActor.run {
                                self.downloadService.startDownload(track: track, streamURL: streamURL, source: source)
                            }
                        }
                    } catch {
                        print("[AppState] Failed to resolve stream for batch download: \(error.localizedDescription)")
                    }
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
            let originalLikeState = self.isTrackLiked(track)
            self.applyLocalLikeState(shouldLike, for: track)

            do {
                try await self.catalogService.setLikeStatus(for: track, isLiked: shouldLike, accessToken: accessToken)
                self.lastLikedSongsAccountSyncDate = Date()
                self.errorMessage = nil
            } catch {
                self.applyLocalLikeState(originalLikeState, for: track)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func toggleTrackSaved(_ track: Track) {
        let shouldSave = isTrackSaved(track) == false
        let _ = localMusicProfileStore.setTrackSaved(shouldSave, for: track, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()

        if featuredTracks.isEmpty || homeStatusMessage != nil {
            Task { [weak self] in
                await self?.refreshHome()
            }
        }
    }

    func toggleCollectionSaved(_ collection: MusicCollection) {
        let shouldSave = isCollectionSaved(collection) == false
        let _ = localMusicProfileStore.setCollectionSaved(shouldSave, for: collection, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
    }

    func presentPlaylistPicker(for track: Track) {
        playlistPickerTrack = track
        playlistPickerTargetPlaylist = nil
        isPlaylistPickerPresented = true
    }

    func presentPlaylistCreator() {
        playlistPickerTrack = nil
        playlistPickerTargetPlaylist = nil
        isPlaylistPickerPresented = true
    }

    func presentPlaylistSongAdder(for playlist: Playlist) {
        playlistPickerTrack = nil
        playlistPickerTargetPlaylist = playlist
        isPlaylistPickerPresented = true
    }

    func dismissPlaylistPicker() {
        isPlaylistPickerPresented = false
        playlistPickerTrack = nil
        playlistPickerTargetPlaylist = nil
        clearSearch()
        searchQuery = ""
    }

    func addPlaylistPickerTrack(to playlist: Playlist) {
        guard let track = playlistPickerTrack else { return }
        addTrack(track, to: playlist)
        dismissPlaylistPicker()
    }

    func addTrack(_ track: Track, to playlist: Playlist) {
        let _ = localMusicProfileStore.addTrack(track, toCustomPlaylist: playlist.id, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        playlistCache[playlist.id] = deduplicatedTracks([track] + (playlistCache[playlist.id] ?? []))
    }

    @discardableResult
    func createCustomPlaylist(named name: String) -> Bool {
        guard let playlist = localMusicProfileStore.createCustomPlaylist(
            named: name,
            seedTrack: playlistPickerTrack,
            profileID: currentProfileID
        ) else {
            return false
        }

        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        playlistCache[playlist.id] = playlist.tracks
        dismissPlaylistPicker()
        return true
    }

    func renameCustomPlaylist(_ playlist: Playlist, to name: String) -> Bool {
        guard playlist.kind == .custom else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return false }

        let _ = localMusicProfileStore.renameCustomPlaylist(
            playlistID: playlist.id,
            to: trimmedName,
            description: playlist.description,
            profileID: currentProfileID
        )
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        return true
    }

    func deleteCustomPlaylist(_ playlist: Playlist) {
        guard playlist.kind == .custom else { return }
        let _ = localMusicProfileStore.deleteCustomPlaylist(playlist.id, profileID: currentProfileID)
        playlistCache.removeValue(forKey: playlist.id)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
    }

    func removeTrack(_ track: Track, from playlist: Playlist) {
        guard playlist.kind == .custom else { return }
        let _ = localMusicProfileStore.removeTrack(track, fromCustomPlaylist: playlist.id, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        playlistCache[playlist.id]?.removeAll { $0.playbackKey == track.playbackKey }
    }

    func isTrack(_ track: Track, in playlist: Playlist) -> Bool {
        let cachedTracks = playlistCache[playlist.id] ?? []
        return cachedTracks.contains { $0.playbackKey == track.playbackKey }
    }

    func searchTracksForPlaylist(_ query: String) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        do {
            let results = try await catalogService.search(query: trimmed, accessToken: session?.accessToken)
            return results.songs
        } catch {
            errorMessage = error.localizedDescription
            return []
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

        if let lastLikedSongsAccountSyncDate,
           Date().timeIntervalSince(lastLikedSongsAccountSyncDate) < likedSongsAccountSyncCooldown {
            return
        }

        lastLikedSongsAccountSyncDate = Date()
        await hydrateLikedSongsPlaylistIfNeeded(forceRefresh: true)
    }

    private func restoreSession() async {
        if let restored = await authService.restoreSession() {
            session = restored
            user = restored.user
            authState = .signedIn
        } else {
            authState = .guest
        }

        syncLocalMusicProfileState()
        await refreshDashboard()
    }

    private func refreshRelatedTracksTask(for track: Track?) {
        relatedTracksTask?.cancel()
        relatedTracksTask = nil

        guard let track else {
            relatedTracks = []
            isLoadingRelatedTracks = false
            return
        }

        isLoadingRelatedTracks = true
        relatedTracksTask = Task { [weak self] in
            guard let self else { return }
            let tracks = await self.smartRecommendations(
                limit: 18,
                excluding: Set([self.trackIdentifier(track)]),
                focusedTrack: track
            )
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                self.relatedTracks = tracks
                self.isLoadingRelatedTracks = false
            }
        }
    }

    private func resetAllLoadedState() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        relatedTracksTask?.cancel()
        relatedTracksTask = nil
        playbackService.stop()
        featuredTracks = []
        recentTracks = []
        playlists = []
        suggestedMixes = []
        searchResults = .empty
        nowPlaying = nil
        isPlaying = false
        searchQuery = ""
        isPlayerPresented = false
        isSearching = false
        isDownloadingNowPlaying = false
        playlistCache = [:]
        collectionCache = [:]
        activeSearchRequestID = nil
        errorMessage = nil
        homeStatusMessage = nil
        libraryStatusMessage = nil
        likedTrackIDs = []
        savedTrackIDs = []
        savedCollections = []
        recentSearches = []
        relatedTracks = []
        hasLoadedHome = false
        hasLoadedLibrary = false
        isRefreshingDashboard = false
        sleepTimerEndDate = nil
        playlistPickerTrack = nil
        isPlaylistPickerPresented = false
        lastLikedSongsAccountSyncDate = nil
    }

    private func clearRemoteState() {
        featuredTracks = []
        recentTracks = []
        playlists = []
        suggestedMixes = []
        playlistCache = playlistCache.filter { isLocalCollectionID($0.key) }
        collectionCache.removeAll()
        hasLoadedHome = false
        hasLoadedLibrary = false
        lastLikedSongsAccountSyncDate = nil
    }

    private func buildHomeFromLoadedLibrary() async -> Bool {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let candidateMixes = selectSuggestedMixSourcePlaylists(from: playlists)
        let likedPlaylist = likedSongsPlaylist
        let savedSongsPlaylist = savedSongsPlaylist

        async let likedTracksFetch: [Track] = {
            if let likedPlaylist {
                return await self.loadPlaylistItems(for: likedPlaylist, surfaceErrors: false)
            }
            return []
        }()
        async let savedTracksFetch: [Track] = {
            if let savedSongsPlaylist {
                return await self.loadPlaylistItems(for: savedSongsPlaylist)
            }
            return snapshot.savedTracks
        }()

        let mixTracks = await withTaskGroup(of: [Track].self) { group in
            for playlist in candidateMixes.prefix(6) {
                group.addTask { await self.loadPlaylistItems(for: playlist, surfaceErrors: false) }
            }

            var tracks: [Track] = []
            for await batch in group {
                tracks.append(contentsOf: self.randomizedTracks(from: batch, limit: 14))
            }
            return tracks
        }

        let likedTracks = curatedSuggestionTracks(await likedTracksFetch)
        let savedTracks = curatedSuggestionTracks(await savedTracksFetch)
        let topTracks = curatedSuggestionTracks(snapshot.topTracks)
        let recentProfileTracks = curatedSuggestionTracks(snapshot.recentTracks)
        let curatedMixTracks = curatedSuggestionTracks(mixTracks)
        let learnedTracks = await smartRecommendations(
            limit: 30,
            excluding: Set((likedTracks + savedTracks + curatedMixTracks).map(trackIdentifier))
        )

        let featuredPool = curatedSuggestionTracks(
            deduplicatedTracks(
            learnedTracks +
            savedTracks.shuffled() +
            likedTracks.shuffled() +
            topTracks.shuffled() +
            curatedMixTracks.shuffled() +
            recentProfileTracks.shuffled()
            )
        )

        guard featuredPool.isEmpty == false else { return false }

        let featured = Array(featuredPool.prefix(50))
        let featuredIDs = Set(featured.map(trackIdentifier))
        let recent = Array(
            curatedSuggestionTracks(
                deduplicatedTracks(recentProfileTracks + curatedMixTracks.shuffled() + learnedTracks.shuffled())
            )
                .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                .prefix(30)
        )

        featuredTracks = featured
        recentTracks = recent
        await rebuildSuggestedMixes()
        return true
    }

    private func buildStarterHome() async -> Bool {
        let starterTracks = await starterRecommendations(limit: 40, excluding: [])
        guard starterTracks.isEmpty == false else { return false }

        let curatedTracks = curatedSuggestionTracks(starterTracks)
        featuredTracks = Array(curatedTracks.prefix(40))
        recentTracks = Array(curatedTracks.dropFirst(16).prefix(24))
        suggestedMixes = []
        playlistCache = playlistCache.filter { isSyntheticMixID($0.key) == false }
        return true
    }

    private func starterRecommendations(
        limit: Int,
        excluding excludedIdentifiers: Set<String>
    ) async -> [Track] {
        let starterQueries = [
            "top songs official audio",
            "new music official audio",
            "arabic songs official audio",
            "worship songs official audio",
            "afrobeats official audio",
            "acoustic songs official audio",
            "indie pop official audio",
            "chill music official audio"
        ]

        let resultBuckets = await withTaskGroup(of: [Track]?.self) { group in
            for query in starterQueries {
                group.addTask {
                    do {
                        let results = try await self.catalogService.search(query: query, accessToken: self.session?.accessToken)
                        let bucket = Array(results.songs.prefix(16))
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

        var collected: [Track] = []
        var seen = excludedIdentifiers
        var offsets = Array(repeating: 0, count: resultBuckets.count)

        while collected.count < limit {
            var appendedTrackThisRound = false

            for bucketIndex in resultBuckets.indices {
                while offsets[bucketIndex] < resultBuckets[bucketIndex].count {
                    let track = resultBuckets[bucketIndex][offsets[bucketIndex]]
                    offsets[bucketIndex] += 1

                    let identifier = trackIdentifier(track)
                    guard seen.insert(identifier).inserted else { continue }

                    collected.append(track)
                    appendedTrackThisRound = true
                    break
                }

                if collected.count >= limit {
                    break
                }
            }

            if appendedTrackThisRound == false {
                break
            }
        }

        return curatedSuggestionTracks(collected)
    }

    private func smartRecommendations(
        limit: Int,
        excluding excludedIdentifiers: Set<String>,
        focusedTrack: Track? = nil
    ) async -> [Track] {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let savedSeedTracks = curatedSuggestionTracks(snapshot.savedTracks)
        let likedSeedTracks = curatedSuggestionTracks(snapshot.likedTracks)
        let topArtists = orderedUniqueQueries(
            snapshot.topArtists +
            savedSeedTracks.map(\.artist) +
            likedSeedTracks.map(\.artist) +
            savedArtistCollections.map(\.title)
        )
        var queries: [String] = []

        if let focusedTrack, focusedTrack.isEligibleForMusicSuggestions {
            queries.append("\(focusedTrack.artist) \(focusedTrack.title)")
            queries.append("\(focusedTrack.artist) official audio")
            queries.append("\(focusedTrack.artist) songs")
            queries.append("\(focusedTrack.title) official audio")
        }

        queries.append(contentsOf: topArtists.prefix(4).map { "\($0) official audio" })
        queries.append(contentsOf: recentSearches.prefix(3))
        queries.append(contentsOf: savedSeedTracks.prefix(3).map { "\($0.artist) \($0.title)" })
        queries.append(contentsOf: likedSeedTracks.prefix(3).map { "\($0.artist) songs" })
        queries.append(contentsOf: savedArtistCollections.prefix(3).map { "\($0.title) songs" })

        let normalizedQueries = orderedUniqueQueries(queries)
        guard normalizedQueries.isEmpty == false else {
            return []
        }

        let preferredArtists = Set(
            topArtists
            .prefix(8)
            .map(normalizedRecommendationText)
        )

        let resultBuckets = await withTaskGroup(of: [Track].self) { group in
            for query in normalizedQueries.prefix(focusedTrack == nil ? 6 : 4) {
                group.addTask {
                    let response = try? await self.catalogService.search(query: query, accessToken: self.session?.accessToken)
                    return Array((response?.songs ?? []).prefix(focusedTrack == nil ? 10 : 14))
                }
            }

            var buckets: [[Track]] = []
            for await bucket in group {
                if bucket.isEmpty == false {
                    buckets.append(bucket)
                }
            }
            return buckets
        }

        let rankedTracks = curatedSuggestionTracks(deduplicatedTracks(resultBuckets.flatMap { $0 })).sorted {
            recommendationScore(for: $0, focusedTrack: focusedTrack, preferredArtists: preferredArtists) >
            recommendationScore(for: $1, focusedTrack: focusedTrack, preferredArtists: preferredArtists)
        }

        var collected: [Track] = []
        var seen = excludedIdentifiers

        for track in rankedTracks {
            let identifier = trackIdentifier(track)
            guard seen.insert(identifier).inserted else { continue }
            let score = recommendationScore(for: track, focusedTrack: focusedTrack, preferredArtists: preferredArtists)
            guard score > 0 || focusedTrack == nil else { continue }
            collected.append(track)
            if collected.count >= limit {
                return collected
            }
        }

        return collected
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenTrackIDs: Set<String> = []
        return tracks.filter { track in
            let identifier = trackIdentifier(track)
            return seenTrackIDs.insert(identifier).inserted
        }
    }

    private func curatedSuggestionTracks(_ tracks: [Track]) -> [Track] {
        let withoutShorts = tracks.filter { $0.isLikelyShortFormVideo == false }
        let curated = withoutShorts.filter(\.isEligibleForMusicSuggestions)
        if curated.isEmpty == false {
            return curated
        }
        return withoutShorts
    }

    private func isQuotaOrTransientCatalogError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("quota")
            || message.contains("daily limit")
            || message.contains("rate limit")
            || message.contains("temporarily unavailable")
            || message.contains("backend error")
            || message.contains("timed out")
            || message.contains("network connection was lost")
            || message.contains("offline")
            || message.contains("returned status 429")
            || message.contains("returned status 500")
            || message.contains("returned status 502")
            || message.contains("returned status 503")
    }

    private func shouldSuppressBackgroundCatalogError(_ error: Error) -> Bool {
        isAuthorizationError(error) || isQuotaOrTransientCatalogError(error)
    }

    private func prioritizeLibraryPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let likedPlaylists = playlists.filter { $0.kind == .likedMusic }
        let savedSongs = playlists.filter { $0.kind == .savedSongs }
        let remainingPlaylists = playlists.filter { $0.kind != .likedMusic && $0.kind != .savedSongs }
        return likedPlaylists + savedSongs + remainingPlaylists
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

    private func recommendationScore(
        for track: Track,
        focusedTrack: Track?,
        preferredArtists: Set<String>
    ) -> Int {
        let normalizedArtist = normalizedRecommendationText(track.artist)
        let normalizedTitle = normalizedRecommendationText(track.title)
        var score = 0

        if preferredArtists.contains(normalizedArtist) {
            score += 5
        }

        if let focusedTrack {
            let focusedArtist = normalizedRecommendationText(focusedTrack.artist)
            let focusedTitleTokens = Set(normalizedRecommendationText(focusedTrack.title).split(separator: " ").map(String.init))
            let candidateTitleTokens = Set(normalizedTitle.split(separator: " ").map(String.init))
            let overlap = focusedTitleTokens.intersection(candidateTitleTokens).count

            if normalizedArtist == focusedArtist {
                score += 12
            }
            score += min(overlap * 3, 9)
        }

        return score
    }

    private func normalizedRecommendationText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s\\p{Arabic}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasPersonalizedRecommendationSignals() -> Bool {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let hasPlaylistSignals = playlists.contains {
            ($0.kind == .standard || $0.kind == .custom || $0.kind == .uploads) && $0.itemCount > 0
        }

        return snapshot.topArtists.isEmpty == false
            || snapshot.savedTracks.isEmpty == false
            || snapshot.likedTracks.isEmpty == false
            || snapshot.topTracks.isEmpty == false
            || snapshot.recentTracks.isEmpty == false
            || snapshot.recentSearches.isEmpty == false
            || savedArtistCollections.isEmpty == false
            || hasPlaylistSignals
    }

    private func starterRecommendationsStatusMessage(expiredSessionFallback: Bool) -> String {
        if expiredSessionFallback {
            return "Your YouTube session expired, so MusicTube is using starter picks for now."
        }

        return isYouTubeConnected
            ? "Starter picks while MusicTube rebuilds your recommendations."
            : "Starter picks while MusicTube learns what you like."
    }

    private func trackIdentifier(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private var currentProfileID: String {
        deviceProfileID
    }

    private func isSyntheticMixID(_ playlistID: String) -> Bool {
        playlistID.hasPrefix("suggested-mix-")
    }

    private func isLocalCollectionID(_ playlistID: String) -> Bool {
        playlistID.hasPrefix("local-")
    }

    private func isAuthorizationError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("invalid authentication credentials")
            || message.contains("oauth 2")
            || message.contains("login cookie")
            || message.contains("status 401")
            || message.contains("status 403")
    }

    private func handleAuthorizationFailureIfNeeded(for error: Error) async -> Bool {
        guard isAuthorizationError(error) else { return false }

        await authService.signOut()
        session = nil
        user = nil
        authState = .guest
        clearRemoteState()
        syncLocalMusicProfileState()
        errorMessage = nil
        return true
    }

    private func syncLocalMusicProfileState() {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        likedTrackIDs = Set(snapshot.likedTracks.map(trackIdentifier))
        savedTrackIDs = Set(snapshot.savedTracks.map(trackIdentifier))
        savedCollections = snapshot.savedCollections
        recentSearches = snapshot.recentSearches
    }

    private func refreshLocalLibraryOverlay() {
        playlists = mergedLibraryPlaylists(remotePlaylists: playlists.filter { isLocalCollectionID($0.id) == false })
        trimCachesToValidCollections()
        libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    private func trimCachesToValidCollections() {
        let validPlaylistIDs = Set(playlists.map(\.id) + suggestedMixes.map(\.id))
        playlistCache = playlistCache.filter { validPlaylistIDs.contains($0.key) || isSyntheticMixID($0.key) }
        let validCollectionIDs = Set(savedCollections.map(\.id))
        collectionCache = collectionCache.filter { validCollectionIDs.contains($0.key) }
    }

    private func recordLocalPlayback(for track: Track) {
        _ = localMusicProfileStore.recordPlayback(of: track, for: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Avoid rebuilding Home on every play; that causes visible list "reload" jitter.
            // Rehydrate only when recommendations are genuinely empty.
            if self.featuredTracks.isEmpty {
                _ = await self.buildHomeFromLoadedLibrary()
                AppContainer.shared.carPlayManager?.refresh(using: self)
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
                    description: "Songs you liked in MusicTube",
                    artworkURL: likedTracks.first?.artworkURL,
                    itemCount: likedTracks.count,
                    kind: .likedMusic
                )
            )
        } else {
            playlistCache.removeValue(forKey: localLikedPlaylistID)
        }

        if snapshot.savedTracks.isEmpty == false {
            let savedTracks = Array(snapshot.savedTracks.prefix(200))
            playlistCache[localSavedSongsPlaylistID] = savedTracks
            collections.append(
                Playlist(
                    id: localSavedSongsPlaylistID,
                    title: "Saved Songs",
                    description: "Songs you saved to your library",
                    artworkURL: savedTracks.first?.artworkURL,
                    itemCount: savedTracks.count,
                    kind: .savedSongs
                )
            )
        } else {
            playlistCache.removeValue(forKey: localSavedSongsPlaylistID)
        }

        for customPlaylist in snapshot.customPlaylists {
            playlistCache[customPlaylist.id] = customPlaylist.tracks
            collections.append(
                Playlist(
                    id: customPlaylist.id,
                    title: customPlaylist.title,
                    description: customPlaylist.description,
                    artworkURL: customPlaylist.tracks.first?.artworkURL,
                    itemCount: customPlaylist.tracks.count,
                    kind: .custom
                )
            )
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

        let favoriteTracks = Array(deduplicatedTracks(snapshot.savedTracks + snapshot.likedTracks + snapshot.topTracks).prefix(60))
        if favoriteTracks.isEmpty == false {
            playlistCache[localFavoritesMixPlaylistID] = favoriteTracks
            collections.append(
                Playlist(
                    id: localFavoritesMixPlaylistID,
                    title: "Favorites Mix",
                    description: "Made from the songs you come back to most",
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

    private func libraryStatusMessageText(for playlists: [Playlist], savedCollections: [MusicCollection]) -> String? {
        if playlists.isEmpty && savedCollections.isEmpty {
            return "Save songs, playlists, albums, and artists to start building your library."
        }

        if isYouTubeConnected == false {
            return "Guest mode keeps your MusicTube library and playlists on this device."
        }

        return nil
    }

    private func hydrateLikedSongsPlaylistIfNeeded(forceRefresh: Bool) async {
        guard let likedPlaylist = likedSongsPlaylist else {
            syncLocalMusicProfileState()
            return
        }

        let tracks = await loadPlaylistItems(
            for: likedPlaylist,
            forceRefresh: forceRefresh,
            surfaceErrors: false
        )
        var resolvedTracks = tracks

        if isLocalCollectionID(likedPlaylist.id) == false {
            let mergedSnapshot = localMusicProfileStore.mergeLikedTracks(tracks, profileID: currentProfileID)
            resolvedTracks = mergedSnapshot.likedTracks
            if resolvedTracks.isEmpty {
                playlistCache.removeValue(forKey: likedPlaylist.id)
            } else {
                playlistCache[likedPlaylist.id] = resolvedTracks
            }
        }

        likedTrackIDs = Set(resolvedTracks.map(trackIdentifier))

        if let playlistIndex = playlists.firstIndex(where: { $0.id == likedPlaylist.id }) {
            playlists[playlistIndex] = Playlist(
                id: likedPlaylist.id,
                title: likedPlaylist.title,
                description: likedPlaylist.description,
                artworkURL: resolvedTracks.first?.artworkURL ?? likedPlaylist.artworkURL,
                itemCount: resolvedTracks.count,
                kind: likedPlaylist.kind
            )
        }
    }

    private func rebuildSuggestedMixes() async {
        let sourcePlaylists = selectSuggestedMixSourcePlaylists(from: playlists, limit: 6)

        let likedPlaylistSnapshot = likedSongsPlaylist
        async let likedFetch: [Track] = {
            if let playlist = likedPlaylistSnapshot {
                return await self.loadPlaylistItems(for: playlist, surfaceErrors: false)
            }
            return []
        }()

        let playlistFetches: [[Track]] = await withTaskGroup(of: [Track].self) { group in
            for playlist in sourcePlaylists {
                group.addTask { await self.loadPlaylistItems(for: playlist, surfaceErrors: false) }
            }

            var results: [[Track]] = []
            for await tracks in group {
                results.append(tracks)
            }
            return results
        }

        let likedTracks = curatedSuggestionTracks(await likedFetch)

        var sourcePools: [[Track]] = []
        if featuredTracks.isEmpty == false || recentTracks.isEmpty == false {
            sourcePools.append(curatedSuggestionTracks(deduplicatedTracks(featuredTracks.shuffled() + recentTracks.shuffled())))
        }
        if likedTracks.isEmpty == false {
            sourcePools.append(curatedSuggestionTracks(deduplicatedTracks(likedTracks.shuffled() + featuredTracks.shuffled())))
        }

        for tracks in playlistFetches where tracks.isEmpty == false {
            sourcePools.append(curatedSuggestionTracks(deduplicatedTracks(tracks.shuffled() + recentTracks.shuffled())))
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
            let tracks = Array(curatedSuggestionTracks(deduplicatedTracks(pool)).prefix(32))
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
        _ = localMusicProfileStore.setLike(isLiked, for: track, profileID: currentProfileID)
        syncLocalMusicProfileState()
        updateLikedSongsPlaylistCache(for: track, isLiked: isLiked)
        refreshLocalLibraryOverlay()
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
        playlists[playlistIndex] = Playlist(
            id: currentPlaylist.id,
            title: currentPlaylist.title,
            description: currentPlaylist.description,
            artworkURL: updatedTracks.first?.artworkURL ?? currentPlaylist.artworkURL,
            itemCount: max(currentPlaylist.itemCount + countDelta, updatedTracks.count),
            kind: currentPlaylist.kind
        )
    }

    private func orderedUniqueQueries(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

final class AppContainer {
    static let shared = AppContainer()
    weak var appState: AppState?
    weak var carPlayManager: CarPlayManager?

    private init() {}
}

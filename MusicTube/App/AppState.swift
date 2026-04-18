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
    @Published var isPlaylistPickerPresented = false
    @Published private(set) var playlistPickerTrack: Track?

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
    private let localLikedPlaylistID = "local-liked-songs"
    private let localSavedSongsPlaylistID = "local-saved-songs"
    private let localReplayMixPlaylistID = "local-replay-mix"
    private let localFavoritesMixPlaylistID = "local-favorites-mix"
    private let deviceProfileID = "device-local-profile"

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

        async let libraryFetch: Void = refreshLibrary()
        async let homeFetch: Void = refreshHome()
        _ = await (libraryFetch, homeFetch)
    }

    func refreshHome() async {
        guard isLoading == false else { return }

        isLoading = true
        defer {
            isLoading = false
            hasLoadedHome = true
        }

        if let accessToken = session?.accessToken {
            do {
                let home = try await catalogService.loadHome(accessToken: accessToken)
                let learnedTracks = await smartRecommendations(
                    limit: 24,
                    excluding: Set((home.featured + home.recent).map(trackIdentifier))
                )
                let mergedFeatured = deduplicatedTracks(
                    home.featured + learnedTracks + home.recent
                )
                let featured = Array(mergedFeatured.prefix(60))
                let featuredIDs = Set(featured.map(trackIdentifier))
                let recent = Array(
                    deduplicatedTracks(home.recent + learnedTracks.shuffled() + home.featured.shuffled())
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
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self.playbackService.prefetchStreams(for: Array(featured.prefix(6)))
                }
                return
            } catch {
                if await buildHomeFromLoadedLibrary() {
                    homeStatusMessage = "Using your MusicTube taste profile while YouTube recommendations reload."
                    AppContainer.shared.carPlayManager?.refresh(using: self)
                    return
                }
            }
        }

        if await buildHomeFromLoadedLibrary() {
            homeStatusMessage = nil
            AppContainer.shared.carPlayManager?.refresh(using: self)
            return
        }

        let discoveryTracks = await smartRecommendations(limit: 40, excluding: Set<String>())
        if discoveryTracks.isEmpty == false {
            featuredTracks = Array(discoveryTracks.prefix(40))
            recentTracks = Array(discoveryTracks.dropFirst(20).prefix(20))
            homeStatusMessage = isYouTubeConnected
                ? "Building more recommendations from your MusicTube listening."
                : nil
            await rebuildSuggestedMixes()
            AppContainer.shared.carPlayManager?.refresh(using: self)
            return
        }

        featuredTracks = []
        recentTracks = []
        suggestedMixes = []
        playlistCache = playlistCache.filter { isSyntheticMixID($0.key) == false }
        homeStatusMessage = "Search and play a few songs so MusicTube can learn what you like."
    }

    func loadMoreRecommendedTracksIfNeeded() async {
        guard isLoadingMoreRecommendations == false else { return }

        isLoadingMoreRecommendations = true
        defer { isLoadingMoreRecommendations = false }

        let existingIDs = Set((featuredTracks + recentTracks).map(trackIdentifier))
        let moreTracks = await smartRecommendations(limit: 24, excluding: existingIDs)
        guard moreTracks.isEmpty == false else { return }

        featuredTracks = deduplicatedTracks(featuredTracks + moreTracks)
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
        searchResults = .empty
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
                trimCachesToValidCollections()
                libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
                AppContainer.shared.carPlayManager?.refresh(using: self)
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        playlists = mergedLibraryPlaylists(remotePlaylists: [])
        trimCachesToValidCollections()
        libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    func loadPlaylistItems(for playlist: Playlist, forceRefresh: Bool = false) async -> [Track] {
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

    func loadCollectionItems(for collection: MusicCollection, forceRefresh: Bool = false) async -> [Track] {
        if forceRefresh == false, let cached = collectionCache[collection.id] {
            return cached
        }

        do {
            let tracks = try await catalogService.loadCollectionItems(
                for: collection,
                accessToken: session?.accessToken
            )
            collectionCache[collection.id] = tracks
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
        isPlaylistPickerPresented = true
    }

    func presentPlaylistCreator() {
        playlistPickerTrack = nil
        isPlaylistPickerPresented = true
    }

    func dismissPlaylistPicker() {
        isPlaylistPickerPresented = false
        playlistPickerTrack = nil
    }

    func addPlaylistPickerTrack(to playlist: Playlist) {
        guard let track = playlistPickerTrack else { return }
        let _ = localMusicProfileStore.addTrack(track, toCustomPlaylist: playlist.id, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        dismissPlaylistPicker()
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
    }

    private func buildHomeFromLoadedLibrary() async -> Bool {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let candidateMixes = selectSuggestedMixSourcePlaylists(from: playlists)
        let likedPlaylist = likedSongsPlaylist
        let savedSongsPlaylist = savedSongsPlaylist

        async let likedTracksFetch: [Track] = {
            if let likedPlaylist {
                return await self.loadPlaylistItems(for: likedPlaylist)
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
                group.addTask { await self.loadPlaylistItems(for: playlist) }
            }

            var tracks: [Track] = []
            for await batch in group {
                tracks.append(contentsOf: self.randomizedTracks(from: batch, limit: 14))
            }
            return tracks
        }

        let likedTracks = await likedTracksFetch
        let savedTracks = await savedTracksFetch
        let learnedTracks = await smartRecommendations(
            limit: 30,
            excluding: Set((likedTracks + savedTracks + mixTracks).map(trackIdentifier))
        )

        let featuredPool = deduplicatedTracks(
            learnedTracks +
            savedTracks.shuffled() +
            likedTracks.shuffled() +
            snapshot.topTracks.shuffled() +
            mixTracks.shuffled() +
            snapshot.recentTracks.shuffled()
        )

        guard featuredPool.isEmpty == false else { return false }

        let featured = Array(featuredPool.prefix(50))
        let featuredIDs = Set(featured.map(trackIdentifier))
        let recent = Array(
            deduplicatedTracks(snapshot.recentTracks + mixTracks.shuffled() + learnedTracks.shuffled())
                .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                .prefix(30)
        )

        featuredTracks = featured
        recentTracks = recent
        await rebuildSuggestedMixes()
        return true
    }

    private func smartRecommendations(
        limit: Int,
        excluding excludedIdentifiers: Set<String>,
        focusedTrack: Track? = nil
    ) async -> [Track] {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        var queries: [String] = []

        if let focusedTrack {
            queries.append("\(focusedTrack.artist) official audio")
            queries.append("\(focusedTrack.artist) top songs")
            queries.append("\(focusedTrack.artist) \(focusedTrack.title)")
        }

        queries.append(contentsOf: snapshot.topArtists.prefix(4).map { "\($0) official audio" })
        queries.append(contentsOf: recentSearches.prefix(3))
        queries.append(contentsOf: snapshot.savedTracks.prefix(3).map { "\($0.artist) \($0.title)" })
        queries.append(contentsOf: snapshot.likedTracks.prefix(3).map { "\($0.artist) songs" })
        queries.append(contentsOf: savedArtistCollections.prefix(3).map { "\($0.title) songs" })

        let normalizedQueries = orderedUniqueQueries(queries)
        let effectiveQueries = normalizedQueries.isEmpty
            ? ["new music official audio", "top songs playlist", "viral songs 2026"]
            : normalizedQueries

        let resultBuckets = await withTaskGroup(of: [Track].self) { group in
            for query in effectiveQueries.prefix(8) {
                group.addTask {
                    let response = try? await self.catalogService.search(query: query, accessToken: self.session?.accessToken)
                    return Array((response?.songs ?? []).prefix(12))
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

        var collected: [Track] = []
        var seen = excludedIdentifiers

        for bucket in resultBuckets {
            for track in bucket {
                let identifier = trackIdentifier(track)
                guard seen.insert(identifier).inserted else { continue }
                collected.append(track)
                if collected.count >= limit {
                    return collected
                }
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
            if self.homeStatusMessage != nil || self.featuredTracks.isEmpty {
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

        let tracks = await loadPlaylistItems(for: likedPlaylist, forceRefresh: forceRefresh)
        likedTrackIDs = Set(tracks.map(trackIdentifier))

        if let playlistIndex = playlists.firstIndex(where: { $0.id == likedPlaylist.id }) {
            playlists[playlistIndex] = Playlist(
                id: likedPlaylist.id,
                title: likedPlaylist.title,
                description: likedPlaylist.description,
                artworkURL: tracks.first?.artworkURL ?? likedPlaylist.artworkURL,
                itemCount: tracks.count,
                kind: likedPlaylist.kind
            )
        }
    }

    private func rebuildSuggestedMixes() async {
        let sourcePlaylists = selectSuggestedMixSourcePlaylists(from: playlists, limit: 6)

        let likedPlaylistSnapshot = likedSongsPlaylist
        async let likedFetch: [Track] = {
            if let playlist = likedPlaylistSnapshot {
                return await self.loadPlaylistItems(for: playlist)
            }
            return []
        }()

        let playlistFetches: [[Track]] = await withTaskGroup(of: [Track].self) { group in
            for playlist in sourcePlaylists {
                group.addTask { await self.loadPlaylistItems(for: playlist) }
            }

            var results: [[Track]] = []
            for await tracks in group {
                results.append(tracks)
            }
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

        for tracks in playlistFetches where tracks.isEmpty == false {
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

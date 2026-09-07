import Combine
import Foundation
import UIKit
import UserNotifications

extension Publisher where Failure == Never {
    /// Delivers on the next main-queue turn, once the emitting assignment has
    /// committed.
    ///
    /// `@Published` emits from `willSet`, so a subscriber that reads the source
    /// object back inside its `sink` sees the *pre-change* value. Every snapshot view
    /// model does exactly that — it rebuilds by re-reading `AppState` /
    /// `PlaybackService` — so without this hop each snapshot lags one event behind:
    /// a tapped row highlights the previously playing track, or reads "Paused" while
    /// audio is playing. Use this on any subscription whose sink re-reads state.
    func receiveAfterStateCommit() -> AnyPublisher<Output, Never> {
        receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
}

@MainActor
final class AppState: ObservableObject {
    enum AuthState {
        case restoring
        case guest
        case signedIn
    }

    /// Tabs in `MainTabView`, in display order. Raw values are the `TabView` tags.
    enum MainTab: Int {
        case home
        case search
        case downloads
        case library
    }

    struct HomeContent: Equatable {
        var featuredTracks: [Track] = []
        var recentTracks: [Track] = []
        var suggestedMixes: [Playlist] = []
        var statusMessage: String?
        var recommendationGenerationID = UUID()
        var recommendationGeneratedAt = Date.distantPast
    }

    struct TrackCacheEntry {
        let tracks: [Track]
        let expiresAt: Date
    }

    struct ActiveListeningSession {
        let track: Track
        let startingOffset: TimeInterval
        var didLogThirtySecondPlay = false
    }

    struct RecommendationSessionOutcome {
        let track: Track
        let skipped: Bool
        let recordedAt: Date
    }

    struct RecommendationBucket: Sendable {
        let seed: RecommendationSeedQuery
        let ordinal: Int
        let tracks: [Track]
    }

    struct RecommendationScoreComponents {
        let collaborative: Double
        let contentSimilarity: Double
        let behavior: Double

        var total: Double {
            // Personalized "Recommended For You" leans on what the user actually
            // likes rather than raw cross-search popularity. Spotify/YT Music both
            // weight engagement signals (completion rate, repeat listens, saves/likes)
            // far above generic stream volume, so behavior carries more weight here
            // than a popularity-only ranking would give it.
            (0.38 * collaborative) + (0.30 * contentSimilarity) + (0.32 * behavior)
        }
    }

    struct RecommendationSeedContext {
        let queries: [String]
        let seedQueries: [RecommendationSeedQuery]
        let preferredArtists: Set<String>
        let focusedArtist: String?
        let focusedTitleTokens: Set<String>
        let keywordTokens: Set<String>
        let behaviorInsightsByTrackKey: [String: TrackBehaviorInsight]
        let behaviorInsightsByArtist: [String: [TrackBehaviorInsight]]
        let likedTrackKeys: Set<String>
        let savedTrackKeys: Set<String>
        let downloadedTrackKeys: Set<String>
        let collaborativeSeedTrackKeys: Set<String>
        let strongPositiveArtists: Set<String>
        let skippedArtists: Set<String>
        let suppressedTrackKeys: Set<String>
        let sessionArtistAdjustments: [String: Double]
        let preferenceKeywords: Set<String>
        let preferenceContentContexts: Set<ListeningContentContext>
        let activeContentContext: ListeningContentContext?
        let activeQuranDomain: Bool?
    }

    enum PlaylistPickerState: Equatable {
        case hidden
        case create(seedTrack: Track?)
        case add(to: Playlist)
    }

    enum PlaylistPickerHost: Equatable {
        case main
        case player
    }

    enum ResolvedSearchInput {
        case text(String)
        case playlist(Playlist)
        case video(String)
    }

    @Published var authState: AuthState = .restoring
    @Published var user: YouTubeUser?
    @Published private(set) var homeContent = HomeContent()
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var savedCollections: [MusicCollection] = []
    @Published var searchResults: SearchResponse = .empty
    private(set) var playbackState: PlaybackState = .idle
    @Published private(set) var nowPlayingTrack: Track?
    @Published var searchQuery: String = ""
    @Published private(set) var recentSearches: [String] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isRecognizingMusic = false
    @Published var isLoading = false
    @Published var isLoadingPlaylists = false
    @Published var isPlayerPresented = false
    @Published var errorMessage: String?
    @Published private(set) var libraryStatusMessage: String?
    @Published private(set) var likedTrackIDs: Set<String> = []
    @Published private(set) var savedTrackIDs: Set<String> = []
    @Published private(set) var substantiallyListenedTrackIDs: Set<String> = []
    @Published private(set) var userPreferenceProfile: UserPreferenceProfile = .empty
    @Published var isPreferenceOnboardingPresented = false
    @Published private(set) var historyTracks: [Track] = []
    @Published private(set) var librarySectionOrder: [AppLibrarySection] = AppLibrarySection.defaultOrder
    @Published private(set) var isSyncingLikedSongs = false
    @Published private(set) var hasLoadedHome = false
    @Published private(set) var hasLoadedLibrary = false
    @Published private(set) var sleepTimerEndDate: Date?
    @Published private(set) var isDownloadingNowPlaying = false
    @Published private(set) var isDeletingAccountData = false
    @Published var relatedTracks: [Track] = []
    @Published private(set) var isLoadingRelatedTracks = false
    @Published private(set) var isLoadingMoreRecommendations = false
    @Published private(set) var isLoadingMoreSearchResults = false
    @Published private(set) var searchSuggestionTracks: [Track] = []
    @Published private(set) var isLoadingSearchSuggestions = false
    var searchSuggestionQueryKey = ""
    @Published var isSearchFieldFocused = false
    @Published var playlistPickerState: PlaylistPickerState = .hidden
    @Published private(set) var playlistPickerHost: PlaylistPickerHost = .main
    @Published private(set) var dislikedTrackIDs: Set<String> = []
    @Published var isHistoryEnabled: Bool = true
    @Published private(set) var isPlaybackActive = false
    /// Short, friendly "why these picks" line produced by the optional AI curator for
    /// the home Recommended shelf. `nil` when AI curation is unconfigured or unavailable.
    @Published var recommendationBlurb: String?
    /// Currently selected bottom tab. Bound by `MainTabView`; also driven externally
    /// (e.g. tapping a "download finished" notification jumps to the Downloads tab).
    @Published var selectedMainTab: MainTab = .home

    var session: YouTubeSession?
    var sleepTimerTask: Task<Void, Never>?
    var relatedTracksTask: Task<Void, Never>?
    var relatedTracksContextKey: String?
    var loadedRelatedTracksContextKey: String?
    var autoplayContinuationTask: Task<Void, Never>?
    var playbackCompletionWatchTask: Task<Void, Never>?
    var likedSongsHydrationTask: Task<Void, Never>?
    let downloadService = DownloadService.shared
    let authService: AuthProviding
    let catalogService: MusicCatalogProviding
    let playbackService: PlaybackService
    let logger: any AppLogging
    let musicRecognitionService = MusicRecognitionService()
    let localMusicProfileStore: MusicProfileStoring
    let interactionTracker: InteractionTracker
    let recommendationEngine: RecommendationEngine
    let recommendationExposureStore: RecommendationExposureStore
    /// Optional AI curation layer. Self-guards to a no-op when no backend is configured.
    let openRouterService = OpenRouterService()
    let recommendationCandidateCache = CacheStore<String, [Track]>(
        ttl: AppConfig.Recommendations.candidateCacheTTL,
        maxEntries: AppConfig.Recommendations.maxCachedQueries
    )
    var playlistCache: [String: TrackCacheEntry] = [:]
    var collectionCache: [String: TrackCacheEntry] = [:]
    var cancellables: Set<AnyCancellable> = []
    var accountLikedTrackIDs: Set<String> = []
    var isRefreshingDashboard = false
    var activeSearchRequestID: UUID?
    let localLikedPlaylistID = AppConfig.Library.localLikedPlaylistID
    let localSavedSongsPlaylistID = AppConfig.Library.localSavedSongsPlaylistID
    let localReplayMixPlaylistID = AppConfig.Library.localReplayMixPlaylistID
    let localFavoritesMixPlaylistID = AppConfig.Library.localFavoritesMixPlaylistID
    let deviceProfileID = AppConfig.Library.deviceProfileID
    let likedSongsAccountSyncCooldown = AppConfig.Library.likedSongsSyncCooldown
    let maxConcurrentBatchStreamResolutions = AppConfig.Downloads.maxConcurrentStreamResolutions
    let batchDownloadResolveSpacingNanoseconds = AppConfig.Downloads.batchResolveSpacingNanoseconds
    let pendingDownloadRetryDelayNanoseconds = AppConfig.Downloads.pendingDownloadRetryDelayNanoseconds
    let maxPendingDownloadRetryPassesWithoutProgress = AppConfig.Downloads.maxPendingDownloadRetryPassesWithoutProgress
    let trackCacheTTL = AppConfig.Cache.trackListTTL
    let authenticatedCatalogRefreshCooldown = AppConfig.Catalog.authenticatedRefreshCooldown
    let dislikedTrackIDsKey = "musictube.dislikedTrackIDs"
    let locallyUnlikedTrackIDsKey = "musictube.locallyUnlikedTrackIDs"
    let historyEnabledKey = "musictube.historyEnabled"
    let lastLikedSyncKey = "musictube.lastLikedSongsAccountSyncDate"
    let downloadNotificationPromptKey = "musictube.downloadNotificationPromptRequested"
    var lastLikedSongsAccountSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: lastLikedSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastLikedSyncKey) }
    }
    var pendingDownloadResumeTask: Task<Void, Never>?
    var metadataEnrichmentTask: Task<Void, Never>?
    var homeFeedPersistTask: Task<Void, Never>?
    var homeMixRefreshTask: Task<Void, Never>?
    var homeRecommendationRefreshTask: Task<Void, Never>?
    var homePrefetchTask: Task<Void, Never>?
    private static let homeFeedCacheMaxAge: TimeInterval = 60 * 60 * 24 * 7
    private static let presentationHomeRefreshCooldown: TimeInterval = 60
    var activeListeningSession: ActiveListeningSession?
    var recentRecommendationOutcomes: [RecommendationSessionOutcome] = []
    /// Learned in the background and consumed only when the next feed generation is
    /// intentionally built. This prevents a late network/AI response moving Home.
    var pendingHomeRecommendations: [Track] = []
    var pendingAICuratedTrackIDs: [String] = []
    var accumulatedRecommendationSignalCount = 0
    /// Frozen at the beginning of a recommendation generation so impressions recorded
    /// while the user is browsing do not reshuffle cards underneath their finger.
    var recommendationRotationExposures: [Track] = []
    var collaborativeRecommendationSeedTrackKeys: Set<String> = []
    var locallyUnlikedTrackIDs: Set<String> = []
    var sessionRestoreStarted = false
    var isAppInBackground = false
    var isCarPlayConnected = false
    var lastAuthenticatedHomeRefreshDate: Date?
    var lastAuthenticatedLibraryRefreshDate: Date?
    var lastPresentationHomeRefreshDate = Date.distantPast
    var presentationHomeRefreshTask: Task<Void, Never>?
    var pendingPresentationHomeRefresh = false
    var pendingPresentationHomeRefreshShouldForce = false
    var lifecycleObservers: [NSObjectProtocol] = []

    init(
        authService: AuthProviding,
        catalogService: MusicCatalogProviding,
        playbackService: PlaybackService,
        localMusicProfileStore: MusicProfileStoring = LocalMusicProfileStore.shared,
        interactionTracker: InteractionTracker? = nil,
        recommendationEngine: RecommendationEngine = .shared,
        recommendationExposureStore: RecommendationExposureStore? = nil,
        logger: any AppLogging = DefaultAppLogger(category: "AppState")
    ) {
        self.authService = authService
        self.catalogService = catalogService
        self.playbackService = playbackService
        self.localMusicProfileStore = localMusicProfileStore
        self.interactionTracker = interactionTracker ?? InteractionTracker.shared
        self.recommendationEngine = recommendationEngine
        let resolvedExposureStore = recommendationExposureStore ?? RecommendationExposureStore.shared
        self.recommendationExposureStore = resolvedExposureStore
        self.recommendationRotationExposures = resolvedExposureStore.recentTracks(
            profileID: AppConfig.Library.deviceProfileID
        )
        self.logger = logger
        if let raw = UserDefaults.standard.object(forKey: "musictube.dislikedTrackIDs") as? [String] {
            dislikedTrackIDs = Set(raw)
        }
        if let raw = UserDefaults.standard.object(forKey: "musictube.locallyUnlikedTrackIDs") as? [String] {
            locallyUnlikedTrackIDs = Set(raw)
        }
        // History tracking is always on now that the Library on/off toggle has been
        // removed. The internal `isHistoryEnabled` gate is retained so the rest of the
        // recording/recommendation logic keeps working unchanged.
        isHistoryEnabled = true
        UserDefaults.standard.set(true, forKey: historyEnabledKey)
        syncLocalMusicProfileState()

        // Paint the last rendered "Recommended For You" feed instantly on launch so the
        // homepage never waits on the network. The cached feed already carries enriched
        // duration/view-count metadata; the background refresh replaces it when ready.
        restorePersistedHomeFeedIfAvailable()

        // Make recognition a "secondary audio source" so the RemoteCommandManager
        // stops it before primary playback resumes. Without this, a Shazam
        // session that's still listening when the user taps "play" from the
        // Lock Screen keeps holding the `.playAndRecord` audio session and
        // routes pause taps to itself instead of to PlaybackService.
        playbackService.registerSecondaryAudioSource(musicRecognitionService)

        observePublisher(playbackService.$state) { state, playbackState in
            let previousPlaybackState = state.playbackState
            let previousTrack = previousPlaybackState.nowPlaying
            let previousIsPlaying = previousPlaybackState.isPlaying
            let didChangeTrack = previousTrack?.playbackKey != playbackState.nowPlaying?.playbackKey
            guard previousPlaybackState != playbackState else { return }
            state.handlePlaybackStateTransition(from: previousPlaybackState, to: playbackState)
            state.playbackState = playbackState
            if state.nowPlayingTrack != playbackState.nowPlaying {
                state.nowPlayingTrack = playbackState.nowPlaying
            }
            if state.isPlaybackActive != playbackState.isPlaying {
                state.isPlaybackActive = playbackState.isPlaying
            }

            if previousPlaybackState.playbackErrorMessage != playbackState.playbackErrorMessage,
               let message = playbackState.playbackErrorMessage {
                state.errorMessage = message
            }

            if didChangeTrack, state.isAppInBackground == false {
                state.refreshRelatedTracksTask(for: playbackState.nowPlaying)
            } else if didChangeTrack {
                state.cancelRelatedTracksRefresh()
            }

            if didChangeTrack || previousIsPlaying != playbackState.isPlaying {
                state.refreshCarPlay()
            }
        }

        observePublisher(downloadService.$lastError) { state, error in
            guard let error else { return }
            state.errorMessage = error.localizedDescription
        }

        observePublisher(downloadService.$downloads) { state, _ in
            state.refreshCarPlay()
        }

        observePublisher(downloadService.$folders) { state, _ in
            state.refreshCarPlay()
        }

        observePublisher(DataUsageSettings.shared.$personalizedAICuration) { state, isEnabled in
            if isEnabled == false {
                state.recommendationBlurb = nil
            }
        }

        AppContainer.shared.appState = self

        observePublisher($authState) { state, authState in
            guard authState != .restoring else { return }
            state.updatePreferenceOnboardingPresentation()
            state.refreshCarPlay()
            if state.pendingPresentationHomeRefresh {
                let shouldForce = state.pendingPresentationHomeRefreshShouldForce
                state.pendingPresentationHomeRefresh = false
                state.pendingPresentationHomeRefreshShouldForce = false
                state.requestPresentationHomeRefresh(forceRefresh: shouldForce)
            }
        }

        observeAppLifecycle()
    }

    deinit {
        sleepTimerTask?.cancel()
        relatedTracksTask?.cancel()
        autoplayContinuationTask?.cancel()
        playbackCompletionWatchTask?.cancel()
        likedSongsHydrationTask?.cancel()
        pendingDownloadResumeTask?.cancel()
        metadataEnrichmentTask?.cancel()
        homeFeedPersistTask?.cancel()
        homeMixRefreshTask?.cancel()
        homeRecommendationRefreshTask?.cancel()
        homePrefetchTask?.cancel()
        presentationHomeRefreshTask?.cancel()
        cancellables.forEach { $0.cancel() }
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }

        if AppContainer.shared.appState === self {
            AppContainer.shared.appState = nil
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

    /// The track the engine is on *right now*.
    ///
    /// Deliberately reads through to `PlaybackService` instead of the mirrored
    /// `nowPlayingTrack`: `@Published` emits from `willSet`, so anything that reads
    /// this from inside a `$nowPlayingTrack` sink would otherwise still see the
    /// previous track. `nowPlayingTrack` stays as the *change signal* that drives
    /// SwiftUI invalidation and Combine subscriptions; this is the value to render.
    var nowPlaying: Track? {
        playbackService.nowPlaying
    }

    /// Whether audio is actually playing right now. Reads through to
    /// `PlaybackService` for the same reason as `nowPlaying` — `isPlaybackActive` is
    /// the change signal, this is the value to render.
    var isPlaying: Bool {
        playbackService.isPlaying
    }

    var featuredTracks: [Track] {
        homeContent.featuredTracks.playableOnly().withoutShorts()
    }

    var recentTracks: [Track] {
        homeContent.recentTracks.playableOnly().withoutShorts()
    }

    var suggestedMixes: [Playlist] {
        homeContent.suggestedMixes
    }

    var homeStatusMessage: String? {
        homeContent.statusMessage
    }

    var isYouTubeConnected: Bool {
        session != nil
    }

    func observePublisher<Value>(
        _ publisher: Published<Value>.Publisher,
        handler: @escaping (AppState, Value) -> Void
    ) {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                handler(self, value)
            }
            .store(in: &cancellables)
    }

    func observeAppLifecycle() {
        let center = NotificationCenter.default
        let backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAppInBackground = true
                // A connected CarPlay scene remains visible while the handset is
                // locked, so its shared Home refresh must be allowed to finish.
                if self.isCarPlayConnected == false {
                    self.cancelOptionalHomeWork()
                    self.cancelRelatedTracksRefresh()
                    self.cancelLikedSongsHydration(clearAccountLikes: false)
                    self.playbackService.cancelSpeculativePrefetches()
                }
            }
        }

        let foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAppInBackground = false
                self.reconcileSleepTimer()
                self.refreshRelatedTracksTask(for: self.playbackState.nowPlaying)
            }
        }

        let powerObserver = center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePowerBudgetChanged()
            }
        }

        let thermalObserver = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePowerBudgetChanged()
            }
        }

        lifecycleObservers = [backgroundObserver, foregroundObserver, powerObserver, thermalObserver]
    }

    func allowsOptionalNetworkWork(forceRefresh: Bool = false) -> Bool {
        guard isAppInBackground == false || isCarPlayConnected else { return false }
        guard AppPowerBudget.isLowPowerModeEnabled == false else { return false }
        guard AppPowerBudget.isThermallyConstrained == false else { return false }
        guard AppPowerBudget.isLowBattery == false else { return false }
        if forceRefresh { return true }
        guard DataUsageSettings.shared.dataSaverMode == false else { return false }
        return AppPowerBudget.isThermallyWarm == false
    }

    func allowsPlaybackPrefetch() -> Bool {
        guard DataUsageSettings.shared.dataSaverMode == false else { return false }
        return AppPowerBudget.allowsSpeculativeNetwork(isAppInBackground: isAppInBackground)
    }

    func handlePowerBudgetChanged() {
        guard allowsOptionalNetworkWork() == false else { return }
        cancelOptionalHomeWork()
        playbackService.cancelSpeculativePrefetches()
    }

    /// Called whenever the phone UI becomes active. Cached content remains visible
    /// while a fresh Home request replaces it.
    func handleApplicationDidBecomeActive() {
        isAppInBackground = false
        reconcileSleepTimer()
        requestPresentationHomeRefresh(forceRefresh: false)
    }

    /// CarPlay is an active app surface even while the phone is locked. It uses the
    /// same Home state as the phone rather than maintaining a separate recommendation feed.
    func handleCarPlayConnected() {
        isCarPlayConnected = true
        playbackService.setCarPlayConnected(true)
        requestPresentationHomeRefresh(forceRefresh: false)
    }

    func handleCarPlayDidBecomeActive() {
        isCarPlayConnected = true
        playbackService.setCarPlayConnected(true)
        requestPresentationHomeRefresh(forceRefresh: false)
    }

    func handleCarPlayDisconnected() {
        isCarPlayConnected = false
        playbackService.setCarPlayConnected(false)
    }

    func requestPresentationHomeRefresh(forceRefresh: Bool = false) {
        // Repaint CarPlay immediately from cached/shared state, then again after refresh.
        refreshCarPlay()

        guard authState != .restoring else {
            pendingPresentationHomeRefresh = true
            pendingPresentationHomeRefreshShouldForce = pendingPresentationHomeRefreshShouldForce || forceRefresh
            return
        }

        // App and CarPlay activation callbacks often arrive together. Coalescing that
        // burst prevents duplicate YouTube requests. CarPlay opens cached-first and
        // only checks remote Home when the shared feed is stale.
        let cooldown = forceRefresh ? 5 : Self.presentationHomeRefreshCooldown
        guard Date().timeIntervalSince(lastPresentationHomeRefreshDate) >= cooldown else { return }
        lastPresentationHomeRefreshDate = Date()

        presentationHomeRefreshTask?.cancel()
        presentationHomeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshHome(forceRefresh: forceRefresh)
            guard Task.isCancelled == false else { return }
            self.refreshCarPlay()
            self.presentationHomeRefreshTask = nil
        }
    }

    func cancelOptionalHomeWork() {
        metadataEnrichmentTask?.cancel()
        metadataEnrichmentTask = nil
        homeMixRefreshTask?.cancel()
        homeMixRefreshTask = nil
        homeRecommendationRefreshTask?.cancel()
        homeRecommendationRefreshTask = nil
        homePrefetchTask?.cancel()
        homePrefetchTask = nil
    }

    func cachedPlaylistTracks(for playlistID: String) -> [Track]? {
        guard let entry = playlistCache[playlistID] else { return nil }
        guard entry.expiresAt > Date() || isSyntheticMixID(playlistID) else {
            playlistCache.removeValue(forKey: playlistID)
            return nil
        }

        guard isSyntheticMixID(playlistID) else {
            return entry.tracks.playableOnly()
        }

        let sanitizedTracks = sanitizedSyntheticMixTracks(entry.tracks, for: playlistID).playableOnly()
        guard sanitizedTracks.isEmpty == false else {
            playlistCache.removeValue(forKey: playlistID)
            return nil
        }

        if sanitizedTracks.map(trackIdentifier) != entry.tracks.map(trackIdentifier) {
            setPlaylistCache(sanitizedTracks, for: playlistID)
        }

        return sanitizedTracks
    }

    func setPlaylistCache(_ tracks: [Track], for playlistID: String) {
        playlistCache[playlistID] = TrackCacheEntry(
            tracks: tracks,
            expiresAt: Date().addingTimeInterval(trackCacheTTL)
        )
    }

    func cachedCollectionTracks(for collectionID: String) -> [Track]? {
        guard let entry = collectionCache[collectionID] else { return nil }
        guard entry.expiresAt > Date() else {
            collectionCache.removeValue(forKey: collectionID)
            return nil
        }

        return entry.tracks.playableOnly()
    }

    func setCollectionCache(_ tracks: [Track], for collectionID: String) {
        collectionCache[collectionID] = TrackCacheEntry(
            tracks: tracks,
            expiresAt: Date().addingTimeInterval(trackCacheTTL)
        )
    }

    func updateHomeContent(
        featuredTracks: [Track]? = nil,
        recentTracks: [Track]? = nil,
        suggestedMixes: [Playlist]? = nil,
        statusMessage: String?? = nil
    ) {
        var updated = homeContent

        if let featuredTracks {
            let previousKeys = updated.featuredTracks.map(trackIdentifier)
            let nextKeys = featuredTracks.map(trackIdentifier)
            updated.featuredTracks = featuredTracks
            if previousKeys != nextKeys {
                updated.recommendationGenerationID = UUID()
                updated.recommendationGeneratedAt = Date()
            }
        }

        if let recentTracks {
            updated.recentTracks = recentTracks
        }

        if let suggestedMixes {
            updated.suggestedMixes = suggestedMixes
        }

        if let statusMessage {
            updated.statusMessage = statusMessage
        }

        guard updated != homeContent else { return }
        homeContent = updated

        // Keep the on-disk copy in step so the next launch restores this exact feed.
        if updated.featuredTracks.isEmpty == false {
            schedulePersistHomeFeed()
        }
    }

    func refreshCarPlay() {
        AppContainer.shared.carPlayManager?.refresh(using: self)
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

    var visibleLibrarySectionOrder: [AppLibrarySection] {
        librarySectionOrder.filter(isLibrarySectionVisible(_:))
    }

    var libraryPlaylists: [Playlist] {
        playlists.filter { $0.kind != .likedMusic && $0.kind != .savedSongs }
    }

    var isUsingLocalLibraryFallback: Bool {
        playlists.contains(where: { isLocalCollectionID($0.id) })
    }

    func isTrackLiked(_ track: Track) -> Bool {
        let identifier = trackIdentifier(track)
        return likedTrackIDs.contains(identifier) && locallyUnlikedTrackIDs.contains(identifier) == false
    }

    func isTrackSaved(_ track: Track) -> Bool {
        savedTrackIDs.contains(trackIdentifier(track))
    }

    func isTrackSubstantiallyListened(_ track: Track) -> Bool {
        substantiallyListenedTrackIDs.contains(trackIdentifier(track))
    }

    func completePreferenceOnboarding(selectedTags: [UserPreferenceTag], customTags: [String]) {
        let customPreferences = customTags.compactMap { tag -> UserPreferenceTag? in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            return UserPreferenceTag(
                id: "custom-preference-\(UUID().uuidString)",
                name: trimmed,
                category: .genres,
                isCustom: true
            )
        }
        let profile = UserPreferenceProfile(
            hasCompletedOnboarding: true,
            selectedTags: selectedTags + customPreferences
        )
        applyPreferenceSnapshot(localMusicProfileStore.setPreferenceProfile(profile, profileID: currentProfileID))
        refreshRecommendationsFromPreferenceSignals()
    }

    func setPreferenceTag(_ tag: UserPreferenceTag, isSelected: Bool) {
        var profile = userPreferenceProfile
        profile.hasCompletedOnboarding = true
        profile.selectedTags.removeAll { $0.id == tag.id }
        if isSelected {
            profile.selectedTags.append(tag)
        }
        applyPreferenceSnapshot(localMusicProfileStore.setPreferenceProfile(profile, profileID: currentProfileID))
        refreshRecommendationsFromPreferenceSignals()
    }

    func addCustomPreference(named name: String, category: UserPreferenceCategory) {
        applyPreferenceSnapshot(localMusicProfileStore.addCustomPreference(name, category: category, profileID: currentProfileID))
        refreshRecommendationsFromPreferenceSignals()
    }

    func updateCustomPreference(_ preferenceID: String, name: String, category: UserPreferenceCategory) {
        applyPreferenceSnapshot(localMusicProfileStore.updateCustomPreference(preferenceID, name: name, category: category, profileID: currentProfileID))
        refreshRecommendationsFromPreferenceSignals()
    }

    func removePreference(_ preferenceID: String) {
        applyPreferenceSnapshot(localMusicProfileStore.removePreference(preferenceID, profileID: currentProfileID))
        refreshRecommendationsFromPreferenceSignals()
    }

    func isCollectionSaved(_ collection: MusicCollection) -> Bool {
        savedCollections.contains(where: { $0.id == collection.id })
    }

    func isLibrarySectionVisible(_ section: AppLibrarySection) -> Bool {
        switch section {
        case .history, .quickActions, .likedSongs, .savedSongs, .customPlaylists, .savedCollections:
            return true
        }
    }

    func moveLibrarySection(_ draggedSection: AppLibrarySection, to targetSection: AppLibrarySection) {
        guard draggedSection != targetSection else { return }
        guard let sourceIndex = librarySectionOrder.firstIndex(of: draggedSection),
              let targetIndex = librarySectionOrder.firstIndex(of: targetSection) else {
            return
        }

        var updatedOrder = librarySectionOrder
        let movedSection = updatedOrder.remove(at: sourceIndex)
        updatedOrder.insert(movedSection, at: targetIndex)
        persistLibrarySectionOrder(updatedOrder)
    }

    var playlistPickerTrack: Track? {
        if case .create(let track) = playlistPickerState { return track }
        return nil
    }

    var playlistPickerTargetPlaylist: Playlist? {
        if case .add(let playlist) = playlistPickerState { return playlist }
        return nil
    }

    func signIn() async {
        isLoading = true
        defer { isLoading = false }

        do {
            logger.info("Starting YouTube sign-in")
            let session = try await authService.signIn()
            applyAuthorizedSession(session)
            syncLocalMusicProfileState()
            logger.info("YouTube sign-in succeeded for user \(session.user.email)")
            await refreshDashboard(forceRefresh: true)
        } catch {
            logger.error("YouTube sign-in failed", error: error)
            errorMessage = error.localizedDescription
            authState = .guest
        }
    }

    func signOut() async {
        logger.info("Signing out current YouTube session")
        await authService.signOut()
        session = nil
        user = nil
        authState = .guest
        // Remove account-synced liked tracks so they don't appear in guest mode.
        // Tracks the user explicitly liked inside MusicTube are also cleared here;
        // they will be re-synced from YouTube on the next sign-in.
        localMusicProfileStore.clearAccountLikedTracks(profileID: currentProfileID)
        clearRemoteState()
        syncLocalMusicProfileState()
        await refreshDashboard(forceRefresh: true)
    }

    func deleteCurrentAccountData() async {
        guard isDeletingAccountData == false else { return }

        isDeletingAccountData = true
        defer { isDeletingAccountData = false }

        logger.info("Deleting current account data and signing out")
        await authService.signOut()
        await downloadService.deleteAllDownloads()
        localMusicProfileStore.clearAllData()
        interactionTracker.clearAllData()
        recommendationExposureStore.clearAllData()
        recommendationRotationExposures = []
        await recommendationCandidateCache.removeAll()
        clearPersistedHomeFeed()
        ImageCache.shared.removeAll()
        await ArtworkDiskCache.shared.removeAll()
        DataUsageSettings.shared.resetToDefaults()

        session = nil
        user = nil
        authState = .guest
        resetAllLoadedState()
        syncLocalMusicProfileState()
        await refreshDashboard(forceRefresh: true)
    }

    func refreshDashboard(forceRefresh: Bool = false) async {
        guard isRefreshingDashboard == false else { return }

        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }

        // Refresh the visible home feed immediately so the app opens to content first.
        await refreshHome(forceRefresh: forceRefresh)
        // Refresh library data without blocking the initial home experience.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.allowsOptionalNetworkWork(forceRefresh: forceRefresh) else { return }
            await self.refreshLibrary(forceRefresh: forceRefresh)
            if self.homeStatusMessage != nil || self.suggestedMixes.count < 2 {
                _ = await self.buildHomeFromLoadedLibrary()
                self.refreshCarPlay()
            }
        }
    }

    func refreshHome(forceRefresh: Bool = false) async {
        guard isLoading == false else {
            // A cold launch can still be finishing its initial load when the active
            // scene callback arrives. Preserve the activation refresh instead of
            // silently dropping it behind the in-flight request.
            if forceRefresh {
                pendingPresentationHomeRefresh = true
            }
            return
        }

        if forceRefresh == false,
           hasLoadedHome,
           featuredTracks.isEmpty == false || recentTracks.isEmpty == false {
            let shouldRefreshRemoteHome = session != nil && shouldRefreshAuthenticatedHome(forceRefresh: false)
            guard shouldRefreshRemoteHome || suggestedMixes.isEmpty else { return }
        }

        if forceRefresh {
            // A user-requested/foreground refresh is an explicit request for a new
            // batch. Mark the prior visible shelf and rotate the query seeds before
            // asking any source for more recommendations.
            recommendationExposureStore.record(
                Array(featuredTracks.prefix(12)),
                profileID: currentProfileID
            )
            recommendationExposureStore.advanceRotation(profileID: currentProfileID)
            recommendationRotationExposures = recommendationExposureStore.recentTracks(
                profileID: currentProfileID
            )
        } else {
            recommendationRotationExposures = recommendationExposureStore.recentTracks(
                profileID: currentProfileID
            )
        }

        let didSeedLocalHome = seedHomeFromLocalProfileIfNeeded(forceRefresh: forceRefresh)
        if didSeedLocalHome {
            refreshCarPlay()
        }

        guard allowsOptionalNetworkWork(forceRefresh: forceRefresh) else {
            if didSeedLocalHome {
                hasLoadedHome = true
            }
            return
        }

        let dataSettings = DataUsageSettings.shared
        let network = NetworkMonitor.shared
        if dataSettings.autoSyncOnWiFiOnly, network.isCellular, !forceRefresh {
            if didSeedLocalHome {
                hasLoadedHome = true
            }
            return
        }

        isLoading = true
        defer {
            isLoading = false
            hasLoadedHome = true
            if pendingPresentationHomeRefresh {
                pendingPresentationHomeRefresh = false
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.refreshHome(forceRefresh: true)
                    self.refreshCarPlay()
                }
            }
        }

        var didFallBackFromExpiredSession = false

        if session != nil, shouldRefreshAuthenticatedHome(forceRefresh: forceRefresh) {
            do {
                if let home = try await performAuthenticatedOperation({ accessToken in
                    try await catalogService.loadHome(accessToken: accessToken)
                }) {
                    lastAuthenticatedHomeRefreshDate = Date()
                    interactionTracker.registerTracks(home.featured + home.recent)
                    collaborativeRecommendationSeedTrackKeys = Set((home.featured + home.recent).map(trackIdentifier))
                    let context = recommendationSeedContext(focusedTrack: nowPlayingTrack)
                    let mergedFeatured = rankedRecommendationCandidates(
                        pendingHomeRecommendations + home.featured + home.recent,
                        context: context,
                        limit: 60,
                        excluding: alreadyKnownTrackIdentifiers()
                    )
                    let featured = mergedFeatured.isEmpty
                        ? Array(curatedSuggestionTracks(deduplicatedTracks(home.featured + home.recent)).prefix(60))
                        : mergedFeatured
                    let featuredIDs = Set(featured.map(trackIdentifier))
                    let recent = Array(
                        curatedSuggestionTracks(
                            deduplicatedTracks(home.recent + home.featured.shuffled())
                        )
                            .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                            .prefix(40)
                    )

                    updateHomeContent(
                        featuredTracks: featured,
                        recentTracks: recent,
                        statusMessage: nil
                    )
                    pendingHomeRecommendations = []
                    accumulatedRecommendationSignalCount = 0

                    refreshCarPlay()
                    scheduleHomeMetadataEnrichment()

                    homeMixRefreshTask?.cancel()
                    homeMixRefreshTask = Task { @MainActor [weak self] in
                        guard let self, self.allowsOptionalNetworkWork() else { return }
                        await self.rebuildSuggestedMixes()
                        guard Task.isCancelled == false else { return }
                        self.refreshCarPlay()
                    }

                    homeRecommendationRefreshTask?.cancel()
                    homeRecommendationRefreshTask = Task { @MainActor [weak self] in
                        guard let self, self.allowsOptionalNetworkWork() else { return }
                        let learnedTracks = await self.smartRecommendations(
                            limit: 18,
                            excluding: Set((featured + recent).map(self.trackIdentifier))
                                .union(self.alreadyKnownTrackIdentifiers())
                        )
                        guard Task.isCancelled == false, self.allowsOptionalNetworkWork() else { return }
                        guard learnedTracks.isEmpty == false else { return }

                        // Keep learning, but stage this batch for the next intentional
                        // feed generation instead of mutating the visible Home shelf.
                        self.pendingHomeRecommendations = self.deduplicatedBySignature(
                            learnedTracks + self.pendingHomeRecommendations
                        )
                    }

                    homePrefetchTask?.cancel()
                    homePrefetchTask = Task { @MainActor [weak self] in
                        guard let self, self.allowsPlaybackPrefetch() else { return }
                        self.playbackService.prefetchStreams(for: Array(featured.prefix(2)))
                    }
                    return
                }
            } catch {
                if await handleAuthorizationFailureIfNeeded(for: error) {
                    didFallBackFromExpiredSession = true
                    updateHomeContent(
                        statusMessage: "Your YouTube session expired, so MusicTube is using on-device picks for now."
                    )
                }
                if await buildHomeFromLoadedLibrary() {
                    updateHomeContent(
                        statusMessage: "Using your MusicTube taste profile while YouTube recommendations reload."
                    )
                    refreshCarPlay()
                    return
                }
            }
        }

        if await buildHomeFromLoadedLibrary() {
            updateHomeContent(
                statusMessage: hasPersonalizedRecommendationSignals()
                    ? nil
                    : starterRecommendationsStatusMessage(expiredSessionFallback: didFallBackFromExpiredSession)
            )
            refreshCarPlay()
            return
        }

        if await buildStarterHome() {
            updateHomeContent(
                statusMessage: starterRecommendationsStatusMessage(expiredSessionFallback: didFallBackFromExpiredSession)
            )
            refreshCarPlay()
            return
        }

        updateHomeContent(
            featuredTracks: [],
            recentTracks: [],
            suggestedMixes: [],
            statusMessage: isYouTubeConnected
                ? "Reconnect YouTube or play more songs so MusicTube can rebuild your recommendations."
                : "Search and play a few songs so MusicTube can learn what you like."
        )
        playlistCache = playlistCache.filter { isSyntheticMixID($0.key) == false }
    }

    func loadMoreRecommendedTracksIfNeeded() async {
        guard isLoadingMoreRecommendations == false else { return }
        guard allowsOptionalNetworkWork() else { return }

        isLoadingMoreRecommendations = true
        defer { isLoadingMoreRecommendations = false }

        // Exclude what's already shown AND what the user has already heard so paged
        // recommendations keep introducing fresh content instead of repeating history.
        let existingIDs = Set((featuredTracks + recentTracks).map(trackIdentifier))
            .union(alreadyKnownTrackIdentifiers())
        var moreTracks = await smartRecommendations(limit: 24, excluding: existingIDs)
        if moreTracks.isEmpty {
            moreTracks = await starterRecommendations(limit: 24, excluding: existingIDs)
        }
        guard moreTracks.isEmpty == false else { return }

        updateHomeContent(
            featuredTracks: curatedSuggestionTracks(deduplicatedBySignature(featuredTracks + moreTracks))
        )
        refreshCarPlay()
        scheduleHomeMetadataEnrichment()
    }

    /// Fills missing duration / view count on the visible home feed in the background.
    /// Many feed sources (liked songs, playlist items, the local taste profile) carry
    /// no view count and sometimes no duration, which left "Recommended For You" rows
    /// blank. A single batched lookup backfills them without blocking the first paint.
    func scheduleHomeMetadataEnrichment() {
        metadataEnrichmentTask?.cancel()
        guard allowsOptionalNetworkWork() else { return }
        metadataEnrichmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.allowsOptionalNetworkWork() else { return }
            // Prioritise what the user actually sees first.
            let candidates = Array((self.featuredTracks + self.recentTracks).prefix(60))
            let needsEnrichment = candidates.contains { $0.duration == nil || $0.viewCount == nil }
            guard needsEnrichment else { return }

            let enriched = await self.catalogService.fillMissingMetadata(for: candidates)
            guard Task.isCancelled == false, enriched.count == candidates.count else { return }

            var metadataByID: [String: Track] = [:]
            for track in enriched {
                metadataByID[self.trackIdentifier(track)] = track
            }

            // Re-apply onto whatever is current — the feed may have changed while the
            // lookup was in flight. mergingMetadata never overwrites existing values.
            let mergedFeatured = self.featuredTracks.map { track -> Track in
                guard let source = metadataByID[self.trackIdentifier(track)] else { return track }
                return track.mergingMetadata(duration: source.duration, viewCount: source.viewCount)
            }
            let mergedRecent = self.recentTracks.map { track -> Track in
                guard let source = metadataByID[self.trackIdentifier(track)] else { return track }
                return track.mergingMetadata(duration: source.duration, viewCount: source.viewCount)
            }

            guard mergedFeatured != self.featuredTracks || mergedRecent != self.recentTracks else { return }
            self.updateHomeContent(featuredTracks: mergedFeatured, recentTracks: mergedRecent)
            self.refreshCarPlay()
        }
    }

    // MARK: - Home feed persistence

    struct PersistedHomeFeed: Codable {
        var featured: [Track]
        var recent: [Track]
        var savedAt: Date
    }

    var homeFeedCacheURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return directory.appendingPathComponent("musictube-home-feed.json")
    }

    /// Restores the last persisted feed into `homeContent` so launch paints real
    /// recommendations with no computation or network. Only runs when the feed is
    /// still empty (i.e. nothing has been built yet this session).
    func restorePersistedHomeFeedIfAvailable() {
        guard homeContent.featuredTracks.isEmpty, homeContent.recentTracks.isEmpty else { return }
        guard let url = homeFeedCacheURL, let data = try? Data(contentsOf: url) else { return }
        guard let feed = try? JSONDecoder().decode(PersistedHomeFeed.self, from: data) else { return }
        guard Date().timeIntervalSince(feed.savedAt) <= Self.homeFeedCacheMaxAge else { return }

        // A persisted feed is a UI snapshot: restore its exact order. Re-running the
        // ranker during launch would make cards jump before the user does anything.
        let featured = curatedSuggestionTracks(feed.featured)
            .filter { $0.isQuranOrRecitation == false && $0.listeningContentContext == .music }
        guard featured.isEmpty == false else { return }
        let featuredIDs = Set(featured.map(trackIdentifier))
        let recent = curatedSuggestionTracks(feed.recent)
            .filter { featuredIDs.contains(trackIdentifier($0)) == false }

        homeContent = HomeContent(
            featuredTracks: featured,
            recentTracks: recent,
            suggestedMixes: homeContent.suggestedMixes,
            statusMessage: nil
        )
    }

    /// Writes the current feed to disk off the main actor. Cancels any in-flight write
    /// so frequent feed updates collapse into a single save.
    func schedulePersistHomeFeed() {
        let featured = Array(homeContent.featuredTracks.prefix(60))
        guard featured.isEmpty == false, let url = homeFeedCacheURL else { return }
        let recent = Array(homeContent.recentTracks.prefix(40))
        let feed = PersistedHomeFeed(featured: featured, recent: recent, savedAt: Date())

        homeFeedPersistTask?.cancel()
        homeFeedPersistTask = Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(feed) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func clearPersistedHomeFeed() {
        homeFeedPersistTask?.cancel()
        homeFeedPersistTask = nil
        guard let url = homeFeedCacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func performSearch() async {
        _ = await search(query: searchQuery)
    }

    /// Non-publishing search entry point used by `SearchViewModel`. Keeping request
    /// state in the feature model prevents every keystroke/result page from
    /// invalidating views that observe the AppState compatibility facade.
    func fetchSearchResults(for query: String) async throws -> SearchResponse {
        let resolvedInput = resolveSearchInput(from: query)
        let trimmed: String
        switch resolvedInput {
        case .text(let value):
            trimmed = value
        case .playlist(let playlist):
            trimmed = playlist.id
        case .video(let videoID):
            trimmed = videoID
        }

        guard trimmed.isEmpty == false else { return .empty }
        let accessToken = await authorizedAccessTokenIfAvailable()
        if let direct = try await resolveDirectSearchResponse(
            from: resolvedInput,
            accessToken: accessToken
        ) {
            return sanitizedSearchResults(direct)
        }
        return sanitizedSearchResults(
            try await catalogService.search(query: trimmed, accessToken: accessToken)
        )
    }

    func fetchMoreSearchResults(query: String, continuation: String) async throws -> SearchResponse {
        let accessToken = await authorizedAccessTokenIfAvailable()
        return sanitizedSearchResults(
            try await catalogService.loadMoreSearchResults(
                query: query,
                continuation: continuation,
                accessToken: accessToken
            )
        )
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
        searchResults = .empty

        do {
            let results = try await fetchSearchResults(for: query)
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

    /// Lightweight search used by the CarPlay search template. Returns playable songs
    /// only and deliberately does **not** mutate the published `searchResults`/`isSearching`
    /// state that drives the iPhone search screen, so searching from the car never
    /// disturbs what's on the phone.
    func carPlaySearchResults(for query: String) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let accessToken = await authorizedAccessTokenIfAvailable()
        do {
            if let direct = try await resolveDirectSearchResponse(
                from: resolveSearchInput(from: trimmed),
                accessToken: accessToken
            ) {
                return direct.songs.playableOnly().withoutShorts()
            }
            let response = try await catalogService.search(query: trimmed, accessToken: accessToken)
            return response.songs.playableOnly().withoutShorts()
        } catch {
            return []
        }
    }

    /// Strips private/deleted/unavailable videos out of a search response's song list
    /// so they never reach search-derived UI sections or queues built from search.
    func sanitizedSearchResults(_ response: SearchResponse) -> SearchResponse {
        var sanitized = response
        // Music-only app: strip unavailable videos AND Shorts/non-music clips from
        // everything the search UI shows.
        sanitized.trackCategory.items = response.trackCategory.items.playableOnly().musicOnly()
        return sanitized
    }

    func recognizeMusic(playFirstResult: Bool = false) async {
        guard isRecognizingMusic == false else {
            musicRecognitionService.stopRecognition()
            return
        }

        isRecognizingMusic = true
        errorMessage = nil

        do {
            let detectedQuery = try await musicRecognitionService.recognizeSong()
            searchQuery = detectedQuery
            isRecognizingMusic = false
            if playFirstResult {
                // Used by the "Recognize Music" App Shortcut: jump straight to
                // playing the best match instead of only showing search results.
                await searchAndPlayFirstResult(query: detectedQuery)
            } else {
                await performSearch()
            }
        } catch {
            isRecognizingMusic = false
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
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
            let accessToken = await authorizedAccessTokenIfAvailable()
            let moreResults = try await catalogService.loadMoreSearchResults(
                query: trimmedQuery,
                continuation: continuation,
                accessToken: accessToken
            )
            guard activeSearchRequestID == requestID else { return }

            var mergedResults = searchResults
            mergedResults.trackCategory.items = deduplicatedTracks(searchResults.songs + moreResults.songs).playableOnly().musicOnly()
            mergedResults.trackCategory.continuationToken = moreResults.nextSongsContinuationToken
            searchResults = mergedResults
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

    func toggleHistoryEnabled() {
        isHistoryEnabled.toggle()
        UserDefaults.standard.set(isHistoryEnabled, forKey: historyEnabledKey)
    }

    func removeHistoryTrack(_ track: Track) {
        let _ = localMusicProfileStore.removeRecentTrack(track, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()

        if featuredTracks.isEmpty || homeStatusMessage != nil {
            Task { [weak self] in
                await self?.refreshHome()
            }
        }
    }

    func clearHistory() {
        let _ = localMusicProfileStore.clearRecentTracks(profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()

        if featuredTracks.isEmpty || homeStatusMessage != nil {
            Task { [weak self] in
                await self?.refreshHome()
            }
        }
    }

    func autocompleteSuggestions(
        for query: String,
        limit: Int = 10,
        includeRemote: Bool = true
    ) async -> [String] {
        let normalizedQuery = SearchTextNormalizer.normalized(query)
        guard normalizedQuery.isEmpty == false else {
            return Array(recentSearches.prefix(limit))
        }

        let capturedRecentSearches = recentSearches
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let savedTrackTitles = snapshot.savedTracks.map(\.title)
        let savedTrackArtists = snapshot.savedTracks.map(\.artist)
        let likedTrackTitles = locallyVisibleLikedTracks(from: snapshot).map(\.title)
        let topTrackCombined = snapshot.topTracks.map { "\($0.artist) \($0.title)" }
        let historyTitles = historyTracks.map(\.title)
        let historyCombined = historyTracks.map { "\($0.artist) \($0.title)" }
        let playlistTitles = playlists.map(\.title)
        let collectionTitles = savedCollections.map(\.title)
        let collectionHints = savedCollections.map(\.queryHint)
        let downloadTitles = downloadService.availableDownloads.map(\.track.title)
        let downloadCombined = downloadService.availableDownloads.map { "\($0.track.artist) \($0.track.title)" }

        let localSuggestions: [String] = await Task.detached(priority: .userInitiated) {
            typealias Candidate = (text: String, sourcePriority: Int, ordinal: Int)
            var candidates: [Candidate] = []

            func appendCandidates(_ values: [String], sourcePriority: Int) {
                for (index, value) in values.enumerated() {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { continue }
                    candidates.append((text: trimmed, sourcePriority: sourcePriority, ordinal: index))
                }
            }

            appendCandidates(capturedRecentSearches, sourcePriority: 0)
            appendCandidates(historyTitles, sourcePriority: 1)
            appendCandidates(historyCombined, sourcePriority: 1)
            appendCandidates(savedTrackTitles, sourcePriority: 2)
            appendCandidates(savedTrackArtists, sourcePriority: 2)
            appendCandidates(likedTrackTitles, sourcePriority: 2)
            appendCandidates(topTrackCombined, sourcePriority: 2)
            appendCandidates(playlistTitles, sourcePriority: 3)
            appendCandidates(collectionTitles, sourcePriority: 3)
            appendCandidates(collectionHints, sourcePriority: 3)
            appendCandidates(downloadTitles, sourcePriority: 4)
            appendCandidates(downloadCombined, sourcePriority: 4)

            var rankedSuggestions: [(text: String, score: Int)] = []
            var seenNormalizedSuggestions: Set<String> = []
            let queryTokens = Set(SearchTextNormalizer.tokens(from: normalizedQuery))

            for candidate in candidates {
                let normalizedCandidate = SearchTextNormalizer.normalized(candidate.text)
                guard normalizedCandidate.isEmpty == false else { continue }
                guard seenNormalizedSuggestions.insert(normalizedCandidate).inserted else { continue }

                let candidateTokens = Set(SearchTextNormalizer.tokens(from: normalizedCandidate))
                let tokenOverlap = queryTokens.intersection(candidateTokens).count

                let matchScore: Int
                if normalizedCandidate == normalizedQuery {
                    matchScore = 200
                } else if normalizedCandidate.hasPrefix(normalizedQuery) {
                    matchScore = 160
                } else if candidateTokens.contains(where: { $0.hasPrefix(normalizedQuery) }) {
                    matchScore = 130
                } else if normalizedCandidate.contains(normalizedQuery) {
                    matchScore = 100
                } else if tokenOverlap > 0 {
                    matchScore = min(90, 50 + (tokenOverlap * 12))
                } else {
                    continue
                }

                let sourceBoost = max(0, 40 - (candidate.sourcePriority * 6))
                let recencyBoost = max(0, 18 - candidate.ordinal)
                rankedSuggestions.append(
                    (text: candidate.text, score: matchScore + sourceBoost + recencyBoost)
                )
            }

            return rankedSuggestions
                .sorted {
                    if $0.score != $1.score {
                        return $0.score > $1.score
                    }
                    return $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending
                }
                .map(\.text)
                .prefix(limit)
                .map { $0 }
        }.value

        if localSuggestions.count >= limit {
            return localSuggestions
        }

        guard includeRemote else { return localSuggestions }

        let accessToken = await authorizedAccessTokenIfAvailable()
        guard let remoteResponse = try? await catalogService.search(query: query, accessToken: accessToken) else {
            return localSuggestions
        }

        var remoteCandidates: [String] = []
        remoteCandidates.append(contentsOf: remoteResponse.songs.prefix(6).map(\.title))
        remoteCandidates.append(contentsOf: remoteResponse.songs.prefix(6).map { "\($0.artist) \($0.title)" })
        remoteCandidates.append(contentsOf: remoteResponse.artists.prefix(4).map(\.title))
        remoteCandidates.append(contentsOf: remoteResponse.albums.prefix(4).map(\.title))
        remoteCandidates.append(contentsOf: remoteResponse.playlists.prefix(4).map(\.title))

        var mergedSuggestions = localSuggestions
        var seenNormalizedSuggestions = Set(localSuggestions.map { SearchTextNormalizer.normalized($0) })

        for candidate in remoteCandidates {
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCandidate = SearchTextNormalizer.normalized(trimmedCandidate)
            guard trimmedCandidate.isEmpty == false else { continue }
            guard normalizedCandidate.isEmpty == false else { continue }
            guard seenNormalizedSuggestions.insert(normalizedCandidate).inserted else { continue }

            let candidateTokens = Set(SearchTextNormalizer.tokens(from: trimmedCandidate))
            guard normalizedCandidate.hasPrefix(normalizedQuery)
                || candidateTokens.contains(where: { $0.hasPrefix(normalizedQuery) })
                || normalizedCandidate.contains(normalizedQuery) else {
                continue
            }

            mergedSuggestions.append(trimmedCandidate)
            if mergedSuggestions.count >= limit {
                break
            }
        }

        return mergedSuggestions
    }

    /// Published entry point used by the search tab and CarPlay. Computes track
    /// suggestions from recent searches, caches them in `searchSuggestionTracks`,
    /// and exposes loading state so observers can show progress.
    @discardableResult
    func refreshSearchSuggestionTracks(limit: Int = 18, forceRefresh: Bool = false) async -> [Track] {
        let suggestionQueries = Array(recentSearches.prefix(6))
        let queryKey = suggestionQueries
            .map { SearchTextNormalizer.normalized($0) }
            .joined(separator: "|")

        guard suggestionQueries.isEmpty == false else {
            searchSuggestionTracks = []
            searchSuggestionQueryKey = ""
            isLoadingSearchSuggestions = false
            refreshCarPlay()
            return []
        }

        if forceRefresh == false,
           searchSuggestionQueryKey == queryKey,
           searchSuggestionTracks.count >= limit {
            return Array(searchSuggestionTracks.prefix(limit))
        }

        isLoadingSearchSuggestions = true
        refreshCarPlay()
        defer {
            isLoadingSearchSuggestions = false
            refreshCarPlay()
        }

        let suggestions = await recentSearchTrackSuggestions(limit: limit)
        searchSuggestionTracks = suggestions
        searchSuggestionQueryKey = queryKey
        refreshCarPlay()
        return suggestions
    }

    func recentSearchTrackSuggestions(limit: Int = 18) async -> [Track] {
        let suggestionQueries = Array(recentSearches.prefix(6))

        var suggestions: [Track] = []
        var seenTrackIDs: Set<String> = []

        if suggestionQueries.isEmpty == false {
            // Scale how deep we read from each query with the requested page size so
            // deeper pagination keeps pulling fresh songs instead of hitting a hard
            // 12-per-query ceiling (which made the shelf "finish" after ~70 tracks).
            let perQueryLimit = max(
                12,
                min(48, Int(ceil(Double(limit) / Double(suggestionQueries.count))) + 8)
            )

            let resultBuckets = await withTaskGroup(of: (Int, [Track]?).self) { group in
                let accessToken = await authorizedAccessTokenIfAvailable()
                for (index, query) in suggestionQueries.enumerated() {
                    guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { continue }

                    group.addTask {
                        do {
                            if let directResponse = try await self.resolveDirectSearchResponse(
                                from: self.resolveSearchInput(from: query),
                                accessToken: accessToken
                            ) {
                                let bucket = Array(directResponse.songs.prefix(perQueryLimit))
                                return (index, bucket.isEmpty ? nil : bucket)
                            }

                            let results = try await self.catalogService.search(query: query, accessToken: accessToken)
                            let bucket = Array(results.songs.prefix(perQueryLimit))
                            return (index, bucket.isEmpty ? nil : bucket)
                        } catch {
                            return (index, nil)
                        }
                    }
                }

                var buckets: [(Int, [Track])] = []
                for await bucket in group {
                    if let tracks = bucket.1 {
                        buckets.append((bucket.0, tracks))
                    }
                }
                return buckets.sorted { $0.0 < $1.0 }.map { $0.1 }
            }

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
        }

        // Keep the shelf flowing once recent-search results run dry (or when there is
        // no search history yet) by topping up with the taste-ranked recommendation
        // pool. This stays on-taste rather than padding with random popular songs.
        if suggestions.count < limit {
            let supplemental = curatedSuggestionTracks(featuredTracks + relatedTracks)
            for track in supplemental {
                guard seenTrackIDs.insert(trackIdentifier(track)).inserted else { continue }
                suggestions.append(track)
                if suggestions.count >= limit { break }
            }
        }

        return curatedSuggestionTracks(suggestions)
    }

    func play(track: Track, queue: [Track]? = nil) {
        // Never start playback for a private/deleted/unavailable item, and strip any
        // such items out of the queue before it is created.
        guard track.isPlayableContent else {
            logger.info("Skipped play for unavailable track: \(track.title)")
            return
        }
        let playableTrack = downloadedPlaybackTrack(for: track)
        let isLocalPlayback = playableTrack.streamURL?.isFileURL == true
        if isLocalPlayback == false,
           DataUsageSettings.shared.canStream(onCellular: NetworkMonitor.shared.isCellular) == false {
            errorMessage = "Streaming on cellular is disabled in Settings. Connect to Wi-Fi or enable cellular streaming."
            return
        }
        let playableQueue = queue?.playableOnly().map { downloadedPlaybackTrack(for: $0) }
        playbackService.play(track: playableTrack, queue: playableQueue)
        AppReviewPrompter.shared.recordPlaybackStarted()
        refreshCarPlay()

        Task { @MainActor [weak self] in
            guard let self, self.isHistoryEnabled else { return }
            self.recordLocalPlayback(for: track)
        }
    }

    func downloadedPlaybackTrack(for track: Track) -> Track {
        downloadService.downloadedRecord(for: track)?.localTrack ?? track
    }

    func prefetchPlayback(for tracks: [Track]) {
        guard allowsPlaybackPrefetch() || isCarPlayConnected else { return }
        playbackService.prefetchStreams(
            for: tracks,
            allowWhileBackgrounded: isCarPlayConnected
        )
    }

    func playNextTrack() {
        playbackService.playNextTrack()
        refreshCarPlay()
    }

    func playPreviousTrack() {
        playbackService.playPreviousTrack()
        refreshCarPlay()
    }

    func refreshLibrary(forceRefresh: Bool = false) async {
        let dataSettings = DataUsageSettings.shared
        let network = NetworkMonitor.shared
        if dataSettings.autoSyncOnWiFiOnly, network.isCellular, !forceRefresh {
            return
        }
        guard isLoadingPlaylists == false else { return }

        if forceRefresh == false,
           hasLoadedLibrary,
           playlists.isEmpty == false || savedCollections.isEmpty == false {
            return
        }

        isLoadingPlaylists = true
        defer {
            isLoadingPlaylists = false
            hasLoadedLibrary = true
        }

        if session != nil, shouldRefreshAuthenticatedLibrary(forceRefresh: forceRefresh) {
            do {
                if let loadedPlaylists = try await performAuthenticatedOperation({ accessToken in
                    try await catalogService.loadPlaylists(accessToken: accessToken)
                }) {
                    lastAuthenticatedLibraryRefreshDate = Date()
                    playlists = mergedLibraryPlaylists(remotePlaylists: loadedPlaylists)
                    trimCachesToValidCollections()
                    if let likedPlaylist = likedSongsPlaylist, isLocalCollectionID(likedPlaylist.id) == false {
                        // Only background-sync liked songs if 30+ minutes have passed since the
                        // last sync. This avoids a full YouTube fetch on every short session.
                        // Pull-to-refresh in LibraryView always forces a fresh sync regardless.
                        let autoSyncCooldown: TimeInterval = 1800
                        let recentlySynced = lastLikedSongsAccountSyncDate.map {
                            Date().timeIntervalSince($0) < autoSyncCooldown
                        } ?? false
                        if recentlySynced == false {
                            libraryStatusMessage = "Syncing all liked songs from YouTube..."
                            startLikedSongsHydration(forceRefresh: true)
                        } else {
                            libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
                        }
                    } else {
                        libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
                    }
                    refreshCarPlay()
                    return
                }
            } catch {
                if await handleAuthorizationFailureIfNeeded(for: error) {
                    libraryStatusMessage = "Your YouTube session expired, so MusicTube is showing your on-device library."
                }
            }
        }

        let preservedLibraryStatus = libraryStatusMessage
        cancelLikedSongsHydration(clearAccountLikes: false)
        playlists = mergedLibraryPlaylists(remotePlaylists: [])
        trimCachesToValidCollections()
        libraryStatusMessage = preservedLibraryStatus ?? libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
        refreshCarPlay()
    }

    func loadPlaylistItems(
        for playlist: Playlist,
        forceRefresh: Bool = false,
        surfaceErrors: Bool = true
    ) async -> [Track] {
        func sanitizedTracks(_ tracks: [Track]) -> [Track] {
            playlist.kind == .likedMusic
                ? tracks.likedSongsOnly()
                : tracks.playableOnly()
        }

        if isSyntheticMixID(playlist.id) {
            if forceRefresh == false, let cached = cachedPlaylistTracks(for: playlist.id) {
                return sanitizedTracks(cached)
            }

            await rebuildSuggestedMixes()
            return sanitizedTracks(cachedPlaylistTracks(for: playlist.id) ?? [])
        }

        if isLocalCollectionID(playlist.id) {
            if forceRefresh == false, let cached = cachedPlaylistTracks(for: playlist.id) {
                return sanitizedTracks(cached)
            }

            _ = mergedLibraryPlaylists(remotePlaylists: playlists.filter { isLocalCollectionID($0.id) == false })
            return sanitizedTracks(cachedPlaylistTracks(for: playlist.id) ?? [])
        }

        if forceRefresh == false,
           let cached = cachedPlaylistTracks(for: playlist.id),
           cached.isEmpty == false {
            return sanitizedTracks(cached)
        }

        do {
            let tracks: [Track]
            if session != nil {
                tracks = try await performAuthenticatedOperation { accessToken in
                    try await self.catalogService.loadPlaylistItems(
                        for: playlist,
                        accessToken: accessToken
                    )
                } ?? []
            } else {
                if playlist.kind == .likedMusic {
                    tracks = locallyVisibleLikedTracks(
                        from: localMusicProfileStore.snapshot(for: currentProfileID)
                    )
                } else {
                    tracks = try await catalogService.loadPlaylistItems(
                        for: playlist,
                        accessToken: nil
                    )
                }
            }

            let playableTracks = sanitizedTracks(tracks)
            if playableTracks.isEmpty {
                playlistCache.removeValue(forKey: playlist.id)
            } else {
                setPlaylistCache(playableTracks, for: playlist.id)
            }
            if surfaceErrors {
                errorMessage = nil
            }
            return playableTracks
        } catch {
            if surfaceErrors && shouldSuppressBackgroundCatalogError(error) == false {
                errorMessage = error.localizedDescription
            }
            if let cached = cachedPlaylistTracks(for: playlist.id), cached.isEmpty == false {
                return sanitizedTracks(cached)
            }
            let localLikedTracks = playlist.kind == .likedMusic
                ? locallyVisibleLikedTracks(from: localMusicProfileStore.snapshot(for: currentProfileID))
                : []
            if localLikedTracks.isEmpty == false {
                let fallbackTracks = deduplicatedTracks(localLikedTracks)
                setPlaylistCache(fallbackTracks, for: playlist.id)
                return fallbackTracks
            }
            return []
        }
    }

    func loadCollectionItems(
        for collection: MusicCollection,
        forceRefresh: Bool = false,
        surfaceErrors: Bool = true
    ) async -> [Track] {
        if forceRefresh == false,
           let cached = cachedCollectionTracks(for: collection.id),
           cached.isEmpty == false {
            return cached
        }

        do {
            let tracks: [Track]
            if session != nil {
                tracks = try await performAuthenticatedOperation { accessToken in
                    try await self.catalogService.loadCollectionItems(
                        for: collection,
                        accessToken: accessToken
                    )
                } ?? []
            } else {
                tracks = try await catalogService.loadCollectionItems(
                    for: collection,
                    accessToken: nil
                )
            }
            let playableTracks = tracks.playableOnly()
            if playableTracks.isEmpty {
                collectionCache.removeValue(forKey: collection.id)
            } else {
                setCollectionCache(playableTracks, for: collection.id)
            }
            if surfaceErrors {
                errorMessage = nil
            }
            return playableTracks
        } catch {
            if surfaceErrors && shouldSuppressBackgroundCatalogError(error) == false {
                errorMessage = error.localizedDescription
            }
            if let cached = cachedCollectionTracks(for: collection.id), cached.isEmpty == false {
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

    func setPlaybackRate(_ rate: Float) {
        playbackService.setPlaybackRate(rate)
    }

    func setSleepTimer(minutes: Int) {
        setSleepTimer(duration: TimeInterval(minutes) * 60)
    }

    /// Internal duration-based entry point keeps the scheduler independently testable
    /// without making production callers convert minutes themselves.
    func setSleepTimer(duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else {
            cancelSleepTimer()
            return
        }

        scheduleSleepTimer(endingAt: Date().addingTimeInterval(duration))
    }

    private func scheduleSleepTimer(endingAt endDate: Date) {
        sleepTimerTask?.cancel()
        sleepTimerEndDate = endDate
        sleepTimerTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                guard self?.sleepTimerEndDate == endDate else { return }

                let remaining = endDate.timeIntervalSinceNow
                if remaining <= 0 {
                    self?.expireSleepTimer(expectedEndDate: endDate)
                    return
                }

                // Recheck the wall-clock deadline periodically. This makes a timer
                // recover correctly after delayed background execution or a clock jump
                // instead of trusting one long relative sleep for the entire interval.
                let nextCheck = min(remaining, 60)
                do {
                    try await Task.sleep(nanoseconds: UInt64(nextCheck * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    /// Reconciles an armed timer after the app becomes active. Internal for regression
    /// tests and lifecycle hooks; normal UI callers only arm or cancel the timer.
    func reconcileSleepTimer(now: Date = Date()) {
        guard let endDate = sleepTimerEndDate else {
            sleepTimerTask?.cancel()
            sleepTimerTask = nil
            return
        }

        if now >= endDate {
            expireSleepTimer(expectedEndDate: endDate)
        } else if sleepTimerTask == nil {
            scheduleSleepTimer(endingAt: endDate)
        }
    }

    private func expireSleepTimer(expectedEndDate: Date) {
        guard sleepTimerEndDate == expectedEndDate else { return }
        sleepTimerTask = nil
        sleepTimerEndDate = nil
        pause()
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

    func resumePendingDownloads() {
        guard pendingDownloadResumeTask == nil else { return }
        guard downloadService.pendingRequestsNeedingProcessing.isEmpty == false else { return }

        // Run download stream resolution at .utility so it never competes with
        // user-initiated playback (which resolves at .high) for CPU.
        pendingDownloadResumeTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingDownloadResumeTask = nil }

            var consecutivePassesWithoutProgress = 0

            while Task.isCancelled == false {
                guard AppPowerBudget.isThermallyConstrained == false else { return }
                let pending = self.downloadService.pendingRequestsNeedingProcessing
                guard pending.isEmpty == false else { return }

                var startedAnyDownloads = false
                let batchSize = AppPowerBudget.downloadResolutionBatchSize(default: self.maxConcurrentBatchStreamResolutions)

                for startIndex in stride(from: 0, to: pending.count, by: batchSize) {
                    guard Task.isCancelled == false else { return }
                    guard AppPowerBudget.isThermallyConstrained == false else { return }
                    let endIndex = min(startIndex + batchSize, pending.count)
                    let batch = Array(pending[startIndex..<endIndex])

                    let batchStartedDownloads = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                        for request in batch {
                            guard !self.downloadService.isDownloaded(request.track),
                                  !self.downloadService.isDownloading(request.track) else { continue }

                            group.addTask { [weak self] in
                                guard let self else { return false }
                                return await self.resolvePendingDownloadRequest(request)
                            }
                        }

                        var didStartAny = false
                        for await didStart in group {
                            didStartAny = didStartAny || didStart
                        }
                        return didStartAny
                    }

                    startedAnyDownloads = startedAnyDownloads || batchStartedDownloads
                    if endIndex < pending.count {
                        try? await Task.sleep(nanoseconds: self.batchDownloadResolveSpacingNanoseconds)
                    }
                }

                if startedAnyDownloads {
                    consecutivePassesWithoutProgress = 0
                    continue
                }

                consecutivePassesWithoutProgress += 1
                guard consecutivePassesWithoutProgress < self.maxPendingDownloadRetryPassesWithoutProgress else {
                    return
                }

                try? await Task.sleep(nanoseconds: self.pendingDownloadRetryDelayNanoseconds)
            }
        }
    }

    /// Background URLSession wakes are short. When iOS wakes the app because the
    /// current batch finished, schedule only enough persisted pending requests to
    /// refill the URLSession slots, then let the background session own the transfer.
    func resumePendingDownloadsForBackgroundEvents() async {
        var retryPasses = 0

        while Task.isCancelled == false {
            guard AppPowerBudget.isThermallyConstrained == false else { return }

            let availableSlots = downloadService.availableRunningDownloadSlots
            guard availableSlots > 0 else { return }

            let pending = Array(downloadService.pendingRequestsNeedingProcessing.prefix(
                min(availableSlots, AppPowerBudget.downloadResolutionBatchSize(default: maxConcurrentBatchStreamResolutions))
            ))
            guard pending.isEmpty == false else { return }

            let startedCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for request in pending {
                    guard !downloadService.isDownloaded(request.track),
                          !downloadService.isDownloading(request.track) else { continue }

                    group.addTask { [weak self] in
                        guard let self else { return false }
                        return await self.resolvePendingDownloadRequest(request)
                    }
                }

                var count = 0
                for await didStart in group where didStart {
                    count += 1
                }
                return count
            }

            if startedCount > 0 {
                return
            }

            retryPasses += 1
            guard retryPasses < maxPendingDownloadRetryPassesWithoutProgress else { return }
            try? await Task.sleep(nanoseconds: pendingDownloadRetryDelayNanoseconds)
        }
    }

    func downloadTrack(
        _ track: Track,
        source: DownloadSource? = nil,
        sourceTrackIndex: Int? = nil
    ) {
        guard !downloadService.isDownloaded(track), !downloadService.isDownloading(track) else { return }
        guard canStartDownloadForCurrentNetwork() else { return }
        requestDownloadNotificationAuthorizationIfNeeded()
        AppReviewPrompter.shared.recordSignificantEvent()

        let requestKey = track.youtubeVideoID ?? track.id
        downloadService.addPendingRequest(PendingDownloadRequest(
            trackKey: requestKey, track: track, source: source, sourceTrackIndex: sourceTrackIndex,
            requestedAt: Date()
        ))

        isDownloadingNowPlaying = true
        Task(priority: .utility) {
            let request = PendingDownloadRequest(
                trackKey: requestKey,
                track: track,
                source: source,
                sourceTrackIndex: sourceTrackIndex,
                requestedAt: Date()
            )
            _ = await resolvePendingDownloadRequest(request, surfaceErrors: true)
            await MainActor.run {
                self.isDownloadingNowPlaying = false
                self.resumePendingDownloads()
            }
        }
    }

    func downloadCollection(_ collection: MusicCollection) {
        let source = DownloadSource(id: collection.id, title: collection.title, kind: collection.kind)
        startSourceDownload(source) { [weak self] in
            guard let self else { return [] }
            return await self.loadCollectionItems(for: collection)
        }
    }

    func downloadPlaylist(_ playlist: Playlist) {
        let source = DownloadSource(
            id: "playlist:\(playlist.id)",
            title: playlist.title,
            kind: .playlist
        )
        startSourceDownload(source) { [weak self] in
            guard let self else { return [] }
            return await self.loadPlaylistItems(for: playlist)
        }
    }

    func downloadTracks(_ tracks: [Track], source: DownloadSource) {
        startSourceDownload(source) { tracks }
    }

    private func startSourceDownload(
        _ source: DownloadSource,
        loadTracks: @escaping @MainActor () async -> [Track]
    ) {
        guard canStartDownloadForCurrentNetwork() else { return }
        requestDownloadNotificationAuthorizationIfNeeded()
        AppReviewPrompter.shared.recordSignificantEvent()
        downloadService.beginPreparingSource(source)

        Task(priority: .utility) { @MainActor [weak self] in
            defer { DownloadService.shared.finishPreparingSource(source) }
            guard let self else { return }
            let tracks = await loadTracks()
            guard Task.isCancelled == false else { return }
            guard self.downloadService.isPreparing(source: source) else { return }
            guard tracks.isEmpty == false else {
                self.errorMessage = "No downloadable songs were found in \(source.title)."
                return
            }
            await self.enqueueDownloads(tracks, source: source)
        }
    }

    private func enqueueDownloads(_ tracks: [Track], source: DownloadSource) async {
        let excludedTrackKeys = Set(tracks.lazy.filter {
            self.downloadService.isDownloaded($0) || self.downloadService.isDownloading($0)
        }.map(\.playbackKey))
        let candidates = DownloadBatchPlanner.candidates(
            from: tracks,
            excluding: excludedTrackKeys
        )
        guard candidates.isEmpty == false else { return }

        for candidate in candidates {
            downloadService.addPendingRequest(PendingDownloadRequest(
                trackKey: candidate.track.playbackKey,
                track: candidate.track,
                source: source,
                sourceTrackIndex: candidate.sourceTrackIndex,
                requestedAt: Date()
            ))
        }

        let batchSize = AppPowerBudget.downloadResolutionBatchSize(default: maxConcurrentBatchStreamResolutions)
        for startIndex in stride(from: 0, to: candidates.count, by: batchSize) {
            guard AppPowerBudget.isThermallyConstrained == false,
                  downloadService.isPreparing(source: source) else { break }
            let endIndex = min(startIndex + batchSize, candidates.count)
            let batch = Array(candidates[startIndex..<endIndex])

            await withTaskGroup(of: Void.self) { group in
                for candidate in batch {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        let request = PendingDownloadRequest(
                            trackKey: candidate.track.playbackKey,
                            track: candidate.track,
                            source: source,
                            sourceTrackIndex: candidate.sourceTrackIndex,
                            requestedAt: Date()
                        )
                        _ = await self.resolvePendingDownloadRequest(request, surfaceErrors: true)
                    }
                }
            }

            if endIndex < candidates.count {
                try? await Task.sleep(nanoseconds: batchDownloadResolveSpacingNanoseconds)
            }
        }

        resumePendingDownloads()
    }

    func requestDownloadNotificationAuthorizationIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: downloadNotificationPromptKey) == false else { return }
        defaults.set(true, forKey: downloadNotificationPromptKey)
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    func canStartDownloadForCurrentNetwork() -> Bool {
        let settings = DataUsageSettings.shared
        guard settings.canDownload(onCellular: NetworkMonitor.shared.isCellular) else {
            errorMessage = settings.dataSaverMode
                ? "Downloads are unavailable while Data Saver Mode is enabled."
                : "Downloads on cellular are disabled in Settings. Connect to Wi-Fi or enable cellular downloads."
            return false
        }
        return true
    }

    func resolvePendingDownloadRequest(
        _ request: PendingDownloadRequest,
        surfaceErrors: Bool = false
    ) async -> Bool {
        guard !downloadService.isDownloaded(request.track),
              !downloadService.isDownloading(request.track) else { return false }

        downloadService.beginResolvingDownload(for: request.track)
        defer { downloadService.finishResolvingDownload(for: request.track) }

        do {
            guard let resolution = try await playbackService.resolveDownloadStreamURL(for: request.track) else {
                return false
            }
            guard downloadService.hasPendingRequest(request) else {
                return false
            }

            // Persist YouTube's authoritative duration with the download. Offline playback
            // reads the local file's container duration, which some YouTube DASH audio
            // streams misreport (often ~2x the real length); storing the known duration
            // here lets the player show the correct length without re-resolving the stream.
            // `mergingMetadata` never overwrites an existing (trusted) metadata duration.
            let trackToDownload = request.track.mergingMetadata(
                duration: resolution.approximateDuration,
                viewCount: nil
            )

            downloadService.startDownload(
                track: trackToDownload,
                streamURL: resolution.url,
                source: request.source,
                sourceTrackIndex: request.sourceTrackIndex
            )
            return true
        } catch {
            if surfaceErrors, errorMessage == nil {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func toggleLike(for track: Track) {
        let shouldLike = likedTrackIDs.contains(trackIdentifier(track)) == false
        applyLocalLikeState(shouldLike, for: track)
        AppReviewPrompter.shared.recordSignificantEvent()
    }

    func likeTrackIfNeeded(_ track: Track) {
        guard likedTrackIDs.contains(trackIdentifier(track)) == false else { return }
        applyLocalLikeState(true, for: track)
    }

    func recommendMoreLike(_ track: Track) {
        recordRecommendationOutcome(for: track, skipped: false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let extra = await self.smartRecommendations(
                limit: 14,
                excluding: Set(self.featuredTracks.map(self.trackIdentifier)),
                focusedTrack: track
            )
            guard extra.isEmpty == false else { return }
            let merged = self.curatedSuggestionTracks(
                self.deduplicatedTracks(extra + self.featuredTracks)
            )
            self.updateHomeContent(featuredTracks: merged)
        }
    }

    func recommendLessLike(_ track: Track) {
        let id = trackIdentifier(track)
        recordRecommendationOutcome(for: track, skipped: true)
        var updated = dislikedTrackIDs
        updated.insert(id)
        dislikedTrackIDs = updated
        UserDefaults.standard.set(Array(updated), forKey: dislikedTrackIDsKey)
        updateHomeContent(
            featuredTracks: featuredTracks.filter { trackIdentifier($0) != id },
            recentTracks: recentTracks.filter { trackIdentifier($0) != id }
        )
    }

    func switchAccount() async {
        await signOut()
        await signIn()
    }

    func toggleTrackSaved(_ track: Track) {
        let shouldSave = isTrackSaved(track) == false
        let _ = localMusicProfileStore.setTrackSaved(shouldSave, for: track, profileID: currentProfileID)
        if shouldSave {
            interactionTracker.registerTrack(track)
            interactionTracker.logSave(trackId: trackIdentifier(track))
            recordRecommendationOutcome(for: track, skipped: false)
        }
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        AppReviewPrompter.shared.recordSignificantEvent()

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
        playlistPickerHost = isPlayerPresented ? .player : .main
        playlistPickerState = .create(seedTrack: track)
    }

    func presentPlaylistCreator() {
        playlistPickerHost = isPlayerPresented ? .player : .main
        playlistPickerState = .create(seedTrack: nil)
    }

    func presentPlaylistSongAdder(for playlist: Playlist) {
        playlistPickerHost = isPlayerPresented ? .player : .main
        playlistPickerState = .add(to: playlist)
    }

    func dismissPlaylistPicker() {
        playlistPickerState = .hidden
        playlistPickerHost = .main
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
        setPlaylistCache(
            deduplicatedTracks([track] + (cachedPlaylistTracks(for: playlist.id) ?? [])),
            for: playlist.id
        )
    }

    @discardableResult
    func createCustomPlaylist(named name: String) -> Bool {
        guard let playlist = localMusicProfileStore.createCustomPlaylist(
            named: name,
            description: "",
            seedTrack: playlistPickerTrack,
            profileID: currentProfileID
        ) else {
            return false
        }

        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        setPlaylistCache(playlist.tracks, for: playlist.id)
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
        var updatedTracks = cachedPlaylistTracks(for: playlist.id) ?? []
        updatedTracks.removeAll { $0.playbackKey == track.playbackKey }
        if updatedTracks.isEmpty {
            playlistCache.removeValue(forKey: playlist.id)
        } else {
            setPlaylistCache(updatedTracks, for: playlist.id)
        }
    }

    func isTrack(_ track: Track, in playlist: Playlist) -> Bool {
        let cachedTracks = cachedPlaylistTracks(for: playlist.id) ?? []
        return cachedTracks.contains { $0.playbackKey == track.playbackKey }
    }

    func searchTracksForPlaylist(_ query: String) async -> [Track] {
        let resolvedInput = resolveSearchInput(from: query)
        let trimmed: String
        switch resolvedInput {
        case .text(let value):
            trimmed = value
        case .playlist(let playlist):
            trimmed = playlist.id
        case .video(let videoID):
            trimmed = videoID
        }

        guard trimmed.isEmpty == false else { return [] }

        do {
            let accessToken = await authorizedAccessTokenIfAvailable()
            if let directResponse = try await resolveDirectSearchResponse(
                from: resolvedInput,
                accessToken: accessToken
            ) {
                return directResponse.songs
            }

            let results = try await catalogService.search(query: trimmed, accessToken: accessToken)
            return results.songs
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func handleIncomingURL(_ url: URL) async {
        // Search-and-play deep link, e.g. from the Share Extension when a song is
        // shared into MusicTube from Shazam: musictube://search?q=<title artist>
        if let query = sharedSearchQuery(from: url) {
            await searchAndPlayFirstResult(query: query)
            return
        }

        guard let sharedVideoID = sharedTrackID(from: url) else { return }

        do {
            let accessToken = await authorizedAccessTokenIfAvailable()
            if let track = try await catalogService.lookupTrack(videoID: sharedVideoID, accessToken: accessToken) {
                searchQuery = "\(track.artist) \(track.title)"
                var response = SearchResponse.empty
                response.trackCategory.items = [track]
                searchResults = response
                play(track: track, queue: [track])
                isPlayerPresented = true
                errorMessage = nil
                return
            }
        } catch {
            logger.error("Failed to open shared track", error: error)
        }

        searchQuery = sharedVideoID
        let response = await search(query: sharedVideoID)
        if let track = response.songs.first {
            play(track: track, queue: response.songs)
            isPlayerPresented = true
        } else {
            errorMessage = "MusicTube couldn't open that shared track."
        }
    }

    /// Parses a `musictube://search?q=…` (or `…/recognize?q=…`) deep link into a
    /// search query. Used by the Share Extension to hand a Shazam'd song to the app.
    func sharedSearchQuery(from url: URL) -> String? {
        guard url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == AppConfig.Sharing.appURLScheme else {
            return nil
        }

        let host = url.host?.lowercased()
        let firstPath = url.pathComponents.first { $0 != "/" && $0.isEmpty == false }?.lowercased()
        let routes: Set<String> = ["search", "recognize", "play"]
        guard (host.map(routes.contains) ?? false) || (firstPath.map(routes.contains) ?? false) else {
            return nil
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let rawValue = queryItems.first(where: { ["q", "query", "song"].contains($0.name.lowercased()) })?.value else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Searches for `query` and starts playback of the best playable match.
    func searchAndPlayFirstResult(query: String) async {
        searchQuery = query
        selectedMainTab = .search
        let response = await search(query: query)
        let playableSongs = response.songs.playableOnly().musicOnly()
        guard let firstSong = playableSongs.first else {
            errorMessage = "MusicTube couldn't find “\(query)”."
            return
        }
        play(track: firstSong, queue: playableSongs)
        isPlayerPresented = true
        errorMessage = nil
    }

    func handleIncomingUserActivity(_ userActivity: NSUserActivity) async {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else {
            return
        }

        await handleIncomingURL(url)
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

        startLikedSongsHydration(forceRefresh: true)
    }

    func restoreSession() async {
        guard !sessionRestoreStarted else { return }
        sessionRestoreStarted = true
        logger.info("Restoring YouTube session from persisted storage")
        if let restored = await authService.restoreSession() {
            applyAuthorizedSession(restored)
            logger.info("Restored persisted YouTube session for user \(restored.user.email)")
        } else {
            logger.info("No persisted YouTube session could be restored")
            authState = .guest
        }

        syncLocalMusicProfileState()
        resumePendingDownloads()

        Task {
            await refreshDashboard()
        }
    }

    func refreshRelatedTracksTask(for track: Track?, forceRefresh: Bool = false) {
        relatedTracksTask?.cancel()
        relatedTracksTask = nil

        guard let track else {
            relatedTracks = []
            relatedTracksContextKey = nil
            loadedRelatedTracksContextKey = nil
            isLoadingRelatedTracks = false
            return
        }

        let contextKey = track.playbackKey
        let localTracks = localRelatedTracks(for: track, limit: 18)
        if relatedTracksContextKey != contextKey {
            relatedTracks = localTracks
            relatedTracksContextKey = contextKey
            loadedRelatedTracksContextKey = nil
        } else if relatedTracks.isEmpty {
            relatedTracks = localTracks
        }

        guard isAppInBackground == false else {
            isLoadingRelatedTracks = false
            refreshCarPlay()
            return
        }

        guard allowsOptionalNetworkWork(forceRefresh: forceRefresh) else {
            isLoadingRelatedTracks = false
            refreshCarPlay()
            return
        }

        isLoadingRelatedTracks = true
        refreshCarPlay()
        relatedTracksTask = Task { [weak self, contextKey] in
            guard let self else { return }
            guard self.allowsOptionalNetworkWork(forceRefresh: forceRefresh) else {
                self.isLoadingRelatedTracks = false
                return
            }
            var remoteTracks = await self.relatedTracks(for: track, limit: 18)
            if remoteTracks.isEmpty {
                remoteTracks = await self.smartRecommendations(
                    limit: 18,
                    excluding: Set([self.trackIdentifier(track)]),
                    focusedTrack: track,
                    forceRefresh: forceRefresh
                )
            }
            guard Task.isCancelled == false else { return }
            guard self.nowPlaying?.playbackKey == contextKey else { return }

            let fallback = self.localRelatedTracks(for: track, limit: 18)
            self.relatedTracks = Array(
                self.deduplicatedTracks(remoteTracks + fallback).prefix(18)
            )
            self.relatedTracksContextKey = contextKey
            self.loadedRelatedTracksContextKey = remoteTracks.isEmpty ? nil : contextKey
            self.isLoadingRelatedTracks = false
            self.refreshCarPlay()
        }
    }

    func cancelRelatedTracksRefresh() {
        relatedTracksTask?.cancel()
        relatedTracksTask = nil
        isLoadingRelatedTracks = false
    }

    /// Ensures the player's "Related" tab has content. The track-change observer
    /// only refreshes related tracks when the now-playing track actually changes,
    /// so opening the player for an already-playing track (or after a background
    /// track change) can leave the shelf empty. The player calls this on appear.
    func refreshRelatedTracksForCurrentTrackIfNeeded() {
        guard let track = nowPlaying else {
            relatedTracks = []
            relatedTracksContextKey = nil
            loadedRelatedTracksContextKey = nil
            return
        }
        guard isLoadingRelatedTracks == false else { return }
        guard loadedRelatedTracksContextKey != track.playbackKey else { return }
        refreshRelatedTracksTask(for: track, forceRefresh: true)
    }

    func retryRelatedTracksForCurrentTrack() {
        guard let track = nowPlaying, isLoadingRelatedTracks == false else { return }
        loadedRelatedTracksContextKey = nil
        refreshRelatedTracksTask(for: track, forceRefresh: true)
    }

    func resetAllLoadedState() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        relatedTracksTask?.cancel()
        relatedTracksTask = nil
        cancelLikedSongsHydration()
        playbackService.stop()
        updateHomeContent(
            featuredTracks: [],
            recentTracks: [],
            suggestedMixes: [],
            statusMessage: nil
        )
        playlists = []
        searchResults = .empty
        searchQuery = ""
        isPlayerPresented = false
        isSearching = false
        isDownloadingNowPlaying = false
        playlistCache = [:]
        collectionCache = [:]
        activeSearchRequestID = nil
        errorMessage = nil
        libraryStatusMessage = nil
        likedTrackIDs = []
        savedTrackIDs = []
        substantiallyListenedTrackIDs = []
        historyTracks = []
        savedCollections = []
        recentSearches = []
        relatedTracks = []
        relatedTracksContextKey = nil
        loadedRelatedTracksContextKey = nil
        hasLoadedHome = false
        hasLoadedLibrary = false
        userPreferenceProfile = .empty
        isPreferenceOnboardingPresented = false
        isRefreshingDashboard = false
        isSyncingLikedSongs = false
        sleepTimerEndDate = nil
        playlistPickerState = .hidden
        isSearchFieldFocused = false
        lastLikedSongsAccountSyncDate = nil
        lastAuthenticatedHomeRefreshDate = nil
        lastAuthenticatedLibraryRefreshDate = nil
        accountLikedTrackIDs = []
        activeListeningSession = nil
        recentRecommendationOutcomes = []
        pendingHomeRecommendations = []
        pendingAICuratedTrackIDs = []
        accumulatedRecommendationSignalCount = 0
        collaborativeRecommendationSeedTrackKeys = []
        locallyUnlikedTrackIDs = []
        dislikedTrackIDs = []
        UserDefaults.standard.removeObject(forKey: locallyUnlikedTrackIDsKey)
        UserDefaults.standard.removeObject(forKey: dislikedTrackIDsKey)
    }

    func clearRemoteState() {
        updateHomeContent(
            featuredTracks: [],
            recentTracks: [],
            suggestedMixes: [],
            statusMessage: nil
        )
        playlists = []
        cancelLikedSongsHydration()
        playlistCache = playlistCache.filter { isLocalCollectionID($0.key) }
        collectionCache.removeAll()
        hasLoadedHome = false
        hasLoadedLibrary = false
        lastLikedSongsAccountSyncDate = nil
        lastAuthenticatedHomeRefreshDate = nil
        lastAuthenticatedLibraryRefreshDate = nil
        collaborativeRecommendationSeedTrackKeys = []
        recentRecommendationOutcomes = []
    }

    func seedHomeFromLocalProfileIfNeeded(forceRefresh: Bool) -> Bool {
        if forceRefresh == false,
           featuredTracks.isEmpty == false || recentTracks.isEmpty == false || suggestedMixes.isEmpty == false {
            return false
        }

        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let behaviorTracks = snapshot.behaviorInsights
            .sorted { lhs, rhs in
                let lhsScore = recommendationAffinityScore(for: lhs)
                let rhsScore = recommendationAffinityScore(for: rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return lhs.lastInteractedAt > rhs.lastInteractedAt
            }
            .map(\.track)
        let pool = curatedSuggestionTracks(
            deduplicatedBySignature(
                behaviorTracks
                + snapshot.topTracks
                + locallyVisibleLikedTracks(from: snapshot)
                + snapshot.savedTracks
                + snapshot.recentTracks
            )
        )

        guard pool.isEmpty == false else { return false }

        let recommendationContext = recommendationSeedContext(focusedTrack: nowPlayingTrack)
        let featured = diversifiedRecommendationTracks(
            pendingHomeRecommendations + pool.filter { recommendationContextCompatible($0, context: recommendationContext) },
            limit: 50
        )
        let featuredIDs = Set(featured.map(trackIdentifier))
        let recent = Array(
            curatedSuggestionTracks(snapshot.recentTracks + pool)
                .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                .prefix(30)
        )

        var mixes: [Playlist] = []
        let quranMixID = "suggested-mix-quran"
        if shouldShowQuranSuggestedMix(from: snapshot) {
            let quranTracks = Array(
                curatedSuggestionTracks(pool)
                    .filter(\.isQuranOrRecitation)
                    .prefix(32)
            )
            if quranTracks.isEmpty == false {
                setPlaylistCache(quranTracks, for: quranMixID)
                mixes.append(
                    Playlist(
                        id: quranMixID,
                        title: "Quran Mix",
                        description: "Recitations suggested for you",
                        artworkURL: quranTracks.first?.artworkURL,
                        itemCount: quranTracks.count,
                        kind: .standard
                    )
                )
            }
        } else {
            playlistCache.removeValue(forKey: quranMixID)
        }

        let songTracks = Array(
            curatedSuggestionTracks(pool)
                .filter { $0.isQuranOrRecitation == false }
                .prefix(32)
        )
        if songTracks.isEmpty == false {
            let mixID = "suggested-mix-1"
            setPlaylistCache(sanitizedSyntheticMixTracks(songTracks, for: mixID), for: mixID)
            mixes.append(
                Playlist(
                    id: mixID,
                    title: "Daily Mix 1",
                    description: "Made from your MusicTube taste profile",
                    artworkURL: songTracks.first?.artworkURL,
                    itemCount: songTracks.count,
                    kind: .standard
                )
            )
        }

        updateHomeContent(
            featuredTracks: featured,
            recentTracks: recent,
            suggestedMixes: mixes,
            statusMessage: nil
        )
        pendingHomeRecommendations = []
        accumulatedRecommendationSignalCount = 0
        scheduleHomeMetadataEnrichment()
        return true
    }

    func buildHomeFromLoadedLibrary() async -> Bool {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let candidateMixes = selectSuggestedMixSourcePlaylists(from: playlists)
        let likedPlaylist = likedSongsPlaylist
        let savedSongsPlaylist = savedSongsPlaylist

        // Capture synchronous fast-path data on the main actor before entering async context.
        let cachedLiked = (likedPlaylist.flatMap { cachedPlaylistTracks(for: $0.id) } ?? [])
            .likedSongsOnly()
        let localLiked = locallyVisibleLikedTracks(from: snapshot)

        async let likedTracksFetch: [Track] = {
            if let likedPlaylist {
                // Use in-memory cache first (warm from a prior sync this session).
                if cachedLiked.isEmpty == false { return cachedLiked }
                // Fall back to locally persisted liked tracks — avoids a full API round-trip
                // on every launch and lets the home page load immediately.
                if localLiked.isEmpty == false { return localLiked }
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
            // Cap the playlistItems.list fanout — this runs as a background fallback, so
            // 4 mix playlists is plenty to seed the feed without piling on Data API calls.
            for playlist in candidateMixes.prefix(4) {
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
        let learnedTracks = allowsOptionalNetworkWork()
            ? await smartRecommendations(
                limit: 30,
                excluding: Set((likedTracks + savedTracks + curatedMixTracks).map(trackIdentifier))
            )
            : []
        let localCatalog = deduplicatedTracks(
            likedTracks + savedTracks + topTracks + recentProfileTracks + curatedMixTracks + learnedTracks
        )
        interactionTracker.registerTracks(localCatalog)

        // "Recommended For You" should surface FRESH songs that match the user's taste,
        // not echo what they already played. Prefer freshly-learned recommendations and
        // drop anything already heard / downloaded / now playing. Familiar tracks are
        // used only as backfill when there aren't enough fresh ones to fill the shelf.
        let knownIDs = alreadyKnownTrackIdentifiers()
        let algorithmicTracks = algorithmicRecommendations(
            from: localCatalog,
            focusedTrack: nowPlayingTrack,
            excluding: knownIDs
        )
        let freshLearned = deduplicatedTracks(algorithmicTracks + learnedTracks)
            .filter { knownIDs.contains(trackIdentifier($0)) == false }

        let freshBackfill = (curatedMixTracks.shuffled() + savedTracks.shuffled() + likedTracks.shuffled())
            .filter { knownIDs.contains(trackIdentifier($0)) == false }

        // Last resort if the user has almost no fresh candidates yet (brand-new library):
        // allow familiar tracks so the shelf is never empty.
        let familiarFallback = topTracks.shuffled() + recentProfileTracks.shuffled()

        let recommendationContext = recommendationSeedContext(focusedTrack: nowPlayingTrack)
        let featuredPool = curatedSuggestionTracks(
            deduplicatedBySignature(
                pendingHomeRecommendations + freshLearned + freshBackfill + familiarFallback
            )
        ).filter { recommendationContextCompatible($0, context: recommendationContext) }

        guard featuredPool.isEmpty == false else { return false }

        let featured = diversifiedRecommendationTracks(featuredPool, limit: 50)
        let featuredIDs = Set(featured.map(trackIdentifier))
        let recent = Array(
            curatedSuggestionTracks(
                deduplicatedBySignature(recentProfileTracks + curatedMixTracks.shuffled() + learnedTracks.shuffled())
            )
                .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                .prefix(30)
        )

        updateHomeContent(
            featuredTracks: featured,
            recentTracks: recent
        )
        pendingHomeRecommendations = []
        accumulatedRecommendationSignalCount = 0
        if allowsOptionalNetworkWork() {
            await rebuildSuggestedMixes()
        }
        scheduleHomeMetadataEnrichment()
        return true
    }

    func buildStarterHome() async -> Bool {
        let starterTracks = await starterRecommendations(limit: 40, excluding: [])
        let blendedPool = deduplicatedTracks(starterTracks)
        guard blendedPool.isEmpty == false else { return false }

        let curatedTracks = curatedSuggestionTracks(blendedPool)
            .filter { $0.isQuranOrRecitation == false && $0.listeningContentContext == .music }
        updateHomeContent(
            featuredTracks: diversifiedRecommendationTracks(curatedTracks, limit: 40),
            recentTracks: Array(curatedTracks.dropFirst(16).prefix(24)),
            suggestedMixes: []
        )
        playlistCache = playlistCache.filter { isSyntheticMixID($0.key) == false }
        scheduleHomeMetadataEnrichment()
        return true
    }

    func shouldRefreshAuthenticatedHome(forceRefresh: Bool) -> Bool {
        guard forceRefresh == false else { return true }
        guard hasLoadedHome else { return true }
        guard featuredTracks.isEmpty == false || recentTracks.isEmpty == false else { return true }
        guard let lastAuthenticatedHomeRefreshDate else { return true }
        return Date().timeIntervalSince(lastAuthenticatedHomeRefreshDate) >= authenticatedCatalogRefreshCooldown
    }

    func shouldRefreshAuthenticatedLibrary(forceRefresh: Bool) -> Bool {
        guard forceRefresh == false else { return true }
        guard hasLoadedLibrary else { return true }
        guard playlists.isEmpty == false || savedCollections.isEmpty == false else { return true }
        guard let lastAuthenticatedLibraryRefreshDate else { return true }
        return Date().timeIntervalSince(lastAuthenticatedLibraryRefreshDate) >= authenticatedCatalogRefreshCooldown
    }

    func isQuotaOrTransientCatalogError(_ error: Error) -> Bool {
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

    func shouldSuppressBackgroundCatalogError(_ error: Error) -> Bool {
        isAuthorizationError(error) || isQuotaOrTransientCatalogError(error)
    }

    func prioritizeLibraryPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let likedPlaylists = playlists.filter { $0.kind == .likedMusic }
        let savedSongs = playlists.filter { $0.kind == .savedSongs }
        let remainingPlaylists = playlists.filter { $0.kind != .likedMusic && $0.kind != .savedSongs }
        return likedPlaylists + savedSongs + remainingPlaylists
    }

    func selectSuggestedMixSourcePlaylists(from playlists: [Playlist], limit: Int = 8) -> [Playlist] {
        let candidates = playlists.suggestedMixCandidates()
        guard candidates.isEmpty == false else { return [] }

        let poolSize = min(candidates.count, max(limit * 2, limit))
        return Array(candidates.prefix(poolSize).shuffled().prefix(limit))
    }

    func randomizedTracks(from tracks: [Track], limit: Int) -> [Track] {
        guard tracks.isEmpty == false else { return [] }
        return Array(tracks.shuffled().prefix(limit))
    }

    func trackIdentifier(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    func locallyVisibleLikedTracks(from snapshot: LocalMusicProfileSnapshot) -> [Track] {
        snapshot.likedTracks
            .likedSongsOnly()
            .filter { locallyUnlikedTrackIDs.contains(trackIdentifier($0)) == false }
    }

    var currentProfileID: String {
        deviceProfileID
    }

    func isSyntheticMixID(_ playlistID: String) -> Bool {
        playlistID.hasPrefix("suggested-mix-")
    }

    func isQuranSyntheticMixID(_ playlistID: String) -> Bool {
        playlistID == "suggested-mix-quran"
    }

    func sanitizedSyntheticMixTracks(_ tracks: [Track], for playlistID: String) -> [Track] {
        let deduplicated = deduplicatedTracks(tracks)
        if isQuranSyntheticMixID(playlistID) {
            return deduplicated.filter(\.isQuranOrRecitation)
        }

        return deduplicated.filter { $0.isQuranOrRecitation == false }
    }

    func isLocalCollectionID(_ playlistID: String) -> Bool {
        playlistID.hasPrefix("local-")
    }

    func isAuthorizationError(_ error: Error) -> Bool {
        if let error = error as? YouTubeAPIService.YouTubeAPIError,
           case .authenticationFailure = error {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("invalid authentication credentials")
            || message.contains("oauth 2")
            || message.contains("login cookie")
            || message.contains("session expired")
            || message.contains("sign in again")
            || message.contains("status 401")
            || message.contains("invalid_grant")
            || message.contains("revoked")
    }

    func syncLocalMusicProfileState() {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        interactionTracker.registerTracks(
            locallyVisibleLikedTracks(from: snapshot)
                + snapshot.savedTracks
                + snapshot.recentTracks
                + snapshot.topTracks
                + snapshot.behaviorInsights.map(\.track)
                + snapshot.customPlaylists.flatMap(\.tracks)
        )
        likedTrackIDs = Set(locallyVisibleLikedTracks(from: snapshot).map(trackIdentifier))
            .union(accountLikedTrackIDs)
            .subtracting(locallyUnlikedTrackIDs)
        savedTrackIDs = Set(snapshot.savedTracks.map(trackIdentifier))
        substantiallyListenedTrackIDs = snapshot.substantiallyListenedTrackIDs
        userPreferenceProfile = snapshot.preferenceProfile
        savedCollections = snapshot.savedCollections
        librarySectionOrder = snapshot.librarySectionOrder
        recentSearches = snapshot.recentSearches
        // Purge private/deleted/unavailable items from persisted history on restore.
        historyTracks = snapshot.recentTracks.playableOnly()
        updatePreferenceOnboardingPresentation()
    }

    func applyPreferenceSnapshot(_ snapshot: LocalMusicProfileSnapshot) {
        userPreferenceProfile = snapshot.preferenceProfile
        updatePreferenceOnboardingPresentation()
        refreshCarPlay()
    }

    func updatePreferenceOnboardingPresentation() {
        isPreferenceOnboardingPresented = authState != .restoring && userPreferenceProfile.hasCompletedOnboarding == false
    }

    func persistLibrarySectionOrder(_ order: [AppLibrarySection]) {
        let normalizedOrder = AppLibrarySection.normalizedOrder(from: order.map(\.rawValue))
        guard normalizedOrder != librarySectionOrder else { return }

        let snapshot = localMusicProfileStore.setLibrarySectionOrder(normalizedOrder, profileID: currentProfileID)
        librarySectionOrder = snapshot.librarySectionOrder
        refreshCarPlay()
    }

    func resolveDirectSearchResponse(
        from resolvedInput: ResolvedSearchInput,
        accessToken: String?
    ) async throws -> SearchResponse? {
        switch resolvedInput {
        case .text:
            return nil

        case .playlist(let playlist):
            let tracks = try await catalogService.loadPlaylistItems(for: playlist, accessToken: accessToken)
            var response = SearchResponse.empty
            response.trackCategory.items = tracks
            response.playlistCategory.items = [directLinkedCollection(for: playlist, tracks: tracks)]
            return response

        case .video(let videoID):
            var response = SearchResponse.empty
            if let track = try await catalogService.lookupTrack(videoID: videoID, accessToken: accessToken) {
                response.trackCategory.items = [track]
            }
            return response
        }
    }

    func resolveSearchInput(from query: String) -> ResolvedSearchInput {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return .text("") }
        guard let url = normalizedYouTubeURL(from: trimmed) else { return .text(trimmed) }

        let pathComponents = url.pathComponents.filter { $0 != "/" && $0.isEmpty == false }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let videoID = queryItems.first(where: { $0.name == "v" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlistID = queryItems.first(where: { $0.name == "list" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = url.host?.lowercased()
        let firstPath = pathComponents.first?.lowercased()

        if host == "youtu.be" || host == "www.youtu.be" {
            if let sharedVideoID = pathComponents.first, sharedVideoID.isEmpty == false {
                return .video(sharedVideoID)
            }
        }

        switch firstPath {
        case "watch":
            if let videoID, videoID.isEmpty == false {
                return .video(videoID)
            }
            if let playlistID, playlistID.isEmpty == false {
                return .playlist(temporaryLinkedPlaylist(id: playlistID))
            }

        case "playlist":
            if let playlistID, playlistID.isEmpty == false {
                return .playlist(temporaryLinkedPlaylist(id: playlistID))
            }

        case "shorts", "embed", "live", "v":
            if pathComponents.count > 1 {
                let directVideoID = pathComponents[1]
                if directVideoID.isEmpty == false {
                    return .video(directVideoID)
                }
            }

        default:
            break
        }

        if let videoID, videoID.isEmpty == false {
            return .video(videoID)
        }

        if let playlistID, playlistID.isEmpty == false {
            return .playlist(temporaryLinkedPlaylist(id: playlistID))
        }

        if let handle = pathComponents.first(where: { $0.hasPrefix("@") }), handle.isEmpty == false {
            return .text(handle)
        }

        return .text(trimmed)
    }

    func sharedTrackID(from url: URL) -> String? {
        let trimmedScheme = url.scheme?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if trimmedScheme == AppConfig.Sharing.appURLScheme,
           let directID = sharedTrackIDFromComponents(
                host: url.host,
                pathComponents: url.pathComponents,
                queryItems: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
           ) {
            return directID
        }

        guard let host = url.host?.lowercased(),
              AppConfig.Sharing.supportedWebHosts.contains(host) else {
            return nil
        }

        return sharedTrackIDFromComponents(
            host: url.host,
            pathComponents: url.pathComponents,
            queryItems: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        )
    }

    func sharedTrackIDFromComponents(
        host: String?,
        pathComponents: [String],
        queryItems: [URLQueryItem]
    ) -> String? {
        let filteredPath = pathComponents.filter { $0 != "/" && $0.isEmpty == false }

        if let queryTrackID = queryItems.first(where: { ["track", "video", "v"].contains($0.name.lowercased()) })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           queryTrackID.isEmpty == false {
            return queryTrackID
        }

        if host?.lowercased() == "track", let firstPath = filteredPath.first {
            let decodedPath = firstPath.removingPercentEncoding ?? firstPath
            let trimmedPath = decodedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedPath.isEmpty ? nil : trimmedPath
        }

        return nil
    }

    func normalizedYouTubeURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let candidate: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            candidate = trimmed
        } else if trimmed.contains("youtube.com") || trimmed.contains("youtu.be") {
            candidate = "https://\(trimmed)"
        } else {
            return nil
        }

        guard let url = URL(string: candidate), let host = url.host?.lowercased() else {
            return nil
        }

        guard host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix(".youtu.be") else {
            return nil
        }

        return url
    }

    func temporaryLinkedPlaylist(id: String) -> Playlist {
        Playlist(
            id: id,
            title: id.hasPrefix("OLAK") ? "Linked Album" : "Linked Playlist",
            description: "",
            artworkURL: nil,
            itemCount: 0,
            kind: .standard
        )
    }

    func directLinkedCollection(for playlist: Playlist, tracks: [Track]) -> MusicCollection {
        let title = playlist.title.isEmpty ? "Linked Playlist" : playlist.title
        let description = playlist.description.isEmpty
            ? "Opened from a YouTube link"
            : playlist.description
        let itemCount = max(playlist.itemCount, tracks.count)
        let kind: MusicCollectionKind = playlist.id.hasPrefix("OLAK") ? .album : .playlist
        let subtitle: String
        if itemCount > 0 {
            subtitle = itemCount == 1 ? "1 track" : "\(itemCount) tracks"
        } else {
            subtitle = kind == .album ? "YouTube album" : "YouTube playlist"
        }

        return MusicCollection(
            sourceID: playlist.id,
            title: title,
            subtitle: subtitle,
            description: description,
            artworkURL: tracks.first?.artworkURL ?? playlist.artworkURL,
            itemCount: itemCount,
            kind: kind,
            queryHint: title
        )
    }

    func refreshLocalLibraryOverlay() {
        playlists = mergedLibraryPlaylists(remotePlaylists: playlists.filter { isLocalCollectionID($0.id) == false })
        trimCachesToValidCollections()
        libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
        refreshCarPlay()
    }

    func trimCachesToValidCollections() {
        let validPlaylistIDs = Set(playlists.map(\.id) + suggestedMixes.map(\.id))
        playlistCache = playlistCache.filter { validPlaylistIDs.contains($0.key) || isSyntheticMixID($0.key) }
        let validCollectionIDs = Set(savedCollections.map(\.id))
        collectionCache = collectionCache.filter { validCollectionIDs.contains($0.key) }
    }

    func handlePlaybackStateTransition(from previousState: PlaybackState, to nextState: PlaybackState) {
        let previousTrack = previousState.nowPlaying
        let nextTrack = nextState.nowPlaying

        if previousTrack != nextTrack || nextState.isPlaying || nextState.isResolvingStream {
            autoplayContinuationTask?.cancel()
            autoplayContinuationTask = nil
        }

        if previousTrack != nextTrack || shouldKeepWatchingPlaybackCompletion(for: nextState) == false {
            playbackCompletionWatchTask?.cancel()
            playbackCompletionWatchTask = nil
        }

        if previousTrack != nextTrack {
            if let previousTrack {
                finalizeListeningSession(for: previousTrack, using: previousState)
            }
            if let nextTrack {
                if isHistoryEnabled {
                    beginListeningSession(for: nextTrack, using: nextState)
                } else {
                    activeListeningSession = nil
                }
            } else {
                activeListeningSession = nil
            }
            return
        }

        guard let nextTrack else {
            autoplayContinuationTask?.cancel()
            autoplayContinuationTask = nil
            activeListeningSession = nil
            return
        }

        if isHistoryEnabled,
           activeListeningSession == nil,
           nextState.isPlaying || nextState.currentTime > 0 {
            beginListeningSession(for: nextTrack, using: nextState)
        } else if isHistoryEnabled == false {
            activeListeningSession = nil
        }

        if let activeListeningSession,
           trackIdentifier(activeListeningSession.track) == trackIdentifier(nextTrack),
           nextState.currentTime + 1 < previousState.currentTime {
            self.activeListeningSession = ActiveListeningSession(
                track: nextTrack,
                startingOffset: nextState.currentTime
            )
        }

        logThirtySecondPlayIfNeeded(for: nextTrack, using: nextState)

        if shouldAttemptAutoplayContinuation(from: previousState, to: nextState, track: nextTrack) {
            scheduleAutoplayContinuation(after: nextTrack)
        }

        if shouldKeepWatchingPlaybackCompletion(for: nextState) {
            schedulePlaybackCompletionWatch(for: nextTrack, observedTime: nextState.currentTime)
        }
    }

    func shouldAttemptAutoplayContinuation(
        from previousState: PlaybackState,
        to nextState: PlaybackState,
        track: Track
    ) -> Bool {
        guard playbackService.repeatMode == .off else { return false }
        guard previousState.isPlaying else { return false }
        guard nextState.isPlaying == false, nextState.isResolvingStream == false else { return false }
        guard nextState.playbackErrorMessage == nil else { return false }
        guard nextState.hasNextTrack == false else { return false }
        guard nextState.duration > 0 else { return false }

        let endThreshold = max(1.5, min(4, nextState.duration * 0.05))
        let didReachNaturalEnd = nextState.currentTime >= nextState.duration - endThreshold
        guard didReachNaturalEnd else { return false }

        if let queueIndex = playbackService.currentQueueIndex,
           queueIndex + 1 < playbackService.currentQueue.count {
            return true
        }

        return autoplayContinuationCandidates(after: track).isEmpty == false
    }

    func scheduleAutoplayContinuation(after track: Track) {
        autoplayContinuationTask?.cancel()
        autoplayContinuationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, Task.isCancelled == false else { return }
            guard let currentTrack = self.playbackState.nowPlaying,
                  self.trackIdentifier(currentTrack) == self.trackIdentifier(track) else { return }
            guard self.playbackState.isPlaying == false,
                  self.playbackState.isResolvingStream == false,
                  self.playbackState.playbackErrorMessage == nil else { return }
            self.attemptAutoplayContinuation(after: track)
        }
    }

    func shouldKeepWatchingPlaybackCompletion(for state: PlaybackState) -> Bool {
        guard playbackService.repeatMode != .one else { return false }
        guard state.nowPlaying != nil else { return false }
        guard state.playbackErrorMessage == nil else { return false }
        guard state.isResolvingStream == false else { return false }
        guard state.duration > 0 else { return false }

        let endThreshold = max(1.5, min(4, state.duration * 0.05))
        return state.currentTime >= state.duration - endThreshold
    }

    func schedulePlaybackCompletionWatch(for track: Track, observedTime: TimeInterval) {
        playbackCompletionWatchTask?.cancel()
        playbackCompletionWatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, Task.isCancelled == false else { return }
            guard let currentTrack = self.playbackState.nowPlaying,
                  self.trackIdentifier(currentTrack) == self.trackIdentifier(track) else { return }
            guard self.playbackState.playbackErrorMessage == nil,
                  self.playbackState.isResolvingStream == false,
                  self.shouldKeepWatchingPlaybackCompletion(for: self.playbackState) else { return }

            let playheadAdvanced = self.playbackState.currentTime > observedTime + 0.2
            guard playheadAdvanced == false else { return }

            self.logger.debug("Playback completion watchdog advancing stalled end-of-track playback")
            self.attemptAutoplayContinuation(after: track)
        }
    }

    func attemptAutoplayContinuation(after track: Track) {
        if let nextQueuedTrack = nextTrackInCurrentQueue(after: track) {
            self.logger.debug("Autoplay advancing to the next queued track")
            self.play(track: nextQueuedTrack.track, queue: nextQueuedTrack.queue)
            return
        }

        if playbackService.repeatMode == .all,
           let firstTrack = playbackService.currentQueue.first,
           playbackService.currentQueue.isEmpty == false {
            self.logger.debug("Autoplay wrapping to the start of the current queue")
            self.play(track: firstTrack, queue: playbackService.currentQueue)
            return
        }

        let candidates = self.autoplayContinuationCandidates(after: track)
        guard let nextTrack = candidates.first else { return }

        self.logger.debug("Autoplay continuing with \(nextTrack.artist) - \(nextTrack.title)")
        self.play(track: nextTrack, queue: candidates)
    }

    func nextTrackInCurrentQueue(after track: Track) -> (track: Track, queue: [Track])? {
        let queue = playbackService.currentQueue
        guard queue.isEmpty == false else { return nil }

        if let queueIndex = playbackService.currentQueueIndex,
           queueIndex >= 0,
           queueIndex < queue.count - 1 {
            return (queue[queueIndex + 1], queue)
        }

        if let matchedIndex = queue.firstIndex(where: { trackIdentifier($0) == trackIdentifier(track) }),
           matchedIndex < queue.count - 1 {
            return (queue[matchedIndex + 1], queue)
        }

        return nil
    }

    func autoplayContinuationCandidates(after track: Track) -> [Track] {
        let currentID = trackIdentifier(track)
        var candidates: [Track] = []

        func append(_ tracks: [Track]) {
            candidates.append(contentsOf: tracks.filter { candidate in
                trackIdentifier(candidate) != currentID
                    && candidate.isQuranOrRecitation == track.isQuranOrRecitation
                    && (track.listeningContentContext == .unknown
                        || candidate.listeningContentContext == track.listeningContentContext)
            })
        }

        if let queueIndex = playbackService.currentQueueIndex,
           queueIndex + 1 < playbackService.currentQueue.count {
            append(Array(playbackService.currentQueue.suffix(from: queueIndex + 1)))
        }

        append(relatedTracks)
        append(homeContent.featuredTracks)
        append(homeContent.recentTracks)
        append(searchResults.songs)
        append(historyTracks)

        return RecommendationDiversityPolicy.diversified(
            curatedSuggestionTracks(deduplicatedBySignature(candidates))
                .filter { dislikedTrackIDs.contains(trackIdentifier($0)) == false },
            recentlyPlayed: recommendationDiversityRecents(),
            recentlyRecommended: recentRecommendationExposures(),
            recommendationExposures: recentRecommendationExposureRecords(),
            limit: 60,
            recentWindow: 60,
            artistGap: 3
        )
    }

    func beginListeningSession(for track: Track, using playbackState: PlaybackState) {
        interactionTracker.registerTrack(track)
        activeListeningSession = ActiveListeningSession(
            track: track,
            startingOffset: max(0, playbackState.currentTime)
        )
    }

    func recordRecommendationOutcome(for track: Track, skipped: Bool) {
        recentRecommendationOutcomes.append(
            RecommendationSessionOutcome(track: track, skipped: skipped, recordedAt: Date())
        )
        if recentRecommendationOutcomes.count > 24 {
            recentRecommendationOutcomes.removeFirst(recentRecommendationOutcomes.count - 24)
        }
        accumulatedRecommendationSignalCount += skipped ? 2 : 1
        refreshRecommendationsFromSessionSignals()
    }

    func refreshRecommendationsFromSessionSignals() {
        guard featuredTracks.isEmpty == false else { return }
        let context = recommendationSeedContext(focusedTrack: nowPlayingTrack)
        let reranked = rankedRecommendationCandidates(
            featuredTracks + recentTracks,
            context: context,
            limit: 60,
            excluding: []
        )
        guard reranked.isEmpty == false, reranked.map(trackIdentifier) != featuredTracks.map(trackIdentifier) else { return }
        pendingHomeRecommendations = reranked
        if accumulatedRecommendationSignalCount >= 4 {
            // Mark remote candidates stale enough for the next presentation refresh;
            // do not publish a new snapshot during the current browsing session.
            lastAuthenticatedHomeRefreshDate = nil
        }
    }

    func refreshRecommendationsFromPreferenceSignals() {
        let context = recommendationSeedContext(focusedTrack: nowPlayingTrack)
        let existingPool = featuredTracks + recentTracks + historyTracks
        if existingPool.isEmpty == false {
            let reranked = rankedRecommendationCandidates(
                existingPool,
                context: context,
                limit: max(40, featuredTracks.count),
                excluding: []
            )
            if reranked.isEmpty == false {
                updateHomeContent(featuredTracks: reranked)
            }
        }

        if featuredTracks.isEmpty || homeStatusMessage != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshHome(forceRefresh: false)
            }
        }
        refreshCarPlay()
    }

    func finalizeListeningSession(for track: Track, using playbackState: PlaybackState) {
        guard let session = activeListeningSession else { return }
        guard trackIdentifier(session.track) == trackIdentifier(track) else { return }

        let listenedSeconds = max(0, playbackState.currentTime - session.startingOffset)
        self.activeListeningSession = nil

        guard isHistoryEnabled else { return }
        guard listenedSeconds > 0 else { return }

        let resolvedDuration = playbackState.duration > 0
            ? playbackState.duration
            : (track.duration ?? playbackState.nowPlaying?.duration ?? 0)
        let skipThreshold = resolvedDuration > 0
            ? min(30, max(10, resolvedDuration * 0.35))
            : 20
        let wasSkipped = listenedSeconds < skipThreshold
        let identifier = trackIdentifier(track)
        if wasSkipped, listenedSeconds < 30 {
            interactionTracker.logSkip(trackId: identifier)
            recordRecommendationOutcome(for: track, skipped: true)
        } else if listenedSeconds >= 30, session.didLogThirtySecondPlay == false {
            interactionTracker.logCompletePlay(trackId: identifier)
            recordRecommendationOutcome(for: track, skipped: false)
        }

        _ = localMusicProfileStore.recordListeningBehavior(
            for: track,
            listenedSeconds: listenedSeconds,
            trackDuration: resolvedDuration > 0 ? resolvedDuration : nil,
            skipped: wasSkipped,
            profileID: currentProfileID
        )
        syncLocalMusicProfileState()
    }

    func logThirtySecondPlayIfNeeded(for track: Track, using playbackState: PlaybackState) {
        guard isHistoryEnabled else { return }
        guard var session = activeListeningSession else { return }
        guard trackIdentifier(session.track) == trackIdentifier(track) else { return }
        guard session.didLogThirtySecondPlay == false else { return }

        let listenedSeconds = max(0, playbackState.currentTime - session.startingOffset)
        guard listenedSeconds >= 30 else { return }

        interactionTracker.logCompletePlay(trackId: trackIdentifier(track))
        recordRecommendationOutcome(for: track, skipped: false)
        session.didLogThirtySecondPlay = true
        activeListeningSession = session
    }

    func recordLocalPlayback(for track: Track) {
        _ = localMusicProfileStore.recordPlayback(of: track, for: currentProfileID)
        syncLocalMusicProfileState()
        // Record immediately, but keep the visible feed immutable. Recency/fatigue is
        // applied when the next recommendation generation is intentionally committed.
        refreshLocalLibraryOverlay()

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Avoid rebuilding Home on every play; that causes visible list "reload" jitter.
            // Rehydrate only when recommendations are genuinely empty.
            if self.featuredTracks.isEmpty {
                _ = await self.buildHomeFromLoadedLibrary()
                self.refreshCarPlay()
            }
        }
    }

    func mergedLibraryPlaylists(remotePlaylists: [Playlist]) -> [Playlist] {
        let remoteCollections = remotePlaylists.filter { isLocalCollectionID($0.id) == false }
        let hasRemoteLikedSongs = remoteCollections.contains(where: { $0.kind == .likedMusic })
        let localCollections = buildLocalProfilePlaylists(includeLikedSongs: hasRemoteLikedSongs == false)

        // YouTube's playlist-list API returns an itemCount from playlist metadata, which is
        // often stale or lower than the real count (it doesn't include local-only liked tracks).
        // When we have a higher count from a previous full hydration (stored in playlistCache or
        // the local snapshot), keep that larger number so the UI doesn't visibly drop mid-session.
        let patchedRemote: [Playlist] = remoteCollections.map { playlist in
            guard playlist.kind == .likedMusic else { return playlist }
            let cachedCount = cachedPlaylistTracks(for: playlist.id)?.count
            let localCount = locallyVisibleLikedTracks(from: localMusicProfileStore.snapshot(for: currentProfileID)).count
            let bestCount = max(playlist.itemCount, cachedCount ?? 0, localCount)
            guard bestCount > playlist.itemCount else { return playlist }
            return Playlist(
                id: playlist.id,
                title: playlist.title,
                description: playlist.description,
                artworkURL: playlist.artworkURL,
                itemCount: bestCount,
                kind: playlist.kind
            )
        }

        return prioritizeLibraryPlaylists(patchedRemote + localCollections)
    }

    func buildLocalProfilePlaylists(includeLikedSongs: Bool) -> [Playlist] {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)

        var collections: [Playlist] = []

        let visibleLikedTracks = locallyVisibleLikedTracks(from: snapshot)
        if includeLikedSongs, visibleLikedTracks.isEmpty == false {
            let likedTracks = visibleLikedTracks
            setPlaylistCache(likedTracks, for: localLikedPlaylistID)
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
            setPlaylistCache(savedTracks, for: localSavedSongsPlaylistID)
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
            setPlaylistCache(customPlaylist.tracks, for: customPlaylist.id)
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
            setPlaylistCache(replayTracks, for: localReplayMixPlaylistID)
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

        let favoriteTracks = Array(deduplicatedTracks(snapshot.savedTracks + visibleLikedTracks + snapshot.topTracks).prefix(60))
        if favoriteTracks.isEmpty == false {
            setPlaylistCache(favoriteTracks, for: localFavoritesMixPlaylistID)
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

    func libraryStatusMessageText(for playlists: [Playlist], savedCollections: [MusicCollection]) -> String? {
        if playlists.isEmpty && savedCollections.isEmpty {
            return "Save songs, playlists, albums, and artists to start building your library."
        }

        if isYouTubeConnected == false {
            return "Guest mode keeps your MusicTube library and playlists on this device."
        }

        return nil
    }

    func hydrateLikedSongsPlaylistIfNeeded(forceRefresh: Bool) async {
        guard let likedPlaylist = likedSongsPlaylist else {
            accountLikedTrackIDs = []
            syncLocalMusicProfileState()
            return
        }

        let tracks = await loadPlaylistItems(
            for: likedPlaylist,
            forceRefresh: forceRefresh,
            surfaceErrors: false
        )
        let accountTracks = tracks
            .likedSongsOnly()
            .filter { locallyUnlikedTrackIDs.contains(trackIdentifier($0)) == false }
        var resolvedTracks = accountTracks
        var profileSnapshot = localMusicProfileStore.snapshot(for: currentProfileID)

        if isLocalCollectionID(likedPlaylist.id) == false {
            profileSnapshot = localMusicProfileStore.mergeLikedTracks(
                accountTracks,
                profileID: currentProfileID
            )
            accountLikedTrackIDs = Set(accountTracks.map(trackIdentifier))
            resolvedTracks = deduplicatedTracks(
                accountTracks + profileSnapshot.likedTracks.likedSongsOnly()
            )
                .filter { locallyUnlikedTrackIDs.contains(trackIdentifier($0)) == false }
            if resolvedTracks.isEmpty {
                playlistCache.removeValue(forKey: likedPlaylist.id)
            } else {
                setPlaylistCache(resolvedTracks, for: likedPlaylist.id)
            }
        } else {
            accountLikedTrackIDs = []
        }

        likedTrackIDs = Set(
            locallyVisibleLikedTracks(from: profileSnapshot)
                .map(trackIdentifier)
        )
            .union(accountLikedTrackIDs)
            .subtracting(locallyUnlikedTrackIDs)

        if let playlistIndex = playlists.firstIndex(where: { $0.id == likedPlaylist.id }) {
            var updatedPlaylists = playlists
            updatedPlaylists[playlistIndex] = Playlist(
                id: likedPlaylist.id,
                title: likedPlaylist.title,
                description: likedPlaylist.description,
                artworkURL: resolvedTracks.first?.artworkURL ?? likedPlaylist.artworkURL,
                itemCount: resolvedTracks.count,
                kind: likedPlaylist.kind
            )
            playlists = updatedPlaylists
        }
    }

    func startLikedSongsHydration(forceRefresh: Bool) {
        cancelLikedSongsHydration(clearAccountLikes: false)

        guard let likedPlaylist = likedSongsPlaylist,
              isLocalCollectionID(likedPlaylist.id) == false,
              session?.accessToken != nil else {
            accountLikedTrackIDs = []
            syncLocalMusicProfileState()
            libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
            return
        }

        isSyncingLikedSongs = true
        libraryStatusMessage = "Syncing all liked songs from YouTube..."
        Task { await NetworkLogger.shared.recordSyncEvent(description: "liked-songs-hydration force=\(forceRefresh)") }

        likedSongsHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.hydrateLikedSongsPlaylistIfNeeded(forceRefresh: forceRefresh)
            guard Task.isCancelled == false else { return }
            self.lastLikedSongsAccountSyncDate = Date()
            self.isSyncingLikedSongs = false
            self.libraryStatusMessage = self.libraryStatusMessageText(for: self.playlists, savedCollections: self.savedCollections)
            self.refreshCarPlay()
        }
    }

    func cancelLikedSongsHydration(clearAccountLikes: Bool = true) {
        likedSongsHydrationTask?.cancel()
        likedSongsHydrationTask = nil
        isSyncingLikedSongs = false
        if clearAccountLikes {
            accountLikedTrackIDs = []
            syncLocalMusicProfileState()
        }
    }

    func rebuildSuggestedMixes() async {
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

        let likedTracks = curatedSuggestionTracks(
            (await likedFetch).filter { locallyUnlikedTrackIDs.contains(trackIdentifier($0)) == false }
        )
        let localProfileSnapshot = localMusicProfileStore.snapshot(for: currentProfileID)

        var songSourcePools: [[Track]] = []
        var quranSourcePools: [[Track]] = []

        func appendSeparatedMixSource(_ tracks: [Track]) {
            let curatedTracks = curatedSuggestionTracks(deduplicatedTracks(tracks))
            let quranTracks = curatedTracks.filter(\.isQuranOrRecitation)
            let songTracks = curatedTracks.filter { $0.isQuranOrRecitation == false }

            if songTracks.isEmpty == false {
                songSourcePools.append(songTracks)
            }
            if quranTracks.isEmpty == false {
                quranSourcePools.append(quranTracks)
            }
        }

        if featuredTracks.isEmpty == false || recentTracks.isEmpty == false {
            appendSeparatedMixSource(featuredTracks.shuffled() + recentTracks.shuffled())
        }
        if likedTracks.isEmpty == false {
            appendSeparatedMixSource(likedTracks.shuffled() + featuredTracks.shuffled())
        }

        for tracks in playlistFetches where tracks.isEmpty == false {
            appendSeparatedMixSource(tracks.shuffled() + recentTracks.shuffled())
        }

        let mixTitles = [
            "Daily Mix 1",
            "Daily Mix 2",
            "Replay Mix",
            "Discovery Mix",
            "Favorites Mix",
            "Late Night Mix"
        ]

        var mixes = Array(songSourcePools.prefix(mixTitles.count).enumerated()).compactMap { index, pool -> Playlist? in
            let tracks = Array(
                curatedSuggestionTracks(deduplicatedTracks(pool))
                    .filter { $0.isQuranOrRecitation == false }
                    .prefix(32)
            )
            guard tracks.isEmpty == false else { return nil }

            let mixID = "suggested-mix-\(index + 1)"
            setPlaylistCache(sanitizedSyntheticMixTracks(tracks, for: mixID), for: mixID)

            return Playlist(
                id: mixID,
                title: mixTitles[index],
                description: "Made for you",
                artworkURL: tracks.first?.artworkURL,
                itemCount: tracks.count,
                kind: .standard
            )
        }

        let quranMixID = "suggested-mix-quran"
        if shouldShowQuranSuggestedMix(from: localProfileSnapshot) {
            let personalQuranTracks = curatedSuggestionTracks(
                localProfileSnapshot.behaviorInsights
                    .sorted {
                        if $0.totalListenedDuration != $1.totalListenedDuration {
                            return $0.totalListenedDuration > $1.totalListenedDuration
                        }
                        return $0.lastInteractedAt > $1.lastInteractedAt
                    }
                    .map(\.track)
                + locallyVisibleLikedTracks(from: localProfileSnapshot)
                + localProfileSnapshot.savedTracks
            )
            .filter(\.isQuranOrRecitation)
            let quranTracks = Array(
                deduplicatedTracks(personalQuranTracks + quranSourcePools.flatMap { $0 })
                    .filter(\.isQuranOrRecitation)
                    .prefix(32)
            )

            guard quranTracks.isEmpty == false else {
                playlistCache.removeValue(forKey: quranMixID)
                updateHomeContent(suggestedMixes: mixes)
                return
            }

            setPlaylistCache(quranTracks, for: quranMixID)
            let quranMix = Playlist(
                id: quranMixID,
                title: "Quran Mix",
                description: "Recitations suggested for you",
                artworkURL: quranTracks.first?.artworkURL,
                itemCount: quranTracks.count,
                kind: .standard
            )

            mixes = [quranMix] + mixes
        } else {
            playlistCache.removeValue(forKey: quranMixID)
        }

        updateHomeContent(suggestedMixes: mixes)
    }

    func shouldShowQuranSuggestedMix(from snapshot: LocalMusicProfileSnapshot) -> Bool {
        snapshot.behaviorInsights.contains { insight in
            guard insight.track.isQuranOrRecitation else { return false }
            return insight.totalListenedDuration >= 60 || insight.averageListenRatio >= 0.2
        }
    }

    func applyLocalLikeState(_ isLiked: Bool, for track: Track) {
        guard isLiked == false || track.isEligibleForLikedSongs else { return }
        let identifier = trackIdentifier(track)
        if isLiked {
            locallyUnlikedTrackIDs.remove(identifier)
        } else {
            locallyUnlikedTrackIDs.insert(identifier)
            accountLikedTrackIDs.remove(identifier)
        }
        UserDefaults.standard.set(Array(locallyUnlikedTrackIDs), forKey: locallyUnlikedTrackIDsKey)

        _ = localMusicProfileStore.setLike(isLiked, for: track, profileID: currentProfileID)
        if isLiked {
            interactionTracker.registerTrack(track)
            interactionTracker.logSave(trackId: identifier)
            recordRecommendationOutcome(for: track, skipped: false)
        }
        syncLocalMusicProfileState()
        updateLikedSongsPlaylistCache(for: track, isLiked: isLiked)
        refreshLocalLibraryOverlay()
    }

    func updateLikedSongsPlaylistCache(for track: Track, isLiked: Bool) {
        guard let likedPlaylist = likedSongsPlaylist else { return }

        let playlistID = likedPlaylist.id
        let identifier = trackIdentifier(track)
        let cachedTracks = cachedPlaylistTracks(for: playlistID) ?? []
        let wasPresent = cachedTracks.contains { trackIdentifier($0) == identifier }

        var updatedTracks = cachedTracks.filter { trackIdentifier($0) != identifier }
        if isLiked {
            updatedTracks.insert(track, at: 0)
        }
        updatedTracks = deduplicatedTracks(updatedTracks.likedSongsOnly())

        if updatedTracks.isEmpty {
            playlistCache.removeValue(forKey: playlistID)
        } else {
            setPlaylistCache(updatedTracks, for: playlistID)
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
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = Playlist(
            id: currentPlaylist.id,
            title: currentPlaylist.title,
            description: currentPlaylist.description,
            artworkURL: updatedTracks.first?.artworkURL ?? currentPlaylist.artworkURL,
            itemCount: max(currentPlaylist.itemCount + countDelta, updatedTracks.count),
            kind: currentPlaylist.kind
        )
        playlists = updatedPlaylists
    }

    func orderedUniqueQueries(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            let key = SearchTextNormalizer.normalized(trimmed)
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

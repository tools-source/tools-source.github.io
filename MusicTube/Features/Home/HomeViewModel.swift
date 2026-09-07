import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var snapshot: HomeSnapshot = .empty

    private struct PlaybackSummary: Equatable {
        let nowPlayingKey: String?
        let isPlaying: Bool
    }

    private let appState: AppState
    private let playback: PlaybackService
    private var visibleRecommendationCount = 12
    private var recordedRecommendationSignatures: Set<String> = []
    private var pendingRecommendationImpressions: [String: Track] = [:]
    private var recommendationImpressionTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        self.playback = appState.playbackEngine
        observeRelevantState()
        rebuildSnapshot()
    }

    func appear() async {
        guard appState.hasLoadedHome == false,
              appState.isLoading == false,
              appState.isLoadingPlaylists == false else { return }
        await appState.refreshDashboard()
    }

    func refresh() async {
        await appState.refreshDashboard(forceRefresh: true)
        visibleRecommendationCount = 12
        rebuildSnapshot()
    }

    func play(_ track: Track, queue: [Track]) {
        appState.play(track: track, queue: queue)
    }

    func playContinueListening(_ track: Track) {
        let queue = appState.playbackEngine.currentQueue
        appState.play(
            track: track,
            queue: queue.isEmpty ? snapshot.continueListening : queue
        )
    }

    func togglePlayback() {
        appState.togglePlayback()
    }

    func playFreshMix() {
        let queue = recommendationQueue
        guard let first = queue.first else { return }
        play(first, queue: queue)
    }

    func surpriseMe() {
        let queue = recommendationQueue.shuffled()
        guard let first = queue.first else { return }
        play(first, queue: queue)
    }

    func openSearch() {
        appState.selectedMainTab = .search
    }

    func openLibrary() {
        appState.selectedMainTab = .library
    }

    func openDownloads() {
        appState.selectedMainTab = .downloads
    }

    func recommendMoreLike(_ track: Track) {
        appState.recommendMoreLike(track)
    }

    func recommendLessLike(_ track: Track) {
        appState.recommendLessLike(track)
    }

    func recommendationAppeared(_ item: IndexedTrackPresentation) {
        recordRecommendationImpressionIfNeeded(item.track)
        guard item.index >= visibleRecommendationCount - 2 else { return }
        if visibleRecommendationCount < appState.featuredTracks.count {
            visibleRecommendationCount = min(
                visibleRecommendationCount + AppConfig.Search.visibleSongPageSize,
                appState.featuredTracks.count
            )
            rebuildSnapshot()
        } else if appState.isLoadingMoreRecommendations == false {
            Task { [weak self] in
                await self?.appState.loadMoreRecommendedTracksIfNeeded()
            }
        }
    }

    func spotlightAppeared() {
        guard let track = snapshot.spotlightTrack else { return }
        recordRecommendationImpressionIfNeeded(track)
    }

    private func recordRecommendationImpressionIfNeeded(_ track: Track) {
        let signature = RecommendationTrackIdentity.contentSignature(for: track)
        guard recordedRecommendationSignatures.insert(signature).inserted else { return }
        pendingRecommendationImpressions[signature] = track
        guard recommendationImpressionTask == nil else { return }
        recommendationImpressionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            self?.flushRecommendationImpressions()
        }
    }

    private func flushRecommendationImpressions() {
        recommendationImpressionTask = nil
        let tracks = Array(pendingRecommendationImpressions.values)
        pendingRecommendationImpressions.removeAll(keepingCapacity: true)
        guard tracks.isEmpty == false else { return }
        appState.recordRecommendationImpressions(tracks)
    }

    private func rebuildSnapshot() {
        let playbackState = playback.liveState
        let currentQueue = playback.currentQueue
        let continueListening: [Track]
        if playbackState.nowPlaying != nil, currentQueue.isEmpty == false {
            continueListening = Array(currentQueue.prefix(12))
        } else {
            continueListening = Array(appState.historyTracks.prefix(12))
        }

        let visibleRecommendations = Array(appState.featuredTracks.prefix(visibleRecommendationCount))
        let spotlightTrack = visibleRecommendations.first
        let recommendations = visibleRecommendations
            .dropFirst()
            .enumerated()
            .map { IndexedTrackPresentation(index: $0.offset + 1, track: $0.element) }
        let recommendationIDs = Set(recommendations.map { $0.track.playbackKey })
        let contextual = appState.relatedTracks.isEmpty
            ? appState.recentTracks.filter { recommendationIDs.contains($0.playbackKey) == false }
            : appState.relatedTracks

        let nextSnapshot = HomeSnapshot(
            spotlightTrack: spotlightTrack,
            continueListening: continueListening,
            madeForYou: recommendations,
            recentlyPlayed: Array(appState.historyTracks.prefix(12)),
            mixes: Array(appState.suggestedMixes.prefix(10)),
            contextualTracks: Array(contextual.prefix(8)),
            statusMessage: appState.homeStatusMessage,
            recommendationBlurb: appState.recommendationBlurb,
            recommendationGenerationID: appState.homeContent.recommendationGenerationID,
            nowPlayingKey: playbackState.nowPlaying?.playbackKey,
            isPlaying: playbackState.isPlaying,
            isLoading: appState.isLoading || appState.isLoadingMoreRecommendations,
            hasLoaded: appState.hasLoadedHome,
            displayName: appState.user?.name.components(separatedBy: " ").first
        )
        guard nextSnapshot != snapshot else { return }
        if nextSnapshot.recommendationGenerationID != snapshot.recommendationGenerationID {
            recommendationImpressionTask?.cancel()
            recommendationImpressionTask = nil
            recordedRecommendationSignatures.removeAll(keepingCapacity: true)
            pendingRecommendationImpressions.removeAll(keepingCapacity: true)
        }
        snapshot = nextSnapshot
    }

    private var recommendationQueue: [Track] {
        let tracks = [snapshot.spotlightTrack].compactMap { $0 } + snapshot.madeForYou.map(\.track)
        return tracks.isEmpty ? snapshot.continueListening : tracks
    }

    // Every subscription here rebuilds the snapshot by re-reading `AppState` /
    // `PlaybackService`, so each one hops to the next main-queue turn — see
    // `receiveAfterStateCommit()`. The hop sits after `removeDuplicates()` so
    // high-frequency playback ticks are filtered out before it.
    private func observeRelevantState() {
        appState.$homeContent
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$historyTracks
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$relatedTracks
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        playback.$state
            .map {
                PlaybackSummary(
                    nowPlayingKey: $0.nowPlaying?.playbackKey,
                    isPlaying: $0.isPlaying
                )
            }
            .removeDuplicates()
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        playback.$currentQueue
            .map { $0.map(\.playbackKey) }
            .removeDuplicates()
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$recommendationBlurb
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$isLoading
            .combineLatest(appState.$isLoadingMoreRecommendations)
            .receiveAfterStateCommit()
            .sink { [weak self] _, _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$hasLoadedHome
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$user
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
    }
}

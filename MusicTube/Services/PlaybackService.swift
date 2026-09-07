import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

struct PlaybackState: Equatable, Sendable {
    var nowPlaying: Track?
    var isPlaying = false
    var isResolvingStream = false
    var playbackErrorMessage: String?
    var hasNextTrack = false
    var hasPreviousTrack = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var bufferedTime: TimeInterval = 0
    var isBufferingPlayback = false

    static let idle = PlaybackState()
}

struct PlaybackRecoveryBudget: Equatable, Sendable {
    private(set) var attempts = 0
    let maximumAttempts: Int

    init(maximumAttempts: Int = 1) {
        self.maximumAttempts = max(0, maximumAttempts)
    }

    mutating func consumeIfAvailable() -> Bool {
        guard attempts < maximumAttempts else { return false }
        attempts += 1
        return true
    }

    mutating func reset() {
        attempts = 0
    }
}

@MainActor
final class PlaybackService: NSObject, ObservableObject, PlaybackControlling {
    private let logger: any AppLogging

    private enum BufferingPolicy {
        static let startupForwardBufferDuration = AppConfig.Playback.startupForwardBufferDuration
        static let steadyStateForwardBufferDuration = AppConfig.Playback.steadyStateForwardBufferDuration
        static let progressiveFallbackWaitTimeoutNanoseconds = AppConfig.Playback.progressiveFallbackWaitTimeoutNanoseconds
        static let startupWaitTimeoutNanoseconds = AppConfig.Playback.startupWaitTimeoutNanoseconds
    }

    private struct StreamResolutionResult: Sendable {
        let urls: [URL]
        let approximateDuration: TimeInterval?
    }

    private enum StreamResolutionAttempt: Sendable {
        case success(StreamResolutionResult)
        case failure
        case timedOut
    }

    private struct StreamPrefetch {
        let id: UUID
        let usesRemoteFallback: Bool
        let task: Task<[URL], Never>
    }

    /// Picks the duration that should govern playback. A track duration comes from
    /// YouTube's video metadata / visible length and must win over an audio-only
    /// container duration, since some DASH files advertise padded timing that extends
    /// well beyond the audible song.
    nonisolated static func preferredAuthoritativeDuration(
        trackDuration: TimeInterval?,
        streamDurations: [TimeInterval] = [],
        streamURLs: [URL] = []
    ) -> TimeInterval? {
        func validDuration(_ value: TimeInterval?) -> TimeInterval? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }

        if let trackDuration = validDuration(trackDuration) {
            return trackDuration
        }

        if let extractedDuration = streamDurations.lazy.compactMap(validDuration).first {
            return extractedDuration
        }

        return streamURLs.lazy.compactMap(durationFromStreamURL).first
    }

    /// Remote extraction does not always include `approxDurationMs`, but Google Video
    /// URLs commonly carry the same value in their `dur` query item. Reading it avoids
    /// falling back to AVFoundation's occasionally inflated DASH container duration.
    nonisolated static func durationFromStreamURL(_ url: URL) -> TimeInterval? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawValue = components.queryItems?.first(where: { $0.name == "dur" })?.value,
              let duration = TimeInterval(rawValue),
              duration.isFinite,
              duration > 0 else {
            return nil
        }
        return duration
    }

    // Interactive playback is latency-sensitive, especially from CarPlay where the
    // app is normally backgrounded. The remote extractor avoids initializing the
    // on-device JavaScript solver for every uncached selection; local extraction
    // remains the fallback when the service is unavailable.
    nonisolated static let playbackExtractionMethods: [YouTube.ExtractionMethod] = [.remote, .local]

    enum RepeatMode: String, CaseIterable, Sendable {
        case off, one, all
    }

    @Published private(set) var state: PlaybackState = .idle
    private(set) var nowPlaying: Track?
    private(set) var isPlaying = false
    private(set) var isResolvingStream = false
    private(set) var playbackErrorMessage: String?
    private(set) var hasNextTrack = false
    private(set) var hasPreviousTrack = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0
    private(set) var isBufferingPlayback = false
    @Published var shuffleMode: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var playbackRate: Float = 1.0
    @Published private(set) var currentQueue: [Track] = []
    @Published private(set) var currentQueueIndex: Int?

    /// Playback truth as of *right now*, assembled from the eagerly-updated mirrors
    /// above rather than from the published `state` snapshot.
    ///
    /// `@Published` emits from `willSet`, so a subscriber to `$state` that reads
    /// `state` back inside its `sink` is handed the *pre-change* value. Anything that
    /// needs the real state at notification time must read this instead — otherwise
    /// the value it renders lags one event behind.
    var liveState: PlaybackState {
        PlaybackState(
            nowPlaying: nowPlaying,
            isPlaying: isPlaying,
            isResolvingStream: isResolvingStream,
            playbackErrorMessage: playbackErrorMessage,
            hasNextTrack: hasNextTrack,
            hasPreviousTrack: hasPreviousTrack,
            currentTime: currentTime,
            duration: duration,
            bufferedTime: bufferedTime,
            isBufferingPlayback: isBufferingPlayback
        )
    }

    private var originalQueue: [Track] = []

    private var player: AVPlayer?
    private var activeStreamURL: URL?
    private var activeStreamLoader: BoundedHTTPStreamLoader?
    private var playbackObservation: NSKeyValueObservation?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var playerItemDurationObservation: NSKeyValueObservation?
    private var playerItemBufferedTimeObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var playbackStartupBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var playbackStartupTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?
    private var timeObserverToken: Any?
    private var boundaryEndObserverToken: Any?
    private var playbackEndWatchdogTask: Task<Void, Never>?
    private var playbackCompletionMonitorTask: Task<Void, Never>?
    private var lastHandledPlaybackEndKey: String?
    private var lastHandledPlaybackEndDate = Date.distantPast
    private var lastObservedTime: TimeInterval = 0
    private var pendingSeekTime: TimeInterval? = nil
    /// AVPlayer can transiently report `.paused` while it switches to a distant HLS
    /// segment. Keep the user's pre-seek play intent separate from that transport
    /// state so the seek does not turn into a permanent pause.
    private var isSeekingPlayback = false
    private var shouldResumePlaybackAfterSeek = false
    private var seekRequestID = 0
    private var didApplySteadyStateBuffering = false
    private var userInitiatedPause = false
    private var playbackQueue: [Track] = []
    private var playbackQueueIndex: Int?
    private var itemDidEndObserver: NSObjectProtocol?
    private var itemFailedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var stallRecoveryTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var streamCandidateCache: [String: [URL]] = [:]
    private var authoritativeDurationCache: [String: TimeInterval] = [:]
    private var prefetchTasks: [String: StreamPrefetch] = [:]
    private var delayedPrefetchTasks: [String: Task<Void, Never>] = [:]
    private var isAppInBackground = false
    private var isCarPlayConnected = false
    private var activeTimeObserverInterval: TimeInterval?
    private var lastNowPlayingElapsedUpdate = Date.distantPast
    /// Tracks the timestamp of the last resolution failure per videoID, used to
    /// avoid hammering YouTube for tracks that are genuinely unavailable.
    private var streamResolutionFailureTimestamps: [String: Date] = [:]
    /// KVO, playback notifications, and the startup watchdog can report the same
    /// failed item independently. Keep them from creating an unbounded retry loop.
    private var automaticStreamRecoveryBudget = PlaybackRecoveryBudget()
    private var policyCancellables: Set<AnyCancellable> = []
    private let remoteCommandManager = RemoteCommandManager()
    /// Tracks whether `AVAudioSession.setActive(true)` has been called. Deferring
    /// activation until first play avoids ducking other apps' audio at launch
    /// and skips the activation handshake during cold start.
    private var audioSessionActivated = false
    /// True between the moment the user requests playback and the moment
    /// AVPlayer actually reports `.playing`. The manager reads this so the
    /// system sees `playbackRate = 1.0` / `playbackState = .playing` during
    /// stream resolution — without it, the Now Playing app registration is
    /// deferred until audio starts, and skip/seek buttons render grayed
    /// because iOS doesn't yet consider us the active media source.
    private var isStartingPlayback = false
    /// Timestamp captured the moment the user taps a track, used to log tap-to-play
    /// latency once AVPlayer reports `.readyToPlay`. Diagnostic only.
    private var tapToPlayStartedAt: Date?
    private var tapToPlayTrackID: String?
    private let artworkCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 50
        return cache
    }()
    // Stores JPEG-round-tripped images ready for AirPlay transmission, keyed by artwork URL.
    private let transmittableArtworkCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 20
        return cache
    }()
    private let foregroundNowPlayingElapsedUpdateInterval: TimeInterval = 1
    private let backgroundNowPlayingElapsedUpdateInterval: TimeInterval = 30
    private let foregroundTimeObserverInterval = AppConfig.Playback.foregroundTimeObserverInterval
    private let backgroundTimeObserverInterval = AppConfig.Playback.backgroundTimeObserverInterval
    private let maxActivePrefetchTasks = AppConfig.Playback.maxActivePrefetchTasks

    init(logger: any AppLogging = DefaultAppLogger(category: "PlaybackService")) {
        self.logger = logger
        super.init()
        configureAudioSession()
        // Pre-warm AVPlayer once so every subsequent track avoids the full pipeline-creation cost.
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        // Keep AirPlay in audio-route mode. When AVPlayer external playback is
        // enabled and YouTube only offers video+audio, tvOS shows the video
        // instead of the audio Now Playing screen with artwork and progress.
        player.allowsExternalPlayback = false
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        remoteCommandManager.attachPlayer(player)
        installRemoteCommandHandlers()
        observeAudioSessionInterruptions()
        observeAppLifecycle()
        observeExternalPlayback(on: player)
        installTimeObserver(on: player, interval: foregroundTimeObserverInterval)
        observePlaybackPolicy()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        externalPlaybackObservation = nil
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Lets other audio sources (e.g. `MusicRecognitionService`) opt in to being
    /// silenced before primary playback resumes. Without this, two concurrent
    /// audio sources can both be subscribed to remote commands, leaving the
    /// Lock-Screen pause button routed to the wrong one.
    func registerSecondaryAudioSource(_ source: SecondaryAudioSource) {
        remoteCommandManager.registerSecondaryPlayer(source)
    }

    func unregisterSecondaryAudioSource(_ source: SecondaryAudioSource) {
        remoteCommandManager.unregisterSecondaryPlayer(source)
    }

    /// Plays a single track, preserving the current queue when possible.
    func play(track: Track) {
        play(track: track, queue: nil)
    }

    /// Plays a track and replaces the active queue with the provided ordering.
    func play(track: Track, queue: [Track]?) {
        guard allowsNetworkPlayback(for: track) else {
            reportCellularPlaybackBlocked()
            return
        }
        userInitiatedPause = false
        prepareInteractivePlayback(for: track)

        configureQueue(for: track, queue: queue)

        if let currentTrack = nowPlaying,
           matches(currentTrack, track),
           let currentItem = player?.currentItem,
           currentItem.status != .failed {
            resume()
            return
        }

        startPlayback(for: track)
    }

    func playNextTrack() {
        userInitiatedPause = false

        guard playbackQueue.isEmpty == false else { return }

        if let playbackQueueIndex, playbackQueueIndex + 1 < playbackQueue.count {
            let nextIndex = playbackQueueIndex + 1
            let nextTrack = playbackQueue[nextIndex]
            prepareInteractivePlayback(for: nextTrack)
            self.playbackQueueIndex = nextIndex
            updateQueueState()
            startPlayback(for: nextTrack)
            return
        }

        guard repeatMode == .all else { return }
        let nextTrack = playbackQueue[0]
        prepareInteractivePlayback(for: nextTrack)
        playbackQueueIndex = 0
        updateQueueState()
        startPlayback(for: nextTrack)
    }

    func playPreviousTrack() {
        userInitiatedPause = false

        if let player, player.currentTime().seconds > 5 {
            // If the stream URL expired, restart rather than seeking on a dead item.
            if let url = activeStreamURL, Self.isStreamURLExpired(url), let track = nowPlaying {
                streamCandidateCache.removeValue(forKey: cacheKey(for: track))
                prepareInteractivePlayback(for: track)
                startPlayback(for: track)
                return
            }
            player.seek(to: .zero)
            if isPlaying == false {
                player.play()
                player.rate = playbackRate
                setIsPlaying(true)
                updatePlaybackState()
            }
            return
        }

        guard let playbackQueueIndex else { return }

        if playbackQueueIndex > 0 {
            let previousIndex = playbackQueueIndex - 1
            let previousTrack = playbackQueue[previousIndex]
            prepareInteractivePlayback(for: previousTrack)
            self.playbackQueueIndex = previousIndex
            updateQueueState()
            startPlayback(for: previousTrack)
            return
        }

        if repeatMode == .all, let lastIndex = playbackQueue.indices.last {
            let previousTrack = playbackQueue[lastIndex]
            prepareInteractivePlayback(for: previousTrack)
            self.playbackQueueIndex = lastIndex
            updateQueueState()
            startPlayback(for: previousTrack)
            return
        }

        player?.seek(to: .zero)
        updatePlaybackState()
    }

    func toggleShuffle() {
        shuffleMode.toggle()
        guard playbackQueue.isEmpty == false else {
            updateCommandAvailability()
            return
        }

        if shuffleMode {
            // Save original, shuffle remaining (keep current track at index)
            originalQueue = playbackQueue
            if let currentIndex = playbackQueueIndex {
                let current = playbackQueue[currentIndex]
                var rest = playbackQueue
                rest.remove(at: currentIndex)
                rest.shuffle()
                playbackQueue = [current] + rest
                playbackQueueIndex = 0
            } else {
                playbackQueue.shuffle()
            }
        } else {
            // Restore original order, keep position on current track
            if originalQueue.isEmpty == false {
                let current = nowPlaying
                playbackQueue = originalQueue
                if let current, let idx = playbackQueue.firstIndex(where: { matches($0, current) }) {
                    playbackQueueIndex = idx
                }
                originalQueue = []
            }
        }
        updateQueueState()
        if let current = nowPlaying {
            prewarmQueue(around: current)
        }
        updateCommandAvailability()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        updateCommandAvailability()
    }

    /// Eagerly warms the stream cache for a list of tracks (call when tracks first appear on screen).
    func prefetchStreams(for tracks: [Track], allowWhileBackgrounded: Bool = false) {
        if allowWhileBackgrounded {
            guard AppPowerBudget.isLowPowerModeEnabled == false,
                  AppPowerBudget.isThermallyConstrained == false,
                  AppPowerBudget.isLowBattery == false else { return }
        } else {
            guard AppPowerBudget.allowsSpeculativeNetwork(isAppInBackground: isAppInBackground) else { return }
        }
        guard DataUsageSettings.shared.dataSaverMode == false else { return }
        guard DataUsageSettings.shared.canStream(onCellular: NetworkMonitor.shared.isCellular) else { return }

        let candidates = tracks
            .filter { $0.youtubeVideoID != nil && $0.streamURL == nil }
            .prefix(2)

        // Stagger background prefetch to avoid firing dozens of InnerTube requests
        // simultaneously. Keep this intentionally tiny: playback itself resolves
        // at high priority, while this is only a convenience cache for visible rows.
        for (index, track) in candidates.enumerated() {
            let immediateWindow = 1
            if index < immediateWindow {
                _ = enqueueStreamResolutionTaskIfNeeded(
                    for: track,
                    priority: .utility,
                    allowWhileBackgrounded: allowWhileBackgrounded
                )
            } else {
                let key = cacheKey(for: track)
                delayedPrefetchTasks[key]?.cancel()
                let delayNS = UInt64(index - immediateWindow + 1) * 350_000_000
                let delayedTask = Task(priority: .background) { @MainActor [weak self, track, key] in
                    defer { self?.delayedPrefetchTasks.removeValue(forKey: key) }
                    try? await Task.sleep(nanoseconds: delayNS)
                    guard let self, Task.isCancelled == false else { return }
                    if allowWhileBackgrounded == false {
                        guard AppPowerBudget.allowsSpeculativeNetwork(isAppInBackground: self.isAppInBackground) else { return }
                    }
                    _ = self.enqueueStreamResolutionTaskIfNeeded(
                        for: track,
                        priority: .background,
                        allowWhileBackgrounded: allowWhileBackgrounded
                    )
                }
                delayedPrefetchTasks[key] = delayedTask
            }
        }
    }

    func cancelSpeculativePrefetches() {
        // A CarPlay tap can still be resolving when the handset locks. Preserve
        // that user-requested task while cancelling unrelated speculative work.
        let activeStartupKey = isResolvingStream || isStartingPlayback
            ? nowPlaying.map(cacheKey(for:))
            : nil
        cancelAllPrefetchTasks(preserving: activeStartupKey)
    }

    /// CarPlay remains an active playback surface while the phone app is backgrounded.
    /// Keep exactly the next queue item warm in that state, then return to the normal
    /// foreground-only speculative policy as soon as CarPlay disconnects.
    func setCarPlayConnected(_ isConnected: Bool) {
        guard isCarPlayConnected != isConnected else { return }
        isCarPlayConnected = isConnected

        if isConnected, let nowPlaying {
            prewarmQueue(around: nowPlaying)
        } else if isAppInBackground {
            cancelSpeculativePrefetches()
        }
    }

    /// Resolves the best audio stream URL for a track (used by DownloadService).
    func resolveStreamURL(for track: Track) async throws -> URL? {
        let candidates = try await resolveAndCacheStreamCandidates(for: track)
        return candidates.first
    }

    /// The resolved download stream plus YouTube's authoritative duration for the item.
    /// The duration is persisted with the download so offline playback shows the correct
    /// length even when the saved container misreports it.
    struct DownloadStreamResolution: Sendable {
        let url: URL
        let approximateDuration: TimeInterval?
    }

    // The remote extractor currently supplies direct URLs that permit a complete
    // background transfer. Keep local extraction as an availability fallback.
    nonisolated static let downloadExtractionMethods: [YouTube.ExtractionMethod] = [.remote, .local]

    /// Resolves a stream URL for offline downloads using the same cached path as playback.
    /// Downloads intentionally avoid the playback cache: playback may prefer streams
    /// that are fine for AVPlayer but poor for URLSession background transfers
    /// (for example HLS playlists or video-containing streams). A fresh direct
    /// audio URL is more reliable once the phone locks.
    func resolveDownloadStreamURL(for track: Track) async throws -> DownloadStreamResolution? {
        let result = try await Self.extractDownloadStreamCandidates(
            for: track,
            methods: Self.downloadExtractionMethods
        )
        let candidates = Self.deduplicatedURLs(result.urls)
            .filter { !Self.isStreamURLExpired($0) }
        guard let url = candidates.first else { return nil }
        return DownloadStreamResolution(url: url, approximateDuration: result.approximateDuration)
    }

    /// Stops playback and clears queue, observers, and now-playing metadata.
    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        endPlaybackStartupBackgroundTask()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        isResolvingStream = false
        playbackErrorMessage = nil
        tearDownPlayer()
        nowPlaying = nil
        setIsPlaying(false)
        setCurrentTime(0, threshold: 0)
        setDuration(0, threshold: 0)
        setBufferedTime(0, threshold: 0)
        setIsBufferingPlayback(false)
        playbackQueue = []
        playbackQueueIndex = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil
        playbackCompletionMonitorTask?.cancel()
        playbackCompletionMonitorTask = nil
        userInitiatedPause = false
        isStartingPlayback = false
        cancelAllPrefetchTasks()
        remoteCommandManager.clearNowPlaying()
        deactivateAudioSession()
        updateQueueState()
    }

    private func startPlayback(for track: Track) {
        guard allowsNetworkPlayback(for: track) else {
            reportCellularPlaybackBlocked()
            return
        }
        beginPlaybackStartupBackgroundTask()
        resolveTask?.cancel()
        resolveTask = nil
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        playbackErrorMessage = nil
        userInitiatedPause = false
        automaticStreamRecoveryBudget.reset()
        // Mark intent to play *before* updating Now Playing info so the system
        // sees us as the active media source from the very first system tick
        // after the user taps a track — not 1–3 s later when stream resolution
        // completes. This is what eliminates the "buttons are grayed until
        // pause-play-pause" symptom.
        isStartingPlayback = true
        // Capture tap-to-play start for latency diagnostics (logged at .readyToPlay).
        tapToPlayStartedAt = Date()
        tapToPlayTrackID = track.id
        nowPlaying = track
        setCurrentTime(0, threshold: 0)
        if let authoritativeDuration = authoritativeDuration(for: track) {
            setDuration(authoritativeDuration, threshold: 0)
        } else {
            setDuration(0, threshold: 0)
        }
        setBufferedTime(0, threshold: 0)
        setIsBufferingPlayback(false)
        // Activate the audio session up-front (before stream extraction) so
        // iOS designates this app as the now-playing source immediately.
        // Without an active session, the system may route remote-command
        // events to a previously-playing app or render the controls inert.
        activateAudioSessionIfNeeded()
        remoteCommandManager.becomeActiveIfPossible()
        updateNowPlayingInfo(for: track)
        // Refresh `next/previous/seek` enable state right after Now Playing
        // info is set so the lock-screen layout doesn't render gray buttons
        // for the first paint.
        updateQueueState()
        prewarmQueue(around: track)
        tearDownPlayer()

        if let streamURL = track.streamURL {
            startPlayback(fromCandidates: [streamURL], for: track)
        } else if let cachedCandidates = cachedStreamCandidates(for: track), cachedCandidates.isEmpty == false {
            startPlayback(fromCandidates: cachedCandidates, for: track)
        } else if track.youtubeVideoID != nil {
            isResolvingStream = true
            updatePlaybackState()

            resolveTask = Task { [weak self, track] in
                guard let self else { return }

                do {
                    let resolvedURLs = try await self.resolveAndCacheStreamCandidates(
                        for: track,
                        reuseExistingPrefetch: true
                    )

                    guard Task.isCancelled == false else { return }
                    guard self.nowPlaying?.id == track.id else { return }

                    self.startPlayback(fromCandidates: resolvedURLs, for: track)
                } catch is CancellationError {
                    guard self.nowPlaying?.id == track.id else { return }
                    self.endPlaybackStartupBackgroundTask()
                    self.isResolvingStream = false
                    self.updatePlaybackState()
                } catch {
                    guard self.nowPlaying?.id == track.id else { return }
                    self.endPlaybackStartupBackgroundTask()
                    self.recordResolutionFailure(for: track)
                    self.isResolvingStream = false
                    self.isStartingPlayback = false
                    self.setIsBufferingPlayback(false)
                    self.setIsPlaying(false)
                    self.playbackErrorMessage = "MusicTube couldn't extract audio for this YouTube item right now."
                    self.updatePlaybackState()
                }
            }
        } else {
            endPlaybackStartupBackgroundTask()
            isResolvingStream = false
            setIsPlaying(false)
            updatePlaybackState()
        }
    }

    private func allowsNetworkPlayback(for track: Track) -> Bool {
        if track.streamURL?.isFileURL == true { return true }
        return DataUsageSettings.shared.canStream(onCellular: NetworkMonitor.shared.isCellular)
    }

    private func reportCellularPlaybackBlocked() {
        endPlaybackStartupBackgroundTask()
        playbackErrorMessage = "Streaming on cellular is disabled in Settings."
        isStartingPlayback = false
        setIsPlaying(false)
        updatePlaybackState()
    }

    private func observePlaybackPolicy() {
        Publishers.CombineLatest(
            DataUsageSettings.shared.$allowStreamOnCellular,
            NetworkMonitor.shared.$isCellular
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _ in
            guard let self,
                  let track = self.nowPlaying,
                  self.allowsNetworkPlayback(for: track) == false else {
                return
            }
            self.pause()
            self.reportCellularPlaybackBlocked()
        }
        .store(in: &policyCancellables)
    }

    /// Resumes playback or re-resolves the current track if the player has been torn down.
    func resume() {
        playbackErrorMessage = nil

        if isResolvingStream {
            return
        }

        userInitiatedPause = false

        if let player,
           let currentItem = player.currentItem,
           currentItem.status != .failed {
            // If the active stream URL has expired, recover with a fresh URL before resuming.
            if let url = activeStreamURL, Self.isStreamURLExpired(url), let track = nowPlaying {
                streamCandidateCache.removeValue(forKey: cacheKey(for: track))
                recoverPlayback(for: track, resumingAt: currentTime)
                return
            }
            activateAudioSessionIfNeeded()
            remoteCommandManager.becomeActiveIfPossible()
            player.play()
            player.rate = playbackRate
            setIsPlaying(true)
            updatePlaybackState()
            return
        }

        if let track = nowPlaying {
            play(track: track, queue: playbackQueue.isEmpty ? nil : playbackQueue)
        }
    }

    /// Pauses active playback and cancels in-flight startup and recovery work.
    func pause() {
        resolveTask?.cancel()
        resolveTask = nil
        endPlaybackStartupBackgroundTask()
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackCompletionMonitorTask?.cancel()
        playbackCompletionMonitorTask = nil
        cancelAllPrefetchTasks()
        invalidatePendingSeek()
        isResolvingStream = false
        userInitiatedPause = true
        // Clear the optimistic load flag — pausing during stream resolution
        // must take effect immediately on the lock-screen icon, not wait for
        // the resolver to finish.
        isStartingPlayback = false
        player?.pause()
        setIsPlaying(false)
        updatePlaybackState()
    }

    /// Seeks to the requested playback time, clamped to the current duration.
    func seek(to time: TimeInterval) {
        guard let player else { return }

        let shouldResume = Self.shouldResumeAfterSeek(
            userInitiatedPause: userInitiatedPause,
            isPlaying: isPlaying,
            playerRate: player.rate,
            isStartingPlayback: isStartingPlayback
        )

        // If the stream URL has expired, re-resolve and resume from the seek target.
        if let url = activeStreamURL, Self.isStreamURLExpired(url), let track = nowPlaying {
            beginPlaybackStartupBackgroundTask()
            streamCandidateCache.removeValue(forKey: cacheKey(for: track))
            pendingSeekTime = time
            setCurrentTime(time, threshold: 0)
            lastObservedTime = time
            updatePlaybackState()
            isResolvingStream = true
            resolveTask?.cancel()
            resolveTask = Task { [weak self, track, time] in
                guard let self else { return }
                do {
                    let freshURLs = try await self.resolveAndCacheStreamCandidates(
                        for: track,
                        reuseExistingPrefetch: false
                    )
                    guard !Task.isCancelled, self.nowPlaying?.id == track.id else { return }
                    self.startPlayback(fromCandidates: freshURLs, for: track, resumeTime: time)
                } catch {
                    guard self.nowPlaying?.id == track.id else { return }
                    self.endPlaybackStartupBackgroundTask()
                    self.isResolvingStream = false
                    self.isStartingPlayback = false
                    self.setIsBufferingPlayback(false)
                    self.pendingSeekTime = nil
                    self.playbackErrorMessage = "Stream interrupted. Tap play to retry."
                    self.updatePlaybackState()
                }
            }
            return
        }

        let boundedDuration = duration.isFinite && duration > 0 ? duration : time
        let clampedTime = max(0, min(time, boundedDuration))
        let targetTime = CMTime(seconds: clampedTime, preferredTimescale: 600)

        seekRequestID &+= 1
        let requestID = seekRequestID
        isSeekingPlayback = true
        shouldResumePlaybackAfterSeek = shouldResume
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil

        // Update UI immediately so the bar shows the new position right away.
        pendingSeekTime = clampedTime
        setCurrentTime(clampedTime, threshold: 0)
        lastObservedTime = clampedTime
        updatePlaybackState()

        // 0.5s tolerance = instant keyframe seek for audio; zero tolerance can take 3–10s
        // on DASH streams, which froze the bar while audio played from the new position.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak player] _ in
            Task { @MainActor [weak self] in
                guard let self, let player, self.player === player else { return }
                guard self.seekRequestID == requestID else { return }

                self.pendingSeekTime = nil
                self.isSeekingPlayback = false
                let shouldResume = self.shouldResumePlaybackAfterSeek
                self.shouldResumePlaybackAfterSeek = false

                // Seeking a remote HLS item may drop AVPlayer to `.paused` while it
                // obtains the target segment. Reassert the user's play intent after
                // the seek completes so playback continues at the requested minute.
                if shouldResume, self.userInitiatedPause == false {
                    self.activateAudioSessionIfNeeded()
                    player.playImmediately(atRate: self.playbackRate)
                    self.setIsPlaying(true)
                    self.setIsBufferingPlayback(player.timeControlStatus != .playing)
                }
                self.updatePlaybackState()
            }
        }

        // Preserve a non-zero desired rate during the network-backed seek. This lets
        // AVPlayer fetch the distant HLS segment instead of remaining paused while the
        // completion callback waits for media data.
        if shouldResume {
            activateAudioSessionIfNeeded()
            player.playImmediately(atRate: playbackRate)
            setIsPlaying(true)
            setIsBufferingPlayback(true)
            updatePlaybackState()
        }
    }

    nonisolated static func shouldResumeAfterSeek(
        userInitiatedPause: Bool,
        isPlaying: Bool,
        playerRate: Float,
        isStartingPlayback: Bool
    ) -> Bool {
        userInitiatedPause == false
            && (isPlaying || playerRate != 0 || isStartingPlayback)
    }

    private func invalidatePendingSeek() {
        seekRequestID &+= 1
        pendingSeekTime = nil
        isSeekingPlayback = false
        shouldResumePlaybackAfterSeek = false
    }

    private func configureAudioSession() {
        // Configure category only — `setActive(true)` is deferred to
        // `activateAudioSessionIfNeeded()` so we don't duck other apps' audio
        // at launch when the user hasn't yet asked us to play anything. This
        // also moves the activation handshake off the cold-start critical path.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
        } catch {
            do {
                try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
            } catch {
                logger.error("Failed to configure audio session", error: error)
            }
        }
    }

    private func installRemoteCommandHandlers() {
        let bindings = RemoteCommandManager.Bindings(
            isPlaying: { [weak self] in
                guard let self else { return false }
                // Treat "still loading the stream the user just asked for" as
                // playing for the purposes of `MPNowPlayingInfo`. Otherwise
                // the system shows playbackRate=0 / playbackState=.paused
                // during the 1–3 s YouTube extraction, refuses to designate
                // us as the active media source, and the entire command set
                // renders grayed-out until something else triggers a refresh.
                return self.isPlaying || self.isStartingPlayback
            },
            currentRate: { [weak self] in self?.playbackRate ?? 1.0 },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            duration: { [weak self] in self?.duration ?? 0 },
            queueIndex: { [weak self] in self?.playbackQueueIndex },
            queueCount: { [weak self] in self?.playbackQueue.count ?? 0 },
            hasNextTrack: { [weak self] in self?.hasNextTrack ?? false },
            hasPreviousTrack: { [weak self] in self?.hasPreviousTrack ?? false },
            canSeek: { [weak self] in (self?.duration ?? 0) > 0 },
            isPlayingImmediately: { [weak player] in
                guard let player else { return false }
                return player.rate != 0 || player.timeControlStatus == .playing
            },
            pauseImmediately: { [weak player] in
                player?.pause()
            },
            currentTimeImmediately: { [weak player] in
                guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
                return max(0, seconds)
            },
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayback() },
            next: { [weak self] in self?.playNextTrack() },
            previous: { [weak self] in self?.playPreviousTrack() },
            seek: { [weak self] time in self?.seek(to: time) },
            changeRepeatType: { [weak self] type in self?.applyRepeatType(type) },
            changeShuffleType: { [weak self] type in self?.applyShuffleType(type) }
        )
        remoteCommandManager.install(bindings)
        remoteCommandManager.applyCommandAvailability()
    }

    private func updateNowPlayingInfo(for track: Track) {
        var artwork: MPMediaItemArtwork?
        // Include cached processed artwork immediately so Apple TV gets it on first transmission.
        if let artworkURL = track.artworkURL,
           let cached = transmittableArtworkCache.object(forKey: artworkURL as NSURL) {
            let side = CGFloat(ArtworkPixelSize.nowPlaying)
            let size = CGSize(width: side, height: side)
            artwork = MPMediaItemArtwork(boundsSize: size) { _ in cached }
        }

        remoteCommandManager.updateNowPlayingInfo(
            title: track.title,
            artist: track.artist,
            artwork: artwork
        )
        loadArtworkForNowPlaying(track)
    }

    private func updatePlaybackState() {
        remoteCommandManager.syncPlaybackState()
        refreshStateSnapshot()
        updateCommandAvailability()
        updateQueueState()
    }

    /// Lightweight variant used by the periodic time observer — only updates elapsed
    /// time in NowPlayingInfo and refreshes the state snapshot. Avoids the overhead
    /// of updateCommandAvailability() and updateQueueState() on every 0.5 s tick.
    private func updateElapsedPlaybackInfo() {
        guard shouldUpdateNowPlayingElapsedInfo() else { return }
        remoteCommandManager.updateElapsedTime()
    }

    private func tearDownPlayer() {
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil
        playbackCompletionMonitorTask?.cancel()
        playbackCompletionMonitorTask = nil
        invalidatePendingSeek()
        didApplySteadyStateBuffering = false
        playerItemStatusObservation = nil
        playerItemDurationObservation = nil
        playerItemBufferedTimeObservation = nil
        playbackObservation = nil
        removeBoundaryEndObserver()
        activeStreamLoader?.invalidate()
        activeStreamLoader = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        activeStreamURL = nil
        setBufferedTime(0, threshold: 0)
        setIsBufferingPlayback(false)
        removeItemDidEndObserver()
        removeItemFailedObserver()
        removeStalledObserver()
    }

    private func startPlayback(
        fromCandidates candidateURLs: [URL],
        for track: Track,
        candidateIndex: Int = 0,
        resumeTime: TimeInterval = 0,
        allowRemoteRecovery: Bool = true,
        usesBoundedLoader: Bool = false
    ) {
        let uniqueCandidates = Self.deduplicatedURLs(candidateURLs)

        guard candidateIndex < uniqueCandidates.count else {
            if allowRemoteRecovery,
               track.youtubeVideoID != nil,
               automaticStreamRecoveryBudget.consumeIfAvailable() {
                beginPlaybackStartupBackgroundTask()
                streamCandidateCache.removeValue(forKey: cacheKey(for: track))
                resolveTask?.cancel()
                isResolvingStream = true
                setIsBufferingPlayback(true)
                updatePlaybackState()

                resolveTask = Task { [weak self] in
                    guard let self else { return }

                    do {
                        // Initial playback may use the faster remote extractor. If
                        // AVPlayer rejects that URL, make the one automatic recovery
                        // local-only so it cannot select the same restricted URL again.
                        let localCandidates = try await self.resolveLocalStreamCandidates(for: track)
                        guard Task.isCancelled == false else { return }
                        guard self.nowPlaying?.id == track.id else { return }

                        self.startPlayback(
                            fromCandidates: localCandidates,
                            for: track,
                            resumeTime: resumeTime,
                            allowRemoteRecovery: false
                        )
                    } catch {
                        guard self.nowPlaying?.id == track.id else { return }
                        self.endPlaybackStartupBackgroundTask()
                        self.recordResolutionFailure(for: track)
                        self.tearDownPlayer()
                        self.isResolvingStream = false
                        self.isStartingPlayback = false
                        self.setIsBufferingPlayback(false)
                        self.setIsPlaying(false)
                        self.playbackErrorMessage = "MusicTube couldn't start audio for this YouTube item right now."
                        self.updatePlaybackState()
                    }
                }
                return
            }

            recordResolutionFailure(for: track)
            endPlaybackStartupBackgroundTask()
            tearDownPlayer()
            isResolvingStream = false
            isStartingPlayback = false
            setIsBufferingPlayback(false)
            setIsPlaying(false)
            playbackErrorMessage = "MusicTube couldn't start audio for this YouTube item right now."
            updatePlaybackState()
            return
        }

        let url = uniqueCandidates[candidateIndex]
        tearDownPlayer()
        isResolvingStream = false
        activeStreamURL = url
        didApplySteadyStateBuffering = false
        if let authoritativeDuration = authoritativeDuration(for: track) {
            setDuration(authoritativeDuration, threshold: 0)
        }

        let playerItem: AVPlayerItem
        if usesBoundedLoader,
           let streamLoader = BoundedHTTPStreamLoader(sourceURL: url) {
            // Large Googlevideo files reject the HEAD and open-ended byte-range
            // probes AVFoundation uses for progressive downloads. Route those
            // requests through a bounded range loader so the first media bytes
            // can reach AVPlayer immediately.
            activeStreamLoader = streamLoader
            playerItem = Self.makePlayerItem(asset: streamLoader.asset, isLocal: false)
        } else {
            activeStreamLoader = nil
            playerItem = Self.makePlayerItem(for: url)
        }
        self.player?.replaceCurrentItem(with: playerItem)
        registerItemDidEndObserver(for: playerItem)
        if let player {
            installBoundaryEndObserverIfNeeded(for: player)
            installPlaybackCompletionMonitor(for: player, track: track)
        }
        registerItemFailedObserver(for: playerItem, track: track)
        registerStalledObserver(for: playerItem, track: track)
        observeDuration(for: playerItem, track: track)
        observeBufferedTime(for: playerItem, track: track)
        activateAudioSessionIfNeeded()

        playerItemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.nowPlaying?.id == track.id else { return }

                switch item.status {
                case .failed:
                    let transport = usesBoundedLoader ? "bounded" : "direct"
                    self.logger.error(
                        "[Playback] Player item failed for candidate \(candidateIndex + 1) transport=\(transport)",
                        error: item.error
                    )
                    let shouldTryBoundedLoader = Self.shouldUseBoundedLoaderFallback(
                        for: url,
                        currentlyUsingBoundedLoader: usesBoundedLoader
                    )
                    self.startPlayback(
                        fromCandidates: uniqueCandidates,
                        for: track,
                        candidateIndex: shouldTryBoundedLoader ? candidateIndex : candidateIndex + 1,
                        resumeTime: resumeTime,
                        allowRemoteRecovery: allowRemoteRecovery,
                        usesBoundedLoader: shouldTryBoundedLoader
                    )
                case .readyToPlay:
                    if let startedAt = self.tapToPlayStartedAt, self.tapToPlayTrackID == track.id {
                        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                        self.logger.info("[Playback] tap-to-play latency=\(ms)ms title=\(track.title)")
                        self.tapToPlayStartedAt = nil
                        self.tapToPlayTrackID = nil
                    }
                    if let duration = self.preferredDuration(for: track, reportedDuration: self.seconds(from: item.duration)) {
                        self.setDuration(duration)
                    }
                    // Resume from position after stream recovery.
                    // Use 0.5 s tolerance — zero tolerance can stall for several seconds on DASH streams.
                    if resumeTime > 1 {
                        let target = CMTime(seconds: resumeTime, preferredTimescale: 600)
                        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
                        self.player?.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
                        self.setCurrentTime(resumeTime, threshold: 0)
                    }
                    // Never override a user-initiated pause — the user tapped pause before
                    // the item finished loading; honour that intent and stay paused.
                    guard !self.userInitiatedPause else {
                        self.updatePlaybackState()
                        return
                    }
                    self.player?.playImmediately(atRate: self.playbackRate)
                    self.updatePlaybackState()
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        playbackObservation = self.player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.setIsPlaying(self.shouldPresentAsPlaying(player))
                self.setIsBufferingPlayback(
                    (player.timeControlStatus == .waitingToPlayAtSpecifiedRate && self.isResolvingStream == false)
                        || (self.isSeekingPlayback && self.shouldResumePlaybackAfterSeek)
                )
                switch player.timeControlStatus {
                case .playing:
                    self.automaticStreamRecoveryBudget.reset()
                    // Stream is healthy — commit to steady-state buffering and dismiss the watchdog.
                    self.endPlaybackStartupBackgroundTask()
                    self.applySteadyStateBufferingIfNeeded(on: player)
                    self.playbackStartupTask?.cancel()
                    self.playbackStartupTask = nil
                    // A CarPlay selection usually arrives while the app is already
                    // backgrounded. The earlier queue warmup is intentionally gated
                    // until playback is active, so trigger it now to keep Next fast.
                    self.prewarmQueue(around: track)
                case .waitingToPlayAtSpecifiedRate:
                    // Keep the startup watchdog alive until media actually starts.
                    // A remote item can remain in this state indefinitely without
                    // receiving any bytes; in that case the watchdog should try the
                    // next resolved stream candidate.
                    break
                case .paused:
                    if self.isSeekingPlayback == false,
                       self.shouldTreatPausedPlayerAsPlaybackEnd(player) {
                        self.handlePlaybackEnd()
                        return
                    }
                default:
                    break
                }
                self.updatePlaybackState()
            }
        }

        updateNowPlayingInfo(for: track)
        beginPlaybackAsSoonAsPossible()
        updatePlaybackState()

        let startupWaitTimeoutNanoseconds = Self.startupWaitTimeoutNanoseconds(
            for: url,
            currentlyUsingBoundedLoader: usesBoundedLoader
        )
        playbackStartupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: startupWaitTimeoutNanoseconds)
            guard let self else { return }
            guard let player = self.player else { return }
            guard Task.isCancelled == false else { return }
            guard self.nowPlaying?.id == track.id else { return }

            let playbackTime = CMTimeGetSeconds(player.currentTime())
            if player.timeControlStatus == .playing || (playbackTime.isFinite && playbackTime > 0.05) {
                return
            }

            let item = player.currentItem
            let hasBufferedMedia = item.map { self.bufferedTime(for: $0) > 0.05 } ?? false
            let shouldTryBoundedLoader = Self.shouldUseBoundedLoaderFallback(
                for: url,
                currentlyUsingBoundedLoader: usesBoundedLoader
            )
            let hasAnotherCandidate = shouldTryBoundedLoader
                || candidateIndex + 1 < uniqueCandidates.count
                || (allowRemoteRecovery && track.youtubeVideoID != nil)

            if hasAnotherCandidate && (item?.status != .readyToPlay || hasBufferedMedia == false) {
                self.startPlayback(
                    fromCandidates: uniqueCandidates,
                    for: track,
                    candidateIndex: shouldTryBoundedLoader ? candidateIndex : candidateIndex + 1,
                    resumeTime: resumeTime,
                    allowRemoteRecovery: allowRemoteRecovery,
                    usesBoundedLoader: shouldTryBoundedLoader
                )
                return
            }

            player.playImmediately(atRate: self.playbackRate)
        }

        updatePlaybackState()
    }

    /// Creates a playback item without making remote duration discovery a prerequisite
    /// for readiness. Internal so the critical startup policy can be regression-tested.
    nonisolated static func shouldUseBoundedLoaderFallback(
        for url: URL,
        currentlyUsingBoundedLoader: Bool
    ) -> Bool {
        currentlyUsingBoundedLoader == false
            && isHLSManifestURL(url) == false
            && BoundedHTTPStreamLoader(sourceURL: url) != nil
    }

    nonisolated static func startupWaitTimeoutNanoseconds(
        for url: URL,
        currentlyUsingBoundedLoader: Bool
    ) -> UInt64 {
        shouldUseBoundedLoaderFallback(
            for: url,
            currentlyUsingBoundedLoader: currentlyUsingBoundedLoader
        )
            ? AppConfig.Playback.progressiveFallbackWaitTimeoutNanoseconds
            : AppConfig.Playback.startupWaitTimeoutNanoseconds
    }

    nonisolated static func shouldPromotePrefetch(
        existingUsesRemoteFallback: Bool,
        requestedUsesRemoteFallback: Bool
    ) -> Bool {
        requestedUsesRemoteFallback && existingUsesRemoteFallback == false
    }

    nonisolated static func shouldAllowQueueWarmup(
        isAppInBackground: Bool,
        isCarPlayConnected: Bool,
        isPlaybackActive: Bool
    ) -> Bool {
        isAppInBackground == false || (isCarPlayConnected && isPlaybackActive)
    }

    static func makePlayerItem(for url: URL) -> AVPlayerItem {
        // Downloaded YouTube DASH audio can misreport its header duration (commonly ~2x
        // the real length). For local files, ask AVFoundation to compute precise timing
        // from the sample tables — cheap on disk — so the scrubber length is correct.
        // Streamed URLs keep fast header timing to avoid extra network round-trips.
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: url.isFileURL]
        )
        return makePlayerItem(asset: asset, isLocal: url.isFileURL)
    }

    private static func makePlayerItem(asset: AVURLAsset, isLocal: Bool) -> AVPlayerItem {
        let playerItem: AVPlayerItem
        if isLocal {
            // Local downloads are cheap to inspect and benefit from having their
            // duration available as soon as the item becomes ready.
            playerItem = AVPlayerItem(asset: asset)
        } else {
            // AVPlayerItem(asset:) automatically loads `duration` before changing
            // to .readyToPlay. Determining the duration of a large remote DASH file
            // can require AVFoundation to inspect far-away container metadata, making
            // startup time grow with a track's length. YouTube already supplies an
            // authoritative duration, and the item duration remains KVO-observable,
            // so don't put duration loading on the remote playback critical path.
            // `playable` initializes AVFoundation's media pipeline without making
            // remote duration discovery a prerequisite for .readyToPlay. Passing
            // an empty key list can leave remote file items stuck in .unknown.
            playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable"])
        }
        playerItem.preferredForwardBufferDuration = AppConfig.Playback.startupForwardBufferDuration
        playerItem.preferredPeakBitRate = 256_000
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        return playerItem
    }

    private func beginPlaybackAsSoonAsPossible() {
        guard userInitiatedPause == false else { return }
        guard let player else { return }
        player.playImmediately(atRate: playbackRate)
        setIsPlaying(true)
        setIsBufferingPlayback(true)
    }

    private func configureQueue(for track: Track, queue: [Track]?) {
        var normalizedQueue = normalizeQueue(queue ?? [track], selectedTrack: track)
        originalQueue = normalizedQueue

        if shuffleMode {
            if let idx = normalizedQueue.firstIndex(where: { matches($0, track) }) {
                normalizedQueue.remove(at: idx)
                normalizedQueue.shuffle()
                normalizedQueue.insert(track, at: 0)
            } else {
                normalizedQueue.shuffle()
            }
        }

        playbackQueue = normalizedQueue
        playbackQueueIndex = normalizedQueue.firstIndex(where: { matches($0, track) }) ?? 0
        updateQueueState()
        prewarmQueue(around: track)
    }

    private func normalizeQueue(_ queue: [Track], selectedTrack: Track) -> [Track] {
        let dedupedQueue = deduplicatedTracks(queue)

        if dedupedQueue.contains(where: { matches($0, selectedTrack) }) {
            return dedupedQueue
        }

        return [selectedTrack] + dedupedQueue
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenTrackIDs: Set<String> = []
        return tracks.filter { track in
            let identifier = track.youtubeVideoID ?? track.id
            return seenTrackIDs.insert(identifier).inserted
        }
    }

    private func matches(_ lhs: Track, _ rhs: Track) -> Bool {
        let lhsIdentifier = lhs.youtubeVideoID ?? lhs.id
        let rhsIdentifier = rhs.youtubeVideoID ?? rhs.id
        return lhsIdentifier == rhsIdentifier
    }

    private func updateQueueState() {
        let nextTrackAvailable = canAdvanceToNextTrack
        let previousTrackAvailable = canReturnToPreviousTrack

        if hasNextTrack != nextTrackAvailable { hasNextTrack = nextTrackAvailable }
        if hasPreviousTrack != previousTrackAvailable { hasPreviousTrack = previousTrackAvailable }
        if currentQueue != playbackQueue { currentQueue = playbackQueue }
        if currentQueueIndex != playbackQueueIndex { currentQueueIndex = playbackQueueIndex }

        refreshStateSnapshot()
        updateCommandAvailability()
    }

    private var canAdvanceToNextTrack: Bool {
        guard playbackQueue.isEmpty == false else { return false }
        guard let playbackQueueIndex else { return playbackQueue.count > 1 }
        return playbackQueueIndex < playbackQueue.count - 1 || (repeatMode == .all && playbackQueue.count > 1)
    }

    private var canReturnToPreviousTrack: Bool {
        // Always available when a track is loaded. The handler decides between
        // "seek to start" (currentTime > 5 s) and "skip to previous queue item"
        // (currentTime ≤ 5 s). Gating the button on the 5-second threshold made
        // it render as grayed for the first five seconds of every song; users
        // couldn't tell whether the control was broken or just disabled until
        // they manually pause/play/paused to force a refresh.
        return nowPlaying != nil
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    private func registerItemDidEndObserver(for item: AVPlayerItem?) {
        removeItemDidEndObserver()

        guard let item else { return }

        itemDidEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnd()
            }
        }
    }

    private func handlePlaybackEnd() {
        guard shouldHandlePlaybackEndNow() else { return }
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil
        playbackCompletionMonitorTask?.cancel()
        playbackCompletionMonitorTask = nil
        userInitiatedPause = false

        switch repeatMode {
        case .one:
            // If the stream URL expired mid-song, do a full restart rather than seeking on a dead item.
            if let url = activeStreamURL, Self.isStreamURLExpired(url), let track = nowPlaying {
                streamCandidateCache.removeValue(forKey: cacheKey(for: track))
                prepareInteractivePlayback(for: track)
                startPlayback(for: track)
                return
            }
            player?.seek(to: .zero)
            player?.play()
            setIsPlaying(true)
            setCurrentTime(0, threshold: 0)
            updatePlaybackState()
        case .all:
            if hasNextTrack {
                playNextTrack()
            } else if playbackQueue.isEmpty == false {
                let nextTrack = playbackQueue[0]
                prepareInteractivePlayback(for: nextTrack)
                playbackQueueIndex = 0
                updateQueueState()
                startPlayback(for: nextTrack)
            }
        case .off:
            if hasNextTrack {
                playNextTrack()
            } else {
                setIsPlaying(false)
                updatePlaybackState()
            }
        }
    }

    private func shouldHandlePlaybackEndNow() -> Bool {
        let trackKey = nowPlaying.map { cacheKey(for: $0) } ?? "unknown"
        let now = Date()
        if lastHandledPlaybackEndKey == trackKey,
           now.timeIntervalSince(lastHandledPlaybackEndDate) < 2 {
            return false
        }

        lastHandledPlaybackEndKey = trackKey
        lastHandledPlaybackEndDate = now
        return true
    }

    private func removeItemDidEndObserver() {
        if let itemDidEndObserver {
            NotificationCenter.default.removeObserver(itemDidEndObserver)
            self.itemDidEndObserver = nil
        }
    }

    private func installBoundaryEndObserverIfNeeded(for player: AVPlayer) {
        guard boundaryEndObserverToken == nil else { return }
        guard duration.isFinite, duration > 1 else { return }

        let boundaryTime = CMTime(seconds: max(0.1, duration - 0.35), preferredTimescale: 600)
        boundaryEndObserverToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundaryTime)],
            queue: .main
        ) { [weak self, weak player] in
            MainActor.assumeIsolated { [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                guard self.userInitiatedPause == false else { return }
                let currentTime = CMTimeGetSeconds(player.currentTime())
                guard currentTime.isFinite else { return }
                self.setCurrentTime(max(0, currentTime), threshold: 0)
                self.schedulePlaybackEndWatchdog(observedTime: currentTime, player: player)
            }
        }
    }

    private func removeBoundaryEndObserver() {
        guard let boundaryEndObserverToken else { return }
        player?.removeTimeObserver(boundaryEndObserverToken)
        self.boundaryEndObserverToken = nil
    }

    private func installPlaybackCompletionMonitor(for player: AVPlayer, track: Track) {
        playbackCompletionMonitorTask?.cancel()

        guard duration > 1 else { return }

        playbackCompletionMonitorTask = Task { @MainActor [weak self, weak player, track] in
            var lastSampledTime = self?.currentTime ?? 0
            var stalledNearEndSamples = 0

            while Task.isCancelled == false {
                guard let self, let player else { return }
                guard self.player === player else { return }
                guard self.nowPlaying?.id == track.id else { return }
                guard self.duration > 1 else { return }
                guard self.userInitiatedPause == false else { return }

                if self.isSeekingPlayback {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                let sampledTime = CMTimeGetSeconds(player.currentTime())
                guard sampledTime.isFinite else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                let remaining = self.duration - sampledTime
                if remaining <= 0.35 {
                    self.setCurrentTime(self.duration, threshold: 0)
                    self.handlePlaybackEnd()
                    return
                }

                if remaining <= 1.5, player.timeControlStatus == .paused {
                    self.setCurrentTime(max(0, sampledTime), threshold: 0)
                    self.handlePlaybackEnd()
                    return
                }

                if remaining <= 2.5,
                   player.timeControlStatus != .waitingToPlayAtSpecifiedRate {
                    if abs(sampledTime - lastSampledTime) < 0.12 {
                        stalledNearEndSamples += 1
                    } else {
                        stalledNearEndSamples = 0
                    }

                    if stalledNearEndSamples >= 2 {
                        self.setCurrentTime(max(0, sampledTime), threshold: 0)
                        self.handlePlaybackEnd()
                        return
                    }
                }

                lastSampledTime = sampledTime

                let sleepNanoseconds: UInt64
                if remaining > 10 {
                    sleepNanoseconds = UInt64(min(5, max(1, remaining - 6)) * 1_000_000_000)
                } else {
                    sleepNanoseconds = 1_000_000_000
                }
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            }
        }
    }

    // MARK: - Stream Failure Recovery

    /// Fires when the stream errors mid-playback (e.g. expired YouTube URL).
    /// Clears the cached URL and re-resolves a fresh one, resuming from currentTime.
    private func registerItemFailedObserver(for item: AVPlayerItem, track: Track) {
        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.nowPlaying?.id == track.id else { return }
                let resumeAt = self.currentTime
                // Evict the stale (likely expired) URL from cache before re-resolving
                self.streamCandidateCache.removeValue(forKey: self.cacheKey(for: track))
                self.recoverPlayback(for: track, resumingAt: resumeAt)
            }
        }
    }

    private func removeItemFailedObserver() {
        if let itemFailedObserver {
            NotificationCenter.default.removeObserver(itemFailedObserver)
            self.itemFailedObserver = nil
        }
    }

    /// Fires when AVPlayer stalls mid-song due to buffer underrun.
    /// Gives AVPlayer 30 s to self-recover; if still stalled, re-resolves the stream.
    private func registerStalledObserver(for item: AVPlayerItem, track: Track) {
        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.nowPlaying?.id == track.id else { return }
                self.scheduleStallRecovery(for: track)
            }
        }
    }

    private func removeStalledObserver() {
        if let stalledObserver {
            NotificationCenter.default.removeObserver(stalledObserver)
            self.stalledObserver = nil
        }
    }

    private func scheduleStallRecovery(for track: Track) {
        stallRecoveryTask?.cancel()
        stallRecoveryTask = Task { [weak self, track] in
            // Give AVPlayer 12 s to self-recover before forcing a stream re-resolution.
            // 30 s was too long: expired stream URLs cause a 30-second hang on seek/resume.
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, Task.isCancelled == false else { return }
            guard self.nowPlaying?.id == track.id else { return }
            // Still stalled — force a fresh stream resolution
            guard self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            let resumeAt = self.currentTime
            self.streamCandidateCache.removeValue(forKey: self.cacheKey(for: track))
            self.recoverPlayback(for: track, resumingAt: resumeAt)
        }
    }

    /// Re-resolves a fresh stream URL and resumes playback from `time`.
    private func recoverPlayback(for track: Track, resumingAt time: TimeInterval) {
        guard nowPlaying?.id == track.id else { return }
        // Don't attempt recovery while the user has deliberately paused — the stream
        // will be re-resolved when the user taps play.
        guard !userInitiatedPause else { return }
        guard automaticStreamRecoveryBudget.consumeIfAvailable() else {
            endPlaybackStartupBackgroundTask()
            tearDownPlayer()
            isResolvingStream = false
            isStartingPlayback = false
            setIsBufferingPlayback(false)
            setIsPlaying(false)
            playbackErrorMessage = "Stream interrupted. Tap play to retry."
            updatePlaybackState()
            return
        }
        beginPlaybackStartupBackgroundTask()
        isResolvingStream = true
        resolveTask?.cancel()
        resolveTask = Task { [weak self, track, time] in
            guard let self else { return }
            do {
                let freshURLs = try await self.resolveLocalStreamCandidates(for: track)
                guard Task.isCancelled == false, self.nowPlaying?.id == track.id else { return }
                self.startPlayback(
                    fromCandidates: freshURLs,
                    for: track,
                    resumeTime: time,
                    allowRemoteRecovery: false
                )
            } catch {
                guard self.nowPlaying?.id == track.id else { return }
                self.endPlaybackStartupBackgroundTask()
                self.isResolvingStream = false
                self.isStartingPlayback = false
                self.setIsBufferingPlayback(false)
                self.setIsPlaying(false)
                self.playbackErrorMessage = "Stream interrupted. Tap play to retry."
                self.updatePlaybackState()
            }
        }
    }

    private func installTimeObserver(on player: AVPlayer, interval: TimeInterval) {
        if timeObserverToken != nil, activeTimeObserverInterval == interval {
            return
        }

        removeTimeObserver()
        activeTimeObserverInterval = interval
        lastObservedTime = 0

        let observerInterval = CMTime(seconds: interval, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: observerInterval, queue: .main) { [weak self, weak player] time in
            // Already on the main queue — assumeIsolated avoids the async hop that
            // Task { @MainActor } would introduce, which under background QoS (no
            // debugger) stalls the scheduler and causes visible UI lag.
            MainActor.assumeIsolated { [weak self, weak player] in
                guard let self, let player else { return }
                guard self.player === player else { return }

                let updatedTime = CMTimeGetSeconds(time)
                if updatedTime.isFinite {
                    if let target = self.pendingSeekTime, updatedTime < target - 1.0 {
                        // Still mid-seek — keep the already-set pending position on screen.
                    } else {
                        self.setCurrentTime(max(0, updatedTime))
                        self.checkForDASHPlaybackEnd(currentTime: updatedTime, player: player)
                        self.lastObservedTime = updatedTime
                    }
                }

                if let item = player.currentItem {
                    self.setBufferedTime(self.bufferedTime(for: item))
                }

                if self.duration == 0,
                   let track = self.nowPlaying,
                   let itemDuration = self.preferredDuration(
                        for: track,
                        reportedDuration: self.seconds(from: player.currentItem?.duration)
                   ) {
                    self.setDuration(itemDuration)
                }

                self.updateElapsedPlaybackInfo()
            }
        }
    }

    /// Watchdog for YouTube DASH audio-only streams whose reported duration is shorter than
    /// actual playback — `AVPlayerItemDidPlayToEndTime` never fires in that case.
    /// Detects end-of-stream by checking the playhead has stopped advancing near duration.
    private func checkForDASHPlaybackEnd(currentTime: TimeInterval, player: AVPlayer) {
        guard duration > 0,
              nowPlaying != nil,
              userInitiatedPause == false,
              isSeekingPlayback == false else { return }
        // Only arm the watchdog within the last 5 seconds of reported duration
        guard currentTime >= duration - 5 else {
            playbackEndWatchdogTask?.cancel()
            playbackEndWatchdogTask = nil
            return
        }

        schedulePlaybackEndWatchdog(observedTime: currentTime, player: player)
    }

    private func schedulePlaybackEndWatchdog(observedTime: TimeInterval, player: AVPlayer) {
        guard playbackEndWatchdogTask == nil else { return }

        playbackEndWatchdogTask = Task { [weak self, weak player] in
            // Wait 3 s (3 time-observer ticks) before concluding the stream truly ended.
            // 1.5 s was too short: a brief buffer stall near the end falsely triggered
            // end-of-track, silently skipping to the next song while audio was still playing.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let player else { return }
            guard self.isSeekingPlayback == false else { return }

            let newTime = CMTimeGetSeconds(player.currentTime())
            // Require at least 0.5 s of advancement to consider the stream still alive.
            let timeAdvanced = abs(newTime - observedTime) > 0.5
            let playerStillThinkingItsPlaying = player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let playerSilentlyStoppedNearTheEnd = player.timeControlStatus == .paused && newTime >= self.duration - 0.75

            if !timeAdvanced, (playerStillThinkingItsPlaying || playerSilentlyStoppedNearTheEnd) {
                await MainActor.run { [weak self] in
                    self?.handlePlaybackEnd()
                }
            }
            await MainActor.run { [weak self] in
                self?.playbackEndWatchdogTask = nil
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        activeTimeObserverInterval = nil
    }

    private func observeDuration(for item: AVPlayerItem, track: Track) {
        playerItemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.nowPlaying?.id == track.id else { return }
                if let duration = self.preferredDuration(for: track, reportedDuration: self.seconds(from: item.duration)) {
                    self.setDuration(duration)
                }
                self.updatePlaybackState()
            }
        }

        // Some downloaded YouTube DASH audio files report an inflated duration through
        // AVPlayer. For local media only, load the container duration and use it as a
        // fallback. Never explicitly load a remote asset's duration here: on long files
        // that can require distant container reads and delay playback readiness.
        guard authoritativeDuration(for: track) == nil else { return }
        Task { [weak self, weak item, track] in
            guard let asset = item?.asset as? AVURLAsset else { return }
            guard asset.url.isFileURL else { return }
            guard let assetDuration = try? await asset.load(.duration) else { return }
            let loadedDuration = CMTimeGetSeconds(assetDuration)
            guard loadedDuration.isFinite, loadedDuration > 1 else { return }
            await MainActor.run { [weak self] in
                guard let self, self.nowPlaying?.id == track.id else { return }
                let candidate = self.preferredDuration(for: track, reportedDuration: loadedDuration) ?? loadedDuration
                if self.duration == 0 || self.duration > candidate * 1.4 {
                    self.setDuration(candidate, threshold: 0)
                    self.updatePlaybackState()
                }
            }
        }
    }

    private func observeBufferedTime(for item: AVPlayerItem, track: Track) {
        playerItemBufferedTimeObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.nowPlaying?.id == track.id else { return }
                guard self.isAppInBackground == false else { return }
                self.setBufferedTime(self.bufferedTime(for: item))
            }
        }
    }

    private func setIsPlaying(_ newValue: Bool) {
        // Once we have real playback state from AVPlayer (in either direction),
        // the optimistic loading flag is no longer needed and must be cleared
        // so future updates accurately reflect the player.
        if isStartingPlayback {
            isStartingPlayback = false
        }
        guard isPlaying != newValue else { return }
        isPlaying = newValue
        refreshStateSnapshot()
    }

    private func setCurrentTime(_ newValue: TimeInterval, threshold: TimeInterval = 0.05) {
        let clampedValue = duration > 0 ? max(0, min(newValue, duration)) : max(0, newValue)
        guard abs(currentTime - clampedValue) > threshold else { return }
        currentTime = clampedValue
        if isAppInBackground == false {
            refreshStateSnapshot()
        }
    }

    private func setDuration(_ newValue: TimeInterval, threshold: TimeInterval = 0.05) {
        let normalizedValue = max(0, newValue)
        let previousDuration = duration
        guard abs(previousDuration - normalizedValue) > threshold else { return }
        duration = normalizedValue
        if let player {
            removeBoundaryEndObserver()
            if normalizedValue > 1 {
                installBoundaryEndObserverIfNeeded(for: player)
                if let track = nowPlaying {
                    installPlaybackCompletionMonitor(for: player, track: track)
                }
            }
        }
        refreshStateSnapshot()
        // `changePlaybackPositionCommand.isEnabled` is gated on `duration > 0`.
        // Without this refresh the scrubber stays disabled until the next
        // `updatePlaybackState()` (typically only fired by a user tap), which
        // is what manifested as a "grayed-out seek bar that wakes up only
        // after pause/play/pause."
        let crossedZeroBoundary = (previousDuration == 0) != (normalizedValue == 0)
        if crossedZeroBoundary {
            remoteCommandManager.applyCommandAvailability()
        }
    }

    private func setBufferedTime(_ newValue: TimeInterval, threshold: TimeInterval = 0.1) {
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let normalizedValue = max(currentTime, min(max(0, newValue), upperBound))
        guard abs(bufferedTime - normalizedValue) > threshold else { return }
        bufferedTime = normalizedValue
        if isAppInBackground == false {
            refreshStateSnapshot()
        }
    }

    private func setIsBufferingPlayback(_ newValue: Bool) {
        guard isBufferingPlayback != newValue else { return }
        isBufferingPlayback = newValue
        refreshStateSnapshot()
    }

    private func refreshStateSnapshot() {
        let snapshot = liveState
        guard state != snapshot else { return }
        state = snapshot
    }

    private func shouldUpdateNowPlayingElapsedInfo() -> Bool {
        let now = Date()
        let interval = isAppInBackground
            ? backgroundNowPlayingElapsedUpdateInterval
            : foregroundNowPlayingElapsedUpdateInterval
        guard now.timeIntervalSince(lastNowPlayingElapsedUpdate) >= interval else { return false }
        lastNowPlayingElapsedUpdate = now
        return true
    }

    private func shouldPresentAsPlaying(_ player: AVPlayer) -> Bool {
        if isSeekingPlayback, shouldResumePlaybackAfterSeek {
            return true
        }

        switch player.timeControlStatus {
        case .paused:
            return false
        case .playing, .waitingToPlayAtSpecifiedRate:
            return true
        @unknown default:
            return player.rate != 0
        }
    }

    private func shouldTreatPausedPlayerAsPlaybackEnd(_ player: AVPlayer) -> Bool {
        guard userInitiatedPause == false else { return false }
        guard isSeekingPlayback == false else { return false }
        guard nowPlaying != nil, duration > 0 else { return false }
        guard player.currentItem?.status == .readyToPlay else { return false }

        let currentTime = CMTimeGetSeconds(player.currentTime())
        guard currentTime.isFinite else { return false }

        let endThreshold = max(0.75, min(2, duration * 0.02))
        return currentTime >= duration - endThreshold
    }

    private func applySteadyStateBufferingIfNeeded(on player: AVPlayer) {
        guard didApplySteadyStateBuffering == false else { return }
        didApplySteadyStateBuffering = true

        if player.automaticallyWaitsToMinimizeStalling {
            player.automaticallyWaitsToMinimizeStalling = false
        }

        if let item = player.currentItem,
           item.preferredForwardBufferDuration != BufferingPolicy.steadyStateForwardBufferDuration {
            item.preferredForwardBufferDuration = BufferingPolicy.steadyStateForwardBufferDuration
        }
    }

    private func loadArtworkForNowPlaying(_ track: Track) {
        artworkLoadTask?.cancel()
        artworkLoadTask = nil

        guard let artworkURL = track.artworkURL else {
            remoteCommandManager.removeArtwork()
            return
        }

        // Already processed and cached — apply immediately.
        if let transmittable = transmittableArtworkCache.object(forKey: artworkURL as NSURL) {
            applyTransmittableArtwork(transmittable)
            return
        }

        artworkLoadTask = Task { [weak self, artworkURL, track] in
            guard let self else { return }

            // Try memory caches before hitting the network.
            let sourceImage: UIImage?
            if let cached = self.artworkCache.object(forKey: artworkURL as NSURL) {
                sourceImage = cached
            } else if let cached = ImageCache.shared.image(for: artworkURL, maxPixelSize: ArtworkPixelSize.nowPlaying) {
                self.artworkCache.setObject(cached, forKey: artworkURL as NSURL)
                sourceImage = cached
            } else {
                sourceImage = await ArtworkRepository.shared.image(
                    for: artworkURL,
                    maxPixelSize: ArtworkPixelSize.nowPlaying
                )
            }

            guard let image = sourceImage, !Task.isCancelled else { return }
            self.artworkCache.setObject(image, forKey: artworkURL as NSURL)

            // Process the image off the main thread so AirPlay/Lock Screen artwork is fully decoded.
            let transmittable = await Task.detached(priority: .utility) {
                Self.makeTransmittableArtwork(from: image)
            }.value

            guard !Task.isCancelled, self.nowPlaying?.id == track.id else { return }

            self.transmittableArtworkCache.setObject(transmittable, forKey: artworkURL as NSURL)
            self.applyTransmittableArtwork(transmittable)
        }
    }

    // Runs on a background thread — no actor state accessed.
    // Uses CGContext to produce a raw pixel-buffer UIImage (no lazy decoding) so AirPlay 2
    // can serialize it directly without needing to call back into a Swift closure.
    private nonisolated static func makeTransmittableArtwork(from image: UIImage) -> UIImage {
        let side = ArtworkPixelSize.nowPlaying
        let sideCG = CGFloat(side)
        guard let cgSource = image.cgImage else { return image }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                       | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return image }

        // Center-crop 16:9 source into a 1:1 square.
        let srcW = CGFloat(cgSource.width)
        let srcH = CGFloat(cgSource.height)
        let srcRatio = srcW / srcH
        let drawRect: CGRect
        if srcRatio > 1 {
            let w = sideCG * srcRatio
            drawRect = CGRect(x: -(w - sideCG) / 2, y: 0, width: w, height: sideCG)
        } else {
            let h = sideCG / srcRatio
            drawRect = CGRect(x: 0, y: -(h - sideCG) / 2, width: sideCG, height: h)
        }
        ctx.draw(cgSource, in: drawRect)

        guard let result = ctx.makeImage() else { return image }
        return UIImage(cgImage: result)
    }

    private func applyTransmittableArtwork(_ transmittable: UIImage) {
        let side = CGFloat(ArtworkPixelSize.nowPlaying)
        let size = CGSize(width: side, height: side)
        let artwork = MPMediaItemArtwork(boundsSize: size) { _ in transmittable }
        remoteCommandManager.setArtwork(artwork)
    }

    private func observeAudioSessionInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(notification)
            }
        }
    }

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        let backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidEnterBackground()
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
                if let player = self.player {
                    self.installTimeObserver(on: player, interval: self.foregroundTimeObserverInterval)
                    let seconds = CMTimeGetSeconds(player.currentTime())
                    if seconds.isFinite {
                        self.setCurrentTime(max(0, seconds), threshold: 0)
                    }
                    self.updatePlaybackState()
                }
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

    private func observeExternalPlayback(on player: AVPlayer) {
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                self.handleExternalPlaybackChanged(isActive: player.isExternalPlaybackActive)
            }
        }
    }

    private func handleExternalPlaybackChanged(isActive: Bool) {
        guard isActive else { return }
        // Once AirPlay owns external playback, keep the active stream untouched
        // but stop speculative work that only helps local on-device playback.
        cancelAllPrefetchTasks()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
    }

    private func handleAppDidEnterBackground() {
        isAppInBackground = true
        if let player {
            installTimeObserver(on: player, interval: backgroundTimeObserverInterval)
        }
        // Keep the active AVPlayer untouched. Cancel broad foreground prefetch,
        // then keep only the next likely queue item warm; that makes CarPlay /
        // Lock Screen "next" feel instant without running a whole recommendation
        // batch while the phone is locked. A CarPlay tap can still be resolving
        // during this transition, so preserve that user-requested task.
        let activeStartupKey = isResolvingStream || isStartingPlayback
            ? nowPlaying.map(cacheKey(for:))
            : nil
        cancelAllPrefetchTasks(preserving: activeStartupKey)
        if isCarPlayConnected, let nowPlaying {
            prewarmQueue(around: nowPlaying)
        }
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
    }

    private func handlePowerBudgetChanged() {
        if isAppInBackground, isCarPlayConnected {
            cancelSpeculativePrefetches()
            if let nowPlaying {
                prewarmQueue(around: nowPlaying)
            }
            return
        }
        guard AppPowerBudget.allowsSpeculativeNetwork(isAppInBackground: isAppInBackground) == false else { return }
        cancelSpeculativePrefetches()
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch interruptionType {
        case .began:
            // iOS implicitly deactivates the session on interruption — reset the
            // flag so activateAudioSessionIfNeeded() runs setActive(true) again
            // when playback resumes, re-establishing us as the Now Playing source.
            audioSessionActivated = false
            pause()
        case .ended:
            guard
                let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
            else {
                return
            }

            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    private func activateAudioSessionIfNeeded() {
        // Skip the activation handshake when the session is already active —
        // calling `setActive(true)` repeatedly is cheap-ish but not free, and
        // doing it on every play/seek event under main-thread pressure (long
        // background sessions without the debugger) adds perceptible latency.
        guard !audioSessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActivated = true
        } catch {
            logger.error("Failed to reactivate audio session", error: error)
        }
    }

    /// Keeps a user-requested CarPlay/Lock Screen start alive until AVPlayer is
    /// actually producing audio. The audio background mode only protects the app
    /// after playback begins; stream extraction happens before that point.
    private func beginPlaybackStartupBackgroundTask() {
        endPlaybackStartupBackgroundTask()
        playbackStartupBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "MusicTube.StartPlayback"
        ) { [weak self] in
            guard let self else { return }
            self.logger.error("[Playback] Startup background time expired before audio began", error: nil)
            self.resolveTask?.cancel()
            if let track = self.nowPlaying {
                self.cancelPrefetch(for: track)
            }
            self.isResolvingStream = false
            self.isStartingPlayback = false
            self.setIsBufferingPlayback(false)
            self.setIsPlaying(false)
            self.playbackErrorMessage = "Playback couldn't start while the iPhone was locked. Try again."
            self.endPlaybackStartupBackgroundTask()
            self.updatePlaybackState()
        }
    }

    private func endPlaybackStartupBackgroundTask() {
        guard playbackStartupBackgroundTask != .invalid else { return }
        let identifier = playbackStartupBackgroundTask
        playbackStartupBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func deactivateAudioSession() {
        guard audioSessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            audioSessionActivated = false
        } catch {
            logger.error("Failed to deactivate audio session", error: error)
        }
    }

    private func updateCommandAvailability() {
        remoteCommandManager.applyCommandAvailability()
        remoteCommandManager.setShuffleType(shuffleMode ? .items : .off)
        remoteCommandManager.setRepeatType(currentRemoteRepeatType)
    }

    private func cachedStreamCandidates(for track: Track) -> [URL]? {
        streamCandidateCache[cacheKey(for: track)]
    }

    private func cacheKey(for track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func authoritativeDuration(for track: Track) -> TimeInterval? {
        let cachedDuration = authoritativeDurationCache[cacheKey(for: track)]
        return Self.preferredAuthoritativeDuration(
            trackDuration: track.duration,
            streamDurations: cachedDuration.map { [$0] } ?? []
        )
    }

    private func preferredDuration(for track: Track, reportedDuration: TimeInterval?) -> TimeInterval? {
        if let authoritativeDuration = authoritativeDuration(for: track) {
            return authoritativeDuration
        }

        return reportedDuration
    }

    private func bufferedTime(for item: AVPlayerItem) -> TimeInterval {
        let loadedRanges = item.loadedTimeRanges.compactMap(\.timeRangeValue)
        let loadedEndTimes = loadedRanges.compactMap { range -> TimeInterval? in
            let start = CMTimeGetSeconds(range.start)
            let length = CMTimeGetSeconds(range.duration)
            guard start.isFinite, length.isFinite else { return nil }
            return start + length
        }

        return loadedEndTimes.max() ?? currentTime
    }

    private func resolveAndCacheStreamCandidates(
        for track: Track,
        allowRemoteFallback: Bool = true,
        reuseExistingPrefetch: Bool = true
    ) async throws -> [URL] {
        let key = cacheKey(for: track)
        if let cached = cachedStreamCandidates(for: track), cached.isEmpty == false {
            // Filter out any URLs whose YouTube `expire` timestamp is within 5 minutes
            let stillValid = cached.filter { !Self.isStreamURLExpired($0) }
            if stillValid.isEmpty == false {
                return stillValid
            }
            // All cached URLs are expired — evict and re-resolve
            streamCandidateCache.removeValue(forKey: key)
        }

        if reuseExistingPrefetch == false {
            cancelPrefetch(for: track)
        } else if let prefetchTask = prefetchTasks[key]?.task
            ?? enqueueStreamResolutionTaskIfNeeded(for: track, priority: .userInitiated) {
            let prefetchedCandidates = await prefetchTask.value
            let stillValidPrefetch = prefetchedCandidates.filter { !Self.isStreamURLExpired($0) }
            if stillValidPrefetch.isEmpty == false {
                streamCandidateCache[key] = stillValidPrefetch
                return stillValidPrefetch
            }
        }

        if allowRemoteFallback {
            return try await resolveFreshStreamCandidates(for: track)
        } else {
            return try await resolveLocalStreamCandidates(for: track)
        }
    }

    private func resolveFreshStreamCandidates(for track: Track) async throws -> [URL] {
        let result = try await Self.extractBoundedPlayableStreamCandidates(
            for: track,
            methods: Self.playbackExtractionMethods
        )
        let deduplicated = Self.deduplicatedURLs(result.urls)
        if deduplicated.isEmpty == false {
            streamCandidateCache[cacheKey(for: track)] = deduplicated
            if let approximateDuration = result.approximateDuration {
                authoritativeDurationCache[cacheKey(for: track)] = approximateDuration
            }
            trimStreamCacheIfNeeded()
        }
        return deduplicated
    }

    private func resolveLocalStreamCandidates(for track: Track) async throws -> [URL] {
        let result = try await Self.extractBoundedPlayableStreamCandidates(for: track, methods: [.local])
        let deduplicated = Self.deduplicatedURLs(result.urls)
        if deduplicated.isEmpty == false {
            streamCandidateCache[cacheKey(for: track)] = deduplicated
            if let approximateDuration = result.approximateDuration {
                authoritativeDurationCache[cacheKey(for: track)] = approximateDuration
            }
            trimStreamCacheIfNeeded()
        }
        return deduplicated
    }

    private func resolveRemoteStreamCandidates(for track: Track) async throws -> [URL] {
        let result = try await Self.extractBoundedPlayableStreamCandidates(for: track, methods: [.remote])
        let deduplicated = Self.deduplicatedURLs(result.urls)
        if deduplicated.isEmpty == false {
            streamCandidateCache[cacheKey(for: track)] = deduplicated
            if let approximateDuration = result.approximateDuration {
                authoritativeDurationCache[cacheKey(for: track)] = approximateDuration
            }
            trimStreamCacheIfNeeded()
        }
        return deduplicated
    }

    /// Evicts oldest entries when any unbounded cache exceeds 200 items.
    private func trimStreamCacheIfNeeded() {
        let maxEntries = 200
        let targetEntries = 100
        if streamCandidateCache.count > maxEntries {
            streamCandidateCache.keys
                .prefix(streamCandidateCache.count - targetEntries)
                .forEach { streamCandidateCache.removeValue(forKey: $0) }
        }
        if authoritativeDurationCache.count > maxEntries {
            authoritativeDurationCache.keys
                .prefix(authoritativeDurationCache.count - targetEntries)
                .forEach { authoritativeDurationCache.removeValue(forKey: $0) }
        }
        if streamResolutionFailureTimestamps.count > maxEntries {
            streamResolutionFailureTimestamps.keys
                .prefix(streamResolutionFailureTimestamps.count - targetEntries)
                .forEach { streamResolutionFailureTimestamps.removeValue(forKey: $0) }
        }
    }

    /// Returns true when a YouTube stream URL's `expire` param is within 5 minutes of now.
    private nonisolated static func isStreamURLExpired(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryExpiration = components?.queryItems?
            .first(where: { $0.name == "expire" })?
            .value
            .flatMap(TimeInterval.init)

        // HLS manifests encode expiry as `/expire/<unix timestamp>/` rather than
        // a query item. Parse both forms so a cached manifest is never reused dead.
        let pathComponents = url.pathComponents
        let pathExpiration: TimeInterval? = pathComponents
            .firstIndex(of: "expire")
            .flatMap { index in
                let valueIndex = pathComponents.index(after: index)
                guard valueIndex < pathComponents.endIndex else { return nil }
                return TimeInterval(pathComponents[valueIndex])
            }

        guard let expireTimestamp = queryExpiration ?? pathExpiration else {
            return false // no expiry info — assume still valid
        }
        // Treat as expired if fewer than 5 minutes remain
        return Date().timeIntervalSince1970 > expireTimestamp - 300
    }

    @discardableResult
    /// Returns true if the track failed resolution recently and should be skipped
    /// during background prefetch to avoid hammering YouTube for unavailable content.
    /// Play-initiated (user tap) calls bypass this so the user always gets a fresh attempt.
    private func recentlyFailed(_ track: Track, withinSeconds window: TimeInterval = 60) -> Bool {
        guard let videoID = track.youtubeVideoID,
              let failedAt = streamResolutionFailureTimestamps[videoID] else { return false }
        return Date().timeIntervalSince(failedAt) < window
    }

    private func recordResolutionFailure(for track: Track) {
        guard let videoID = track.youtubeVideoID else { return }
        streamResolutionFailureTimestamps[videoID] = Date()
        trimStreamCacheIfNeeded()
    }

    private func cancelPrefetch(for track: Track) {
        let key = cacheKey(for: track)
        prefetchTasks.removeValue(forKey: key)?.task.cancel()
    }

    private func cancelAllPrefetchTasks(preserving preservedKey: String? = nil) {
        delayedPrefetchTasks.values.forEach { $0.cancel() }
        delayedPrefetchTasks.removeAll()
        let keysToCancel = prefetchTasks.keys.filter { $0 != preservedKey }
        for key in keysToCancel {
            prefetchTasks.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func prepareInteractivePlayback(for track: Track) {
        // A direct selection and a CarPlay/Lock Screen queue command are equally
        // latency-sensitive. Stop unrelated work and promote the selected item so it
        // never waits behind a local-only speculative extraction.
        guard allowsNetworkPlayback(for: track) else { return }
        let selectedKey = cacheKey(for: track)
        cancelAllPrefetchTasks(preserving: track.streamURL == nil ? selectedKey : nil)

        guard track.streamURL == nil else { return }
        _ = enqueueStreamResolutionTaskIfNeeded(
            for: track,
            priority: .high,
            useRemoteFallback: true,
            allowWhileBackgrounded: true
        )
    }

    private func enqueueStreamResolutionTaskIfNeeded(
        for track: Track,
        priority: TaskPriority,
        useRemoteFallback: Bool = false,
        allowWhileBackgrounded: Bool = false
    ) -> Task<[URL], Never>? {
        let key = cacheKey(for: track)

        guard allowWhileBackgrounded || isAppInBackground == false else {
            return nil
        }

        guard useRemoteFallback || AppPowerBudget.allowsSpeculativeNetwork(isAppInBackground: isAppInBackground) else {
            return nil
        }

        if let cached = streamCandidateCache[key], cached.contains(where: { !Self.isStreamURLExpired($0) }) {
            return nil
        }

        // Skip background prefetch for tracks that recently failed — avoids burning
        // quota on genuinely unavailable content. Play-initiated calls (useRemoteFallback)
        // always get a fresh attempt regardless so the user can retry manually.
        if !useRemoteFallback, recentlyFailed(track) {
            return nil
        }

        if let existingPrefetch = prefetchTasks[key] {
            if Self.shouldPromotePrefetch(
                existingUsesRemoteFallback: existingPrefetch.usesRemoteFallback,
                requestedUsesRemoteFallback: useRemoteFallback
            ) {
                // A tap must not queue behind a lower-priority local-only attempt.
                existingPrefetch.task.cancel()
                prefetchTasks.removeValue(forKey: key)
            } else {
                return existingPrefetch.task
            }
        }

        guard track.youtubeVideoID != nil || track.streamURL != nil else { return nil }
        guard allowWhileBackgrounded || prefetchTasks.count < maxActivePrefetchTasks else {
            return nil
        }

        let prefetchID = UUID()
        let task: Task<[URL], Never> = Task(priority: priority) { [weak self, track] in
            guard let self else { return [] }
            defer {
                Task { @MainActor [weak self] in
                    guard self?.prefetchTasks[key]?.id == prefetchID else { return }
                    self?.prefetchTasks.removeValue(forKey: key)
                }
            }

            // For play-initiated (high priority) resolution use both local and remote so
            // we never waste a round-trip on a local-only attempt that then retries remotely.
            let candidates: [URL]
            if useRemoteFallback {
                candidates = (try? await self.resolveFreshStreamCandidates(for: track)) ?? []
            } else {
                candidates = (try? await self.resolveLocalStreamCandidates(for: track)) ?? []
            }
            return candidates.filter { !Self.isStreamURLExpired($0) }
        }

        prefetchTasks[key] = StreamPrefetch(
            id: prefetchID,
            usesRemoteFallback: useRemoteFallback,
            task: task
        )
        return task
    }

    private func prewarmQueue(around track: Track) {
        let isConservativeBackgroundWarmup = isAppInBackground
        let isPlaybackActive = isPlaying || isStartingPlayback
        guard Self.shouldAllowQueueWarmup(
            isAppInBackground: isAppInBackground,
            isCarPlayConnected: isCarPlayConnected,
            isPlaybackActive: isPlaybackActive
        ) else { return }
        if isConservativeBackgroundWarmup {
            guard AppPowerBudget.isLowPowerModeEnabled == false,
                  AppPowerBudget.isThermallyConstrained == false,
                  AppPowerBudget.isLowBattery == false,
                  DataUsageSettings.shared.dataSaverMode == false,
                  DataUsageSettings.shared.canStream(onCellular: NetworkMonitor.shared.isCellular) else { return }
        }
        guard playbackQueue.isEmpty == false else { return }
        guard let currentIndex = playbackQueue.firstIndex(where: { matches($0, track) }) else { return }

        let nextTrackLimit = isConservativeBackgroundWarmup ? 1 : (shuffleMode ? 8 : 3)
        let previousTrackLimit = isConservativeBackgroundWarmup ? 0 : (shuffleMode ? 0 : 1)
        let nextTracks = playbackQueue
            .dropFirst(currentIndex + 1)
            .prefix(nextTrackLimit)

        let previousTracks = playbackQueue
            .prefix(currentIndex)
            .suffix(previousTrackLimit)

        let targetTracks = [track] + Array(nextTracks) + Array(previousTracks)

        for (index, pendingTrack) in targetTracks.enumerated() {
            let priority: TaskPriority
            priority = isConservativeBackgroundWarmup || index < (shuffleMode ? 4 : 2) ? .utility : .background

            // The next 2 tracks are very likely to be played imminently — resolve with
            // remote fallback so they're ready the instant the user skips forward.
            let shouldUseRemoteFallback = isConservativeBackgroundWarmup ? index <= 1 : index < 2
            _ = enqueueStreamResolutionTaskIfNeeded(
                for: pendingTrack,
                priority: priority,
                useRemoteFallback: shouldUseRemoteFallback,
                allowWhileBackgrounded: isConservativeBackgroundWarmup && isCarPlayConnected
            )
        }
    }

    private nonisolated static func extractPlayableStreamCandidates(
        for track: Track,
        methods: [YouTube.ExtractionMethod]
    ) async throws -> StreamResolutionResult {
        if let directURL = track.streamURL {
            return StreamResolutionResult(
                urls: [directURL],
                approximateDuration: preferredAuthoritativeDuration(
                    trackDuration: track.duration,
                    streamURLs: [directURL]
                )
            )
        }

        guard let videoID = track.youtubeVideoID else {
            throw PlaybackError.missingSource
        }

        let youtube = YouTube(videoID: videoID, methods: methods)
        let streams: [Stream]
        do {
            streams = try await youtube.streams
        } catch {
            try Task.checkCancellation()
            let extractedLiveCandidates = (try? await extractLivestreamCandidates(from: youtube)) ?? []
            let liveCandidates = await validatedPlaybackCandidateURLs(extractedLiveCandidates)
            if liveCandidates.isEmpty == false {
                return StreamResolutionResult(
                    urls: liveCandidates,
                    approximateDuration: preferredAuthoritativeDuration(
                        trackDuration: track.duration,
                        streamURLs: liveCandidates
                    )
                )
            }
            throw error
        }

        let preferredStreams = preferredPlaybackStreams(from: streams)
        let extractedURLs = deduplicatedURLs(preferredStreams.map(\.url))
        let candidateURLs = await validatedPlaybackCandidateURLs(extractedURLs)
        let approximateDuration = preferredAuthoritativeDuration(
            trackDuration: track.duration,
            streamDurations: preferredStreams.compactMap(\.approximateDuration)
                + streams.compactMap(\.approximateDuration),
            streamURLs: candidateURLs
        )

        if candidateURLs.isEmpty == false {
            return StreamResolutionResult(urls: candidateURLs, approximateDuration: approximateDuration)
        }

        try Task.checkCancellation()
        let extractedLiveCandidates = try await extractLivestreamCandidates(from: youtube)
        let liveCandidates = await validatedPlaybackCandidateURLs(extractedLiveCandidates)
        if liveCandidates.isEmpty == false {
            return StreamResolutionResult(urls: liveCandidates, approximateDuration: approximateDuration)
        }

        throw PlaybackError.noPlayableStream
    }

    /// Races the available extractors and caps the entire interactive lookup. The
    /// first playable answer wins; a stuck websocket or JavaScript client cannot
    /// keep the user's tap waiting forever.
    private nonisolated static func extractBoundedPlayableStreamCandidates(
        for track: Track,
        methods: [YouTube.ExtractionMethod],
        timeoutNanoseconds: UInt64 = AppConfig.Playback.streamResolutionTimeoutNanoseconds
    ) async throws -> StreamResolutionResult {
        if track.streamURL != nil {
            return try await extractPlayableStreamCandidates(for: track, methods: methods)
        }

        guard methods.isEmpty == false else { throw PlaybackError.noPlayableStream }

        return try await withThrowingTaskGroup(
            of: StreamResolutionAttempt.self,
            returning: StreamResolutionResult.self
        ) { group in
            // Native HLS does not need Google Video Server proof tokens or the local
            // JavaScript signature solver. Race it alongside the legacy extractors;
            // on current YouTube responses it is normally both the fastest and most
            // reliable path for AVPlayer.
            group.addTask {
                do {
                    let result = try await extractFastHLSStreamCandidates(for: track)
                    return .success(result)
                } catch {
                    return .failure
                }
            }

            for method in methods {
                group.addTask {
                    do {
                        let result = try await extractPlayableStreamCandidates(
                            for: track,
                            methods: [method]
                        )
                        return .success(result)
                    } catch {
                        return .failure
                    }
                }
            }

            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return .timedOut
                } catch {
                    return .failure
                }
            }

            var failedExtractors = 0
            let extractorCount = methods.count + 1
            while let attempt = try await group.next() {
                switch attempt {
                case .success(let result) where result.urls.isEmpty == false:
                    group.cancelAll()
                    return result
                case .success, .failure:
                    failedExtractors += 1
                    if failedExtractors == extractorCount {
                        group.cancelAll()
                        throw PlaybackError.noPlayableStream
                    }
                case .timedOut:
                    group.cancelAll()
                    throw PlaybackError.streamResolutionTimedOut
                }
            }

            throw PlaybackError.noPlayableStream
        }
    }

    private nonisolated static func extractFastHLSStreamCandidates(
        for track: Track
    ) async throws -> StreamResolutionResult {
        guard let videoID = track.youtubeVideoID else {
            throw PlaybackError.missingSource
        }

        let youtube = YouTube(videoID: videoID, methods: [.local])
        let extractedURLs = try await youtube.fastNativeHLSStreams.map(\.url)
        let validatedURLs = await validatedPlaybackCandidateURLs(extractedURLs)
        guard validatedURLs.isEmpty == false else {
            throw PlaybackError.noPlayableStream
        }

        return StreamResolutionResult(
            urls: validatedURLs,
            approximateDuration: preferredAuthoritativeDuration(
                trackDuration: track.duration,
                streamURLs: validatedURLs
            )
        )
    }

    /// Verifies a small, bounded set of candidates before AVPlayer is committed to
    /// one. Extraction APIs can return syntactically valid URLs that Google Video
    /// Server rejects with 403; without this probe the UI remains on "Starting…"
    /// until AVFoundation eventually reports `Cannot Open`.
    private nonisolated static func validatedPlaybackCandidateURLs(_ urls: [URL]) async -> [URL] {
        let candidates = Array(deduplicatedURLs(urls).prefix(6))
        guard candidates.isEmpty == false else { return [] }

        return await withTaskGroup(of: (Int, URL?).self, returning: [URL].self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    let isReachable = await isPlaybackCandidateReachable(url)
                    return (index, isReachable ? url : nil)
                }
            }

            var reachable: [(Int, URL)] = []
            for await (index, url) in group {
                if let url {
                    reachable.append((index, url))
                }
            }
            return reachable.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private nonisolated static func isPlaybackCandidateReachable(_ url: URL) async -> Bool {
        guard url.isFileURL == false else { return true }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if isHLSManifestURL(url) {
            // A manifest is small, but HEAD avoids downloading it twice before AVPlayer.
            request.httpMethod = "HEAD"
        } else {
            request.httpMethod = "GET"
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200 || httpResponse.statusCode == 206
        } catch {
            return false
        }
    }

    nonisolated static func isHLSManifestURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "manifest.googlevideo.com"
            || path.hasSuffix(".m3u8")
            || path.contains("/manifest/hls")
    }

    private nonisolated static func extractDownloadStreamCandidates(
        for track: Track,
        methods: [YouTube.ExtractionMethod]
    ) async throws -> StreamResolutionResult {
        if let directURL = track.streamURL {
            return StreamResolutionResult(
                urls: [directURL],
                approximateDuration: preferredAuthoritativeDuration(
                    trackDuration: track.duration,
                    streamURLs: [directURL]
                )
            )
        }

        guard let videoID = track.youtubeVideoID else {
            throw PlaybackError.missingSource
        }

        let youtube = YouTube(videoID: videoID, methods: methods)
        let streams: [Stream]
        do {
            streams = try await youtube.streams
        } catch {
            let liveCandidates = (try? await extractLivestreamCandidates(from: youtube)) ?? []
            if liveCandidates.isEmpty == false {
                return StreamResolutionResult(
                    urls: liveCandidates,
                    approximateDuration: preferredAuthoritativeDuration(
                        trackDuration: track.duration,
                        streamURLs: liveCandidates
                    )
                )
            }
            throw error
        }

        let preferredStreams = preferredDownloadStreams(from: streams)
        let candidateURLs = deduplicatedURLs(preferredStreams.map(\.url))
        let approximateDuration = preferredAuthoritativeDuration(
            trackDuration: track.duration,
            streamDurations: preferredStreams.compactMap(\.approximateDuration)
                + streams.compactMap(\.approximateDuration),
            streamURLs: candidateURLs
        )

        if candidateURLs.isEmpty == false {
            return StreamResolutionResult(urls: candidateURLs, approximateDuration: approximateDuration)
        }

        let liveCandidates = try await extractLivestreamCandidates(from: youtube)
        if liveCandidates.isEmpty == false {
            return StreamResolutionResult(urls: liveCandidates, approximateDuration: approximateDuration)
        }

        throw PlaybackError.noPlayableStream
    }

    private nonisolated static func extractLivestreamCandidates(from youtube: YouTube) async throws -> [URL] {
        let livestreams = try await youtube.livestreams
        return deduplicatedURLs(livestreams.map(\.url))
    }

    private var currentRemoteRepeatType: MPRepeatType {
        switch repeatMode {
        case .off:
            return .off
        case .one:
            return .one
        case .all:
            return .all
        }
    }

    private func applyRepeatType(_ repeatType: MPRepeatType) {
        switch repeatType {
        case .off:
            repeatMode = .off
        case .one:
            repeatMode = .one
        case .all:
            repeatMode = .all
        default:
            break
        }

        updateCommandAvailability()
    }

    private func applyShuffleType(_ shuffleType: MPShuffleType) {
        let shouldShuffle = shuffleType != .off
        guard shuffleMode != shouldShuffle else {
            updateCommandAvailability()
            return
        }

        toggleShuffle()
    }

    private nonisolated static func preferredPlaybackStreams(from streams: [Stream]) -> [Stream] {
        let playableAudioStreams = streams.filter { $0.includesAudioTrack && $0.isNativelyPlayable }
        let unrestrictedStreams = playableAudioStreams.filter {
            $0.includesVideoTrack || isLikelyProofRestrictedAudioURL($0.url) == false
        }
        let candidates = unrestrictedStreams.isEmpty ? playableAudioStreams : unrestrictedStreams

        return candidates
            .sorted { lhs, rhs in
                let lhsScore = playbackPreferenceScore(for: lhs)
                let rhsScore = playbackPreferenceScore(for: rhs)

                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                return (lhs.itag.audioBitrate ?? 0) > (rhs.itag.audioBitrate ?? 0)
            }
    }

    /// YouTube's Google Video Server currently limits proofless long-form URLs from
    /// these clients to an initial byte window. They start normally and then fail near
    /// one minute, so selection must prefer an unrestricted progressive alternative.
    nonisolated static func isLikelyProofRestrictedAudioURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let items = components.queryItems ?? []
        let values = Dictionary(items.map { ($0.name.lowercased(), $0.value ?? "") }) { first, _ in first }
        guard values["pot"]?.isEmpty != false else { return false }

        switch values["c"]?.uppercased() {
        case "IOS", "ANDROID_VR", "MWEB":
            // Remote extractors do not always copy `clen` into the URL. Missing
            // length must be treated as restricted; otherwise the invalid mobile
            // audio stream outranks the accessible progressive/HLS alternative.
            guard let rawLength = values["clen"], let contentLength = Int64(rawLength) else {
                return true
            }
            return contentLength > 1_048_576
        default:
            return false
        }
    }

    private nonisolated static func playbackPreferenceScore(for stream: Stream) -> Int {
        var score = 0

        if stream.includesAudioTrack && stream.includesVideoTrack == false {
            score += 50
        }

        if stream.fileExtension == .m4a {
            score += 40
        } else if stream.fileExtension == .mp4 {
            score += 30
        }

        if stream.audioCodec == .mp4a {
            score += 35
        }

        if let audioBitrate = stream.itag.audioBitrate {
            switch audioBitrate {
            case 96...192:
                score += 18
            case 193...256:
                score += 8
            case let bitrate where bitrate > 256:
                score -= 8
            default:
                break
            }
        }

        if stream.videoCodec == .avc1 {
            score += 10
        }

        if stream.audioCodec == .ec3 || stream.audioCodec == .ac3 {
            score -= 20
        }

        if stream.fileExtension == .m3u8 || stream.itag.isHLS {
            score -= 10
        }

        return score
    }

    private nonisolated static func preferredDownloadStreams(from streams: [Stream]) -> [Stream] {
        streams
            .filter { $0.includesAudioTrack && $0.isNativelyPlayable }
            .filter { $0.includesVideoTrack == false }
            .filter { $0.fileExtension != .m3u8 && !$0.itag.isHLS }
            .sorted { lhs, rhs in
                let lhsScore = downloadPreferenceScore(for: lhs)
                let rhsScore = downloadPreferenceScore(for: rhs)

                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                return (lhs.itag.audioBitrate ?? Int.max) < (rhs.itag.audioBitrate ?? Int.max)
            }
    }

    private nonisolated static func downloadPreferenceScore(for stream: Stream) -> Int {
        var score = 0

        if stream.includesAudioTrack && stream.includesVideoTrack == false {
            score += 80
        } else if stream.includesVideoTrack {
            score -= 80
        }

        if stream.fileExtension == .m4a {
            score += 45
        } else if stream.fileExtension == .mp4 {
            score += 25
        }

        if stream.audioCodec == .mp4a {
            score += 35
        }

        if let audioBitrate = stream.itag.audioBitrate {
            switch audioBitrate {
            case 48...128:
                score += 35
            case 129...192:
                score += 18
            case let bitrate where bitrate > 192:
                score -= 20
            default:
                score += 6
            }
        }

        if stream.audioCodec == .ec3 || stream.audioCodec == .ac3 {
            score -= 30
        }

        if stream.fileExtension == .m3u8 || stream.itag.isHLS {
            score -= 20
        }

        return score
    }

    private nonisolated static func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seenURLs: Set<String> = []
        return urls.filter { url in
            seenURLs.insert(url.absoluteString).inserted
        }
    }

    private func seconds(from time: CMTime?) -> TimeInterval? {
        guard let time else { return nil }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

private enum PlaybackError: LocalizedError {
    case missingSource
    case noPlayableStream
    case streamResolutionTimedOut

    var errorDescription: String? {
        switch self {
        case .missingSource:
            return "No playback source was available for this item."
        case .noPlayableStream:
            return "MusicTube couldn't find a playable audio stream for this YouTube item."
        case .streamResolutionTimedOut:
            return "MusicTube couldn't resolve this audio stream quickly enough."
        }
    }
}

/// Adapts YouTube's large progressive media responses to AVFoundation's resource
/// loading contract. Googlevideo accepts bounded byte ranges but rejects the HEAD
/// and open-ended range probes AVPlayer uses for some long files with HTTP 403.
final class BoundedHTTPStreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private struct PendingRequest {
        let loadingRequest: AVAssetResourceLoadingRequest
        let requestedOffset: Int64
        let finalOffset: Int64
        let rangeLength: Int64
    }

    // Stay comfortably below Googlevideo's per-request range cap. Some CDN
    // nodes reject a 1 MiB request when multiple parser probes overlap.
    static let maximumRangeLength: Int64 = 512 * 1_024
    private static let minimumRetryRangeLength: Int64 = 64 * 1_024

    private let sourceURL: URL
    private let interceptedURL: URL
    private var contentLength: Int64?
    private let contentType: String
    private let callbackQueue = DispatchQueue(label: "com.majdinagi.musicTube.playback-range-loader")
    private var pendingRequests: [Int: PendingRequest] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.majdinagi.musicTube.playback-range-session"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = callbackQueue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    lazy var asset: AVURLAsset = {
        let asset = AVURLAsset(
            url: interceptedURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        asset.resourceLoader.setDelegate(self, queue: callbackQueue)
        return asset
    }()

    init?(sourceURL: URL) {
        guard let scheme = sourceURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = sourceURL.host?.lowercased(), host.hasSuffix(".googlevideo.com") else {
            return nil
        }
        guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let queryItems = components.queryItems ?? []
        let contentLength = queryItems
            .first(where: { $0.name == "clen" })?.value
            .flatMap(Int64.init)
            .flatMap { $0 > 0 ? $0 : nil }

        let mimeType = queryItems.first(where: { $0.name == "mime" })?.value ?? "audio/mp4"
        var interceptedComponents = components
        interceptedComponents.scheme = "musictube-stream"
        guard let interceptedURL = interceptedComponents.url else { return nil }

        self.sourceURL = sourceURL
        self.interceptedURL = interceptedURL
        self.contentLength = contentLength
        self.contentType = UTType(mimeType: mimeType)?.identifier
            ?? (mimeType.hasPrefix("audio/") ? "public.audio" : "public.movie")
        super.init()
    }

    func invalidate() {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.pendingRequests.values.forEach { pending in
                pending.loadingRequest.finishLoading(with: URLError(.cancelled))
            }
            self.pendingRequests.removeAll()
            self.session.invalidateAndCancel()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        populateContentInformation(on: loadingRequest.contentInformationRequest)

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let requestedOffset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        guard requestedOffset >= 0,
              contentLength.map({ requestedOffset < $0 }) ?? true else {
            loadingRequest.finishLoading(with: URLError(.badServerResponse))
            return true
        }

        let requestedLength = max(1, Int64(dataRequest.requestedLength))
        let finalOffset: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            finalOffset = contentLength.map { $0 - 1 } ?? Int64.max
        } else {
            let requestedFinalOffset = requestedOffset + requestedLength - 1
            finalOffset = contentLength.map { min($0 - 1, requestedFinalOffset) }
                ?? requestedFinalOffset
        }
        startDataTask(for: loadingRequest, from: requestedOffset, through: finalOffset)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let entry = pendingRequests.first(where: { $0.value.loadingRequest === loadingRequest }) else {
            return
        }
        pendingRequests.removeValue(forKey: entry.key)
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == entry.key })?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let pending = pendingRequests[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 206 || (httpResponse.statusCode == 200 && pending.requestedOffset == 0) else {
            pendingRequests.removeValue(forKey: dataTask.taskIdentifier)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if statusCode == 403, pending.rangeLength > Self.minimumRetryRangeLength {
                // CDN range limits can vary by node and by concurrent parser probes.
                // Retry the same bytes with a smaller bounded request before failing
                // the player item or moving to a lower-quality stream candidate.
                completionHandler(.cancel)
                startDataTask(
                    for: pending.loadingRequest,
                    from: pending.requestedOffset,
                    through: pending.finalOffset,
                    maximumLength: max(Self.minimumRetryRangeLength, pending.rangeLength / 2)
                )
                return
            }
            let error = NSError(
                domain: "MusicTube.StreamLoader",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Media server returned HTTP \(statusCode)."]
            )
            pending.loadingRequest.finishLoading(with: error)
            completionHandler(.cancel)
            return
        }

        updateContentLength(from: httpResponse)
        populateContentInformation(on: pending.loadingRequest.contentInformationRequest)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pendingRequests[dataTask.taskIdentifier]?.loadingRequest.dataRequest?.respond(with: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let pending = pendingRequests.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            pending.loadingRequest.finishLoading(with: error)
        } else if let dataRequest = pending.loadingRequest.dataRequest {
            let knownFinalOffset = contentLength.map { min(pending.finalOffset, $0 - 1) }
                ?? pending.finalOffset
            guard dataRequest.currentOffset <= knownFinalOffset else {
                pending.loadingRequest.finishLoading()
                return
            }
            startDataTask(
                for: pending.loadingRequest,
                from: dataRequest.currentOffset,
                through: knownFinalOffset
            )
        } else {
            pending.loadingRequest.finishLoading()
        }
    }

    private func startDataTask(
        for loadingRequest: AVAssetResourceLoadingRequest,
        from requestedOffset: Int64,
        through finalOffset: Int64,
        maximumLength: Int64 = BoundedHTTPStreamLoader.maximumRangeLength
    ) {
        let rangeEnd = min(finalOffset, requestedOffset + maximumLength - 1)
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=\(requestedOffset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        pendingRequests[task.taskIdentifier] = PendingRequest(
            loadingRequest: loadingRequest,
            requestedOffset: requestedOffset,
            finalOffset: finalOffset,
            rangeLength: maximumLength
        )
        task.resume()
    }

    private func populateContentInformation(
        on request: AVAssetResourceLoadingContentInformationRequest?
    ) {
        guard let request else { return }
        request.contentType = contentType
        if let contentLength {
            request.contentLength = contentLength
        }
        request.isByteRangeAccessSupported = true
    }

    private func updateContentLength(from response: HTTPURLResponse) {
        guard contentLength == nil,
              let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              let totalText = contentRange.split(separator: "/").last,
              let total = Int64(totalText), total > 0 else {
            return
        }
        contentLength = total
    }
}

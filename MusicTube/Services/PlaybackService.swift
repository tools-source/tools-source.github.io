import AVFoundation
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class PlaybackService: NSObject, ObservableObject, PlaybackControlling {
    enum RepeatMode: String, CaseIterable {
        case off, one, all
    }

    @Published private(set) var nowPlaying: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var isResolvingStream = false
    @Published private(set) var playbackErrorMessage: String?
    @Published private(set) var hasNextTrack = false
    @Published private(set) var hasPreviousTrack = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var shuffleMode: Bool = false
    @Published var repeatMode: RepeatMode = .off

    private var originalQueue: [Track] = []

    private var player: AVPlayer?
    private var activeStreamURL: URL?
    private var playbackObservation: NSKeyValueObservation?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var playerItemDurationObservation: NSKeyValueObservation?
    private var playbackStartupTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?
    private var timeObserverToken: Any?
    private var isSeekInProgress = false
    private var chaseTime: CMTime = .zero
    private var playbackEndWatchdogTask: Task<Void, Never>?
    private var lastObservedTime: TimeInterval = 0
    private var playbackQueue: [Track] = []
    private var playbackQueueIndex: Int?
    private var itemDidEndObserver: NSObjectProtocol?
    private var itemFailedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var stallRecoveryTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var streamCandidateCache: [String: [URL]] = [:]
    private var authoritativeDurationCache: [String: TimeInterval] = [:]
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private let artworkCache = NSCache<NSURL, UIImage>()

    override init() {
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSessionInterruptions()
    }

    func play(track: Track) {
        play(track: track, queue: nil)
    }

    func play(track: Track, queue: [Track]?) {
        configureQueue(for: track, queue: queue)

        if let currentTrack = nowPlaying, matches(currentTrack, track), player != nil {
            resume()
            return
        }

        startPlayback(for: track)
    }

    func playNextTrack() {
        guard let playbackQueueIndex, playbackQueueIndex + 1 < playbackQueue.count else { return }
        let nextIndex = playbackQueueIndex + 1
        self.playbackQueueIndex = nextIndex
        updateQueueState()
        startPlayback(for: playbackQueue[nextIndex])
    }

    func playPreviousTrack() {
        if let player, player.currentTime().seconds > 5 {
            player.seek(to: .zero)
            if isPlaying == false {
                player.play()
                setIsPlaying(true)
                updatePlaybackState()
            }
            return
        }

        guard let playbackQueueIndex else { return }

        if playbackQueueIndex > 0 {
            let previousIndex = playbackQueueIndex - 1
            self.playbackQueueIndex = previousIndex
            updateQueueState()
            startPlayback(for: playbackQueue[previousIndex])
            return
        }

        player?.seek(to: .zero)
        updatePlaybackState()
    }

    func toggleShuffle() {
        shuffleMode.toggle()
        guard playbackQueue.isEmpty == false else { return }

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
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Eagerly warms the stream cache for a list of tracks (call when tracks first appear on screen).
    func prefetchStreams(for tracks: [Track]) {
        let candidates = tracks
            .filter { $0.youtubeVideoID != nil && $0.streamURL == nil }
            .prefix(6)                      // warm top 6 to keep memory reasonable

        for track in candidates {
            let key = cacheKey(for: track)
            guard streamCandidateCache[key] == nil, prefetchTasks[key] == nil else { continue }

            prefetchTasks[key] = Task { [weak self, track] in
                guard let self else { return }
                defer { Task { @MainActor in self.prefetchTasks.removeValue(forKey: key) } }
                _ = try? await self.resolveAndCacheStreamCandidates(for: track)
            }
        }
    }

    /// Resolves the best audio stream URL for a track (used by DownloadService).
    func resolveStreamURL(for track: Track) async throws -> URL? {
        let candidates = try await resolveAndCacheStreamCandidates(for: track)
        return candidates.first
    }

    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        isResolvingStream = false
        playbackErrorMessage = nil
        tearDownPlayer()
        nowPlaying = nil
        setIsPlaying(false)
        setCurrentTime(0, threshold: 0)
        setDuration(0, threshold: 0)
        playbackQueue = []
        playbackQueueIndex = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks = [:]
        nowPlayingInfoCenter.nowPlayingInfo = nil
        nowPlayingInfoCenter.playbackState = .stopped
        deactivateAudioSession()
        updateQueueState()
    }

    private func startPlayback(for track: Track) {
        resolveTask?.cancel()
        resolveTask = nil
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        playbackErrorMessage = nil
        nowPlaying = track
        setCurrentTime(0, threshold: 0)
        if let authoritativeDuration = authoritativeDuration(for: track) {
            setDuration(authoritativeDuration, threshold: 0)
        } else {
            setDuration(0, threshold: 0)
        }
        updateNowPlayingInfo(for: track)
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
                    let resolvedURLs = try await self.resolveAndCacheStreamCandidates(for: track)

                    guard Task.isCancelled == false else { return }
                    guard self.nowPlaying?.id == track.id else { return }

                    self.startPlayback(fromCandidates: resolvedURLs, for: track)
                } catch is CancellationError {
                    guard self.nowPlaying?.id == track.id else { return }
                    self.isResolvingStream = false
                    self.updatePlaybackState()
                } catch {
                    guard self.nowPlaying?.id == track.id else { return }
                    self.isResolvingStream = false
                    self.setIsPlaying(false)
                    self.playbackErrorMessage = "MusicTube couldn't extract audio for this YouTube item right now."
                    self.updatePlaybackState()
                }
            }
        } else {
            isResolvingStream = false
            setIsPlaying(false)
            updatePlaybackState()
        }
    }

    func resume() {
        playbackErrorMessage = nil

        if isResolvingStream {
            return
        }

        if let player {
            activateAudioSessionIfNeeded()
            player.play()
            setIsPlaying(true)
            updatePlaybackState()
            return
        }

        if let track = nowPlaying {
            play(track: track, queue: playbackQueue.isEmpty ? nil : playbackQueue)
        }
    }

    func pause() {
        resolveTask?.cancel()
        resolveTask = nil
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        isResolvingStream = false
        player?.pause()
        setIsPlaying(false)
        updatePlaybackState()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }

        let boundedDuration = duration.isFinite && duration > 0 ? duration : time
        let clampedTime = max(0, min(time, boundedDuration))
        let targetTime = CMTime(seconds: clampedTime, preferredTimescale: 600)

        isSeekInProgress = true
        chaseTime = targetTime
        setCurrentTime(clampedTime, threshold: 0)
        updatePlaybackState()
        performSeekToChaseTime()
    }

    private func performSeekToChaseTime() {
        guard let player else { isSeekInProgress = false; return }
        let seekTarget = chaseTime
        player.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if CMTimeCompare(seekTarget, self.chaseTime) == 0 {
                    self.isSeekInProgress = false
                    self.lastObservedTime = CMTimeGetSeconds(seekTarget)
                } else {
                    self.performSeekToChaseTime()
                }
            }
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
            try session.setActive(true)
        } catch {
            do {
                try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
                try session.setActive(true)
            } catch {
                print("Failed to configure audio session: \(error)")
            }
        }
    }

    private func configureRemoteCommands() {
        [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.togglePlayPauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
            commandCenter.changePlaybackPositionCommand
        ].forEach { $0.removeTarget(nil) }

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.resume()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayback()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.playNextTrack()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.playPreviousTrack()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor in
                self?.seek(to: event.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo(for track: Track) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: playbackQueueIndex ?? 0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: playbackQueue.count
        ]

        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = currentNowPlayingPlaybackState()
        loadArtworkForNowPlaying(track)
    }

    private func updatePlaybackState() {
        var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = playbackQueueIndex ?? 0
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = playbackQueue.count

        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }

        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = currentNowPlayingPlaybackState()
        updateCommandAvailability()
        updateQueueState()
    }

    private func tearDownPlayer() {
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil
        isSeekInProgress = false
        playerItemStatusObservation = nil
        playerItemDurationObservation = nil
        playbackObservation = nil
        removeTimeObserver()
        player?.pause()
        player = nil
        activeStreamURL = nil
        removeItemDidEndObserver()
        removeItemFailedObserver()
        removeStalledObserver()
    }

    private func startPlayback(
        fromCandidates candidateURLs: [URL],
        for track: Track,
        candidateIndex: Int = 0,
        resumeTime: TimeInterval = 0
    ) {
        let uniqueCandidates = deduplicatedURLs(candidateURLs)

        guard candidateIndex < uniqueCandidates.count else {
            tearDownPlayer()
            isResolvingStream = false
            setIsPlaying(false)
            playbackErrorMessage = "MusicTube couldn't start audio for this YouTube item right now."
            updatePlaybackState()
            return
        }

        let url = uniqueCandidates[candidateIndex]
        tearDownPlayer()
        isResolvingStream = false
        activeStreamURL = url
        if let authoritativeDuration = authoritativeDuration(for: track) {
            setDuration(authoritativeDuration, threshold: 0)
        }

        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Larger buffer = fewer mid-song re-requests to YouTube CDN
        playerItem.preferredForwardBufferDuration = 120
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        self.player = player
        registerItemDidEndObserver(for: playerItem)
        registerItemFailedObserver(for: playerItem, track: track)
        registerStalledObserver(for: playerItem, track: track)
        observeDuration(for: playerItem, track: track)
        installTimeObserver(on: player)
        activateAudioSessionIfNeeded()

        playerItemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.nowPlaying?.id == track.id else { return }

                switch item.status {
                case .failed:
                    self.startPlayback(
                        fromCandidates: uniqueCandidates,
                        for: track,
                        candidateIndex: candidateIndex + 1,
                        resumeTime: resumeTime
                    )
                case .readyToPlay:
                    self.playbackStartupTask?.cancel()
                    self.playbackStartupTask = nil
                    if let duration = self.preferredDuration(for: track, reportedDuration: self.seconds(from: item.duration)) {
                        self.setDuration(duration)
                    }
                    // Resume from position after stream recovery
                    if resumeTime > 1 {
                        let target = CMTime(seconds: resumeTime, preferredTimescale: 600)
                        self.player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                        self.setCurrentTime(resumeTime, threshold: 0)
                    }
                    self.updatePlaybackState()
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.setIsPlaying(self.shouldPresentAsPlaying(player))
                if player.timeControlStatus == .playing {
                    self.playbackStartupTask?.cancel()
                    self.playbackStartupTask = nil
                }
                self.updatePlaybackState()
            }
        }

        updateNowPlayingInfo(for: track)
        player.play()
        setIsPlaying(true)
        updatePlaybackState()

        playbackStartupTask = Task { [weak self, weak player] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, let player else { return }
            guard Task.isCancelled == false else { return }
            guard self.nowPlaying?.id == track.id else { return }

            if player.timeControlStatus != .playing,
               player.currentItem?.status != .readyToPlay {
                self.startPlayback(
                    fromCandidates: uniqueCandidates,
                    for: track,
                    candidateIndex: candidateIndex + 1,
                    resumeTime: resumeTime
                )
            }
        }

        updatePlaybackState()
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
        let nextTrackAvailable = playbackQueueIndex.map { $0 < playbackQueue.count - 1 } ?? false
        let previousTrackAvailable = nowPlaying != nil

        if hasNextTrack != nextTrackAvailable {
            hasNextTrack = nextTrackAvailable
        }

        if hasPreviousTrack != previousTrackAvailable {
            hasPreviousTrack = previousTrackAvailable
        }

        updateCommandAvailability()
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
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil

        switch repeatMode {
        case .one:
            player?.seek(to: .zero)
            player?.play()
            setIsPlaying(true)
            setCurrentTime(0, threshold: 0)
            updatePlaybackState()
        case .all:
            if hasNextTrack {
                playNextTrack()
            } else if playbackQueue.isEmpty == false {
                playbackQueueIndex = 0
                updateQueueState()
                startPlayback(for: playbackQueue[0])
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

    private func removeItemDidEndObserver() {
        if let itemDidEndObserver {
            NotificationCenter.default.removeObserver(itemDidEndObserver)
            self.itemDidEndObserver = nil
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
            // Give AVPlayer 30 s to recover on its own (it often does on slow connections)
            try? await Task.sleep(nanoseconds: 30_000_000_000)
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
        isResolvingStream = true
        resolveTask?.cancel()
        resolveTask = Task { [weak self, track, time] in
            guard let self else { return }
            do {
                let freshURLs = try await self.resolveAndCacheStreamCandidates(for: track)
                guard Task.isCancelled == false, self.nowPlaying?.id == track.id else { return }
                self.startPlayback(fromCandidates: freshURLs, for: track, resumeTime: time)
            } catch {
                guard self.nowPlaying?.id == track.id else { return }
                self.isResolvingStream = false
                self.setIsPlaying(false)
                self.playbackErrorMessage = "Stream interrupted. Tap play to retry."
                self.updatePlaybackState()
            }
        }
    }

    private func installTimeObserver(on player: AVPlayer) {
        removeTimeObserver()
        lastObservedTime = 0

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                // Discard callbacks from a player that has already been torn down
                guard self.player === player else { return }

                let updatedTime = CMTimeGetSeconds(time)
                if !self.isSeekInProgress, updatedTime.isFinite {
                    self.setCurrentTime(max(0, updatedTime))
                    self.checkForDASHPlaybackEnd(currentTime: updatedTime, player: player)
                    self.lastObservedTime = updatedTime
                }

                // Only update duration from the player item if we don't already have a
                // trustworthy value — avoids overwriting the asset-corrected duration
                // with the (potentially 2×-inflated) KVO value on every tick.
                if self.duration == 0,
                   let track = self.nowPlaying,
                   let itemDuration = self.preferredDuration(
                        for: track,
                        reportedDuration: self.seconds(from: player.currentItem?.duration)
                   ) {
                    self.setDuration(itemDuration)
                }

                self.updatePlaybackState()
            }
        }
    }

    /// Watchdog for YouTube DASH audio-only streams whose reported duration is shorter than
    /// actual playback — `AVPlayerItemDidPlayToEndTime` never fires in that case.
    /// Detects end-of-stream by checking the playhead has stopped advancing near duration.
    private func checkForDASHPlaybackEnd(currentTime: TimeInterval, player: AVPlayer) {
        guard duration > 0, isPlaying else { return }
        // Only arm the watchdog within the last 5 seconds of reported duration
        guard currentTime >= duration - 5 else {
            playbackEndWatchdogTask?.cancel()
            playbackEndWatchdogTask = nil
            return
        }
        guard playbackEndWatchdogTask == nil else { return }

        playbackEndWatchdogTask = Task { [weak self, weak player] in
            // Wait two ticks (1 second) then check if playhead has stalled
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let player else { return }

            let newTime = CMTimeGetSeconds(player.currentTime())
            let timeAdvanced = abs(newTime - self.lastObservedTime) > 0.1
            let playerStillThinkingItsPlaying = player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate

            if !timeAdvanced, playerStillThinkingItsPlaying {
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

        // Some YouTube DASH audio streams report an inflated duration through AVPlayer.
        // Prefer YouTube's own duration metadata when we have it, otherwise fall back to
        // the asset container duration if it looks more trustworthy than the player item.
        Task { [weak self, weak item, track] in
            guard let asset = item?.asset as? AVURLAsset else { return }
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

    private func setIsPlaying(_ newValue: Bool) {
        guard isPlaying != newValue else { return }
        isPlaying = newValue
    }

    private func setCurrentTime(_ newValue: TimeInterval, threshold: TimeInterval = 0.05) {
        let clampedValue = duration > 0 ? max(0, min(newValue, duration)) : max(0, newValue)
        guard abs(currentTime - clampedValue) > threshold else { return }
        currentTime = clampedValue
    }

    private func setDuration(_ newValue: TimeInterval, threshold: TimeInterval = 0.05) {
        let normalizedValue = max(0, newValue)
        guard abs(duration - normalizedValue) > threshold else { return }
        duration = normalizedValue
    }

    private func shouldPresentAsPlaying(_ player: AVPlayer) -> Bool {
        switch player.timeControlStatus {
        case .paused:
            return false
        case .playing, .waitingToPlayAtSpecifiedRate:
            return true
        @unknown default:
            return player.rate != 0
        }
    }

    private func currentNowPlayingPlaybackState() -> MPNowPlayingPlaybackState {
        guard nowPlaying != nil else { return .stopped }
        return isPlaying ? .playing : .paused
    }

    private func loadArtworkForNowPlaying(_ track: Track) {
        artworkLoadTask?.cancel()
        artworkLoadTask = nil

        guard let artworkURL = track.artworkURL else {
            var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            nowPlayingInfoCenter.nowPlayingInfo = info
            return
        }

        if let cachedImage = artworkCache.object(forKey: artworkURL as NSURL) {
            setNowPlayingArtwork(cachedImage)
            return
        }

        artworkLoadTask = Task { [weak self, artworkURL, track] in
            guard let self else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: artworkURL)
                guard Task.isCancelled == false else { return }
                guard let image = UIImage(data: data) else { return }

                self.artworkCache.setObject(image, forKey: artworkURL as NSURL)

                guard self.nowPlaying?.id == track.id else { return }
                self.setNowPlayingArtwork(image)
            } catch {
                return
            }
        }
    }

    private func setNowPlayingArtwork(_ image: UIImage) {
        // CarPlay and Lock Screen require a square image with a standard boundsSize.
        // YouTube thumbnails are 16:9; passing a non-square boundsSize makes CarPlay
        // silently skip the artwork. Normalize to 600×600 square by center-cropping.
        let side: CGFloat = 600
        let squareSize = CGSize(width: side, height: side)
        let squareImage = UIGraphicsImageRenderer(size: squareSize).image { ctx in
            let srcRatio = image.size.width / image.size.height
            let drawRect: CGRect
            if srcRatio > 1 {
                // landscape: fit height, center-crop width
                let w = side * srcRatio
                drawRect = CGRect(x: -(w - side) / 2, y: 0, width: w, height: side)
            } else {
                // portrait or square: fit width, center-crop height
                let h = side / srcRatio
                drawRect = CGRect(x: 0, y: -(h - side) / 2, width: side, height: h)
            }
            image.draw(in: drawRect)
        }
        let artwork = MPMediaItemArtwork(boundsSize: squareSize) { size in
            UIGraphicsImageRenderer(size: size).image { _ in squareImage.draw(in: CGRect(origin: .zero, size: size)) }
        }
        var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        nowPlayingInfoCenter.nowPlayingInfo = info
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
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to reactivate audio session: \(error)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }

    private func updateCommandAvailability() {
        commandCenter.nextTrackCommand.isEnabled = hasNextTrack
        commandCenter.previousTrackCommand.isEnabled = hasPreviousTrack
        commandCenter.changePlaybackPositionCommand.isEnabled = duration > 0
    }

    private func cachedStreamCandidates(for track: Track) -> [URL]? {
        streamCandidateCache[cacheKey(for: track)]
    }

    private func cacheKey(for track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func authoritativeDuration(for track: Track) -> TimeInterval? {
        let cachedDuration = authoritativeDurationCache[cacheKey(for: track)]
        let trackDuration = track.duration

        for candidate in [cachedDuration, trackDuration] {
            if let candidate, candidate.isFinite, candidate > 0 {
                return candidate
            }
        }

        return nil
    }

    private func preferredDuration(for track: Track, reportedDuration: TimeInterval?) -> TimeInterval? {
        if let authoritativeDuration = authoritativeDuration(for: track) {
            return authoritativeDuration
        }

        return reportedDuration
    }

    private func resolveAndCacheStreamCandidates(for track: Track) async throws -> [URL] {
        let key = cacheKey(for: track)
        if let cached = cachedStreamCandidates(for: track), cached.isEmpty == false {
            // Filter out any URLs whose YouTube `expire` timestamp is within 5 minutes
            let stillValid = cached.filter { !isStreamURLExpired($0) }
            if stillValid.isEmpty == false {
                return stillValid
            }
            // All cached URLs are expired — evict and re-resolve
            streamCandidateCache.removeValue(forKey: key)
        }

        let candidates = try await extractPlayableStreamCandidates(for: track)
        let deduplicated = deduplicatedURLs(candidates)
        if deduplicated.isEmpty == false {
            streamCandidateCache[key] = deduplicated
        }
        return deduplicated
    }

    /// Returns true when a YouTube stream URL's `expire` param is within 5 minutes of now.
    private func isStreamURLExpired(_ url: URL) -> Bool {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let expireItem = components.queryItems?.first(where: { $0.name == "expire" }),
            let expireString = expireItem.value,
            let expireTimestamp = TimeInterval(expireString)
        else {
            return false   // no expiry info — assume still valid
        }
        // Treat as expired if fewer than 5 minutes remain
        return Date().timeIntervalSince1970 > expireTimestamp - 300
    }

    private func prewarmQueue(around track: Track) {
        guard playbackQueue.isEmpty == false else { return }

        let targetTracks = playbackQueue
            .filter { matches($0, track) == false }
            .prefix(3)

        for pendingTrack in targetTracks {
            guard pendingTrack.youtubeVideoID != nil else { continue }

            let key = cacheKey(for: pendingTrack)
            guard streamCandidateCache[key] == nil, prefetchTasks[key] == nil else { continue }

            prefetchTasks[key] = Task { [weak self, pendingTrack] in
                guard let self else { return }
                defer { self.prefetchTasks.removeValue(forKey: key) }
                _ = try? await self.resolveAndCacheStreamCandidates(for: pendingTrack)
            }
        }
    }

    private func extractPlayableStreamCandidates(for track: Track) async throws -> [URL] {
        if let directURL = track.streamURL {
            return [directURL]
        }

        guard let videoID = track.youtubeVideoID else {
            throw PlaybackError.missingSource
        }

        let youtube = YouTube(videoID: videoID, methods: [.local, .remote])
        let streams = try await youtube.streams
        let preferredStreams = preferredPlaybackStreams(from: streams)
        let candidateURLs = deduplicatedURLs(preferredStreams.map(\.url))

        if let approximateDuration = preferredStreams
            .compactMap(\.approximateDuration)
            .first(where: { $0.isFinite && $0 > 0 })
            ?? streams.compactMap(\.approximateDuration).first(where: { $0.isFinite && $0 > 0 }) {
            authoritativeDurationCache[cacheKey(for: track)] = approximateDuration
        }

        if candidateURLs.isEmpty == false {
            return candidateURLs
        }

        throw PlaybackError.noPlayableStream
    }

    private func preferredPlaybackStreams(from streams: [Stream]) -> [Stream] {
        streams
            .filter { $0.includesAudioTrack && $0.isNativelyPlayable }
            .sorted { lhs, rhs in
                let lhsScore = playbackPreferenceScore(for: lhs)
                let rhsScore = playbackPreferenceScore(for: rhs)

                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                return (lhs.itag.audioBitrate ?? 0) > (rhs.itag.audioBitrate ?? 0)
            }
    }

    private func playbackPreferenceScore(for stream: Stream) -> Int {
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

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
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

    var errorDescription: String? {
        switch self {
        case .missingSource:
            return "No playback source was available for this item."
        case .noPlayableStream:
            return "MusicTube couldn't find a playable audio stream for this YouTube item."
        }
    }
}

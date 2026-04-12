import AVFoundation
import Foundation
import MediaPlayer

@MainActor
final class PlaybackService: NSObject, ObservableObject, PlaybackControlling {
    @Published private(set) var nowPlaying: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var isResolvingStream = false
    @Published private(set) var playbackErrorMessage: String?
    @Published private(set) var hasNextTrack = false
    @Published private(set) var hasPreviousTrack = false

    private var player: AVPlayer?
    private var activeStreamURL: URL?
    private var playbackObservation: NSKeyValueObservation?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var playbackStartupTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var playbackQueue: [Track] = []
    private var playbackQueueIndex: Int?
    private var itemDidEndObserver: NSObjectProtocol?
    private let commandCenter = MPRemoteCommandCenter.shared()

    override init() {
        super.init()
        configureAudioSession()
        configureRemoteCommands()
    }

    func play(track: Track) {
        play(track: track, queue: nil)
    }

    func play(track: Track, queue: [Track]?) {
        configureQueue(for: track, queue: queue)
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
                isPlaying = true
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

    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        isResolvingStream = false
        playbackErrorMessage = nil
        tearDownPlayer()
        nowPlaying = nil
        isPlaying = false
        playbackQueue = []
        playbackQueueIndex = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateQueueState()
    }

    private func startPlayback(for track: Track) {
        resolveTask?.cancel()
        resolveTask = nil
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        playbackErrorMessage = nil
        nowPlaying = track
        updateNowPlayingInfo(for: track)
        tearDownPlayer()

        if let streamURL = track.streamURL {
            startPlayback(fromCandidates: [streamURL], for: track)
        } else if track.youtubeVideoID != nil {
            isResolvingStream = true
            updatePlaybackState()

            resolveTask = Task { [weak self, track] in
                guard let self else { return }

                do {
                    let resolvedURLs = try await self.extractPlayableStreamCandidates(for: track)

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
                    self.isPlaying = false
                    self.playbackErrorMessage = "MusicTube couldn't extract audio for this YouTube item right now."
                    self.updatePlaybackState()
                }
            }
        } else {
            isResolvingStream = false
            isPlaying = false
            updatePlaybackState()
        }
    }

    func resume() {
        playbackErrorMessage = nil

        if isResolvingStream {
            return
        }

        if let player {
            player.play()

            if player.rate != 0 {
                isPlaying = true
                updatePlaybackState()
            }
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
        isPlaying = false
        updatePlaybackState()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    private func configureRemoteCommands() {
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false

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
    }

    private func updateNowPlayingInfo(for track: Track) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: playbackQueueIndex ?? 0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: playbackQueue.count
        ]
    }

    private func updatePlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.currentTime().seconds ?? 0
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = playbackQueueIndex ?? 0
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = playbackQueue.count
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateQueueState()
    }

    private func tearDownPlayer() {
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        playerItemStatusObservation = nil
        playbackObservation = nil
        player?.pause()
        player = nil
        activeStreamURL = nil
        removeItemDidEndObserver()
    }

    private func startPlayback(fromCandidates candidateURLs: [URL], for track: Track, candidateIndex: Int = 0) {
        let uniqueCandidates = deduplicatedURLs(candidateURLs)

        guard candidateIndex < uniqueCandidates.count else {
            tearDownPlayer()
            isResolvingStream = false
            isPlaying = false
            playbackErrorMessage = "MusicTube couldn't start audio for this YouTube item right now."
            updatePlaybackState()
            return
        }

        let url = uniqueCandidates[candidateIndex]
        tearDownPlayer()
        isResolvingStream = false
        activeStreamURL = url

        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        registerItemDidEndObserver(for: playerItem)

        playerItemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.nowPlaying?.id == track.id else { return }

                switch item.status {
                case .failed:
                    self.startPlayback(
                        fromCandidates: uniqueCandidates,
                        for: track,
                        candidateIndex: candidateIndex + 1
                    )
                case .readyToPlay:
                    self.playbackStartupTask?.cancel()
                    self.playbackStartupTask = nil
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
                self.isPlaying = player.timeControlStatus == .playing
                if player.timeControlStatus == .playing {
                    self.playbackStartupTask?.cancel()
                    self.playbackStartupTask = nil
                }
                self.updatePlaybackState()
            }
        }

        updateNowPlayingInfo(for: track)
        player.play()
        isPlaying = false
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
                    candidateIndex: candidateIndex + 1
                )
            }
        }

        updatePlaybackState()
    }

    private func configureQueue(for track: Track, queue: [Track]?) {
        let normalizedQueue = normalizeQueue(queue ?? [track], selectedTrack: track)
        playbackQueue = normalizedQueue
        playbackQueueIndex = normalizedQueue.firstIndex(where: { matches($0, track) }) ?? 0
        updateQueueState()
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
        hasNextTrack = playbackQueueIndex.map { $0 < playbackQueue.count - 1 } ?? false
        hasPreviousTrack = nowPlaying != nil
        commandCenter.nextTrackCommand.isEnabled = hasNextTrack
        commandCenter.previousTrackCommand.isEnabled = hasPreviousTrack
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
                guard let self else { return }

                if self.hasNextTrack {
                    self.playNextTrack()
                } else {
                    self.isPlaying = false
                    self.updatePlaybackState()
                }
            }
        }
    }

    private func removeItemDidEndObserver() {
        if let itemDidEndObserver {
            NotificationCenter.default.removeObserver(itemDidEndObserver)
            self.itemDidEndObserver = nil
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
        let candidateURLs = deduplicatedURLs(
            preferredPlaybackStreams(from: streams).map(\.url)
        )

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

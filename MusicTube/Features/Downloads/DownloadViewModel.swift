import Combine
import Foundation

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published private(set) var snapshot: DownloadSnapshot = .empty

    private let appState: AppState
    private let service: DownloadService
    private var selectedFolderID: String?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState, service: DownloadService? = nil) {
        self.appState = appState
        self.service = service ?? .shared
        observeRelevantState()
        rebuildSnapshot()
    }

    func appear() {
        service.refreshDownloadsFromDisk()
    }

    func selectFolder(_ folderID: String?) {
        selectedFolderID = folderID
        rebuildSnapshot()
    }

    func createFolder(named name: String) {
        service.createFolder(named: name)
    }

    func renameFolder(_ folder: DownloadFolder, to name: String) {
        service.renameFolder(folder, to: name)
    }

    func deleteFolder(_ folder: DownloadFolder) {
        if selectedFolderID == folder.id { selectedFolderID = nil }
        service.deleteFolder(folder)
    }

    func pauseOrResume(_ download: DownloadProgressPresentation) {
        if download.isPaused {
            service.resumeDownload(for: download.track)
        } else {
            service.pauseDownload(for: download.track)
        }
    }

    func cancel(_ download: DownloadProgressPresentation) {
        service.cancelDownload(for: download.track)
    }

    func cancelAll() {
        service.cancelAllDownloads()
    }

    func delete(_ record: DownloadRecord) {
        service.deleteDownload(record)
    }

    func move(_ record: DownloadRecord, to folderID: String?) {
        service.moveDownload(record, to: folderID)
    }

    func move(recordIDs: Set<String>, to folderID: String?) {
        for record in service.downloads where recordIDs.contains(record.id) {
            service.moveDownload(record, to: folderID)
        }
    }

    func delete(recordIDs: Set<String>) {
        for record in service.downloads where recordIDs.contains(record.id) {
            service.deleteDownload(record)
        }
    }

    func play(_ record: DownloadRecord) {
        let queue = service.playbackQueue(from: snapshot.downloaded)
        guard let track = queue.first(where: { $0.playbackKey == record.track.playbackKey }) else { return }
        appState.play(track: track, queue: queue)
    }

    func playAll() {
        playDownloadedQueue(shuffled: false)
    }

    func shuffleAll() {
        playDownloadedQueue(shuffled: true)
    }

    func togglePlayback() {
        appState.togglePlayback()
    }

    private func playDownloadedQueue(shuffled: Bool) {
        var queue = service.playbackQueue(from: snapshot.downloaded)
        if shuffled { queue.shuffle() }
        guard let first = queue.first else { return }
        appState.play(track: first, queue: queue)
    }

    private func rebuildSnapshot() {
        if let selectedFolderID,
           service.folders.contains(where: { $0.id == selectedFolderID }) == false {
            self.selectedFolderID = nil
        }

        let active = service.activeDownloads.values
            .sorted {
                if $0.queuePosition != $1.queuePosition { return $0.queuePosition < $1.queuePosition }
                return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
            }
            .map {
                DownloadProgressPresentation(
                    id: $0.id,
                    track: $0.track,
                    progress: $0.progress,
                    isPaused: $0.isPaused,
                    isFailed: $0.isFailed,
                    bytesDownloaded: $0.bytesDownloaded,
                    totalExpectedBytes: $0.totalExpectedBytes
                )
            }
        let records = service.downloads(in: selectedFolderID)
            .sorted { $0.downloadedAt > $1.downloadedAt }

        let nextSnapshot = DownloadSnapshot(
            downloading: active.filter { $0.isFailed == false },
            downloaded: records,
            folders: service.folders,
            selectedFolderID: selectedFolderID,
            needsAttentionMessage: active.contains(where: \.isFailed)
                ? "One or more downloads need to be retried."
                : service.lastError?.localizedDescription,
            totalDownloadedBytes: service.totalDownloadedBytes,
            nowPlayingKey: appState.nowPlaying?.playbackKey,
            isPlaying: appState.isPlaying
        )
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    // Every subscription here rebuilds the snapshot by re-reading `DownloadService` /
    // `AppState`, so each one hops to the next main-queue turn — see
    // `receiveAfterStateCommit()`.
    private func observeRelevantState() {
        service.$downloads
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        service.$folders
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        service.$activeDownloads
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        service.$lastError
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$nowPlayingTrack
            .combineLatest(appState.$isPlaybackActive)
            .receiveAfterStateCommit()
            .sink { [weak self] _, _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
    }
}

import Combine
import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var snapshot: LibrarySnapshot = .empty

    private let appState: AppState
    private let downloadService: DownloadService
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState, downloadService: DownloadService? = nil) {
        self.appState = appState
        self.downloadService = downloadService ?? .shared
        observeRelevantState()
        rebuildSnapshot()
    }

    func appear() async {
        guard appState.hasLoadedLibrary == false,
              appState.isLoadingPlaylists == false else { return }
        await appState.refreshLibrary()
    }

    func refresh() async {
        await appState.refreshLibrary(forceRefresh: true)
    }

    func openDownloads() {
        appState.selectedMainTab = .downloads
    }

    func createPlaylist() {
        appState.presentPlaylistCreator()
    }

    private func rebuildSnapshot() {
        let nextSnapshot = LibrarySnapshot(
            likedSongs: appState.likedSongsPlaylist,
            playlists: appState.customPlaylists,
            downloadedCount: downloadService.downloads.count,
            downloadedArtworkURL: downloadService.downloads.first?.track.artworkURL,
            collections: appState.savedCollections,
            history: Array(appState.historyTracks.prefix(8)),
            isLoading: appState.isLoadingPlaylists,
            nowPlayingKey: appState.nowPlaying?.playbackKey
        )
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    // Every subscription here rebuilds the snapshot by re-reading `AppState` /
    // `DownloadService`, so each one hops to the next main-queue turn — see
    // `receiveAfterStateCommit()`.
    private func observeRelevantState() {
        appState.$playlists
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$savedCollections
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$historyTracks
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$isLoadingPlaylists
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$nowPlayingTrack
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        downloadService.$downloads
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
    }
}

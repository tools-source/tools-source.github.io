import CarPlay
import UIKit

// MARK: - CarPlayManager
// Principles:
//  • One template per tab, updated atomically.
//  • No per-item background tasks that fight each other.
//  • Artwork: gradient placeholder immediately → one batch fetch → one refresh.
//  • Never push CPNowPlayingTemplate.shared when it's already on the stack.

@MainActor
final class CarPlayManager: NSObject {

    // MARK: Outlets
    private weak var interfaceController: CPInterfaceController?
    private weak var appState: AppState?

    private var forYouTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var downloadsTemplate: CPListTemplate?
    private var downloadFolderTemplates: [String: CPListTemplate] = [:]
    private var tabTemplate: CPTabBarTemplate?
    private let allDownloadsTemplateKey = "__all_downloads__"

    // Artwork cache (URL → 60×60 UIImage)
    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 180
        return cache
    }()

    // MARK: Lifecycle

    func attach(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.appState = AppContainer.shared.appState
        buildRoot()
    }

    func detach() {
        interfaceController = nil
        forYouTemplate = nil
        libraryTemplate = nil
        downloadsTemplate = nil
        downloadFolderTemplates = [:]
        tabTemplate = nil
    }

    func refresh(using state: AppState) {
        self.appState = state
        guard tabTemplate != nil else { buildRoot(); return }

        forYouTemplate?.updateSections(forYouSections(state))
        libraryTemplate?.updateSections(librarySections(state))
        downloadsTemplate?.updateSections(downloadSections(state))
        updateDownloadFolderTemplates(using: state)
        updateNowPlayingControls(using: state)

        // Batch-fetch artwork for all visible tracks, then do ONE refresh
        let tracks  = Array((state.featuredTracks + state.recentTracks).prefix(30))
        let playlists = Array(state.suggestedMixes.prefix(10))
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.batchFetch(tracks: tracks, playlists: playlists)
            // After artwork is cached, rebuild with real images
            self.forYouTemplate?.updateSections(self.forYouSections(state))
            self.libraryTemplate?.updateSections(self.librarySections(state))
            self.downloadsTemplate?.updateSections(self.downloadSections(state))
            self.updateDownloadFolderTemplates(using: state)
        }
    }

    // MARK: Root build

    private func buildRoot() {
        guard let ic = interfaceController, tabTemplate == nil else { return }
        let state = appState

        let fy = makeListTemplate(
            title: "Home",
            tabTitle: "Home",
            tabImage: UIImage(systemName: "house.fill"),
            sections: forYouSections(state))
        let lib = makeListTemplate(
            title: "Library",
            tabTitle: "Library",
            tabImage: UIImage(systemName: "music.note.list"),
            sections: librarySections(state))
        let dl = makeListTemplate(
            title: "Downloads",
            tabTitle: "Downloads",
            tabImage: UIImage(systemName: "arrow.down.circle.fill"),
            sections: downloadSections(state))

        let tab = CPTabBarTemplate(templates: [fy, lib, dl])
        self.forYouTemplate   = fy
        self.libraryTemplate  = lib
        self.downloadsTemplate = dl
        self.tabTemplate      = tab

        ic.setRootTemplate(tab, animated: false, completion: nil)
        updateNowPlayingControls(using: state)
    }

    private func makeListTemplate(
        title: String, tabTitle: String, tabImage: UIImage?,
        sections: [CPListSection]
    ) -> CPListTemplate {
        let t = CPListTemplate(title: title, sections: sections)
        t.tabTitle = tabTitle
        t.tabImage = tabImage
        return t
    }

    // MARK: For You sections

    private func forYouSections(_ state: AppState?) -> [CPListSection] {
        guard let state else {
            return [section("", [plain("Loading your music…")])]
        }
        guard state.authState != .restoring else {
            return [section("", [plain("Loading your music…")])]
        }

        var sections: [CPListSection] = []

        // ── Suggested Mixes ────────────────────────────────────────────────
        if state.isLoadingPlaylists && state.suggestedMixes.isEmpty {
            sections.append(section("Suggested Mixes", [plain("Loading mixes…")]))
        } else if state.suggestedMixes.isEmpty == false {
            let items = state.suggestedMixes.prefix(8).map { playlistRow($0, state: state) }
            sections.append(section("Suggested Mixes", Array(items)))
        }

        // ── Recommended for you ────────────────────────────────────────────
        if state.isLoading && state.featuredTracks.isEmpty {
            sections.append(section("Recommended for you", [plain("Loading your picks…")]))
        } else if state.featuredTracks.isEmpty {
            let emptyMessage = state.homeStatusMessage ?? "Open Home on your iPhone to refresh recommendations."
            sections.append(section("Recommended for you", [plain(emptyMessage)]))
        } else {
            let queue = Array(state.featuredTracks.prefix(30))
            let items = queue.map { trackRow($0, queue: queue, state: state) }
            sections.append(section("Recommended for you", items))
        }

        return sections.isEmpty ? [section("", [plain("No content yet.")])] : sections
    }

    // MARK: Library sections

    private func librarySections(_ state: AppState?) -> [CPListSection] {
        guard let state else {
            return [section("", [plain("Loading your music…")])]
        }
        guard state.authState != .restoring else {
            return [section("", [plain("Loading your music…")])]
        }

        if state.isLoadingPlaylists && state.playlists.isEmpty {
            return [section("Library", [plain("Importing your library…")])]
        }

        var sections: [CPListSection] = []

        if let liked = state.likedSongsPlaylist {
            sections.append(section("Liked Songs",
                                    [playlistRow(liked, state: state)]))
        }

        if let saved = state.savedSongsPlaylist {
            sections.append(section("Saved Songs",
                                    [playlistRow(saved, state: state)]))
        }

        let mixes = state.suggestedMixes
        if mixes.isEmpty == false {
            sections.append(section("Mixes",
                                    mixes.prefix(6).map { playlistRow($0, state: state) }))
        }

        let standard = state.libraryPlaylists.filter { p in
            !mixes.contains(where: { $0.id == p.id })
        }
        if standard.isEmpty == false {
            sections.append(section("Playlists",
                                    standard.prefix(20).map { playlistRow($0, state: state) }))
        }

        return sections.isEmpty ? [section("Library", [plain("No playlists found.")])] : sections
    }

    // MARK: Downloads sections

    private func downloadSections(_ state: AppState?) -> [CPListSection] {
        let records = DownloadService.shared.downloads
        guard records.isEmpty == false else {
            return [section("Downloads",
                            [plain("No downloads yet. Save songs from iPhone.")])]
        }
        guard let state = state ?? self.appState ?? AppContainer.shared.appState else {
            return [section("Downloads", [plain("Connecting…")])]
        }

        if DownloadService.shared.folders.isEmpty {
            let tracks = Array(records.reversed().map(\.localTrack))
            return [section("Downloaded · \(tracks.count) songs",
                            tracks.map { trackRow($0, queue: tracks, state: state) })]
        }

        let allTracks = downloadTracks(in: nil)
        let browseItems = [downloadFolderRow(title: "All Downloads", folderID: nil, state: state)]
        let folderItems = DownloadService.shared.folders.map {
            downloadFolderRow(title: $0.name, folderID: $0.id, state: state)
        }
        let recentTracks = Array(allTracks.prefix(12))

        var sections: [CPListSection] = [
            section("Browse", browseItems),
            section("Folders", folderItems)
        ]

        if recentTracks.isEmpty == false {
            sections.append(section("Recently Downloaded",
                                    recentTracks.map { trackRow($0, queue: allTracks, state: state) }))
        }

        return sections
    }

    // MARK: Item builders

    private func trackRow(_ track: Track, queue: [Track], state: AppState) -> CPListItem {
        let img  = cachedImage(track.artworkURL) ?? musicPlaceholder
        let item = CPListItem(text: track.title, detailText: track.artist, image: img)
        item.handler = { [weak self] _, done in
            state.play(track: track, queue: queue)
            self?.showNowPlaying()
            done()
        }
        return item
    }

    private func playlistRow(_ playlist: Playlist, state: AppState) -> CPListItem {
        let img  = cachedImage(playlist.artworkURL) ?? mixPlaceholder
        let item = CPListItem(text: playlist.title,
                              detailText: playlistSubtitle(playlist),
                              image: img,
                              accessoryImage: nil,
                              accessoryType: .disclosureIndicator)
        item.handler = { [weak self] _, done in
            self?.openPlaylist(playlist, state: state)
            done()
        }
        return item
    }

    private func downloadFolderRow(title: String, folderID: String?, state: AppState) -> CPListItem {
        let tracks = downloadTracks(in: folderID)
        let subtitle = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        let item = CPListItem(
            text: title,
            detailText: subtitle,
            image: UIImage(systemName: folderID == nil ? "square.stack.fill" : "folder.fill"),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        item.handler = { [weak self] _, done in
            self?.openDownloadFolder(title: title, folderID: folderID, state: state)
            done()
        }
        return item
    }

    private func plain(_ text: String) -> CPListItem {
        CPListItem(text: text, detailText: nil)
    }

    private func section(_ header: String, _ items: [any CPSelectableListItem]) -> CPListSection {
        CPListSection(items: items, header: header.isEmpty ? nil : header,
                      sectionIndexTitle: nil)
    }

    // MARK: Playlist detail

    private func openPlaylist(_ playlist: Playlist, state: AppState) {
        guard let ic = interfaceController else { return }

        // Loading placeholder template
        let loading = makeListTemplate(
            title: playlist.title, tabTitle: "", tabImage: nil,
            sections: [section(playlist.title, [plain("Loading tracks…")])])
        guard ic.topTemplate !== loading else { return }
        ic.pushTemplate(loading, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let tracks = await state.loadPlaylistItems(for: playlist)
            guard tracks.isEmpty == false else {
                loading.updateSections([self.section(playlist.title,
                                                      [self.plain("No tracks in this playlist.")])])
                return
            }
            await self.batchFetch(tracks: tracks, playlists: [])
            let header = "\(playlist.title) · \(tracks.count)"
            loading.updateSections([self.section(header,
                                                  tracks.map { self.trackRow($0, queue: tracks, state: state) })])
        }
    }

    private func openDownloadFolder(title: String, folderID: String?, state: AppState) {
        guard let ic = interfaceController else { return }

        let template = makeListTemplate(
            title: title,
            tabTitle: "",
            tabImage: nil,
            sections: downloadFolderSections(title: title, folderID: folderID, state: state)
        )
        downloadFolderTemplates[downloadTemplateKey(for: folderID)] = template
        ic.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: Now Playing

    private func showNowPlaying() {
        guard let ic = interfaceController else { return }
        updateNowPlayingControls(using: appState)
        guard ic.topTemplate !== CPNowPlayingTemplate.shared else { return }
        ic.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func updateNowPlayingControls(using state: AppState?) {
        guard let state else {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
            return
        }

        guard let nowPlayingTrack = state.nowPlaying else {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
            return
        }

        let downloadService = DownloadService.shared
        let isLiked = state.isTrackLiked(nowPlayingTrack)
        let isDownloaded = downloadService.isDownloaded(nowPlayingTrack)
        let isDownloading = downloadService.isDownloading(nowPlayingTrack)

        let shuffleButton = CPNowPlayingShuffleButton { [weak self, weak state] _ in
            state?.toggleShuffle()
            guard let self, let state else { return }
            self.updateNowPlayingControls(using: state)
        }

        let repeatButton = CPNowPlayingRepeatButton { [weak self, weak state] _ in
            state?.cycleRepeatMode()
            guard let self, let state else { return }
            self.updateNowPlayingControls(using: state)
        }

        let likeImageName = isLiked ? "heart.fill" : "heart"
        let likeButton = CPNowPlayingImageButton(
            image: UIImage(systemName: likeImageName) ?? UIImage(),
            handler: { [weak self, weak state] _ in
                guard let track = state?.nowPlaying else { return }
                state?.toggleLike(for: track)
                guard let self, let state else { return }
                self.updateNowPlayingControls(using: state)
            }
        )
        likeButton.isEnabled = true
        likeButton.isSelected = isLiked

        let downloadImageName: String
        if isDownloaded {
            downloadImageName = "checkmark.circle.fill"
        } else if isDownloading {
            downloadImageName = "arrow.down.circle.fill"
        } else {
            downloadImageName = "arrow.down.circle"
        }

        let downloadButton = CPNowPlayingImageButton(
            image: UIImage(systemName: downloadImageName) ?? UIImage(),
            handler: { [weak self, weak state] _ in
                state?.downloadNowPlaying()
                guard let self, let state else { return }
                self.updateNowPlayingControls(using: state)
            }
        )
        downloadButton.isEnabled = !isDownloaded && !isDownloading
        downloadButton.isSelected = isDownloaded

        CPNowPlayingTemplate.shared.updateNowPlayingButtons([
            shuffleButton,
            repeatButton,
            likeButton,
            downloadButton
        ])
    }

    private func updateDownloadFolderTemplates(using state: AppState) {
        for (key, template) in downloadFolderTemplates {
            let folderID = key == allDownloadsTemplateKey ? nil : key
            template.updateSections(
                downloadFolderSections(
                    title: template.title ?? "Downloads",
                    folderID: folderID,
                    state: state
                )
            )
        }
    }

    private func downloadFolderSections(title: String, folderID: String?, state: AppState) -> [CPListSection] {
        let tracks = downloadTracks(in: folderID)
        guard tracks.isEmpty == false else {
            let emptyMessage = folderID == nil ? "No downloads yet." : "This folder is empty."
            return [section(title, [plain(emptyMessage)])]
        }

        let header = tracks.count == 1
            ? "\(title) · 1 song"
            : "\(title) · \(tracks.count) songs"

        return [
            section(
                header,
                tracks.map { trackRow($0, queue: tracks, state: state) }
            )
        ]
    }

    private func downloadTracks(in folderID: String?) -> [Track] {
        let records: [DownloadRecord]
        if let folderID {
            records = DownloadService.shared.downloads(in: folderID)
        } else {
            records = DownloadService.shared.downloads
        }

        return Array(records.reversed().map(\.localTrack))
    }

    private func downloadTemplateKey(for folderID: String?) -> String {
        folderID ?? allDownloadsTemplateKey
    }

    // MARK: Artwork

    private func cachedImage(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    private func batchFetch(tracks: [Track], playlists: [Playlist]) async {
        await withTaskGroup(of: Void.self) { g in
            let urls = Set(tracks.compactMap(\.artworkURL) + playlists.compactMap(\.artworkURL))
            for url in urls {
                guard cache.object(forKey: url as NSURL) == nil else { continue }
                g.addTask { [weak self] in
                    guard let self else { return }
                    guard let raw = await ArtworkRepository.shared.image(
                        for: url,
                        maxPixelSize: ArtworkPixelSize.list
                    ) else { return }
                    let sized = await self.squareImage(raw, side: 60)
                    await MainActor.run {
                        self.cache.setObject(sized, forKey: url as NSURL)
                    }
                }
            }
        }
    }

    private func squareImage(_ image: UIImage, side: CGFloat) -> UIImage {
        let sz = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: sz).image { _ in
            let r  = image.size.width / image.size.height
            let dr: CGRect = r > 1
                ? CGRect(x: -(side * r - side) / 2, y: 0, width: side * r, height: side)
                : CGRect(x: 0, y: -(side / r - side) / 2, width: side, height: side / r)
            image.draw(in: dr)
        }
    }

    // MARK: Placeholders

    private lazy var musicPlaceholder: UIImage = gradientIcon(
        symbol: "music.note",
        colors: [UIColor(red: 1, green: 0.23, blue: 0.42, alpha: 1),
                 UIColor(red: 0.55, green: 0.08, blue: 0.28, alpha: 1)])

    private lazy var mixPlaceholder: UIImage = gradientIcon(
        symbol: "music.note.list",
        colors: [UIColor(red: 0.25, green: 0.47, blue: 1, alpha: 1),
                 UIColor(red: 0.08, green: 0.22, blue: 0.7, alpha: 1)])

    private func gradientIcon(symbol: String, colors: [UIColor]) -> UIImage {
        let side: CGFloat = 60
        let sz = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: sz).image { ctx in
            let cgc = ctx.cgContext
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 12).addClip()
            let cs = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: cs,
                                   colors: colors.map(\.cgColor) as CFArray,
                                   locations: [0, 1]) {
                cgc.drawLinearGradient(g, start: .zero,
                                       end: CGPoint(x: side, y: side), options: [])
            }
            let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            if let ico = UIImage(systemName: symbol, withConfiguration: cfg)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let o = CGPoint(x: (side - ico.size.width) / 2,
                                y: (side - ico.size.height) / 2)
                ico.draw(in: CGRect(origin: o, size: ico.size))
            }
        }
    }

    // MARK: Helpers

    private func playlistSubtitle(_ p: Playlist) -> String {
        let n = p.itemCount
        switch p.kind {
        case .likedMusic: return n == 1 ? "1 song"   : "\(n) songs"
        case .uploads:    return n == 1 ? "1 upload" : "\(n) uploads"
        case .savedSongs: return n == 1 ? "1 saved song" : "\(n) saved songs"
        case .custom:     return n == 1 ? "1 track"  : "\(n) tracks"
        case .standard:   return n == 1 ? "1 track"  : "\(n) tracks"
        }
    }
}

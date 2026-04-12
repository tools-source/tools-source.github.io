import CarPlay
import UIKit

@MainActor
final class CarPlayManager: NSObject {
    private struct ArtworkPalette {
        let start: UIColor
        let end: UIColor
        let accent: UIColor
    }

    private weak var interfaceController: CPInterfaceController?
    private weak var appState: AppState?

    private var homeTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var downloadsTemplate: CPListTemplate?
    private var tabBarTemplate: CPTabBarTemplate?
    private let artworkCache = NSCache<NSURL, UIImage>()
    private let placeholderCache = NSCache<NSString, UIImage>()

    func attach(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        appState = AppContainer.shared.appState
        installRootTemplateIfNeeded()
    }

    func detach() {
        interfaceController = nil
        homeTemplate = nil
        libraryTemplate = nil
        downloadsTemplate = nil
        tabBarTemplate = nil
        artworkCache.removeAllObjects()
        placeholderCache.removeAllObjects()
    }

    func refresh(using appState: AppState) {
        self.appState = appState
        installRootTemplateIfNeeded()
        configureNowPlayingTemplate(using: appState)

        let trailingButtons = trailingNavigationButtons(using: appState)
        homeTemplate?.updateSections(homeSections(using: appState))
        homeTemplate?.trailingNavigationBarButtons = trailingButtons
        libraryTemplate?.updateSections(librarySections(using: appState))
        libraryTemplate?.trailingNavigationBarButtons = trailingButtons
        downloadsTemplate?.updateSections(downloadsSections())
        downloadsTemplate?.trailingNavigationBarButtons = trailingButtons
    }

    private func installRootTemplateIfNeeded() {
        guard let interfaceController else { return }
        guard tabBarTemplate == nil else { return }

        let currentAppState = appState ?? AppContainer.shared.appState

        let homeTemplate = CPListTemplate(
            title: "Home",
            sections: homeSections(using: currentAppState)
        )
        homeTemplate.tabTitle = "Home"
        homeTemplate.tabImage = UIImage(systemName: "house.fill")
        homeTemplate.trailingNavigationBarButtons = trailingNavigationButtons(using: currentAppState)

        let libraryTemplate = CPListTemplate(
            title: "Library",
            sections: librarySections(using: currentAppState)
        )
        libraryTemplate.tabTitle = "Library"
        libraryTemplate.tabImage = UIImage(systemName: "music.note.list")
        libraryTemplate.trailingNavigationBarButtons = trailingNavigationButtons(using: currentAppState)

        let downloadsTemplate = CPListTemplate(
            title: "Downloads",
            sections: downloadsSections()
        )
        downloadsTemplate.tabTitle = "Downloads"
        downloadsTemplate.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        downloadsTemplate.trailingNavigationBarButtons = trailingNavigationButtons(using: currentAppState)

        let tabBarTemplate = CPTabBarTemplate(templates: [
            homeTemplate,
            downloadsTemplate,
            libraryTemplate
        ])

        self.homeTemplate = homeTemplate
        self.libraryTemplate = libraryTemplate
        self.downloadsTemplate = downloadsTemplate
        self.tabBarTemplate = tabBarTemplate

        configureNowPlayingTemplate(using: currentAppState)
        interfaceController.setRootTemplate(tabBarTemplate, animated: true, completion: nil)
    }

    private func homeSections(using appState: AppState?) -> [CPListSection] {
        guard let appState, appState.authState == .signedIn else {
            return [
                section(
                    header: "Home",
                    items: [
                        messageItem(
                            title: "Sign in on your iPhone",
                            detailText: "Your Home recommendations will appear here."
                        )
                    ]
                )
            ]
        }

        let featuredItems: [CPListItem]
        if appState.featuredTracks.isEmpty, appState.isLoading {
            featuredItems = [messageItem(title: "Loading For You...")]
        } else if appState.featuredTracks.isEmpty {
            featuredItems = [
                messageItem(
                    title: "No recommendations yet",
                    detailText: "Pull to refresh on the phone and try again."
                )
            ]
        } else {
            featuredItems = appState.featuredTracks.map { trackItem(for: $0, queue: appState.featuredTracks, appState: appState) }
        }

        let mixItems: [CPListItem]
        if appState.suggestedMixes.isEmpty, appState.isLoadingPlaylists {
            mixItems = [messageItem(title: "Building suggested mixes...")]
        } else if appState.suggestedMixes.isEmpty {
            mixItems = [
                messageItem(
                    title: "No suggested mixes yet",
                    detailText: "Refresh on your iPhone after your library finishes loading."
                )
            ]
        } else {
            mixItems = appState.suggestedMixes.map { playlistItem(for: $0, appState: appState) }
        }

        return [
            section(
                header: "Suggested Mixes",
                items: mixItems
            ),
            section(
                header: "For You",
                items: featuredItems
            )
        ]
    }

    private func librarySections(using appState: AppState?) -> [CPListSection] {
        guard let appState, appState.authState == .signedIn else {
            return [
                section(
                    header: "Library",
                    items: [
                        messageItem(
                            title: "Sign in on your iPhone",
                            detailText: "Your collections will appear here."
                        )
                    ]
                )
            ]
        }

        var sections: [CPListSection] = []

        if appState.playlists.isEmpty, appState.isLoadingPlaylists {
            sections.append(section(header: "Library", items: [messageItem(title: "Importing collections...")]))
            return sections
        }

        let likedSongsItems: [CPListItem]
        if let likedSongsPlaylist = appState.likedSongsPlaylist {
            likedSongsItems = [playlistItem(for: likedSongsPlaylist, appState: appState)]
        } else {
            likedSongsItems = [messageItem(title: "No liked songs found yet")]
        }

        let mixPlaylists = appState.suggestedMixes.isEmpty
            ? appState.libraryPlaylists.filter { $0.title.localizedCaseInsensitiveContains("mix") }
            : appState.suggestedMixes
        let mixPlaylistIDs = Set(mixPlaylists.map(\.id))
        let standardPlaylistCollections = appState.libraryPlaylists.filter { mixPlaylistIDs.contains($0.id) == false }

        let mixItems: [CPListItem]
        if mixPlaylists.isEmpty {
            mixItems = [
                messageItem(
                    title: "No mixes yet",
                    detailText: "Replay Mix and your suggested mixes will show up here."
                )
            ]
        } else {
            mixItems = mixPlaylists.map { playlistItem(for: $0, appState: appState) }
        }

        let playlistItems: [CPListItem]
        if standardPlaylistCollections.isEmpty {
            playlistItems = [
                messageItem(
                    title: "No playlists found",
                    detailText: "Refresh the library on the phone to try again."
                )
            ]
        } else {
            playlistItems = standardPlaylistCollections.map { playlistItem(for: $0, appState: appState) }
        }

        sections.append(section(header: "Liked Songs", items: likedSongsItems))
        sections.append(section(header: "Mixes", items: mixItems))
        sections.append(section(header: "Playlists", items: playlistItems))
        return sections
    }

    private func downloadsSections() -> [CPListSection] {
        let downloads = DownloadService.shared.downloads
        guard downloads.isEmpty == false else {
            return [
                section(
                    header: "Downloads",
                    items: [
                        messageItem(
                            title: "No downloaded tracks",
                            detailText: "Download songs on your iPhone to play offline."
                        )
                    ]
                )
            ]
        }

        guard let appState = self.appState ?? AppContainer.shared.appState else {
            return [section(header: "Downloaded", items: downloads.reversed().map { _ in
                messageItem(title: "Tap to play", detailText: nil)
            })]
        }
        let tracks = downloads.reversed().map(\.localTrack)
        let items = tracks.map { trackItem(for: $0, queue: tracks, appState: appState) }
        return [section(header: "Downloaded", items: items)]
    }

    private func section(header: String, items: [CPListItem]) -> CPListSection {
        CPListSection(items: items, header: header, sectionIndexTitle: nil)
    }

    private func makeNowPlayingBarButton() -> CPBarButton {
        let nowPlayingButton = CPBarButton(image: UIImage(systemName: "waveform.circle.fill") ?? UIImage()) { [weak self] _ in
            self?.showNowPlaying()
        }
        nowPlayingButton.buttonStyle = .rounded
        return nowPlayingButton
    }

    private func makeShuffleBarButton(using appState: AppState?) -> CPBarButton {
        let shuffleImageName = appState?.shuffleMode == true ? "shuffle.circle.fill" : "shuffle.circle"
        let shuffleButton = CPBarButton(image: UIImage(systemName: shuffleImageName) ?? UIImage()) { [weak self] _ in
            self?.toggleShuffle()
        }
        shuffleButton.buttonStyle = .rounded
        return shuffleButton
    }

    private func trailingNavigationButtons(using appState: AppState?) -> [CPBarButton] {
        var buttons = [makeShuffleBarButton(using: appState)]

        if appState?.nowPlaying != nil {
            buttons.insert(makeNowPlayingBarButton(), at: 0)
        }

        return buttons
    }

    private func showNowPlaying() {
        guard interfaceController != nil else { return }
        configureNowPlayingTemplate(using: appState ?? AppContainer.shared.appState)
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func trackItem(for track: Track, queue: [Track], appState: AppState) -> CPListItem {
        let item = CPListItem(text: track.title, detailText: track.artist)
        styleTrackItem(item, track: track, appState: appState)

        item.handler = { [weak self] _, completion in
            appState.play(track: track, queue: queue)
            self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            completion()
        }

        return item
    }

    private func playlistItem(for playlist: Playlist, appState: AppState) -> CPListItem {
        let item = CPListItem(text: playlist.title, detailText: playlistSubtitle(for: playlist))
        item.userInfo = playlist.id
        configureArtwork(
            for: item,
            artworkURL: playlist.artworkURL,
            title: playlist.title,
            symbolName: playlistSymbolName(for: playlist)
        )

        item.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion()
                    return
                }

                await self.playPlaylist(playlist, appState: appState)
                completion()
            }
        }

        return item
    }

    private func messageItem(title: String, detailText: String? = nil) -> CPListItem {
        let item = CPListItem(text: title, detailText: detailText)
        item.userInfo = nil
        item.isEnabled = false
        return item
    }

    private func playPlaylist(_ playlist: Playlist, appState: AppState) async {
        let tracks = await appState.loadPlaylistItems(for: playlist)

        guard tracks.isEmpty == false else {
            presentAlert(title: "No playable tracks are available for \(playlist.title).")
            return
        }

        let selectedTrack = startingTrack(for: tracks, shuffled: appState.shuffleMode)
        appState.play(track: selectedTrack, queue: tracks)
        showNowPlaying()
    }

    private func playlistSubtitle(for playlist: Playlist) -> String {
        switch playlist.kind {
        case .likedMusic:
            return playlist.itemCount == 1 ? "1 song" : "\(playlist.itemCount) songs"
        case .uploads:
            return playlist.itemCount == 1 ? "1 upload" : "\(playlist.itemCount) uploads"
        case .standard:
            return playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks"
        }
    }

    private func playlistSymbolName(for playlist: Playlist) -> String {
        switch playlist.kind {
        case .likedMusic:
            return "heart.fill"
        case .uploads:
            return "arrow.up.circle.fill"
        case .standard:
            return "music.note.list"
        }
    }

    private func styleTrackItem(_ item: CPListItem, track: Track, appState: AppState) {
        item.userInfo = trackIdentifier(for: track)
        item.playingIndicatorLocation = .trailing

        let isNowPlaying = appState.nowPlaying.map { trackIdentifier(for: $0) } == trackIdentifier(for: track)
        item.isPlaying = isNowPlaying
        item.playbackProgress = isNowPlaying ? CGFloat(min(max(appState.playbackProgress, 0), 1)) : 0

        configureArtwork(
            for: item,
            artworkURL: track.artworkURL,
            title: track.title,
            symbolName: "music.note"
        )
    }

    private func configureArtwork(
        for item: CPListItem,
        artworkURL: URL?,
        title: String,
        symbolName: String
    ) {
        let placeholder = decorativeImage(
            seed: title,
            symbolName: symbolName,
            size: listItemImageSize(),
            cacheKeyPrefix: "row"
        )

        item.setImage(placeholder)

        guard let artworkURL else { return }

        if let cachedImage = artworkCache.object(forKey: artworkURL as NSURL) {
            item.setImage(cachedImage)
            return
        }

        Task { [weak self, weak item] in
            guard let self else { return }
            guard let styledImage = await loadArtworkImage(from: artworkURL) else { return }
            guard let item else { return }
            item.setImage(styledImage)
        }
    }

    private func loadArtworkImage(from url: URL) async -> UIImage? {
        let cacheKey = url as NSURL
        if let cached = artworkCache.object(forKey: cacheKey) {
            return cached
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            let styledImage = renderArtworkImage(image, targetSize: listItemImageSize())
            artworkCache.setObject(styledImage, forKey: cacheKey)
            return styledImage
        } catch {
            return nil
        }
    }

    private func decorativeImage(
        seed: String,
        symbolName: String,
        size: CGSize,
        cacheKeyPrefix: String
    ) -> UIImage {
        let cacheKey = "\(cacheKeyPrefix)-\(seed)-\(symbolName)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = placeholderCache.object(forKey: cacheKey) {
            return cached
        }

        let image = renderDecorativeImage(seed: seed, symbolName: symbolName, size: size)
        placeholderCache.setObject(image, forKey: cacheKey)
        return image
    }

    private func renderDecorativeImage(seed: String, symbolName: String, size: CGSize) -> UIImage {
        let palette = palette(for: seed)
        let renderer = UIGraphicsImageRenderer(size: size, format: rendererFormat())
        let rect = CGRect(origin: .zero, size: size)
        let cornerRadius = min(size.width, size.height) * 0.28

        return renderer.image { context in
            let cgContext = context.cgContext
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: cornerRadius)

            cgContext.saveGState()
            path.addClip()
            drawGradient(in: rect, palette: palette, context: cgContext)

            cgContext.setFillColor(UIColor.white.withAlphaComponent(0.12).cgColor)
            cgContext.fillEllipse(in: rect.insetBy(dx: -size.width * 0.2, dy: -size.height * 0.25))

            cgContext.restoreGState()

            UIColor.white.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 1
            path.stroke()

            let symbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: min(size.width, size.height) * 0.44,
                weight: .semibold
            )

            let symbol = UIImage(systemName: symbolName, withConfiguration: symbolConfiguration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)

            if let symbol {
                let symbolRect = CGRect(
                    x: (size.width - symbol.size.width) / 2,
                    y: (size.height - symbol.size.height) / 2,
                    width: symbol.size.width,
                    height: symbol.size.height
                )
                symbol.draw(in: symbolRect)
            }
        }
    }

    private func renderArtworkImage(_ image: UIImage, targetSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: rendererFormat())
        let rect = CGRect(origin: .zero, size: targetSize)
        let cornerRadius = min(targetSize.width, targetSize.height) * 0.24
        let drawRect = aspectFillRect(for: image.size, in: rect)

        return renderer.image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()
            image.draw(in: drawRect)

            UIColor.white.withAlphaComponent(0.1).setStroke()
            let strokePath = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: cornerRadius)
            strokePath.lineWidth = 1
            strokePath.stroke()
        }
    }

    private func drawGradient(in rect: CGRect, palette: ArtworkPalette, context: CGContext) {
        let colors = [palette.start.cgColor, palette.end.cgColor] as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let locations: [CGFloat] = [0, 1]

        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
            context.setFillColor(palette.start.cgColor)
            context.fill(rect)
            return
        }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: rect.maxY),
            options: []
        )
    }

    private func palette(for seed: String) -> ArtworkPalette {
        let palettes: [ArtworkPalette] = [
            ArtworkPalette(
                start: UIColor(red: 0.98, green: 0.37, blue: 0.25, alpha: 1),
                end: UIColor(red: 1.00, green: 0.72, blue: 0.33, alpha: 1),
                accent: UIColor(red: 1.00, green: 0.59, blue: 0.30, alpha: 1)
            ),
            ArtworkPalette(
                start: UIColor(red: 0.17, green: 0.75, blue: 0.64, alpha: 1),
                end: UIColor(red: 0.16, green: 0.49, blue: 0.92, alpha: 1),
                accent: UIColor(red: 0.25, green: 0.86, blue: 0.78, alpha: 1)
            ),
            ArtworkPalette(
                start: UIColor(red: 0.34, green: 0.43, blue: 0.96, alpha: 1),
                end: UIColor(red: 0.67, green: 0.30, blue: 0.93, alpha: 1),
                accent: UIColor(red: 0.57, green: 0.51, blue: 1.00, alpha: 1)
            ),
            ArtworkPalette(
                start: UIColor(red: 0.99, green: 0.27, blue: 0.54, alpha: 1),
                end: UIColor(red: 0.72, green: 0.25, blue: 0.90, alpha: 1),
                accent: UIColor(red: 1.00, green: 0.41, blue: 0.68, alpha: 1)
            ),
            ArtworkPalette(
                start: UIColor(red: 0.34, green: 0.76, blue: 0.34, alpha: 1),
                end: UIColor(red: 0.12, green: 0.58, blue: 0.48, alpha: 1),
                accent: UIColor(red: 0.47, green: 0.88, blue: 0.45, alpha: 1)
            )
        ]

        let hash = seed.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            partialResult = ((partialResult * 31) + Int(scalar.value)) % 10_000
        }

        return palettes[hash % palettes.count]
    }

    private func toggleShuffle() {
        guard let appState = self.appState ?? AppContainer.shared.appState else { return }
        appState.toggleShuffle()
        refresh(using: appState)
    }

    private func configureNowPlayingTemplate(using appState: AppState?) {
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        nowPlayingTemplate.isUpNextButtonEnabled = false
        nowPlayingTemplate.isAlbumArtistButtonEnabled = false

        guard let appState else {
            nowPlayingTemplate.updateNowPlayingButtons([])
            return
        }

        let shuffleImageName = appState.shuffleMode ? "shuffle.circle.fill" : "shuffle.circle"
        let shuffleButton = CPNowPlayingImageButton(
            image: UIImage(systemName: shuffleImageName) ?? UIImage()
        ) { [weak self] _ in
            self?.toggleShuffle()
        }

        nowPlayingTemplate.updateNowPlayingButtons([shuffleButton])
    }

    private func startingTrack(for tracks: [Track], shuffled: Bool) -> Track {
        guard shuffled else { return tracks[0] }
        return tracks.randomElement() ?? tracks[0]
    }

    private func presentAlert(title: String) {
        guard let interfaceController else { return }

        let dismissAction = CPAlertAction(title: "OK", style: .cancel) { [weak interfaceController] _ in
            interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [title], actions: [dismissAction])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private func rendererFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = interfaceController?.carTraitCollection.displayScale ?? UIScreen.main.scale
        return format
    }

    private func listItemImageSize() -> CGSize {
        let size = CPListItem.maximumImageSize
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: 56, height: 56)
        }

        return size
    }

    private func sectionHeaderImageSize() -> CGSize {
        guard CPMaximumListSectionImageSize.width > 0, CPMaximumListSectionImageSize.height > 0 else {
            return CGSize(width: 26, height: 26)
        }

        return CPMaximumListSectionImageSize
    }

    private func aspectFillRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }

        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        return CGRect(
            x: bounds.midX - (scaledSize.width / 2),
            y: bounds.midY - (scaledSize.height / 2),
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    private func trackIdentifier(for track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }
}

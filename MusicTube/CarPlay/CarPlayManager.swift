import CarPlay
import UIKit

@MainActor
final class CarPlayManager: NSObject {
    private weak var interfaceController: CPInterfaceController?
    private weak var appState: AppState?

    private var homeTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var searchTemplate: CPSearchTemplate?
    private var tabBarTemplate: CPTabBarTemplate?
    private var searchResultsByIdentifier: [String: Track] = [:]
    private var currentSearchResults: [Track] = []

    func attach(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        appState = AppContainer.shared.appState
        installRootTemplateIfNeeded()
    }

    func detach() {
        interfaceController = nil
        homeTemplate = nil
        libraryTemplate = nil
        searchTemplate = nil
        tabBarTemplate = nil
        searchResultsByIdentifier = [:]
        currentSearchResults = []
    }

    func refresh(using appState: AppState) {
        self.appState = appState
        installRootTemplateIfNeeded()

        homeTemplate?.updateSections(homeSections(using: appState))
        homeTemplate?.trailingNavigationBarButtons = trailingNavigationButtons(using: appState)
        libraryTemplate?.updateSections(librarySections(using: appState))
        libraryTemplate?.trailingNavigationBarButtons = trailingNavigationButtons(using: appState)
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

        let searchTemplate = CPSearchTemplate()
        searchTemplate.delegate = self

        let libraryTemplate = CPListTemplate(
            title: "Library",
            sections: librarySections(using: currentAppState)
        )
        libraryTemplate.tabTitle = "Library"
        libraryTemplate.tabImage = UIImage(systemName: "music.note.list")
        libraryTemplate.trailingNavigationBarButtons = trailingNavigationButtons(using: currentAppState)

        let tabBarTemplate = CPTabBarTemplate(templates: [
            homeTemplate,
            libraryTemplate
        ])

        self.homeTemplate = homeTemplate
        self.searchTemplate = searchTemplate
        self.libraryTemplate = libraryTemplate
        self.tabBarTemplate = tabBarTemplate

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
            section(header: "For You", items: featuredItems),
            section(header: "Suggested Mixes", items: mixItems)
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

        if let user = appState.user {
            sections.append(
                section(
                    header: "Account",
                    items: [messageItem(title: user.name, detailText: user.email)]
                )
            )
        }

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

    private func section(header: String, items: [CPListItem]) -> CPListSection {
        CPListSection(items: items, header: header, sectionIndexTitle: nil)
    }

    private func makeSearchBarButton() -> CPBarButton {
        let searchButton = CPBarButton(image: UIImage(systemName: "magnifyingglass") ?? UIImage()) { [weak self] _ in
            self?.showSearch()
        }
        searchButton.buttonStyle = .rounded
        return searchButton
    }

    private func makeNowPlayingBarButton() -> CPBarButton {
        let nowPlayingButton = CPBarButton(image: UIImage(systemName: "play.circle.fill") ?? UIImage()) { [weak self] _ in
            self?.showNowPlaying()
        }
        nowPlayingButton.buttonStyle = .rounded
        return nowPlayingButton
    }

    private func trailingNavigationButtons(using appState: AppState?) -> [CPBarButton] {
        var buttons = [makeSearchBarButton()]

        if appState?.nowPlaying != nil {
            buttons.insert(makeNowPlayingBarButton(), at: 0)
        }

        return buttons
    }

    private func showSearch() {
        guard let interfaceController, let searchTemplate else { return }
        interfaceController.pushTemplate(searchTemplate, animated: true, completion: nil)
    }

    private func showNowPlaying() {
        guard interfaceController != nil else { return }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func trackItem(for track: Track, queue: [Track], appState: AppState) -> CPListItem {
        let item = CPListItem(text: track.title, detailText: track.artist)
        item.userInfo = trackIdentifier(for: track)

        item.handler = { [weak self] _, completion in
            appState.play(track: track, queue: queue)
            self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            completion()
        }

        return item
    }

    private func playlistItem(for playlist: Playlist, appState: AppState) -> CPListItem {
        let item = CPListItem(text: playlist.title, detailText: playlistSubtitle(for: playlist))
        item.accessoryType = .disclosureIndicator
        item.userInfo = playlist.id

        item.handler = { [weak self] _, completion in
            self?.showPlaylist(playlist, appState: appState)
            completion()
        }

        return item
    }

    private func messageItem(title: String, detailText: String? = nil) -> CPListItem {
        let item = CPListItem(text: title, detailText: detailText)
        item.userInfo = nil
        return item
    }

    private func showPlaylist(_ playlist: Playlist, appState: AppState) {
        guard let interfaceController else { return }

        let template = CPListTemplate(
            title: playlist.title,
            sections: [section(header: "Tracks", items: [messageItem(title: "Loading playlist tracks...")])]
        )
        template.trailingNavigationBarButtons = trailingNavigationButtons(using: appState)

        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }

            let tracks = await appState.loadPlaylistItems(for: playlist)

            if tracks.isEmpty {
                template.updateSections([
                    section(
                        header: "Tracks",
                        items: [
                            messageItem(
                                title: "No playable YouTube items yet",
                                detailText: "This collection is empty or still loading."
                            )
                        ]
                    )
                ])
                return
            }

            template.updateSections([
                section(
                    header: "Tracks",
                    items: tracks.map { self.trackItem(for: $0, queue: tracks, appState: appState) }
                )
            ])
        }
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

    private func trackIdentifier(for track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }
}

extension CarPlayManager: CPSearchTemplateDelegate {
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let appState, trimmedSearchText.isEmpty == false else {
            searchResultsByIdentifier = [:]
            currentSearchResults = []
            completionHandler([])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler([])
                return
            }

            let results = await appState.search(query: trimmedSearchText)
            currentSearchResults = results
            searchResultsByIdentifier = Dictionary(
                uniqueKeysWithValues: results.map { (self.trackIdentifier(for: $0), $0) }
            )

            let items = results.prefix(20).map { track -> CPListItem in
                let item = CPListItem(text: track.title, detailText: track.artist)
                item.userInfo = self.trackIdentifier(for: track)
                return item
            }

            completionHandler(Array(items))
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard
            let appState,
            let identifier = item.userInfo as? String,
            let track = searchResultsByIdentifier[identifier]
        else {
            return
        }

        appState.play(track: track, queue: currentSearchResults)
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}

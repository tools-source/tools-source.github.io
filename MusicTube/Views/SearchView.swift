import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchTask: Task<Void, Never>?
    @State private var suggestedTracks: [Track] = []
    @State private var isLoadingSuggestedTracks = false
    @State private var immediateSearchQuery: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    searchHeader

                    if trimmedSearchQuery.isEmpty, appState.recentSearches.isEmpty == false {
                        recentSearchesSection
                    }

                    if trimmedSearchQuery.isEmpty {
                        suggestionsSection
                    }

                    if appState.isSearching, appState.searchResults.isEmpty {
                        statusCard(label: "Searching songs, playlists, albums, and artists...")
                    } else if appState.searchResults.isEmpty {
                        if trimmedSearchQuery.isEmpty, appState.recentSearches.isEmpty == false {
                            EmptyView()
                        } else {
                            statusCard(label: emptyStateMessage)
                        }
                    } else {
                        if appState.isSearching {
                            statusCard(label: "Refreshing results...")
                        }

                        resultSummary

                        if appState.searchResults.songs.isEmpty == false {
                            resultSection(title: "Songs") {
                                ForEach(appState.searchResults.songs) { track in
                                    TrackRowView(
                                        track: track,
                                        showsNowPlayingIndicator: true,
                                        showsDownloadButton: true
                                    ) {
                                        playSearchTrack(track)
                                    }
                                }
                            }
                        }

                        if appState.searchResults.playlists.isEmpty == false {
                            resultSection(title: "Playlists") {
                                ForEach(appState.searchResults.playlists) { collection in
                                    NavigationLink(value: collection) {
                                        MusicCollectionRow(collection: collection)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if appState.searchResults.albums.isEmpty == false {
                            resultSection(title: "Albums") {
                                ForEach(appState.searchResults.albums) { collection in
                                    NavigationLink(value: collection) {
                                        MusicCollectionRow(collection: collection)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if appState.searchResults.artists.isEmpty == false {
                            resultSection(title: "Artists") {
                                ForEach(appState.searchResults.artists) { collection in
                                    NavigationLink(value: collection) {
                                        MusicCollectionRow(collection: collection)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomSpacing)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: MusicCollection.self) { collection in
                CollectionDetailView(collection: collection)
            }
            .searchable(text: $appState.searchQuery, prompt: "Songs, playlists, albums, artists")
            .onSubmit(of: .search) {
                commitRecentSearch(from: appState.searchQuery)
                scheduleSearch(for: appState.searchQuery, immediately: true)
            }
            .onChange(of: appState.searchQuery) { _, newValue in
                let shouldSearchImmediately = normalized(newValue) == normalized(immediateSearchQuery ?? "")
                scheduleSearch(for: newValue, immediately: shouldSearchImmediately)
                if shouldSearchImmediately {
                    immediateSearchQuery = nil
                }
            }
            .onDisappear {
                searchTask?.cancel()
            }
            .task(id: suggestionsRefreshKey) {
                await refreshSuggestedTracks()
            }
            .background(searchBackground.ignoresSafeArea())
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search songs, playlists, albums, and artists, then save anything you like to your library.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.68))

            Text(appState.isYouTubeConnected ? "Connected to YouTube, with your MusicTube library available everywhere." : "Guest mode is active. Connect YouTube anytime from Library for account sync.")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.46))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultSummary: some View {
        Text("\(appState.searchResults.totalResultCount) results")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.6))
    }

    private func resultSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            content()
        }
    }

    private var emptyStateMessage: String {
        if trimmedSearchQuery.isEmpty {
            return "Search for songs, playlists, albums, or artists."
        }

        if appState.isSearching {
            return "Searching..."
        }

        return "No results matched that search."
    }

    private var trimmedSearchQuery: String {
        appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestionsRefreshKey: String {
        "\(trimmedSearchQuery)|\(appState.recentSearches.joined(separator: "||"))"
    }

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent searches")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.72))

            VStack(spacing: 10) {
                ForEach(Array(appState.recentSearches.prefix(8)), id: \.self) { query in
                    HStack(spacing: 12) {
                        Button {
                            selectSuggestion(query)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.white.opacity(0.52))

                                Text(query)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            appState.removeRecentSearch(query)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.white.opacity(0.44))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(query)")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                }
            }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.72))

            if isLoadingSuggestedTracks, suggestedTracks.isEmpty {
                statusCard(label: "Learning your taste...")
            } else if suggestedTracks.isEmpty {
                statusCard(label: "Search and play a few songs to unlock personalized suggestions.")
            } else {
                VStack(spacing: 12) {
                    ForEach(suggestedTracks) { track in
                        TrackRowView(
                            track: track,
                            showsNowPlayingIndicator: true,
                            showsDownloadButton: true
                        ) {
                            playSuggestedTrack(track)
                        }
                    }
                }
            }
        }
    }

    private var bottomSpacing: CGFloat {
        appState.nowPlaying == nil ? 108 : 172
    }

    private var searchBackground: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.04, green: 0.04, blue: 0.08)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func statusCard(label: String) -> some View {
        HStack(spacing: 10) {
            if appState.isSearching || isLoadingSuggestedTracks {
                ProgressView()
                    .tint(.white)
            }

            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func playSearchTrack(_ track: Track) {
        commitRecentSearch(from: appState.searchQuery)
        appState.play(track: track, queue: appState.searchResults.songs)
    }

    private func playSuggestedTrack(_ track: Track) {
        appState.play(track: track, queue: suggestedTracks)
    }

    private func selectSuggestion(_ query: String) {
        immediateSearchQuery = query
        appState.searchQuery = query
        commitRecentSearch(from: query)
    }

    private func commitRecentSearch(from query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return }
        appState.recordRecentSearch(trimmedQuery)
    }

    private func refreshSuggestedTracks() async {
        guard trimmedSearchQuery.isEmpty else {
            suggestedTracks = []
            isLoadingSuggestedTracks = false
            return
        }

        isLoadingSuggestedTracks = true
        let loadedTracks = await appState.recentSearchTrackSuggestions(limit: 18)
        guard Task.isCancelled == false else { return }
        suggestedTracks = loadedTracks
        isLoadingSuggestedTracks = false
    }

    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func scheduleSearch(for query: String, immediately: Bool = false) {
        searchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            appState.clearSearch()
            return
        }

        searchTask = Task {
            if immediately == false {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }

            guard Task.isCancelled == false else { return }
            _ = await appState.search(query: trimmedQuery)
        }
    }
}

private struct MusicCollectionRow: View {
    @EnvironmentObject private var appState: AppState
    let collection: MusicCollection

    var body: some View {
        HStack(spacing: 14) {
            AsyncArtworkView(url: collection.artworkURL, cornerRadius: 14)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    appState.downloadCollection(collection)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    appState.toggleCollectionSaved(collection)
                } label: {
                    Image(systemName: appState.isCollectionSaved(collection) ? "bookmark.fill" : "bookmark")
                        .font(.headline)
                        .foregroundStyle(appState.isCollectionSaved(collection) ? Color(red: 1, green: 0.23, blue: 0.42) : Color.white.opacity(0.68))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var detailLine: String {
        var parts = [collectionKindLabel]
        if collection.subtitle.isEmpty == false {
            parts.append(collection.subtitle)
        }
        if collection.itemCount > 0 {
            parts.append(collection.itemCount == 1 ? "1 track" : "\(collection.itemCount) tracks")
        }
        return parts.joined(separator: " · ")
    }

    private var collectionKindLabel: String {
        switch collection.kind {
        case .playlist: return "Playlist"
        case .album: return "Album"
        case .artist: return "Artist"
        }
    }
}

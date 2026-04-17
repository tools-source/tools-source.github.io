import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    accountSection

                    if let libraryStatusMessage = appState.libraryStatusMessage,
                       appState.playlists.isEmpty,
                       appState.isLoadingPlaylists == false {
                        librarySection("Library Status") {
                            Text(libraryStatusMessage)
                                .font(.subheadline)
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                    }

                    likedSongsSection

                    playlistsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomSpacing)
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .refreshable {
                await appState.refreshLibrary()
            }
            .task {
                if appState.hasLoadedLibrary == false, appState.isLoadingPlaylists == false {
                    await appState.refreshLibrary()
                }
            }
            .onAppear {
                guard appState.hasLoadedLibrary, appState.isLoadingPlaylists == false else { return }
                Task {
                    await appState.refreshLikedSongsPlaylistFromAccount()
                }
            }
            .background(libraryBackground.ignoresSafeArea())
        }
    }

    private var likedSongsEmptyStateMessage: String {
        if appState.isUsingLocalLibraryFallback {
            if let libraryStatusMessage = appState.libraryStatusMessage,
               libraryStatusMessage.isEmpty == false {
                return "\(libraryStatusMessage)\nTap the heart on a song to save it here."
            }

            return "Tap the heart on a song to save it here."
        }

        return appState.libraryStatusMessage ?? "No liked songs were found for this account yet."
    }

    private var bottomSpacing: CGFloat {
        appState.nowPlaying == nil ? 108 : 174
    }

    private var libraryBackground: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.03, green: 0.03, blue: 0.05)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var accountSection: some View {
        librarySection("Account") {
            VStack(alignment: .leading, spacing: 16) {
                if let user = appState.user {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(user.name)
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(user.email)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                Button("Sign out", role: .destructive) {
                    Task {
                        await appState.signOut()
                    }
                }
                .font(.headline)
            }
        }
    }

    private var likedSongsSection: some View {
        librarySection("Liked Songs") {
            if appState.isLoadingPlaylists && appState.playlists.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Importing liked songs and playlists...")
                        .foregroundStyle(Color.white.opacity(0.72))
                }
            } else if let likedSongs = appState.likedSongsPlaylist {
                NavigationLink(value: likedSongs) {
                    PlaylistRow(playlist: likedSongs)
                }
                .buttonStyle(.plain)
            } else {
                Text(likedSongsEmptyStateMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.65))
            }
        }
    }

    private var playlistsSection: some View {
        librarySection("Playlists") {
            if appState.libraryPlaylists.isEmpty {
                Text(
                    appState.isUsingLocalLibraryFallback
                        ? "Search and play more songs to keep building Replay Mix and Favorites Mix."
                        : (appState.libraryStatusMessage ?? "No playlists found for this account yet.")
                )
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.65))
            } else {
                VStack(spacing: 12) {
                    ForEach(appState.libraryPlaylists) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistRow(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func librarySection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    }
            )
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 16)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(itemCountLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.6))
            }

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.35))
        }
        .padding(.vertical, 4)
    }

    private var itemCountLabel: String {
        switch playlist.kind {
        case .likedMusic:
            return playlist.itemCount == 1 ? "1 song" : "\(playlist.itemCount) songs"
        case .uploads:
            return playlist.itemCount == 1 ? "1 upload" : "\(playlist.itemCount) uploads"
        case .standard:
            return playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks"
        }
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject private var appState: AppState
    let playlist: Playlist

    @State private var tracks: [Track] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 14) {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading playlist tracks...")
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                } else if tracks.isEmpty {
                    Text("This collection does not have playable YouTube items yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        )
                } else {
                    ForEach(tracks) { track in
                        TrackRowView(
                            track: track,
                            showsNowPlayingIndicator: true,
                            showsDownloadButton: true
                        ) {
                            appState.play(track: track, queue: tracks)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, appState.nowPlaying == nil ? 108 : 174)
        }
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.03, green: 0.03, blue: 0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle(playlist.title)
        .task {
            guard tracks.isEmpty else { return }
            tracks = await appState.loadPlaylistItems(
                for: playlist,
                forceRefresh: playlist.kind == .likedMusic
            )
            isLoading = false
        }
        .refreshable {
            tracks = await appState.loadPlaylistItems(for: playlist, forceRefresh: true)
            isLoading = false
        }
    }
}

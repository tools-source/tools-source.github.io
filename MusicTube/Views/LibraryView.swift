import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if let user = appState.user {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.name)
                                .font(.headline)
                            Text(user.email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Sign out", role: .destructive) {
                        Task {
                            await appState.signOut()
                        }
                    }
                }

                Section("All Collections") {
                    if appState.isLoadingPlaylists && appState.playlists.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Importing collections...")
                                .foregroundStyle(.secondary)
                        }
                    } else if appState.playlists.isEmpty {
                        Text("No playlists or liked collections found for this account yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.playlists) { playlist in
                            NavigationLink(value: playlist) {
                                PlaylistRow(playlist: playlist)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
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
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 10)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(itemCountLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var itemCountLabel: String {
        switch playlist.kind {
        case .likedMusic:
            return "Music only"
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
        List {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("Loading playlist tracks...")
                        .foregroundStyle(.secondary)
                }
            } else if tracks.isEmpty {
                Text("This collection does not have playable YouTube items yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tracks) { track in
                    TrackRowView(track: track) {
                        appState.play(track: track, queue: tracks)
                    }
                }
            }
        }
        .navigationTitle(playlist.title)
        .task {
            guard tracks.isEmpty else { return }
            tracks = await appState.loadPlaylistItems(for: playlist)
            isLoading = false
        }
        .refreshable {
            tracks = await appState.loadPlaylistItems(for: playlist, forceRefresh: true)
            isLoading = false
        }
    }
}

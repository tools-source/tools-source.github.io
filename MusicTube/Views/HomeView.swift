import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    forYouSection

                    mixAlbumsSection
                }
                .padding()
                .padding(.bottom, 90)
            }
            .navigationTitle("Home")
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .refreshable {
                await appState.refreshDashboard()
            }
            .task {
                if appState.hasLoadedHome == false,
                   appState.isLoading == false,
                   appState.isLoadingPlaylists == false {
                    await appState.refreshDashboard()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Discover")
                .font(.largeTitle.bold())
            Text("Songs picked from the music you already like.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var forYouSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("For You")
                .font(.title3.bold())

            if appState.featuredTracks.isEmpty {
                if appState.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading music from your account...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("We couldn't build your recommendations yet. Pull to refresh after your likes finish loading.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(appState.featuredTracks) { track in
                    TrackRowView(track: track) {
                        appState.play(track: track, queue: appState.featuredTracks)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mixAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mix Albums")
                .font(.title3.bold())

            if appState.homeMixAlbums.isEmpty {
                if appState.isLoadingPlaylists {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading playlists and mixes...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Your playlists and mixes will show up here once they load from your account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(appState.homeMixAlbums) { playlist in
                            NavigationLink(value: playlist) {
                                MixAlbumCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct MixAlbumCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 18)
                .frame(width: 164, height: 164)

            Text(playlist.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 164, alignment: .leading)
    }

    private var detailText: String {
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

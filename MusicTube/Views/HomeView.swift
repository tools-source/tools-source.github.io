import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    quickPicksSection

                    featuredTracksSection

                    recentTracksSection

                    mixAlbumsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomSpacing)
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
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
            .background(homeBackground.ignoresSafeArea())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Discover")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("A denser home feed built from your likes, mixes, and recently played songs.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.68))

            HStack(spacing: 12) {
                Button {
                    Task {
                        await appState.refreshHome()
                    }
                } label: {
                    Label("Shuffle Picks", systemImage: "shuffle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1, green: 0.23, blue: 0.42))
                .disabled(appState.isLoading)

                if appState.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Refreshing")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.05, blue: 0.12),
                            Color(red: 0.07, green: 0.07, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
        )
    }

    @ViewBuilder
    private var quickPicksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("For You")
                .font(.title3.bold())
                .foregroundStyle(.white)

            if appState.featuredTracks.isEmpty {
                if appState.isLoading {
                    infoCard("Loading music from your account...")
                } else {
                    infoCard(
                        appState.homeStatusMessage ??
                            (appState.isUsingLocalLibraryFallback
                                ? "Search and play a few songs and we’ll turn that into your For You picks."
                                : "We couldn't build your recommendations yet. Pull to refresh after your library finishes loading.")
                    )
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(Array(appState.featuredTracks.prefix(6))) { track in
                        CompactTrackCard(track: track) {
                            appState.play(track: track, queue: homePlaybackQueue)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var featuredTracksSection: some View {
        let expandedFeaturedTracks = Array(appState.featuredTracks.dropFirst(6).prefix(10))

        if expandedFeaturedTracks.isEmpty == false {
            VStack(alignment: .leading, spacing: 8) {
                Text("More Songs")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                ForEach(expandedFeaturedTracks) { track in
                    TrackRowView(track: track) {
                        appState.play(track: track, queue: homePlaybackQueue)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentTracksSection: some View {
        if appState.recentTracks.isEmpty == false {
            VStack(alignment: .leading, spacing: 8) {
                Text("From Your Library")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                ForEach(Array(appState.recentTracks.prefix(12))) { track in
                    TrackRowView(track: track) {
                        appState.play(track: track, queue: homePlaybackQueue)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mixAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested Mixes")
                .font(.title3.bold())
                .foregroundStyle(.white)

            if appState.suggestedMixes.isEmpty {
                if appState.isLoadingPlaylists {
                    infoCard("Building suggested mixes...")
                } else {
                    infoCard(
                        appState.libraryStatusMessage ??
                            (appState.isUsingLocalLibraryFallback
                                ? "Replay Mix and Favorites Mix will show up here as you use the app."
                                : "We’ll pull suggested mixes from your playlists once your library finishes loading.")
                    )
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(appState.suggestedMixes) { playlist in
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

    private var bottomSpacing: CGFloat {
        appState.nowPlaying == nil ? 108 : 174
    }

    private var homeBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.03, green: 0.03, blue: 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(Color(red: 0.94, green: 0.18, blue: 0.35).opacity(0.16))
                .frame(width: 260, height: 260)
                .blur(radius: 80)
                .offset(x: 140, y: -220)
        }
    }

    private var homePlaybackQueue: [Track] {
        let combined = appState.featuredTracks + appState.recentTracks
        var seenIDs: Set<String> = []
        return combined.filter { track in
            let identifier = track.youtubeVideoID ?? track.id
            return seenIDs.insert(identifier).inserted
        }
    }

    private func infoCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.white.opacity(0.72))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
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
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)
        }
        .frame(width: 164, alignment: .leading)
        .padding(14)
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

    private var detailText: String {
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

private struct CompactTrackCard: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                AsyncArtworkView(url: track.artworkURL, cornerRadius: 20)
                    .frame(height: 152)

                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(track.artist)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    }
            )
        }
        .buttonStyle(.plain)
    }
}

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
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, appState.nowPlaying == nil ? 108 : 200)
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
                if !appState.hasLoadedHome, !appState.isLoading, !appState.isLoadingPlaylists {
                    await appState.refreshDashboard()
                }
            }
            .background(homeBackground.ignoresSafeArea())
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Discover")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("A denser home feed built from your likes, mixes, and recently played songs.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    Task { await appState.refreshHome() }
                } label: {
                    Label("Shuffle Picks", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1, green: 0.23, blue: 0.42))
                .disabled(appState.isLoading)

                if appState.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().tint(.white).scaleEffect(0.8)
                        Text("Refreshing")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.05, blue: 0.13),
                            Color(red: 0.08, green: 0.07, blue: 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        )
    }

    // MARK: For You — 2-column grid

    @ViewBuilder
    private var quickPicksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("For You")

            if appState.featuredTracks.isEmpty {
                if appState.isLoading {
                    skeletonGrid
                } else {
                    infoCard(
                        appState.homeStatusMessage ??
                            (appState.isUsingLocalLibraryFallback
                                ? "Play a few songs and we'll build your personalised picks."
                                : "Pull to refresh once your library finishes loading.")
                    )
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(Array(appState.featuredTracks.prefix(6))) { track in
                        CompactTrackCard(track: track) {
                            appState.play(track: track, queue: homePlaybackQueue)
                        }
                    }
                }
            }
        }
    }

    // MARK: More Songs

    @ViewBuilder
    private var featuredTracksSection: some View {
        let extra = Array(appState.featuredTracks.dropFirst(6).prefix(10))
        if extra.isEmpty == false {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("More Songs")
                VStack(spacing: 0) {
                    ForEach(extra) { track in
                        TrackRowView(track: track) {
                            appState.play(track: track, queue: homePlaybackQueue)
                        }
                        if track.id != extra.last?.id {
                            Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 76)
                        }
                    }
                }
                .padding(14)
                .background(glassCard(cornerRadius: 22))
            }
        }
    }

    // MARK: From Library

    @ViewBuilder
    private var recentTracksSection: some View {
        if appState.recentTracks.isEmpty == false {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("From Your Library")
                VStack(spacing: 0) {
                    ForEach(Array(appState.recentTracks.prefix(8))) { track in
                        TrackRowView(track: track) {
                            appState.play(track: track, queue: homePlaybackQueue)
                        }
                        if track.id != appState.recentTracks.prefix(8).last?.id {
                            Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 76)
                        }
                    }
                }
                .padding(14)
                .background(glassCard(cornerRadius: 22))
            }
        }
    }

    // MARK: Suggested Mixes

    @ViewBuilder
    private var mixAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Suggested Mixes")

            if appState.suggestedMixes.isEmpty {
                if appState.isLoadingPlaylists {
                    skeletonRow
                } else {
                    infoCard(
                        appState.libraryStatusMessage ??
                            (appState.isUsingLocalLibraryFallback
                                ? "Mixes appear here as you use the app."
                                : "Mixes will load once your library finishes syncing.")
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
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    // MARK: Helpers

    private var homePlaybackQueue: [Track] {
        let combined = appState.featuredTracks + appState.recentTracks
        var seen: Set<String> = []
        return combined.filter { seen.insert($0.youtubeVideoID ?? $0.id).inserted }
    }

    private var homeBackground: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.03, blue: 0.07), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(Color(red: 0.94, green: 0.18, blue: 0.35).opacity(0.14))
                .frame(width: 260, height: 260)
                .blur(radius: 90)
                .offset(x: 130, y: -240)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(.white)
    }

    private func infoCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.white.opacity(0.68))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(glassCard(cornerRadius: 20))
    }

    private func glassCard(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            }
    }

    // MARK: Skeleton Loading

    private var skeletonGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            ForEach(0..<6, id: \.self) { _ in
                SkeletonCard()
            }
        }
    }

    private var skeletonRow: some View {
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 160, height: 200)
                    .shimmering()
            }
        }
    }
}

// MARK: - MixAlbumCard

private struct MixAlbumCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 16)
                .frame(width: 156, height: 156)

            Text(playlist.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.58))
                .lineLimit(1)
        }
        .frame(width: 156, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
        )
    }

    private var detailText: String {
        let count = playlist.itemCount
        switch playlist.kind {
        case .likedMusic: return count == 1 ? "1 song" : "\(count) songs"
        case .uploads:    return count == 1 ? "1 upload" : "\(count) uploads"
        case .standard:   return count == 1 ? "1 track" : "\(count) tracks"
        }
    }
}

// MARK: - CompactTrackCard

private struct CompactTrackCard: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                AsyncArtworkView(url: track.artworkURL, cornerRadius: 16)
                    .aspectRatio(1, contentMode: .fit)   // always square, no fixed height
                    .clipped()

                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(track.artist)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                    }
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SkeletonCard

private struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .aspectRatio(1, contentMode: .fit)
                .shimmering()

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(height: 12)
                .shimmering()

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(width: 80, height: 10)
                .shimmering()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - Shimmer modifier

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.08),
                            Color.white.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: geo.size.width * (phase - 1))
                }
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

private extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

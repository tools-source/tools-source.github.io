import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var viewModel: HomeViewModel

    private var snapshot: HomeSnapshot { viewModel.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    header
                        .appearTransition()
                    spotlightSection
                        .appearTransition(delay: 0.04)
                    quickActions
                        .appearTransition(delay: 0.08)
                    statusMessage
                    continueListeningSection
                    madeForYouSection
                    mixesSection
                    recentlyPlayedSection
                    contextualSection
                }
                .padding(.horizontal, AppLayout.horizontalMargin)
                .padding(.top, AppSpacing.small)
                .padding(.bottom, snapshot.nowPlayingKey == nil ? 108 : 178)
            }
            .navigationBarHidden(true)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: coordinator.playlistViewModel(for: playlist)
                )
            }
            .refreshable {
                await viewModel.refresh()
            }
            .task {
                await viewModel.appear()
            }
            .premiumScreenBackground()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AppSpacing.medium) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)

                Text(snapshot.displayName ?? "MusicTube")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)

                Text("A fresh soundtrack, shaped by your listening")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: AppSpacing.small)

            NavigationLink {
                SettingsView(viewModel: coordinator.settings)
            } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(AppTheme.controlFill))
                    .overlay(Circle().strokeBorder(AppTheme.surfaceStroke, lineWidth: 1))
            }
            .accessibilityLabel("Account and settings")
        }
    }

    @ViewBuilder
    private var spotlightSection: some View {
        if let track = snapshot.spotlightTrack {
            HomeSpotlightCard(
                track: track,
                isCurrent: snapshot.nowPlayingKey == track.playbackKey,
                isPlaying: snapshot.isPlaying,
                isRefreshing: snapshot.isLoading,
                onPlay: viewModel.playFreshMix,
                onTogglePlayback: viewModel.togglePlayback,
                onRefresh: {
                    Task { await viewModel.refresh() }
                }
            )
            .onAppear(perform: viewModel.spotlightAppeared)
        } else if snapshot.hasLoaded == false || snapshot.isLoading {
            HomeSpotlightPlaceholder()
        } else {
            HomeEmptyState(onSearch: viewModel.openSearch)
        }
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                HomeQuickAction(
                    title: "Surprise me",
                    systemImage: "sparkles",
                    tint: AppTheme.accent,
                    action: viewModel.surpriseMe
                )
                HomeQuickAction(
                    title: "Search",
                    systemImage: "magnifyingglass",
                    tint: .blue,
                    action: viewModel.openSearch
                )
                HomeQuickAction(
                    title: "Library",
                    systemImage: "music.note.list",
                    tint: .purple,
                    action: viewModel.openLibrary
                )
                HomeQuickAction(
                    title: "Offline",
                    systemImage: "arrow.down.circle.fill",
                    tint: .green,
                    action: viewModel.openDownloads
                )
            }
        }
        .contentMargins(.horizontal, 1)
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let message = snapshot.statusMessage, message.isEmpty == false {
            Label(message, systemImage: "info.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(AppSpacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appSurface()
        }
    }

    @ViewBuilder
    private var continueListeningSection: some View {
        if snapshot.continueListening.isEmpty == false {
            HomeSection(
                title: "Jump back in",
                subtitle: "Continue from your recent queue",
                systemImage: "waveform"
            ) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(snapshot.continueListening) { track in
                            HomeArtworkCard(
                                track: track,
                                isCurrent: snapshot.nowPlayingKey == track.playbackKey,
                                isPlaying: snapshot.isPlaying
                            ) {
                                viewModel.playContinueListening(track)
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, 1)
            }
        }
    }

    private var madeForYouSection: some View {
        HomeSection(
            title: "Fresh for you",
            subtitle: snapshot.recommendationBlurb ?? "Previously shown songs move back so discovery stays fresh",
            systemImage: "wand.and.stars"
        ) {
            if snapshot.madeForYou.isEmpty {
                if snapshot.hasLoaded == false || snapshot.isLoading {
                    HomeLoadingRows()
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.madeForYou) { item in
                        TrackSwipeActionsView(
                            onMore: { viewModel.recommendMoreLike(item.track) },
                            onLess: { viewModel.recommendLessLike(item.track) }
                        ) {
                            RecommendedRow(
                                track: item.track,
                                isCurrentTrack: snapshot.nowPlayingKey == item.track.playbackKey,
                                isPlaying: snapshot.isPlaying,
                                onTap: {
                                    viewModel.play(
                                        item.track,
                                        queue: [snapshot.spotlightTrack].compactMap { $0 } + snapshot.madeForYou.map(\.track)
                                    )
                                },
                                onPlayPause: viewModel.togglePlayback
                            )
                        }
                        .onAppear {
                            viewModel.recommendationAppeared(item)
                        }

                        if item.id != snapshot.madeForYou.last?.id {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 64)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .appSurface()
            }
        }
    }

    @ViewBuilder
    private var mixesSection: some View {
        if snapshot.mixes.isEmpty == false {
            HomeSection(
                title: "Your mixes",
                subtitle: "Longer sessions built around your taste",
                systemImage: "square.stack.3d.up.fill"
            ) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(snapshot.mixes) { playlist in
                            NavigationLink(value: playlist) {
                                HomeMixCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .contentMargins(.horizontal, 1)
            }
        }
    }

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        if snapshot.recentlyPlayed.isEmpty == false {
            HomeSection(
                title: "Recently played",
                subtitle: "Your listening history at a glance",
                systemImage: "clock.arrow.circlepath"
            ) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(snapshot.recentlyPlayed) { track in
                            HomeArtworkCard(
                                track: track,
                                isCurrent: snapshot.nowPlayingKey == track.playbackKey,
                                isPlaying: snapshot.isPlaying
                            ) {
                                viewModel.play(track, queue: snapshot.recentlyPlayed)
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, 1)
            }
        }
    }

    @ViewBuilder
    private var contextualSection: some View {
        if snapshot.contextualTracks.isEmpty == false {
            HomeSection(
                title: "More like this",
                subtitle: "Inspired by what you are listening to now",
                systemImage: "point.3.connected.trianglepath.dotted"
            ) {
                VStack(spacing: 0) {
                    ForEach(snapshot.contextualTracks) { track in
                        RecommendedRow(
                            track: track,
                            isCurrentTrack: snapshot.nowPlayingKey == track.playbackKey,
                            isPlaying: snapshot.isPlaying,
                            onTap: {
                                viewModel.play(track, queue: snapshot.contextualTracks)
                            },
                            onPlayPause: viewModel.togglePlayback
                        )

                        if track.playbackKey != snapshot.contextualTracks.last?.playbackKey {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 64)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .appSurface()
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "GOOD MORNING"
        case 12..<18: return "GOOD AFTERNOON"
        default: return "GOOD EVENING"
        }
    }
}

private struct HomeSpotlightCard: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let isRefreshing: Bool
    let onPlay: () -> Void
    let onTogglePlayback: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncArtworkView(
                url: track.artworkURL,
                cornerRadius: 0,
                maxPixelSize: ArtworkTargetSize.card
            )
            .frame(maxWidth: .infinity)
            .frame(height: 268)
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.22), .black.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("FRESH PICK", systemImage: "sparkles")
                    .font(.caption2.bold())
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(AppTheme.accent.opacity(0.92)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    Button(action: isCurrent ? onTogglePlayback : onPlay) {
                        Label(
                            isCurrent && isPlaying ? "Pause" : "Play mix",
                            systemImage: isCurrent && isPlaying ? "pause.fill" : "play.fill"
                        )
                        .font(.subheadline.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 17)
                        .frame(height: 44)
                        .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain)

                    Button(action: onRefresh) {
                        Label("New picks", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 15)
                            .frame(height: 44)
                            .background(Capsule().fill(.white.opacity(0.18)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .opacity(isRefreshing ? 0.55 : 1)
                }
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: AppTheme.accent.opacity(0.14), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
    }
}

private struct HomeQuickAction: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline.bold())
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Capsule().fill(AppTheme.cardFill))
            .overlay(Capsule().strokeBorder(AppTheme.surfaceStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct HomeSection<Content: View>: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(AppTheme.primaryText)

                    if let subtitle, subtitle.isEmpty == false {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
    }
}

private struct HomeArtworkCard: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                AsyncArtworkView(
                    url: track.artworkURL,
                    cornerRadius: 16,
                    maxPixelSize: ArtworkTargetSize.card
                )
                .frame(width: 146, height: 146)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(isCurrent ? AppTheme.accent : .black.opacity(0.68)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        .padding(8)
                }

                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrent ? AppTheme.accent : AppTheme.primaryText)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: 146, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct HomeMixCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncArtworkView(
                url: playlist.artworkURL,
                cornerRadius: 16,
                maxPixelSize: ArtworkTargetSize.card
            )
            .frame(width: 176, height: 176)
            .overlay(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.76)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Label("MIX", systemImage: "waveform")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(12)
                }
            }

            Text(playlist.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)

            Text(playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(width: 176, alignment: .leading)
    }
}

private struct HomeSpotlightPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(AppTheme.cardFill)
            .frame(height: 268)
            .overlay {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(AppTheme.accent)
                    Text("Building fresh picks…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .accessibilityLabel("Loading fresh recommendations")
    }
}

private struct HomeLoadingRows: View {
    var body: some View {
        VStack(spacing: AppSpacing.small) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .fill(AppTheme.cardFill)
                    .frame(height: 68)
                    .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel("Loading recommendations")
    }
}

private struct HomeEmptyState: View {
    let onSearch: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house.fill")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.accent)
            Text("Let’s find your sound")
                .font(.title3.bold())
            Text("Search and play a few songs. Your home feed will quickly adapt around what you enjoy.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Explore music", action: onSearch)
                .buttonStyle(AppPrimaryActionButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .appSurface()
    }
}

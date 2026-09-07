import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var viewModel: LibraryViewModel

    private var snapshot: LibrarySnapshot { viewModel.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: AppSpacing.large) {
                    primaryDestinations
                    playlistsSection
                    collectionsSection
                    historySection
                }
                .padding(.horizontal, AppLayout.horizontalMargin)
                .padding(.top, AppSpacing.small)
                .padding(.bottom, snapshot.nowPlayingKey == nil ? 108 : 174)
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: viewModel.createPlaylist) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create playlist")

                    NavigationLink {
                        SettingsView(viewModel: coordinator.settings)
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Account and settings")
                }
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: coordinator.playlistViewModel(for: playlist)
                )
            }
            .navigationDestination(for: MusicCollection.self) { collection in
                CollectionDetailView(collection: collection)
            }
            .navigationDestination(for: String.self) { route in
                if route == "HistoryDetail" {
                    HistoryDetailView()
                }
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

    private var primaryDestinations: some View {
        VStack(spacing: AppSpacing.small) {
            if let likedSongs = snapshot.likedSongs {
                NavigationLink(value: likedSongs) {
                    LibraryOverviewRow(
                        title: "Liked Songs",
                        subtitle: likedSongs.itemCount == 1 ? "1 song" : "\(likedSongs.itemCount) songs",
                        systemImage: "heart.fill",
                        artworkURL: likedSongs.artworkURL
                    )
                }
                .buttonStyle(.plain)
            }

            Button(action: viewModel.openDownloads) {
                LibraryOverviewRow(
                    title: "Downloaded Music",
                    subtitle: snapshot.downloadedCount == 1
                        ? "1 song available offline"
                        : "\(snapshot.downloadedCount) songs available offline",
                    systemImage: "arrow.down.circle.fill",
                    artworkURL: snapshot.downloadedArtworkURL
                )
            }
            .buttonStyle(.plain)

            NavigationLink(value: "HistoryDetail") {
                LibraryOverviewRow(
                    title: "Listening History",
                    subtitle: snapshot.history.isEmpty ? "No recent listening" : "Your recently played music",
                    systemImage: "clock.arrow.circlepath",
                    artworkURL: snapshot.history.first?.artworkURL
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        LibraryOverviewSection(title: "Playlists") {
            if snapshot.playlists.isEmpty {
                Text("Create playlists from any track menu.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, AppSpacing.small)
            } else {
                ForEach(Array(snapshot.playlists.enumerated()), id: \.element.id) { index, playlist in
                    NavigationLink(value: playlist) {
                        LibraryOverviewRow(
                            title: playlist.title,
                            subtitle: playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks",
                            systemImage: "music.note.list",
                            artworkURL: playlist.artworkURL
                        )
                    }
                    .buttonStyle(.plain)

                    if index < snapshot.playlists.count - 1 {
                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 68)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var collectionsSection: some View {
        LibraryOverviewSection(title: "Albums & Collections") {
            if snapshot.collections.isEmpty {
                Text("Saved albums, artists, and collections will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, AppSpacing.small)
            } else {
                let collections = Array(snapshot.collections.prefix(8))
                ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                    NavigationLink(value: collection) {
                        LibraryOverviewRow(
                            title: collection.title,
                            subtitle: collection.subtitle,
                            systemImage: collection.kind == .artist ? "person.fill" : "square.stack.fill",
                            artworkURL: collection.artworkURL
                        )
                    }
                    .buttonStyle(.plain)

                    if index < collections.count - 1 {
                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 68)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if snapshot.history.isEmpty == false {
            LibraryOverviewSection(title: "Recently Played") {
                ForEach(Array(snapshot.history.enumerated()), id: \.element.id) { index, track in
                    LibraryOverviewRow(
                        title: track.title,
                        subtitle: track.artist,
                        systemImage: "music.note",
                        artworkURL: track.artworkURL
                    )

                    if index < snapshot.history.count - 1 {
                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 68)
                    }
                }
            }
        }
    }
}

private struct LibraryOverviewSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(AppTheme.primaryText)
            VStack(spacing: 0) {
                content
            }
        }
    }
}

private struct LibraryOverviewRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let artworkURL: URL?

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            Group {
                if let artworkURL {
                    AsyncArtworkView(
                        url: artworkURL,
                        cornerRadius: AppCornerRadius.small,
                        maxPixelSize: ArtworkTargetSize.compactRow
                    )
                } else {
                    RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                        .fill(AppTheme.controlFill)
                        .overlay {
                            Image(systemName: systemImage)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.tertiaryText)
        }
        .padding(.vertical, AppSpacing.small)
        .contentShape(Rectangle())
    }
}

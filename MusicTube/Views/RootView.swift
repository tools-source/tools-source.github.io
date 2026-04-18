import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch appState.authState {
            case .restoring:
                ProgressView("Loading your music...")
                    .tint(.white)
            case .guest, .signedIn:
                MainTabView()
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $appState.isPlayerPresented, onDismiss: {
            appState.dismissPlayer()
        }) {
            if let nowPlaying = appState.nowPlaying {
                PlayerView(track: nowPlaying, playbackService: appState.playbackEngine)
                    .environmentObject(appState)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { _ in appState.errorMessage = nil }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $appState.isPlaylistPickerPresented, onDismiss: {
            appState.dismissPlaylistPicker()
        }) {
            PlaylistPickerSheet()
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - MainTabView

private struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    init() {
        Self.configureTabBarAppearance()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }

                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }

                DownloadsView()
                    .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }

                LibraryView()
                    .tabItem { Label("Library", systemImage: "music.note.list") }
            }
            .toolbarColorScheme(.dark, for: .tabBar)

            // Persistent mini player sits between content and tab bar
            if let nowPlaying = appState.nowPlaying {
                MiniPlayerBar(
                    track: nowPlaying,
                    playbackService: appState.playbackEngine,
                    onTap: { appState.isPlayerPresented = true },
                    onPreviousTap: { appState.playPreviousTrack() },
                    onPlayPauseTap: { appState.togglePlayback() },
                    onNextTap: { appState.playNextTrack() },
                    onCloseTap: { appState.closeNowPlaying() }
                )
                // Sits just above the tab bar (tab bar ~49pt + safe area handled inside)
                .padding(.bottom, 49)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: appState.nowPlaying?.id)
    }

    private static func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.backgroundColor = UIColor(white: 0.05, alpha: 0.92)
        appearance.shadowColor = .clear

        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(white: 0.45, alpha: 1)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(white: 0.45, alpha: 1)]
        item.selected.iconColor = .white
        item.selected.titleTextAttributes = [.foregroundColor: UIColor.white]

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

private struct PlaylistPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var playlistName = ""

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.playlistPickerTrack == nil ? "Create playlist" : "Save to playlist")
                            .font(.title3.bold())
                            .foregroundStyle(.white)

                        Text(helperText)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.64))
                    }

                    if appState.playlistPickerTrack != nil, appState.customPlaylists.isEmpty == false {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your playlists")
                                .font(.headline)
                                .foregroundStyle(.white)

                            ForEach(appState.customPlaylists) { playlist in
                                Button {
                                    appState.addPlaylistPickerTrack(to: playlist)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 10)
                                            .frame(width: 48, height: 48)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(playlist.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.white)
                                            Text(playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks")
                                                .font(.caption)
                                                .foregroundStyle(Color.white.opacity(0.58))
                                        }

                                        Spacer()

                                        Image(systemName: "plus.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
                                    }
                                    .padding(14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(Color.white.opacity(0.06))
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            Divider()
                                .overlay(Color.white.opacity(0.08))
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(appState.playlistPickerTrack == nil ? "New playlist" : "Create new playlist")
                            .font(.headline)
                            .foregroundStyle(.white)

                        TextField("Playlist name", text: $playlistName)
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .foregroundStyle(.white)

                        Button {
                            if appState.createCustomPlaylist(named: playlistName) {
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                Text(appState.playlistPickerTrack == nil ? "Create Playlist" : "Create & Add Song")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 1, green: 0.23, blue: 0.42))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let track = appState.playlistPickerTrack {
                            trackPreview(track)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        appState.dismissPlaylistPicker()
                        dismiss()
                    }
                    .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
                }
            }
        }
    }

    private var helperText: String {
        if let track = appState.playlistPickerTrack {
            return "Add \(track.title) to an existing playlist or create a new one."
        }

        return "Create a playlist now and start filling it from search, home, downloads, or the player."
    }

    private func trackPreview(_ track: Track) -> some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}

// MARK: - MiniPlayerBar (matches mockup)

private struct MiniPlayerBar: View {
    let track: Track
    @ObservedObject var playbackService: PlaybackService
    let onTap: () -> Void
    let onPreviousTap: () -> Void
    let onPlayPauseTap: () -> Void
    let onNextTap: () -> Void
    let onCloseTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 0) {
                // Artwork + info — tappable to open player
                Button(action: onTap) {
                    HStack(spacing: 12) {
                        AsyncArtworkView(url: track.artworkURL, cornerRadius: 8)
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(Color(white: 0.60))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onCloseTap) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)

                // Transport controls
                HStack(spacing: 4) {
                    // Skip back
                    Button(action: onPreviousTap) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(playbackService.hasPreviousTrack ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(!playbackService.hasPreviousTrack)

                    // Play / Pause — filled circle like mockup
                    Button(action: onPlayPauseTap) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 1, green: 0.23, blue: 0.42))
                                .frame(width: 36, height: 36)

                            if playbackService.isResolvingStream {
                                ProgressView().tint(.white).scaleEffect(0.65)
                            } else {
                                Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: playbackService.isPlaying ? 0 : 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    // Skip forward
                    Button(action: onNextTap) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(playbackService.hasNextTrack ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(!playbackService.hasNextTrack)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Thin progress bar at very bottom of bar
            MiniProgressStrip(progress: playbackProgress)
        }
        .background(
            Rectangle()
                .fill(Color(white: 0.07, opacity: 1))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                }
        )
    }

    private var playbackProgress: Double {
        guard playbackService.duration.isFinite, playbackService.duration > 0 else { return 0 }
        return min(max(playbackService.currentTime / playbackService.duration, 0), 1)
    }
}

// MARK: - MiniProgressStrip

private struct MiniProgressStrip: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08))
                Rectangle()
                    .fill(Color(red: 1, green: 0.23, blue: 0.42))
                    .frame(width: max(geo.size.width * clamped, 0))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

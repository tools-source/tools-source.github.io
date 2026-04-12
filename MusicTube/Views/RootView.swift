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
            case .signedOut:
                LoginView()
            case .signedIn:
                MainTabView()
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $appState.isPlayerPresented, onDismiss: {
            appState.dismissPlayer()
        }) {
            if let nowPlaying = appState.nowPlaying {
                PlayerView(track: nowPlaying)
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
                    isPlaying: appState.isPlaying,
                    isPreparingPlayback: appState.isPreparingPlayback,
                    playbackProgress: appState.playbackProgress,
                    hasPreviousTrack: appState.hasPreviousTrack,
                    hasNextTrack: appState.hasNextTrack,
                    onTap: { appState.isPlayerPresented = true },
                    onPreviousTap: { appState.playPreviousTrack() },
                    onPlayPauseTap: { appState.togglePlayback() },
                    onNextTap: { appState.playNextTrack() }
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

// MARK: - MiniPlayerBar (matches mockup)

private struct MiniPlayerBar: View {
    let track: Track
    let isPlaying: Bool
    let isPreparingPlayback: Bool
    let playbackProgress: Double
    let hasPreviousTrack: Bool
    let hasNextTrack: Bool
    let onTap: () -> Void
    let onPreviousTap: () -> Void
    let onPlayPauseTap: () -> Void
    let onNextTap: () -> Void

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

                // Transport controls
                HStack(spacing: 4) {
                    // Skip back
                    Button(action: onPreviousTap) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(hasPreviousTrack ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasPreviousTrack)

                    // Play / Pause — filled circle like mockup
                    Button(action: onPlayPauseTap) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 1, green: 0.23, blue: 0.42))
                                .frame(width: 36, height: 36)

                            if isPreparingPlayback {
                                ProgressView().tint(.white).scaleEffect(0.65)
                            } else {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: isPlaying ? 0 : 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    // Skip forward
                    Button(action: onNextTap) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(hasNextTrack ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasNextTrack)
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

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
        GeometryReader { geometry in
            TabView {
                HomeView()
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }

                SearchView()
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }

                DownloadsView()
                    .tabItem {
                        Label("Downloads", systemImage: "arrow.down.circle.fill")
                    }

                LibraryView()
                    .tabItem {
                        Label("Library", systemImage: "music.note.list")
                    }
            }
            .toolbarColorScheme(.dark, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if appState.nowPlaying != nil {
                    // Reserve space so tab bar is not obscured by mini player
                    Color.clear
                        .frame(height: miniPlayerHeight(safeArea: geometry.safeAreaInsets.bottom))
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottom) {
                if let nowPlaying = appState.nowPlaying {
                    MiniPlayerView(
                        track: nowPlaying,
                        isPlaying: appState.isPlaying,
                        isPreparingPlayback: appState.isPreparingPlayback,
                        playbackProgress: appState.playbackProgress,
                        hasNextTrack: appState.hasNextTrack,
                        onTap: { appState.isPlayerPresented = true },
                        onPlayPauseTap: { appState.togglePlayback() },
                        onNextTap: { appState.playNextTrack() }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 8) + 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: appState.nowPlaying?.id)
        }
    }

    private func miniPlayerHeight(safeArea: CGFloat) -> CGFloat {
        // mini player (~80px) + padding above tab bar
        80 + max(safeArea, 8) + 50
    }

    private static func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.52)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.06)

        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = UIColor(white: 0.50, alpha: 1)
        itemAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(white: 0.50, alpha: 1)
        ]
        itemAppearance.selected.iconColor = .white
        itemAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor.white
        ]

        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

// MARK: - MiniPlayerView

private struct MiniPlayerView: View {
    let track: Track
    let isPlaying: Bool
    let isPreparingPlayback: Bool
    let playbackProgress: Double
    let hasNextTrack: Bool
    let onTap: () -> Void
    let onPlayPauseTap: () -> Void
    let onNextTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar at very top
            MiniPlayerProgressBar(progress: playbackProgress)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            HStack(spacing: 10) {
                // Tappable track info area
                Button(action: onTap) {
                    HStack(spacing: 12) {
                        AsyncArtworkView(url: track.artworkURL, cornerRadius: 12)
                            .frame(width: 44, height: 44)
                            .overlay(alignment: .topLeading) {
                                Circle()
                                    .fill((isPlaying ? Color.green : Color.gray).opacity(0.9))
                                    .frame(width: 9, height: 9)
                                    .overlay {
                                        Circle().stroke(Color.black.opacity(0.4), lineWidth: 1.5)
                                    }
                                    .offset(x: -3, y: -3)
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(Color(white: 0.65))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Play / pause
                Button(action: onPlayPauseTap) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 38, height: 38)

                        if isPreparingPlayback {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: isPlaying ? 0 : 1)
                        }
                    }
                }
                .buttonStyle(.plain)

                // Next track
                Button(action: onNextTap) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(hasNextTrack ? Color.white : Color.white.opacity(0.25))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(!hasNextTrack)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.44))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}

// MARK: - MiniPlayerProgressBar

private struct MiniPlayerProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(progress, 0), 1)
            let width = max(geometry.size.width * clamped, clamped > 0 ? 10 : 0)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.92), Color(red: 1, green: 0.23, blue: 0.42).opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width)
            }
        }
        .frame(height: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }
}

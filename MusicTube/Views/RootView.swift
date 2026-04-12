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

                LibraryView()
                    .tabItem {
                        Label("Library", systemImage: "music.note.list")
                    }
            }
            .toolbarColorScheme(.dark, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if appState.nowPlaying != nil {
                    Color.clear
                        .frame(height: 132)
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
                        onTap: {
                            appState.isPlayerPresented = true
                        },
                        onPlayPauseTap: {
                            appState.togglePlayback()
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 10) + 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: appState.nowPlaying?.id)
        }
    }

    private static func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.06)

        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = UIColor(white: 0.57, alpha: 1)
        itemAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(white: 0.57, alpha: 1)
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

private struct MiniPlayerView: View {
    let track: Track
    let isPlaying: Bool
    let isPreparingPlayback: Bool
    let playbackProgress: Double
    let onTap: () -> Void
    let onPlayPauseTap: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: onTap) {
                    HStack(spacing: 12) {
                        AsyncArtworkView(url: track.artworkURL, cornerRadius: 14)
                            .frame(width: 48, height: 48)
                            .overlay(alignment: .topLeading) {
                                Circle()
                                    .fill((isPlaying ? Color.green : Color.gray).opacity(0.9))
                                    .frame(width: 10, height: 10)
                                    .overlay {
                                        Circle()
                                            .stroke(Color.black.opacity(0.35), lineWidth: 2)
                                    }
                                    .offset(x: -4, y: -4)
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(Color(white: 0.72))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.backward.and.arrow.down.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onPlayPauseTap) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 40, height: 40)

                        if isPreparingPlayback {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                                .offset(x: isPlaying ? 0 : 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            MiniPlayerProgressBar(progress: playbackProgress)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.42))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }
}

private struct MiniPlayerProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let clampedProgress = min(max(progress, 0), 1)
            let width = max(geometry.size.width * clampedProgress, clampedProgress > 0 ? 10 : 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.95), Color.pink.opacity(0.72)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width)
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }
}

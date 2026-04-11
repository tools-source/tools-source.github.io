import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch appState.authState {
            case .restoring:
                ProgressView("Loading your music...")
            case .signedOut:
                LoginView()
            case .signedIn:
                MainTabView()
            }
        }
        .sheet(isPresented: $appState.isPlayerPresented, onDismiss: {
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

    var body: some View {
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
        .overlay(alignment: .bottom) {
            if let nowPlaying = appState.nowPlaying {
                MiniPlayerView(track: nowPlaying) {
                    appState.isPlayerPresented = true
                }
                .padding(.horizontal)
                .padding(.bottom, 62)
            }
        }
    }
}

private struct MiniPlayerView: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AsyncArtworkView(url: track.artworkURL, cornerRadius: 8)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

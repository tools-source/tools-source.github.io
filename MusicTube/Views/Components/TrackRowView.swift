import SwiftUI

struct DownloadButton: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var downloadService = DownloadService.shared

    let track: Track
    var size: CGFloat = 36

    var body: some View {
        let downloading = downloadService.isDownloading(track)
        let downloaded = downloadService.isDownloaded(track)
        let progress = downloadService.downloadProgress(for: track)

        Button {
            appState.downloadTrack(track)
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))

                if downloading {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: progress)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.7))
                } else if downloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.cyan)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(downloading || downloaded)
    }
}

struct TrackActionsButton: View {
    @EnvironmentObject private var appState: AppState
    let track: Track
    var size: CGFloat = 36

    var body: some View {
        Menu {
            Button {
                appState.toggleTrackSaved(track)
            } label: {
                Label(
                    appState.isTrackSaved(track) ? "Remove From Library" : "Save To Library",
                    systemImage: appState.isTrackSaved(track) ? "bookmark.slash" : "bookmark"
                )
            }

            Button {
                appState.presentPlaylistPicker(for: track)
            } label: {
                Label("Add To Playlist", systemImage: "text.badge.plus")
            }

            Button {
                appState.toggleLike(for: track)
            } label: {
                Label(
                    appState.isTrackLiked(track) ? "Unlike" : "Like",
                    systemImage: appState.isTrackLiked(track) ? "heart.slash" : "heart"
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}

struct TrackRowView: View {
    @EnvironmentObject private var appState: AppState

    let track: Track
    var showsNowPlayingIndicator: Bool = false
    var showsDownloadButton: Bool = false
    var prefetchPlaybackOnAppear: Bool = true
    let onTap: () -> Void

    @StateObject private var downloadService = DownloadService.shared

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 4) {
                            if isCurrentlyPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))

                                Text("Playing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))
                            }

                            if appState.isTrackSaved(track) {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.white.opacity(0.75))
                            }

                            if downloadService.isDownloaded(track) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.cyan.opacity(0.8))
                            }

                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)

                            if let duration = track.formattedDuration {
                                Text("· \(duration)")
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.38))
                                    .fixedSize()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsDownloadButton {
                DownloadButton(track: track, size: 36)
            }

            TrackActionsButton(track: track, size: 36)

            Button(action: handlePlaybackButtonTap) {
                Image(systemName: isCurrentlyPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color(red: 1, green: 0.24, blue: 0.43))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .task(id: track.playbackKey) {
            guard prefetchPlaybackOnAppear else { return }
            appState.prefetchPlayback(for: [track])
        }
    }

    private var isCurrentlyPlaying: Bool {
        showsNowPlayingIndicator && isCurrentTrack && appState.isPlaying
    }

    private var isCurrentTrack: Bool {
        guard let nowPlaying = appState.nowPlaying else { return false }
        return nowPlaying.playbackKey == track.playbackKey
    }

    private func handlePlaybackButtonTap() {
        if showsNowPlayingIndicator && isCurrentTrack {
            appState.togglePlayback()
        } else {
            onTap()
        }
    }
}

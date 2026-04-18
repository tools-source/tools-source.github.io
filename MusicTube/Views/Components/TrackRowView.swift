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
    let onTap: () -> Void

    @StateObject private var downloadService = DownloadService.shared

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    AsyncArtworkView(url: track.artworkURL, cornerRadius: 14)
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 4) {
                            if isCurrentlyPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))

                                Text("Playing")
                                    .font(.footnote.weight(.semibold))
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
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.58))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }
        )
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

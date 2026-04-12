import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var downloadService = DownloadService.shared

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if downloadService.activeDownloads.isEmpty == false {
                        activeDownloadsSection
                    }

                    if downloadService.downloads.isEmpty && downloadService.activeDownloads.isEmpty {
                        emptyState
                    } else if downloadService.downloads.isEmpty == false {
                        downloadedTracksSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, appState.nowPlaying == nil ? 108 : 174)
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.large)
            .background(downloadsBackground.ignoresSafeArea())
            .toolbar {
                if downloadService.downloads.isEmpty == false {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        storageLabel
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var activeDownloadsSection: some View {
        downloadsSection("Downloading") {
            VStack(spacing: 10) {
                ForEach(Array(downloadService.activeDownloads.values)) { active in
                    ActiveDownloadRow(active: active) {
                        downloadService.cancelDownload(for: active.track)
                    }
                }
            }
        }
    }

    private var downloadedTracksSection: some View {
        downloadsSection("Downloaded") {
            VStack(spacing: 0) {
                ForEach(downloadService.downloads.reversed()) { record in
                    DownloadedTrackRow(record: record) {
                        let localTrack = record.localTrack
                        let allDownloaded = downloadService.downloads.reversed().map(\.localTrack)
                        appState.play(track: localTrack, queue: allDownloaded)
                    } onDelete: {
                        withAnimation(.spring(response: 0.3)) {
                            downloadService.deleteDownload(record)
                        }
                    }
                    if record.id != downloadService.downloads.first?.id {
                        Divider()
                            .overlay(Color.white.opacity(0.06))
                            .padding(.leading, 80)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Color.white.opacity(0.3))

            VStack(spacing: 8) {
                Text("No Downloads Yet")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text("Tap the download button on any song to save it for offline listening.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
    }

    private var storageLabel: some View {
        Text(String(format: "%.1f MB", downloadService.totalDownloadedMB))
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.55))
    }

    private func downloadsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Color.white.opacity(0.03))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        }
                )
        }
    }

    private var downloadsBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.03, green: 0.03, blue: 0.07)],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(Color(red: 0.1, green: 0.3, blue: 0.8).opacity(0.12))
                .frame(width: 240, height: 240)
                .blur(radius: 80)
                .offset(x: -100, y: -200)
        }
    }
}

// MARK: - ActiveDownloadRow

private struct ActiveDownloadRow: View {
    let active: ActiveDownload
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: active.track.artworkURL, cornerRadius: 12)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                Text(active.track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(active.track.artist)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)

                DownloadProgressBar(progress: active.progress)
                    .frame(height: 3)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - DownloadProgressBar

struct DownloadProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.3, green: 0.6, blue: 1), Color.cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geo.size.width * progress, progress > 0 ? 8 : 0))
            }
        }
    }
}

// MARK: - DownloadedTrackRow

private struct DownloadedTrackRow: View {
    let record: DownloadRecord
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    AsyncArtworkView(url: record.track.artworkURL, cornerRadius: 12)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Text(record.track.artist)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.cyan.opacity(0.8))
                            Text(sizeLabel)
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.4))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                onPlay()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private var sizeLabel: String {
        let mb = Double(record.fileSizeBytes) / 1_048_576
        if mb < 1 { return "< 1 MB" }
        return String(format: "%.1f MB", mb)
    }
}

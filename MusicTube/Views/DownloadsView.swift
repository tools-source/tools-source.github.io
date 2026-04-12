import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var downloadService = DownloadService.shared

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if downloadService.activeDownloads.isEmpty == false {
                        activeSection
                    }

                    if downloadService.downloads.isEmpty && downloadService.activeDownloads.isEmpty {
                        emptyState
                    } else if downloadService.downloads.isEmpty == false {
                        downloadedSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, appState.nowPlaying == nil ? 108 : 174)
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.large)
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                if downloadService.downloads.isEmpty == false {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Text(String(format: "%.1f MB", downloadService.totalDownloadedMB))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(Color.white.opacity(0.08))
                            )
                    }
                }
            }
        }
    }

    // MARK: - Active Downloads

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Downloading")
            VStack(spacing: 0) {
                ForEach(Array(downloadService.activeDownloads.values)) { active in
                    ActiveRow(active: active) {
                        downloadService.cancelDownload(for: active.track)
                    }
                }
            }
            .background(rowBackground)
        }
    }

    // MARK: - Downloaded Tracks

    private var downloadedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Downloaded")
            VStack(spacing: 0) {
                ForEach(Array(downloadService.downloads.reversed().enumerated()), id: \.element.id) { index, record in
                    CompactDownloadRow(record: record) {
                        let allDownloaded = downloadService.downloads.reversed().map(\.localTrack)
                        appState.play(track: record.localTrack, queue: allDownloaded)
                    } onDelete: {
                        withAnimation(.spring(response: 0.3)) {
                            downloadService.deleteDownload(record)
                        }
                    }
                    if index < downloadService.downloads.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.07))
                            .padding(.leading, 58)
                    }
                }
            }
            .background(rowBackground)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.white.opacity(0.25))

            VStack(spacing: 6) {
                Text("No Downloads Yet")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Tap ··· on any song to save it offline.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 4)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(white: 0.1, opacity: 1))
    }
}

// MARK: - Active Download Row

private struct ActiveRow: View {
    let active: ActiveDownload
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: active.track.artworkURL, cornerRadius: 8)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                Text(active.track.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                DownloadProgressBar(progress: active.progress)
                    .frame(height: 3)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - DownloadProgressBar

struct DownloadProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(Color(red: 1, green: 0.23, blue: 0.42))
                    .frame(width: max(geo.size.width * progress, progress > 0 ? 6 : 0))
            }
        }
    }
}

// MARK: - Compact Downloaded Row

private struct CompactDownloadRow: View {
    let record: DownloadRecord
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Artwork — tap to play
            Button(action: onPlay) {
                AsyncArtworkView(url: record.track.artworkURL, cornerRadius: 8)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)

            // Title + artist
            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.track.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(record.track.artist)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            // Size badge
            Text(sizeLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.35))

            // Delete
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var sizeLabel: String {
        let mb = Double(record.fileSizeBytes) / 1_048_576
        if mb < 1 { return "< 1 MB" }
        return String(format: "%.1f MB", mb)
    }
}

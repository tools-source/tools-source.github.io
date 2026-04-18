import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var downloadService = DownloadService.shared
    @State private var selectedFolderID: String?
    @State private var isShowingCreateFolderPrompt = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if downloadService.folders.isEmpty == false || downloadService.downloads.isEmpty == false {
                        foldersSection
                    }

                    if downloadService.activeDownloads.isEmpty == false {
                        activeSection
                    }

                    if filteredDownloads.isEmpty, downloadService.activeDownloads.isEmpty {
                        emptyState
                    } else if filteredDownloads.isEmpty {
                        emptyFolderState
                    } else {
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if downloadService.downloads.isEmpty == false {
                        Text(String(format: "%.1f MB", downloadService.totalDownloadedMB))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }

                    Button {
                        isShowingCreateFolderPrompt = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.white)
                    }
                }
            }
            .alert("Create Folder", isPresented: $isShowingCreateFolderPrompt) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    downloadService.createFolder(named: newFolderName)
                    newFolderName = ""
                }
                Button("Cancel", role: .cancel) {
                    newFolderName = ""
                }
            } message: {
                Text("Organize downloaded songs into folders.")
            }
        }
    }

    private var filteredDownloads: [DownloadRecord] {
        if let selectedFolderID {
            return Array(downloadService.downloads(in: selectedFolderID).reversed())
        }
        return Array(downloadService.downloads.reversed())
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Folders")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    folderChip(title: "All", isSelected: selectedFolderID == nil) {
                        selectedFolderID = nil
                    }

                    ForEach(downloadService.folders) { folder in
                        folderChip(
                            title: folder.name,
                            isSelected: selectedFolderID == folder.id
                        ) {
                            selectedFolderID = folder.id
                        }
                    }
                }
            }
        }
    }

    private func folderChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.white : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }

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

    private var downloadedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(selectedFolderID == nil ? "Downloaded" : "Folder")
            VStack(spacing: 0) {
                ForEach(Array(filteredDownloads.enumerated()), id: \.element.id) { index, record in
                    CompactDownloadRow(record: record) {
                        let allDownloaded = filteredDownloads.map(\.localTrack)
                        appState.play(track: record.localTrack, queue: allDownloaded)
                    } onDelete: {
                        withAnimation(.spring(response: 0.3)) {
                            downloadService.deleteDownload(record)
                        }
                    }
                    if index < filteredDownloads.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.07))
                            .padding(.leading, 58)
                    }
                }
            }
            .background(rowBackground)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.white.opacity(0.25))

            VStack(spacing: 6) {
                Text("No Downloads Yet")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Download songs anywhere in the app, then organize them into folders here.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyFolderState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.white.opacity(0.3))
            Text("This folder is empty.")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Move downloads here from the menu on any track.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

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

private struct CompactDownloadRow: View {
    @StateObject private var downloadService = DownloadService.shared
    let record: DownloadRecord
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                AsyncArtworkView(url: record.track.artworkURL, cornerRadius: 8)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)

            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.track.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(record.track.artist)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.5))
                            .lineLimit(1)

                        if let folder = downloadService.folder(for: record) {
                            Text("· \(folder.name)")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.32))
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            TrackActionsButton(track: record.localTrack, size: 32)

            DownloadFolderMenu(record: record)

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
}

private struct DownloadFolderMenu: View {
    @StateObject private var downloadService = DownloadService.shared
    let record: DownloadRecord

    var body: some View {
        Menu {
            Button {
                downloadService.moveDownload(record, to: nil)
            } label: {
                Label("No Folder", systemImage: record.folderID == nil ? "checkmark" : "folder.badge.minus")
            }

            ForEach(downloadService.folders) { folder in
                Button {
                    downloadService.moveDownload(record, to: folder.id)
                } label: {
                    Label(folder.name, systemImage: record.folderID == folder.id ? "checkmark" : "folder")
                }
            }
        } label: {
            Image(systemName: "folder")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }
}

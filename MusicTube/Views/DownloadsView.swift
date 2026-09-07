import SwiftUI

struct DownloadsView: View {
    @ObservedObject var viewModel: DownloadViewModel
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var folderToRename: DownloadFolder?
    @State private var renamedFolderName = ""
    @State private var folderToDelete: DownloadFolder?
    @State private var isSelecting = false
    @State private var selectedRecordIDs: Set<String> = []
    @State private var isShowingMoveSheet = false
    @State private var isConfirmingDelete = false

    private var snapshot: DownloadSnapshot { viewModel.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                    summary
                    folderFilters
                    downloadingSection
                    downloadedSection
                    needsAttentionSection
                }
                .padding(.horizontal, AppLayout.horizontalMargin)
                .padding(.top, AppSpacing.small)
                .padding(.bottom, snapshot.nowPlayingKey == nil ? 108 : 174)
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionBar }
            }
            .task { viewModel.appear() }
            .premiumScreenBackground()
            .alert("Create Folder", isPresented: $isCreatingFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create", action: createFolder)
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
            .alert("Rename Folder", isPresented: renameBinding) {
                TextField("Folder name", text: $renamedFolderName)
                Button("Save", action: renameFolder)
                Button("Cancel", role: .cancel) { folderToRename = nil }
            }
            .alert("Delete Folder?", isPresented: deleteFolderBinding) {
                Button("Delete", role: .destructive, action: deleteFolder)
                Button("Cancel", role: .cancel) { folderToDelete = nil }
            } message: {
                Text("Songs in this folder will be removed from this iPhone.")
            }
            .confirmationDialog(
                "Move selected downloads to…",
                isPresented: $isShowingMoveSheet,
                titleVisibility: .visible
            ) {
                Button("No Folder") { moveSelected(to: nil) }
                ForEach(snapshot.folders) { folder in
                    Button(folder.name) { moveSelected(to: folder.id) }
                }
            }
            .alert("Delete selected downloads?", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive, action: deleteSelected)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The selected songs will be removed from this iPhone.")
            }
        }
    }

    private var summary: some View {
        VStack(spacing: 14) {
            HStack(spacing: AppSpacing.medium) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)

                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                    Text("\(snapshot.downloaded.count) downloaded")
                        .font(.headline)
                    Text(ByteCountFormatter.string(fromByteCount: snapshot.totalDownloadedBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
            }

            if snapshot.downloaded.isEmpty == false {
                HStack(spacing: 10) {
                    Button(action: viewModel.playAll) {
                        Label("Play all", systemImage: "play.fill")
                    }
                    .buttonStyle(AppPrimaryActionButtonStyle())

                    Button(action: viewModel.shuffleAll) {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(AppSecondaryActionButtonStyle())
                }
            }
        }
        .padding(AppSpacing.medium)
        .appSurface()
    }

    @ViewBuilder
    private var folderFilters: some View {
        if snapshot.folders.isEmpty == false {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.small) {
                    folderChip(title: "All", id: nil)
                    ForEach(snapshot.folders) { folder in
                        folderChip(title: folder.name, id: folder.id)
                            .contextMenu {
                                Button("Rename") { beginRenaming(folder) }
                                Button("Delete", role: .destructive) { folderToDelete = folder }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var downloadingSection: some View {
        if snapshot.downloading.isEmpty == false {
            DownloadSection(title: "Downloading") {
                ForEach(snapshot.downloading) { download in
                    ActiveDownloadRow(
                        download: download,
                        onPauseResume: { viewModel.pauseOrResume(download) },
                        onCancel: { viewModel.cancel(download) }
                    )

                    if download.id != snapshot.downloading.last?.id {
                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 68)
                    }
                }
            }
        }
    }

    private var downloadedSection: some View {
        DownloadSection(title: "Downloaded") {
            if snapshot.downloaded.isEmpty {
                DownloadEmptyState()
            } else {
                ForEach(snapshot.downloaded) { record in
                    DownloadedTrackRow(
                        record: record,
                        isCurrent: snapshot.nowPlayingKey == record.track.playbackKey,
                        isPlaying: snapshot.isPlaying,
                        isSelecting: isSelecting,
                        isSelected: selectedRecordIDs.contains(record.id),
                        folders: snapshot.folders,
                        onTap: { handleTap(record) },
                        onMove: { viewModel.move(record, to: $0) },
                        onDelete: { viewModel.delete(record) }
                    )

                    if record.id != snapshot.downloaded.last?.id {
                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 68)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var needsAttentionSection: some View {
        if let message = snapshot.needsAttentionMessage {
            DownloadSection(title: "Needs Attention") {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(.vertical, AppSpacing.small)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if snapshot.downloaded.isEmpty == false {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if isSelecting == false { selectedRecordIDs.removeAll() }
                }
            }
            Button {
                isCreatingFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel("Create download folder")
        }
    }

    private var selectionBar: some View {
        HStack {
            Button("Move") { isShowingMoveSheet = true }
                .disabled(selectedRecordIDs.isEmpty)
            Spacer()
            Text("\(selectedRecordIDs.count) selected")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
            Button("Delete", role: .destructive) { isConfirmingDelete = true }
                .disabled(selectedRecordIDs.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func folderChip(title: String, id: String?) -> some View {
        Button {
            viewModel.selectFolder(id)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(snapshot.selectedFolderID == id ? AppTheme.inverseText : AppTheme.primaryText)
                .background(
                    Capsule().fill(snapshot.selectedFolderID == id ? AppTheme.inverseFill : AppTheme.controlFill)
                )
        }
        .buttonStyle(.plain)
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { folderToRename != nil }, set: { if $0 == false { folderToRename = nil } })
    }

    private var deleteFolderBinding: Binding<Bool> {
        Binding(get: { folderToDelete != nil }, set: { if $0 == false { folderToDelete = nil } })
    }

    private func createFolder() {
        viewModel.createFolder(named: newFolderName)
        newFolderName = ""
    }

    private func beginRenaming(_ folder: DownloadFolder) {
        folderToRename = folder
        renamedFolderName = folder.name
    }

    private func renameFolder() {
        guard let folderToRename else { return }
        viewModel.renameFolder(folderToRename, to: renamedFolderName)
        self.folderToRename = nil
        renamedFolderName = ""
    }

    private func deleteFolder() {
        guard let folderToDelete else { return }
        viewModel.deleteFolder(folderToDelete)
        self.folderToDelete = nil
    }

    private func handleTap(_ record: DownloadRecord) {
        if isSelecting {
            if selectedRecordIDs.contains(record.id) {
                selectedRecordIDs.remove(record.id)
            } else {
                selectedRecordIDs.insert(record.id)
            }
        } else if snapshot.nowPlayingKey == record.track.playbackKey {
            viewModel.togglePlayback()
        } else {
            viewModel.play(record)
        }
    }

    private func moveSelected(to folderID: String?) {
        viewModel.move(recordIDs: selectedRecordIDs, to: folderID)
        finishSelection()
    }

    private func deleteSelected() {
        viewModel.delete(recordIDs: selectedRecordIDs)
        finishSelection()
    }

    private func finishSelection() {
        selectedRecordIDs.removeAll()
        isSelecting = false
    }
}

private struct DownloadSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(title).font(.title3.bold())
            VStack(spacing: 0) { content }
        }
    }
}

private struct ActiveDownloadRow: View {
    let download: DownloadProgressPresentation
    let onPauseResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            AsyncArtworkView(url: download.track.artworkURL, maxPixelSize: ArtworkTargetSize.compactRow)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(download.track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                ProgressView(value: download.progress)
                    .tint(AppTheme.accent)
                Text(download.isPaused ? "Paused" : "\(Int(download.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Button(action: onPauseResume) {
                Image(systemName: download.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive, action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, AppSpacing.small)
    }
}

private struct DownloadedTrackRow: View {
    let record: DownloadRecord
    let isCurrent: Bool
    let isPlaying: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let folders: [DownloadFolder]
    let onTap: () -> Void
    let onMove: (String?) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.secondaryText)
            }
            Button(action: onTap) {
                HStack(spacing: AppSpacing.medium) {
                    AsyncArtworkView(url: record.track.artworkURL, maxPixelSize: ArtworkTargetSize.compactRow)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCurrent ? AppTheme.accent : AppTheme.primaryText)
                            .lineLimit(1)
                        Text(record.track.artist)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isCurrent {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
            .buttonStyle(.plain)

            if isSelecting == false {
                Menu {
                    Button("No Folder") { onMove(nil) }
                    ForEach(folders) { folder in
                        Button(folder.name) { onMove(folder.id) }
                    }
                    Button("Delete Download", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 36)
                }
            }
        }
        .padding(.vertical, AppSpacing.small)
    }
}

private struct DownloadEmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No Downloads",
            systemImage: "arrow.down.circle",
            description: Text("Downloaded songs will be ready here for offline playback.")
        )
        .padding(.vertical, AppSpacing.large)
    }
}

import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isShowingDeleteDataConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    accountSection
                    quickActionsSection
                    likedSongsSection
                    savedSongsSection
                    customPlaylistsSection
                    savedCollectionsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomSpacing)
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .navigationDestination(for: MusicCollection.self) { collection in
                CollectionDetailView(collection: collection)
            }
            .refreshable {
                await appState.refreshLibrary()
            }
            .task {
                if appState.hasLoadedLibrary == false, appState.isLoadingPlaylists == false {
                    await appState.refreshLibrary()
                }
            }
            .background(libraryBackground.ignoresSafeArea())
            .confirmationDialog(
                "Delete MusicTube data from this iPhone?",
                isPresented: $isShowingDeleteDataConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete MusicTube Data", role: .destructive) {
                    Task {
                        await appState.deleteCurrentAccountData()
                    }
                }
            } message: {
                Text("This removes MusicTube’s local library, playlists, downloads, likes, and listening history from this iPhone. It does not delete your Google or YouTube account.")
            }
        }
    }

    private var bottomSpacing: CGFloat {
        appState.nowPlaying == nil ? 108 : 174
    }

    private var libraryBackground: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.03, green: 0.03, blue: 0.05)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var accountSection: some View {
        librarySection(appState.isYouTubeConnected ? "Account" : "Guest Mode") {
            VStack(alignment: .leading, spacing: 16) {
                if let user = appState.user {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(user.name)
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(user.email)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your library is local and ready to use.")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text("Connect YouTube anytime to import your account library while keeping your MusicTube guest library and playlists on this device.")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                if let libraryStatusMessage = appState.libraryStatusMessage {
                    Text(libraryStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if appState.isYouTubeConnected {
                    Button("Disconnect YouTube", role: .destructive) {
                        Task {
                            await appState.signOut()
                        }
                    }
                    .font(.headline)
                } else {
                    Button {
                        Task {
                            await appState.signIn()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text("Connect YouTube")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 1, green: 0.23, blue: 0.42))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isLoading)
                }

                Button("Delete MusicTube Data", role: .destructive) {
                    isShowingDeleteDataConfirmation = true
                }
                .font(.headline)
                .disabled(appState.isDeletingAccountData)

                if appState.isDeletingAccountData {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Deleting local MusicTube data...")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                }
            }
        }
    }

    private var quickActionsSection: some View {
        librarySection("Quick Actions") {
            Button {
                appState.presentPlaylistCreator()
            } label: {
                HStack {
                    Image(systemName: "music.note.list")
                    Text("Create Playlist")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var likedSongsSection: some View {
        librarySection("Liked Songs") {
            if appState.isLoadingPlaylists && appState.playlists.isEmpty {
                loadingLabel("Syncing liked songs...")
            } else if let likedSongs = appState.likedSongsPlaylist {
                VStack(alignment: .leading, spacing: 10) {
                    NavigationLink(value: likedSongs) {
                        PlaylistRow(playlist: likedSongs)
                    }
                    .buttonStyle(.plain)

                    if appState.isSyncingLikedSongs {
                        loadingLabel("Importing the rest of your YouTube liked songs...")
                    }
                }
            } else {
                Text("Tap the heart on a song to keep it here.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.65))
            }
        }
    }

    private var savedSongsSection: some View {
        librarySection("Saved Songs") {
            if let savedSongs = appState.savedSongsPlaylist {
                NavigationLink(value: savedSongs) {
                    PlaylistRow(playlist: savedSongs)
                }
                .buttonStyle(.plain)
            } else {
                Text("Save any song from Search, Home, Downloads, or the Player and it’ll show up here.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.65))
            }
        }
    }

    private var customPlaylistsSection: some View {
        librarySection("Your Playlists") {
            if appState.customPlaylists.isEmpty {
                Text("Create playlists and add tracks from anywhere in the app.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.65))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appState.customPlaylists.enumerated()), id: \.element.id) { index, playlist in
                        NavigationLink(value: playlist) {
                            PlaylistRow(playlist: playlist) {
                                appState.downloadPlaylist(playlist)
                            }
                        }
                        .buttonStyle(.plain)

                        if index < appState.customPlaylists.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.07))
                                .padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    private var savedCollectionsSection: some View {
        librarySection("Saved Collections") {
            if appState.savedCollections.isEmpty {
                Text("Save playlists, albums, and artists from Search for quick access later.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.65))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appState.savedCollections.enumerated()), id: \.element.id) { index, collection in
                        NavigationLink(value: collection) {
                            SavedCollectionRow(collection: collection)
                        }
                        .buttonStyle(.plain)

                        if index < appState.savedCollections.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.07))
                                .padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    private func librarySection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
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

    private func loadingLabel(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(text)
                .foregroundStyle(Color.white.opacity(0.72))
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    var onDownload: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(itemCountLabel)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            Spacer(minLength: 10)

            if let onDownload {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.35))
        }
        .padding(.vertical, 8)
    }

    private var itemCountLabel: String {
        switch playlist.kind {
        case .likedMusic:
            return playlist.itemCount == 1 ? "1 song" : "\(playlist.itemCount) songs"
        case .uploads:
            return playlist.itemCount == 1 ? "1 upload" : "\(playlist.itemCount) uploads"
        case .savedSongs:
            return playlist.itemCount == 1 ? "1 saved song" : "\(playlist.itemCount) saved songs"
        case .custom:
            return playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks"
        case .standard:
            return playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks"
        }
    }
}

private struct SavedCollectionRow: View {
    let collection: MusicCollection

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: collection.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(collection.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.35))
        }
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        var parts: [String] = []
        switch collection.kind {
        case .playlist: parts.append("Playlist")
        case .album: parts.append("Album")
        case .artist: parts.append("Artist")
        }
        if collection.subtitle.isEmpty == false {
            parts.append(collection.subtitle)
        }
        if collection.itemCount > 0 {
            parts.append(collection.itemCount == 1 ? "1 track" : "\(collection.itemCount) tracks")
        }
        return parts.joined(separator: " · ")
    }
}

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let playlist: Playlist

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var isEditSheetPresented = false
    @State private var editedPlaylistName = ""

    private var currentPlaylist: Playlist {
        appState.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if isLoading {
                    loadingCard("Loading playlist tracks...")
                } else if tracks.isEmpty {
                    emptyCard("This playlist is empty for now.")
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        if playlist.kind == .custom {
                            editableTrackRow(track)
                        } else {
                            TrackRowView(
                                track: track,
                                showsNowPlayingIndicator: true,
                                showsDownloadButton: true,
                                prefetchPlaybackOnAppear: false
                            ) {
                                appState.play(track: track, queue: tracks)
                            }
                        }

                        if index < tracks.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.07))
                                .padding(.leading, 64)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, appState.nowPlaying == nil ? 108 : 174)
        }
        .background(detailBackground)
        .navigationTitle(currentPlaylist.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    appState.downloadPlaylist(currentPlaylist)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.white)
                }

                if playlist.kind == .custom {
                    Menu {
                        Button {
                            editedPlaylistName = currentPlaylist.title
                            isEditSheetPresented = true
                        } label: {
                            Label("Edit Playlist", systemImage: "pencil")
                        }

                        Button {
                            appState.presentPlaylistSongAdder(for: currentPlaylist)
                        } label: {
                            Label("Add Songs", systemImage: "plus.circle")
                        }

                        Button(role: .destructive) {
                            appState.deleteCustomPlaylist(currentPlaylist)
                            dismiss()
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
                    }
                }
            }
        }
        .sheet(isPresented: $isEditSheetPresented) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Playlist name")
                        .font(.headline)
                        .foregroundStyle(.white)

                    TextField("Playlist name", text: $editedPlaylistName)
                        .textInputAutocapitalization(.words)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .foregroundStyle(.white)

                    Spacer()
                }
                .padding(20)
                .background(Color.black.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isEditSheetPresented = false
                        }
                        .foregroundStyle(.white.opacity(0.8))
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if appState.renameCustomPlaylist(currentPlaylist, to: editedPlaylistName) {
                                isEditSheetPresented = false
                            }
                        }
                        .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
                        .disabled(editedPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
        .task {
            await loadInitialTracks()
        }
        .onChange(of: appState.isSyncingLikedSongs) { _, isSyncing in
            guard playlist.kind == .likedMusic, isSyncing == false else { return }
            Task {
                tracks = await appState.loadPlaylistItems(
                    for: playlist,
                    forceRefresh: false,
                    surfaceErrors: false
                )
                prefetchVisibleTracks(from: tracks)
            }
        }
        .refreshable {
            tracks = await appState.loadPlaylistItems(for: playlist, forceRefresh: true)
            isLoading = false
            prefetchVisibleTracks(from: tracks)
        }
    }

    private var detailBackground: some View {
        LinearGradient(
            colors: [Color.black, Color(red: 0.03, green: 0.03, blue: 0.05)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func loadingCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(text)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Color.white.opacity(0.72))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
    }

    private func editableTrackRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Button {
                appState.play(track: track, queue: tracks)
            } label: {
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
                            if appState.nowPlaying?.playbackKey == track.playbackKey, appState.isPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))
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

                    Spacer(minLength: 8)
                }
            }
            .buttonStyle(.plain)

            DownloadButton(track: track, size: 36)

            Button {
                appState.removeTrack(track, from: playlist)
                tracks.removeAll { $0.playbackKey == track.playbackKey }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.red.opacity(0.92))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.red.opacity(0.14)))
            }
            .buttonStyle(.plain)

            Button {
                if appState.nowPlaying?.playbackKey == track.playbackKey, appState.isPlaying {
                    appState.togglePlayback()
                } else {
                    appState.play(track: track, queue: tracks)
                }
            } label: {
                Image(systemName: appState.nowPlaying?.playbackKey == track.playbackKey && appState.isPlaying ? "pause.fill" : "play.fill")
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
    }

    private func loadInitialTracks() async {
        guard tracks.isEmpty else { return }

        let initialTracks = await appState.loadPlaylistItems(for: playlist, forceRefresh: false)
        tracks = initialTracks
        isLoading = false
        prefetchVisibleTracks(from: initialTracks)

        guard playlist.kind == .likedMusic else { return }
        guard appState.isSyncingLikedSongs == false else { return }

        let refreshedTracks = await appState.loadPlaylistItems(
            for: playlist,
            forceRefresh: true,
            surfaceErrors: false
        )
        guard refreshedTracks != initialTracks else { return }
        tracks = refreshedTracks
        prefetchVisibleTracks(from: refreshedTracks)
    }

    private func prefetchVisibleTracks(from tracks: [Track]) {
        let warmTracks = Array(tracks.prefix(3))
        guard warmTracks.isEmpty == false else { return }
        appState.prefetchPlayback(for: warmTracks)
    }
}

struct CollectionDetailView: View {
    @EnvironmentObject private var appState: AppState
    let collection: MusicCollection

    @State private var tracks: [Track] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 14) {
                headerCard

                if isLoading {
                    loadingCard("Loading \(collectionTitleLowercased) tracks...")
                } else if tracks.isEmpty {
                    loadingCard("No playable songs were found for this \(collectionTitleLowercased).")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRowView(
                                track: track,
                                showsNowPlayingIndicator: true,
                                showsDownloadButton: true,
                                prefetchPlaybackOnAppear: false
                            ) {
                                appState.play(track: track, queue: tracks)
                            }

                            if index < tracks.count - 1 {
                                Divider()
                                    .overlay(Color.white.opacity(0.07))
                                    .padding(.leading, 64)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, appState.nowPlaying == nil ? 108 : 174)
        }
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.03, green: 0.03, blue: 0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle(collection.title)
        .task {
            guard tracks.isEmpty else { return }
            tracks = await appState.loadCollectionItems(for: collection)
            isLoading = false
            prefetchVisibleTracks(from: tracks)
        }
        .refreshable {
            tracks = await appState.loadCollectionItems(for: collection, forceRefresh: true)
            isLoading = false
            prefetchVisibleTracks(from: tracks)
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            AsyncArtworkView(url: collection.artworkURL, cornerRadius: 18)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text(collectionKindLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.58))

                Text(collection.title)
                    .font(.headline)
                    .foregroundStyle(.white)

                if collection.subtitle.isEmpty == false {
                    Text(collection.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(2)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    appState.downloadCollection(collection)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    appState.toggleCollectionSaved(collection)
                } label: {
                    Image(systemName: appState.isCollectionSaved(collection) ? "bookmark.fill" : "bookmark")
                        .font(.headline)
                        .foregroundStyle(appState.isCollectionSaved(collection) ? Color(red: 1, green: 0.23, blue: 0.42) : Color.white.opacity(0.65))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var collectionKindLabel: String {
        switch collection.kind {
        case .playlist: return "Playlist"
        case .album: return "Album"
        case .artist: return "Artist"
        }
    }

    private var collectionTitleLowercased: String {
        collectionKindLabel.lowercased()
    }

    private func loadingCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(text)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func prefetchVisibleTracks(from tracks: [Track]) {
        let warmTracks = Array(tracks.prefix(3))
        guard warmTracks.isEmpty == false else { return }
        appState.prefetchPlayback(for: warmTracks)
    }
}

import SwiftUI

// MARK: - HomeFilter

enum HomeFilter: String, CaseIterable {
    case all = "All"
    case arabic = "Arabic"
    case worship = "Worship"
    case playlists = "Playlists"
    case recent = "Recent"
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedFilter: HomeFilter = .all
    @State private var seeAllTitle: String = ""
    @State private var seeAllTracks: [Track] = []
    @State private var showSeeAll = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    greetingHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 16)

                    filterChips
                        .padding(.bottom, 24)

                    if selectedFilter == .all || selectedFilter == .recent {
                        continueListeningSection
                            .padding(.bottom, 28)
                    }

                    if selectedFilter == .all || selectedFilter == .arabic || selectedFilter == .worship || selectedFilter == .recent {
                        recommendedSection
                            .padding(.bottom, 28)
                    }

                    if selectedFilter == .all || selectedFilter == .playlists {
                        mixesSection
                            .padding(.bottom, 28)
                    }
                }
                .padding(.bottom, appState.nowPlaying == nil ? 100 : 180)
            }
            .navigationBarHidden(true)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .refreshable {
                await appState.refreshDashboard()
            }
            .task {
                if !appState.hasLoadedHome, !appState.isLoading, !appState.isLoadingPlaylists {
                    await appState.refreshDashboard()
                }
            }
            .background(Color.black.ignoresSafeArea())
            .sheet(isPresented: $showSeeAll) {
                TrackListSheet(title: seeAllTitle, tracks: seeAllTracks)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: Greeting Header

    private var greetingHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text(greeting)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                if let name = appState.user?.name.components(separatedBy: " ").first {
                    Text(name)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            // Avatar
            if let user = appState.user {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.85, green: 0.22, blue: 0.22))
                        .frame(width: 42, height: 42)
                    Text(initials(from: user.name))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning,"
        case 12..<17: return "Good afternoon,"
        case 17..<21: return "Good evening,"
        default:      return "Good night,"
        }
    }

    private func initials(from name: String) -> String {
        let parts = name.components(separatedBy: " ").filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    // MARK: Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeFilter.allCases, id: \.self) { filter in
                    FilterChip(
                        title: filter.rawValue,
                        isSelected: selectedFilter == filter
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            selectedFilter = filter
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
    }

    // MARK: Continue Listening

    @ViewBuilder
    private var continueListeningSection: some View {
        let tracks = filteredContinueListening
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Continue Listening", showSeeAll: !tracks.isEmpty) {
                seeAllTitle = "Continue Listening"
                seeAllTracks = tracks
                showSeeAll = true
            }
            .padding(.horizontal, 20)

            if !appState.hasLoadedHome || (appState.isLoading && tracks.isEmpty) {
                skeletonContinueListening
            } else if tracks.isEmpty {
                emptyStateCard("No recent tracks yet. Search and play something!")
                    .padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(tracks.prefix(8).enumerated()), id: \.element.id) { index, track in
                            ContinueListeningCard(track: track, isNew: index == 0) {
                                appState.play(track: track, queue: Array(tracks))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: Recommended

    @ViewBuilder
    private var recommendedSection: some View {
        let tracks = filteredRecommended
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Recommended for you", showSeeAll: !tracks.isEmpty) {
                seeAllTitle = "Recommended for you"
                seeAllTracks = tracks
                showSeeAll = true
            }
            .padding(.horizontal, 20)

            if !appState.hasLoadedHome || (appState.isLoading && tracks.isEmpty) {
                skeletonList
                    .padding(.horizontal, 20)
            } else if tracks.isEmpty {
                emptyStateCard("Your recommendations will appear here.")
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tracks.prefix(10).enumerated()), id: \.element.id) { index, track in
                        RecommendedRow(track: track) {
                            appState.play(track: track, queue: Array(tracks))
                        }
                        if index < min(tracks.count, 10) - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.06))
                                .padding(.leading, 76)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: Mixes

    @ViewBuilder
    private var mixesSection: some View {
        if !appState.suggestedMixes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "Suggested Mixes", showSeeAll: false) {}
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(appState.suggestedMixes) { playlist in
                            NavigationLink(value: playlist) {
                                MixCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: Filtered data

    private var filteredContinueListening: [Track] {
        let base = appState.recentTracks.isEmpty ? appState.featuredTracks : appState.recentTracks
        switch selectedFilter {
        case .all, .recent: return Array(base)
        case .arabic: return base.filter { isArabic($0) }
        case .worship: return base.filter { isWorship($0) }
        case .playlists: return []
        }
    }

    private var filteredRecommended: [Track] {
        let base = appState.featuredTracks
        switch selectedFilter {
        case .all: return base
        case .arabic: return base.filter { isArabic($0) }
        case .worship: return base.filter { isWorship($0) }
        case .recent: return Array((appState.recentTracks + base).prefix(20))
        case .playlists: return []
        }
    }

    private func isArabic(_ track: Track) -> Bool {
        let text = "\(track.title) \(track.artist)"
        return text.unicodeScalars.contains { scalar in
            (0x0600...0x06FF).contains(scalar.value) || (0x0750...0x077F).contains(scalar.value)
        }
    }

    private func isWorship(_ track: Track) -> Bool {
        let text = "\(track.title) \(track.artist)".lowercased()
        let keywords = ["worship", "praise", "jesus", "god", "holy", "awakening", "hillsong", "bethel", "elevation"]
        return keywords.contains { text.contains($0) }
    }

    // MARK: Shared helpers

    private func sectionHeader(title: String, showSeeAll: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
            Spacer()
            if showSeeAll {
                Button("See all", action: action)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
            }
        }
    }

    private func emptyStateCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
    }

    // MARK: Skeletons

    private var skeletonContinueListening: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 160, height: 200)
                        .shimmering()
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var skeletonList: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 52, height: 52)
                        .shimmering()
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 12)
                            .shimmering()
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 100, height: 10)
                            .shimmering()
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.white : Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ContinueListeningCard

private struct ContinueListeningCard: View {
    @EnvironmentObject private var appState: AppState

    let track: Track
    let isNew: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        AsyncArtworkView(url: track.artworkURL, cornerRadius: 14)
                            .frame(width: 160, height: 160)

                        if isNew {
                            Text("NEW")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color(red: 1, green: 0.23, blue: 0.42))
                                )
                                .padding(8)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 3) {
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)

                            if let duration = track.formattedDuration {
                                Text("· \(duration)")
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.42))
                                    .fixedSize()
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 6)
                }
                .frame(width: 160, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                if isCurrentlyPlaying {
                    Label("Playing", systemImage: "speaker.wave.2.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                HomeTrackButtons(track: track, onPlay: onTap, buttonSize: 30)
            }
            .padding(.top, 8)
            .padding(.horizontal, 6)
        }
    }

    private var isCurrentlyPlaying: Bool {
        appState.nowPlaying?.playbackKey == track.playbackKey && appState.isPlaying
    }
}

// MARK: - RecommendedRow

private struct RecommendedRow: View {
    @EnvironmentObject private var appState: AppState

    let track: Track
    let onTap: () -> Void

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

                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)

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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HomeTrackButtons(track: track, onPlay: onTap)
        }
        .padding(.vertical, 8)
    }

    private var isCurrentlyPlaying: Bool {
        appState.nowPlaying?.playbackKey == track.playbackKey && appState.isPlaying
    }
}

// MARK: - MixCard

private struct MixCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 14)
                .frame(width: 148, height: 148)

            Text(playlist.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(width: 148, alignment: .leading)
    }

    private var subtitleText: String {
        let count = playlist.itemCount
        switch playlist.kind {
        case .likedMusic: return count == 1 ? "1 song" : "\(count) songs"
        case .uploads:    return count == 1 ? "1 upload" : "\(count) uploads"
        case .standard:   return count == 1 ? "1 track" : "\(count) tracks"
        }
    }
}

// MARK: - TrackListSheet

struct TrackListSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let title: String
    let tracks: [Track]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 12) {
                            Button {
                                appState.play(track: track, queue: tracks)
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Color.white.opacity(0.3))
                                        .frame(width: 20, alignment: .trailing)

                                    AsyncArtworkView(url: track.artworkURL, cornerRadius: 8)
                                        .frame(width: 44, height: 44)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)

                                        HStack(spacing: 4) {
                                            if appState.nowPlaying?.playbackKey == track.playbackKey && appState.isPlaying {
                                                Image(systemName: "speaker.wave.2.fill")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))

                                                Text("Playing")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))
                                            }

                                            Text(track.artist)
                                                .font(.caption)
                                                .foregroundStyle(Color.white.opacity(0.5))
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            HomeTrackButtons(
                                track: track,
                                onPlay: { appState.play(track: track, queue: tracks) },
                                buttonSize: 32
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)

                        if index < tracks.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.07))
                                .padding(.leading, 92)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Track+formattedDuration

private extension Track {
    var formattedDuration: String? { nil } // populated by playback; kept as hook
}

private struct HomeTrackButtons: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var downloadService = DownloadService.shared

    let track: Track
    let onPlay: () -> Void
    var buttonSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 8) {
            Button {
                appState.downloadTrack(track)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))

                    if downloadService.isDownloading(track) {
                        ProgressView()
                            .scaleEffect(0.75)
                            .tint(.white)
                    } else if downloadService.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.cyan)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: buttonSize, height: buttonSize)
            }
            .buttonStyle(.plain)
            .disabled(downloadService.isDownloading(track) || downloadService.isDownloaded(track))

            Button(action: handlePlaybackButtonTap) {
                Image(systemName: isCurrentTrack && appState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(
                        Circle()
                            .fill(Color(red: 1, green: 0.24, blue: 0.43))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var isCurrentTrack: Bool {
        appState.nowPlaying?.playbackKey == track.playbackKey
    }

    private func handlePlaybackButtonTap() {
        if isCurrentTrack {
            appState.togglePlayback()
        } else {
            onPlay()
        }
    }
}

// MARK: - Shimmer

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.07), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: geo.size.width * (phase - 1))
                }
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

private extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

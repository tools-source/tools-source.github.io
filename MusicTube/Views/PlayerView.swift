import SwiftUI

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let track: Track

    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var showSleepTimerSheet = false
    @StateObject private var downloadService = DownloadService.shared

    var body: some View {
        ZStack {
            // Background fills edge-to-edge behind the status bar
            playerBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    header
                    artwork
                    titleArea
                    progressCard
                    transportCard
                    secondaryControls
                    utilityCard
                    if let youtubeURL = track.youtubeWatchURL {
                        youtubeLink(url: youtubeURL)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)   // safe area is now respected by ScrollView
                .padding(.bottom, 40)
            }
            // Let ScrollView respect top safe area so header stays below status bar
        }
        .onAppear { syncScrubber() }
        .onChange(of: track.id) { _, _ in syncScrubber() }
        .onChange(of: appState.playbackPosition) { _, _ in
            guard !isScrubbing else { return }
            syncScrubber()
        }
        .onChange(of: appState.playbackDuration) { _, _ in
            guard !isScrubbing else { return }
            syncScrubber()
        }
        .sheet(isPresented: $showSleepTimerSheet) {
            SleepTimerSheet()
                .environmentObject(appState)
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button {
                appState.dismissPlayer()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text("Now Playing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(white: 0.60))
                    .textCase(.uppercase)
                Text("MusicTube")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            Spacer()

            // Download button
            Button {
                if downloadService.isDownloaded(track) {
                    // Already downloaded — no-op or show confirmation
                } else {
                    appState.downloadTrack(track)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 40, height: 40)

                    if downloadService.isDownloading(track) {
                        let key = track.youtubeVideoID ?? track.id
                        let progress = downloadService.activeDownloads[key]?.progress ?? 0
                        CircularProgress(progress: progress)
                            .frame(width: 22, height: 22)
                    } else if downloadService.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Color.cyan)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.headline)
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(downloadService.isDownloading(track) || downloadService.isDownloaded(track))
        }
    }

    // MARK: Artwork

    private var artwork: some View {
        AsyncArtworkView(url: track.artworkURL, cornerRadius: 30)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .scaleEffect(appState.isPlaying ? 1.0 : 0.95)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: appState.isPlaying)
    }

    // MARK: Title

    private var titleArea: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(track.title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(track.artist)
                    .font(.body)
                    .foregroundStyle(Color(white: 0.70))
            }

            Spacer(minLength: 8)

            Button {
                appState.toggleLike(for: track)
            } label: {
                Image(systemName: appState.isTrackLiked(track) ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(appState.isTrackLiked(track) ? Color(red: 1, green: 0.23, blue: 0.42) : Color.white.opacity(0.6))
                    .animation(.spring(response: 0.3), value: appState.isTrackLiked(track))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Progress Card

    private var progressCard: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : appState.playbackPosition },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(appState.playbackDuration, 1),
                onEditingChanged: handleScrubbingChanged
            )
            .tint(.white)
            .disabled(appState.playbackDuration <= 0)

            HStack {
                Text(formatted(displayedPlaybackPosition))
                    .foregroundStyle(Color(white: 0.70))
                Spacer()
                if appState.isPreparingPlayback {
                    HStack(spacing: 6) {
                        ProgressView().tint(.white).scaleEffect(0.7)
                        Text("Loading audio…")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.65))
                    }
                }
                Spacer()
                Text(formatted(appState.playbackDuration))
                    .foregroundStyle(Color(white: 0.70))
            }
            .font(.caption.monospacedDigit())
        }
        .padding(20)
        .background(glassCard(cornerRadius: 26))
    }

    // MARK: Transport Card

    private var transportCard: some View {
        HStack(spacing: 24) {
            Button { appState.playPreviousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(appState.hasPreviousTrack ? .white : .white.opacity(0.3))
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!appState.hasPreviousTrack)

            // Play / Pause
            Button { appState.togglePlayback() } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 84, height: 84)
                    if appState.isPreparingPlayback {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: appState.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(.plain)

            Button { appState.playNextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(appState.hasNextTrack ? .white : .white.opacity(0.3))
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!appState.hasNextTrack)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(glassCard(cornerRadius: 30))
    }

    // MARK: Secondary Controls (Shuffle / Repeat / Sleep Timer)

    private var secondaryControls: some View {
        HStack(spacing: 0) {
            // Shuffle
            Spacer()
            Button { appState.toggleShuffle() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(appState.shuffleMode ? Color(red: 1, green: 0.23, blue: 0.42) : Color.white.opacity(0.55))
                    if appState.shuffleMode {
                        Circle()
                            .fill(Color(red: 1, green: 0.23, blue: 0.42))
                            .frame(width: 4, height: 4)
                    } else {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Repeat
            Button { appState.cycleRepeatMode() } label: {
                VStack(spacing: 4) {
                    Image(systemName: repeatIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(appState.repeatMode == .off ? Color.white.opacity(0.55) : Color(red: 1, green: 0.23, blue: 0.42))
                    if appState.repeatMode != .off {
                        Circle()
                            .fill(Color(red: 1, green: 0.23, blue: 0.42))
                            .frame(width: 4, height: 4)
                    } else {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Sleep Timer
            Button { showSleepTimerSheet = true } label: {
                VStack(spacing: 4) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(appState.sleepTimerEndDate != nil ? Color.cyan : Color.white.opacity(0.55))
                    if appState.sleepTimerEndDate != nil {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 4, height: 4)
                    } else {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(glassCard(cornerRadius: 22))
    }

    private var repeatIcon: String {
        switch appState.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    // MARK: Utility Card

    private var utilityCard: some View {
        VStack(spacing: 0) {
            if downloadService.isDownloaded(track) {
                infoRow(
                    icon: "arrow.down.circle.fill",
                    iconColor: .cyan,
                    title: "Saved for offline",
                    subtitle: "This track plays without an internet connection."
                )
                Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 48)
            }

            infoRow(
                icon: "waveform",
                iconColor: Color(red: 1, green: 0.23, blue: 0.42),
                title: "Background playback",
                subtitle: "Plays on the lock screen, home screen, and CarPlay."
            )
        }
        .padding(.vertical, 6)
        .background(glassCard(cornerRadius: 24))
    }

    private func infoRow(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func youtubeLink(url: URL) -> some View {
        Link(destination: url) {
            Label("Open in YouTube", systemImage: "arrow.up.right.square")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    // MARK: Background

    private var playerBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.07),
                    Color(red: 0.10, green: 0.02, blue: 0.10),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.pink.opacity(0.18))
                .frame(width: 320, height: 320)
                .blur(radius: 120)
                .offset(x: 140, y: -210)
            Circle()
                .fill(Color.blue.opacity(0.14))
                .frame(width: 280, height: 280)
                .blur(radius: 110)
                .offset(x: -150, y: 260)
        }
    }

    // MARK: Helpers

    private var displayedPlaybackPosition: TimeInterval {
        isScrubbing ? scrubPosition : appState.playbackPosition
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        isScrubbing = editing
        if !editing { appState.seek(to: scrubPosition) }
    }

    private func syncScrubber() {
        let current = min(appState.playbackPosition, appState.playbackDuration)
        scrubPosition = max(0, current)
    }

    private func formatted(_ interval: TimeInterval) -> String {
        Self.timeFormatter.string(from: interval) ?? "0:00"
    }

    private func glassCard(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.34))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
    }

    private static let timeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.minute, .second]
        f.zeroFormattingBehavior = [.pad]
        return f
    }()
}

// MARK: - CircularProgress

struct CircularProgress: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
    }
}

// MARK: - SleepTimerSheet

private struct SleepTimerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let options = [15, 30, 45, 60, 90]

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.cyan)
                Text("Sleep Timer")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                if let endDate = appState.sleepTimerEndDate {
                    Text("Stops at \(endDate, style: .time)")
                        .font(.subheadline)
                        .foregroundStyle(Color.cyan.opacity(0.8))
                }
            }
            .padding(.top, 8)

            VStack(spacing: 10) {
                ForEach(options, id: \.self) { minutes in
                    Button {
                        appState.setSleepTimer(minutes: minutes)
                        dismiss()
                    } label: {
                        HStack {
                            Text("\(minutes) minutes")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.3))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            if appState.sleepTimerEndDate != nil {
                Button("Cancel Timer") {
                    appState.cancelSleepTimer()
                    dismiss()
                }
                .foregroundStyle(Color.red.opacity(0.85))
                .font(.subheadline.weight(.semibold))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.07, green: 0.07, blue: 0.12).ignoresSafeArea())
    }
}

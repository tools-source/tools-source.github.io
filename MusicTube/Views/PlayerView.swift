import SwiftUI

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let track: Track

    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            playerBackground

            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {
                    header

                    artwork

                    VStack(spacing: 8) {
                        Text(track.title)
                            .font(.title.bold())
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text(track.artist)
                            .font(.title3)
                            .foregroundStyle(Color(white: 0.72))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal)

                    progressCard

                    transportCard

                    utilityCard

                    if let youtubeURL = track.youtubeWatchURL {
                        Link(destination: youtubeURL) {
                            Label("Open in YouTube", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            syncScrubber()
        }
        .onChange(of: track.id) { _, _ in
            syncScrubber()
        }
        .onChange(of: appState.playbackPosition) { _, _ in
            guard isScrubbing == false else { return }
            syncScrubber()
        }
        .onChange(of: appState.playbackDuration) { _, _ in
            guard isScrubbing == false else { return }
            syncScrubber()
        }
    }

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
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text("Now Playing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(white: 0.68))
                    .textCase(.uppercase)
                Text("MusicTube")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            Spacer()

            Color.clear
                .frame(width: 40, height: 40)
        }
    }

    private var artwork: some View {
        AsyncArtworkView(url: track.artworkURL, cornerRadius: 34)
            .frame(maxWidth: 340, maxHeight: 340)
            .shadow(color: .black.opacity(0.42), radius: 28, y: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }

    private var progressCard: some View {
        VStack(spacing: 14) {
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
                Text(Self.playbackTimeFormatter.string(from: displayedPlaybackPosition) ?? "0:00")
                    .foregroundStyle(Color(white: 0.75))

                Spacer()

                Text(Self.playbackTimeFormatter.string(from: appState.playbackDuration) ?? "0:00")
                    .foregroundStyle(Color(white: 0.75))
            }
            .font(.caption.monospacedDigit())

            if appState.isPreparingPlayback {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Preparing extracted YouTube audio for background playback...")
                        .font(.footnote)
                        .foregroundStyle(Color(white: 0.76))
                }
            }
        }
        .padding(22)
        .background(glassCardBackground(cornerRadius: 28))
    }

    private var transportCard: some View {
        HStack(spacing: 28) {
            Button {
                appState.playPreviousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(appState.hasPreviousTrack ? .white : .white.opacity(0.35))
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(appState.hasPreviousTrack == false)

            Button {
                appState.togglePlayback()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 88, height: 88)

                    if appState.isPreparingPlayback {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: appState.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                appState.playNextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(appState.hasNextTrack ? .white : .white.opacity(0.35))
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(appState.hasNextTrack == false)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(glassCardBackground(cornerRadius: 32))
    }

    private var utilityCard: some View {
        VStack(spacing: 18) {
            Button {
                appState.toggleLike(for: track)
            } label: {
                Label(
                    appState.isTrackLiked(track) ? "Saved to Liked Songs" : "Save to Liked Songs",
                    systemImage: appState.isTrackLiked(track) ? "heart.fill" : "heart"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appState.isTrackLiked(track) ? .pink : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                Text("Background playback is native.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text("MusicTube keeps playing on the home screen, the lock screen, and in CarPlay using AVPlayer plus extracted YouTube audio streams.")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.72))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(22)
        .background(glassCardBackground(cornerRadius: 28))
    }

    private var playerBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.03, blue: 0.05),
                    Color(red: 0.09, green: 0.02, blue: 0.09),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.pink.opacity(0.2))
                .frame(width: 320, height: 320)
                .blur(radius: 120)
                .offset(x: 140, y: -210)

            Circle()
                .fill(Color.blue.opacity(0.16))
                .frame(width: 280, height: 280)
                .blur(radius: 110)
                .offset(x: -150, y: 260)
        }
    }

    private var displayedPlaybackPosition: TimeInterval {
        isScrubbing ? scrubPosition : appState.playbackPosition
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        isScrubbing = editing

        if editing == false {
            appState.seek(to: scrubPosition)
        }
    }

    private func syncScrubber() {
        let current = min(appState.playbackPosition, appState.playbackDuration)
        scrubPosition = max(0, current)
    }

    private func glassCardBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.36))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
    }

    private static let playbackTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}

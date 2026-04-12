import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    let track: Track

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.2, green: 0.02, blue: 0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                AsyncArtworkView(url: track.artworkURL, cornerRadius: 28)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 8)

                VStack(spacing: 6) {
                    Text(track.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal)

                VStack(spacing: 18) {
                    transportControls

                    Button {
                        appState.toggleLike(for: track)
                    } label: {
                        Label(
                            appState.isTrackLiked(track) ? "Saved to Liked Songs" : "Save to Liked Songs",
                            systemImage: appState.isTrackLiked(track) ? "heart.fill" : "heart"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appState.isTrackLiked(track) ? .pink : .white)
                    }
                    .buttonStyle(.plain)

                    if appState.isPreparingPlayback {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("Preparing audio stream...")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    } else {
                        Text("Audio stays in MusicTube, even after you leave this screen.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal)

                if let youtubeURL = track.youtubeWatchURL {
                    Link(destination: youtubeURL) {
                        Label("Open in YouTube", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Text("This item can only be played inside MusicTube.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 18)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 32) {
            Button {
                appState.playPreviousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(appState.hasPreviousTrack ? .white : .white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(appState.hasPreviousTrack == false)

            Button {
                appState.togglePlayback()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 72, height: 72)

                    if appState.isPreparingPlayback {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.black)
                            .offset(x: appState.isPlaying ? 0 : 2)
                    }
                }
            }

            Button {
                appState.playNextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(appState.hasNextTrack ? .white : .white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(appState.hasNextTrack == false)
        }
    }
}

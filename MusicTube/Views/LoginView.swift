import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.1), Color(red: 0.15, green: 0.03, blue: 0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                Image(systemName: "music.note.tv.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)

                VStack(spacing: 10) {
                    Text("MusicTube")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Listen on your phone and in CarPlay with one seamless queue.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                Button {
                    Task {
                        await appState.signIn()
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Continue with YouTube")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(red: 0.92, green: 0.12, blue: 0.16))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(appState.isLoading)

                Text("No in-app ads. Playback behavior follows your YouTube account permissions.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
        .overlay {
            if appState.isLoading {
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

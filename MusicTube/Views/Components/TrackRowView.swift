import SwiftUI

struct TrackRowView: View {
    let track: Track
    let onTap: () -> Void

    @StateObject private var downloadService = DownloadService.shared

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                AsyncArtworkView(url: track.artworkURL, cornerRadius: 14)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 4) {
                        if downloadService.isDownloaded(track) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.cyan.opacity(0.8))
                        }
                        Text(track.artist)
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.58))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color(red: 1, green: 0.24, blue: 0.43))
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

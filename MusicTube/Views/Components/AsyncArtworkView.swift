import SwiftUI

struct AsyncArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 10

    var body: some View {
        // Color.clear establishes the layout frame; overlay constrains its
        // content to exactly that frame, preventing scaledToFill overflow.
        Color.clear
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        Color(white: 0.12)
                            .overlay(ProgressView().tint(Color.white.opacity(0.4)))
                    default:
                        Color(white: 0.12)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.title2)
                                    .foregroundStyle(Color.white.opacity(0.3))
                            )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

import SwiftUI
import UIKit

// MARK: - ImageCache

private final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024  // 50 MB
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

// MARK: - CachedArtworkLoader

@MainActor
private final class CachedArtworkLoader: ObservableObject {
    @Published var image: UIImage?
    private var loadTask: Task<Void, Never>?
    private var loadedURL: URL?

    func load(url: URL?) {
        guard let url else { image = nil; return }
        guard url != loadedURL else { return }
        loadedURL = url

        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                guard let img = UIImage(data: data) else { return }
                ImageCache.shared.store(img, for: url)
                await MainActor.run { [weak self] in self?.image = img }
            } catch {}
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        loadedURL = nil
    }
}

// MARK: - AsyncArtworkView

struct AsyncArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 10

    @StateObject private var loader = CachedArtworkLoader()

    var body: some View {
        Color.clear
            .overlay {
                if let img = loader.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(white: 0.12)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.title2)
                                .foregroundStyle(Color.white.opacity(0.3))
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                loader.load(url: url)
            }
    }
}

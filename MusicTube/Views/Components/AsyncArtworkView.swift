import SwiftUI
import ImageIO
import UIKit

// MARK: - ImageCache

enum ArtworkPixelSize {
    static let list = 320
    static let nowPlaying = 720
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024  // 50 MB
    }

    func image(for url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: cacheKey(for: url, maxPixelSize: maxPixelSize))
    }

    func store(_ image: UIImage, for url: URL, maxPixelSize: Int) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: cacheKey(for: url, maxPixelSize: maxPixelSize), cost: cost)
    }

    func cacheKey(for url: URL, maxPixelSize: Int) -> NSString {
        "\(url.absoluteString)|\(maxPixelSize)" as NSString
    }
}

actor ArtworkRepository {
    static let shared = ArtworkRepository()

    private var inFlightLoads: [NSString: Task<UIImage?, Never>] = [:]

    func image(for url: URL, maxPixelSize: Int) async -> UIImage? {
        if let cached = ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize) {
            return cached
        }

        let cacheKey = ImageCache.shared.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let existingTask = inFlightLoads[cacheKey] {
            return await existingTask.value
        }

        let task: Task<UIImage?, Never> = Task.detached(priority: .utility) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard Task.isCancelled == false else { return Optional<UIImage>.none }
                guard let image = Self.downsampledImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
                ImageCache.shared.store(image, for: url, maxPixelSize: maxPixelSize)
                return image
            } catch {
                return nil
            }
        }

        inFlightLoads[cacheKey] = task
        let image = await task.value
        inFlightLoads.removeValue(forKey: cacheKey)
        return image
    }

    private static func downsampledImage(from data: Data, maxPixelSize: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(data: data)
        }

        return UIImage(cgImage: thumbnail)
    }
}

// MARK: - CachedArtworkLoader

@MainActor
private final class CachedArtworkLoader: ObservableObject {
    @Published var image: UIImage?
    private var loadTask: Task<Void, Never>?
    private var loadedURL: URL?
    private let maxPixelSize = ArtworkPixelSize.list

    func load(url: URL?) {
        guard let url else { image = nil; return }
        guard url != loadedURL else { return }
        loadedURL = url

        if let cached = ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize) {
            image = cached
            return
        }

        loadTask?.cancel()
        let maxPixelSize = self.maxPixelSize
        loadTask = Task { [weak self] in
            guard let image = await ArtworkRepository.shared.image(for: url, maxPixelSize: maxPixelSize) else { return }
            guard Task.isCancelled == false else { return }
            self?.image = image
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

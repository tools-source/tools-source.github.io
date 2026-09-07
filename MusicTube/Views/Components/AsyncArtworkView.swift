import CryptoKit
import SwiftUI
import ImageIO
import UIKit

// MARK: - ImageCache

enum ArtworkTargetSize {
    static let compactRow = 120
    static let standardRow = 240
    static let card = 480
    static let nowPlaying = 900
}

enum ArtworkPixelSize {
    static let list = ArtworkTargetSize.standardRow
    static let nowPlaying = ArtworkTargetSize.nowPlaying
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
        let normalizedURL = url.normalizedArtworkURL
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: cacheKey(for: normalizedURL, maxPixelSize: maxPixelSize), cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func cacheKey(for url: URL, maxPixelSize: Int) -> NSString {
        let normalizedURL = url.normalizedArtworkURL
        return "\(normalizedURL.absoluteString)|\(maxPixelSize)" as NSString
    }
}

// MARK: - ArtworkDiskCache

/// Persistent on-disk cache for already-downsampled artwork. Keyed by the same
/// "url|maxPixelSize" string the memory cache uses, so a relaunch reuses the exact
/// rendition without re-downloading or re-decoding from the network. Stored as JPEG
/// (album art needs no alpha) to keep the footprint small. Bounded to a fixed budget
/// with oldest-first eviction so the cache never grows without limit.
actor ArtworkDiskCache {
    static let shared = ArtworkDiskCache()

    private let directory: URL
    private let maxBytes: Int = 96 * 1024 * 1024   // 96 MB on-disk budget
    private let fileManager = FileManager.default
    private var didSchedulePrune = false

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("musictube-artwork", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deterministic filename so the same artwork maps to the same file across launches
    /// (`String.hashValue` is per-process-seeded and would not survive a relaunch).
    private func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    func image(forKey key: String) -> UIImage? {
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        // Touch so least-recently-used files are evicted last.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    func store(_ image: UIImage, forKey key: String) {
        guard let data = image.jpegData(compressionQuality: 0.82) ?? image.pngData() else { return }
        try? data.write(to: fileURL(forKey: key), options: .atomic)
        schedulePruneIfNeeded()
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        didSchedulePrune = false
    }

    /// Coalesces pruning so a burst of stores triggers a single sweep.
    private func schedulePruneIfNeeded() {
        guard didSchedulePrune == false else { return }
        didSchedulePrune = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.prune()
        }
    }

    private func prune() {
        didSchedulePrune = false
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return }

        let entries = files.compactMap { url -> (url: URL, size: Int, modified: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }

        let totalBytes = entries.reduce(0) { $0 + $1.size }
        guard totalBytes > maxBytes else { return }

        // Evict oldest first until back under budget.
        var remaining = totalBytes
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard remaining > maxBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            remaining -= entry.size
        }
    }
}

actor ArtworkRepository {
    static let shared = ArtworkRepository()

    private var inFlightLoads: [NSString: Task<UIImage?, Never>] = [:]
    private var failedUntil: [URL: Date] = [:]
    private let failedRequestTTL: TimeInterval = 45
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = .shared
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL, maxPixelSize: Int) async -> UIImage? {
        let normalizedURL = url.normalizedArtworkURL

        if let cached = ImageCache.shared.image(for: normalizedURL, maxPixelSize: maxPixelSize) {
            return cached
        }

        if let expiry = failedUntil[normalizedURL], expiry > Date() {
            return nil
        }
        failedUntil.removeValue(forKey: normalizedURL)

        let cacheKey = ImageCache.shared.cacheKey(for: normalizedURL, maxPixelSize: maxPixelSize)
        if let existingTask = inFlightLoads[cacheKey] {
            return await existingTask.value
        }

        let session = self.session
        let task: Task<UIImage?, Never> = Task.detached(priority: .utility) {
            let keyString = cacheKey as String

            // 1. Persistent disk cache — survives relaunch, avoids the network entirely.
            if let diskImage = await ArtworkDiskCache.shared.image(forKey: keyString) {
                guard Task.isCancelled == false else { return Optional<UIImage>.none }
                ImageCache.shared.store(diskImage, for: normalizedURL, maxPixelSize: maxPixelSize)
                return diskImage
            }

            // 2. Network — downsample, then populate both memory and disk caches.
            do {
                var request = URLRequest(url: normalizedURL)
                request.cachePolicy = .useProtocolCachePolicy
                let (data, response) = try await session.data(for: request)
                guard Task.isCancelled == false else { return Optional<UIImage>.none }
                if let response = response as? HTTPURLResponse,
                   (200..<300).contains(response.statusCode) == false {
                    return nil
                }
                guard let image = Self.downsampledImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
                ImageCache.shared.store(image, for: normalizedURL, maxPixelSize: maxPixelSize)
                await ArtworkDiskCache.shared.store(image, forKey: keyString)
                return image
            } catch {
                return nil
            }
        }

        inFlightLoads[cacheKey] = task
        let image = await task.value
        inFlightLoads.removeValue(forKey: cacheKey)
        if image == nil {
            failedUntil[normalizedURL] = Date().addingTimeInterval(failedRequestTTL)
        } else {
            failedUntil.removeValue(forKey: normalizedURL)
        }
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
    private var loadedMaxPixelSize: Int?

    func load(url: URL?, maxPixelSize: Int = ArtworkPixelSize.list) {
        guard let url else {
            loadTask?.cancel()
            loadTask = nil
            loadedURL = nil
            loadedMaxPixelSize = nil
            image = nil
            return
        }
        let normalizedURL = url.normalizedArtworkURL
        guard normalizedURL != loadedURL || maxPixelSize != loadedMaxPixelSize else { return }

        loadTask?.cancel()
        loadedURL = normalizedURL
        loadedMaxPixelSize = maxPixelSize

        if let cached = ImageCache.shared.image(for: normalizedURL, maxPixelSize: maxPixelSize) {
            image = cached
            loadTask = nil
            return
        }

        // Keep the previous artwork in place while a replacement is loading. Clearing
        // it here makes every lazy-grid reconfiguration flash the placeholder, even
        // when the new image arrives a frame later from the memory cache.
        loadTask = Task { [weak self] in
            let loadedImage = await ArtworkRepository.shared.image(
                for: normalizedURL,
                maxPixelSize: maxPixelSize
            )
            guard Task.isCancelled == false,
                  let self,
                  self.loadedURL == normalizedURL,
                  self.loadedMaxPixelSize == maxPixelSize else { return }
            guard let loadedImage else {
                self.image = nil
                // Permit a later appearance to retry a transient artwork failure.
                self.loadedURL = nil
                self.loadedMaxPixelSize = nil
                self.loadTask = nil
                return
            }
            self.image = loadedImage
            self.loadTask = nil
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        // Lazy containers call onDisappear while cells are merely off-screen. Retain
        // successful identity so returning cells do not briefly regress to a placeholder.
        if image == nil {
            loadedURL = nil
            loadedMaxPixelSize = nil
        }
    }
}

// MARK: - AsyncArtworkView

struct AsyncArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 10
    var maxPixelSize: Int = ArtworkPixelSize.list
    var contentMode: ContentMode = .fill

    @StateObject private var loader = CachedArtworkLoader()

    var body: some View {
        Color.clear
            .overlay {
                if let img = loader.image {
                    artworkImage(img)
                } else {
                    AppTheme.controlFillStrong
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.title2)
                                .foregroundStyle(AppTheme.tertiaryText)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: "\(url?.absoluteString ?? "")|\(maxPixelSize)") {
                loader.load(url: url, maxPixelSize: maxPixelSize)
            }
            .onDisappear {
                loader.cancel()
            }
    }

    @ViewBuilder
    private func artworkImage(_ image: UIImage) -> some View {
        let renderedImage = Image(uiImage: image).resizable()
        switch contentMode {
        case .fit:
            renderedImage.scaledToFit()
        case .fill:
            renderedImage.scaledToFill()
        }
    }
}

private extension URL {
    var normalizedArtworkURL: URL {
        if scheme == nil, absoluteString.hasPrefix("//"), let httpsURL = URL(string: "https:\(absoluteString)") {
            return httpsURL
        }
        return self
    }
}

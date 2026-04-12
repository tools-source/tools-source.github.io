import AVFoundation
import Foundation

// MARK: - DownloadRecord

struct DownloadRecord: Codable, Identifiable, Sendable {
    let id: String
    let track: Track
    let fileName: String
    let downloadedAt: Date
    var fileSizeBytes: Int64

    var localURL: URL {
        DownloadService.downloadsDirectory.appendingPathComponent(fileName)
    }

    var localTrack: Track {
        Track(
            id: track.id,
            title: track.title,
            artist: track.artist,
            artworkURL: track.artworkURL,
            youtubeVideoID: track.youtubeVideoID,
            streamURL: localURL
        )
    }
}

// MARK: - ActiveDownload

struct ActiveDownload: Identifiable {
    let id: String   // youtubeVideoID or track.id
    let track: Track
    var progress: Double   // 0.0 – 1.0
    var isFailed: Bool
}

// MARK: - DownloadService

@MainActor
final class DownloadService: NSObject, ObservableObject {

    static let shared = DownloadService()

    static var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("MusicTubeDownloads", isDirectory: true)
    }

    @Published private(set) var downloads: [DownloadRecord] = []
    @Published private(set) var activeDownloads: [String: ActiveDownload] = [:]

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    private var metadataURL: URL {
        Self.downloadsDirectory.appendingPathComponent("metadata.json")
    }

    // MARK: Init

    override init() {
        super.init()
        createDirectoryIfNeeded()
        loadMetadata()
        pruneOrphanedRecords()
    }

    // MARK: Public Query API

    func isDownloaded(_ track: Track) -> Bool {
        let key = trackKey(track)
        return downloads.contains { trackKey($0.track) == key }
    }

    func isDownloading(_ track: Track) -> Bool {
        activeDownloads[trackKey(track)] != nil
    }

    func downloadedRecord(for track: Track) -> DownloadRecord? {
        let key = trackKey(track)
        return downloads.first { trackKey($0.track) == key }
    }

    // MARK: Download Control

    /// Starts a download using a pre-resolved stream URL.
    /// Call resolveStreamURL(for:) on PlaybackService first, then pass the result here.
    func startDownload(track: Track, streamURL: URL) {
        let key = trackKey(track)
        guard activeDownloads[key] == nil, !isDownloaded(track) else { return }

        activeDownloads[key] = ActiveDownload(id: key, track: track, progress: 0, isFailed: false)

        let task = urlSession.downloadTask(with: streamURL) { [weak self] tempURL, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.activeDownloads.removeValue(forKey: key)
                    self.downloadTasks.removeValue(forKey: key)
                    self.progressObservations.removeValue(forKey: key)
                }

                if let error {
                    self.activeDownloads[key]?.isFailed = true
                    print("[DownloadService] Download failed for \(track.title): \(error.localizedDescription)")
                    return
                }

                guard let tempURL else { return }

                let fileExtension = self.preferredExtension(for: response)
                let fileName = "\(key).\(fileExtension)"
                let destURL = Self.downloadsDirectory.appendingPathComponent(fileName)

                do {
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: tempURL, to: destURL)

                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                    let record = DownloadRecord(
                        id: UUID().uuidString,
                        track: track,
                        fileName: fileName,
                        downloadedAt: Date(),
                        fileSizeBytes: fileSize
                    )
                    self.downloads.append(record)
                    self.saveMetadata()
                } catch {
                    print("[DownloadService] Failed to move download file: \(error.localizedDescription)")
                }
            }
        }

        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeDownloads[key]?.progress = min(max(progress.fractionCompleted, 0), 0.98)
            }
        }

        progressObservations[key] = observation
        downloadTasks[key] = task
        task.resume()
    }

    func cancelDownload(for track: Track) {
        let key = trackKey(track)
        downloadTasks[key]?.cancel()
        downloadTasks.removeValue(forKey: key)
        progressObservations.removeValue(forKey: key)
        activeDownloads.removeValue(forKey: key)
    }

    func deleteDownload(_ record: DownloadRecord) {
        try? FileManager.default.removeItem(at: record.localURL)
        downloads.removeAll { $0.id == record.id }
        saveMetadata()
    }

    func deleteDownload(for track: Track) {
        guard let record = downloadedRecord(for: track) else { return }
        deleteDownload(record)
    }

    // MARK: Computed

    var totalDownloadedBytes: Int64 {
        downloads.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var totalDownloadedMB: Double {
        Double(totalDownloadedBytes) / 1_048_576
    }

    // MARK: Private helpers

    private func trackKey(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func preferredExtension(for response: URLResponse?) -> String {
        guard let mime = response?.mimeType else { return "m4a" }
        if mime.contains("webm") { return "webm" }
        if mime.contains("mp4") || mime.contains("m4a") { return "m4a" }
        return "m4a"
    }

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: Self.downloadsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let records = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        else { return }
        downloads = records
    }

    private func pruneOrphanedRecords() {
        let existing = downloads.filter {
            FileManager.default.fileExists(atPath: $0.localURL.path)
        }
        if existing.count != downloads.count {
            downloads = existing
            saveMetadata()
        }
    }

    private func saveMetadata() {
        guard let data = try? JSONEncoder().encode(downloads) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }
}

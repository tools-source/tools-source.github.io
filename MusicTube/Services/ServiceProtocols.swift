import Foundation
import OSLog
import UIKit

extension Logger {
    private static var musicTubeSubsystem: String {
        Bundle.main.bundleIdentifier ?? "MusicTube"
    }

    static let playback = Logger(subsystem: musicTubeSubsystem, category: "Playback")
    static let downloads = Logger(subsystem: musicTubeSubsystem, category: "Downloads")
    static let recommendations = Logger(subsystem: musicTubeSubsystem, category: "Recommendations")
    static let search = Logger(subsystem: musicTubeSubsystem, category: "Search")
}

struct AppConfig {
    enum Sharing {
        static let appURLSchemeInfoDictionaryKey = "MUSICTUBE_URL_SCHEME"
        static var appURLScheme: String {
            let configuredScheme = (Bundle.main.infoDictionary?[appURLSchemeInfoDictionaryKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return (configuredScheme?.isEmpty == false ? configuredScheme : nil) ?? "musictube"
        }
        static let webShareBaseURL = URL(string: "https://music-tube.me/share.html")!
        static let supportedWebHosts: Set<String> = [
            "music-tube.me",
            "www.music-tube.me",
            "musictube-api-322459144075.us-east4.run.app"
        ]
    }

    enum YouTube {
        static let apiKeyInfoDictionaryKey = "YOUTUBE_API_KEY"
        static let innerTubeSearchEndpoint = URL(string: "https://www.youtube.com/youtubei/v1/search")!
        static let innerTubeClientVersion = "2.20260114.08.00"
        static let likedMusicPlaylistID = "liked-music"
        static let likedMusicPreviewLimit = 40
    }

    enum AICuration {
        static let endpointInfoDictionaryKey = "MUSICTUBE_AI_ENDPOINT"
        static let cacheTTL: TimeInterval = 900
        static let requestTimeout: TimeInterval = 18
        static let maxSeedQueries = 8
        static let maxRerankCandidates = 40
        static let maxResponseBytes = 64 * 1024

        static var clientVersion: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        }

        static var endpointURL: URL? {
            guard let value = Bundle.main.object(forInfoDictionaryKey: endpointInfoDictionaryKey) as? String else {
                return nil
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  trimmed.hasPrefix("$(") == false,
                  let url = URL(string: trimmed),
                  url.scheme?.lowercased() == "https",
                  url.host?.isEmpty == false else {
                return nil
            }
            return url
        }
    }

    enum Search {
        static let maxQueryLength = 100
        static let resultsPerPage = 24
        static let cacheTTL: TimeInterval = 300
        static let maxCachedQueries = 80
        static let debounceNanoseconds: UInt64 = 350_000_000
        static let autocompleteDebounceNanoseconds: UInt64 = 350_000_000
        static let visibleSongPageSize = 8
    }

    enum Recommendations {
        static let candidateCacheTTL: TimeInterval = 600
        static let maxCachedQueries = 96
    }

    enum Cache {
        static let trackListTTL: TimeInterval = 300
    }

    enum Metadata {
        // Duration is immutable and view counts change slowly, so display metadata
        // can be cached aggressively. This keeps a single batched lookup from
        // repeating as the same songs reappear across home/search/recommendations.
        static let cacheTTL: TimeInterval = 86_400
        static let maxCachedEntries = 600
        static let batchSize = 50
    }

    enum Catalog {
        static let authenticatedRefreshCooldown: TimeInterval = 900
        // The account's liked/uploads playlist IDs don't change within a session.
        static let relatedPlaylistsCacheTTL: TimeInterval = 3_600
        static let dataAPITransientBackoff: TimeInterval = 300
        static let dataAPIDeniedBackoff: TimeInterval = 1_800
        static let dataAPINetworkBackoff: TimeInterval = 120
    }

    enum Playback {
        // Keep startup lean so AVPlayer can begin as soon as the first audio
        // packets are ready. Steady-state buffering expands after playback starts.
        static let startupForwardBufferDuration: TimeInterval = 0.75
        // Keep the forward buffer modest for long background sessions. A large
        // buffer can keep AVPlayer's network pipeline busy for minutes after
        // startup, which makes lock-screen transport commands sluggish on
        // device when the debugger is not attached.
        static let steadyStateForwardBufferDuration: TimeInterval = 6
        static let foregroundTimeObserverInterval: TimeInterval = 1
        static let backgroundTimeObserverInterval: TimeInterval = 10
        static let maxActivePrefetchTasks = 4
        // Interactive extraction is bounded so a failed remote endpoint can never
        // leave the UI waiting indefinitely. Local and remote extraction race.
        static let streamResolutionTimeoutNanoseconds: UInt64 = 3_000_000_000
        // Direct progressive YouTube URLs sometimes leave AVPlayer waiting without
        // buffering a byte. Switch those to the bounded loader quickly; retain the
        // longer timeout for HLS, local files, and an already-bounded stream.
        static let progressiveFallbackWaitTimeoutNanoseconds: UInt64 = 1_500_000_000
        static let startupWaitTimeoutNanoseconds: UInt64 = 5_000_000_000
    }

    enum Downloads {
        // Keep bulk "Download All" gentle on CPU/network/thermals. 8 parallel
        // transfers (plus 8 parallel stream resolutions) saturated the radio and
        // spiked the SoC, heating the device within seconds. 3 concurrent transfers
        // keeps throughput high while staying well under the thermal/network budget.
        static let maxConcurrentActiveDownloads = 3
        static let maxConcurrentStreamResolutions = 3
        static let batchResolveSpacingNanoseconds: UInt64 = 10_000_000
        static let pendingDownloadRetryDelayNanoseconds: UInt64 = 1_500_000_000
        static let maxPendingDownloadRetryPassesWithoutProgress = 3
    }

    enum Library {
        static let localLikedPlaylistID = "local-liked-songs"
        static let localSavedSongsPlaylistID = "local-saved-songs"
        static let localReplayMixPlaylistID = "local-replay-mix"
        static let localFavoritesMixPlaylistID = "local-favorites-mix"
        static let deviceProfileID = "device-local-profile"
        static let likedSongsSyncCooldown: TimeInterval = 300
    }
}

enum AppPowerBudget {
    static var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static var isThermallyConstrained: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return true
        }
    }

    static var isThermallyWarm: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .fair, .serious, .critical:
            return true
        case .nominal:
            return false
        @unknown default:
            return true
        }
    }

    @MainActor
    static var isLowBattery: Bool {
        let device = UIDevice.current
        if device.isBatteryMonitoringEnabled == false {
            device.isBatteryMonitoringEnabled = true
        }

        guard device.batteryLevel >= 0 else { return false }
        return device.batteryLevel <= 0.20
    }

    @MainActor
    static var shouldReduceWork: Bool {
        isLowPowerModeEnabled || isThermallyWarm || isLowBattery
    }

    @MainActor
    static func allowsSpeculativeNetwork(isAppInBackground: Bool) -> Bool {
        guard isAppInBackground == false else { return false }
        guard isLowPowerModeEnabled == false else { return false }
        guard isThermallyWarm == false else { return false }
        guard isLowBattery == false else { return false }
        return true
    }

    @MainActor
    static func allowsBackgroundQueueWarmup() -> Bool {
        false
    }

    @MainActor
    static func downloadResolutionBatchSize(default defaultSize: Int) -> Int {
        shouldReduceWork ? 1 : defaultSize
    }

    @MainActor
    static func activeDownloadLimit(default defaultLimit: Int) -> Int {
        shouldReduceWork ? min(defaultLimit, 1) : defaultLimit
    }
}

struct DownloadConcurrencyEnvironment: Equatable, Sendable {
    let isLowPowerModeEnabled: Bool
    let isCellular: Bool
    let isExpensiveNetwork: Bool
    let isLowDataMode: Bool
    let isInBackground: Bool
    let isThermallyConstrained: Bool
}

enum DownloadConcurrencyPolicy {
    static func limit(
        default defaultLimit: Int,
        environment: DownloadConcurrencyEnvironment
    ) -> Int {
        guard defaultLimit > 0 else { return 0 }
        if environment.isLowPowerModeEnabled
            || environment.isThermallyConstrained
            || environment.isInBackground {
            return 1
        }
        if environment.isCellular || environment.isLowDataMode {
            return 1
        }
        if environment.isExpensiveNetwork {
            return min(2, defaultLimit)
        }
        return min(3, defaultLimit)
    }
}

enum QueryValidationError: LocalizedError {
    case empty
    case tooLong(maxLength: Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter something to search for."
        case .tooLong(let maxLength):
            return "Searches are limited to \(maxLength) characters."
        }
    }
}

struct QueryValidator {
    static func validateSearchQuery(_ query: String) throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else {
            throw QueryValidationError.empty
        }

        guard trimmed.count <= AppConfig.Search.maxQueryLength else {
            throw QueryValidationError.tooLong(maxLength: AppConfig.Search.maxQueryLength)
        }

        return trimmed
    }
}

enum SearchTextNormalizer {
    static func normalized(_ value: String, collapsingTaMarbuta: Bool = true) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[\\u064B-\\u065F\\u0670\\u06D6-\\u06ED]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[أإآٱ]", with: "ا", options: .regularExpression)
            .replacingOccurrences(of: "ى", with: "ي")
            .replacingOccurrences(of: "ؤ", with: "و")
            .replacingOccurrences(of: "ئ", with: "ي")
            .replacingOccurrences(of: "ة", with: collapsingTaMarbuta ? "ه" : "ة")
            .replacingOccurrences(of: "[^a-z0-9\\s\\p{Arabic}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(from value: String, collapsingTaMarbuta: Bool = true) -> [String] {
        normalized(value, collapsingTaMarbuta: collapsingTaMarbuta)
            .split(separator: " ")
            .map(String.init)
    }
}

protocol AppLogging {
    func debug(_ message: String)
    func info(_ message: String)
    func error(_ message: String, error: Error?)
}

struct DefaultAppLogger: AppLogging {
    private let logger: Logger

    init(category: String, subsystem: String = Bundle.main.bundleIdentifier ?? "MusicTube") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .private)")
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
    }

    func error(_ message: String, error: Error? = nil) {
        if let error {
            logger.error("\(message, privacy: .private): \(error.localizedDescription, privacy: .private)")
        } else {
            logger.error("\(message, privacy: .private)")
        }
    }
}

actor CacheStore<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let expiresAt: Date
    }

    private var store: [Key: Entry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int?

    init(ttl: TimeInterval, maxEntries: Int? = nil) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    func value(for key: Key) -> Value? {
        guard let entry = store[key] else { return nil }
        guard entry.expiresAt > Date() else {
            store.removeValue(forKey: key)
            return nil
        }

        return entry.value
    }

    func set(_ value: Value, for key: Key) {
        store[key] = Entry(
            value: value,
            expiresAt: Date().addingTimeInterval(ttl)
        )

        trimExpiredEntries()
        trimOverflowIfNeeded()
    }

    func removeValue(for key: Key) {
        store.removeValue(forKey: key)
    }

    func removeAll() {
        store.removeAll()
    }

    private func trimExpiredEntries() {
        let now = Date()
        store = store.filter { $0.value.expiresAt > now }
    }

    private func trimOverflowIfNeeded() {
        guard let maxEntries, store.count > maxEntries else { return }

        let overflowKeys = store
            .sorted { $0.value.expiresAt < $1.value.expiresAt }
            .prefix(store.count - maxEntries)
            .map(\.key)

        for key in overflowKeys {
            store.removeValue(forKey: key)
        }
    }
}

protocol AuthProviding {
    /// Restores a previously persisted session when one is still valid or refreshable.
    func restoreSession() async -> YouTubeSession?
    /// Forces a token refresh for the current persisted session, if possible.
    func refreshSession() async -> YouTubeSession?
    /// Starts the interactive YouTube sign-in flow and returns a new authorized session.
    func signIn() async throws -> YouTubeSession
    /// Clears any persisted credentials and local auth session state.
    func signOut() async
}

protocol MusicCatalogProviding {
    /// Loads personalized home content for an authenticated YouTube account.
    func loadHome(accessToken: String) async throws -> (featured: [Track], recent: [Track])
    /// Searches songs, playlists, albums, and artists for the given query.
    func search(query: String, accessToken: String?) async throws -> SearchResponse
    /// Loads the next page of song results for a previously issued search query.
    /// - Parameters:
    ///   - query: The original validated search query.
    ///   - continuation: The continuation token returned by the previous search response.
    ///   - accessToken: Optional OAuth token for authenticated YouTube requests.
    func loadMoreSearchResults(query: String, continuation: String, accessToken: String?) async throws -> SearchResponse
    /// Loads playlists visible to the authenticated user, including system collections.
    func loadPlaylists(accessToken: String) async throws -> [Playlist]
    /// Loads the tracks contained in a playlist, using guest fallbacks when needed.
    func loadPlaylistItems(for playlist: Playlist, accessToken: String?) async throws -> [Track]
    /// Resolves a direct YouTube video ID into a playable track when possible.
    func lookupTrack(videoID: String, accessToken: String?) async throws -> Track?
    /// Loads tracks contained in a saved collection, with guest fallbacks when available.
    func loadCollectionItems(for collection: MusicCollection, accessToken: String?) async throws -> [Track]
    /// Fills in missing display metadata (duration, view count) for the given tracks
    /// using a single batched lookup per 50 items. Returns the tracks unchanged when
    /// no enrichment source is available so callers can use the result directly.
    func fillMissingMetadata(for tracks: [Track]) async -> [Track]
}

extension MusicCatalogProviding {
    /// Default no-op so conformers that cannot enrich metadata still satisfy the
    /// protocol; the result is always safe to use in place of the input.
    func fillMissingMetadata(for tracks: [Track]) async -> [Track] { tracks }
}

@MainActor
protocol PlaybackControlling: AnyObject {
    var nowPlaying: Track? { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    func play(track: Track)
    func resume()
    func pause()
    func seek(to time: TimeInterval)
}

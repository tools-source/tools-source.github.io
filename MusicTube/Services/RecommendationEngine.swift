import Foundation

/// One canonical identity for recommendation de-duplication. YouTube frequently
/// returns the same recording from an artist channel, a VEVO channel, and a Topic
/// channel with small title changes such as "official video" or "lyrics". Treating
/// those uploads as different songs is the biggest source of apparent repetition.
enum RecommendationTrackIdentity {
    private static let presentationOnlyTitleTokens: Set<String> = [
        "4k", "audio", "hd", "hq", "lyric", "lyrics", "music", "official",
        "video", "visualiser", "visualizer"
    ]

    static func contentSignature(for track: Track) -> String {
        let artist = canonicalArtist(track.artist)
        var titleTokens = SearchTextNormalizer.tokens(from: track.title)
            .filter { presentationOnlyTitleTokens.contains($0) == false }
        let artistTokens = artist.split(separator: " ").map(String.init)

        // Search results sometimes prefix the song with the artist even when the
        // channel metadata already supplies the artist. Remove that redundant prefix.
        if artistTokens.isEmpty == false,
           titleTokens.starts(with: artistTokens) {
            titleTokens.removeFirst(artistTokens.count)
        }

        let title = titleTokens.joined(separator: " ")
        guard title.isEmpty == false else { return "id:\(track.playbackKey)" }
        return "\(title)|\(artist)"
    }

    static func artistKey(for track: Track) -> String {
        let artist = canonicalArtist(track.artist)
        return artist.isEmpty ? "track:\(track.playbackKey)" : artist
    }

    private static func canonicalArtist(_ value: String) -> String {
        var normalized = SearchTextNormalizer.normalized(value)
        var removedSuffix = true
        while removedSuffix {
            removedSuffix = false
            for suffix in [" vevo", " topic", " official", " music"] where normalized.hasSuffix(suffix) {
                normalized.removeLast(suffix.count)
                removedSuffix = true
                break
            }
        }
        // Handles compact channel names such as `AdeleVEVO`.
        if normalized.hasSuffix("vevo"), normalized.count > 4 {
            normalized.removeLast(4)
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RecommendationSeedFamily: String, CaseIterable, Hashable, Sendable {
    case focusedTrack
    case likedSongs
    case savedSongs
    case completedListens
    case topArtists
    case recentSearches
    case preferences
    case successfulDiscovery
    case exploration
}

enum RecommendationLane: String, Hashable, Sendable {
    case familiar
    case discovery
    case exploration
}

struct RecommendationSeedQuery: Hashable, Sendable {
    let query: String
    let family: RecommendationSeedFamily
    let lane: RecommendationLane
}

struct RecommendationExposure: Hashable, Sendable {
    let track: Track
    let shownAt: Date
}

/// Centralized, intentionally readable weights for the deterministic ranker.
/// These are MusicTube product weights—not values from any proprietary service.
struct RecommendationScoringWeights: Sendable {
    // Explicit taste is deliberately stronger than passive popularity/recency.
    let likedArtist = 5.5
    let savedArtist = 5.0
    let completedArtist = 1.8
    let replayedArtist = 1.4
    let preferenceToken = 1.25
    let focusedArtist = 8.0
    let focusedTitleToken = 0.8

    // Source priors distinguish confident retrieval from controlled exploration.
    let likedSeed = 2.0
    let savedSeed = 1.8
    let completionSeed = 1.6
    let searchSeed = 0.8
    let preferenceSeed = 1.0
    let discoverySeed = 1.2
    let explorationSeed = 0.35

    // Negative intent and fatigue must be able to outweigh artist affinity.
    let exactRecentSkip = 9.0
    let artistSkip = 2.2
    let exactLikedOrSavedReplay = 4.0
    let artistFatigue = 1.6

    static let `default` = RecommendationScoringWeights()
}

/// Persists what the Home shelf actually displayed, not just what was played.
/// This lets a refresh and a later app launch honor the same novelty cooldown.
@MainActor
final class RecommendationExposureStore {
    static let shared = RecommendationExposureStore()

    struct Entry: Codable, Equatable, Sendable {
        let track: Track
        let shownAt: Date
    }

    private struct StoragePayload: Codable, Sendable {
        var entriesByProfile: [String: [Entry]] = [:]
        var rotationCursorByProfile: [String: Int] = [:]
    }

    private actor PersistenceWriter {
        private let defaults: UserDefaults
        private let storageKey: String
        private var latestGeneration = 0

        init(defaults: UserDefaults, storageKey: String) {
            self.defaults = defaults
            self.storageKey = storageKey
        }

        func persist(_ payload: StoragePayload, generation: Int) {
            guard generation >= latestGeneration else { return }
            latestGeneration = generation
            guard let data = try? JSONEncoder().encode(payload) else { return }
            defaults.set(data, forKey: storageKey)
        }
    }

    private static let storageKey = "musictube.recommendationExposures.v1"
    private static let maximumEntriesPerProfile = 160
    private static let cooldown: TimeInterval = 60 * 60 * 24 * 30

    private let defaults: UserDefaults
    private let persistenceWriter: PersistenceWriter
    private var payload: StoragePayload
    private var signaturesByProfile: [String: [String: String]]
    private var scheduledPersistenceTask: Task<Void, Never>?
    private var persistenceGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.persistenceWriter = PersistenceWriter(
            defaults: defaults,
            storageKey: Self.storageKey
        )
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(StoragePayload.self, from: data) {
            payload = decoded
        } else {
            payload = StoragePayload()
        }
        signaturesByProfile = payload.entriesByProfile.mapValues { entries in
            Dictionary(uniqueKeysWithValues: entries.map {
                ($0.track.playbackKey, RecommendationTrackIdentity.contentSignature(for: $0.track))
            })
        }
    }

    func record(_ tracks: [Track], profileID: String, now: Date = Date()) {
        guard tracks.isEmpty == false else { return }

        let existing = payload.entriesByProfile[profileID] ?? []
        var cachedSignatures = signaturesByProfile[profileID] ?? [:]
        var incomingIDs: Set<String> = []
        var incomingSignatures: Set<String> = []
        let newEntries = tracks.compactMap { track -> Entry? in
            let identifier = track.playbackKey
            let signature = RecommendationTrackIdentity.contentSignature(for: track)
            guard incomingIDs.insert(identifier).inserted,
                  incomingSignatures.insert(signature).inserted else { return nil }
            cachedSignatures[identifier] = signature
            return Entry(track: track, shownAt: now)
        }
        let retained = existing.filter { entry in
            let identifier = entry.track.playbackKey
            let signature: String
            if let cached = cachedSignatures[identifier] {
                signature = cached
            } else {
                let computed = RecommendationTrackIdentity.contentSignature(for: entry.track)
                cachedSignatures[identifier] = computed
                signature = computed
            }
            return incomingIDs.contains(identifier) == false
                && incomingSignatures.contains(signature) == false
        }
        let updated = Array((newEntries + retained).prefix(Self.maximumEntriesPerProfile))
        payload.entriesByProfile[profileID] = updated
        signaturesByProfile[profileID] = Dictionary(uniqueKeysWithValues: updated.map { entry in
            let identifier = entry.track.playbackKey
            return (
                identifier,
                cachedSignatures[identifier]
                    ?? RecommendationTrackIdentity.contentSignature(for: entry.track)
            )
        })
        schedulePersistence()
    }

    func recentTracks(profileID: String, now: Date = Date(), limit: Int = 120) -> [Track] {
        recentExposures(profileID: profileID, now: now, limit: limit).map(\.track)
    }

    func recentExposures(
        profileID: String,
        now: Date = Date(),
        limit: Int = 120
    ) -> [RecommendationExposure] {
        guard limit > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Self.cooldown)
        return Array(
            (payload.entriesByProfile[profileID] ?? [])
                .filter { $0.shownAt >= cutoff }
                .prefix(limit)
                .map { RecommendationExposure(track: $0.track, shownAt: $0.shownAt) }
        )
    }

    @discardableResult
    func advanceRotation(profileID: String) -> Int {
        let next = (payload.rotationCursorByProfile[profileID, default: 0] + 1) % 10_000
        payload.rotationCursorByProfile[profileID] = next
        // A user-requested refresh must survive an immediate app suspension. It also
        // flushes any card impressions accumulated by the debounced writer.
        scheduledPersistenceTask?.cancel()
        scheduledPersistenceTask = nil
        persist()
        return next
    }

    func rotationCursor(profileID: String) -> Int {
        payload.rotationCursorByProfile[profileID, default: 0]
    }

    func clearAllData() {
        scheduledPersistenceTask?.cancel()
        scheduledPersistenceTask = nil
        payload = StoragePayload()
        signaturesByProfile = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func schedulePersistence() {
        scheduledPersistenceTask?.cancel()
        scheduledPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard let self else { return }
            let payload = self.payload
            self.persistenceGeneration += 1
            let generation = self.persistenceGeneration
            await self.persistenceWriter.persist(payload, generation: generation)
            self.scheduledPersistenceTask = nil
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// A final, deterministic pass that keeps a taste-ranked list from feeling repetitive.
/// Exact songs (including duplicate uploads with a different video ID) heard recently
/// are moved behind fresh candidates, and tracks by the same artist are spaced apart.
struct RecommendationDiversityPolicy {
    static let defaultRecentWindow = 40
    static let defaultRecommendationWindow = 120
    static let defaultArtistGap = 2

    private struct PreparedTrack {
        let track: Track
        let identifier: String
        let signature: String
        let artist: String
        let originalIndex: Int
    }

    private struct RecencyLookup {
        var playedByID: [String: Int] = [:]
        var playedBySignature: [String: Int] = [:]
        var recommendedByID: [String: Int] = [:]
        var recommendedBySignature: [String: Int] = [:]
        var exposureByID: [String: Date] = [:]
        var exposureBySignature: [String: Date] = [:]
    }

    static func diversified(
        _ candidates: [Track],
        recentlyPlayed: [Track],
        recentlyRecommended: [Track] = [],
        recommendationExposures: [RecommendationExposure] = [],
        limit: Int,
        recentWindow: Int = defaultRecentWindow,
        recommendationWindow: Int = defaultRecommendationWindow,
        artistGap: Int = defaultArtistGap,
        now: Date = Date()
    ) -> [Track] {
        guard limit > 0, candidates.isEmpty == false else { return [] }

        let deduplicated = preparedCandidates(candidates)
        let played = Array(recentlyPlayed.prefix(max(0, recentWindow)))
        let recommended = Array(recentlyRecommended.prefix(max(0, recommendationWindow)))
        let exposures = Array(recommendationExposures.prefix(max(0, recommendationWindow)))
        let recency = makeRecencyLookup(
            played: played,
            recommended: recommended,
            exposures: exposures
        )
        let recentArtistCounts = (played + recommended + exposures.map(\.track))
            .prefix(24)
            .enumerated()
            .reduce(into: [String: Double]()) { result, element in
                let decay = exp(-Double(element.offset) / 6)
                let artist = RecommendationTrackIdentity.artistKey(for: element.element)
                result[artist, default: 0] += decay
            }

        // Preserve taste rank as the base ordering, then add a smooth recency cost.
        // Very recent content moves far back; older favorites gradually become eligible.
        var scoredCandidates: [(prepared: PreparedTrack, rank: Double)] = []
        scoredCandidates.reserveCapacity(deduplicated.count)
        for prepared in deduplicated {
            let penalty = recencyPenalty(for: prepared, lookup: recency, now: now)
            scoredCandidates.append((prepared, Double(prepared.originalIndex) + penalty))
        }
        scoredCandidates.sort { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            return left.prepared.originalIndex < right.prepared.originalIndex
        }
        let recencyAdjusted = scoredCandidates.map(\.prepared)

        return artistSpaced(
            recencyAdjusted,
            limit: limit,
            artistGap: artistGap,
            recentArtistCounts: recentArtistCounts
        ).map(\.track)
    }

    private static func preparedCandidates(_ tracks: [Track]) -> [PreparedTrack] {
        var seenIDs: Set<String> = []
        var seenSignatures: Set<String> = []
        return tracks.enumerated().compactMap { index, track in
            let identifier = track.playbackKey
            guard seenIDs.insert(identifier).inserted else { return nil }
            let signature = RecommendationTrackIdentity.contentSignature(for: track)
            guard seenSignatures.insert(signature).inserted else { return nil }
            return PreparedTrack(
                track: track,
                identifier: identifier,
                signature: signature,
                artist: RecommendationTrackIdentity.artistKey(for: track),
                originalIndex: index
            )
        }
    }

    private static func artistSpaced(
        _ tracks: [PreparedTrack],
        limit: Int,
        artistGap: Int,
        recentArtistCounts: [String: Double]
    ) -> [PreparedTrack] {
        guard limit > 0, tracks.isEmpty == false else { return [] }

        let targetCount = min(limit, tracks.count)
        let maximumPerArtist = max(2, Int(ceil(Double(min(targetCount, 20)) * 0.2)))
        let gap = max(0, artistGap)
        var remaining = tracks
        var result: [PreparedTrack] = []
        var artistCounts: [String: Int] = [:]

        while result.count < targetCount, remaining.isEmpty == false {
            let recentArtists = Set(result.suffix(gap).map(\.artist))
            let eligibleIndices = remaining.indices.filter { index in
                let track = remaining[index]
                return recentArtists.contains(track.artist) == false
                    && artistCounts[track.artist, default: 0] < maximumPerArtist
            }
            let preferredIndex = eligibleIndices.min { lhs, rhs in
                let leftArtist = remaining[lhs].artist
                let rightArtist = remaining[rhs].artist
                let leftFatigue = recentArtistCounts[leftArtist, default: 0]
                let rightFatigue = recentArtistCounts[rightArtist, default: 0]
                return leftFatigue == rightFatigue ? lhs < rhs : leftFatigue < rightFatigue
            }
            let withinCapIndex = remaining.firstIndex {
                artistCounts[$0.artist, default: 0] < maximumPerArtist
            }
            let outsideGapIndex = remaining.firstIndex {
                recentArtists.contains($0.artist) == false
            }
            let index = preferredIndex ?? withinCapIndex ?? outsideGapIndex ?? remaining.startIndex
            let selected = remaining.remove(at: index)
            result.append(selected)
            artistCounts[selected.artist, default: 0] += 1
        }

        return result
    }

    private static func makeRecencyLookup(
        played: [Track],
        recommended: [Track],
        exposures: [RecommendationExposure]
    ) -> RecencyLookup {
        var lookup = RecencyLookup()
        for (index, track) in played.enumerated() {
            let signature = RecommendationTrackIdentity.contentSignature(for: track)
            if lookup.playedByID[track.playbackKey] == nil {
                lookup.playedByID[track.playbackKey] = index
            }
            if lookup.playedBySignature[signature] == nil {
                lookup.playedBySignature[signature] = index
            }
        }
        for (index, track) in recommended.enumerated() {
            let signature = RecommendationTrackIdentity.contentSignature(for: track)
            if lookup.recommendedByID[track.playbackKey] == nil {
                lookup.recommendedByID[track.playbackKey] = index
            }
            if lookup.recommendedBySignature[signature] == nil {
                lookup.recommendedBySignature[signature] = index
            }
        }
        for exposure in exposures {
            let track = exposure.track
            let signature = RecommendationTrackIdentity.contentSignature(for: track)
            if lookup.exposureByID[track.playbackKey] == nil {
                lookup.exposureByID[track.playbackKey] = exposure.shownAt
            }
            if lookup.exposureBySignature[signature] == nil {
                lookup.exposureBySignature[signature] = exposure.shownAt
            }
        }
        return lookup
    }

    private static func recencyPenalty(
        for track: PreparedTrack,
        lookup: RecencyLookup,
        now: Date
    ) -> Double {
        var penalty = 0.0

        if let index = minimum(
            lookup.playedByID[track.identifier],
            lookup.playedBySignature[track.signature]
        ) {
            penalty += max(8, 80 * exp(-Double(index) / 8))
        }
        if let index = minimum(
            lookup.recommendedByID[track.identifier],
            lookup.recommendedBySignature[track.signature]
        ) {
            penalty += max(5, 55 * exp(-Double(index) / 18))
        }
        if let shownAt = mostRecent(
            lookup.exposureByID[track.identifier],
            lookup.exposureBySignature[track.signature]
        ) {
            let ageHours = max(0, now.timeIntervalSince(shownAt) / 3_600)
            penalty += 70 * exp(-ageHours / (24 * 7))
        }
        return penalty
    }

    private static func minimum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (.some(left), .some(right)): min(left, right)
        case let (.some(left), .none): left
        case let (.none, .some(right)): right
        case (.none, .none): nil
        }
    }

    private static func mostRecent(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (.some(left), .some(right)): max(left, right)
        case let (.some(left), .none): left
        case let (.none, .some(right)): right
        case (.none, .none): nil
        }
    }
}

struct RecommendationRequest: Sendable {
    let candidates: [Track]
    let recentTracks: [Track]
    let likedTracks: [Track]
    let savedTracks: [Track]
    let recentlyRecommended: [Track]
    let recommendationExposures: [RecommendationExposure]
    let behaviorInsights: [TrackBehaviorInsight]
    let candidateSourcesByTrackID: [String: Set<RecommendationSeedFamily>]
    let dislikedTrackIDs: Set<String>
    let preferences: UserPreferenceProfile
    let focusedTrack: Track?
    let activeContext: ListeningContentContext?
    let activeQuranDomain: Bool?
    let sessionArtistAdjustments: [String: Double]
    let sessionSkippedTrackIDs: Set<String>
    let excludedTrackIDs: Set<String>
    let limit: Int

    init(
        candidates: [Track],
        recentTracks: [Track],
        likedTracks: [Track],
        savedTracks: [Track] = [],
        recentlyRecommended: [Track] = [],
        recommendationExposures: [RecommendationExposure] = [],
        behaviorInsights: [TrackBehaviorInsight] = [],
        candidateSourcesByTrackID: [String: Set<RecommendationSeedFamily>] = [:],
        dislikedTrackIDs: Set<String>,
        preferences: UserPreferenceProfile,
        focusedTrack: Track?,
        activeContext: ListeningContentContext? = nil,
        activeQuranDomain: Bool? = nil,
        sessionArtistAdjustments: [String: Double] = [:],
        sessionSkippedTrackIDs: Set<String> = [],
        excludedTrackIDs: Set<String> = [],
        limit: Int
    ) {
        self.candidates = candidates
        self.recentTracks = recentTracks
        self.likedTracks = likedTracks
        self.savedTracks = savedTracks
        self.recentlyRecommended = recentlyRecommended
        self.recommendationExposures = recommendationExposures
        self.behaviorInsights = behaviorInsights
        self.candidateSourcesByTrackID = candidateSourcesByTrackID
        self.dislikedTrackIDs = dislikedTrackIDs
        self.preferences = preferences
        self.focusedTrack = focusedTrack
        self.activeContext = activeContext
        self.activeQuranDomain = activeQuranDomain
        self.sessionArtistAdjustments = sessionArtistAdjustments
        self.sessionSkippedTrackIDs = sessionSkippedTrackIDs
        self.excludedTrackIDs = excludedTrackIDs
        self.limit = max(0, limit)
    }
}

actor RecommendationEngine {
    static let shared = RecommendationEngine()
    private struct CacheEntry {
        let tracks: [Track]
        let createdAt: Date
    }

    private struct RankedCandidate {
        let track: Track
        let total: Double
        let lane: RecommendationLane
        let ordinal: Int
    }

    private let weights = RecommendationScoringWeights.default
    private let resultCacheTTL: TimeInterval = 120
    private var resultCache: [Int: CacheEntry] = [:]

    func recommendations(for request: RecommendationRequest) -> [Track] {
        guard request.limit > 0 else { return [] }
        let key = cacheKey(for: request)
        if let cached = resultCache[key], Date().timeIntervalSince(cached.createdAt) < resultCacheTTL {
            return cached.tracks
        }

        let likedIDs = Set(request.likedTracks.map(\.playbackKey))
        let savedIDs = Set(request.savedTracks.map(\.playbackKey))
        let likedArtists = frequencyMap(request.likedTracks.map {
            RecommendationTrackIdentity.artistKey(for: $0)
        })
        let savedArtists = frequencyMap(request.savedTracks.map {
            RecommendationTrackIdentity.artistKey(for: $0)
        })
        let behaviorByTrackID = Dictionary(
            uniqueKeysWithValues: request.behaviorInsights.map { ($0.track.playbackKey, $0) }
        )
        let behaviorByArtist = Dictionary(grouping: request.behaviorInsights) {
            RecommendationTrackIdentity.artistKey(for: $0.track)
        }
        let behaviorScoreByArtist = behaviorByArtist.mapValues(artistBehaviorScore)
        let skipPenaltyByArtist = behaviorByArtist.mapValues { insights in
            min(7, Double(insights.reduce(0) { $0 + $1.skipCount }) * weights.artistSkip)
        }
        let preferenceTokens = Set(
            request.preferences.normalizedKeywords.flatMap { SearchTextNormalizer.tokens(from: $0) }
        )
        let hardRecentSignatures = Set(
            request.recentTracks.prefix(8).map(RecommendationTrackIdentity.contentSignature)
        )
        let artistFatigue = artistFatigueMap(for: request)
        let focusedArtistKey = request.focusedTrack.map {
            RecommendationTrackIdentity.artistKey(for: $0)
        }
        let focusedTitleTokens = Set(
            SearchTextNormalizer.tokens(from: request.focusedTrack?.title ?? "")
        )
        let exposureLookup = makeExposureLookup(request.recommendationExposures)
        let scoringDate = Date()

        var seenIDs = request.excludedTrackIDs
        var seenSignatures: Set<String> = []
        var ranked: [RankedCandidate] = []

        for (ordinal, track) in request.candidates.enumerated() {
            let id = track.playbackKey
            guard request.dislikedTrackIDs.contains(id) == false else { continue }
            guard seenIDs.insert(id).inserted else { continue }

            let signature = contentSignature(for: track)
            guard seenSignatures.insert(signature).inserted else { continue }
            guard hardRecentSignatures.contains(signature) == false else { continue }
            guard isContextCompatible(track, request: request) else {
                continue
            }

            let artistKey = RecommendationTrackIdentity.artistKey(for: track)
            let candidateTokens = Set(SearchTextNormalizer.tokens(from: "\(track.artist) \(track.title) \(track.tags.joined(separator: " "))"))
            let preferenceOverlap = preferenceTokens.intersection(candidateTokens).count
            let sources = request.candidateSourcesByTrackID[id, default: []]
            var score = Double(likedArtists[artistKey, default: 0]) * weights.likedArtist
            score += Double(savedArtists[artistKey, default: 0]) * weights.savedArtist
            score += Double(preferenceOverlap) * weights.preferenceToken
            score += sourcePrior(sources)

            if artistKey == focusedArtistKey {
                score += weights.focusedArtist
            }
            if focusedTitleTokens.isEmpty == false {
                score += Double(focusedTitleTokens.intersection(candidateTokens).count) * weights.focusedTitleToken
            }

            if let insight = behaviorByTrackID[id] {
                score += behaviorScore(insight)
            }
            score += behaviorScoreByArtist[artistKey, default: 0]
            score += request.sessionArtistAdjustments[artistKey, default: 0] * 8
            score -= artistFatigue[artistKey, default: 0] * weights.artistFatigue

            if request.sessionSkippedTrackIDs.contains(id) {
                score -= weights.exactRecentSkip
            }
            score -= skipPenaltyByArtist[artistKey, default: 0]
            if likedIDs.contains(id) || savedIDs.contains(id) {
                // Exact seeds belong in Listen Again/Favorites. They remain an eventual
                // fallback but do not crowd out discovery in Quick Picks.
                score -= weights.exactLikedOrSavedReplay
            }
            score -= exposurePenalty(
                for: track,
                lookup: exposureLookup,
                now: scoringDate
            )

            ranked.append(
                RankedCandidate(
                    track: track,
                    total: score,
                    lane: lane(
                        for: sources,
                        artistKey: artistKey,
                        focusedArtistKey: focusedArtistKey,
                        likedArtists: likedArtists,
                        savedArtists: savedArtists,
                        preferenceOverlap: preferenceOverlap
                    ),
                    ordinal: ordinal
                )
            )
        }

        let scoreRanked = ranked
            .sorted {
                if $0.total != $1.total { return $0.total > $1.total }
                return $0.ordinal < $1.ordinal
            }
        let tasteRanked = blendedLanes(scoreRanked, limit: max(request.limit * 2, request.limit))
        let result = RecommendationDiversityPolicy.diversified(
            tasteRanked,
            recentlyPlayed: request.recentTracks,
            recentlyRecommended: request.recentlyRecommended,
            recommendationExposures: request.recommendationExposures,
            limit: request.limit
        )
        resultCache[key] = CacheEntry(tracks: result, createdAt: Date())
        trimCacheIfNeeded()
        return result
    }

    private func behaviorScore(_ insight: TrackBehaviorInsight) -> Double {
        let positive = Double(insight.completedListenCount) * 2.4
            + Double(insight.repeatCount) * 1.2
            + insight.averageListenRatio * 1.6
        let negative = Double(insight.skipCount) * 2.8
        return positive - negative
    }

    private func artistBehaviorScore(_ insights: [TrackBehaviorInsight]) -> Double {
        let completions = insights.reduce(0) { $0 + $1.completedListenCount }
        let repeats = insights.reduce(0) { $0 + $1.repeatCount }
        return min(8, Double(completions) * weights.completedArtist)
            + min(5, Double(repeats) * weights.replayedArtist)
    }

    private func sourcePrior(_ sources: Set<RecommendationSeedFamily>) -> Double {
        sources.reduce(0) { score, source in
            switch source {
            case .likedSongs: score + weights.likedSeed
            case .savedSongs: score + weights.savedSeed
            case .completedListens: score + weights.completionSeed
            case .recentSearches: score + weights.searchSeed
            case .preferences: score + weights.preferenceSeed
            case .successfulDiscovery: score + weights.discoverySeed
            case .exploration: score + weights.explorationSeed
            case .focusedTrack: score + weights.focusedArtist
            case .topArtists: score + 0.9
            }
        }
    }

    private func lane(
        for sources: Set<RecommendationSeedFamily>,
        artistKey: String,
        focusedArtistKey: String?,
        likedArtists: [String: Int],
        savedArtists: [String: Int],
        preferenceOverlap: Int
    ) -> RecommendationLane {
        if sources.contains(.exploration) { return .exploration }
        if sources.contains(.successfulDiscovery)
            || sources.contains(.preferences)
            || sources.contains(.recentSearches) {
            return .discovery
        }
        if artistKey == focusedArtistKey
            || likedArtists[artistKey, default: 0] > 0
            || savedArtists[artistKey, default: 0] > 0
            || sources.contains(.likedSongs)
            || sources.contains(.savedSongs)
            || sources.contains(.completedListens)
            || sources.contains(.focusedTrack) {
            return .familiar
        }
        return preferenceOverlap > 0 ? .discovery : .exploration
    }

    private func blendedLanes(_ ranked: [RankedCandidate], limit: Int) -> [Track] {
        guard limit > 0 else { return [] }
        var familiar = ranked.filter { $0.lane == .familiar }
        var discovery = ranked.filter { $0.lane == .discovery }
        var exploration = ranked.filter { $0.lane == .exploration }
        let pattern: [RecommendationLane] = [
            .familiar, .familiar, .discovery, .familiar, .familiar,
            .exploration, .familiar, .discovery, .familiar, .discovery
        ]
        var result: [Track] = []

        while result.count < min(limit, ranked.count) {
            let preferredLane = pattern[result.count % pattern.count]
            let selected: RankedCandidate?
            switch preferredLane {
            case .familiar:
                selected = familiar.isEmpty ? (discovery.isEmpty ? exploration.removeFirstIfPresent() : discovery.removeFirst()) : familiar.removeFirst()
            case .discovery:
                selected = discovery.isEmpty ? (familiar.isEmpty ? exploration.removeFirstIfPresent() : familiar.removeFirst()) : discovery.removeFirst()
            case .exploration:
                selected = exploration.isEmpty ? (discovery.isEmpty ? familiar.removeFirstIfPresent() : discovery.removeFirst()) : exploration.removeFirst()
            }
            guard let selected else { break }
            result.append(selected.track)
        }
        return result
    }

    private func artistFatigueMap(for request: RecommendationRequest) -> [String: Double] {
        let tracks = Array(request.recentTracks.prefix(24))
            + request.recommendationExposures.prefix(24).map(\.track)
        return tracks.enumerated().reduce(into: [:]) { result, element in
            let decay = exp(-Double(element.offset) / 7)
            result[RecommendationTrackIdentity.artistKey(for: element.element), default: 0] += decay
        }
    }

    private struct ExposureLookup {
        var byID: [String: Date] = [:]
        var bySignature: [String: Date] = [:]
    }

    private func makeExposureLookup(_ exposures: [RecommendationExposure]) -> ExposureLookup {
        var lookup = ExposureLookup()
        for exposure in exposures {
            let identifier = exposure.track.playbackKey
            let signature = contentSignature(for: exposure.track)
            if lookup.byID[identifier] == nil {
                lookup.byID[identifier] = exposure.shownAt
            }
            if lookup.bySignature[signature] == nil {
                lookup.bySignature[signature] = exposure.shownAt
            }
        }
        return lookup
    }

    private func exposurePenalty(
        for track: Track,
        lookup: ExposureLookup,
        now: Date
    ) -> Double {
        let signature = contentSignature(for: track)
        let byID = lookup.byID[track.playbackKey]
        let bySignature = lookup.bySignature[signature]
        let shownAt: Date?
        switch (byID, bySignature) {
        case let (.some(left), .some(right)): shownAt = max(left, right)
        case let (.some(left), .none): shownAt = left
        case let (.none, .some(right)): shownAt = right
        case (.none, .none): shownAt = nil
        }
        guard let shownAt else { return 0 }
        let ageHours = max(0, now.timeIntervalSince(shownAt) / 3_600)
        return 12 * exp(-ageHours / (24 * 7))
    }

    private func frequencyMap(_ artists: [String]) -> [String: Int] {
        artists.reduce(into: [:]) { result, artist in
            guard artist.isEmpty == false else { return }
            result[artist, default: 0] += 1
        }
    }

    private func contentSignature(for track: Track) -> String {
        RecommendationTrackIdentity.contentSignature(for: track)
    }

    private func isContextCompatible(_ candidate: Track, request: RecommendationRequest) -> Bool {
        let quranDomain = request.activeQuranDomain ?? request.focusedTrack?.isQuranOrRecitation
        if let quranDomain, candidate.isQuranOrRecitation != quranDomain {
            return false
        }

        let focusedContext = request.activeContext ?? request.focusedTrack?.listeningContentContext
        guard let focusedContext, focusedContext != .unknown else { return true }
        let candidateContext = candidate.listeningContentContext
        return candidateContext == focusedContext
    }

    private func cacheKey(for request: RecommendationRequest) -> Int {
        var hasher = Hasher()
        func combineTracks(_ tracks: [Track], maximum: Int = 256) {
            hasher.combine(tracks.count)
            for track in tracks.prefix(maximum) {
                hasher.combine(track.playbackKey)
            }
        }

        combineTracks(request.candidates)
        combineTracks(request.recentTracks)
        combineTracks(request.likedTracks)
        combineTracks(request.savedTracks)
        combineTracks(request.recentlyRecommended)
        for exposure in request.recommendationExposures.prefix(160) {
            hasher.combine(exposure.track.playbackKey)
            hasher.combine(Int(exposure.shownAt.timeIntervalSince1970 / 3_600))
        }
        for insight in request.behaviorInsights.prefix(160) {
            hasher.combine(insight.track.playbackKey)
            hasher.combine(insight.playCount)
            hasher.combine(insight.repeatCount)
            hasher.combine(insight.skipCount)
            hasher.combine(insight.completedListenCount)
        }
        for key in request.candidateSourcesByTrackID.keys.sorted() {
            hasher.combine(key)
            for source in request.candidateSourcesByTrackID[key, default: []].sorted(by: { $0.rawValue < $1.rawValue }) {
                hasher.combine(source.rawValue)
            }
        }
        for value in request.dislikedTrackIDs.sorted() { hasher.combine(value) }
        for value in request.excludedTrackIDs.sorted() { hasher.combine(value) }
        for value in request.preferences.normalizedKeywords { hasher.combine(value) }
        hasher.combine(request.focusedTrack?.playbackKey)
        hasher.combine(request.activeContext?.rawValue)
        hasher.combine(request.activeQuranDomain)
        for key in request.sessionArtistAdjustments.keys.sorted() {
            hasher.combine(key)
            hasher.combine(request.sessionArtistAdjustments[key, default: 0])
        }
        for value in request.sessionSkippedTrackIDs.sorted() { hasher.combine(value) }
        hasher.combine(request.limit)
        return hasher.finalize()
    }

    private func trimCacheIfNeeded() {
        while resultCache.count > 32, let key = resultCache.keys.first {
            resultCache.removeValue(forKey: key)
        }
    }
}

private extension Array {
    mutating func removeFirstIfPresent() -> Element? {
        isEmpty ? nil : removeFirst()
    }
}

import Foundation

struct LocalMusicProfileSnapshot {
    let likedTracks: [Track]
    let recentTracks: [Track]
    let topTracks: [Track]
    let recentSearches: [String]

    var hasContent: Bool {
        likedTracks.isEmpty == false || recentTracks.isEmpty == false || topTracks.isEmpty == false
    }
}

final class LocalMusicProfileStore {
    static let shared = LocalMusicProfileStore()

    private struct StoredProfile: Codable {
        var likedTracks: [Track] = []
        var playRecords: [PlayRecord] = []
        var recentSearches: [String] = []

        enum CodingKeys: String, CodingKey {
            case likedTracks
            case playRecords
            case recentSearches
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            likedTracks = try container.decodeIfPresent([Track].self, forKey: .likedTracks) ?? []
            playRecords = try container.decodeIfPresent([PlayRecord].self, forKey: .playRecords) ?? []
            recentSearches = try container.decodeIfPresent([String].self, forKey: .recentSearches) ?? []
        }
    }

    private struct PlayRecord: Codable {
        var track: Track
        var playCount: Int
        var lastPlayedAt: Date
    }

    private actor PersistenceController {
        private let storageKey: String
        private let defaults: UserDefaults

        init(storageKey: String, defaults: UserDefaults) {
            self.storageKey = storageKey
            self.defaults = defaults
        }

        func persist(_ profiles: [String: StoredProfile]) {
            guard let data = try? JSONEncoder().encode(profiles) else { return }
            defaults.set(data, forKey: storageKey)
        }

        func clear() {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private let storageKey = "musictube.local.musicProfiles.v1"
    private let defaults: UserDefaults
    private let persistence: PersistenceController
    private var profiles: [String: StoredProfile]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.persistence = PersistenceController(
            storageKey: "musictube.local.musicProfiles.v1",
            defaults: defaults
        )

        if
            let data = defaults.data(forKey: storageKey),
            let decodedProfiles = try? JSONDecoder().decode([String: StoredProfile].self, from: data)
        {
            profiles = decodedProfiles
        } else {
            profiles = [:]
        }
    }

    func snapshot(for profileID: String) -> LocalMusicProfileSnapshot {
        snapshot(from: profiles[profileID] ?? StoredProfile())
    }

    @discardableResult
    func recordPlayback(of track: Track, for profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let identifier = trackIdentifier(track)
        let now = Date()

        if let existingIndex = profile.playRecords.firstIndex(where: { trackIdentifier($0.track) == identifier }) {
            profile.playRecords[existingIndex].track = track
            profile.playRecords[existingIndex].playCount += 1
            profile.playRecords[existingIndex].lastPlayedAt = now
        } else {
            profile.playRecords.append(
                PlayRecord(track: track, playCount: 1, lastPlayedAt: now)
            )
        }

        profile.playRecords.sort { lhs, rhs in
            if lhs.lastPlayedAt != rhs.lastPlayedAt {
                return lhs.lastPlayedAt > rhs.lastPlayedAt
            }
            return lhs.playCount > rhs.playCount
        }
        profile.playRecords = Array(profile.playRecords.prefix(100))
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func toggleLike(for track: Track, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let identifier = trackIdentifier(track)

        if let existingIndex = profile.likedTracks.firstIndex(where: { trackIdentifier($0) == identifier }) {
            profile.likedTracks.remove(at: existingIndex)
        } else {
            profile.likedTracks.insert(track, at: 0)
        }

        profile.likedTracks = deduplicatedTracks(profile.likedTracks).prefix(200).map { $0 }
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func setLike(_ isLiked: Bool, for track: Track, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let identifier = trackIdentifier(track)

        profile.likedTracks.removeAll { trackIdentifier($0) == identifier }
        if isLiked {
            profile.likedTracks.insert(track, at: 0)
        }

        profile.likedTracks = deduplicatedTracks(profile.likedTracks).prefix(200).map { $0 }
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    func isTrackLiked(_ track: Track, for profileID: String) -> Bool {
        let identifier = trackIdentifier(track)
        return profiles[profileID]?.likedTracks.contains(where: { trackIdentifier($0) == identifier }) ?? false
    }

    @discardableResult
    func recordSearch(_ query: String, for profileID: String) -> LocalMusicProfileSnapshot {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            return snapshot(for: profileID)
        }

        var profile = profiles[profileID] ?? StoredProfile()
        let normalizedQuery = normalizedSearchQuery(trimmedQuery)

        profile.recentSearches.removeAll { normalizedSearchQuery($0) == normalizedQuery }
        profile.recentSearches.insert(trimmedQuery, at: 0)
        profile.recentSearches = Array(profile.recentSearches.prefix(20))
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func removeRecentSearch(_ query: String, for profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let normalizedQuery = normalizedSearchQuery(query)
        profile.recentSearches.removeAll { normalizedSearchQuery($0) == normalizedQuery }
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    func clearAllData() {
        profiles = [:]
        Task(priority: .utility) { [persistence] in
            await persistence.clear()
        }
    }

    private func snapshot(from profile: StoredProfile) -> LocalMusicProfileSnapshot {
        let likedTracks = deduplicatedTracks(profile.likedTracks)
        let recentTracks = deduplicatedTracks(
            profile.playRecords
                .map(\.track)
        )
        let topTracks = deduplicatedTracks(
            profile.playRecords
                .sorted {
                    if $0.playCount != $1.playCount {
                        return $0.playCount > $1.playCount
                    }
                    return $0.lastPlayedAt > $1.lastPlayedAt
                }
                .map(\.track)
        )

        return LocalMusicProfileSnapshot(
            likedTracks: Array(likedTracks.prefix(100)),
            recentTracks: Array(recentTracks.prefix(100)),
            topTracks: Array(topTracks.prefix(100)),
            recentSearches: Array(
                profile.recentSearches
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                    .prefix(20)
            )
        )
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenIdentifiers: Set<String> = []
        return tracks.filter { track in
            seenIdentifiers.insert(trackIdentifier(track)).inserted
        }
    }

    private func trackIdentifier(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func normalizedSearchQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func persistProfiles() {
        let profiles = self.profiles
        Task(priority: .utility) { [persistence] in
            await persistence.persist(profiles)
        }
    }
}

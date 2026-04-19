import Foundation

struct CustomPlaylistRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var description: String
    var createdAt: Date
    var tracks: [Track]
}

struct LocalMusicProfileSnapshot {
    let likedTracks: [Track]
    let savedTracks: [Track]
    let savedCollections: [MusicCollection]
    let customPlaylists: [CustomPlaylistRecord]
    let recentTracks: [Track]
    let topTracks: [Track]
    let recentSearches: [String]
    let topArtists: [String]

    var hasContent: Bool {
        likedTracks.isEmpty == false ||
        savedTracks.isEmpty == false ||
        savedCollections.isEmpty == false ||
        customPlaylists.isEmpty == false ||
        recentTracks.isEmpty == false ||
        topTracks.isEmpty == false
    }
}

final class LocalMusicProfileStore {
    static let shared = LocalMusicProfileStore()

    private struct StoredProfile: Codable {
        var likedTracks: [Track] = []
        var savedTracks: [Track] = []
        var savedCollections: [MusicCollection] = []
        var customPlaylists: [CustomPlaylistRecord] = []
        var playRecords: [PlayRecord] = []
        var recentSearches: [String] = []

        enum CodingKeys: String, CodingKey {
            case likedTracks
            case savedTracks
            case savedCollections
            case customPlaylists
            case playRecords
            case recentSearches
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            likedTracks = try container.decodeIfPresent([Track].self, forKey: .likedTracks) ?? []
            savedTracks = try container.decodeIfPresent([Track].self, forKey: .savedTracks) ?? []
            savedCollections = try container.decodeIfPresent([MusicCollection].self, forKey: .savedCollections) ?? []
            customPlaylists = try container.decodeIfPresent([CustomPlaylistRecord].self, forKey: .customPlaylists) ?? []
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
        profile.playRecords = Array(profile.playRecords.prefix(120))
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func toggleLike(for track: Track, profileID: String) -> LocalMusicProfileSnapshot {
        setLike(isTrackLiked(track, for: profileID) == false, for: track, profileID: profileID)
    }

    @discardableResult
    func setLike(_ isLiked: Bool, for track: Track, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let identifier = trackIdentifier(track)

        profile.likedTracks.removeAll { trackIdentifier($0) == identifier }
        if isLiked {
            profile.likedTracks.insert(track, at: 0)
        }

        profile.likedTracks = Array(deduplicatedTracks(profile.likedTracks).prefix(200))
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func mergeLikedTracks(_ tracks: [Track], profileID: String) -> LocalMusicProfileSnapshot {
        guard tracks.isEmpty == false else {
            return snapshot(for: profileID)
        }

        var profile = profiles[profileID] ?? StoredProfile()
        profile.likedTracks = Array(deduplicatedTracks(tracks + profile.likedTracks).prefix(200))
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    func isTrackLiked(_ track: Track, for profileID: String) -> Bool {
        let identifier = trackIdentifier(track)
        return profiles[profileID]?.likedTracks.contains(where: { trackIdentifier($0) == identifier }) ?? false
    }

    @discardableResult
    func setTrackSaved(_ isSaved: Bool, for track: Track, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let identifier = trackIdentifier(track)

        profile.savedTracks.removeAll { trackIdentifier($0) == identifier }
        if isSaved {
            profile.savedTracks.insert(track, at: 0)
        }

        profile.savedTracks = Array(deduplicatedTracks(profile.savedTracks).prefix(400))
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    func isTrackSaved(_ track: Track, for profileID: String) -> Bool {
        let identifier = trackIdentifier(track)
        return profiles[profileID]?.savedTracks.contains(where: { trackIdentifier($0) == identifier }) ?? false
    }

    @discardableResult
    func setCollectionSaved(_ isSaved: Bool, for collection: MusicCollection, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        profile.savedCollections.removeAll { $0.id == collection.id }
        if isSaved {
            profile.savedCollections.insert(collection, at: 0)
        }

        profile.savedCollections = Array(deduplicatedCollections(profile.savedCollections).prefix(200))
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    func isCollectionSaved(_ collection: MusicCollection, for profileID: String) -> Bool {
        profiles[profileID]?.savedCollections.contains(where: { $0.id == collection.id }) ?? false
    }

    @discardableResult
    func createCustomPlaylist(
        named name: String,
        description: String = "",
        seedTrack: Track? = nil,
        profileID: String
    ) -> CustomPlaylistRecord? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return nil }

        var profile = profiles[profileID] ?? StoredProfile()
        var playlist = CustomPlaylistRecord(
            id: "local-user-playlist-\(UUID().uuidString)",
            title: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            tracks: []
        )

        if let seedTrack {
            playlist.tracks = [seedTrack]
        }

        profile.customPlaylists.insert(playlist, at: 0)
        profiles[profileID] = profile
        persistProfiles()
        return playlist
    }

    @discardableResult
    func addTrack(_ track: Track, toCustomPlaylist playlistID: String, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()

        if let playlistIndex = profile.customPlaylists.firstIndex(where: { $0.id == playlistID }) {
            var playlist = profile.customPlaylists[playlistIndex]
            let identifier = trackIdentifier(track)
            playlist.tracks.removeAll { trackIdentifier($0) == identifier }
            playlist.tracks.insert(track, at: 0)
            profile.customPlaylists[playlistIndex] = playlist
        }

        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func removeTrack(_ track: Track, fromCustomPlaylist playlistID: String, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()

        if let playlistIndex = profile.customPlaylists.firstIndex(where: { $0.id == playlistID }) {
            let identifier = trackIdentifier(track)
            profile.customPlaylists[playlistIndex].tracks.removeAll { trackIdentifier($0) == identifier }
        }

        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func renameCustomPlaylist(
        playlistID: String,
        to name: String,
        description: String? = nil,
        profileID: String
    ) -> LocalMusicProfileSnapshot {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else {
            return snapshot(for: profileID)
        }

        var profile = profiles[profileID] ?? StoredProfile()

        if let playlistIndex = profile.customPlaylists.firstIndex(where: { $0.id == playlistID }) {
            profile.customPlaylists[playlistIndex].title = trimmedName
            if let description {
                profile.customPlaylists[playlistIndex].description = description.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func deleteCustomPlaylist(_ playlistID: String, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        profile.customPlaylists.removeAll { $0.id == playlistID }
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
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
        let savedTracks = deduplicatedTracks(profile.savedTracks)
        let recentTracks = deduplicatedTracks(
            profile.playRecords
                .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
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
        let topArtists = orderedUniqueStrings(
            profile.playRecords
                .sorted {
                    if $0.playCount != $1.playCount {
                        return $0.playCount > $1.playCount
                    }
                    return $0.lastPlayedAt > $1.lastPlayedAt
                }
                .map(\.track.artist)
            + likedTracks.map(\.artist)
            + savedTracks.map(\.artist)
            + profile.savedCollections
                .filter { $0.kind == .artist }
                .map(\.title)
        )

        return LocalMusicProfileSnapshot(
            likedTracks: Array(likedTracks.prefix(100)),
            savedTracks: Array(savedTracks.prefix(200)),
            savedCollections: Array(deduplicatedCollections(profile.savedCollections).prefix(200)),
            customPlaylists: profile.customPlaylists.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            },
            recentTracks: Array(recentTracks.prefix(100)),
            topTracks: Array(topTracks.prefix(100)),
            recentSearches: Array(
                profile.recentSearches
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                    .prefix(20)
            ),
            topArtists: Array(topArtists.prefix(20))
        )
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenIdentifiers: Set<String> = []
        return tracks.filter { track in
            seenIdentifiers.insert(trackIdentifier(track)).inserted
        }
    }

    private func deduplicatedCollections(_ collections: [MusicCollection]) -> [MusicCollection] {
        var seenIdentifiers: Set<String> = []
        return collections.filter { collection in
            seenIdentifiers.insert(collection.id).inserted
        }
    }

    private func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
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

import Foundation

struct CustomPlaylistRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var description: String
    var createdAt: Date
    var tracks: [Track]
}

struct TrackBehaviorInsight: Codable, Hashable, Sendable {
    let track: Track
    let playCount: Int
    let repeatCount: Int
    let skipCount: Int
    let completedListenCount: Int
    let totalListenedDuration: TimeInterval
    let averageListenRatio: Double
    let lastInteractedAt: Date
}

enum UserPreferenceCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case genres
    case languages
    case artists
    case moods
    case activities
    case contentTypes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .genres: "Genres"
        case .languages: "Languages"
        case .artists: "Artists"
        case .moods: "Moods"
        case .activities: "Activities"
        case .contentTypes: "Content Types"
        }
    }
}

struct UserPreferenceTag: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var category: UserPreferenceCategory
    var isCustom: Bool
    var createdAt: Date

    init(
        id: String? = nil,
        name: String,
        category: UserPreferenceCategory,
        isCustom: Bool = false,
        createdAt: Date = Date()
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? "preference-\(category.rawValue)-\(SearchTextNormalizer.normalized(trimmedName))"
        self.name = trimmedName
        self.category = category
        self.isCustom = isCustom
        self.createdAt = createdAt
    }
}

struct UserPreferenceProfile: Codable, Hashable, Sendable {
    var hasCompletedOnboarding: Bool = false
    var selectedTags: [UserPreferenceTag] = []

    var normalizedKeywords: [String] {
        Self.orderedUniqueStrings(selectedTags.map(\.name))
    }

    var customTags: [UserPreferenceTag] {
        selectedTags.filter(\.isCustom)
    }

    static let empty = UserPreferenceProfile()

    static let defaultOptions: [UserPreferenceCategory: [UserPreferenceTag]] = [
        .genres: [
            "Pop", "Rock", "Hip-Hop", "R&B", "Jazz", "Classical", "Country",
            "Electronic", "LoFi", "Folk", "Oud", "Nasheeds"
        ].map { UserPreferenceTag(name: $0, category: .genres) },
        .languages: [
            "English", "Spanish", "Arabic", "French", "Turkish", "Hindi",
            "Korean", "Japanese", "Portuguese"
        ].map { UserPreferenceTag(name: $0, category: .languages) },
        .artists: [
            "New artists", "Local artists", "Classic artists", "Live performances",
            "Acoustic sessions"
        ].map { UserPreferenceTag(name: $0, category: .artists) },
        .moods: [
            "Happy", "Calm", "Focus", "Energetic", "Romantic", "Nostalgic",
            "Relaxation", "Sleep"
        ].map { UserPreferenceTag(name: $0, category: .moods) },
        .activities: [
            "Workout", "Driving", "Study", "Travel", "Cooking", "Coding",
            "Meditation", "Road Trip"
        ].map { UserPreferenceTag(name: $0, category: .activities) },
        .contentTypes: [
            "Music", "Podcasts", "Audiobooks", "Religious Content",
            "Educational Content", "Kids Content", "News", "Sports"
        ].map { UserPreferenceTag(name: $0, category: .contentTypes) }
    ]

    private static func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            let key = SearchTextNormalizer.normalized(trimmed)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

struct LocalMusicProfileSnapshot {
    let likedTracks: [Track]
    let savedTracks: [Track]
    let savedCollections: [MusicCollection]
    let customPlaylists: [CustomPlaylistRecord]
    let librarySectionOrder: [AppLibrarySection]
    let recentTracks: [Track]
    let topTracks: [Track]
    let substantiallyListenedTrackIDs: Set<String>
    let preferenceProfile: UserPreferenceProfile
    let recentSearches: [String]
    let topArtists: [String]
    let behaviorInsights: [TrackBehaviorInsight]

    var hasContent: Bool {
        likedTracks.isEmpty == false ||
        savedTracks.isEmpty == false ||
        savedCollections.isEmpty == false ||
        customPlaylists.isEmpty == false ||
        recentTracks.isEmpty == false ||
        topTracks.isEmpty == false ||
        behaviorInsights.isEmpty == false ||
        preferenceProfile.selectedTags.isEmpty == false
    }
}

protocol MusicProfileStoring: AnyObject {
    func snapshot(for profileID: String) -> LocalMusicProfileSnapshot
    func clearAllData()
    func recordPlayback(of track: Track, for profileID: String) -> LocalMusicProfileSnapshot
    func recordListeningBehavior(
        for track: Track,
        listenedSeconds: TimeInterval,
        trackDuration: TimeInterval?,
        skipped: Bool,
        profileID: String
    ) -> LocalMusicProfileSnapshot
    func setLike(_ isLiked: Bool, for track: Track, profileID: String) -> LocalMusicProfileSnapshot
    func mergeLikedTracks(_ tracks: [Track], profileID: String) -> LocalMusicProfileSnapshot
    /// Removes all liked tracks for a profile (called on account sign-out so
    /// account-synced songs don't bleed into guest mode).
    func clearAccountLikedTracks(profileID: String)
    func setTrackSaved(_ isSaved: Bool, for track: Track, profileID: String) -> LocalMusicProfileSnapshot
    func setCollectionSaved(_ isSaved: Bool, for collection: MusicCollection, profileID: String) -> LocalMusicProfileSnapshot
    func recordSearch(_ query: String, for profileID: String) -> LocalMusicProfileSnapshot
    func removeRecentSearch(_ query: String, for profileID: String) -> LocalMusicProfileSnapshot
    func removeRecentTrack(_ track: Track, profileID: String) -> LocalMusicProfileSnapshot
    func clearRecentTracks(profileID: String) -> LocalMusicProfileSnapshot
    func setLibrarySectionOrder(_ order: [AppLibrarySection], profileID: String) -> LocalMusicProfileSnapshot
    func setPreferenceProfile(_ preferences: UserPreferenceProfile, profileID: String) -> LocalMusicProfileSnapshot
    func addCustomPreference(_ name: String, category: UserPreferenceCategory, profileID: String) -> LocalMusicProfileSnapshot
    func updateCustomPreference(_ preferenceID: String, name: String, category: UserPreferenceCategory, profileID: String) -> LocalMusicProfileSnapshot
    func removePreference(_ preferenceID: String, profileID: String) -> LocalMusicProfileSnapshot
    func createCustomPlaylist(
        named name: String,
        description: String,
        seedTrack: Track?,
        profileID: String
    ) -> CustomPlaylistRecord?
    func addTrack(_ track: Track, toCustomPlaylist playlistID: String, profileID: String) -> LocalMusicProfileSnapshot
    func removeTrack(_ track: Track, fromCustomPlaylist playlistID: String, profileID: String) -> LocalMusicProfileSnapshot
    func renameCustomPlaylist(
        playlistID: String,
        to name: String,
        description: String?,
        profileID: String
    ) -> LocalMusicProfileSnapshot
    func deleteCustomPlaylist(_ playlistID: String, profileID: String) -> LocalMusicProfileSnapshot
}

final class LocalMusicProfileStore: MusicProfileStoring {
    static let shared = LocalMusicProfileStore()
    private let maxStoredLikedTracks = 5_000

    private struct StoredProfile: Codable {
        var likedTracks: [Track] = []
        var savedTracks: [Track] = []
        var savedCollections: [MusicCollection] = []
        var customPlaylists: [CustomPlaylistRecord] = []
        var librarySectionOrder: [String] = []
        var playRecords: [PlayRecord] = []
        var recentSearches: [String] = []
        var preferenceProfile: UserPreferenceProfile = .empty

        enum CodingKeys: String, CodingKey {
            case likedTracks
            case savedTracks
            case savedCollections
            case customPlaylists
            case librarySectionOrder
            case playRecords
            case recentSearches
            case preferenceProfile
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            likedTracks = try container.decodeIfPresent([Track].self, forKey: .likedTracks) ?? []
            savedTracks = try container.decodeIfPresent([Track].self, forKey: .savedTracks) ?? []
            savedCollections = try container.decodeIfPresent([MusicCollection].self, forKey: .savedCollections) ?? []
            customPlaylists = try container.decodeIfPresent([CustomPlaylistRecord].self, forKey: .customPlaylists) ?? []
            librarySectionOrder = try container.decodeIfPresent([String].self, forKey: .librarySectionOrder) ?? []
            playRecords = try container.decodeIfPresent([PlayRecord].self, forKey: .playRecords) ?? []
            recentSearches = try container.decodeIfPresent([String].self, forKey: .recentSearches) ?? []
            preferenceProfile = try container.decodeIfPresent(UserPreferenceProfile.self, forKey: .preferenceProfile) ?? .empty
        }
    }

    private struct PlayRecord: Codable {
        var track: Track
        var playCount: Int
        var lastPlayedAt: Date
        var skipCount: Int
        var totalListenedDuration: TimeInterval
        var totalCompletedDuration: TimeInterval
        var completedListenCount: Int

        enum CodingKeys: String, CodingKey {
            case track
            case playCount
            case lastPlayedAt
            case skipCount
            case totalListenedDuration
            case totalCompletedDuration
            case completedListenCount
        }

        init(
            track: Track,
            playCount: Int,
            lastPlayedAt: Date,
            skipCount: Int = 0,
            totalListenedDuration: TimeInterval = 0,
            totalCompletedDuration: TimeInterval = 0,
            completedListenCount: Int = 0
        ) {
            self.track = track
            self.playCount = playCount
            self.lastPlayedAt = lastPlayedAt
            self.skipCount = skipCount
            self.totalListenedDuration = totalListenedDuration
            self.totalCompletedDuration = totalCompletedDuration
            self.completedListenCount = completedListenCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            track = try container.decode(Track.self, forKey: .track)
            playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
            lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt) ?? .distantPast
            skipCount = try container.decodeIfPresent(Int.self, forKey: .skipCount) ?? 0
            totalListenedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .totalListenedDuration) ?? 0
            totalCompletedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .totalCompletedDuration) ?? 0
            completedListenCount = try container.decodeIfPresent(Int.self, forKey: .completedListenCount) ?? 0
        }
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
    func recordListeningBehavior(
        for track: Track,
        listenedSeconds: TimeInterval,
        trackDuration: TimeInterval?,
        skipped: Bool,
        profileID: String
    ) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let identifier = trackIdentifier(track)
        let sanitizedListenDuration = max(0, listenedSeconds)
        let completionThreshold = max(30, (trackDuration ?? track.duration ?? 0) * 0.8)

        guard let existingIndex = profile.playRecords.firstIndex(where: { trackIdentifier($0.track) == identifier }) else {
            return snapshot(from: profile)
        }

        profile.playRecords[existingIndex].track = track
        profile.playRecords[existingIndex].totalListenedDuration += sanitizedListenDuration
        if skipped {
            profile.playRecords[existingIndex].skipCount += 1
        }
        if sanitizedListenDuration >= completionThreshold {
            profile.playRecords[existingIndex].completedListenCount += 1
            profile.playRecords[existingIndex].totalCompletedDuration += sanitizedListenDuration
        }

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
        if isLiked, track.isEligibleForLikedSongs {
            profile.likedTracks.insert(track, at: 0)
        }

        profile.likedTracks = Array(
            deduplicatedTracks(profile.likedTracks.likedSongsOnly()).prefix(maxStoredLikedTracks)
        )
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func mergeLikedTracks(_ tracks: [Track], profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        
        // Always merge and deduplicate, even if incoming tracks are empty
        // This ensures account tracks are merged with local tracks
        let mergedTracks = deduplicatedTracks(
            tracks.likedSongsOnly() + profile.likedTracks.likedSongsOnly()
        )
        profile.likedTracks = Array(mergedTracks.prefix(maxStoredLikedTracks))
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    func clearAccountLikedTracks(profileID: String) {
        var profile = profiles[profileID] ?? StoredProfile()
        profile.likedTracks = []
        profiles[profileID] = profile
        persistProfiles()
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

    @discardableResult
    func removeRecentTrack(_ track: Track, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let identifier = trackIdentifier(track)
        profile.playRecords.removeAll { trackIdentifier($0.track) == identifier }
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func clearRecentTracks(profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        profile.playRecords.removeAll()
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func setLibrarySectionOrder(_ order: [AppLibrarySection], profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        profile.librarySectionOrder = AppLibrarySection
            .normalizedOrder(from: order.map(\.rawValue))
            .map(\.rawValue)
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func setPreferenceProfile(_ preferences: UserPreferenceProfile, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        profile.preferenceProfile = normalizedPreferenceProfile(preferences)
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func addCustomPreference(
        _ name: String,
        category: UserPreferenceCategory,
        profileID: String
    ) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return snapshot(from: profile) }

        let newTag = UserPreferenceTag(
            id: "custom-preference-\(UUID().uuidString)",
            name: trimmedName,
            category: category,
            isCustom: true
        )
        profile.preferenceProfile.selectedTags.append(newTag)
        profile.preferenceProfile.hasCompletedOnboarding = true
        profile.preferenceProfile = normalizedPreferenceProfile(profile.preferenceProfile)
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func updateCustomPreference(
        _ preferenceID: String,
        name: String,
        category: UserPreferenceCategory,
        profileID: String
    ) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return snapshot(from: profile) }

        if let index = profile.preferenceProfile.selectedTags.firstIndex(where: { $0.id == preferenceID && $0.isCustom }) {
            profile.preferenceProfile.selectedTags[index].name = trimmedName
            profile.preferenceProfile.selectedTags[index].category = category
        }
        profile.preferenceProfile = normalizedPreferenceProfile(profile.preferenceProfile)
        profiles[profileID] = profile
        persistProfiles()
        return snapshot(from: profile)
    }

    @discardableResult
    func removePreference(_ preferenceID: String, profileID: String) -> LocalMusicProfileSnapshot {
        var profile = profiles[profileID] ?? StoredProfile()
        profile.preferenceProfile.selectedTags.removeAll { $0.id == preferenceID }
        profile.preferenceProfile = normalizedPreferenceProfile(profile.preferenceProfile)
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
        let likedTracks = deduplicatedTracks(profile.likedTracks.likedSongsOnly())
        let savedTracks = deduplicatedTracks(profile.savedTracks)
        let recentTracks = deduplicatedTracks(
            profile.playRecords
                .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
                .map(\.track)
        )
        let topTracks = deduplicatedTracks(
            profile.playRecords
                .sorted { lhs, rhs in
                    let lhsScore = listeningAffinityScore(lhs)
                    let rhsScore = listeningAffinityScore(rhs)
                    if lhsScore != rhsScore {
                        return lhsScore > rhsScore
                    }
                    return lhs.lastPlayedAt > rhs.lastPlayedAt
                }
                .map(\.track)
        )
        var artistScores: [String: (displayName: String, score: Double, lastPlayedAt: Date)] = [:]
        for record in profile.playRecords {
            let normalizedArtist = normalizedSearchQuery(record.track.artist)
            guard normalizedArtist.isEmpty == false else { continue }
            let previous = artistScores[normalizedArtist]
            artistScores[normalizedArtist] = (
                displayName: previous?.displayName ?? record.track.artist,
                score: (previous?.score ?? 0) + listeningAffinityScore(record),
                lastPlayedAt: max(previous?.lastPlayedAt ?? .distantPast, record.lastPlayedAt)
            )
        }
        for track in likedTracks + savedTracks {
            let normalizedArtist = normalizedSearchQuery(track.artist)
            guard normalizedArtist.isEmpty == false else { continue }
            let previous = artistScores[normalizedArtist]
            artistScores[normalizedArtist] = (
                displayName: previous?.displayName ?? track.artist,
                score: (previous?.score ?? 0) + 4,
                lastPlayedAt: previous?.lastPlayedAt ?? .distantPast
            )
        }
        for collection in profile.savedCollections where collection.kind == .artist {
            let normalizedArtist = normalizedSearchQuery(collection.title)
            guard normalizedArtist.isEmpty == false else { continue }
            let previous = artistScores[normalizedArtist]
            artistScores[normalizedArtist] = (
                displayName: previous?.displayName ?? collection.title,
                score: (previous?.score ?? 0) + 5,
                lastPlayedAt: previous?.lastPlayedAt ?? .distantPast
            )
        }
        let topArtists = artistScores.values
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.lastPlayedAt > $1.lastPlayedAt
            }
            .map(\.displayName)
        let behaviorInsights = profile.playRecords
            .sorted {
                if $0.lastPlayedAt != $1.lastPlayedAt {
                    return $0.lastPlayedAt > $1.lastPlayedAt
                }
                return $0.playCount > $1.playCount
            }
            .map { record in
                let candidateDuration = record.track.duration ?? 0
                let averageListenRatio: Double
                if record.playCount > 0, candidateDuration > 0 {
                    averageListenRatio = min(1, (record.totalListenedDuration / Double(record.playCount)) / candidateDuration)
                } else {
                    averageListenRatio = 0
                }

                return TrackBehaviorInsight(
                    track: record.track,
                    playCount: record.playCount,
                    repeatCount: max(0, record.playCount - 1),
                    skipCount: record.skipCount,
                    completedListenCount: record.completedListenCount,
                    totalListenedDuration: record.totalListenedDuration,
                    averageListenRatio: averageListenRatio,
                    lastInteractedAt: record.lastPlayedAt
                )
            }
        let substantiallyListenedTrackIDs = Set(
            behaviorInsights.compactMap { insight -> String? in
                let listenedLongEnough = insight.totalListenedDuration >= 30
                let completedEnough = insight.completedListenCount > 0 || insight.averageListenRatio >= 0.8
                return listenedLongEnough || completedEnough ? trackIdentifier(insight.track) : nil
            }
        )

        return LocalMusicProfileSnapshot(
            likedTracks: Array(likedTracks.prefix(maxStoredLikedTracks)),
            savedTracks: Array(savedTracks.prefix(200)),
            savedCollections: Array(deduplicatedCollections(profile.savedCollections).prefix(200)),
            customPlaylists: profile.customPlaylists.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            },
            librarySectionOrder: AppLibrarySection.normalizedOrder(from: profile.librarySectionOrder),
            recentTracks: Array(recentTracks.prefix(100)),
            topTracks: Array(topTracks.prefix(100)),
            substantiallyListenedTrackIDs: substantiallyListenedTrackIDs,
            preferenceProfile: normalizedPreferenceProfile(profile.preferenceProfile),
            recentSearches: Array(
                profile.recentSearches
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                    .prefix(20)
            ),
            topArtists: Array(topArtists.prefix(20)),
            behaviorInsights: Array(behaviorInsights.prefix(120))
        )
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenIdentifiers: Set<String> = []
        return tracks.filter { track in
            seenIdentifiers.insert(trackIdentifier(track)).inserted
        }
    }

    private func listeningAffinityScore(_ record: PlayRecord) -> Double {
        let duration = record.track.duration ?? 0
        let averageListenRatio: Double
        if record.playCount > 0, duration > 0 {
            averageListenRatio = min(1, (record.totalListenedDuration / Double(record.playCount)) / duration)
        } else {
            averageListenRatio = 0
        }

        let recencyDays = max(0, Date().timeIntervalSince(record.lastPlayedAt) / 86_400)
        let recencyBoost = max(0, 1.5 - (recencyDays * 0.08))
        let completionBoost = Double(record.completedListenCount) * 3.0
        let listenQualityBoost = averageListenRatio * 2.5
        let playBoost = min(4.0, Double(record.playCount) * 0.7)
        let skipPenalty = min(5.0, Double(record.skipCount) * 1.4)

        return max(0, playBoost + completionBoost + listenQualityBoost + recencyBoost - skipPenalty)
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
            let key = SearchTextNormalizer.normalized(trimmed)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private func normalizedPreferenceProfile(_ preferences: UserPreferenceProfile) -> UserPreferenceProfile {
        var seen: Set<String> = []
        let normalizedTags = preferences.selectedTags.compactMap { tag -> UserPreferenceTag? in
            let trimmedName = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedName.isEmpty == false else { return nil }
            let key = "\(tag.category.rawValue):\(SearchTextNormalizer.normalized(trimmedName))"
            guard seen.insert(key).inserted else { return nil }
            var normalized = tag
            normalized.name = trimmedName
            return normalized
        }
        return UserPreferenceProfile(
            hasCompletedOnboarding: preferences.hasCompletedOnboarding,
            selectedTags: Array(normalizedTags.prefix(80))
        )
    }

    private func trackIdentifier(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func normalizedSearchQuery(_ query: String) -> String {
        SearchTextNormalizer.normalized(query)
    }

    private func persistProfiles() {
        let profiles = self.profiles
        Task(priority: .utility) { [persistence] in
            await persistence.persist(profiles)
        }
    }
}

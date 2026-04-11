import Foundation

final class YouTubeAPIService: MusicCatalogProviding {
    enum APIError: LocalizedError {
        case serviceError(String)

        var errorDescription: String? {
            switch self {
            case .serviceError(let message):
                return message
            }
        }
    }

    private let urlSession: URLSession
    private let apiKey: String?
    private let likedMusicPlaylistID = "liked-music"

    init(urlSession: URLSession = .shared, apiKey: String? = Bundle.main.object(forInfoDictionaryKey: "YOUTUBE_API_KEY") as? String) {
        self.urlSession = urlSession
        self.apiKey = apiKey
    }

    func loadHome(accessToken: String) async throws -> (featured: [Track], recent: [Track]) {
        await loadAuthorizedHome(accessToken: accessToken)
    }

    func search(query: String, accessToken: String) async throws -> [Track] {
        guard let apiKey = validatedAPIKey else {
            return []
        }

        do {
            return try await fetchSearchResults(
                query: query,
                apiKey: apiKey,
                maxResults: 25
            )
        } catch {
            return []
        }
    }

    func loadPlaylists(accessToken: String) async throws -> [Playlist] {
        let related = try? await fetchRelatedPlaylists(accessToken: accessToken)
        async let collections = fetchSystemCollections(related: related, accessToken: accessToken)
        async let userPlaylists = fetchUserPlaylists(accessToken: accessToken)

        let resolvedCollections = (try? await collections) ?? []
        let resolvedUserPlaylists = (try? await userPlaylists) ?? []
        var resolvedPlaylists = resolvedCollections + resolvedUserPlaylists

        if resolvedPlaylists.contains(where: { $0.kind == .likedMusic }) == false,
           let fallbackLikedMusicPlaylist = try? await fetchLikedMusicPlaylist(accessToken: accessToken) {
            resolvedPlaylists.insert(fallbackLikedMusicPlaylist, at: 0)
        }

        return deduplicatedPlaylists(resolvedPlaylists)
    }

    private func loadAuthorizedHome(accessToken: String) async -> (featured: [Track], recent: [Track]) {
        async let likedTracksTask = fetchLikedMusicTracks(accessToken: accessToken, maxItems: 50)
        async let userPlaylistsTask = fetchUserPlaylists(accessToken: accessToken)

        let likedTracks = (try? await likedTracksTask) ?? []
        let userPlaylists = (try? await userPlaylistsTask) ?? []
        let mixAlbums = userPlaylists.mixAlbumCandidates(limit: 4)
        let tracksByPlaylist = await fetchTracks(
            for: mixAlbums,
            accessToken: accessToken,
            maxItemsPerPlaylist: 20
        )

        let mixTracks = mixAlbums.flatMap { tracksByPlaylist[$0.id] ?? [] }
        let featured = Array(deduplicatedTracks(likedTracks + mixTracks).prefix(25))
        let recent = Array(deduplicatedTracks(mixTracks + likedTracks).prefix(15))

        return (featured, recent)
    }

    private func fetchUserPlaylists(accessToken: String) async throws -> [Playlist] {
        var playlists: [Playlist] = []
        var nextPageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlists")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "maxResults", value: "50")
            ]

            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }

            components.queryItems = authorizedQueryItems(queryItems)

            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            let (data, urlResponse) = try await urlSession.data(for: request)
            let response = try decodeResponse(PlaylistSearchResponse.self, from: data, response: urlResponse)

            playlists.append(contentsOf: response.items.map(playlist(from:)))
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && playlists.count < 200

        return playlists
    }

    private func fetchSystemCollections(related: RelatedPlaylists?, accessToken: String) async throws -> [Playlist] {
        guard let related else {
            return []
        }

        let playlistIDs = [related.likes, related.uploads].compactMap { $0 }
        guard playlistIDs.isEmpty == false else {
            return []
        }

        let playlists = try await fetchPlaylists(ids: playlistIDs, accessToken: accessToken)
        let order = Dictionary(uniqueKeysWithValues: playlistIDs.enumerated().map { ($1, $0) })

        return playlists
            .map { playlist in
                if playlist.id == related.likes {
                    return Playlist(
                        id: playlist.id,
                        title: "Liked songs",
                        description: "Music-only items from your likes",
                        artworkURL: playlist.artworkURL,
                        itemCount: playlist.itemCount,
                        kind: .likedMusic
                    )
                }

                if playlist.id == related.uploads {
                    return Playlist(
                        id: playlist.id,
                        title: "Uploads",
                        description: playlist.description,
                        artworkURL: playlist.artworkURL,
                        itemCount: playlist.itemCount,
                        kind: .uploads
                    )
                }

                return playlist
            }
            .sorted { lhs, rhs in
                order[lhs.id, default: .max] < order[rhs.id, default: .max]
            }
    }

    private func fetchPlaylists(ids: [String], accessToken: String) async throws -> [Playlist] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlists")!
        components.queryItems = authorizedQueryItems(
            [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "id", value: ids.joined(separator: ",")),
                URLQueryItem(name: "maxResults", value: String(ids.count))
            ]
        )

        let request = authorizedRequest(url: components.url!, accessToken: accessToken)
        let (data, urlResponse) = try await urlSession.data(for: request)
        let response = try decodeResponse(PlaylistSearchResponse.self, from: data, response: urlResponse)
        return response.items.map(playlist(from:))
    }

    func loadPlaylistItems(for playlist: Playlist, accessToken: String) async throws -> [Track] {
        if playlist.kind == .likedMusic {
            do {
                return try await fetchLikedMusicTracks(accessToken: accessToken, maxItems: 200)
            } catch {
                guard playlist.id != likedMusicPlaylistID else {
                    throw error
                }

                let fallbackTracks = try await fetchPlaylistItems(
                    for: playlist,
                    accessToken: accessToken,
                    maxItems: 200
                )

                return (try? await filterMusicTracks(fallbackTracks, accessToken: accessToken)) ?? fallbackTracks
            }
        }

        return try await fetchPlaylistItems(
            for: playlist,
            accessToken: accessToken,
            maxItems: 200
        )
    }

    private func fetchMostPopularMusic(apiKey: String) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "chart", value: "mostPopular"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "regionCode", value: "US"),
            URLQueryItem(name: "maxResults", value: "25"),
            URLQueryItem(name: "key", value: apiKey)
        ]

        let (data, urlResponse) = try await urlSession.data(from: components.url!)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)

        return response.items.compactMap { item in
            guard let videoID = item.id.videoID ?? item.id.raw else { return nil }
            return Track(
                id: videoID,
                title: item.snippet.title,
                artist: item.snippet.channelTitle,
                artworkURL: item.snippet.thumbnails.bestURL,
                youtubeVideoID: videoID
            )
        }
    }

    private func fetchSearchResults(query: String, apiKey: String, maxResults: Int) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "key", value: apiKey)
        ]

        let (data, urlResponse) = try await urlSession.data(from: components.url!)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)

        return response.items.compactMap { item in
            guard let videoID = item.id.videoID ?? item.id.raw else { return nil }
            return Track(
                id: videoID,
                title: item.snippet.title,
                artist: item.snippet.channelTitle,
                artworkURL: item.snippet.thumbnails.bestURL,
                youtubeVideoID: videoID
            )
        }
    }

    private func fetchPersonalizedMusic(seedTracks: [Track], apiKey: String) async throws -> [Track] {
        guard seedTracks.isEmpty == false else {
            return try await fetchMostPopularMusic(apiKey: apiKey)
        }
        let seedArtists = Array(orderedUniqueStrings(seedTracks.map(\.artist)).prefix(4))

        guard seedArtists.isEmpty == false else {
            return try await fetchMostPopularMusic(apiKey: apiKey)
        }

        let excludedIDs = Set(seedTracks.compactMap(\.youtubeVideoID))
        var recommendations: [Track] = []

        for artist in seedArtists {
            let query = "\(artist) official audio"
            let results = try await fetchSearchResults(query: query, apiKey: apiKey, maxResults: 8)
            recommendations.append(contentsOf: results.filter { track in
                guard let videoID = track.youtubeVideoID else { return true }
                return excludedIDs.contains(videoID) == false
            })
        }

        let deduped = deduplicatedTracks(recommendations)
        if deduped.isEmpty {
            return try await fetchMostPopularMusic(apiKey: apiKey)
        }

        return Array(deduped.prefix(25))
    }

    private func fetchRelatedPlaylists(accessToken: String) async throws -> RelatedPlaylists? {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = authorizedQueryItems(
            [
                URLQueryItem(name: "part", value: "contentDetails"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "maxResults", value: "1")
            ]
        )

        let request = authorizedRequest(url: components.url!, accessToken: accessToken)
        let (data, urlResponse) = try await urlSession.data(for: request)
        let response = try decodeResponse(ChannelSearchResponse.self, from: data, response: urlResponse)
        return response.items.first?.contentDetails?.relatedPlaylists
    }

    private func filterMusicTracks(_ tracks: [Track], accessToken: String) async throws -> [Track] {
        let videoIDs = tracks.compactMap(\.youtubeVideoID)
        guard videoIDs.isEmpty == false else {
            return []
        }

        var musicVideoIDs: Set<String> = []

        for batch in videoIDs.chunked(into: 50) {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
            components.queryItems = authorizedQueryItems(
                [
                    URLQueryItem(name: "part", value: "snippet"),
                    URLQueryItem(name: "id", value: batch.joined(separator: ",")),
                    URLQueryItem(name: "maxResults", value: String(batch.count))
                ]
            )

            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            let (data, urlResponse) = try await urlSession.data(for: request)
            let response = try decodeResponse(VideoMetadataResponse.self, from: data, response: urlResponse)

            for item in response.items where item.snippet.categoryID == "10" {
                musicVideoIDs.insert(item.id)
            }
        }

        return tracks.filter { track in
            guard let videoID = track.youtubeVideoID else { return false }
            return musicVideoIDs.contains(videoID)
        }
    }

    private var validatedAPIKey: String? {
        guard let apiKey, apiKey.isEmpty == false, apiKey.hasPrefix("YOUR_") == false else {
            return nil
        }
        return apiKey
    }

    private func authorizedQueryItems(_ items: [URLQueryItem]) -> [URLQueryItem] {
        items
    }

    private func playlist(from item: PlaylistItem) -> Playlist {
        Playlist(
            id: item.id,
            title: item.snippet.title,
            description: item.snippet.description ?? "",
            artworkURL: item.snippet.thumbnails?.bestURL,
            itemCount: item.contentDetails?.itemCount ?? 0,
            kind: .standard
        )
    }

    private func track(from item: VideoItem) -> Track? {
        guard let videoID = item.id.videoID ?? item.id.raw else { return nil }

        return Track(
            id: videoID,
            title: item.snippet.title,
            artist: item.snippet.channelTitle,
            artworkURL: item.snippet.thumbnails.bestURL,
            youtubeVideoID: videoID
        )
    }

    private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func fetchLikedMusicPlaylist(accessToken: String) async throws -> Playlist? {
        let likedTracks = try await fetchLikedMusicTracks(accessToken: accessToken, maxItems: 12)
        guard likedTracks.isEmpty == false else { return nil }

        return Playlist(
            id: likedMusicPlaylistID,
            title: "Liked songs",
            description: "Music-only items from your likes",
            artworkURL: likedTracks.first?.artworkURL,
            itemCount: likedTracks.count,
            kind: .likedMusic
        )
    }

    private func fetchLikedMusicTracks(accessToken: String, maxItems: Int) async throws -> [Track] {
        var tracks: [Track] = []
        var nextPageToken: String?
        var requiresMusicFiltering = false

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "myRating", value: "like"),
                URLQueryItem(name: "maxResults", value: "50")
            ]

            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }

            components.queryItems = authorizedQueryItems(queryItems)

            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            let (data, urlResponse) = try await urlSession.data(for: request)
            let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)

            let pageTracks = response.items.compactMap { item -> Track? in
                if let categoryID = item.snippet.categoryID {
                    guard categoryID == "10" else { return nil }
                } else {
                    requiresMusicFiltering = true
                }

                return track(from: item)
            }

            tracks.append(contentsOf: pageTracks)
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && tracks.count < maxItems

        let dedupedTracks = Array(deduplicatedTracks(tracks).prefix(maxItems))

        if requiresMusicFiltering {
            return (try? await filterMusicTracks(dedupedTracks, accessToken: accessToken)) ?? dedupedTracks
        }

        return dedupedTracks
    }

    private func fetchTracks(
        for playlists: [Playlist],
        accessToken: String,
        maxItemsPerPlaylist: Int
    ) async -> [String: [Track]] {
        await withTaskGroup(of: (String, [Track]).self) { group in
            for playlist in playlists {
                group.addTask { [self] in
                    let tracks = (try? await fetchPlaylistItems(
                        for: playlist,
                        accessToken: accessToken,
                        maxItems: maxItemsPerPlaylist
                    )) ?? []
                    return (playlist.id, tracks)
                }
            }

            var tracksByPlaylist: [String: [Track]] = [:]
            for await (playlistID, tracks) in group {
                tracksByPlaylist[playlistID] = tracks
            }

            return tracksByPlaylist
        }
    }

    private func fetchPlaylistItems(
        for playlist: Playlist,
        accessToken: String,
        maxItems: Int
    ) async throws -> [Track] {
        var entries: [PlaylistEntry] = []
        var nextPageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "playlistId", value: playlist.id),
                URLQueryItem(name: "maxResults", value: "50")
            ]

            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }

            components.queryItems = authorizedQueryItems(queryItems)

            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            let (data, urlResponse) = try await urlSession.data(for: request)
            let response = try decodeResponse(PlaylistItemsResponse.self, from: data, response: urlResponse)

            entries.append(contentsOf: response.items)
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && entries.count < maxItems

        let tracks: [Track] = entries.prefix(maxItems).compactMap { item in
            guard let videoID = item.snippet.resourceID?.videoID else { return nil }

            let artistName = item.snippet.videoOwnerChannelTitle ??
                item.snippet.channelTitle ??
                "YouTube"

            return Track(
                id: item.id,
                title: item.snippet.title,
                artist: artistName,
                artworkURL: item.snippet.thumbnails?.bestURL,
                youtubeVideoID: videoID
            )
        }

        return tracks
    }

    private func deduplicatedPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        var seenIDs: Set<String> = []
        return playlists.filter { playlist in
            seenIDs.insert(playlist.id).inserted
        }
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenIDs: Set<String> = []
        return tracks.filter { track in
            let dedupeID = track.youtubeVideoID ?? track.id
            return seenIDs.insert(dedupeID).inserted
        }
    }

    private func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return false }
            return seen.insert(trimmed.lowercased()).inserted
        }
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse) throws -> T {
        if let apiError = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data),
           let message = apiError.error?.message,
           message.isEmpty == false {
            throw APIError.serviceError(message.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }

        if let httpResponse = response as? HTTPURLResponse,
           (200 ..< 300).contains(httpResponse.statusCode) == false {
            throw APIError.serviceError("YouTube returned status \(httpResponse.statusCode).")
        }

        return try JSONDecoder().decode(type, from: data)
    }
}

enum MockLibraryService {
    static let featured: [Track] = [
        Track(title: "Synth Nights", artist: "Nova Echo", artworkURL: URL(string: "https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f")),
        Track(title: "Sunset Drive", artist: "Mira Lane", artworkURL: URL(string: "https://images.unsplash.com/photo-1461784180009-21121b2f204c")),
        Track(title: "City Lights", artist: "North Atlas", artworkURL: URL(string: "https://images.unsplash.com/photo-1511379938547-c1f69419868d"))
    ]

    static let recent: [Track] = [
        Track(title: "After Hours", artist: "Chrome Avenue", artworkURL: URL(string: "https://images.unsplash.com/photo-1516450360452-9312f5e86fc7")),
        Track(title: "Ocean Avenue", artist: "The Blue Tape", artworkURL: URL(string: "https://images.unsplash.com/photo-1471478331149-c72f17e33c73")),
        Track(title: "Nightliner", artist: "Vanta", artworkURL: URL(string: "https://images.unsplash.com/photo-1465847899084-d164df4dedc6"))
    ]

    static func search(query: String) -> [Track] {
        let catalog = featured + recent
        guard query.isEmpty == false else { return catalog }

        return catalog.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.artist.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct VideoSearchResponse: Decodable {
    let items: [VideoItem]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([VideoItem].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
    }
}

private struct VideoMetadataResponse: Decodable {
    let items: [VideoMetadataItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([VideoMetadataItem].self, forKey: .items) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }
}

private struct VideoMetadataItem: Decodable {
    let id: String
    let snippet: VideoMetadataSnippet
}

private struct VideoMetadataSnippet: Decodable {
    let categoryID: String?

    enum CodingKeys: String, CodingKey {
        case categoryID = "categoryId"
    }
}

private struct PlaylistSearchResponse: Decodable {
    let items: [PlaylistItem]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([PlaylistItem].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
    }
}

private struct ChannelSearchResponse: Decodable {
    let items: [ChannelItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([ChannelItem].self, forKey: .items) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }
}

private struct ChannelItem: Decodable {
    let contentDetails: ChannelContentDetails?
}

private struct ChannelContentDetails: Decodable {
    let relatedPlaylists: RelatedPlaylists?
}

private struct RelatedPlaylists: Decodable {
    let likes: String?
    let uploads: String?
}

private struct PlaylistItem: Decodable {
    let id: String
    let snippet: PlaylistSnippet
    let contentDetails: PlaylistContentDetails?
}

private struct PlaylistContentDetails: Decodable {
    let itemCount: Int?
}

private struct PlaylistItemsResponse: Decodable {
    let items: [PlaylistEntry]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([PlaylistEntry].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
    }
}

private struct PlaylistEntry: Decodable {
    let id: String
    let snippet: PlaylistEntrySnippet
}

private struct PlaylistSnippet: Decodable {
    let title: String
    let description: String?
    let thumbnails: ThumbnailCollection?
}

private struct PlaylistEntrySnippet: Decodable {
    let title: String
    let channelTitle: String?
    let videoOwnerChannelTitle: String?
    let resourceID: PlaylistEntryResourceID?
    let thumbnails: ThumbnailCollection?

    enum CodingKeys: String, CodingKey {
        case title
        case channelTitle
        case videoOwnerChannelTitle
        case resourceID = "resourceId"
        case thumbnails
    }
}

private struct PlaylistEntryResourceID: Decodable {
    let videoID: String?

    enum CodingKeys: String, CodingKey {
        case videoID = "videoId"
    }
}

private struct VideoItem: Decodable {
    let id: VideoIdentifier
    let snippet: Snippet
}

private struct VideoIdentifier: Decodable {
    let raw: String?
    let videoID: String?

    enum CodingKeys: String, CodingKey {
        case raw
        case videoID = "videoId"
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            raw = try container.decodeIfPresent(String.self, forKey: .raw)
            videoID = try container.decodeIfPresent(String.self, forKey: .videoID)
        } else {
            let single = try decoder.singleValueContainer()
            raw = try? single.decode(String.self)
            videoID = nil
        }
    }
}

private struct Snippet: Decodable {
    let title: String
    let channelTitle: String
    let thumbnails: ThumbnailCollection
    let categoryID: String?

    enum CodingKeys: String, CodingKey {
        case title
        case channelTitle
        case thumbnails
        case categoryID = "categoryId"
    }
}

private struct ThumbnailCollection: Decodable {
    let high: Thumbnail?
    let medium: Thumbnail?
    let `default`: Thumbnail?

    var bestURL: URL? {
        high?.url ?? medium?.url ?? `default`?.url
    }
}

private struct Thumbnail: Decodable {
    let url: URL?
}

private struct GoogleAPIErrorEnvelope: Decodable {
    let error: GoogleAPIError?
}

private struct GoogleAPIError: Decodable {
    let message: String?
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, isEmpty == false else { return [] }

        var chunks: [[Element]] = []
        var startIndex = 0

        while startIndex < count {
            let endIndex = Swift.min(startIndex + size, count)
            chunks.append(Array(self[startIndex ..< endIndex]))
            startIndex = endIndex
        }

        return chunks
    }
}

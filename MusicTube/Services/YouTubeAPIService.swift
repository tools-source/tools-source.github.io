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

    private actor SearchCache {
        private struct Entry {
            let response: SearchResponse
            let timestamp: Date
        }

        private var entries: [String: Entry] = [:]
        private let maxAge: TimeInterval = 300
        private let maxEntries = 80

        func results(for key: String) -> SearchResponse? {
            guard let entry = entries[key] else { return nil }
            guard Date().timeIntervalSince(entry.timestamp) < maxAge else {
                entries.removeValue(forKey: key)
                return nil
            }
            return entry.response
        }

        func store(_ response: SearchResponse, for key: String) {
            entries[key] = Entry(response: response, timestamp: Date())

            if entries.count > maxEntries {
                let staleKeys = entries
                    .sorted { $0.value.timestamp < $1.value.timestamp }
                    .prefix(entries.count - maxEntries)
                    .map(\.key)

                for key in staleKeys {
                    entries.removeValue(forKey: key)
                }
            }
        }
    }

    private let urlSession: URLSession
    private let apiKey: String?
    private let searchCache = SearchCache()
    private let likedMusicPlaylistID = "liked-music"
    private let innerTubeSearchURL = URL(string: "https://www.youtube.com/youtubei/v1/search?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false")!
    private let innerTubeClientVersion = "2.20260114.08.00"

    init(urlSession: URLSession = .shared, apiKey: String? = Bundle.main.object(forInfoDictionaryKey: "YOUTUBE_API_KEY") as? String) {
        self.urlSession = urlSession
        self.apiKey = apiKey
    }

    func loadHome(accessToken: String) async throws -> (featured: [Track], recent: [Track]) {
        try await loadAuthorizedHome(accessToken: accessToken)
    }

    func search(query: String, accessToken: String?) async throws -> SearchResponse {
        let cacheKey = normalizedSearchCacheKey(for: query)
        if let cachedResults = await searchCache.results(for: cacheKey) {
            return cachedResults
        }

        let results = try await performSearch(query: query, accessToken: accessToken)
        await searchCache.store(results, for: cacheKey)
        return results
    }

    private func performSearch(query: String, accessToken: String?) async throws -> SearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return .empty }

        var trackSearchError: Error?
        let songs: [Track]

        do {
            songs = try await performTrackSearch(query: trimmedQuery, accessToken: accessToken)
        } catch {
            trackSearchError = error
            songs = []
        }

        let collections = (try? await performCollectionSearch(query: trimmedQuery)) ??
            (playlists: [], albums: [], artists: [])
        let response = SearchResponse(
            songs: songs,
            playlists: collections.playlists,
            albums: collections.albums,
            artists: collections.artists
        )

        if response.isEmpty, let trackSearchError {
            throw trackSearchError
        }

        return response
    }

    private func performTrackSearch(query: String, accessToken: String?) async throws -> [Track] {
        if let innerTubeResults = try? await fetchSearchResultsViaInnerTube(query: query, maxResults: 25),
           innerTubeResults.isEmpty == false {
            return innerTubeResults
        }

        if let accessToken {
            do {
                let musicResults = try await fetchSearchResults(
                    query: query,
                    accessToken: accessToken,
                    maxResults: 25
                )
                if musicResults.isEmpty == false {
                    return musicResults
                }

                let broaderResults = try await fetchSearchResults(
                    query: query,
                    accessToken: accessToken,
                    maxResults: 25,
                    musicOnly: false
                )
                if broaderResults.isEmpty == false {
                    return broaderResults
                }
            } catch {
                if let apiKey = validatedAPIKey {
                    let fallbackResults = try? await fetchSearchResults(
                        query: query,
                        apiKey: apiKey,
                        maxResults: 25
                    )
                    if let fallbackResults, fallbackResults.isEmpty == false {
                        return fallbackResults
                    }
                }

                throw error
            }
        }

        if let apiKey = validatedAPIKey {
            let fallbackResults = try? await fetchSearchResults(
                query: query,
                apiKey: apiKey,
                maxResults: 25
            )
            if let fallbackResults, fallbackResults.isEmpty == false {
                return fallbackResults
            }

            let broaderFallbackResults = try? await fetchSearchResults(
                query: query,
                apiKey: apiKey,
                maxResults: 25,
                musicOnly: false
            )
            if let broaderFallbackResults, broaderFallbackResults.isEmpty == false {
                return broaderFallbackResults
            }
        }

        return []
    }

    func loadPlaylists(accessToken: String) async throws -> [Playlist] {
        async let userPlaylists = fetchUserPlaylists(accessToken: accessToken)
        async let relatedPlaylists = fetchRelatedPlaylists(accessToken: accessToken)

        var loadErrors: [Error] = []

        let related: RelatedPlaylists?
        do {
            related = try await relatedPlaylists
        } catch {
            related = nil
            loadErrors.append(error)
        }

        let resolvedCollections: [Playlist]
        do {
            resolvedCollections = try await fetchSystemCollections(related: related, accessToken: accessToken)
        } catch {
            resolvedCollections = []
            loadErrors.append(error)
        }

        let resolvedUserPlaylists: [Playlist]
        do {
            resolvedUserPlaylists = try await userPlaylists
        } catch {
            resolvedUserPlaylists = []
            loadErrors.append(error)
        }

        let resolvedLikedTracks: [Track]
        do {
            resolvedLikedTracks = try await fetchLikedMusicTracks(
                accessToken: accessToken,
                relatedPlaylists: related,
                maxItems: 200
            )
        } catch {
            resolvedLikedTracks = []
            loadErrors.append(error)
        }

        var resolvedPlaylists = resolvedCollections + resolvedUserPlaylists

        if let fallbackLikedMusicPlaylist = makeLikedMusicPlaylist(
            from: resolvedLikedTracks,
            fallbackPlaylist: resolvedPlaylists.first(where: { $0.kind == .likedMusic })
        ) {
            if let existingIndex = resolvedPlaylists.firstIndex(where: { $0.kind == .likedMusic }) {
                resolvedPlaylists[existingIndex] = fallbackLikedMusicPlaylist
            } else {
                resolvedPlaylists.insert(fallbackLikedMusicPlaylist, at: 0)
            }
        }

        let prioritizedPlaylists = prioritizedLibraryPlaylists(resolvedPlaylists)
        if prioritizedPlaylists.isEmpty, let loadError = loadErrors.first {
            throw loadError
        }

        return prioritizedPlaylists
    }

    private func loadAuthorizedHome(accessToken: String) async throws -> (featured: [Track], recent: [Track]) {
        async let userPlaylistsTask = fetchUserPlaylists(accessToken: accessToken)
        async let relatedPlaylistsTask = fetchRelatedPlaylists(accessToken: accessToken)

        var loadErrors: [Error] = []

        let relatedPlaylists: RelatedPlaylists?
        do {
            relatedPlaylists = try await relatedPlaylistsTask
        } catch {
            relatedPlaylists = nil
            loadErrors.append(error)
        }

        let likedTracks: [Track]
        do {
            likedTracks = try await fetchLikedMusicTracks(
                accessToken: accessToken,
                relatedPlaylists: relatedPlaylists,
                maxItems: 50
            )
        } catch {
            likedTracks = []
            loadErrors.append(error)
        }

        let userPlaylists: [Playlist]
        do {
            userPlaylists = try await userPlaylistsTask
        } catch {
            userPlaylists = []
            loadErrors.append(error)
        }

        let systemCollections: [Playlist]
        do {
            systemCollections = try await fetchSystemCollections(related: relatedPlaylists, accessToken: accessToken)
        } catch {
            systemCollections = []
            loadErrors.append(error)
        }

        let playlistSources = prioritizedLibraryPlaylists(systemCollections + userPlaylists)
        let mixAlbums = selectSuggestedMixes(from: playlistSources, limit: 8)
        let tracksByPlaylist = await fetchTracks(
            for: mixAlbums,
            accessToken: accessToken,
            maxItemsPerPlaylist: 36
        )

        let mixTracks = mixAlbums.flatMap { randomizedTracks(from: tracksByPlaylist[$0.id] ?? [], limit: 16) }
        let seedTracks = deduplicatedTracks(likedTracks + mixTracks)

        guard seedTracks.isEmpty == false else {
            if let loadError = loadErrors.first {
                throw loadError
            }
            return ([], [])
        }

        let personalizedTracks: [Track]
        do {
            personalizedTracks = try await fetchPersonalizedMusic(
                seedTracks: seedTracks,
                accessToken: accessToken
            )
        } catch {
            personalizedTracks = []
            loadErrors.append(error)
        }

        let featuredPool = deduplicatedTracks(
            personalizedTracks.shuffled() + likedTracks.shuffled() + mixTracks.shuffled()
        )
        let featured = Array(featuredPool.prefix(36))
        let featuredIDs = Set(featured.map(trackIdentifier))
        let recent = Array(
            deduplicatedTracks(mixTracks.shuffled() + personalizedTracks.shuffled() + likedTracks.shuffled())
                .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                .prefix(30)
        )

        if featured.isEmpty, recent.isEmpty, let loadError = loadErrors.first {
            throw loadError
        }

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
                        title: "Liked Songs",
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
            let relatedPlaylists = try? await fetchRelatedPlaylists(accessToken: accessToken)
            return try await fetchLikedMusicTracks(
                accessToken: accessToken,
                relatedPlaylists: relatedPlaylists,
                maxItems: 200
            )
        }

        return try await fetchPlaylistItems(
            for: playlist,
            accessToken: accessToken,
            maxItems: 200
        )
    }

    func loadCollectionItems(for collection: MusicCollection, accessToken: String?) async throws -> [Track] {
        switch collection.kind {
        case .playlist, .album:
            if let accessToken {
                return try await fetchPlaylistItems(
                    playlistID: collection.sourceID,
                    accessToken: accessToken,
                    maxItems: 120
                )
            }

            if let apiKey = validatedAPIKey {
                return try await fetchPlaylistItems(
                    playlistID: collection.sourceID,
                    apiKey: apiKey,
                    maxItems: 120
                )
            }

            return Array(try await performTrackSearch(query: collection.queryHint, accessToken: nil).prefix(50))

        case .artist:
            return try await fetchArtistTracks(
                for: collection,
                accessToken: accessToken,
                maxItems: 60
            )
        }
    }

    func setLikeStatus(for track: Track, isLiked: Bool, accessToken: String) async throws {
        let videoID = track.youtubeVideoID ?? track.id
        guard videoID.isEmpty == false else {
            throw APIError.serviceError("This YouTube item can't be liked right now.")
        }

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos/rate")!
        components.queryItems = authorizedQueryItems(
            [
                URLQueryItem(name: "id", value: videoID),
                URLQueryItem(name: "rating", value: isLiked ? "like" : "none")
            ]
        )

        var request = authorizedRequest(url: components.url!, accessToken: accessToken)
        request.httpMethod = "POST"

        let (data, response) = try await urlSession.data(for: request)
        try validateStatusCode(for: response, data: data)
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
            guard isLiveSearchResult(snippet: item.snippet) == false else { return nil }
            return Track(
                id: videoID,
                title: item.snippet.title,
                artist: item.snippet.channelTitle,
                artworkURL: item.snippet.thumbnails.bestURL,
                youtubeVideoID: videoID
            )
        }
    }

    private func fetchSearchResults(
        query: String,
        apiKey: String,
        maxResults: Int,
        musicOnly: Bool = true
    ) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "key", value: apiKey)
        ]
        if musicOnly {
            queryItems.insert(URLQueryItem(name: "videoCategoryId", value: "10"), at: 2)
        }
        components.queryItems = queryItems

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

    private func fetchSearchResults(
        query: String,
        accessToken: String,
        maxResults: Int,
        musicOnly: Bool = true
    ) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        if musicOnly {
            queryItems.insert(URLQueryItem(name: "videoCategoryId", value: "10"), at: 2)
        }
        components.queryItems = authorizedQueryItems(queryItems)

        let request = authorizedRequest(url: components.url!, accessToken: accessToken)
        let (data, urlResponse) = try await urlSession.data(for: request)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)
        return response.items.compactMap(track(from:))
    }

    private func fetchPersonalizedMusic(seedTracks: [Track], accessToken: String) async throws -> [Track] {
        guard seedTracks.isEmpty == false else {
            return []
        }
        let seedArtists = Array(orderedUniqueStrings(seedTracks.shuffled().map(\.artist)).prefix(4))

        guard seedArtists.isEmpty == false else {
            return Array(deduplicatedTracks(seedTracks.shuffled()).prefix(25))
        }

        let excludedIDs = Set(seedTracks.compactMap(\.youtubeVideoID))
        let querySuffixes = [
            "official audio",
            "official music video",
            "lyrics",
            "live session"
        ]
        let recommendations = await withTaskGroup(of: [Track].self) { group in
            for (index, artist) in seedArtists.enumerated() {
                let suffix = querySuffixes[index % querySuffixes.count]
                group.addTask { [self] in
                    let query = "\(artist) \(suffix)"
                    let results: [Track]
                    if let innerTubeResults = try? await fetchSearchResultsViaInnerTube(query: query, maxResults: 8),
                       innerTubeResults.isEmpty == false {
                        results = innerTubeResults
                    } else {
                        results = (try? await fetchSearchResults(
                            query: query,
                            accessToken: accessToken,
                            maxResults: 8,
                            musicOnly: true
                        )) ?? []
                    }

                    return results.filter { track in
                        guard let videoID = track.youtubeVideoID else { return true }
                        return excludedIDs.contains(videoID) == false
                    }
                }
            }

            var collected: [Track] = []
            for await tracks in group {
                collected.append(contentsOf: tracks)
            }
            return collected
        }

        let deduped = deduplicatedTracks(recommendations.shuffled())
        if deduped.isEmpty {
            return Array(deduplicatedTracks(seedTracks.shuffled()).prefix(25))
        }

        return Array(deduped.prefix(25))
    }

    private func fetchFallbackDiscoveryTracks() async throws -> [Track] {
        let fallbackQueries = [
            "new music official audio",
            "viral songs official music video",
            "top songs playlist",
            "latest hits official audio",
            "music mix",
            "best songs 2026"
        ].shuffled()

        var collectedTracks: [Track] = []
        for query in fallbackQueries.prefix(3) {
            let results = try await fetchSearchResultsViaInnerTube(query: query, maxResults: 12)
            collectedTracks.append(contentsOf: results)
        }

        return Array(deduplicatedTracks(collectedTracks.shuffled()).prefix(25))
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
                let title = item.snippet.title ?? ""
                let channel = item.snippet.channelTitle ?? ""
                guard !isNonMusicContent(title: title, channel: channel) else { continue }
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

    private func normalizedSearchCacheKey(for query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
        guard isLiveSearchResult(snippet: item.snippet) == false else { return nil }
        let artist = cleanArtistName(item.snippet.channelTitle)
        let title = cleanTrackTitle(item.snippet.title, channelName: artist)
        return Track(
            id: videoID,
            title: title,
            artist: artist,
            artworkURL: item.snippet.thumbnails.bestURL,
            youtubeVideoID: videoID
        )
    }

    private func performCollectionSearch(query: String) async throws -> (playlists: [MusicCollection], albums: [MusicCollection], artists: [MusicCollection]) {
        let object = try await fetchInnerTubeSearchPayload(query: query)
        let playlistRenderers = collectObjects(matchingKey: "playlistRenderer", in: object)
        let channelRenderers = collectObjects(matchingKey: "channelRenderer", in: object)

        var playlists = deduplicatedCollections(
            playlistRenderers
                .compactMap { musicCollection(fromInnerTubePlaylistRenderer: $0) }
                .filter { $0.kind == .playlist }
        )
        var albums = deduplicatedCollections(
            playlistRenderers
                .compactMap { musicCollection(fromInnerTubePlaylistRenderer: $0) }
                .filter { $0.kind == .album }
        )
        let artists = deduplicatedCollections(
            channelRenderers.compactMap(musicCollection(fromInnerTubeChannelRenderer:))
        )

        if albums.count < 6 {
            let albumPayload = try? await fetchInnerTubeSearchPayload(query: "\(query) album")
            if let albumPayload {
                let albumRenderers = collectObjects(matchingKey: "playlistRenderer", in: albumPayload)
                albums = deduplicatedCollections(
                    albums + albumRenderers.compactMap {
                        musicCollection(fromInnerTubePlaylistRenderer: $0, forceAlbum: true)
                    }
                )
            }
        }

        if playlists.count > 12 {
            playlists = Array(playlists.prefix(12))
        }
        if albums.count > 12 {
            albums = Array(albums.prefix(12))
        }

        return (playlists, albums, artists)
    }

    private func fetchSearchResultsViaInnerTube(query: String, maxResults: Int) async throws -> [Track] {
        let object = try await fetchInnerTubeSearchPayload(query: query)
        let renderers = collectObjects(matchingKey: "videoRenderer", in: object)

        let tracks = renderers.compactMap(track(fromInnerTubeVideoRenderer:))
        return Array(deduplicatedTracks(tracks).prefix(maxResults))
    }

    private func fetchInnerTubeSearchPayload(query: String) async throws -> Any {
        var request = URLRequest(url: innerTubeSearchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(innerTubeClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "context": [
                    "client": [
                        "clientName": "WEB",
                        "clientVersion": innerTubeClientVersion
                    ]
                ],
                "query": query
            ]
        )

        let (data, response) = try await urlSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           (200 ..< 300).contains(httpResponse.statusCode) == false {
            throw APIError.serviceError("YouTube internal search returned status \(httpResponse.statusCode).")
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    private func collectObjects(matchingKey key: String, in object: Any) -> [[String: Any]] {
        if let dictionary = object as? [String: Any] {
            var matches: [[String: Any]] = []
            if let match = dictionary[key] as? [String: Any] {
                matches.append(match)
            }

            for value in dictionary.values {
                matches.append(contentsOf: collectObjects(matchingKey: key, in: value))
            }
            return matches
        }

        if let array = object as? [Any] {
            return array.flatMap { collectObjects(matchingKey: key, in: $0) }
        }

        return []
    }

    private func track(fromInnerTubeVideoRenderer renderer: [String: Any]) -> Track? {
        guard let videoID = renderer["videoId"] as? String else { return nil }
        guard isLiveSearchResult(renderer: renderer) == false else { return nil }

        let rawTitle = text(from: renderer["title"]) ?? "YouTube Track"
        let rawArtist =
            text(from: renderer["longBylineText"]) ??
            text(from: renderer["ownerText"]) ??
            text(from: renderer["shortBylineText"]) ??
            "YouTube"

        // Filter out non-music content (kids, gaming, vlogs, etc.)
        guard !isNonMusicContent(title: rawTitle, channel: rawArtist) else { return nil }

        // Filter by duration — music tracks are generally under 12 minutes
        let parsedDuration = text(from: renderer["lengthText"]).flatMap(parseDurationSeconds)
        if let durationText = text(from: renderer["lengthText"]),
           let seconds = parseDurationSeconds(durationText), seconds > 720 {
            return nil
        }

        let artist = cleanArtistName(rawArtist)
        let title = cleanTrackTitle(rawTitle, channelName: artist)
        let artworkURL = bestThumbnailURL(from: renderer["thumbnail"])

        return Track(
            id: videoID,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            duration: parsedDuration.map(TimeInterval.init),
            youtubeVideoID: videoID
        )
    }

    private func musicCollection(fromInnerTubePlaylistRenderer renderer: [String: Any], forceAlbum: Bool? = nil) -> MusicCollection? {
        guard let playlistID = renderer["playlistId"] as? String else { return nil }

        let title = text(from: renderer["title"]) ?? "Playlist"
        let subtitle =
            text(from: renderer["shortBylineText"]) ??
            text(from: renderer["longBylineText"]) ??
            "YouTube"
        let description = text(from: renderer["descriptionSnippet"]) ?? subtitle
        let itemCount = parseCount(
            from: text(from: renderer["videoCountText"]) ??
                text(from: renderer["videoCountShortText"]) ??
                text(from: renderer["thumbnailOverlays"])
        )
        let artworkURL = extractThumbnailURL(from: renderer)
        let resolvedIsAlbum = forceAlbum ?? isLikelyAlbum(title: title, subtitle: subtitle, description: description)
        let kind: MusicCollectionKind = resolvedIsAlbum ? .album : .playlist

        return MusicCollection(
            sourceID: playlistID,
            title: title,
            subtitle: subtitle,
            description: description,
            artworkURL: artworkURL,
            itemCount: itemCount,
            kind: kind,
            queryHint: [title, subtitle].filter { $0.isEmpty == false }.joined(separator: " ")
        )
    }

    private func musicCollection(fromInnerTubeChannelRenderer renderer: [String: Any]) -> MusicCollection? {
        guard let channelID = renderer["channelId"] as? String else { return nil }

        let title = cleanArtistName(text(from: renderer["title"]) ?? "Artist")
        let subtitle = text(from: renderer["subscriberCountText"]) ?? "Artist"
        let description = text(from: renderer["descriptionSnippet"]) ?? subtitle
        let artworkURL = extractThumbnailURL(from: renderer)

        guard isNonMusicContent(title: description, channel: title) == false else { return nil }

        return MusicCollection(
            sourceID: channelID,
            title: title,
            subtitle: subtitle,
            description: description,
            artworkURL: artworkURL,
            itemCount: 0,
            kind: .artist,
            queryHint: title
        )
    }

    private func text(from object: Any?) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }

        if let simpleText = dictionary["simpleText"] as? String, simpleText.isEmpty == false {
            return simpleText
        }

        if let runs = dictionary["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private func bestThumbnailURL(from object: Any?) -> URL? {
        guard
            let dictionary = object as? [String: Any],
            let thumbnails = dictionary["thumbnails"] as? [[String: Any]],
            let lastThumbnail = thumbnails.last,
            let urlString = lastThumbnail["url"] as? String
        else {
            return nil
        }

        return URL(string: urlString)
    }

    private func extractThumbnailURL(from object: Any?) -> URL? {
        if let url = bestThumbnailURL(from: object) {
            return url
        }

        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                if let url = extractThumbnailURL(from: value) {
                    return url
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let url = extractThumbnailURL(from: value) {
                    return url
                }
            }
        }

        return nil
    }

    private func parseCount(from text: String?) -> Int {
        guard let text else { return 0 }
        let digits = text.unicodeScalars.filter(CharacterSet.decimalDigits.contains)
        let numericString = String(String.UnicodeScalarView(digits))
        return Int(numericString) ?? 0
    }

    private func isLikelyAlbum(title: String, subtitle: String, description: String) -> Bool {
        let searchableText = "\(title) \(subtitle) \(description)".lowercased()
        if searchableText.contains("album") {
            return true
        }

        if searchableText.contains(" - topic") && searchableText.contains("playlist") == false {
            return true
        }

        return false
    }

    private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func fetchLikedMusicPlaylist(accessToken: String) async throws -> Playlist? {
        let likedTracks = try await fetchLikedMusicTracks(accessToken: accessToken, maxItems: 12)
        return makeLikedMusicPlaylist(from: likedTracks)
    }

    private func fetchLikedMusicTracks(
        accessToken: String,
        relatedPlaylists: RelatedPlaylists? = nil,
        maxItems: Int
    ) async throws -> [Track] {
        do {
            return try await fetchLikedMusicTracksByRating(accessToken: accessToken, maxItems: maxItems)
        } catch {
            let effectiveRelatedPlaylists: RelatedPlaylists?
            if let relatedPlaylists {
                effectiveRelatedPlaylists = relatedPlaylists
            } else {
                effectiveRelatedPlaylists = try? await fetchRelatedPlaylists(accessToken: accessToken)
            }

            guard let likesPlaylistID = effectiveRelatedPlaylists?.likes else {
                throw error
            }

            let likesPlaylist = Playlist(
                id: likesPlaylistID,
                title: "Liked Songs",
                description: "Music-only items from your likes",
                artworkURL: nil,
                itemCount: maxItems,
                kind: .likedMusic
            )

            let playlistTracks = try await fetchPlaylistItems(
                for: likesPlaylist,
                accessToken: accessToken,
                maxItems: maxItems
            )
            let filteredTracks = (try? await filterMusicTracks(playlistTracks, accessToken: accessToken)) ?? playlistTracks

            guard filteredTracks.isEmpty == false else {
                throw error
            }

            return Array(deduplicatedTracks(filteredTracks).prefix(maxItems))
        }
    }

    private func fetchLikedMusicTracksByRating(accessToken: String, maxItems: Int) async throws -> [Track] {
        var tracks: [Track] = []
        var nextPageToken: String?
        var requiresMusicFiltering = false
        let rawTrackLimit = max(maxItems * 3, 150)

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
                // Heuristic filter: catches kids content (e.g., Cocomelon) that has categoryId=10
                guard !isNonMusicContent(title: item.snippet.title, channel: item.snippet.channelTitle) else {
                    return nil
                }
                return track(from: item)
            }

            tracks.append(contentsOf: pageTracks)
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && tracks.count < rawTrackLimit

        let dedupedTracks = deduplicatedTracks(tracks)

        if requiresMusicFiltering {
            let filteredTracks = (try? await filterMusicTracks(dedupedTracks, accessToken: accessToken)) ?? dedupedTracks
            return Array(filteredTracks.prefix(maxItems))
        }

        return Array(dedupedTracks.prefix(maxItems))
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
        try await fetchPlaylistItems(
            playlistID: playlist.id,
            accessToken: accessToken,
            maxItems: maxItems
        )
    }

    private func fetchPlaylistItems(
        playlistID: String,
        accessToken: String,
        maxItems: Int
    ) async throws -> [Track] {
        try await fetchPlaylistItems(
            playlistID: playlistID,
            queryItems: authorizedQueryItems([]),
            accessToken: accessToken,
            maxItems: maxItems
        )
    }

    private func fetchPlaylistItems(
        playlistID: String,
        apiKey: String,
        maxItems: Int
    ) async throws -> [Track] {
        try await fetchPlaylistItems(
            playlistID: playlistID,
            queryItems: [URLQueryItem(name: "key", value: apiKey)],
            accessToken: nil,
            maxItems: maxItems
        )
    }

    private func fetchPlaylistItems(
        playlistID: String,
        queryItems additionalQueryItems: [URLQueryItem],
        accessToken: String?,
        maxItems: Int
    ) async throws -> [Track] {
        var entries: [PlaylistEntry] = []
        var nextPageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "playlistId", value: playlistID),
                URLQueryItem(name: "maxResults", value: "50")
            ]
            queryItems.append(contentsOf: additionalQueryItems)

            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }

            components.queryItems = queryItems

            let data: Data
            let urlResponse: URLResponse
            if let accessToken {
                let request = authorizedRequest(url: components.url!, accessToken: accessToken)
                (data, urlResponse) = try await urlSession.data(for: request)
            } else {
                (data, urlResponse) = try await urlSession.data(from: components.url!)
            }
            let response = try decodeResponse(PlaylistItemsResponse.self, from: data, response: urlResponse)

            entries.append(contentsOf: response.items)
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && entries.count < maxItems

        let tracks: [Track] = entries.prefix(maxItems).compactMap { item in
            guard let videoID = item.snippet.resourceID?.videoID else { return nil }

            let rawArtist = item.snippet.videoOwnerChannelTitle ??
                item.snippet.channelTitle ??
                "YouTube"
            let artist = cleanArtistName(rawArtist)
            let title = cleanTrackTitle(item.snippet.title, channelName: artist)

            return Track(
                id: item.id,
                title: title,
                artist: artist,
                artworkURL: item.snippet.thumbnails?.bestURL,
                youtubeVideoID: videoID
            )
        }

        return tracks
    }

    private func fetchArtistTracks(
        for collection: MusicCollection,
        accessToken: String?,
        maxItems: Int
    ) async throws -> [Track] {
        if let accessToken {
            let results = try await fetchArtistTracks(
                query: collection.queryHint,
                channelID: collection.sourceID,
                accessToken: accessToken,
                maxItems: maxItems
            )
            if results.isEmpty == false {
                return results
            }
        }

        if let apiKey = validatedAPIKey {
            let results = try await fetchArtistTracks(
                query: collection.queryHint,
                channelID: collection.sourceID,
                apiKey: apiKey,
                maxResults: maxItems
            )
            if results.isEmpty == false {
                return results
            }
        }

        return Array(try await performTrackSearch(query: "\(collection.title) official audio", accessToken: accessToken).prefix(maxItems))
    }

    private func fetchArtistTracks(
        query: String,
        channelID: String,
        accessToken: String,
        maxItems: Int
    ) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "channelId", value: channelID),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxItems))
        ]

        let request = authorizedRequest(url: components.url!, accessToken: accessToken)
        let (data, urlResponse) = try await urlSession.data(for: request)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)
        return response.items.compactMap(track(from:))
    }

    private func fetchArtistTracks(
        query: String,
        channelID: String,
        apiKey: String,
        maxResults: Int
    ) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "channelId", value: channelID),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "key", value: apiKey)
        ]

        let (data, urlResponse) = try await urlSession.data(from: components.url!)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)
        return response.items.compactMap(track(from:))
    }

    private func prioritizedLibraryPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let deduplicated = deduplicatedPlaylists(playlists)
        let likedPlaylists = deduplicated.filter { $0.kind == .likedMusic }
        let remainingPlaylists = deduplicated.filter { $0.kind != .likedMusic }
        return likedPlaylists + remainingPlaylists
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

    private func deduplicatedCollections(_ collections: [MusicCollection]) -> [MusicCollection] {
        var seenIDs: Set<String> = []
        return collections.filter { collection in
            seenIDs.insert(collection.id).inserted
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

    private func selectSuggestedMixes(from playlists: [Playlist], limit: Int) -> [Playlist] {
        let candidates = playlists.suggestedMixCandidates()
        guard candidates.isEmpty == false else { return [] }

        let poolSize = min(candidates.count, max(limit * 2, limit))
        return Array(candidates.prefix(poolSize).shuffled().prefix(limit))
    }

    private func randomizedTracks(from tracks: [Track], limit: Int) -> [Track] {
        guard tracks.isEmpty == false else { return [] }
        return Array(tracks.shuffled().prefix(limit))
    }

    private func trackIdentifier(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func makeLikedMusicPlaylist(
        from tracks: [Track],
        fallbackPlaylist: Playlist? = nil
    ) -> Playlist? {
        guard tracks.isEmpty == false || fallbackPlaylist != nil else { return nil }

        return Playlist(
            id: fallbackPlaylist?.id ?? likedMusicPlaylistID,
            title: "Liked Songs",
            description: "Music-only items from your likes",
            artworkURL: tracks.first?.artworkURL ?? fallbackPlaylist?.artworkURL,
            itemCount: max(tracks.count, fallbackPlaylist?.itemCount ?? 0),
            kind: .likedMusic
        )
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse) throws -> T {
        try validateStatusCode(for: response, data: data)

        return try JSONDecoder().decode(type, from: data)
    }

    private func validateStatusCode(for response: URLResponse, data: Data) throws {
        if let apiError = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data),
           let message = apiError.error?.message,
           message.isEmpty == false {
            throw APIError.serviceError(message.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }

        if let httpResponse = response as? HTTPURLResponse,
           (200 ..< 300).contains(httpResponse.statusCode) == false {
            throw APIError.serviceError("YouTube returned status \(httpResponse.statusCode).")
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
    let title: String?
    let channelTitle: String?

    enum CodingKeys: String, CodingKey {
        case categoryID = "categoryId"
        case title
        case channelTitle
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
    let liveBroadcastContent: String?

    enum CodingKeys: String, CodingKey {
        case title
        case channelTitle
        case thumbnails
        case categoryID = "categoryId"
        case liveBroadcastContent
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

// MARK: - Music Content Helpers

private extension YouTubeAPIService {
    func isLiveSearchResult(snippet: Snippet) -> Bool {
        switch snippet.liveBroadcastContent?.lowercased() {
        case "live", "upcoming":
            return true
        default:
            return false
        }
    }

    func isLiveSearchResult(renderer: [String: Any]) -> Bool {
        if renderer["upcomingEventData"] != nil {
            return true
        }

        if let overlayText = text(from: renderer["thumbnailOverlays"])?.lowercased(),
           overlayText.contains("live") || overlayText.contains("upcoming") {
            return true
        }

        if let badges = renderer["badges"] as? [Any],
           badges.contains(where: { badge in
               let badgeText = text(from: badge)?.lowercased() ?? ""
               return badgeText.contains("live") || badgeText.contains("upcoming")
           }) {
            return true
        }

        let durationText = text(from: renderer["lengthText"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return durationText == nil
    }

    /// Returns true when the video is clearly non-music (kids songs, gaming, vlogs, etc.)
    func isNonMusicContent(title: String, channel: String) -> Bool {
        let t = title.lowercased()
        let ch = channel.lowercased()

        // Kids / nursery content
        let kidsKeywords = [
            "nursery rhyme", "baby shark", "kids song", "children's song", "children song",
            "cocomelon", "super simple songs", "little baby bum", "blippi", "ms rachel",
            "toddler song", "abc song", "phonics song", "wheels on the bus",
            "if you're happy", "finger family", "johny johny", "five little",
            "old macdonald", "twinkle twinkle", "baa baa", "itsy bitsy",
            "pinkfong", "moonbug", "dave and ava", "little angel"
        ]
        for kw in kidsKeywords where t.contains(kw) || ch.contains(kw) { return true }

        // Gaming content
        let gamingKeywords = [
            "gameplay", "let's play", "lets play", "playthrough", "walkthrough",
            "minecraft", "roblox", "fortnite", "among us", "gta v", "call of duty",
            "game review", "gaming montage"
        ]
        for kw in gamingKeywords where t.contains(kw) { return true }

        // Vlog / lifestyle
        let vlogKeywords = [
            "daily vlog", "weekly vlog", "room tour", "morning routine", "night routine",
            "get ready with me", "grwm", "what i eat in a day",
            "unboxing video", "haul video", "try on haul"
        ]
        for kw in vlogKeywords where t.contains(kw) { return true }

        // Channel-level signals
        let nonMusicChannelSuffixes = ["gaming", "gamer", "plays", "vlogs"]
        for suffix in nonMusicChannelSuffixes where ch.hasSuffix(suffix) { return true }

        return false
    }

    /// Parses "M:SS" or "H:MM:SS" duration strings to total seconds.
    func parseDurationSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3_600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    /// Cleans YouTube video titles: strips "Artist - " prefix and common qualifiers.
    func cleanTrackTitle(_ raw: String, channelName: String) -> String {
        var title = raw

        // Strip exact "Channel - " prefix first (most reliable)
        let exactPrefix = channelName + " - "
        if title.hasPrefix(exactPrefix) {
            title = String(title.dropFirst(exactPrefix.count))
        } else if let dashRange = title.range(of: " - ") {
            // General "Artist - Title" split when artist part is a plausible short name
            let leftCount = title.distance(from: title.startIndex, to: dashRange.lowerBound)
            let right = String(title[dashRange.upperBound...])
            if leftCount <= 50, !right.isEmpty {
                title = right
            }
        }

        // Remove trailing YouTube qualifiers (applied repeatedly to handle stacked ones)
        let qualifiers: [String] = [
            "(Official Music Video)", "[Official Music Video]",
            "(Official Video)", "[Official Video]",
            "(Official Audio)", "[Official Audio]",
            "(Lyric Video)", "[Lyric Video]",
            "(Lyrics Video)", "[Lyrics Video]",
            "(Lyrics)", "[Lyrics]",
            "(Audio)", "[Audio]",
            "(Live Session)", "[Live Session]",
            "(Live Performance)", "[Live Performance]",
            "(HD)", "[HD]", "(4K)", "[4K]", "(HQ)", "[HQ]",
            "(Official)", "[Official]",
            "- Official Music Video", "- Official Video", "- Official Audio",
            "- Lyric Video", "- Lyrics", "- Audio"
        ]

        var changed = true
        while changed {
            changed = false
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            for q in qualifiers {
                if trimmed.lowercased().hasSuffix(q.lowercased()) {
                    title = String(trimmed.dropLast(q.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }

        let result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? raw : result
    }

    /// Cleans YouTube channel names: removes "- Topic" and "VEVO" suffixes.
    func cleanArtistName(_ raw: String) -> String {
        var name = raw
        if name.hasSuffix(" - Topic") { name = String(name.dropLast(8)) }
        if name.uppercased().hasSuffix("VEVO") {
            name = String(name.dropLast(4)).trimmingCharacters(in: .whitespaces)
        }
        if name.hasSuffix(" Official") { name = String(name.dropLast(9)) }
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? raw : result
    }
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

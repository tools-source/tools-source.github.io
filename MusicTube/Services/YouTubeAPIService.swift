import Foundation

final class YouTubeAPIService: MusicCatalogProviding {
    enum YouTubeAPIError: LocalizedError {
        case invalidSearchQuery(QueryValidationError)
        case authenticationFailure
        case rateLimited(retryAfter: TimeInterval?)
        case networkError(URLError)
        case invalidResponse(statusCode: Int, message: String?)
        case decodingError(DecodingError)
        case notFound
        case serviceError(String)

        var errorDescription: String? {
            switch self {
            case .invalidSearchQuery(let error):
                return error.localizedDescription
            case .authenticationFailure:
                return "Your YouTube session expired. Please sign in again."
            case .rateLimited:
                return "YouTube is rate limiting requests right now. Please try again in a moment."
            case .networkError(let error):
                return error.localizedDescription
            case .invalidResponse(_, let message):
                return message ?? "YouTube returned an unexpected response."
            case .decodingError:
                return "MusicTube couldn't read YouTube's response."
            case .notFound:
                return "The requested YouTube item could not be found."
            case .serviceError(let message):
                return message
            }
        }

        var isRetryable: Bool {
            switch self {
            case .networkError, .rateLimited:
                return true
            case .invalidResponse(let statusCode, _):
                return [500, 502, 503, 504].contains(statusCode)
            default:
                return false
            }
        }
    }

    typealias APIError = YouTubeAPIError

    private struct InnerTubeTrackPage {
        let tracks: [Track]
        let continuationToken: String?
    }

    private enum DataAPIEndpoint: Hashable, Sendable {
        case channelsList
        case playlistItemsList
        case playlistsList
        case videosList
    }

    private actor DataAPIBackoffGate {
        private var suppressedUntilByEndpoint: [DataAPIEndpoint: Date] = [:]

        func check(_ endpoint: DataAPIEndpoint) throws {
            guard let suppressedUntil = suppressedUntilByEndpoint[endpoint] else { return }
            let retryAfter = suppressedUntil.timeIntervalSinceNow
            guard retryAfter > 0 else {
                suppressedUntilByEndpoint.removeValue(forKey: endpoint)
                return
            }

            throw APIError.rateLimited(retryAfter: retryAfter)
        }

        func recordSuccess(_ endpoint: DataAPIEndpoint) {
            suppressedUntilByEndpoint.removeValue(forKey: endpoint)
        }

        func recordFailure(_ endpoint: DataAPIEndpoint, backoffDelay: TimeInterval?) {
            guard let backoffDelay, backoffDelay > 0 else { return }
            let proposedDate = Date().addingTimeInterval(backoffDelay)
            if let currentDate = suppressedUntilByEndpoint[endpoint], currentDate > proposedDate {
                return
            }
            suppressedUntilByEndpoint[endpoint] = proposedDate
        }
    }

    private let urlSession: URLSession
    private let apiKey: String?
    private let logger: any AppLogging
    private let dataAPIBackoffGate = DataAPIBackoffGate()
    private let searchCache = CacheStore<String, SearchResponse>(
        ttl: AppConfig.Search.cacheTTL,
        maxEntries: AppConfig.Search.maxCachedQueries
    )
    private let videoMetadataCache = CacheStore<String, ResolvedVideoMetadata>(
        ttl: AppConfig.Metadata.cacheTTL,
        maxEntries: AppConfig.Metadata.maxCachedEntries
    )
    // The signed-in user's liked/uploads playlist IDs are immutable for the account,
    // yet channels.list was previously re-hit on every home, library, and liked-songs
    // load (its 10% error rate dominated the Data API dashboard). Cache it per session.
    private let relatedPlaylistsCache = CacheStore<String, RelatedPlaylists>(
        ttl: AppConfig.Catalog.relatedPlaylistsCacheTTL,
        maxEntries: 4
    )
    private let likedMusicPlaylistID = AppConfig.YouTube.likedMusicPlaylistID
    private let innerTubeClientVersion = AppConfig.YouTube.innerTubeClientVersion

    private var innerTubeSearchURL: URL {
        var components = URLComponents(
            url: AppConfig.YouTube.innerTubeSearchEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "key", value: validatedAPIKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ].compactMap { $0.value == nil ? nil : $0 }

        return components?.url ?? AppConfig.YouTube.innerTubeSearchEndpoint
    }

    init(
        urlSession: URLSession = .shared,
        apiKey: String? = Bundle.main.object(
            forInfoDictionaryKey: AppConfig.YouTube.apiKeyInfoDictionaryKey
        ) as? String,
        logger: any AppLogging = DefaultAppLogger(category: "YouTubeAPIService")
    ) {
        self.urlSession = urlSession
        self.apiKey = apiKey
        self.logger = logger
    }

    func loadHome(accessToken: String) async throws -> (featured: [Track], recent: [Track]) {
        do {
            logger.debug("Loading personalized home content")
            await NetworkLogger.shared.recordAPIRequest(endpoint: "home")
            let home = try await loadAuthorizedHome(accessToken: accessToken)
            logger.info("Loaded personalized home content")
            return home
        } catch {
            logger.error("Failed to load personalized home content", error: error)
            throw mapAPIError(error)
        }
    }

    func search(query: String, accessToken: String?) async throws -> SearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return .empty }

        let validatedQuery: String
        do {
            validatedQuery = try QueryValidator.validateSearchQuery(trimmedQuery)
        } catch let error as QueryValidationError {
            throw APIError.invalidSearchQuery(error)
        }

        let cacheKey = normalizedSearchCacheKey(for: validatedQuery)
        if let cachedResults = await searchCache.value(for: cacheKey) {
            logger.debug("Returning cached search results for query: \(validatedQuery)")
            await NetworkLogger.shared.recordCacheHit(key: "search:\(cacheKey)")
            return cachedResults
        }
        await NetworkLogger.shared.recordCacheMiss(key: "search:\(cacheKey)")

        do {
            logger.debug("Starting search for query: \(validatedQuery)")
            await NetworkLogger.shared.recordAPIRequest(endpoint: "search")
            let results = try await performSearch(query: validatedQuery, accessToken: accessToken)
            await searchCache.set(results, for: cacheKey)
            logger.info("Completed search for query: \(validatedQuery)")
            return results
        } catch {
            logger.error("Search failed for query: \(validatedQuery)", error: error)
            throw mapAPIError(error)
        }
    }

    func loadMoreSearchResults(query: String, continuation: String, accessToken: String?) async throws -> SearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return .empty }

        let validatedQuery: String
        do {
            validatedQuery = try QueryValidator.validateSearchQuery(trimmedQuery)
        } catch let error as QueryValidationError {
            throw APIError.invalidSearchQuery(error)
        }

        do {
            logger.debug("Loading more search results for query: \(validatedQuery)")
            let page = try await fetchTrackSearchPageViaInnerTube(
                query: validatedQuery,
                continuationToken: continuation,
                maxResults: AppConfig.Search.resultsPerPage
            )

            return SearchResponse(
                trackCategory: .init(
                    items: page.tracks,
                    continuationToken: page.continuationToken
                )
            )
        } catch {
            logger.error("Failed to load more search results for query: \(validatedQuery)", error: error)
            throw mapAPIError(error)
        }
    }

    private func performSearch(query: String, accessToken: String?) async throws -> SearchResponse {
        async let trackSearchTask: Result<InnerTubeTrackPage, Error> = {
            do {
                return .success(try await performTrackSearch(query: query, accessToken: accessToken))
            } catch {
                return .failure(error)
            }
        }()
        async let collectionSearchTask: (playlists: [MusicCollection], albums: [MusicCollection], artists: [MusicCollection]) = {
            (try? await performCollectionSearch(query: query)) ??
                (playlists: [], albums: [], artists: [])
        }()

        let trackSearchResult = await trackSearchTask
        let trackPage: InnerTubeTrackPage
        let trackSearchError: Error?
        switch trackSearchResult {
        case .success(let page):
            trackPage = page
            trackSearchError = nil
        case .failure(let error):
            trackPage = InnerTubeTrackPage(tracks: [], continuationToken: nil)
            trackSearchError = error
        }

        let collections = await collectionSearchTask
        let response = SearchResponse(
            trackCategory: .init(
                items: trackPage.tracks,
                continuationToken: trackPage.continuationToken
            ),
            playlistCategory: .init(items: collections.playlists),
            albumCategory: .init(items: collections.albums),
            artistCategory: .init(items: collections.artists)
        )

        if response.isEmpty, let trackSearchError {
            throw trackSearchError
        }

        return response
    }

    private func performTrackSearch(query: String, accessToken: String?) async throws -> InnerTubeTrackPage {
        if let innerTubePage = try? await fetchTrackSearchPageViaInnerTube(
            query: query,
            continuationToken: nil,
            maxResults: AppConfig.Search.resultsPerPage
        ), innerTubePage.tracks.isEmpty == false {
            return innerTubePage
        }

        if let relaxedTracks = try? await fetchRelaxedSearchResultsViaInnerTube(
            query: query,
            maxResults: AppConfig.Search.resultsPerPage
        ), relaxedTracks.isEmpty == false {
            return InnerTubeTrackPage(tracks: relaxedTracks, continuationToken: nil)
        }

        return InnerTubeTrackPage(tracks: [], continuationToken: nil)
    }

    func loadPlaylists(accessToken: String) async throws -> [Playlist] {
        do {
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

            var resolvedPlaylists = resolvedCollections + resolvedUserPlaylists

            if resolvedPlaylists.contains(where: { $0.kind == .likedMusic }) == false {
                // Playlist discovery should stay fast. The song-only liked collection is
                // hydrated once in the background after the Library becomes interactive.
                resolvedPlaylists.insert(
                    Playlist(
                        id: related?.likes ?? likedMusicPlaylistID,
                        title: "Liked Songs",
                        description: "Music-only items from your likes",
                        artworkURL: nil,
                        itemCount: 0,
                        kind: .likedMusic
                    ),
                    at: 0
                )
            }

            let prioritizedPlaylists = prioritizedLibraryPlaylists(resolvedPlaylists)
            if prioritizedPlaylists.isEmpty, let loadError = loadErrors.first {
                throw loadError
            }

            return prioritizedPlaylists
        } catch {
            throw mapAPIError(error)
        }
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
        // Each mix playlist is a paginated playlistItems.list call (the slowest Data API
        // method, ~4s p99). 5 playlists × 16 tracks still gives the featured/recent pool
        // ample variety while cutting the per-home fanout by ~40%.
        let mixAlbums = selectSuggestedMixes(from: playlistSources, limit: 5)
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

    func loadPlaylistItems(for playlist: Playlist, accessToken: String?) async throws -> [Track] {
        do {
            if playlist.kind == .likedMusic, let accessToken {
                return try await fetchLikedMusicTracks(
                    accessToken: accessToken,
                    maxItems: nil
                )
            }

            if let accessToken {
                let authorizedTracks = try? await fetchPlaylistItems(
                    for: playlist,
                    accessToken: accessToken,
                    maxItems: 200
                )
                if let authorizedTracks, authorizedTracks.isEmpty == false {
                    return authorizedTracks
                }
            }

            if let apiKey = validatedAPIKey {
                let apiTracks = try? await fetchPlaylistItems(
                    playlistID: playlist.id,
                    apiKey: apiKey,
                    maxItems: 200
                )
                if let apiTracks, apiTracks.isEmpty == false {
                    return apiTracks
                }
            }

            let webTracks = try await fetchPlaylistItemsViaWeb(
                playlistID: playlist.id,
                maxItems: 200
            )
            if webTracks.isEmpty == false {
                return webTracks
            }

            return []
        } catch {
            throw mapAPIError(error)
        }
    }

    func lookupTrack(videoID: String, accessToken: String?) async throws -> Track? {
        let trimmedVideoID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedVideoID.isEmpty == false else { return nil }

        if let accessToken,
           let authorizedTrack = try? await fetchTrack(videoID: trimmedVideoID, accessToken: accessToken) {
            return authorizedTrack
        }

        if let apiKey = validatedAPIKey,
           let apiTrack = try? await fetchTrack(videoID: trimmedVideoID, apiKey: apiKey) {
            return apiTrack
        }

        let youtube = YouTube(videoID: trimmedVideoID)
        if let metadata = try? await youtube.metadata {
            return Track(
                id: trimmedVideoID,
                title: metadata.title.isEmpty ? "YouTube Video" : metadata.title,
                artist: "YouTube",
                artworkURL: metadata.thumbnail?.url,
                youtubeVideoID: trimmedVideoID
            )
        }

        return Track(
            id: trimmedVideoID,
            title: "YouTube Video",
            artist: "YouTube",
            youtubeVideoID: trimmedVideoID
        )
    }

    func loadCollectionItems(for collection: MusicCollection, accessToken: String?) async throws -> [Track] {
        do {
            switch collection.kind {
            case .playlist, .album:
                do {
                    if let accessToken {
                        let tracks = try await fetchPlaylistItems(
                            playlistID: collection.sourceID,
                            accessToken: accessToken,
                            maxItems: 500
                        )
                        if tracks.isEmpty == false {
                            return tracks
                        }
                    }

                    if let apiKey = validatedAPIKey {
                        let tracks = try await fetchPlaylistItems(
                            playlistID: collection.sourceID,
                            apiKey: apiKey,
                            maxItems: 500
                        )
                        if tracks.isEmpty == false {
                            return tracks
                        }
                    }
                } catch {
                    let webTracks = try await fetchPlaylistItemsViaWeb(
                        playlistID: collection.sourceID,
                        maxItems: 500
                    )
                    if webTracks.isEmpty == false {
                        return webTracks
                    }
                }

                let webTracks = try await fetchPlaylistItemsViaWeb(
                    playlistID: collection.sourceID,
                    maxItems: 500
                )
                if webTracks.isEmpty == false {
                    return webTracks
                }

                let fallbackTracks = try await fallbackTracks(for: collection, limit: 80)
                return fallbackTracks

            case .artist:
                do {
                    return try await fetchArtistTracks(
                        for: collection,
                        accessToken: accessToken,
                        maxItems: 60
                    )
                } catch {
                    let fallbackTracks = try await fallbackTracks(for: collection, limit: 60)
                    if fallbackTracks.isEmpty == false {
                        return fallbackTracks
                    }

                    return []
                }
            }
        } catch {
            throw mapAPIError(error)
        }
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
            let response = try await fetchDataAPIResponse(
                PlaylistSearchResponse.self,
                from: request,
                endpoint: .playlistsList
            )

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
                        // YouTube's likes playlist count includes non-music videos.
                        // The exact song count is applied after the filtered fetch.
                        itemCount: 0,
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
        let response = try await fetchDataAPIResponse(
            PlaylistSearchResponse.self,
            from: request,
            endpoint: .playlistsList
        )
        return response.items.map(playlist(from:))
    }

    private func fetchPlaylistItemsViaWeb(
        playlistID: String,
        maxItems: Int
    ) async throws -> [Track] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/playlist"
        components.queryItems = [URLQueryItem(name: "list", value: playlistID)]

        guard let playlistURL = components.url else {
            return []
        }

        var request = URLRequest(url: playlistURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await urlSession.data(for: request)
        guard let html = String(data: data, encoding: .utf8),
              let object = extractYouTubeInitialData(fromHTML: html) else {
            return []
        }

        let renderers = collectObjects(matchingKey: "playlistVideoRenderer", in: object)
        let tracks = renderers.compactMap(track(fromPlaylistVideoRenderer:))
        return Array(deduplicatedTracks(tracks).prefix(maxItems))
    }

    private func track(fromPlaylistVideoRenderer renderer: [String: Any]) -> Track? {
        guard let videoID = renderer["videoId"] as? String else { return nil }

        let rawTitle = text(from: renderer["title"]) ?? "YouTube Track"
        let rawArtist =
            text(from: renderer["shortBylineText"]) ??
            text(from: renderer["longBylineText"]) ??
            text(from: renderer["ownerText"]) ??
            "YouTube"

        let parsedDuration = text(from: renderer["lengthText"]).flatMap(parseDurationSeconds)
        let artist = cleanArtistName(rawArtist)
        let title = cleanTrackTitle(rawTitle, channelName: artist)

        return Track(
            id: videoID,
            title: title,
            artist: artist,
            artworkURL: bestThumbnailURL(from: renderer["thumbnail"]),
            duration: parsedDuration.map(TimeInterval.init),
            youtubeVideoID: videoID
        )
    }

    private func extractYouTubeInitialData(fromHTML html: String) -> Any? {
        guard let markerRange = html.range(of: "ytInitialData = ") else { return nil }
        let jsonStart = markerRange.upperBound
        guard let openingBraceIndex = html[jsonStart...].firstIndex(of: "{") else { return nil }
        guard let jsonString = balancedJSONObjectString(in: html, startingAt: openingBraceIndex) else {
            return nil
        }

        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func balancedJSONObjectString(in text: String, startingAt startIndex: String.Index) -> String? {
        var index = startIndex
        var depth = 0
        var isInsideString = false
        var isEscaping = false

        while index < text.endIndex {
            let character = text[index]

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else {
                if character == "\"" {
                    isInsideString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[startIndex...index])
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
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

        let response = try await fetchDataAPIResponse(
            VideoSearchResponse.self,
            from: components.url!,
            endpoint: .videosList
        )

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
            "album",
            "audio",
            "topic"
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
                        results = (try? await fetchRelaxedSearchResultsViaInnerTube(
                            query: query,
                            maxResults: 8
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
            "top songs official audio",
            "new album official audio",
            "latest hits official audio",
            "best songs audio",
            "best albums 2026"
        ].shuffled()

        var collectedTracks: [Track] = []
        for query in fallbackQueries.prefix(3) {
            let results = try await fetchSearchResultsViaInnerTube(query: query, maxResults: 12)
            collectedTracks.append(contentsOf: results)
        }

        return Array(deduplicatedTracks(collectedTracks.shuffled()).prefix(25))
    }

    private func fetchRelatedPlaylists(accessToken: String) async throws -> RelatedPlaylists? {
        // Keyed by token so a new sign-in re-resolves; the value itself is immutable.
        let cacheKey = String(accessToken.suffix(16))
        if let cached = await relatedPlaylistsCache.value(for: cacheKey) {
            return cached
        }

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = authorizedQueryItems(
            [
                URLQueryItem(name: "part", value: "contentDetails"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "maxResults", value: "1")
            ]
        )

        let request = authorizedRequest(url: components.url!, accessToken: accessToken)
        let response = try await fetchDataAPIResponse(
            ChannelSearchResponse.self,
            from: request,
            endpoint: .channelsList
        )
        let related = response.items.first?.contentDetails?.relatedPlaylists
        if let related {
            await relatedPlaylistsCache.set(related, for: cacheKey)
        }
        return related
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
            let response = try await fetchDataAPIResponse(
                VideoMetadataResponse.self,
                from: request,
                endpoint: .videosList
            )

            for item in response.items {
                let title = item.snippet.title ?? ""
                let channel = item.snippet.channelTitle ?? ""
                guard !isNonMusicContent(title: title, channel: channel) else { continue }
                guard !looksLikeShorts(title: title) else { continue }
                guard item.snippet.liveBroadcastContent?.lowercased() != "live",
                      item.snippet.liveBroadcastContent?.lowercased() != "upcoming" else {
                    continue
                }
                guard item.snippet.categoryID == "10" else { continue }
                musicVideoIDs.insert(item.id)
            }
        }

        return tracks.filter { track in
            guard let videoID = track.youtubeVideoID else { return false }
            return musicVideoIDs.contains(videoID)
        }
    }

    // MARK: - Metadata enrichment

    /// Fills in missing duration / view count for the supplied tracks using a single
    /// batched `videos.list` call per 50 items (1 quota unit each). Results are cached
    /// aggressively and the call degrades gracefully — when there is no API key or the
    /// Data API is backing off, the original tracks are returned unchanged.
    func fillMissingMetadata(for tracks: [Track]) async -> [Track] {
        guard let apiKey = validatedAPIKey else { return tracks }

        // Only IDs that are actually missing a field need a lookup.
        let missingIDs = tracks.compactMap { track -> String? in
            guard let videoID = track.youtubeVideoID, videoID.isEmpty == false else { return nil }
            return (track.duration == nil || track.viewCount == nil) ? videoID : nil
        }
        guard missingIDs.isEmpty == false else { return tracks }

        var resolved: [String: ResolvedVideoMetadata] = [:]
        var idsToFetch: [String] = []
        var seen: Set<String> = []
        for id in missingIDs where seen.insert(id).inserted {
            if let cached = await videoMetadataCache.value(for: id) {
                resolved[id] = cached
            } else {
                idsToFetch.append(id)
            }
        }

        for batch in idsToFetch.chunked(into: AppConfig.Metadata.batchSize) {
            guard let fetched = try? await fetchVideoMetadata(ids: batch, apiKey: apiKey) else {
                // A failure (quota/backoff/network) shouldn't abandon the cache hits we
                // already gathered — just stop fetching more batches.
                break
            }
            for (id, metadata) in fetched {
                resolved[id] = metadata
                await videoMetadataCache.set(metadata, for: id)
            }
        }

        guard resolved.isEmpty == false else { return tracks }

        return tracks.map { track in
            guard let videoID = track.youtubeVideoID,
                  let metadata = resolved[videoID],
                  track.duration == nil || track.viewCount == nil else {
                return track
            }
            return track.mergingMetadata(duration: metadata.duration, viewCount: metadata.viewCount)
        }
    }

    private func fetchVideoMetadata(ids: [String], apiKey: String) async throws -> [String: ResolvedVideoMetadata] {
        guard ids.isEmpty == false else { return [:] }

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet,contentDetails,statistics"),
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "maxResults", value: String(ids.count)),
            URLQueryItem(name: "key", value: apiKey)
        ]

        await NetworkLogger.shared.recordAPIRequest(endpoint: "videos.metadata")
        let response = try await fetchDataAPIResponse(
            VideoMetadataResponse.self,
            from: components.url!,
            endpoint: .videosList
        )

        var result: [String: ResolvedVideoMetadata] = [:]
        for item in response.items {
            let duration = item.contentDetails?.duration.flatMap(parseISO8601DurationSeconds).map(TimeInterval.init)
            let viewCount = item.statistics?.viewCount.flatMap { Int($0) }
            guard duration != nil || viewCount != nil else { continue }
            result[item.id] = ResolvedVideoMetadata(duration: duration, viewCount: viewCount)
        }
        return result
    }

    /// Parses an ISO 8601 duration (e.g. "PT1H2M30S") into whole seconds.
    func parseISO8601DurationSeconds(_ text: String) -> Int? {
        guard text.hasPrefix("PT") else { return nil }
        var seconds = 0
        var current = ""
        var matched = false
        for character in text.dropFirst(2) {
            if character.isNumber {
                current.append(character)
                continue
            }
            guard let value = Int(current) else { current = ""; continue }
            switch character {
            case "H": seconds += value * 3_600; matched = true
            case "M": seconds += value * 60; matched = true
            case "S": seconds += value; matched = true
            default: break
            }
            current = ""
        }
        return matched ? seconds : nil
    }

    private var validatedAPIKey: String? {
        guard let apiKey, apiKey.isEmpty == false, apiKey.hasPrefix("YOUR_") == false else {
            return nil
        }
        return apiKey
    }

    private func mapAPIError(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }

        if let validationError = error as? QueryValidationError {
            return .invalidSearchQuery(validationError)
        }

        if let urlError = error as? URLError {
            return .networkError(urlError)
        }

        if let decodingError = error as? DecodingError {
            return .decodingError(decodingError)
        }

        return .serviceError(error.localizedDescription)
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

    private func musicSearchTrack(from item: VideoItem) -> Track? {
        guard let videoID = item.id.videoID ?? item.id.raw else { return nil }
        guard isLiveSearchResult(snippet: item.snippet) == false else { return nil }
        return buildMusicSearchTrack(
            videoID: videoID,
            rawTitle: item.snippet.title,
            rawArtist: item.snippet.channelTitle,
            artworkURL: item.snippet.thumbnails.bestURL,
            duration: nil
        )
    }

    private func performCollectionSearch(query: String) async throws -> (playlists: [MusicCollection], albums: [MusicCollection], artists: [MusicCollection]) {
        let object = try await fetchInnerTubeSearchPayload(query: query)
        let playlistRenderers = collectObjects(matchingKey: "playlistRenderer", in: object)
        let channelRenderers = collectObjects(matchingKey: "channelRenderer", in: object)
        let lockupViewModels = collectObjects(matchingKey: "lockupViewModel", in: object)

        var playlists = deduplicatedCollections(
            (playlistRenderers
                .compactMap { musicCollection(fromInnerTubePlaylistRenderer: $0) }
                .filter { $0.kind == .playlist }) +
            lockupViewModels.compactMap { musicCollection(fromInnerTubeLockupViewModel: $0) }
                .filter { $0.kind == .playlist }
        )
        var albums = deduplicatedCollections(
            (playlistRenderers
                .compactMap { musicCollection(fromInnerTubePlaylistRenderer: $0) }
                .filter { $0.kind == .album }) +
            lockupViewModels.compactMap { musicCollection(fromInnerTubeLockupViewModel: $0) }
                .filter { $0.kind == .album }
        )
        let artists = deduplicatedCollections(
            channelRenderers.compactMap(musicCollection(fromInnerTubeChannelRenderer:))
        )

        if albums.count < 6 {
            let albumPayload = try? await fetchInnerTubeSearchPayload(query: "\(query) album")
            if let albumPayload {
                let albumRenderers = collectObjects(matchingKey: "playlistRenderer", in: albumPayload)
                let albumLockups = collectObjects(matchingKey: "lockupViewModel", in: albumPayload)
                albums = deduplicatedCollections(
                    albums +
                    albumRenderers.compactMap {
                        musicCollection(fromInnerTubePlaylistRenderer: $0, forceAlbum: true)
                    } +
                    albumLockups.compactMap {
                        musicCollection(fromInnerTubeLockupViewModel: $0, forceAlbum: true)
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
        try await fetchTrackSearchPageViaInnerTube(
            query: query,
            continuationToken: nil,
            maxResults: maxResults
        ).tracks
    }

    private func fetchTrackSearchPageViaInnerTube(
        query: String,
        continuationToken: String?,
        maxResults: Int
    ) async throws -> InnerTubeTrackPage {
        let object = try await fetchInnerTubeSearchPayload(
            query: continuationToken == nil ? query : nil,
            continuationToken: continuationToken
        )
        let renderers = collectObjects(matchingKey: "videoRenderer", in: object)
        let tracks = renderers.compactMap(track(fromInnerTubeVideoRenderer:))

        return InnerTubeTrackPage(
            tracks: Array(deduplicatedTracks(tracks).prefix(maxResults)),
            continuationToken: firstContinuationToken(in: object)
        )
    }

    private func fetchRelaxedSearchResultsViaInnerTube(
        query: String,
        maxResults: Int
    ) async throws -> [Track] {
        let object = try await fetchInnerTubeSearchPayload(query: query)
        let renderers = collectObjects(matchingKey: "videoRenderer", in: object)
        let tracks = renderers.compactMap(relaxedTrack(fromInnerTubeVideoRenderer:))
        return Array(deduplicatedTracks(tracks).prefix(maxResults))
    }

    private func fetchInnerTubeSearchPayload(query: String? = nil, continuationToken: String? = nil) async throws -> Any {
        var request = URLRequest(url: innerTubeSearchURL)
        request.timeoutInterval = 12
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(innerTubeClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")

        var payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": innerTubeClientVersion
                ]
            ]
        ]

        if let query, query.isEmpty == false {
            payload["query"] = query
        }
        if let continuationToken, continuationToken.isEmpty == false {
            payload["continuation"] = continuationToken
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        try validateStatusCode(for: response, data: data)

        return try JSONSerialization.jsonObject(with: data)
    }

    private func firstContinuationToken(in object: Any) -> String? {
        let continuations = collectObjects(matchingKey: "continuationItemRenderer", in: object)
        return continuations.first.flatMap { continuation in
            ((continuation["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any])?["token"] as? String
        }
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

        let parsedDuration = text(from: renderer["lengthText"]).flatMap(parseDurationSeconds)
        let viewCount = parseViewCount(from:
            text(from: renderer["viewCountText"]) ??
            text(from: renderer["shortViewCountText"])
        )
        return buildMusicSearchTrack(
            videoID: videoID,
            rawTitle: rawTitle,
            rawArtist: rawArtist,
            artworkURL: bestThumbnailURL(from: renderer["thumbnail"]),
            duration: parsedDuration.map(TimeInterval.init),
            viewCount: viewCount
        )
    }

    private func relaxedTrack(fromInnerTubeVideoRenderer renderer: [String: Any]) -> Track? {
        guard let videoID = renderer["videoId"] as? String else { return nil }
        guard isLiveSearchResult(renderer: renderer) == false else { return nil }

        let rawTitle = text(from: renderer["title"]) ?? "YouTube Track"
        let rawArtist =
            text(from: renderer["longBylineText"]) ??
            text(from: renderer["ownerText"]) ??
            text(from: renderer["shortBylineText"]) ??
            "YouTube"

        guard isNonMusicContent(title: rawTitle, channel: rawArtist) == false else { return nil }
        guard looksLikeShorts(title: rawTitle) == false else { return nil }

        let parsedDuration = text(from: renderer["lengthText"]).flatMap(parseDurationSeconds)
        let artist = cleanArtistName(rawArtist)
        let title = cleanTrackTitle(rawTitle, channelName: artist)
        let viewCount = parseViewCount(from:
            text(from: renderer["viewCountText"]) ??
            text(from: renderer["shortViewCountText"])
        )

        return Track(
            id: videoID,
            title: title,
            artist: artist,
            artworkURL: bestThumbnailURL(from: renderer["thumbnail"]),
            duration: parsedDuration.map(TimeInterval.init),
            youtubeVideoID: videoID,
            viewCount: viewCount
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

    private func musicCollection(fromInnerTubeLockupViewModel renderer: [String: Any], forceAlbum: Bool? = nil) -> MusicCollection? {
        guard let sourceID = renderer["contentId"] as? String, sourceID.isEmpty == false else { return nil }
        guard let contentType = renderer["contentType"] as? String, contentType == "LOCKUP_CONTENT_TYPE_PLAYLIST" else {
            return nil
        }

        let title = lockupTitle(from: renderer) ?? "Playlist"
        let metadataParts = lockupMetadataParts(from: renderer)
        let subtitle = metadataParts.first ?? "YouTube"
        let description = metadataParts.joined(separator: " · ")
        let itemCount = parseCount(from: extractLooseText(from: renderer["contentImage"]))
        let artworkURL = extractThumbnailURL(from: renderer["contentImage"])
        let resolvedIsAlbum = forceAlbum ?? sourceID.hasPrefix("OLAK") || isLikelyAlbum(
            title: title,
            subtitle: subtitle,
            description: description
        )
        let kind: MusicCollectionKind = resolvedIsAlbum ? .album : .playlist

        return MusicCollection(
            sourceID: sourceID,
            title: title,
            subtitle: subtitle,
            description: description,
            artworkURL: artworkURL,
            itemCount: itemCount,
            kind: kind,
            queryHint: [title, subtitle, resolvedIsAlbum ? "album" : "playlist"]
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
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

        if let content = dictionary["content"] as? String, content.isEmpty == false {
            return content
        }

        if let simpleText = dictionary["simpleText"] as? String, simpleText.isEmpty == false {
            return simpleText
        }

        if let runs = dictionary["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private func lockupTitle(from renderer: [String: Any]) -> String? {
        (((renderer["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any])?["title"] as? [String: Any])?["content"] as? String
    }

    private func lockupMetadataParts(from renderer: [String: Any]) -> [String] {
        guard
            let metadata = renderer["metadata"] as? [String: Any],
            let lockupMetadata = metadata["lockupMetadataViewModel"] as? [String: Any],
            let metadataContainer = lockupMetadata["metadata"] as? [String: Any],
            let contentMetadata = metadataContainer["contentMetadataViewModel"] as? [String: Any],
            let rows = contentMetadata["metadataRows"] as? [[String: Any]]
        else {
            return []
        }

        return rows.flatMap { row in
            let parts = row["metadataParts"] as? [[String: Any]] ?? []
            return parts.compactMap { part in
                text(from: part["text"])
            }
        }
    }

    private func extractLooseText(from object: Any?) -> String? {
        if let text = text(from: object), text.isEmpty == false {
            return text
        }

        if let string = object as? String, string.isEmpty == false {
            return string
        }

        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                if let nested = extractLooseText(from: value), nested.isEmpty == false {
                    return nested
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let nested = extractLooseText(from: value), nested.isEmpty == false {
                    return nested
                }
            }
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

        return thumbnailURL(from: urlString)
    }

    private func extractThumbnailURL(from object: Any?) -> URL? {
        if let url = bestThumbnailURL(from: object) {
            return url
        }

        if let dictionary = object as? [String: Any] {
            if let urlString = dictionary["url"] as? String,
               let url = thumbnailURL(from: urlString) {
                return url
            }

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

    private func thumbnailURL(from urlString: String) -> URL? {
        let cleaned = urlString.replacingOccurrences(of: "\\/", with: "/")
        if cleaned.hasPrefix("//") {
            return URL(string: "https:\(cleaned)")
        }
        return URL(string: cleaned)
    }

    private func parseCount(from text: String?) -> Int {
        guard let text else { return 0 }
        let digits = text.unicodeScalars.filter(CharacterSet.decimalDigits.contains)
        let numericString = String(String.UnicodeScalarView(digits))
        return Int(numericString) ?? 0
    }

    private func parseViewCount(from text: String?) -> Int? {
        guard let text, text.isEmpty == false else { return nil }
        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "views", with: "")
            .replacingOccurrences(of: "مشاهدة", with: "")
            .trimmingCharacters(in: .whitespaces)

        let multiplier: Double
        let numericPortion: String

        if cleaned.hasSuffix("b") {
            multiplier = 1_000_000_000
            numericPortion = String(cleaned.dropLast())
        } else if cleaned.hasSuffix("m") {
            multiplier = 1_000_000
            numericPortion = String(cleaned.dropLast())
        } else if cleaned.hasSuffix("k") {
            multiplier = 1_000
            numericPortion = String(cleaned.dropLast())
        } else {
            multiplier = 1
            numericPortion = cleaned.filter { $0.isNumber || $0 == "." }
        }

        guard let value = Double(numericPortion.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }

        return Int(value * multiplier)
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

    private func fetchLikedMusicTracks(
        accessToken: String,
        relatedPlaylists: RelatedPlaylists? = nil,
        maxItems: Int?
    ) async throws -> [Track] {
        // `videos.list?myRating=like` already returns category metadata, so it can
        // validate and collect each page in one request. The likes-playlist route is
        // retained only as a resilient fallback because it needs a second metadata
        // request for every page.
        do {
            let ratedTracks = try await fetchLikedMusicTracksByRating(
                accessToken: accessToken,
                maxItems: maxItems
            )
            return limitedTracks(
                deduplicatedTracks(ratedTracks).likedSongsOnly(),
                maxItems: maxItems
            )
        } catch let ratingError {
            let effectiveRelatedPlaylists: RelatedPlaylists?
            if let relatedPlaylists {
                effectiveRelatedPlaylists = relatedPlaylists
            } else {
                effectiveRelatedPlaylists = try? await fetchRelatedPlaylists(accessToken: accessToken)
            }
            guard let likesPlaylistID = effectiveRelatedPlaylists?.likes else {
                throw ratingError
            }

            let likesPlaylist = Playlist(
                id: likesPlaylistID,
                title: "Liked Songs",
                description: "Music-only items from your likes",
                artworkURL: nil,
                itemCount: maxItems ?? 0,
                kind: .likedMusic
            )
            return try await fetchLikedMusicTracksFromLikesPlaylist(
                likesPlaylist: likesPlaylist,
                accessToken: accessToken,
                maxItems: maxItems
            )
        }
    }

    private func fetchLikedMusicTracksFromLikesPlaylist(
        likesPlaylist: Playlist,
        accessToken: String,
        maxItems: Int?
    ) async throws -> [Track] {
        var tracks: [Track] = []
        var seenTrackIDs: Set<String> = []
        var nextPageToken: String?
        let targetCount = maxItems ?? Int.max

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "playlistId", value: likesPlaylist.id),
                URLQueryItem(name: "maxResults", value: "50")
            ]

            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }

            components.queryItems = authorizedQueryItems(queryItems)

            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            let response = try await fetchDataAPIResponse(
                PlaylistItemsResponse.self,
                from: request,
                endpoint: .playlistItemsList
            )

            let pageTracks: [Track] = response.items.compactMap { item in
                guard let videoID = item.snippet.resourceID?.videoID ?? item.contentDetails?.videoID else { return nil }

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

            // Fail closed. The likes playlist can contain every kind of YouTube video;
            // if category validation is unavailable, returning the raw page would leak
            // podcasts, vlogs, and other videos into Liked Songs.
            let filteredPageTracks = pageTracks.isEmpty
                ? []
                : try await filterMusicTracks(pageTracks, accessToken: accessToken)

            for track in filteredPageTracks where seenTrackIDs.insert(trackIdentifier(track)).inserted {
                tracks.append(track)
            }
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && tracks.count < targetCount

        return limitedTracks(tracks, maxItems: maxItems)
    }

    private func fetchLikedMusicTracksByRating(accessToken: String, maxItems: Int?) async throws -> [Track] {
        var tracks: [Track] = []
        var seenTrackIDs: Set<String> = []
        var nextPageToken: String?
        let targetCount = maxItems ?? Int.max

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
            let response = try await fetchDataAPIResponse(
                VideoSearchResponse.self,
                from: request,
                endpoint: .videosList
            )

            let pageTracks = response.items.compactMap { item -> Track? in
                // videos.list supplies the authoritative category here. Missing or
                // non-Music categories are excluded rather than guessed from titles.
                guard item.snippet.categoryID == "10" else { return nil }
                guard !isNonMusicContent(title: item.snippet.title, channel: item.snippet.channelTitle) else {
                    return nil
                }
                guard !looksLikeShorts(title: item.snippet.title) else { return nil }
                return track(from: item)
            }

            for track in pageTracks where seenTrackIDs.insert(trackIdentifier(track)).inserted {
                tracks.append(track)
            }
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && tracks.count < targetCount

        return limitedTracks(tracks, maxItems: maxItems)
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

            let response: PlaylistItemsResponse
            if let accessToken {
                let request = authorizedRequest(url: components.url!, accessToken: accessToken)
                response = try await fetchDataAPIResponse(
                    PlaylistItemsResponse.self,
                    from: request,
                    endpoint: .playlistItemsList
                )
            } else {
                response = try await fetchDataAPIResponse(
                    PlaylistItemsResponse.self,
                    from: components.url!,
                    endpoint: .playlistItemsList
                )
            }

            entries.append(contentsOf: response.items)
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && entries.count < maxItems

        let tracks: [Track] = entries.prefix(maxItems).compactMap { item in
            guard let videoID = item.snippet.resourceID?.videoID ?? item.contentDetails?.videoID else { return nil }

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

    private func fetchTrack(videoID: String, accessToken: String) async throws -> Track? {
        try await fetchTrack(
            videoID: videoID,
            queryItems: authorizedQueryItems([]),
            accessToken: accessToken
        )
    }

    private func fetchTrack(videoID: String, apiKey: String) async throws -> Track? {
        try await fetchTrack(
            videoID: videoID,
            queryItems: [URLQueryItem(name: "key", value: apiKey)],
            accessToken: nil
        )
    }

    private func fetchTrack(
        videoID: String,
        queryItems additionalQueryItems: [URLQueryItem],
        accessToken: String?
    ) async throws -> Track? {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "id", value: videoID),
            URLQueryItem(name: "maxResults", value: "1")
        ]
        queryItems.append(contentsOf: additionalQueryItems)
        components.queryItems = queryItems

        let response: VideoMetadataResponse
        if let accessToken {
            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            response = try await fetchDataAPIResponse(
                VideoMetadataResponse.self,
                from: request,
                endpoint: .videosList
            )
        } else {
            response = try await fetchDataAPIResponse(
                VideoMetadataResponse.self,
                from: components.url!,
                endpoint: .videosList
            )
        }

        guard let item = response.items.first else { return nil }
        return directTrack(from: item)
    }

    private func limitedTracks(_ tracks: [Track], maxItems: Int?) -> [Track] {
        guard let maxItems else { return tracks }
        return Array(tracks.prefix(maxItems))
    }

    private func fetchArtistTracks(
        for collection: MusicCollection,
        accessToken: String?,
        maxItems: Int
    ) async throws -> [Track] {
        if let results = try? await fetchSearchResultsViaInnerTube(
            query: collection.queryHint,
            maxResults: maxItems
        ), results.isEmpty == false {
            return results
        }

        if let results = try? await fetchRelaxedSearchResultsViaInnerTube(
            query: "\(collection.title) songs",
            maxResults: maxItems
        ), results.isEmpty == false {
            return results
        }

        let fallbackPage = try await performTrackSearch(query: "\(collection.title) official audio", accessToken: accessToken)
        return Array(fallbackPage.tracks.prefix(maxItems))
    }

    private func prioritizedLibraryPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let deduplicated = deduplicatedPlaylists(playlists)
        let likedPlaylists = deduplicated.filter { $0.kind == .likedMusic }
        let remainingPlaylists = deduplicated.filter { $0.kind != .likedMusic }
        return likedPlaylists + remainingPlaylists
    }

    private func fallbackTracks(for collection: MusicCollection, limit: Int) async throws -> [Track] {
        let kindHint: String
        switch collection.kind {
        case .playlist:
            kindHint = "playlist"
        case .album:
            kindHint = "album"
        case .artist:
            kindHint = "songs"
        }

        let queries = fallbackQueries(
            title: collection.title,
            subtitle: collection.subtitle.isEmpty ? collection.queryHint : collection.subtitle,
            kindHint: kindHint
        )

        return try await fallbackTracks(queries: queries, limit: limit)
    }

    private func fallbackTracks(
        queries: [String],
        limit: Int
    ) async throws -> [Track] {
        for query in queries {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedQuery.isEmpty == false else { continue }

            let page = try await fetchTrackSearchPageViaInnerTube(
                query: trimmedQuery,
                continuationToken: nil,
                maxResults: limit
            )
            if page.tracks.isEmpty == false {
                return Array(page.tracks.prefix(limit))
            }

            let relaxedTracks = try await fetchRelaxedSearchResultsViaInnerTube(
                query: trimmedQuery,
                maxResults: limit
            )
            if relaxedTracks.isEmpty == false {
                return Array(relaxedTracks.prefix(limit))
            }
        }

        return []
    }

    private func fallbackQueries(title: String, subtitle: String, kindHint: String) -> [String] {
        let titleParts = [title, subtitle]
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            }
            .filter { $0.isEmpty == false }

        let base = titleParts.joined(separator: " ")
        let titleOnly = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let variants = [
            base,
            "\(base) \(kindHint)",
            "\(titleOnly) \(kindHint)",
            "\(titleOnly) official audio",
            "\(titleOnly) full album"
        ]

        return orderedUniqueStrings(variants)
    }

    private func isQuotaOrTransientAPIError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("quota")
            || message.contains("daily limit")
            || message.contains("rate limit")
            || message.contains("backend error")
            || message.contains("temporarily unavailable")
            || message.contains("timed out")
            || message.contains("network connection was lost")
            || message.contains("offline")
            || message.contains("status 429")
            || message.contains("status 500")
            || message.contains("status 502")
            || message.contains("status 503")
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

    private func fetchDataAPIResponse<T: Decodable>(
        _ type: T.Type,
        from request: URLRequest,
        endpoint: DataAPIEndpoint
    ) async throws -> T {
        try await dataAPIBackoffGate.check(endpoint)
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            await dataAPIBackoffGate.recordFailure(
                endpoint,
                backoffDelay: dataAPIBackoffDelay(for: error)
            )
            throw error
        }

        return try await decodeDataAPIResponse(type, from: data, response: urlResponse, endpoint: endpoint)
    }

    private func fetchDataAPIResponse<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        endpoint: DataAPIEndpoint
    ) async throws -> T {
        try await dataAPIBackoffGate.check(endpoint)
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(from: url)
        } catch {
            await dataAPIBackoffGate.recordFailure(
                endpoint,
                backoffDelay: dataAPIBackoffDelay(for: error)
            )
            throw error
        }

        return try await decodeDataAPIResponse(type, from: data, response: urlResponse, endpoint: endpoint)
    }

    private func decodeDataAPIResponse<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        response: URLResponse,
        endpoint: DataAPIEndpoint
    ) async throws -> T {
        do {
            let decoded = try decodeResponse(type, from: data, response: response)
            await dataAPIBackoffGate.recordSuccess(endpoint)
            return decoded
        } catch {
            await dataAPIBackoffGate.recordFailure(
                endpoint,
                backoffDelay: dataAPIBackoffDelay(for: error)
            )
            throw error
        }
    }

    private func dataAPIBackoffDelay(for error: Error) -> TimeInterval? {
        if let apiError = error as? APIError {
            switch apiError {
            case .rateLimited(let retryAfter):
                return max(retryAfter ?? AppConfig.Catalog.dataAPIDeniedBackoff, AppConfig.Catalog.dataAPITransientBackoff)
            case .invalidResponse(let statusCode, _):
                if statusCode == 403 {
                    return AppConfig.Catalog.dataAPIDeniedBackoff
                }
                if [500, 502, 503, 504].contains(statusCode) {
                    return AppConfig.Catalog.dataAPITransientBackoff
                }
            case .networkError:
                return AppConfig.Catalog.dataAPINetworkBackoff
            case .serviceError(let message):
                let normalizedMessage = message.lowercased()
                if normalizedMessage.contains("quota")
                    || normalizedMessage.contains("daily limit")
                    || normalizedMessage.contains("rate limit")
                    || normalizedMessage.contains("permission")
                    || normalizedMessage.contains("denied")
                    || normalizedMessage.contains("forbidden") {
                    return AppConfig.Catalog.dataAPIDeniedBackoff
                }
            default:
                break
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost:
                return AppConfig.Catalog.dataAPINetworkBackoff
            default:
                return nil
            }
        }

        return nil
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse) throws -> T {
        try validateStatusCode(for: response, data: data)

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw APIError.decodingError(error)
        }
    }

    private func validateStatusCode(for response: URLResponse, data: Data) throws {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        let retryAfter = retryAfterInterval(from: httpResponse)
        let sanitizedMessage = sanitizedErrorMessage(from: data)

        if let statusCode, (200 ..< 300).contains(statusCode) == false {
            switch statusCode {
            case 401:
                throw APIError.authenticationFailure
            case 403:
                throw APIError.invalidResponse(statusCode: statusCode, message: sanitizedMessage ?? "YouTube denied that request.")
            case 404:
                throw APIError.notFound
            case 429:
                throw APIError.rateLimited(retryAfter: retryAfter)
            default:
                throw APIError.invalidResponse(statusCode: statusCode, message: sanitizedMessage)
            }
        }

        if let sanitizedMessage {
            throw APIError.serviceError(sanitizedMessage)
        }
    }

    private func retryAfterInterval(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let interval = TimeInterval(value) {
            return interval
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        guard let retryDate = formatter.date(from: value) else { return nil }
        return max(retryDate.timeIntervalSinceNow, 0)
    }

    private func sanitizedErrorMessage(from data: Data) -> String? {
        guard let apiError = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data),
              let message = apiError.error?.message,
              message.isEmpty == false else {
            return nil
        }

        return message.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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
    let contentDetails: VideoContentDetails?
    let statistics: VideoStatistics?

    enum CodingKeys: String, CodingKey {
        case id
        case snippet
        case contentDetails
        case statistics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        snippet = try container.decode(VideoMetadataSnippet.self, forKey: .snippet)
        contentDetails = try container.decodeIfPresent(VideoContentDetails.self, forKey: .contentDetails)
        statistics = try container.decodeIfPresent(VideoStatistics.self, forKey: .statistics)
    }
}

private struct ResolvedVideoMetadata {
    let duration: TimeInterval?
    let viewCount: Int?
}

private struct VideoContentDetails: Decodable {
    /// ISO 8601 duration, e.g. "PT3M20S".
    let duration: String?
}

private struct VideoStatistics: Decodable {
    let viewCount: String?
}

private struct VideoMetadataSnippet: Decodable {
    let categoryID: String?
    let title: String?
    let channelTitle: String?
    let thumbnails: ThumbnailCollection?
    let liveBroadcastContent: String?

    enum CodingKeys: String, CodingKey {
        case categoryID = "categoryId"
        case title
        case channelTitle
        case thumbnails
        case liveBroadcastContent
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

private struct RelatedPlaylists: Decodable, Sendable {
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
    let contentDetails: PlaylistEntryContentDetails?
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

private struct PlaylistEntryContentDetails: Decodable {
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

    private enum CodingKeys: String, CodingKey {
        case url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let urlString = try container.decodeIfPresent(String.self, forKey: .url)
        url = urlString.flatMap(Self.normalizedRemoteURL(from:))
    }

    private static func normalizedRemoteURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if trimmed.hasPrefix("//") {
            return URL(string: "https:\(trimmed)")
        }

        return URL(string: trimmed)
    }
}

private struct GoogleAPIErrorEnvelope: Decodable {
    let error: GoogleAPIError?
}

private struct GoogleAPIError: Decodable {
    let message: String?
    let code: Int?
}

// MARK: - Music Content Helpers

private extension YouTubeAPIService {
    func directTrack(from item: VideoMetadataItem) -> Track? {
        guard let rawTitle = item.snippet.title, rawTitle.isEmpty == false else { return nil }

        let rawArtist = item.snippet.channelTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = rawArtist?.isEmpty == false ? cleanArtistName(rawArtist!) : "YouTube"
        let title = cleanTrackTitle(rawTitle, channelName: artist)

        return Track(
            id: item.id,
            title: title,
            artist: artist,
            artworkURL: item.snippet.thumbnails?.bestURL,
            youtubeVideoID: item.id
        )
    }

    func buildMusicSearchTrack(
        videoID: String,
        rawTitle: String,
        rawArtist: String,
        artworkURL: URL?,
        duration: TimeInterval?,
        viewCount: Int? = nil
    ) -> Track? {
        guard isNonMusicContent(title: rawTitle, channel: rawArtist) == false else { return nil }
        guard isStrictMusicSearchCandidate(title: rawTitle, artist: rawArtist, duration: duration) else {
            return nil
        }

        let artist = cleanArtistName(rawArtist)
        let title = cleanTrackTitle(rawTitle, channelName: artist)
        let track = Track(
            id: videoID,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            duration: duration,
            youtubeVideoID: videoID,
            viewCount: viewCount
        )

        return track.isEligibleForMusicSuggestions ? track : nil
    }

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

    func isStrictMusicSearchCandidate(title: String, artist: String, duration: TimeInterval?) -> Bool {
        let searchText = "\(title) \(artist)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let videoKeywords = [
            "official music video", "music video", "official video", "video clip",
            "lyric video", "lyrics video", "lyrics", "visualizer",
            "live session", "live performance", "concert", "performance", "session"
        ]
        if videoKeywords.contains(where: searchText.contains) {
            return false
        }

        if searchText.contains("shorts") || searchText.contains("#shorts") {
            return false
        }

        if let duration {
            if duration < 60 || duration > 900 {
                return false
            }
        }

        var score = 0
        if searchText.contains("official audio") || searchText.contains("[audio]") || searchText.contains("(audio)") {
            score += 5
        }
        if searchText.contains("album") || searchText.contains("ep") {
            score += 2
        }
        if artist.lowercased().contains("topic") {
            score += 4
        }
        if let duration {
            switch duration {
            case 90 ... 540:
                score += 3
            case 60 ... 780:
                score += 1
            default:
                break
            }
        }

        return score > 0
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

    func looksLikeShorts(title: String) -> Bool {
        let normalized = title.lowercased()
        return normalized.contains("shorts") || normalized.contains("#shorts")
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

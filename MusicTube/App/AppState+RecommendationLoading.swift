import Foundation

@MainActor
extension AppState {
    func starterRecommendations(
        limit: Int,
        excluding excludedIdentifiers: Set<String>
    ) async -> [Track] {
        let starterQueries = [
            "top songs official audio",
            "new music official audio",
            "arabic songs official audio",
            "worship songs official audio",
            "afrobeats official audio",
            "acoustic songs official audio",
            "indie pop official audio",
            "chill music official audio"
        ]

        let resultBuckets = await withTaskGroup(of: [Track]?.self) { group in
            let accessToken = await authorizedAccessTokenIfAvailable()
            for query in starterQueries {
                group.addTask {
                    do {
                        let results = try await self.catalogService.search(query: query, accessToken: accessToken)
                        let bucket = Array(results.songs.prefix(16))
                        return bucket.isEmpty ? nil : bucket
                    } catch {
                        return nil
                    }
                }
            }

            var buckets: [[Track]] = []
            for await bucket in group {
                if let bucket {
                    buckets.append(bucket)
                }
            }
            return buckets
        }

        guard resultBuckets.isEmpty == false else { return [] }

        var collected: [Track] = []
        var seen = excludedIdentifiers
        var offsets = Array(repeating: 0, count: resultBuckets.count)

        while collected.count < limit {
            var appendedTrackThisRound = false

            for bucketIndex in resultBuckets.indices {
                while offsets[bucketIndex] < resultBuckets[bucketIndex].count {
                    let track = resultBuckets[bucketIndex][offsets[bucketIndex]]
                    offsets[bucketIndex] += 1

                    let identifier = trackIdentifier(track)
                    guard seen.insert(identifier).inserted else { continue }

                    collected.append(track)
                    appendedTrackThisRound = true
                    break
                }

                if collected.count >= limit {
                    break
                }
            }

            if appendedTrackThisRound == false {
                break
            }
        }

        return curatedSuggestionTracks(collected)
    }

    func smartRecommendations(
        limit: Int,
        excluding excludedIdentifiers: Set<String>,
        focusedTrack: Track? = nil,
        forceRefresh: Bool = false
    ) async -> [Track] {
        guard allowsOptionalNetworkWork(forceRefresh: forceRefresh) else {
            return []
        }

        let context = recommendationSeedContext(focusedTrack: focusedTrack)
        guard context.seedQueries.isEmpty == false else {
            return []
        }

        let accessToken = await authorizedAccessTokenIfAvailable()
        let selectedSeeds = balancedRecommendationSeeds(
            from: context.seedQueries,
            focused: focusedTrack != nil
        )
        let resultLimit = focusedTrack == nil ? 10 : 12

        let resultBuckets = await withTaskGroup(of: RecommendationBucket?.self) { group in
            // Seven searches is a hard fan-out ceiling. Each comes from a different
            // signal family before any family receives a second slot.
            for (ordinal, seed) in selectedSeeds.enumerated() {
                group.addTask {
                    await self.loadRecommendationBucket(
                        for: seed,
                        ordinal: ordinal,
                        accessToken: accessToken,
                        limit: resultLimit
                    )
                }
            }

            var buckets: [RecommendationBucket] = []
            for await bucket in group {
                if let bucket {
                    buckets.append(bucket)
                }
            }
            return buckets.sorted { $0.ordinal < $1.ordinal }
        }

        guard Task.isCancelled == false else { return [] }
        guard resultBuckets.isEmpty == false else { return [] }

        var candidateSources: [String: Set<RecommendationSeedFamily>] = [:]
        for bucket in resultBuckets {
            for track in bucket.tracks {
                candidateSources[trackIdentifier(track), default: []].insert(bucket.seed.family)
            }
        }

        let eligibleTracks = curatedSuggestionTracks(
            deduplicatedBySignature(resultBuckets.flatMap(\.tracks))
        ).filter { track in
            let identifier = trackIdentifier(track)
            guard context.suppressedTrackKeys.contains(identifier) == false else { return false }
            return recommendationContextCompatible(track, context: context)
        }
        interactionTracker.registerTracks(eligibleTracks)
        let profileSnapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let collected = await recommendationEngine.recommendations(
            for: RecommendationRequest(
                candidates: eligibleTracks,
                recentTracks: profileSnapshot.recentTracks,
                likedTracks: locallyVisibleLikedTracks(from: profileSnapshot),
                savedTracks: profileSnapshot.savedTracks,
                recentlyRecommended: recentRecommendationExposures(),
                recommendationExposures: recentRecommendationExposureRecords(),
                behaviorInsights: profileSnapshot.behaviorInsights,
                candidateSourcesByTrackID: candidateSources,
                dislikedTrackIDs: dislikedTrackIDs,
                preferences: userPreferenceProfile,
                focusedTrack: focusedTrack,
                activeContext: context.activeContentContext,
                activeQuranDomain: context.activeQuranDomain,
                sessionArtistAdjustments: context.sessionArtistAdjustments,
                sessionSkippedTrackIDs: context.suppressedTrackKeys,
                excludedTrackIDs: excludedIdentifiers,
                limit: limit
            )
        )

        let locallyCurated = applyingPendingAICuration(to: collected)
        scheduleAICuration(of: locallyCurated, focusedTrack: focusedTrack)
        return locallyCurated
    }

    func scheduleAICuration(of tracks: [Track], focusedTrack: Track?) {
        guard tracks.count > 1, DataUsageSettings.shared.personalizedAICuration else {
            if focusedTrack == nil { recommendationBlurb = nil }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let reranked = await self.applyAICuration(to: tracks, focusedTrack: focusedTrack)
            guard reranked.map(self.trackIdentifier) != tracks.map(self.trackIdentifier) else { return }

            if focusedTrack == nil {
                // Stage the result for the next feed generation. A late AI response
                // must never move the shelf currently under the user's finger.
                self.pendingAICuratedTrackIDs = reranked.map(self.trackIdentifier)
            } else {
                // Related remains deterministic during the active player session too.
                self.pendingAICuratedTrackIDs = reranked.map(self.trackIdentifier)
            }
        }
    }

    func applyingPendingAICuration(to tracks: [Track]) -> [Track] {
        guard pendingAICuratedTrackIDs.isEmpty == false else { return tracks }
        let ranks = Dictionary(uniqueKeysWithValues: pendingAICuratedTrackIDs.enumerated().map { ($0.element, $0.offset) })
        let reordered = tracks.enumerated().sorted { lhs, rhs in
            let left = ranks[trackIdentifier(lhs.element)]
            let right = ranks[trackIdentifier(rhs.element)]
            switch (left, right) {
            case let (.some(a), .some(b)): return a < b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }.map(\.element)
        pendingAICuratedTrackIDs = []
        return reordered
    }

    func reorderingCurrentRecommendations(
        _ current: [Track],
        preferredOrder: [Track]
    ) -> [Track] {
        let ranks = Dictionary(
            uniqueKeysWithValues: preferredOrder.enumerated().map {
                (trackIdentifier($0.element), $0.offset)
            }
        )
        return current.enumerated().sorted { lhs, rhs in
            let leftRank = ranks[trackIdentifier(lhs.element)]
            let rightRank = ranks[trackIdentifier(rhs.element)]
            switch (leftRank, rightRank) {
            case let (.some(left), .some(right)): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Optional AI pass over the deterministic shortlist: re-orders by taste fit and, for
    /// the home shelf, publishes a short "why these picks" blurb. Falls back to the
    /// engine's own ordering whenever curation is unconfigured or returns nothing.
    func applyAICuration(to tracks: [Track], focusedTrack: Track?) async -> [Track] {
        guard tracks.count > 1 else { return tracks }
        guard DataUsageSettings.shared.personalizedAICuration else {
            if focusedTrack == nil { recommendationBlurb = nil }
            return tracks
        }

        let briefs = tracks.map {
            OpenRouterService.TrackBrief(id: trackIdentifier($0), title: $0.title, artist: $0.artist)
        }
        let result = await openRouterService.rerank(briefs, for: aiTasteSignals(focusedTrack: focusedTrack))

        // Only the home shelf surfaces the blurb; focused "radio" refreshes keep it quiet.
        if focusedTrack == nil {
            recommendationBlurb = result.blurb
        }

        guard result.orderedIDs.isEmpty == false else { return tracks }

        let byID = Dictionary(uniqueKeysWithValues: tracks.map { (trackIdentifier($0), $0) })
        var reordered: [Track] = []
        var placed = Set<String>()
        for id in result.orderedIDs {
            guard let track = byID[id], placed.insert(id).inserted else { continue }
            reordered.append(track)
        }
        // Append anything the model omitted, preserving the engine's original order.
        for track in tracks where placed.contains(trackIdentifier(track)) == false {
            reordered.append(track)
        }
        return reordered
    }

    /// Builds the compact, `Sendable` taste snapshot handed to the optional AI curator.
    func aiTasteSignals(focusedTrack: Track?) -> OpenRouterService.TasteSignals {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let likedSeedTracks = curatedSuggestionTracks(locallyVisibleLikedTracks(from: snapshot))
        let savedSeedTracks = curatedSuggestionTracks(snapshot.savedTracks)
        let lovedTracks = (savedSeedTracks + likedSeedTracks)
            .prefix(14)
            .map { "\($0.artist) — \($0.title)" }
        let topArtists = orderedUniqueQueries(
            snapshot.topArtists + savedSeedTracks.map(\.artist) + likedSeedTracks.map(\.artist)
        )
        let skippedArtists = snapshot.behaviorInsights
            .filter { $0.skipCount >= 2 && $0.averageListenRatio < 0.35 }
            .map(\.track.artist)

        return OpenRouterService.TasteSignals(
            topArtists: Array(topArtists.prefix(12)),
            lovedTracks: Array(lovedTracks),
            recentSearches: Array(recentSearches.prefix(8)),
            preferenceKeywords: Array(snapshot.preferenceProfile.normalizedKeywords.prefix(10)),
            skippedArtists: Array(orderedUniqueQueries(skippedArtists).prefix(8)),
            focusedTrack: focusedTrack.map { "\($0.artist) — \($0.title)" }
        )
    }

    func algorithmicRecommendations(
        from catalog: [Track],
        focusedTrack: Track?,
        excluding excludedIdentifiers: Set<String>
    ) -> [Track] {
        guard catalog.isEmpty == false else { return [] }

        let history = interactionTracker.allInteractions()
        let collaborative = interactionTracker.getRecommendationsFromSimilarProfiles(
            userHistory: history,
            globalTrendingTracks: catalog
        )
        let contentSeed = focusedTrack
            ?? history
                .sorted {
                    interactionTracker.calculateAffinityScore(for: $0.trackId)
                        > interactionTracker.calculateAffinityScore(for: $1.trackId)
                }
                .compactMap { interaction in
                    catalog.first { trackIdentifier($0) == interaction.trackId }
                }
                .first
        let similar = contentSeed.map {
            interactionTracker.findSimilarContent(targetTrack: $0, fullCatalog: catalog)
        } ?? []

        return deduplicatedTracks(collaborative + similar)
            .filter { excludedIdentifiers.contains(trackIdentifier($0)) == false }
    }

    func relatedTracks(for track: Track, limit: Int) async -> [Track] {
        let queries = focusedRelatedQueries(for: track)
        guard queries.isEmpty == false else { return [] }

        let accessToken = await authorizedAccessTokenIfAvailable()
        let excludedTrackID = trackIdentifier(track)
        let resultBuckets = await withTaskGroup(of: (Int, [Track]).self) { group in
            for (index, query) in queries.prefix(4).enumerated() {
                group.addTask {
                    guard let response = try? await self.catalogService.search(query: query, accessToken: accessToken) else {
                        return (index, [])
                    }
                    return (index, response.songs)
                }
            }

            var buckets: [(Int, [Track])] = []
            for await bucket in group where bucket.1.isEmpty == false {
                buckets.append(bucket)
            }
            return buckets.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        let candidates = relatedCandidateTracks(
            deduplicatedTracks(resultBuckets.flatMap { $0 })
                .filter { trackIdentifier($0) != excludedTrackID },
            to: track
        )

        guard candidates.isEmpty == false else { return [] }

        return rankedRelatedCandidates(candidates, to: track, limit: limit)
    }

    func focusedRelatedQueries(for track: Track) -> [String] {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = meaningfulArtistName(from: track.artist)
        var queries: [String] = []

        if let artist {
            queries.append("\(artist) \(title)")
        }

        if title.isEmpty == false {
            queries.append(title)
            if track.isQuranOrRecitation, containsArabicText(title) {
                queries.append("\(title) تلاوة")
            } else if track.isQuranOrRecitation {
                queries.append("\(title) quran recitation")
            } else if track.listeningContentContext == .music,
                      containsArabicText(title) == false {
                queries.append("\(title) official audio")
            }
        }

        if let artist {
            queries.append("\(artist) songs")
        }

        return orderedUniqueQueries(queries)
    }

    func localRelatedTracks(for focusedTrack: Track, limit: Int) -> [Track] {
        let candidates = playbackService.currentQueue
            + featuredTracks
            + recentTracks
            + historyTracks
            + searchSuggestionTracks
            + downloadService.availableDownloads.map(\.track)
        let filtered = relatedCandidateTracks(
            deduplicatedTracks(candidates)
                .filter { trackIdentifier($0) != trackIdentifier(focusedTrack) },
            to: focusedTrack
        )
        return rankedRelatedCandidates(filtered, to: focusedTrack, limit: limit)
    }

    func relatedCandidateTracks(_ tracks: [Track], to focusedTrack: Track) -> [Track] {
        let playable = tracks.filter { candidate in
            candidate.isPlayableContent
                && candidate.isLikelyShortFormVideo == false
                && dislikedTrackIDs.contains(trackIdentifier(candidate)) == false
        }
        let focusedContext = focusedTrack.listeningContentContext
        let contextMatches = playable.filter { candidate in
            guard candidate.isQuranOrRecitation == focusedTrack.isQuranOrRecitation else {
                return false
            }
            let candidateContext = candidate.listeningContentContext
            return focusedContext == .unknown || candidateContext == focusedContext
        }

        if contextMatches.isEmpty == false {
            return contextMatches
        }
        return playable.filter { candidate in
            candidate.isQuranOrRecitation == focusedTrack.isQuranOrRecitation
                && (focusedContext == .unknown || candidate.listeningContentContext == focusedContext)
        }
    }

    func rankedRelatedCandidates(_ candidates: [Track], to focusedTrack: Track, limit: Int) -> [Track] {
        Array(
            candidates.enumerated()
                .map { index, candidate in
                    (
                        track: candidate,
                        score: relatednessScore(candidate, to: focusedTrack),
                        ordinal: index
                    )
                }
                .sorted {
                    if $0.score != $1.score {
                        return $0.score > $1.score
                    }
                    let leftViews = $0.track.viewCount ?? 0
                    let rightViews = $1.track.viewCount ?? 0
                    if leftViews != rightViews {
                        return leftViews > rightViews
                    }
                    return $0.ordinal < $1.ordinal
                }
                .map(\.track)
                .prefix(max(0, limit))
        )
    }

    func meaningfulArtistName(from artist: String) -> String? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let normalized = SearchTextNormalizer.normalized(trimmed)
        guard normalized != "musictube", normalized != "youtube", normalized != "unknown" else {
            return nil
        }
        return trimmed
    }

    func relatednessScore(_ candidate: Track, to focusedTrack: Track) -> Double {
        let focusedTitleTokens = Set(SearchTextNormalizer.tokens(from: focusedTrack.title))
        let focusedArtistTokens = Set(SearchTextNormalizer.tokens(from: meaningfulArtistName(from: focusedTrack.artist) ?? ""))
        let candidateTitleTokens = Set(SearchTextNormalizer.tokens(from: candidate.title))
        let candidateArtistTokens = Set(SearchTextNormalizer.tokens(from: candidate.artist))
        let candidateAllTokens = candidateTitleTokens.union(candidateArtistTokens)

        var score = 0.0
        let titleOverlap = focusedTitleTokens.intersection(candidateAllTokens).count
        let artistOverlap = focusedArtistTokens.intersection(candidateAllTokens).count

        score += Double(titleOverlap) * 3.0
        score += Double(artistOverlap) * 4.0

        if let focusedArtist = meaningfulArtistName(from: focusedTrack.artist),
           SearchTextNormalizer.normalized(candidate.artist) == SearchTextNormalizer.normalized(focusedArtist) {
            score += 8.0
        }

        if containsArabicText(focusedTrack.title),
           containsArabicText(candidate.title) || containsArabicText(candidate.artist) {
            score += 1.5
        }

        if candidate.isLikelyShortFormVideo {
            score -= 4.0
        }

        return score
    }

    func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenTrackIDs: Set<String> = []
        return tracks.filter { track in
            let identifier = trackIdentifier(track)
            return seenTrackIDs.insert(identifier).inserted
        }
    }

    /// A canonical content signature used to catch the same song re-uploaded under
    /// different video IDs/channels and with presentation labels such as "official
    /// video" or "lyrics". Two items with the same signature are duplicates.
    func trackSignature(_ track: Track) -> String {
        RecommendationTrackIdentity.contentSignature(for: track)
    }

    /// Removes duplicates by stable video ID first, then by content signature
    /// (title + artist + duration). Order is preserved. Items with an empty title
    /// are only de-duplicated by ID to avoid collapsing unrelated placeholders.
    func deduplicatedBySignature(_ tracks: [Track]) -> [Track] {
        var seenIDs: Set<String> = []
        var seenSignatures: Set<String> = []
        var result: [Track] = []
        for track in tracks {
            guard seenIDs.insert(trackIdentifier(track)).inserted else { continue }
            let normalizedTitle = SearchTextNormalizer.normalized(track.title)
            if normalizedTitle.isEmpty == false {
                guard seenSignatures.insert(trackSignature(track)).inserted else { continue }
            }
            result.append(track)
        }
        return result
    }

    /// Identifiers of songs the user has already heard or already has on device —
    /// used to keep "Recommended For You" fresh rather than echoing the user's history.
    func alreadyKnownTrackIdentifiers() -> Set<String> {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        var ids = Set<String>()
        ids.formUnion(snapshot.recentTracks.map(trackIdentifier))
        ids.formUnion(snapshot.topTracks.map(trackIdentifier))
        ids.formUnion(historyTracks.map(trackIdentifier))
        ids.formUnion(downloadService.availableDownloads.map { trackIdentifier($0.track) })
        ids.formUnion(recentRecommendationExposures().map(trackIdentifier))
        if let nowPlayingTrack {
            ids.insert(trackIdentifier(nowPlayingTrack))
        }
        return ids
    }

    func curatedSuggestionTracks(_ tracks: [Track]) -> [Track] {
        let withoutShorts = tracks.filter { $0.isLikelyShortFormVideo == false }
        let curated = withoutShorts.filter(\.isEligibleForMusicSuggestions)
        let pool = curated.isEmpty ? withoutShorts : curated
        return pool.filter { dislikedTrackIDs.contains(trackIdentifier($0)) == false }
    }

}

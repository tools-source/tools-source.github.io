import Foundation

@MainActor
extension AppState {
    func recommendationSeedContext(focusedTrack: Track?) -> RecommendationSeedContext {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let activeTrack = focusedTrack ?? nowPlayingTrack
        let activeContentContext = activeTrack?.listeningContentContext ?? .music
        let activeQuranDomain = activeTrack?.isQuranOrRecitation ?? false

        func isCompatibleSeed(_ track: Track) -> Bool {
            if activeQuranDomain {
                return track.isQuranOrRecitation
            }
            guard track.isQuranOrRecitation == false else { return false }
            return track.listeningContentContext == activeContentContext
        }

        // Seed construction runs on the UI actor because it snapshots AppState. Keep
        // the working set bounded; the engine still receives the complete taste data
        // for scoring away from the main actor.
        let visibleLikedTracks = locallyVisibleLikedTracks(from: snapshot)
        let savedSeedTracks = curatedSuggestionTracks(Array(snapshot.savedTracks.prefix(240)))
            .filter(isCompatibleSeed)
        let likedSeedTracks = curatedSuggestionTracks(Array(visibleLikedTracks.prefix(240)))
            .filter(isCompatibleSeed)
        let behaviorSeedTracks = snapshot.behaviorInsights
            .filter { isCompatibleSeed($0.track) }
            .sorted {
                let lhsScore = recommendationAffinityScore(for: $0)
                let rhsScore = recommendationAffinityScore(for: $1)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return $0.lastInteractedAt > $1.lastInteractedAt
            }
            .map(\.track)
        let positiveInsights = snapshot.behaviorInsights.filter {
            isCompatibleSeed($0.track) &&
            recommendationAffinityScore(for: $0) >= 2.0
        }
        let skippedInsights = snapshot.behaviorInsights.filter {
            $0.skipCount >= max(2, $0.completedListenCount + 1)
                && $0.averageListenRatio < 0.35
        }
        let suppressedTrackKeys = Set(
            skippedInsights
                .filter { $0.skipCount >= 2 && $0.completedListenCount == 0 }
                .map { trackIdentifier($0.track) }
        )
        let topArtists = orderedUniqueQueries(
            snapshot.topArtists +
            savedSeedTracks.map(\.artist) +
            likedSeedTracks.map(\.artist) +
            positiveInsights
                .sorted {
                    recommendationAffinityScore(for: $0) > recommendationAffinityScore(for: $1)
                }
                .map(\.track.artist) +
            savedArtistCollections.map(\.title)
        )
        var seedQueries: [RecommendationSeedQuery] = []

        func appendSeed(
            _ query: String,
            family: RecommendationSeedFamily,
            lane: RecommendationLane
        ) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return }
            seedQueries.append(RecommendationSeedQuery(query: trimmed, family: family, lane: lane))
        }

        if let focusedTrack, focusedTrack.isEligibleForMusicSuggestions {
            appendSeed("\(focusedTrack.artist) \(focusedTrack.title)", family: .focusedTrack, lane: .familiar)
            appendSeed("\(focusedTrack.artist) songs", family: .focusedTrack, lane: .discovery)
            appendSeed("\(focusedTrack.title) related songs", family: .focusedTrack, lane: .discovery)
        }

        for track in likedSeedTracks.prefix(4) {
            appendSeed("\(track.artist) songs", family: .likedSongs, lane: .familiar)
        }
        for track in savedSeedTracks.prefix(4) {
            appendSeed("\(track.artist) \(track.title) related songs", family: .savedSongs, lane: .discovery)
        }
        for track in behaviorSeedTracks.prefix(5) {
            appendSeed("\(track.artist) \(track.title)", family: .completedListens, lane: .familiar)
        }
        for artist in topArtists.prefix(5) {
            appendSeed("\(artist) official audio", family: .topArtists, lane: .familiar)
        }
        for search in recentSearches.prefix(4) {
            appendSeed(search, family: .recentSearches, lane: .discovery)
        }
        for collection in savedArtistCollections.prefix(3) {
            appendSeed("\(collection.title) songs", family: .savedSongs, lane: .discovery)
        }

        let preferenceKeywords = snapshot.preferenceProfile.normalizedKeywords
        for keyword in preferenceKeywords.prefix(6) {
            let preferenceContext = preferenceContentContext(for: keyword)
            guard preferenceContext == nil || preferenceContext == activeContentContext else { continue }
            appendSeed("\(keyword) music", family: .preferences, lane: .discovery)
        }
        for outcome in recentRecommendationOutcomes.reversed()
            where outcome.skipped == false && isCompatibleSeed(outcome.track) {
            appendSeed(
                "\(outcome.track.artist) similar artists",
                family: .successfulDiscovery,
                lane: .discovery
            )
        }
        let explorationAnchors = orderedUniqueQueries(
            likedSeedTracks.map(\.artist)
                + savedSeedTracks.map(\.artist)
                + preferenceKeywords
        )
        for anchor in explorationAnchors.prefix(4) {
            appendSeed("\(anchor) radio songs", family: .exploration, lane: .exploration)
        }

        var seenSeedQueries: Set<String> = []
        seedQueries = seedQueries.filter {
            seenSeedQueries.insert(SearchTextNormalizer.normalized($0.query)).inserted
        }

        let behaviorInsightsByTrackKey = Dictionary(
            uniqueKeysWithValues: snapshot.behaviorInsights.map { (trackIdentifier($0.track), $0) }
        )
        let behaviorInsightsByArtist = Dictionary(grouping: snapshot.behaviorInsights) {
            normalizedRecommendationText($0.track.artist)
        }
        let preferenceKeywordTokens = Set(preferenceKeywords.flatMap { SearchTextNormalizer.tokens(from: $0) })
        let preferenceContentContexts = preferenceContentContexts(from: snapshot.preferenceProfile.selectedTags)
        let keywordSources = recentSearches
            + topArtists
            + savedCollections.map(\.queryHint)
            + savedCollections.map(\.title)
            + savedCollections.map(\.subtitle)
            + savedSeedTracks.map(\.title)
            + likedSeedTracks.map(\.title)
            + behaviorSeedTracks.map(\.title)
            + preferenceKeywords
            + [focusedTrack?.artist, focusedTrack?.title].compactMap { $0 }
        let downloadedTrackKeys = Set(downloadService.availableDownloads.map { trackIdentifier($0.track) })
        let collaborativeSeedTrackKeys = collaborativeRecommendationSeedTrackKeys
            .union(featuredTracks.map(trackIdentifier))
            .union(recentTracks.map(trackIdentifier))
        let sessionAdjustment = sessionRecommendationAdjustments(positiveInsights: positiveInsights)

        return RecommendationSeedContext(
            queries: seedQueries.map(\.query),
            seedQueries: seedQueries,
            preferredArtists: Set(topArtists.prefix(10).map(normalizedRecommendationText)),
            focusedArtist: focusedTrack.map { normalizedRecommendationText($0.artist) },
            focusedTitleTokens: Set(SearchTextNormalizer.tokens(from: focusedTrack?.title ?? "")),
            keywordTokens: Set(keywordSources.flatMap { SearchTextNormalizer.tokens(from: $0) }).union(preferenceKeywordTokens),
            behaviorInsightsByTrackKey: behaviorInsightsByTrackKey,
            behaviorInsightsByArtist: behaviorInsightsByArtist,
            likedTrackKeys: Set(visibleLikedTracks.map(trackIdentifier)),
            savedTrackKeys: Set(snapshot.savedTracks.map(trackIdentifier)),
            downloadedTrackKeys: downloadedTrackKeys,
            collaborativeSeedTrackKeys: collaborativeSeedTrackKeys,
            strongPositiveArtists: Set(positiveInsights.map { normalizedRecommendationText($0.track.artist) }),
            skippedArtists: Set(skippedInsights.map { normalizedRecommendationText($0.track.artist) }),
            suppressedTrackKeys: suppressedTrackKeys.union(sessionAdjustment.suppressedTrackKeys),
            sessionArtistAdjustments: sessionAdjustment.artistAdjustments,
            preferenceKeywords: Set(preferenceKeywords.map(normalizedRecommendationText)),
            preferenceContentContexts: preferenceContentContexts,
            activeContentContext: activeContentContext,
            activeQuranDomain: activeQuranDomain
        )
    }

    func sessionRecommendationAdjustments(
        positiveInsights: [TrackBehaviorInsight]
    ) -> (artistAdjustments: [String: Double], suppressedTrackKeys: Set<String>) {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        let recentOutcomes = recentRecommendationOutcomes.filter { $0.recordedAt >= cutoff }
        guard recentOutcomes.isEmpty == false else { return ([:], []) }

        var consecutiveSkips = 0
        for outcome in recentOutcomes.reversed() {
            guard outcome.skipped else { break }
            consecutiveSkips += 1
        }

        var artistAdjustments: [String: Double] = [:]
        var skipCountsByTrackKey: [String: Int] = [:]

        for outcome in recentOutcomes {
            let artistKey = normalizedRecommendationText(outcome.track.artist)
            guard artistKey.isEmpty == false else { continue }

            if outcome.skipped {
                skipCountsByTrackKey[trackIdentifier(outcome.track), default: 0] += 1
                let streakMultiplier = consecutiveSkips >= 2 ? Double(min(consecutiveSkips, 4)) : 1
                artistAdjustments[artistKey, default: 0] -= min(0.65, 0.16 * streakMultiplier)
            } else {
                artistAdjustments[artistKey, default: 0] += 0.22
            }
        }

        if consecutiveSkips >= 2 {
            let preferenceBoost = min(0.42, Double(consecutiveSkips) * 0.08)
            for insight in positiveInsights
                .sorted(by: { recommendationAffinityScore(for: $0) > recommendationAffinityScore(for: $1) })
                .prefix(8) {
                let artistKey = normalizedRecommendationText(insight.track.artist)
                guard artistKey.isEmpty == false else { continue }
                artistAdjustments[artistKey, default: 0] += preferenceBoost
            }
        }

        let suppressedTrackKeys = Set(skipCountsByTrackKey.compactMap { key, count in
            count >= 1 ? key : nil
        })
        return (artistAdjustments, suppressedTrackKeys)
    }

    func preferenceContentContexts(from tags: [UserPreferenceTag]) -> Set<ListeningContentContext> {
        Set(tags.compactMap { preferenceContentContext(for: $0.name) })
    }

    func preferenceContentContext(for value: String) -> ListeningContentContext? {
        let normalized = normalizedRecommendationText(value)
        if normalized.contains("podcast") { return .podcast }
        if normalized.contains("audiobook") || normalized.contains("audio book") { return .audiobook }
        if normalized.contains("religious") || normalized.contains("worship") || normalized.contains("quran") || normalized.contains("recitation") {
            return .religious
        }
        if normalized.contains("education") || normalized.contains("study") || normalized.contains("course") || normalized.contains("learn") {
            return .educational
        }
        if normalized.contains("kid") || normalized.contains("children") { return .kids }
        if normalized.contains("news") { return .news }
        if normalized.contains("sport") { return .sports }
        if normalized.contains("music") || normalized.contains("song") || normalized.contains("jazz") || normalized.contains("oud") || normalized.contains("pop") || normalized.contains("rock") || normalized.contains("lofi") {
            return .music
        }
        return nil
    }

    func strongestRecentContentContext(from insights: [TrackBehaviorInsight]) -> ListeningContentContext? {
        let ranked = insights
            .sorted {
                let lhsScore = recommendationAffinityScore(for: $0)
                let rhsScore = recommendationAffinityScore(for: $1)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return $0.lastInteractedAt > $1.lastInteractedAt
            }

        return ranked
            .map { $0.track.listeningContentContext }
            .first { $0 != .unknown }
    }

    func contentContextCompatibility(
        candidate: ListeningContentContext,
        active: ListeningContentContext?
    ) -> Double {
        guard let active, active != .unknown, candidate != .unknown else { return 0 }
        if candidate == active { return 0.28 }

        switch (active, candidate) {
        case (.music, .religious), (.religious, .music),
             (.podcast, .music), (.audiobook, .music),
             (.kids, .news), (.news, .kids):
            return -0.55
        case (.podcast, .audiobook), (.audiobook, .podcast),
             (.educational, .podcast), (.educational, .audiobook):
            return 0.08
        default:
            return -0.18
        }
    }

    func loadRecommendationBucket(
        for seed: RecommendationSeedQuery,
        ordinal: Int,
        accessToken: String?,
        limit: Int
    ) async -> RecommendationBucket? {
        let query = seed.query
        let normalizedQuery = SearchTextNormalizer.normalized(query)
        guard normalizedQuery.isEmpty == false else { return nil }

        if let cachedTracks = await recommendationCandidateCache.value(for: normalizedQuery), cachedTracks.isEmpty == false {
            return RecommendationBucket(seed: seed, ordinal: ordinal, tracks: cachedTracks)
        }

        guard let response = try? await catalogService.search(query: query, accessToken: accessToken) else {
            return nil
        }

        let tracks = Array(curatedSuggestionTracks(response.songs).prefix(limit))
        guard tracks.isEmpty == false else { return nil }
        await recommendationCandidateCache.set(tracks, for: normalizedQuery)
        return RecommendationBucket(seed: seed, ordinal: ordinal, tracks: tracks)
    }

    func balancedRecommendationSeeds(
        from seeds: [RecommendationSeedQuery],
        focused: Bool
    ) -> [RecommendationSeedQuery] {
        guard seeds.isEmpty == false else { return [] }
        let limit = focused ? 4 : 7
        let cursor = recommendationExposureStore.rotationCursor(profileID: currentProfileID)
        let baseOrder: [RecommendationSeedFamily] = focused
            ? [.focusedTrack, .likedSongs, .completedListens, .savedSongs, .successfulDiscovery, .exploration]
            : [.likedSongs, .completedListens, .savedSongs, .topArtists, .recentSearches, .preferences, .successfulDiscovery, .exploration]
        let fixedPrefix: [RecommendationSeedFamily] = focused ? [.focusedTrack] : []
        let rotatable = baseOrder.filter { fixedPrefix.contains($0) == false }
        let rotation = rotatable.isEmpty ? 0 : cursor % rotatable.count
        let rotatedFamilies = rotatable.isEmpty
            ? []
            : Array(rotatable[rotation...]) + Array(rotatable[..<rotation])
        let familyOrder = fixedPrefix + rotatedFamilies
        let grouped = Dictionary(grouping: seeds, by: \.family)
        var offsets: [RecommendationSeedFamily: Int] = [:]
        var selected: [RecommendationSeedQuery] = []

        // Round-robin across signal families. Only after every available family has
        // contributed once can any family take a second retrieval slot.
        while selected.count < limit {
            var appended = false
            for family in familyOrder {
                let bucket = grouped[family, default: []]
                guard bucket.isEmpty == false else { continue }
                let offset = offsets[family, default: 0]
                guard offset < bucket.count else { continue }
                let rotatedOffset = (offset + cursor) % bucket.count
                selected.append(bucket[rotatedOffset])
                offsets[family] = offset + 1
                appended = true
                if selected.count == limit { break }
            }
            if appended == false { break }
        }
        return selected
    }

    func recommendationContextCompatible(
        _ track: Track,
        context: RecommendationSeedContext
    ) -> Bool {
        if let quranDomain = context.activeQuranDomain,
           track.isQuranOrRecitation != quranDomain {
            return false
        }
        guard let active = context.activeContentContext, active != .unknown else { return true }
        return track.listeningContentContext == active
    }

    func recommendationScore(
        for track: Track,
        context: RecommendationSeedContext,
        collaborativeHitCount: Int,
        totalBucketCount: Int
    ) -> RecommendationScoreComponents {
        let trackKey = trackIdentifier(track)
        let normalizedArtist = normalizedRecommendationText(track.artist)
        let candidateTokens = Set(SearchTextNormalizer.tokens(from: "\(track.artist) \(track.title)"))
        let sessionAdjustment = context.sessionArtistAdjustments[normalizedArtist] ?? 0
        let candidateContext = track.listeningContentContext

        let collaborativeSeedMatch = context.collaborativeSeedTrackKeys.contains(trackKey) ? 1.0 : 0.0
        let collaborativeConsensus = totalBucketCount > 0
            ? min(1, Double(collaborativeHitCount) / Double(max(1, min(totalBucketCount, 3))))
            : 0
        let collaborativeScore = max(collaborativeSeedMatch, collaborativeConsensus)

        var contentScore = 0.0
        if context.preferredArtists.contains(normalizedArtist) {
            contentScore += 0.45
        }
        if context.strongPositiveArtists.contains(normalizedArtist) {
            contentScore += 0.35
        }
        if let focusedArtist = context.focusedArtist, normalizedArtist == focusedArtist {
            contentScore += 0.35
        }
        let focusedOverlap = context.focusedTitleTokens.intersection(candidateTokens).count
        if focusedOverlap > 0 {
            contentScore += min(0.25, Double(focusedOverlap) * 0.1)
        }
        let keywordOverlap = context.keywordTokens.intersection(candidateTokens).count
        if keywordOverlap > 0 {
            contentScore += min(0.3, Double(keywordOverlap) * 0.06)
        }
        let preferenceOverlap = context.preferenceKeywords.reduce(0) { partialResult, keyword in
            partialResult + (candidateTokens.contains(keyword) ? 1 : 0)
        }
        if preferenceOverlap > 0 {
            contentScore += min(0.18, Double(preferenceOverlap) * 0.06)
        }
        if context.preferenceContentContexts.contains(candidateContext) {
            contentScore += 0.12
        }
        contentScore += contentContextCompatibility(candidate: candidateContext, active: context.activeContentContext)
        contentScore = max(0, min(1, contentScore))

        var behaviorScore = 0.0
        if context.likedTrackKeys.contains(trackKey) {
            behaviorScore += 0.3
        }
        if context.savedTrackKeys.contains(trackKey) {
            behaviorScore += 0.2
        }
        if context.downloadedTrackKeys.contains(trackKey) {
            behaviorScore += 0.2
        }

        if let insight = context.behaviorInsightsByTrackKey[trackKey] {
            // Completion rate and repeat listens are the strongest "I love this"
            // signals (per Spotify/YT Music), so they out-weigh raw play count.
            behaviorScore += min(0.18, Double(insight.playCount) * 0.03)
            behaviorScore += min(0.16, Double(insight.repeatCount) * 0.05)
            behaviorScore += min(0.24, Double(insight.completedListenCount) * 0.07)
            behaviorScore += min(0.20, insight.averageListenRatio * 0.20)
            behaviorScore -= min(0.18, Double(insight.skipCount) * 0.05)
        } else if let artistInsights = context.behaviorInsightsByArtist[normalizedArtist], artistInsights.isEmpty == false {
            // Fresh recommendations rarely have a per-track history, so artist-level
            // engagement is what carries the user's taste onto songs they haven't
            // heard yet. Completion + repeat dominate here too.
            let aggregatePlayCount = artistInsights.reduce(0) { $0 + $1.playCount }
            let aggregateRepeatCount = artistInsights.reduce(0) { $0 + $1.repeatCount }
            let aggregateSkipCount = artistInsights.reduce(0) { $0 + $1.skipCount }
            let aggregateCompletedCount = artistInsights.reduce(0) { $0 + $1.completedListenCount }
            let averageListenRatio = artistInsights.reduce(0.0) { $0 + $1.averageListenRatio } / Double(artistInsights.count)

            behaviorScore += min(0.18, Double(aggregatePlayCount) * 0.015)
            behaviorScore += min(0.16, Double(aggregateRepeatCount) * 0.04)
            behaviorScore += min(0.24, Double(aggregateCompletedCount) * 0.05)
            behaviorScore += min(0.16, averageListenRatio * 0.16)
            behaviorScore -= min(0.12, Double(aggregateSkipCount) * 0.03)
        }

        if context.skippedArtists.contains(normalizedArtist),
           context.strongPositiveArtists.contains(normalizedArtist) == false {
            behaviorScore -= 0.25
        }
        behaviorScore += sessionAdjustment
        if context.suppressedTrackKeys.contains(trackKey) {
            behaviorScore -= 0.55
        }

        behaviorScore = max(0, min(1, behaviorScore))

        return RecommendationScoreComponents(
            collaborative: collaborativeScore,
            contentSimilarity: contentScore,
            behavior: behaviorScore
        )
    }

    func recommendationAffinityScore(for insight: TrackBehaviorInsight) -> Double {
        let recencyDays = max(0, Date().timeIntervalSince(insight.lastInteractedAt) / 86_400)
        let recencyBoost = max(0, 1.2 - recencyDays * 0.05)
        let completedBoost = Double(insight.completedListenCount) * 3.0
        let repeatBoost = Double(insight.repeatCount) * 0.7
        let playBoost = min(3.5, Double(insight.playCount) * 0.5)
        let qualityBoost = insight.averageListenRatio * 2.5
        let skipPenalty = min(5.0, Double(insight.skipCount) * 1.25)
        return max(0, playBoost + completedBoost + repeatBoost + qualityBoost + recencyBoost - skipPenalty)
    }

    func rankedRecommendationCandidates(
        _ tracks: [Track],
        context: RecommendationSeedContext,
        limit: Int,
        excluding excludedIdentifiers: Set<String>
    ) -> [Track] {
        let curated = curatedSuggestionTracks(deduplicatedBySignature(tracks))
        guard curated.isEmpty == false else { return [] }

        var collaborativeHitCounts: [String: Int] = [:]
        for track in curated {
            collaborativeHitCounts[trackIdentifier(track), default: 0] += 1
        }

        // Does the listener have enough taste signal that we can safely drop
        // popularity-only filler without emptying the shelf?
        let hasTasteSignals = context.preferredArtists.isEmpty == false
            || context.strongPositiveArtists.isEmpty == false
            || context.preferenceContentContexts.isEmpty == false
            || context.preferenceKeywords.isEmpty == false
            || context.behaviorInsightsByTrackKey.isEmpty == false
            || context.likedTrackKeys.isEmpty == false
            || context.savedTrackKeys.isEmpty == false

        let scored = curated.map { track -> (track: Track, components: RecommendationScoreComponents) in
            (
                track,
                recommendationScore(
                    for: track,
                    context: context,
                    collaborativeHitCount: collaborativeHitCounts[trackIdentifier(track), default: 0],
                    totalBucketCount: 3
                )
            )
        }

        func isSuppressed(_ track: Track) -> Bool {
            context.suppressedTrackKeys.contains(trackIdentifier(track))
        }
        func isPreferredArtist(_ track: Track) -> Bool {
            let artist = normalizedRecommendationText(track.artist)
            return context.preferredArtists.contains(artist) || context.strongPositiveArtists.contains(artist)
        }

        // Base gate: original behavior (drops suppressed + near-zero scorers).
        func passesBaseGate(_ candidate: (track: Track, components: RecommendationScoreComponents)) -> Bool {
            guard isSuppressed(candidate.track) == false else { return false }
            return candidate.components.total > 0.10 || isPreferredArtist(candidate.track)
        }

        // Taste gate: requires real taste alignment (content match, engagement, or a
        // preferred artist). A globally-popular song that only scores through the
        // collaborative/popularity term — with no tie to the listener's taste — is
        // dropped, which is what keeps off-taste "random" picks out of the shelf.
        func passesTasteGate(_ candidate: (track: Track, components: RecommendationScoreComponents)) -> Bool {
            guard isSuppressed(candidate.track) == false else { return false }
            if isPreferredArtist(candidate.track) { return true }
            let tasteSignal = candidate.components.contentSimilarity + candidate.components.behavior
            return tasteSignal >= 0.14 || candidate.components.total >= 0.45
        }

        let baseFiltered = scored.filter(passesBaseGate)
        let tasteFiltered = hasTasteSignals ? scored.filter(passesTasteGate) : []

        // Use the strict taste set when it is healthy; otherwise fall back to the
        // base set (topped with any taste hits) so the shelf is never thin or empty.
        let minHealthyCount = min(limit, 8)
        let filtered: [(track: Track, components: RecommendationScoreComponents)]
        if hasTasteSignals, tasteFiltered.count >= minHealthyCount {
            filtered = tasteFiltered
        } else if hasTasteSignals {
            var seenIDs = Set(tasteFiltered.map { trackIdentifier($0.track) })
            var merged = tasteFiltered
            for candidate in baseFiltered where seenIDs.insert(trackIdentifier(candidate.track)).inserted {
                merged.append(candidate)
            }
            filtered = merged
        } else {
            filtered = baseFiltered
        }

        let ranked = filtered.sorted {
            if $0.components.total != $1.components.total {
                return $0.components.total > $1.components.total
            }
            return ($0.track.viewCount ?? 0) > ($1.track.viewCount ?? 0)
        }

        var seen = excludedIdentifiers
        let eligible = ranked.compactMap { candidate -> Track? in
            guard seen.insert(trackIdentifier(candidate.track)).inserted else { return nil }
            return candidate.track
        }
        return diversifiedRecommendationTracks(eligible, limit: limit)
    }

    /// Playback recency is ordered newest-first. Session outcomes cover tracks that
    /// may not have reached persistent history yet; history keeps the rule effective
    /// across launches and CarPlay reconnects.
    func recommendationDiversityRecents() -> [Track] {
        var tracks: [Track] = []
        if let nowPlayingTrack {
            tracks.append(nowPlayingTrack)
        }
        tracks.append(contentsOf: recentRecommendationOutcomes.reversed().map(\.track))
        tracks.append(contentsOf: historyTracks)
        return tracks
    }

    func diversifiedRecommendationTracks(_ tracks: [Track], limit: Int) -> [Track] {
        RecommendationDiversityPolicy.diversified(
            tracks,
            recentlyPlayed: recommendationDiversityRecents(),
            recentlyRecommended: recentRecommendationExposures(),
            recommendationExposures: recentRecommendationExposureRecords(),
            limit: limit
        )
    }

    func recentRecommendationExposures(limit: Int = 120) -> [Track] {
        Array(recommendationRotationExposures.prefix(max(0, limit)))
    }

    func recentRecommendationExposureRecords(limit: Int = 120) -> [RecommendationExposure] {
        recommendationExposureStore.recentExposures(
            profileID: currentProfileID,
            limit: limit
        )
    }

    /// Called as a card becomes visible. Recording impressions instead of only plays
    /// prevents an ignored song from occupying the same prime Home slot indefinitely.
    func recordRecommendationImpression(_ track: Track) {
        recordRecommendationImpressions([track])
    }

    /// CarPlay presents several recommendations at once and does not expose per-row
    /// visibility callbacks. Recording the prime shelf in one write keeps its novelty
    /// history aligned with Home without causing a preferences write for every tile.
    func recordRecommendationImpressions(_ tracks: [Track]) {
        recommendationExposureStore.record(tracks, profileID: currentProfileID)
    }

    /// Rotates the deterministic taste-query list while preserving its ranked order.
    /// The cursor persists, so pull-to-refresh and a later launch do not restart at the
    /// exact same three artists/searches.
    func rotatedRecommendationQueries(_ queries: [String]) -> [String] {
        let unique = orderedUniqueQueries(queries)
        guard unique.count > 1 else { return unique }
        let offset = recommendationExposureStore.rotationCursor(profileID: currentProfileID) % unique.count
        guard offset > 0 else { return unique }
        return Array(unique[offset...]) + Array(unique[..<offset])
    }

    /// Shared by CarPlay's quick-play action and recommendation carousels. Rebuilding
    /// from the current history means every drive starts with the freshest available
    /// song instead of always replaying `featuredTracks.first`.
    func recommendationPlaybackQueue(limit: Int = 60) -> [Track] {
        let activeTrack = nowPlayingTrack
        let quranDomain = activeTrack?.isQuranOrRecitation ?? false
        let contentContext = activeTrack?.listeningContentContext ?? .music
        func isCompatible(_ track: Track) -> Bool {
            guard track.isQuranOrRecitation == quranDomain else { return false }
            return contentContext == .unknown || track.listeningContentContext == contentContext
        }

        // Queue composition is latency-sensitive (CarPlay can request it repeatedly).
        // It needs only context filtering—not the full profile/seed snapshot.
        let personalized = featuredTracks.filter(isCompatible)
        let related = relatedTracks.filter(isCompatible)
        let familiarFallback = (recentTracks + historyTracks).filter {
            isCompatible($0)
        }
        return RecommendationDiversityPolicy.diversified(
            curatedSuggestionTracks(
                deduplicatedBySignature(personalized + related + familiarFallback)
            ),
            recentlyPlayed: recommendationDiversityRecents(),
            recentlyRecommended: recentRecommendationExposures(),
            recommendationExposures: recentRecommendationExposureRecords(),
            limit: limit,
            recentWindow: 60,
            artistGap: 3
        )
    }

    func normalizedRecommendationText(_ value: String) -> String {
        SearchTextNormalizer.normalized(value)
    }

    func containsArabicText(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value)
        }
    }

    func hasPersonalizedRecommendationSignals() -> Bool {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let hasPlaylistSignals = playlists.contains {
            ($0.kind == .standard || $0.kind == .custom || $0.kind == .uploads) && $0.itemCount > 0
        }

        return snapshot.topArtists.isEmpty == false
            || snapshot.savedTracks.isEmpty == false
            || locallyVisibleLikedTracks(from: snapshot).isEmpty == false
            || snapshot.topTracks.isEmpty == false
            || snapshot.recentTracks.isEmpty == false
            || snapshot.behaviorInsights.isEmpty == false
            || snapshot.recentSearches.isEmpty == false
            || snapshot.preferenceProfile.selectedTags.isEmpty == false
            || savedArtistCollections.isEmpty == false
            || hasPlaylistSignals
    }

    func starterRecommendationsStatusMessage(expiredSessionFallback: Bool) -> String {
        if expiredSessionFallback {
            return "Your YouTube session expired, so MusicTube is using starter picks for now."
        }

        return isYouTubeConnected
            ? "Starter picks while MusicTube rebuilds your recommendations."
            : "Starter picks while MusicTube learns what you like."
    }

}

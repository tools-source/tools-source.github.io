import AVFoundation
import XCTest
@testable import MusicTube

final class MusicTubeCoreTests: XCTestCase {
    func testLaunchExperienceOnlyBlocksInteractionOnce() {
        let suiteName = "MusicTubeCoreTests.Launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(LaunchExperiencePolicy.shouldPresent(defaults: defaults))
        LaunchExperiencePolicy.markPresented(defaults: defaults)
        XCTAssertFalse(LaunchExperiencePolicy.shouldPresent(defaults: defaults))
    }

    func testPlaybackRecoveryBudgetStopsAnInfiniteFailureLoop() {
        var budget = PlaybackRecoveryBudget(maximumAttempts: 1)

        XCTAssertTrue(budget.consumeIfAvailable())
        XCTAssertFalse(budget.consumeIfAvailable())

        budget.reset()
        XCTAssertTrue(budget.consumeIfAvailable())
    }

    func testPlayingTrackResumesAfterSeek() {
        XCTAssertTrue(
            PlaybackService.shouldResumeAfterSeek(
                userInitiatedPause: false,
                isPlaying: true,
                playerRate: 0,
                isStartingPlayback: false
            )
        )
    }

    func testWaitingTrackResumesAfterSeekFromItsDesiredRate() {
        XCTAssertTrue(
            PlaybackService.shouldResumeAfterSeek(
                userInitiatedPause: false,
                isPlaying: false,
                playerRate: 1,
                isStartingPlayback: false
            )
        )
    }

    func testPausedTrackStaysPausedAfterSeek() {
        XCTAssertFalse(
            PlaybackService.shouldResumeAfterSeek(
                userInitiatedPause: true,
                isPlaying: true,
                playerRate: 1,
                isStartingPlayback: true
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldResumeAfterSeek(
                userInitiatedPause: false,
                isPlaying: false,
                playerRate: 0,
                isStartingPlayback: false
            )
        )
    }

    @MainActor
    func testRootErrorMessageBindingDoesNotRecurse() {
        let appState = AppState.makeDefault()
        let root = RootViewModel(appState: appState)

        appState.errorMessage = "Playback failed"
        XCTAssertEqual(root.errorMessage, "Playback failed")

        root.errorMessage = nil
        XCTAssertNil(appState.errorMessage)
    }

    @MainActor
    func testRemotePlaybackItemDoesNotWaitForDurationMetadata() {
        let remoteURL = URL(string: "https://example.com/two-hour-track.m4a")!
        let remoteItem = PlaybackService.makePlayerItem(for: remoteURL)

        XCTAssertFalse(remoteItem.automaticallyLoadedAssetKeys.contains("duration"))
        XCTAssertTrue(remoteItem.automaticallyLoadedAssetKeys.contains("playable"))
    }

    func testLongGooglevideoStreamsUseBoundedRangeLoader() throws {
        let longStreamURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&mime=audio%2Fmp4"
        ))
        let loader = try XCTUnwrap(BoundedHTTPStreamLoader(sourceURL: longStreamURL))

        XCTAssertEqual(loader.asset.url.scheme, "musictube-stream")
        XCTAssertEqual(BoundedHTTPStreamLoader.maximumRangeLength, 512 * 1_024)
        XCTAssertNotNil(BoundedHTTPStreamLoader(sourceURL: URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?mime=video%2Fmp4&c=TVHTML5"
        )!))
        XCTAssertNil(BoundedHTTPStreamLoader(sourceURL: URL(string: "https://example.com/audio.m4a")!))
    }

    func testBoundedRangeLoaderIsOnlyAOneTimeFallback() throws {
        let googleVideoURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&mime=audio%2Fmp4"
        ))

        XCTAssertTrue(
            PlaybackService.shouldUseBoundedLoaderFallback(
                for: googleVideoURL,
                currentlyUsingBoundedLoader: false
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldUseBoundedLoaderFallback(
                for: googleVideoURL,
                currentlyUsingBoundedLoader: true
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldUseBoundedLoaderFallback(
                for: URL(string: "https://example.com/audio.m4a")!,
                currentlyUsingBoundedLoader: false
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldUseBoundedLoaderFallback(
                for: URL(string:
                    "https://manifest.googlevideo.com/api/manifest/hls_playlist/playlist/index.m3u8"
                )!,
                currentlyUsingBoundedLoader: false
            )
        )
    }

    func testProgressiveStartupFallbackDoesNotWaitTheFullWatchdog() throws {
        let googleVideoURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&mime=audio%2Fmp4"
        ))

        XCTAssertEqual(
            PlaybackService.startupWaitTimeoutNanoseconds(
                for: googleVideoURL,
                currentlyUsingBoundedLoader: false
            ),
            AppConfig.Playback.progressiveFallbackWaitTimeoutNanoseconds
        )
        XCTAssertEqual(
            PlaybackService.startupWaitTimeoutNanoseconds(
                for: googleVideoURL,
                currentlyUsingBoundedLoader: true
            ),
            AppConfig.Playback.startupWaitTimeoutNanoseconds
        )
    }

    func testInteractivePlaybackPromotesLocalOnlyPrefetch() {
        XCTAssertTrue(
            PlaybackService.shouldPromotePrefetch(
                existingUsesRemoteFallback: false,
                requestedUsesRemoteFallback: true
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldPromotePrefetch(
                existingUsesRemoteFallback: true,
                requestedUsesRemoteFallback: true
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldPromotePrefetch(
                existingUsesRemoteFallback: false,
                requestedUsesRemoteFallback: false
            )
        )
    }

    func testQueueWarmupContinuesForActiveBackgroundCarPlayPlayback() {
        XCTAssertTrue(
            PlaybackService.shouldAllowQueueWarmup(
                isAppInBackground: true,
                isCarPlayConnected: true,
                isPlaybackActive: true
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldAllowQueueWarmup(
                isAppInBackground: true,
                isCarPlayConnected: false,
                isPlaybackActive: true
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldAllowQueueWarmup(
                isAppInBackground: true,
                isCarPlayConnected: true,
                isPlaybackActive: false
            )
        )
        XCTAssertTrue(
            PlaybackService.shouldAllowQueueWarmup(
                isAppInBackground: false,
                isCarPlayConnected: false,
                isPlaybackActive: false
            )
        )
    }

    func testProoflessLongMobileAudioURLRequiresProgressiveFallback() throws {
        let restrictedURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&c=IOS&mime=audio%2Fmp4"
        ))
        let proofedURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&c=IOS&pot=proof"
        ))
        let shortURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=900000&c=ANDROID_VR"
        ))
        let missingLengthURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?c=IOS&mime=audio%2Fmp4"
        ))
        let tvURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&c=TVHTML5"
        ))

        XCTAssertTrue(PlaybackService.isLikelyProofRestrictedAudioURL(restrictedURL))
        XCTAssertFalse(PlaybackService.isLikelyProofRestrictedAudioURL(proofedURL))
        XCTAssertFalse(PlaybackService.isLikelyProofRestrictedAudioURL(shortURL))
        XCTAssertTrue(PlaybackService.isLikelyProofRestrictedAudioURL(missingLengthURL))
        XCTAssertFalse(PlaybackService.isLikelyProofRestrictedAudioURL(tvURL))
    }

    func testHLSManifestDetectionCoversYouTubeAndStandardPlaylists() throws {
        let youtubeManifest = try XCTUnwrap(URL(string:
            "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/1999999999/playlist/index.m3u8"
        ))
        let standardManifest = try XCTUnwrap(URL(string: "https://example.com/audio/master.m3u8"))
        let directMedia = try XCTUnwrap(URL(string: "https://example.com/audio.m4a"))

        XCTAssertTrue(PlaybackService.isHLSManifestURL(youtubeManifest))
        XCTAssertTrue(PlaybackService.isHLSManifestURL(standardManifest))
        XCTAssertFalse(PlaybackService.isHLSManifestURL(directMedia))
    }

    func testDownloadsPreferRemoteExtractionWithLocalFallback() {
        XCTAssertEqual(PlaybackService.downloadExtractionMethods, [.remote, .local])
    }

    func testInteractivePlaybackPrefersRemoteExtractionWithLocalFallback() {
        XCTAssertEqual(PlaybackService.playbackExtractionMethods, [.remote, .local])
    }

    func testYouTubeTrackDurationWinsOverPaddedStreamDuration() {
        let duration = PlaybackService.preferredAuthoritativeDuration(
            trackDuration: 203,
            streamDurations: [406]
        )

        XCTAssertEqual(duration, 203)
    }

    func testGoogleVideoURLDurationIsUsedWhenMetadataIsMissing() throws {
        let streamURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?mime=audio%2Fmp4&dur=203.417&clen=4000000"
        ))

        let urlDuration = try XCTUnwrap(PlaybackService.durationFromStreamURL(streamURL))
        let preferredDuration = try XCTUnwrap(
            PlaybackService.preferredAuthoritativeDuration(
                trackDuration: nil,
                streamURLs: [streamURL]
            )
        )

        XCTAssertEqual(urlDuration, 203.417, accuracy: 0.001)
        XCTAssertEqual(preferredDuration, 203.417, accuracy: 0.001)
    }

    @MainActor
    func testSleepTimerExpiresAndClearsItsVisibleState() async throws {
        let appState = AppState.makeDefault()
        appState.setSleepTimer(duration: 0.05)

        XCTAssertNotNil(appState.sleepTimerEndDate)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(appState.sleepTimerEndDate)
        XCTAssertNil(appState.sleepTimerTask)
    }

    @MainActor
    func testSleepTimerReconcilesAnOverdueDeadlineAndCanBeCancelled() throws {
        let appState = AppState.makeDefault()
        appState.setSleepTimer(duration: 60)
        let endDate = try XCTUnwrap(appState.sleepTimerEndDate)

        appState.reconcileSleepTimer(now: endDate.addingTimeInterval(1))
        XCTAssertNil(appState.sleepTimerEndDate)
        XCTAssertNil(appState.sleepTimerTask)

        appState.setSleepTimer(duration: 60)
        appState.cancelSleepTimer()
        XCTAssertNil(appState.sleepTimerEndDate)
        XCTAssertNil(appState.sleepTimerTask)
    }

    func testQueryValidationTrimsAndRejectsInvalidInput() throws {
        XCTAssertEqual(try QueryValidator.validateSearchQuery("  Massive Attack  "), "Massive Attack")
        XCTAssertThrowsError(try QueryValidator.validateSearchQuery("   "))
        XCTAssertThrowsError(
            try QueryValidator.validateSearchQuery(String(repeating: "a", count: AppConfig.Search.maxQueryLength + 1))
        )
    }

    func testArabicSearchNormalizationIsDeterministic() {
        XCTAssertEqual(SearchTextNormalizer.normalized("  إِلَى السَّماء  "), "الي السماء")
        XCTAssertEqual(SearchTextNormalizer.tokens(from: "Beyoncé — Halo"), ["beyonce", "halo"])
    }

    func testUnavailableAndShortFormTracksAreFiltered() {
        let unavailable = Track(title: "[Deleted video]", artist: "", youtubeVideoID: "deleted")
        let short = Track(title: "Song #Shorts", artist: "Artist", duration: 30, youtubeVideoID: "short")
        let song = Track(title: "Full Song", artist: "Artist", duration: 210, youtubeVideoID: "song")

        XCTAssertEqual([unavailable, short, song].playableOnly().map(\.id), [short.id, song.id])
        XCTAssertEqual([short, song].withoutShorts().map(\.id), [song.id])
    }

    func testLikedSongsFilterNeverFallsBackToNonMusicContent() {
        let podcast = Track(
            title: "Weekly Podcast Episode",
            artist: "Talk Channel",
            youtubeVideoID: "podcast"
        )
        let short = Track(
            title: "Song #Shorts",
            artist: "Artist",
            duration: 30,
            youtubeVideoID: "short"
        )
        let unavailable = Track(title: "[Private video]", artist: "", youtubeVideoID: "private")
        let song = Track(
            title: "Full Song",
            artist: "Artist",
            duration: 210,
            youtubeVideoID: "song"
        )

        XCTAssertTrue([podcast, short, unavailable].likedSongsOnly().isEmpty)
        XCTAssertEqual([podcast, song, short, unavailable].likedSongsOnly(), [song])
    }

    func testTrackSynthesizesArtworkFromYouTubeVideoID() throws {
        let track = Track(title: "Song", artist: "Artist", youtubeVideoID: "video-id")
        XCTAssertEqual(
            track.artworkURL?.absoluteString,
            "https://i.ytimg.com/vi/video-id/hqdefault.jpg"
        )

        let persistedJSON = """
        {
          "id": "persisted-track",
          "title": "Persisted Song",
          "artist": "Artist",
          "youtubeVideoID": "persisted-video",
          "tags": []
        }
        """
        let decoded = try JSONDecoder().decode(Track.self, from: Data(persistedJSON.utf8))
        XCTAssertEqual(
            decoded.artworkURL?.absoluteString,
            "https://i.ytimg.com/vi/persisted-video/hqdefault.jpg"
        )
    }

    func testAICurationDefaultsOnAndPreservesExplicitOptOut() {
        let suiteName = "MusicTubeCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = DataUsageSettings(defaults: defaults)
        XCTAssertTrue(settings.personalizedAICuration)

        settings.personalizedAICuration = false
        XCTAssertFalse(defaults.bool(forKey: "Privacy.personalizedAICuration"))

        settings = DataUsageSettings(defaults: defaults)
        
        XCTAssertFalse(settings.personalizedAICuration)
        
        settings.resetToDefaults()
        XCTAssertTrue(settings.personalizedAICuration)
    }

    func testRecommendationEngineDeduplicatesContentAndExcludesDislikesAndRecents() async {
        let engine = RecommendationEngine()
        let recent = Track(title: "Recent", artist: "Artist", duration: 180, youtubeVideoID: "recent")
        let disliked = Track(title: "Disliked", artist: "Artist", duration: 180, youtubeVideoID: "disliked")
        let original = Track(title: "Song", artist: "Singer", duration: 201, youtubeVideoID: "one")
        let duplicateUpload = Track(title: "Song", artist: "Singer", duration: 202, youtubeVideoID: "two")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [recent, disliked, original, duplicateUpload],
                recentTracks: [recent],
                likedTracks: [],
                dislikedTrackIDs: [disliked.playbackKey],
                preferences: .empty,
                focusedTrack: nil,
                limit: 10
            )
        )

        XCTAssertEqual(results.map(\.playbackKey), [original.playbackKey])
    }

    func testRecommendationEngineSeparatesQuranFromMusic() async {
        let engine = RecommendationEngine()
        let focusedQuran = Track(title: "Surah Al-Kahf Quran Recitation", artist: "Reciter", youtubeVideoID: "focus")
        let recitation = Track(title: "Surah Maryam Tilawah", artist: "Reciter", youtubeVideoID: "quran")
        let song = Track(title: "Summer Song", artist: "Band", youtubeVideoID: "music")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [song, recitation],
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: focusedQuran,
                limit: 10
            )
        )

        XCTAssertEqual(results.map(\.playbackKey), [recitation.playbackKey])
    }

    func testRecommendationEnginePreservesArtistAffinity() async {
        let engine = RecommendationEngine()
        let preferredArtistTrack = Track(title: "Known Favorite", artist: "Favorite Artist", youtubeVideoID: "liked")
        let matchingCandidate = Track(title: "Deep Cut", artist: "Favorite Artist", youtubeVideoID: "match")
        let unrelatedCandidate = Track(title: "Popular Song", artist: "Another Artist", youtubeVideoID: "other")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [unrelatedCandidate, matchingCandidate],
                recentTracks: [],
                likedTracks: [preferredArtistTrack],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                limit: 10
            )
        )

        XCTAssertEqual(results.first?.playbackKey, matchingCandidate.playbackKey)
    }

    func testRecommendationEngineUsesSavedAndFocusedAffinities() async {
        let engine = RecommendationEngine()
        let saved = Track(title: "Saved", artist: "Saved Artist", youtubeVideoID: "saved")
        let focused = Track(title: "Focus", artist: "Focus Artist", youtubeVideoID: "focus")
        let neutral = Track(title: "Neutral", artist: "Other", youtubeVideoID: "neutral")
        let savedMatch = Track(title: "Saved Match", artist: "Saved Artist", youtubeVideoID: "saved-match")
        let focusedMatch = Track(title: "Focused Match", artist: "Focus Artist", youtubeVideoID: "focus-match")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [neutral, savedMatch, focusedMatch],
                recentTracks: [],
                likedTracks: [],
                savedTracks: [saved],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: focused,
                limit: 3
            )
        )

        XCTAssertEqual(results.first?.playbackKey, focusedMatch.playbackKey)
        XCTAssertEqual(results.dropFirst().first?.playbackKey, savedMatch.playbackKey)
    }

    func testRecommendationEngineKeepsUnknownContextAndStableOrdering() async {
        let engine = RecommendationEngine()
        let first = Track(title: "First", artist: "Artist A", youtubeVideoID: "first")
        let second = Track(title: "Second", artist: "Artist B", youtubeVideoID: "second")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [first, second],
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                limit: 2
            )
        )

        XCTAssertEqual(results.map(\.playbackKey), ["first", "second"])
    }

    func testRecommendationEngineHandlesEmptyInputAndLimit() async {
        let engine = RecommendationEngine()
        let tracks = (0..<5).map {
            Track(title: "Track \($0)", artist: "Artist", youtubeVideoID: "track-\($0)")
        }
        let empty = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [],
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                limit: 10
            )
        )
        let limited = await engine.recommendations(
            for: RecommendationRequest(
                candidates: tracks,
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                limit: 2
            )
        )

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(limited.count, 2)
    }

    func testRecommendationDiversityMovesRecentlyPlayedSongsBehindFreshSongs() {
        let recent = Track(title: "Recent Song", artist: "Artist A", youtubeVideoID: "recent")
        let freshOne = Track(title: "Fresh One", artist: "Artist B", youtubeVideoID: "fresh-1")
        let freshTwo = Track(title: "Fresh Two", artist: "Artist C", youtubeVideoID: "fresh-2")

        let result = RecommendationDiversityPolicy.diversified(
            [recent, freshOne, freshTwo],
            recentlyPlayed: [recent],
            limit: 3
        )

        XCTAssertEqual(result.map(\.playbackKey), [freshOne.playbackKey, freshTwo.playbackKey, recent.playbackKey])
    }

    func testRecommendationDiversityRecognizesRecentlyPlayedDuplicateUploads() {
        let played = Track(title: "Same Song", artist: "Same Artist", duration: 200, youtubeVideoID: "played")
        let duplicateUpload = Track(title: "Same Song", artist: "Same Artist", duration: 203, youtubeVideoID: "duplicate")
        let fresh = Track(title: "Different Song", artist: "Other Artist", youtubeVideoID: "fresh")

        let result = RecommendationDiversityPolicy.diversified(
            [duplicateUpload, fresh],
            recentlyPlayed: [played],
            limit: 2
        )

        XCTAssertEqual(result.map(\.playbackKey), [fresh.playbackKey, duplicateUpload.playbackKey])
    }

    func testRecommendationDiversitySpacesArtistsWithoutDroppingTracks() {
        let tracks = [
            Track(title: "A1", artist: "Artist A", youtubeVideoID: "a1"),
            Track(title: "A2", artist: "Artist A", youtubeVideoID: "a2"),
            Track(title: "A3", artist: "Artist A", youtubeVideoID: "a3"),
            Track(title: "B1", artist: "Artist B", youtubeVideoID: "b1"),
            Track(title: "C1", artist: "Artist C", youtubeVideoID: "c1")
        ]

        let result = RecommendationDiversityPolicy.diversified(
            tracks,
            recentlyPlayed: [],
            limit: tracks.count
        )

        XCTAssertEqual(result.count, tracks.count)
        XCTAssertEqual(result.prefix(3).map(\.artist), ["Artist A", "Artist B", "Artist C"])
    }

    func testRecommendationDiversityUsesLeastRecentFallbackWhenEverythingWasPlayed() {
        let newest = Track(title: "Newest", artist: "Artist A", youtubeVideoID: "newest")
        let older = Track(title: "Older", artist: "Artist B", youtubeVideoID: "older")

        let result = RecommendationDiversityPolicy.diversified(
            [newest, older],
            recentlyPlayed: [newest, older],
            limit: 2
        )

        XCTAssertEqual(result.map(\.playbackKey), [older.playbackKey, newest.playbackKey])
    }

    func testRecommendationDiversityMovesPreviouslyShownSongsBehindFreshSongs() {
        let shown = Track(title: "Already Shown", artist: "Artist A", youtubeVideoID: "shown")
        let fresh = Track(title: "Fresh Pick", artist: "Artist B", youtubeVideoID: "fresh")

        let result = RecommendationDiversityPolicy.diversified(
            [shown, fresh],
            recentlyPlayed: [],
            recentlyRecommended: [shown],
            limit: 2
        )

        XCTAssertEqual(result.map(\.playbackKey), [fresh.playbackKey, shown.playbackKey])
    }

    func testRecommendationDiversityCollapsesPresentationVariantsAcrossChannels() {
        let officialVideo = Track(
            title: "Adele - Hello (Official Video)",
            artist: "AdeleVEVO",
            youtubeVideoID: "official"
        )
        let lyricUpload = Track(
            title: "Hello Lyrics",
            artist: "Adele - Topic",
            youtubeVideoID: "lyrics"
        )
        let fresh = Track(title: "Easy On Me", artist: "Adele", youtubeVideoID: "fresh")

        let result = RecommendationDiversityPolicy.diversified(
            [officialVideo, lyricUpload, fresh],
            recentlyPlayed: [],
            limit: 3
        )

        XCTAssertEqual(result.map(\.playbackKey), [officialVideo.playbackKey, fresh.playbackKey])
    }

    @MainActor
    func testRecommendationExposureStorePersistsImpressionsAndRotation() {
        let suiteName = "MusicTubeCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let track = Track(title: "Shown", artist: "Artist", youtubeVideoID: "shown")

        var store = RecommendationExposureStore(defaults: defaults)
        store.record([track], profileID: "device")
        XCTAssertEqual(store.advanceRotation(profileID: "device"), 1)

        store = RecommendationExposureStore(defaults: defaults)
        XCTAssertEqual(store.recentTracks(profileID: "device").map(\.playbackKey), [track.playbackKey])
        XCTAssertEqual(store.rotationCursor(profileID: "device"), 1)
    }

    func testRecommendationEngineStrictlySeparatesMusicSessionFromQuran() async {
        let engine = RecommendationEngine()
        let song = Track(title: "Arabic Oud Song", artist: "Oud Artist", youtubeVideoID: "song")
        let recitation = Track(title: "Surah Maryam Quran Recitation", artist: "Reciter", youtubeVideoID: "quran")

        let musicResults = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [recitation, song],
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                activeContext: .music,
                activeQuranDomain: false,
                limit: 10
            )
        )
        let quranResults = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [song, recitation],
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: recitation,
                activeContext: .religious,
                activeQuranDomain: true,
                limit: 10
            )
        )

        XCTAssertEqual(musicResults.map(\.playbackKey), [song.playbackKey])
        XCTAssertEqual(quranResults.map(\.playbackKey), [recitation.playbackKey])
    }

    func testRecommendationEngineUsesLikesAsDiscoveryAffinityWithoutEchoingExactLike() async {
        let engine = RecommendationEngine()
        let liked = Track(title: "Loved Song", artist: "Favorite Artist", youtubeVideoID: "liked")
        let discovery = Track(title: "Unheard Deep Cut", artist: "Favorite Artist", youtubeVideoID: "discovery")
        let unrelated = Track(title: "Unrelated", artist: "Other Artist", youtubeVideoID: "other")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [liked, unrelated, discovery],
                recentTracks: [],
                likedTracks: [liked],
                candidateSourcesByTrackID: [
                    liked.playbackKey: [.likedSongs],
                    discovery.playbackKey: [.likedSongs],
                    unrelated.playbackKey: [.exploration]
                ],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                activeContext: .music,
                activeQuranDomain: false,
                limit: 3
            )
        )

        XCTAssertEqual(results.first?.playbackKey, discovery.playbackKey)
        XCTAssertTrue(results.contains(liked))
    }

    func testRecommendationEngineRespondsToSkipsAndCompletedListens() async {
        let engine = RecommendationEngine()
        let skippedSeed = Track(title: "Skipped Seed", artist: "Skipped Artist", duration: 200, youtubeVideoID: "skip-seed")
        let completedSeed = Track(title: "Completed Seed", artist: "Loved Artist", duration: 200, youtubeVideoID: "complete-seed")
        let skippedCandidate = Track(title: "More Skipped Style", artist: "Skipped Artist", youtubeVideoID: "skip-candidate")
        let completedCandidate = Track(title: "More Loved Style", artist: "Loved Artist", youtubeVideoID: "complete-candidate")
        let now = Date()
        let insights = [
            TrackBehaviorInsight(
                track: skippedSeed,
                playCount: 4,
                repeatCount: 0,
                skipCount: 4,
                completedListenCount: 0,
                totalListenedDuration: 40,
                averageListenRatio: 0.05,
                lastInteractedAt: now
            ),
            TrackBehaviorInsight(
                track: completedSeed,
                playCount: 4,
                repeatCount: 3,
                skipCount: 0,
                completedListenCount: 4,
                totalListenedDuration: 760,
                averageListenRatio: 0.95,
                lastInteractedAt: now
            )
        ]

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [skippedCandidate, completedCandidate],
                recentTracks: [],
                likedTracks: [],
                behaviorInsights: insights,
                candidateSourcesByTrackID: [
                    skippedCandidate.playbackKey: [.completedListens],
                    completedCandidate.playbackKey: [.completedListens]
                ],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                activeContext: .music,
                activeQuranDomain: false,
                limit: 2
            )
        )

        XCTAssertEqual(results.first?.playbackKey, completedCandidate.playbackKey)
    }

    func testRecommendationEngineIncludesTasteAdjacentExplorationLane() async {
        let engine = RecommendationEngine()
        let familiar = (0..<6).map {
            Track(title: "Familiar \($0)", artist: "Familiar Artist \($0)", youtubeVideoID: "f-\($0)")
        }
        let discovery = (0..<3).map {
            Track(title: "Discovery \($0)", artist: "Discovery Artist \($0)", youtubeVideoID: "d-\($0)")
        }
        let exploration = Track(title: "Adjacent Experiment", artist: "Adjacent Artist", youtubeVideoID: "explore")
        var sources: [String: Set<RecommendationSeedFamily>] = [:]
        familiar.forEach { sources[$0.playbackKey] = [.likedSongs] }
        discovery.forEach { sources[$0.playbackKey] = [.preferences] }
        sources[exploration.playbackKey] = [.exploration]

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: familiar + discovery + [exploration],
                recentTracks: [],
                likedTracks: [],
                candidateSourcesByTrackID: sources,
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                activeContext: .music,
                activeQuranDomain: false,
                limit: 10
            )
        )

        XCTAssertTrue(results.contains(exploration))
        XCTAssertLessThanOrEqual(results.firstIndex(of: exploration) ?? .max, 6)
    }

    @MainActor
    func testBalancedRecommendationSeedsAreBoundedAndFamilyDiverse() {
        let state = AppState.makeDefault()
        let seeds = RecommendationSeedFamily.allCases.flatMap { family in
            (0..<3).map { index in
                RecommendationSeedQuery(
                    query: "\(family.rawValue) \(index)",
                    family: family,
                    lane: family == .exploration ? .exploration : .discovery
                )
            }
        }

        let selected = state.balancedRecommendationSeeds(from: seeds, focused: false)

        XCTAssertLessThanOrEqual(selected.count, 7)
        XCTAssertEqual(Set(selected.map(\.family)).count, selected.count)
    }

    @MainActor
    func testPlaybackRecordingDoesNotReplaceVisibleHomeFeed() {
        let suiteName = "MusicTubeCoreTests.HomeStability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            authService: YouTubeAuthService(),
            catalogService: YouTubeAPIService(),
            playbackService: PlaybackService(),
            localMusicProfileStore: LocalMusicProfileStore(defaults: defaults),
            interactionTracker: InteractionTracker(defaults: defaults),
            recommendationEngine: RecommendationEngine(),
            recommendationExposureStore: RecommendationExposureStore(defaults: defaults)
        )
        let tracks = [
            Track(title: "First", artist: "Artist A", youtubeVideoID: "first"),
            Track(title: "Second", artist: "Artist B", youtubeVideoID: "second"),
            Track(title: "Third", artist: "Artist C", youtubeVideoID: "third")
        ]
        state.updateHomeContent(featuredTracks: tracks)
        let generation = state.homeContent.recommendationGenerationID

        state.recordLocalPlayback(for: tracks[0])

        XCTAssertEqual(state.featuredTracks.map(\.playbackKey), tracks.map(\.playbackKey))
        XCTAssertEqual(state.homeContent.recommendationGenerationID, generation)
    }

    @MainActor
    func testAutoplayAndCarPlayQueueUseFreshContextCompatibleRecommendations() {
        let state = AppState.makeDefault()
        let current = Track(title: "Current Song", artist: "Artist A", youtubeVideoID: "current")
        let fresh = Track(title: "Fresh Song", artist: "Artist B", youtubeVideoID: "fresh")
        let recitation = Track(title: "Surah Al-Kahf Quran Recitation", artist: "Reciter", youtubeVideoID: "quran")
        state.updateHomeContent(featuredTracks: [fresh, recitation], recentTracks: [current])

        let autoplay = state.autoplayContinuationCandidates(after: current)
        let carPlayQueue = state.recommendationPlaybackQueue()

        XCTAssertTrue(autoplay.allSatisfy { $0.listeningContentContext == .music && $0.isQuranOrRecitation == false })
        XCTAssertTrue(carPlayQueue.allSatisfy { $0.listeningContentContext == .music && $0.isQuranOrRecitation == false })
        XCTAssertEqual(carPlayQueue.first?.playbackKey, fresh.playbackKey)
    }

    @MainActor
    func testSearchViewModelCancelsPreviousRequest() async throws {
        let source = MockSearchDataSource(mode: .cancellable)
        let model = SearchViewModel(
            appState: .makeDefault(),
            dataSource: source,
            debounceNanoseconds: 0
        )

        model.setQuery("first", immediately: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        model.setQuery("second", immediately: true)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.snapshot.results.songs.first?.title, "second")
        XCTAssertEqual(source.cancelledQueries, ["first"])
    }

    @MainActor
    func testSearchViewModelIgnoresStaleResponse() async throws {
        let source = MockSearchDataSource(mode: .ignoresCancellation)
        let model = SearchViewModel(
            appState: .makeDefault(),
            dataSource: source,
            debounceNanoseconds: 0
        )

        model.setQuery("slow", immediately: true)
        try await Task.sleep(nanoseconds: 10_000_000)
        model.setQuery("fast", immediately: true)
        try await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(model.snapshot.results.songs.first?.title, "fast")
        XCTAssertFalse(model.snapshot.isSearching)
    }

    @MainActor
    func testSearchAutocompletePreservesLocalSuggestionsWhenRemoteIsEmpty() async throws {
        let source = MockSearchDataSource(
            mode: .cancellable,
            localAutocompleteSuggestions: ["Halo", "Halo Beyonce"],
            remoteAutocompleteSuggestions: []
        )
        let model = SearchViewModel(
            appState: .makeDefault(),
            dataSource: source,
            debounceNanoseconds: 0
        )

        model.setQuery("halo", immediately: true)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.snapshot.autocompleteSuggestions, ["Halo", "Halo Beyonce"])
        XCTAssertFalse(model.snapshot.isLoadingAutocomplete)
    }

    @MainActor
    func testRelatedRankingKeepsSparseFocusedSearchCandidates() {
        let appState = AppState.makeDefault()
        let focused = Track(title: "Focus", artist: "Original Artist", youtubeVideoID: "focus")
        let first = Track(title: "Different One", artist: "Another Artist", youtubeVideoID: "one")
        let second = Track(title: "Different Two", artist: "Third Artist", youtubeVideoID: "two")

        let ranked = appState.rankedRelatedCandidates([first, second], to: focused, limit: 10)

        XCTAssertEqual(ranked.map(\.playbackKey), ["one", "two"])
    }

    @MainActor
    func testRelatedQueriesOnlyAddRecitationQualifierForQuran() {
        let appState = AppState.makeDefault()
        let arabicSong = Track(
            title: "مهما يلوعني الحنين",
            artist: "أيوب طارش",
            youtubeVideoID: "song"
        )
        let recitation = Track(
            title: "سورة الكهف",
            artist: "مشاري العفاسي",
            youtubeVideoID: "quran"
        )

        XCTAssertFalse(appState.focusedRelatedQueries(for: arabicSong).contains { $0.contains("تلاوة") })
        XCTAssertTrue(appState.focusedRelatedQueries(for: recitation).contains { $0.contains("تلاوة") })
    }

    func testDownloadConcurrencyPolicyAdaptsToEnvironment() {
        let normalWiFi = DownloadConcurrencyEnvironment(
            isLowPowerModeEnabled: false,
            isCellular: false,
            isExpensiveNetwork: false,
            isLowDataMode: false,
            isInBackground: false,
            isThermallyConstrained: false
        )
        XCTAssertEqual(DownloadConcurrencyPolicy.limit(default: 3, environment: normalWiFi), 3)

        var constrained = DownloadConcurrencyEnvironment(
            isLowPowerModeEnabled: true,
            isCellular: false,
            isExpensiveNetwork: false,
            isLowDataMode: false,
            isInBackground: false,
            isThermallyConstrained: false
        )
        XCTAssertEqual(DownloadConcurrencyPolicy.limit(default: 3, environment: constrained), 1)

        constrained = DownloadConcurrencyEnvironment(
            isLowPowerModeEnabled: false,
            isCellular: true,
            isExpensiveNetwork: true,
            isLowDataMode: false,
            isInBackground: false,
            isThermallyConstrained: false
        )
        XCTAssertEqual(DownloadConcurrencyPolicy.limit(default: 3, environment: constrained), 1)

        constrained = DownloadConcurrencyEnvironment(
            isLowPowerModeEnabled: false,
            isCellular: false,
            isExpensiveNetwork: true,
            isLowDataMode: false,
            isInBackground: false,
            isThermallyConstrained: false
        )
        XCTAssertEqual(DownloadConcurrencyPolicy.limit(default: 3, environment: constrained), 2)
    }

    func testRecommendationDiversityLargePoolCompletesWithinInteractiveBudget() {
        let candidates = (0..<1_200).map { index in
            Track(
                title: "Recommendation \(index)",
                artist: "Artist \(index % 80)",
                youtubeVideoID: "candidate-\(index)"
            )
        }
        let recentlyPlayed = Array(candidates.prefix(60))
        let recentlyRecommended = Array(candidates.dropFirst(60).prefix(120))
        let now = Date()
        let exposures = candidates.dropFirst(180).prefix(120).enumerated().map { index, track in
            RecommendationExposure(
                track: track,
                shownAt: now.addingTimeInterval(-Double(index) * 900)
            )
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = RecommendationDiversityPolicy.diversified(
            candidates,
            recentlyPlayed: recentlyPlayed,
            recentlyRecommended: recentlyRecommended,
            recommendationExposures: exposures,
            limit: 60,
            recentWindow: 60,
            recommendationWindow: 120,
            artistGap: 3,
            now: now
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertEqual(result.count, 60)
        XCTAssertLessThan(elapsed, 1.0, "Diversity ranking exceeded an interactive latency budget")
    }

    func testDownloadBatchPlannerDeduplicatesAndPreservesSourceOrder() {
        let first = Track(title: "First", artist: "Artist", youtubeVideoID: "first")
        let duplicate = Track(title: "First duplicate", artist: "Artist", youtubeVideoID: "first")
        let existing = Track(title: "Existing", artist: "Artist", youtubeVideoID: "existing")
        let last = Track(title: "Last", artist: "Artist", youtubeVideoID: "last")

        let candidates = DownloadBatchPlanner.candidates(
            from: [first, duplicate, existing, last],
            excluding: [existing.playbackKey]
        )

        XCTAssertEqual(candidates.map(\.track.playbackKey), ["first", "last"])
        XCTAssertEqual(candidates.map(\.sourceTrackIndex), [0, 3])
    }
}

@MainActor
private final class MockSearchDataSource: SearchDataSource {
    enum Mode {
        case cancellable
        case ignoresCancellation
    }

    let mode: Mode
    private(set) var cancelledQueries: [String] = []
    private let localAutocompleteSuggestions: [String]
    private let remoteAutocompleteSuggestions: [String]

    init(
        mode: Mode,
        localAutocompleteSuggestions: [String] = [],
        remoteAutocompleteSuggestions: [String] = []
    ) {
        self.mode = mode
        self.localAutocompleteSuggestions = localAutocompleteSuggestions
        self.remoteAutocompleteSuggestions = remoteAutocompleteSuggestions
    }

    func fetchSearchResults(for query: String) async throws -> SearchResponse {
        switch mode {
        case .cancellable:
            do {
                try await Task.sleep(
                    nanoseconds: query == "first" ? 200_000_000 : 5_000_000
                )
            } catch {
                cancelledQueries.append(query)
                throw error
            }
        case .ignoresCancellation:
            let delay: UInt64 = query == "slow" ? 150_000_000 : 5_000_000
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
                    continuation.resume()
                }
            }
        }

        return SearchResponse(
            songs: [Track(title: query, artist: "Test", youtubeVideoID: query)],
            playlists: [],
            albums: [],
            artists: [],
            nextSongsContinuationToken: nil
        )
    }

    func fetchMoreSearchResults(query: String, continuation: String) async throws -> SearchResponse {
        .empty
    }

    func autocompleteSuggestions(
        for query: String,
        limit: Int,
        includeRemote: Bool
    ) async -> [String] {
        Array(
            (includeRemote ? remoteAutocompleteSuggestions : localAutocompleteSuggestions)
                .prefix(limit)
        )
    }

    func recentSearchTrackSuggestions(limit: Int) async -> [Track] {
        []
    }
}

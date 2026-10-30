// cspell:ignore EXTINF
import AVFoundation
import XCTest
@testable import HopeTViOS

/// A playlist item's own source (awe#6550). The item names a provider and a link-only
/// `mediaLinks` map. Its `id` is the episode ObjectId, never a media id.
final class PlaylistItemSourceTests: XCTestCase {

    private func source(_ json: String) throws -> String? {
        PlaybackService.playlistItemSource(try TestDocument.value(json))?.url.absoluteString
    }

    func testAJetstreamItemPlaysTheManifestOfItsLink() throws {
        XCTAssertEqual(
            try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "jetstream", "mediaLinks": { "jetstream": { "link": "jsv:4kRn8WqZp2X" } } }"#),
            "https://jstre.am/videos/jsv:4kRn8WqZp2X/hls/main.m3u8"
        )
    }

    /// The trap: `episodeSource` falls back to `id`, and the allowlist accepts a 24-hex id. On an
    /// item that id is the episode ObjectId, so it must never become a manifest.
    func testTheEpisodeObjectIdNeverBecomesASource() throws {
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "jetstream", "mediaLinks": {} }"#))
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "jetstream" }"#))
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "jetstream", "mediaLinks": { "youtube": { "link": "https://youtu.be/x" } } }"#))
    }

    func testProvidersThisDeviceCannotPlayResolveNothing() throws {
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "youtube", "mediaLinks": { "youtube": { "link": "https://www.youtube.com/watch?v=Hq3sL7uVb2c" } } }"#))
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "vimeo", "mediaLinks": { "vimeo": { "link": "76979871" } } }"#))
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "jetstream-live", "mediaLinks": { "jetstream-live": { "link": "jsl:AQfP7b5HoTM" } } }"#))
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "jetstream-audio", "mediaLinks": { "jetstream-audio": { "link": "jsa:AQfP7b5HoTM" } } }"#))
    }

    /// `provider` can be `null`: the channel's player order found no link. The server sends it only
    /// when no fallback key holds a link either (`videoProvider` tries every default provider), so
    /// the item plays nothing, as its Episode Screen (`NO_SOURCE`) does.
    func testANullProviderResolvesNothing() throws {
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": null, "mediaLinks": {} }"#))
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": null, "mediaLinks": { "vimeo": { "link": "76979871" } } }"#))
    }

    func testASelfHostedItemPlaysItsHttpsLinkOnly() throws {
        XCTAssertEqual(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "hls", "mediaLinks": { "hls": { "link": "https://cdn.test/a/main.m3u8" } } }"#),
                       "https://cdn.test/a/main.m3u8")
        XCTAssertNil(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "hls", "mediaLinks": { "hls": { "link": "http://cdn.test/a/main.m3u8" } } }"#))
    }

    /// The item predicts what its Episode Screen plays. That screen falls back from an unplayable
    /// provider to its `mediaLinks` (`episodeSource`), so the item does too: Up Next offers a
    /// YouTube-served episode with a Jetstream or self-hosted link.
    func testAnUnplayableProviderFallsBackToTheMap() throws {
        let item = try TestDocument.value(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "youtube", "mediaLinks": { "youtube": { "link": "dQw4w9WgXcQ" }, "jetstream": { "link": "jsv:4kRn8WqZp2X" } } }"#)
        let resolved = try XCTUnwrap(PlaybackService.playlistItemSource(item))
        XCTAssertEqual(resolved.url.absoluteString, "https://jstre.am/videos/jsv:4kRn8WqZp2X/hls/main.m3u8")
        XCTAssertEqual(resolved.rendition, "jetstream")
        // What its Episode Screen serves for the same episode.
        let screen = try TestDocument.value(#"{ "provider": "youtube", "id": "dQw4w9WgXcQ", "mediaLinks": { "youtube": { "link": "dQw4w9WgXcQ" }, "jetstream": { "link": "jsv:4kRn8WqZp2X" } } }"#)
        XCTAssertEqual(resolved, PlaybackService.episodeSource(screen), "the item and its Episode Screen agree")

        XCTAssertEqual(try source(#"{ "id": "69a1c2f83ec5247f807e1b20", "provider": "youtube", "mediaLinks": { "youtube": { "link": "https://youtu.be/x" }, "hls": { "link": "https://cdn.test/a/main.m3u8" } } }"#),
                       "https://cdn.test/a/main.m3u8")
    }

    /// A playable item is offered: its `Playlist.Item.isPlayable` is true.
    func testAYouTubeServedItemWithAJetstreamLinkIsPlayable() throws {
        let resource = try TestDocument.value(#"{ "playlistIndex": 0, "playlist": [{ "id": "69a1c2f83ec5247f807e1b20", "title": "E1", "provider": "youtube", "mediaLinks": { "youtube": { "link": "dQw4w9WgXcQ" }, "jetstream": { "link": "jsv:4kRn8WqZp2X" } } }] }"#)
        XCTAssertEqual(Playlist(resource)?.items.first?.isPlayable, true)
    }
}

/// The `episodePlayer` playlist read into the request (awe#6550, spec §5.6).
@MainActor
final class PlaylistTests: XCTestCase {

    private func playlist(_ json: String) throws -> Playlist? {
        Playlist(try TestDocument.value(json))
    }

    private func item(_ n: Int, provider: String = "jetstream") -> String {
        let link = provider == "youtube" ? "https://youtu.be/x\(n)" : "jsv:Abcdefghij\(n)"
        return #"{ "id": "aaaaaaaaaaaaaaaaaaaaaa0\#(n)", "title": "E\#(n)", "poster": "https://img.test/\#(n).jpg", "provider": "\#(provider)", "mediaLinks": { "\#(provider)": { "link": "\#(link)" } } }"#
    }

    func testTheCapturedEpisodeScreenServesTheSeason() throws {
        let screen = try ContractDecoder.screen(Fixtures.data("episode"))
        let resource = try XCTUnwrap(screen.blockResources.values.compactMap { $0["episodePlayer"] }.first)
        let list = try XCTUnwrap(Playlist(resource))

        XCTAssertEqual(list.items.map(\.title), ["Lesson 1: Suffering With the Good Shepherd", "Lesson 2: Suffering and the Book of Job",
                                                 "Lesson 3: Suffering and Our Hope"])
        XCTAssertEqual(list.items.map(\.isPlayable), [true, true, false], "Lesson 3 is YouTube")
        XCTAssertEqual(list.currentIndex, 0)
        XCTAssertFalse(list.autoplay)
        XCTAssertNotNil(list.items[0].posterURL)
    }

    func testAnIndexOutsideTheListIsNoCurrentItem() throws {
        XCTAssertNil(try playlist(#"{ "playlist": [\#(item(1))], "playlistIndex": -1 }"#)?.currentIndex)
        XCTAssertNil(try playlist(#"{ "playlist": [\#(item(1))], "playlistIndex": 1 }"#)?.currentIndex)
        XCTAssertNil(try playlist(#"{ "playlist": [\#(item(1))] }"#)?.currentIndex)
        XCTAssertEqual(try playlist(#"{ "playlist": [\#(item(1))], "playlistIndex": 0 }"#)?.currentIndex, 0)
    }

    func testAutoplayIsOnlyTheJsonBoolTrue() throws {
        XCTAssertEqual(try playlist(#"{ "playlist": [\#(item(1))], "autoplayEpisodes": true }"#)?.autoplay, true)
        XCTAssertEqual(try playlist(#"{ "playlist": [\#(item(1))], "autoplayEpisodes": "true" }"#)?.autoplay, false)
        XCTAssertEqual(try playlist(#"{ "playlist": [\#(item(1))] }"#)?.autoplay, false)
    }

    /// An item with no ObjectId cannot open its Episode Screen. It drops, and the index follows
    /// the current item.
    func testAnItemWithoutAnObjectIdDropsAndTheIndexFollows() throws {
        let list = try XCTUnwrap(try playlist(#"{ "playlist": [{ "id": "nope", "title": "X" }, \#(item(1)), \#(item(2))], "playlistIndex": 2 }"#))
        XCTAssertEqual(list.items.map(\.title), ["E1", "E2"])
        XCTAssertEqual(list.currentIndex, 1)

        let gone = try XCTUnwrap(try playlist(#"{ "playlist": [{ "id": "nope" }, \#(item(1))], "playlistIndex": 0 }"#))
        XCTAssertNil(gone.currentIndex, "the current item dropped")
    }

    func testAnEmptyOrMissingListIsNoPlaylist() throws {
        XCTAssertNil(try playlist(#"{ "playlist": [], "playlistIndex": -1 }"#))
        XCTAssertNil(try playlist(#"{ "provider": "jetstream", "id": "jsv:Abcdefghij1" }"#))
    }

    func testAnInsecurePosterIsDropped() throws {
        let list = try XCTUnwrap(try playlist(#"{ "playlist": [{ "id": "aaaaaaaaaaaaaaaaaaaaaa01", "title": "E", "poster": "http://img.test/1.jpg" }] }"#))
        XCTAssertNil(list.items[0].posterURL)
        XCTAssertFalse(list.items[0].isPlayable)
    }

    /// The Episode Screen's Play request carries the playlist, so tap-to-play and Play both have it.
    func testThePlayRequestCarriesThePlaylist() throws {
        let screen = try ContractDecoder.screen(Fixtures.data("episode"))
        let images = ImageConfig(cdn: TestConfig.staging.imagesCDN, bucket: TestConfig.staging.imagesBucket)
        let request = try XCTUnwrap(BlockRegistry.playRequest(on: screen, images: images))
        XCTAssertEqual(request.playlist?.items.count, 3)
        XCTAssertEqual(request.playlist?.currentIndex, 0)
    }

    func testALivestreamAndATrailerCarryNoPlaylist() throws {
        let images = TestRender.context().images
        let channel = try TestDocument.value(#"{ "title": "Hope TV Deutsch", "hls": "https://live.example.org/x.m3u8" }"#)
        XCTAssertNil(try XCTUnwrap(PlaybackService.liveRequest(channel, images: images)).playlist)
        let trailer = try TestDocument.value(#"{ "provider": "jetstream", "videoId": "jsv:QBvi99xy28Q" }"#)
        XCTAssertNil(try XCTUnwrap(PlaybackService.trailerRequest(trailer, title: "T", description: nil, artworkURL: nil)).playlist)
    }
}

/// Up Next (awe#6550, spec §5.4): which item the player offers, and how.
final class UpNextOfferTests: XCTestCase {

    private func list(_ playable: [Bool], current: Int?, autoplay: Bool = true) -> Playlist {
        Playlist(
            items: playable.enumerated().map { index, playable in
                Playlist.Item(id: String(format: "aaaaaaaaaaaaaaaaaaaaaa%02d", index), title: "E\(index)", posterURL: nil, isPlayable: playable)
            },
            currentIndex: current,
            autoplay: autoplay
        )
    }

    private func offered(_ playlist: Playlist?, autoStarts: Int = 0) -> String? {
        UpNext.offer(in: playlist, autoStarts: autoStarts)?.item.title
    }

    func testTheNextItemIsOffered() {
        XCTAssertEqual(offered(list([true, true, true], current: 0)), "E1")
        XCTAssertEqual(offered(list([true, true, true], current: 1)), "E2")
    }

    func testNoOfferWithAutoplayOff() {
        XCTAssertNil(offered(list([true, true], current: 0, autoplay: false)))
    }

    func testNoOfferForTheLastItemOrNoCurrentItem() {
        XCTAssertNil(offered(list([true, true], current: 1)))
        XCTAssertNil(offered(list([true, true], current: nil)), "playlistIndex -1")
        XCTAssertNil(offered(nil), "a livestream or a trailer has no playlist")
    }

    func testUnplayableItemsAreSkipped() {
        XCTAssertEqual(offered(list([true, false, true], current: 0)), "E2")
        XCTAssertEqual(offered(list([true, false, false, true], current: 0)), "E3")
    }

    /// At most 3 skips: the item after 3 unplayable ones is still offered; a 4th skip ends the search.
    func testAtMostThreeSkips() {
        XCTAssertEqual(UpNext.maxSkips, 3)
        XCTAssertEqual(offered(list([true, false, false, false, true], current: 0)), "E4")
        XCTAssertNil(offered(list([true, false, false, false, false, true], current: 0)))
    }

    func testSkippingToTheEndMakesNoOffer() {
        XCTAssertNil(offered(list([true, true, false], current: 1)))
    }

    /// After 3 episodes in a row that started by themselves, the offer asks "Still watching?".
    func testStillWatchingAfterThreeAutomaticStarts() {
        XCTAssertEqual(UpNext.stillWatchingAfter, 3)
        let playlist = list([true, true], current: 0)
        XCTAssertEqual(UpNext.offer(in: playlist, autoStarts: 0)?.mode, .countdown)
        XCTAssertEqual(UpNext.offer(in: playlist, autoStarts: 2)?.mode, .countdown)
        XCTAssertEqual(UpNext.offer(in: playlist, autoStarts: 3)?.mode, .stillWatching)
        XCTAssertEqual(UpNext.offer(in: playlist, autoStarts: 3)?.item.title, "E1", "it still names the next item")
    }

    // MARK: - Timing

    func testTheOfferShowsFifteenSecondsBeforeTheEndAndCountsDownTen() {
        XCTAssertEqual(UpNext.offerLead, 15)
        XCTAssertEqual(UpNext.countdown, 10)
        XCTAssertEqual(UpNext.offerTime(duration: 1800), 1785)
        XCTAssertEqual(UpNext.offerTime(duration: 1800, now: 600), 1785)
        XCTAssertEqual(UpNext.offerTime(duration: 10), 1, "a short episode offers 1 s after its start")
    }

    /// A resume point past the offer time (resume allows up to 95 %): AVKit does not show a
    /// proposal whose time has passed, so the offer shows 1 s from now, and never at the end.
    func testAResumePastTheOfferTimeOffersOneSecondFromNow() {
        XCTAssertEqual(UpNext.offerTime(duration: 120, now: 114), 115, "95 % of a 2 min item")
        XCTAssertEqual(UpNext.offerTime(duration: 1800, now: 1790), 1791)
        XCTAssertEqual(UpNext.offerTime(duration: 1800, now: 1799.8), 1799.5, "never at or past the end")
    }

    /// Back on an offer after the item ended closes the player: `.defer` would replay it from 0.
    func testAnItemHasEndedOnlyAtItsKnownEnd() {
        XCTAssertTrue(UpNext.hasEnded(currentTime: 1800, duration: 1800))
        XCTAssertTrue(UpNext.hasEnded(currentTime: 1799.6, duration: 1800))
        XCTAssertFalse(UpNext.hasEnded(currentTime: 1790, duration: 1800), "the offer shows before the end")
        XCTAssertFalse(UpNext.hasEnded(currentTime: 10, duration: .nan), "an unknown duration")
        XCTAssertFalse(UpNext.hasEnded(currentTime: 0, duration: 0))
    }

    func testTheCountdownShowsWholeSecondsLeft() {
        let deadline = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertEqual(UpNext.secondsLeft(until: deadline, now: Date(timeIntervalSinceReferenceDate: 90)), 10)
        XCTAssertEqual(UpNext.secondsLeft(until: deadline, now: Date(timeIntervalSinceReferenceDate: 90.2)), 10)
        XCTAssertEqual(UpNext.secondsLeft(until: deadline, now: Date(timeIntervalSinceReferenceDate: 99.5)), 1)
        XCTAssertEqual(UpNext.secondsLeft(until: deadline, now: Date(timeIntervalSinceReferenceDate: 101)), 0)
    }
}

/// The item's own end notification marks it ended, so Back on the offer closes the player even
/// when a stream stops short of its reported duration (a last segment shorter than its `EXTINF`).
@MainActor
final class UpNextEndTests: XCTestCase {
    private func controller(for item: AVPlayerItem) -> UpNextProposalController {
        let next = Playlist.Item(id: "aaaaaaaaaaaaaaaaaaaaaa02", title: "E2", posterURL: nil, isPlayable: true)
        return UpNextProposalController(
            offer: UpNext.Offer(item: next, mode: .stillWatching),
            item: item,
            theme: AppTheme(tokens: PresetTokens(preset: .object([:]))),
            closePlayer: {}
        )
    }

    private func item() -> AVPlayerItem {
        AVPlayerItem(url: URL(string: "https://example.com/main.m3u8")!)
    }

    /// AVFoundation can post on another thread, so the flag can arrive one main-queue turn later.
    private func settle(_ upNext: UpNextProposalController) async throws {
        for _ in 0..<50 where !upNext.itemEnded {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testTheItemsEndMarksItEnded() async throws {
        let item = item()
        let upNext = controller(for: item)
        XCTAssertFalse(upNext.itemEnded)

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        try await settle(upNext)
        XCTAssertTrue(upNext.itemEnded)
    }

    func testTheEndPostedFromAnotherThreadMarksItEnded() async throws {
        let item = item()
        let upNext = controller(for: item)

        await Task.detached {
            NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        }.value
        try await settle(upNext)
        XCTAssertTrue(upNext.itemEnded)
    }

    func testAnotherItemsEndDoesNotCount() async throws {
        let upNext = controller(for: item())

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item())
        try await settle(upNext)
        XCTAssertFalse(upNext.itemEnded, "the previous player's item ends after the next one starts")
    }
}

/// Starting a playlist item from the player (Episodes tab, Up Next) and the auto-start counter.
@MainActor
final class PlayerPlaylistRoutingTests: XCTestCase {

    private func router(_ resolve: (@MainActor (StackEntry) async -> PlaybackRequest?)?) throws -> AppRouter {
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1, "app": { "design": "tv" }, "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [{ "id": "home", "kind": "static" },
                      { "id": "episode-tpl", "kind": "template", "resourceType": "episode" },
                      { "id": "show-tpl", "kind": "template", "resourceType": "show" }],
          "preset": {}
        }
        """.utf8))
        let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
        router.playRequest = resolve
        return router
    }

    private func request(_ name: String) -> PlaybackRequest {
        PlaybackRequest(url: URL(string: "https://media.test/\(name).m3u8")!,
                        metadata: PlaybackMetadata(title: name, description: nil, showName: nil, artworkURL: nil), isHLS: true)
    }

    private let next = "aaaaaaaaaaaaaaaaaaaaaa02"

    func testAPlayableItemReplacesThePlayerOverTheSameScreen() async throws {
        var asked: [StackEntry] = []
        let router = try router { entry in asked.append(entry); return self.request("e2") }
        router.openCard(CardTarget(resourceType: "show", itemId: "s1"))
        router.play(request("e1"))

        await router.playFromPlayer(episodeId: next, automatic: false)?.value

        XCTAssertEqual(asked, [StackEntry(screenId: "episode-tpl", param: next)], "the item's Episode Screen loads")
        XCTAssertEqual(router.playback, request("e2"))
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "show-tpl", param: "s1")], "Back still returns to the Show Screen")
    }

    func testAnUnplayableItemClosesThePlayerAndOpensItsEpisodeScreen() async throws {
        let router = try router { _ in nil }
        router.play(request("e1"))

        await router.playFromPlayer(episodeId: next, automatic: true)?.value

        XCTAssertNil(router.playback)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: next)])
        XCTAssertEqual(router.autoStarts, 0)
    }

    func testAStalledLoadClosesThePlayerAndOpensTheEpisodeScreenAfterTheLimit() async throws {
        var release: CheckedContinuation<Void, Never>?
        let router = try router { _ in
            await withCheckedContinuation { release = $0 }
            return self.request("e2")
        }
        router.tapToPlayTimeLimit = .milliseconds(50)
        router.play(request("e1"))

        let task = router.playFromPlayer(episodeId: next, automatic: false)
        for _ in 0..<100 where router.playback != nil { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertNil(router.playback)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: next)])
        release?.resume()
        await task?.value
        XCTAssertNil(router.playback, "the late answer is dropped")
    }

    /// Back during the load closes the player and ends the press: the late answer opens nothing.
    func testBackDuringTheLoadDropsTheAnswer() async throws {
        var release: CheckedContinuation<Void, Never>?
        let router = try router { _ in
            await withCheckedContinuation { release = $0 }
            return self.request("e2")
        }
        router.play(request("e1"))

        let task = router.playFromPlayer(episodeId: next, automatic: true)
        for _ in 0..<1000 where release == nil { await Task.yield() }
        router.endPlayback()
        XCTAssertNil(router.selecting)
        release?.resume()
        await task?.value

        XCTAssertNil(router.playback)
        XCTAssertTrue(router.state.stack.isEmpty)
    }

    func testNothingStartsWithoutAPlayerOrDuringAnotherLoad() async throws {
        var release: CheckedContinuation<Void, Never>?
        let router = try router { _ in
            await withCheckedContinuation { release = $0 }
            return self.request("e2")
        }
        XCTAssertNil(router.playFromPlayer(episodeId: next, automatic: false), "no player is up")

        router.play(request("e1"))
        let first = router.playFromPlayer(episodeId: next, automatic: false)
        XCTAssertNotNil(first)
        XCTAssertNil(router.playFromPlayer(episodeId: "aaaaaaaaaaaaaaaaaaaaaa03", automatic: false), "one press at a time")
        for _ in 0..<1000 where release == nil { await Task.yield() }
        release?.resume()
        await first?.value
        XCTAssertEqual(router.playback, request("e2"))
    }

    // MARK: - Auto-start counter ("Still watching?")

    func testOnlyCountdownStartsCountAndAnyOtherStartResets() async throws {
        let router = try router { entry in self.request(entry.param ?? "") }
        router.play(request("e1"))
        XCTAssertEqual(router.autoStarts, 0, "the viewer started it")

        await router.playFromPlayer(episodeId: "aaaaaaaaaaaaaaaaaaaaaa02", automatic: true)?.value
        await router.playFromPlayer(episodeId: "aaaaaaaaaaaaaaaaaaaaaa03", automatic: true)?.value
        await router.playFromPlayer(episodeId: "aaaaaaaaaaaaaaaaaaaaaa04", automatic: true)?.value
        XCTAssertEqual(router.autoStarts, 3)

        await router.playFromPlayer(episodeId: "aaaaaaaaaaaaaaaaaaaaaa05", automatic: false)?.value
        XCTAssertEqual(router.autoStarts, 0, "a press on the offer or the Episodes tab resets it")

        await router.playFromPlayer(episodeId: "aaaaaaaaaaaaaaaaaaaaaa06", automatic: true)?.value
        router.play(request("card"))
        XCTAssertEqual(router.autoStarts, 0, "a card press resets it")

        await router.playFromPlayer(episodeId: "aaaaaaaaaaaaaaaaaaaaaa07", automatic: true)?.value
        router.endPlayback()
        XCTAssertEqual(router.autoStarts, 0, "leaving the player resets it")

        router.play(request("e1"))
        await router.playFromPlayer(episodeId: "aaaaaaaaaaaaaaaaaaaaaa08", automatic: true)?.value
        router.leavePlayback(openingCard: CardTarget(resourceType: "show", itemId: "s1"))
        XCTAssertEqual(router.autoStarts, 0, "Go to show resets it")
    }

    // MARK: - The store path

    /// The next item's Episode Screen loads through the store, as a card press does, and its own
    /// Play request answers: full metadata, and that episode's own playlist, so Up Next chains.
    func testTheNextItemPlaysItsOwnEpisodeScreensRequest() async throws {
        ChromeText.served.strings = [:]
        ContractCache().clear()
        StubProtocol.reset()
        defer { ContractCache().clear(); StubProtocol.reset() }

        let data = try Fixtures.data("episode")
        StubProtocol.queue = [.init(status: 200, body: data)]
        let store = ContractStore(config: TestConfig.staging, client: AppContractClient(config: TestConfig.staging, session: StubProtocol.session()))
        let router = AppRouter(tree: NavigationTree(manifest: try ContractDecoder.manifest(Fixtures.data("manifest"))), diagnostics: Diagnostics())
        router.playRequest = { [store] entry in await store.playRequest(screenId: entry.screenId, param: entry.param) }
        router.play(request("e1"))

        let lesson2 = "629ecd52e1e081635d1110a4"
        await router.playFromPlayer(episodeId: lesson2, automatic: true)?.value

        XCTAssertEqual(StubProtocol.requests.first?.url?.query?.contains("param=\(lesson2)"), true)
        XCTAssertEqual(router.playback?.title, "Lesson 1: Suffering With the Good Shepherd", "the stub answers the captured screen")
        XCTAssertNotNil(router.playback?.playlist)
        XCTAssertEqual(router.autoStarts, 1)
        XCTAssertTrue(router.state.stack.isEmpty)
    }
}

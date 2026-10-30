// cspell:ignore Ähnliche
import XCTest
@testable import HopeTViOS

/// The `relatedEpisodes` block resource read into the request (awe#7391; contract *Related
/// list*, awe#7390). Only items this device can play and whose Episode Screen can open stay.
@MainActor
final class RelatedEpisodesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        super.tearDown()
    }

    /// The `relatedEpisodes` block resource set to `items` (nil: an old server sends no key).
    private func related(_ items: String?) throws -> RelatedEpisodes? {
        try RelatedEpisodes(items.map { try TestDocument.value($0) })
    }

    private func item(_ n: Int, provider: String = "jetstream", showTitle: String = #""Show""#) -> String {
        let link = provider == "jetstream" ? "jsv:Abcdefghij\(n)" : "https://youtu.be/x\(n)"
        return #"{ "id": "bbbbbbbbbbbbbbbbbbbbbb0\#(n)", "title": "R\#(n)", "poster": "https://img.test/\#(n).jpg", "provider": "\#(provider)", "mediaLinks": { "\#(provider)": { "link": "\#(link)" } }, "showTitle": \#(showTitle) }"#
    }

    /// The bug awe#7655 shape: no provider and no link.
    private let noSource = #"{ "id": "bbbbbbbbbbbbbbbbbbbbbb09", "title": "R9", "poster": null, "provider": null, "mediaLinks": {}, "showTitle": "Show" }"#

    func testTheServedOrderIsKept() throws {
        let list = try XCTUnwrap(try related("[\(item(3)), \(item(1)), \(item(2))]"))
        XCTAssertEqual(list.items.map(\.title), ["R3", "R1", "R2"])
        XCTAssertEqual(list.items.map(\.id), ["bbbbbbbbbbbbbbbbbbbbbb03", "bbbbbbbbbbbbbbbbbbbbbb01", "bbbbbbbbbbbbbbbbbbbbbb02"])
        XCTAssertEqual(list.items[0].posterURL?.absoluteString, "https://img.test/3.jpg")
    }

    /// Only items `PlaybackService.playlistItemSource` resolves stay: YouTube and the awe#7655
    /// shape (`provider: null`, empty `mediaLinks`) drop. A YouTube item with a Jetstream link plays.
    func testAnItemThisDeviceCannotPlayDrops() throws {
        let fallback = #"{ "id": "bbbbbbbbbbbbbbbbbbbbbb05", "title": "R5", "provider": "youtube", "mediaLinks": { "youtube": { "link": "dQw4w9WgXcQ" }, "jetstream": { "link": "jsv:4kRn8WqZp2X" } }, "showTitle": null }"#
        let list = try XCTUnwrap(try related("[\(item(1)), \(item(2, provider: "youtube")), \(noSource), \(fallback), \(item(3))]"))
        XCTAssertEqual(list.items.map(\.title), ["R1", "R5", "R3"])
    }

    /// An item with no ObjectId cannot open its Episode Screen, as in `Playlist`.
    func testAnItemWithoutAnObjectIdDrops() throws {
        let bad = #"{ "id": "nope", "title": "Bad", "provider": "jetstream", "mediaLinks": { "jetstream": { "link": "jsv:Abcdefghij7" } } }"#
        let missing = #"{ "title": "None", "provider": "jetstream", "mediaLinks": { "jetstream": { "link": "jsv:Abcdefghij8" } } }"#
        let list = try XCTUnwrap(try related("[\(bad), \(item(1)), \(missing)]"))
        XCTAssertEqual(list.items.map(\.title), ["R1"])
    }

    /// An old server (no key), an empty list and a list with nothing playable: no Related tab.
    func testNoKeyAnEmptyListOrNothingPlayableIsNoList() throws {
        XCTAssertNil(try related(nil))
        XCTAssertNil(try related("[]"))
        XCTAssertNil(try related("null"))
        XCTAssertNil(try related("[\(noSource), \(item(2, provider: "youtube"))]"))
    }

    /// `showTitle` is one secondary line. `null`, missing, empty or whitespace only: no line.
    func testTheShowNameIsALineOnlyWhenItHasText() throws {
        let missing = #"{ "id": "bbbbbbbbbbbbbbbbbbbbbb06", "title": "R6", "provider": "jetstream", "mediaLinks": { "jetstream": { "link": "jsv:Abcdefghij6" } } }"#
        let list = try XCTUnwrap(try related("""
        [\(item(1, showTitle: #""Hope Sabbath School""#)), \(item(2, showTitle: "null")), \(item(3, showTitle: #""""#)),
         \(item(4, showTitle: #""   ""#)), \(missing)]
        """))
        XCTAssertEqual(list.items.map(\.showTitle), ["Hope Sabbath School", nil, nil, nil, nil])
    }

    /// The same https rule as a stream; an untitled item draws the English "Episode".
    func testAnInsecurePosterDropsAndAMissingTitleFallsBack() throws {
        let item = #"{ "id": "bbbbbbbbbbbbbbbbbbbbbb01", "poster": "http://img.test/1.jpg", "provider": "jetstream", "mediaLinks": { "jetstream": { "link": "jsv:Abcdefghij1" } } }"#
        let list = try XCTUnwrap(try related("[\(item)]"))
        XCTAssertNil(list.items[0].posterURL)
        XCTAssertEqual(list.items[0].title, "Episode")
    }

    // MARK: - The request

    /// One player node. `related` is the sibling `relatedEpisodes` block resource beside the
    /// player resource, as the server sends it (nil leaves the key out).
    private func screen(player: String, resource: String, related: String? = nil) throws -> AppScreen {
        let sibling = related.map { #", "relatedEpisodes": \#($0)"# } ?? ""
        return try ContractDecoder.screen(Data("""
        {
          "id": "s1", "kind": "template", "resourceType": "\(player == "EpisodePlayer" ? "episode" : "movie")",
          "resources": {},
          "blockResources": { "p": { "resources": { "\(player == "EpisodePlayer" ? "episodePlayer" : "moviePlayer")": \(resource)\(sibling) } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["p"] },
            "p": { "type": { "resolvedName": "\(player)" }, "props": {}, "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
    }

    private let images = ImageConfig(cdn: "https://images.test", bucket: "bucket")

    /// The live shape: `relatedEpisodes` is a second block resource beside `episodePlayer` on the
    /// same node. Play and tap-to-play read the same request (`BlockRegistry.playRequest(on:)`).
    func testTheEpisodePlayRequestCarriesTheSiblingList() throws {
        let resource = #"{ "provider": "hls", "id": "https://media.test/a.m3u8" }"#
        let screen = try screen(player: "EpisodePlayer", resource: resource, related: "[\(item(2)), \(noSource), \(item(1))]")
        let request = try XCTUnwrap(BlockRegistry.playRequest(on: screen, images: images))
        XCTAssertEqual(request.related?.items.map(\.title), ["R2", "R1"])
        XCTAssertNil(request.playlist, "a related list needs no playlist")
    }

    /// A `relatedEpisodes` field inside the `episodePlayer` resource is not the served shape: no list.
    func testAListInsideTheEpisodePlayerResourceIsNoList() throws {
        let resource = #"{ "provider": "hls", "id": "https://media.test/a.m3u8", "relatedEpisodes": [\#(item(1))] }"#
        let request = try XCTUnwrap(BlockRegistry.playRequest(on: try screen(player: "EpisodePlayer", resource: resource), images: images))
        XCTAssertNil(request.related)
    }

    func testAMovieATrailerAndALivestreamCarryNoList() throws {
        let resource = #"{ "provider": "hls", "id": "https://media.test/m.m3u8" }"#
        let movie = try XCTUnwrap(BlockRegistry.playRequest(on: try screen(player: "MoviePlayer", resource: resource, related: "[\(item(1))]"), images: images))
        XCTAssertNil(movie.related, "only an episode request reads the list")

        let channel = try TestDocument.value(#"{ "title": "Hope TV Deutsch", "hls": "https://live.example.org/x.m3u8" }"#)
        XCTAssertNil(try XCTUnwrap(PlaybackService.liveRequest(channel, images: images)).related)
        let trailer = try TestDocument.value(#"{ "provider": "jetstream", "videoId": "jsv:QBvi99xy28Q" }"#)
        XCTAssertNil(try XCTUnwrap(PlaybackService.trailerRequest(trailer, title: "T", description: nil, artworkURL: nil)).related)
    }
}

/// Which custom tabs the player draws beside the system Info tab (awe#7391).
@MainActor
final class PlayerTabTests: XCTestCase {

    private let url = URL(string: "https://media.test/a.m3u8")!
    private let metadata = PlaybackMetadata(title: "E1", description: nil, showName: nil, artworkURL: nil)

    private func playlist() throws -> Playlist {
        try XCTUnwrap(Playlist(try TestDocument.value(#"{ "playlist": [{ "id": "aaaaaaaaaaaaaaaaaaaaaa01", "title": "E1", "provider": "jetstream", "mediaLinks": { "jetstream": { "link": "jsv:Abcdefghij1" } } }], "playlistIndex": 0 }"#)))
    }

    private func related() throws -> RelatedEpisodes {
        try XCTUnwrap(RelatedEpisodes(try TestDocument.value(#"[{ "id": "bbbbbbbbbbbbbbbbbbbbbb01", "title": "R1", "provider": "jetstream", "mediaLinks": { "jetstream": { "link": "jsv:Abcdefghij2" } }, "showTitle": "Show" }]"#)))
    }

    private func schedule() throws -> [ScheduleModel.Entry] {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1", "kind": "static",
          "blockResources": { "player": { "resources": { "channel": { "title": "Live", "hls": "https://live.test/x.m3u8" },
            "broadcastsLive": { "current": null, "items": [{ "_id": "later", "episodeTitle": "Later", "startsAt": "2099-10-10T16:00:00.000Z", "endsAt": "2099-10-10T16:30:00.000Z" }] } } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["player"] },
            "player": { "type": { "resolvedName": "LivestreamPlayer" }, "props": {}, "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: screen.blockResources)))
        guard case let .player(model)? = node.first(where: { $0.key == .livestreamPlayer })?.content else {
            XCTFail("LivestreamPlayer drew no player")
            throw CancellationError()
        }
        return try XCTUnwrap(model.request.schedule)
    }

    private let anyEpisode: (CardTarget) -> Bool = { $0.resourceType == "episode" }

    func testRelatedComesAfterEpisodes() throws {
        let request = PlaybackRequest(url: url, metadata: metadata, playlist: try playlist(), related: try related(), isHLS: true)
        XCTAssertEqual(PlayerTab.tabs(for: request, canOpen: anyEpisode), [.episodes(try playlist()), .related(try related())])
    }

    func testARelatedListWithNoPlaylistStillShows() throws {
        let request = PlaybackRequest(url: url, metadata: metadata, related: try related(), isHLS: true)
        XCTAssertEqual(PlayerTab.tabs(for: request, canOpen: anyEpisode), [.related(try related())])
    }

    func testNoListIsNoRelatedTab() throws {
        let request = PlaybackRequest(url: url, metadata: metadata, playlist: try playlist(), isHLS: true)
        XCTAssertEqual(PlayerTab.tabs(for: request, canOpen: anyEpisode), [.episodes(try playlist())])
        XCTAssertEqual(PlayerTab.tabs(for: PlaybackRequest(url: url, metadata: metadata, isHLS: true), canOpen: anyEpisode), [])
    }

    /// No Episode Template Screen: a card would open nothing, so neither tab draws.
    func testNoTabWhenAnEpisodeCannotOpen() throws {
        let request = PlaybackRequest(url: url, metadata: metadata, playlist: try playlist(), related: try related(), isHLS: true)
        XCTAssertEqual(PlayerTab.tabs(for: request, canOpen: { _ in false }), [])
    }

    func testALivestreamShowsOnlyItsSchedule() throws {
        let schedule = try schedule()
        let request = PlaybackRequest(url: url, metadata: metadata, recordsProgress: false, schedule: schedule, isHLS: true)
        XCTAssertEqual(PlayerTab.tabs(for: request, canOpen: anyEpisode), [.schedule(schedule)])
        // Every row ended before the player opened: no tab.
        let after = try XCTUnwrap(ISO8601DateFormatter().date(from: "2099-10-10T17:00:00Z"))
        XCTAssertEqual(PlayerTab.tabs(for: request, canOpen: anyEpisode, now: after), [])
    }

    func testTheTabTitleIsTheRelatedLabel() throws {
        ChromeText.served.strings = [:]
        XCTAssertEqual(ChromeText.manifestKey(.relatedLabel), "tvRelatedLabel")
        XCTAssertEqual(ChromeText.string(.relatedLabel), "Related")
        XCTAssertEqual(PlayerTab.related(try related()).title, "Related")
        ChromeText.served.strings = ["tvRelatedLabel": "Ähnliche"]
        XCTAssertEqual(PlayerTab.related(try related()).title, "Ähnliche")
        ChromeText.served.strings = [:]
    }
}

/// Select on a Related card starts the item as an Episodes tab select does:
/// `PlayerController` calls `onEpisode(item.id, false)`, which is `AppRouter.playFromPlayer`.
/// The press itself is proved by `RelatedTabUITests`.
@MainActor
final class RelatedSelectRoutingTests: XCTestCase {

    func testSelectLoadsTheItemsEpisodeScreenAndReplacesThePlayer() async throws {
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1, "app": { "design": "tv" }, "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [{ "id": "home", "kind": "static" },
                      { "id": "episode-tpl", "kind": "template", "resourceType": "episode" }],
          "preset": {}
        }
        """.utf8))
        let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
        func request(_ name: String) -> PlaybackRequest {
            PlaybackRequest(url: URL(string: "https://media.test/\(name).m3u8")!,
                            metadata: PlaybackMetadata(title: name, description: nil, showName: nil, artworkURL: nil), isHLS: true)
        }
        var asked: [StackEntry] = []
        router.playRequest = { entry in asked.append(entry); return request("related") }
        let related = try XCTUnwrap(RelatedEpisodes(try TestDocument.value(#"[{ "id": "bbbbbbbbbbbbbbbbbbbbbb01", "title": "R1", "provider": "jetstream", "mediaLinks": { "jetstream": { "link": "jsv:Abcdefghij2" } } }]"#)))
        router.play(request("e1"))

        await router.playFromPlayer(episodeId: related.items[0].id, automatic: false)?.value

        XCTAssertEqual(asked, [StackEntry(screenId: "episode-tpl", param: "bbbbbbbbbbbbbbbbbbbbbb01")], "the item's Episode Screen loads")
        XCTAssertEqual(router.playback, request("related"))
        XCTAssertEqual(router.autoStarts, 0, "a press is not an automatic start")
    }
}

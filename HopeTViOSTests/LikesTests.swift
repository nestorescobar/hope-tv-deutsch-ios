import UIKit
import XCTest
@testable import HopeTViOS

/// TV Likes (awe#6871, ADR-0259 §3–§5): the `likes` saved list (device list signed out, member list
/// signed in, the one-time import), the Umami `like` / `unlike` event at each press, and the three
/// places that offer Like: the card menu, the detail screens and the player's transport bar.

private let showId = "61975e24d9c698836400305c"
private let episodeId = "629ecd4ce1e081635d11107e"
private let movieId = "65f0a1b2c3d4e5f60718293a"
private let websiteId = "0f8a2c5e-6b1d-4e7a-9c3f-2d4b5a6e7f80"

private func item(_ itemType: SavedItem.ItemType, _ itemId: String, title: String = "T") -> SavedItem {
    SavedItem(itemType: itemType, itemId: itemId, title: title, imageURL: URL(string: "https://images.test/\(itemId).jpg"),
              savedAt: .distantPast)
}

/// A `UserDefaults` of its own, so no test reads or writes the app's list.
private func scratchDefaults() -> UserDefaults {
    let name = "likes-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let analytics = AnalyticsConfig(websiteId: websiteId, host: URL(string: "https://stats.test")!)

/// Records each request; it never touches a network.
private final class RecordingSender: UmamiSending {
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) {
        requests.append(request)
    }

    /// The payloads of the sent events.
    var payloads: [[String: Any]] {
        requests.compactMap { request in
            guard let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            return json["payload"] as? [String: Any]
        }
    }

    var names: [String] { payloads.compactMap { $0["name"] as? String } }
}

// MARK: - The list, the press and the event

@MainActor
final class LikesTests: XCTestCase {

    private var service: FakeMemberService!
    private var account: MemberAccount!
    private var device: DeviceItemListStore!
    private var sender: RecordingSender!
    private var config: AnalyticsConfig?
    private var likes: Likes!

    override func setUp() async throws {
        service = FakeMemberService()
        account = MemberAccount(service: service, store: MemorySessionStore(), now: { Date(timeIntervalSince1970: 1_000_000) })
        device = DeviceItemListStore(key: SavedList.likes.deviceKey, defaults: scratchDefaults())
        sender = RecordingSender()
        config = analytics
        likes = makeLikes(sender: sender)
    }

    private func makeLikes(sender: UmamiSending) -> Likes {
        Likes(list: SavedItemList(list: .likes, account: account, device: device),
              analytics: { [unowned self] in self.config },
              sender: sender, language: "de", screen: "1920x1080", userAgent: "UA")
    }

    private func signIn(_ token: String = "tok") {
        account.signedIn(MemberSession(token: token, expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana"))
    }

    func testTheLikesListHasItsOwnDeviceKey() {
        XCTAssertEqual(SavedList.likes.rawValue, "likes")
        XCTAssertEqual(SavedList.likes.deviceKey, "saved-list-likes-v1")
        XCTAssertNotEqual(SavedList.likes.deviceKey, SavedList.watchlist.deviceKey)
    }

    /// Signed out: a press likes on the device, a second press removes the like. Each press sends one event.
    func testSignedOutAPressLikesOnTheDeviceAndSendsOneEvent() async throws {
        let episode = item(.episode, episodeId, title: "Lesson 1")

        await likes.toggle(episode)

        XCTAssertTrue(likes.isLiked(episode))
        XCTAssertEqual(device.items.map(\.id), ["episode:\(episodeId)"])
        XCTAssertTrue(service.savedCalls.isEmpty, "signed out sends no member call")
        XCTAssertEqual(sender.names, ["like"])
        let data = try XCTUnwrap(sender.payloads.first?["data"] as? [String: String])
        XCTAssertEqual(data, ["itemType": "episode", "itemId": episodeId, "title": "Lesson 1"])

        await likes.toggle(episode)

        XCTAssertFalse(likes.isLiked(episode))
        XCTAssertTrue(device.items.isEmpty)
        XCTAssertEqual(sender.names, ["like", "unlike"])
    }

    func testAMovieCanBeLikedAndAShowCannot() async {
        await likes.toggle(item(.movie, movieId))
        await likes.toggle(item(.show, showId))

        XCTAssertEqual(device.items.map(\.id), ["movie:\(movieId)"])
        XCTAssertEqual(sender.names, ["like"], "a show press does nothing and sends nothing")
        XCTAssertTrue(Likes.canLike(.episode))
        XCTAssertTrue(Likes.canLike(.movie))
        XCTAssertFalse(Likes.canLike(.show))
    }

    /// No `analytics` in the manifest: the like still works, and no event goes out.
    func testNoAnalyticsSendsNoEvent() async {
        config = nil

        await likes.toggle(item(.episode, episodeId))

        XCTAssertTrue(likes.isLiked(item(.episode, episodeId)))
        XCTAssertTrue(sender.requests.isEmpty)
    }

    /// The real sender never awaits the post: a slow Umami host does not hold the press, and a
    /// failed post does not undo the like.
    func testASlowOrFailedPostNeitherBlocksNorUndoesTheLike() async throws {
        StubProtocol.reset()
        defer { StubProtocol.reset() }
        StubProtocol.queue = [.init(status: 500, delay: 3)]
        likes = makeLikes(sender: UmamiSender(session: StubProtocol.session()))
        let episode = item(.episode, episodeId)

        let started = Date()
        await likes.toggle(episode)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the press does not wait for the post")
        XCTAssertTrue(likes.isLiked(episode))

        // The post goes out and fails; the like stays.
        let deadline = Date().addingTimeInterval(5)
        while StubProtocol.requests.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(StubProtocol.requests.count, 1)
        try await Task.sleep(for: .seconds(3.5))
        XCTAssertTrue(likes.isLiked(episode))
        XCTAssertEqual(device.items.count, 1)
    }

    /// Signed in: the press goes to the member route, and the event goes out too.
    func testSignedInAPressCallsTheLikesRouteAndSendsTheEvent() async {
        signIn()
        await likes.list.load()

        await likes.toggle(item(.episode, episodeId))

        XCTAssertEqual(service.savedCalls.last, .init(verb: "PUT", list: .likes, token: "tok", ids: ["episode:\(episodeId)"]))
        XCTAssertTrue(likes.isLiked(item(.episode, episodeId)))
        XCTAssertTrue(device.items.isEmpty, "a signed-in like never writes the device")
        XCTAssertEqual(sender.names, ["like"])

        await likes.toggle(item(.episode, episodeId))

        XCTAssertEqual(service.savedCalls.last?.verb, "DELETE")
        XCTAssertEqual(sender.names, ["like", "unlike"])
    }

    /// A second press while the first one's `PUT` is in flight does nothing: no second call and
    /// no second event, so one like counts once.
    func testAPressWhileTheWriteIsInFlightSendsNoSecondEvent() async {
        signIn()
        await likes.list.load()
        service.holdsSave = true
        let episode = item(.episode, episodeId)

        let first = Task { await likes.toggle(episode) }
        while !service.isHoldingSave { await Task.yield() }
        await likes.toggle(episode)
        service.releaseSave()
        await first.value

        XCTAssertEqual(service.savedCalls.filter { $0.verb == "PUT" }.count, 1)
        XCTAssertEqual(sender.names, ["like"])
    }

    // MARK: An unknown state (review fix: every like counts once)

    /// Signed in with no loaded list (a failed load, a cut page, a press before the load): the
    /// press asks `/contains` first. The server already holds the like: no event, no write.
    func testAnUnknownStateThatIsLikedSendsNoEventAndNoWrite() async {
        signIn()
        service.savedIdsResult = .success([episodeId])
        let episode = item(.episode, episodeId)
        XCTAssertNil(likes.list.isSaved(.episode, episodeId), "unknown before the press")

        await likes.toggle(episode)

        XCTAssertEqual(service.savedCalls.map(\.verb), ["CONTAINS"])
        XCTAssertTrue(sender.requests.isEmpty, "a like the server holds is not counted again")
        XCTAssertTrue(likes.isLiked(episode), "the state redraws as Liked")
    }

    func testAnUnknownStateThatIsNotLikedSendsOneLikeAndAPut() async {
        signIn()
        service.savedIdsResult = .success([])

        await likes.toggle(item(.episode, episodeId))

        XCTAssertEqual(service.savedCalls.map(\.verb), ["CONTAINS", "PUT"])
        XCTAssertEqual(sender.names, ["like"])
        XCTAssertTrue(likes.isLiked(item(.episode, episodeId)))
    }

    /// `/contains` fails: the press falls back to a like and a `PUT` (idempotent on the server).
    func testAFailedCheckFallsBackToALike() async {
        signIn()
        service.savedIdsResult = .failure(.rejected(.httpStatus(503)))

        await likes.toggle(item(.movie, movieId))

        XCTAssertEqual(service.savedCalls.map(\.verb), ["CONTAINS", "PUT"])
        XCTAssertEqual(sender.names, ["like"])
    }

    /// A second press while the check runs does nothing: one check, one write, one event.
    func testASecondPressDuringTheCheckDoesNothing() async {
        signIn()
        service.savedIdsResult = .success([])
        service.holdsSavedIds = true
        let episode = item(.episode, episodeId)

        let first = Task { await likes.toggle(episode) }
        while !service.isHoldingSavedIds { await Task.yield() }
        await likes.toggle(episode)
        XCTAssertEqual(service.savedCalls.map(\.verb), ["CONTAINS"], "the second press sends nothing")
        service.releaseSavedIds()
        await first.value

        XCTAssertEqual(service.savedCalls.map(\.verb), ["CONTAINS", "PUT"])
        XCTAssertEqual(sender.names, ["like"])
    }

    /// Continue imports the device likes once, the device copy goes after the 2xx, and the import
    /// sends no event.
    func testContinueImportsTheDeviceLikesOnceAndSendsNoEvent() async {
        await likes.toggle(item(.episode, episodeId))
        await likes.toggle(item(.movie, movieId))
        let events = sender.requests.count
        signIn()
        service.savedItemsResult = .success([item(.movie, movieId), item(.episode, episodeId)])

        await likes.list.signInCoverClosed(continued: true)
        await likes.list.importDeviceList()

        XCTAssertEqual(service.savedCalls.map(\.verb), ["IMPORT", "GET"], "one import per sign-in")
        XCTAssertEqual(service.savedCalls.first?.list, .likes)
        XCTAssertEqual(service.savedCalls.first?.ids, ["movie:\(movieId)", "episode:\(episodeId)"])
        XCTAssertTrue(device.items.isEmpty, "a 2xx deletes the device copy")
        XCTAssertEqual(sender.requests.count, events, "the import sends no event")
        XCTAssertTrue(likes.isLiked(item(.episode, episodeId)), "the member list shows Liked")
    }

    /// After sign-out no account like is left on the device.
    func testSignOutLeavesNoAccountLike() async {
        signIn()
        service.savedItemsResult = .success([item(.movie, movieId)])
        await likes.list.load()
        await likes.toggle(item(.episode, episodeId))

        await account.signOut()

        XCTAssertTrue(device.items.isEmpty)
        XCTAssertFalse(likes.isLiked(item(.movie, movieId)))
        XCTAssertFalse(likes.isLiked(item(.episode, episodeId)))
    }

    /// The Amendment: a failed import keeps the device copy, so it shows again after sign-out.
    func testAFailedImportKeepsTheDeviceLikes() async {
        await likes.toggle(item(.episode, episodeId))
        signIn()
        service.importSavedResult = .failure(.rejected(.httpStatus(503)))

        await likes.list.signInCoverClosed(continued: true)
        await account.signOut()

        XCTAssertEqual(device.items.map(\.id), ["episode:\(episodeId)"])
        XCTAssertTrue(likes.isLiked(item(.episode, episodeId)))
    }
}

// MARK: - The Umami event

final class UmamiEventTests: XCTestCase {

    /// One named event: `name` and `data` in the payload (a payload without `name` is a pageview).
    func testTheRequestPostsANamedEvent() throws {
        let request = try XCTUnwrap(Umami.eventRequest(
            analytics, name: "like", data: ["itemType": "episode", "itemId": episodeId, "title": "Lesson 1"],
            url: "/episode/\(episodeId)", language: "de", screen: "1920x1080", userAgent: "UA"
        ))

        XCTAssertEqual(request.url?.absoluteString, "https://stats.test/api/send")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "UA")
        XCTAssertNil(request.value(forHTTPHeaderField: "ClientToken"), "no contract header goes to Umami")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "event")
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["website", "url", "language", "screen", "name", "data"])
        XCTAssertEqual(payload["website"] as? String, websiteId)
        XCTAssertEqual(payload["url"] as? String, "/episode/\(episodeId)")
        XCTAssertEqual(payload["language"] as? String, "de")
        XCTAssertEqual(payload["screen"] as? String, "1920x1080")
        XCTAssertEqual(payload["name"] as? String, "like")
        XCTAssertEqual(payload["data"] as? [String: String], ["itemType": "episode", "itemId": episodeId, "title": "Lesson 1"])
    }

    func testATrailingSlashOnTheHostDoesNotDoubleThePath() throws {
        let config = AnalyticsConfig(websiteId: websiteId, host: URL(string: "https://stats.test/")!)
        let request = try XCTUnwrap(Umami.eventRequest(config, name: "like", data: [:], url: "/", language: "en",
                                                       screen: "1920x1080", userAgent: "UA"))

        XCTAssertEqual(request.url?.absoluteString, "https://stats.test/api/send")
    }

    /// A browser-shaped agent: Umami's bot filter drops other agents (`apps/mobile` umami.ts).
    func testTheUserAgentIsBrowserShaped() {
        XCTAssertEqual(Umami.userAgent(osVersion: "18.0", appVersion: "0.1.0"),
                       "Mozilla/5.0 (Apple TV; CPU OS 18_0 like Mac OS X) AWEApp/0.1.0")
        XCTAssertEqual(Umami.userAgent(osVersion: "18.2.1", appVersion: ""),
                       "Mozilla/5.0 (Apple TV; CPU OS 18_2_1 like Mac OS X) AWEApp/0")
    }

    // MARK: The manifest `analytics` object

    private func manifest(_ analytics: String?) throws -> AppManifest {
        let extra = analytics.map { #", "analytics": \#($0)"# } ?? ""
        return try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [{ "id": "home", "kind": "static" }],
          "preset": {}\(extra)
        }
        """.utf8))
    }

    func testTheManifestDecodesTheAnalyticsObject() throws {
        let decoded = try manifest(#"{ "provider": "umami", "websiteId": "\#(websiteId)", "host": "https://stats.hopeplatform.org" }"#)

        XCTAssertEqual(decoded.analytics, AnalyticsConfig(websiteId: websiteId, host: URL(string: "https://stats.hopeplatform.org")!))
    }

    /// Absent (analytics off) or unusable: nil, so no event goes out. The manifest still decodes.
    func testAMissingOrUnusableAnalyticsObjectIsNil() throws {
        XCTAssertNil(try manifest(nil).analytics)
        XCTAssertNil(try manifest("null").analytics)
        XCTAssertNil(try manifest(#"{ "provider": "ga4", "websiteId": "x", "host": "https://stats.test" }"#).analytics)
        XCTAssertNil(try manifest(#"{ "provider": "umami", "websiteId": "", "host": "https://stats.test" }"#).analytics)
        XCTAssertNil(try manifest(#"{ "provider": "umami", "websiteId": "x", "host": "http://stats.test" }"#).analytics,
                     "never posts over plain http")
        XCTAssertNil(try manifest(#"{ "provider": "umami", "websiteId": "x" }"#).analytics)
    }
}

// MARK: - The routes on the wire

final class LikesWiringTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    private var client: MemberClient {
        MemberClient(contract: AppContractClient(config: TestConfig.staging, session: StubProtocol.session()))
    }

    /// The likes routes are the watchlist routes under `likes`, with the same models.
    func testTheLikesRoutes() async throws {
        StubProtocol.queue = [
            .init(status: 200, body: Data("""
            { "items": [{ "_id": "r1", "itemType": "movie", "createdAt": "2026-10-14T10:00:00.000Z",
                          "movie": { "_id": "\(movieId)", "title": "The Movie" } }], "nextCursor": null }
            """.utf8)),
            .init(status: 201),
            .init(status: 204),
            .init(status: 200, body: Data(#"{"items":["\#(episodeId)"]}"#.utf8)),
            .init(status: 200, body: Data(#"{"imported":1,"skipped":0,"refused":[]}"#.utf8)),
        ]

        let page = try await client.savedItems(.likes, token: "tok").get()
        try await client.save(.likes, token: "tok", itemType: .episode, itemId: episodeId).get()
        try await client.unsave(.likes, token: "tok", itemType: .movie, itemId: movieId).get()
        let ids = try await client.savedIds(.likes, token: "tok", itemType: .episode, ids: [episodeId]).get()
        try await client.importSaved(.likes, token: "tok", items: [item(.episode, episodeId)]).get()

        XCTAssertEqual(page.items.map(\.id), ["movie:\(movieId)"])
        XCTAssertEqual(ids, [episodeId])
        let requests = StubProtocol.requests
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "GET /v1/app/hope-tv/member/likes",
            "PUT /v1/app/hope-tv/member/likes/episode/\(episodeId)",
            "DELETE /v1/app/hope-tv/member/likes/movie/\(movieId)",
            "GET /v1/app/hope-tv/member/likes/contains",
            "POST /v1/app/hope-tv/member/likes/import",
        ])
        XCTAssertEqual(requests.first?.url?.query, "limit=100")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "session") == "tok" })
    }
}

// MARK: - Where Like shows: the card menu, the detail screens, the transport bar

@MainActor
final class LikeSurfaceTests: XCTestCase {

    private func screen(_ nodes: String, resources: String = "{}") throws -> AppScreen {
        try ContractDecoder.screen(Data("""
        { "id": "s1", "kind": "static", "blockResources": \(resources), "content": \(nodes) }
        """.utf8))
    }

    private func evaluate(_ screen: AppScreen, watchLater: [SavedItem] = []) throws -> EvaluatedNode {
        try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: RenderContext(blockResources: screen.blockResources, screenResources: screen.resources,
                                   images: ImageConfig(cdn: "https://images.test", bucket: "bucket"), watchLater: watchLater)
        ))
    }

    // MARK: The card menu

    /// Episode and movie cards offer Like beside Watch later; a show card offers Watch later only.
    func testEpisodeAndMovieCardsOfferLikeAndShowCardsDoNot() throws {
        let screen = try screen("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["shows", "episodes", "movies"] },
          "shows": { "type": { "resolvedName": "ShowList" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] },
          "episodes": { "type": { "resolvedName": "EpisodesList" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] },
          "movies": { "type": { "resolvedName": "MovieList" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] }
        }
        """, resources: """
        {
          "shows": { "resources": { "shows": { "items": [{ "_id": "\(showId)", "title": "Sabbath School" }], "count": 1 } } },
          "episodes": { "resources": { "episodes": { "items": [{ "_id": "\(episodeId)", "title": "Lesson 1" }], "count": 1 } } },
          "movies": { "resources": { "movies": { "items": [{ "id": "\(movieId)", "title": "The Movie" }], "count": 1 } } }
        }
        """)
        let node = try evaluate(screen)
        func firstMenu(_ id: String) -> CardMenu? {
            guard case let .shelf(model)? = node.first(where: { $0.id == id })?.content else { return nil }
            return model.cards.first?.menu
        }

        XCTAssertNotNil(firstMenu("shows"), "a show card keeps its Watch later menu")
        XCTAssertNil(firstMenu("shows")?.likeItem, "a show cannot be liked")
        XCTAssertEqual(firstMenu("episodes")?.likeItem?.id, "episode:\(episodeId)")
        XCTAssertEqual(firstMenu("episodes")?.likeItem?.title, "Lesson 1")
        XCTAssertEqual(firstMenu("movies")?.likeItem?.id, "movie:\(movieId)")
    }

    /// A Watch later shelf card is an episode or movie card too: its menu offers Like beside Remove.
    func testAWatchLaterShelfCardOffersLikeForAnEpisode() throws {
        let screen = try screen("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["later"] },
          "later": { "type": { "resolvedName": "MediaLibraryWatchlist" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] }
        }
        """)
        let node = try evaluate(screen, watchLater: [item(.episode, episodeId), item(.show, showId)])
        guard case let .shelf(model)? = node.first(where: { $0.id == "later" })?.content else { return XCTFail("no shelf") }

        XCTAssertEqual(model.cards.map(\.menu?.likeItem?.id), ["episode:\(episodeId)", nil])
    }

    // MARK: The detail screens

    func testTheEpisodeDetailCarriesLikeWithItsHeading() throws {
        let node = try evaluate(try ContractDecoder.screen(Fixtures.data("episode")))
        guard case let .episodeDetail(model)? = node.first(where: { $0.key == .episodeDetail })?.content else {
            return XCTFail("EpisodeDetail drew nothing")
        }

        XCTAssertEqual(model.like?.id, "episode:\(episodeId)")
        XCTAssertEqual(model.like, model.watchLater, "the same snapshot as Watch later")
    }

    func testABodyOnlyEpisodeDetailDrawsNoLike() throws {
        let screen = try screen("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["d"] },
          "d": { "type": { "resolvedName": "EpisodeDetail" }, "props": { "showTitle": false, "showShowTitle": false },
                 "custom": {}, "parent": "ROOT", "nodes": [] }
        }
        """, resources: """
        { "d": { "resources": { "episodeDetail": { "_id": "\(episodeId)", "title": "Lesson 1", "abstract": "A" } } } }
        """)
        guard case let .episodeDetail(model)? = try evaluate(screen).first(where: { $0.id == "d" })?.content else {
            return XCTFail("EpisodeDetail drew nothing")
        }
        XCTAssertNil(model.like)
    }

    /// `MovieDetail` carries Like with its title, also when the Watch later toggle is off; it then
    /// asks for the default focus as the block's only button.
    func testTheMovieDetailCarriesLike() throws {
        let screen = try screen("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["d"] },
          "d": { "type": { "resolvedName": "MovieDetail" }, "props": { "showWatchlistToggle": false },
                 "custom": {}, "parent": "ROOT", "nodes": [] }
        }
        """, resources: """
        { "d": { "resources": { "movieDetail": { "_id": "\(movieId)", "title": "The Movie" } } } }
        """)
        let node = try evaluate(screen)
        guard case let .detail(model)? = node.first(where: { $0.id == "d" })?.content else { return XCTFail("MovieDetail drew nothing") }

        XCTAssertNil(model.watchLater)
        XCTAssertEqual(model.like?.id, "movie:\(movieId)")
        XCTAssertEqual(model.like?.title, "The Movie")
        XCTAssertEqual(node.firstFocusNodeId, "d")
    }

    /// A detail block offers Watch later and Like only for an item the screen's player can play.
    /// No player resource on the screen keeps both.
    func testAnUnplayableItemOffersNoWatchLaterOrLike() throws {
        func episodeDetail(player: String?) throws -> EpisodeDetailModel? {
            let resources = player.map { #""p": { "resources": { "episodePlayer": \#($0) } },"# } ?? ""
            let screen = try screen("""
            {
              "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["p", "d"] },
              "p": { "type": { "resolvedName": "EpisodePlayer" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] },
              "d": { "type": { "resolvedName": "EpisodeDetail" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] }
            }
            """, resources: """
            { \(resources) "d": { "resources": { "episodeDetail": { "_id": "\(episodeId)", "title": "Lesson 1" } } } }
            """)
            guard case let .episodeDetail(model)? = try evaluate(screen).first(where: { $0.id == "d" })?.content else { return nil }
            return model
        }
        func movieDetail(player: String?) throws -> ShowDetailModel? {
            let resources = player.map { #""p": { "resources": { "moviePlayer": \#($0) } },"# } ?? ""
            let screen = try screen("""
            {
              "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["p", "d"] },
              "p": { "type": { "resolvedName": "MoviePlayer" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] },
              "d": { "type": { "resolvedName": "MovieDetail" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] }
            }
            """, resources: """
            { \(resources) "d": { "resources": { "movieDetail": { "_id": "\(movieId)", "title": "The Movie" } } } }
            """)
            guard case let .detail(model)? = try evaluate(screen).first(where: { $0.id == "d" })?.content else { return nil }
            return model
        }
        let playable = #"{ "provider": "hls", "id": "https://media.test/a.m3u8", "poster": null }"#
        let youtube = #"{ "provider": "youtube", "id": "abc", "poster": null }"#
        let noSource = #"{ "error": "NO_SOURCE" }"#

        for player in [youtube, noSource] {
            let episode = try XCTUnwrap(try episodeDetail(player: player), "the text still draws")
            XCTAssertNil(episode.watchLater, player)
            XCTAssertNil(episode.like, player)
            let movie = try XCTUnwrap(try movieDetail(player: player), "the text still draws")
            XCTAssertNil(movie.watchLater, player)
            XCTAssertNil(movie.like, player)
        }
        for player in [playable, nil] {
            XCTAssertEqual(try episodeDetail(player: player)?.watchLater?.id, "episode:\(episodeId)")
            XCTAssertEqual(try episodeDetail(player: player)?.like?.id, "episode:\(episodeId)")
            XCTAssertEqual(try movieDetail(player: player)?.watchLater?.id, "movie:\(movieId)")
            XCTAssertEqual(try movieDetail(player: player)?.like?.id, "movie:\(movieId)")
        }
    }

    func testAShowDetailDrawsNoLike() throws {
        guard case let .detail(model)? = try evaluate(try ContractDecoder.screen(Fixtures.data("show")))
            .first(where: { $0.key == .showDetail })?.content else { return XCTFail("ShowDetail drew nothing") }

        XCTAssertNotNil(model.watchLater)
        XCTAssertNil(model.like)
    }

    // MARK: The transport bar

    private func request(_ metadata: PlaybackMetadata, recordsProgress: Bool = true) -> PlaybackRequest {
        PlaybackRequest(url: URL(string: "https://cdn.test/a.m3u8")!, metadata: metadata, recordsProgress: recordsProgress, isHLS: true)
    }

    /// The player likes the on-demand episode, else the movie. A livestream and a trailer have none.
    func testThePlayerLikesTheEpisodeOrTheMovie() {
        let art = URL(string: "https://images.test/art.jpg")
        let episode = request(PlaybackMetadata(title: "Lesson 1", description: nil, showName: "S", artworkURL: art, episodeId: episodeId))
        let movie = request(PlaybackMetadata(title: "The Movie", description: nil, showName: nil, artworkURL: art, movieId: movieId))
        let live = request(PlaybackMetadata(title: "Live", description: nil, showName: nil, artworkURL: art), recordsProgress: false)
        let freeText = request(PlaybackMetadata(title: "E", description: nil, showName: nil, artworkURL: nil, episodeId: "e1"))

        XCTAssertEqual(episode.likeItem, SavedItem(itemType: .episode, itemId: episodeId, title: "Lesson 1", imageURL: art, savedAt: .distantPast))
        XCTAssertEqual(movie.likeItem?.id, "movie:\(movieId)")
        XCTAssertNil(live.likeItem)
        XCTAssertNil(freeText.likeItem, "only an ObjectId reaches a route path")
    }

    /// "Like", or "Liked" with a filled heart and the on state.
    func testTheTransportBarItemShowsTheState() {
        let off = TransportLike.action(liked: false) {}
        let on = TransportLike.action(liked: true) {}

        XCTAssertEqual(off.title, "Like")
        XCTAssertEqual(off.state, .off)
        XCTAssertEqual(on.title, "Liked")
        XCTAssertEqual(on.state, .on)
        XCTAssertEqual(on.accessibilityIdentifier, "player-like")
        XCTAssertNotEqual(on.image, off.image)
    }

    func testTheChromeStrings() {
        XCTAssertEqual(ChromeText.string(.like), "Like")
        XCTAssertEqual(ChromeText.string(.liked), "Liked")
        XCTAssertEqual(ChromeText.string(.unlike), "Unlike")
    }
}

// cspell:ignore später
import XCTest
@testable import HopeTViOS

/// TV Watch later (awe#6869, ADR-0259 §3 and §5): the device list, the signed-in member list, the
/// one-time import, the card menu, the detail toggle and the `MediaLibraryWatchlist` shelf.

private let showId = "61975e24d9c698836400305c"
private let episodeId = "629ecd4ce1e081635d11107e"
private let movieId = "65f0a1b2c3d4e5f60718293a"

/// A 24-hex ObjectId made from a number.
private func objectId(_ number: Int) -> String {
    String(format: "%024x", number)
}

private func item(_ itemType: SavedItem.ItemType, _ itemId: String, title: String = "T", at seconds: TimeInterval = 0) -> SavedItem {
    SavedItem(itemType: itemType, itemId: itemId, title: title, imageURL: URL(string: "https://images.test/\(itemId).jpg"),
              savedAt: Date(timeIntervalSince1970: seconds))
}

/// A `UserDefaults` of its own, so no test reads or writes the app's list.
private func scratchDefaults() -> UserDefaults {
    let name = "watch-later-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - The device list

@MainActor
final class DeviceItemListStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = scratchDefaults()
    }

    private func store(_ key: String = SavedList.watchlist.deviceKey) -> DeviceItemListStore {
        DeviceItemListStore(key: key, defaults: defaults)
    }

    func testAnAddGoesFirstAndOutlivesTheStore() {
        let first = store()
        first.add(item(.show, showId, at: 1))
        first.add(item(.episode, episodeId, at: 2))

        XCTAssertEqual(first.items.map(\.itemId), [episodeId, showId], "newest first")
        XCTAssertTrue(first.contains(.show, showId))
        XCTAssertFalse(first.contains(.episode, showId), "the type is part of the identity")
        XCTAssertEqual(store().items, first.items, "a new store reads what the first one saved")
    }

    /// Full at 100: a new save drops the oldest entry.
    func testAFullListDropsTheOldestEntry() {
        let list = store()
        for index in 0..<DeviceItemListStore.limit {
            list.add(item(.episode, objectId(index), at: TimeInterval(index)))
        }
        list.add(item(.movie, movieId, at: 500))

        XCTAssertEqual(list.items.count, 100)
        XCTAssertEqual(list.items.first?.itemId, movieId)
        XCTAssertFalse(list.contains(.episode, objectId(0)), "the oldest went")
        XCTAssertTrue(list.contains(.episode, objectId(1)))
    }

    /// Already saved: it keeps its place and its time, as the server keeps its row (200).
    func testAnItemSavedAgainKeepsItsPlace() {
        let list = store()
        list.add(item(.show, showId, at: 1))
        list.add(item(.episode, episodeId, at: 2))

        list.add(item(.show, showId, at: 3))

        XCTAssertEqual(list.items.map(\.itemId), [episodeId, showId])
        XCTAssertEqual(list.items.last?.savedAt, Date(timeIntervalSince1970: 1))
    }

    func testARemoveOutlivesTheStore() {
        let list = store()
        list.add(item(.show, showId))
        list.add(item(.episode, episodeId))

        list.remove(.show, showId)

        XCTAssertEqual(list.items.map(\.itemId), [episodeId])
        XCTAssertEqual(store().items.map(\.itemId), [episodeId])
    }

    /// The store is generic over its key: the Likes list (ADR-0259) gets a second, separate list.
    func testTwoKeysAreTwoLists() {
        store("list-a").add(item(.show, showId))

        XCTAssertEqual(store("list-a").items.count, 1)
        XCTAssertTrue(store("list-b").items.isEmpty)
    }

    /// An entry this build cannot read (an unknown type) is skipped; the rest still read.
    func testAnUnknownEntryIsSkipped() throws {
        let saved = """
        [{ "itemType": "podcast", "itemId": "x", "title": "X", "savedAt": 0 },
         { "itemType": "show", "itemId": "\(showId)", "title": "S", "savedAt": 0 }]
        """
        defaults.set(Data(saved.utf8), forKey: "list-a")

        XCTAssertEqual(store("list-a").items.map(\.itemId), [showId])
    }

    func testImportedEntriesGoAndALaterSaveStays() {
        let list = store()
        list.add(item(.show, showId))
        let sent = Set(list.items.map(\.id))
        list.add(item(.episode, episodeId))

        list.removeImported(sent)

        XCTAssertEqual(list.items.map(\.itemId), [episodeId])
        XCTAssertEqual(store().items.map(\.itemId), [episodeId])
    }
}

// MARK: - The source switch

@MainActor
final class SavedItemListTests: XCTestCase {

    private let session = MemberSession(token: "tok", expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana")
    private var service: FakeMemberService!
    private var sessions: MemorySessionStore!
    private var account: MemberAccount!
    private var device: DeviceItemListStore!
    private var list: SavedItemList!

    override func setUp() async throws {
        service = FakeMemberService()
        sessions = MemorySessionStore()
        account = MemberAccount(service: service, store: sessions, now: { Date(timeIntervalSince1970: 1_000_000) })
        device = DeviceItemListStore(key: SavedList.watchlist.deviceKey, defaults: scratchDefaults())
        list = SavedItemList(list: .watchlist, account: account, device: device)
    }

    private func signIn(_ token: String = "tok") {
        account.signedIn(MemberSession(token: token, expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana"))
    }

    // MARK: Signed out

    func testSignedOutTheDeviceListIsTheSource() async {
        await list.save(item(.show, showId))
        await list.save(item(.episode, episodeId))

        XCTAssertEqual(list.items.map(\.itemId), [episodeId, showId])
        XCTAssertEqual(list.isSaved(.show, showId), true)
        XCTAssertEqual(list.isSaved(.movie, movieId), false)
        XCTAssertEqual(device.items.count, 2)
        XCTAssertTrue(service.savedCalls.isEmpty, "signed out sends nothing")

        await list.remove(.show, showId)

        XCTAssertEqual(list.items.map(\.itemId), [episodeId])
        XCTAssertEqual(list.isSaved(.show, showId), false)
    }

    /// A save takes the time it happens, not the card model's placeholder.
    func testASaveTakesTheTimeOfTheSave() async {
        let before = Date()
        await list.save(item(.show, showId, at: 0))

        XCTAssertGreaterThanOrEqual(list.items.first?.savedAt ?? .distantPast, before)
    }

    // MARK: Signed in

    func testSignedInTheMemberListIsTheSourceAndStaysInMemory() async {
        await list.save(item(.show, showId))
        signIn()
        service.savedItemsResult = .success([item(.movie, movieId, at: 5), item(.episode, episodeId, at: 4)])

        await list.load()

        XCTAssertEqual(service.savedCalls, [.init(verb: "GET", list: .watchlist, token: "tok")])
        XCTAssertEqual(list.items.map(\.itemId), [movieId, episodeId], "as served, newest first")
        XCTAssertEqual(list.isSaved(.movie, movieId), true)
        XCTAssertEqual(list.isSaved(.show, showId), false, "a device entry does not count signed in")
        XCTAssertEqual(device.items.map(\.itemId), [showId], "the member list is never written to the device")
    }

    func testSignedInASaveAndARemoveCallTheRoutesAndNeverTheDevice() async {
        signIn()
        await list.load()

        await list.save(item(.episode, episodeId))

        XCTAssertEqual(service.savedCalls.last, .init(verb: "PUT", list: .watchlist, token: "tok", ids: ["episode:\(episodeId)"]))
        XCTAssertEqual(list.items.map(\.itemId), [episodeId], "the shelf updates at once")
        XCTAssertEqual(list.isSaved(.episode, episodeId), true)
        XCTAssertTrue(device.items.isEmpty)

        await list.remove(.episode, episodeId)

        XCTAssertEqual(service.savedCalls.last, .init(verb: "DELETE", list: .watchlist, token: "tok", ids: ["episode:\(episodeId)"]))
        XCTAssertTrue(list.items.isEmpty)
        XCTAssertEqual(list.isSaved(.episode, episodeId), false)
    }

    /// A refused save (404 unknown item, 5xx) changes nothing.
    func testAFailedSaveChangesNothing() async {
        signIn()
        await list.load()
        service.saveResult = .failure(.unavailable)

        await list.save(item(.episode, episodeId))

        XCTAssertTrue(list.items.isEmpty)
        XCTAssertEqual(list.isSaved(.episode, episodeId), false)
        XCTAssertNotNil(account.session)
    }

    /// The list did not load: the state is unknown, and `check` asks `/contains` for that one item.
    func testAnUnknownStateAsksContainsOnce() async {
        signIn()
        service.savedIdsResult = .success([episodeId])

        XCTAssertNil(list.isSaved(.episode, episodeId))
        await list.check(.episode, episodeId)

        XCTAssertEqual(service.savedCalls, [.init(verb: "CONTAINS", list: .watchlist, token: "tok", ids: ["episode:\(episodeId)"])])
        XCTAssertEqual(list.isSaved(.episode, episodeId), true)

        await list.check(.episode, episodeId)
        XCTAssertEqual(service.savedCalls.count, 1, "a known state asks nothing")
    }

    /// The loaded list answers the state: no `/contains` call.
    func testALoadedListAnswersWithoutARequest() async {
        signIn()
        await list.load()

        await list.check(.show, showId)

        XCTAssertEqual(service.savedCalls.map(\.verb), ["GET"])
        XCTAssertEqual(list.isSaved(.show, showId), false)
    }

    /// Signed out, `check` asks nothing: the device list knows.
    func testSignedOutCheckSendsNothing() async {
        await list.check(.show, showId)

        XCTAssertTrue(service.savedCalls.isEmpty)
    }

    func testA401SignsOutOnThisTV() async {
        signIn()
        service.saveResult = .failure(.signedOut)

        await list.save(item(.episode, episodeId))

        XCTAssertNil(account.session)
        XCTAssertNil(sessions.stored)
        XCTAssertTrue(service.signedOutTokens.isEmpty, "no DELETE /session")
        XCTAssertTrue(device.items.isEmpty, "the save never falls back to the device")
    }

    /// A list that lands after a sign-out belongs to no one on this TV now.
    func testAnAnswerAfterSignOutIsDropped() async {
        signIn()
        service.savedItemsResult = .success([item(.episode, episodeId)])
        service.holdsSavedItems = true
        let load = Task { await list.load() }
        while !service.isHoldingSavedItems { await Task.yield() }

        await account.signOut()
        service.releaseSavedItems()
        await load.value

        XCTAssertTrue(list.items.isEmpty)
        signIn("tok-2")
        XCTAssertTrue(list.items.isEmpty, "another member does not see the first one's list")
    }

    /// A remove that ends while the list loads: the page the server read before it must not bring
    /// the item back (review fix 1).
    func testARemoveDuringALoadSurvives() async {
        signIn()
        service.savedItemsResult = .success([item(.episode, episodeId)])
        await list.load()
        service.holdsSavedItems = true
        let load = Task { await list.load() }
        while !service.isHoldingSavedItems { await Task.yield() }

        service.savedItemsResult = .success([])
        await list.remove(.episode, episodeId)
        service.releaseSavedItems()
        await load.value

        XCTAssertTrue(list.items.isEmpty, "the removed item does not come back")
        XCTAssertEqual(list.isSaved(.episode, episodeId), false)
    }

    /// A save that ends while the list loads stays on the shelf and in the toggle (review fix 1).
    func testASaveDuringALoadSurvives() async {
        signIn()
        service.holdsSavedItems = true
        let load = Task { await list.load() }
        while !service.isHoldingSavedItems { await Task.yield() }

        service.savedItemsResult = .success([item(.show, showId)])
        await list.save(item(.show, showId))
        service.releaseSavedItems()
        await load.value

        XCTAssertEqual(list.items.map(\.itemId), [showId], "the saved item stays")
        XCTAssertEqual(list.isSaved(.show, showId), true)
    }

    /// A page with a `nextCursor` is cut: an item that is not on it is unknown, so the detail
    /// toggle asks `/contains` (review fix 2). An item on it is saved.
    func testACutPageLeavesAnUnlistedItemUnknown() async {
        signIn()
        service.savedItemsResult = .success([item(.movie, movieId)])
        service.savedItemsHasMore = true
        await list.load()

        XCTAssertEqual(list.isSaved(.movie, movieId), true)
        XCTAssertNil(list.isSaved(.episode, episodeId))

        service.savedIdsResult = .success([episodeId])
        await list.check(.episode, episodeId)

        XCTAssertEqual(service.savedCalls.map(\.verb), ["GET", "CONTAINS"])
        XCTAssertEqual(list.isSaved(.episode, episodeId), true)
    }

    /// After sign-out the shelf is empty and no account item is left on the device.
    func testSignOutLeavesNoAccountItem() async {
        signIn()
        service.savedItemsResult = .success([item(.movie, movieId)])
        await list.load()
        await list.save(item(.show, showId))
        XCTAssertEqual(list.items.count, 2)

        await account.signOut()

        XCTAssertTrue(list.items.isEmpty)
        XCTAssertTrue(device.items.isEmpty)
        XCTAssertEqual(list.isSaved(.movie, movieId), false)
    }

    // MARK: The one-time import

    func testContinueImportsTheDeviceListThenClearsItThenLoads() async {
        await list.save(item(.show, showId))
        await list.save(item(.episode, episodeId))
        signIn()
        service.savedItemsResult = .success([item(.episode, episodeId), item(.show, showId)])

        await list.signInCoverClosed(continued: true)

        XCTAssertEqual(service.savedCalls.map(\.verb), ["IMPORT", "GET"])
        XCTAssertEqual(service.savedCalls.first?.ids, ["episode:\(episodeId)", "show:\(showId)"])
        XCTAssertTrue(device.items.isEmpty, "a 2xx deletes the device copy")
        XCTAssertEqual(list.items.map(\.itemId), [episodeId, showId])

        await account.signOut()
        XCTAssertTrue(list.items.isEmpty, "after sign-out the device list starts empty")
    }

    func testTheImportRunsOncePerSignIn() async {
        await list.save(item(.show, showId))
        signIn()
        service.importSavedResult = .failure(.rejected(.httpStatus(503)))

        await list.importDeviceList()
        await list.importDeviceList()

        XCTAssertEqual(service.savedCalls.map(\.verb), ["IMPORT"], "a failure is not retried")
        XCTAssertEqual(device.items.map(\.itemId), [showId], "a failure keeps the device copy")

        await account.signOut()
        signIn("tok-2")
        service.importSavedResult = .success(())
        await list.importDeviceList()

        XCTAssertEqual(service.savedCalls.map(\.token), ["tok", "tok-2"])
        XCTAssertTrue(device.items.isEmpty)
    }

    /// An entry whose id is no ObjectId would fail the whole batch (400) on every sign-in, so the
    /// device copy would never clear. It is not sent, and a 2xx drops it with the rest (fix 4).
    func testTheImportSendsOnlyObjectIdsAndClearsTheRest() async {
        device.add(item(.show, "not-an-id"))
        device.add(item(.episode, episodeId))
        signIn()

        await list.importDeviceList()

        XCTAssertEqual(service.savedCalls.first?.ids, ["episode:\(episodeId)"])
        XCTAssertTrue(device.items.isEmpty)
    }

    /// Only bad ids: no call, and they go, since no member can ever save them.
    func testOnlyBadIdsSendNothingAndAreDropped() async {
        device.add(item(.show, "not-an-id"))
        signIn()

        await list.importDeviceList()

        XCTAssertTrue(service.savedCalls.isEmpty)
        XCTAssertTrue(device.items.isEmpty)
    }

    func testAnEmptyDeviceListSendsNoImport() async {
        signIn()

        await list.importDeviceList()

        XCTAssertTrue(service.savedCalls.isEmpty)
    }

    func testA401OnTheImportSignsOutAndKeepsTheDeviceCopy() async {
        await list.save(item(.show, showId))
        signIn()
        service.importSavedResult = .failure(.signedOut)

        await list.importDeviceList()

        XCTAssertNil(account.session)
        XCTAssertEqual(device.items.map(\.itemId), [showId])
    }

    /// Back from the confirm screen imports nothing; the member list still loads.
    func testBackFromTheConfirmScreenOnlyLoads() async {
        await list.save(item(.show, showId))
        signIn()

        await list.signInCoverClosed(continued: false)

        XCTAssertEqual(service.savedCalls.map(\.verb), ["GET"])
        XCTAssertEqual(device.items.count, 1)
    }

    func testSignedOutTheCoverClosingSendsNothing() async {
        await list.save(item(.show, showId))

        await list.signInCoverClosed(continued: true)

        XCTAssertTrue(service.savedCalls.isEmpty)
    }
}

// MARK: - The routes on the wire

final class SavedListWiringTests: XCTestCase {

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

    static let listBody = Data("""
    {
      "items": [
        { "_id": "r1", "itemType": "movie", "createdAt": "2026-10-14T10:00:00.000Z",
          "movie": { "_id": "\(movieId)", "title": "The Movie", "duration": 5400,
                     "images": { "default": { "containerId": "c1", "name": "movie.jpg" } } } },
        { "_id": "r2", "itemType": "episode", "createdAt": "2026-10-13T10:00:00.000Z",
          "episode": { "_id": "\(episodeId)", "title": "Lesson 1", "image": null, "duration": 1500,
                       "show": { "_id": "\(showId)", "title": "Sabbath School", "image": { "containerId": "c1", "name": "show.jpg" } } } },
        { "_id": "r3", "itemType": "show", "createdAt": "2026-10-12T10:00:00.000Z",
          "show": { "_id": "\(showId)", "title": "Sabbath School", "image": { "containerId": "c1", "name": "show.jpg" } } },
        { "_id": "r4", "itemType": "podcast", "createdAt": "2026-10-11T10:00:00.000Z", "podcast": { "_id": "\(objectId(1))" } },
        { "_id": "r5", "itemType": "episode", "createdAt": "2026-10-10T10:00:00.000Z", "episode": { "_id": "not-an-id" } }
      ],
      "nextCursor": null
    }
    """.utf8)

    func testTheListAsksOnePageAndMapsEachType() async throws {
        StubProtocol.queue = [.init(status: 200, body: Self.listBody)]

        let page = try await client.savedItems(.watchlist, token: "tok").get()
        let items = page.items

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/watchlist?limit=100")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session"), "tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ClientToken"), "test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AWE-App-Contract"), "1")

        XCTAssertEqual(items.map(\.id), ["movie:\(movieId)", "episode:\(episodeId)", "show:\(showId)"],
                       "as served; an unknown type and a bad id are skipped")
        XCTAssertEqual(items.map(\.title), ["The Movie", "Lesson 1", "Sabbath School"])
        XCTAssertEqual(items[0].imageURL?.absoluteString.hasSuffix("/c1/movie.jpg"), true, "a movie reads `images`")
        XCTAssertEqual(items[1].imageURL?.absoluteString.hasSuffix("/c1/show.jpg"), true, "an episode with no image draws its show's")
        XCTAssertEqual(items[0].savedAt, ISO8601DateFormatter().date(from: "2026-10-14T10:00:00Z"))
    }

    /// `nextCursor` set: the page is cut, so the list knows it may miss an item (review fix 2).
    func testTheListReadsTheNextCursor() async throws {
        let cut = String(decoding: Self.listBody, as: UTF8.self)
            .replacingOccurrences(of: #""nextCursor": null"#, with: #""nextCursor": "abc""#)
        StubProtocol.queue = [.init(status: 200, body: Self.listBody), .init(status: 200, body: Data(cut.utf8))]

        let full = try await client.savedItems(.watchlist, token: "tok").get()
        let page = try await client.savedItems(.watchlist, token: "tok").get()

        XCTAssertFalse(full.hasMore)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.count, 3)
    }

    func testContainsSendsTheTypeAndTheIds() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"items":["\#(episodeId)"]}"#.utf8))]

        let ids = try await client.savedIds(.watchlist, token: "tok", itemType: .episode, ids: [episodeId, objectId(2)]).get()

        XCTAssertEqual(ids, [episodeId])
        let url = try XCTUnwrap(StubProtocol.requests.first?.url)
        XCTAssertEqual(url.path, "/v1/app/hope-tv/member/watchlist/contains")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query, [URLQueryItem(name: "itemType", value: "episode"),
                               URLQueryItem(name: "ids", value: "\(episodeId),\(objectId(2))")])
    }

    func testAPutAcceptsCreatedAndOK() async throws {
        StubProtocol.queue = [.init(status: 201), .init(status: 200)]

        try await client.save(.watchlist, token: "tok", itemType: .show, itemId: showId).get()
        try await client.save(.watchlist, token: "tok", itemType: .show, itemId: showId).get()

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/watchlist/show/\(showId)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session"), "tok")
    }

    func testADeleteAcceptsNoContent() async throws {
        StubProtocol.queue = [.init(status: 204)]

        try await client.unsave(.watchlist, token: "tok", itemType: .movie, itemId: movieId).get()

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/watchlist/movie/\(movieId)")
    }

    /// The id lands in the URL path, so only a 24-hex ObjectId is sent.
    func testAnIdThatIsNoObjectIdIsNeverSent() async {
        let result = await client.save(.watchlist, token: "tok", itemType: .show, itemId: "../session")

        guard case .failure = result else { return XCTFail("expected a failure") }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testAnUnknownItemIsA404() async {
        StubProtocol.queue = [.init(status: 404, body: Data(#"{"code":"NOT_FOUND"}"#.utf8))]

        let result = await client.save(.watchlist, token: "tok", itemType: .show, itemId: showId)

        guard case .failure(.unavailable) = result else { return XCTFail("expected a 404, got \(result)") }
    }

    func testTheImportPostsTypeIdAndSavedAt() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"imported":2,"skipped":0,"refused":[]}"#.utf8))]
        let saved = ISO8601DateFormatter().date(from: "2026-10-12T19:04:11Z")!

        try await client.importSaved(.watchlist, token: "tok", items: [
            SavedItem(itemType: .episode, itemId: episodeId, title: "Lesson 1", imageURL: nil, savedAt: saved),
        ]).get()

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/watchlist/import")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session"), "tok")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.data(of: request)) as? [String: Any])
        let entries = try XCTUnwrap(body["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(Set(entries[0].keys), ["itemType", "itemId", "savedAt"], "the title and the image stay on the device")
        XCTAssertEqual(entries[0]["itemType"] as? String, "episode")
        XCTAssertEqual(entries[0]["itemId"] as? String, episodeId)
        XCTAssertEqual(entries[0]["savedAt"] as? String, "2026-10-12T19:04:11.000Z")
    }

    /// Any 2xx is a success (the issue rule), whatever the body says.
    func testAnyImport2xxIsASuccess() async {
        StubProtocol.queue = [.init(status: 201, body: Data("{}".utf8))]

        let result = await client.importSaved(.watchlist, token: "tok", items: [item(.show, showId)])

        guard case .success = result else { return XCTFail("expected a success, got \(result)") }
    }

    func testA401IsSignedOut() async {
        StubProtocol.queue = [.init(status: 401, body: Data(#"{"code":"UNAUTHORIZED"}"#.utf8))]

        let result = await client.savedItems(.watchlist, token: "tok")

        guard case .failure(.signedOut) = result else { return XCTFail("expected signed out, got \(result)") }
    }

    private static func data(of request: URLRequest) -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return data
    }
}

// MARK: - The shelf, the card menu and the detail toggle

@MainActor
final class WatchLaterBlockTests: XCTestCase {

    private func screen(_ nodes: String, resources: String = "{}") throws -> AppScreen {
        try ContractDecoder.screen(Data("""
        { "id": "s1", "kind": "static", "blockResources": \(resources), "content": \(nodes) }
        """.utf8))
    }

    private func shelfScreen(props: String = "") throws -> AppScreen {
        try screen("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["later"] },
          "later": { "type": { "resolvedName": "MediaLibraryWatchlist" }, "props": { \(props) },
                     "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] }
        }
        """)
    }

    private func evaluate(_ screen: AppScreen, watchLater: [SavedItem] = [],
                          canOpenCard: @escaping (CardTarget) -> Bool = { _ in true }) throws -> EvaluatedNode {
        try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: RenderContext(blockResources: screen.blockResources, screenResources: screen.resources,
                                   images: ImageConfig(cdn: "https://images.test", bucket: "bucket"),
                                   watchLater: watchLater, canOpenCard: canOpenCard)
        ))
    }

    private func shelf(props: String = "", items: [SavedItem]) throws -> ShelfModel? {
        let node = try evaluate(try shelfScreen(props: props), watchLater: items)
        guard case let .shelf(model)? = node.first(where: { $0.id == "later" })?.content else { return nil }
        return model
    }

    private let saved = [item(.movie, movieId, title: "The Movie", at: 3),
                         item(.episode, episodeId, title: "Lesson 1", at: 2),
                         item(.show, showId, title: "Sabbath School", at: 1)]

    func testTheBlockKeyIsInTheRegistry() {
        XCTAssertEqual(BlockKey(resolvedName: "MediaLibraryWatchlist"), .mediaLibraryWatchlist)
        XCTAssertTrue(BlockRegistry.keys.contains("MediaLibraryWatchlist"))
    }

    func testTheShelfDrawsTheItemsInOrderWithARemoveMenu() throws {
        let model = try XCTUnwrap(try shelf(items: saved))

        XCTAssertEqual(model.layout, .row)
        XCTAssertEqual(model.cards.map(\.title), ["The Movie", "Lesson 1", "Sabbath School"])
        XCTAssertEqual(model.cards.map(\.target?.resourceType), ["movie", "episode", "show"])
        XCTAssertEqual(model.cards.map(\.target?.itemId), [movieId, episodeId, showId])
        XCTAssertEqual(model.cards.first?.imageURL, saved.first?.imageURL)
        XCTAssertEqual(model.cards.map(\.menu), saved.map { .removeFromWatchLater($0) })
    }

    /// An episode and a movie can share an id: the cards keep apart, so the shelf draws both
    /// (review fix 3).
    func testTwoTypesWithOneIdDrawTwoCards() throws {
        let model = try XCTUnwrap(try shelf(items: [item(.episode, movieId, title: "E"), item(.movie, movieId, title: "M")]))

        XCTAssertEqual(model.cards.map(\.id), ["episode:\(movieId)", "movie:\(movieId)"])
    }

    /// An empty list hides the whole block: no title, no message.
    func testAnEmptyListHidesTheBlock() throws {
        let node = try evaluate(try shelfScreen(), watchLater: [])

        let block = try XCTUnwrap(node.first { $0.id == "later" })
        XCTAssertNil(block.content)
        XCTAssertEqual(node.keyReport.null, ["MediaLibraryWatchlist"])
    }

    /// `title` names the shelf; an empty one draws "Watch later"; `showTitle: false` draws none.
    func testTheTitleProps() throws {
        XCTAssertEqual(try shelf(props: #""title": "Für später""#, items: saved)?.title, "Für später")
        XCTAssertEqual(try shelf(props: #""title": """#, items: saved)?.title, "Watch later")
        XCTAssertEqual(try shelf(items: saved)?.title, "Watch later")
        XCTAssertNil(try shelf(props: #""title": "X", "showTitle": false"#, items: saved)?.title)
        XCTAssertEqual(try shelf(props: #""title": "X", "showTitle": "false""#, items: saved)?.title, "X",
                       "only the JSON bool false hides it")
    }

    /// A manifest with no movie Template Screen: the card is there to remove, and a press opens
    /// nothing and does not crash. With one (awe#6270), the same card opens it.
    func testAMovieCardOpensItsTemplateOnlyWhenOneExists() throws {
        let movieCard = try XCTUnwrap(try shelf(items: saved)?.cards.first)

        let without = AppRouter(tree: NavigationTree(manifest: try manifest(templates: ["episode", "show"])), diagnostics: Diagnostics())
        XCTAssertNil(without.select(movieCard.target))
        XCTAssertTrue(without.state.stack.isEmpty, "opens nothing")
        XCTAssertEqual(without.diagnostics.entries.filter { $0.title == "Card press ignored" }.count, 1)

        let with = AppRouter(tree: NavigationTree(manifest: try manifest(templates: ["episode", "show", "movie"])), diagnostics: Diagnostics())
        _ = with.select(movieCard.target)
        XCTAssertEqual(with.state.stack, [StackEntry(screenId: "movie-tpl", param: movieId)])
    }

    func testAShowCardOpensTheShowTemplate() throws {
        let showCard = try XCTUnwrap(try shelf(items: saved)?.cards.last)
        let router = AppRouter(tree: NavigationTree(manifest: try manifest(templates: ["episode", "show"])), diagnostics: Diagnostics())

        _ = router.select(showCard.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "show-tpl", param: showId)])
    }

    private func manifest(templates: [String]) throws -> AppManifest {
        let rows = templates.map { #"{ "id": "\#($0)-tpl", "kind": "template", "resourceType": "\#($0)" }"# }
        return try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [{ "id": "home", "kind": "static" }, \(rows.joined(separator: ", "))],
          "preset": {}
        }
        """.utf8))
    }

    // MARK: The card menu

    /// Show and episode cards built by the list readers carry the Watch later menu, with the
    /// snapshot the device keeps: type, id, title, image.
    func testListCardsCarryTheWatchLaterMenu() throws {
        let screen = try screen("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["shows", "episodes"] },
          "shows": { "type": { "resolvedName": "ShowList" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] },
          "episodes": { "type": { "resolvedName": "EpisodesList" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] }
        }
        """, resources: """
        {
          "shows": { "resources": { "shows": { "items": [
            { "_id": "\(showId)", "title": "Sabbath School", "images": { "default": { "containerId": "c1", "name": "show.jpg" } } },
            { "_id": "no-object-id", "title": "Bad" }
          ], "count": 2 } } },
          "episodes": { "resources": { "episodes": { "items": [
            { "_id": "\(episodeId)", "title": "Lesson 1", "image": { "containerId": "c1", "name": "ep.jpg" } }
          ], "count": 1 } } }
        }
        """)
        let node = try evaluate(screen)
        guard case let .shelf(shows)? = node.first(where: { $0.id == "shows" })?.content,
              case let .shelf(episodes)? = node.first(where: { $0.id == "episodes" })?.content else {
            return XCTFail("the lists drew nothing")
        }

        guard case let .watchLater(show)? = shows.cards.first?.menu else { return XCTFail("no show menu") }
        XCTAssertEqual(show.itemType, .show)
        XCTAssertEqual(show.itemId, showId)
        XCTAssertEqual(show.title, "Sabbath School")
        XCTAssertEqual(show.imageURL?.absoluteString.hasSuffix("/c1/show.jpg"), true)
        XCTAssertNil(shows.cards.last?.menu, "an id that is no ObjectId gets no menu")

        guard case let .watchLater(episode)? = episodes.cards.first?.menu else { return XCTFail("no episode menu") }
        XCTAssertEqual(episode.itemType, .episode)
        XCTAssertEqual(episode.itemId, episodeId)
        XCTAssertEqual(episode.imageURL?.absoluteString.hasSuffix("/c1/ep.jpg"), true)
    }

    /// A "Keep watching" card is an episode card too: it offers Watch later with the entry's art.
    func testAKeepWatchingCardCarriesTheMenu() throws {
        let screen = try screen("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["history"] },
          "history": { "type": { "resolvedName": "EpisodeWatchHistory" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] }
        }
        """)
        let art = URL(string: "https://images.test/ep.jpg")
        let entries = [episodeId, "not-an-id"].map { id in
            WatchProgressStore.Entry(playableId: "https://cdn.test/\(id).m3u8", showId: nil, episodeId: id, title: "Lesson 1",
                                     subtitle: "", imageURL: art, fraction: 0.4, duration: 1500, updatedAt: Date())
        }
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(watchHistory: entries)))
        guard case let .shelf(model)? = node.first(where: { $0.id == "history" })?.content else {
            return XCTFail("EpisodeWatchHistory drew nothing")
        }

        XCTAssertEqual(model.cards.first?.menu, .watchLater(SavedItem(itemType: .episode, itemId: episodeId, title: "Lesson 1",
                                                                      imageURL: art, savedAt: .distantPast)))
        XCTAssertNil(model.cards.last?.menu, "an id that is no ObjectId gets no menu")
    }

    // MARK: The detail toggle

    func testTheEpisodeDetailCarriesTheToggleWithItsHeading() throws {
        let screen = try ContractDecoder.screen(Fixtures.data("episode"))
        let node = try evaluate(screen)
        let detail = try XCTUnwrap(node.first { $0.key == .episodeDetail })
        guard case let .episodeDetail(model)? = detail.content else { return XCTFail("EpisodeDetail drew nothing") }

        let toggle = try XCTUnwrap(model.watchLater)
        XCTAssertEqual(toggle.itemType, .episode)
        XCTAssertEqual(toggle.itemId, episodeId)
        XCTAssertFalse(toggle.title.isEmpty)
        XCTAssertNotNil(toggle.imageURL)
    }

    func testABodyOnlyEpisodeDetailDrawsNoToggle() throws {
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
        XCTAssertNil(model.watchLater)
    }

    /// The toggle is a button: it asks for the default focus, as Go to show does.
    func testTheToggleAsksForTheDefaultFocus() throws {
        let screen = try screen("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["d"] },
          "d": { "type": { "resolvedName": "ShowDetail" }, "props": {}, "custom": {}, "parent": "ROOT", "nodes": [] }
        }
        """, resources: """
        { "d": { "resources": { "showDetail": { "_id": "\(showId)", "title": "Sabbath School" } } } }
        """)
        let node = try evaluate(screen)
        guard case let .detail(model)? = node.first(where: { $0.id == "d" })?.content else { return XCTFail("ShowDetail drew nothing") }

        XCTAssertEqual(model.watchLater?.itemType, .show)
        XCTAssertEqual(model.watchLater?.itemId, showId)
        XCTAssertEqual(node.firstFocusNodeId, "d")
    }

    func testTheShowDetailCarriesTheToggleOnTheFixture() throws {
        let screen = try ContractDecoder.screen(Fixtures.data("show"))
        guard case let .detail(model)? = try evaluate(screen).first(where: { $0.key == .showDetail })?.content else {
            return XCTFail("ShowDetail drew nothing")
        }
        XCTAssertEqual(model.watchLater?.itemId, showId)
        XCTAssertFalse(model.watchLater?.title.isEmpty ?? true)
    }

    func testAShowDetailWithoutItsTitleDrawsNoToggle() throws {
        let screen = try screen("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["d"] },
          "d": { "type": { "resolvedName": "ShowDetail" }, "props": { "showTitle": false }, "custom": {}, "parent": "ROOT", "nodes": [] }
        }
        """, resources: """
        { "d": { "resources": { "showDetail": { "_id": "\(showId)", "title": "S", "body": { "type": "doc", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Body" }] }] } } } } }
        """)
        guard case let .detail(model)? = try evaluate(screen).first(where: { $0.id == "d" })?.content else {
            return XCTFail("ShowDetail drew nothing")
        }
        XCTAssertNil(model.watchLater)
    }
}

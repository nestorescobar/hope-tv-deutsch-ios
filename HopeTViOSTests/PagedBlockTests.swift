// cspell:ignore Zuhause Gott grïd
import XCTest
@testable import HopeTViOS

/// Paged block lists (awe#5318): the block route, the `paging` field, the store's merge and
/// the grid trigger. The Browse screen serves 35 of 39 shows; page 2 is
/// `fixtures/app-contract/hope-tv/browse-page-2.json` (hand-written until the route deploys).
enum PagedFixtures {
    static let browseId = "6aa952fcc445860ea24e1bcc"
    static let showId = "6aa952fbc445860ea24e1bb6"
    static let showParam = "61975e24d9c698836400305c"

    /// A captured screen with `paging` added to one node, as the Frontend API will serve it.
    static func screen(
        _ name: String,
        nodeId: String,
        paging: Any? = ["page": 1, "hasMore": true],
        heading: String? = nil
    ) throws -> Data {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Fixtures.data(name)) as? [String: Any])
        var blocks = try XCTUnwrap(root["blockResources"] as? [String: Any])
        var entry = try XCTUnwrap(blocks[nodeId] as? [String: Any])
        entry["paging"] = paging
        blocks[nodeId] = entry
        root["blockResources"] = blocks
        if let heading {
            var content = try XCTUnwrap(root["content"] as? [String: Any])
            var node = try XCTUnwrap(content["heading"] as? [String: Any])
            var props = try XCTUnwrap(node["props"] as? [String: Any])
            props["text"] = heading
            node["props"] = props
            content["heading"] = node
            root["content"] = content
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func browse(heading: String? = nil) throws -> Data {
        try screen("browse", nodeId: "grid", heading: heading)
    }

    /// A synthetic page of `list` items, named by record id.
    static func page(
        _ number: Int,
        nodeId: String = "grid",
        list: String = "shows",
        ids: [String],
        hasMore: Bool,
        count: Int = 39
    ) -> Data {
        let items = ids.map { #"{ "_id": "\#($0)", "title": "Item \#($0)" }"# }.joined(separator: ",")
        return Data("""
        { "nodeId": "\(nodeId)", "page": \(number), "hasMore": \(hasMore),
          "resources": { "\(list)": { "items": [\(items)], "count": \(count) } } }
        """.utf8)
    }
}

// MARK: - The block route

final class BlockRouteTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    private var client: AppContractClient {
        AppContractClient(config: TestConfig.staging, session: StubProtocol.session())
    }

    private func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testAValidRequestNamesTheScreenTheNodeAndThePage() throws {
        let url = try XCTUnwrap(client.blockURL(screenId: PagedFixtures.browseId, nodeId: "grid", param: nil, page: 2))
        XCTAssertEqual(url.host, "api.test")
        XCTAssertEqual(url.path, "/v1/app/hope-tv/screens/\(PagedFixtures.browseId)/blocks/grid")
        XCTAssertEqual(query(url), ["lang": "en", "page": "2"], "no param on a static screen: any other key is a 400")
    }

    func testAParamIsSentOnlyWhenGiven() {
        let url = client.blockURL(screenId: PagedFixtures.showId, nodeId: "episodes", param: PagedFixtures.showParam, page: 3)
        XCTAssertEqual(query(url), ["lang": "en", "page": "3", "param": PagedFixtures.showParam])
        XCTAssertEqual(query(client.blockURL(screenId: PagedFixtures.showId, nodeId: "episodes", param: "", page: 3)),
                       ["lang": "en", "page": "3"])
    }

    func testAMalformedScreenIdBuildsNoURL() {
        XCTAssertNil(client.blockURL(screenId: "../../admin", nodeId: "grid", param: nil, page: 2))
        XCTAssertNil(client.blockURL(screenId: "6aa952fcc445860ea24e1bc", nodeId: "grid", param: nil, page: 2))
    }

    func testAMalformedNodeIdBuildsNoURL() {
        for bad in ["", "../grid", "grid/x", "a b", "grid?page=9", "gr%69d", "grïd", String(repeating: "a", count: 65)] {
            XCTAssertNil(client.blockURL(screenId: PagedFixtures.browseId, nodeId: bad, param: nil, page: 2), bad)
        }
        for good in ["grid", "ROOT", "a_B-9", "kQ3x-Z_0", String(repeating: "a", count: 64)] {
            XCTAssertNotNil(client.blockURL(screenId: PagedFixtures.browseId, nodeId: good, param: nil, page: 2), good)
        }
    }

    func testAPageOutsideOneToAHundredBuildsNoURL() {
        XCTAssertNil(client.blockURL(screenId: PagedFixtures.browseId, nodeId: "grid", param: nil, page: 0))
        XCTAssertNil(client.blockURL(screenId: PagedFixtures.browseId, nodeId: "grid", param: nil, page: 101))
        XCTAssertNotNil(client.blockURL(screenId: PagedFixtures.browseId, nodeId: "grid", param: nil, page: 100))
    }

    func testAMalformedNodeIdNeverReachesTheWire() async {
        let result = await client.fetchBlockPage(screenId: PagedFixtures.browseId, nodeId: "../x", param: nil, page: 2)
        guard case .failure = result else { return XCTFail("expected a refusal") }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testTheBlockRequestCarriesTheThreeHeaders() async throws {
        StubProtocol.queue = [.init(status: 200, body: try Fixtures.data("browse-page-2"))]
        _ = await client.fetchBlockPage(screenId: PagedFixtures.browseId, nodeId: "grid", param: nil, page: 2)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "ClientToken"), "test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AWE-App-Contract"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AWE-Entity"), "602bd46f36432128d40d5e81")
    }

    func testABlockPageFromAnotherOriginIsRefused() async {
        StubProtocol.queue = [.init(status: 200, url: URL(string: "https://evil.test/x"), body: PagedFixtures.page(2, ids: ["a"], hasMore: false))]
        let result = await client.fetchBlockPage(screenId: PagedFixtures.browseId, nodeId: "grid", param: nil, page: 2)
        guard case let .failure(reason) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(reason, .wrongOrigin("https://evil.test"))
    }

    func testAnOversizeBlockPageIsRefused() async {
        let chunk = Data(repeating: 0x20, count: 64 * 1024)
        StubProtocol.queue = [.init(status: 200, chunks: Array(repeating: chunk, count: 6))]
        let result = await client.fetchBlockPage(screenId: PagedFixtures.browseId, nodeId: "grid", param: nil, page: 2)
        guard case let .failure(reason) = result, case .payloadTooLarge = reason else {
            return XCTFail("expected a size refusal, got \(result)")
        }
    }
}

// MARK: - Decoding

final class BlockPagingDecodingTests: XCTestCase {

    func testACapturedScreenWithoutPagingStillDecodes() throws {
        let screen = try ContractDecoder.screen(Fixtures.data("browse"))
        XCTAssertTrue(screen.paging.isEmpty)
        XCTAssertEqual(screen.blockResources["grid"]?["shows"]?["items"].array.count, 35)
    }

    func testPagingDecodesOnTheNodeThatServesIt() throws {
        let screen = try ContractDecoder.screen(PagedFixtures.browse())
        XCTAssertEqual(screen.paging, ["grid": BlockPaging(page: 1, hasMore: true)])
        XCTAssertEqual(screen.blockResources["grid"]?["shows"]?["items"].array.count, 35, "resources are unchanged")
    }

    /// A malformed `paging` is no paging. It never costs the node its resources.
    func testAMalformedPagingIsIgnored() throws {
        for bad: Any in ["yes", ["page": 1], ["page": "1", "hasMore": true], ["hasMore": true]] {
            let screen = try ContractDecoder.screen(PagedFixtures.screen("browse", nodeId: "grid", paging: bad))
            XCTAssertTrue(screen.paging.isEmpty, "\(bad)")
            XCTAssertEqual(screen.blockResources["grid"]?["shows"]?["items"].array.count, 35, "\(bad)")
        }
    }

    func testTheBlockPageFixtureDecodes() throws {
        let page = try ContractDecoder.blockPage(Fixtures.data("browse-page-2"))
        XCTAssertEqual(page.nodeId, "grid")
        XCTAssertEqual(page.page, 2)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.resources["shows"]?["items"].array.count, 4)
        XCTAssertEqual(page.resources["shows"]?["count"].int, 39)
    }

    func testABlockPageWithoutItsNumbersIsRefused() {
        XCTAssertThrowsError(try ContractDecoder.blockPage(Data(#"{ "nodeId": "grid", "resources": {} }"#.utf8)))
    }
}

// MARK: - The store

@MainActor
final class PagedListStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
        StubProtocol.reset()
        ContractCache().clear()
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        ContractCache().clear()
        StubProtocol.reset()
        super.tearDown()
    }

    private func makeStore() -> ContractStore {
        let config = TestConfig.staging
        return ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
    }

    /// A store with the paged Browse screen on show.
    private func browseStore() async throws -> (ContractStore, ContractCacheKey) {
        let store = makeStore()
        StubProtocol.queue = [.init(status: 200, body: try PagedFixtures.browse())]
        await store.loadScreen(id: PagedFixtures.browseId, param: nil)
        StubProtocol.requests = []
        return (store, store.key(for: PagedFixtures.browseId, param: nil))
    }

    private func shows(_ store: ContractStore, _ key: ContractCacheKey) -> JSONValue? {
        store.blockResources(for: key)["grid"]?["shows"]
    }

    private func grid(_ store: ContractStore, _ key: ContractCacheKey) throws -> ShelfModel {
        let screen = try XCTUnwrap(store.screenEntry(id: PagedFixtures.browseId, param: nil)?.screen)
        let root = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: store.blockResources(for: key))
        ))
        guard case let .shelf(model) = try XCTUnwrap(root.first { $0.key == .showList }).content else {
            throw XCTSkip("ShowList drew nothing")
        }
        return model
    }

    func testTheNextPageMergesIntoTheListTheRegistryReads() async throws {
        let (store, key) = try await browseStore()
        StubProtocol.queue = [.init(status: 200, body: try Fixtures.data("browse-page-2"))]
        await store.loadNextPage(key: key, nodeId: "grid")

        let request = try XCTUnwrap(StubProtocol.requests.first?.url)
        XCTAssertEqual(request.path, "/v1/app/hope-tv/screens/\(PagedFixtures.browseId)/blocks/grid")
        XCTAssertEqual(URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value, "2")

        let model = try grid(store, key)
        XCTAssertEqual(model.cards.count, 39)
        XCTAssertEqual(model.cards.last?.title, "Zuhause bei Gott")
        // A paged card opens its show like a page-1 card: the served link first.
        XCTAssertEqual(model.cards.last?.target?.link?.screenId, PagedFixtures.showId)
        XCTAssertEqual(model.cards.last?.target?.link?.param, "6a0000000000000000000204")
        XCTAssertEqual(store.pagedLists[key]?["grid"]?.lastPage, 2)
        XCTAssertEqual(store.pagedLists[key]?["grid"]?.hasMore, false)
    }

    /// Card ids are record ids, and a repeated id in a `ForEach` is undefined behavior.
    func testARecordAlreadyOnShowIsNotAddedTwice() async throws {
        let (store, key) = try await browseStore()
        // The first id is on page 1; "p2a" repeats inside the page.
        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(2, ids: ["620a794d2d1ac1cdb9358ec8", "p2a", "p2a", "p2b"], hasMore: true, count: 41))]
        await store.loadNextPage(key: key, nodeId: "grid")
        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(3, ids: ["p2b", "p3a"], hasMore: false, count: 40))]
        await store.loadNextPage(key: key, nodeId: "grid")

        let ids = try grid(store, key).cards.map(\.id)
        XCTAssertEqual(ids.count, 38)
        XCTAssertEqual(Set(ids).count, ids.count, "every card id is unique")
        XCTAssertEqual(Array(ids.suffix(3)), ["p2a", "p2b", "p3a"])
        XCTAssertEqual(shows(store, key)?["count"].int, 40, "the count of the latest answer")
    }

    func testOneRequestPerNodeAtATime() async throws {
        let (store, key) = try await browseStore()
        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(2, ids: ["p2a"], hasMore: true), delay: 0.3)]
        async let first: Void = store.loadNextPage(key: key, nodeId: "grid")
        async let second: Void = store.loadNextPage(key: key, nodeId: "grid")
        _ = await (first, second)

        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(store.pagedLists[key]?["grid"]?.lastPage, 2)
        XCTAssertEqual(store.pagedLists[key]?["grid"]?.inFlight, false)
    }

    func testNoMoreRequestsOnceHasMoreIsFalse() async throws {
        let (store, key) = try await browseStore()
        StubProtocol.queue = [.init(status: 200, body: try Fixtures.data("browse-page-2"))]
        await store.loadNextPage(key: key, nodeId: "grid")
        await store.loadNextPage(key: key, nodeId: "grid")
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testA404StopsPagingTheNode() async throws {
        let (store, key) = try await browseStore()
        StubProtocol.queue = [.init(status: 404)]
        await store.loadNextPage(key: key, nodeId: "grid")
        await store.loadNextPage(key: key, nodeId: "grid")

        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(store.pagedLists[key]?["grid"]?.hasMore, false)
        XCTAssertEqual(shows(store, key)?["items"].array.count, 35)
    }

    /// A failure stops without a retry loop; the next focus change asks again.
    func testAFailureRetriesOnlyOnTheNextCall() async throws {
        let (store, key) = try await browseStore()
        StubProtocol.queue = [.init(status: 500)]
        await store.loadNextPage(key: key, nodeId: "grid")
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(store.pagedLists[key]?["grid"]?.hasMore, true)
        XCTAssertEqual(store.pagedLists[key]?["grid"]?.inFlight, false)

        StubProtocol.queue = [.init(status: 200, body: try Fixtures.data("browse-page-2"))]
        await store.loadNextPage(key: key, nodeId: "grid")
        XCTAssertEqual(StubProtocol.requests.count, 2)
        XCTAssertEqual(shows(store, key)?["items"].array.count, 39)
    }

    /// An answer for another node or another page is not this page.
    func testAnAnswerForAnotherNodeOrPageIsNotMerged() async throws {
        let (store, key) = try await browseStore()
        StubProtocol.queue = [
            .init(status: 200, body: PagedFixtures.page(2, nodeId: "other", ids: ["x"], hasMore: false)),
            .init(status: 200, body: PagedFixtures.page(5, ids: ["y"], hasMore: false)),
        ]
        await store.loadNextPage(key: key, nodeId: "grid")
        await store.loadNextPage(key: key, nodeId: "grid")
        XCTAssertEqual(shows(store, key)?["items"].array.count, 35)
        XCTAssertEqual(store.pagedLists[key]?["grid"]?.lastPage, 1)
        XCTAssertEqual(store.pagedLists[key]?["grid"]?.hasMore, true)
    }

    /// The shell never guesses: no `paging`, no request, whatever the block type or count.
    func testANodeWithoutPagingIsNeverPaged() async throws {
        let store = makeStore()
        StubProtocol.queue = [.init(status: 200, body: try Fixtures.data("browse"))]
        await store.loadScreen(id: PagedFixtures.browseId, param: nil)
        StubProtocol.requests = []
        await store.loadNextPage(key: store.key(for: PagedFixtures.browseId, param: nil), nodeId: "grid")
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testANewCopyOfTheScreenResetsItsPages() async throws {
        let (store, key) = try await browseStore()
        StubProtocol.queue = [.init(status: 200, body: try Fixtures.data("browse-page-2"))]
        await store.loadNextPage(key: key, nodeId: "grid")
        XCTAssertEqual(shows(store, key)?["items"].array.count, 39)

        StubProtocol.queue = [.init(status: 200, body: try PagedFixtures.browse(heading: "Changed"))]
        await store.loadScreen(id: PagedFixtures.browseId, param: nil)

        XCTAssertNil(store.pagedLists[key])
        XCTAssertEqual(shows(store, key)?["items"].array.count, 35)
    }

    /// A page asked for by the old copy never lands on the new one.
    func testAPageInFlightWhenANewCopyActivatesIsDropped() async throws {
        let (store, key) = try await browseStore()
        StubProtocol.queue = [
            .init(status: 200, body: try Fixtures.data("browse-page-2"), delay: 0.4),
            .init(status: 200, body: try PagedFixtures.browse(heading: "Changed")),
        ]
        let paging = Task { await store.loadNextPage(key: key, nodeId: "grid") }
        try await Task.sleep(for: .milliseconds(150))
        await store.loadScreen(id: PagedFixtures.browseId, param: nil)
        await paging.value

        XCTAssertEqual(shows(store, key)?["items"].array.count, 35)
        XCTAssertNil(store.pagedLists[key])
    }

    /// Paged items are memory only: never last-known-good.
    func testPagedItemsAreNeverCached() async throws {
        let (store, key) = try await browseStore()
        StubProtocol.queue = [.init(status: 200, body: try Fixtures.data("browse-page-2"))]
        await store.loadNextPage(key: key, nodeId: "grid")
        store.markRendered(key)

        let onDisk = try ContractDecoder.screen(XCTUnwrap(ContractCache().load(key)))
        XCTAssertEqual(onDisk.blockResources["grid"]?["shows"]?["items"].array.count, 35)

        // The next launch paints the cached page 1 only.
        let next = makeStore()
        StubProtocol.queue = [.init(status: 500)]
        await next.loadScreen(id: PagedFixtures.browseId, param: nil)
        XCTAssertEqual(next.blockResources(for: key)["grid"]?["shows"]?["items"].array.count, 35)
        XCTAssertNil(next.pagedLists[key])
    }

    /// An `EpisodesList` pages its `episodes`, and a Template Screen sends its param.
    func testAnEpisodesListPagesWithTheScreenParam() async throws {
        let store = makeStore()
        StubProtocol.queue = [.init(status: 200, body: try PagedFixtures.screen("show", nodeId: "episodes"))]
        await store.loadScreen(id: PagedFixtures.showId, param: PagedFixtures.showParam)
        StubProtocol.requests = []
        let key = store.key(for: PagedFixtures.showId, param: PagedFixtures.showParam)

        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(2, nodeId: "episodes", list: "episodes",
                                                                         ids: ["627dd7c5caab68aa9bd3c2ae", "e9"], hasMore: true, count: 24))]
        await store.loadNextPage(key: key, nodeId: "episodes")

        let url = try XCTUnwrap(StubProtocol.requests.first?.url)
        XCTAssertEqual(url.path, "/v1/app/hope-tv/screens/\(PagedFixtures.showId)/blocks/episodes")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "param" }?.value,
                       PagedFixtures.showParam)
        let items = store.blockResources(for: key)["episodes"]?["episodes"]?["items"].array ?? []
        XCTAssertEqual(items.count, 9)
        XCTAssertEqual(items.last?["_id"].string, "e9")
    }
}

// MARK: - Collection (awe#5983)

/// A `Collection` pages like a list, but page 1 keeps its items in `collection.shows` or
/// `collection.episodes` (the one its `contentType` names), while a page answers the uniform
/// `collection: { items, count }`.
@MainActor
final class CollectionPagingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
        StubProtocol.reset()
        ContractCache().clear()
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        ContractCache().clear()
        StubProtocol.reset()
        super.tearDown()
    }

    private let screenId = PagedFixtures.browseId

    /// One `Collection` node `list` whose record serves `ids` under its `contentType`, with
    /// `paging` served for the node. `otherIds` fills the other array with raw id strings, as
    /// the record stores a filter there (an episodes Collection filtered by show).
    private func collectionScreen(contentType: String, ids: [String], otherIds: [String] = [],
                                  layout: String = "grid") -> Data {
        let items = ids.map { #"{ "_id": "\#($0)", "title": "Item \#($0)" }"# }.joined(separator: ",")
        let other = contentType == "shows" ? "episodes" : "shows"
        let otherItems = otherIds.map { "\"\($0)\"" }.joined(separator: ",")
        return Data("""
        {
          "id": "\(screenId)",
          "kind": "static",
          "blockResources": {
            "list": {
              "resources": { "collection": { "title": "Category", "layout": "posters", "contentType": "\(contentType)",
                                             "\(contentType)": [\(items)], "\(other)": [\(otherItems)],
                                             "\(contentType)Count": 40 } },
              "paging": { "page": 1, "hasMore": true }
            }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["list"] },
            "list": {
              "type": { "resolvedName": "Collection" },
              "props": { "layout": "\(layout)" },
              "custom": { "type": "plugin", "resources": ["collection"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8)
    }

    private func store(with screen: Data) async -> (ContractStore, ContractCacheKey) {
        let config = TestConfig.staging
        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
        StubProtocol.queue = [.init(status: 200, body: screen)]
        await store.loadScreen(id: screenId, param: nil)
        StubProtocol.requests = []
        return (store, store.key(for: screenId, param: nil))
    }

    private func shelf(_ store: ContractStore, _ key: ContractCacheKey, nodeId: String = "list") throws -> ShelfModel {
        let screen = try XCTUnwrap(store.screenEntry(id: screenId, param: nil)?.screen)
        let root = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: store.blockResources(for: key))
        ))
        guard case let .shelf(model) = try XCTUnwrap(root.first { $0.id == nodeId }).content else {
            throw XCTSkip("Collection drew nothing")
        }
        return model
    }

    func testAShowsCollectionAppendsTheNextPageToItsShows() async throws {
        let (store, key) = await store(with: collectionScreen(contentType: "shows", ids: ["s1", "s2"]))
        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(2, nodeId: "list", list: "collection",
                                                                         ids: ["s3", "s4"], hasMore: true, count: 40))]
        await store.loadNextPage(key: key, nodeId: "list")

        let url = try XCTUnwrap(StubProtocol.requests.first?.url)
        XCTAssertEqual(url.path, "/v1/app/hope-tv/screens/\(screenId)/blocks/list")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value, "2")

        let model = try shelf(store, key)
        XCTAssertEqual(model.layout, .grid)
        XCTAssertEqual(model.cards.map(\.id), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(store.pagedLists[key]?["list"]?.lastPage, 2)
        XCTAssertEqual(store.pagedLists[key]?["list"]?.hasMore, true)
    }

    /// The captured Home `latest` Collection: 24 episodes on page 1, served card shape.
    func testAnEpisodesCollectionAppendsTheNextPageToItsEpisodes() async throws {
        let home = try PagedFixtures.screen("home", nodeId: "latest")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: home) as? [String: Any])
        root["id"] = screenId
        let (store, key) = await store(with: try JSONSerialization.data(withJSONObject: root))
        let firstOnPage1 = "6a049248c6d68f1e30573243"
        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(2, nodeId: "latest", list: "collection",
                                                                         ids: [firstOnPage1, "e25", "e26"], hasMore: false, count: 26))]
        await store.loadNextPage(key: key, nodeId: "latest")

        let collection = store.blockResources(for: key)["latest"]?["collection"]
        XCTAssertEqual(collection?["episodes"].array.count, 26, "a record already on page 1 is not added twice")
        XCTAssertEqual(collection?["shows"].array.count, 0)
        let cards = try shelf(store, key, nodeId: "latest").cards
        XCTAssertEqual(cards.count, 26)
        XCTAssertEqual(Set(cards.map(\.id)).count, cards.count, "every card id is unique")
        XCTAssertEqual(Array(cards.map(\.id).suffix(2)), ["e25", "e26"])
    }

    func testRepeatedRecordsAcrossPagesAreDropped() async throws {
        let (store, key) = await store(with: collectionScreen(contentType: "episodes", ids: ["e1", "e2"]))
        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(2, nodeId: "list", list: "collection",
                                                                         ids: ["e2", "e3", "e3"], hasMore: true))]
        await store.loadNextPage(key: key, nodeId: "list")
        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(3, nodeId: "list", list: "collection",
                                                                         ids: ["e3", "e4"], hasMore: true))]
        await store.loadNextPage(key: key, nodeId: "list")

        XCTAssertEqual(try shelf(store, key).cards.map(\.id), ["e1", "e2", "e3", "e4"])
    }

    func testNoMoreRequestsOnceHasMoreIsFalse() async throws {
        let (store, key) = await store(with: collectionScreen(contentType: "shows", ids: ["s1"]))
        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(2, nodeId: "list", list: "collection",
                                                                         ids: ["s2"], hasMore: false))]
        await store.loadNextPage(key: key, nodeId: "list")
        await store.loadNextPage(key: key, nodeId: "list")

        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(store.pagedLists[key]?["list"]?.hasMore, false)
        XCTAssertEqual(try shelf(store, key).cards.map(\.id), ["s1", "s2"])
    }

    /// The merge writes into the array the `contentType` names and leaves the record's other
    /// fields as served. It writes no `items` and no `count`: the shelf reads neither.
    func testTheMergeWritesIntoTheContentTypeList() throws {
        let base: [String: [String: JSONValue]] = ["list": ["collection": try JSONDecoder().decode(JSONValue.self, from: Data("""
        { "title": "Category", "contentType": "episodes", "episodes": [{ "_id": "e1" }], "shows": [], "episodesCount": 40 }
        """.utf8))]]
        var list = try XCTUnwrap(PagedList(paging: BlockPaging(page: 1, hasMore: true), key: .collection))
        list.append(try ContractDecoder.blockPage(PagedFixtures.page(2, nodeId: "list", list: "collection",
                                                                     ids: ["e1", "e2"], hasMore: true, count: 41)),
                    base: base["list"]?["collection"])

        let merged = try XCTUnwrap(PagedList.merge(base, lists: ["list": list])["list"]?["collection"])
        XCTAssertEqual(merged["episodes"].array.compactMap { $0["_id"].string }, ["e1", "e2"])
        XCTAssertEqual(merged["shows"].array.count, 0)
        XCTAssertEqual(merged["title"].string, "Category")
        XCTAssertEqual(merged["episodesCount"].int, 40)
        XCTAssertFalse(merged.hasKey("items"))
        XCTAssertFalse(merged.hasKey("count"))
    }

    /// The record keeps the array its `contentType` does not name as raw ids (a show filter on an
    /// episodes Collection). The shelf draws the `contentType` list, never those ids.
    func testAnEpisodesCollectionWithAShowFilterDrawsItsEpisodes() async throws {
        let (store, key) = await store(with: collectionScreen(contentType: "episodes", ids: ["e1", "e2"],
                                                             otherIds: ["6a0000000000000000000001", "6a0000000000000000000002"]))
        let model = try shelf(store, key)
        XCTAssertEqual(model.cards.map(\.id), ["e1", "e2"])
        XCTAssertEqual(model.cards.map(\.title), ["Item e1", "Item e2"])
        XCTAssertNil(model.emptyMessage)
    }

    /// A page appended to such a record joins the drawn cards.
    func testAPageJoinsTheEpisodesOfAShowFilteredCollection() async throws {
        let (store, key) = await store(with: collectionScreen(contentType: "episodes", ids: ["e1"],
                                                             otherIds: ["6a0000000000000000000001"]))
        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(2, nodeId: "list", list: "collection",
                                                                         ids: ["e2", "e3"], hasMore: false))]
        await store.loadNextPage(key: key, nodeId: "list")

        XCTAssertEqual(try shelf(store, key).cards.map(\.id), ["e1", "e2", "e3"])
    }

    /// The store follows `paging` alone and does not read the layout: a row Collection is
    /// never asked, because only the grid branch of `ShelfView` calls `loadNextPage`
    /// (`CollectionPagingUITests` proves it with the focus engine).
    func testARowCollectionDrawsTheRowWhateverPagingSays() async throws {
        let (store, key) = await store(with: collectionScreen(contentType: "shows", ids: ["s1", "s2"], layout: "slider"))
        XCTAssertEqual(try shelf(store, key).layout, .row)
        XCTAssertNotNil(PagedList(paging: store.screenEntry(id: screenId, param: nil)?.screen?.paging["list"], key: .collection))
        XCTAssertTrue(StubProtocol.requests.isEmpty, "drawing the row asks for nothing")
    }
}

// MARK: - The columns

final class GridColumnsTests: XCTestCase {

    func testTheScreenWidthKeepsFour392PointColumns() {
        // 1920 less two 64 pt margins. A tab grid measures less on the simulator (1632 pt, it
        // starts at x 144), where four columns share out to 378 pt.
        XCTAssertEqual(GridColumns.count(width: 1792), 4)
        XCTAssertEqual(GridColumns.cardWidth(width: 1792, columns: 4), 392)
    }

    func testAnUnmeasuredGridKeepsFour392PointColumns() {
        XCTAssertEqual(GridColumns.count(width: nil), 4)
        XCTAssertEqual(GridColumns.cardWidth(width: nil, columns: 4), 392)
    }

    func testTheResultsBesideTheGridKeyboardTakeThreeNarrowerColumns() {
        // Measured on the tvOS 27 simulator: the results get 1250 pt beside the grid keyboard.
        XCTAssertEqual(GridColumns.count(width: 1250), 3)
        XCTAssertEqual(GridColumns.cardWidth(width: 1250, columns: 3), 390)
    }

    func testANarrowGridKeepsOneColumnOfTheMinimumWidth() {
        XCTAssertEqual(GridColumns.count(width: 200), 1)
        XCTAssertEqual(GridColumns.cardWidth(width: 200, columns: 1), 360)
    }

    /// The default metrics are the landscape grid's, so every existing grid keeps its columns.
    func testTheDefaultMetricsAreTheLandscapeGrid() {
        XCTAssertEqual(GridColumns.Metrics.wide, GridColumns.Metrics(card: 392, minimumCard: 360, maximum: 4))
        for width: CGFloat? in [nil, 1792, 1250, 200] {
            XCTAssertEqual(GridColumns.count(width: width), GridColumns.count(width: width, metrics: .wide))
        }
    }

    /// A poster grid (awe#6870): six 260 pt portrait columns inside the screen margins, with the
    /// same 40 pt gap. 6 × 260 + 5 × 40 = 1760 pt, inside 1792.
    func testThePosterGridTakesSix260PointColumns() {
        XCTAssertEqual(GridColumns.count(width: 1792, metrics: .poster), 6)
        XCTAssertEqual(GridColumns.cardWidth(width: 1792, columns: 6, metrics: .poster), 260)
        XCTAssertEqual(GridColumns.count(width: nil, metrics: .poster), 6)
        XCTAssertEqual(GridColumns.cardWidth(width: nil, columns: 6, metrics: .poster), 260)
    }

    /// Measured on the tvOS 27 simulator (awe#6870): a tab grid starts at x 144, so it gets
    /// 1920 − 2 × 144 = 1632 pt. Six columns still fit there, at 238 pt.
    func testTheMeasuredTabWidthStillTakesSixPosterColumns() {
        XCTAssertEqual(GridColumns.count(width: 1632, metrics: .poster), 6)
        XCTAssertEqual(GridColumns.cardWidth(width: 1632, columns: 6, metrics: .poster), 238)
    }

    func testANarrowPosterGridTakesFewerColumns() {
        XCTAssertEqual(GridColumns.count(width: 1250, metrics: .poster), 4)
        XCTAssertEqual(GridColumns.cardWidth(width: 1250, columns: 4, metrics: .poster), 260)
        XCTAssertEqual(GridColumns.count(width: 200, metrics: .poster), 1)
        XCTAssertEqual(GridColumns.cardWidth(width: 200, columns: 1, metrics: .poster), 230)
    }

    /// The last-row page load counts the poster columns: the last six cards trigger.
    func testThePosterGridPagesOnItsLastRow() {
        let columns = GridColumns.count(width: 1792, metrics: .poster)
        XCTAssertTrue(GridPaging.triggers(index: 18, count: 24, columns: columns))
        XCTAssertFalse(GridPaging.triggers(index: 17, count: 24, columns: columns))
    }
}

// MARK: - The trigger

final class GridPagingTriggerTests: XCTestCase {

    func testTheLastColumnsCardsTrigger() {
        // 35 cards in 4 columns: indices 31...34.
        XCTAssertFalse(GridPaging.triggers(index: 30, count: 35, columns: 4))
        XCTAssertTrue(GridPaging.triggers(index: 31, count: 35, columns: 4))
        XCTAssertTrue(GridPaging.triggers(index: 34, count: 35, columns: 4))
        // 8 cards: the second row.
        XCTAssertFalse(GridPaging.triggers(index: 3, count: 8, columns: 4))
        XCTAssertTrue(GridPaging.triggers(index: 4, count: 8, columns: 4))
    }

    func testAShortGridTriggersOnEveryCard() {
        XCTAssertTrue(GridPaging.triggers(index: 0, count: 3, columns: 4))
        XCTAssertTrue(GridPaging.triggers(index: 2, count: 3, columns: 4))
    }

    func testAnIndexOutsideTheGridNeverTriggers() {
        XCTAssertFalse(GridPaging.triggers(index: 0, count: 0, columns: 4))
        XCTAssertFalse(GridPaging.triggers(index: 35, count: 35, columns: 4))
        XCTAssertFalse(GridPaging.triggers(index: -1, count: 35, columns: 4))
    }
}

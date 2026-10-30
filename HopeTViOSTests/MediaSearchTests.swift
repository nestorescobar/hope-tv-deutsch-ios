// cspell:ignore Bibel bibel bibelkompass kompass grïd
import XCTest
@testable import HopeTViOS

/// The `MediaSearch` block (awe#5947): the fourth route, the answer read into cards, the card
/// press, and the field's debounce.
enum SearchFixtures {
    static let screenId = "6aa952fcc445860ea24e1bcc"
    static let nodeId = "search"

    /// A `{ episodes, shows }` answer built from captured list items: the Show screen's
    /// `EpisodesList` items and the Browse `ShowList` items. Both carry served `screenLink`s.
    static func answer(episodes: Int = 3, shows: Int = 2) throws -> Data {
        let show = try XCTUnwrap(try JSONSerialization.jsonObject(with: Fixtures.data("show")) as? [String: Any])
        let browse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Fixtures.data("browse")) as? [String: Any])
        let episodeItems = try items(show, node: "episodes", list: "episodes")
        let showItems = try items(browse, node: "grid", list: "shows")
        return try JSONSerialization.data(withJSONObject: [
            "episodes": Array(episodeItems.prefix(episodes)),
            "shows": Array(showItems.prefix(shows)),
        ])
    }

    private static func items(_ screen: [String: Any], node: String, list: String) throws -> [Any] {
        let blocks = try XCTUnwrap(screen["blockResources"] as? [String: Any])
        let entry = try XCTUnwrap(blocks[node] as? [String: Any])
        let resources = try XCTUnwrap(entry["resources"] as? [String: Any])
        let listValue = try XCTUnwrap(resources[list] as? [String: Any])
        return try XCTUnwrap(listValue["items"] as? [Any])
    }
}

// MARK: - The registry

final class MediaSearchRegistryTests: XCTestCase {

    private func evaluate() throws -> EvaluatedNode {
        let document = try TestDocument.make("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["search"] },
          "search": {
            "type": { "resolvedName": "MediaSearch" },
            "props": { "episodeScreenId": "6ab3c22ade87f6e74b7dc8f7", "showScreenId": "6aa952fbc445860ea24e1bb6" },
            "parent": "ROOT", "nodes": []
          }
        }
        """)
        return try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: document, context: TestRender.context()))
    }

    func testMediaSearchIsARegistryKey() {
        XCTAssertTrue(BlockKey(resolvedName: "MediaSearch").isSupported)
        XCTAssertTrue(BlockRegistry.keys.contains("MediaSearch"))
    }

    func testTheBlockDrawsTheSearchForItsNode() throws {
        let block = try XCTUnwrap(try evaluate().first { $0.key == .mediaSearch })
        XCTAssertEqual(block.content, .mediaSearch(MediaSearchModel(nodeId: "search")))
    }

    /// The field takes focus, but the view cannot ask for it: tvOS chooses the field, the top
    /// focusable of the screen.
    func testTheSearchFieldTakesFocusButDoesNotAskForIt() throws {
        let root = try evaluate()
        XCTAssertEqual(root.firstFocusStop, .readsOnly)
        XCTAssertNil(root.firstFocusNodeId)
    }
}

// MARK: - The route

final class SearchRouteTests: XCTestCase {

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

    func testAValidRequestNamesTheScreenTheNodeAndTheQuery() throws {
        let url = try XCTUnwrap(client.searchURL(screenId: SearchFixtures.screenId, nodeId: "search", query: "Bibel"))
        XCTAssertEqual(url.host, "api.test")
        XCTAssertEqual(url.path, "/v1/app/hope-tv/screens/\(SearchFixtures.screenId)/blocks/search/search")
        XCTAssertEqual(query(url), ["lang": "en", "q": "Bibel"], "only q and lang: any other key is a 400")
    }

    func testTheQueryIsSentTrimmed() {
        XCTAssertEqual(query(client.searchURL(screenId: SearchFixtures.screenId, nodeId: "search", query: "  Bibel kompass \n"))["q"],
                       "Bibel kompass")
    }

    func testAQueryOfTwoToAHundredCharactersAfterTrimmingIsSent() {
        let client = client
        let build = { (q: String) in client.searchURL(screenId: SearchFixtures.screenId, nodeId: "search", query: q) }
        XCTAssertNil(build(""))
        XCTAssertNil(build("a"))
        XCTAssertNil(build("  a  "), "one character after trimming")
        XCTAssertNil(build("     "))
        XCTAssertNotNil(build("ab"))
        XCTAssertNotNil(build(String(repeating: "a", count: 100)))
        XCTAssertNil(build(String(repeating: "a", count: 101)))
        // The server counts UTF-16 units (Joi), so an emoji pair is two.
        XCTAssertNotNil(build("😀"))
    }

    /// `+`, `&` and `=` are text in a query, not syntax: the server must read them back.
    func testQuerySyntaxCharactersAreEncoded() throws {
        let url = try XCTUnwrap(client.searchURL(screenId: SearchFixtures.screenId, nodeId: "search", query: "C++ & a=b"))
        let raw = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertTrue(raw.contains("q=C%2B%2B%20%26%20a%3Db"), raw)
        XCTAssertEqual(query(url)["q"], "C++ & a=b")
    }

    func testAMalformedScreenIdOrNodeIdBuildsNoURL() {
        XCTAssertNil(client.searchURL(screenId: "../../admin", nodeId: "search", query: "Bibel"))
        XCTAssertNil(client.searchURL(screenId: "6aa952fcc445860ea24e1bc", nodeId: "search", query: "Bibel"))
        for bad in ["", "../x", "a/b", "a b", "x?q=y", "grïd", String(repeating: "a", count: 65)] {
            XCTAssertNil(client.searchURL(screenId: SearchFixtures.screenId, nodeId: bad, query: "Bibel"), bad)
        }
    }

    func testABadInputNeverReachesTheWire() async {
        let result = await client.fetchSearch(screenId: SearchFixtures.screenId, nodeId: "search", query: "a")
        guard case .failure = result else { return XCTFail("expected a refusal") }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testTheSearchRequestCarriesTheThreeHeaders() async throws {
        StubProtocol.queue = [.init(status: 200, body: try SearchFixtures.answer())]
        let result = await client.fetchSearch(screenId: SearchFixtures.screenId, nodeId: "search", query: "Bibel")
        guard case .success = result else { return XCTFail("expected the answer, got \(result)") }
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/app/hope-tv/screens/\(SearchFixtures.screenId)/blocks/search/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ClientToken"), "test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AWE-App-Contract"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AWE-Entity"), "602bd46f36432128d40d5e81")
    }

    func testAnAnswerFromAnotherOriginIsRefused() async throws {
        StubProtocol.queue = [.init(status: 200, url: URL(string: "https://evil.test/x"), body: try SearchFixtures.answer())]
        let result = await client.fetchSearch(screenId: SearchFixtures.screenId, nodeId: "search", query: "Bibel")
        guard case let .failure(reason) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(reason, .wrongOrigin("https://evil.test"))
    }

    func testAnOversizeAnswerIsRefused() async {
        let chunk = Data(repeating: 0x20, count: 64 * 1024)
        StubProtocol.queue = [.init(status: 200, chunks: Array(repeating: chunk, count: 6))]
        let result = await client.fetchSearch(screenId: SearchFixtures.screenId, nodeId: "search", query: "Bibel")
        guard case let .failure(reason) = result, case .payloadTooLarge = reason else {
            return XCTFail("expected a size refusal, got \(result)")
        }
    }

    /// The whole path on the wire: a 404 (search off, or the block is gone) draws "unavailable".
    func testA404OnTheWireReadsAsUnavailable() async {
        StubProtocol.queue = [.init(status: 404, body: Data(#"{"code":"searchUnavailable"}"#.utf8))]
        let result = await client.fetchSearch(screenId: SearchFixtures.screenId, nodeId: "search", query: "Bibel")
        XCTAssertEqual(MediaSearchState(result, nodeId: "search", context: TestRender.context()), .unavailable)
    }
}

// MARK: - The answer

final class SearchAnswerTests: XCTestCase {

    private func results(_ data: Data) throws -> MediaSearchResults {
        guard case let .results(results) = MediaSearchState(.success(data), nodeId: "search", context: TestRender.context()) else {
            throw XCTSkip("the answer drew no results")
        }
        return results
    }

    func testTheAnswerReadsIntoTheListCards() throws {
        let results = try results(SearchFixtures.answer(episodes: 3, shows: 2))

        let episodes = try XCTUnwrap(results.episodes)
        XCTAssertEqual(episodes.title, "Episodes")
        XCTAssertEqual(episodes.layout, .grid)
        XCTAssertEqual(episodes.cards.count, 3)
        XCTAssertEqual(episodes.cards.first?.title, "Testimonials from the 2021 COH")
        XCTAssertEqual(episodes.cards.first?.subtitle, "Celebration of Hope · 2m", "results mix shows: the show, then the duration")
        XCTAssertEqual(episodes.cards.first?.target?.resourceType, "episode")
        XCTAssertEqual(episodes.cards.first?.target?.itemId, "627dd7c5caab68aa9bd3c2ae")
        XCTAssertNotNil(episodes.cards.first?.imageURL)

        let shows = try XCTUnwrap(results.shows)
        XCTAssertEqual(shows.title, "Shows")
        XCTAssertEqual(shows.layout, .grid)
        XCTAssertEqual(shows.cards.map(\.title).first, "_Test Show")
        XCTAssertEqual(shows.cards.first?.target?.resourceType, "show")
        XCTAssertEqual(shows.cards.first?.target?.itemId, "620a794d2d1ac1cdb9358ec8")
        XCTAssertEqual(shows.cards.first?.style, .cards)
    }

    func testAGroupWithNoItemsDrawsNoGrid() throws {
        let results = try results(SearchFixtures.answer(episodes: 0, shows: 2))
        XCTAssertNil(results.episodes)
        XCTAssertEqual(results.shows?.cards.count, 2)
    }

    func testNoItemsInEitherGroupIsNoResults() {
        let state = MediaSearchState(.success(Data(#"{ "episodes": [], "shows": [] }"#.utf8)), nodeId: "search", context: TestRender.context())
        XCTAssertEqual(state, .noResults)
        XCTAssertEqual(MediaSearchState(.success(Data("{}".utf8)), nodeId: "search", context: TestRender.context()), .noResults,
                       "a missing group reads as empty")
    }

    /// Card ids are record ids and key the grid. A record served twice draws once.
    func testARecordServedTwiceDrawsOnce() throws {
        let body = #"{ "episodes": [], "shows": [{ "_id": "a1", "title": "One" }, { "_id": "a1", "title": "One again" }, { "_id": "b2", "title": "Two" }] }"#
        let results = try results(Data(body.utf8))
        XCTAssertEqual(results.shows?.cards.map(\.title), ["One", "Two"])
    }

    func testAnUnknownFieldIsCarriedAndAnUnknownGroupIgnored() throws {
        let body = #"{ "episodes": [{ "_id": "e1", "title": "Ep", "_formatted": { "title": "<em>Ep</em>" } }], "articles": [{ "_id": "x" }] }"#
        let results = try results(Data(body.utf8))
        XCTAssertEqual(results.episodes?.cards.map(\.title), ["Ep"])
        XCTAssertNil(results.shows)
    }

    func testFailuresMapToTheirMessages() {
        let context = TestRender.context()
        XCTAssertEqual(MediaSearchState(.failure(.httpStatus(404)), nodeId: "search", context: context), .unavailable)
        XCTAssertEqual(MediaSearchState(.failure(.httpStatus(400)), nodeId: "search", context: context), .idle,
                       "a refused query draws what a short one draws: nothing")
        XCTAssertEqual(MediaSearchState(.failure(.httpStatus(500)), nodeId: "search", context: context), .failed)
        XCTAssertEqual(MediaSearchState(.failure(.transport("offline")), nodeId: "search", context: context), .failed)
        XCTAssertEqual(MediaSearchState(.success(Data("not json".utf8)), nodeId: "search", context: context), .failed)
        XCTAssertEqual(MediaSearchState(.success(Data("[]".utf8)), nodeId: "search", context: context), .failed)
    }

    func testTheMessagesAreChromeText() {
        XCTAssertEqual(MediaSearchState.noResults.message, ChromeText.string(.searchNoResults))
        XCTAssertEqual(MediaSearchState.unavailable.message, ChromeText.string(.searchUnavailable))
        XCTAssertEqual(MediaSearchState.failed.message, ChromeText.string(.contentUnavailable))
        XCTAssertNil(MediaSearchState.idle.message)
    }
}

// MARK: - Collection tiles (awe#5956)

/// The `collectionTiles` block resource: editor-picked Collections drawn under the field while it
/// is empty. Read from a decoded Screen, so the path from the wire to the model is covered.
@MainActor
final class MediaSearchTilesTests: XCTestCase {

    /// A stored File Manager image object, as the `Image` block stores it.
    private static let image = #"{ "name": "Bibel 1.jpg", "containerId": "602bd46f36432128d40d5e81", "width": 1920, "height": 1080, "blurhash": "LEHV6nWB2yk8" }"#

    private func link(_ screen: String, _ param: String) -> String {
        #", "screenLink": { "linkType": "screen", "screen": "\#(screen)", "screenParam": "\#(param)" }"#
    }

    /// `resource` is the `collectionTiles` value; nil serves no resource for the node.
    private func model(_ resource: String?) throws -> MediaSearchModel {
        let resources = resource.map { #""blockResources": { "search": { "resources": { "collectionTiles": \#($0) } } },"# } ?? ""
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "\(SearchFixtures.screenId)",
          "kind": "static",
          \(resources)
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["search"] },
            "search": { "type": { "resolvedName": "MediaSearch" }, "props": {}, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        let root = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources)
        ))
        guard case let .mediaSearch(model)? = root.first(where: { $0.key == .mediaSearch })?.content else {
            throw XCTSkip("the block drew no search")
        }
        return model
    }

    func testTilesReadIntoCollectionCardsInServedOrder() throws {
        let model = try model("""
        { "items": [
          { "_id": "c1", "title": "Bibel", "image": \(Self.image)\(link("picked", "c1")) },
          { "_id": "c2", "title": "Gesundheit", "image": \(Self.image) }
        ] }
        """)

        XCTAssertEqual(model.nodeId, "search")
        XCTAssertEqual(model.tiles.map(\.title), ["Bibel", "Gesundheit"])
        XCTAssertEqual(model.tiles.map(\.id), ["c1", "c2"])
        XCTAssertEqual(model.tiles.map { $0.target?.resourceType }, ["collection", "collection"])
        XCTAssertEqual(model.tiles.map { $0.target?.itemId }, ["c1", "c2"])
        XCTAssertEqual(model.tiles.first?.target?.link, ScreenLink(try TestDocument.value(
            #"{ "linkType": "screen", "screen": "picked", "screenParam": "c1" }"#)))
        XCTAssertNil(model.tiles.last?.target?.link, "no Collection Screen picked: no link, so the convention applies")
        XCTAssertNil(model.tiles.first?.subtitle)
        XCTAssertEqual(model.tiles.first?.style, .cards, "the 392 pt landscape card (D6)")
        XCTAssertEqual(model.tiles.first?.blurhash, "LEHV6nWB2yk8")
    }

    /// The tile image is the stored File Manager object: its URL is the one the `Image` block
    /// builds from the same object (shell `IMAGES_CDN` and `IMAGES_BUCKET`, ADR-0138).
    func testTheTileImageURLIsTheImageBlockURL() throws {
        let model = try model(#"{ "items": [{ "_id": "c1", "title": "Bibel", "image": \#(Self.image) }] }"#)
        let file = try XCTUnwrap(ImageFile(try TestDocument.value(Self.image)))
        let url = try XCTUnwrap(model.tiles.first?.imageURL)
        XCTAssertEqual(url, TestRender.context().images.url(file, width: 640))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://images.test/resize/"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.hasSuffix("/w:640/bucket/602bd46f36432128d40d5e81/Bibel%201.jpg"), url.absoluteString)
    }

    func testATileWithNoUsableImageDrawsWithoutOne() throws {
        let model = try model(#"{ "items": [{ "_id": "c1", "title": "Bibel" }, { "_id": "c2", "title": "Two", "image": { "name": "x.jpg" } }] }"#)
        XCTAssertEqual(model.tiles.count, 2)
        XCTAssertNil(model.tiles[0].imageURL)
        XCTAssertNil(model.tiles[1].imageURL, "an object without containerId is not a stored file")
    }

    func testAMissingOrEmptyResourceDrawsNoTiles() throws {
        XCTAssertEqual(try model(nil).tiles, [])
        XCTAssertEqual(try model("null").tiles, [])
        XCTAssertEqual(try model("{}").tiles, [])
        XCTAssertEqual(try model(#"{ "items": [] }"#).tiles, [])
    }

    /// Card ids key the grid, so a Collection served twice draws once.
    func testACollectionServedTwiceDrawsOnce() throws {
        let model = try model(#"{ "items": [{ "_id": "c1", "title": "One" }, { "_id": "c1", "title": "Again" }, { "_id": "c2", "title": "Two" }] }"#)
        XCTAssertEqual(model.tiles.map(\.title), ["One", "Two"])
    }

    func testATileWithNoIdOpensNothing() throws {
        let model = try model(#"{ "items": [{ "title": "Orphan" }] }"#)
        XCTAssertEqual(model.tiles.map(\.title), ["Orphan"])
        XCTAssertNil(model.tiles.first?.target)
    }

    // MARK: The empty field

    func testTheTilesShowOnlyForAnEmptyField() throws {
        let model = try model(#"{ "items": [{ "_id": "c1", "title": "Bibel" }, { "_id": "c2", "title": "Two" }] }"#)

        let grid = try XCTUnwrap(model.tileGrid(for: ""))
        XCTAssertEqual(grid.title, ChromeText.string(.categoriesLabel), "the heading reuses tvCategoriesLabel (D8)")
        XCTAssertEqual(grid.title, "Categories")
        XCTAssertEqual(grid.layout, .grid)
        XCTAssertEqual(grid.cardStyle, .cards)
        XCTAssertEqual(grid.cards, model.tiles)
        XCTAssertNil(grid.emptyMessage)
        XCTAssertNotEqual(grid.nodeId, "search", "the grid keys its own focus, apart from the result grids")

        XCTAssertNotNil(model.tileGrid(for: "  \n"), "only whitespace trims to an empty field")
        XCTAssertNil(model.tileGrid(for: "a"), "one character shows neither tiles nor results (D7)")
        XCTAssertNil(model.tileGrid(for: " a "))
        XCTAssertNil(model.tileGrid(for: "Bibel"))
    }

    func testNoTilesDrawsNothingUnderTheField() throws {
        XCTAssertNil(try model(nil).tileGrid(for: ""))
        XCTAssertNil(try model(#"{ "items": [] }"#).tileGrid(for: ""))
    }

    /// The field takes focus first, as before: the tiles do not ask for the default focus.
    func testTilesDoNotChangeTheFocusRole() throws {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s", "kind": "static",
          "blockResources": { "search": { "resources": { "collectionTiles": { "items": [{ "_id": "c1", "title": "Bibel" }] } } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["search"] },
            "search": { "type": { "resolvedName": "MediaSearch" }, "props": {}, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        let root = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: screen.blockResources)))
        XCTAssertEqual(root.firstFocusStop, .readsOnly)
    }

    // MARK: The tile press

    /// "collection-tpl" and "picked" both declare `collection`.
    private func router() throws -> AppRouter {
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [
            { "id": "home", "kind": "static" },
            { "id": "collection-tpl", "kind": "template", "resourceType": "collection" },
            { "id": "picked", "kind": "template", "resourceType": "collection" }
          ],
          "preset": {}
        }
        """.utf8))
        return AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
    }

    func testAServedLinkOpensThePickedCollectionScreen() throws {
        let model = try model(#"{ "items": [{ "_id": "c1", "title": "Bibel"\#(link("picked", "c1")) }] }"#)
        let router = try router()

        router.openCard(model.tiles.first?.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "picked", param: "c1")])
    }

    func testNoLinkOpensTheOneCollectionTemplateByTheConvention() throws {
        let model = try model(#"{ "items": [{ "_id": "c1", "title": "Bibel" }] }"#)
        // Exactly one template declares `collection`, as the staging App will.
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1, "app": { "design": "tv" }, "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [{ "id": "home", "kind": "static" }, { "id": "collection-tpl", "kind": "template", "resourceType": "collection" }],
          "preset": {}
        }
        """.utf8))
        let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())

        router.openCard(model.tiles.first?.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "collection-tpl", param: "c1")])
    }

    func testNoLinkAndSeveralCollectionTemplatesOpensNothing() throws {
        let model = try model(#"{ "items": [{ "_id": "c1", "title": "Bibel" }] }"#)
        let router = try router()

        router.openCard(model.tiles.first?.target)

        XCTAssertTrue(router.state.stack.isEmpty, "two collection templates: the convention never guesses")
    }
}

// MARK: - The card press

/// A search card opens like a list card: the served `screenLink` first, else the convention.
/// The cards come from the same reader the view uses, never a hand-built target.
@MainActor
final class SearchCardRoutingTests: XCTestCase {

    private func router() throws -> AppRouter {
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [
            { "id": "home", "kind": "static" },
            { "id": "show-tpl", "kind": "template", "resourceType": "show" },
            { "id": "episode-tpl", "kind": "template", "resourceType": "episode" },
            { "id": "picked-show", "kind": "template", "resourceType": "other" },
            { "id": "picked-episode", "kind": "template", "resourceType": "other" }
          ],
          "preset": {}
        }
        """.utf8))
        return AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
    }

    private func results(_ body: String) throws -> MediaSearchResults {
        guard case let .results(results) = MediaSearchState(.success(Data(body.utf8)), nodeId: "search", context: TestRender.context()) else {
            throw XCTSkip("the answer drew no results")
        }
        return results
    }

    private func link(_ screen: String, _ param: String) -> String {
        #", "screenLink": { "linkType": "screen", "screen": "\#(screen)", "screenParam": "\#(param)" }"#
    }

    func testAServedLinkOpensThePickedScreenForBothGroups() throws {
        let results = try results("""
        { "episodes": [{ "_id": "e1", "title": "Ep"\(link("picked-episode", "e1")) }],
          "shows": [{ "_id": "s1", "title": "Show"\(link("picked-show", "s1")) }] }
        """)
        let router = try router()

        router.openCard(results.episodes?.cards.first?.target)
        router.openCard(results.shows?.cards.first?.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "picked-episode", param: "e1"),
                                            StackEntry(screenId: "picked-show", param: "s1")])
    }

    func testNoLinkFallsBackToTheConventionForBothGroups() throws {
        let results = try results(#"{ "episodes": [{ "_id": "e1", "title": "Ep" }], "shows": [{ "_id": "s1", "title": "Show" }] }"#)
        let router = try router()

        router.openCard(results.episodes?.cards.first?.target)
        router.openCard(results.shows?.cards.first?.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: "e1"),
                                            StackEntry(screenId: "show-tpl", param: "s1")])
    }

    func testAnUnknownLinkedScreenOpensNothing() throws {
        let results = try results(#"{ "shows": [{ "_id": "s1", "title": "Show"\#(link("gone", "s1")) }] }"#)
        let router = try router()

        router.openCard(results.shows?.cards.first?.target)

        XCTAssertTrue(router.state.stack.isEmpty, "a served link fails closed, never the convention")
    }
}

// MARK: - Debounce and stale answers

/// Suspends each caller until the test releases it, so the session runs without a real clock.
@MainActor
private final class Gate<Value> {
    private var waiting: [(key: String, resume: CheckedContinuation<Value, Never>)] = []

    var keys: [String] { waiting.map(\.key) }

    func wait(_ key: String) async -> Value {
        await withCheckedContinuation { waiting.append((key, $0)) }
    }

    func release(_ key: String, _ value: Value) {
        guard let index = waiting.firstIndex(where: { $0.key == key }) else { return XCTFail("nothing waits for \(key)") }
        waiting.remove(at: index).resume.resume(returning: value)
    }

    func releaseAll(_ value: Value) {
        let all = waiting
        waiting = []
        all.forEach { $0.resume.resume(returning: value) }
    }
}

@MainActor
final class MediaSearchSessionTests: XCTestCase {

    private let sleeps = Gate<Void>()
    private let answers = Gate<MediaSearchState>()
    private var asked: [String] = []
    private var waited: [Duration] = []

    private func session() -> MediaSearchSession {
        MediaSearchSession(sleep: { [sleeps] duration in
            await MainActor.run { self.waited.append(duration) }
            await sleeps.wait("tick")
        })
    }

    private func search(_ query: String) async -> MediaSearchState {
        asked.append(query)
        return await answers.wait(query)
    }

    /// Lets the session's tasks run to their next suspension point.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private let shows = MediaSearchState.results(MediaSearchResults(
        episodes: nil,
        shows: ShelfModel(nodeId: "search-shows", title: "Shows", cards: [], layout: .grid, emptyMessage: nil)
    ))

    func testNothingIsSentBelowTwoCharacters() async {
        let session = session()

        session.update("", search: search)
        session.update(" b ", search: search)
        await settle()

        XCTAssertTrue(waited.isEmpty, "no wait starts")
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(session.state, .idle)
    }

    func testOnlyTheLastChangeIsSentAfterTheWait() async {
        let session = session()

        session.update("bi", search: search)
        session.update("bib", search: search)
        session.update("bibel", search: search)
        await settle()

        XCTAssertEqual(waited, [.milliseconds(400), .milliseconds(400), .milliseconds(400)])
        XCTAssertTrue(asked.isEmpty, "nothing is sent before the wait ends")

        sleeps.releaseAll(())
        await settle()

        XCTAssertEqual(asked, ["bibel"], "an earlier change was canceled during its wait")
        answers.release("bibel", .noResults)
        await settle()
        XCTAssertEqual(session.state, .noResults)
    }

    func testAStaleAnswerIsDropped() async {
        let session = session()

        session.update("bibel", search: search)
        await settle()
        sleeps.releaseAll(())
        await settle()
        XCTAssertEqual(asked, ["bibel"])

        // A newer query starts while "bibel" is still in flight, and answers first.
        session.update("bibelkompass", search: search)
        await settle()
        sleeps.releaseAll(())
        await settle()
        XCTAssertEqual(asked, ["bibel", "bibelkompass"])

        answers.release("bibelkompass", shows)
        await settle()
        XCTAssertEqual(session.state, shows)

        answers.release("bibel", .noResults)
        await settle()
        XCTAssertEqual(session.state, shows, "the older answer never replaces the newer one")
    }

    func testClearingTheFieldDropsTheAnswerInFlight() async {
        let session = session()

        session.update("bibel", search: search)
        await settle()
        sleeps.releaseAll(())
        await settle()

        session.update("", search: search)
        XCTAssertEqual(session.state, .idle)

        answers.release("bibel", shows)
        await settle()
        XCTAssertEqual(session.state, .idle, "an empty field shows nothing")
    }

    func testCancelStopsTheSearchInFlightAndTheSameTextSendsAgain() async {
        let session = session()

        session.update("bibel", search: search)
        await settle()
        sleeps.releaseAll(())
        await settle()

        session.cancel()
        answers.release("bibel", shows)
        await settle()
        XCTAssertEqual(session.state, .idle, "the canceled answer is dropped")

        session.update("bibel", search: search)
        await settle()
        sleeps.releaseAll(())
        await settle()
        XCTAssertEqual(asked, ["bibel", "bibel"], "the view shows again: the query is sent again")
        answers.release("bibel", shows)
        await settle()
        XCTAssertEqual(session.state, shows)
    }

    func testCancelWithNothingInFlightKeepsTheAnswer() async {
        let session = session()

        session.update("bibel", search: search)
        await settle()
        sleeps.releaseAll(())
        await settle()
        answers.release("bibel", shows)
        await settle()

        session.cancel()
        session.update("bibel", search: search)
        await settle()

        XCTAssertEqual(asked, ["bibel"], "a return to the view sends nothing")
        XCTAssertEqual(session.state, shows)
    }

    func testTheSameQueryAfterTrimmingIsNotSentAgain() async {
        let session = session()

        session.update("bibel", search: search)
        await settle()
        sleeps.releaseAll(())
        await settle()
        answers.release("bibel", shows)
        await settle()

        session.update("bibel ", search: search)
        await settle()

        XCTAssertEqual(waited.count, 1, "a trailing space changes nothing")
        XCTAssertEqual(asked, ["bibel"])
        XCTAssertEqual(session.state, shows)
    }
}

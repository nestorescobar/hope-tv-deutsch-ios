// cspell:ignore Auftrag Filme
import XCTest
@testable import HopeTViOS

private let movieA = "665f0c2bd9c698836400aa01"
private let movieB = "665f0c2bd9c698836400aa02"
private let templateId = "6a1f0c2bd9c698836400ff01"

/// Movie item JSON in the Frontend API `movies` list shape. `link` adds a served `screenLink`;
/// `idKey` names the id field (`id` on a list item, `_id` on an older shape).
private func movieJSON(_ id: String, title: String = "Der Auftrag", link: Bool = false, idKey: String = "id",
                       poster: Bool = true) -> String {
    let posterImage = poster ? #""poster": { "containerId": "c1", "name": "poster.jpg" },"# : ""
    let screenLink = link
        ? #", "screenLink": { "linkType": "screen", "screen": "\#(templateId)", "screenParam": "\#(id)" }"#
        : ""
    return #"""
    { "\#(idKey)": "\#(id)", "title": "\#(title)", "abstract": "A film.", "language": "de", "releaseYear": 2019,
      "duration": 6720, "genres": [{ "id": "g1", "title": "Drama", "name": "drama" }], "ageRatings": [],
      "videoOnDemandEndsAt": null,
      "images": { \#(posterImage) "banner": { "containerId": "c1", "name": "banner.jpg" },
                  "default": { "containerId": "c1", "name": "default.jpg" } }\#(screenLink) }
    """#
}

/// Evaluates one block node `list` on a static screen and returns its content.
private func evaluateList(type: String, props: String = "{}", resources: String,
                          paging: String? = nil) throws -> BlockContent? {
    let screen = try ContractDecoder.screen(screenData(type: type, props: props, resources: resources, paging: paging))
    let root = try XCTUnwrap(BlockRegistry.evaluate(
        nodeId: CraftDocument.rootId,
        document: screen.content,
        context: TestRender.context(blockResources: screen.blockResources)
    ))
    return root.first { $0.id == "list" }?.content
}

private func screenData(type: String, props: String = "{}", resources: String, paging: String? = nil,
                        id: String = "6aa952fcc445860ea24e1bcc") -> Data {
    Data("""
    {
      "id": "\(id)",
      "kind": "static",
      "blockResources": { "list": { "resources": \(resources) \(paging.map { ", \"paging\": \($0)" } ?? "") } },
      "content": {
        "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["list"] },
        "list": {
          "type": { "resolvedName": "\(type)" }, "props": \(props),
          "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": []
        }
      }
    }
    """.utf8)
}

private func shelf(_ content: BlockContent?) throws -> ShelfModel {
    guard case let .shelf(model)? = content else {
        XCTFail("drew no shelf")
        throw XCTSkip("no shelf")
    }
    return model
}

// MARK: - MovieList

/// `MovieList` (awe#6870): `movies` `{ items, count }`. A row of poster cards by default, a grid
/// of poster cards for `layout: "grid"`. A card opens the served `screenLink`, else the one
/// `movie` Template Screen. An empty list draws nothing.
final class MovieListTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        super.tearDown()
    }

    private func movies(_ items: [String], count: Int? = nil) -> String {
        #"{ "movies": { "count": \#(count ?? items.count), "items": [\#(items.joined(separator: ","))] }, "movieFilters": { "genres": [] } }"#
    }

    func testTheKeyIsInTheRegistry() {
        XCTAssertEqual(BlockKey(resolvedName: "MovieList"), .movieList)
        XCTAssertTrue(BlockRegistry.keys.contains("MovieList"))
    }

    /// No `layout` and `slider` draw a row of poster cards. A row does not page, so its title
    /// carries no count: "Movies (57)" would name movies the row cannot reach (awe#7032).
    func testARowOfPosterCardsByDefault() throws {
        for props in ["{}", #"{ "layout": "slider" }"#, #"{ "layout": "carousel" }"#] {
            let model = try shelf(try evaluateList(type: "MovieList", props: props,
                                                   resources: movies([movieJSON(movieA), movieJSON(movieB)], count: 57)))
            XCTAssertEqual(model.layout, .row, props)
            XCTAssertEqual(model.title, "Movies", props)
            XCTAssertEqual(model.cards.map(\.id), [movieA, movieB], props)
            XCTAssertEqual(model.cards.first?.style, .posters, props)
            XCTAssertNil(model.emptyMessage, props)
        }
    }

    /// `layout: "grid"` draws a grid of poster cards (2:3): the poster grid metrics, and each
    /// card in the poster shape, an item with no poster too (its art drawn fit, as in the row).
    /// The grid pages, so its title keeps the served count.
    func testTheGridPropDrawsAGridOfPosters() throws {
        let model = try shelf(try evaluateList(type: "MovieList", props: #"{ "layout": "grid" }"#,
                                               resources: movies([movieJSON(movieA), movieJSON(movieB, poster: false)], count: 57)))
        XCTAssertEqual(model.layout, .grid)
        XCTAssertEqual(model.cardStyle, .posters)
        XCTAssertEqual(model.cards.map(\.style), [.posters, .posters])
        XCTAssertEqual(model.cards.map(\.artIsFallback), [false, true])
        XCTAssertEqual(model.gridMetrics, .poster)
        XCTAssertEqual(model.cards.map(model.gridShape), [.poster, .poster])
        XCTAssertEqual(model.title, "Movies (57)")

        // No served `count`: the title counts the items.
        let noCount = try shelf(try evaluateList(type: "MovieList", props: #"{ "layout": "grid" }"#,
                                                 resources: #"{ "movies": { "items": [\#(movieJSON(movieA)), \#(movieJSON(movieB))] } }"#))
        XCTAssertEqual(noCount.title, "Movies (2)")
    }

    /// The other grids keep the landscape metrics and the landscape shape for every card: a shows
    /// or episodes Collection grid (also with a `posters` record, awe#5982 D3), Browse and
    /// `EpisodesList`. Only a movies Collection grid draws posters (awe#7033).
    func testTheOtherGridsKeepTheLandscapeGrid() throws {
        let art = #"""
        { "default": { "containerId": "c1", "name": "d.jpg" }, "poster": { "containerId": "c1", "name": "p.jpg" },
          "banner": { "containerId": "c1", "name": "b.jpg" } }
        """#
        let showsCollection = try shelf(try evaluateList(type: "Collection", props: #"{ "layout": "grid" }"#, resources: #"""
        { "collection": { "_id": "c1", "title": "Shows", "contentType": "shows", "layout": "posters",
          "shows": [{ "_id": "61975e24d9c698836400305b", "title": "Table Talk", "images": \#(art) }], "episodes": [] } }
        """#))
        let episodesCollection = try shelf(try evaluateList(type: "Collection", props: #"{ "layout": "grid" }"#, resources: #"""
        { "collection": { "_id": "c2", "title": "Latest", "contentType": "episodes", "layout": "posters", "shows": [],
          "episodes": [{ "_id": "6a049248c6d68f1e30573243", "title": "A Bear Remembers", "images": \#(art),
                         "show": { "_id": "s1", "title": "_Test Show" } }] } }
        """#))
        let browse = try TestRender.screen("browse").node.first { $0.key == .showList }?.content
        let episodes = try TestRender.screen("show").node.first { $0.key == .episodesList }?.content
        for (name, model) in [("shows collection", showsCollection), ("episodes collection", episodesCollection),
                              ("browse", try shelf(browse)), ("episodes", try shelf(episodes))] {
            XCTAssertEqual(model.layout, .grid, name)
            XCTAssertFalse(model.cards.isEmpty, name)
            XCTAssertEqual(model.gridMetrics, .wide, name)
            XCTAssertTrue(model.cards.allSatisfy { model.gridShape($0) == .wide }, name)
        }
    }

    /// An item with no poster keeps the poster shape in the row and draws its art fit over a
    /// blurred copy, as on a posters Collection (ruled 2026-10-26).
    func testAnItemWithNoPosterKeepsThePosterShape() throws {
        let model = try shelf(try evaluateList(type: "MovieList", resources: movies([movieJSON(movieA, poster: false)])))
        XCTAssertEqual(model.cards.first?.style, .posters)
        XCTAssertEqual(model.cards.first?.artIsFallback, true)
    }

    /// The card: the title, "year · runtime" as the subtitle, and Watch later as a movie.
    func testTheCardNamesTheYearAndRuntimeAndOffersWatchLater() throws {
        let card = try XCTUnwrap(try shelf(try evaluateList(type: "MovieList", resources: movies([movieJSON(movieA)]))).cards.first)
        XCTAssertEqual(card.title, "Der Auftrag")
        XCTAssertEqual(card.subtitle, "2019 · 1h 52m")
        XCTAssertNotNil(card.imageURL)
        guard case let .watchLater(item)? = card.menu else { return XCTFail("no Watch later menu") }
        XCTAssertEqual(item.itemType, .movie)
        XCTAssertEqual(item.itemId, movieA)
    }

    /// The served `screenLink` wins (contract "Resolution order").
    func testACardOpensTheServedLinkFirst() throws {
        let card = try XCTUnwrap(try shelf(try evaluateList(type: "MovieList",
                                                            resources: movies([movieJSON(movieA, link: true)]))).cards.first)
        XCTAssertEqual(card.target?.resourceType, "movie")
        XCTAssertEqual(card.target?.itemId, movieA)
        XCTAssertEqual(card.target?.link?.screenId, templateId)
        XCTAssertEqual(card.target?.link?.param, movieA)
    }

    /// No served link: the card convention, the `movie` Template Screen with the item id. An
    /// item that serves `_id` in place of `id` keeps its target.
    func testACardWithNoLinkUsesTheConvention() throws {
        let cards = try shelf(try evaluateList(type: "MovieList",
                                               resources: movies([movieJSON(movieA), movieJSON(movieB, idKey: "_id")]))).cards
        XCTAssertEqual(cards.map(\.target), [CardTarget(resourceType: "movie", itemId: movieA),
                                             CardTarget(resourceType: "movie", itemId: movieB)])
    }

    /// The router opens the one `movie` template by the convention, and the served link names
    /// its own screen. Built through the evaluator, not by hand.
    @MainActor
    func testTheRouterOpensTheMovieTemplate() throws {
        let otherTemplate = "6a1f0c2bd9c698836400ff02"
        // The linked screen is a `show` template, so only the served link can reach it.
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [
            { "id": "home", "kind": "static" },
            { "id": "\(otherTemplate)", "kind": "template", "resourceType": "movie" },
            { "id": "\(templateId)", "kind": "template", "resourceType": "show" }
          ],
          "preset": {}
        }
        """.utf8))
        let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
        let cards = try shelf(try evaluateList(type: "MovieList",
                                               resources: movies([movieJSON(movieA), movieJSON(movieB, link: true)]))).cards

        router.openCard(cards[0].target)
        router.openCard(cards[1].target)

        XCTAssertEqual(router.state.stack, [
            StackEntry(screenId: otherTemplate, param: movieA),
            StackEntry(screenId: templateId, param: movieB),
        ])
    }

    /// An empty list draws nothing, also when the `movies` flag is off (the server answers
    /// `{ items: [], count: 0 }`). No resource draws nothing.
    func testAnEmptyListDrawsNothing() throws {
        XCTAssertNil(try evaluateList(type: "MovieList", resources: movies([])))
        XCTAssertNil(try evaluateList(type: "MovieList", props: #"{ "layout": "grid" }"#, resources: movies([])))
        XCTAssertNil(try evaluateList(type: "MovieList", resources: "{}"))
    }

    /// `movies` names the list a block page answers.
    func testAMovieListPagesItsMovies() {
        XCTAssertEqual(PagedList(paging: BlockPaging(page: 1, hasMore: true), key: .movieList)?.listName, "movies")
    }
}

// MARK: - Movie Collections

/// A `Collection` / `CollectionTeaser` record with `contentType: "movies"` draws `collection.movies`
/// as movie cards. Before awe#6870 it fell through to `episodes` and drew "nothing to watch".
final class MovieCollectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        super.tearDown()
    }

    /// `resource` is the block's own name: `collectionTeaser` for `CollectionTeaser`.
    private func record(_ resource: String = "collection", layout: String = "posters", movies: [String]) -> String {
        #"""
        { "\#(resource)": { "_id": "c1", "title": "Filme", "contentType": "movies", "layout": "\#(layout)",
          "movies": [\#(movies.joined(separator: ","))], "moviesCount": \#(movies.count), "shows": [], "episodes": [] } }
        """#
    }

    func testAMoviesCollectionDrawsMovieCards() throws {
        for (type, resource) in [("Collection", "collection"), ("CollectionTeaser", "collectionTeaser")] {
            let model = try shelf(try evaluateList(type: type, resources: record(resource, movies: [movieJSON(movieA, link: true),
                                                                                                   movieJSON(movieB)])))
            XCTAssertEqual(model.title, "Filme", type)
            XCTAssertNil(model.emptyMessage, type)
            XCTAssertEqual(model.cards.map(\.id), [movieA, movieB], type)
            XCTAssertEqual(model.cards.first?.style, .posters, type)
            XCTAssertEqual(model.cards.first?.subtitle, "2019 · 1h 52m", type)
            XCTAssertEqual(model.cards.first?.target?.link?.screenId, templateId, type)
            XCTAssertEqual(model.cards.last?.target, CardTarget(resourceType: "movie", itemId: movieB), type)
            guard case let .watchLater(item)? = model.cards.first?.menu else { return XCTFail("no Watch later menu") }
            XCTAssertEqual(item.itemType, .movie, type)
        }
    }

    /// A `cards` record draws landscape movie cards in a row.
    func testTheCardStyleFollowsTheLadder() throws {
        let cards = try shelf(try evaluateList(type: "Collection", resources: record(layout: "cards", movies: [movieJSON(movieA)])))
        XCTAssertEqual(cards.layout, .row)
        XCTAssertEqual(cards.cardStyle, .cards)
        XCTAssertEqual(cards.cards.first?.style, .cards)
    }

    /// A movies Collection grid draws posters, as the `MovieList` grid does (awe#7033): the poster
    /// grid metrics, and each card in the poster shape, a movie with no poster too. The record's
    /// own `layout` does not apply in a grid, so a `hero` record
    /// draws no hero and a `cards` record still draws posters.
    func testAMoviesCollectionGridDrawsPosters() throws {
        for recordLayout in ["posters", "banner", "hero", "cards"] {
            let model = try shelf(try evaluateList(type: "Collection", props: #"{ "layout": "grid" }"#,
                                                   resources: record(layout: recordLayout,
                                                                     movies: [movieJSON(movieA), movieJSON(movieB, poster: false)])))
            XCTAssertEqual(model.layout, .grid, recordLayout)
            XCTAssertEqual(model.cardStyle, .posters, recordLayout)
            XCTAssertEqual(model.gridMetrics, .poster, recordLayout)
            XCTAssertEqual(model.cards.map(\.style), [.posters, .posters], recordLayout)
            XCTAssertEqual(model.cards.map(model.gridShape), [.poster, .poster], recordLayout)
            XCTAssertTrue(model.cards.allSatisfy { $0.hero == nil }, recordLayout)
            XCTAssertEqual(model.title, "Filme", recordLayout)
        }
    }

    /// A hero record draws the hero: the abstract and a "year • runtime" meta line.
    func testAHeroRecordDrawsTheHero() throws {
        let model = try shelf(try evaluateList(type: "CollectionTeaser",
                                               resources: record("collectionTeaser", layout: "hero", movies: [movieJSON(movieA)])))
        let hero = try XCTUnwrap(model.cards.first?.hero)
        XCTAssertEqual(hero.abstract, "A film.")
        XCTAssertEqual(hero.meta, "2019 • 1h 52m")
        XCTAssertEqual(model.cards.first?.target, CardTarget(resourceType: "movie", itemId: movieA))
    }

    /// A banner record draws image-only banner cards (ruled 2026-10-24): no hero, the same card press.
    func testABannerRecordDrawsBannerCards() throws {
        let model = try shelf(try evaluateList(type: "CollectionTeaser",
                                               resources: record("collectionTeaser", layout: "banner", movies: [movieJSON(movieA)])))
        XCTAssertEqual(model.cardStyle, .banner)
        XCTAssertEqual(model.cards.first?.style, .banner)
        XCTAssertNil(model.cards.first?.hero)
        XCTAssertEqual(model.cards.first?.accessibilityLabel(shape: .banner), "Der Auftrag, 2019 · 1h 52m")
        XCTAssertEqual(model.cards.first?.target, CardTarget(resourceType: "movie", itemId: movieA))
    }

    /// An empty movies record draws the Collection's own empty message.
    func testAnEmptyMoviesCollectionSaysNothingToWatch() throws {
        let model = try shelf(try evaluateList(type: "Collection", resources: record(movies: [])))
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertEqual(model.emptyMessage, ChromeText.string(.nothingToWatch))
    }

    /// An empty movies grid keeps the grid and the empty message. A movies grid with no authored
    /// title draws the "Collection" fallback title: a grid is never a hero, also for a hero record.
    func testAnEmptyOrUntitledMoviesGridKeepsTheGridRules() throws {
        let empty = try shelf(try evaluateList(type: "Collection", props: #"{ "layout": "grid" }"#,
                                               resources: record(layout: "hero", movies: [])))
        XCTAssertEqual(empty.layout, .grid)
        XCTAssertEqual(empty.cardStyle, .posters)
        XCTAssertTrue(empty.cards.isEmpty)
        XCTAssertEqual(empty.emptyMessage, ChromeText.string(.nothingToWatch))

        let untitled = try shelf(try evaluateList(type: "Collection", props: #"{ "layout": "grid" }"#, resources: #"""
        { "collection": { "_id": "c1", "contentType": "movies", "layout": "hero",
          "movies": [\#(movieJSON(movieA))], "shows": [], "episodes": [] } }
        """#))
        XCTAssertEqual(untitled.layout, .grid)
        XCTAssertEqual(untitled.title, ChromeText.string(.collection))
    }

    /// A Collection page answers `collection { items, count }`; the merge appends to `movies`, the
    /// array the `contentType` names.
    func testAMoviesCollectionPageAppendsToItsMovies() throws {
        let base: [String: [String: JSONValue]] = ["list": ["collection": try JSONDecoder().decode(JSONValue.self, from: Data("""
        { "title": "Filme", "contentType": "movies", "movies": [{ "id": "m1" }], "shows": [], "episodes": [], "moviesCount": 3 }
        """.utf8))]]
        var list = try XCTUnwrap(PagedList(paging: BlockPaging(page: 1, hasMore: true), key: .collection))
        list.append(try ContractDecoder.blockPage(PagedFixtures.page(2, nodeId: "list", list: "collection",
                                                                     ids: ["m1", "m2", "m3"], hasMore: false, count: 3)),
                    base: base["list"]?["collection"])

        let merged = try XCTUnwrap(PagedList.merge(base, lists: ["list": list])["list"]?["collection"])
        XCTAssertEqual(merged["movies"].array.compactMap { $0["id"].string ?? $0["_id"].string }, ["m1", "m2", "m3"])
        XCTAssertEqual(merged["episodes"].array.count, 0)
        XCTAssertFalse(merged.hasKey("items"))
    }
}

// MARK: - MovieList paging through the store

@MainActor
final class MovieListPagingTests: XCTestCase {

    private let screenId = PagedFixtures.browseId

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

    /// Page 2 of a grid MovieList asks the block route and appends to `movies.items`; the title
    /// count is the latest answer's.
    func testTheNextPageAppendsToTheMovies() async throws {
        let config = TestConfig.staging
        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
        let resources = #"{ "movies": { "count": 3, "items": [\#(movieJSON(movieA))] } }"#
        StubProtocol.queue = [.init(status: 200, body: screenData(type: "MovieList", props: #"{ "layout": "grid" }"#,
                                                                 resources: resources,
                                                                 paging: #"{ "page": 1, "hasMore": true }"#, id: screenId))]
        await store.loadScreen(id: screenId, param: nil)
        StubProtocol.requests = []
        let key = store.key(for: screenId, param: nil)

        StubProtocol.queue = [.init(status: 200, body: PagedFixtures.page(2, nodeId: "list", list: "movies",
                                                                         ids: [movieA, "m2", "m3"], hasMore: false, count: 4))]
        await store.loadNextPage(key: key, nodeId: "list")

        let url = try XCTUnwrap(StubProtocol.requests.first?.url)
        XCTAssertEqual(url.path, "/v1/app/hope-tv/screens/\(screenId)/blocks/list")
        let screen = try XCTUnwrap(store.screenEntry(id: screenId, param: nil)?.screen)
        let root = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: store.blockResources(for: key))))
        let model = try shelf(root.first { $0.id == "list" }?.content)
        XCTAssertEqual(model.cards.map(\.id), [movieA, "m2", "m3"], "a record already on page 1 is not added twice")
        XCTAssertEqual(model.title, "Movies (4)")
        XCTAssertEqual(store.pagedLists[key]?["list"]?.hasMore, false)
    }
}

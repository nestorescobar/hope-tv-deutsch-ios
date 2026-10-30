// cspell:ignore Weiterschauen
import XCTest
@testable import HopeTViOS

/// The media-library Collection shapes (ruled 2026-10-23): `mixed`, `continueWatching`, an unknown
/// `contentType`, the list-layout precedence with the sideways grid, and the `CollectionList` block.
enum CollectionFixtures {
    static let episodeId = "6a0000000000000000000e01"
    static let showId = "6a0000000000000000000501"
    static let movieId = "6a0000000000000000000a01"

    /// One node `c` of `type` that reads `record` as its `resource`.
    static func screen(_ record: Any, type: String = "Collection", resource: String = "collection",
                       props: [String: Any] = [:]) throws -> AppScreen {
        let root: [String: Any] = [
            "id": "s1",
            "kind": "static",
            "blockResources": ["c": ["resources": [resource: record]]],
            "content": [
                "ROOT": ["type": ["resolvedName": "Root"], "nodes": ["c"]],
                "c": [
                    "type": ["resolvedName": type],
                    "props": props,
                    "custom": ["type": "plugin", "resources": [resource]],
                    "parent": "ROOT", "nodes": [String](),
                ],
            ],
        ]
        return try ContractDecoder.screen(JSONSerialization.data(withJSONObject: root))
    }

    /// The node `c`, evaluated. `signedIn` gives the member resume points a signed-in context has.
    static func node(_ screen: AppScreen, watchHistory: [WatchProgressStore.Entry] = [],
                     signedIn: Bool = false) throws -> EvaluatedNode {
        let context = RenderContext(
            blockResources: screen.blockResources,
            images: ImageConfig(cdn: "https://images.test", bucket: "bucket"),
            watchHistory: watchHistory,
            memberResumePoints: signedIn ? [:] : nil
        )
        let root = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: context))
        return try XCTUnwrap(root.first { $0.id == "c" })
    }

    static func shelf(_ node: EvaluatedNode) throws -> ShelfModel {
        guard case let .shelf(model) = node.content else {
            XCTFail("\(node.id) drew no shelf")
            throw XCTSkip("no shelf")
        }
        return model
    }

    static func episode(_ id: String = episodeId, title: String = "Lesson 1") -> [String: Any] {
        ["_id": id, "title": title, "duration": 1500, "show": ["title": "Hope Sabbath School"],
         "images": ["default": ["containerId": "c1", "name": "e.jpg"]]]
    }

    static func show(_ id: String = showId, title: String = "Table Talk") -> [String: Any] {
        ["_id": id, "title": title, "episodeCount": 26,
         "images": ["default": ["containerId": "c1", "name": "s.jpg"], "poster": ["containerId": "c1", "name": "p.jpg"]]]
    }

    /// A `MovieListItem`: it names its record `id`, not `_id`.
    static func movie(_ id: String = movieId, title: String = "The Chosen") -> [String: Any] {
        ["id": id, "title": title, "releaseYear": 2019, "duration": 6720,
         "images": ["default": ["containerId": "c1", "name": "m.jpg"]]]
    }

    static func typed(_ item: [String: Any], _ type: String) -> [String: Any] {
        item.merging(["type": type]) { _, new in new }
    }
}

private func historyEntry(_ id: String, minutesAgo: Double) -> WatchProgressStore.Entry {
    WatchProgressStore.Entry(
        playableId: "https://cdn.test/\(id).m3u8", showId: nil, episodeId: id, title: "Watched \(id)",
        subtitle: "Hope Sabbath School", imageURL: nil, fraction: 0.4, duration: 1500,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60)
    )
}

// MARK: - mixed and contentType

final class MixedCollectionTests: XCTestCase {
    private typealias F = CollectionFixtures

    func testAMixedRecordDrawsOneCardPerTypeInServedOrder() throws {
        let record: [String: Any] = [
            "title": "Picks", "contentType": "mixed", "itemsCount": 4,
            "items": [F.typed(F.movie(), "movie"), F.typed(F.episode(), "episode"),
                      F.typed(F.show(), "show")],
        ]
        let model = try F.shelf(try F.node(try F.screen(record)))

        XCTAssertEqual(model.cards.map(\.id), [F.movieId, F.episodeId, F.showId])
        XCTAssertEqual(model.cards.map { $0.target?.resourceType }, ["movie", "episode", "show"])
        XCTAssertEqual(model.cards.map(\.subtitle), ["2019 · 1h 52m", "Hope Sabbath School", "26 episodes"],
                       "each card uses the reader of its single-type Collection")
        XCTAssertEqual(model.title, "Picks")
        XCTAssertEqual(model.layout, .row)
    }

    /// A mixed movie with no served link (no Movie Screen picked): the card opens by the
    /// convention, like any card with no link.
    func testAMixedMovieOpensByTheConvention() throws {
        let record: [String: Any] = ["contentType": "mixed", "items": [F.typed(F.movie(), "movie")]]
        let target = try XCTUnwrap(try F.shelf(try F.node(try F.screen(record))).cards.first?.target)

        XCTAssertEqual(target, CardTarget(resourceType: "movie", itemId: F.movieId))
        XCTAssertNil(target.link)
    }

    /// A `CollectionList` with picked Screens serves `screenLink` on every item: the card opens
    /// that link, not the convention (single types and mixed).
    func testAServedScreenLinkWinsOnEveryItemType() throws {
        func link(_ screen: String, _ param: String) -> [String: Any] {
            ["linkType": "screen", "screen": screen, "screenParam": param]
        }
        func linked(_ item: [String: Any], _ screen: String, _ param: String) -> [String: Any] {
            item.merging(["screenLink": link(screen, param)]) { _, new in new }
        }
        let records: [(String, [String: Any])] = [
            ("shows", ["contentType": "shows", "shows": [linked(F.show(), "show-tpl", F.showId)]]),
            ("episodes", ["contentType": "episodes", "episodes": [linked(F.episode(), "ep-tpl", F.episodeId)]]),
            ("movies", ["contentType": "movies", "movies": [linked(F.movie(), "movie-tpl", F.movieId)]]),
            ("mixed", ["contentType": "mixed", "items": [
                F.typed(linked(F.movie(), "movie-tpl", F.movieId), "movie"),
                F.typed(linked(F.episode(), "ep-tpl", F.episodeId), "episode"),
                F.typed(linked(F.show(), "show-tpl", F.showId), "show"),
            ]]),
        ]

        for (name, record) in records {
            let cards = try F.shelf(try F.node(try F.screen(record))).cards
            XCTAssertFalse(cards.isEmpty, name)
            for card in cards {
                let link = try XCTUnwrap(card.target?.link, "\(name): \(card.id) has no served link")
                XCTAssertEqual(link.param, card.id, name)
                let prefix = card.target?.resourceType == "movie" ? "movie" : card.target?.resourceType == "show" ? "show" : "ep"
                XCTAssertEqual(link.screenId, "\(prefix)-tpl", name)
            }
        }
    }

    func testAnItemOfAnUnknownTypeIsDroppedAndTheOrderStays() throws {
        let record: [String: Any] = [
            "contentType": "mixed",
            "items": [F.typed(F.show(), "show"), F.typed(F.episode("6a0000000000000000000e99"), "podcast"),
                      F.episode("6a0000000000000000000e98"), F.typed(F.episode(), "episode")],
        ]
        let model = try F.shelf(try F.node(try F.screen(record)))

        XCTAssertEqual(model.cards.map(\.id), [F.showId, F.episodeId], "an unknown or missing `type` draws no card")
    }

    func testAnItemServedTwiceDrawsOnce() throws {
        let record: [String: Any] = [
            "contentType": "mixed",
            "items": [F.typed(F.episode(), "episode"), F.typed(F.show(), "show"), F.typed(F.episode(), "episode")],
        ]
        XCTAssertEqual(try F.shelf(try F.node(try F.screen(record))).cards.map(\.id), [F.episodeId, F.showId])
    }

    func testAMixedRecordWithNothingToDrawSaysSo() throws {
        let record: [String: Any] = ["title": "Picks", "contentType": "mixed", "items": [F.typed(F.show(), "album")]]
        let model = try F.shelf(try F.node(try F.screen(record)))

        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertEqual(model.emptyMessage, ChromeText.string(.nothingToWatch))
    }

    /// A type this build does not know draws nothing, so a new type on the server never breaks the
    /// screen.
    func testAnUnknownContentTypeDrawsNothing() throws {
        let record: [String: Any] = ["title": "New", "contentType": "podcasts", "shows": [F.show()],
                                     "episodes": [F.episode()]]
        let node = try F.node(try F.screen(record))

        XCTAssertNil(node.content)
        XCTAssertNil(try F.node(try F.screen(record, type: "CollectionTeaser", resource: "collectionTeaser")).content)
    }

    func testAnAbsentContentTypeKeepsTheLegacyGuess() throws {
        let shows: [String: Any] = ["shows": [F.show()], "episodes": [F.episode()]]
        XCTAssertEqual(try F.shelf(try F.node(try F.screen(shows))).cards.map(\.id), [F.showId],
                       "`shows` when not empty")

        let episodes: [String: Any] = ["shows": [Any](), "episodes": [F.episode()]]
        XCTAssertEqual(try F.shelf(try F.node(try F.screen(episodes))).cards.map(\.id), [F.episodeId],
                       "else `episodes`")
    }
}

// MARK: - continueWatching

final class ContinueWatchingCollectionTests: XCTestCase {
    private typealias F = CollectionFixtures

    private let history = [historyEntry("6a0000000000000000000e11", minutesAgo: 1),
                           historyEntry("6a0000000000000000000e12", minutesAgo: 2),
                           historyEntry("6a0000000000000000000e13", minutesAgo: 3)]

    /// The served `entries` are always `[]` on the App Contract; one here proves they are ignored.
    private func record(showToGuests: Bool?, extra: [String: Any] = [:]) -> [String: Any] {
        var record: [String: Any] = ["title": "Weiterschauen", "contentType": "continueWatching",
                                     "entries": [["episode": F.episode()]]]
        record["showToGuests"] = showToGuests
        return record.merging(extra) { _, new in new }
    }

    func testSignedOutWithShowToGuestsOffDrawsNothing() throws {
        XCTAssertNil(try F.node(try F.screen(record(showToGuests: false)), watchHistory: history).content)
        XCTAssertNil(try F.node(try F.screen(record(showToGuests: nil)), watchHistory: history).content,
                     "an old record with no field reads as off")
    }

    func testSignedOutWithShowToGuestsOnDrawsTheDeviceHistory() throws {
        let model = try F.shelf(try F.node(try F.screen(record(showToGuests: true)), watchHistory: history))

        XCTAssertEqual(model.cards.map(\.title), history.map(\.title), "the served entries are ignored")
        XCTAssertEqual(model.cards.first?.target, CardTarget(resourceType: "episode", itemId: "6a0000000000000000000e11"))
        XCTAssertEqual(model.cards.first?.progress, 0.4)
        XCTAssertEqual(model.title, "Weiterschauen")
        XCTAssertEqual(model.layout, .row)
        XCTAssertEqual(model.cardStyle, .cards)
        XCTAssertNil(model.emptyMessage)
    }

    func testSignedInDrawsTheMemberHistoryWhateverShowToGuestsSays() throws {
        let model = try F.shelf(try F.node(try F.screen(record(showToGuests: false)), watchHistory: history,
                                           signedIn: true))
        XCTAssertEqual(model.cards.count, 3)
    }

    func testAnEmptyHistoryDrawsNothing() throws {
        XCTAssertNil(try F.node(try F.screen(record(showToGuests: true))).content)
        XCTAssertNil(try F.node(try F.screen(record(showToGuests: true)), signedIn: true).content)
    }

    func testTheCountIsTheBlockLimitElseTheRecordMaxItems() throws {
        let screen = { (props: [String: Any], maxItems: Int?) in
            try F.screen(self.record(showToGuests: true, extra: maxItems.map { ["maxItems": $0] } ?? [:]), props: props)
        }
        XCTAssertEqual(try F.shelf(try F.node(try screen(["limit": 2], 1), watchHistory: history)).cards.count, 2)
        XCTAssertEqual(try F.shelf(try F.node(try screen(["limit": 0], 1), watchHistory: history)).cards.count, 1,
                       "a 0 limit defers to the record")
        XCTAssertEqual(try F.shelf(try F.node(try screen([:], 0), watchHistory: history)).cards.count, 3,
                       "no limit at all draws what the source holds")
        XCTAssertEqual(try F.shelf(try F.node(try screen(["limit": 24], nil), watchHistory: history)).cards.count, 3,
                       "never more than the source holds")
    }

    func testTheTitleFallsBackToKeepWatchingAndRespectsHideTitle() throws {
        var untitled = record(showToGuests: true)
        untitled["title"] = nil
        XCTAssertEqual(try F.shelf(try F.node(try F.screen(untitled), watchHistory: history)).title,
                       ChromeText.string(.keepWatching))

        let hidden = record(showToGuests: true, extra: ["hideTitle": true])
        XCTAssertNil(try F.shelf(try F.node(try F.screen(hidden), watchHistory: history)).title)
        XCTAssertNil(try F.shelf(try F.node(try F.screen(record(showToGuests: true), props: ["hideTitle": true]),
                                            watchHistory: history)).title)
    }

    func testShowDurationAddsTheDurationAndTheTimeLeft() throws {
        let off = try F.shelf(try F.node(try F.screen(record(showToGuests: true)), watchHistory: history))
        XCTAssertEqual(off.cards.first?.subtitle, "Hope Sabbath School")

        let on = try F.shelf(try F.node(try F.screen(record(showToGuests: true), props: ["showDuration": true]),
                                        watchHistory: history))
        XCTAssertEqual(on.cards.first?.subtitle, "Hope Sabbath School · 25m · 15m left")
    }

    /// Under a `Collection` block with `layout: "grid"` it is the paged grid layout, but the
    /// server serves no `paging` for it, so the store never asks for a page. The cards are the
    /// history, landscape.
    func testTheBlockGridDrawsTheHistoryInTheGridLayout() throws {
        let screen = try F.screen(record(showToGuests: true, extra: ["listLayout": "slider"]),
                                  props: ["layout": "grid"])
        XCTAssertTrue(screen.paging.isEmpty, "no paging is served for the node")
        let model = try F.shelf(try F.node(screen, watchHistory: history))
        XCTAssertEqual(model.layout, .grid)
        XCTAssertEqual(model.cards.count, 3)
        XCTAssertNil(PagedList(paging: screen.paging["c"], key: .collection), "nothing to page")
    }

    func testItFollowsTheListLayout() throws {
        let layout = { (listLayout: String) in
            try F.shelf(try F.node(try F.screen(self.record(showToGuests: true, extra: ["listLayout": listLayout])),
                                   watchHistory: self.history)).layout
        }
        XCTAssertEqual(try layout("grid"), .sidewaysGrid)
        XCTAssertEqual(try layout("slider"), .row)
        XCTAssertEqual(try layout("carousel"), .row, "a carousel reads as a row")
    }
}

// MARK: - List layout precedence

final class CollectionListLayoutTests: XCTestCase {
    private typealias F = CollectionFixtures

    func testThePrecedenceTable() {
        typealias L = ShelfModel.Layout
        let table: [(block: String?, record: String?, expected: L)] = [
            ("grid", nil, .grid), ("grid", "slider", .grid), ("grid", "carousel", .grid),
            ("slider", "grid", .row), ("slider", nil, .row),
            (nil, "grid", .sidewaysGrid), (nil, "slider", .row), (nil, "carousel", .row), (nil, nil, .row),
            ("inherit", "grid", .sidewaysGrid), (nil, "masonry", .row),
        ]
        for row in table {
            XCTAssertEqual(L.resolve(block: row.block, record: row.record), row.expected,
                           "block \(row.block ?? "nil"), record \(row.record ?? "nil")")
        }
    }

    private func shelf(type: String = "Collection", props: [String: Any] = [:], listLayout: String?,
                       layout: String?, contentType: String = "shows") throws -> ShelfModel {
        var record: [String: Any] = ["title": "Shows", "contentType": contentType,
                                     "shows": [F.show(), F.show("6a0000000000000000000502")],
                                     "episodes": [F.episode()], "movies": [F.movie()]]
        record["listLayout"] = listLayout
        record["layout"] = layout
        let resource = type == "Collection" ? "collection" : "collectionTeaser"
        return try F.shelf(try F.node(try F.screen(record, type: type, resource: resource, props: props)))
    }

    func testTheBlockGridIsThePagedGridWhateverTheRecordSays() throws {
        let model = try shelf(props: ["layout": "grid"], listLayout: "slider", layout: "posters")
        XCTAssertEqual(model.layout, .grid)
        XCTAssertEqual(model.cardStyle, .cards, "the paged grid keeps its landscape cards")
    }

    func testTheBlockSliderIsARowOverARecordGrid() throws {
        XCTAssertEqual(try shelf(props: ["layout": "slider"], listLayout: "grid", layout: "cards").layout, .row)
    }

    func testARecordGridIsTheSidewaysGridWithTheCardStyleLadder() throws {
        let model = try shelf(listLayout: "grid", layout: "posters")
        XCTAssertEqual(model.layout, .sidewaysGrid)
        XCTAssertEqual(model.cardStyle, .posters)
        XCTAssertEqual(try shelf(props: ["itemLayout": "cards"], listLayout: "grid", layout: "posters").cardStyle, .cards,
                       "the block `itemLayout` wins")
    }

    /// A hero or a banner row always draws as a row, never inside the sideways grid.
    func testAHeroOrBannerNeverDrawsInsideASidewaysGrid() throws {
        let hero = try shelf(listLayout: "grid", layout: "hero")
        XCTAssertEqual(hero.layout, .row)
        XCTAssertEqual(hero.cardStyle, .hero)
        let banner = try shelf(listLayout: "grid", layout: "banner")
        XCTAssertEqual(banner.layout, .row)
        XCTAssertEqual(banner.cardStyle, .banner)
        XCTAssertEqual(try shelf(props: ["itemLayout": "hero"], listLayout: "grid", layout: "cards").layout, .row)
        XCTAssertEqual(try shelf(props: ["itemLayout": "banner"], listLayout: "grid", layout: "cards").layout, .row)
    }

    func testACarouselIsARowAndHeroItemsDrawTheHero() throws {
        let hero = try shelf(listLayout: "carousel", layout: "hero")
        XCTAssertEqual(hero.layout, .row)
        XCTAssertEqual(hero.cardStyle, .hero)
        XCTAssertEqual(try shelf(listLayout: "carousel", layout: "banner").cardStyle, .banner,
                       "`banner` is the image card (ruled 2026-10-24)")
        XCTAssertEqual(try shelf(listLayout: "carousel", layout: "cards").layout, .row)
    }

    func testNoListLayoutKeepsTodaysBehavior() throws {
        XCTAssertEqual(try shelf(listLayout: nil, layout: "banner").cardStyle, .banner)
        XCTAssertEqual(try shelf(listLayout: nil, layout: "banner").layout, .row)
        XCTAssertEqual(try shelf(listLayout: nil, layout: "hero").cardStyle, .hero)
        XCTAssertEqual(try shelf(listLayout: nil, layout: "cards").layout, .row)
    }

    func testATeaserIgnoresItsBlockLayoutAndReadsTheRecord() throws {
        XCTAssertEqual(try shelf(type: "CollectionTeaser", props: ["layout": "grid"], listLayout: nil,
                                 layout: "cards").layout, .row)
        XCTAssertEqual(try shelf(type: "CollectionTeaser", props: ["layout": "slider"], listLayout: "grid",
                                 layout: "cards").layout, .sidewaysGrid)
    }

    func testAMixedSidewaysGridKeepsTheRecordCardStyle() throws {
        var record: [String: Any] = ["contentType": "mixed", "listLayout": "grid", "layout": "posters",
                                     "items": [F.typed(F.show(), "show"), F.typed(F.episode(), "episode")]]
        var model = try F.shelf(try F.node(try F.screen(record)))
        XCTAssertEqual(model.layout, .sidewaysGrid)
        XCTAssertEqual(model.cards.map(\.style), [.posters, .posters], "an item with no poster keeps the poster shape")

        record["listLayout"] = nil
        model = try F.shelf(try F.node(try F.screen(record), watchHistory: []))
        XCTAssertEqual(model.layout, .row)
    }
}

// MARK: - CollectionList

final class CollectionListBlockTests: XCTestCase {
    private typealias F = CollectionFixtures

    private func collections(_ items: [[String: Any]]) -> [String: Any] {
        ["items": items, "count": items.count]
    }

    private let shows: [String: Any] = ["_id": "6a00000000000000000c0001", "title": "Shows", "contentType": "shows",
                                        "listLayout": "slider", "layout": "posters",
                                        "shows": [CollectionFixtures.show()]]
    private let mixed: [String: Any] = ["_id": "6a00000000000000000c0002", "title": "Picks", "contentType": "mixed",
                                        "listLayout": "grid", "layout": "cards",
                                        "items": [CollectionFixtures.typed(CollectionFixtures.movie(), "movie"),
                                                  CollectionFixtures.typed(CollectionFixtures.episode(), "episode")]]
    private let movies: [String: Any] = ["_id": "6a00000000000000000c0003", "contentType": "movies",
                                         "listLayout": "carousel", "layout": "hero",
                                         "movies": [CollectionFixtures.movie()]]

    private func listNode(_ items: [[String: Any]], props: [String: Any] = [:],
                      watchHistory: [WatchProgressStore.Entry] = []) throws -> EvaluatedNode {
        try F.node(try F.screen(collections(items), type: "CollectionList", resource: "collections", props: props),
                   watchHistory: watchHistory)
    }

    func testItDrawsOneShelfPerCollectionInServedOrder() throws {
        let node = try listNode([shows, mixed, movies])

        guard case .stack(.vertical, _, _)? = node.content else { return XCTFail("a column of shelves") }
        XCTAssertEqual(node.children.map(\.id), ["c-6a00000000000000000c0001", "c-6a00000000000000000c0002",
                                                 "c-6a00000000000000000c0003"])
        let models = try node.children.map(F.shelf)
        XCTAssertEqual(models.map(\.nodeId), node.children.map(\.id), "each shelf keeps its own id")
        XCTAssertEqual(models.map(\.layout), [.row, .sidewaysGrid, .row])
        XCTAssertEqual(models.map(\.cardStyle), [.posters, .cards, .hero])
        XCTAssertEqual(models.map(\.title), ["Shows", "Picks", nil], "a hero draws only an authored title")
        XCTAssertEqual(models[1].cards.map(\.id), [F.movieId, F.episodeId])
        XCTAssertEqual(models[1].cards.first?.target, CardTarget(resourceType: "movie", itemId: F.movieId),
                       "no screen link is served: the convention opens the card")
        XCTAssertEqual(node.firstFocusNodeId, "c-6a00000000000000000c0001")
    }

    func testTheShelfIdsAreUniqueAndStable() throws {
        let first = try listNode([shows, mixed, shows]).children.map(\.id)
        XCTAssertEqual(first, ["c-6a00000000000000000c0001", "c-6a00000000000000000c0002"], "a record served twice draws once")
        XCTAssertEqual(try listNode([mixed, shows]).children.map(\.id), ["c-6a00000000000000000c0002", "c-6a00000000000000000c0001"],
                       "an id does not depend on the place")
    }

    func testTheBlockLayoutPropIsNotRead() throws {
        let node = try listNode([shows, mixed], props: ["layout": "grid"])
        XCTAssertEqual(try node.children.map(F.shelf).map(\.layout), [.row, .sidewaysGrid])
    }

    func testACollectionThatDrawsNothingIsLeftOut() throws {
        var unknown = shows
        unknown["_id"] = "6a00000000000000000c0009"
        unknown["contentType"] = "podcasts"
        let guestOff: [String: Any] = ["_id": "6a00000000000000000c0008", "contentType": "continueWatching",
                                       "showToGuests": false, "entries": [Any]()]
        let node = try listNode([unknown, shows, guestOff], watchHistory: [historyEntry("6a0000000000000000000e11", minutesAgo: 1)])
        XCTAssertEqual(node.children.map(\.id), ["c-6a00000000000000000c0001"])
    }

    func testAGuestContinueWatchingCollectionDrawsTheDeviceHistory() throws {
        let guestOn: [String: Any] = ["_id": "6a00000000000000000c0007", "contentType": "continueWatching",
                                      "showToGuests": true, "entries": [Any]()]
        let node = try listNode([guestOn, shows], watchHistory: [historyEntry("6a0000000000000000000e11", minutesAgo: 1)])
        let model = try F.shelf(try XCTUnwrap(node.children.first))
        XCTAssertEqual(model.title, ChromeText.string(.keepWatching))
        XCTAssertEqual(model.cards.map(\.title), ["Watched 6a0000000000000000000e11"])
    }

    /// A record the server keeps (it has items) whose items are all of an unknown type has no card
    /// to draw. The list leaves it out, as the server and the web leave out an empty Collection. A
    /// plain `Collection` keeps its empty message (`testAMixedRecordWithNothingToDrawSaysSo`).
    func testAMixedRecordOfOnlyUnknownTypesIsLeftOutOfTheList() throws {
        let unknownOnly: [String: Any] = ["_id": "6a00000000000000000c0010", "title": "Picks", "contentType": "mixed",
                                          "items": [CollectionFixtures.typed(CollectionFixtures.show(), "album")]]
        let node = try listNode([unknownOnly, shows])
        XCTAssertEqual(node.children.map(\.id), ["c-6a00000000000000000c0001"])
        XCTAssertNil(try listNode([unknownOnly]).content, "no shelf left: the block draws nothing")
    }

    func testNoCollectionsDrawsNothing() throws {
        XCTAssertNil(try listNode([]).content)
        XCTAssertTrue(try listNode([]).children.isEmpty)
        let missing = try F.node(try F.screen(NSNull(), type: "CollectionList", resource: "collections"))
        XCTAssertNil(missing.content)
    }

    func testItIsARegistryKey() {
        XCTAssertTrue(BlockRegistry.keys.contains("CollectionList"))
        XCTAssertEqual(BlockKey(resolvedName: "CollectionList"), .collectionList)
    }
}

// MARK: - Mixed paging

@MainActor
final class MixedCollectionPagingTests: XCTestCase {
    private typealias F = CollectionFixtures
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

    private func json(_ object: Any) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func page(_ items: [[String: Any]], hasMore: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "nodeId": "list", "page": 2, "hasMore": hasMore,
            "resources": ["collection": ["items": items, "count": 40]],
        ])
    }

    /// Page 2 appends to `items`, the list a `mixed` record keeps, and writes no `count`.
    func testTheMergeAppendsToTheMixedItems() throws {
        let record: [String: Any] = ["title": "Picks", "contentType": "mixed", "itemsCount": 3,
                                     "items": [F.typed(F.episode(), "episode")]]
        let base: [String: [String: JSONValue]] = ["list": ["collection": try json(record)]]
        var list = try XCTUnwrap(PagedList(paging: BlockPaging(page: 1, hasMore: true), key: .collection))
        list.append(try ContractDecoder.blockPage(try page([F.typed(F.episode(), "episode"), F.typed(F.show(), "show"),
                                                            F.typed(F.movie(), "movie")], hasMore: false)),
                    base: base["list"]?["collection"])

        let merged = try XCTUnwrap(PagedList.merge(base, lists: ["list": list])["list"]?["collection"])
        XCTAssertEqual(merged["items"].array.map { $0["id"].string ?? $0["_id"].string }, [F.episodeId, F.showId, F.movieId],
                       "a record already on page 1 is not added twice")
        XCTAssertEqual(merged["itemsCount"].int, 3)
        XCTAssertFalse(merged.hasKey("count"))
        XCTAssertEqual(merged["title"].string, "Picks")
    }

    func testAMixedGridPagesThroughTheStore() async throws {
        let record: [String: Any] = ["title": "Picks", "contentType": "mixed", "itemsCount": 3,
                                     "items": [F.typed(F.episode(), "episode")]]
        let screen: [String: Any] = [
            "id": screenId, "kind": "static",
            "blockResources": ["list": ["resources": ["collection": record], "paging": ["page": 1, "hasMore": true]]],
            "content": [
                "ROOT": ["type": ["resolvedName": "Root"], "nodes": ["list"]],
                "list": ["type": ["resolvedName": "Collection"], "props": ["layout": "grid"],
                         "custom": ["type": "plugin", "resources": ["collection"]], "parent": "ROOT", "nodes": [String]()],
            ],
        ]
        let config = TestConfig.staging
        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
        StubProtocol.queue = [.init(status: 200, body: try JSONSerialization.data(withJSONObject: screen))]
        await store.loadScreen(id: screenId, param: nil)
        let key = store.key(for: screenId, param: nil)
        StubProtocol.queue = [.init(status: 200, body: try page([F.typed(F.show(), "show"), F.typed(F.movie(), "movie")],
                                                                 hasMore: false))]
        await store.loadNextPage(key: key, nodeId: "list")

        let loaded = try XCTUnwrap(store.screenEntry(id: screenId, param: nil)?.screen)
        let root = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId, document: loaded.content,
            context: TestRender.context(blockResources: store.blockResources(for: key))
        ))
        guard case let .shelf(model) = try XCTUnwrap(root.first { $0.id == "list" }).content else {
            return XCTFail("the Collection draws a shelf")
        }
        XCTAssertEqual(model.layout, .grid)
        XCTAssertEqual(model.cards.map(\.id), [F.episodeId, F.showId, F.movieId])
        XCTAssertEqual(store.pagedLists[key]?["list"]?.hasMore, false)
    }
}

// cspell:ignore Bibelkompass Finde Glauben iqedd Orientierung Sendung
import SwiftUI
import XCTest
@testable import HopeTViOS

/// Shelf card shapes.
///
/// A shelf knows its card shape separately from its arrangement. The ruled precedence is
/// the block prop `itemLayout` when set, else the Collection record's `layout`, else
/// `cards`. `banner` is a row of image-only 16:9 cards and `hero` the hero (ruled 2026-10-24).
/// Browse is a fixed grid and takes no layout prop.
final class ShelfLayoutTests: XCTestCase {

    private let showId = "61975ddad9c6988364002f3f"

    /// One `CollectionTeaser` with the given block props and Collection record layout.
    private func screen(itemLayout: String? = nil, recordLayout: String? = nil, images: String? = nil) throws -> AppScreen {
        let props = itemLayout.map { "\"itemLayout\": \"\($0)\"" } ?? ""
        let layout = recordLayout.map { "\"layout\": \"\($0)\"," } ?? ""
        let art = images ?? #"{ "default": { "containerId": "c1", "name": "d.jpg" } }"#

        return try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "hero": {
              "resources": {
                "collectionTeaser": {
                  "title": "Featured Shows",
                  \(layout)
                  "contentType": "shows",
                  "shows": [{ "_id": "\(showId)", "title": "Table Talk", "episodeCount": 26, "images": \(art) }]
                }
              }
            }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["hero"] },
            "hero": {
              "type": { "resolvedName": "CollectionTeaser" },
              "props": { \(props) },
              "custom": { "type": "plugin", "resources": ["collectionTeaser"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
    }

    /// Two shows on one teaser: the first carries the given `images`, the second carries
    /// only a default slot.
    private func mixedScreen(itemLayout: String, firstImages: String) throws -> AppScreen {
        try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "hero": {
              "resources": {
                "collectionTeaser": {
                  "title": "Featured Shows",
                  "contentType": "shows",
                  "shows": [
                    { "_id": "\(showId)", "title": "With poster", "images": \(firstImages) },
                    { "_id": "61975e24d9c698836400305c", "title": "No poster",
                      "images": { "default": { "containerId": "c1", "name": "wide.jpg" } } }
                  ]
                }
              }
            }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["hero"] },
            "hero": {
              "type": { "resolvedName": "CollectionTeaser" },
              "props": { "itemLayout": "\(itemLayout)" },
              "custom": { "type": "plugin", "resources": ["collectionTeaser"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
    }

    private func shelf(_ screen: AppScreen) throws -> ShelfModel {
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources)
        ))
        let teaser = try XCTUnwrap(node.first { $0.key == .collectionTeaser })
        guard case let .shelf(model) = teaser.content else {
            throw XCTSkip("CollectionTeaser drew nothing")
        }
        return model
    }

    // MARK: - One test per layout value

    func testCardsDrawsTheLandscapeShelf() throws {
        let model = try shelf(try screen(itemLayout: "cards"))

        XCTAssertEqual(model.cardStyle, .cards)
        XCTAssertEqual(model.layout, .row, "the card shape never changes the arrangement")
    }

    func testPostersDrawsThePortraitShelf() throws {
        XCTAssertEqual(try shelf(try screen(itemLayout: "posters")).cardStyle, .posters)
    }

    /// Ruled 2026-10-24: `banner` is a row of image-only cards. No hero parts, the shelf title
    /// as on a cards row, and the art from the `banner` slot at the hero's CDN width (1920 px).
    func testBannerDrawsARowOfImageCards() throws {
        let images = """
        {
          "default": { "containerId": "c1", "name": "default.jpg" },
          "banner": { "containerId": "c1", "name": "banner.jpg" }
        }
        """
        let model = try shelf(try screen(itemLayout: "banner", images: images))

        XCTAssertEqual(model.cardStyle, .banner)
        XCTAssertEqual(model.layout, .row)
        XCTAssertEqual(model.title, "Featured Shows")
        let card = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(card.style, .banner)
        XCTAssertNil(card.hero, "a banner card draws no hero")
        XCTAssertEqual(card.imageURL?.absoluteString.contains("banner.jpg"), true)
        XCTAssertEqual(card.imageURL?.absoluteString.contains("/w:1920/"), true)
        XCTAssertEqual(card.accessibilityLabel(shape: .banner), "Table Talk, 26 episodes")
        XCTAssertEqual(card.accessibilityLabel(shape: .wide), "Table Talk", "a captioned card reads its title")
    }

    /// A banner card opens the same target as a cards card: only the draw differs.
    func testABannerCardSelectsTheSameTargetAsACardsCard() throws {
        let banner = try shelf(try screen(itemLayout: "banner")).cards.map(\.target)
        let cards = try shelf(try screen(itemLayout: "cards")).cards.map(\.target)
        let hero = try shelf(try screen(itemLayout: "hero")).cards.map(\.target)

        XCTAssertFalse(banner.isEmpty)
        XCTAssertNotNil(banner.first ?? nil)
        XCTAssertEqual(banner, cards)
        XCTAssertEqual(banner, hero)
    }

    func testHeroDrawsTheHeroShelf() throws {
        let model = try shelf(try screen(itemLayout: "hero"))

        XCTAssertEqual(model.cardStyle, .hero)
        XCTAssertEqual(model.cards.first?.style, .hero)
        XCTAssertNotNil(model.cards.first?.hero)
        XCTAssertEqual(model.cards.first?.imageURL?.absoluteString.contains("/w:1920/"), true)
    }

    /// The raw values map one to one. An unknown value reads as unset.
    func testTheCardStyleMapping() {
        typealias S = ShelfModel.CardStyle
        XCTAssertEqual(S.resolve(prop: "banner", record: nil), .banner)
        XCTAssertEqual(S.resolve(prop: "hero", record: nil), .hero)
        XCTAssertEqual(S.resolve(prop: "cards", record: nil), .cards)
        XCTAssertEqual(S.resolve(prop: "posters", record: nil), .posters)
        XCTAssertEqual(S.resolve(prop: "carousel", record: nil), .cards)
        XCTAssertEqual(S.resolve(prop: nil, record: nil), .cards)
        XCTAssertEqual(S.resolve(prop: "Banner", record: "hero"), .hero, "the match is exact")
    }

    /// A banner card without a subtitle reads its title only.
    func testABannerCardWithoutASubtitleReadsItsTitle() {
        let card = CardModel(id: "1", title: "Encounters", subtitle: nil, imageURL: nil, blurhash: nil,
                             badge: nil, progress: nil)
        XCTAssertEqual(card.accessibilityLabel(shape: .banner), "Encounters")
    }

    // MARK: - Precedence

    func testThePropBeatsTheRecord() throws {
        XCTAssertEqual(try shelf(try screen(itemLayout: "cards", recordLayout: "banner")).cardStyle, .cards)
        XCTAssertEqual(try shelf(try screen(itemLayout: "posters", recordLayout: "banner")).cardStyle, .posters)
        XCTAssertEqual(try shelf(try screen(itemLayout: "banner", recordLayout: "hero")).cardStyle, .banner)
        XCTAssertEqual(try shelf(try screen(itemLayout: "hero", recordLayout: "banner")).cardStyle, .hero)
    }

    func testTheRecordBeatsTheDefault() throws {
        XCTAssertEqual(try shelf(try screen(recordLayout: "posters")).cardStyle, .posters)
        XCTAssertEqual(try shelf(try screen(recordLayout: "banner")).cardStyle, .banner)
        XCTAssertEqual(try shelf(try screen(recordLayout: "hero")).cardStyle, .hero)
    }

    func testNeitherSideSetDrawsCards() throws {
        XCTAssertEqual(try shelf(try screen()).cardStyle, .cards)
    }

    /// A value neither side recognizes reads as unset, so it falls through the same ladder.
    func testAnUnknownValueFallsThroughToTheNextSource() throws {
        XCTAssertEqual(try shelf(try screen(itemLayout: "carousel", recordLayout: "posters")).cardStyle, .posters)
        XCTAssertEqual(try shelf(try screen(itemLayout: "carousel")).cardStyle, .cards)
    }

    /// The staging Home screen, as captured 2026-09-20: the hero teaser carries no `itemLayout`
    /// prop any more (the author set it to "Inherit from collection"), so its record's `banner`
    /// wins: since 2026-10-24 that is the row of image cards, not the hero. The `latest`
    /// Collection has no prop either, so its record's `posters` wins. Until that capture the
    /// hero prop said `cards` and beat the record — the ladder is pinned by the synthetic tests
    /// above; this one pins the real data.
    func testTheHomeFixtureResolvesBothShelvesFromItsOwnData() throws {
        let result = try TestRender.screen("home")
        let styles = shelves(in: result.node)

        XCTAssertEqual(styles["hero"], .banner, "no prop, so the record's \"banner\" wins")
        XCTAssertEqual(styles["latest"], .posters, "no prop, so the record's \"posters\" wins")
    }

    private func shelves(in node: EvaluatedNode) -> [String: ShelfModel.CardStyle] {
        var found: [String: ShelfModel.CardStyle] = [:]
        if case let .shelf(model) = node.content { found[model.nodeId] = model.cardStyle }
        for child in node.children {
            found.merge(shelves(in: child)) { current, _ in current }
        }
        return found
    }

    // MARK: - Images

    func testAPostersShelfTakesThePosterSlotFirst() throws {
        let images = """
        {
          "default": { "containerId": "c1", "name": "default.jpg" },
          "banner": { "containerId": "c1", "name": "banner.jpg" },
          "poster": { "containerId": "c1", "name": "poster.jpg" }
        }
        """
        let posters = try shelf(try screen(itemLayout: "posters", images: images))
        let cards = try shelf(try screen(itemLayout: "cards", images: images))
        let banner = try shelf(try screen(itemLayout: "banner", images: images))
        let hero = try shelf(try screen(itemLayout: "hero", images: images))

        XCTAssertEqual(posters.cards.first?.imageURL?.absoluteString.contains("poster.jpg"), true)
        // A landscape card takes the main image; only a banner card and the hero take the banner art.
        XCTAssertEqual(cards.cards.first?.imageURL?.absoluteString.contains("default.jpg"), true)
        XCTAssertEqual(banner.cards.first?.imageURL?.absoluteString.contains("banner.jpg"), true)
        XCTAssertEqual(hero.cards.first?.imageURL?.absoluteString.contains("banner.jpg"), true)
    }

    /// Only `default` is always authored, so every shape lands there when nothing else is.
    func testEveryShapeFallsBackToTheDefaultSlot() throws {
        for value in ["cards", "posters", "banner", "hero"] {
            let model = try shelf(try screen(itemLayout: value))
            XCTAssertEqual(model.cards.first?.imageURL?.absoluteString.contains("d.jpg"), true, value)
        }
    }

    // MARK: - Per-item posters fallback

    /// Ruled 2026-10-26: a posters shelf draws a portrait card for every item. An item with no
    /// poster art keeps the portrait frame and is flagged, so the card draws its wide image
    /// aspect-fit over a blurred copy instead of cropping it.
    func testAPostersShelfKeepsThePosterShapeForAnItemWithoutPosterArt() throws {
        let images = """
        {
          "default": { "containerId": "c1", "name": "default.jpg" },
          "poster": { "containerId": "c1", "name": "poster.jpg" }
        }
        """
        let model = try shelf(try mixedScreen(itemLayout: "posters", firstImages: images))

        XCTAssertEqual(model.cardStyle, .posters, "the shelf still asked for posters")
        XCTAssertEqual(model.cards.map(\.style), [.posters, .posters])
        XCTAssertEqual(model.cards.map(\.artIsFallback), [false, true])
        XCTAssertEqual(model.cards[0].imageURL?.absoluteString.contains("poster.jpg"), true)
        // The poster-less item keeps the wide artwork it does have.
        XCTAssertEqual(model.cards[1].imageURL?.absoluteString.contains("wide.jpg"), true)
    }

    func testAPostersShelfWithNoPostersAtAllDrawsEveryCardAsAPoster() throws {
        let noPoster = #"{ "default": { "containerId": "c1", "name": "default.jpg" } }"#
        let model = try shelf(try mixedScreen(itemLayout: "posters", firstImages: noPoster))

        XCTAssertEqual(model.cards.map(\.style), [.posters, .posters])
        XCTAssertEqual(model.cards.map(\.artIsFallback), [true, true])
    }

    /// The flag judges a non-poster slot by its dimensions: portrait art fills the frame.
    func testAPosterCardFillsWithPortraitArtFromAnotherSlot() throws {
        let portrait = #"{ "default": { "containerId": "c1", "name": "tall.jpg", "width": 1000, "height": 1400 } }"#
        let model = try shelf(try mixedScreen(itemLayout: "posters", firstImages: portrait))

        XCTAssertEqual(model.cards.first?.style, .posters)
        XCTAssertEqual(model.cards.first?.artIsFallback, false)
    }

    /// The other two shapes are per shelf, not per item: they never change shape.
    func testCardsAndBannerShelvesKeepOneShapeForEveryItem() throws {
        let noPoster = #"{ "default": { "containerId": "c1", "name": "default.jpg" } }"#

        XCTAssertEqual(try shelf(try mixedScreen(itemLayout: "cards", firstImages: noPoster)).cards.map(\.style),
                       [.cards, .cards])
        XCTAssertEqual(try shelf(try mixedScreen(itemLayout: "banner", firstImages: noPoster)).cards.map(\.style),
                       [.banner, .banner])
        XCTAssertEqual(try shelf(try mixedScreen(itemLayout: "hero", firstImages: noPoster)).cards.map(\.style),
                       [.hero, .hero])
    }

    // MARK: - Per-item banner fallback

    /// Ruled (awe#4951): a banner or hero shelf keeps its 16:9 frame for every item, and an item
    /// with no `images.banner` is flagged so the card draws its 16:9 art aspect-fit over a blurred
    /// copy instead of cropping it. An item with banner art (no dimensions) is trusted.
    func testABannerShelfFlagsAnItemWithoutBannerArt() throws {
        let images = """
        {
          "default": { "containerId": "c1", "name": "default.jpg" },
          "banner": { "containerId": "c1", "name": "banner.jpg" }
        }
        """
        for (value, style) in [("banner", ShelfModel.CardStyle.banner), ("hero", .hero)] {
            let model = try shelf(try mixedScreen(itemLayout: value, firstImages: images))

            XCTAssertEqual(model.cards.map(\.style), [style, style], "the frame never changes")
            XCTAssertEqual(model.cards.map(\.artIsFallback), [false, true], value)
            XCTAssertEqual(model.cards[0].imageURL?.absoluteString.contains("banner.jpg"), true, value)
            XCTAssertEqual(model.cards[1].imageURL?.absoluteString.contains("wide.jpg"), true, value)
        }
    }

    /// The flag judges by dimensions when the file carries them. The hero frame is 16:9 (ruled
    /// 2026-09-28), so a 16:9 file fills it (Encounters on staging, 1761x990, and the production
    /// 3840x2160 banners); art more than 15% taller or wider than 16:9 is flagged.
    func testABannerCardJudgesItsArtByDimensions() throws {
        func images(_ slot: String, _ width: Int, _ height: Int) -> String {
            #"{ "\#(slot)": { "containerId": "c1", "name": "art.jpg", "width": \#(width), "height": \#(height) } }"#
        }
        for value in ["banner", "hero"] {
            func flagged(_ json: String) throws -> Bool? {
                try shelf(try screen(itemLayout: value, images: json)).cards.first?.artIsFallback
            }

            XCTAssertEqual(try flagged(images("banner", 1761, 990)), false, "16:9 fills the frame")
            XCTAssertEqual(try flagged(images("banner", 3840, 2160)), false, value)
            XCTAssertEqual(try flagged(images("default", 2489, 1400)), false, "a 16:9 default fills it too")
            XCTAssertEqual(try flagged(images("banner", 3000, 1000)), true, "3:1 would lose its sides")
            XCTAssertEqual(try flagged(images("default", 2880, 3840)), true, "portrait art is fitted")
            XCTAssertEqual(try flagged(images("default", 3000, 3000)), true, "square art is fitted")
        }
    }

    /// The staging `hero` teaser, as captured 2026-09-23: five shows serve `banner: null` and a
    /// 16:9 `default`; Encounters carries a 16:9 `banner`. Its record says `banner`, so it draws
    /// banner cards (ruled 2026-10-24), and every one fills the 16:9 frame.
    func testTheHomeFixtureFillsEveryBannerCard() throws {
        let result = try TestRender.screen("home")
        let hero = try XCTUnwrap(shelfModels(in: result.node)["hero"])

        XCTAssertEqual(hero.cards.map(\.style), Array(repeating: .banner, count: 6))
        XCTAssertEqual(hero.cards.map(\.artIsFallback), Array(repeating: false, count: 6))
        XCTAssertTrue(hero.cards.allSatisfy { $0.hero == nil })
    }

    private func shelfModels(in node: EvaluatedNode) -> [String: ShelfModel] {
        var found: [String: ShelfModel] = [:]
        if case let .shelf(model) = node.content { found[model.nodeId] = model }
        for child in node.children {
            found.merge(shelfModels(in: child)) { current, _ in current }
        }
        return found
    }

    /// A landscape card is never flagged: it crops its art (posters, banner and hero are covered above).
    func testALandscapeCardIsNeverFlaggedAsFallback() throws {
        let noBanner = #"{ "default": { "containerId": "c1", "name": "default.jpg" } }"#

        XCTAssertEqual(try shelf(try mixedScreen(itemLayout: "cards", firstImages: noBanner)).cards.map(\.artIsFallback),
                       [false, false])
    }

    /// An episode carries a flat `image` and may carry an `images` map too. A banner card
    /// wants the wide `banner` slot first; a landscape card keeps the episode's own image.
    func testABannerShelfTakesTheBannerSlotBeforeTheEpisodeImage() throws {
        func episodeShelf(itemLayout: String) throws -> ShelfModel {
            let screen = try ContractDecoder.screen(Data("""
            {
              "id": "s3",
              "kind": "static",
              "blockResources": {
                "hero": {
                  "resources": {
                    "collectionTeaser": {
                      "contentType": "episodes",
                      "episodes": [{
                        "_id": "6a049248c6d68f1e30573243",
                        "title": "A Bear Remembers",
                        "image": { "containerId": "c1", "name": "flat.jpg" },
                        "images": { "banner": { "containerId": "c1", "name": "banner.jpg" } }
                      }]
                    }
                  }
                }
              },
              "content": {
                "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["hero"] },
                "hero": {
                  "type": { "resolvedName": "CollectionTeaser" },
                  "props": { "itemLayout": "\(itemLayout)" },
                  "custom": { "type": "plugin", "resources": ["collectionTeaser"] },
                  "parent": "ROOT", "nodes": []
                }
              }
            }
            """.utf8))
            return try shelf(screen)
        }

        let banner = try episodeShelf(itemLayout: "banner")
        XCTAssertEqual(banner.cards.first?.style, .banner)
        XCTAssertEqual(banner.cards.first?.imageURL?.absoluteString.contains("banner.jpg"), true)

        let hero = try episodeShelf(itemLayout: "hero")
        XCTAssertEqual(hero.cards.first?.style, .hero)
        XCTAssertEqual(hero.cards.first?.imageURL?.absoluteString.contains("banner.jpg"), true)

        let cards = try episodeShelf(itemLayout: "cards")
        XCTAssertEqual(cards.cards.first?.imageURL?.absoluteString.contains("flat.jpg"), true)
    }

    // MARK: - Caption

    func testTheEpisodeCountReadsAsOneEpisodeWhenThereIsOne() throws {
        let one = try shelf(try screen(itemLayout: "cards", images: nil))
        XCTAssertEqual(one.cards.first?.subtitle, "26 episodes")

        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "hero": {
              "resources": {
                "collectionTeaser": {
                  "contentType": "shows",
                  "shows": [{ "_id": "\(showId)", "title": "Encounters", "episodeCount": 1 }]
                }
              }
            }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["hero"] },
            "hero": {
              "type": { "resolvedName": "CollectionTeaser" },
              "props": {}, "custom": { "type": "plugin", "resources": ["collectionTeaser"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        XCTAssertEqual(try shelf(screen).cards.first?.subtitle, "1 episode")
    }

    // MARK: - Geometry

    /// The hero art keeps the 1920 pt request width (ContractKit reads it). Its layout is taller
    /// than wide, as the website, with a cap for large phones.
    func testTheHeroIsTallerThanWideWithACap() {
        XCTAssertEqual(CardShape.hero.shelfWidth, 1920)
        XCTAssertEqual(CardShape.hero.artAspect, 9.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(CardShape.hero.shelfHeight, 1080, accuracy: 0.5)
        XCTAssertEqual(Layout.heroHeight(width: 393), 432.3, accuracy: 0.01)
        XCTAssertEqual(Layout.heroHeight(width: 500), 520)
    }

    /// A banner card is 16:9 and image only, as wide as the screen between the margins.
    func testABannerCardIsSixteenByNineBetweenTheMargins() {
        XCTAssertEqual(CardShape.banner.shelfWidth, Layout.phoneWidth - 2 * Layout.screenMargin)
        XCTAssertEqual(CardShape.banner.shelfHeight, CardShape.banner.shelfWidth * 9 / 16, accuracy: 0.5)
        XCTAssertEqual(CardShape.banner.captionHeight, 0)
    }

    /// A poster card is image only, so VoiceOver gets its subtitle, as on a banner card.
    func testOnlyAWideCardHasACaption() {
        XCTAssertGreaterThan(CardShape.wide.captionHeight, 0)
        XCTAssertEqual(CardShape.poster.captionHeight, 0)
    }

    // MARK: - Collection grid (awe#5982)

    /// One `Collection` (or `CollectionTeaser`) with the given `layout` block prop. The record
    /// has two shows with poster and banner art, or none when `empty`.
    private func layoutShelf(
        block: String = "Collection",
        layout: String?,
        recordLayout: String? = nil,
        title: String? = "Category",
        empty: Bool = false
    ) throws -> ShelfModel {
        let resource = block == "Collection" ? "collection" : "collectionTeaser"
        let props = layout.map { "\"layout\": \"\($0)\"" } ?? ""
        let fields = [
            title.map { "\"title\": \"\($0)\"" },
            recordLayout.map { "\"layout\": \"\($0)\"" },
        ].compactMap { $0 }.map { $0 + "," }.joined()
        let art = #"""
        { "default": { "containerId": "c1", "name": "d.jpg" },
          "poster": { "containerId": "c1", "name": "p.jpg" },
          "banner": { "containerId": "c1", "name": "b.jpg" } }
        """#
        let shows = empty ? "" : """
        { "_id": "\(showId)", "title": "Table Talk", "images": \(art) },
        { "_id": "61975e24d9c698836400305c", "title": "Bible Study", "images": \(art) }
        """
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "list": { "resources": { "\(resource)": { \(fields) "contentType": "shows", "shows": [\(shows)] } } }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["list"] },
            "list": {
              "type": { "resolvedName": "\(block)" },
              "props": { \(props) },
              "custom": { "type": "plugin", "resources": ["\(resource)"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources)
        ))
        let list = try XCTUnwrap(node.first { $0.id == "list" })
        var model: ShelfModel?
        if case let .shelf(shelf) = list.content { model = shelf }
        return try XCTUnwrap(model, "\(block) drew no shelf")
    }

    /// A shows grid draws landscape cards only (D3); a movies grid draws posters (awe#7033). The
    /// record's posters, banner or hero do not apply, so a hero record never takes the hero path.
    func testAGridCollectionDrawsLandscapeCardsWhateverTheRecordSays() throws {
        for record in [nil, "cards", "posters", "banner", "hero"] {
            let model = try layoutShelf(layout: "grid", recordLayout: record)

            XCTAssertEqual(model.layout, .grid, "record \(record ?? "absent")")
            XCTAssertEqual(model.cardStyle, .cards, "record \(record ?? "absent")")
            XCTAssertEqual(model.cards.map(\.style), [.cards, .cards], "record \(record ?? "absent")")
            XCTAssertTrue(model.cards.allSatisfy { $0.hero == nil }, "record \(record ?? "absent")")
        }
    }

    /// The empty state keeps the grid, and a grid with no authored title draws the fallback:
    /// it is a cards shelf, not a hero.
    func testAnEmptyGridCollectionKeepsTheGridAndTheTitleRules() throws {
        let empty = try layoutShelf(layout: "grid", recordLayout: "hero", empty: true)
        XCTAssertEqual(empty.layout, .grid)
        XCTAssertEqual(empty.cardStyle, .cards)
        XCTAssertEqual(empty.emptyMessage, ChromeText.string(.nothingToWatch))

        let untitled = try layoutShelf(layout: "grid", recordLayout: "hero", title: nil)
        XCTAssertEqual(untitled.title, ChromeText.string(.collection))
    }

    /// Absent, `slider` or an unknown value draws today's row with the ladder's card style.
    func testACollectionWithoutGridDrawsTheRow() throws {
        for layout in [nil, "slider", "carousel", "Grid"] {
            let posters = try layoutShelf(layout: layout, recordLayout: "posters")
            XCTAssertEqual(posters.layout, .row, "layout \(layout ?? "absent")")
            XCTAssertEqual(posters.cardStyle, .posters, "layout \(layout ?? "absent")")

            let banner = try layoutShelf(layout: layout, recordLayout: "banner", title: nil)
            XCTAssertEqual(banner.layout, .row, "layout \(layout ?? "absent")")
            XCTAssertEqual(banner.cardStyle, .banner, "layout \(layout ?? "absent")")
            XCTAssertEqual(banner.title, ChromeText.string(.collection), "a banner row takes the fallback title")

            let hero = try layoutShelf(layout: layout, recordLayout: "hero", title: nil)
            XCTAssertEqual(hero.layout, .row, "layout \(layout ?? "absent")")
            XCTAssertEqual(hero.cardStyle, .hero, "layout \(layout ?? "absent")")
            XCTAssertNil(hero.title, "a hero still draws no fallback title")
        }
    }

    /// `CollectionTeaser` has its own web `layout` prop, which tvOS still ignores.
    func testACollectionTeaserIgnoresAGridLayout() throws {
        let model = try layoutShelf(block: "CollectionTeaser", layout: "grid", recordLayout: "posters")

        XCTAssertEqual(model.layout, .row)
        XCTAssertEqual(model.cardStyle, .posters)
    }

    // MARK: - Browse

    /// Ruled: Browse stays a fixed grid of landscape cards, whatever an author sets on it.
    func testShowListIgnoresAnItemLayoutProp() throws {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s2",
          "kind": "static",
          "blockResources": {
            "grid": { "resources": { "shows": { "items": [{ "_id": "\(showId)", "title": "Table Talk" }], "count": 1 } } }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["grid"] },
            "grid": {
              "type": { "resolvedName": "ShowList" },
              "props": { "itemLayout": "posters", "layout": "banner" },
              "custom": { "type": "plugin", "resources": ["shows"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources)
        ))
        let grid = try XCTUnwrap(node.first { $0.key == .showList })

        guard case let .shelf(model) = grid.content else { return XCTFail("ShowList drew nothing") }
        XCTAssertEqual(model.layout, .grid)
        XCTAssertEqual(model.cardStyle, .cards)
    }
}

/// `ShowDetail`'s subtitle line.
///
/// The Frontend API serves `showDetail.subtitle` from this same branch; staging does not
/// carry it yet, so the shape is asserted from a hand-built payload.
final class ShowDetailSubtitleTests: XCTestCase {

    private func detail(_ fields: String) throws -> ShowDetailModel {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "template",
          "blockResources": { "detail": { "resources": { "showDetail": { "title": "Celebration of Hope"\(fields) } } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["detail"] },
            "detail": {
              "type": { "resolvedName": "ShowDetail" },
              "props": {}, "custom": { "type": "plugin", "resources": ["showDetail"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources)
        ))
        let block = try XCTUnwrap(node.first { $0.key == .showDetail })
        guard case let .detail(model) = block.content else { throw XCTSkip("ShowDetail drew nothing") }
        return model
    }

    func testTheSubtitleIsCarriedWhenItIsServed() throws {
        XCTAssertEqual(try detail(#", "subtitle": "Weekly from Silver Spring""#).subtitle, "Weekly from Silver Spring")
    }

    func testAnAbsentOrEmptySubtitleDrawsNoLine() throws {
        XCTAssertNil(try detail("").subtitle)
        XCTAssertNil(try detail(#", "subtitle": null"#).subtitle)
        XCTAssertNil(try detail(#", "subtitle": "  ""#).subtitle, "blank text is nothing to draw, not an empty line")
    }

    /// The staging Show template does not serve one yet.
    func testTheShowFixtureHasNoSubtitle() throws {
        let result = try TestRender.screen("show")
        let block = try XCTUnwrap(result.node.first { $0.key == .showDetail })

        guard case let .detail(model) = block.content else { return XCTFail("ShowDetail drew nothing") }
        XCTAssertNil(model.subtitle)
    }
}

/// The full-screen hero of a `hero` shelf (ruled 2026-09-28; `banner` drew it until 2026-10-24):
/// logo or title, abstract, a meta line, the categories, "Watch now" (the card target) and
/// "Trailer" only when playable.
final class HeroModelTests: XCTestCase {

    private let showId = "698b02ede9885270958aac85"

    /// One hero `CollectionTeaser` with one item; `item` is the JSON of the show fields.
    private func hero(_ item: String, contentType: String = "shows", itemLayout: String = "hero") throws -> CardModel {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "hero": { "resources": { "collectionTeaser": { "contentType": "\(contentType)", "\(contentType)": [\(item)] } } }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["hero"] },
            "hero": {
              "type": { "resolvedName": "CollectionTeaser" },
              "props": { "itemLayout": "\(itemLayout)" },
              "custom": { "type": "plugin", "resources": ["collectionTeaser"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources)
        ))
        guard case let .shelf(model) = try XCTUnwrap(node.first { $0.key == .collectionTeaser }).content else {
            throw XCTSkip("CollectionTeaser drew nothing")
        }
        return try XCTUnwrap(model.cards.first)
    }

    private let logo = #"{ "containerId": "c1", "name": "logo.png", "width": 2619, "height": 259 }"#
    private let banner = #"{ "containerId": "c1", "name": "banner.png", "width": 3840, "height": 2160 }"#

    private var bibelkompass: String {
        """
        {
          "_id": "\(showId)", "title": "Bibelkompass",
          "abstract": "Finde Orientierung in der Bibel.",
          "images": { "banner": \(banner), "logo": \(logo) },
          "categories": ["Bibel", "Glauben"],
          "seasonCount": 10, "episodeCount": 17,
          "trailer": { "provider": "jetstream", "videoId": "jsv:QBvi99xy28Q" },
          "screenLink": { "linkType": "screen", "screen": "6ab6e46133822e754aa61388", "screenParam": "\(showId)" }
        }
        """
    }

    func testAShowWithALogoDrawsTheLogoAndEveryPart() throws {
        let card = try hero(bibelkompass)
        let hero = try XCTUnwrap(card.hero)

        XCTAssertEqual(hero.logoURL?.absoluteString.contains("logo.png"), true)
        XCTAssertEqual(try XCTUnwrap(hero.logoAspect), 259.0 / 2619.0, accuracy: 0.0001)
        XCTAssertEqual(hero.abstract, "Finde Orientierung in der Bibel.")
        XCTAssertEqual(hero.meta, "10 seasons • 17 episodes")
        XCTAssertEqual(hero.categories, ["Bibel", "Glauben"])
        XCTAssertEqual(card.imageURL?.absoluteString.contains("banner.png"), true)
        XCTAssertFalse(card.artIsFallback)
    }

    /// "Watch now" is the card press: the served link first, as a card does today.
    func testWatchNowIsTheCardTarget() throws {
        let card = try hero(bibelkompass)

        XCTAssertEqual(card.target?.resourceType, "show")
        XCTAssertEqual(card.target?.itemId, showId)
        XCTAssertEqual(card.target?.link?.screenId, "6ab6e46133822e754aa61388")
    }

    /// No logo: the view draws the title text. No seasons: the meta line names episodes only.
    func testAShowWithoutALogoOrSeasonsDrawsTheTitleAndTheEpisodeCount() throws {
        let card = try hero(#"{ "_id": "\#(showId)", "title": "Ja Jesus", "seasonCount": 0, "episodeCount": 18 }"#)
        let hero = try XCTUnwrap(card.hero)

        XCTAssertNil(hero.logoURL)
        XCTAssertEqual(card.title, "Ja Jesus")
        XCTAssertEqual(hero.meta, "18 episodes")
        XCTAssertEqual(hero.categories, [])
        XCTAssertNil(hero.abstract)
    }

    func testTheMetaLineUsesTheOneForms() throws {
        let hero = try XCTUnwrap(try hero(#"{ "_id": "\#(showId)", "title": "T", "seasonCount": 1, "episodeCount": 1 }"#).hero)
        XCTAssertEqual(hero.meta, "1 season • 1 episode")
        XCTAssertNil(try XCTUnwrap(try self.hero(#"{ "_id": "\#(showId)", "title": "T" }"#).hero).meta)
    }

    /// Trailer draws only when it resolves playable: Jetstream VOD yes, YouTube and live no.
    /// A trailer never writes watch progress.
    func testTheTrailerIsOfferedOnlyWhenItCanPlay() throws {
        let playable = try XCTUnwrap(try hero(bibelkompass).hero?.trailer)
        XCTAssertEqual(playable.url.absoluteString, "https://jstre.am/videos/jsv:QBvi99xy28Q/hls/main.m3u8")
        XCTAssertFalse(playable.recordsProgress)
        XCTAssertEqual(playable.title, "Bibelkompass")

        for trailer in [
            #"{ "provider": "youtube", "videoId": "8iqedd6gPRc" }"#,
            #"{ "provider": "jetstream-live", "videoId": "jsl:abc" }"#,
            #"{ "provider": "jetstream" }"#,
            "null",
        ] {
            let card = try hero(#"{ "_id": "\#(showId)", "title": "T", "trailer": \#(trailer) }"#)
            XCTAssertNil(card.hero?.trailer, trailer)
        }
    }

    /// Art that is not 16:9 keeps the blurred-backdrop fit: banner, then default, then poster.
    func testTheArtFallsBackThroughBannerDefaultPoster() throws {
        let poster = #"{ "containerId": "c1", "name": "poster.png", "width": 2880, "height": 3840 }"#
        let card = try hero(#"{ "_id": "\#(showId)", "title": "T", "images": { "poster": \#(poster) } }"#)

        XCTAssertEqual(card.imageURL?.absoluteString.contains("poster.png"), true)
        XCTAssertTrue(card.artIsFallback)
    }

    /// An episode in a hero shelf draws the same hero with its own fields.
    func testAnEpisodeDrawsTheHeroWithItsOwnFields() throws {
        let card = try hero("""
        { "_id": "6a049248c6d68f1e30573243", "title": "A Bear Remembers", "abstract": "About bears.", "duration": 1203,
          "image": { "containerId": "c1", "name": "flat.jpg" }, "show": { "_id": "s1", "title": "_Test Show" } }
        """, contentType: "episodes")
        let hero = try XCTUnwrap(card.hero)

        XCTAssertNil(hero.logoURL)
        XCTAssertEqual(hero.abstract, "About bears.")
        // No `showDuration` prop: no duration (awe#6055, `CollectionShowDurationTests`).
        XCTAssertEqual(hero.meta, "_Test Show")
        XCTAssertEqual(hero.categories, [])
        XCTAssertNil(hero.trailer)
        XCTAssertEqual(card.target?.resourceType, "episode")
    }

    /// Only a hero reads these parts: a landscape card and a banner card carry none.
    func testOnlyAHeroCardCarriesAHero() throws {
        XCTAssertNil(try hero(bibelkompass, itemLayout: "banner").hero, "a banner card is image only")

        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1", "kind": "static",
          "blockResources": { "row": { "resources": { "collectionTeaser": { "contentType": "shows", "shows": [\(bibelkompass)] } } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["row"] },
            "row": { "type": { "resolvedName": "CollectionTeaser" }, "props": { "itemLayout": "cards" },
                     "custom": { "type": "plugin", "resources": ["collectionTeaser"] }, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: screen.blockResources)))
        guard case let .shelf(model) = try XCTUnwrap(node.first { $0.key == .collectionTeaser }).content else {
            return XCTFail("CollectionTeaser drew nothing")
        }
        XCTAssertNil(model.cards.first?.hero)
    }

    /// A hero leads its screen only when it is the first thing the screen draws. A leading banner
    /// row is a normal row: it never bleeds to the stage top.
    func testTheLeadingHeroIsTheFirstDrawnBlock() throws {
        XCTAssertEqual(try leadingHeroId(itemLayout: "hero"), "hero")
        XCTAssertNil(try leadingHeroId(itemLayout: "banner"), "a banner row is not a hero")
        XCTAssertNil(try leadingHeroId(itemLayout: "cards"))

        // The staging Home teaser leads its screen, but its record says `banner`.
        XCTAssertNil(try TestRender.screen("home").node.leadingHeroId)
        XCTAssertNil(try TestRender.screen("show").node.leadingHeroId)
    }

    private func leadingHeroId(itemLayout: String) throws -> String? {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1", "kind": "static",
          "blockResources": { "hero": { "resources": { "collectionTeaser": { "contentType": "shows", "shows": [\(bibelkompass)] } } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["hero"] },
            "hero": { "type": { "resolvedName": "CollectionTeaser" }, "props": { "itemLayout": "\(itemLayout)" },
                      "custom": { "type": "plugin", "resources": ["collectionTeaser"] }, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: screen.blockResources)))
        XCTAssertEqual(node.firstFocusNodeId, "hero", "the first card or button takes the default focus")
        return node.leadingHeroId
    }
}

/// `ShowDetail` honors its props (ruled 2026-09-28), with the builder's defaults: `showTitle`,
/// `showBody`, `showImage` on; `showAbstract`, `showTrailer` off. A non-empty `title` prop is a
/// section heading. Nothing to draw renders null.
final class ShowDetailPropsTests: XCTestCase {

    private func evaluate(props: String, detail: String) throws -> EvaluatedNode {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "template",
          "blockResources": { "detail": { "resources": { "showDetail": \(detail) } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["detail"] },
            "detail": {
              "type": { "resolvedName": "ShowDetail" },
              "props": \(props), "custom": { "type": "plugin", "resources": ["showDetail"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: screen.blockResources)))
        return try XCTUnwrap(node.first { $0.key == .showDetail })
    }

    private func model(props: String, detail: String? = nil) throws -> ShowDetailModel {
        guard case let .detail(model) = try evaluate(props: props, detail: detail ?? self.detail).content else {
            XCTFail("ShowDetail drew nothing")
            throw CancellationError()
        }
        return model
    }

    private let detail = """
    {
      "_id": "698b02ede9885270958aac85", "title": "Bibelkompass", "abstract": "Finde Orientierung.",
      "body": { "type": "doc", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Body" }] }] },
      "images": {
        "default": { "containerId": "c1", "name": "default.png" },
        "banner": { "containerId": "c1", "name": "banner.png" }
      },
      "trailer": { "provider": "jetstream", "videoId": "jsv:QBvi99xy28Q" }
    }
    """

    func testAbsentPropsDrawTheBuilderDefaults() throws {
        let model = try model(props: "{}")

        XCTAssertEqual(model.title, "Bibelkompass")
        XCTAssertNil(model.abstract, "showAbstract defaults to off")
        XCTAssertEqual(model.paragraphs, ["Body"])
        XCTAssertNotNil(model.imageURL)
        XCTAssertNil(model.trailer, "showTrailer defaults to off")
        XCTAssertNil(model.heading)
    }

    /// The show's main image (`images.default`) comes first, as the web block draws it.
    func testTheImageIsTheDefaultSlotFirst() throws {
        XCTAssertEqual(try model(props: "{}").imageURL?.absoluteString.contains("default.png"), true)

        let noDefault = detail.replacingOccurrences(of: #""default": { "containerId": "c1", "name": "default.png" },"#, with: "")
        XCTAssertEqual(try model(props: "{}", detail: noDefault).imageURL?.absoluteString.contains("banner.png"), true,
                       "then the slot ladder")
    }

    func testShowTrailerDrawsWatchTrailerOnlyWhenPlayable() throws {
        let trailer = try XCTUnwrap(try model(props: #"{ "showTrailer": true }"#).trailer)
        XCTAssertEqual(trailer.url.absoluteString, "https://jstre.am/videos/jsv:QBvi99xy28Q/hls/main.m3u8")
        XCTAssertFalse(trailer.recordsProgress)

        let youtube = detail.replacingOccurrences(of: #""provider": "jetstream", "videoId": "jsv:QBvi99xy28Q""#,
                                                  with: #""provider": "youtube", "videoId": "8iqedd6gPRc""#)
        XCTAssertNil(try model(props: #"{ "showTrailer": true }"#, detail: youtube).trailer)
    }

    /// The production Show screen, as captured 2026-09-28: the first block draws image, title,
    /// abstract and trailer; the second is "Über die Sendung" with the body only.
    func testTheTwoProductionShowDetailsDrawTheirOwnParts() throws {
        let first = try model(props: #"{ "title": "", "showAbstract": true, "showBody": false, "showImage": true, "showTitle": true, "showTrailer": true }"#)
        XCTAssertNil(first.heading)
        XCTAssertEqual(first.title, "Bibelkompass")
        XCTAssertEqual(first.abstract, "Finde Orientierung.")
        XCTAssertEqual(first.paragraphs, [])
        XCTAssertNotNil(first.imageURL)
        XCTAssertNotNil(first.trailer)

        let about = try model(props: #"{ "title": "Über die Sendung", "showAbstract": false, "showBody": true, "showImage": false, "showTitle": false, "showTrailer": false }"#)
        XCTAssertEqual(about.heading, "Über die Sendung")
        XCTAssertNil(about.title)
        XCTAssertNil(about.abstract)
        XCTAssertEqual(about.paragraphs, ["Body"])
        XCTAssertNil(about.imageURL)
        XCTAssertNil(about.blurhash)
        XCTAssertNil(about.trailer)
    }

    func testNothingToDrawRendersNull() throws {
        let block = try evaluate(
            props: #"{ "title": "Heading only", "showAbstract": false, "showBody": false, "showImage": false, "showTitle": false, "showTrailer": false }"#,
            detail: detail
        )
        XCTAssertNil(block.content, "a heading alone is not content, as on the web")
    }

    // MARK: Age rating (awe#6867)

    private func rated(_ ratings: String) -> String {
        detail.replacingOccurrences(of: #""title": "Bibelkompass","#, with: #""title": "Bibelkompass", "ageRatings": "# + ratings + ",")
    }

    /// The primary (first) rating draws as a badge beside the title.
    func testThePrimaryRatingDrawsWithTheTitle() throws {
        let ratings = #"[{ "system": "classind", "value": "14", "descriptors": ["violence"] }, { "system": "fsk", "value": "16" }]"#
        XCTAssertEqual(try model(props: "{}", detail: rated(ratings)).ageRating, "ClassInd 14")
    }

    /// No value draws nothing, and a block that hides the title (the body-only "Über die
    /// Sendung" instance) draws no second badge.
    func testNoRatingOrNoTitleDrawsNoBadge() throws {
        XCTAssertNil(try model(props: "{}").ageRating, "a server that serves no field")
        XCTAssertNil(try model(props: "{}", detail: rated("[]")).ageRating)
        XCTAssertNil(try model(props: "{}", detail: rated(#"[{ "system": "custom", "label": " " }]"#)).ageRating)
        XCTAssertNil(try model(props: #"{ "showTitle": false }"#, detail: rated(#"[{ "system": "fsk", "value": "12" }]"#)).ageRating)
    }
}

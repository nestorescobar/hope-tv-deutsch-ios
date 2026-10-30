import XCTest
@testable import HopeTViOS

/// `showDuration` on `Collection` and `CollectionTeaser` (awe#6055).
///
/// The duration draws only when the block prop is `true`, in every card style and in the
/// hero's meta line. Off, absent or not a bool draws none. The show name stays.
final class CollectionShowDurationTests: XCTestCase {

    /// The values that must draw no duration: `false`, absent, and a string that is not a bool.
    private let offProps = [#""showDuration": false"#, "", #""showDuration": "true""#]

    /// One `block` serving one episodes record with one episode of 1203 s, evaluated to its shelf.
    private func shelf(block: String, props: [String]) throws -> ShelfModel {
        let resource = block == "Collection" ? "collection" : "collectionTeaser"
        let art = #"""
        { "default": { "containerId": "c1", "name": "d.jpg" },
          "poster": { "containerId": "c1", "name": "p.jpg" },
          "banner": { "containerId": "c1", "name": "b.jpg", "width": 3840, "height": 2160 } }
        """#
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "list": { "resources": { "\(resource)": { "title": "Latest", "contentType": "episodes", "episodes": [
              { "_id": "6a049248c6d68f1e30573243", "title": "A Bear Remembers", "duration": 1203, "images": \(art),
                "show": { "_id": "s1", "title": "_Test Show" } }
            ] } } }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["list"] },
            "list": {
              "type": { "resolvedName": "\(block)" },
              "props": { \(props.filter { !$0.isEmpty }.joined(separator: ", ")) },
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
        guard case let .shelf(model) = try XCTUnwrap(node.first { $0.id == "list" }).content else {
            throw XCTSkip("\(block) drew no shelf")
        }
        return model
    }

    private func subtitle(block: String, props: [String]) throws -> String? {
        try XCTUnwrap(try shelf(block: block, props: props).cards.first).subtitle
    }

    func testACollectionRowDrawsTheDurationOnlyWithShowDuration() throws {
        XCTAssertEqual(try subtitle(block: "Collection", props: [#""showDuration": true"#]), "_Test Show · 20m")
        for off in offProps {
            XCTAssertEqual(try subtitle(block: "Collection", props: [off]), "_Test Show", off)
        }
    }

    func testACollectionGridDrawsTheDurationOnlyWithShowDuration() throws {
        let grid = #""layout": "grid""#
        XCTAssertEqual(try shelf(block: "Collection", props: [grid]).layout, .grid)
        XCTAssertEqual(try subtitle(block: "Collection", props: [grid, #""showDuration": true"#]), "_Test Show · 20m")
        for off in offProps {
            XCTAssertEqual(try subtitle(block: "Collection", props: [grid, off]), "_Test Show", off)
        }
    }

    /// A banner card draws no text, but its subtitle is its spoken label, so the same rule holds.
    func testACollectionTeaserCardsPostersAndBannerDrawTheDurationOnlyWithShowDuration() throws {
        for style in ["cards", "posters", "banner"] {
            let itemLayout = #""itemLayout": "\#(style)""#
            let cardStyle = try shelf(block: "CollectionTeaser", props: [itemLayout]).cardStyle
            XCTAssertEqual("\(cardStyle)", style)
            XCTAssertEqual(try subtitle(block: "CollectionTeaser", props: [itemLayout, #""showDuration": true"#]),
                           "_Test Show · 20m", style)
            for off in offProps {
                XCTAssertEqual(try subtitle(block: "CollectionTeaser", props: [itemLayout, off]), "_Test Show", "\(style) \(off)")
            }
        }
    }

    func testAHeroMetaDrawsTheDurationOnlyWithShowDuration() throws {
        let hero = #""itemLayout": "hero""#
        let on = try XCTUnwrap(try shelf(block: "CollectionTeaser", props: [hero, #""showDuration": true"#]).cards.first)
        XCTAssertEqual(on.hero?.meta, "_Test Show • 20m")
        for off in offProps {
            let card = try XCTUnwrap(try shelf(block: "CollectionTeaser", props: [hero, off]).cards.first)
            XCTAssertEqual(card.hero?.meta, "_Test Show", off)
        }
    }
}

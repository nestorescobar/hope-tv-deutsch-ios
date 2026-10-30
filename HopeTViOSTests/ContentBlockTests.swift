// cspell:ignore magnifyingglass
import XCTest
@testable import HopeTViOS

/// The static content blocks of the `tv` design (awe#6116): `Divider`, `Badge`, `Header` and
/// `RichText`. Each test builds the model through `BlockRegistry.evaluate` from Craft node props.
final class ContentBlockTests: XCTestCase {

    /// Evaluates a Root whose children are `blocks` (id, key, props JSON), in order.
    private func evaluate(_ blocks: [(id: String, key: String, props: String)]) throws -> EvaluatedNode {
        let nodes = blocks.map { block in
            #""\#(block.id)": { "type": { "resolvedName": "\#(block.key)" }, "props": \#(block.props), "parent": "ROOT", "nodes": [] }"#
        }
        let ids = blocks.map { #""\#($0.id)""# }.joined(separator: ", ")
        let document = try TestDocument.make("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": [\(ids)] },
          \(nodes.joined(separator: ",\n"))
        }
        """)
        return try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: document, context: TestRender.context()))
    }

    /// The content of one block with `props`.
    private func content(_ key: String, _ props: String) throws -> BlockContent? {
        try XCTUnwrap(evaluate([("blk", key, props)]).first { $0.id == "blk" }).content
    }

    // MARK: - Divider

    private func divider(_ props: String) throws -> DividerModel? {
        guard case let .divider(model)? = try content("Divider", props) else { return nil }
        return model
    }

    func testADividerDrawsTheThicknessOfItsHeightKey() throws {
        XCTAssertEqual(try divider(#"{ "height": { "xs": "xs" } }"#)?.thickness, 1)
        XCTAssertEqual(try divider(#"{ "height": { "xs": "sm" } }"#)?.thickness, 2)
        XCTAssertEqual(try divider(#"{ "height": { "xs": "md" }, "color": "primary-500" }"#)?.thickness, 4)
        // A plain string is the same key, not a responsive map.
        XCTAssertEqual(try divider(#"{ "height": "lg" }"#)?.thickness, 8)
    }

    /// The web and mobile rule: nothing until a height resolves, so an unset divider stays
    /// invisible. `none` is a zero line, so it draws nothing too.
    func testADividerWithNoUsableHeightDrawsNothing() throws {
        XCTAssertNil(try content("Divider", "{}"))
        XCTAssertNil(try content("Divider", #"{ "height": { "xs": null } }"#))
        XCTAssertNil(try content("Divider", #"{ "height": { "xs": "none" } }"#))
        XCTAssertNil(try content("Divider", #"{ "height": { "xs": "huge" } }"#))
        XCTAssertNil(try content("Divider", #"{ "height": 4 }"#))
    }

    /// A responsive map collapses to its lowest set breakpoint, so a null `xs` falls through.
    func testADividerHeightFallsThroughToTheLowestSetBreakpoint() throws {
        XCTAssertEqual(try divider(#"{ "height": { "xs": null, "md": "sm", "xl": "lg" } }"#)?.thickness, 2)
        XCTAssertEqual(try divider(#"{ "height": { "sm": "lg" } }"#)?.thickness, 8)
    }

    func testADividerTakesNoFocus() throws {
        let node = try evaluate([("line", "Divider", #"{ "height": { "xs": "md" } }"#)])
        XCTAssertNil(node.firstFocusStop)
    }

    // MARK: - Badge

    private func badge(_ props: String) throws -> BadgeModel? {
        guard case let .badge(model)? = try content("Badge", props) else { return nil }
        return model
    }

    func testABadgeDrawsItsLabel() throws {
        let model = try XCTUnwrap(badge(#"{ "label": "New", "tone": "neutral", "variant": "filled", "size": "md" }"#))
        XCTAssertEqual(model, BadgeModel(label: "New", symbol: nil))
    }

    /// The `tv` design's icon list maps to SF Symbols. A bare name and its `classic/regular/`
    /// Icon Key are the same icon. An icon with no symbol draws the label alone.
    func testABadgeIconMapsToASymbol() throws {
        // The bare name is the regular (outline) icon; only the solid Icon Key is filled.
        XCTAssertEqual(try badge(#"{ "label": "Live", "icon": "play" }"#)?.symbol, "play")
        XCTAssertEqual(try badge(#"{ "label": "Live", "icon": "classic/solid/play" }"#)?.symbol, "play.fill")
        XCTAssertEqual(try badge(#"{ "label": "Live", "icon": "classic/solid/pause" }"#)?.symbol, "pause.fill")
        XCTAssertEqual(try badge(#"{ "label": "Web", "icon": "classic/regular/globe" }"#)?.symbol, "globe")
        XCTAssertEqual(try badge(#"{ "label": "Find", "icon": "magnifying-glass" }"#)?.symbol, "magnifyingglass")
        XCTAssertEqual(try badge(#"{ "label": "Rocket", "icon": "rocket" }"#), BadgeModel(label: "Rocket", symbol: nil))
        XCTAssertNil(try badge(#"{ "label": "Odd", "icon": "constructor" }"#)?.symbol)
    }

    func testABadgeWithNoLabelDrawsNothing() throws {
        XCTAssertNil(try content("Badge", "{}"))
        XCTAssertNil(try content("Badge", #"{ "label": "" }"#))
        XCTAssertNil(try content("Badge", #"{ "label": "   ", "icon": "play" }"#))
    }

    /// The D-pad cannot reach a badge, so its `screen` link is ignored: it draws a label and takes
    /// no focus.
    func testABadgeIgnoresItsLinkAndTakesNoFocus() throws {
        let node = try evaluate([
            ("chip", "Badge", #"{ "label": "New", "linkType": "screen", "screen": "s2", "screenParam": "p" }"#),
        ])
        guard case let .badge(model)? = node.first(where: { $0.id == "chip" })?.content else {
            return XCTFail("Badge drew no badge")
        }
        XCTAssertEqual(model, BadgeModel(label: "New", symbol: nil))
        XCTAssertNil(node.firstFocusStop)
    }

    // MARK: - Header

    private func header(_ props: String) throws -> HeaderModel? {
        guard case let .header(model)? = try content("Header", props) else { return nil }
        return model
    }

    func testAHeaderDrawsItsText() throws {
        let model = try XCTUnwrap(header(#"{ "kicker": "Hope TV", "title": "Neu", "subtitle": "This week" }"#))
        XCTAssertEqual(model, HeaderModel(kicker: "Hope TV", title: "Neu", level: 1, subtitle: "This week", link: nil))
    }

    /// `as` offers h1–h3. Unset or anything else draws at h1, the editor's own default.
    func testAHeaderTitleLevelFollowsAs() throws {
        XCTAssertEqual(try header(#"{ "title": "T", "as": "h2" }"#)?.level, 2)
        XCTAssertEqual(try header(#"{ "title": "T", "as": "h3" }"#)?.level, 3)
        XCTAssertEqual(try header(#"{ "title": "T", "as": "h5" }"#)?.level, 1)
        XCTAssertEqual(try header(#"{ "title": "T" }"#)?.level, 1)
    }

    func testAHeaderWithNoTextDrawsNothing() throws {
        XCTAssertNil(try content("Header", #"{ "title": "" }"#))
        XCTAssertNil(try content("Header", #"{ "title": " ", "subtitle": "", "kicker": null }"#))
        // A link alone is no header.
        XCTAssertNil(try content("Header", #"{ "linkType": "screen", "screen": "s2", "linkLabel": "More" }"#))
    }

    /// A `screen` link with a label is the Button's link: same model, same press, and the header
    /// is a focus stop that asks for the default focus.
    func testAHeaderScreenLinkIsAFocusableButton() throws {
        let node = try evaluate([
            ("line", "Divider", #"{ "height": { "xs": "md" } }"#),
            ("head", "Header", #"{ "title": "Neu", "linkType": "screen", "screen": "s2", "screenParam": "p1", "linkLabel": "Alle" }"#),
        ])
        guard case let .header(model)? = node.first(where: { $0.id == "head" })?.content else {
            return XCTFail("Header drew no header")
        }
        XCTAssertEqual(model.link, ButtonModel(label: "Alle", screenId: "s2", screenParam: "p1", linkType: "screen", disabled: false))
        XCTAssertEqual(node.firstFocusNodeId, "head")
    }

    /// The linked header asks for the default focus (`.asks`), as a Button does.
    func testALinkedHeaderAsksForTheDefaultFocus() throws {
        let node = try evaluate([("head", "Header", #"{ "title": "Neu", "linkType": "screen", "screen": "s2", "linkLabel": "Alle" }"#)])
        XCTAssertEqual(node.firstFocusStop, .asks("head"))
    }

    /// Only a `screen` link with a target and a label draws the link row. A tv Header gets
    /// `linkType: "screen"` as soon as it is created (awe#6113), so the type alone is no link.
    func testAHeaderWithoutANavigableScreenLinkTakesNoFocus() throws {
        let cases = [
            #"{ "title": "T", "linkType": "screen", "linkLabel": "Alle" }"#,
            #"{ "title": "T", "linkType": "screen", "screen": "", "linkLabel": "Alle" }"#,
            #"{ "title": "T", "linkType": "screen", "screen": "s2" }"#,
            #"{ "title": "T", "linkType": "url", "link": "https://example.org", "linkLabel": "Alle" }"#,
            #"{ "title": "T", "screen": "s2", "linkLabel": "Alle" }"#,
        ]
        for props in cases {
            let node = try evaluate([("head", "Header", props)])
            guard case let .header(model)? = node.first(where: { $0.id == "head" })?.content else {
                return XCTFail("Header drew no header for \(props)")
            }
            XCTAssertNil(model.link, props)
            XCTAssertNil(node.firstFocusStop, props)
        }
    }

    // MARK: - RichText

    private func richText(_ doc: String) throws -> RichTextModel? {
        guard case let .richText(model)? = try content("RichText", #"{ "doc": \#(doc) }"#) else { return nil }
        return model
    }

    private typealias Run = RichTextModel.Run

    func testRichTextReadsTheTiptapBlocks() throws {
        let model = try XCTUnwrap(richText("""
        { "type": "doc", "content": [
          { "type": "heading", "attrs": { "level": 2 }, "content": [{ "type": "text", "text": "Title" }] },
          { "type": "paragraph", "content": [
            { "type": "text", "text": "Plain " },
            { "type": "text", "text": "bold", "marks": [{ "type": "bold" }] },
            { "type": "hardBreak" },
            { "type": "text", "text": "all", "marks": [{ "type": "italic" }, { "type": "underline" }, { "type": "strike" }] }
          ] },
          { "type": "bulletList", "content": [
            { "type": "listItem", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "One" }] }] },
            { "type": "listItem", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Two" }] }] }
          ] },
          { "type": "orderedList", "attrs": { "start": 3 }, "content": [
            { "type": "listItem", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Three" }] }] }
          ] },
          { "type": "blockquote", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Quote" }] }] },
          { "type": "horizontalRule" }
        ] }
        """))

        XCTAssertEqual(model.blocks, [
            .heading(level: 2, [Run(text: "Title")]),
            .paragraph([
                Run(text: "Plain "),
                Run(text: "bold", marks: [.bold]),
                Run(text: "\n"),
                Run(text: "all", marks: [.italic, .underline, .strike]),
            ]),
            .list(ordered: false, start: 1, items: [[.paragraph([Run(text: "One")])], [.paragraph([Run(text: "Two")])]]),
            .list(ordered: true, start: 3, items: [[.paragraph([Run(text: "Three")])]]),
            .quote([.paragraph([Run(text: "Quote")])]),
            .rule,
        ])
        XCTAssertEqual(model.plainText, "Title\nPlain bold\nall\n• One\n• Two\n3. Three\nQuote")
    }

    /// tvOS opens no URLs: a link draws as its plain text, with no mark.
    func testRichTextDrawsALinkAsPlainText() throws {
        let model = try XCTUnwrap(richText("""
        { "type": "doc", "content": [{ "type": "paragraph", "content": [
          { "type": "text", "text": "Visit " },
          { "type": "text", "text": "our site", "marks": [{ "type": "link", "attrs": { "href": "https://example.org" } }] }
        ] }] }
        """))
        XCTAssertEqual(model.blocks, [.paragraph([Run(text: "Visit "), Run(text: "our site")])])
    }

    /// An unknown block node is skipped, as on mobile. An unknown inline node adds no text.
    func testRichTextSkipsUnknownNodes() throws {
        let model = try XCTUnwrap(richText("""
        { "type": "doc", "content": [
          { "type": "table", "content": [{ "type": "tableRow", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "cell" }] }] }] },
          { "type": "paragraph", "content": [{ "type": "text", "text": "Kept" }, { "type": "footnoteReference", "attrs": { "id": "f1" } }] },
          { "type": "heading", "attrs": { "level": 9 }, "content": [{ "type": "text", "text": "Deep" }] }
        ] }
        """))
        XCTAssertEqual(model.blocks, [
            .paragraph([Run(text: "Kept")]),
            .heading(level: 6, [Run(text: "Deep")]),
        ])
    }

    /// The mobile `isRichTextDocEmpty` rule: no doc, no content, or only blank text draws nothing.
    /// A blank paragraph between others is dropped, not drawn as a gap.
    func testAnEmptyRichTextDrawsNothing() throws {
        XCTAssertNil(try content("RichText", "{}"))
        XCTAssertNil(try richText("null"))
        XCTAssertNil(try richText(#""text""#))
        XCTAssertNil(try richText(#"{ "type": "doc" }"#))
        XCTAssertNil(try richText(#"{ "type": "doc", "content": [{ "type": "paragraph" }] }"#))
        XCTAssertNil(try richText(#"{ "type": "doc", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "  " }, { "type": "hardBreak" }] }] }"#))
        XCTAssertNil(try richText(#"{ "type": "doc", "content": [{ "type": "bulletList", "content": [{ "type": "listItem", "content": [] }] }] }"#))
        XCTAssertNil(try richText(#"{ "type": "doc", "content": [{ "type": "horizontalRule" }] }"#))

        let gap = try XCTUnwrap(richText("""
        { "type": "doc", "content": [
          { "type": "paragraph", "content": [{ "type": "text", "text": "A" }] },
          { "type": "paragraph" },
          { "type": "paragraph", "content": [{ "type": "text", "text": "B" }] }
        ] }
        """))
        XCTAssertEqual(gap.blocks, [.paragraph([Run(text: "A")]), .paragraph([Run(text: "B")])])
    }

    /// Lists and quotes nest. Past the depth cap the rest is not drawn, and nothing crashes.
    func testRichTextNestingIsBounded() throws {
        var node = #"{ "type": "paragraph", "content": [{ "type": "text", "text": "deep" }] }"#
        for _ in 0..<40 {
            node = #"{ "type": "blockquote", "content": [\#(node)] }"#
        }
        XCTAssertNil(try richText(#"{ "type": "doc", "content": [\#(node)] }"#))

        let nested = try XCTUnwrap(richText(#"{ "type": "doc", "content": [{ "type": "blockquote", "content": [{ "type": "blockquote", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "two" }] }] }] }] }"#))
        XCTAssertEqual(nested.blocks, [.quote([.quote([.paragraph([Run(text: "two")])])])])
    }

    /// The cap is exact: a paragraph inside `maxDepth - 1` quotes draws, one inside `maxDepth` does not.
    func testRichTextNestingCapIsExact() throws {
        func quoted(_ levels: Int) -> String {
            var node = #"{ "type": "paragraph", "content": [{ "type": "text", "text": "deep" }] }"#
            for _ in 0..<levels {
                node = #"{ "type": "blockquote", "content": [\#(node)] }"#
            }
            return #"{ "type": "doc", "content": [\#(node)] }"#
        }
        XCTAssertNotNil(try richText(quoted(RichTextReader.maxDepth - 1)))
        XCTAssertNil(try richText(quoted(RichTextReader.maxDepth)))
    }

    /// A number out of `Int` range reads as absent, never a trap. A pasted
    /// `<ol start="99999999999999999999">` is stored and served as 1e20.
    func testRichTextSurvivesOutOfRangeNumbers() throws {
        let model = try XCTUnwrap(richText("""
        { "type": "doc", "content": [
          { "type": "heading", "attrs": { "level": 1e20 }, "content": [{ "type": "text", "text": "Big" }] },
          { "type": "orderedList", "attrs": { "start": 1e20 }, "content": [
            { "type": "listItem", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "A" }] }] }
          ] },
          { "type": "orderedList", "attrs": { "start": 9e18 }, "content": [
            { "type": "listItem", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "B" }] }] },
            { "type": "listItem", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "C" }] }] }
          ] },
          { "type": "orderedList", "attrs": { "start": -5 }, "content": [
            { "type": "listItem", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "D" }] }] }
          ] }
        ] }
        """))
        XCTAssertEqual(model.blocks, [
            .heading(level: 1, [Run(text: "Big")]),
            .list(ordered: true, start: 1, items: [[.paragraph([Run(text: "A")])]]),
            // In range for `Int`, but `start + index` would overflow: clamped.
            .list(ordered: true, start: RichTextReader.maxListStart,
                  items: [[.paragraph([Run(text: "B")])], [.paragraph([Run(text: "C")])]]),
            .list(ordered: true, start: 0, items: [[.paragraph([Run(text: "D")])]]),
        ])
        XCTAssertEqual(model.plainText, "Big\n1. A\n1000000. B\n1000001. C\n0. D")
    }

    /// Prose is one reading stop, like `ShowMeta`: it takes focus but cannot ask, so a screen that
    /// opens on it lets tvOS choose.
    func testRichTextIsAReadingStop() throws {
        let node = try evaluate([
            ("prose", "RichText", #"{ "doc": { "type": "doc", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Read me" }] }] } }"#),
            ("go", "Button", #"{ "label": "Go", "linkType": "screen", "screen": "s2" }"#),
        ])
        XCTAssertEqual(node.firstFocusStop, .readsOnly)
        XCTAssertNil(node.firstFocusNodeId)
    }
}

/// `JSONValue.int` truncates toward zero, and a number out of `Int` range reads as absent. A plain
/// `Int(Double)` traps on 1e20, and author content can serve one.
final class JSONValueIntTests: XCTestCase {

    func testIntTruncatesAndRefusesOutOfRangeNumbers() {
        XCTAssertEqual(JSONValue.number(2.9).int, 2)
        XCTAssertEqual(JSONValue.number(-2.9).int, -2)
        XCTAssertEqual(JSONValue.number(42).int, 42)
        XCTAssertNil(JSONValue.number(1e20).int)
        XCTAssertNil(JSONValue.number(-1e20).int)
        XCTAssertNil(JSONValue.number(.infinity).int)
        XCTAssertNil(JSONValue.number(.nan).int)
        XCTAssertNil(JSONValue.string("3").int)
    }
}

import SwiftUI
import XCTest
@testable import HopeTViOS

/// Layout styling on `Section`, `Container` and `Box` (awe#6297), read as `apps/mobile`
/// `blocks/styles.ts` and `preset/units.ts` read it. One reader serves the three blocks, because
/// mobile's Section and Container render its Box. A value the reader cannot map is not drawn.
final class LayoutStyleTests: XCTestCase {

    private static let preset = JSONValue.object([
        "colors": .object(["primary": .object(["500": .string("#2f557f")])]),
    ])

    /// One block of `type` under ROOT, with `props` and one text child, evaluated.
    private func evaluate(_ type: String, props: String) throws -> EvaluatedNode {
        let root = try evaluateTree("""
        "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["blk"] },
        "blk": { "type": { "resolvedName": "\(type)" }, "props": { \(props) }, "parent": "ROOT", "nodes": ["txt"] },
        "txt": { "type": { "resolvedName": "SimpleText" }, "props": { "text": "Hello" }, "parent": "blk", "nodes": [] }
        """)
        return try XCTUnwrap(root.first { $0.id == "blk" })
    }

    private func evaluateTree(_ nodes: String) throws -> EvaluatedNode {
        let screen = try ContractDecoder.screen(Data("""
        { "id": "s1", "kind": "static", "content": { \(nodes) } }
        """.utf8))
        return try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: RenderContext(
                images: ImageConfig(cdn: "https://images.test", bucket: "bucket"),
                colors: PresetColorResolver(preset: Self.preset)
            )
        ))
    }

    private func style(_ type: String = "Section", props: String) throws -> LayoutStyle {
        guard case let .stack(_, _, style) = try evaluate(type, props: props).content else {
            XCTFail("\(type) is not a layout block")
            return LayoutStyle()
        }
        return style
    }

    // MARK: - Padding

    /// Mobile `paddingStyle`: an alias, else a scale step × 4 pt; `px` is 1 pt.
    func testPaddingReadsAliasesAndScaleSteps() throws {
        for type in ["Section", "Container", "Box"] {
            let padding = try style(type, props: #""padding": { "top": "4", "right": "md", "bottom": "px", "left": { "xs": "2xs" } }"#).padding
            XCTAssertEqual(padding, LayoutStyle.Insets(top: 16, right: 16, bottom: 1, left: 2), type)
        }
        let aliases: [String: CGFloat] = [
            "zero": 0, "none": 0, "pixel": 1, "2xs": 2, "xs": 4, "sm": 8, "md": 16, "lg": 32, "xl": 64,
            "2xl": 96, "3xl": 128, "0.5": 2, "12": 48, "32": 128,
        ]
        for (alias, points) in aliases {
            XCTAssertEqual(try style(props: #""padding": { "top": "\#(alias)" }"#).padding.top, points, alias)
        }
        // A bare number is a scale step too, as mobile `toScaleDp` reads it.
        XCTAssertEqual(try style(props: #""padding": { "top": 3 }"#).padding.top, 12)
    }

    func testPaddingThatDoesNotMapIsNotDrawn() throws {
        for value in [#""4px""#, #""1rem""#, #""-2""#, #""huge""#, "{}", "null", #""""#, "true"] {
            XCTAssertEqual(try style(props: #""padding": { "top": \#(value) }"#).padding, LayoutStyle.Insets(), value)
        }
        XCTAssertEqual(try style(props: #""padding": {}"#).padding, LayoutStyle.Insets())
        XCTAssertEqual(try style(props: #""padding": "md""#).padding, LayoutStyle.Insets())
    }

    // MARK: - Heights

    /// px and unitless are points, rem is 16, vw and vh are a share of the 1920 x 1080 stage.
    func testMinHeightReadsALength() throws {
        let lengths: [String: CGFloat?] = [
            #""300px""#: 300, #""300""#: 300, "300": 300, #""10rem""#: 160, #""10REM""#: 160, #"" 2.5rem ""#: 40,
            #""25vw""#: 480, #""50vh""#: 540, #""0vh""#: 0, #""0%""#: 0, #"{ "xs": "200px" }"#: 200,
            #"{ "xs": null, "md": "7rem" }"#: 112,
            // Not drawn: a parent share, a font-relative unit, an expression, a negative, nothing.
            #""50%""#: nil, #""1.5em""#: nil, #""calc(1rem + 2px)""#: nil, #""-10px""#: nil, #""""#: nil,
            "{}": nil, "null": nil, #""tall""#: nil, #""99pt""#: nil,
        ]
        for (value, points) in lengths {
            XCTAssertEqual(try style(props: #""minHeight": \#(value)"#).minHeight, points, value)
        }
        XCTAssertEqual(try style("Box", props: #""minHeight": "120px""#).minHeight, 120)
    }

    /// `AWECustomHeight { value, unit }`: `px` and `rem` join the value, `none` leaves it bare.
    func testBoxHeightReadsTheCustomHeight() throws {
        let heights: [String: CGFloat?] = [
            #"{ "value": 300, "unit": "px" }"#: 300,
            #"{ "value": "20", "unit": "rem" }"#: 320,
            #"{ "value": 250, "unit": "none" }"#: 250,
            #"{ "value": "250" }"#: 250,
            #"{ "value": { "xs": 120 }, "unit": "px" }"#: 120,
            #"{ "unit": "px" }"#: nil,
            #"{ "value": "abc", "unit": "px" }"#: nil,
            #"{ "value": "20px", "unit": "px" }"#: nil,
            "{}": nil,
            #""300px""#: nil,
        ]
        for (value, points) in heights {
            XCTAssertEqual(try style("Box", props: #""height": \#(value)"#).height, points, value)
        }
    }

    // MARK: - Flex

    func testAlignReadsTheFiveKeywords() throws {
        let aligns: [String: LayoutStyle.Align] = [
            "start": .start, "center": .center, "end": .end, "baseline": .baseline, "stretch": .stretch,
        ]
        for (value, align) in aligns {
            XCTAssertEqual(try style("Container", props: #""align": "\#(value)""#).align, align, value)
        }
        XCTAssertEqual(try style("Container", props: #""align": { "xs": "center" }"#).align, .center)
        // RN `alignItems` defaults to stretch.
        XCTAssertEqual(try style("Container", props: "").align, .stretch)
        XCTAssertEqual(try style("Container", props: #""align": "constructor""#).align, .stretch)
    }

    func testJustifyReadsTheSixKeywords() throws {
        let values: [String: LayoutStyle.Justify] = [
            "start": .start, "center": .center, "end": .end, "between": .between, "around": .around, "evenly": .evenly,
        ]
        for (value, justify) in values {
            XCTAssertEqual(try style("Container", props: #""justify": "\#(value)""#).justify, justify, value)
        }
        XCTAssertEqual(try style("Container", props: #""justify": { "xs": "end" }"#).justify, .end)
        XCTAssertEqual(try style("Container", props: "").justify, .start)
        XCTAssertEqual(try style("Container", props: #""justify": "space-between""#).justify, .start)
    }

    // MARK: - Border and radius

    func testBorderReadsWidthsColorAndLine() throws {
        let border = try XCTUnwrap(try style("Box", props: """
        "border": { "width": { "t": "sm", "r": "md", "b": { "xs": "lg" }, "l": "xs" }, "color": "primary-500", "style": "dashed" }
        """).border)
        XCTAssertEqual(border.widths, LayoutStyle.Insets(top: 2, right: 4, bottom: 8, left: 1))
        XCTAssertEqual(border.color, RGBAColor(hex: "#2f557f"))
        XCTAssertEqual(border.line, .dashed)

        let lines: [String: LayoutStyle.Border.Line] = [
            #""solid""#: .solid, #""dotted""#: .dotted, #"{ "xs": "dotted" }"#: .dotted,
            // RN paints `solid` for no style and for one it cannot paint.
            #""double""#: .solid, "null": .solid,
        ]
        for (value, line) in lines {
            let drawn = try style("Box", props: #""border": { "width": { "t": "sm" }, "color": "white", "style": \#(value) }"#).border
            XCTAssertEqual(drawn?.line, line, value)
        }
    }

    /// A border needs a width and a color. `style: none` drops the whole border, as on mobile.
    /// No fallback color (ADR-0122): a border with no color draws nothing.
    func testABorderWithNothingToDrawIsNil() throws {
        let empty = [
            #""border": { "width": { "t": "sm" }, "color": "white", "style": "none" }"#,
            #""border": { "width": { "t": "sm" } }"#,
            #""border": { "width": { "t": "sm" }, "color": "nope-500" }"#,
            #""border": { "width": { "t": "none", "b": "huge" }, "color": "white" }"#,
            #""border": { "color": "white" }"#,
            #""border": {}"#,
            "",
        ]
        for props in empty {
            XCTAssertNil(try style("Box", props: props).border, props)
        }
    }

    func testTheContentStartsInsidePaddingAndBorder() throws {
        let style = try style("Box", props: """
        "padding": { "top": "md", "left": "sm" }, "border": { "width": { "t": "md", "l": "xs" }, "color": "white" }
        """)
        XCTAssertEqual(style.contentInsets, LayoutStyle.Insets(top: 20, right: 0, bottom: 0, left: 9))
    }

    func testBorderRadiusReadsEachCorner() throws {
        let radius = try style("Box", props: #""borderRadius": { "tl": "md", "tr": "full", "bl": { "xs": "xs" }, "br": "nope" }"#).radius
        XCTAssertEqual(radius, LayoutStyle.Corners(topLeft: 6, topRight: 9999, bottomLeft: 2, bottomRight: 0))
        let keys: [String: CGFloat] = [
            "none": 0, "xs": 2, "sm": 4, "base": 4, "md": 6, "lg": 8, "xl": 12, "2xl": 16, "3xl": 24, "full": 9999,
        ]
        for (key, points) in keys {
            XCTAssertEqual(try style("Box", props: #""borderRadius": { "tl": "\#(key)" }"#).radius.topLeft, points, key)
        }
    }

    // MARK: - Direction

    /// All three blocks read `direction` (awe#6297), collapsed to the lowest set breakpoint as on
    /// mobile: `x` and `x-reverse` are a row; `y`, `y-reverse` and no value are a column.
    func testSectionContainerAndBoxReadDirection() throws {
        let axes: [String: BlockContent.Axis] = [
            #""direction": { "xs": "x" }"#: .horizontal,
            #""direction": "x""#: .horizontal,
            #""direction": { "md": "x" }"#: .horizontal,
            #""direction": { "xs": null, "md": "x" }"#: .horizontal,
            #""direction": { "xs": "x-reverse" }"#: .horizontal,
            #""direction": "x-reverse""#: .horizontal,
            #""direction": { "xs": "y" }"#: .vertical,
            #""direction": "y""#: .vertical,
            #""direction": "y-reverse""#: .vertical,
            #""direction": "nonsense""#: .vertical,
            "": .vertical,
        ]
        for type in ["Section", "Container", "Box"] {
            for (props, axis) in axes {
                guard case let .stack(drawn, _, _) = try evaluate(type, props: props).content else {
                    return XCTFail("\(type) is not a layout block")
                }
                XCTAssertEqual(drawn, axis, "\(type) { \(props) }")
            }
        }
    }

    /// A reverse direction starts at the right or bottom edge, so `justify` start and end swap.
    /// The symmetric values stay.
    func testAReverseDirectionMirrorsJustify() throws {
        let cases: [String: LayoutStyle.Justify] = [
            #""direction": "x-reverse""#: .end,
            #""direction": "x-reverse", "justify": "start""#: .end,
            #""direction": "x-reverse", "justify": "end""#: .start,
            #""direction": { "xs": "y-reverse" }, "justify": "end""#: .start,
            #""direction": "y-reverse", "justify": "center""#: .center,
            #""direction": "x-reverse", "justify": "between""#: .between,
            #""direction": "x-reverse", "justify": "around""#: .around,
            #""direction": "y-reverse", "justify": "evenly""#: .evenly,
            #""direction": "x", "justify": "end""#: .end,
        ]
        for type in ["Section", "Container", "Box"] {
            for (props, justify) in cases {
                XCTAssertEqual(try style(type, props: props).justify, justify, "\(type) { \(props) }")
            }
        }
    }

    /// A reverse direction draws the children in reversed document order, in the evaluator, so
    /// D-pad focus and the default focus follow the drawing.
    func testAReverseDirectionReversesTheChildren() throws {
        let tree = { (type: String, direction: String) in
            try self.evaluateTree("""
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["blk"] },
            "blk": { "type": { "resolvedName": "\(type)" }, "props": { "direction": \(direction) }, "parent": "ROOT", "nodes": ["a", "b", "c"] },
            "a": { "type": { "resolvedName": "Button" }, "props": { "label": "A", "linkType": "screen", "screen": "s2" }, "parent": "blk", "nodes": [] },
            "b": { "type": { "resolvedName": "SimpleText" }, "props": { "text": "B" }, "parent": "blk", "nodes": [] },
            "c": { "type": { "resolvedName": "Button" }, "props": { "label": "C", "linkType": "screen", "screen": "s2" }, "parent": "blk", "nodes": [] }
            """)
        }
        for type in ["Section", "Container", "Box"] {
            for direction in [#""x-reverse""#, #"{ "xs": "y-reverse" }"#] {
                let root = try tree(type, direction)
                XCTAssertEqual(try XCTUnwrap(root.first { $0.id == "blk" }).children.map(\.id), ["c", "b", "a"], "\(type) \(direction)")
                XCTAssertEqual(root.firstFocusNodeId, "c", "the default focus is the first child drawn")
            }
            for direction in [#""x""#, #""y""#] {
                let root = try tree(type, direction)
                XCTAssertEqual(try XCTUnwrap(root.first { $0.id == "blk" }).children.map(\.id), ["a", "b", "c"], "\(type) \(direction)")
                XCTAssertEqual(root.firstFocusNodeId, "a")
            }
        }
    }

    // MARK: - One reader, three blocks

    func testRootAndGridTakeNoStyle() throws {
        let props = #""padding": { "top": "md" }, "minHeight": "300px", "align": "center", "justify": "end""#
        for type in ["Root", "Grid"] {
            XCTAssertEqual(try evaluate(type, props: props).content, .stack(axis: .vertical), type)
        }
        XCTAssertEqual(try style("Section", props: props).justify, .end)
        XCTAssertEqual(try style("Container", props: props).minHeight, 300)
    }

    // MARK: - Order

    /// `order` is not drawn (awe#6297): the web and the editor apply it only under a Grid, so the
    /// editor no longer offers it under a Box (awe#6413). A saved `order` leaves the document
    /// order as it is.
    func testALayoutBlockKeepsTheDocumentOrder() throws {
        let child = { (id: String, order: String) in
            #""\#(id)": { "type": { "resolvedName": "SimpleText" }, "props": { "text": "\#(id)", "order": \#(order) }, "parent": "blk", "nodes": [] }"#
        }
        for type in ["Box", "Section", "Container"] {
            let root = try evaluateTree("""
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["blk"] },
            "blk": { "type": { "resolvedName": "\(type)" }, "props": {}, "parent": "ROOT", "nodes": ["a", "b", "c"] },
            \(child("a", #"{ "xs": "2" }"#)),
            \(child("b", #""1""#)),
            \(child("c", "0"))
            """)
            let node = try XCTUnwrap(root.first { $0.id == "blk" })
            XCTAssertEqual(node.children.map(\.id), ["a", "b", "c"], type)
        }
    }

    // MARK: - Leading hero

    /// A leading hero inside padded layout blocks still bleeds to the stage edges: its bleed adds
    /// the padding and border above it, and its art moves back to the stage center.
    func testALeadingHeroCarriesTheInsetsAboveIt() throws {
        let screen = try ContractDecoder.screen(Data("""
        { "id": "s1", "kind": "static",
          "blockResources": { "hero": { "resources": { "collectionTeaser":
            { "contentType": "shows", "shows": [{ "_id": "a1", "title": "A" }] } } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["sec"] },
            "sec": { "type": { "resolvedName": "Section" }, "parent": "ROOT", "nodes": ["box"], "props": {
              "padding": { "top": "md", "left": "xl", "right": "sm", "bottom": "lg" },
              "border": { "width": { "t": "xs", "l": "xs" }, "color": "white" } } },
            "box": { "type": { "resolvedName": "Box" }, "parent": "sec", "nodes": ["hero"],
                     "props": { "padding": { "top": "sm" } } },
            "hero": { "type": { "resolvedName": "CollectionTeaser" }, "parent": "box", "nodes": [],
                      "props": { "itemLayout": "hero" }, "custom": { "type": "plugin", "resources": ["collectionTeaser"] } }
          } }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: screen.blockResources)))
        XCTAssertEqual(node.leadingHeroId, "hero")
        XCTAssertEqual(node.leadingHeroInsets, LayoutStyle.Insets(top: 16 + 1 + 8, right: 8, bottom: 32, left: 64 + 1))

        let hero = LeadingHero(nodeId: "hero", insets: node.leadingHeroInsets, screenTop: 100)
        XCTAssertEqual(hero.bleed, 125, "the stage top is above the insets too")
        XCTAssertEqual(hero.shift, (8 - 65) / 2, "the art moves back to the stage center")

        // No padding on the path: as before awe#6297.
        let plain = try TestRender.screen("home").node
        XCTAssertEqual(plain.leadingHeroInsets, LayoutStyle.Insets())
        XCTAssertEqual(LeadingHero(nodeId: "hero", insets: LayoutStyle.Insets(), screenTop: 100).bleed, 100)
    }

    // MARK: - Justify

    func testJustifySpreadsTheFreeSpace() {
        let positions = { (justify: LayoutStyle.Justify, length: CGFloat) in
            FlexStackLayout.mainPositions(sizes: [100, 100], spacing: 40, length: length, justify: justify)
        }
        XCTAssertEqual(positions(.start, 500), [0, 140])
        XCTAssertEqual(positions(.center, 500), [130, 270])
        XCTAssertEqual(positions(.end, 500), [260, 400])
        XCTAssertEqual(positions(.between, 500), [0, 400])
        XCTAssertEqual(positions(.around, 500), [65, 335])
        let evenly = positions(.evenly, 500)
        XCTAssertEqual(evenly[0], 260.0 / 3, accuracy: 0.001)
        XCTAssertEqual(evenly[1], 500 - 100 - 260.0 / 3, accuracy: 0.001)
        // No free space: the children pack at the start, the gap stays.
        XCTAssertEqual(positions(.end, 200), [0, 140])
        // One child: `between` packs it at the start, as CSS does.
        XCTAssertEqual(FlexStackLayout.mainPositions(sizes: [100], spacing: 40, length: 500, justify: .between), [0])
        XCTAssertEqual(FlexStackLayout.mainPositions(sizes: [], spacing: 40, length: 500, justify: .center), [])
    }
}

/// Draws an evaluated tree with `ImageRenderer` and reads pixels: the stretch, the padding, the
/// heights, the border and the corners are geometry the models alone cannot show.
@MainActor
final class LayoutStyleRenderTests: XCTestCase {

    private static let red = "#ff0000"
    private static let blue = "#0000ff"
    /// An empty blue Box, 256 x 50 pt: its padding alone gives it a width.
    private static let block256 = ##""backgroundColor": "#0000ff", "height": { "value": 50, "unit": "px" }, "padding": { "left": "3xl", "right": "3xl" }"##

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        /// A point outside the image reads as clear.
        func rgba(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return (0, 0, 0, 0) }
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }

        func isRed(_ x: Int, _ y: Int) -> Bool { let p = rgba(x, y); return p.r > 200 && p.g < 40 && p.b < 40 && p.a > 200 }
        func isBlue(_ x: Int, _ y: Int) -> Bool { let p = rgba(x, y); return p.b > 200 && p.r < 40 && p.g < 40 && p.a > 200 }
        func isClear(_ x: Int, _ y: Int) -> Bool { rgba(x, y).a < 20 }
    }

    /// `nodes` under a Root, drawn 800 pt wide at scale 1. `height` makes the offer finite, as
    /// the AppLayout's full-screen frame does. A `ContentPlaceholder` draws a clear, greedy slot.
    private func render(_ nodes: String, root: [String], height: CGFloat? = nil) throws -> Pixels {
        let ids = root.map { "\"\($0)\"" }.joined(separator: ", ")
        let screen = try ContractDecoder.screen(Data("""
        { "id": "s1", "kind": "static", "content": {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": [\(ids)] },
          \(nodes)
        } }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: RenderContext(images: ImageConfig(cdn: "https://images.test", bucket: "bucket"),
                                   colors: PresetColorResolver(preset: .null))
        ))
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1, "app": { "design": "tv" }, "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "s1", "label": "Home" }] } }],
          "screens": [{ "id": "s1", "kind": "static" }], "preset": {}
        }
        """.utf8))
        let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
        let renderer = ImageRenderer(content: NodeView(node: node, slot: AnyView(Color.clear)).environment(router))
        renderer.proposedSize = ProposedViewSize(width: 800, height: height)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(width: image.width, height: image.height, bytes: bytes)
    }

    private func node(_ id: String, _ type: String, _ props: String, parent: String = "ROOT", nodes: [String] = []) -> String {
        let ids = nodes.map { "\"\($0)\"" }.joined(separator: ", ")
        return #""\#(id)": { "type": { "resolvedName": "\#(type)" }, "props": { \#(props) }, "parent": "\#(parent)", "nodes": [\#(ids)] }"#
    }

    private func badge(_ id: String, parent: String) -> String {
        node(id, "Badge", #""label": "B""#, parent: parent)
    }

    /// Acceptance 1: a Section with only a short child still draws a full-width band.
    func testASectionBackgroundIsAFullWidthBand() throws {
        let pixels = try render([
            node("sec", "Section", #""bgColor": "\#(Self.red)""#, nodes: ["b"]),
            badge("b", parent: "sec"),
        ].joined(separator: ",\n"), root: ["sec"])
        XCTAssertEqual(pixels.width, 800)
        XCTAssertTrue(pixels.isRed(795, pixels.height / 2), "the band reaches the far edge")
    }

    /// Acceptance 2: in a horizontal Container, the short column is as tall as the row.
    func testRowColumnsAreAsTallAsTheRow() throws {
        let pixels = try render([
            node("row", "Container", #""direction": "x""#, nodes: ["short", "tall"]),
            node("short", "Box", #""backgroundColor": "\#(Self.red)""#, parent: "row", nodes: ["b1"]),
            badge("b1", parent: "short"),
            node("tall", "Box", #""backgroundColor": "\#(Self.blue)", "height": { "value": 300, "unit": "px" }"#,
                 parent: "row", nodes: ["b2"]),
            badge("b2", parent: "tall"),
        ].joined(separator: ",\n"), root: ["row"])
        XCTAssertEqual(pixels.height, 300)
        XCTAssertTrue(pixels.isRed(2, 295), "the short column's background reaches the row bottom")
    }

    /// A Box with `direction: x` is a row like a Container: both backgrounds are as tall as the row.
    func testABoxRowStretchesItsColumns() throws {
        let pixels = try render([
            node("row", "Box", #""direction": { "xs": "x" }"#, nodes: ["short", "tall"]),
            node("short", "Box", #""backgroundColor": "\#(Self.red)""#, parent: "row", nodes: ["b1"]),
            badge("b1", parent: "short"),
            node("tall", "Box", #""backgroundColor": "\#(Self.blue)", "height": { "value": 300, "unit": "px" }"#,
                 parent: "row", nodes: ["b2"]),
            badge("b2", parent: "tall"),
        ].joined(separator: ",\n"), root: ["row"])
        XCTAssertEqual(pixels.height, 300)
        XCTAssertTrue(pixels.isRed(2, 295), "the short column's background reaches the row bottom")
        XCTAssertTrue((0..<pixels.width).contains { pixels.isBlue($0, 295) }, "the tall column sits beside it")
    }

    /// `x-reverse` with `justify: start` packs at the right edge, and the last child is leftmost.
    func testXReversePacksAtTheRightEdge() throws {
        let pixels = try render([
            node("row", "Box", #""direction": "x-reverse", "justify": "start""#, nodes: ["first", "last"]),
            node("first", "Box", Self.block256.replacingOccurrences(of: "#0000ff", with: Self.red), parent: "row"),
            node("last", "Box", Self.block256, parent: "row"),
        ].joined(separator: ",\n"), root: ["row"])
        // Two 256 pt children and the 40 pt gap: red 544...800, blue 248...504.
        XCTAssertEqual(pixels.height, 50)
        XCTAssertTrue(pixels.isRed(797, 25), "the first child sits at the right edge")
        XCTAssertTrue(pixels.isBlue(260, 25), "the last child is leftmost")
        XCTAssertTrue(pixels.isClear(2, 25), "nothing at the left edge")
    }

    /// `y-reverse` in a column with a `minHeight` packs at the bottom, the first child lowest.
    func testYReversePacksAtTheBottom() throws {
        let pixels = try render([
            node("col", "Section", #""direction": "y-reverse", "minHeight": "300px""#, nodes: ["first", "last"]),
            node("first", "Box", Self.block256.replacingOccurrences(of: "#0000ff", with: Self.red), parent: "col"),
            node("last", "Box", Self.block256, parent: "col"),
        ].joined(separator: ",\n"), root: ["col"])
        // Two 50 pt children and the 44 pt gap: red 250...300, blue 156...206.
        XCTAssertEqual(pixels.height, 300)
        XCTAssertTrue(pixels.isRed(5, 295), "the first child sits at the bottom")
        XCTAssertTrue(pixels.isBlue(5, 180), "the last child is above it")
        XCTAssertTrue(pixels.isClear(5, 20), "nothing at the top")
    }

    /// Acceptance 3 and 4: padding insets the child inside the background; `minHeight` holds.
    func testPaddingAndMinHeight() throws {
        let pixels = try render([
            node("sec", "Section", #""bgColor": "\#(Self.red)", "minHeight": "300px", "padding": { "top": "xl", "left": "xl" }"#,
                 nodes: ["box"]),
            node("box", "Box", #""backgroundColor": "\#(Self.blue)", "height": { "value": 50, "unit": "px" }"#,
                 parent: "sec"),
        ].joined(separator: ",\n"), root: ["sec"])
        XCTAssertEqual(pixels.height, 300)
        XCTAssertTrue(pixels.isRed(30, 30), "the padding shows the Section color")
        XCTAssertTrue(pixels.isBlue(70, 70), "the child starts inside the padding")
        XCTAssertTrue(pixels.isBlue(795, 70), "the child Box fills the width inside the padding")
        XCTAssertTrue(pixels.isRed(70, 200), "below the 50 pt child, the Section keeps its minimum height")
    }

    func testBorderAndRadius() throws {
        let pixels = try render([
            node("box", "Box", """
            "height": { "value": 100, "unit": "px" }, "backgroundColor": "\(Self.red)",
            "border": { "width": { "t": "md", "r": "md", "b": "md", "l": "md" }, "color": "\(Self.blue)" },
            "borderRadius": { "tl": "full", "tr": "full", "bl": "full", "br": "full" }
            """, nodes: ["b"]),
            badge("b", parent: "box"),
        ].joined(separator: ",\n"), root: ["box"])
        XCTAssertEqual(pixels.height, 100)
        XCTAssertTrue(pixels.isClear(2, 2), "the pill corner clips the background")
        XCTAssertTrue(pixels.isBlue(400, 1), "the border draws at the top edge")
        XCTAssertTrue(pixels.isRed(400, 50), "the background fills the inside")
    }

    /// `justify: end` moves a short child to the far end of a full-width row.
    func testJustifyEndInARow() throws {
        let pixels = try render([
            node("row", "Container", #""direction": "x", "justify": "end""#, nodes: ["box"]),
            node("box", "Box", Self.block256, parent: "row"),
        ].joined(separator: ",\n"), root: ["row"])
        XCTAssertEqual(pixels.height, 50)
        XCTAssertTrue(pixels.isBlue(797, 25), "the child sits at the row end")
        XCTAssertTrue(pixels.isClear(540, 25), "the child keeps its 256 pt width")
        XCTAssertTrue(pixels.isClear(2, 25), "nothing at the row start")
    }

    /// A column that the row stretches has free height: `justify: end` uses it.
    func testJustifyEndInAColumnTheRowStretches() throws {
        let pixels = try render([
            node("row", "Container", #""direction": "x""#, nodes: ["tall", "col"]),
            node("tall", "Box", Self.block256.replacingOccurrences(of: #""value": 50"#, with: #""value": 300"#), parent: "row"),
            node("col", "Container", #""justify": "end""#, parent: "row", nodes: ["box"]),
            node("box", "Box", Self.block256.replacingOccurrences(of: "#0000ff", with: Self.red), parent: "col"),
        ].joined(separator: ",\n"), root: ["row"])
        XCTAssertEqual(pixels.height, 300)
        // The column starts after the 256 pt Box and the 40 pt gap.
        XCTAssertTrue(pixels.isRed(300, 290), "the child sits at the column bottom")
        XCTAssertTrue(pixels.isClear(300, 10), "nothing at the column top")
    }

    /// A justified column that the row does not stretch (`align: start`) keeps its content
    /// height, so `justify` has no free space and packs at the start.
    func testJustifyNeedsSpaceTheBlockOwns() throws {
        let pixels = try render([
            node("row", "Container", #""direction": "x", "align": "start""#, nodes: ["tall", "col"]),
            node("tall", "Box", Self.block256.replacingOccurrences(of: #""value": 50"#, with: #""value": 300"#), parent: "row"),
            node("col", "Container", #""justify": "center""#, parent: "row", nodes: ["box"]),
            node("box", "Box", Self.block256.replacingOccurrences(of: "#0000ff", with: Self.red), parent: "col"),
        ].joined(separator: ",\n"), root: ["row"])
        XCTAssertEqual(pixels.height, 300)
        XCTAssertTrue(pixels.isRed(300, 25), "the child stays at the column top")
        XCTAssertTrue(pixels.isClear(300, 150), "no centering in the row height")
    }

    /// The AppLayout case: under a finite offer, a justified footer keeps its content height and
    /// the content slot keeps the rest.
    func testAJustifiedBlockDoesNotTakeAFiniteOffer() throws {
        let pixels = try render([
            node("slot", "ContentPlaceholder", ""),
            // No fixed height: 32 pt of padding is its whole content.
            node("footer", "Box", ##""backgroundColor": "#0000ff", "justify": "center", "padding": { "top": "md", "bottom": "md" }"##),
        ].joined(separator: ",\n"), root: ["slot", "footer"], height: 600)
        XCTAssertEqual(pixels.height, 600)
        XCTAssertTrue(pixels.isBlue(5, 590), "the footer sits at the bottom")
        XCTAssertTrue(pixels.isClear(5, 560), "the footer is 32 pt, not a share of the offer")
    }

    /// A Box with a fixed height shares out its own height, not the parent's offer. A pin: the
    /// system frame and padding already place the stack at its own size, so this was green
    /// before the sizing pass used `height` too.
    func testAFixedHeightIsTheOfferForTheChildren() throws {
        // The greedy slot above keeps the Root at the 600 pt offer, so the Box is offered a share.
        let pixels = try render([
            node("top", "ContentPlaceholder", ""),
            node("box", "Box", #""backgroundColor": "\#(Self.blue)", "height": { "value": 100, "unit": "px" }"#,
                 nodes: ["slot", "inner"]),
            node("slot", "ContentPlaceholder", "", parent: "box"),
            node("inner", "Box", #""backgroundColor": "\#(Self.red)", "height": { "value": 20, "unit": "px" }"#,
                 parent: "box"),
        ].joined(separator: ",\n"), root: ["top", "box"], height: 600)
        XCTAssertEqual(pixels.height, 600)
        // The Box is 500...600. Its slot takes 100 - 44 - 20 = 36 pt, so the red Box is 580...600.
        XCTAssertTrue(pixels.isRed(5, 590), "the last child ends at the Box bottom")
        XCTAssertTrue(pixels.isBlue(5, 560), "the gap shows the Box color")
    }

    /// An over-full fixed-height Box keeps its children at their own size: the text overflows
    /// the 50 pt Box, as RN (`flexShrink: 0`) and the web (`min-height: auto`) draw it. It is not
    /// cut to the Box height with "…".
    func testAnOverFullFixedHeightKeepsTheContentSize() throws {
        let words = String(repeating: "Overflowing words on a television screen. ", count: 12)
        let pixels = try render([
            node("box", "Box", #""height": { "value": 50, "unit": "px" }"#, nodes: ["txt"]),
            node("txt", "SimpleText", #""text": "\#(words)""#, parent: "box"),
            node("slot", "ContentPlaceholder", ""),
        ].joined(separator: ",\n"), root: ["box", "slot"], height: 600)
        // The Box is 0...50 and the clear slot starts at 94. Only overflowing text draws below 60.
        let drawnBelow = (60..<200).contains { y in (0..<pixels.width).contains { !pixels.isClear($0, y) } }
        XCTAssertTrue(drawnBelow, "the text keeps its full height and overflows the Box")
    }

    /// `align: center` stops the stretch and centers the layout child.
    func testAlignCenterInAColumn() throws {
        let pixels = try render([
            node("col", "Container", #""align": "center""#, nodes: ["box"]),
            node("box", "Box", Self.block256, parent: "col"),
        ].joined(separator: ",\n"), root: ["col"])
        XCTAssertTrue(pixels.isBlue(400, 25), "the child is centered")
        XCTAssertTrue(pixels.isBlue(275, 25) && pixels.isClear(268, 25), "the child spans 272 to 528")
        XCTAssertTrue(pixels.isClear(2, 25), "the child does not stretch")
    }
}

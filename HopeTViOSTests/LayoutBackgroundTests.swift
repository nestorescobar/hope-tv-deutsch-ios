import XCTest
@testable import HopeTViOS

/// The Background panel on layout blocks (awe#6239): one color and one image.
///
/// `Section`, `Container` and `Box` draw a color and an image; `ContentPlaceholder` draws a
/// color only. The rules are a port of `apps/mobile` (`blocks/backgroundStyles.ts`,
/// `blocks/backgroundGeometry.ts`, `preset/colors.ts`). An absent or unknown value draws nothing.
final class LayoutBackgroundTests: XCTestCase {

    /// A small App Preset. `ocean` is a Custom Palette that the `sea` theme puts in the primary slot.
    private static let preset = JSONValue.object([
        "colors": .object([
            "primary": .object(["400": .string("#3f77b4"), "500": .string("#2f557f")]),
            "secondary": .object(["400": .string("#c07d2a")]),
            "danger": .object(["500": .string("#ef4444")]),
            "ocean": .object(["500": .string("#0a3d62")]),
            "eight": .object(["500": .string("#11223380")]),
        ]),
        "themes": .array([
            .object(["code": .string("sea"), "colors": .object(["primary": .string("ocean")])]),
        ]),
    ])

    private let file = #"{ "containerId": "c1", "name": "bg.jpg", "blurhash": "LKO2", "width": 1920, "height": 1080 }"#

    /// One block of `type` under ROOT, with `props` and one text child, evaluated.
    private func evaluate(_ type: String, props: String, preset: JSONValue = preset) throws -> EvaluatedNode {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["blk"] },
            "blk": {
              "type": { "resolvedName": "\(type)" },
              "props": { \(props) },
              "parent": "ROOT", "nodes": ["txt"]
            },
            "txt": {
              "type": { "resolvedName": "SimpleText" },
              "props": { "text": "Hello" },
              "parent": "blk", "nodes": []
            }
          }
        }
        """.utf8))
        let root = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: RenderContext(
                images: ImageConfig(cdn: "https://images.test", bucket: "bucket"),
                colors: PresetColorResolver(preset: preset)
            )
        ))
        return try XCTUnwrap(root.first { $0.id == "blk" })
    }

    private func background(_ type: String, props: String, preset: JSONValue = preset) throws -> LayoutBackground? {
        switch try evaluate(type, props: props, preset: preset).content {
        case let .stack(_, background, _), let .contentSlot(background):
            return background
        default:
            XCTFail("\(type) is not a layout block")
            return nil
        }
    }

    private func color(_ type: String = "Section", props: String, preset: JSONValue = preset) throws -> RGBAColor? {
        try background(type, props: props, preset: preset)?.color
    }

    private func hex(_ value: String, opacity: Double = 1) throws -> RGBAColor {
        let color = try XCTUnwrap(RGBAColor(hex: value))
        return RGBAColor(red: color.red, green: color.green, blue: color.blue, opacity: color.opacity * opacity)
    }

    // MARK: - Color

    func testAHexValueReadsAsSRGBChannels() throws {
        XCTAssertEqual(RGBAColor(hex: "#ff0000"), RGBAColor(red: 1, green: 0, blue: 0, opacity: 1))
        XCTAssertEqual(RGBAColor(hex: "#00ff0080")?.opacity ?? 0, 128.0 / 255, accuracy: 0.0001)
    }

    func testSectionContainerAndBoxDrawAPaletteColor() throws {
        XCTAssertEqual(try color("Section", props: #""bgColor": "primary-500""#), try hex("#2f557f"))
        XCTAssertEqual(try color("Container", props: #""bgColor": "secondary-400""#), try hex("#c07d2a"))
        // The editor's Box writes its color to `backgroundColor`.
        XCTAssertEqual(try color("Box", props: #""backgroundColor": "primary-400""#), try hex("#3f77b4"))
    }

    func testContentPlaceholderDrawsItsBgColor() throws {
        XCTAssertEqual(try color("ContentPlaceholder", props: #""bgColor": "primary-500""#), try hex("#2f557f"))
    }

    /// Mobile `Box.tsx`: `authored(bgColor) ?? backgroundColor`. An authored `bgColor` wins,
    /// even when it does not resolve; a cleared `{}` or `null` gives way.
    func testAnAuthoredBgColorWinsOverBackgroundColor() throws {
        XCTAssertEqual(try color("Box", props: #""bgColor": "primary-500", "backgroundColor": "primary-400""#),
                       try hex("#2f557f"))
        XCTAssertEqual(try color("Box", props: #""bgColor": {}, "backgroundColor": "primary-400""#), try hex("#3f77b4"))
        XCTAssertEqual(try color("Box", props: #""bgColor": null, "backgroundColor": "primary-400""#), try hex("#3f77b4"))
        XCTAssertNil(try color("Box", props: #""bgColor": "nope-500", "backgroundColor": "primary-400""#))
        // Section and Container render through mobile's Box, so the same rule holds there.
        XCTAssertEqual(try color("Section", props: #""backgroundColor": "primary-400""#), try hex("#3f77b4"))
    }

    /// ADR-0071: an integer percent strictly between 0 and 100 is the alpha. Any other suffix
    /// drops, and the color stays opaque.
    func testAnAlphaSuffixSetsTheOpacity() throws {
        let faded = try XCTUnwrap(try color(props: #""bgColor": "primary-500/40""#))
        XCTAssertEqual(faded, try hex("#2f557f", opacity: 0.4))
        for suffix in ["100", "0", "abc", "40.5", "40/2"] {
            XCTAssertEqual(try color(props: #""bgColor": "primary-500/\#(suffix)""#), try hex("#2f557f"), suffix)
        }
    }

    /// A Custom Palette key may hold a dash: the step is after the LAST one (mobile `applyTheme`).
    func testACustomPaletteKeyWithADashResolves() throws {
        var preset = Self.preset
        if case var .object(fields) = preset, case var .object(colors) = fields["colors"] ?? .null {
            colors["my-brand"] = .object(["500": .string("#abcdef")])
            fields["colors"] = .object(colors)
            preset = .object(fields)
        }
        XCTAssertEqual(try color(props: #""bgColor": "my-brand-500""#, preset: preset), try hex("#abcdef"))
        XCTAssertEqual(try color(props: #""bgColor": "my-brand-500/40""#, preset: preset), try hex("#abcdef", opacity: 0.4))
        XCTAssertNil(try color(props: #""bgColor": "my-brand""#, preset: preset))
    }

    /// An empty or negative suffix is not an integer percent: the color stays opaque.
    func testAnEmptyAlphaSuffixStaysOpaque() throws {
        XCTAssertEqual(try color(props: #""bgColor": "primary-500/""#), try hex("#2f557f"))
        XCTAssertEqual(try color(props: #""bgColor": "primary-500/-5""#), try hex("#2f557f"))
        XCTAssertEqual(try color(props: #""bgColor": "primary-500/1""#), try hex("#2f557f", opacity: 0.01))
        XCTAssertEqual(try color(props: #""bgColor": "primary-500/99""#), try hex("#2f557f", opacity: 0.99))
    }

    func testTheThemeRemapsTheSemanticPalette() throws {
        var preset = Self.preset
        if case var .object(fields) = preset {
            fields["defaultTheme"] = .string("sea")
            preset = .object(fields)
        }
        XCTAssertEqual(try color(props: #""bgColor": "primary-500""#, preset: preset), try hex("#0a3d62"))
        // The legacy `danger` palette fills the `error` slot.
        XCTAssertEqual(try color(props: #""bgColor": "error-500""#), try hex("#ef4444"))
        XCTAssertEqual(try color(props: #""bgColor": "danger-500""#), try hex("#ef4444"))
    }

    func testSystemColorsAndRawHex() throws {
        XCTAssertEqual(try color(props: #""bgColor": "white""#), RGBAColor(red: 1, green: 1, blue: 1, opacity: 1))
        XCTAssertEqual(try color(props: #""bgColor": "black/50""#), RGBAColor(red: 0, green: 0, blue: 0, opacity: 0.5))
        XCTAssertEqual(try color(props: #""bgColor": "transparent""#), RGBAColor(red: 0, green: 0, blue: 0, opacity: 0))
        XCTAssertEqual(try color(props: ##""bgColor": "#112233""##), try hex("#112233"))
        // A palette leaf with its own alpha keeps it, and a suffix multiplies it.
        XCTAssertEqual(try color(props: #""bgColor": "eight-500/50""#), try hex("#11223380", opacity: 0.5))
        // No value of its own, or a raw form tvOS does not read: nothing.
        XCTAssertNil(try color(props: #""bgColor": "currentColor""#))
        XCTAssertNil(try color(props: ##""bgColor": "#12345""##))
        XCTAssertNil(try color(props: ##""bgColor": "#112233/40""##))
        XCTAssertNil(try color(props: #""bgColor": "rgb(1, 2, 3)""#))
    }

    func testAResponsiveColorCollapsesToItsLowestBreakpoint() throws {
        XCTAssertEqual(try color(props: #""bgColor": { "xs": "primary-500", "md": "primary-400" }"#), try hex("#2f557f"))
        XCTAssertEqual(try color(props: #""bgColor": { "md": "primary-400" }"#), try hex("#3f77b4"))
        XCTAssertEqual(try color(props: #""bgColor": { "xs": null, "lg": "primary-400" }"#), try hex("#3f77b4"))
    }

    /// Mobile `backgroundLayers`: a solid layer only for `bgType: "solid"` or no `bgType`. The tv
    /// editor never writes `bgType`; a node copied from another design can carry one.
    func testANonSolidBgTypeDrawsNoColor() throws {
        XCTAssertEqual(try color(props: #""bgType": "solid", "bgColor": "primary-500""#), try hex("#2f557f"))
        XCTAssertEqual(try color(props: #""bgType": "", "bgColor": "primary-500""#), try hex("#2f557f"))
        XCTAssertNil(try color(props: #""bgType": "image", "bgColor": "primary-500""#))
        XCTAssertNil(try color(props: #""bgType": "gradient", "bgColor": "primary-500""#))
    }

    // MARK: - Image

    func testABgImageDrawsAtTheStageWidthCenteredByDefault() throws {
        for type in ["Section", "Container", "Box"] {
            let image = try XCTUnwrap(try background(type, props: #""bgImage": \#(file)"#)?.image, type)
            XCTAssertEqual(image.url.absoluteString.hasPrefix("https://images.test/resize/"), true, type)
            XCTAssertTrue(image.url.absoluteString.hasSuffix("/w:1920/bucket/c1/bg.jpg"), type)
            XCTAssertEqual(image.alignment, .center, type)
        }
    }

    func testBgImageAlignPlacesTheImage() throws {
        let expected: [String: BackgroundAlignment] = [
            "top left": BackgroundAlignment(x: 0, y: 0),
            "top": BackgroundAlignment(x: 0.5, y: 0),
            "top right": BackgroundAlignment(x: 1, y: 0),
            "center left": BackgroundAlignment(x: 0, y: 0.5),
            "center": .center,
            "center right": BackgroundAlignment(x: 1, y: 0.5),
            "bottom left": BackgroundAlignment(x: 0, y: 1),
            "bottom": BackgroundAlignment(x: 0.5, y: 1),
            "bottom right": BackgroundAlignment(x: 1, y: 1),
        ]
        for (key, alignment) in expected {
            let image = try XCTUnwrap(try background("Section", props: #""bgImage": \#(file), "bgImageAlign": "\#(key)""#)?.image)
            XCTAssertEqual(image.alignment, alignment, key)
        }
    }

    func testAResponsiveOrUnknownAlignment() throws {
        let align = { (value: String) in
            try XCTUnwrap(try self.background("Section", props: #""bgImage": \#(self.file), "bgImageAlign": \#(value)"#)?.image).alignment
        }
        XCTAssertEqual(try align(#"{ "xs": "top left", "lg": "bottom" }"#), BackgroundAlignment(x: 0, y: 0))
        XCTAssertEqual(try align(#"{ "md": "bottom right" }"#), BackgroundAlignment(x: 1, y: 1))
        // `custom` reads `bgImagePosition`, which the tv design does not offer: center.
        XCTAssertEqual(try align(#""custom""#), .center)
        XCTAssertEqual(try align(#""nonsense""#), .center)
        XCTAssertEqual(try align(#"{}"#), .center)
    }

    func testAResponsiveBgImageCollapsesToItsLowestBreakpoint() throws {
        let other = #"{ "containerId": "c1", "name": "large.jpg" }"#
        let xs = try XCTUnwrap(try background("Box", props: #""bgImage": { "xs": \#(file), "lg": \#(other) }"#)?.image)
        XCTAssertTrue(xs.url.absoluteString.hasSuffix("/c1/bg.jpg"))
        let md = try XCTUnwrap(try background("Box", props: #""bgImage": { "xs": null, "md": \#(other) }"#)?.image)
        XCTAssertTrue(md.url.absoluteString.hasSuffix("/c1/large.jpg"))
    }

    func testTheImageDrawsWithAnyBgTypeAndOverTheColor() throws {
        let both = try XCTUnwrap(try background("Section", props: #""bgColor": "primary-500", "bgImage": \#(file)"#))
        XCTAssertEqual(both.color, try hex("#2f557f"))
        XCTAssertNotNil(both.image)
        XCTAssertNotNil(try background("Section", props: #""bgType": "solid", "bgImage": \#(file)"#)?.image)
    }

    func testContentPlaceholderDrawsNoImage() throws {
        XCTAssertNil(try background("ContentPlaceholder", props: #""bgImage": \#(file)"#))
    }

    // MARK: - Nothing to draw

    func testAnAbsentOrUnknownValueDrawsNothing() throws {
        let empty = [
            "",
            #""bgColor": {}"#,
            #""bgColor": """#,
            #""bgColor": null"#,
            #""bgColor": "nope-500""#,
            #""bgColor": "primary-999""#,
            #""bgColor": "primary""#,
            #""bgColor": 12"#,
            #""bgImage": {}"#,
            #""bgImage": null"#,
            #""bgImage": { "name": "bg.jpg" }"#,
            #""bgImage": { "xs": null }"#,
            #""bgImageAlign": "top""#,
        ]
        for props in empty {
            for type in ["Section", "Container", "Box", "ContentPlaceholder"] {
                XCTAssertNil(try background(type, props: props), "\(type) { \(props) }")
            }
        }
        // No background leaves the content as it was before awe#6239.
        XCTAssertEqual(try evaluate("Section", props: "").content, .stack(axis: .vertical))
        XCTAssertEqual(try evaluate("Container", props: #""direction": { "xs": "x" }"#).content, .stack(axis: .horizontal))
        XCTAssertEqual(try evaluate("ContentPlaceholder", props: "").content, .contentSlot())
    }

    func testNoPresetDrawsNoColorButStillTheImage() throws {
        XCTAssertNil(try color(props: #""bgColor": "primary-500""#, preset: .null))
        XCTAssertNotNil(try background("Section", props: #""bgColor": "primary-500", "bgImage": \#(file)"#, preset: .null)?.image)
    }

    func testRootAndGridDrawNoBackground() throws {
        for type in ["Root", "Grid"] {
            XCTAssertEqual(try evaluate(type, props: #""bgColor": "primary-500", "bgImage": \#(file)"#).content,
                           .stack(axis: .vertical), type)
        }
    }

    func testABackgroundKeepsTheAxisAndTheChildren() throws {
        let node = try evaluate("Container", props: #""direction": "x", "bgColor": "primary-500""#)
        guard case let .stack(axis, background, _) = node.content else { return XCTFail("not a stack") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(background?.color, try hex("#2f557f"))
        XCTAssertEqual(node.children.map(\.id), ["txt"])
    }
}

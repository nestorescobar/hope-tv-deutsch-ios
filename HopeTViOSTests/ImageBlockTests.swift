import XCTest
@testable import HopeTViOS

/// The `Image` block reads the picked file from `props.file` (awe#6076).
///
/// The App Screen editor saves the file there, as a plain file or a responsive map. A map
/// collapses to its lowest non-null breakpoint, as the backend `useBaseImageFile` does.
/// `image` is an old key the editor no longer writes: it is the last fallback.
final class ImageBlockTests: XCTestCase {

    private let file = #"{ "containerId": "c1", "name": "picked.jpg", "blurhash": "LKO2", "width": 1920, "height": 1080 }"#

    /// One `Image` node with `props`, evaluated to its content.
    private func content(props: String) throws -> BlockContent? {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["img"] },
            "img": {
              "type": { "resolvedName": "Image" },
              "props": { \(props) },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context()
        ))
        return try XCTUnwrap(node.first { $0.id == "img" }).content
    }

    private func image(props: String) throws -> ImageModel {
        if case let .image(model) = try content(props: props) { return model }
        return try XCTUnwrap(nil, "Image drew no image for props \(props)")
    }

    func testAPlainFileDrawsThatFile() throws {
        let model = try image(props: #""file": \#(file), "width": { "xs": "full" }"#)
        XCTAssertTrue(model.url.absoluteString.hasPrefix("https://images.test/resize/"))
        // A width token is not a pixel width: the request keeps the 960 px default.
        XCTAssertTrue(model.url.absoluteString.hasSuffix("/w:960/bucket/c1/picked.jpg"))
        XCTAssertEqual(model.blurhash, "LKO2")
    }

    func testAResponsiveFileDrawsItsLowestBreakpoint() throws {
        let other = #"{ "containerId": "c1", "name": "large.jpg" }"#
        let xs = try image(props: #""file": { "xs": \#(file), "lg": \#(other) }"#)
        XCTAssertTrue(xs.url.absoluteString.hasSuffix("/c1/picked.jpg"))

        let mdOnly = try image(props: #""file": { "md": \#(file) }"#)
        XCTAssertTrue(mdOnly.url.absoluteString.hasSuffix("/c1/picked.jpg"))

        let smBeforeXl = try image(props: #""file": { "xl": \#(other), "sm": \#(file) }"#)
        XCTAssertTrue(smBeforeXl.url.absoluteString.hasSuffix("/c1/picked.jpg"))

        let threeXlOnly = try image(props: #""file": { "3xl": \#(file) }"#)
        XCTAssertTrue(threeXlOnly.url.absoluteString.hasSuffix("/c1/picked.jpg"))
    }

    func testANullBreakpointIsSkipped() throws {
        let model = try image(props: #""file": { "xs": null, "md": \#(file) }"#)
        XCTAssertTrue(model.url.absoluteString.hasSuffix("/c1/picked.jpg"))
    }

    func testTheOldImagePropIsTheLastFallback() throws {
        let imageOnly = try image(props: #""image": \#(file)"#)
        XCTAssertTrue(imageOnly.url.absoluteString.hasSuffix("/c1/picked.jpg"))

        let other = #"{ "containerId": "c1", "name": "other.jpg" }"#
        let both = try image(props: #""file": \#(file), "image": \#(other)"#)
        XCTAssertTrue(both.url.absoluteString.hasSuffix("/c1/picked.jpg"))
    }

    func testNoFileDrawsNothing() throws {
        XCTAssertNil(try content(props: ""))
        XCTAssertNil(try content(props: #""file": { "xs": null }"#))
    }
}

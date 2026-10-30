// cspell:ignore Kijkwijzer
import XCTest
@testable import HopeTViOS

/// `EpisodeDetail`: the Episode Screen's data (awe#4950). It mirrors the web block
/// (`apps/hope-frontend/components/content/blocks/media-library/EpisodeDetail.js`): text only,
/// no image. Every prop defaults to on, as the builder's `EpisodeDetail.craft.props` does.
final class EpisodeDetailTests: XCTestCase {

    private func model(_ screen: AppScreen) throws -> EpisodeDetailModel {
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources)
        ))
        let block = try XCTUnwrap(node.first { $0.key == .episodeDetail }, "no EpisodeDetail node")
        guard case let .episodeDetail(model) = block.content else {
            XCTFail("EpisodeDetail drew nothing")
            throw CancellationError()
        }
        return model
    }

    /// One `EpisodeDetail` node with the given props and resource.
    private func screen(props: String, detail: String) throws -> AppScreen {
        try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "template",
          "blockResources": { "detail": { "resources": { "episodeDetail": \(detail) } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["detail"] },
            "detail": {
              "type": { "resolvedName": "EpisodeDetail" },
              "props": \(props), "custom": { "type": "plugin", "resources": ["episodeDetail"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
    }

    private let detail = """
    {
      "_id": "e1", "title": "Lesson 1", "abstract": "About the lesson", "episodeViews": 6730,
      "body": { "type": "doc", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Body text" }] }] },
      "image": { "containerId": "c1", "name": "e.jpg", "blurhash": "LCB3" },
      "show": { "_id": "61975e37d9c698836400309f", "title": "Hope Sabbath School" }
    }
    """

    func testTheCapturedEpisodeDrawsFromTheServedBytes() throws {
        let screen = try ContractDecoder.screen(Fixtures.data("episode"))
        let served = try XCTUnwrap(screen.blockResources.values.compactMap { $0["episodeDetail"] }.first)
        let model = try model(screen)

        XCTAssertEqual(model.title, served["title"].string)
        XCTAssertEqual(model.showTitle, served["show"]["title"].string)
        XCTAssertEqual(model.abstract, served["abstract"].string)
        XCTAssertEqual(model.views, served["episodeViews"].int)
        // The captured body is one empty paragraph, which draws no line.
        XCTAssertEqual(model.paragraphs, [])
    }

    func testAbsentPropsShowEveryPart() throws {
        let model = try model(try screen(props: "{}", detail: detail))

        XCTAssertEqual(model.title, "Lesson 1")
        XCTAssertEqual(model.showTitle, "Hope Sabbath School")
        XCTAssertEqual(model.abstract, "About the lesson")
        XCTAssertEqual(model.paragraphs, ["Body text"])
        XCTAssertEqual(model.views, 6730)
    }

    /// Web parity (ruled 2026-09-23): the same five parts as the web block, and no image, even
    /// when the resource serves one. The additions are the "Go to show" target (ruled
    /// 2026-09-28), which is navigation, the age rating and language (awe#6867), the Watch
    /// later toggle (awe#6869) and the Like button (awe#6871), whose snapshot image is for a card,
    /// not drawn here.
    func testItCarriesTheWebBlockPartsAndNoImage() throws {
        let model = try model(try screen(props: "{}", detail: detail))

        XCTAssertEqual(
            Mirror(reflecting: model).children.compactMap(\.label),
            ["title", "showTitle", "views", "abstract", "paragraphs", "showTarget", "ageRating", "language", "watchLater", "like"]
        )
    }

    func testPropsHideTheirPart() throws {
        let props = #"{ "showTitle": false, "showShowTitle": false, "showAbstract": false, "showBody": false, "showViews": false }"#
        let model = try model(try screen(props: props, detail: detail))

        XCTAssertNil(model.title)
        XCTAssertNil(model.showTitle)
        XCTAssertNil(model.abstract)
        XCTAssertEqual(model.paragraphs, [])
        XCTAssertNil(model.views)
    }

    /// Zero views draws no line, as the web renderer does.
    func testZeroViewsAndBlankTextDrawNothing() throws {
        let blank = #"{ "_id": "e1", "title": "T", "abstract": "  ", "episodeViews": 0 }"#
        let model = try model(try screen(props: "{}", detail: blank))

        XCTAssertNil(model.views)
        XCTAssertNil(model.abstract)
        XCTAssertNil(model.showTitle)
    }

    /// "Go to show" opens the show by the card convention: the same path a show card takes.
    func testGoToShowTargetsTheShowByTheConvention() throws {
        let model = try model(try screen(props: "{}", detail: detail))
        XCTAssertEqual(model.showTarget, CardTarget(resourceType: "show", itemId: "61975e37d9c698836400309f"))

        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1, "app": { "design": "tv" }, "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [{ "id": "home", "kind": "static" }, { "id": "show-tpl", "kind": "template", "resourceType": "show" }],
          "preset": {}
        }
        """.utf8))
        let target = model.showTarget
        let stack = MainActor.assumeIsolated { () -> [StackEntry] in
            let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
            router.openCard(target)
            return router.state.stack
        }
        XCTAssertEqual(stack, [StackEntry(screenId: "show-tpl", param: "61975e37d9c698836400309f")])
    }

    /// A body-only instance (the second `EpisodeDetail` of a split Episode screen) draws no
    /// heading, so it draws no second "Go to show".
    func testNoHeadingDrawsNoGoToShow() throws {
        let bodyOnly = #"{ "showTitle": false, "showShowTitle": false, "showViews": false, "showAbstract": false, "showBody": true }"#
        let model = try model(try screen(props: bodyOnly, detail: detail))

        XCTAssertNil(model.showTarget)
        XCTAssertNil(model.title)
        XCTAssertNil(model.showTitle)
        XCTAssertEqual(model.paragraphs, ["Body text"])

        // Either heading part alone still offers it.
        XCTAssertNotNil(try self.model(try screen(props: #"{ "showTitle": false }"#, detail: detail)).showTarget)
        XCTAssertNotNil(try self.model(try screen(props: #"{ "showShowTitle": false }"#, detail: detail)).showTarget)
    }

    /// One rule with the player's Info panel: a served ObjectId only (`CardTarget.show(id:)`).
    func testAShowIdThatIsNotAnObjectIdDrawsNoGoToShow() throws {
        let freeText = detail.replacingOccurrences(of: #""_id": "61975e37d9c698836400309f""#, with: #""_id": "Hope Sabbath School""#)
        XCTAssertNil(try model(try screen(props: "{}", detail: freeText)).showTarget)
    }

    /// The button draws only when the convention opens a screen: exactly one `show` template.
    @MainActor
    func testGoToShowOpensOnlyWithExactlyOneShowTemplate() throws {
        let target = try XCTUnwrap(try model(try screen(props: "{}", detail: detail)).showTarget)
        func router(_ templates: [String]) throws -> AppRouter {
            let rows = templates.map { "{ \"id\": \"\($0)\", \"kind\": \"template\", \"resourceType\": \"show\" }" }
            let manifest = try ContractDecoder.manifest(Data("""
            {
              "contractVersion": 1, "app": { "design": "tv" }, "defaultLayoutId": "l1",
              "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
              "screens": [{ "id": "home", "kind": "static" }\(rows.isEmpty ? "" : ", " + rows.joined(separator: ", "))],
              "preset": {}
            }
            """.utf8))
            return AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
        }

        XCTAssertTrue(try router(["show-tpl"]).canOpenCard(target))
        XCTAssertFalse(try router([]).canOpenCard(target), "no show template: no dead button")
        XCTAssertFalse(try router(["a", "b"]).canOpenCard(target), "two show templates: no dead button")
    }

    /// The evaluator asks the router, so a button that could open nothing is never built, and
    /// the default-focus role agrees with the view (one source of truth).
    /// The fixture episode id (`e1`) is no ObjectId, so no Watch later toggle draws. A served
    /// episode always has one: see `testAServedEpisodeAsksWithItsWatchLaterToggle`.
    func testAShowThatCannotOpenBuildsNoButtonAndNoFocusRequest() throws {
        let screen = try screen(props: "{}", detail: detail)
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId, document: screen.content,
            context: RenderContext(blockResources: screen.blockResources, images: TestRender.context().images,
                                   canOpenCard: { _ in false })
        ))
        guard case let .episodeDetail(model) = try XCTUnwrap(node.first { $0.key == .episodeDetail }).content else {
            return XCTFail("EpisodeDetail drew nothing")
        }
        XCTAssertNil(model.showTarget)
        XCTAssertEqual(node.firstFocusStop, .readsOnly, "the text panel is the stop, and it does not ask")
        XCTAssertNil(node.firstFocusNodeId)

        // When it can open, the block asks.
        let opening = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                           context: TestRender.context(blockResources: screen.blockResources)))
        XCTAssertEqual(opening.firstFocusNodeId, "detail")
    }

    /// With a served ObjectId, the Watch later toggle asks for the default focus, also when Go to
    /// show cannot open (awe#6869, ruled 2026-10-15).
    func testAServedEpisodeAsksWithItsWatchLaterToggle() throws {
        let served = detail.replacingOccurrences(of: #""_id": "e1""#, with: #""_id": "629ecd4ce1e081635d11107e""#)
        let screen = try screen(props: "{}", detail: served)
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId, document: screen.content,
            context: RenderContext(blockResources: screen.blockResources, images: TestRender.context().images,
                                   canOpenCard: { _ in false })
        ))
        guard case let .episodeDetail(model) = try XCTUnwrap(node.first { $0.key == .episodeDetail }).content else {
            return XCTFail("EpisodeDetail drew nothing")
        }
        XCTAssertNil(model.showTarget)
        XCTAssertNotNil(model.watchLater)
        XCTAssertEqual(node.firstFocusNodeId, "detail")
    }

    func testNoShowIdDrawsNoGoToShow() throws {
        let noShow = detail.replacingOccurrences(of: #""show": { "_id": "61975e37d9c698836400309f", "title": "Hope Sabbath School" }"#,
                                                 with: #""show": { "title": "Hope Sabbath School" }"#)
        XCTAssertNil(try model(try screen(props: "{}", detail: noShow)).showTarget)
    }

    /// The captured Episode Screen serves `episodeDetail.show._id`, so it offers "Go to show".
    func testTheCapturedEpisodeOffersGoToShow() throws {
        let screen = try ContractDecoder.screen(Fixtures.data("episode"))
        let served = try XCTUnwrap(screen.blockResources.values.compactMap { $0["episodeDetail"] }.first)
        XCTAssertEqual(try model(screen).showTarget?.itemId, served["show"]["_id"].string)
    }

    func testAMissingResourceDrawsNothing() throws {
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: try screen(props: "{}", detail: "null").content,
            context: TestRender.context()
        ))
        XCTAssertNil(try XCTUnwrap(node.first { $0.key == .episodeDetail }).content)
    }

    // MARK: Age rating and language (awe#6867)

    /// The detail with extra served fields. The server resolves both (Episode, else Show; the
    /// language also falls back to the channel), so the block draws what is served.
    private func served(_ fields: String) -> String {
        detail.replacingOccurrences(of: #""episodeViews": 6730,"#, with: #""episodeViews": 6730, "# + fields + ",")
    }

    func testThePrimaryRatingAndTheLanguageDraw() throws {
        let fields = #""ageRatings": [{ "system": "fsk", "value": "12", "descriptors": [] }, { "system": "mpa", "value": "R", "descriptors": [] }], "language": "Deutsch""#
        let model = try model(try screen(props: "{}", detail: served(fields)))

        XCTAssertEqual(model.ageRating, "FSK 12", "the first item only")
        XCTAssertEqual(model.language, "Deutsch")
    }

    /// A rating the Episode inherits from its Show arrives in the same field.
    func testAnInheritedCustomRatingDraws() throws {
        let fields = #""ageRatings": [{ "system": "custom", "label": "Kijkwijzer", "minAge": 9, "descriptors": [] }], "language": null"#
        let model = try model(try screen(props: "{}", detail: served(fields)))

        XCTAssertEqual(model.ageRating, "Kijkwijzer 9+")
        XCTAssertNil(model.language)
    }

    /// No value draws nothing: no empty badge, no empty language line.
    func testNoRatingAndNoLanguageDrawNothing() throws {
        let old = try model(try screen(props: "{}", detail: detail))
        XCTAssertNil(old.ageRating, "a server that serves neither field")
        XCTAssertNil(old.language)

        let empty = try model(try screen(props: "{}", detail: served(#""ageRatings": [], "language": "  ""#)))
        XCTAssertNil(empty.ageRating)
        XCTAssertNil(empty.language, "blank text is nothing to draw")

        let unknown = try model(try screen(props: "{}", detail: served(#""ageRatings": [{ "system": "fsk", "value": "13" }]"#)))
        XCTAssertNil(unknown.ageRating, "a value outside the catalog draws no badge")
    }

    /// Both belong to the heading group, as "Go to show" does: a body-only second instance on
    /// the same screen draws no second badge.
    func testNoHeadingDrawsNoRatingAndNoLanguage() throws {
        let fields = served(#""ageRatings": [{ "system": "fsk", "value": "12" }], "language": "Deutsch""#)
        let bodyOnly = #"{ "showTitle": false, "showShowTitle": false, "showViews": false, "showAbstract": false, "showBody": true }"#
        let model = try model(try screen(props: bodyOnly, detail: fields))

        XCTAssertNil(model.ageRating)
        XCTAssertNil(model.language)
        XCTAssertEqual(try self.model(try screen(props: #"{ "showTitle": false }"#, detail: fields)).ageRating, "FSK 12",
                       "either heading part alone still draws it")
    }
}

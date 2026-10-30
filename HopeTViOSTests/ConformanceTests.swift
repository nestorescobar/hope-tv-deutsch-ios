import XCTest
@testable import HopeTViOS

/// Conformance against the shared `expectations.json`.
///
/// The same file drives the DOM renderer's Vitest suite. `render` / `renderNull` are the
/// two sides of "did this block key reach a renderer, and did it draw anything"; a
/// `clientOwned` key satisfies the fixture either way.
final class ManifestConformanceTests: XCTestCase {

    private func manifest() throws -> AppManifest {
        try ContractDecoder.manifest(Fixtures.data("manifest"))
    }

    private func expected() throws -> JSONValue {
        try Fixtures.json("expectations")["manifest"]
    }

    func testManifestMatchesTheCapturedExpectations() throws {
        let manifest = try manifest()
        let expected = try expected()

        XCTAssertEqual(manifest.contractVersion, expected["contractVersion"].int)
        XCTAssertEqual(manifest.app.design, expected["appDesign"].string)
        XCTAssertNil(manifest.entryScreenId)
        XCTAssertEqual(manifest.entryScreenId, expected["entryScreenId"].string)
        XCTAssertEqual(manifest.defaultLayoutId, expected["defaultLayoutId"].string)
    }

    func testTheTreeCarriesTheThreeTabsAndOneAuthoringNote() throws {
        let manifest = try manifest()
        let expected = try expected()
        let tree = NavigationTree(manifest: manifest)
        let layoutId = try XCTUnwrap(expected["defaultLayoutId"].string)

        XCTAssertEqual(tree.layouts[layoutId]?.tabs.map(\.label), expected["tabs"].array.compactMap(\.string))
        // Derived, not hard-coded: this App is authored with no entry Screen, so the shell
        // opens on the default layout and the first tab is the one root the back key exits.
        let firstTab = try XCTUnwrap(tree.layouts[layoutId]?.tabs.first?.screenId)
        XCTAssertEqual(tree.initialRoute, .layout(layoutId: layoutId, screenId: firstTab))
        XCTAssertEqual(tree.issues, ["App has no entry screen"])
        XCTAssertEqual(tree.rootScreenId, tree.layouts[layoutId]?.tabs.first?.screenId)
    }

    func testTheLayoutChromeRendersDownToItsOneContentPlaceholder() throws {
        let manifest = try manifest()
        let layout = try XCTUnwrap(manifest.layouts.first { $0.id == manifest.defaultLayoutId })
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: layout.content,
            context: TestRender.context()
        ))

        XCTAssertEqual(node.keyReport.rendered.sorted(), ["ContentPlaceholder", "Root"])
        XCTAssertTrue(node.keyReport.null.isEmpty)
    }

    func testTheManifestDesignGateAcceptsTv() throws {
        XCTAssertNil(ContractValidator.assertManifestDesign(try manifest()))
    }
}

final class ScreenConformanceTests: XCTestCase {

    private func check(_ name: String, watchHistory: [WatchProgressStore.Entry] = []) throws -> TestRender.Result {
        let expected = try Fixtures.json("expectations")["screens"][name]
        let result = try TestRender.screen(name, watchHistory: watchHistory)

        // The captured body has to be the screen the fixture names, or every assertion below
        // is measuring the wrong response.
        XCTAssertEqual(result.screen.id, expected["id"].string, "\(name): screen id")

        // `clientOwned` keys are removed from both sides, then checked separately: the
        // block must still REACH a renderer.
        let clientOwned = Set(expected["clientOwned"].array.compactMap(\.string))
        let strict = { (keys: Set<String>) in keys.subtracting(clientOwned).sorted() }

        XCTAssertEqual(strict(result.rendered), expected["render"].array.compactMap(\.string).sorted(), "\(name): rendered keys")
        XCTAssertEqual(strict(result.null), expected["renderNull"].array.compactMap(\.string).sorted(), "\(name): null keys")

        for key in clientOwned {
            XCTAssertTrue(result.rendered.contains(key) || result.null.contains(key), "\(name): \(key) never reached a renderer")
        }

        for (path, value) in expected["resources"].object {
            try assertResource(path: path, expected: value, screen: result.screen, name: name)
        }

        return result
    }

    /// `nodeId.resourceName.field` against `blockResources`. An array asserts its length, a
    /// number or a string asserts its value, and `"present"` asserts only that it is served.
    private func assertResource(path: String, expected: JSONValue, screen: AppScreen, name: String) throws {
        let parts = path.split(separator: ".").map(String.init)
        XCTAssertGreaterThanOrEqual(parts.count, 3, "\(name): \(path) is not nodeId.resource.field")
        let resource = try XCTUnwrap(screen.blockResources[parts[0]]?[parts[1]], "\(name): \(path) is not served")
        let value = parts.dropFirst(2).reduce(resource) { $0[$1] }

        if case let .array(items) = value {
            XCTAssertEqual(items.count, expected.int, "\(name): \(path) item count")
        } else if expected.string == "present" {
            XCTAssertFalse(value.isNull, "\(name): \(path) is not served")
        } else {
            XCTAssertEqual(value, expected, "\(name): \(path) value")
        }
    }

    // MARK: - Screens

    func testHomeRendersEveryExpectedKey() throws {
        _ = try check("home")
    }

    func testHomeLeadsTheFeaturedShelfWithTheExpectedShow() throws {
        let result = try check("home")
        let expected = try Fixtures.json("expectations")["screens"]["home"]

        XCTAssertEqual(result.firstCardTitle, expected["firstCardTitle"].string)
    }

    /// Staging has an EPG since the 2026-09-23 re-capture. The count is time-bound: the EPG
    /// moves by the hour, so a re-capture changes it.
    func testHomeDrawsOneScheduleRowPerServedBroadcast() throws {
        let result = try check("home")
        let schedule = try XCTUnwrap(result.node.first { $0.key == .scheduleLive })
        let items = TestRender.scheduleRows(try XCTUnwrap(result.screen.blockResources[schedule.id]?["broadcastsLive"]))

        guard case let .schedule(model) = schedule.content else { return XCTFail("ScheduleLive drew nothing") }
        XCTAssertFalse(items.isEmpty)
        // The captured on-air row serves no `episodeTitle`; its title is the populated episode's.
        XCTAssertEqual(model.entries.map(\.title), items.map { $0["episodeTitle"].string ?? $0["episode"]["title"].string ?? "" })
        XCTAssertNil(model.emptyMessage)
    }

    /// Nothing is watched in this suite, so the client-owned block answers null. With local
    /// progress it answers a shelf; the fixture accepts both.
    func testHomeWatchHistoryIsNullWithoutLocalProgressAndAShelfWithIt() throws {
        XCTAssertEqual(try check("home").null, ["EpisodeWatchHistory"])

        let entry = WatchProgressStore.Entry(playableId: "e1", title: "Watched", subtitle: "", fraction: 0.4, updatedAt: Date())
        let withProgress = try check("home", watchHistory: [entry])
        XCTAssertTrue(withProgress.rendered.contains("EpisodeWatchHistory"))
    }

    func testBrowseRendersTheShowsGridAtTheServedCount() throws {
        let result = try check("browse")
        let grid = try XCTUnwrap(result.node.first { $0.key == .showList })

        guard case let .shelf(model) = grid.content else { return XCTFail("ShowList drew nothing") }
        XCTAssertEqual(model.cards.count, 35)
        XCTAssertEqual(model.title, "Shows (39)")
        XCTAssertEqual(model.layout, .grid)
    }

    /// `shows` serves `images.banner` beside `images.default` (awe#4682). A landscape card takes
    /// the default slot first: banner art is hero art (focus on the right, no title). So a show
    /// with both draws its default image.
    func testBrowseCardsTakeTheDefaultSlotOverTheBanner() throws {
        let result = try check("browse")
        let grid = try XCTUnwrap(result.node.first { $0.key == .showList })

        guard case let .shelf(model) = grid.content else { return XCTFail("ShowList drew nothing") }
        let encounters = try XCTUnwrap(model.cards.first { $0.title == "Encounters" })
        XCTAssertEqual(encounters.imageURL?.absoluteString.contains("onI1652266789424.JPG"), true)

        let celebration = try XCTUnwrap(model.cards.first { $0.title == "Celebration of Hope" })
        XCTAssertEqual(celebration.imageURL?.absoluteString.contains("4Dm1727853937952.jpg"), false)
        XCTAssertNotNil(celebration.imageURL)
    }

    func testBrowseCarriesTheScreenLinkTheButtonWasAuthoredWith() throws {
        let result = try check("browse")
        let expected = try Fixtures.json("expectations")["screens"]["browse"]["buttonLink"]
        let button = try XCTUnwrap(result.node.first { $0.key == .button })

        guard case let .button(model) = button.content else { return XCTFail("Button drew nothing") }
        XCTAssertEqual(model.linkType, expected["linkType"].string)
        XCTAssertEqual(model.screenId, expected["screen"].string)
        XCTAssertEqual(model.screenParam, expected["screenParam"].string)
        XCTAssertEqual(model.label, "Featured show")
    }

    /// The link resolves against the manifest, and a link to an unknown screen resolves to
    /// nothing rather than to some other screen.
    func testTheBrowseButtonLinkResolvesToTheShowTemplate() throws {
        let tree = NavigationTree(manifest: try ContractDecoder.manifest(Fixtures.data("manifest")))
        let expected = try Fixtures.json("expectations")["screens"]["browse"]["buttonLink"]

        let target = tree.resolveTarget(screenId: expected["screen"].string, param: expected["screenParam"].string, currentParam: nil)
        XCTAssertEqual(target?.screenId, expected["screen"].string)
        XCTAssertEqual(target?.param, expected["screenParam"].string)

        XCTAssertNil(tree.resolveTarget(screenId: "not-a-screen", param: nil, currentParam: nil))
        // A template screen with no param would make the contract answer 400.
        XCTAssertNil(tree.resolveTarget(screenId: expected["screen"].string, param: nil, currentParam: nil))
    }

    func testLiveHandsTheChannelHlsToThePlayer() throws {
        let result = try check("live")
        let player = try XCTUnwrap(result.node.first { $0.key == .livestreamPlayer })
        let channel = try XCTUnwrap(result.screen.blockResources["player"]?["channel"])

        guard case let .player(model) = player.content else { return XCTFail("LivestreamPlayer drew nothing") }
        XCTAssertEqual(model.request.url.absoluteString, channel["hls"].string)
        XCTAssertEqual(model.request.url.scheme, "https")
    }

    func testShowTemplateRendersTheBoundShow() throws {
        let result = try check("show")
        let expected = try Fixtures.json("expectations")["screens"]["show"]
        let detail = try XCTUnwrap(result.node.first { $0.key == .showDetail })

        guard case let .detail(model) = detail.content else { return XCTFail("ShowDetail drew nothing") }
        XCTAssertEqual(model.title, expected["resources"]["detail.showDetail.title"].string)
    }

    /// awe#4412 (fixed, PR #4665): the Frontend API evaluates the block condition after the
    /// resources are inlined, so `EpisodesList` reaches the renderer with the first page.
    func testShowRendersTheEpisodesList() throws {
        let result = try check("show")

        XCTAssertTrue(result.rendered.contains("EpisodesList"), "show: EpisodesList did not draw")
        XCTAssertTrue(result.screen.content.nodes.values.contains { $0.resolvedName == "EpisodesList" })
    }

    /// awe#4950: the Episode template serves a Jetstream media id, not a url. The player draws
    /// the poster and Play (it never plays inline); Play carries the manifest the Jetstream rule
    /// derives from that id, titled from the screen's `resources.Episode`.
    func testEpisodeTemplateOffersTheJetstreamManifestBehindPlay() throws {
        let result = try check("episode")
        let player = try XCTUnwrap(result.node.first { $0.key == .episodePlayer })
        let resource = try XCTUnwrap(result.screen.blockResources[player.id]?["episodePlayer"])
        let resolved = try XCTUnwrap(PlaybackService.episodeSource(resource), "episode: no playable source")

        guard case let .playAction(model) = player.content else { return XCTFail("EpisodePlayer drew no play action") }
        let request = try XCTUnwrap(model.request)
        XCTAssertEqual(request.url, resolved.url)
        XCTAssertEqual(request.url.absoluteString, "https://jstre.am/videos/\(resource["id"].string ?? "")/hls/main.m3u8")
        XCTAssertEqual(model.label, "Play")
        XCTAssertEqual(model.posterURL?.absoluteString, resource["poster"].string)
        XCTAssertEqual(request.metadata.title, result.screen.resources["Episode"]?["title"].string)
    }

    /// Content order is kept: the owner authored the player above the detail.
    func testEpisodeTemplateDrawsThePlayerThenTheDetail() throws {
        let result = try check("episode")
        let expected = try Fixtures.json("expectations")["screens"]["episode"]["resources"]
        let container = try XCTUnwrap(result.node.first { $0.key == .container })

        XCTAssertEqual(container.children.map(\.key), [.episodePlayer, .episodeDetail])
        guard case let .episodeDetail(model) = container.children.last?.content else {
            return XCTFail("EpisodeDetail drew nothing")
        }
        XCTAssertEqual(model.title, expected["4SQMb_-iqc.episodeDetail.title"].string)
        XCTAssertEqual(model.showTitle, expected["4SQMb_-iqc.episodeDetail.show.title"].string)
    }
}

/// Renders a fixture screen the way the app does, and reports what drew.
enum TestRender {
    struct Result {
        let screen: AppScreen
        let node: EvaluatedNode
        let rendered: Set<String>
        let null: Set<String>

        /// The first card of the first shelf that has one, in document order.
        var firstCardTitle: String? {
            node.first {
                if case let .shelf(model) = $0.content { return !model.cards.isEmpty }
                return false
            }
            .flatMap {
                if case let .shelf(model) = $0.content { return model.cards.first?.title }
                return nil
            }
        }
    }

    static func context(
        blockResources: [String: [String: JSONValue]] = [:],
        screenResources: [String: JSONValue] = [:],
        watchHistory: [WatchProgressStore.Entry] = [],
        resumePoints: [String: Double] = [:],
        watchLater: [SavedItem] = []
    ) -> RenderContext {
        RenderContext(
            blockResources: blockResources,
            screenResources: screenResources,
            images: ImageConfig(cdn: "https://images.test", bucket: "bucket"),
            watchHistory: watchHistory,
            resumePoints: resumePoints,
            watchLater: watchLater
        )
    }

    static func screen(_ name: String, watchHistory: [WatchProgressStore.Entry] = []) throws -> Result {
        let screen = try ContractDecoder.screen(Fixtures.data(name))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: context(blockResources: screen.blockResources, screenResources: screen.resources, watchHistory: watchHistory)
        ))
        let report = node.keyReport
        return Result(screen: screen, node: node, rendered: report.rendered, null: report.null)
    }

    /// The broadcasts a served `broadcastsLive` draws, in order: `current` when it is an object,
    /// then every `items` row whose id is not the current one's (awe#5033).
    static func scheduleRows(_ broadcastsLive: JSONValue) -> [JSONValue] {
        let current = broadcastsLive["current"]
        guard case .object = current else { return broadcastsLive["items"].array }
        let currentId = current["id"].text ?? current["_id"].text
        return [current] + broadcastsLive["items"].array.filter { ($0["id"].text ?? $0["_id"].text) != currentId }
    }
}

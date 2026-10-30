// cspell:ignore Andacht Bibelkompass bibelkompass Bindung Folgen Heute
import XCTest
@testable import HopeTViOS

/// The card convention.
///
/// A card opens the manifest's Template Screen whose `resourceType` equals the item's type,
/// with `param` = the item's id. Exactly one candidate opens; zero or several is a no-op plus
/// one log per resource type. A served `screenLink` wins over the convention (awe#4519).
@MainActor
final class CardRoutingTests: XCTestCase {

    // MARK: - Manifests

    /// `templates` is a list of `(id, resourceType)` pairs.
    private func manifest(templates: [(String, String)], statics: [String] = ["home"]) throws -> AppManifest {
        let templateRows = templates
            .map { "{ \"id\": \"\($0.0)\", \"kind\": \"template\", \"resourceType\": \"\($0.1)\" }" }
        let staticRows = statics.map { "{ \"id\": \"\($0)\", \"kind\": \"static\" }" }
        let tabs = statics.map { "{ \"screenId\": \"\($0)\", \"label\": \"\($0)\" }" }

        return try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [\(tabs.joined(separator: ", "))] } }],
          "screens": [\((staticRows + templateRows).joined(separator: ", "))],
          "preset": {}
        }
        """.utf8))
    }

    private func router(_ manifest: AppManifest) -> AppRouter {
        AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
    }

    private func card(_ resourceType: String, _ itemId: String?) -> CardModel {
        CardModel(
            id: itemId ?? "shelf:0",
            title: "Card",
            subtitle: nil,
            imageURL: nil,
            blurhash: nil,
            badge: nil,
            progress: nil,
            target: itemId.map { CardTarget(resourceType: resourceType, itemId: $0) }
        )
    }

    private func refusals(_ router: AppRouter) -> Int {
        router.diagnostics.entries.filter { $0.title == "Card press ignored" }.count
    }

    // MARK: - Resolution table

    func testOneCandidateOpensTheTemplateWithTheItemId() throws {
        let router = router(try manifest(templates: [("show-tpl", "show")]))

        router.openCard(card("show", "abc123").target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "show-tpl", param: "abc123")])
        XCTAssertEqual(refusals(router), 0)
    }

    func testZeroCandidatesIsANoOpAndLogsOncePerResourceType() throws {
        // This synthetic manifest has no `episode` template.
        let router = router(try manifest(templates: [("show-tpl", "show")]))

        router.openCard(card("episode", "ep1").target)
        router.openCard(card("episode", "ep2").target)

        XCTAssertTrue(router.state.stack.isEmpty)
        XCTAssertEqual(refusals(router), 1)

        // A different resource type reports on its own.
        router.openCard(card("article", "a1").target)
        XCTAssertEqual(refusals(router), 2)
    }

    func testSeveralCandidatesIsANoOpAndLogsOnce() throws {
        let router = router(try manifest(templates: [("show-a", "show"), ("show-b", "show")]))

        router.openCard(card("show", "abc123").target)
        router.openCard(card("show", "abc123").target)

        XCTAssertTrue(router.state.stack.isEmpty, "two candidates must never pick one")
        XCTAssertEqual(refusals(router), 1)
    }

    func testACardWithNoRecordIdOpensNothing() throws {
        let router = router(try manifest(templates: [("show-tpl", "show")]))
        let noId = card("show", nil)

        XCTAssertNil(noId.target)
        router.openCard(noId.target)

        XCTAssertTrue(router.state.stack.isEmpty)
        XCTAssertEqual(refusals(router), 1)
    }

    /// The convention never guesses across types: a show card cannot open an episode template.
    func testAShowCardNeverOpensAnEpisodeTemplate() throws {
        let router = router(try manifest(templates: [("episode-tpl", "episode")]))

        router.openCard(card("show", "abc123").target)

        XCTAssertTrue(router.state.stack.isEmpty)
        XCTAssertEqual(refusals(router), 1)
    }

    // MARK: - The staging manifest

    func testTheStagingManifestResolvesAShowCardAndAnEpisodeCardToTheirTemplates() throws {
        let manifest = try ContractDecoder.manifest(Fixtures.data("manifest"))
        let router = router(manifest)
        let screens = try Fixtures.json("expectations")["screens"]
        let showId = try XCTUnwrap(screens["show"]["param"].string)
        let episodeId = try XCTUnwrap(screens["episode"]["param"].string)

        router.openCard(card("show", showId).target)

        // The same Template Screen the Browse Button opens, reached by convention instead.
        XCTAssertEqual(router.state.stack.first?.screenId, screens["show"]["id"].string)
        XCTAssertEqual(router.state.stack.first?.param, showId)

        // The Episode template exists since awe#4950, so an episode card resolves too.
        router.openCard(card("episode", episodeId).target)
        XCTAssertEqual(router.state.stack.last, StackEntry(screenId: screens["episode"]["id"].string ?? "", param: episodeId))
        XCTAssertEqual(router.state.stack.count, 2)
        XCTAssertEqual(refusals(router), 0)
    }

    /// A card press pushes onto the tab it was pressed from, so the back key returns there.
    func testAPressedCardPushesOntoTheCurrentTabAndPopsBackToIt() throws {
        let manifest = try ContractDecoder.manifest(Fixtures.data("manifest"))
        let router = router(manifest)
        let browseTab = try XCTUnwrap(router.tree.tabs.first { $0.label == "Browse" })
        let rootScreenId = try XCTUnwrap(router.tree.rootScreenId)

        router.state.selectTab(browseTab.screenId)
        router.openCard(card("show", "61975e24d9c698836400305c").target)
        XCTAssertEqual(router.state.stack.count, 1)

        XCTAssertTrue(router.state.goBack(rootScreenId: rootScreenId))
        XCTAssertTrue(router.state.stack.isEmpty)
        XCTAssertEqual(router.state.tabScreenId, browseTab.screenId, "back returns to the tab the card was on")
    }
}

/// `ScheduleLive` rows (ruled 2026-09-23, awe#4989).
///
/// A row that carries a populated `episode` record opens THAT episode, as every episode card
/// does: the served `episode.screenLink` first, else the `episode` template by convention. A
/// title-only row carries no target, so it draws without a button. The shapes are the Frontend
/// API's own (`apis/frontend/modules/media-library/resources/broadcastsLive.js`): a linked row
/// populates `episode { _id title image slug show screenLink? }`; a title-only row serves only
/// `episodeTitle`, `showTitle`, `startsAt`, `endsAt` and its own `id`.
@MainActor
final class ScheduleRowRoutingTests: XCTestCase {

    private let showId = "61975e24d9c698836400305c"
    private let episodeId = "6a049248c6d68f1e30573243"

    private func router() throws -> AppRouter {
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [
            { "id": "home", "kind": "static" },
            { "id": "show-tpl", "kind": "template", "resourceType": "show" },
            { "id": "episode-tpl", "kind": "template", "resourceType": "episode" },
            { "id": "movie-tpl", "kind": "template", "resourceType": "movie" },
            { "id": "linked-tpl", "kind": "template", "resourceType": "other" }
          ],
          "preset": {}
        }
        """.utf8))
        return AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
    }

    /// `current` is the JSON of `broadcastsLive.current`; `nil` leaves the key out. `channel` is
    /// the node's `channel` resource.
    private func screen(
        _ items: String,
        current: String? = "null",
        channel: String = #"{ "title": "HC North America" }"#,
        props: String = "{}"
    ) throws -> AppScreen {
        try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "strip": {
              "resources": {
                "channel": \(channel),
                "broadcastsLive": { \(current.map { #""current": \#($0), "# } ?? "")"items": [\(items)], "count": 1 }
              }
            }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["strip"] },
            "strip": {
              "type": { "resolvedName": "ScheduleLive" },
              "props": \(props), "custom": { "type": "plugin", "resources": ["channel", "broadcastsLive"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
    }

    private func model(_ screen: AppScreen) throws -> ScheduleModel {
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources)
        ))
        let strip = try XCTUnwrap(node.first { $0.key == .scheduleLive })
        guard case let .schedule(model) = strip.content else {
            return try XCTUnwrap(nil as ScheduleModel?, "ScheduleLive drew nothing")
        }
        return model
    }

    private func entries(_ screen: AppScreen) throws -> [ScheduleModel.Entry] {
        try model(screen).entries
    }

    /// A row whose `episode` field is the given JSON. `nil` leaves the key out (a title-only row).
    private func broadcast(id: String = "b1", title: String = "Reassurance", episode: String?) -> String {
        """
        {
          "_id": "\(id)",
          "id": "\(id)",
          "episodeTitle": "\(title)",
          "showTitle": "Celebration of Hope",
          "startsAt": "2026-09-18T19:00:00.000Z",
          "endsAt": "2026-09-18T19:30:00.000Z"\(episode.map { #", "episode": \#($0)"# } ?? "")
        }
        """
    }

    private func episode(link: String = "", image: String = "") -> String {
        #"""
        { "_id": "\#(episodeId)", "title": "Reassurance", "slug": "reassurance",
          "show": { "_id": "\#(showId)", "title": "Celebration of Hope" }\#(link)\#(image) }
        """#
    }

    private func firstTarget(_ episode: String?) throws -> CardTarget? {
        try XCTUnwrap(try entries(try screen(broadcast(episode: episode))).first).target
    }

    func testALinkedRowOpensTheEpisodeTemplateByConvention() throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: episode()))).first)

        XCTAssertEqual(row.title, "Reassurance")
        XCTAssertEqual(row.target, CardTarget(resourceType: "episode", itemId: episodeId))

        let router = try router()
        router.openCard(row.target)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: episodeId)])
    }

    func testALinkedRowWithAServedScreenLinkOpensTheLinkedScreen() throws {
        let link = #", "screenLink": { "linkType": "screen", "screen": "linked-tpl", "screenParam": "\#(episodeId)" }"#
        let target = try firstTarget(episode(link: link))

        let router = try router()
        router.openCard(target)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "linked-tpl", param: episodeId)])
    }

    func testATitleOnlyRowCarriesNoTarget() throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: nil))).first)

        XCTAssertEqual(row.title, "Reassurance")
        XCTAssertNil(row.target, "the broadcast's own id is not an episode to open")
    }

    func testARowWithAnUnpopulatedEpisodeCarriesNoTarget() throws {
        // An unpopulated ref is a bare id string, not a record.
        XCTAssertNil(try firstTarget(#""\#(episodeId)""#))
        XCTAssertNil(try firstTarget("null"))
        XCTAssertNil(try firstTarget("{ }"))
    }

    /// The show is on the record, but the row is about the episode: no id, no target.
    func testARowNeverFallsBackToTheShow() throws {
        XCTAssertNil(try firstTarget(#"{ "title": "Reassurance", "show": { "_id": "\#(showId)" } }"#))
    }

    /// A title-only row is normal data, so it reports nothing.
    func testATitleOnlyRowReportsNoRenderIssue() throws {
        RenderIssueLog.reset()
        defer { RenderIssueLog.reset() }

        _ = try entries(try screen(broadcast(episode: nil)))

        XCTAssertTrue(RenderIssueLog.report("broadcast-without-show"), "a title-only row logged a render issue")
    }

    // MARK: Focus (awe#5036)

    /// A linked row is the pressable kind, and it carries its episode target.
    func testALinkedRowIsTheLinkedKind() throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: episode()))).first)

        XCTAssertEqual(row.kind, .linked(CardTarget(resourceType: "episode", itemId: episodeId)))
    }

    /// A title-only row is the information kind: a focus stop that opens nothing.
    func testATitleOnlyRowIsTheInformationKind() throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: nil))).first)

        XCTAssertEqual(row.kind, .information)
        XCTAssertNil(row.target)
    }

    /// Every row of a mixed strip is present, the on-air row too, each with its own kind.
    func testEveryRowOfAMixedStripKeepsItsKind() throws {
        let items = [broadcast(id: "b1", episode: episode()), broadcast(id: "b2", episode: nil)]
        let rows = try entries(try screen(items.joined(separator: ","),
                                          current: broadcast(id: "now", episode: nil)))

        XCTAssertEqual(rows.map(\.id), ["now", "b1", "b2"])
        XCTAssertEqual(rows.map(\.kind), [
            .information,
            .linked(CardTarget(resourceType: "episode", itemId: episodeId)),
            .information,
        ])
    }

    // MARK: Thumbnail (awe#5031)

    /// A linked row's flat `episode.image` resolves through the shell image config, like a card.
    func testALinkedRowWithAnImageCarriesItsThumbnail() throws {
        let file = #"{ "name": "reassurance.jpg", "containerId": "c1", "blurhash": "LEHV6nWB2yk8" }"#
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: episode(image: #", "image": \#(file)"#)))).first)

        let json = try JSONDecoder().decode(JSONValue.self, from: Data(file.utf8))
        let expected = try XCTUnwrap(TestRender.context().images.url(ImageFile(json), width: 640))
        XCTAssertEqual(row.imageURL, expected)
        XCTAssertEqual(row.blurhash, "LEHV6nWB2yk8")
    }

    func testALinkedRowWithoutAnImageCarriesNoThumbnail() throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: episode()))).first)

        XCTAssertNotNil(row.target, "the row is still pressable")
        XCTAssertNil(row.imageURL)
        XCTAssertNil(row.blurhash)
    }

    /// An image without `containerId` cannot build a URL, so the row draws with no image slot.
    func testALinkedRowWithAnIncompleteImageCarriesNoThumbnail() throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: episode(image: #", "image": { "name": "x.jpg" }"#)))).first)

        XCTAssertNotNil(row.target, "the row is still pressable")
        XCTAssertNil(row.imageURL)
        XCTAssertNil(row.blurhash)
    }

    func testATitleOnlyRowCarriesNoThumbnail() throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: nil))).first)

        XCTAssertNil(row.imageURL)
        XCTAssertNil(row.blurhash)
    }

    // MARK: The on-air broadcast (awe#5033)

    /// `broadcastsLive.current` draws first, marked on air, before `items` in served order.
    func testTheCurrentBroadcastDrawsFirstAndMarkedOnAir() throws {
        let items = [broadcast(id: "b1", title: "Next", episode: nil), broadcast(id: "b2", title: "Later", episode: nil)]
        let rows = try entries(try screen(items.joined(separator: ","),
                                          current: broadcast(id: "now", title: "On Air", episode: episode())))

        XCTAssertEqual(rows.map(\.id), ["now", "b1", "b2"])
        XCTAssertEqual(rows.map(\.title), ["On Air", "Next", "Later"])
        XCTAssertEqual(rows.map(\.isCurrent), [true, false, false])
    }

    /// A null or missing `current` keeps the items-only rows, none on air.
    func testANullOrMissingCurrentDrawsOnlyTheItems() throws {
        let items = [broadcast(id: "b1", episode: nil), broadcast(id: "b2", episode: episode())].joined(separator: ",")
        for current in ["null", nil] as [String?] {
            let rows = try entries(try screen(items, current: current))

            XCTAssertEqual(rows.map(\.id), ["b1", "b2"], "current: \(current ?? "missing")")
            XCTAssertFalse(rows.contains(where: \.isCurrent), "current: \(current ?? "missing")")
        }
    }

    func testACurrentBroadcastWithNoItemsDrawsOneRowAndNoEmptyMessage() throws {
        let model = try model(try screen("", current: broadcast(id: "now", episode: nil)))

        XCTAssertEqual(model.entries.map(\.id), ["now"])
        XCTAssertEqual(model.entries.first?.isCurrent, true)
        XCTAssertNil(model.emptyMessage)
    }

    func testNoCurrentAndNoItemsDrawsTheEmptyMessage() throws {
        for current in ["null", nil] as [String?] {
            let model = try model(try screen("", current: current))

            XCTAssertTrue(model.entries.isEmpty)
            XCTAssertNotNil(model.emptyMessage, "current: \(current ?? "missing")")
        }
    }

    /// The on-air row follows awe#4989 like any row: linked opens its episode, title-only has no target.
    func testTheCurrentRowTakesItsTargetFromItsEpisode() throws {
        let linked = try XCTUnwrap(try entries(try screen("", current: broadcast(id: "now", episode: episode()))).first)
        XCTAssertEqual(linked.target, CardTarget(resourceType: "episode", itemId: episodeId))

        let router = try router()
        router.openCard(linked.target)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: episodeId)])

        let titleOnly = try XCTUnwrap(try entries(try screen("", current: broadcast(id: "now", episode: nil))).first)
        XCTAssertNil(titleOnly.target)
    }

    /// Both bounds are inclusive, so a broadcast that starts at `now` is served twice. It draws once.
    func testAnItemWithTheCurrentIdDrawsOnce() throws {
        let items = [broadcast(id: "now", title: "On Air", episode: nil), broadcast(id: "b1", episode: nil)]
        let rows = try entries(try screen(items.joined(separator: ","),
                                          current: broadcast(id: "now", title: "On Air", episode: nil)))

        XCTAssertEqual(rows.map(\.id), ["now", "b1"])
        XCTAssertEqual(rows.map(\.isCurrent), [true, false])
    }

    // MARK: The local clock (ruled 2026-09-28)

    private func timed(_ id: String, _ startsAt: String, _ endsAt: String) -> String {
        #"{ "_id": "\#(id)", "episodeTitle": "\#(id)", "startsAt": "\#(startsAt)", "endsAt": "\#(endsAt)" }"#
    }

    private func date(_ value: String) throws -> Date { try XCTUnwrap(ContractDate.parse(value)) }

    /// Every tick recomputes from the served windows: an ended row drops, and the row whose
    /// window holds `now` becomes the current one. No network call is involved.
    func testTheClockDropsEndedRowsAndMovesTheCurrentRow() throws {
        let model = try model(try screen(
            [timed("b1", "2026-09-28T15:30:00.000Z", "2026-09-28T15:54:53.000Z"),
             timed("b2", "2026-09-28T15:55:00.000Z", "2026-09-28T15:58:56.000Z")].joined(separator: ","),
            current: timed("now", "2026-09-28T15:00:00.000Z", "2026-09-28T15:26:05.000Z")
        ))

        let atServe = model.entries(at: try date("2026-09-28T15:10:00.000Z"))
        XCTAssertEqual(atServe.map(\.id), ["now", "b1", "b2"])
        XCTAssertEqual(atServe.map(\.isCurrent), [true, false, false])

        // In the gap after `now` ends: it drops, and nothing is on air yet.
        let inGap = model.entries(at: try date("2026-09-28T15:28:00.000Z"))
        XCTAssertEqual(inGap.map(\.id), ["b1", "b2"])
        XCTAssertEqual(inGap.map(\.isCurrent), [false, false])

        let later = model.entries(at: try date("2026-09-28T15:56:00.000Z"))
        XCTAssertEqual(later.map(\.id), ["b2"])
        XCTAssertEqual(later.map(\.isCurrent), [true])

        XCTAssertEqual(model.entries(at: try date("2026-09-28T16:00:00.000Z")), [], "every row ended")
    }

    func testTheProgressFollowsTheWindow() throws {
        let row = try XCTUnwrap(try entries(try screen("", current: timed("now", "2026-09-28T15:00:00.000Z", "2026-09-28T15:20:00.000Z"))).first)

        XCTAssertEqual(try XCTUnwrap(row.progress(at: try date("2026-09-28T15:05:00.000Z"))), 0.25, accuracy: 0.001)
        XCTAssertEqual(row.progress(at: try date("2026-09-28T14:00:00.000Z")), 0)
        XCTAssertEqual(row.progress(at: try date("2026-09-28T16:00:00.000Z")), 1)
    }

    /// A row without both bounds keeps the flag it was served with.
    func testARowWithoutAWindowKeepsItsServedFlag() throws {
        let model = try model(try screen("", current: #"{ "_id": "now", "episodeTitle": "Live" }"#))

        XCTAssertEqual(model.entries(at: Date()).map(\.isCurrent), [true])
    }

    // MARK: Show title and image fallback (ruled 2026-09-28)

    func testARowNamesItsShow() throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: episode()))).first)
        XCTAssertEqual(row.showTitle, "Celebration of Hope")

        // No populated show: the served `showTitle`. The same text as the title draws once.
        let titleOnly = try XCTUnwrap(try entries(try screen(broadcast(episode: nil))).first)
        XCTAssertEqual(titleOnly.showTitle, "Celebration of Hope")
        let same = try XCTUnwrap(try entries(try screen(#"{ "_id": "b9", "showTitle": "Andacht" }"#)).first)
        XCTAssertEqual(same.title, "Andacht")
        XCTAssertNil(same.showTitle)
    }

    /// No `episode.image`: the show's images through the slot ladder, `default` first.
    func testARowWithoutAnEpisodeImageTakesTheShowsMainImage() throws {
        let show = """
        { "_id": "\(showId)", "title": "Celebration of Hope", "images": {
          "banner": null,
          "poster": { "containerId": "c1", "name": "poster.png" },
          "default": { "containerId": "c1", "name": "default.png", "blurhash": "LFC$" } } }
        """
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: #"{ "_id": "\#(episodeId)", "title": "Reassurance", "image": null, "show": \#(show) }"#))).first)

        XCTAssertEqual(row.imageURL?.absoluteString.contains("default.png"), true)
        XCTAssertEqual(row.blurhash, "LFC$")
    }

    /// Every row is one size, with or without an image (the slot holds a placeholder); the
    /// on-air row is clearly larger.
    func testEveryRowHasOneSizeAndTheOnAirRowIsLarger() {
        XCTAssertGreaterThan(ScheduleRowMetrics.rowHeight(isCurrent: true), ScheduleRowMetrics.rowHeight(isCurrent: false))
        XCTAssertGreaterThan(ScheduleRowMetrics.thumbnail(isCurrent: true).width,
                             ScheduleRowMetrics.thumbnail(isCurrent: false).width)
    }

    // MARK: The on-air row plays the livestream (ruled 2026-09-28)

    private let liveChannel = #"{ "title": "Hope TV Deutsch", "hls": "https://live.example.org/hope/main.m3u8" }"#

    /// The "Now" row plays the channel's livestream full screen, resolved as `LivestreamPlayer`
    /// resolves it, and keeps no watch progress. The other rows keep their episode target.
    func testTheOnAirRowPlaysTheChannelLivestream() throws {
        let model = try model(try screen(
            timed("next", "2026-09-28T15:30:00.000Z", "2026-09-28T15:55:00.000Z"),
            current: #"{ "_id": "now", "episodeTitle": "On Air", "startsAt": "2026-09-28T15:00:00.000Z", "endsAt": "2026-09-28T15:26:05.000Z", "episode": \#(episode()) }"#,
            channel: liveChannel
        ))
        let rows = model.entries(at: try date("2026-09-28T15:10:00.000Z"))
        let expected = try XCTUnwrap(ContractValidator.playableURL(PlaybackService.livestreamSource(
            try JSONDecoder().decode(JSONValue.self, from: Data(liveChannel.utf8)))))

        guard case let .live(request) = try XCTUnwrap(rows.first).kind else {
            return XCTFail("the on-air row is not the live kind")
        }
        XCTAssertEqual(request.url, expected)
        XCTAssertFalse(request.recordsProgress, "live playback records no progress")
        XCTAssertEqual(request.title, "Hope TV Deutsch", "the livestream shape: the channel title, no episode fields")
        XCTAssertNil(request.metadata.showName)
        XCTAssertEqual(rows.last?.kind, .information, "a later row keeps today's behavior")

        let router = try router()
        router.play(request)
        XCTAssertEqual(router.playback, request)
        XCTAssertEqual(router.state.stack, [], "it opens no Episode screen")
        XCTAssertFalse(router.isAtSafeBoundary, "a refetched screen waits while the player is up")
    }

    /// The live action moves with the 60 s clock: the next row becomes the live one.
    func testTheLiveActionMovesWithTheClock() throws {
        let model = try model(try screen(
            [timed("b1", "2026-09-28T15:30:00.000Z", "2026-09-28T15:54:53.000Z"),
             timed("b2", "2026-09-28T15:55:00.000Z", "2026-09-28T15:58:56.000Z")].joined(separator: ","),
            current: timed("now", "2026-09-28T15:00:00.000Z", "2026-09-28T15:26:05.000Z"),
            channel: liveChannel
        ))
        func liveIds(_ at: String) throws -> [String] {
            try model.entries(at: date(at)).filter { if case .live = $0.kind { return true }; return false }.map(\.id)
        }

        XCTAssertEqual(try liveIds("2026-09-28T15:10:00.000Z"), ["now"])
        XCTAssertEqual(try liveIds("2026-09-28T15:28:00.000Z"), [], "nothing on air in the gap")
        XCTAssertEqual(try liveIds("2026-09-28T15:40:00.000Z"), ["b1"])
        XCTAssertEqual(model.entries.contains { $0.live != nil }, false, "only the clock view attaches it")
    }

    /// No playable live source (none, or not https): the on-air row keeps its episode target.
    func testWithoutAPlayableLiveSourceTheOnAirRowOpensItsEpisode() throws {
        for channel in [#"{ "title": "No stream" }"#, #"{ "title": "Insecure", "hls": "http://live.example.org/x.m3u8" }"#] {
            let model = try model(try screen("", current: broadcast(id: "now", episode: episode()), channel: channel))
            // Inside the served 19:00–19:30 window of `broadcast`.
            let row = try XCTUnwrap(model.entries(at: try date("2026-09-18T19:10:00.000Z")).first)
            XCTAssertTrue(row.isCurrent, channel)

            XCTAssertNil(model.live, channel)
            XCTAssertEqual(row.kind, .linked(CardTarget(resourceType: "episode", itemId: episodeId)), channel)
        }
    }

    // MARK: What Select on a row does (awe#6549)

    /// A router whose tap-to-play loader counts its calls and answers nothing.
    private func countingRouter() throws -> (AppRouter, () -> [StackEntry]) {
        let router = try router()
        var asked: [StackEntry] = []
        router.playRequest = { entry in asked.append(entry); return nil }
        return (router, { asked })
    }

    /// The on-air row plays the livestream through `router.play`. It never goes through
    /// tap-to-play, so no Episode Screen loads.
    func testAPressOnTheOnAirRowPlaysTheLivestreamWithoutTapToPlay() throws {
        let model = try model(try screen("", current: broadcast(id: "now", episode: episode()), channel: liveChannel))
        let row = try XCTUnwrap(model.entries(at: try date("2026-09-18T19:10:00.000Z")).first)
        guard case let .live(request) = row.kind else { return XCTFail("the on-air row is not the live kind") }
        let (router, asked) = try countingRouter()

        row.press(router: router)

        XCTAssertEqual(router.playback, request)
        XCTAssertEqual(asked(), [], "no Episode Screen loads")
        XCTAssertNil(router.selecting)
        XCTAssertEqual(router.state.stack, [])
    }

    /// The on-air row with no live source keeps its link: it opens the Episode Screen.
    func testAPressOnTheOnAirRowWithoutALiveSourceOpensItsEpisode() throws {
        let model = try model(try screen("", current: broadcast(id: "now", episode: episode()), channel: #"{ "title": "No stream" }"#))
        let row = try XCTUnwrap(model.entries(at: try date("2026-09-18T19:10:00.000Z")).first)
        XCTAssertTrue(row.isCurrent)
        let (router, asked) = try countingRouter()

        row.press(router: router)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: episodeId)])
        XCTAssertEqual(asked(), [])
    }

    /// A later linked row goes through tap-to-play: it loads the Episode Screen first.
    func testAPressOnALaterLinkedRowGoesThroughTapToPlay() async throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: episode()))).first)
        XCTAssertFalse(row.isCurrent)
        let (router, asked) = try countingRouter()

        row.press(router: router)
        for _ in 0..<1000 where asked().isEmpty { await Task.yield() }

        XCTAssertEqual(asked(), [StackEntry(screenId: "episode-tpl", param: episodeId)])
    }

    // MARK: The heading (round 4)

    /// The block's `title` prop is the heading, as on production ("Heute auf Hope TV"). Only an
    /// empty or missing prop falls back to "On <channel>".
    func testTheTitlePropIsTheHeading() throws {
        let row = broadcast(episode: nil)
        XCTAssertEqual(try model(try screen(row, props: #"{ "title": "Heute auf Hope TV" }"#)).title, "Heute auf Hope TV")
        XCTAssertEqual(try model(try screen(row, props: #"{ "title": "" }"#)).title, "On HC North America")
        XCTAssertEqual(try model(try screen(row)).title, "On HC North America")
        XCTAssertEqual(try model(try screen(row, channel: "{}")).title, "On now", "no prop and no channel title")
    }

    // MARK: An explicit null screenLink (ruling A)

    /// `episode.screenLink: null` (key present) says the episode is not linkable: an
    /// information row, and Select opens nothing.
    func testAnExplicitNullScreenLinkMakesAnInformationRow() throws {
        let row = try XCTUnwrap(try entries(try screen(broadcast(episode: episode(link: #", "screenLink": null"#)))).first)

        XCTAssertNil(row.target)
        XCTAssertEqual(row.kind, .information)
        XCTAssertEqual(row.showTitle, "Celebration of Hope", "it keeps its show title")

        let router = try router()
        router.openCard(row.target)
        XCTAssertEqual(router.state.stack, [], "no push")
    }

    /// No `screenLink` key at all keeps the convention; an object is the served link.
    func testAMissingScreenLinkKeepsTheConventionAndAnObjectIsTheLink() throws {
        XCTAssertEqual(try firstTarget(episode()), CardTarget(resourceType: "episode", itemId: episodeId))

        let link = #", "screenLink": { "linkType": "screen", "screen": "linked-tpl", "screenParam": "\#(episodeId)" }"#
        let router = try router()
        router.openCard(try firstTarget(episode(link: link)))
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "linked-tpl", param: episodeId)])
    }

    /// The on-air row: the live action still wins over a null link; with no live source, a null
    /// link makes it an information row.
    func testTheOnAirRowWithANullLinkPlaysLiveOrInforms() throws {
        let current = #"{ "_id": "now", "episodeTitle": "On Air", "startsAt": "2026-09-28T15:00:00.000Z", "endsAt": "2026-09-28T15:30:00.000Z", "episode": \#(episode(link: #", "screenLink": null"#)) }"#
        let at = try date("2026-09-28T15:10:00.000Z")

        let withLive = try model(try screen("", current: current, channel: liveChannel))
        guard case .live = try XCTUnwrap(withLive.entries(at: at).first).kind else {
            return XCTFail("the live action wins over the null link")
        }

        let noLive = try model(try screen("", current: current))
        XCTAssertEqual(try XCTUnwrap(noLive.entries(at: at).first).kind, .information)
    }

    // MARK: Movie rows (awe#6185)

    private let movieId = "6a1f0c2bd9c698836400aa01"
    private var movieLink: String {
        #", "screenLink": { "linkType": "screen", "screen": "linked-tpl", "screenParam": "\#(movieId)" }"#
    }

    /// A row the import linked to a Movie: no manual titles, a populated `movie`.
    private func movieBroadcast(link: String = "", images: String = "") -> String {
        #"""
        { "_id": "m1", "id": "m1",
          "startsAt": "2026-09-18T19:00:00.000Z", "endsAt": "2026-09-18T21:00:00.000Z",
          "movie": { "_id": "\#(movieId)", "title": "The Chosen Path", "slug": "the-chosen-path"\#(images)\#(link) } }
        """#
    }

    /// The served `movie.screenLink` opens the movie, as `episode.screenLink` does.
    func testAMovieRowWithAServedScreenLinkOpensTheMovie() throws {
        let row = try XCTUnwrap(try entries(try screen(movieBroadcast(link: movieLink))).first)

        XCTAssertEqual(row.title, "The Chosen Path")
        XCTAssertNil(row.showTitle, "a movie has no show")
        XCTAssertEqual(row.kind, .linked(try XCTUnwrap(row.target)))
        XCTAssertEqual(row.target?.resourceType, "movie")
        XCTAssertEqual(row.target?.itemId, movieId)

        let router = try router()
        router.openCard(row.target)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "linked-tpl", param: movieId)])
    }

    /// A press on a movie row pushes the movie Template Screen (awe#6270). It does not go through
    /// tap-to-play: only an episode screen loads first, so the movie details show.
    func testAPressOnAMovieRowPushesTheMovieScreen() throws {
        let link = #", "screenLink": { "linkType": "screen", "screen": "movie-tpl", "screenParam": "\#(movieId)" }"#
        let row = try XCTUnwrap(try entries(try screen(movieBroadcast(link: link))).first)
        let (router, asked) = try countingRouter()

        row.press(router: router)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "movie-tpl", param: movieId)])
        XCTAssertEqual(asked(), [], "no tap-to-play load")
        XCTAssertNil(router.selecting)
        XCTAssertNil(router.playback)
    }

    /// A movie opens only through its served link (contract rule 1), also now that a `movie`
    /// Template Screen exists: a missing, `null`, or malformed link is an information row, and a
    /// press opens nothing.
    func testAMovieRowWithoutAServedLinkIsAnInformationRow() throws {
        for link in ["", #", "screenLink": null"#, #", "screenLink": { "linkType": "url", "url": "https://x.org" }"#] {
            let row = try XCTUnwrap(try entries(try screen(movieBroadcast(link: link))).first)
            XCTAssertEqual(row.title, "The Chosen Path", "link: \(link)")
            XCTAssertNil(row.target, "link: \(link)")
            XCTAssertEqual(row.kind, .information, "link: \(link)")

            let router = try router()
            row.press(router: router)
            XCTAssertEqual(router.state.stack, [], "link: \(link)")
        }
    }

    /// A movie row takes its thumbnail from `movie.images` through the main slot ladder.
    func testAMovieRowTakesItsMainImage() throws {
        let file = #"{ "name": "path.jpg", "containerId": "c1" }"#
        let row = try XCTUnwrap(try entries(try screen(movieBroadcast(images: #", "images": { "poster": null, "default": \#(file) }"#))).first)

        let json = try JSONDecoder().decode(JSONValue.self, from: Data(file.utf8))
        XCTAssertEqual(row.imageURL, TestRender.context().images.url(ImageFile(json), width: 640))
        XCTAssertNotNil(row.imageURL)
    }

    /// A manual title still wins over the movie title, as it does over the episode title.
    func testAManualTitleWinsOverTheMovieTitle() throws {
        let item = #"{ "_id": "m2", "episodeTitle": "Sunday Film", "startsAt": "2026-09-18T19:00:00.000Z", "movie": { "_id": "\#(movieId)", "title": "The Chosen Path" } }"#
        XCTAssertEqual(try XCTUnwrap(try entries(try screen(item)).first).title, "Sunday Film")
    }

    /// Other cards keep "a missing or null link is the convention".
    func testANullLinkOnAnEpisodeCardStillUsesTheConvention() throws {
        XCTAssertNil(ScreenLink(.null))
        XCTAssertNil(ScreenLink(JSONValue.object(["screenLink": .null])["screenLink"]))
    }

    // MARK: Refetch

    /// A screen with a schedule refetches itself; others never do.
    func testOnlyAScreenWithAScheduleRefetches() throws {
        XCTAssertTrue(try TestRender.screen("live").node.holdsSchedule)
        XCTAssertTrue(try TestRender.screen("home").node.holdsSchedule)
        XCTAssertFalse(try TestRender.screen("show").node.holdsSchedule)
        XCTAssertFalse(try TestRender.screen("episode").node.holdsSchedule)
    }
}

/// `EpisodesList` draws a grid of cards from its `episodes` resource.
///
/// The `show` fixture now carries the block (awe#4412 fixed); this test keeps a hand-built
/// payload so the card mapping is checked in isolation. The shape below is the API's own:
/// `modules/media-library/blocks/EpisodesList/index.js` declares `episodes` (a list resource,
/// `{ items, count }`) and `show` (a model), and `resources/episodes.js` selects `title`,
/// `duration`, `image`, `images`, `publishedAt`, `show`, `slug`, `abstract`, `number`.
final class EpisodesListTests: XCTestCase {

    private func screen(
        items: String,
        show: String = #"{ "title": "Celebration of Hope" }"#,
        props: String = "{}"
    ) throws -> AppScreen {
        try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "template",
          "blockResources": {
            "list": { "resources": { "episodes": { "items": [\(items)], "count": 2 }, "show": \(show) } }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["list"] },
            "list": {
              "type": { "resolvedName": "EpisodesList" },
              "props": \(props), "custom": { "type": "plugin", "resources": ["episodes", "show"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
    }

    private let episodes = """
    {
      "_id": "6a049248c6d68f1e30573243",
      "title": "A Bear Remembers",
      "duration": 1203,
      "publishedAt": "2026-05-13T15:01:28.288Z",
      "abstract": "",
      "slug": "a-bear-remembers-336988",
      "image": { "containerId": "602bd46f36432128d40d5e81", "name": "ucD1778684487809.jpg", "blurhash": "LCB3~R.S?wMx" },
      "show": { "_id": "620a794d2d1ac1cdb9358ec8", "title": "_Test Show" }
    },
    {
      "_id": "6a049248c6d68f1e30573244",
      "title": "The Second One",
      "duration": 60,
      "publishedAt": "2026-05-14T15:01:28.288Z",
      "images": { "default": { "containerId": "602bd46f36432128d40d5e81", "name": "x.jpg" } },
      "show": { "_id": "620a794d2d1ac1cdb9358ec8", "title": "_Test Show" }
    }
    """

    private func shelf(_ screen: AppScreen) throws -> ShelfModel {
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources)
        ))
        let list = try XCTUnwrap(node.first { $0.key == .episodesList })
        guard case let .shelf(model) = list.content else {
            throw XCTSkip("EpisodesList drew nothing")
        }
        return model
    }

    /// Ruled 2026-09-28: a grid of the 392 pt landscape cards, image + two-line title + duration.
    func testItDrawsOneGridCardPerEpisodeWithTitleImageAndDuration() throws {
        let model = try shelf(try screen(items: episodes, props: #"{ "showDuration": true }"#))

        XCTAssertEqual(model.layout, .grid)
        XCTAssertEqual(model.cardStyle, .cards)
        XCTAssertEqual(model.titleLines, 2)
        XCTAssertEqual(model.cards.count, 2)

        let first = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(first.title, "A Bear Remembers")
        // A card names only the episode's duration; the show is the screen.
        XCTAssertEqual(first.subtitle, "20m")
        XCTAssertNotNil(first.imageURL)
        XCTAssertEqual(first.blurhash, "LCB3~R.S?wMx")

        // `images.default` is the fallback when there is no flat `image`.
        XCTAssertNotNil(model.cards[1].imageURL)
    }

    func testEveryRowTargetsTheEpisodeTemplateByItsOwnId() throws {
        let model = try shelf(try screen(items: episodes))

        XCTAssertEqual(model.cards.map(\.target?.resourceType), ["episode", "episode"])
        XCTAssertEqual(
            model.cards.map(\.target?.itemId),
            ["6a049248c6d68f1e30573243", "6a049248c6d68f1e30573244"]
        )
    }

    func testAnEmptyListDrawsItsEmptyState() throws {
        let model = try shelf(try screen(items: ""))

        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertEqual(model.emptyMessage, "No episodes are published for this show.")
    }

    /// The heading is the block's own `title` prop (ruled 2026-09-28), never `show.title`.
    func testTheHeadingIsTheTitlePropAndNeverTheShowTitle() throws {
        XCTAssertEqual(try shelf(try screen(items: episodes, props: #"{ "title": "Alle Folgen" }"#)).title, "Alle Folgen")
        XCTAssertNil(try shelf(try screen(items: episodes)).title, "no prop draws no heading")
        XCTAssertNil(try shelf(try screen(items: episodes, props: #"{ "title": "" }"#)).title, "an empty prop draws no heading")
        // The block renders even when the `show` model resource is absent.
        XCTAssertEqual(try shelf(try screen(items: episodes, show: "null", props: #"{ "title": "Alle Folgen" }"#)).title, "Alle Folgen")
    }

    // MARK: Season filter

    private func episode(_ id: String, season: String?) -> String {
        let field = season.map { #", "season": { "_id": "\#($0)", "slug": "s", "title": "unused", "groupName": "" }"# } ?? ""
        return #"{ "_id": "\#(id)", "title": "Episode \#(id)"\#(field) }"#
    }

    /// `show.seasons` in authored order; the served per-season `episodeCount` is 0 on purpose.
    private let seasonsShow = """
    { "title": "Bibelkompass", "seasons": [
      { "_id": "s3", "title": "Third", "episodeCount": 0 },
      { "_id": "s2", "title": "Second", "episodeCount": 0 },
      { "_id": "s1", "title": "First", "episodeCount": 0 }
    ] }
    """

    /// Only seasons that hold a served episode get a chip, in authored order.
    func testTheSeasonChipsListTheSeasonsThatHoldAnEpisodeInAuthoredOrder() throws {
        let items = [episode("e1", season: "s1"), episode("e2", season: "s3"), episode("e3", season: "s1")]
        let model = try shelf(try screen(items: items.joined(separator: ","), show: seasonsShow))

        XCTAssertEqual(model.seasons, [ShelfModel.Season(id: "s3", title: "Third"), ShelfModel.Season(id: "s1", title: "First")])
        XCTAssertEqual(model.cards.map(\.seasonId), ["s1", "s3", "s1"])
    }

    /// A chip filters the grid on the client; nil ("All") keeps every card in served order.
    func testASeasonChipFiltersTheCards() throws {
        let items = [episode("e1", season: "s1"), episode("e2", season: "s3"), episode("e3", season: "s1")]
        let model = try shelf(try screen(items: items.joined(separator: ","), show: seasonsShow))

        XCTAssertEqual(model.cards(inSeason: nil).map(\.id), ["e1", "e2", "e3"])
        XCTAssertEqual(model.cards(inSeason: "s1").map(\.id), ["e1", "e3"])
        XCTAssertEqual(model.cards(inSeason: "s3").map(\.id), ["e2"])
        XCTAssertEqual(model.cards(inSeason: "s2").map(\.id), [], "a season without episodes has no chip anyway")
    }

    // MARK: List layout

    /// `layout: "list"` draws the list; absent, `"grid"` or any other value draws the grid.
    func testTheLayoutPropPicksTheListOnlyForList() throws {
        XCTAssertEqual(try shelf(try screen(items: episodes, props: #"{ "layout": "list" }"#)).layout, .list)
        XCTAssertEqual(try shelf(try screen(items: episodes, props: #"{ "layout": "grid" }"#)).layout, .grid)
        XCTAssertEqual(try shelf(try screen(items: episodes)).layout, .grid, "no prop draws the grid")
        XCTAssertEqual(try shelf(try screen(items: episodes, props: #"{ "layout": "slider" }"#)).layout, .grid)
        XCTAssertEqual(try shelf(try screen(items: episodes, props: #"{ "layout": true }"#)).layout, .grid)
    }

    /// The list keeps the grid's heading, season chips, targets and empty state.
    func testTheListKeepsTheHeadingChipsTargetsAndEmptyState() throws {
        let items = [episode("e1", season: "s1"), episode("e2", season: "s3")].joined(separator: ",")
        let model = try shelf(try screen(items: items, show: seasonsShow, props: #"{ "layout": "list", "title": "Folgen" }"#))
        XCTAssertEqual(model.title, "Folgen")
        XCTAssertEqual(model.seasons.map(\.id), ["s3", "s1"])
        XCTAssertEqual(model.cards.map(\.target?.itemId), ["e1", "e2"])

        let empty = try shelf(try screen(items: "", props: #"{ "layout": "list" }"#))
        XCTAssertEqual(empty.layout, .list)
        XCTAssertEqual(empty.emptyMessage, "No episodes are published for this show.")
    }

    /// A row draws the `abstract` and the `number`. Blank text and a number of 0 read as absent.
    func testACardCarriesTheAbstractAndANumberAboveZero() throws {
        let items = [
            #"{ "_id": "e1", "title": "One", "number": 3, "abstract": "Daniel 2 in plain words." }"#,
            #"{ "_id": "e2", "title": "Two", "number": 0, "abstract": "  " }"#,
            #"{ "_id": "e3", "title": "Three" }"#,
        ].joined(separator: ",")
        for layout in ["list", "grid"] {
            let cards = try shelf(try screen(items: items, props: #"{ "layout": "\#(layout)" }"#)).cards
            XCTAssertEqual(cards.map(\.number), [3, nil, nil], layout)
            XCTAssertEqual(cards.map(\.abstract), ["Daniel 2 in plain words.", nil, nil], layout)
        }
    }

    /// The duration draws only when `showDuration` is on, in both layouts. Off, absent or not a
    /// bool draws none.
    func testTheDurationDrawsOnlyWithShowDuration() throws {
        for layout in ["list", "grid"] {
            let on = try shelf(try screen(items: episodes, props: #"{ "layout": "\#(layout)", "showDuration": true }"#))
            XCTAssertEqual(on.cards.map(\.subtitle), ["20m", "1m"], layout)

            for off in [#", "showDuration": false"#, "", #", "showDuration": "true""#] {
                let model = try shelf(try screen(items: episodes, props: #"{ "layout": "\#(layout)"\#(off) }"#))
                XCTAssertEqual(model.cards.map(\.subtitle), [nil, nil], "\(layout)\(off)")
            }
        }
    }

    /// A season with no title and no group name is named by its authored position, never by
    /// its raw id.
    func testAnUntitledSeasonIsNamedByItsPosition() throws {
        let show = #"{ "title": "T", "seasons": [{ "_id": "s3", "title": "Third" }, { "_id": "s2" }, { "_id": "s1", "groupName": "Group" }] }"#
        let items = [episode("e1", season: "s2"), episode("e2", season: "s1")].joined(separator: ",")
        let model = try shelf(try screen(items: items, show: show))

        XCTAssertEqual(model.seasons.map(\.title), ["Season 2", "Group"])
        XCTAssertFalse(model.seasons.contains { $0.title == $0.id })
    }

    /// A show with no seasons, or episodes that name none, draws no chips.
    func testNoSeasonsDrawNoChips() throws {
        let unseasoned = [episode("e1", season: nil), episode("e2", season: nil)].joined(separator: ",")
        XCTAssertEqual(try shelf(try screen(items: unseasoned, show: #"{ "title": "inBindung", "seasons": [] }"#)).seasons, [])
        XCTAssertEqual(try shelf(try screen(items: unseasoned, show: seasonsShow)).seasons, [])
        XCTAssertEqual(try shelf(try screen(items: episode("e1", season: "s1"), show: #"{ "title": "No list" }"#)).seasons, [])
    }
}

/// A served Screen link (awe#4519).
///
/// `apis/frontend/modules/media-library/resources/helpers/addScreenLinks.js` attaches
/// `{ linkType: "screen", screen, screenParam }` to an item when the block names a target
/// Screen. The link wins over the convention; no link falls back to it.
@MainActor
final class ServedScreenLinkTests: XCTestCase {

    private let showId = "61975ddad9c6988364002f3f"

    private func manifest() throws -> AppManifest {
        try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [
            { "id": "home", "kind": "static" },
            { "id": "show-tpl", "kind": "template", "resourceType": "show" },
            { "id": "linked-tpl", "kind": "template", "resourceType": "other" }
          ],
          "preset": {}
        }
        """.utf8))
    }

    /// One `Collection` shelf of shows, each item carrying the given extra fields.
    private func shelf(itemFields: String) throws -> ShelfModel {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "shelf": {
              "resources": {
                "collection": {
                  "title": "Featured",
                  "contentType": "shows",
                  "shows": [{ "_id": "\(showId)", "title": "Table Talk"\(itemFields) }]
                }
              }
            }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["shelf"] },
            "shelf": {
              "type": { "resolvedName": "Collection" },
              "props": {}, "custom": { "type": "plugin", "resources": ["collection"] },
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
        let block = try XCTUnwrap(node.first { $0.key == .collection })
        guard case let .shelf(model) = block.content else { throw XCTSkip("Collection drew nothing") }
        return model
    }

    private func link(screen: String, param: String) -> String {
        #", "screenLink": { "linkType": "screen", "screen": "\#(screen)", "screenParam": "\#(param)" }"#
    }

    private func router() throws -> AppRouter {
        AppRouter(tree: NavigationTree(manifest: try manifest()), diagnostics: Diagnostics())
    }

    func testAServedLinkOpensItsOwnScreenAndParam() throws {
        let card = try XCTUnwrap(try shelf(itemFields: link(screen: "linked-tpl", param: showId)).cards.first)
        let router = try router()

        XCTAssertEqual(card.target?.link, ScreenLink(try JSONValue.link("linked-tpl", showId)))
        router.openCard(card.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "linked-tpl", param: showId)])
    }

    /// The convention would answer `show-tpl` for this same card; the served link outranks it.
    func testTheServedLinkWinsOverTheConvention() throws {
        let router = try router()
        let linked = try XCTUnwrap(try shelf(itemFields: link(screen: "linked-tpl", param: showId)).cards.first)
        let plain = try XCTUnwrap(try shelf(itemFields: "").cards.first)

        router.openCard(plain.target)
        router.openCard(linked.target)

        XCTAssertEqual(router.state.stack, [
            StackEntry(screenId: "show-tpl", param: showId),
            StackEntry(screenId: "linked-tpl", param: showId),
        ])
    }

    func testNoLinkFallsBackToTheConvention() throws {
        let card = try XCTUnwrap(try shelf(itemFields: "").cards.first)
        let router = try router()

        XCTAssertNil(card.target?.link)
        router.openCard(card.target)

        XCTAssertEqual(router.state.stack.count, 1)
        XCTAssertEqual(router.state.stack.first?.param, showId)
    }

    /// A link to a Screen the manifest does not carry opens nothing, reports once, and never
    /// falls back to the convention's answer.
    func testALinkedScreenOutsideTheManifestIsANoOpWithOneLog() throws {
        let card = try XCTUnwrap(try shelf(itemFields: link(screen: "6aa952fbc445860ea24e1bb6", param: showId)).cards.first)
        let router = try router()

        router.openCard(card.target)
        router.openCard(card.target)

        XCTAssertTrue(router.state.stack.isEmpty, "a missing linked Screen never falls back")
        XCTAssertEqual(router.diagnostics.entries.filter { $0.title == "Card press ignored" }.count, 1)
    }

    /// Only `linkType: "screen"` is a route. A half-built link reads as absent, so the card
    /// keeps the convention.
    func testAMalformedLinkReadsAsAbsent() throws {
        let other = #", "screenLink": { "linkType": "url", "screen": "linked-tpl", "screenParam": "\#(showId)" }"#
        XCTAssertNil(try shelf(itemFields: other).cards.first?.target?.link)

        let noParam = #", "screenLink": { "linkType": "screen", "screen": "linked-tpl" }"#
        XCTAssertNil(try shelf(itemFields: noParam).cards.first?.target?.link)

        let noScreen = #", "screenLink": { "linkType": "screen", "screenParam": "\#(showId)" }"#
        XCTAssertNil(try shelf(itemFields: noScreen).cards.first?.target?.link)
    }

    /// A broadcast row follows the served episode link, like every episode card (awe#4989).
    func testAScheduleRowFollowsTheServedEpisodeLink() throws {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": {
            "strip": {
              "resources": {
                "channel": { "title": "HC" },
                "broadcastsLive": {
                  "items": [{
                    "_id": "b1",
                    "episodeTitle": "Reassurance",
                    "startsAt": "2026-09-18T19:00:00.000Z",
                    "episode": {
                      "_id": "6a049248c6d68f1e30573243",
                      "title": "Reassurance",
                      "screenLink": { "linkType": "screen", "screen": "linked-tpl", "screenParam": "6a049248c6d68f1e30573243" },
                      "show": { "_id": "\(showId)", "title": "Table Talk" }
                    }
                  }],
                  "count": 1
                }
              }
            }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["strip"] },
            "strip": {
              "type": { "resolvedName": "ScheduleLive" },
              "props": {}, "custom": { "type": "plugin", "resources": ["channel", "broadcastsLive"] },
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
        let strip = try XCTUnwrap(node.first { $0.key == .scheduleLive })
        guard case let .schedule(model) = strip.content else { return XCTFail("ScheduleLive drew nothing") }

        let router = try router()
        router.openCard(model.entries.first?.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "linked-tpl", param: "6a049248c6d68f1e30573243")])
    }
}

/// A block prop never redirects a card (awe#4878).
///
/// The owner deleted the explicit block-prop tier on 2026-09-23. No block authors
/// `showScreen` / `episodeScreen`, and the served `screenLink` carries the authored target.
/// A stray prop must leave the convention's answer in place.
@MainActor
final class BlockPropTargetTests: XCTestCase {

    private let showId = "61975ddad9c6988364002f3f"
    private let episodeId = "6a049248c6d68f1e30573243"

    private func router() throws -> AppRouter {
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [
            { "id": "home", "kind": "static" },
            { "id": "show-tpl", "kind": "template", "resourceType": "show" },
            { "id": "episode-tpl", "kind": "template", "resourceType": "episode" },
            { "id": "other-tpl", "kind": "template", "resourceType": "other" }
          ],
          "preset": {}
        }
        """.utf8))
        return AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
    }

    /// One block of `type` with `props`, serving `resources`, evaluated to its content.
    private func block(_ type: String, props: String, resources: String) throws -> BlockContent? {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "blockResources": { "b": { "resources": { \(resources) } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["b"] },
            "b": {
              "type": { "resolvedName": "\(type)" },
              "props": { \(props) }, "custom": { "type": "plugin" },
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
        return node.first { $0.id == "b" }?.content
    }

    private func firstCard(_ content: BlockContent?) throws -> CardModel {
        guard case let .shelf(model)? = content else {
            XCTFail("the block drew no shelf")
            throw CocoaError(.featureUnsupported)
        }
        return try XCTUnwrap(model.cards.first)
    }

    func testAShowScreenPropDoesNotRedirectAShowCard() throws {
        let card = try firstCard(try block(
            "ShowList",
            props: #""showScreen": "other-tpl""#,
            resources: #""shows": { "items": [{ "_id": "\#(showId)", "title": "Table Talk" }], "count": 1 }"#
        ))
        let router = try router()

        router.openCard(card.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "show-tpl", param: showId)])
    }

    func testAnEpisodeScreenPropDoesNotRedirectAnEpisodeCard() throws {
        let card = try firstCard(try block(
            "EpisodesList",
            props: #""episodeScreen": "other-tpl""#,
            resources: #""episodes": { "items": [{ "_id": "\#(episodeId)", "title": "Reassurance" }], "count": 1 }"#
        ))
        let router = try router()

        router.openCard(card.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: episodeId)])
    }

    /// A broadcast row with no served link opens its episode template by convention.
    func testAShowScreenPropDoesNotRedirectAScheduleRow() throws {
        let content = try block(
            "ScheduleLive",
            props: #""showScreen": "other-tpl""#,
            resources: #"""
            "channel": { "title": "HC" },
            "broadcastsLive": { "items": [{
              "_id": "b1", "episodeTitle": "Reassurance", "startsAt": "2026-09-18T19:00:00.000Z",
              "episode": { "_id": "\#(episodeId)", "show": { "_id": "\#(showId)", "title": "Table Talk" } }
            }], "count": 1 }
            """#
        )
        guard case let .schedule(model)? = content else { return XCTFail("ScheduleLive drew nothing") }
        let router = try router()

        router.openCard(model.entries.first?.target)

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: episodeId)])
    }
}

/// The served Screen link against the shared capture (awe#4679).
///
/// Every value comes from the fixture bytes, never a literal. Since the 2026-09-23 re-capture
/// (awe#4950) every fixture card serves a `screenLink`: the Browse `ShowList`, the Home hero
/// `CollectionTeaser` and `latest` `Collection`, and the Show `EpisodesList`. Each linked Screen
/// is also the one the convention picks, so these tests pin `target.link`, not only the push.
/// Router precedence and the no-link fallback are proven by `ServedScreenLinkTests` against a
/// synthetic manifest.
@MainActor
final class FixtureScreenLinkTests: XCTestCase {

    private func router() throws -> AppRouter {
        let manifest = try ContractDecoder.manifest(Fixtures.data("manifest"))
        return AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
    }

    /// The manifest's one Template Screen for `resourceType`.
    private func template(_ resourceType: String) throws -> String {
        let manifest = try ContractDecoder.manifest(Fixtures.data("manifest"))
        let ids = manifest.screens.filter { $0.kind == .template && $0.resourceType == resourceType }.map(\.id)
        XCTAssertEqual(ids.count, 1, "manifest: \(resourceType) templates")
        return try XCTUnwrap(ids.first)
    }

    /// The card carries the served link, and a press opens the linked template with the item id.
    private func assertOpensLinkedTemplate(_ card: CardModel, _ item: JSONValue, resourceType: String, _ name: String)
        throws {
        let itemId = try XCTUnwrap(item["id"].text ?? item["_id"].text)
        let served = try XCTUnwrap(ScreenLink(item["screenLink"]), "\(name): the first item serves no screenLink")

        XCTAssertEqual(served.screenId, try template(resourceType), "\(name): the link names another Screen")
        XCTAssertEqual(served.param, itemId)
        XCTAssertEqual(card.target?.link, served)

        let router = try router()
        router.openCard(card.target)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: served.screenId, param: itemId)])
    }

    /// The first card of the first `key` block, and the fixture item it was built from.
    private func firstCard(_ name: String, key: BlockKey, resource: String, items: (JSONValue) -> JSONValue)
        throws -> (card: CardModel, item: JSONValue) {
        let result = try TestRender.screen(name)
        let block = try XCTUnwrap(result.node.first { $0.key == key }, "\(name): no \(key) block")
        guard case let .shelf(model) = block.content else { throw XCTSkip("\(name): \(key) drew nothing") }
        let served = try XCTUnwrap(result.screen.blockResources[block.id]?[resource], "\(name): \(resource) is not served")
        let item = try XCTUnwrap(items(served).array.first, "\(name): \(resource) serves no item")
        let card = try XCTUnwrap(model.cards.first, "\(name): \(key) drew no card")
        XCTAssertEqual(card.id, item["id"].text ?? item["_id"].text, "\(name): the first card is not the first item")
        return (card, item)
    }

    func testABrowseCardWithAServedScreenLinkOpensThatScreenWithItsParam() throws {
        let (card, item) = try firstCard("browse", key: .showList, resource: "shows") { $0["items"] }
        let itemId = try XCTUnwrap(item["id"].text ?? item["_id"].text)
        let served = try XCTUnwrap(
            ScreenLink(item["screenLink"]),
            "browse: shows.items[0] serves no screenLink — re-capture browse.json after the ShowList block names its Show screen"
        )

        // The card carries the served link; `ServedScreenLinkTests` pins that the router prefers it.
        XCTAssertEqual(card.target?.link, served)

        let router = try router()
        router.openCard(card.target)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: served.screenId, param: itemId)])
    }

    /// The hero names its Show screen since awe#4950 (`showScreenId`), so its cards carry the link.
    func testAHomeHeroCardWithAServedScreenLinkOpensTheShowTemplate() throws {
        let (card, item) = try firstCard("home", key: .collectionTeaser, resource: "collectionTeaser") { $0["shows"] }
        try assertOpensLinkedTemplate(card, item, resourceType: "show", "home hero")
    }

    func testAHomeLatestEpisodeCardWithAServedScreenLinkOpensTheEpisodeTemplate() throws {
        let (card, item) = try firstCard("home", key: .collection, resource: "collection") { $0["episodes"] }
        try assertOpensLinkedTemplate(card, item, resourceType: "episode", "home latest")
    }

    func testAShowEpisodesListRowWithAServedScreenLinkOpensTheEpisodeTemplate() throws {
        let (card, item) = try firstCard("show", key: .episodesList, resource: "episodes") { $0["items"] }
        try assertOpensLinkedTemplate(card, item, resourceType: "episode", "show episodes")
    }

    /// A schedule row is pressable exactly when it carries an episode record id (awe#4989). The
    /// EPG capture is time-bound, so the test reads each row and never pins "all title-only".
    func testAScheduleRowHasATargetExactlyWhenItCarriesAnEpisodeRecord() throws {
        var rows = 0
        for name in ["home", "live"] {
            let result = try TestRender.screen(name)
            let block = try XCTUnwrap(result.node.first { $0.key == .scheduleLive }, "\(name): no ScheduleLive block")
            guard case let .schedule(model) = block.content else { return XCTFail("\(name): ScheduleLive drew nothing") }
            let items = TestRender.scheduleRows(result.screen.blockResources[block.id]?["broadcastsLive"] ?? .null)
            XCTAssertEqual(model.entries.count, items.count, "\(name): one row per broadcast")
            for (entry, item) in zip(model.entries, items) {
                let episode = item["episode"]
                let episodeId = episode["id"].text ?? episode["_id"].text
                XCTAssertEqual(entry.target?.itemId, episodeId, "\(name): row \(entry.id)")
                if episodeId != nil {
                    XCTAssertEqual(entry.target?.resourceType, "episode")
                    XCTAssertEqual(entry.target?.link, ScreenLink(episode["screenLink"]))
                }
                rows += 1
            }
        }
        XCTAssertGreaterThan(rows, 0, "the fixtures serve no broadcast row")
    }

    /// The Live schedule draws the served on-air broadcast first (awe#5033). The capture is
    /// time-bound, so the expected row comes from the fixture bytes, never a pinned title.
    func testTheLiveScheduleDrawsTheServedCurrentBroadcastFirst() throws {
        let result = try TestRender.screen("live")
        let block = try XCTUnwrap(result.node.first { $0.key == .scheduleLive }, "live: no ScheduleLive block")
        guard case let .schedule(model) = block.content else { return XCTFail("live: ScheduleLive drew nothing") }
        let current = try XCTUnwrap(
            result.screen.blockResources[block.id]?["broadcastsLive"]?["current"],
            "live: broadcastsLive serves no current key"
        )
        guard case .object = current else {
            return XCTFail("live: broadcastsLive.current is null — re-capture live.json while a broadcast is on air")
        }

        let first = try XCTUnwrap(model.entries.first, "live: the schedule drew no row")
        XCTAssertEqual(first.id, current["id"].text ?? current["_id"].text)
        XCTAssertEqual(first.title, current["episodeTitle"].text ?? current["episode"]["title"].text)
        XCTAssertTrue(first.isCurrent)
        XCTAssertEqual(model.entries.filter(\.isCurrent).count, 1, "live: exactly one row is on air")
    }
}

/// A "Keep watching" card is device-local (spec §8 Q4): it carries no served link, so it opens
/// the Episode Template Screen by the convention, with the episode id its progress entry kept.
/// Each card is built by `BlockRegistry.evaluate` from an `EpisodeWatchHistory` node.
@MainActor
final class WatchHistoryCardTests: XCTestCase {

    private func entry(episodeId: String? = nil, subtitle: String = "Hope Sabbath School", duration: Double? = nil) -> WatchProgressStore.Entry {
        WatchProgressStore.Entry(
            playableId: "https://jstre.am/videos/jsv:mmPNfkcIEdR/hls/main.m3u8",
            showId: nil,
            episodeId: episodeId,
            title: "Lesson 1",
            subtitle: subtitle,
            imageURL: nil,
            fraction: 0.4,
            duration: duration,
            updatedAt: Date()
        )
    }

    /// The one card an `EpisodeWatchHistory` node with `props` draws from `entry`.
    private func card(_ entry: WatchProgressStore.Entry, props: String = "") throws -> CardModel {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "static",
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["history"] },
            "history": {
              "type": { "resolvedName": "EpisodeWatchHistory" },
              "props": { \(props) }, "custom": { "type": "plugin" },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(watchHistory: [entry])
        ))
        guard case let .shelf(model) = try XCTUnwrap(node.first { $0.id == "history" }).content else {
            throw XCTSkip("EpisodeWatchHistory drew nothing")
        }
        return try XCTUnwrap(model.cards.first)
    }

    func testAKeptEpisodeIdOpensTheEpisodeTemplate() throws {
        let manifest = try ContractDecoder.manifest(Fixtures.data("manifest"))
        let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
        let expected = try Fixtures.json("expectations")["screens"]["episode"]
        let episodeId = try XCTUnwrap(expected["param"].string)

        let card = try card(entry(episodeId: episodeId))
        XCTAssertEqual(card.target?.resourceType, "episode")
        XCTAssertNil(card.target?.link)

        router.openCard(card.target)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: expected["id"].string ?? "", param: episodeId)])
    }

    func testAnEntryFromBeforeTheEpisodeIdOpensNothing() throws {
        XCTAssertNil(try card(entry(episodeId: nil)).target)
    }

    func testAnEntrySavedWithoutTheEpisodeIdStillDecodes() throws {
        let saved = #"{ "playableId": "p", "title": "T", "subtitle": "", "fraction": 0.5, "updatedAt": 0 }"#
        let decoded = try JSONDecoder().decode(WatchProgressStore.Entry.self, from: Data(saved.utf8))
        XCTAssertNil(decoded.episodeId)
    }

    // MARK: showDuration (awe#6055)

    /// 1500 s watched to 40%: 25m long, 15m left.
    func testShowDurationAddsTheDurationAndTheTimeLeft() throws {
        XCTAssertEqual(try card(entry(duration: 1500), props: #""showDuration": true"#).subtitle,
                       "Hope Sabbath School · 25m · 15m left")
    }

    /// Off, absent or not a bool draws the show name only.
    func testWithoutShowDurationTheCardDrawsTheShowNameOnly() throws {
        for props in [#""showDuration": false"#, "", #""showDuration": "true""#] {
            XCTAssertEqual(try card(entry(duration: 1500), props: props).subtitle, "Hope Sabbath School", props)
        }
    }

    /// An entry saved before the duration was kept draws neither number until watched again.
    func testAnEntryWithoutADurationDrawsTheShowNameOnly() throws {
        XCTAssertEqual(try card(entry(duration: nil), props: #""showDuration": true"#).subtitle, "Hope Sabbath School")
    }

    /// An empty show name is left out, so the line does not start with a separator.
    func testAnEmptyShowNameIsLeftOut() throws {
        XCTAssertEqual(try card(entry(subtitle: "", duration: 1500), props: #""showDuration": true"#).subtitle, "25m · 15m left")
        XCTAssertNil(try card(entry(subtitle: "", duration: 1500)).subtitle)
    }

    func testAnEntrySavedWithoutTheDurationStillDecodes() throws {
        let saved = #"{ "playableId": "p", "title": "T", "subtitle": "", "fraction": 0.5, "updatedAt": 0 }"#
        let decoded = try JSONDecoder().decode(WatchProgressStore.Entry.self, from: Data(saved.utf8))
        XCTAssertNil(decoded.duration)
        XCTAssertEqual(decoded.fraction, 0.5)
    }

    func testRecordKeepsTheDuration() {
        let key = "watch-progress-v2"
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        let store = WatchProgressStore()
        store.record(0.4, for: "https://example.org/e1.m3u8", title: "E1", duration: 1500)

        XCTAssertEqual(store.resumable(limit: 1).first?.duration, 1500)
        XCTAssertEqual(WatchProgressStore().resumable(limit: 1).first?.duration, 1500, "persisted")
    }

    /// A later write without a duration keeps the stored one, as `episodeId` and `imageURL` do.
    func testARecordWithoutADurationKeepsTheStoredOne() {
        let key = "watch-progress-v2"
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        let store = WatchProgressStore()
        store.record(0.4, for: "https://example.org/e1.m3u8", title: "E1", duration: 1500)
        store.record(0.5, for: "https://example.org/e1.m3u8", title: "E1")

        XCTAssertEqual(store.resumable(limit: 1).first?.fraction, 0.5)
        XCTAssertEqual(store.resumable(limit: 1).first?.duration, 1500)
    }
}

private extension JSONValue {
    /// The served link shape, for an assertion that compares against the decoded value.
    static func link(_ screen: String, _ param: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data("""
        { "linkType": "screen", "screen": "\(screen)", "screenParam": "\(param)" }
        """.utf8))
    }
}

// cspell:ignore Bibelkompass Bindung Glauben Müller Alles Finde Orientierung
import XCTest
@testable import HopeTViOS

/// The four invariants, the response guards, and the decoder's tolerance.
///
/// Five of the proof of concept's 27 contract tests survive the move to the App Contract;
/// the rest tested an envelope, a capability header and count caps that no longer exist.
final class ContractInvariantTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UnknownBlockLog.reset()
    }

    // MARK: - Invariant 1: the 256 KiB byte cap

    func testOversizedPayloadIsRejectedBeforeParsing() {
        let oversized = ContractLimits.maxPayloadBytes + 1

        XCTAssertEqual(ContractValidator.checkSize(bytes: oversized), .payloadTooLarge(bytes: oversized))
        XCTAssertNil(ContractValidator.checkSize(bytes: ContractLimits.maxPayloadBytes))
    }

    /// The declared length is refused before a byte of body is read.
    func testContentLengthOverTheCapIsRefusedUpFront() {
        let declared = Int64(ContractLimits.maxPayloadBytes) + 1

        XCTAssertEqual(ContractValidator.checkDeclaredLength(declared), .declaredPayloadTooLarge(bytes: Int(declared)))
        XCTAssertNil(ContractValidator.checkDeclaredLength(Int64(ContractLimits.maxPayloadBytes)))
        // A response with no declared length is not refused here; the running total catches it.
        XCTAssertNil(ContractValidator.checkDeclaredLength(-1))
    }

    func testEveryFixtureScreenIsUnderTheCap() throws {
        for name in ["manifest", "home", "browse", "live", "show", "episode"] {
            let bytes = try Fixtures.data(name).count
            XCTAssertNil(ContractValidator.checkSize(bytes: bytes), "\(name) is \(bytes) bytes")
        }
    }

    // MARK: - Invariant 2: an unknown node renders absent and logs once

    func testUnknownOptionalNodeIsOmittedAndReportedOnce() throws {
        let document = try TestDocument.make("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "isCanvas": true, "props": {}, "nodes": ["a", "b", "c"] },
          "a": { "type": { "resolvedName": "Nope" }, "props": {}, "nodes": [] },
          "b": { "type": { "resolvedName": "Nope" }, "props": {}, "nodes": [] },
          "c": { "type": { "resolvedName": "SimpleText" }, "props": { "text": "Still here" }, "nodes": [] }
        }
        """)
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: "ROOT", document: document, context: TestRender.context()))
        let report = node.keyReport

        // The screen survives the unknown blocks, and they are not in either bucket.
        XCTAssertEqual(report.rendered.sorted(), ["Root", "SimpleText"])
        XCTAssertTrue(report.null.isEmpty)
        // One report per key, for the session.
        XCTAssertFalse(UnknownBlockLog.report("Nope"))
        XCTAssertTrue(UnknownBlockLog.report("SomethingElse"))
    }

    /// Fails closed: an unrecognized `kind` never opens a screen, rather than opening it as
    /// a static one and letting the contract answer 400.
    func testUnrecognizedScreenKindFailsClosed() throws {
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [] } }],
          "screens": [{ "id": "s1", "kind": "carousel" }],
          "preset": {}
        }
        """.utf8))
        let tree = NavigationTree(manifest: manifest)

        XCTAssertEqual(manifest.screens.first?.kind, .unsupported)
        XCTAssertNil(tree.resolveTarget(screenId: "s1", param: nil, currentParam: nil))
        XCTAssertNil(tree.resolveTarget(screenId: "s1", param: "anything", currentParam: nil))
    }

    // MARK: - Invariant 4: https-only playback

    func testNonHttpsSourcesAreRejected() {
        XCTAssertNotNil(ContractValidator.playableURL("https://example.test/stream.m3u8"))

        for source in [
            "http://example.test/stream.m3u8",
            "file:///etc/passwd",
            "data:video/mp4;base64,AAAA",
            "javascript:alert(1)",
            "",
        ] {
            XCTAssertNil(ContractValidator.playableURL(source), "\(source) must not reach the player")
        }
        XCTAssertNil(ContractValidator.playableURL(nil))
    }

    func testTheRenditionLadderPrefersHlsAndSkipsNonHttps() throws {
        let links = try TestDocument.value("""
        { "hls": "http://example.test/insecure.m3u8",
          "mp4-hd": { "link": "https://example.test/hd.mp4" },
          "mp4-sd": "https://example.test/sd.mp4" }
        """)

        // The insecure HLS entry is skipped, not downgraded to an error.
        XCTAssertEqual(PlaybackService.episodeSource(.object(["mediaLinks": links]))?.rendition, "mp4-hd")
        XCTAssertEqual(PlaybackService.renditions, ["hls", "mp4-hd", "mp4-sd"])

        let secure = try TestDocument.value("""
        { "hls": "https://example.test/master.m3u8", "mp4-hd": "https://example.test/hd.mp4" }
        """)
        XCTAssertEqual(PlaybackService.episodeSource(.object(["mediaLinks": secure]))?.rendition, "hls")
    }

    func testEpisodePlayerResourceResolvesOnlyHttpsSources() throws {
        // A self-hosted provider stores the stream url itself. A Jetstream id resolves by its
        // own rule (`JetstreamSourceTests`).
        let hls = try TestDocument.value("""
        { "provider": "hls", "id": "https://example.test/episode.m3u8", "poster": "https://images.test/p.jpg" }
        """)
        XCTAssertEqual(PlaybackService.episodeSource(hls)?.url.absoluteString, "https://example.test/episode.m3u8")

        let insecure = try TestDocument.value("""
        { "provider": "hls", "id": "http://example.test/episode.m3u8" }
        """)
        XCTAssertNil(PlaybackService.episodeSource(insecure))

        // A YouTube id is not a URL this renderer can play, so no source resolves.
        let youtube = try TestDocument.value("""
        { "provider": "youtube", "id": "dQw4w9WgXcQ" }
        """)
        XCTAssertNil(PlaybackService.episodeSource(youtube))
    }

    // MARK: - The built-in floor

    func testTheBuiltInFloorValidatesAndRenders() throws {
        let manifest = BuiltInContract.manifest()
        let screen = BuiltInContract.screen()
        let tree = NavigationTree(manifest: manifest)

        XCTAssertNil(ContractValidator.assertManifestDesign(manifest))
        XCTAssertEqual(tree.rootScreenId, BuiltInContract.screenId)
        XCTAssertEqual(tree.tabs.count, 1)

        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context()
        ))
        XCTAssertEqual(node.keyReport.rendered.sorted(), ["Container", "Root", "Section", "SimpleText"])
        XCTAssertTrue(node.keyReport.null.isEmpty)
    }

    /// The floor names the shell's App. The name is free text, so it is JSON-escaped.
    func testTheBuiltInFloorUsesTheShellDisplayName() {
        let name = #"Hope TV "Deutsch" \ Test"#
        XCTAssertEqual(BuiltInContract.manifest(name: name).app.name, name)
        XCTAssertEqual(BuiltInContract.screen(name: name).content["title"]?.props["text"].text, name)
    }

    /// The floor draws in the shell's `CONTENT_LANGUAGE`: no manifest serves chrome strings here.
    func testTheBuiltInFloorDrawsInTheShellLanguage() throws {
        let german = BuiltInContract.strings(for: "de")
        let manifest = BuiltInContract.manifest(name: "TV", language: "de")
        let screen = BuiltInContract.screen(name: "TV", language: "de")

        XCTAssertEqual(manifest.app.defaultLanguage, "de")
        // cspell:disable-next-line
        XCTAssertEqual(try XCTUnwrap(manifest.layouts.first).navigation.tabs.first?.label, "Startseite")
        XCTAssertEqual(screen.language, "de")
        XCTAssertEqual(screen.content["note"]?.props["text"].text, german.unreachable)
    }

    func testTheBuiltInFloorMatchesThePrimarySubtagAndFallsBackToEnglish() {
        XCTAssertEqual(BuiltInContract.strings(for: "de-AT").language, "de")
        XCTAssertEqual(BuiltInContract.strings(for: "DE").language, "de")
        XCTAssertEqual(BuiltInContract.strings(for: "xx"), BuiltInContract.english)
        XCTAssertEqual(BuiltInContract.strings(for: ""), BuiltInContract.english)
    }

    // MARK: - Design gate

    func testAManifestForAnotherDesignIsRefused() throws {
        let manifest = try ContractDecoder.manifest(Data("""
        { "contractVersion": 1, "app": { "design": "hope" }, "layouts": [], "screens": [], "preset": {} }
        """.utf8))

        XCTAssertEqual(ContractValidator.assertManifestDesign(manifest), .wrongAppDesign("hope"))
        XCTAssertEqual(
            ContractValidator.assertManifestDesign(manifest)?.text,
            "manifest design is \"hope\"; this build renders the \"tv\" design only"
        )
    }

    func testAManifestWithNoDesignIsRefused() throws {
        let manifest = try ContractDecoder.manifest(Data("""
        { "contractVersion": 1, "app": {}, "layouts": [], "screens": [], "preset": {} }
        """.utf8))

        XCTAssertEqual(ContractValidator.assertManifestDesign(manifest), .wrongAppDesign(""))
    }

    // MARK: - Response-origin guard

    func testOnlyTheConfiguredOriginIsTrusted() throws {
        let expected = try XCTUnwrap(URL(string: "https://frontend-staging-api.hopeplatform.org"))

        XCTAssertTrue(ResponseOrigin.matches(expected: expected, actual: URL(string: "https://frontend-staging-api.hopeplatform.org/v1/app/hope-tv/manifest?lang=en")))
        // A redirect that lands anywhere else is refused, whatever it answers.
        XCTAssertFalse(ResponseOrigin.matches(expected: expected, actual: URL(string: "https://evil.test/v1/app/hope-tv/manifest")))
        XCTAssertFalse(ResponseOrigin.matches(expected: expected, actual: URL(string: "http://frontend-staging-api.hopeplatform.org/v1")))
        XCTAssertFalse(ResponseOrigin.matches(expected: expected, actual: URL(string: "https://frontend-staging-api.hopeplatform.org:8443/v1")))
        XCTAssertFalse(ResponseOrigin.matches(expected: expected, actual: nil))
    }

    // MARK: - Ids that reach a request path

    func testAnObjectIdIsTwentyFourAsciiHexBytes() {
        XCTAssertTrue(ContractValidator.isObjectId("6aa952fbc445860ea24e1bb6"))
        XCTAssertTrue(ContractValidator.isObjectId("6AA952FBC445860EA24E1BB6"))

        XCTAssertFalse(ContractValidator.isObjectId("6aa952fbc445860ea24e1bb"))
        XCTAssertFalse(ContractValidator.isObjectId("6aa952fbc445860ea24e1bb6a"))
        // Full-width digits and letters are hex to `Character.isHexDigit`, never to the server.
        XCTAssertFalse(ContractValidator.isObjectId(String(repeating: "\u{FF10}", count: 24)))
        XCTAssertFalse(ContractValidator.isObjectId("6aa952fbc445860ea24e1bb" + "\u{FF21}"))
        // 24 characters, 25 bytes: the count is on the bytes, not the graphemes.
        XCTAssertFalse(ContractValidator.isObjectId("6aa952fbc445860ea24e1bb" + "\u{00E9}"))
    }

    // MARK: - The two routes and the three headers

    func testTheClientBuildsBothRoutesAndSendsTheThreeHeaders() throws {
        let client = AppContractClient(config: TestConfig.staging)
        let screenId = "6aa952fbc445860ea24e1bb6"
        let manifest = try XCTUnwrap(client.manifestURL())
        let screen = try XCTUnwrap(client.screenURL(id: screenId, param: "def"))

        XCTAssertEqual(manifest.absoluteString, "https://api.test/v1/app/hope-tv/manifest?lang=en")
        XCTAssertEqual(screen.absoluteString, "https://api.test/v1/app/hope-tv/screens/\(screenId)?lang=en&param=def")
        XCTAssertEqual(
            client.screenURL(id: screenId, param: nil)?.absoluteString,
            "https://api.test/v1/app/hope-tv/screens/\(screenId)?lang=en"
        )
        // A screen id that is not a 24-hex id never becomes a path.
        XCTAssertNil(client.screenURL(id: "abc", param: nil))

        let headers = client.request(for: manifest).allHTTPHeaderFields ?? [:]
        XCTAssertEqual(headers["ClientToken"], "test-token")
        XCTAssertEqual(headers["X-AWE-App-Contract"], "1")
        // The 24-hex id, never the slug: the server rejects a slug with 400.
        XCTAssertEqual(headers["X-AWE-Entity"], "602bd46f36432128d40d5e81")
    }
}

/// The decoder's tolerance. An unknown key, a missing field or an extra field all decode.
final class CraftDecoderTests: XCTestCase {

    func testANodeWithNoPropsOrNodesStillDecodes() throws {
        let document = try TestDocument.make("""
        { "ROOT": { "type": { "resolvedName": "Root" } } }
        """)
        let root = try XCTUnwrap(document.root)

        XCTAssertEqual(root.key, .root)
        XCTAssertEqual(root.props, .object([:]))
        XCTAssertTrue(root.nodes.isEmpty)
        XCTAssertFalse(root.hidden)
    }

    func testExtraFieldsAndUnknownKeysAreCarriedNotThrown() throws {
        let document = try TestDocument.make("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["x"], "somethingNew": 42 },
          "x": { "type": { "resolvedName": "QuantumCarousel" }, "props": { "spin": true }, "nodes": [] }
        }
        """)

        XCTAssertEqual(document["x"]?.key, .unsupported("QuantumCarousel"))
        XCTAssertEqual(document["x"]?.props["spin"].bool, true)
    }

    func testAHiddenNodeRendersNothing() throws {
        let document = try TestDocument.make("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["t"] },
          "t": { "type": { "resolvedName": "SimpleText" }, "props": { "text": "hidden" }, "hidden": true }
        }
        """)
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: "ROOT", document: document, context: TestRender.context()))

        XCTAssertTrue(node.children.isEmpty)
    }

    func testSimpleTextWithNoTextRendersNull() throws {
        let document = try TestDocument.make("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["t"] },
          "t": { "type": { "resolvedName": "SimpleText" }, "props": { "as": "p" } }
        }
        """)
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: "ROOT", document: document, context: TestRender.context()))

        XCTAssertEqual(node.keyReport.null, ["SimpleText"])
    }

    func testAMissingRootDecodesToNothingRatherThanThrowing() throws {
        let document = try TestDocument.make("""
        { "somewhereElse": { "type": { "resolvedName": "Root" } } }
        """)

        XCTAssertNil(document.root)
        XCTAssertNil(BlockRegistry.evaluate(nodeId: "ROOT", document: document, context: TestRender.context()))
    }
}

/// The drift guard's Swift side (ADR-0164 point 4).
final class RegistryKeyListTests: XCTestCase {

    func testTheCommittedKeyListEqualsTheSwiftRegistry() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HopeTV/Registry/tvRegistryKeys.json")
        let file = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))

        XCTAssertEqual(file["keys"].array.compactMap(\.string), BlockRegistry.keys)
        XCTAssertEqual(file["renderer"].string, "swiftui-tvos")
        XCTAssertEqual(file["contractVersion"].int, 1)
    }

    func testEveryKeyResolvesToItsOwnCaseAndBack() {
        for key in BlockRegistry.keys {
            let resolved = BlockKey(resolvedName: key)
            XCTAssertTrue(resolved.isSupported, "\(key) is not in the Swift registry")
            XCTAssertEqual(resolved.name, key)
        }
        XCTAssertFalse(BlockKey(resolvedName: "Marquee").isSupported)
    }
}

// MARK: - Helpers

enum TestConfig {
    static let staging = ContractConfig(
        apiBaseURL: URL(string: "https://api.test")!,
        clientToken: "test-token",
        appSlug: "hope-tv",
        entityId: "602bd46f36432128d40d5e81",
        language: "en",
        imagesCDN: "https://images.test",
        imagesBucket: "bucket"
    )
}

enum TestDocument {
    static func make(_ json: String) throws -> CraftDocument {
        try JSONDecoder().decode(CraftDocument.self, from: Data(json.utf8))
    }

    static func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}

/// `ShowMeta` (ruled 2026-09-28): the `showMetaData` resource as label / value rows, in the web
/// block's order. Every prop defaults to on. Zero counts and empty lists draw no row; a host is
/// named by `PersonName.display`, and a host with no name draws no entry. An empty resource renders null.
final class ShowMetaTests: XCTestCase {

    private func evaluate(props: String = "{}", meta: String) throws -> EvaluatedNode {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "template",
          "blockResources": { "meta": { "resources": { "showMetaData": \(meta) } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["meta"] },
            "meta": {
              "type": { "resolvedName": "ShowMeta" },
              "props": \(props), "custom": { "type": "plugin", "resources": ["showMetaData"] },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: screen.blockResources)))
        return try XCTUnwrap(node.first { $0.key == .showMeta })
    }

    private func rows(props: String = "{}", meta: String) throws -> [ShowMetaModel.Row] {
        guard case let .showMeta(model) = try evaluate(props: props, meta: meta).content else {
            XCTFail("ShowMeta drew nothing")
            return []
        }
        return model.rows
    }

    private let bibelkompass = """
    {
      "title": "Bibelkompass",
      "hosts": [{ "_id": "p1", "firstName": "Matthias", "fullName": "Matthias Müller" }, { "_id": "p2", "firstName": "", "fullName": "" }],
      "categories": [{ "id": "c1", "title": "Bibel" }, { "id": "c2", "title": "Glauben" }],
      "language": "Deutsch",
      "seasonsCount": 10,
      "episodesCount": 17
    }
    """

    func testEveryPartDrawsInTheWebOrder() throws {
        let rows = try rows(meta: bibelkompass)

        XCTAssertEqual(rows.map(\.label), ["Show", "Hosts", "Categories", "Language", "Seasons", "Episodes"])
        XCTAssertEqual(rows.map(\.value), ["Bibelkompass", "Matthias Müller", "Bibel, Glauben", "Deutsch", "10", "17"])
    }

    func testPropsHideTheirRow() throws {
        let props = #"{ "showTitle": false, "showHosts": false, "showLanguage": false, "showEpisodes": false }"#
        XCTAssertEqual(try rows(props: props, meta: bibelkompass).map(\.label), ["Categories", "Seasons"])
    }

    func testZeroSeasonsAndNamelessHostsDrawNoRow() throws {
        let meta = #"{ "title": "inBindung", "hosts": [{ "_id": "p2" }, { "_id": "p3", "fullName": "" }], "categories": [], "seasonsCount": 0, "episodesCount": 112 }"#
        XCTAssertEqual(try rows(meta: meta).map(\.label), ["Show", "Episodes"])
    }

    /// A host is named by `PersonName.display` (awe#7116): Core treats `fullName` as an optional
    /// override, so a host with only the name parts still draws its name.
    func testAHostWithOnlyNamePartsDrawsTheComposedName() throws {
        let meta = #"{ "hosts": [{ "_id": "p1", "firstName": "Mark", "lastName": "Finley" }] }"#
        XCTAssertEqual(try rows(meta: meta).map(\.value), ["Mark Finley"])
    }

    func testAHostWithAFullNameKeepsTheFullName() throws {
        let meta = #"{ "hosts": [{ "_id": "p1", "firstName": "Mark", "lastName": "Finley", "fullName": "Pastor Mark Finley" }] }"#
        XCTAssertEqual(try rows(meta: meta).map(\.value), ["Pastor Mark Finley"])
    }

    /// An `initialsOnly` host (ADR-0008) arrives as `toPublicPerson` serves it: initials in the
    /// name parts and in `fullName`, no flag. It draws the initials.
    func testAnInitialsOnlyHostDrawsTheServedInitials() throws {
        let meta = #"{ "hosts": [{ "_id": "p1", "firstName": "M.", "lastName": "F.", "fullName": "M. F." }] }"#
        XCTAssertEqual(try rows(meta: meta).map(\.value), ["M. F."])
    }

    func testAHostWithNoNamePartDrawsNoEntry() throws {
        let meta = #"{ "hosts": [{ "_id": "p1", "firstName": "Mark", "lastName": "Finley" }, { "_id": "p2" }, { "_id": "p3", "firstName": "", "fullName": "" }] }"#
        XCTAssertEqual(try rows(meta: meta).map(\.value), ["Mark Finley"])
    }

    func testAnEmptyResourceRendersNull() throws {
        XCTAssertNil(try evaluate(meta: "{}").content)
        XCTAssertNil(try evaluate(props: #"{ "showTitle": false }"#, meta: #"{ "title": "Only a title" }"#).content)
    }
}

/// A failed pushed screen is calm copy (ruled 2026-09-28); the whole-app refusal names the shell.
final class FailureMessageTests: XCTestCase {

    func testAPushedScreenThatFailedSaysItIsNotAvailable() {
        let message = FailureMessage.unavailable

        XCTAssertEqual(message.title, "This content is not available.")
        XCTAssertEqual(message.detail, "Press Back to return.")
        XCTAssertFalse(message.title.contains("HTTP") || message.detail.contains("HTTP"), "the reason stays in the log")
    }

    func testTheWholeAppRefusalNamesTheShell() {
        let message = FailureMessage.refusal(.wrongAppDesign("hope"), appName: "Hope TV Deutsch")

        XCTAssertEqual(message.title, "Hope TV Deutsch cannot open this App")
        XCTAssertEqual(message.detail, RejectionReason.wrongAppDesign("hope").text)
    }
}

/// The text panel's scroll rule: short text never scrolls; long text scrolls a third of the
/// panel per press and lets focus leave at either end.
final class ReadingScrollTests: XCTestCase {

    func testShortTextHasNoPanelAndLetsFocusLeave() {
        let scroll = ReadingScroll(contentHeight: 400, maxHeight: 620)

        XCTAssertFalse(scroll.scrolls)
        XCTAssertNil(scroll.step(from: 0, down: true))
        XCTAssertNil(scroll.step(from: 0, down: false))
    }

    func testLongTextScrollsAThirdPerPressAndLeavesAtTheEnds() throws {
        let scroll = ReadingScroll(contentHeight: 1200, maxHeight: 600)
        XCTAssertTrue(scroll.scrolls)
        XCTAssertEqual(scroll.overflow, 600)

        XCTAssertNil(scroll.step(from: 0, down: false), "at the top, Up leaves the panel")
        let first = try XCTUnwrap(scroll.step(from: 0, down: true))
        XCTAssertEqual(first, 200)
        let second = try XCTUnwrap(scroll.step(from: first, down: true))
        let third = try XCTUnwrap(scroll.step(from: second, down: true))
        XCTAssertEqual(third, 600, "the last step stops at the end")
        XCTAssertNil(scroll.step(from: third, down: true), "at the bottom, Down leaves the panel")
        XCTAssertEqual(scroll.step(from: third, down: false), 400)
    }
}

/// Review round: the schedule clock takes the current time at once each time it runs, so a
/// strip that reappears (Back, a tab switch) never draws the time it last saw.
final class ScheduleClockTests: XCTestCase {

    private struct Stop: Error {}

    func testEachRunTakesTheTimeBeforeItSleeps() async {
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 5_000)
        var seen: [Date] = []

        // A run canceled at its first sleep still set the time first.
        await ScheduleClock.run(now: { first }, sleep: { _ in throw Stop() }) { seen.append($0) }
        XCTAssertEqual(seen, [first])

        // A restart (the strip shows again) takes the new time at once, not after a tick.
        await ScheduleClock.run(now: { later }, sleep: { _ in throw Stop() }) { seen.append($0) }
        XCTAssertEqual(seen, [first, later])
    }

    func testItTicksOncePerInterval() async {
        var ticks = 0
        var sleeps: [Duration] = []
        await ScheduleClock.run(interval: .seconds(60), now: { Date() }, sleep: { duration in
            sleeps.append(duration)
            if sleeps.count == 3 { throw Stop() }
        }) { _ in ticks += 1 }

        XCTAssertEqual(ticks, 3)
        XCTAssertEqual(sleeps, [.seconds(60), .seconds(60), .seconds(60)])
    }
}

/// Review round: the evaluator's default-focus choice matches the views. A block whose view
/// asks for focus is the default; a reading panel (it cannot ask) ends the search with none.
final class DefaultFocusRoleTests: XCTestCase {

    private func evaluate(_ blocks: [(id: String, name: String, props: String, resources: String)]) throws -> EvaluatedNode {
        let nodes = blocks.map { block in
            #""\#(block.id)": { "type": { "resolvedName": "\#(block.name)" }, "props": \#(block.props), "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] }"#
        }
        let resources = blocks.map { #""\#($0.id)": { "resources": \#($0.resources) }"# }
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1", "kind": "template",
          "blockResources": { \(resources.joined(separator: ", ")) },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": [\(blocks.map { "\"\($0.id)\"" }.joined(separator: ", "))] },
            \(nodes.joined(separator: ",\n"))
          }
        }
        """.utf8))
        return try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                    context: TestRender.context(blockResources: screen.blockResources)))
    }

    private let show = #"{ "showDetail": { "title": "Bibelkompass", "abstract": "Finde Orientierung.", "trailer": { "provider": "jetstream", "videoId": "jsv:QBvi99xy28Q" } } }"#
    private let episodes = #"{ "episodes": { "items": [{ "_id": "6a049248c6d68f1e30573243", "title": "One" }], "count": 1 } }"#

    /// The reviewed case: ShowDetail without a trailer above EpisodesList. The panel cannot ask,
    /// so there is no default, and focus never jumps past the show text to the first card.
    /// The fixture serves no show `_id`, so no Watch later toggle draws. A served show always has
    /// one: see `testAServedShowAsksWithItsWatchLaterToggle`.
    func testAReadingPanelFirstGivesNoDefault() throws {
        let node = try evaluate([
            ("detail", "ShowDetail", #"{ "showTrailer": false, "showAbstract": true }"#, show),
            ("list", "EpisodesList", "{}", episodes),
        ])
        XCTAssertEqual(node.firstFocusStop, .readsOnly)
        XCTAssertNil(node.firstFocusNodeId)
    }

    /// With a served ObjectId, the Watch later toggle is the block's first button and asks for
    /// the default focus (awe#6869, ruled 2026-10-15).
    func testAServedShowAsksWithItsWatchLaterToggle() throws {
        let served = show.replacingOccurrences(of: #""title": "Bibelkompass""#,
                                               with: #""_id": "61975e24d9c698836400305c", "title": "Bibelkompass""#)
        let node = try evaluate([
            ("detail", "ShowDetail", #"{ "showTrailer": false, "showAbstract": true }"#, served),
            ("list", "EpisodesList", "{}", episodes),
        ])
        XCTAssertEqual(node.firstFocusNodeId, "detail")
    }

    func testAShowDetailWithATrailerIsTheDefault() throws {
        let node = try evaluate([
            ("detail", "ShowDetail", #"{ "showTrailer": true }"#, show),
            ("list", "EpisodesList", "{}", episodes),
        ])
        XCTAssertEqual(node.firstFocusNodeId, "detail")
    }

    func testShowMetaFirstGivesNoDefault() throws {
        let node = try evaluate([
            ("meta", "ShowMeta", "{}", #"{ "showMetaData": { "title": "Bibelkompass", "episodesCount": 17 } }"#),
            ("list", "EpisodesList", "{}", episodes),
        ])
        XCTAssertNil(node.firstFocusNodeId)
    }

    /// The inline player asks now (it applies `TakesDefaultFocus`), and so does a schedule.
    func testTheInlinePlayerAndTheScheduleAsk() throws {
        let player = try evaluate([
            ("player", "LivestreamPlayer", "{}", #"{ "channel": { "title": "T", "hls": "https://live.example.org/x.m3u8" } }"#),
        ])
        XCTAssertEqual(player.firstFocusNodeId, "player")

        let strip = try evaluate([
            ("strip", "ScheduleLive", "{}", #"{ "channel": { "title": "T" }, "broadcastsLive": { "items": [{ "_id": "b1", "episodeTitle": "B" }] } }"#),
        ])
        XCTAssertEqual(strip.firstFocusNodeId, "strip")
    }

    /// Blocks that draw nothing focusable are skipped.
    func testTextAndEmptyBlocksAreSkipped() throws {
        let node = try evaluate([
            ("heading", "SimpleText", #"{ "text": "Alles", "as": "h1" }"#, "{}"),
            ("list", "EpisodesList", "{}", episodes),
        ])
        XCTAssertEqual(node.firstFocusNodeId, "list")
    }
}

/// Ruling A needs a served `null` told apart from a missing key. The subscript reads both as
/// `.null`; `hasKey` tells them apart, and nothing else changes.
final class JSONValueKeyTests: XCTestCase {

    func testHasKeyTellsAServedNullFromAMissingKey() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{ "screenLink": null, "title": "T" }"#.utf8))

        XCTAssertTrue(value.hasKey("screenLink"))
        XCTAssertTrue(value["screenLink"].isNull)
        XCTAssertFalse(value.hasKey("missing"))
        XCTAssertTrue(value["missing"].isNull, "the subscript still reads both alike")
        XCTAssertFalse(JSONValue.null.hasKey("screenLink"))
        XCTAssertFalse(JSONValue.array([]).hasKey("screenLink"))
    }
}

/// Ruling (i): the refetch loop fetches at once, then every interval; a vanished focused row
/// hands focus to its nearest neighbor.
final class ScheduleRefreshLoopTests: XCTestCase {

    private struct Stop: Error {}

    /// The loop sleeps first: `ScreenHost` already fetches the screen each time it appears, so
    /// a fetch here at once would ask twice.
    func testTheLoopSleepsBeforeItFetches() async {
        var events: [String] = []
        await ScheduleRefresh.loop(sleep: { _ in
            events.append("sleep")
            if events.filter({ $0 == "sleep" }).count == 3 { throw Stop() }
        }) {
            events.append("fetch")
        }
        XCTAssertEqual(events, ["sleep", "fetch", "sleep", "fetch", "sleep"])
    }

    /// The inline player loads its stream only on screen: a covered NavigationStack root or an
    /// unselected tab still sees the "may play" change and must stay silent.
    /// The inline card: before the first measure it uses the assumed tab-bar layout, so it does
    /// not jump; an odd huge content top never collapses it.
    func testTheInlineCardSizeIsStableBeforeTheFirstMeasure() {
        XCTAssertEqual(InlineCardSize.maxWidth(contentTop: nil),
                       InlineCardSize.maxWidth(contentTop: InlineCardSize.assumedContentTop))
        XCTAssertEqual(InlineCardSize.maxWidth(contentTop: nil), 1325, accuracy: 1, "the measured simulator size")
        XCTAssertEqual(InlineCardSize.maxWidth(contentTop: 5000), InlineCardSize.minWidth)
    }

    func testFocusMovesToTheNearestRowWhenItsRowGoesAway() {
        XCTAssertEqual(ScheduleFocus.replacement(for: "b", old: ["a", "b", "c"], new: ["a", "c"]), "c")
        XCTAssertEqual(ScheduleFocus.replacement(for: "c", old: ["a", "b", "c"], new: ["a", "b"]), "b", "the last row")
        XCTAssertEqual(ScheduleFocus.replacement(for: "b", old: ["a", "b", "c"], new: ["c", "d"]), "c",
                       "rows before it that also ended shift the position")
        XCTAssertNil(ScheduleFocus.replacement(for: "b", old: ["a", "b"], new: ["a", "b"]), "still there")
        XCTAssertNil(ScheduleFocus.replacement(for: "b", old: ["a", "b"], new: []), "no row left")
    }
}

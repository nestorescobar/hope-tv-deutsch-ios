import XCTest
@testable import HopeTViOS

/// Tap-to-play (awe#6549, spec §5.1–5.2). A card press on an episode loads the Episode Template
/// Screen through the store and plays its `EpisodePlayer` source at once. A source this device
/// cannot play, or a failed load, opens the Episode Screen as before. Any other target opens its
/// screen at once.
@MainActor
final class TapToPlayTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
        ContractCache().clear()
        StubProtocol.reset()
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        ContractCache().clear()
        StubProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private var images: ImageConfig { ImageConfig(cdn: TestConfig.staging.imagesCDN, bucket: TestConfig.staging.imagesBucket) }

    private func episodeScreenId() throws -> String { try XCTUnwrap(Fixtures.json("expectations")["screens"]["episode"]["id"].string) }
    private func episodeId() throws -> String { try XCTUnwrap(Fixtures.json("expectations")["screens"]["episode"]["param"].string) }

    /// The captured Episode Screen, with its `episodePlayer` resource replaced when asked.
    private func episodeScreen(player: [String: Any]? = nil) throws -> Data {
        let data = try Fixtures.data("episode")
        guard let player else { return data }
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var blocks = try XCTUnwrap(root["blockResources"] as? [String: Any])
        let nodeId = try XCTUnwrap(blocks.first { (($0.value as? [String: Any])?["resources"] as? [String: Any])?["episodePlayer"] != nil }?.key)
        blocks[nodeId] = ["resources": ["episodePlayer": player]]
        root["blockResources"] = blocks
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// The request the Episode Screen's own Play button builds, read through the evaluator.
    private func playButtonRequest(_ data: Data) throws -> PlaybackRequest? {
        let screen = try ContractDecoder.screen(data)
        let node = BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: RenderContext(blockResources: screen.blockResources, screenResources: screen.resources, images: images)
        )
        let found = node?.first { if case .playAction = $0.content { return true }; return false }
        guard case let .playAction(model)? = found?.content else { return nil }
        return model.request
    }

    private func store() -> ContractStore {
        ContractStore(config: TestConfig.staging, client: AppContractClient(config: TestConfig.staging, session: StubProtocol.session()))
    }

    /// The staging manifest, and the router wired to the store the way `HopeTVApp` wires it.
    private func router(_ store: ContractStore) throws -> AppRouter {
        let router = AppRouter(tree: NavigationTree(manifest: try ContractDecoder.manifest(Fixtures.data("manifest"))),
                               diagnostics: Diagnostics())
        router.playRequest = { [store] entry in await store.playRequest(screenId: entry.screenId, param: entry.param) }
        return router
    }

    private func episodeCard() throws -> CardTarget {
        CardTarget(resourceType: "episode", itemId: try episodeId())
    }

    // MARK: - Store + router, the path a press takes

    func testAPlayableEpisodePlaysAtOnceWithThePlayButtonsProgressKey() async throws {
        let data = try episodeScreen()
        StubProtocol.queue = [.init(status: 200, body: data)]
        let router = try router(store())

        await router.select(try episodeCard())?.value

        let expected = try XCTUnwrap(try playButtonRequest(data), "the fixture's Jetstream VOD id plays")
        XCTAssertEqual(router.playback, expected, "the same request as the Episode Screen's Play")
        XCTAssertEqual(router.playback?.progressId, expected.url.absoluteString, "resume reads the Play button's key")
        XCTAssertEqual(router.playback?.metadata.title, "Lesson 1: Suffering With the Good Shepherd")
        XCTAssertNotNil(router.playback?.metadata.showName, "the show name comes from `episodeDetail`, as on Play")
        XCTAssertTrue(router.state.stack.isEmpty, "the player opens over the screen the press came from")
        XCTAssertNil(router.selecting)
    }

    func testAnEpisodeThisDeviceCannotPlayOpensTheEpisodeScreen() async throws {
        let unplayable: [(String, [String: Any])] = [
            ("YouTube", ["provider": "youtube", "id": "dQw4w9WgXcQ"]),
            ("Vimeo", ["provider": "vimeo", "id": "76979871"]),
            ("Jetstream live", ["provider": "jetstream-live", "id": "jsl:AQfP7b5HoTM"]),
            ("Jetstream audio", ["provider": "jetstream-audio", "id": "jsa:AQfP7b5HoTM"]),
        ]
        for (name, player) in unplayable {
            ContractCache().clear()
            StubProtocol.queue = [.init(status: 200, body: try episodeScreen(player: player))]
            let router = try router(store())

            await router.select(try episodeCard())?.value

            XCTAssertNil(router.playback, "\(name) does not play")
            XCTAssertEqual(router.state.stack, [StackEntry(screenId: try episodeScreenId(), param: try episodeId())],
                           "\(name) opens the Episode Screen, which says it cannot play")
        }
    }

    /// D2: a failed load is never a dead press. The Episode Screen opens and draws its own error.
    func testAFailedLoadOpensTheEpisodeScreen() async throws {
        for failure: StubProtocol.Response in [.init(status: 404), .init(status: 200, body: Data("{".utf8))] {
            ContractCache().clear()
            StubProtocol.queue = [failure]
            let store = store()
            let router = try router(store)

            await router.select(try episodeCard())?.value

            XCTAssertNil(router.playback)
            XCTAssertEqual(router.state.stack, [StackEntry(screenId: try episodeScreenId(), param: try episodeId())])
            XCTAssertNil(store.screenEntry(id: try episodeScreenId(), param: try episodeId())?.screen,
                         "the pushed screen finds no copy, so it fetches again and draws its error state")
        }
    }

    /// A screen the store already holds answers at once: no second request before playback.
    func testALoadedEpisodeScreenPlaysWithoutWaitingForTheNetwork() async throws {
        let data = try episodeScreen()
        let store = store()
        StubProtocol.queue = [.init(status: 200, body: data)]
        await store.loadScreen(id: try episodeScreenId(), param: try episodeId())
        // The revalidation fetch answers late; the press must not wait for it.
        StubProtocol.queue = [.init(status: 200, body: data, delay: 5)]
        let router = try router(store)

        let started = ContinuousClock.now
        await router.select(try episodeCard())?.value

        XCTAssertNotNil(router.playback)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "the press did not wait for the revalidation")
    }

    /// A copy in the disk cache (last-known-good) answers at once on a fresh store. The fetch
    /// still runs behind it, but nothing is drawn, so the cache keeps the seeded bytes.
    func testACachedCopyOnDiskPlaysAtOnceAndIsNotPromotedWithoutADraw() async throws {
        let seeded = try episodeScreen()
        let fresher = try episodeScreen(player: ["provider": "jetstream", "id": "jsv:AbCdEfGhIjK"])
        let store = store()
        let key = store.key(for: try episodeScreenId(), param: try episodeId())
        ContractCache().store(seeded, for: key)
        StubProtocol.queue = [.init(status: 200, body: fresher, delay: 1)]
        let router = try router(store)

        let started = ContinuousClock.now
        await router.select(try episodeCard())?.value

        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500), "the cached copy answered at once")
        XCTAssertEqual(router.playback, try playButtonRequest(seeded), "it plays the cached copy")
        XCTAssertNotNil(store.screenEntry(id: try episodeScreenId(), param: try episodeId())?.screen, "the copy is ready in memory")

        // The revalidation answers a changed copy; nothing draws it, so it is not promoted.
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(StubProtocol.requests.count, 1, "the fetch ran behind the press")
        XCTAssertEqual(ContractCache().load(key), seeded, "last-known-good keeps the seeded bytes")
    }

    // MARK: - Resume (spec §5.2)

    /// The tap-to-play request reads the resume point the Episode Screen's Play wrote. The player
    /// seeks to it before it starts (`PlayerView.start`), with no prompt.
    func testTapToPlayResumesFromTheEpisodeScreensProgress() async throws {
        let data = try episodeScreen()
        let progress = WatchProgressStore()
        progress.clear()
        defer { progress.clear() }
        let play = try XCTUnwrap(try playButtonRequest(data))
        progress.record(0.4, for: play.progressId, title: play.title)

        StubProtocol.queue = [.init(status: 200, body: data)]
        let router = try router(store())
        await router.select(try episodeCard())?.value

        XCTAssertEqual(router.playback?.resumeFraction(in: progress), 0.4)
    }

    // MARK: - Router decisions

    private struct LoaderNeverRan: Error {}

    /// Yields until `condition` holds; fails instead of hanging when it never does.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        // A thrown error fails the test and stops it before it resumes nothing.
        if !condition() { throw LoaderNeverRan() }
    }

    private func syntheticRouter(_ resolve: (@MainActor (StackEntry) async -> PlaybackRequest?)?) throws -> AppRouter {
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1, "app": { "design": "tv" }, "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }, { "screenId": "live", "label": "Live" }] } }],
          "screens": [
            { "id": "home", "kind": "static" }, { "id": "live", "kind": "static" },
            { "id": "episode-tpl", "kind": "template", "resourceType": "episode" },
            { "id": "show-tpl", "kind": "template", "resourceType": "show" },
            { "id": "other-episode-page", "kind": "static" }
          ],
          "preset": {}
        }
        """.utf8))
        let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
        router.playRequest = resolve
        return router
    }

    private let request = PlaybackRequest(url: URL(string: "https://media.test/ep.m3u8")!,
                                          metadata: PlaybackMetadata(title: "Ep", description: nil, showName: nil, artworkURL: nil),
                                          isHLS: true)

    func testAShowTargetOpensItsScreenAtOnceAndLoadsNothing() throws {
        var asked = 0
        let router = try syntheticRouter { _ in asked += 1; return self.request }

        XCTAssertNil(router.select(CardTarget(resourceType: "show", itemId: "s1")))

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "show-tpl", param: "s1")])
        XCTAssertEqual(asked, 0)
        XCTAssertNil(router.playback)
    }

    /// "Is it an episode" is the resolved screen, not the card: a served link to a static screen
    /// opens that screen, even on an episode card.
    func testAnEpisodeCardLinkedToAnotherScreenOpensThatScreen() throws {
        var asked = 0
        let router = try syntheticRouter { _ in asked += 1; return self.request }
        var target = CardTarget(resourceType: "episode", itemId: "e1")
        target.link = ScreenLink(.object(["linkType": .string("screen"), "screen": .string("other-episode-page"),
                                          "screenParam": .string("e1")]))

        XCTAssertNil(router.select(target))

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "other-episode-page", param: nil)])
        XCTAssertEqual(asked, 0)
    }

    func testAPlayableEpisodeLoadsTheResolvedEntryAndPlays() async throws {
        var asked: [StackEntry] = []
        let router = try syntheticRouter { entry in asked.append(entry); return self.request }

        await router.select(CardTarget(resourceType: "episode", itemId: "e1"))?.value

        XCTAssertEqual(asked, [StackEntry(screenId: "episode-tpl", param: "e1")])
        XCTAssertEqual(router.playback, request)
        XCTAssertTrue(router.state.stack.isEmpty)
    }

    func testAnUnplayableEpisodeOpensTheEpisodeScreen() async throws {
        let router = try syntheticRouter { _ in nil }

        await router.select(CardTarget(resourceType: "episode", itemId: "e1"))?.value

        XCTAssertNil(router.playback)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: "e1")])
    }

    /// A router with no loader (a test, a preview) keeps the old press.
    func testWithNoLoaderAnEpisodeOpensItsScreen() throws {
        let router = try syntheticRouter(nil)

        XCTAssertNil(router.select(CardTarget(resourceType: "episode", itemId: "e1")))

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: "e1")])
    }

    func testPressesWhileAnEpisodeLoadsAreIgnored() async throws {
        var asked = 0
        var release: CheckedContinuation<Void, Never>?
        let router = try syntheticRouter { _ in
            asked += 1
            await withCheckedContinuation { release = $0 }
            return self.request
        }
        let target = CardTarget(resourceType: "episode", itemId: "e1")

        let first = router.select(target)
        await Task.yield()
        XCTAssertEqual(router.selecting, target, "the pressed card shows its loading cue")

        XCTAssertNil(router.select(target), "a repeat press is ignored")
        XCTAssertNil(router.select(CardTarget(resourceType: "show", itemId: "s1")), "so is a press on another card")
        XCTAssertTrue(router.state.stack.isEmpty)

        try await waitUntil { release != nil }
        release?.resume()
        await first?.value

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(router.playback, request)
        XCTAssertNil(router.selecting)
    }

    /// The viewer moved to another tab while the screen loaded: the press ends at once, and the
    /// answer does nothing.
    func testAnAnswerAfterTheViewerMovedOnIsDropped() async throws {
        var release: CheckedContinuation<Void, Never>?
        let router = try syntheticRouter { _ in
            await withCheckedContinuation { release = $0 }
            return self.request
        }

        let task = router.select(CardTarget(resourceType: "episode", itemId: "e1"))
        try await waitUntil { release != nil }
        router.state.selectTab("live")
        XCTAssertNil(router.selecting, "the tab change ends the press: no cue, presses work")
        release?.resume()
        await task?.value

        XCTAssertNil(router.playback)
        XCTAssertTrue(router.state.stack.isEmpty)
        XCTAssertNil(router.selecting)
    }

    /// Back (a pop of the pushed screen) during the load ends the press at once. A new press then
    /// works, and the first answer cannot touch it.
    func testBackDuringTheLoadEndsThePressAndANewPressWorks() async throws {
        var releases: [CheckedContinuation<Void, Never>] = []
        var asked: [StackEntry] = []
        let second = PlaybackRequest(url: URL(string: "https://media.test/ep2.m3u8")!,
                                     metadata: PlaybackMetadata(title: "Ep 2", description: nil, showName: nil, artworkURL: nil),
                                     isHLS: true)
        let router = try syntheticRouter { entry in
            asked.append(entry)
            await withCheckedContinuation { releases.append($0) }
            return entry.param == "e1" ? self.request : second
        }
        router.openCard(CardTarget(resourceType: "show", itemId: "s1"))

        let first = router.select(CardTarget(resourceType: "episode", itemId: "e1"))
        try await waitUntil { releases.count == 1 }
        router.state.stack.removeLast()
        XCTAssertNil(router.selecting, "Back ends the press")

        let next = router.select(CardTarget(resourceType: "episode", itemId: "e2"))
        XCTAssertNotNil(next, "a new press after Back works")
        try await waitUntil { releases.count == 2 }
        XCTAssertEqual(router.selecting, CardTarget(resourceType: "episode", itemId: "e2"))

        releases[0].resume()
        await first?.value
        XCTAssertNil(router.playback, "the first answer is dropped")
        XCTAssertEqual(router.selecting, CardTarget(resourceType: "episode", itemId: "e2"), "and it does not end the new press")

        releases[1].resume()
        await next?.value
        XCTAssertEqual(router.playback, second)
        XCTAssertEqual(asked.map(\.param), ["e1", "e2"])
        XCTAssertNil(router.selecting)
    }

    /// Playback the viewer starts during the load (the on-air row, the Live card, Trailer, Play)
    /// is kept: the late answer does not replace it and pushes nothing.
    func testAPlaybackStartedDuringTheLoadIsKept() async throws {
        var release: CheckedContinuation<Void, Never>?
        let router = try syntheticRouter { _ in
            await withCheckedContinuation { release = $0 }
            return self.request
        }
        let live = PlaybackRequest(url: URL(string: "https://live.test/main.m3u8")!,
                                   metadata: PlaybackMetadata(title: "Live", description: nil, showName: nil, artworkURL: nil),
                                   recordsProgress: false, isHLS: true)

        let task = router.select(CardTarget(resourceType: "episode", itemId: "e1"))
        try await waitUntil { release != nil }
        router.play(live)
        XCTAssertNil(router.selecting, "the playback ends the press")
        release?.resume()
        await task?.value

        XCTAssertEqual(router.playback, live)
        XCTAssertTrue(router.state.stack.isEmpty)
    }

    // MARK: - Time limit (developer ruling 2026-10-10)

    func testTheTimeLimitIsAboutThreeSeconds() throws {
        XCTAssertEqual(AppRouter.tapToPlayTimeLimit, .seconds(3))
        XCTAssertEqual(try syntheticRouter(nil).tapToPlayTimeLimit, .seconds(3))
    }

    /// No answer within the limit: the Episode Screen opens and draws its own loading state. A
    /// late answer is dropped, so the player never opens over it.
    func testAStalledLoadOpensTheEpisodeScreenAfterTheLimitAndDropsTheLateAnswer() async throws {
        var release: CheckedContinuation<Void, Never>?
        let router = try syntheticRouter { _ in
            await withCheckedContinuation { release = $0 }
            return self.request
        }
        router.tapToPlayTimeLimit = .milliseconds(50)

        let task = router.select(CardTarget(resourceType: "episode", itemId: "e1"))
        try await waitUntil { release != nil }
        XCTAssertTrue(router.state.stack.isEmpty, "nothing opens before the limit")
        for _ in 0..<100 where router.state.stack.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: "e1")])
        XCTAssertNil(router.selecting)

        release?.resume()
        await task?.value
        XCTAssertNil(router.playback, "the late answer is dropped")
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: "e1")])
    }
}

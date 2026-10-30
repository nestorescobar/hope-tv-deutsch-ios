// cspell:ignore Abspielen Entdecken
import SwiftUI
import XCTest
@testable import HopeTViOS

/// The foreground trigger (awe#5398): the same rule as `apps/mobile`'s `useAppForeground`.
final class ForegroundTriggerTests: XCTestCase {

    private func fires(_ phases: [ScenePhase]) -> [Bool] {
        var trigger = ForegroundTrigger()
        return phases.map { trigger.fires(on: $0) }
    }

    func testBackgroundThenActiveFiresOnce() {
        XCTAssertEqual(fires([.background, .active]), [false, true])
    }

    /// Control Center, a notification, the app switcher preview: not a return.
    func testInactiveThenActiveDoesNotFire() {
        XCTAssertEqual(fires([.active, .inactive, .active]), [false, false, false])
    }

    /// An interrupted resume.
    func testBackgroundThenInactiveThenActiveFiresOnce() {
        XCTAssertEqual(fires([.background, .inactive, .active]), [false, false, true])
    }

    func testASecondActiveWithoutANewBackgroundDoesNotFire() {
        XCTAssertEqual(fires([.background, .active, .inactive, .active]), [false, true, false, false])
    }
}

/// The foreground refresh is throttled by `chrome.ttlSec`, and a new manifest still activates
/// only at a safe boundary (invariant 3).
@MainActor
final class ManifestForegroundRefreshTests: XCTestCase {

    /// A clock the test moves by hand, so no test sleeps.
    private final class TestClock {
        var now = ContinuousClock.now
        func advance(_ seconds: Int) { now = now.advanced(by: .seconds(seconds)) }
    }

    private func manifest(name: String = "Hope TV", tab: String = "Home", play: String = "Play", ttlSec: String? = nil) -> Data {
        let ttl = ttlSec.map { ", \"ttlSec\": \($0)" } ?? ""
        return Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv", "name": "\(name)" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "s1", "label": "\(tab)" }] } }],
          "screens": [{ "id": "s1", "kind": "static" }],
          "preset": {},
          "chrome": { "strings": { "tvPlay": "\(play)" }\(ttl) }
        }
        """.utf8)
    }

    private func makeStore(_ clock: TestClock) -> ContractStore {
        let config = TestConfig.staging
        return ContractStore(
            config: config,
            client: AppContractClient(config: config, session: StubProtocol.session()),
            now: { clock.now }
        )
    }

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
        StubProtocol.reset()
        ContractCache().clear()
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        ContractCache().clear()
        StubProtocol.reset()
        super.tearDown()
    }

    func testTheTtlDecodesWithTheDefaultForAMissingOrInvalidValue() throws {
        XCTAssertEqual(try ContractDecoder.manifest(manifest()).chromeTtlSec, 300)
        XCTAssertEqual(try ContractDecoder.manifest(manifest(ttlSec: "60")).chromeTtlSec, 60)
        XCTAssertEqual(try ContractDecoder.manifest(manifest(ttlSec: "0")).chromeTtlSec, 300)
        XCTAssertEqual(try ContractDecoder.manifest(manifest(ttlSec: "-5")).chromeTtlSec, 300)
        XCTAssertEqual(try ContractDecoder.manifest(manifest(ttlSec: "\"soon\"")).chromeTtlSec, 300)
    }

    func testAForegroundInsideTheTtlMakesNoRequest() async {
        let clock = TestClock()
        let store = makeStore(clock)
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()
        XCTAssertEqual(StubProtocol.requests.count, 1, "the launch fetch")

        clock.advance(299)
        await store.refreshManifestIfStale()
        XCTAssertEqual(StubProtocol.requests.count, 1, "inside the 300 s default ttl")

        clock.advance(2)
        StubProtocol.queue = [.init(status: 200, body: manifest(name: "Newer"))]
        await store.refreshManifestIfStale()
        XCTAssertEqual(StubProtocol.requests.count, 2, "after the ttl")
        XCTAssertEqual(store.manifest.app.name, "Newer")
    }

    func testACustomTtlIsHonored() async {
        let clock = TestClock()
        let store = makeStore(clock)
        StubProtocol.queue = [.init(status: 200, body: manifest(ttlSec: "60"))]
        await store.refreshManifest()

        clock.advance(59)
        await store.refreshManifestIfStale()
        XCTAssertEqual(StubProtocol.requests.count, 1)

        clock.advance(2)
        StubProtocol.queue = [.init(status: 200, body: manifest(ttlSec: "60"))]
        await store.refreshManifestIfStale()
        XCTAssertEqual(StubProtocol.requests.count, 2, "61 s is past a 60 s ttl, not inside the 300 s default")
    }

    func testAFailedFetchDoesNotStartTheWindow() async {
        let clock = TestClock()
        let store = makeStore(clock)
        StubProtocol.queue = [.init(status: 500)]
        await store.refreshManifest()

        clock.advance(1)
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifestIfStale()
        XCTAssertEqual(StubProtocol.requests.count, 2, "a failed launch fetch leaves nothing to throttle on")

        // A failure after the window closes does not open a new one: the next foreground tries again.
        clock.advance(301)
        StubProtocol.queue = [.init(status: 503)]
        await store.refreshManifestIfStale()
        clock.advance(1)
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifestIfStale()
        XCTAssertEqual(StubProtocol.requests.count, 4)
    }

    /// Back from Home with the full-screen player still up: the new manifest is fetched, held,
    /// and activates when the viewer reaches a safe boundary.
    func testAChangedManifestFetchedWhilePlayingIsHeldUntilTheSafeBoundary() async {
        let clock = TestClock()
        let store = makeStore(clock)
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()
        let generation = store.manifestGeneration

        store.isAtSafeBoundary = false
        clock.advance(301)
        StubProtocol.queue = [.init(status: 200, body: manifest(name: "Hope TV Deutsch", tab: "Start", play: "Abspielen"))]
        await store.refreshManifestIfStale()

        XCTAssertEqual(StubProtocol.requests.count, 2, "the foreground fetch ran")
        XCTAssertEqual(store.manifest.app.name, "Hope TV")
        XCTAssertEqual(store.manifest.layouts.first?.navigation.tabs.first?.label, "Home")
        XCTAssertEqual(store.manifestGeneration, generation)
        XCTAssertEqual(ChromeText.string(.play), "Play")

        store.isAtSafeBoundary = true

        XCTAssertEqual(store.manifest.app.name, "Hope TV Deutsch")
        XCTAssertEqual(store.manifest.layouts.first?.navigation.tabs.first?.label, "Start")
        XCTAssertEqual(store.manifestGeneration, generation + 1)
        XCTAssertEqual(ChromeText.string(.play), "Abspielen")
    }

    /// The launch fetch is still on the wire when the viewer comes back: no second fetch, so
    /// two answers can never land out of order.
    func testAForegroundWhileAFetchIsInFlightMakesNoSecondRequest() async throws {
        let store = makeStore(TestClock())
        StubProtocol.queue = [.init(status: 200, body: manifest(), delay: 0.5)]
        let launch = Task { await store.refreshManifest() }

        // Wait until the launch request reached the stub: the fetch is now in flight.
        for _ in 0..<200 where StubProtocol.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(StubProtocol.requests.count, 1)

        await store.refreshManifestIfStale()
        XCTAssertEqual(StubProtocol.requests.count, 1, "a foreground during the launch fetch sends nothing")

        await launch.value
        XCTAssertEqual(store.manifest.app.name, "Hope TV")
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    /// A manifest that activates mid-session (a foreground refresh) is promoted once it draws,
    /// not only the launch copy. The view calls `markManifestRendered` on each activation.
    func testAManifestActivatedMidSessionIsPromotedWhenItDraws() async throws {
        let config = TestConfig.staging
        let key = ContractCacheKey.manifest(config, contractVersion: 1)
        let clock = TestClock()
        let store = makeStore(clock)
        StubProtocol.queue = [.init(status: 200, body: manifest(name: "Launch"))]
        await store.refreshManifest()
        store.markManifestRendered()

        store.isAtSafeBoundary = false
        clock.advance(301)
        StubProtocol.queue = [.init(status: 200, body: manifest(name: "Foreground"))]
        await store.refreshManifestIfStale()
        store.isAtSafeBoundary = true
        store.markManifestRendered()

        let onDisk = try XCTUnwrap(ContractCache().load(key))
        XCTAssertEqual(try ContractDecoder.manifest(onDisk).app.name, "Foreground")
    }

    // MARK: - Byte dedupe: the bytes on show change nothing

    /// The server caches the manifest, so most refetches answer the bytes on show. The fetch
    /// still counts for the ttl.
    func testTheSameBytesAsTheActiveManifestChangeNothing() async {
        let clock = TestClock()
        let store = makeStore(clock)
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()
        XCTAssertEqual(store.manifestGeneration, 1)

        clock.advance(200)
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()
        XCTAssertEqual(store.manifestGeneration, 1, "no activation for the bytes on show")
        XCTAssertEqual(store.manifest.app.name, "Hope TV")
        XCTAssertEqual(store.manifestSource, .remote)

        clock.advance(200)
        await store.refreshManifestIfStale()
        XCTAssertEqual(StubProtocol.requests.count, 2, "the same-bytes fetch restarted the ttl window")
    }

    func testTheSameBytesAsTheCachedCopyAtLaunchChangeNothing() async {
        let config = TestConfig.staging
        ContractCache().store(manifest(name: "Cached"), for: ContractCacheKey.manifest(config, contractVersion: 1))
        let store = makeStore(TestClock())
        XCTAssertEqual(store.manifestSource, .lastKnownGood)

        StubProtocol.queue = [.init(status: 200, body: manifest(name: "Cached"))]
        await store.refreshManifest()

        XCTAssertEqual(store.manifestSource, .lastKnownGood)
        XCTAssertEqual(store.manifestGeneration, 0)
    }

    /// The newest answer is what is on show, so an older held copy is stale too.
    func testAFetchThatAnswersTheActiveBytesDropsAHeldCopy() async {
        let store = makeStore(TestClock())
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()

        store.isAtSafeBoundary = false
        StubProtocol.queue = [.init(status: 200, body: manifest(name: "Held"))]
        await store.refreshManifest()
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()

        store.isAtSafeBoundary = true
        XCTAssertEqual(store.manifest.app.name, "Hope TV")
        XCTAssertEqual(store.manifestGeneration, 1)
    }

    func testDifferentBytesStillActivate() async {
        let store = makeStore(TestClock())
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()
        StubProtocol.queue = [.init(status: 200, body: manifest(name: "Newer"))]
        await store.refreshManifest()

        XCTAssertEqual(store.manifest.app.name, "Newer")
        XCTAssertEqual(store.manifestGeneration, 2)
    }

    /// A refusal (a manifest for another design) ends when the server answers the bytes on show again.
    func testTheSameBytesAfterARefusalClearTheRefusal() async {
        let store = makeStore(TestClock())
        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()
        let otherDesign = String(decoding: manifest(), as: UTF8.self).replacingOccurrences(of: "\"design\": \"tv\"", with: "\"design\": \"hope\"")
        StubProtocol.queue = [.init(status: 200, body: Data(otherDesign.utf8))]
        await store.refreshManifest()
        XCTAssertNotNil(store.refusal)

        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()
        XCTAssertNil(store.refusal)
    }

    /// A first launch shows a spinner, not the built-in floor's copy, until the launch fetch ends.
    func testTheBuiltInFloorAwaitsTheLaunchFetch() async {
        let store = makeStore(TestClock())
        XCTAssertEqual(store.manifestSource, .builtIn)
        XCTAssertTrue(store.awaitingFirstManifest)

        StubProtocol.queue = [.init(status: 200, body: manifest())]
        await store.refreshManifest()

        XCTAssertFalse(store.awaitingFirstManifest)
        XCTAssertEqual(store.manifestSource, .remote)
    }

    /// A failed launch fetch ends the wait, so the built-in floor draws (never a spinner forever).
    func testAFailedLaunchFetchShowsTheBuiltInFloor() async {
        let store = makeStore(TestClock())
        StubProtocol.queue = [.init(status: 503)]
        await store.refreshManifest()

        XCTAssertFalse(store.awaitingFirstManifest)
        XCTAssertEqual(store.manifestSource, .builtIn)
    }

    /// A cached manifest paints at once: no spinner.
    func testACachedManifestDoesNotWait() {
        ContractCache().store(manifest(name: "Cached"), for: ContractCacheKey.manifest(TestConfig.staging, contractVersion: 1))
        XCTAssertFalse(makeStore(TestClock()).awaitingFirstManifest)
    }
}

/// The tree a new manifest builds: the view on show survives when its tab does.
@MainActor
final class RouterRebuildTests: XCTestCase {

    private func manifest(tabs: [(id: String, label: String)]) throws -> AppManifest {
        let rows = tabs.map { "{ \"screenId\": \"\($0.id)\", \"label\": \"\($0.label)\" }" }
        let screens = tabs.map { "{ \"id\": \"\($0.id)\", \"kind\": \"static\" }" }
        return try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [\(rows.joined(separator: ", "))] } }],
          "screens": [\(screens.joined(separator: ", "))],
          "preset": {}
        }
        """.utf8))
    }

    func testANewManifestThatKeepsTheTabKeepsTheTabAndTheStack() throws {
        let router = AppRouter(
            tree: NavigationTree(manifest: try manifest(tabs: [("home", "Home"), ("browse", "Browse")])),
            diagnostics: Diagnostics()
        )
        router.state.selectTab("browse")
        router.state.push(StackEntry(screenId: "show", param: "123"))

        router.rebuild(with: try manifest(tabs: [("home", "Start"), ("browse", "Entdecken")]))

        XCTAssertEqual(router.state.tabScreenId, "browse")
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "show", param: "123")])
        XCTAssertEqual(router.tree.tabs.map(\.label), ["Start", "Entdecken"])
    }

    func testANewManifestThatDropsTheTabResetsToTheRootTab() throws {
        let router = AppRouter(
            tree: NavigationTree(manifest: try manifest(tabs: [("home", "Home"), ("browse", "Browse")])),
            diagnostics: Diagnostics()
        )
        router.state.selectTab("browse")
        router.state.push(StackEntry(screenId: "show", param: "123"))

        router.rebuild(with: try manifest(tabs: [("home", "Home"), ("live", "Live")]))

        XCTAssertEqual(router.state.tabScreenId, "home")
        XCTAssertEqual(router.state.stack, [])
    }
}

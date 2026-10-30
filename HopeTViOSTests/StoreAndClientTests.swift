import XCTest
@testable import HopeTViOS

/// A stub transport. Each request answers the next queued response, so a test can drive the
/// client without a network.
final class StubProtocol: URLProtocol {
    struct Response {
        var status = 200
        var url: URL?
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// Sends the body in pieces, so the running byte total is exercised.
        var chunks: [Data]?
        /// Answers after this many seconds, so a test can act while the fetch is in flight.
        var delay: TimeInterval = 0
    }

    nonisolated(unsafe) static var queue: [Response] = []
    /// Every request the stub was asked for, in order.
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        queue = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubProtocol.requests.append(request)
        let next = StubProtocol.queue.isEmpty ? Response() : StubProtocol.queue.removeFirst()
        guard next.delay > 0 else { return answer(next) }
        DispatchQueue.global().asyncAfter(deadline: .now() + next.delay) { self.answer(next) }
    }

    private func answer(_ next: Response) {
        let url = next.url ?? request.url!
        let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in next.chunks ?? [next.body] {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// The guards that only show up on the wire.
final class ContractClientWiringTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    private var client: AppContractClient {
        AppContractClient(config: TestConfig.staging, session: StubProtocol.session())
    }

    /// A 200 is not enough: the body has to come from the configured origin.
    func testA200FromAnotherOriginIsRefused() async throws {
        StubProtocol.queue = [.init(
            status: 200,
            url: URL(string: "https://evil.test/v1/app/hope-tv/manifest"),
            body: Data(#"{"contractVersion":1}"#.utf8)
        )]

        let result = await client.fetchManifest()

        guard case let .failure(reason) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(reason, .wrongOrigin("https://evil.test"))
    }

    /// No `Content-Length`, so only the running total can stop it.
    func testAChunkedOversizeBodyIsRefusedByTheRunningTotal() async throws {
        let chunk = Data(repeating: 0x20, count: 64 * 1024)
        StubProtocol.queue = [.init(status: 200, chunks: Array(repeating: chunk, count: 6))]

        let result = await client.fetchManifest()

        guard case let .failure(reason) = result else { return XCTFail("expected a refusal") }
        guard case let .payloadTooLarge(bytes) = reason else { return XCTFail("expected a size refusal, got \(reason)") }
        XCTAssertGreaterThan(bytes, ContractLimits.maxPayloadBytes)
    }

    func testABodyUnderTheCapIsRead() async throws {
        let body = Data(#"{"contractVersion":1,"app":{"design":"tv"},"layouts":[],"screens":[],"preset":{}}"#.utf8)
        StubProtocol.queue = [.init(status: 200, body: body)]

        let result = await client.fetchManifest()

        guard case let .success(data) = result else { return XCTFail("expected the body") }
        XCTAssertEqual(data, body)
    }

    /// A screen id is checked before it is interpolated into the path.
    func testAMalformedScreenIdNeverReachesTheWire() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data("{}".utf8))]

        let result = await client.fetchScreen(id: "../../admin", param: nil)

        guard case let .failure(reason) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(reason, .malformedScreenId("../../admin"))
        XCTAssertNil(client.screenURL(id: "../../admin", param: nil))
        XCTAssertNotNil(client.screenURL(id: "6aa952fbc445860ea24e1bb6", param: nil))
        // The stub was never asked for anything.
        XCTAssertEqual(StubProtocol.queue.count, 1)
    }
}

/// The last-known-good ladder.
@MainActor
final class ContractStorePromotionTests: XCTestCase {

    private let cachedManifest = """
    {
      "contractVersion": 1,
      "app": { "design": "tv", "name": "Cached" },
      "defaultLayoutId": "l1",
      "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "s1", "label": "Home" }] } }],
      "screens": [{ "id": "s1", "kind": "static" }],
      "preset": {}
    }
    """

    private func remoteManifest(_ name: String) -> String {
        cachedManifest.replacingOccurrences(of: "\"name\": \"Cached\"", with: "\"name\": \"\(name)\"")
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

    /// The bug this covers: `promoted` was also set on a cache READ, so after the first launch
    /// no remote copy was ever written and the file froze on its first version.
    func testARenderedRemoteManifestOverwritesACacheHitFromLaunch() async throws {
        let config = TestConfig.staging
        let key = ContractCacheKey.manifest(config, contractVersion: 1)
        let cache = ContractCache()

        // Launch 2: a cached copy is on disk and is adopted at init.
        cache.store(Data(cachedManifest.utf8), for: key)
        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
        XCTAssertEqual(store.manifestSource, .lastKnownGood)
        XCTAssertEqual(store.manifest.app.name, "Cached")

        // A newer remote copy arrives, activates and draws.
        StubProtocol.queue = [.init(status: 200, body: Data(remoteManifest("Remote").utf8))]
        await store.refreshManifest()
        XCTAssertEqual(store.manifestSource, .remote)
        XCTAssertEqual(store.manifest.app.name, "Remote")

        store.markManifestRendered()

        let onDisk = try XCTUnwrap(cache.load(key))
        let reloaded = try ContractDecoder.manifest(onDisk)
        XCTAssertEqual(reloaded.app.name, "Remote", "the cache file must hold the rendered remote bytes")
        XCTAssertEqual(store.manifestGeneration, 1, "the view needs a stamp to rebuild the tree on")
    }

    /// The chrome strings move with the manifest: the cached copy's at init (the first frame),
    /// and a remote copy's only when it activates at a safe boundary.
    func testTheChromeStringsFollowTheActiveManifest() async {
        let config = TestConfig.staging
        let withPlay = { (label: String, name: String) in
            self.remoteManifest(name).replacingOccurrences(
                of: "\"preset\": {}", with: "\"preset\": {}, \"chrome\": { \"strings\": { \"tvPlay\": \"\(label)\" } }")
        }
        ContractCache().store(Data(withPlay("Play (cached)", "Cached").utf8), for: ContractCacheKey.manifest(config, contractVersion: 1))

        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
        XCTAssertEqual(ChromeText.string(.play), "Play (cached)", "a cache-painted launch draws its language on the first frame")

        store.isAtSafeBoundary = false
        StubProtocol.queue = [.init(status: 200, body: Data(withPlay("Play (remote)", "Remote").utf8))]
        await store.refreshManifest()
        XCTAssertEqual(ChromeText.string(.play), "Play (cached)", "a held manifest keeps the strings on show")

        store.isAtSafeBoundary = true
        XCTAssertEqual(ChromeText.string(.play), "Play (remote)")
    }

    /// A cached manifest for another design is not adopted; the ladder falls back.
    func testACachedManifestForAnotherDesignIsNotAdopted() throws {
        let config = TestConfig.staging
        let key = ContractCacheKey.manifest(config, contractVersion: 1)
        ContractCache().store(Data(cachedManifest.replacingOccurrences(of: "\"design\": \"tv\"", with: "\"design\": \"hope\"").utf8), for: key)

        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))

        XCTAssertEqual(store.manifestSource, .builtIn)
        XCTAssertEqual(store.manifest.app.slug, "builtin")
    }
}

/// The schedule refetch reuses `loadScreen`, so invariant 3 holds for it: a replacement that
/// lands while the viewer is not at a safe boundary waits, and activates at the boundary.
@MainActor
final class ScreenRefetchBoundaryTests: XCTestCase {

    private func screen(_ title: String) -> Data {
        Data("""
        {
          "id": "6aa952fcc445860ea24e1bd7", "kind": "static", "blockResources": {},
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["t"] },
            "t": { "type": { "resolvedName": "SimpleText" }, "props": { "text": "\(title)" }, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8)
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

    private func text(_ store: ContractStore) -> String? {
        let screen = store.screenEntry(id: "6aa952fcc445860ea24e1bd7", param: nil)?.screen
        return screen?.content["t"]?.props["text"].string
    }

    func testARefetchedScreenWaitsForTheSafeBoundary() async throws {
        let config = TestConfig.staging
        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
        let id = "6aa952fcc445860ea24e1bd7"

        StubProtocol.queue = [.init(status: 200, body: screen("First"))]
        await store.loadScreen(id: id, param: nil)
        XCTAssertEqual(text(store), "First", "a first paint never waits")

        store.isAtSafeBoundary = false
        StubProtocol.queue = [.init(status: 200, body: screen("Second"))]
        await store.loadScreen(id: id, param: nil)
        XCTAssertEqual(text(store), "First", "held while media plays or a screen is pushed")

        store.isAtSafeBoundary = true
        XCTAssertEqual(text(store), "Second", "activated at the boundary")
    }
}

/// The Live screen holds no inline player, so its tab root is a plain safe boundary: a refetched
/// or a first-fetched copy applies at once, and only a full-screen player holds it.
@MainActor
final class LiveScreenRefreshTests: XCTestCase {

    private let id = "6ab6e3e9781df5a29fe4d265"

    private func live(title: String = "Next", scheduleFirst: Bool = false) -> Data {
        let order = scheduleFirst ? #"["strip", "player"]"# : #"["player", "strip"]"#
        return Data("""
        {
          "id": "\(id)", "kind": "static",
          "blockResources": {
            "player": { "resources": { "channel": { "title": "Hope TV Deutsch", "hls": "https://live.example.org/a.m3u8" } } },
            "strip": { "resources": { "channel": { "title": "Hope TV Deutsch" },
              "broadcastsLive": { "items": [{ "_id": "b1", "episodeTitle": "\(title)" }] } } }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": \(order) },
            "player": { "type": { "resolvedName": "LivestreamPlayer" }, "props": {}, "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] },
            "strip": { "type": { "resolvedName": "ScheduleLive" }, "props": {}, "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8)
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

    private func makeStore() -> ContractStore {
        let config = TestConfig.staging
        return ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
    }

    private func firstRowTitle(_ store: ContractStore) -> String? {
        store.screenEntry(id: id, param: nil)?.screen?.blockResources["strip"]?["broadcastsLive"]?["items"][0]["episodeTitle"].string
    }

    private func order(_ store: ContractStore) -> [String] {
        store.screenEntry(id: id, param: nil)?.screen?.content.root?.nodes ?? []
    }

    func testARefetchAtTheTabRootAppliesAtOnce() async {
        let store = makeStore()
        StubProtocol.queue = [.init(status: 200, body: live())]
        await store.loadScreen(id: id, param: nil)
        StubProtocol.queue = [.init(status: 200, body: live(title: "Fresh"))]
        await store.loadScreen(id: id, param: nil)

        XCTAssertEqual(firstRowTitle(store), "Fresh")
    }

    /// The full-screen stream holds the copy; Back applies it.
    func testARefetchUnderTheFullScreenStreamWaitsForBack() async {
        let store = makeStore()
        StubProtocol.queue = [.init(status: 200, body: live())]
        await store.loadScreen(id: id, param: nil)
        store.isAtSafeBoundary = false
        StubProtocol.queue = [.init(status: 200, body: live(title: "Fresh"))]
        await store.loadScreen(id: id, param: nil)
        XCTAssertEqual(firstRowTitle(store), "Next", "held while the stream plays full screen")

        store.isAtSafeBoundary = true
        XCTAssertEqual(firstRowTitle(store), "Fresh")
    }

    /// A cache-painted Live screen takes a changed first fetch at once: there is no player to
    /// wait for, so no revalidation window.
    func testAReorderedFirstFetchReplacesTheCachedCopy() async {
        let store = makeStore()
        ContractCache().store(live(), for: store.key(for: id, param: nil))
        StubProtocol.queue = [.init(status: 200, body: live(scheduleFirst: true))]
        await store.loadScreen(id: id, param: nil)

        XCTAssertEqual(order(store), ["strip", "player"])
    }

    /// A screen a debug override answered never becomes last-known-good, so a UI-test fixture
    /// never outlives its run (it once did, and the next launch drew the fixture's rows).
    func testAnOverriddenScreenIsNeverCached() async {
        let overriddenId = "6ab6e3e9781df5a29fe4d999"
        let store = makeStore()
        DebugScreenOverride.markOverridden(overriddenId)
        StubProtocol.queue = [.init(status: 200, body: Data(String(decoding: live(), as: UTF8.self)
            .replacingOccurrences(of: id, with: overriddenId).utf8))]
        await store.loadScreen(id: overriddenId, param: nil)
        let key = store.key(for: overriddenId, param: nil)
        store.markRendered(key)

        XCTAssertNotNil(store.screenEntry(id: overriddenId, param: nil)?.screen, "it still draws")
        XCTAssertNil(ContractCache().load(key), "it is not cached")
    }
}

/// A refetch that answers the bytes on show changes nothing (the server caches a screen for
/// about 5 minutes, so most 60 s refetches are this case).
@MainActor
final class IdenticalRefetchTests: XCTestCase {

    private let id = "6aa952fcc445860ea24e1bd7"

    private func screen(_ title: String) -> Data {
        Data("""
        { "id": "\(id)", "kind": "static", "blockResources": {},
          "content": { "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["t"] },
                       "t": { "type": { "resolvedName": "SimpleText" }, "props": { "text": "\(title)" }, "parent": "ROOT", "nodes": [] } } }
        """.utf8)
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

    func testAnIdenticalRefetchActivatesNothingAndWritesNothing() async {
        let config = TestConfig.staging
        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
        let key = store.key(for: id, param: nil)
        StubProtocol.queue = [.init(status: 200, body: screen("Same"))]
        await store.loadScreen(id: id, param: nil)
        store.markRendered(key)
        XCTAssertEqual(store.activations[key], 1)
        ContractCache().remove(key) // any later write would bring the file back

        StubProtocol.queue = [.init(status: 200, body: screen("Same"))]
        await store.loadScreen(id: id, param: nil)
        store.markRendered(key)

        XCTAssertEqual(store.activations[key], 1, "no activation, so no redraw")
        XCTAssertNil(ContractCache().load(key), "no cache write")
    }

    func testAChangedRefetchActivates() async {
        let config = TestConfig.staging
        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
        let key = store.key(for: id, param: nil)
        StubProtocol.queue = [.init(status: 200, body: screen("First"))]
        await store.loadScreen(id: id, param: nil)
        StubProtocol.queue = [.init(status: 200, body: screen("Second"))]
        await store.loadScreen(id: id, param: nil)

        XCTAssertEqual(store.activations[key], 2)
        XCTAssertEqual(store.screenEntry(id: id, param: nil)?.screen?.content["t"]?.props["text"].string, "Second")
    }

    /// Also after a cache paint: the same bytes as the cached copy are dropped.
    func testAnIdenticalCopyOfTheCachedPaintIsDropped() async {
        let config = TestConfig.staging
        let store = ContractStore(config: config, client: AppContractClient(config: config, session: StubProtocol.session()))
        let key = store.key(for: id, param: nil)
        ContractCache().store(screen("Cached"), for: key)
        StubProtocol.queue = [.init(status: 200, body: screen("Cached"))]
        await store.loadScreen(id: id, param: nil)

        XCTAssertNil(store.activations[key], "painted from the cache, and the fetch changed nothing")
    }
}

/// A node map is a graph. A cycle or a self-parent must not take the app down.
final class BlockGraphGuardTests: XCTestCase {

    func testATwoNodeCycleRendersAbsentWithoutACrash() throws {
        let document = try TestDocument.make("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["a"] },
          "a": { "type": { "resolvedName": "Section" }, "nodes": ["b"] },
          "b": { "type": { "resolvedName": "Container" }, "nodes": ["a"] }
        }
        """)
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: "ROOT", document: document, context: TestRender.context()))

        // Each node is drawn once on the path; the repeat is dropped.
        XCTAssertEqual(node.keyReport.rendered.sorted(), ["Container", "Root", "Section"])
        XCTAssertTrue(node.first { $0.id == "b" }?.children.isEmpty ?? false)
    }

    func testASelfParentRendersAbsentWithoutACrash() throws {
        let document = try TestDocument.make("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["a"] },
          "a": { "type": { "resolvedName": "Section" }, "nodes": ["a"] }
        }
        """)
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: "ROOT", document: document, context: TestRender.context()))

        XCTAssertEqual(node.keyReport.rendered.sorted(), ["Root", "Section"])
        XCTAssertTrue(node.first { $0.id == "a" }?.children.isEmpty ?? false)
    }

    /// A diamond is not a cycle: the same node under two parents draws under both.
    func testADiamondStillDrawsUnderBothParents() throws {
        let document = try TestDocument.make("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["a", "b"] },
          "a": { "type": { "resolvedName": "Section" }, "nodes": ["leaf"] },
          "b": { "type": { "resolvedName": "Section" }, "nodes": ["leaf"] },
          "leaf": { "type": { "resolvedName": "SimpleText" }, "props": { "text": "shared" } }
        }
        """)
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: "ROOT", document: document, context: TestRender.context()))

        XCTAssertEqual(node.children.count, 2)
        XCTAssertEqual(node.children.compactMap { $0.children.first?.id }, ["leaf", "leaf"])
    }

    func testAChainDeeperThanTheCapStops() throws {
        let depth = BlockRegistry.maxDepth + 10
        var nodes = ["\"ROOT\": { \"type\": { \"resolvedName\": \"Root\" }, \"nodes\": [\"n0\"] }"]
        for index in 0..<depth {
            let child = index == depth - 1 ? "" : "\"n\(index + 1)\""
            nodes.append("\"n\(index)\": { \"type\": { \"resolvedName\": \"Section\" }, \"nodes\": [\(child)] }")
        }
        let document = try TestDocument.make("{ \(nodes.joined(separator: ", ")) }")

        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: "ROOT", document: document, context: TestRender.context()))

        var levels = 0
        var cursor: EvaluatedNode? = node
        while let current = cursor {
            levels += 1
            cursor = current.children.first
        }
        XCTAssertEqual(levels, BlockRegistry.maxDepth)
    }
}

/// Play opens the full-screen player with the episode's own metadata.
final class PlaybackRequestTests: XCTestCase {

    func testAnOnDemandRequestKeysProgressOnTheMediaURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/episode.m3u8"))
        let metadata = PlaybackMetadata(title: "A Bear Remembers", description: nil, showName: "_Test Show", artworkURL: nil)
        let request = PlaybackRequest(url: url, metadata: metadata, isHLS: true)

        XCTAssertEqual(request.url, url)
        // The progress record stores the real title, not a fallback.
        XCTAssertEqual(request.title, "A Bear Remembers")
        XCTAssertEqual(request.metadata, metadata)
        XCTAssertEqual(request.progressId, url.absoluteString)
    }
}

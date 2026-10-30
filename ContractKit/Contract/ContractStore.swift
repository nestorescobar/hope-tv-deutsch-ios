import Foundation
import Observation

/// Where the active manifest came from. Precedence, lowest first:
/// built-in < bundled baseline < cached last-known-good < remote.
enum ContractSource: Equatable {
    case builtIn
    case bundled
    case lastKnownGood
    case remote

    var label: String {
        switch self {
        case .builtIn: return "built-in floor"
        case .bundled: return "bundled baseline"
        case .lastKnownGood: return "cached last-known-good"
        case .remote: return "remote"
        }
    }
}

enum ScreenEntry {
    case loading
    case ready(AppScreen)
    case failed(String)

    var screen: AppScreen? {
        if case let .ready(screen) = self { return screen }
        return nil
    }
}

/// The acceptance state machine.
///
/// Fetch → byte cap → origin guard → decode → design check → hold as candidate →
/// activate at a safe boundary → promote to last-known-good after it rendered.
@MainActor
@Observable
final class ContractStore {

    private(set) var manifest: AppManifest
    private(set) var manifestSource: ContractSource
    /// Set when the app cannot render at all — a manifest for another design, for example.
    private(set) var refusal: RejectionReason?
    private(set) var screens: [ContractCacheKey: ScreenEntry] = [:]
    /// Bumped on every manifest activation. `AppManifest` is not `Equatable` (its Craft trees
    /// are not), so the view observes this stamp to rebuild the navigation tree.
    private(set) var manifestGeneration = 0
    private(set) var lastFetchError: String?
    /// True while the launch fetch runs on the built-in floor, so the UI shows a spinner, not
    /// the floor's copy. A failed fetch ends it, and the floor then draws.
    private(set) var awaitingFirstManifest = false

    /// Set by the UI. A structural change never lands mid-playback; it waits.
    var isAtSafeBoundary = true {
        didSet { if isAtSafeBoundary && !oldValue { applyPendingIfPossible() } }
    }

    /// How often a remote copy activated for a key. The view keys its promote task on it, so a
    /// copy that replaces one with the same screen id is promoted too.
    private(set) var activations: [ContractCacheKey: Int] = [:]

    /// The bytes on show per key (a remote copy, or the cached one it painted from). A fetch
    /// that answers the same bytes changes nothing: no activation, no cache write, no redraw.
    /// The server caches a screen for about 5 minutes, so most refetches are this case.
    @ObservationIgnored private var bytesOnShow: [ContractCacheKey: Data] = [:]
    /// The same for the active manifest. nil on the built-in floor, which has no served bytes.
    @ObservationIgnored private var manifestBytesOnShow: Data?

    let config: ContractConfig
    let diagnostics = Diagnostics()

    /// The pages loaded after page 1, per screen and node (awe#5318). Memory only: never
    /// written to the cache, never last-known-good. A new copy of the screen clears its entry.
    private(set) var pagedLists: [ContractCacheKey: [String: PagedList]] = [:]

    private let client: AppContractClient
    private let cache = ContractCache()
    /// Monotonic, so a wall-clock change never stretches or skips the ttl. Injected by tests.
    private let now: () -> ContinuousClock.Instant
    /// The last manifest fetch that answered bytes. A failed fetch leaves it as it was.
    @ObservationIgnored private var lastManifestFetch: ContinuousClock.Instant?
    /// A manifest fetch is on the wire. The foreground refresh skips while it runs, so two
    /// answers never land out of order.
    @ObservationIgnored private var manifestFetchInFlight = false
    private var pendingManifest: (manifest: AppManifest, data: Data)?
    private var pendingScreens: [ContractCacheKey: (screen: AppScreen, data: Data)] = [:]
    /// Bytes that decoded and activated but have not rendered yet.
    private var awaitingPromotion: [ContractCacheKey: Data] = [:]

    init(config: ContractConfig, client: AppContractClient? = nil, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.config = config
        self.client = client ?? AppContractClient(config: config)
        self.now = now

        // 1. Built-in floor. Compiled in, so it always exists.
        manifest = BuiltInContract.manifest()
        manifestSource = .builtIn

        // 2. Bundled baseline, when this build ships one.
        if let data = ContractStore.bundledBaselineData(),
           let candidate = ContractStore.decodeManifest(data, diagnostics: diagnostics, origin: "bundled baseline"),
           ContractValidator.assertManifestDesign(candidate) == nil {
            manifest = candidate
            manifestSource = .bundled
            manifestBytesOnShow = data
        }

        // 3. Cached last-known-good, re-validated on every launch — design gate included, so a
        // manifest for another design cannot reach the renderer through the cache either. A
        // cached refusal is not shown: the remote copy owns the visible error state.
        let key = ContractCacheKey.manifest(config, contractVersion: manifest.contractVersion)
        if let data = cache.load(key),
           let candidate = ContractStore.decodeManifest(data, diagnostics: diagnostics, origin: "cache") {
            if let refusal = ContractValidator.assertManifestDesign(candidate) {
                diagnostics.log(.reject, "Cached manifest refused", refusal.text)
            } else {
                manifest = candidate
                manifestSource = .lastKnownGood
                manifestBytesOnShow = data
            }
        }

        // The built-in screen the built-in manifest's one tab points at.
        screens[ContractCacheKey.screen(
            config,
            contractVersion: manifest.contractVersion,
            screenId: BuiltInContract.screenId,
            param: nil
        )] = .ready(BuiltInContract.screen())

        awaitingFirstManifest = manifestSource == .builtIn
        publishChromeStrings()
        diagnostics.log(.ok, "Booted on the \(manifestSource.label)", config.appSlug)
    }

    // MARK: - Manifest

    func refreshManifest() async {
        manifestFetchInFlight = true
        defer {
            manifestFetchInFlight = false
            awaitingFirstManifest = false
        }
        switch await client.fetchManifest() {
        case let .failure(reason):
            lastFetchError = reason.text
            // Staying on the last-known-good is the correct outcome, not an error state.
            diagnostics.log(.warn, "Manifest fetch failed", "\(reason.text) — staying on the \(manifestSource.label)")

        case let .success(data):
            lastFetchError = nil
            lastManifestFetch = now()
            if data == manifestBytesOnShow {
                // The newest answer is what is on show, so an older held copy is stale too.
                pendingManifest = nil
                refusal = nil
                return
            }
            guard let candidate = ContractStore.decodeManifest(data, diagnostics: diagnostics, origin: "remote") else {
                return
            }
            if let refusal = ContractValidator.assertManifestDesign(candidate) {
                self.refusal = refusal
                diagnostics.log(.reject, "Manifest refused", refusal.text)
                return
            }
            refusal = nil
            pendingManifest = (candidate, data)
            applyPendingIfPossible()
        }
    }

    /// The foreground refresh. It skips the network while the last fetch is younger than
    /// `chrome.ttlSec` (the newest fetched copy's, held or active), or while a fetch is in
    /// flight. The launch fetch stays `refreshManifest`, unthrottled.
    func refreshManifestIfStale() async {
        guard !manifestFetchInFlight else { return }
        let ttl = (pendingManifest?.manifest ?? manifest).chromeTtlSec
        if let last = lastManifestFetch, now() - last < .seconds(ttl) {
            diagnostics.log(.info, "Manifest is fresh", "fetched less than \(ttl) s ago")
            return
        }
        await refreshManifest()
    }

    // MARK: - Screens

    func screenEntry(id: String, param: String?) -> ScreenEntry? {
        screens[key(for: id, param: param)]
    }

    func loadScreen(id: String, param: String?) async {
        let key = key(for: id, param: param)

        if screens[key] == nil, !paintFromCache(key) {
            screens[key] = .loading
        }

        switch await client.fetchScreen(id: id, param: param) {
        case let .failure(reason):
            diagnostics.log(.warn, "Screen \(id) fetch failed", reason.text)
            if screens[key]?.screen == nil {
                screens[key] = .failed(reason.text)
            }

        case let .success(data):
            if data == bytesOnShow[key] {
                // The newest answer is what is on show, so an older held copy is stale too.
                pendingScreens.removeValue(forKey: key)
                return
            }
            guard let screen = decodeScreen(data, origin: "remote") else {
                if screens[key]?.screen == nil {
                    screens[key] = .failed("the screen did not decode")
                }
                return
            }
            pendingScreens[key] = (screen, data)
            applyPendingIfPossible()
        }
    }

    private func activate(_ key: ContractCacheKey, _ pending: (screen: AppScreen, data: Data)) {
        screens[key] = .ready(pending.screen)
        // The pages belong to the copy they extended; the new copy starts again from its page 1.
        pagedLists[key] = nil
        activations[key, default: 0] += 1
        awaitingPromotion[key] = pending.data
        bytesOnShow[key] = pending.data
    }

    /// A cached copy paints at once; the remote copy replaces it when it lands, at a safe
    /// boundary (invariant 3). False: no usable cached copy.
    private func paintFromCache(_ key: ContractCacheKey) -> Bool {
        guard !DebugScreenOverride.skipsCache, let data = cache.load(key), let screen = decodeScreen(data, origin: "cache") else {
            return false
        }
        screens[key] = .ready(screen)
        bytesOnShow[key] = data
        return true
    }

    /// Tap-to-play (awe#6549): the Play request of a Template Screen, through the same request
    /// and cache as `loadScreen`. A copy in memory or in the cache answers at once, and the fetch
    /// still runs behind it, as it does when the screen opens. Otherwise it waits for the fetch.
    /// nil: no Play that this device can play, or no copy (the fetch failed or did not decode).
    func playRequest(screenId: String, param: String?) async -> PlaybackRequest? {
        let key = key(for: screenId, param: param)
        if screens[key] == nil {
            _ = paintFromCache(key)
        }
        if screens[key]?.screen != nil {
            Task { await loadScreen(id: screenId, param: param) }
        } else {
            await loadScreen(id: screenId, param: param)
        }
        guard let screen = screens[key]?.screen else { return nil }
        return BlockRegistry.playRequest(on: screen, images: images)
    }

    // MARK: - Paged lists

    /// The screen's block resources with its loaded pages merged in, for `RenderContext`. The
    /// registry reads a longer list and needs no change.
    func blockResources(for key: ContractCacheKey) -> [String: [String: JSONValue]] {
        PagedList.merge(screens[key]?.screen?.blockResources ?? [:], lists: pagedLists[key] ?? [:])
    }

    /// Loads the next page of one node. Only a node the server served `paging` for, one request
    /// per node at a time, and none once `hasMore` is false. A page append is a user-driven
    /// addition and applies at once: it is not a document swap (invariant 3 does not hold it).
    /// A failure other than a 404 (transport, decode, an answer for another node or page) logs each
    /// attempt and keeps `hasMore`, so the next call (the next last-row focus change) asks again;
    /// nothing retries in a loop. A 404 means the node cannot be paged, so it stops for good.
    func loadNextPage(key: ContractCacheKey, nodeId: String) async {
        guard let screenId = key.screenId, let screen = screens[key]?.screen else { return }
        guard var list = pagedLists[key]?[nodeId]
            ?? PagedList(paging: screen.paging[nodeId], key: screen.content[nodeId]?.key) else { return }
        guard list.hasMore, !list.inFlight, list.lastPage < ContractLimits.maxBlockPage else { return }

        let page = list.lastPage + 1
        list.inFlight = true
        pagedLists[key, default: [:]][nodeId] = list
        let generation = activations[key, default: 0]

        let result = await client.fetchBlockPage(screenId: screenId, nodeId: nodeId, param: key.param, page: page)

        // A new copy activated meanwhile: this answer extends a list that is gone.
        guard activations[key, default: 0] == generation, var current = pagedLists[key]?[nodeId] else { return }
        current.inFlight = false
        switch result {
        case .failure(.httpStatus(404)):
            current.hasMore = false
            diagnostics.log(.info, "Block \(nodeId) cannot be paged", "HTTP 404 for page \(page)")
        case let .failure(reason):
            diagnostics.log(.warn, "Block \(nodeId) page \(page) failed", reason.text)
        case let .success(data):
            do {
                let answer = try ContractDecoder.blockPage(data)
                if answer.nodeId == nodeId, answer.page == page {
                    current.append(answer, base: screen.blockResources[nodeId]?[current.listName])
                } else {
                    diagnostics.log(.reject, "Block \(nodeId) page \(page) refused",
                                    "the answer names node \(answer.nodeId), page \(answer.page)")
                }
            } catch {
                diagnostics.log(.reject, "Block \(nodeId) page \(page) refused", RejectionReason.decodeFailed("\(error)").text)
            }
        }
        pagedLists[key]?[nodeId] = current
    }

    /// One `MediaSearch` query (awe#5947). The answer is memory only: it never enters the cache
    /// and activates nothing, so invariant 3 does not hold it. A failure other than a 404 logs.
    func search(screenId: String, nodeId: String, query: String) async -> Result<Data, RejectionReason> {
        let result = await client.fetchSearch(screenId: screenId, nodeId: nodeId, query: query)
        if case let .failure(reason) = result, reason != .httpStatus(404) {
            diagnostics.log(.warn, "Search in block \(nodeId) failed", reason.text)
        }
        return result
    }

    func key(for screenId: String, param: String?) -> ContractCacheKey {
        ContractCacheKey.screen(config, contractVersion: manifest.contractVersion, screenId: screenId, param: param)
    }

    // MARK: - Activation

    private func applyPendingIfPossible() {
        // A screen that is not drawn yet is a first paint, not a swap under the viewer, so
        // the safe-boundary rule does not hold it back.
        for key in Array(pendingScreens.keys) where screens[key]?.screen == nil {
            guard let pending = pendingScreens.removeValue(forKey: key) else { continue }
            activate(key, pending)
        }

        guard isAtSafeBoundary else {
            if !pendingScreens.isEmpty || pendingManifest != nil {
                diagnostics.log(.info, "Holding a new document", "not at a safe activation boundary")
            }
            return
        }

        if let pending = pendingManifest {
            pendingManifest = nil
            manifest = pending.manifest
            manifestSource = .remote
            manifestGeneration += 1
            manifestBytesOnShow = pending.data
            publishChromeStrings()
            let key = ContractCacheKey.manifest(config, contractVersion: pending.manifest.contractVersion)
            awaitingPromotion[key] = pending.data
            diagnostics.log(.ok, "Activated the remote manifest", pending.manifest.app.name ?? config.appSlug)
        }

        for (key, pending) in pendingScreens {
            activate(key, pending)
        }
        pendingScreens.removeAll()
    }

    /// Called once a document has actually drawn. Only then is it last-known-good.
    ///
    /// Promotion is per DOCUMENT, not once per cache key: a key that was served from the cache
    /// at launch must still accept the next rendered remote copy, or the file freezes on the
    /// first version it ever held. `awaitingPromotion` holds exactly the activated-but-not-yet-
    /// drawn bytes, so one write per document falls out of clearing the entry.
    func markRendered(_ key: ContractCacheKey) {
        guard let data = awaitingPromotion.removeValue(forKey: key) else { return }
        #if DEBUG
        // A fixture (an override, or a seeded old copy under it) never outlives its run.
        if DebugScreenOverride.isOverridden(key.screenId) {
            cache.remove(key)
            return
        }
        #endif
        cache.store(data, for: key)
    }

    func markManifestRendered() {
        markRendered(ContractCacheKey.manifest(config, contractVersion: manifest.contractVersion))
    }

    func clearCache() {
        cache.clear()
        awaitingPromotion.removeAll()
        diagnostics.log(.warn, "Cache cleared", "the next launch starts from the \(ContractSource.builtIn.label)")
    }

    private var images: ImageConfig { ImageConfig(cdn: config.imagesCDN, bucket: config.imagesBucket) }

    /// The active manifest's chrome strings go to `ChromeText` with the manifest itself, so a
    /// cache-painted launch draws its language on the first frame. Observed: the chrome redraws.
    private func publishChromeStrings() {
        var strings = manifest.chromeStrings
        #if DEBUG
        strings = DebugLaunch.chromeStrings(over: strings)
        #endif
        ChromeText.served.strings = strings
    }

    #if DEBUG
    /// `-seed-screen-cache <path>`: writes a screen into last-known-good before the first load,
    /// so a run can start from an old copy. Debug builds only.
    func seedCache(_ data: Data) {
        guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"].text else { return }
        cache.store(data, for: key(for: id, param: nil))
    }
    #endif

    // MARK: - Decoding

    private func decodeScreen(_ data: Data, origin: String) -> AppScreen? {
        if let refusal = ContractValidator.checkSize(bytes: data.count) {
            diagnostics.log(.reject, "Screen from \(origin) refused", refusal.text)
            return nil
        }
        do {
            return try ContractDecoder.screen(data)
        } catch {
            // A decode failure never crashes a screen; the previous copy stays on screen.
            diagnostics.log(.reject, "Screen from \(origin) refused", RejectionReason.decodeFailed("\(error)").text)
            return nil
        }
    }

    private static func decodeManifest(_ data: Data, diagnostics: Diagnostics, origin: String) -> AppManifest? {
        if let refusal = ContractValidator.checkSize(bytes: data.count) {
            diagnostics.log(.reject, "Manifest from \(origin) refused", refusal.text)
            return nil
        }
        do {
            return try ContractDecoder.manifest(data)
        } catch {
            diagnostics.log(.reject, "Manifest from \(origin) refused", RejectionReason.decodeFailed("\(error)").text)
            return nil
        }
    }

    private static func bundledBaselineData() -> Data? {
        guard let url = Bundle.main.url(forResource: "baseline.manifest", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

}

/// The pages of one node's list loaded after page 1. Pure, apart from the store that holds it.
struct PagedList: Equatable {
    /// The resource the node reads, and the list a page answers: `shows` for `ShowList`,
    /// `episodes` for `EpisodesList`, `movies` for `MovieList`, `collection` for `Collection` (awe#5983).
    let listName: String
    var lastPage: Int
    var hasMore: Bool
    /// The items after page 1, in page order, with no record id twice.
    var extraItems: [JSONValue] = []
    /// `count` from the latest answer. nil keeps page 1's.
    var count: Int?
    var inFlight = false

    /// nil unless the server served `paging` for the node AND the node is a list this renderer
    /// draws. The type only names the list; `paging` alone decides that a node pages. The layout
    /// is not read here: the view asks only from a grid, so a `Collection` row never pages.
    init?(paging: BlockPaging?, key: BlockKey?) {
        guard let paging else { return nil }
        switch key {
        case .showList: listName = "shows"
        case .episodesList: listName = "episodes"
        case .movieList: listName = "movies"
        case .collection: listName = "collection"
        default: return nil
        }
        lastPage = paging.page
        hasMore = paging.hasMore
    }

    /// Adds one answered page. Card ids are record ids, and a repeated id in a `ForEach` is
    /// undefined behavior, so an item whose record id is already listed is dropped.
    mutating func append(_ answer: BlockPage, base: JSONValue?) {
        let list = answer.resources[listName]
        let baseItems = PagedList.itemsKey(listName, in: base).map { base?[$0].array ?? [] } ?? []
        var seen = Set(baseItems.compactMap(PagedList.recordId))
        seen.formUnion(extraItems.compactMap(PagedList.recordId))
        for item in list?["items"].array ?? [] {
            if let id = PagedList.recordId(item), !seen.insert(id).inserted { continue }
            extraItems.append(item)
        }
        if let latest = list?["count"].int { count = latest }
        lastPage = answer.page
        hasMore = answer.hasMore
    }

    /// The id a card takes (`BlockRegistry.showCard` / `episodeCard`).
    private static func recordId(_ item: JSONValue) -> String? {
        item["id"].text ?? item["_id"].text
    }

    /// Where page 1 keeps its items in the node's resource. A list keeps them in `items`, beside
    /// `count`. A `collection` keeps them in the array its `contentType` names (`shows`,
    /// `episodes` or `movies`), because page 1 serves the whole record. A `mixed` collection
    /// keeps its typed items in `items`. nil: a collection with another `contentType`; nothing
    /// merges into it.
    private static func itemsKey(_ listName: String, in resource: JSONValue?) -> String? {
        guard listName == "collection" else { return "items" }
        switch resource?["contentType"].string {
        case let type? where ["shows", "episodes", "movies"].contains(type): return type
        case "mixed": return "items"
        default: return nil
        }
    }

    /// `base` with each list's loaded items appended to page 1's items, and a list's `count`
    /// replaced by the latest one. A collection keeps its own counts: its shelf reads none.
    /// O(items) per call.
    static func merge(_ base: [String: [String: JSONValue]], lists: [String: PagedList]) -> [String: [String: JSONValue]] {
        var merged = base
        for (nodeId, list) in lists where !list.extraItems.isEmpty || list.count != nil {
            let resource = base[nodeId]?[list.listName]
            guard let itemsKey = itemsKey(list.listName, in: resource) else { continue }
            var fields = resource?.object ?? [:]
            fields[itemsKey] = .array((fields[itemsKey]?.array ?? []) + list.extraItems)
            if list.listName != "collection", let count = list.count { fields["count"] = .number(Double(count)) }
            merged[nodeId, default: [:]][list.listName] = .object(fields)
        }
        return merged
    }
}

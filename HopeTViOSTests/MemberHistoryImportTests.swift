import XCTest
@testable import HopeTViOS

/// TV sign-in slice 3 (awe#6565): the one-time import of device history after Continue.

private let episodeA = "629ecd4ce1e081635d11107e"
private let episodeB = "629ecd52e1e081635d1110a4"
private let episodeC = "629ecd58e1e081635d1110c9"

private let progressKey = "watch-progress-v2"

/// A 24-hex ObjectId made from a number.
private func objectId(_ number: Int) -> String {
    String(format: "%024x", number)
}

/// A device entry as `WatchProgressStore` saves it. `seconds` is its `updatedAt`.
private func entry(
    _ playableId: String,
    episodeId: String? = nil,
    fraction: Double = 0.4,
    duration: Double? = 1000,
    at seconds: TimeInterval,
    deviceOnly: Bool? = nil
) -> WatchProgressStore.Entry {
    WatchProgressStore.Entry(
        playableId: playableId, showId: nil, episodeId: episodeId, title: playableId, subtitle: "",
        imageURL: nil, fraction: fraction, duration: duration, updatedAt: Date(timeIntervalSince1970: seconds),
        deviceOnly: deviceOnly
    )
}

/// Writes the entries where the store reads them, then opens a store over them.
@MainActor
private func seeded(_ entries: [WatchProgressStore.Entry]) throws -> WatchProgressStore {
    let map = Dictionary(uniqueKeysWithValues: entries.map { ($0.playableId, $0) })
    UserDefaults.standard.set(try JSONEncoder().encode(map), forKey: progressKey)
    return WatchProgressStore()
}

// MARK: - The mapping and the clear

@MainActor
final class HistoryImportStoreTests: XCTestCase {

    private var saved: Data?

    override func setUp() async throws {
        saved = UserDefaults.standard.data(forKey: progressKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(saved, forKey: progressKey)
    }

    /// Position is fraction × duration; `lastAt` is the entry's `updatedAt`.
    func testAnEntryMapsToSecondsAndItsLastWatch() throws {
        let store = try seeded([entry("https://cdn.test/a.m3u8", episodeId: episodeA, fraction: 0.25, duration: 1800, at: 500)])

        let entries = store.importEntries(limit: 100)

        XCTAssertEqual(entries, [HistoryImportEntry(episodeId: episodeA, position: 450, duration: 1800,
                                                     lastAt: Date(timeIntervalSince1970: 500))])
    }

    /// No episode id, an id that is no ObjectId, no duration, or a position under the minimum
    /// resume seconds (the slice 2 report gate): skipped. A finished entry and a device-only
    /// entry are sent.
    func testItSkipsWhatTheServerCannotTake() throws {
        let store = try seeded([
            entry("no-id", at: 1),
            entry("bad-id", episodeId: "not-an-id", at: 2),
            entry("no-duration", episodeId: objectId(1), duration: nil, at: 3),
            entry("zero-duration", episodeId: objectId(2), duration: 0, at: 4),
            entry("near-start", episodeId: objectId(3), fraction: 0.009, duration: 1000, at: 5),
            entry("finished", episodeId: episodeB, fraction: 0.97, at: 6),
            entry("device-only", episodeId: episodeC, at: 7, deviceOnly: true),
        ])

        let entries = store.importEntries(limit: 100)

        XCTAssertEqual(entries.map(\.episodeId), [episodeC, episodeB])
        XCTAssertEqual(entries.last?.position ?? 0, 970, accuracy: 0.0001)
    }

    /// A number outside the server bounds (0 … 604800 s, `MAX_SECONDS`) would fail the whole
    /// batch: that entry is skipped, the rest are sent.
    func testItSkipsANumberOutsideTheServerBounds() throws {
        let store = try seeded([
            entry("long", episodeId: objectId(1), duration: 700_000, at: 1),
            entry("past-max", episodeId: objectId(2), fraction: 1.5, duration: 500_000, at: 2),
            entry("at-max", episodeId: objectId(3), fraction: 1, duration: 604_800, at: 3),
            entry("plain", episodeId: episodeA, at: 4),
        ])

        let entries = store.importEntries(limit: 100)

        XCTAssertEqual(entries.map(\.episodeId), [episodeA, objectId(3)])
    }

    /// The newest key of an episode cannot be sent (no duration, or under the minimum): an older,
    /// mappable key of the same episode is sent instead. Only a sent key claims the episode.
    func testANewestKeyThatCannotBeSentDoesNotHideAnOlderMappableKey() throws {
        let store = try seeded([
            entry("x-old", episodeId: objectId(1), fraction: 0.5, at: 1),
            entry("x-new", episodeId: objectId(1), duration: nil, at: 5),
            entry("y-old", episodeId: objectId(2), fraction: 0.3, at: 2),
            entry("y-new", episodeId: objectId(2), fraction: 0.005, at: 6),
        ])

        let entries = store.importEntries(limit: 100)

        XCTAssertEqual(entries.map(\.episodeId), [objectId(2), objectId(1)])
        XCTAssertEqual(entries.map(\.position), [300, 500])
    }

    /// Newest first, at most `limit`, one per episode (the newest mappable key).
    func testItSendsTheNewestEntriesOncePerEpisode() throws {
        var all = (0..<105).map { index in
            entry("https://cdn.test/\(index).m3u8", episodeId: objectId(index), at: TimeInterval(index))
        }
        all.append(entry("https://cdn.test/old.m3u8", episodeId: objectId(104), fraction: 0.1, at: 50))
        let store = try seeded(all)

        let entries = store.importEntries(limit: 100)

        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(entries.first?.episodeId, objectId(104))
        XCTAssertEqual(entries.first?.position, 400, "the newest key of the episode is sent")
        XCTAssertEqual(entries.last?.episodeId, objectId(5))
        XCTAssertEqual(entries.map(\.lastAt), entries.map(\.lastAt).sorted(by: >))
    }

    /// After a 2xx: everything goes except the refused episodes. Each of their keys stays,
    /// marked device-only, and the result is persisted.
    func testFinishKeepsOnlyTheRefusedEpisodesAsDeviceOnly() throws {
        let store = try seeded([
            entry("https://cdn.test/a.m3u8", episodeId: episodeA, at: 1),
            entry("https://cdn.test/a-hd.m3u8", episodeId: episodeA, at: 2),
            entry("https://cdn.test/b.m3u8", episodeId: episodeB, at: 3),
            entry("https://cdn.test/no-id.m3u8", at: 4),
        ])

        store.finishImport(refused: [episodeA], snapshot: store.savedAt)

        let reopened = WatchProgressStore()
        let kept = reopened.resumable(limit: .max)
        XCTAssertEqual(Set(kept.map(\.playableId)), ["https://cdn.test/a.m3u8", "https://cdn.test/a-hd.m3u8"])
        XCTAssertTrue(kept.allSatisfy { $0.deviceOnly == true })
    }

    /// A device movie entry (awe#6270: `movieId`, no `episodeId`) imports as an episode does,
    /// with `itemType: movie`. An episode with the same id is a separate item, so both are sent.
    func testTheImportSendsAMovieEntryAsAMovie() throws {
        let movieId = objectId(42)
        var movie = entry("https://cdn.test/movie.m3u8", fraction: 0.25, duration: 6720, at: 3)
        movie.movieId = movieId
        let store = try seeded([
            movie,
            entry("https://cdn.test/same-id.m3u8", episodeId: movieId, at: 2),
            entry("https://cdn.test/a.m3u8", episodeId: episodeA, at: 1),
        ])

        let entries = store.importEntries(limit: 100)

        XCTAssertEqual(entries.map(\.itemType), [.movie, .episode, .episode])
        XCTAssertEqual(entries.map(\.episodeId), [movieId, movieId, episodeA], "`episodeId` carries the movie id too")
        XCTAssertEqual(entries.first?.position, 1680)
        XCTAssertEqual(entries.first?.duration, 6720)
    }

    /// After a 2xx a movie follows the episode rule: an accepted movie goes; a refused movie stays,
    /// marked device-only, so it shows beside the server copy.
    func testTheClearKeepsARefusedMovieAsDeviceOnly() throws {
        let refusedId = objectId(42)
        let acceptedId = objectId(43)
        var refused = entry("https://cdn.test/refused.m3u8", at: 2)
        refused.movieId = refusedId
        var accepted = entry("https://cdn.test/accepted.m3u8", at: 3)
        accepted.movieId = acceptedId
        let store = try seeded([refused, accepted, entry("https://cdn.test/a.m3u8", episodeId: episodeA, at: 1)])

        store.finishImport(refused: [refusedId], snapshot: store.savedAt)

        let kept = WatchProgressStore().resumable(limit: .max)
        XCTAssertEqual(kept.map(\.playableId), ["https://cdn.test/refused.m3u8"], "persisted")
        XCTAssertEqual(kept.first?.deviceOnly, true)
        XCTAssertEqual(WatchHistorySource(local: kept, server: [:]).entries.compactMap(\.movieId), [refusedId],
                       "it shows on Keep watching while signed in")
    }

    /// The clear reads the snapshot taken when the import started, not the clock: an entry added
    /// or changed after it stays as it is, even with an `updatedAt` older than the snapshot's (a
    /// clock step back) or in the future.
    func testFinishKeepsAnEntryAddedOrChangedAfterTheSnapshot() throws {
        let store = try seeded([
            entry("https://cdn.test/a.m3u8", episodeId: episodeA, at: 100),
            entry("https://cdn.test/b.m3u8", episodeId: episodeB, at: 4_000_000_000),
            entry("https://cdn.test/gone.m3u8", episodeId: episodeC, at: 50),
        ])
        let snapshot = store.savedAt
        // The store after a play while the call ran: a new key, and a changed key whose clock
        // stepped back.
        let changed = try seeded([
            entry("https://cdn.test/a.m3u8", episodeId: episodeA, fraction: 0.6, at: 10),
            entry("https://cdn.test/b.m3u8", episodeId: episodeB, at: 4_000_000_000),
            entry("https://cdn.test/gone.m3u8", episodeId: episodeC, at: 50),
            entry("https://cdn.test/c.m3u8", episodeId: objectId(9), at: 60),
        ])

        changed.finishImport(refused: [], snapshot: snapshot)

        let kept = changed.resumable(limit: .max)
        XCTAssertEqual(Set(kept.map(\.playableId)), ["https://cdn.test/a.m3u8", "https://cdn.test/c.m3u8"],
                       "the changed and the new key stay; the unchanged ones go, the future-dated one too")
        XCTAssertTrue(kept.allSatisfy { $0.deviceOnly == nil }, "a kept plain entry stays plain")
    }
}

// MARK: - The import, once per sign-in

@MainActor
final class HistoryImportTests: XCTestCase {

    private let session = MemberSession(token: "tok", expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana")
    private var saved: Data?
    private var service: FakeMemberService!
    private var store: MemorySessionStore!
    private var account: MemberAccount!
    private var progress: WatchProgressStore!

    override func setUp() async throws {
        saved = UserDefaults.standard.data(forKey: progressKey)
        service = FakeMemberService()
        store = MemorySessionStore()
        store.stored = session
        account = MemberAccount(service: service, store: store, now: { Date(timeIntervalSince1970: 1_000_000) })
        progress = try seeded([
            entry("https://cdn.test/a.m3u8", episodeId: episodeA, at: 1),
            entry("https://cdn.test/b.m3u8", episodeId: episodeB, fraction: 0.5, at: 2),
        ])
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(saved, forKey: progressKey)
    }

    private var deviceIds: Set<String> {
        Set(progress.resumable(limit: .max).map(\.playableId))
    }

    func testItSendsTheMappedEntriesThenClearsTheDeviceCopy() async {
        await account.importDeviceHistory(from: progress)

        XCTAssertEqual(service.imports.map(\.token), ["tok"])
        XCTAssertEqual(service.imports.first?.entries.map(\.episodeId), [episodeB, episodeA])
        XCTAssertEqual(service.imports.first?.entries.first?.position, 500)
        XCTAssertTrue(deviceIds.isEmpty)
        XCTAssertEqual(account.session, session)
    }

    /// Ruled 2026-10-13 (option B): a refused episode stays on the device, marked device-only, so
    /// it shows beside the server copy.
    func testARefusedEpisodeStaysOnTheDeviceAsDeviceOnly() async {
        service.importResult = .success([episodeA])

        await account.importDeviceHistory(from: progress)

        XCTAssertEqual(deviceIds, ["https://cdn.test/a.m3u8"])
        XCTAssertEqual(progress.resumable(limit: 1).first?.deviceOnly, true)
        let shelf = WatchHistorySource(progress: progress, account: account)
        XCTAssertEqual(shelf.entries.map(\.episodeId), [episodeA], "it shows signed in")
    }

    /// A 5xx, a 422 or a transport failure: the device copy stays untouched, the session stays.
    func testAFailureLeavesTheDeviceCopy() async {
        service.importResult = .failure(.rejected(.httpStatus(503)))

        await account.importDeviceHistory(from: progress)

        XCTAssertEqual(service.imports.count, 1)
        XCTAssertEqual(deviceIds, ["https://cdn.test/a.m3u8", "https://cdn.test/b.m3u8"])
        XCTAssertNil(progress.resumable(limit: .max).first(where: { $0.deviceOnly == true }))
        XCTAssertEqual(account.session, session)
    }

    /// 401: the slice 2 local sign-out (no DELETE). The device copy stays.
    func testA401SignsOutAndLeavesTheDeviceCopy() async {
        service.importResult = .failure(.signedOut)

        await account.importDeviceHistory(from: progress)

        XCTAssertNil(account.session)
        XCTAssertNil(store.stored)
        XCTAssertTrue(service.signedOutTokens.isEmpty)
        XCTAssertEqual(deviceIds, ["https://cdn.test/a.m3u8", "https://cdn.test/b.m3u8"])
    }

    /// Nothing maps: no call, and nothing is cleared.
    func testNoMappableEntrySendsNothingAndClearsNothing() async throws {
        progress = try seeded([entry("https://cdn.test/no-id.m3u8", at: 1)])

        await account.importDeviceHistory(from: progress)

        XCTAssertTrue(service.imports.isEmpty)
        XCTAssertEqual(deviceIds, ["https://cdn.test/no-id.m3u8"])
    }

    func testSignedOutNothingIsSent() async {
        await account.signOut()

        await account.importDeviceHistory(from: progress)

        XCTAssertTrue(service.imports.isEmpty)
        XCTAssertEqual(deviceIds.count, 2)
    }

    /// A second Continue while the import runs, or after it, sends nothing.
    func testItRunsOncePerSignIn() async {
        service.holdsImport = true
        let first = Task { await account.importDeviceHistory(from: progress) }
        while !service.isHoldingImport { await Task.yield() }

        await account.importDeviceHistory(from: progress)
        service.releaseImport()
        await first.value
        await account.importDeviceHistory(from: progress)

        XCTAssertEqual(service.imports.count, 1)
    }

    /// No retry after a failure until the next sign-in.
    func testAFailedImportIsNotRetriedUntilTheNextSignIn() async {
        service.importResult = .failure(.rejected(.transport("offline")))
        await account.importDeviceHistory(from: progress)
        await account.importDeviceHistory(from: progress)
        XCTAssertEqual(service.imports.count, 1)

        await account.signOut()
        account.signedIn(MemberSession(token: "tok-2", expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana"))
        service.importResult = .success([])
        await account.importDeviceHistory(from: progress)

        XCTAssertEqual(service.imports.map(\.token), ["tok", "tok-2"])
        XCTAssertTrue(deviceIds.isEmpty)
    }

    /// The answer lands after a sign-out: it belongs to no one on this TV now. Nothing is cleared.
    func testAnAnswerAfterSignOutIsDropped() async {
        service.holdsImport = true
        let run = Task { await account.importDeviceHistory(from: progress) }
        while !service.isHoldingImport { await Task.yield() }

        await account.signOut()
        service.releaseImport()
        await run.value

        XCTAssertEqual(deviceIds.count, 2)
    }

    /// A play that saves while the import runs keeps its entry.
    func testAnEntrySavedDuringTheImportStays() async {
        service.holdsImport = true
        let run = Task { await account.importDeviceHistory(from: progress) }
        while !service.isHoldingImport { await Task.yield() }

        progress.record(0.3, for: "https://cdn.test/c.m3u8", title: "C", episodeId: episodeC, duration: 1000)
        progress.record(0.7, for: "https://cdn.test/a.m3u8", title: "A", episodeId: episodeA, duration: 1000)
        service.releaseImport()
        await run.value

        XCTAssertEqual(deviceIds, ["https://cdn.test/a.m3u8", "https://cdn.test/c.m3u8"],
                       "a new key and a key that changed during the call stay; the unchanged one goes")
        XCTAssertEqual(progress.fraction(for: "https://cdn.test/a.m3u8"), 0.7)
    }

    // MARK: The confirm screen (decision 17)

    /// Back from the confirm screen closes it signed in: no import, the server copy loads.
    func testClosingWithoutContinueImportsNothing() async {
        await account.signInCoverClosed(continued: false, progress: progress)

        XCTAssertTrue(service.imports.isEmpty)
        XCTAssertEqual(service.historyTokens, ["tok"])
        XCTAssertEqual(deviceIds.count, 2)
    }

    /// Continue: the import runs first, then the server copy loads, so it holds the imported rows.
    func testContinueImportsThenLoadsTheServerCopy() async {
        service.holdsImport = true
        let closed = Task { await account.signInCoverClosed(continued: true, progress: progress) }
        while !service.isHoldingImport { await Task.yield() }

        XCTAssertTrue(service.historyTokens.isEmpty, "the server copy waits for the import")
        service.releaseImport()
        await closed.value

        XCTAssertEqual(service.imports.count, 1)
        XCTAssertEqual(service.historyTokens, ["tok"])
    }

    /// Sign out from the confirm screen: the cover closes signed out, so nothing is sent.
    func testSignOutFromTheConfirmScreenImportsNothing() async {
        await account.signOut()

        await account.signInCoverClosed(continued: true, progress: progress)

        XCTAssertTrue(service.imports.isEmpty)
        XCTAssertTrue(service.historyTokens.isEmpty)
    }
}

// MARK: - The route on the wire

final class HistoryImportWiringTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    override func tearDown() {
        StubProtocol.reset()
        super.tearDown()
    }

    private var client: MemberClient {
        MemberClient(contract: AppContractClient(config: TestConfig.staging, session: StubProtocol.session()))
    }

    private let sent = [
        HistoryImportEntry(episodeId: episodeA, position: 734.2, duration: 1800,
                           lastAt: ISO8601DateFormatter().date(from: "2026-10-12T19:04:11Z")!),
    ]

    func testItPostsTheEntriesWithTheSessionHeader() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"imported":0,"skipped":1,"refused":["\#(episodeA)"]}"#.utf8))]

        let refused = try await client.importHistory(token: "tok", entries: sent).get()

        XCTAssertEqual(refused, [episodeA])
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/watch-history/import")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session"), "tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ClientToken"), "test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AWE-App-Contract"), "1")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.data(of: request)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["entries"])
        let item = try XCTUnwrap((body["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["episodeId", "position", "duration", "lastAt"])
        XCTAssertEqual(item["episodeId"] as? String, episodeA)
        XCTAssertEqual(item["position"] as? Double, 734.2)
        XCTAssertEqual(item["duration"] as? Double, 1800)
        XCTAssertEqual(item["lastAt"] as? String, "2026-10-12T19:04:11.000Z")
    }

    /// A movie entry adds `itemType: "movie"`; an episode still sends no `itemType`.
    func testAMovieEntrySendsItsItemType() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"imported":2,"skipped":0,"refused":[]}"#.utf8))]
        let lastAt = ISO8601DateFormatter().date(from: "2026-10-12T19:04:11Z")!

        _ = try await client.importHistory(token: "tok", entries: [
            HistoryImportEntry(itemType: .movie, episodeId: episodeB, position: 1680, duration: 6720, lastAt: lastAt),
            HistoryImportEntry(episodeId: episodeA, position: 734.2, duration: 1800, lastAt: lastAt),
        ]).get()

        let request = try XCTUnwrap(StubProtocol.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.data(of: request)) as? [String: Any])
        let items = try XCTUnwrap(body["entries"] as? [[String: Any]])
        XCTAssertEqual(items.first?["itemType"] as? String, "movie")
        XCTAssertEqual(items.first?["episodeId"] as? String, episodeB)
        XCTAssertEqual(items.first?["position"] as? Double, 1680)
        XCTAssertNil(items.last?["itemType"], "the episode body is as before movies")
    }

    func testA401IsSignedOut() async {
        StubProtocol.queue = [.init(status: 401, body: Data(#"{"code":"UNAUTHORIZED"}"#.utf8))]

        let result = await client.importHistory(token: "tok", entries: sent)

        guard case .failure(.signedOut) = result else { return XCTFail("expected signed out, got \(result)") }
    }

    /// Without `refused` the TV cannot tell which entries to keep, so it clears nothing.
    func testAnAnswerWithoutRefusedIsAFailure() async {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"imported":1,"skipped":0}"#.utf8))]

        let result = await client.importHistory(token: "tok", entries: sent)

        guard case .failure(.decodeFailed) = result else { return XCTFail("expected a decode failure, got \(result)") }
    }

    func testA422IsAFailure() async {
        StubProtocol.queue = [.init(status: 422, body: Data(#"{"code":"VALIDATION_ERROR"}"#.utf8))]

        let result = await client.importHistory(token: "tok", entries: sent)

        guard case .failure(.rejected) = result else { return XCTFail("expected a rejection, got \(result)") }
    }

    private static func data(of request: URLRequest) -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return data
    }
}

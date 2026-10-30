// cspell:ignore hopetv
import XCTest
@testable import HopeTViOS

/// TV sign-in slice 2 (awe#6564): server resume, Keep watching and progress reports.

private let episodeA = "629ecd4ce1e081635d11107e"
private let episodeB = "629ecd52e1e081635d1110a4"
private let episodeC = "629ecd58e1e081635d1110c9"

private func entry(
    _ playableId: String,
    episodeId: String? = nil,
    fraction: Double = 0.4,
    at seconds: TimeInterval,
    deviceOnly: Bool? = nil
) -> WatchProgressStore.Entry {
    WatchProgressStore.Entry(
        playableId: playableId, showId: nil, episodeId: episodeId, title: playableId, subtitle: "",
        imageURL: nil, fraction: fraction, duration: 1000, updatedAt: Date(timeIntervalSince1970: seconds),
        deviceOnly: deviceOnly
    )
}

private func request(episodeId: String?, url: String = "https://cdn.test/a.m3u8", recordsProgress: Bool = true) -> PlaybackRequest {
    PlaybackRequest(
        url: URL(string: url)!,
        metadata: PlaybackMetadata(title: "Lesson 1", description: nil, showName: "Hope Sabbath School",
                                   artworkURL: URL(string: "https://images.test/a.jpg"), episodeId: episodeId),
        recordsProgress: recordsProgress,
        isHLS: true
    )
}

private let movieId = "6a1f0c2bd9c698836400aa01"

/// A movie play: `movieId`, no episode id and no show (awe#6270).
private func movieRequest(url: String = "https://cdn.test/movie.m3u8") -> PlaybackRequest {
    PlaybackRequest(
        url: URL(string: url)!,
        metadata: PlaybackMetadata(title: "The Chosen Path", description: nil, showName: nil,
                                   artworkURL: URL(string: "https://images.test/m.jpg"), movieId: movieId),
        isHLS: true
    )
}

// MARK: - The source switch

final class WatchHistorySourceTests: XCTestCase {

    /// Signed out: the device-local store, every entry, as before slice 2.
    func testSignedOutTheShelfReadsTheLocalStore() {
        let local = [entry("https://cdn.test/b.m3u8", at: 20), entry("https://cdn.test/a.m3u8", episodeId: episodeA, at: 10)]

        let source = WatchHistorySource(local: local, server: nil)

        XCTAssertEqual(source.entries.map(\.playableId), ["https://cdn.test/b.m3u8", "https://cdn.test/a.m3u8"])
        XCTAssertNil(source.memberResumePoints)
    }

    /// Signed in: the server copy wins. A device entry from before sign-in does not show.
    func testSignedInTheShelfReadsTheServerCopy() {
        let local = [entry("https://cdn.test/a.m3u8", episodeId: episodeA, at: 50)]
        let server = [WatchHistoryItem.episode(episodeB): entry(episodeB, episodeId: episodeB, at: 10)]

        let source = WatchHistorySource(local: local, server: server)

        XCTAssertEqual(source.entries.map(\.playableId), [episodeB])
    }

    /// Signed in before the first load answers: an empty server copy, not the device store.
    func testSignedInWithNothingLoadedTheShelfIsEmpty() {
        let source = WatchHistorySource(local: [entry("https://cdn.test/a.m3u8", episodeId: episodeA, at: 50)], server: [:])

        XCTAssertTrue(source.entries.isEmpty)
    }

    /// Device-only entries (`recorded: false`) join the server items, deduped by episode id with
    /// the server copy winning, newest first.
    func testDeviceOnlyEntriesMergeWithTheServerCopy() {
        let local = [
            entry("https://cdn.test/a.m3u8", episodeId: episodeA, fraction: 0.2, at: 90, deviceOnly: true),
            entry("https://cdn.test/c.m3u8", episodeId: episodeC, at: 30, deviceOnly: true),
        ]
        let server = [
            WatchHistoryItem.episode(episodeA): entry(episodeA, episodeId: episodeA, fraction: 0.6, at: 10),
            .episode(episodeB): entry(episodeB, episodeId: episodeB, at: 40),
        ]

        let source = WatchHistorySource(local: local, server: server)

        XCTAssertEqual(source.entries.map(\.playableId), [episodeB, "https://cdn.test/c.m3u8", episodeA])
        XCTAssertEqual(source.entries.last?.fraction, 0.6, "the server copy wins for the same episode")
    }

    func testTheShelfKeepsTheLimit() {
        let server = Dictionary(uniqueKeysWithValues: (0..<20).map { index in
            let id = String(format: "%024d", index)
            return (WatchHistoryItem.episode(id), entry(id, episodeId: id, at: TimeInterval(index)))
        })

        XCTAssertEqual(WatchHistorySource(local: [], server: server, limit: 12).entries.count, 12)
    }

    /// Signed in, resume is keyed by episode id; a device entry under the same URL is not read.
    func testSignedInResumeIsKeyedByEpisodeId() {
        let local = [entry("https://cdn.test/a.m3u8", episodeId: episodeA, fraction: 0.8, at: 50)]
        let server = [WatchHistoryItem.episode(episodeA): entry(episodeA, episodeId: episodeA, fraction: 0.3, at: 10)]

        let source = WatchHistorySource(local: local, server: server)

        XCTAssertEqual(source.resumeFraction(for: request(episodeId: episodeA)), 0.3)
        XCTAssertNil(source.resumeFraction(for: request(episodeId: episodeB)), "no server item, no resume")
    }

    /// A movie item keys apart from an episode with the same id: both show, and each request
    /// resumes from its own item.
    func testSignedInAMovieIsItsOwnItem() {
        var movie = entry("movie:\(movieId)", fraction: 0.6, at: 20)
        movie.movieId = movieId
        let server = [
            WatchHistoryItem.movie(movieId): movie,
            .episode(movieId): entry(movieId, episodeId: movieId, fraction: 0.3, at: 10),
        ]

        let source = WatchHistorySource(local: [], server: server)

        XCTAssertEqual(source.entries.map(\.playableId), ["movie:\(movieId)", movieId])
        XCTAssertEqual(source.resumeFraction(for: movieRequest()), 0.6)
        XCTAssertEqual(source.resumeFraction(for: request(episodeId: movieId)), 0.3)
    }

    func testSignedInADeviceOnlyEntryResumes() {
        let local = [entry("https://cdn.test/a.m3u8", episodeId: episodeA, fraction: 0.5, at: 50, deviceOnly: true)]

        XCTAssertEqual(WatchHistorySource(local: local, server: [:]).resumeFraction(for: request(episodeId: episodeA)), 0.5)
    }

    /// A play with no episode id stays device-local, signed in or out.
    func testAPlayWithNoEpisodeIdReadsTheDeviceStore() {
        let local = [entry("https://cdn.test/a.m3u8", fraction: 0.5, at: 50)]

        XCTAssertEqual(WatchHistorySource(local: local, server: [:]).resumeFraction(for: request(episodeId: nil)), 0.5)
        XCTAssertEqual(WatchHistorySource(local: local, server: nil).resumeFraction(for: request(episodeId: nil)), 0.5)
    }

    /// Signed out: by media URL, as before.
    func testSignedOutResumeIsKeyedByURL() {
        let local = [entry("https://cdn.test/a.m3u8", episodeId: episodeA, fraction: 0.5, at: 50)]
        let source = WatchHistorySource(local: local, server: nil)

        XCTAssertEqual(source.resumeFraction(for: request(episodeId: episodeA)), 0.5)
        XCTAssertNil(source.resumeFraction(for: request(episodeId: episodeA, recordsProgress: false)), "a trailer never resumes")
    }

    /// The Play button reads the same rule: "Resume" for a server item, "Play" for none.
    func testThePlayLabelReadsTheServerCopy() throws {
        let data = try Fixtures.data("episode")
        let screen = try ContractDecoder.screen(data)
        func label(server: [WatchHistoryItem: WatchProgressStore.Entry]?) throws -> String? {
            let source = WatchHistorySource(local: [], server: server)
            let node = try XCTUnwrap(BlockRegistry.evaluate(
                nodeId: CraftDocument.rootId,
                document: screen.content,
                context: RenderContext(
                    blockResources: screen.blockResources, screenResources: screen.resources,
                    images: ImageConfig(cdn: "https://images.test", bucket: "bucket"),
                    watchHistory: source.entries, resumePoints: source.resumePoints,
                    memberResumePoints: source.memberResumePoints
                )
            ))
            let play = node.first { if case .playAction = $0.content { return true }; return false }
            guard case let .playAction(model)? = play?.content else { return nil }
            return model.label
        }
        ChromeText.served.strings = [:]

        XCTAssertEqual(try label(server: [.episode(episodeA): entry(episodeA, episodeId: episodeA, at: 1)]), "Resume")
        XCTAssertEqual(try label(server: [:]), "Play")
        XCTAssertEqual(try label(server: nil), "Play")
    }
}

// MARK: - The device store

@MainActor
final class DeviceOnlyEntryTests: XCTestCase {

    private let key = "watch-progress-v2"
    private var saved: Data?

    override func setUp() async throws {
        saved = UserDefaults.standard.data(forKey: key)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(saved, forKey: key)
    }

    /// Data saved before slice 2 has no `deviceOnly` field and still decodes.
    func testAnEntrySavedBeforeSlice2StillDecodes() throws {
        let saved = #"{ "https://cdn.test/a.m3u8": { "playableId": "https://cdn.test/a.m3u8", "episodeId": "\#(episodeA)", "title": "T", "subtitle": "", "fraction": 0.5, "duration": 1000, "updatedAt": 0 } }"#
        UserDefaults.standard.set(Data(saved.utf8), forKey: key)

        let store = WatchProgressStore()

        XCTAssertEqual(store.resumable(limit: 5).count, 1)
        XCTAssertNil(store.resumable(limit: 5).first?.deviceOnly)
    }

    func testADeviceOnlyWriteIsMarkedAndPersisted() {
        let store = WatchProgressStore()
        store.clear()

        store.record(0.4, for: "https://cdn.test/a.m3u8", title: "A", episodeId: episodeA, deviceOnly: true)

        XCTAssertEqual(WatchProgressStore().resumable(limit: 1).first?.deviceOnly, true)
    }
}

// MARK: - Member routes on the wire

final class MemberHistoryWiringTests: XCTestCase {

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

    /// The narrowed wire shape: `{ _id, itemType, position, duration, updatedAt, episode? | movie? }`.
    static let historyBody = Data(#"""
    {"items":[
      {"_id":"h1","itemType":"episode","position":600,"duration":3540,"updatedAt":"2026-10-12T10:00:00.000Z",
       "episode":{"_id":"629ecd4ce1e081635d11107e","title":"Lesson 1",
         "image":{"containerId":"602bd46f36432128d40d5e81","name":"IXU1656302401390.jpg"},"duration":3540,
         "show":{"_id":"61975e37d9c698836400309f","title":"Hope Sabbath School","image":null}}},
      {"_id":"h2","itemType":"movie","position":60,"duration":5000,"updatedAt":"2026-10-12T11:00:00.000Z",
       "movie":{"_id":"m1","title":"A movie","images":null,"duration":5000}},
      {"_id":"h3","itemType":"episode","position":120,"duration":null,"updatedAt":"2026-10-11T10:00:00Z",
       "episode":{"_id":"629ecd52e1e081635d1110a4","title":"Lesson 2","duration":1200,"show":null}},
      {"_id":"h4","itemType":"episode","position":120,"duration":null,"updatedAt":"2026-10-11T10:00:00Z",
       "episode":{"_id":"not-an-id","title":"Bad"}},
      {"_id":"h5","itemType":"episode","position":120,"duration":null,"updatedAt":"2026-10-11T10:00:00Z",
       "episode":{"_id":"629ecd58e1e081635d1110c9","title":"No duration","duration":0}}
    ]}
    """#.utf8)

    /// GET with the session header. Only items with an ObjectId and a duration map; the others are
    /// skipped, never a whole-list failure. Here `m1` (no ObjectId, not because it is a movie),
    /// `not-an-id` and the item with no duration drop, so only the two episodes stay.
    func testHistoryReadsEpisodeItems() async throws {
        StubProtocol.queue = [.init(status: 200, body: Self.historyBody)]

        let entries = try await client.watchHistory(token: "tok").get()

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/watch-history")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session"), "tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ClientToken"), "test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AWE-App-Contract"), "1")

        XCTAssertEqual(entries.map(\.episodeId), [episodeA, episodeB])
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.playableId, episodeA)
        XCTAssertEqual(first.title, "Lesson 1")
        XCTAssertEqual(first.subtitle, "Hope Sabbath School")
        XCTAssertEqual(first.showId, "61975e37d9c698836400309f")
        XCTAssertEqual(first.fraction, 600.0 / 3540.0, accuracy: 0.0001)
        XCTAssertEqual(first.duration, 3540)
        XCTAssertEqual(first.updatedAt, ISO8601DateFormatter().date(from: "2026-10-12T10:00:00Z"))
        XCTAssertEqual(first.imageURL?.host, "images.test")
        XCTAssertEqual(entries.last?.fraction ?? 0, 0.1, accuracy: 0.0001, "the episode duration stands in for a null one")
    }

    /// An episode with no image of its own draws its show's image.
    func testAnEpisodeWithNoImageUsesTheShowImage() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"""
        {"items":[{"_id":"h1","itemType":"episode","position":600,"duration":3540,"updatedAt":"2026-10-12T10:00:00.000Z",
         "episode":{"_id":"629ecd4ce1e081635d11107e","title":"Lesson 1","image":null,"duration":3540,
           "show":{"_id":"61975e37d9c698836400309f","title":"Hope Sabbath School",
             "image":{"containerId":"602bd46f36432128d40d5e81","name":"show-art.jpg"}}}}]}
        """#.utf8))]

        let entries = try await client.watchHistory(token: "tok").get()

        let url = try XCTUnwrap(entries.first?.imageURL)
        XCTAssertEqual(url, ImageConfig(cdn: "https://images.test", bucket: "bucket")
            .url(ImageFile(.object(["containerId": .string("602bd46f36432128d40d5e81"), "name": .string("show-art.jpg")])), width: 640))
    }

    func testA401IsSignedOut() async {
        StubProtocol.queue = [.init(status: 401, body: Data(#"{"code":"UNAUTHORIZED"}"#.utf8))]

        let result = await client.watchHistory(token: "tok")

        guard case .failure(.signedOut) = result else { return XCTFail("expected signed out, got \(result)") }
    }

    func testReportPutsPositionAndDuration() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"recorded":true}"#.utf8)),
                              .init(status: 200, body: Data(#"{"recorded":false}"#.utf8))]

        let recorded = try await client.reportProgress(token: "tok", item: .episode(episodeA),
                                                       report: ProgressReport(position: 612.5, duration: 3540, ended: false)).get()
        let ended = try await client.reportProgress(token: "tok", item: .episode(episodeA),
                                                    report: ProgressReport(position: 3540, duration: nil, ended: true)).get()

        XCTAssertTrue(recorded)
        XCTAssertFalse(ended)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/watch-history/episode/\(episodeA)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session"), "tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try body(of: request), ["position": 612.5, "duration": 3540])
        let second = try body(of: StubProtocol.requests[1])
        XCTAssertEqual(second["ended"] as? Bool, true)
        XCTAssertTrue(second["duration"] is NSNull, "an unknown duration is sent as null")
    }

    /// A movie report goes to `watch-history/movie/<id>`, with the same body as an episode's.
    func testAMovieReportPutsToTheMoviePath() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"recorded":true}"#.utf8))]

        let recorded = try await client.reportProgress(token: "tok", item: .movie(movieId),
                                                       report: ProgressReport(position: 1680, duration: 6720, ended: false)).get()

        XCTAssertTrue(recorded)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/watch-history/movie/\(movieId)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session"), "tok")
        XCTAssertEqual(try body(of: request), ["position": 1680, "duration": 6720])
    }

    /// A movie item (`movie { _id, title, images, duration }`) maps to a shelf entry with its
    /// `movieId`, its `images` art and no show. A null item duration reads the movie's.
    func testHistoryMapsAMovieItem() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"""
        {"items":[{"_id":"h1","itemType":"movie","position":1680,"duration":null,"updatedAt":"2026-10-12T11:00:00.000Z",
         "movie":{"_id":"\#(movieId)","title":"The Chosen Path","duration":6720,
           "images":{"default":{"containerId":"c1","name":"movie.jpg"}}}}]}
        """#.utf8))]

        let entries = try await client.watchHistory(token: "tok").get()

        let movie = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(movie.historyItem, .movie(movieId))
        XCTAssertNil(movie.episodeId)
        XCTAssertNil(movie.showId)
        XCTAssertEqual(movie.playableId, "movie:\(movieId)")
        XCTAssertEqual(movie.title, "The Chosen Path")
        XCTAssertEqual(movie.subtitle, "")
        XCTAssertEqual(movie.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(movie.duration, 6720)
        XCTAssertEqual(movie.imageURL?.absoluteString.hasSuffix("/c1/movie.jpg"), true)
        XCTAssertEqual(movie.updatedAt, ISO8601DateFormatter().date(from: "2026-10-12T11:00:00Z"))
    }

    /// An id that is not an ObjectId never reaches the URL path.
    func testAReportForABadIdIsNotSent() async {
        let result = await client.reportProgress(token: "tok", item: .episode("../session"), report: ProgressReport(position: 1, duration: 2, ended: false))

        guard case .failure = result else { return XCTFail("expected a refusal") }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testSettingsReadsTheHint() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"watchHistoryHint":{"site":"app.hopetv.de"}}"#.utf8)),
                              .init(status: 200, body: Data(#"{"watchHistoryHint":null}"#.utf8))]

        let hint = try await client.settings(token: "tok").get()
        let none = try await client.settings(token: "tok").get()

        XCTAssertEqual(hint, "app.hopetv.de")
        XCTAssertNil(none)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/settings")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session"), "tok")
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
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
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private func XCTAssertEqual(_ actual: [String: Any], _ expected: [String: Double], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Set(actual.keys), Set(expected.keys), file: file, line: line)
    for (key, value) in expected {
        XCTAssertEqual(actual[key] as? Double, value, key, file: file, line: line)
    }
}

// MARK: - The account's server copy

@MainActor
final class MemberServerCopyTests: XCTestCase {

    private let session = MemberSession(token: "tok", expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana")
    private var service: FakeMemberService!
    private var store: MemorySessionStore!

    override func setUp() async throws {
        service = FakeMemberService()
        store = MemorySessionStore()
        store.stored = session
    }

    private func account() -> MemberAccount {
        MemberAccount(service: service, store: store, now: { Date(timeIntervalSince1970: 1_000_000) })
    }

    func testLoadFillsTheServerCopyByEpisodeId() async {
        service.history = .success([entry(episodeA, episodeId: episodeA, at: 1)])
        let account = account()

        await account.loadHistory()

        XCTAssertEqual(service.historyTokens, ["tok"])
        XCTAssertEqual(Array(account.history.keys), [.episode(episodeA)])
    }

    /// An episode and a movie can share an id: the copy keeps both.
    func testLoadKeepsAMovieApartFromAnEpisode() async {
        var movie = entry("movie:\(episodeA)", at: 2)
        movie.movieId = episodeA
        service.history = .success([entry(episodeA, episodeId: episodeA, at: 1), movie])
        let account = account()

        await account.loadHistory()

        XCTAssertEqual(Set(account.history.keys), [.episode(episodeA), .movie(episodeA)])
    }

    func testSignedOutNothingLoads() async {
        store.stored = nil
        let account = account()

        await account.loadHistory()
        await account.loadSettings()

        XCTAssertTrue(service.historyTokens.isEmpty)
        XCTAssertTrue(service.settingsTokens.isEmpty)
    }

    /// A 5xx or a transport failure keeps the session and the copy.
    func testAFailedLoadKeepsTheSession() async {
        service.history = .success([entry(episodeA, episodeId: episodeA, at: 1)])
        let account = account()
        await account.loadHistory()
        service.history = .failure(.rejected(.httpStatus(503)))

        await account.loadHistory()

        XCTAssertEqual(account.session, session)
        XCTAssertEqual(Array(account.history.keys), [.episode(episodeA)])
    }

    /// 401: the session is gone on the server. Sign out locally (no DELETE), clear the copy.
    func testA401SignsOutLocallyAndClearsTheCopy() async {
        service.history = .success([entry(episodeA, episodeId: episodeA, at: 1)])
        let account = account()
        await account.loadHistory()
        service.history = .failure(.signedOut)

        await account.loadHistory()

        XCTAssertNil(account.session)
        XCTAssertNil(store.stored, "the Keychain item is deleted")
        XCTAssertTrue(account.history.isEmpty)
        XCTAssertTrue(service.signedOutTokens.isEmpty, "no DELETE for a session the server already dropped")
    }

    func testA401OnSettingsSignsOut() async {
        service.settingsResult = .failure(.signedOut)
        let account = account()

        await account.loadSettings()

        XCTAssertNil(account.session)
        XCTAssertNil(store.stored)
    }

    func testSignOutClearsTheCopyAndTheHint() async {
        service.history = .success([entry(episodeA, episodeId: episodeA, at: 1)])
        service.settingsResult = .success("app.hopetv.de")
        let account = account()
        await account.loadHistory()
        await account.loadSettings()

        await account.signOut()

        XCTAssertTrue(account.history.isEmpty)
        XCTAssertNil(account.watchHistoryHint)
    }

    /// An answer that lands after sign-out does not refill the copy.
    func testALateLoadAfterSignOutIsDropped() async {
        service.history = .success([entry(episodeA, episodeId: episodeA, at: 1)])
        service.holdsHistory = true
        let account = account()
        let load = Task { await account.loadHistory() }
        while !service.isHoldingHistory { await Task.yield() }

        await account.signOut()
        service.releaseHistory()
        await load.value

        XCTAssertTrue(account.history.isEmpty)
    }

    func testTheHintIsPresentOrAbsent() async {
        service.settingsResult = .success("app.hopetv.de")
        let account = account()

        await account.loadSettings()
        XCTAssertEqual(account.watchHistoryHint, "app.hopetv.de")

        service.settingsResult = .success(nil)
        await account.loadSettings()
        XCTAssertNil(account.watchHistoryHint)
    }

    func testTheHintLineFillsTheSite() {
        ChromeText.served.strings = [:]
        XCTAssertEqual(ChromeText.string(.watchHistoryHint, ["site": "app.hopetv.de"]), "Turn on watch history at app.hopetv.de")
    }

    // MARK: Report answers after a session change (F3b)

    private func pendingReport(_ account: MemberAccount) async -> Task<MemberAccount.ReportOutcome, Never> {
        service.holdsReport = true
        let token = account.session?.token
        let report = Task { await account.report(entry(episodeA, episodeId: episodeA, at: 1),
                                                 report: ProgressReport(position: 600, duration: 3540, ended: false), token: token) }
        while !service.isHoldingReport { await Task.yield() }
        return report
    }

    /// No session when the report was queued: the caller writes it as signed out.
    func testAReportQueuedWithNoSessionIsNoSession() async {
        store.stored = nil
        let outcome = await account().report(entry(episodeA, episodeId: episodeA, at: 1),
                                             report: ProgressReport(position: 600, duration: 3540, ended: false), token: nil)

        XCTAssertEqual(outcome, .noSession)
        XCTAssertTrue(service.reports.isEmpty)
    }

    /// R1: queued with a session that ended before it ran: dropped, never a signed-out write.
    func testAReportQueuedWithASessionThatEndedBeforeItRanIsDropped() async {
        let account = account()
        let token = account.session?.token
        await account.signOut()

        let outcome = await account.report(entry(episodeA, episodeId: episodeA, at: 1),
                                           report: ProgressReport(position: 600, duration: 3540, ended: false), token: token)

        XCTAssertEqual(outcome, .dropped)
        XCTAssertTrue(service.reports.isEmpty, "nothing is sent for a session that is gone")
    }

    /// Signed out while the report ran: its answer is dropped, never a signed-out device write.
    func testASignOutDuringAReportDropsIt() async {
        let account = account()
        let report = await pendingReport(account)

        await account.signOut()
        service.releaseReport()

        let outcome = await report.value
        XCTAssertEqual(outcome, .dropped)
        XCTAssertTrue(account.history.isEmpty)
    }

    /// Another member signed in while the report ran: the answer is not theirs.
    func testAnotherMemberSigningInDuringAReportDropsIt() async {
        let account = account()
        let report = await pendingReport(account)

        account.signedIn(MemberSession(token: "other", expires: Date(timeIntervalSince1970: 2_000_000), name: "Ben"))
        service.releaseReport()

        let outcome = await report.value
        XCTAssertEqual(outcome, .dropped)
        XCTAssertTrue(account.history.isEmpty, "Ana's progress never enters Ben's copy")
    }

    /// A 401 on a report signs out on this TV, and that report is dropped.
    func testA401OnAReportSignsOutAndDropsIt() async {
        service.reportResults = [.failure(.signedOut)]
        let account = account()

        let outcome = await account.report(entry(episodeA, episodeId: episodeA, at: 1),
                                           report: ProgressReport(position: 600, duration: 3540, ended: false),
                                           token: account.session?.token)

        XCTAssertEqual(outcome, .dropped)
        XCTAssertNil(account.session)
        XCTAssertNil(store.stored)
    }

    #if DEBUG
    /// `-member-session`: the fake session never touches the session store, so the 401 that
    /// follows its fake token deletes no real Keychain item.
    func testADebugSessionNeverTouchesTheRealStore() async {
        let account = account()
        account.debugSignIn(name: "Debug")
        service.history = .failure(.signedOut)

        await account.loadHistory()

        XCTAssertNil(account.session, "the 401 still signs out")
        XCTAssertEqual(store.stored, session, "the real item stays")
        XCTAssertEqual(store.deletes, 0)
    }

    /// A UI test that answers the poll from a file (`-sign-in-poll-override-file`) never writes
    /// the real Keychain: the launch uses a memory store. Without the arg, the real store.
    func testAPollOverrideKeepsTheLaunchOffTheRealStore() throws {
        let key = "sign-in-poll-override-file"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let real = MemorySessionStore()

        UserDefaults.standard.set("/nonexistent/poll.json", forKey: key)
        let debug = DebugMemberSignIn.sessionStore(real: real)
        try debug.save(session)
        debug.delete()
        XCTAssertNil(real.stored)
        XCTAssertEqual(real.deletes, 0)

        UserDefaults.standard.removeObject(forKey: key)
        try DebugMemberSignIn.sessionStore(real: real).save(session)
        XCTAssertEqual(real.stored, session)
    }
    #endif
}

// MARK: - Progress reports

@MainActor
final class MemberProgressReporterTests: XCTestCase {

    private let session = MemberSession(token: "tok", expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana")
    private let key = "watch-progress-v2"
    private var saved: Data?
    private var service: FakeMemberService!
    private var store: MemorySessionStore!
    private var account: MemberAccount!
    private var progress: WatchProgressStore!
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        saved = UserDefaults.standard.data(forKey: key)
        service = FakeMemberService()
        store = MemorySessionStore()
        store.stored = session
        account = MemberAccount(service: service, store: store, now: { Date(timeIntervalSince1970: 1_000_000) })
        progress = WatchProgressStore()
        progress.clear()
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(saved, forKey: key)
    }

    private func reporter(_ request: PlaybackRequest = request(episodeId: episodeA)) -> MemberProgressReporter? {
        MemberProgressReporter(request: request, account: account, progress: progress, now: { [unowned self] in now })
    }

    func testNoReporterSignedOutOrWithoutAnEpisodeId() {
        XCTAssertNil(reporter(request(episodeId: nil)))
        XCTAssertNil(reporter(request(episodeId: "not-an-id")))
        XCTAssertNil(reporter(request(episodeId: episodeA, recordsProgress: false)))
        store.stored = nil
        account = MemberAccount(service: service, store: store)
        XCTAssertNil(reporter())
    }

    /// A movie play reports by the episode rules, to the movie item: the throttle, pause and the
    /// end. `recorded: true` keeps it in the server copy until the end removes it.
    func testAMoviePlayReportsByTheSameRules() async throws {
        let reporter = try XCTUnwrap(reporter(movieRequest()))

        for second in 1...15 {
            now = Date(timeIntervalSince1970: 1_000_000 + TimeInterval(second))
            await reporter.tick(position: TimeInterval(second), duration: 6720)?.value
        }
        await reporter.paused(position: 1680, duration: 6720)?.value

        XCTAssertEqual(service.reports.map(\.item), [.movie(movieId), .movie(movieId)])
        XCTAssertEqual(service.reports.map(\.report.position), [10, 1680])
        let copy = try XCTUnwrap(account.history[.movie(movieId)])
        XCTAssertEqual(copy.movieId, movieId)
        XCTAssertNil(copy.episodeId)
        XCTAssertEqual(copy.playableId, "movie:\(movieId)")
        XCTAssertEqual(copy.fraction, 0.25, accuracy: 0.0001)
        XCTAssertTrue(progress.resumable(limit: 5).isEmpty, "nothing on the device")

        await reporter.ended(duration: 6720)?.value
        await reporter.exited(position: 6720, duration: 6720)?.value

        XCTAssertEqual(service.reports.map(\.report.ended), [false, false, true], "no exit report after the end")
        XCTAssertNil(account.history[.movie(movieId)], "the finished movie leaves the copy")
    }

    /// `recorded: false` keeps a movie on the device, marked device-only, with its `movieId`. A
    /// later `recorded: true` deletes that device-only entry.
    func testAMovieNotRecordedStaysOnTheDeviceUntilRecorded() async throws {
        service.reportResults = [.success(false), .success(true)]
        let reporter = try XCTUnwrap(reporter(movieRequest()))

        await reporter.paused(position: 1680, duration: 6720)?.value

        let local = try XCTUnwrap(progress.resumable(limit: 5).first)
        XCTAssertEqual(local.playableId, "https://cdn.test/movie.m3u8")
        XCTAssertEqual(local.movieId, movieId)
        XCTAssertNil(local.episodeId)
        XCTAssertEqual(local.deviceOnly, true)

        await reporter.paused(position: 2000, duration: 6720)?.value

        XCTAssertTrue(progress.resumable(limit: 5).isEmpty, "the server copy holds it now")
        XCTAssertNotNil(account.history[.movie(movieId)])
    }

    /// At most one report every 10 s while playing; the first one 10 s after the start.
    func testTicksAreThrottledToTenSeconds() async throws {
        let reporter = try XCTUnwrap(reporter())

        for second in 1...25 {
            now = Date(timeIntervalSince1970: 1_000_000 + TimeInterval(second))
            await reporter.tick(position: TimeInterval(second), duration: 3540)?.value
        }

        XCTAssertEqual(service.reports.map(\.report.position), [10, 20])
        XCTAssertEqual(service.reports.first?.item, .episode(episodeA))
        XCTAssertEqual(service.reports.first?.token, "tok")
    }

    /// Pause, exit and end always report, whatever the throttle says. After the end, exit sends nothing.
    func testPauseExitAndEndAlwaysReport() async throws {
        let reporter = try XCTUnwrap(reporter())

        await reporter.paused(position: 30, duration: 3540)?.value
        await reporter.paused(position: 40, duration: 3540)?.value
        await reporter.ended(duration: 3540)?.value
        await reporter.exited(position: 3540, duration: 3540)?.value

        XCTAssertEqual(service.reports.map(\.report), [
            ProgressReport(position: 30, duration: 3540, ended: false),
            ProgressReport(position: 40, duration: 3540, ended: false),
            ProgressReport(position: 3540, duration: 3540, ended: true),
        ])
    }

    /// L1: Back while it buffers sends nothing below `minResumeSeconds`, so no 0% row appears.
    func testAPauseOrExitNearTheStartSendsNothing() async throws {
        let reporter = try XCTUnwrap(reporter())

        XCTAssertNil(reporter.paused(position: 0, duration: 3540))
        XCTAssertNil(reporter.exited(position: 9.5, duration: 3540))

        XCTAssertTrue(service.reports.isEmpty)
        XCTAssertTrue(progress.resumable(limit: 5).isEmpty)
    }

    /// Once a report went out, a later short position still reports (a scrub back to the start).
    func testAfterAReportAShortPositionStillReports() async throws {
        let reporter = try XCTUnwrap(reporter())
        now = Date(timeIntervalSince1970: 1_000_010)
        await reporter.tick(position: 10, duration: 3540)?.value

        await reporter.exited(position: 2, duration: 3540)?.value

        XCTAssertEqual(service.reports.map(\.report.position), [10, 2])
    }

    func testTheEndAlwaysReports() async throws {
        let reporter = try XCTUnwrap(reporter())

        await reporter.ended(duration: 5)?.value

        XCTAssertEqual(service.reports.map(\.report), [ProgressReport(position: 5, duration: 5, ended: true)])
    }

    /// F3a: reports go out one at a time, in order. A tick still in flight when the end comes
    /// cannot land after it and put the finished episode back in the copy.
    func testAReportInFlightBeforeTheEndCannotPutTheItemBack() async throws {
        let reporter = try XCTUnwrap(reporter())
        service.holdsReport = true
        now = Date(timeIntervalSince1970: 1_000_010)
        let tick = reporter.tick(position: 3186, duration: 3540)
        while !service.isHoldingReport { await Task.yield() }

        let end = reporter.ended(duration: 3540)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(service.reports.count, 1, "the end waits for the tick")

        service.releaseReport()
        await tick?.value
        await end?.value

        XCTAssertEqual(service.reports.map(\.report.ended), [false, true])
        XCTAssertNil(account.history[.episode(episodeA)], "the finished episode stays out of the copy")
    }

    /// F2 (ruled 2026-10-13, option 1): `recorded: true` deletes the episode's device-only
    /// entries, under the request URL or under any other key with the same episode id. A plain
    /// device entry stays. After the end, the episode is on no shelf and Play shows no Resume.
    func testRecordedRemovesTheDeviceOnlyEntryAndTheEndClearsTheShelf() async throws {
        progress.record(0.3, for: "https://cdn.test/a.m3u8", title: "Lesson 1", episodeId: episodeA, deviceOnly: true)
        progress.record(0.3, for: "https://cdn.test/old.m3u8", title: "Lesson 1", episodeId: episodeA, deviceOnly: true)
        progress.record(0.5, for: "https://cdn.test/plain.m3u8", title: "Lesson 1", episodeId: episodeA)
        progress.record(0.4, for: "https://cdn.test/b.m3u8", title: "Lesson 2", episodeId: episodeB, deviceOnly: true)
        service.reportResults = [.success(true), .success(true)]
        let reporter = try XCTUnwrap(reporter())

        await reporter.paused(position: 708, duration: 3540)?.value

        XCTAssertEqual(Set(progress.resumable(limit: 5).map(\.playableId)),
                       ["https://cdn.test/plain.m3u8", "https://cdn.test/b.m3u8"], "only E's device-only entries go")

        await reporter.ended(duration: 3540)?.value

        let source = WatchHistorySource(local: progress.resumable(limit: .max), server: account.history)
        XCTAssertFalse(source.entries.contains { $0.episodeId == episodeA }, "E is on no shelf")
        XCTAssertNil(source.resumeFraction(for: request(episodeId: episodeA)), "Play shows no Resume")
    }

    /// F3b: an exit report in flight when the member signs out writes nothing to the device.
    func testAnExitInFlightDuringSignOutWritesNothing() async throws {
        let reporter = try XCTUnwrap(reporter())
        service.holdsReport = true
        let exit = reporter.exited(position: 708, duration: 3540)
        while !service.isHoldingReport { await Task.yield() }

        await account.signOut()
        service.releaseReport()
        await exit?.value

        XCTAssertTrue(progress.resumable(limit: 5).isEmpty, "this member's progress is not a signed-out entry")
    }

    /// R1: an exit queued behind a slow report reads the session it was queued under. The member
    /// signs out while it waits: it is dropped, not written to the device as signed out.
    func testAnExitQueuedBehindASlowReportDuringSignOutWritesNothing() async throws {
        let reporter = try XCTUnwrap(reporter())
        service.holdsReport = true
        now = Date(timeIntervalSince1970: 1_000_010)
        let tick = reporter.tick(position: 600, duration: 3540)
        while !service.isHoldingReport { await Task.yield() }
        let exit = reporter.exited(position: 708, duration: 3540)

        await account.signOut()
        service.releaseReport()
        await tick?.value
        await exit?.value

        XCTAssertEqual(service.reports.count, 1, "no call for a session that is gone")
        XCTAssertTrue(progress.resumable(limit: 5).isEmpty, "this member's progress is not a signed-out entry")
    }

    /// R3: buffering 8 s then playing 2 s must not make a 2 s row. The periodic report waits
    /// until the position reaches the minimum; after that the gate stays open.
    func testATickBelowTheMinimumWaitsForThePosition() async throws {
        let reporter = try XCTUnwrap(reporter())

        now = Date(timeIntervalSince1970: 1_000_010)
        XCTAssertNil(reporter.tick(position: 2, duration: 3540))
        now = Date(timeIntervalSince1970: 1_000_011)
        XCTAssertNil(reporter.tick(position: 9.9, duration: 3540))
        now = Date(timeIntervalSince1970: 1_000_012)
        await reporter.tick(position: 10, duration: 3540)?.value
        await reporter.exited(position: 3, duration: 3540)?.value

        XCTAssertEqual(service.reports.map(\.report.position), [10, 3])
    }

    func testExitReportsOnce() async throws {
        let reporter = try XCTUnwrap(reporter())

        await reporter.exited(position: 30, duration: 3540)?.value
        await reporter.exited(position: 30, duration: 3540)?.value

        XCTAssertEqual(service.reports.count, 1)
    }

    /// `recorded: true` updates the server copy and writes nothing to the device store.
    func testRecordedUpdatesTheServerCopyOnly() async throws {
        service.reportResults = [.success(true)]
        let reporter = try XCTUnwrap(reporter())

        await reporter.paused(position: 708, duration: 3540)?.value

        let item = try XCTUnwrap(account.history[.episode(episodeA)])
        XCTAssertEqual(item.fraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(item.title, "Lesson 1")
        XCTAssertEqual(item.subtitle, "Hope Sabbath School")
        XCTAssertEqual(item.updatedAt, now)
        XCTAssertTrue(progress.resumable(limit: 5).isEmpty)
        XCTAssertEqual(WatchHistorySource(local: progress.resumable(limit: .max), server: account.history)
            .resumeFraction(for: request(episodeId: episodeA)) ?? 0, 0.2, accuracy: 0.0001)
    }

    /// The end removes the item from the server copy: it is finished.
    func testEndedRemovesTheItemFromTheServerCopy() async throws {
        service.reportResults = [.success(true), .success(true)]
        let reporter = try XCTUnwrap(reporter())
        await reporter.paused(position: 708, duration: 3540)?.value

        await reporter.ended(duration: 3540)?.value

        XCTAssertNil(account.history[.episode(episodeA)])
    }

    /// `recorded: false` keeps the item device-local, marked device-only.
    func testNotRecordedWritesADeviceOnlyEntry() async throws {
        service.reportResults = [.success(false)]
        let reporter = try XCTUnwrap(reporter())

        await reporter.paused(position: 708, duration: 3540)?.value

        let local = try XCTUnwrap(progress.resumable(limit: 5).first)
        XCTAssertEqual(local.playableId, "https://cdn.test/a.m3u8")
        XCTAssertEqual(local.episodeId, episodeA)
        XCTAssertEqual(local.deviceOnly, true)
        XCTAssertEqual(local.fraction, 0.2, accuracy: 0.0001)
        XCTAssertTrue(account.history.isEmpty)
        XCTAssertEqual(WatchHistorySource(local: progress.resumable(limit: .max), server: account.history).entries.map(\.playableId),
                       ["https://cdn.test/a.m3u8"], "the device-only entry shows while signed in")
    }

    /// A failed report is dropped: no retry, no device write, the session stays.
    func testAFailedReportIsDropped() async throws {
        service.reportResults = [.failure(.rejected(.httpStatus(503))), .success(true)]
        let reporter = try XCTUnwrap(reporter())

        await reporter.paused(position: 100, duration: 3540)?.value
        XCTAssertEqual(service.reports.count, 1, "no retry")
        XCTAssertTrue(progress.resumable(limit: 5).isEmpty)
        XCTAssertTrue(account.history.isEmpty)
        XCTAssertNotNil(account.session)

        await reporter.paused(position: 200, duration: 3540)?.value
        XCTAssertEqual(account.history[.episode(episodeA)]?.fraction ?? 0, 200.0 / 3540.0, accuracy: 0.0001, "the next one replaces it")
    }

    /// 401 on a report signs out locally; later progress goes to the device store, as signed out.
    func testA401SignsOutAndLaterProgressStaysOnTheDevice() async throws {
        service.reportResults = [.failure(.signedOut)]
        let reporter = try XCTUnwrap(reporter())

        await reporter.paused(position: 100, duration: 3540)?.value
        XCTAssertNil(account.session)
        XCTAssertNil(store.stored)
        XCTAssertTrue(progress.resumable(limit: 5).isEmpty, "the 401 report itself is dropped")

        await reporter.exited(position: 708, duration: 3540)?.value
        XCTAssertEqual(service.reports.count, 1, "no member call without a session")
        let local = try XCTUnwrap(progress.resumable(limit: 5).first)
        XCTAssertEqual(local.fraction, 0.2, accuracy: 0.0001)
        XCTAssertNil(local.deviceOnly, "a signed-out write is a plain device entry")
    }
}

// MARK: - Keep watching, signed in, with a movie

@MainActor
final class MemberKeepWatchingMovieTests: XCTestCase {

    override func setUp() async throws {
        StubProtocol.reset()
    }

    override func tearDown() async throws {
        StubProtocol.reset()
    }

    /// A movie in the served history shows on Keep watching. The card is built by
    /// `BlockRegistry.evaluate` and opens the `movie` Template Screen by the card convention.
    func testAServedMovieShowsAndOpensTheMovieTemplate() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"""
        {"items":[{"_id":"h1","itemType":"movie","position":1680,"duration":6720,"updatedAt":"2026-10-12T11:00:00.000Z",
         "movie":{"_id":"\#(movieId)","title":"The Chosen Path","images":null,"duration":6720}}]}
        """#.utf8))]
        let sessions = MemorySessionStore()
        sessions.stored = MemberSession(token: "tok", expires: Date().addingTimeInterval(3600), name: "Ana")
        let client = MemberClient(contract: AppContractClient(config: TestConfig.staging, session: StubProtocol.session()))
        let account = MemberAccount(service: client, store: sessions)
        await account.loadHistory()
        let source = WatchHistorySource(local: [], server: account.history)

        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "home", "kind": "static",
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["history"] },
            "history": { "type": { "resolvedName": "EpisodeWatchHistory" }, "props": {}, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(watchHistory: source.entries)))
        guard case let .shelf(model)? = node.first(where: { $0.id == "history" })?.content else {
            return XCTFail("EpisodeWatchHistory drew nothing")
        }
        let card = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertEqual(card.title, "The Chosen Path")
        XCTAssertEqual(card.progress ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(card.target, CardTarget(resourceType: "movie", itemId: movieId))

        let router = AppRouter(tree: NavigationTree(manifest: try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1,
          "app": { "design": "tv" },
          "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [{ "id": "home", "kind": "static" },
                      { "id": "episode-tpl", "kind": "template", "resourceType": "episode" },
                      { "id": "movie-tpl", "kind": "template", "resourceType": "movie" }],
          "preset": {}
        }
        """.utf8))), diagnostics: Diagnostics())
        _ = router.select(card.target)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "movie-tpl", param: movieId)])
    }
}

// MARK: - Decision 9: no member data in the response cache

@MainActor
final class MemberDataCacheTests: XCTestCase {

    override func setUp() async throws {
        StubProtocol.reset()
    }

    override func tearDown() async throws {
        StubProtocol.reset()
    }

    /// Every member call runs through the real client, and the `ContractCache` folder is the same
    /// before and after: no file added or changed, and no file holds the token or a member title.
    func testMemberAnswersNeverReachTheContractCache() async throws {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app-contract", isDirectory: true)
        _ = ContractCache()
        let before = try snapshot(folder)

        StubProtocol.queue = [
            .init(status: 200, body: MemberHistoryWiringTests.historyBody),
            .init(status: 200, body: Data(#"{"watchHistoryHint":{"site":"app.hopetv.de"}}"#.utf8)),
            .init(status: 200, body: Data(#"{"recorded":true}"#.utf8)),
        ]
        let sessions = MemorySessionStore()
        let token = "member-token-\(UUID().uuidString)"
        sessions.stored = MemberSession(token: token, expires: Date().addingTimeInterval(3600), name: "Ana")
        let client = MemberClient(contract: AppContractClient(config: TestConfig.staging, session: StubProtocol.session()))
        let account = MemberAccount(service: client, store: sessions)

        await account.loadHistory()
        await account.loadSettings()
        let outcome = await account.report(
            entry(episodeA, episodeId: episodeA, at: 1), report: ProgressReport(position: 600, duration: 3540, ended: false),
            token: token
        )

        XCTAssertEqual(outcome, .recorded)
        XCTAssertEqual(account.history.count, 2, "the calls ran")
        XCTAssertEqual(account.watchHistoryHint, "app.hopetv.de")
        let after = try snapshot(folder)
        XCTAssertEqual(after.keys.sorted(), before.keys.sorted(), "no cache file added")
        XCTAssertEqual(after, before, "no cache file changed")
        for data in after.values {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(token))
            XCTAssertFalse(text.contains("watchHistoryHint"))
        }
    }

    private func snapshot(_ folder: URL) throws -> [String: Data] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Dictionary(uniqueKeysWithValues: try files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}

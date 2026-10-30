// cspell:ignore BCDF GHJK BCDFGHJK
import Security
import XCTest
@testable import HopeTViOS

// TV member sign-in, slice 1 (awe#6563): the Manifest flag, the Account tab, the member
// routes on the wire, the Keychain item, the poll loop and sign-out.

// MARK: - Manifest flag

final class MemberSignInFlagTests: XCTestCase {

    private func manifest(_ extra: String) throws -> AppManifest {
        try ContractDecoder.manifest(Data("""
        {"contractVersion": 1, "app": {}, "layouts": [], "screens": []\(extra)}
        """.utf8))
    }

    func testTheFlagIsReadFromMemberSignInEnabled() throws {
        XCTAssertTrue(try manifest(#", "memberSignIn": {"enabled": true}"#).memberSignIn)
        XCTAssertFalse(try manifest(#", "memberSignIn": {"enabled": false}"#).memberSignIn)
    }

    /// The flag is a hint. A missing or malformed value reads as off and never fails the decode.
    func testAMissingOrMalformedFlagReadsAsOff() throws {
        for extra in ["", #", "memberSignIn": null"#, #", "memberSignIn": true"#, #", "memberSignIn": {}"#,
                      #", "memberSignIn": {"enabled": "yes"}"#, #", "memberSignIn": ["x"]"#] {
            XCTAssertFalse(try manifest(extra).memberSignIn, extra)
        }
    }

    func testTheFixtureManifestHasNoFlag() throws {
        XCTAssertFalse(try ContractDecoder.manifest(Fixtures.data("manifest")).memberSignIn)
    }
}

// MARK: - Account tab

@MainActor
final class AccountTabTests: XCTestCase {

    private func tree(flag: Bool?, entry: String? = nil) throws -> NavigationTree {
        let flagJSON = flag.map { #", "memberSignIn": {"enabled": \#($0)}"# } ?? ""
        return NavigationTree(manifest: try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1, "app": {},
          "entryScreenId": \(entry.map { "\"\($0)\"" } ?? "null"),
          "defaultLayoutId": "l1",
          "layouts": [
            { "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "s1", "label": "Home" }] } }
          ],
          "screens": [{ "id": "s1", "kind": "static" }, { "id": "bare", "kind": "static" }]
          \(flagJSON)
        }
        """.utf8)))
    }

    func testTheRootTabBarGetsAccountWhenTheFlagIsOn() throws {
        XCTAssertTrue(try tree(flag: true).showsAccountTab)
        XCTAssertFalse(try tree(flag: false).showsAccountTab)
        XCTAssertFalse(try tree(flag: nil).showsAccountTab)
    }

    /// Ruling 1: an App with no tab layout (a bare Entry Screen) gets no Account in slice 1.
    func testABareEntryScreenGetsNoAccount() throws {
        let bare = try tree(flag: true, entry: "bare")

        guard case .screen = bare.initialRoute else { return XCTFail("expected the bare entry route") }
        XCTAssertFalse(bare.showsAccountTab)
    }

    /// The Account tab is never a Screen id, so it can never fetch a screen.
    func testTheAccountTagIsNoScreenId() {
        XCTAssertFalse(ContractValidator.isObjectId(AccountTab.tag))
    }

    /// A new manifest keeps the viewer on Account while it still carries the flag.
    func testANewManifestKeepsTheAccountTabWhileTheFlagIsOn() throws {
        let state = NavigationState(tabScreenId: AccountTab.tag)

        XCTAssertTrue(try tree(flag: true).keeps(state))
        XCTAssertFalse(try tree(flag: false).keeps(state))
    }
}

// MARK: - Member routes on the wire

final class MemberClientWiringTests: XCTestCase {

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

    private let grantBody = Data(#"""
    {"pollingSecret":"s3cr3t","signInCode":"BCDF-GHJK","verificationUri":"https://hope.test/activate",
     "verificationUriComplete":"https://hope.test/activate#code=BCDFGHJK","expiresIn":600,"interval":5}
    """#.utf8)

    func testStartPostsAnEmptyObjectWithTheThreeHeaders() async throws {
        StubProtocol.queue = [.init(status: 200, body: grantBody)]

        let grant = try await client.startSignIn().get()

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/sign-in")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ClientToken"), "test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AWE-App-Contract"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AWE-Entity"), "602bd46f36432128d40d5e81")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try body(of: request), [:])

        XCTAssertEqual(grant.pollingSecret, "s3cr3t")
        XCTAssertEqual(grant.signInCode, "BCDF-GHJK")
        XCTAssertEqual(grant.verificationURI.absoluteString, "https://hope.test/activate")
        XCTAssertEqual(grant.verificationURIComplete.absoluteString, "https://hope.test/activate#code=BCDFGHJK")
        XCTAssertEqual(grant.expiresIn, 600)
        XCTAssertEqual(grant.interval, 5)
    }

    /// A QR that sends a phone to plain http (or anywhere not https) is never drawn.
    func testAGrantWithANonHttpsUriIsRefused() async {
        let body = String(decoding: grantBody, as: UTF8.self).replacingOccurrences(of: "https://hope.test/activate#", with: "http://hope.test/activate#")
        StubProtocol.queue = [.init(status: 200, body: Data(body.utf8))]

        let result = await client.startSignIn()

        guard case .failure(.decodeFailed) = result else { return XCTFail("expected a decode refusal, got \(result)") }
    }

    /// 404 is the one "sign-in is off" answer (no App Site, no auth, no user-login flag).
    func testA404IsSignInUnavailable() async {
        StubProtocol.queue = [.init(status: 404, body: Data(#"{"code":"NOT_FOUND"}"#.utf8))]

        let result = await client.startSignIn()

        guard case .failure(.unavailable) = result else { return XCTFail("expected unavailable, got \(result)") }
    }

    func testA429IsRateLimited() async {
        StubProtocol.queue = [.init(status: 429, headers: ["Retry-After": "30"])]

        let result = await client.poll(secret: "s3cr3t")

        guard case .failure(.rateLimited) = result else { return XCTFail("expected rate limited, got \(result)") }
    }

    /// The polling secret travels in the JSON body, never in the URL.
    func testPollSendsTheSecretInTheBody() async throws {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"status":"pending"}"#.utf8))]

        let outcome = try await client.poll(secret: "s3cr3t").get()

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/sign-in/poll")
        XCTAssertFalse(request.url?.absoluteString.contains("s3cr3t") ?? true)
        XCTAssertEqual(try body(of: request), ["pollingSecret": "s3cr3t"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "ClientToken"), "test-token")
        XCTAssertEqual(outcome, .pending)
    }

    func testPollDecodesEveryOutcome() async throws {
        StubProtocol.queue = [
            .init(status: 200, body: Data(#"{"status":"slow_down"}"#.utf8)),
            .init(status: 200, body: Data(#"{"status":"expired"}"#.utf8)),
            .init(status: 200, body: Data(#"{"status":"approved","sessionToken":"tok","expires":"2026-10-25T12:00:00.000Z","member":{"name":"Ana"}}"#.utf8)),
            .init(status: 200, body: Data(#"{"status":"approved","sessionToken":"tok","expires":"2026-10-25T12:00:00Z","member":{}}"#.utf8)),
            .init(status: 200, body: Data(#"{"status":"teleported"}"#.utf8)),
        ]

        let slowDown = try await client.poll(secret: "s").get()
        let expired = try await client.poll(secret: "s").get()
        let approved = try await client.poll(secret: "s").get()
        let noName = try await client.poll(secret: "s").get()
        let unknown = try await client.poll(secret: "s").get()

        XCTAssertEqual(slowDown, .slowDown)
        XCTAssertEqual(expired, .expired)
        let expires = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z"))
        XCTAssertEqual(approved, .approved(MemberSession(token: "tok", expires: expires, name: "Ana")))
        XCTAssertEqual(noName, .approved(MemberSession(token: "tok", expires: expires, name: "")))
        XCTAssertEqual(unknown, .unsupported)
    }

    /// An approved answer without a token is no session.
    func testAnApprovedAnswerWithoutATokenIsRefused() async {
        StubProtocol.queue = [.init(status: 200, body: Data(#"{"status":"approved","expires":"2026-10-25T12:00:00Z","member":{"name":"Ana"}}"#.utf8))]

        let result = await client.poll(secret: "s")

        guard case .failure(.decodeFailed) = result else { return XCTFail("expected a decode refusal, got \(result)") }
    }

    func testSignOutDeletesWithTheSessionHeader() async throws {
        StubProtocol.queue = [.init(status: 204)]

        let result = await client.signOut(token: "tok")

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/app/hope-tv/member/session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "session"), "tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ClientToken"), "test-token")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
    }

    /// The same origin guard as the contract routes: a session token never trusts another host.
    func testAnAnswerFromAnotherOriginIsRefused() async {
        StubProtocol.queue = [.init(
            status: 200,
            url: URL(string: "https://evil.test/v1/app/hope-tv/member/sign-in/poll"),
            body: Data(#"{"status":"approved","sessionToken":"tok","expires":"2026-10-25T12:00:00Z","member":{"name":"Ana"}}"#.utf8)
        )]

        let result = await client.poll(secret: "s")

        guard case .failure(.rejected(.wrongOrigin("https://evil.test"))) = result else {
            return XCTFail("expected an origin refusal, got \(result)")
        }
    }

    /// A redirect is refused, not followed: the session header never reaches a second host.
    func testARedirectIsNotFollowed() async {
        RedirectStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        let client = MemberClient(contract: AppContractClient(config: TestConfig.staging, session: URLSession(configuration: configuration)))

        let result = await client.signOut(token: "tok")

        guard case .failure(.rejected(.redirected)) = result else { return XCTFail("expected a refused redirect, got \(result)") }
        XCTAssertEqual(RedirectStub.hosts, ["api.test"], "the second host was never asked")
    }

    private func body(of request: URLRequest) throws -> [String: String] {
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
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}

/// Answers the first request with a 302 to another host, then a 204 anywhere.
final class RedirectStub: URLProtocol {
    nonisolated(unsafe) static var hosts: [String] = []

    static func reset() { hosts = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        RedirectStub.hosts.append(request.url?.host ?? "")
        guard request.url?.host == "api.test" else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let target = URL(string: "https://evil.test/v1/app/hope-tv/member/session")!
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
        var next = request
        next.url = target
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Keychain

final class SessionKeychainTests: XCTestCase {

    private let keychain = SessionKeychain(service: "de.hopemedia.awe.tests.member", account: "602bd46f36432128d40d5e81:hope-tv-test")
    private let session = MemberSession(token: "tok-\(UUID().uuidString)", expires: Date(timeIntervalSince1970: 1_800_000_000), name: "Ana")

    override func setUp() {
        super.setUp()
        keychain.delete()
    }

    override func tearDown() {
        keychain.delete()
        super.tearDown()
    }

    func testTheAccountNamesTheEntityAndTheApp() {
        XCTAssertEqual(SessionKeychain.account(for: TestConfig.staging), "602bd46f36432128d40d5e81:hope-tv")
    }

    func testASavedSessionLoadsBack() throws {
        XCTAssertNil(keychain.load())

        try keychain.save(session)

        XCTAssertEqual(keychain.load(), session)
    }

    func testASecondSaveReplacesTheFirst() throws {
        try keychain.save(session)
        let next = MemberSession(token: "tok-2", expires: Date(timeIntervalSince1970: 1_900_000_000), name: "Ben")

        try keychain.save(next)

        XCTAssertEqual(keychain.load(), next)
    }

    func testDeleteRemovesTheItem() throws {
        try keychain.save(session)

        keychain.delete()

        XCTAssertNil(keychain.load())
    }

    /// A generic password, this device only, readable after the first unlock.
    func testTheItemIsAThisDeviceOnlyGenericPassword() throws {
        try keychain.save(session)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "de.hopemedia.awe.tests.member",
            kSecAttrAccount as String: "602bd46f36432128d40d5e81:hope-tv-test",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}

// MARK: - Poll loop

/// A clock the test drives: `sleep` records the wait and moves `now` by it.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private(set) var sleeps: [TimeInterval] = []
    /// From this sleep on (0-based), the wait is real and long, so a test can cancel it.
    var blockFromSleep = Int.max

    var clock: SignInClock {
        SignInClock(now: { [unowned self] in now }, sleep: { [unowned self] seconds in
            sleeps.append(seconds)
            if sleeps.count > blockFromSleep {
                try await Task.sleep(for: .seconds(60))
            }
            now += seconds
        })
    }
}

/// Queued answers for the three member calls.
@MainActor
final class FakeMemberService: MemberService {
    var start: Result<SignInGrant, MemberFailure> = .success(FakeMemberService.grant)
    var polls: [Result<PollOutcome, MemberFailure>] = []
    private(set) var polledSecrets: [String] = []
    private(set) var startCount = 0
    var signOutResult: Result<Void, MemberFailure> = .success(())
    private(set) var signedOutTokens: [String] = []

    static let grant = SignInGrant(
        pollingSecret: "s3cr3t", signInCode: "BCDF-GHJK",
        verificationURI: URL(string: "https://hope.test/activate")!,
        verificationURIComplete: URL(string: "https://hope.test/activate#code=BCDFGHJK")!,
        expiresIn: 600, interval: 5
    )

    func startSignIn() async -> Result<SignInGrant, MemberFailure> {
        startCount += 1
        return start
    }

    /// When set, the next poll waits here until the test calls `releasePoll()`.
    var holdsPoll = false
    private var heldPoll: CheckedContinuation<Void, Never>?

    func releasePoll() {
        heldPoll?.resume()
        heldPoll = nil
    }

    /// Like URLSession: a poll whose calling task was cancelled fails, whatever the server answered.
    func poll(secret: String) async -> Result<PollOutcome, MemberFailure> {
        polledSecrets.append(secret)
        if holdsPoll {
            holdsPoll = false
            await withCheckedContinuation { heldPoll = $0 }
        }
        let answer = polls.isEmpty ? .success(.pending) : polls.removeFirst()
        return Task.isCancelled ? .failure(.rejected(.transport("cancelled"))) : answer
    }

    func signOut(token: String) async -> Result<Void, MemberFailure> {
        signedOutTokens.append(token)
        return signOutResult
    }

    // MARK: Slice 2 (awe#6564)

    var history: Result<[WatchProgressStore.Entry], MemberFailure> = .success([])
    private(set) var historyTokens: [String] = []
    /// When set, the next history load waits here until the test calls `releaseHistory()`.
    var holdsHistory = false
    private(set) var isHoldingHistory = false
    private var heldHistory: CheckedContinuation<Void, Never>?

    func releaseHistory() {
        heldHistory?.resume()
        heldHistory = nil
        isHoldingHistory = false
    }

    func watchHistory(token: String) async -> Result<[WatchProgressStore.Entry], MemberFailure> {
        historyTokens.append(token)
        if holdsHistory {
            holdsHistory = false
            await withCheckedContinuation { heldHistory = $0; isHoldingHistory = true }
        }
        return history
    }

    struct SentReport: Equatable {
        let token: String
        let item: WatchHistoryItem
        let report: ProgressReport
    }

    /// Answers in order; once empty, every report answers `recorded: true`.
    var reportResults: [Result<Bool, MemberFailure>] = []
    private(set) var reports: [SentReport] = []

    /// When set, the next report waits here until the test calls `releaseReport()`.
    var holdsReport = false
    private(set) var isHoldingReport = false
    private var heldReport: CheckedContinuation<Void, Never>?

    func releaseReport() {
        heldReport?.resume()
        heldReport = nil
        isHoldingReport = false
    }

    func reportProgress(token: String, item: WatchHistoryItem, report: ProgressReport) async -> Result<Bool, MemberFailure> {
        reports.append(SentReport(token: token, item: item, report: report))
        let answer = reportResults.isEmpty ? Result<Bool, MemberFailure>.success(true) : reportResults.removeFirst()
        if holdsReport {
            holdsReport = false
            await withCheckedContinuation { heldReport = $0; isHoldingReport = true }
        }
        return answer
    }

    var settingsResult: Result<String?, MemberFailure> = .success(nil)
    private(set) var settingsTokens: [String] = []

    func settings(token: String) async -> Result<String?, MemberFailure> {
        settingsTokens.append(token)
        return settingsResult
    }

    // MARK: Slice 3 (awe#6565)

    struct SentImport: Equatable {
        let token: String
        let entries: [HistoryImportEntry]
    }

    /// The refused episode ids, or a failure.
    var importResult: Result<Set<String>, MemberFailure> = .success([])
    private(set) var imports: [SentImport] = []
    /// When set, the next import waits here until the test calls `releaseImport()`.
    var holdsImport = false
    private(set) var isHoldingImport = false
    private var heldImport: CheckedContinuation<Void, Never>?

    func releaseImport() {
        heldImport?.resume()
        heldImport = nil
        isHoldingImport = false
    }

    func importHistory(token: String, entries: [HistoryImportEntry]) async -> Result<Set<String>, MemberFailure> {
        imports.append(SentImport(token: token, entries: entries))
        if holdsImport {
            holdsImport = false
            await withCheckedContinuation { heldImport = $0; isHoldingImport = true }
        }
        return importResult
    }

    // MARK: Saved lists (awe#6869)

    struct SavedCall: Equatable {
        let verb: String
        let list: SavedList
        let token: String
        var ids: [String] = []
    }

    private(set) var savedCalls: [SavedCall] = []
    var savedItemsResult: Result<[SavedItem], MemberFailure> = .success([])
    /// The page served a `nextCursor`.
    var savedItemsHasMore = false
    var savedIdsResult: Result<Set<String>, MemberFailure> = .success([])
    var saveResult: Result<Void, MemberFailure> = .success(())
    var unsaveResult: Result<Void, MemberFailure> = .success(())
    var importSavedResult: Result<Void, MemberFailure> = .success(())
    private(set) var importedSaved: [[SavedItem]] = []
    /// When set, the next list load waits here until the test calls `releaseSavedItems()`.
    var holdsSavedItems = false
    private(set) var isHoldingSavedItems = false
    private var heldSavedItems: CheckedContinuation<Void, Never>?

    func releaseSavedItems() {
        heldSavedItems?.resume()
        heldSavedItems = nil
        isHoldingSavedItems = false
    }

    /// The answer is read when the call starts, so a held load answers what the server held then.
    func savedItems(_ list: SavedList, token: String) async -> Result<SavedItemsPage, MemberFailure> {
        savedCalls.append(SavedCall(verb: "GET", list: list, token: token))
        let answer = savedItemsResult.map { SavedItemsPage(items: $0, hasMore: savedItemsHasMore) }
        if holdsSavedItems {
            holdsSavedItems = false
            await withCheckedContinuation { heldSavedItems = $0; isHoldingSavedItems = true }
        }
        return answer
    }

    /// When set, the next `/contains` waits here until the test calls `releaseSavedIds()` (awe#6871).
    var holdsSavedIds = false
    private(set) var isHoldingSavedIds = false
    private var heldSavedIds: CheckedContinuation<Void, Never>?

    func releaseSavedIds() {
        heldSavedIds?.resume()
        heldSavedIds = nil
        isHoldingSavedIds = false
    }

    func savedIds(_ list: SavedList, token: String, itemType: SavedItem.ItemType, ids: [String]) async -> Result<Set<String>, MemberFailure> {
        savedCalls.append(SavedCall(verb: "CONTAINS", list: list, token: token, ids: ids.map { SavedItem.id(itemType, $0) }))
        if holdsSavedIds {
            holdsSavedIds = false
            await withCheckedContinuation { heldSavedIds = $0; isHoldingSavedIds = true }
        }
        return savedIdsResult
    }

    /// When set, the next save waits here until the test calls `releaseSave()` (awe#6871).
    var holdsSave = false
    private(set) var isHoldingSave = false
    private var heldSave: CheckedContinuation<Void, Never>?

    func releaseSave() {
        heldSave?.resume()
        heldSave = nil
        isHoldingSave = false
    }

    func save(_ list: SavedList, token: String, itemType: SavedItem.ItemType, itemId: String) async -> Result<Void, MemberFailure> {
        savedCalls.append(SavedCall(verb: "PUT", list: list, token: token, ids: [SavedItem.id(itemType, itemId)]))
        if holdsSave {
            holdsSave = false
            await withCheckedContinuation { heldSave = $0; isHoldingSave = true }
        }
        return saveResult
    }

    func unsave(_ list: SavedList, token: String, itemType: SavedItem.ItemType, itemId: String) async -> Result<Void, MemberFailure> {
        savedCalls.append(SavedCall(verb: "DELETE", list: list, token: token, ids: [SavedItem.id(itemType, itemId)]))
        return unsaveResult
    }

    func importSaved(_ list: SavedList, token: String, items: [SavedItem]) async -> Result<Void, MemberFailure> {
        savedCalls.append(SavedCall(verb: "IMPORT", list: list, token: token, ids: items.map(\.id)))
        importedSaved.append(items)
        return importSavedResult
    }
}

/// A Keychain stand-in, so the loop tests never touch the real one.
final class MemorySessionStore: SessionStoring {
    var stored: MemberSession?
    private(set) var deletes = 0

    func load() -> MemberSession? { stored }
    func save(_ session: MemberSession) throws { stored = session }
    func delete() { deletes += 1; stored = nil }
}

@MainActor
final class SignInFlowTests: XCTestCase {

    private var service: FakeMemberService!
    private var store: MemorySessionStore!
    private var clock: FakeClock!
    private var account: MemberAccount!

    private let session = MemberSession(token: "tok", expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana")

    override func setUp() async throws {
        service = FakeMemberService()
        store = MemorySessionStore()
        clock = FakeClock()
        account = MemberAccount(service: service, store: store, now: { [clock] in clock!.now })
    }

    private func flow() -> SignInFlow {
        SignInFlow(service: service, account: account, clock: clock.clock)
    }

    func testItShowsTheCodeAndPollsEveryInterval() async {
        service.polls = [.success(.pending), .success(.pending), .success(.approved(session))]
        let flow = flow()

        await flow.run()

        XCTAssertEqual(clock.sleeps, [5, 5, 5])
        XCTAssertEqual(service.polledSecrets, ["s3cr3t", "s3cr3t", "s3cr3t"])
        XCTAssertEqual(flow.phase, .approved(session))
    }

    /// The token goes to the Keychain at approval; the confirm screen comes after.
    func testApprovalStoresTheSession() async {
        service.polls = [.success(.approved(session))]

        await flow().run()

        XCTAssertEqual(store.stored, session)
        XCTAssertEqual(account.session, session)
    }

    func testSlowDownAddsFiveSecondsEachTime() async {
        service.polls = [.success(.slowDown), .success(.slowDown), .success(.pending), .success(.approved(session))]

        await flow().run()

        XCTAssertEqual(clock.sleeps, [5, 10, 15, 15])
    }

    func testA429AlsoSlowsDown() async {
        service.polls = [.failure(.rateLimited), .success(.approved(session))]

        await flow().run()

        XCTAssertEqual(clock.sleeps, [5, 10])
    }

    func testExpiredStopsAndOffersANewCode() async {
        service.polls = [.success(.pending), .success(.expired)]
        let flow = flow()

        await flow.run()

        XCTAssertEqual(flow.phase, .expired)
        XCTAssertEqual(service.polledSecrets.count, 2)
    }

    /// The local deadline stops the loop even when the server never says `expired`.
    func testTheLocalDeadlineStopsTheLoop() async {
        service.start = .success(SignInGrant(
            pollingSecret: "s", signInCode: "BCDF-GHJK",
            verificationURI: FakeMemberService.grant.verificationURI,
            verificationURIComplete: FakeMemberService.grant.verificationURIComplete,
            expiresIn: 12, interval: 5
        ))
        let flow = flow()

        await flow.run()

        XCTAssertEqual(clock.sleeps, [5, 5, 2])
        XCTAssertEqual(service.polledSecrets.count, 2, "no poll after the deadline")
        XCTAssertEqual(flow.phase, .expired)
    }

    func testANetworkErrorKeepsPolling() async {
        service.polls = [.failure(.rejected(.transport("offline"))), .failure(.rejected(.httpStatus(503))), .success(.approved(session))]
        let flow = flow()

        await flow.run()

        XCTAssertEqual(clock.sleeps, [5, 5, 5])
        XCTAssertEqual(flow.phase, .approved(session))
    }

    func testAnUnknownStatusKeepsPolling() async {
        service.polls = [.success(.unsupported), .success(.approved(session))]

        await flow().run()

        XCTAssertEqual(service.polledSecrets.count, 2)
    }

    /// The screen went away: the loop stops and polls no more.
    /// Back during a poll that the server answers `approved`: the grant is spent and the session
    /// minted, so the answer is still read and stored. No further poll goes out.
    func testCancelDuringAnApprovedPollStillStoresTheSession() async {
        service.holdsPoll = true
        service.polls = [.success(.approved(session))]
        let flow = flow()

        let task = Task { await flow.run() }
        while service.polledSecrets.isEmpty { await Task.yield() }
        task.cancel()
        service.releasePoll()
        await task.value

        XCTAssertEqual(store.stored, session)
        XCTAssertEqual(account.session, session)
        XCTAssertEqual(service.polledSecrets.count, 1)
    }

    /// Back during a poll that answers `pending`: the loop stops and sends no further poll.
    func testCancelDuringAPendingPollStopsTheLoop() async {
        service.holdsPoll = true
        service.polls = [.success(.pending)]
        let flow = flow()

        let task = Task { await flow.run() }
        while service.polledSecrets.isEmpty { await Task.yield() }
        task.cancel()
        service.releasePoll()
        await task.value

        XCTAssertEqual(service.polledSecrets.count, 1)
        XCTAssertNil(store.stored)
    }

    /// A 404 mid-poll means sign-in was turned off: stop at once, do not poll to the deadline.
    func testA404WhilePollingStopsAsUnavailable() async {
        service.polls = [.success(.pending), .failure(.unavailable)]
        let flow = flow()

        await flow.run()

        XCTAssertEqual(flow.phase, .unavailable)
        XCTAssertEqual(service.polledSecrets.count, 2)
    }

    func testCancelStopsThePolling() async {
        clock.blockFromSleep = 1
        let flow = flow()

        let task = Task { await flow.run() }
        while clock.sleeps.count < 2 { await Task.yield() }
        task.cancel()
        await task.value

        XCTAssertEqual(service.polledSecrets.count, 1)
        XCTAssertEqual(flow.phase, .code(FakeMemberService.grant))
    }

    func testAStartThatAnswers404SaysSignInIsUnavailable() async {
        service.start = .failure(.unavailable)
        let flow = flow()

        await flow.run()

        XCTAssertEqual(flow.phase, .unavailable)
        XCTAssertEqual(service.polledSecrets, [])
    }

    func testAStartThatFailsOffersANewTry() async {
        service.start = .failure(.rejected(.transport("offline")))
        let flow = flow()

        await flow.run()

        XCTAssertEqual(flow.phase, .failed)
    }

    /// "Get a new code" runs the flow again with a fresh grant.
    func testANewCodeStartsAgain() async {
        service.polls = [.success(.expired)]
        let flow = flow()
        await flow.run()

        service.polls = [.success(.approved(session))]
        await flow.run()

        XCTAssertEqual(service.startCount, 2)
        XCTAssertEqual(flow.phase, .approved(session))
    }

    /// A grant with no usable interval still waits: never a tight loop.
    func testAZeroIntervalWaitsTheDefault() async {
        service.start = .success(SignInGrant(
            pollingSecret: "s", signInCode: "BCDF-GHJK",
            verificationURI: FakeMemberService.grant.verificationURI,
            verificationURIComplete: FakeMemberService.grant.verificationURIComplete,
            expiresIn: 600, interval: 0
        ))
        service.polls = [.success(.approved(session))]

        await flow().run()

        XCTAssertEqual(clock.sleeps, [5])
    }
}

// MARK: - Account and sign-out

@MainActor
final class MemberAccountTests: XCTestCase {

    private let session = MemberSession(token: "tok", expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana")

    func testAStoredSessionSignsInAtLaunch() {
        let store = MemorySessionStore()
        store.stored = session

        let account = MemberAccount(service: FakeMemberService(), store: store, now: { Date(timeIntervalSince1970: 1_000_000) })

        XCTAssertEqual(account.session, session)
    }

    /// An expired session is signed out at launch and its item removed.
    func testAnExpiredStoredSessionIsDropped() {
        let store = MemorySessionStore()
        store.stored = session

        let account = MemberAccount(service: FakeMemberService(), store: store, now: { Date(timeIntervalSince1970: 3_000_000) })

        XCTAssertNil(account.session)
        XCTAssertNil(store.stored)
    }

    func testSignOutRevokesThenDeletesTheItem() async {
        let service = FakeMemberService()
        let store = MemorySessionStore()
        store.stored = session
        let account = MemberAccount(service: service, store: store, now: { Date(timeIntervalSince1970: 1_000_000) })

        await account.signOut()

        XCTAssertEqual(service.signedOutTokens, ["tok"])
        XCTAssertNil(store.stored)
        XCTAssertNil(account.session)
    }

    /// The Keychain item goes whatever the server answers.
    func testSignOutDeletesTheItemWhenTheCallFails() async {
        let service = FakeMemberService()
        service.signOutResult = .failure(.rejected(.transport("offline")))
        let store = MemorySessionStore()
        store.stored = session
        let account = MemberAccount(service: service, store: store, now: { Date(timeIntervalSince1970: 1_000_000) })

        await account.signOut()

        XCTAssertEqual(service.signedOutTokens, ["tok"])
        XCTAssertNil(store.stored)
        XCTAssertNil(account.session)
    }

    /// Security §7 row 5: the token lives in the Keychain, never in UserDefaults.
    func testTheTokenNeverReachesUserDefaults() throws {
        let keychain = SessionKeychain(service: "de.hopemedia.awe.tests.member", account: "defaults-check")
        defer { keychain.delete() }
        let token = "tok-\(UUID().uuidString)"
        let account = MemberAccount(service: FakeMemberService(), store: keychain, now: Date.init)

        account.signedIn(MemberSession(token: token, expires: Date().addingTimeInterval(3600), name: "Ana"))

        XCTAssertEqual(keychain.load()?.token, token)
        let defaults = UserDefaults.standard.dictionaryRepresentation().values.map { "\($0)" }.joined()
        XCTAssertFalse(defaults.contains(token))
    }
}

// MARK: - Strings

final class SignInScreenTests: XCTestCase {

    func testTheSignedInNameFillsThePlaceholder() {
        ChromeText.served.strings = [:]
        defer { ChromeText.served.strings = [:] }

        XCTAssertEqual(ChromeText.string(.signedInAs, ["name": "Ana"]), "Signed in as Ana")
        XCTAssertEqual(ChromeText.string(.signInVisit, ["url": "https://hope.test/activate"]),
                       "On your phone or computer, go to https://hope.test/activate and enter this code.")
    }
}

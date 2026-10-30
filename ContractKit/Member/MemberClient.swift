import Foundation

/// A signed-in member on this TV: the `app`-audience session the poll minted. The token is a
/// secret; it lives only in the Keychain (`SessionKeychain`) and in memory.
struct MemberSession: Codable, Equatable {
    let token: String
    let expires: Date
    /// `member.name`: the WebUser name, else the member's email. Drawn on the Account tab.
    let name: String
}

/// `POST /member/sign-in`: one device grant. `signInCode` is drawn as served (`XXXX-XXXX`).
struct SignInGrant: Equatable {
    let pollingSecret: String
    let signInCode: String
    let verificationURI: URL
    /// The QR target. The code is in the URL fragment, never the query (ruling 3).
    let verificationURIComplete: URL
    /// Seconds from now until the grant ends: the local deadline.
    let expiresIn: TimeInterval
    /// Seconds between polls.
    let interval: TimeInterval
}

/// `POST /member/sign-in/poll`. All four statuses are HTTP 200. An unknown status decodes to
/// `.unsupported`, never a decode failure.
enum PollOutcome: Equatable {
    case pending
    case slowDown
    case expired
    case approved(MemberSession)
    case unsupported
}

enum MemberFailure: Error, Equatable {
    /// 404 `NOT_FOUND`: sign-in is off for this App.
    case unavailable
    /// 429 `RATE_LIMITED`.
    case rateLimited
    /// 401: the session is no longer valid. The caller signs out locally (awe#6564).
    case signedOut
    /// A body that is not the contract's shape.
    case decodeFailed
    /// Transport, origin, redirect, byte cap or any other status.
    case rejected(RejectionReason)
}

/// One item of the member's watch history: the `:itemType/:itemId` of the member routes. An
/// episode and a movie can share an id, so the server copy and the resume points key by both.
struct WatchHistoryItem: Hashable {
    enum ItemType: String {
        case episode, movie
    }

    let itemType: ItemType
    let itemId: String

    static func episode(_ id: String) -> WatchHistoryItem { WatchHistoryItem(itemType: .episode, itemId: id) }
    static func movie(_ id: String) -> WatchHistoryItem { WatchHistoryItem(itemType: .movie, itemId: id) }

    /// The card id of a server-copy entry: the episode id (awe#6564), `movie:<id>` for a movie.
    var playableId: String { itemType == .episode ? itemId : "\(itemType.rawValue):\(itemId)" }
}

/// One progress report (`PUT /member/watch-history/:itemType/:id`), in seconds. A nil duration is
/// sent as `null`: the player does not know it.
struct ProgressReport: Equatable {
    let position: Double
    let duration: Double?
    let ended: Bool
}

/// One page of a saved list (awe#6869). `hasMore`: the server served a `nextCursor`, so an item
/// that is not in `items` can still be saved.
struct SavedItemsPage: Equatable {
    var items: [SavedItem]
    var hasMore = false
}

/// One device entry for the one-time import (`POST /member/watch-history/import`, awe#6565), in
/// seconds. `lastAt` is the entry's `updatedAt`. `episodeId` is the wire name of every id, a
/// movie's too. Only a movie sends `itemType`: with none, the server reads `episode`.
struct HistoryImportEntry: Equatable {
    var itemType: WatchHistoryItem.ItemType = .episode
    let episodeId: String
    let position: Double
    let duration: Double
    let lastAt: Date
}

/// The member calls. `SignInFlow` and `MemberAccount` read this, so a test can stand in for the
/// network. Slice 1: sign-in and sign-out. Slice 2 (awe#6564): history, progress and settings.
protocol MemberService {
    func startSignIn() async -> Result<SignInGrant, MemberFailure>
    func poll(secret: String) async -> Result<PollOutcome, MemberFailure>
    func signOut(token: String) async -> Result<Void, MemberFailure>
    /// `GET /member/watch-history`: the unfinished episodes and movies, as shelf entries.
    func watchHistory(token: String) async -> Result<[WatchProgressStore.Entry], MemberFailure>
    /// `PUT /member/watch-history/:itemType/:id`: the server's `recorded` flag.
    func reportProgress(token: String, item: WatchHistoryItem, report: ProgressReport) async -> Result<Bool, MemberFailure>
    /// `GET /member/settings`: the `watchHistoryHint.site`, or nil when there is no hint.
    func settings(token: String) async -> Result<String?, MemberFailure>
    /// `POST /member/watch-history/import` (slice 3, awe#6565): the item ids the server refused.
    func importHistory(token: String, entries: [HistoryImportEntry]) async -> Result<Set<String>, MemberFailure>
    /// `GET /member/<list>?limit=100` (awe#6869): the first page, as served (newest first).
    func savedItems(_ list: SavedList, token: String) async -> Result<SavedItemsPage, MemberFailure>
    /// `GET /member/<list>/contains?itemType=&ids=`: the ids of `ids` that the list holds.
    func savedIds(_ list: SavedList, token: String, itemType: SavedItem.ItemType, ids: [String]) async -> Result<Set<String>, MemberFailure>
    /// `PUT /member/<list>/:itemType/:itemId`: 201 (saved now) or 200 (already saved).
    func save(_ list: SavedList, token: String, itemType: SavedItem.ItemType, itemId: String) async -> Result<Void, MemberFailure>
    /// `DELETE /member/<list>/:itemType/:itemId`: 204, also when the item is not in the list.
    func unsave(_ list: SavedList, token: String, itemType: SavedItem.ItemType, itemId: String) async -> Result<Void, MemberFailure>
    /// `POST /member/<list>/import`: any 2xx is a success.
    func importSaved(_ list: SavedList, token: String, items: [SavedItem]) async -> Result<Void, MemberFailure>
}

/// The App member router (`/v1/app/:appSlug/member/*`, awe#6563).
///
/// It sends through `AppContractClient.send`: the three headers, the refused redirect, the
/// origin guard and the byte cap. The session token must never follow a redirect. Member answers
/// are memory only: they never touch `ContractCache`.
struct MemberClient: MemberService {
    let contract: AppContractClient

    func startSignIn() async -> Result<SignInGrant, MemberFailure> {
        #if DEBUG
        if let data = DebugMemberSignIn.startAnswer() {
            return Self.decode(data, SignInGrant.self)
        }
        #endif
        guard let request = post("sign-in", body: [:]) else { return .failure(.rejected(.transport("cannot build the sign-in URL"))) }
        return Self.decode(await contract.send(request), SignInGrant.self)
    }

    func poll(secret: String) async -> Result<PollOutcome, MemberFailure> {
        #if DEBUG
        if let data = DebugMemberSignIn.pollAnswer() {
            return Self.decode(data, PollAnswer.self).map(\.outcome)
        }
        #endif
        guard let request = post("sign-in/poll", body: ["pollingSecret": secret]) else {
            return .failure(.rejected(.transport("cannot build the poll URL")))
        }
        return Self.decode(await contract.send(request), PollAnswer.self).map(\.outcome)
    }

    func signOut(token: String) async -> Result<Void, MemberFailure> {
        guard let url = url("session") else { return .failure(.rejected(.transport("cannot build the session URL"))) }
        var request = contract.request(for: url)
        request.httpMethod = "DELETE"
        request.setValue(token, forHTTPHeaderField: "session")
        return Self.failure(await contract.send(request, accepting: [200, 204])).map { _ in }
    }

    func watchHistory(token: String) async -> Result<[WatchProgressStore.Entry], MemberFailure> {
        #if DEBUG
        if let data = DebugMemberHistory.historyAnswer() {
            return Self.decode(data, HistoryAnswer.self).map { $0.entries(images: images) }
        }
        #endif
        guard let request = get("watch-history", token: token) else {
            return .failure(.rejected(.transport("cannot build the watch history URL")))
        }
        return Self.decode(await contract.send(request), HistoryAnswer.self).map { $0.entries(images: images) }
    }

    func reportProgress(token: String, item: WatchHistoryItem, report: ProgressReport) async -> Result<Bool, MemberFailure> {
        // The id lands in the URL path, so only a 24-hex ObjectId is sent. The type is a closed enum.
        guard ContractValidator.isObjectId(item.itemId), let url = url("watch-history/\(item.itemType.rawValue)/\(item.itemId)") else {
            return .failure(.rejected(.transport("not an item id")))
        }
        #if DEBUG
        DebugMemberHistory.log(report, episodeId: item.itemId)
        if let data = DebugMemberHistory.progressAnswer() {
            return Self.decode(data, RecordedAnswer.self).map(\.recorded)
        }
        #endif
        var body: [String: Any] = ["position": max(report.position, 0), "duration": report.duration.map { max($0, 0) } ?? NSNull()]
        if report.ended {
            body["ended"] = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.rejected(.transport("cannot encode the report")))
        }
        var request = contract.request(for: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "session")
        request.httpBody = data
        return Self.decode(await contract.send(request), RecordedAnswer.self).map(\.recorded)
    }

    func settings(token: String) async -> Result<String?, MemberFailure> {
        #if DEBUG
        if let data = DebugMemberHistory.settingsAnswer() {
            return Self.decode(data, SettingsAnswer.self).map(\.hintSite)
        }
        #endif
        guard let request = get("settings", token: token) else {
            return .failure(.rejected(.transport("cannot build the settings URL")))
        }
        return Self.decode(await contract.send(request), SettingsAnswer.self).map(\.hintSite)
    }

    func importHistory(token: String, entries: [HistoryImportEntry]) async -> Result<Set<String>, MemberFailure> {
        #if DEBUG
        DebugMemberHistory.logImport(entries)
        if let data = DebugMemberHistory.importAnswer() {
            return Self.decode(data, ImportAnswer.self).map(\.refused)
        }
        #endif
        // `WatchProgressStore.importEntries` keeps both numbers within the route's bounds.
        let items: [[String: Any]] = entries.map { entry in
            var item: [String: Any] = ["episodeId": entry.episodeId, "position": entry.position, "duration": entry.duration,
                                       "lastAt": ISODate.format(entry.lastAt)]
            // An episode sends no `itemType`, as before movies: the server reads `episode`.
            if entry.itemType != .episode {
                item["itemType"] = entry.itemType.rawValue
            }
            return item
        }
        guard let url = url("watch-history/import"), let data = try? JSONSerialization.data(withJSONObject: ["entries": items]) else {
            return .failure(.rejected(.transport("cannot build the import request")))
        }
        var request = contract.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "session")
        request.httpBody = data
        return Self.decode(await contract.send(request), ImportAnswer.self).map(\.refused)
    }

    // MARK: - Saved lists (awe#6869)

    func savedItems(_ list: SavedList, token: String) async -> Result<SavedItemsPage, MemberFailure> {
        #if DEBUG
        if let data = DebugMemberHistory.savedItemsAnswer(list) {
            return Self.decode(data, SavedItemsAnswer.self).map { $0.page(images: images) }
        }
        #endif
        // The route answers 400 to any other query key, and to a limit above 100.
        guard let url = url(list.rawValue, query: [URLQueryItem(name: "limit", value: "100")]) else {
            return .failure(.rejected(.transport("cannot build the \(list.rawValue) URL")))
        }
        var request = contract.request(for: url)
        request.setValue(token, forHTTPHeaderField: "session")
        return Self.decode(await contract.send(request), SavedItemsAnswer.self).map { $0.page(images: images) }
    }

    func savedIds(_ list: SavedList, token: String, itemType: SavedItem.ItemType, ids: [String]) async -> Result<Set<String>, MemberFailure> {
        let ids = ids.filter(ContractValidator.isObjectId)
        guard !ids.isEmpty, let url = url("\(list.rawValue)/contains", query: [
            URLQueryItem(name: "itemType", value: itemType.rawValue),
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
        ]) else { return .failure(.rejected(.transport("not an item id"))) }
        var request = contract.request(for: url)
        request.setValue(token, forHTTPHeaderField: "session")
        return Self.decode(await contract.send(request), SavedIdsAnswer.self).map { Set($0.items) }
    }

    func save(_ list: SavedList, token: String, itemType: SavedItem.ItemType, itemId: String) async -> Result<Void, MemberFailure> {
        await write("PUT", list, token: token, itemType: itemType, itemId: itemId, accepting: [200, 201])
    }

    func unsave(_ list: SavedList, token: String, itemType: SavedItem.ItemType, itemId: String) async -> Result<Void, MemberFailure> {
        await write("DELETE", list, token: token, itemType: itemType, itemId: itemId, accepting: [200, 204])
    }

    func importSaved(_ list: SavedList, token: String, items: [SavedItem]) async -> Result<Void, MemberFailure> {
        #if DEBUG
        if DebugMemberHistory.savedImportAnswer(list) != nil {
            return .success(())
        }
        #endif
        // Only the type, the id and the time leave the device; the title and the image stay.
        let entries: [[String: Any]] = items.prefix(DeviceItemListStore.limit).map { item in
            ["itemType": item.itemType.rawValue, "itemId": item.itemId, "savedAt": ISODate.format(item.savedAt)]
        }
        guard let url = url("\(list.rawValue)/import"), let data = try? JSONSerialization.data(withJSONObject: ["entries": entries]) else {
            return .failure(.rejected(.transport("cannot build the import request")))
        }
        var request = contract.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "session")
        request.httpBody = data
        // Any 2xx clears the device copy, so the body is not read.
        return Self.failure(await contract.send(request, accepting: Set(200..<300))).map { _ in }
    }

    /// A `PUT` or `DELETE` of one item. The type and the id land in the URL path, so only a
    /// 24-hex ObjectId is sent.
    private func write(_ method: String, _ list: SavedList, token: String, itemType: SavedItem.ItemType, itemId: String,
                       accepting statuses: Set<Int>) async -> Result<Void, MemberFailure> {
        guard ContractValidator.isObjectId(itemId), let url = url("\(list.rawValue)/\(itemType.rawValue)/\(itemId)") else {
            return .failure(.rejected(.transport("not an item id")))
        }
        var request = contract.request(for: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "session")
        return Self.failure(await contract.send(request, accepting: statuses)).map { _ in }
    }

    // MARK: - Request

    private var images: ImageConfig {
        ImageConfig(cdn: contract.config.imagesCDN, bucket: contract.config.imagesBucket)
    }

    /// A member read. The session token is a header, never part of the URL.
    private func get(_ path: String, token: String) -> URLRequest? {
        guard let url = url(path) else { return nil }
        var request = contract.request(for: url)
        request.setValue(token, forHTTPHeaderField: "session")
        return request
    }

    /// The path is fixed text plus the build-time App slug; no response value shapes it.
    private func url(_ path: String) -> URL? {
        contract.config.apiBaseURL.appendingPathComponent("/v1/app/\(contract.config.appSlug)/member/\(path)")
    }

    /// The same URL with a query.
    private func url(_ path: String, query: [URLQueryItem]) -> URL? {
        guard let base = url(path), var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = query
        return components.url
    }

    /// The polling secret goes in the JSON body, never the URL.
    private func post(_ path: String, body: [String: String]) -> URLRequest? {
        guard let url = url(path), let data = try? JSONEncoder().encode(body) else { return nil }
        var request = contract.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    private static func failure(_ result: Result<Data, RejectionReason>) -> Result<Data, MemberFailure> {
        result.mapError { reason in
            switch reason {
            case .httpStatus(401): return .signedOut
            case .httpStatus(404): return .unavailable
            case .httpStatus(429): return .rateLimited
            default: return .rejected(reason)
            }
        }
    }

    private static func decode<T: Decodable>(_ result: Result<Data, RejectionReason>, _ type: T.Type) -> Result<T, MemberFailure> {
        failure(result).flatMap { decode($0, type) }
    }

    private static func decode<T: Decodable>(_ data: Data, _ type: T.Type) -> Result<T, MemberFailure> {
        guard let value = try? JSONDecoder().decode(type, from: data) else { return .failure(.decodeFailed) }
        return .success(value)
    }
}

extension SignInGrant: Decodable {
    private enum Keys: String, CodingKey {
        case pollingSecret, signInCode, verificationUri, verificationUriComplete, expiresIn, interval
    }

    /// Both URIs must be https: the QR sends a phone there. A missing `interval` reads as the
    /// RFC 8628 default of 5 s; `SignInFlow` also floors a value below 1 s.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        pollingSecret = try container.decode(String.self, forKey: .pollingSecret)
        signInCode = try container.decode(String.self, forKey: .signInCode)
        verificationURI = try Self.https(container.decode(String.self, forKey: .verificationUri), container, .verificationUri)
        verificationURIComplete = try Self.https(container.decode(String.self, forKey: .verificationUriComplete), container, .verificationUriComplete)
        expiresIn = try container.decode(TimeInterval.self, forKey: .expiresIn)
        interval = (try? container.decode(TimeInterval.self, forKey: .interval)) ?? SignInGrant.defaultInterval
    }

    static let defaultInterval: TimeInterval = 5

    private static func https(_ text: String, _ container: KeyedDecodingContainer<Keys>, _ key: Keys) throws -> URL {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "not an https URL")
        }
        return url
    }
}

/// The poll body. `approved` needs a token and an expiry; a missing name reads as empty.
private struct PollAnswer: Decodable {
    let outcome: PollOutcome

    private enum Keys: String, CodingKey { case status, sessionToken, expires, member }
    private enum MemberKeys: String, CodingKey { case name }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "pending": outcome = .pending
        case "slow_down": outcome = .slowDown
        case "expired": outcome = .expired
        case "approved":
            let token = try container.decode(String.self, forKey: .sessionToken)
            guard !token.isEmpty, let expires = ISODate.parse(try container.decode(String.self, forKey: .expires)) else {
                throw DecodingError.dataCorruptedError(forKey: .sessionToken, in: container, debugDescription: "no usable session")
            }
            let member = try? container.nestedContainer(keyedBy: MemberKeys.self, forKey: .member)
            let name = (try? member?.decode(String.self, forKey: .name)) ?? ""
            outcome = .approved(MemberSession(token: token, expires: expires, name: name))
        default: outcome = .unsupported
        }
    }
}

/// `GET /member/watch-history`. Each item maps on its own: an unknown type, an item with no usable
/// id, or one with no duration is skipped, never a failure of the whole list.
private struct HistoryAnswer: Decodable {
    let items: [JSONValue]

    func entries(images: ImageConfig) -> [WatchProgressStore.Entry] {
        items.compactMap { Self.entry($0, images: images) }
    }

    /// An episode or a movie. `playableId` is `WatchHistoryItem.playableId`: a server item has no
    /// media URL, and the card id only needs to be unique.
    static func entry(_ item: JSONValue, images: ImageConfig) -> WatchProgressStore.Entry? {
        guard let itemType = item["itemType"].string.flatMap(WatchHistoryItem.ItemType.init(rawValue:)) else { return nil }
        let record = item[itemType.rawValue]
        guard let id = record["_id"].text, ContractValidator.isObjectId(id),
              let position = item["position"].double, position >= 0,
              let duration = [item["duration"].double, record["duration"].double].compactMap({ $0 }).first(where: { $0 > 0 })
        else { return nil }
        let updatedAt = item["updatedAt"].string.flatMap(ISODate.parse) ?? .distantPast
        guard itemType == .episode else {
            // `movie { _id, title, images, duration }`: no show, so no subtitle and no show id.
            return WatchProgressStore.Entry(
                playableId: WatchHistoryItem.movie(id).playableId,
                showId: nil,
                movieId: id,
                title: record["title"].text ?? ChromeText.string(.untitled),
                subtitle: "",
                imageURL: images.url(ImageCatalog.pick(record["images"]), width: 640),
                fraction: min(position / duration, 1),
                duration: duration,
                updatedAt: updatedAt
            )
        }
        let episode = record
        let show = episode["show"]
        // An episode with no image of its own draws its show's image.
        let image = ImageFile(episode["image"]) ?? ImageCatalog.pick(episode["images"]) ?? ImageFile(show["image"])
        return WatchProgressStore.Entry(
            playableId: id,
            showId: show["_id"].text.flatMap { ContractValidator.isObjectId($0) ? $0 : nil },
            episodeId: id,
            title: episode["title"].text ?? ChromeText.string(.episode),
            subtitle: show["title"].text ?? "",
            imageURL: images.url(image, width: 640),
            fraction: min(position / duration, 1),
            duration: duration,
            updatedAt: updatedAt
        )
    }
}

/// `PUT /member/watch-history/...`: `{ recorded }`. A missing flag reads as not recorded.
private struct RecordedAnswer: Decodable {
    let recorded: Bool

    private enum Keys: String, CodingKey { case recorded }

    init(from decoder: Decoder) throws {
        recorded = (try? decoder.container(keyedBy: Keys.self).decode(Bool.self, forKey: .recorded)) ?? false
    }
}

/// `GET /member/settings`: `{ watchHistoryHint: { site } | null }`. A blank site is no hint.
private struct SettingsAnswer: Decodable {
    let hintSite: String?

    private enum Keys: String, CodingKey { case watchHistoryHint }
    private enum HintKeys: String, CodingKey { case site }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let hint = try? container.nestedContainer(keyedBy: HintKeys.self, forKey: .watchHistoryHint)
        let site = (try? hint?.decode(String.self, forKey: .site))?.trimmingCharacters(in: .whitespacesAndNewlines)
        hintSite = site?.isEmpty == false ? site : nil
    }
}

/// `POST /member/watch-history/import`: `{ imported, skipped, refused }`. Only `refused` is read.
/// It is required: without it the TV cannot tell which entries to keep, so it clears nothing.
private struct ImportAnswer: Decodable {
    let refused: Set<String>
}

/// `GET /member/<list>` (awe#6869): `{ items, nextCursor }`. Each item maps on its own: an unknown
/// `itemType`, or a record with no ObjectId, is skipped, never a failure of the whole list. The
/// order is the server's (newest first). Only the first page is read; it can be shorter than the
/// limit while `nextCursor` is set (the server drops hidden items after paging).
private struct SavedItemsAnswer: Decodable {
    let items: [JSONValue]

    let nextCursor: String?

    func page(images: ImageConfig) -> SavedItemsPage {
        SavedItemsPage(items: items.compactMap { Self.item($0, images: images) }, hasMore: nextCursor?.isEmpty == false)
    }

    static func item(_ item: JSONValue, images: ImageConfig) -> SavedItem? {
        guard let itemType = item["itemType"].string.flatMap(SavedItem.ItemType.init(rawValue:)) else { return nil }
        let record = item[itemType.rawValue]
        guard let id = record["_id"].text, ContractValidator.isObjectId(id) else { return nil }
        let file: ImageFile?
        switch itemType {
        // A show serves its default image as `image`, as an episode's nested show does.
        case .show: file = ImageFile(record["image"])
        // An episode with no image of its own draws its show's image.
        case .episode: file = ImageFile(record["image"]) ?? ImageFile(record["show"]["image"])
        case .movie: file = ImageCatalog.pick(record["images"])
        }
        return SavedItem(
            itemType: itemType,
            itemId: id,
            title: record["title"].text ?? ChromeText.string(.untitled),
            imageURL: images.url(file, width: 640),
            savedAt: item["createdAt"].string.flatMap(ISODate.parse) ?? .distantPast
        )
    }
}

/// `GET /member/<list>/contains`: `{ items: [<saved id>] }`.
private struct SavedIdsAnswer: Decodable {
    let items: [String]
}

/// `Date.toISOString()` sends milliseconds; a plain RFC 3339 date is read too.
private enum ISODate {
    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The `toISOString()` shape: `2026-10-12T19:04:11.000Z`.
    static func format(_ date: Date) -> String {
        fractional.string(from: date)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

#if DEBUG
/// Simulator aids for sign-in. Debug builds only.
///
/// - `-member-sign-in 1` turns the Manifest flag on, so the Account tab shows before the server
///   serves the flag.
/// - `-sign-in-override-file <path>` answers the start call with that file, so the code screen and
///   its QR show before the route is deployed.
/// - `-sign-in-poll-override-file <path>` answers every poll with that file (an `approved` body
///   reaches the confirm screen). Without it the poll goes to the server.
/// - `-open-account 1` selects the Account tab; `-open-sign-in 1` also opens the code screen.
enum DebugMemberSignIn {
    static var forcesFlag: Bool { UserDefaults.standard.bool(forKey: "member-sign-in") }
    static var opensAccount: Bool { UserDefaults.standard.bool(forKey: "open-account") || opensSignIn }
    static var opensSignIn: Bool { UserDefaults.standard.bool(forKey: "open-sign-in") }
    /// Once per launch, so Back from the code screen stays on the Account tab.
    @MainActor static var openedSignIn = false

    static func startAnswer() -> Data? { file("sign-in-override-file") }
    static func pollAnswer() -> Data? { file("sign-in-poll-override-file") }

    /// The session store for this launch. With a poll override (a UI test), a memory store, so
    /// the test never writes the real Keychain and no item leaks into a later suite.
    static func sessionStore(real: SessionStoring) -> SessionStoring {
        let key = "sign-in-poll-override-file"
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return real }
        return DebugMemoryStore()
    }

    fileprivate static func file(_ key: String) -> Data? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}

/// A session store that holds nothing: a debug session lives only in `MemberAccount.session`, and
/// a sign-out or a 401 deletes nothing on disk. Debug builds only.
struct DebugMemoryStore: SessionStoring {
    func load() -> MemberSession? { nil }
    func save(_ session: MemberSession) throws {}
    func delete() {}
}

/// Simulator aids for server history (awe#6564). Debug builds only.
///
/// - `-member-session <name>` signs in for this launch with a fake session (memory only, never
///   the Keychain). Pair it with the override files: the server refuses the fake token (401),
///   and a 401 signs out.
/// - `-member-history-override-file <path>` answers `GET /member/watch-history` with that file.
/// - `-member-settings-override-file <path>` answers `GET /member/settings` with that file.
/// - `-member-progress-override-file <path>` answers every progress report with that file
///   (`{"recorded":false}` keeps the item on the device).
/// - `-member-import-override-file <path>` answers the one-time import with that file
///   (`{"imported":0,"skipped":0,"refused":[]}`, awe#6565).
/// - `-member-watchlist-override-file <path>` answers `GET /member/watchlist`, and
///   `-member-watchlist-import-override-file <path>` answers its import (awe#6869).
///
/// Each report logs one `[tv] member: progress …` line, so a run shows the cadence. The import
/// logs one `[tv] member: import …` line.
enum DebugMemberHistory {
    static var sessionName: String? {
        guard let name = UserDefaults.standard.string(forKey: "member-session"), !name.isEmpty else { return nil }
        return name
    }

    static func historyAnswer() -> Data? { DebugMemberSignIn.file("member-history-override-file") }
    static func settingsAnswer() -> Data? { DebugMemberSignIn.file("member-settings-override-file") }
    static func progressAnswer() -> Data? { DebugMemberSignIn.file("member-progress-override-file") }
    static func importAnswer() -> Data? { DebugMemberSignIn.file("member-import-override-file") }
    /// `-member-<list>-override-file <path>` answers the saved list (`-member-watchlist-override-file`).
    static func savedItemsAnswer(_ list: SavedList) -> Data? { DebugMemberSignIn.file("member-\(list.rawValue)-override-file") }
    /// `-member-<list>-import-override-file <path>`: the import answers 2xx with no call.
    static func savedImportAnswer(_ list: SavedList) -> Data? { DebugMemberSignIn.file("member-\(list.rawValue)-import-override-file") }

    static func logImport(_ entries: [HistoryImportEntry]) {
        NSLog("[tv] member: import %d entries %@", entries.count, entries.map(\.episodeId).joined(separator: ","))
    }

    static func log(_ report: ProgressReport, episodeId: String) {
        let duration = report.duration.map { String(format: "%.0f", $0) } ?? "null"
        NSLog("[tv] member: progress %@ position %.0f duration %@%@", episodeId, report.position, duration, report.ended ? " ended" : "")
    }
}
#endif

import Foundation

/// Everything this build needs to talk to the App Contract. Bundled at build time; the
/// contract response can never change it.
struct ContractConfig: Equatable {
    var apiBaseURL: URL
    var clientToken: String
    var appSlug: String
    var entityId: String
    var language: String
    var imagesCDN: String
    var imagesBucket: String
}

/// The App Contract client: four routes (manifest, screen, block page, block search), three
/// headers, one origin guard.
struct AppContractClient {
    let config: ContractConfig
    var session: URLSession

    init(config: ContractConfig, session: URLSession? = nil) {
        self.config = config
        self.session = session ?? AppContractClient.makeSession()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ContractLimits.requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func manifestURL() -> URL? {
        url(path: "/v1/app/\(config.appSlug)/manifest", param: nil)
    }

    /// The id is checked BEFORE it is interpolated into the path, so a value from a manifest
    /// or a link can never shape the request.
    func screenURL(id: String, param: String?) -> URL? {
        guard ContractValidator.isObjectId(id) else { return nil }
        return url(path: "/v1/app/\(config.appSlug)/screens/\(id)", param: param)
    }

    /// The next page of one pageable node (awe#5318). Both ids and the page are checked before
    /// they reach the path, like `screenURL`. `param` is the Template Screen's param only.
    func blockURL(screenId: String, nodeId: String, param: String?, page: Int) -> URL? {
        guard ContractValidator.isObjectId(screenId), ContractValidator.isNodeId(nodeId),
              (1...ContractLimits.maxBlockPage).contains(page) else { return nil }
        return url(path: "/v1/app/\(config.appSlug)/screens/\(screenId)/blocks/\(nodeId)", param: param, page: page)
    }

    /// Same `fetch` as a screen: the three headers, the byte cap, the refused redirect and the
    /// origin guard.
    func fetchBlockPage(screenId: String, nodeId: String, param: String?, page: Int) async -> Result<Data, RejectionReason> {
        guard let url = blockURL(screenId: screenId, nodeId: nodeId, param: param, page: page) else {
            return .failure(.transport("cannot build the block page URL"))
        }
        #if DEBUG
        if let data = DebugBlockPageOverride.answer(nodeId: nodeId, page: page) {
            return .success(data)
        }
        #endif
        return await fetch(url)
    }

    /// A `MediaSearch` node's search (awe#5947). Both ids are checked like `blockURL`. The query
    /// is sent trimmed, and only when it holds 2...100 UTF-16 units, the server's (Joi) count.
    func searchURL(screenId: String, nodeId: String, query: String) -> URL? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ContractValidator.isObjectId(screenId), ContractValidator.isNodeId(nodeId),
              ContractLimits.searchQueryLength.contains(query.utf16.count) else { return nil }
        return url(path: "/v1/app/\(config.appSlug)/screens/\(screenId)/blocks/\(nodeId)/search", param: nil, query: query)
    }

    /// Same `fetch` as a screen. The answer is memory only: it never enters the cache.
    func fetchSearch(screenId: String, nodeId: String, query: String) async -> Result<Data, RejectionReason> {
        guard let url = searchURL(screenId: screenId, nodeId: nodeId, query: query) else {
            return .failure(.transport("cannot build the search URL"))
        }
        #if DEBUG
        if let data = DebugSearchOverride.answer() {
            return .success(data)
        }
        #endif
        return await fetch(url)
    }

    func fetchManifest() async -> Result<Data, RejectionReason> {
        guard let url = manifestURL() else { return .failure(.transport("cannot build the manifest URL")) }
        return await fetch(url)
    }

    func fetchScreen(id: String, param: String?) async -> Result<Data, RejectionReason> {
        guard ContractValidator.isObjectId(id) else { return .failure(.malformedScreenId(id)) }
        #if DEBUG
        // Simulator aid: `-screen-override-file <path>` answers the fetch of the screen whose
        // `id` the file names, so a composition can be checked before it is authored.
        // `-screen-override-then <path>` answers every later fetch of that screen (the refresh
        // loop's refetch, 60 s after the first paint), so a changed copy can arrive.
        // `-screen-override-also <path>` answers every fetch of a second screen (an Episode Screen
        // under a card the run presses). The store still applies the byte cap and the decoder.
        // `-screen-override-dir <folder>` answers a Template Screen fetch with `<param>.json` from
        // that folder, so each playlist item can serve its own Episode Screen (Up Next chains).
        if let folder = UserDefaults.standard.string(forKey: "screen-override-dir"), !folder.isEmpty,
           let param, ContractValidator.isObjectId(param),
           let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("\(param).json")),
           (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"].string == id {
            DebugScreenOverride.markOverridden(id)
            return .success(data)
        }
        let served = DebugScreenOverride.count(id)
        for key in (served == 0 ? ["screen-override-file"] : ["screen-override-then", "screen-override-file"]) + ["screen-override-also"] {
            if let path = UserDefaults.standard.string(forKey: key), !path.isEmpty,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"].string == id {
                DebugScreenOverride.markOverridden(id)
                return .success(data)
            }
        }
        #endif
        guard let url = screenURL(id: id, param: param) else {
            return .failure(.transport("cannot build the screen URL"))
        }
        return await fetch(url)
    }

    // MARK: - Request

    private func url(path: String, param: String?, page: Int? = nil, query: String? = nil) -> URL? {
        guard var components = URLComponents(url: config.apiBaseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else { return nil }
        var items = [URLQueryItem(name: "lang", value: config.language)]
        if let param, !param.isEmpty {
            items.append(URLQueryItem(name: "param", value: param))
        }
        if let page {
            items.append(URLQueryItem(name: "page", value: String(page)))
        }
        if let query {
            items.append(URLQueryItem(name: "q", value: query))
        }
        components.queryItems = items
        // `queryItems` leaves `+` as is, and the server reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// The three headers every request carries. `X-AWE-Entity` is the 24-hex id — the
    /// server rejects the slug with 400.
    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(config.clientToken, forHTTPHeaderField: "ClientToken")
        request.setValue("1", forHTTPHeaderField: "X-AWE-App-Contract")
        request.setValue(config.entityId, forHTTPHeaderField: "X-AWE-Entity")
        return request
    }

    private func fetch(_ url: URL) async -> Result<Data, RejectionReason> {
        await send(request(for: url))
    }

    /// Sends a request and reads the response under the byte cap. The member routes use it too
    /// (`MemberClient`), so a session token gets the same guards.
    ///
    /// A redirect is REFUSED, not followed: the ClientToken never travels to a second host.
    /// The origin of the response is checked as well, because a session configured elsewhere
    /// could still follow one. `Content-Length` is checked before the body is read, and the
    /// running total is checked while it is read — a response with no declared length cannot
    /// get past the cap either. Any status outside `accepting` fails as `.httpStatus`.
    func send(_ request: URLRequest, accepting statuses: Set<Int> = [200]) async -> Result<Data, RejectionReason> {
        do {
            let guardDelegate = RedirectRefusal()
            let (stream, response) = try await session.bytes(for: request, delegate: guardDelegate)

            if let location = guardDelegate.refusedLocation {
                return .failure(.redirected(location))
            }

            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("no HTTP response"))
            }
            guard ResponseOrigin.matches(expected: config.apiBaseURL, actual: http.url) else {
                return .failure(.wrongOrigin(ResponseOrigin.origin(of: http.url) ?? "unknown"))
            }
            guard statuses.contains(http.statusCode) else {
                return .failure(.httpStatus(http.statusCode))
            }
            if http.expectedContentLength > 0,
               let refusal = ContractValidator.checkDeclaredLength(http.expectedContentLength) {
                return .failure(refusal)
            }

            var buffer = [UInt8]()
            buffer.reserveCapacity(min(Int(max(http.expectedContentLength, 0)), ContractLimits.maxPayloadBytes))
            for try await byte in stream {
                buffer.append(byte)
                if buffer.count > ContractLimits.maxPayloadBytes {
                    return .failure(.payloadTooLarge(bytes: buffer.count))
                }
            }
            return .success(Data(buffer))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}

/// Refuses every redirect. `nil` from this callback stops the hop and hands back the
/// redirect response itself, which then fails the 200 check.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    private(set) var refusedLocation: String?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        refusedLocation = request.url?.absoluteString ?? "an unnamed host"
        completionHandler(nil)
    }
}

#if DEBUG
/// How often each screen id was fetched, for `-screen-override-then`. Debug builds only.
enum DebugScreenOverride {
    nonisolated(unsafe) private static var fetches: [String: Int] = [:]
    nonisolated(unsafe) private static var overridden = Set<String>()
    private static let lock = NSLock()

    /// A screen answered from a file this launch. Its copy never becomes last-known-good, so a
    /// fixture never outlives the run that asked for it.
    static func markOverridden(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        overridden.insert(id)
    }

    /// A run with a screen override starts from the override, not a cached copy, so the fixture
    /// is the first paint.
    static var skipsCache: Bool {
        ["screen-override-file", "screen-override-also", "screen-override-dir"].contains { !(UserDefaults.standard.string(forKey: $0) ?? "").isEmpty }
            && (UserDefaults.standard.string(forKey: "seed-screen-cache") ?? "").isEmpty
    }

    static func isOverridden(_ id: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return id.map(overridden.contains) ?? false
    }

    /// The fetches before this one, then counts this one.
    static func count(_ id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let served = fetches[id, default: 0]
        fetches[id] = served + 1
        return served
    }
}
#endif

#if DEBUG
/// Simulator aid, like the screen override: `-block-page-override-file <path>` answers the
/// block page whose `nodeId` and `page` the file names, so paging can be checked before the
/// route is deployed. The store still decodes it and checks both. Debug builds only.
enum DebugBlockPageOverride {
    static func answer(nodeId: String, page: Int) -> Data? {
        guard let path = UserDefaults.standard.string(forKey: "block-page-override-file"), !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let body = try? JSONDecoder().decode(JSONValue.self, from: data),
              body["nodeId"].string == nodeId, body["page"].int == page else { return nil }
        return data
    }
}
#endif

#if DEBUG
/// Simulator aid: `-search-override-file <path>` answers every search with that file, so the
/// search block can be checked before the route is deployed. Debug builds only.
enum DebugSearchOverride {
    static func answer() -> Data? {
        guard let path = UserDefaults.standard.string(forKey: "search-override-file"), !path.isEmpty else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}
#endif

#if !DEBUG
/// Release builds have no screen override.
enum DebugScreenOverride {
    static let skipsCache = false
}
#endif

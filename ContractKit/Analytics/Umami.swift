// cspell:ignore isbot
import Foundation

/// `manifest.analytics` (awe#6871): `{ provider: "umami", websiteId, host }`. The server serves it
/// only when the App's analytics is on. Any other provider, an empty `websiteId` or a host that is
/// not https fails the decode, and the manifest then reads it as nil: no event goes out.
struct AnalyticsConfig: Equatable, Decodable {
    let websiteId: String
    let host: URL

    init(websiteId: String, host: URL) {
        self.websiteId = websiteId
        self.host = host
    }

    private enum Keys: String, CodingKey { case provider, websiteId, host }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard try container.decode(String.self, forKey: .provider) == "umami" else {
            throw DecodingError.dataCorruptedError(forKey: .provider, in: container, debugDescription: "not umami")
        }
        websiteId = try container.decode(String.self, forKey: .websiteId)
        guard !websiteId.isEmpty, let host = URL(string: try container.decode(String.self, forKey: .host)),
              host.scheme?.lowercased() == "https", host.host?.isEmpty == false else {
            throw DecodingError.dataCorruptedError(forKey: .host, in: container, debugDescription: "no usable Umami target")
        }
        self.host = host
    }
}

/// The Umami event request, ported from `apps/mobile/src/analytics/umami.ts`. Pure, so it tests
/// without a network.
enum Umami {
    /// A named event: `name` and `data` in the payload. A payload without `name` is a pageview to
    /// Umami. The body carries what the mobile pageview carries, plus the two event fields.
    static func eventRequest(_ config: AnalyticsConfig, name: String, data: [String: String], url: String,
                             language: String, screen: String, userAgent: String) -> URLRequest? {
        let host = config.host.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let payload: [String: Any] = [
            "website": config.websiteId, "url": url, "language": language, "screen": screen, "name": name, "data": data,
        ]
        guard let endpoint = URL(string: "\(host)/api/send"),
              let body = try? JSONSerialization.data(withJSONObject: ["type": "event", "payload": payload]) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    /// A browser-shaped User-Agent. Umami drops every request whose agent `isbot` flags, so the
    /// mobile app sends one too (`appUserAgent`). The platform part lets Umami still read the OS.
    static func userAgent(osVersion: String, appVersion: String) -> String {
        let version = osVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (Apple TV; CPU OS \(version) like Mac OS X) AWEApp/\(appVersion.isEmpty ? "0" : appVersion)"
    }
}

/// Sends one Umami request. Injected, so a test records the request instead.
protocol UmamiSending {
    func send(_ request: URLRequest)
}

/// Fire-and-forget: it never waits for the answer, never retries and keeps no queue. A failed or
/// offline post drops the event; it never blocks or undoes the press that sent it.
struct UmamiSender: UmamiSending {
    let session: URLSession

    init(session: URLSession = UmamiSender.defaultSession) {
        self.session = session
    }

    func send(_ request: URLRequest) {
        session.dataTask(with: request).resume()
    }

    /// No cookies, no credentials, no cache, and a short limit: analytics never holds a socket long.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}

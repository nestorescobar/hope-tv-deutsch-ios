import Foundation

/// Limits enforced on raw bytes, before any parsing.
enum ContractLimits {
    /// The 256 KiB byte cap — invariant 1, shared by all three renderers.
    static let maxPayloadBytes = 256 * 1024
    static let requestTimeout: TimeInterval = 10
    /// The block route takes `page` 1...100.
    static let maxBlockPage = 100
    /// The search route takes a trimmed `q` of 2...100 characters.
    static let searchQueryLength = 2...100
}

/// Why a response or a document was refused. Every path is reported, never swallowed.
enum RejectionReason: Error, Equatable {
    case payloadTooLarge(bytes: Int)
    case declaredPayloadTooLarge(bytes: Int)
    case wrongOrigin(String)
    case wrongAppDesign(String)
    case httpStatus(Int)
    case transport(String)
    case decodeFailed(String)
    case notPlayable(String)
    case malformedScreenId(String)
    case redirected(String)

    var text: String {
        switch self {
        case let .payloadTooLarge(bytes):
            return "response is \(bytes) bytes, over the \(ContractLimits.maxPayloadBytes) byte cap"
        case let .declaredPayloadTooLarge(bytes):
            return "response declares \(bytes) bytes, over the \(ContractLimits.maxPayloadBytes) byte cap"
        case let .wrongOrigin(origin):
            return "response came from \"\(origin)\", not the configured API origin"
        case let .wrongAppDesign(design):
            return "manifest design is \"\(design)\"; this build renders the \"tv\" design only"
        case let .httpStatus(code):
            return "HTTP \(code)"
        case let .transport(message):
            return message
        case let .decodeFailed(detail):
            return "decode failed: \(detail)"
        case let .notPlayable(source):
            return "source \"\(source)\" is not an https stream"
        case let .malformedScreenId(id):
            return "screen id \"\(id)\" is not a 24-hex id"
        case let .redirected(location):
            return "the API redirected to \"\(location)\"; the ClientToken does not follow a hop"
        }
    }
}

/// The four invariants, and nothing else.
///
/// 1. 256 KiB byte cap on raw bytes, checked before parsing.
/// 2. An unknown node renders as absent and logs once (`UnknownBlockLog`).
/// 3. A new manifest activates at a safe boundary (`ContractStore`).
/// 4. Playback sources are https only.
enum ContractValidator {

    /// Invariant 1, on bytes already read.
    static func checkSize(bytes: Int) -> RejectionReason? {
        bytes > ContractLimits.maxPayloadBytes ? .payloadTooLarge(bytes: bytes) : nil
    }

    /// Invariant 1, on the declared `Content-Length`. Refuses before a byte of body is read.
    static func checkDeclaredLength(_ length: Int64) -> RejectionReason? {
        length > Int64(ContractLimits.maxPayloadBytes) ? .declaredPayloadTooLarge(bytes: Int(length)) : nil
    }

    /// A 24-character hex id, ASCII hex checked on the bytes. Every id this renderer puts in a
    /// request path or turns into a route passes here first — a populate that did not run, or a
    /// value the CMS invented, never reaches the wire.
    static func isObjectId(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 24 && bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"),
                 UInt8(ascii: "A")...UInt8(ascii: "F"):
                return true
            default:
                return false
            }
        }
    }

    /// A Craft node id, `^[A-Za-z0-9_-]{1,64}$`, checked on the bytes: no separator, no
    /// percent sign and no non-ASCII letter can reach the block route's path.
    static func isNodeId(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...64).contains(bytes.count) && bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    /// Invariant 4. A non-https source never reaches AVPlayer.
    static func playableURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// This build draws the `tv` design. Another design's preset and palette would render
    /// wrong rather than not at all, so it is refused with a visible error instead.
    static func assertManifestDesign(_ manifest: AppManifest) -> RejectionReason? {
        let design = manifest.app.design ?? ""
        return design == "tv" ? nil : .wrongAppDesign(design)
    }
}

/// The response-origin guard.
///
/// Redirects are followed by URLSession, so the ClientToken and the body are only trusted
/// after the FINAL response URL is checked against the configured API origin.
enum ResponseOrigin {
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    static func matches(expected: URL, actual: URL?) -> Bool {
        guard let expectedOrigin = origin(of: expected), let actualOrigin = origin(of: actual) else { return false }
        return expectedOrigin == actualOrigin
    }
}

/// One line per kind of degraded row, for the whole session. Same "report once" shape as
/// `UnknownBlockLog`, for content a renderer can draw but cannot act on.
enum RenderIssueLog {
    private static var reported = Set<String>()

    @discardableResult
    static func report(_ key: String) -> Bool {
        guard !reported.contains(key) else { return false }
        reported.insert(key)
        return true
    }

    static func reset() { reported.removeAll() }
}

/// Invariant 2's "logs once" half. One line per unknown key, for the whole session.
enum UnknownBlockLog {
    private static var reported = Set<String>()

    /// Returns true the first time a key is seen, so a caller can log exactly once.
    @discardableResult
    static func report(_ key: String) -> Bool {
        guard !reported.contains(key) else { return false }
        reported.insert(key)
        return true
    }

    static func reset() { reported.removeAll() }
}

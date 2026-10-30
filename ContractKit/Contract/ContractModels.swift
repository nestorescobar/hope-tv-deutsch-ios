import Foundation

/// `GET /v1/app/:appSlug/manifest` — the App, its layouts, its screen index and the
/// merged Design Preset.
struct AppManifest: Decodable {
    struct App: Decodable {
        let id: String?
        let slug: String?
        let name: String?
        let design: String?
        let languages: [String]?
        let defaultLanguage: String?
    }

    let contractVersion: Int
    let app: App
    let entryScreenId: String?
    /// The fixed record id a Template Entry Screen opens with. The server sends it as null with
    /// `entryScreenId` when the record is not servable; an older server omits it.
    let entryParam: String?
    let defaultLayoutId: String?
    let layouts: [ManifestLayout]
    let screens: [ManifestScreen]
    /// The merged Design Preset. Read through `Theme`, never as typed fields — the preset
    /// grows server-side and an unknown branch must not fail a decode.
    let preset: JSONValue
    /// `chrome.strings`: the `mobile` UI Translation bag for the request language, merged over
    /// English on the server. Only string values are kept; any other value is dropped, and a
    /// missing or malformed bag is empty. `ChromeText` reads it (the manifest byte cap bounds it).
    let chromeStrings: [String: String]
    /// `chrome.ttlSec`: how long a fetched manifest counts as fresh. It throttles the foreground
    /// refresh. Missing, not an integer, or not above zero reads as the server default, as on mobile.
    let chromeTtlSec: Int
    /// `memberSignIn.enabled` (awe#6563): the App offers TV member sign-in. A hint only, cached per
    /// App generation; the start route is the gate. Missing or malformed reads as off.
    let memberSignIn: Bool
    /// `analytics` (awe#6871): the Umami target of the like events. Served only when the App's
    /// analytics is on; missing or unusable reads as nil, and no event goes out.
    let analytics: AnalyticsConfig?

    /// `DEFAULT_CHROME_TTL_SEC` in `apis/frontend/modules/app/constants.js`.
    static let defaultChromeTtlSec = 300

    private enum Keys: String, CodingKey {
        case contractVersion, app, entryScreenId, entryParam, defaultLayoutId, layouts, screens, preset, chrome, memberSignIn, analytics
    }

    private enum ChromeKeys: String, CodingKey { case strings, ttlSec }
    private enum MemberSignInKeys: String, CodingKey { case enabled }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        contractVersion = (try? container.decode(Int.self, forKey: .contractVersion)) ?? 0
        app = try container.decode(App.self, forKey: .app)
        entryScreenId = try? container.decode(String.self, forKey: .entryScreenId)
        entryParam = try? container.decode(String.self, forKey: .entryParam)
        defaultLayoutId = try? container.decode(String.self, forKey: .defaultLayoutId)
        layouts = (try? container.decode([ManifestLayout].self, forKey: .layouts)) ?? []
        screens = (try? container.decode([ManifestScreen].self, forKey: .screens)) ?? []
        preset = (try? container.decode(JSONValue.self, forKey: .preset)) ?? .null
        let chrome = try? container.nestedContainer(keyedBy: ChromeKeys.self, forKey: .chrome)
        let strings = (try? chrome?.decode([String: JSONValue].self, forKey: .strings)) ?? [:]
        chromeStrings = strings.compactMapValues(\.string)
        let ttl = (try? chrome?.decode(Int.self, forKey: .ttlSec)) ?? 0
        chromeTtlSec = ttl > 0 ? ttl : AppManifest.defaultChromeTtlSec
        let memberSignIn = try? container.nestedContainer(keyedBy: MemberSignInKeys.self, forKey: .memberSignIn)
        self.memberSignIn = (try? memberSignIn?.decode(Bool.self, forKey: .enabled)) ?? false
        analytics = try? container.decode(AnalyticsConfig.self, forKey: .analytics)
    }
}

struct ManifestLayout: Decodable {
    struct Tab: Decodable {
        let screenId: String
        let label: String
        let icon: String?

        private enum Keys: String, CodingKey { case screenId, screen, label, icon }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            // The contract names the field `screenId`; `screen` is accepted because the
            // Button block's `screen` prop carries the same value.
            screenId = (try? container.decode(String.self, forKey: .screenId))
                ?? (try? container.decode(String.self, forKey: .screen))
                ?? ""
            label = (try? container.decode(String.self, forKey: .label)) ?? ""
            icon = try? container.decode(String.self, forKey: .icon)
        }
    }

    struct Navigation: Decodable {
        let tabs: [Tab]

        private enum Keys: String, CodingKey { case tabs }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            tabs = (try? container.decode([Tab].self, forKey: .tabs)) ?? []
        }
    }

    let id: String
    let content: CraftDocument
    let navigation: Navigation

    private enum Keys: String, CodingKey { case id, content, navigation }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        content = (try? container.decode(CraftDocument.self, forKey: .content)) ?? CraftDocument(nodes: [:])
        navigation = (try? container.decode(Navigation.self, forKey: .navigation))
            ?? Navigation(tabs: [])
    }
}

extension ManifestLayout.Navigation {
    init(tabs: [ManifestLayout.Tab]) { self.tabs = tabs }
}

/// A screen's index entry. `kind` decides whether a `param` is required.
struct ManifestScreen: Decodable {
    enum Kind: String, Decodable {
        case `static`
        case template
        /// An unrecognized kind. Treated as a template with no param — it never opens.
        case unsupported
    }

    let id: String
    let kind: Kind
    let resourceType: String?
    let layoutId: String?
    let presentation: String?

    private enum Keys: String, CodingKey { case id, kind, resourceType, layoutId, presentation }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .unsupported
        resourceType = try? container.decode(String.self, forKey: .resourceType)
        layoutId = try? container.decode(String.self, forKey: .layoutId)
        presentation = try? container.decode(String.self, forKey: .presentation)
    }
}

/// `GET /v1/app/:appSlug/screens/:id` — one screen's Craft tree plus its inlined resources.
struct AppScreen: Decodable {
    let id: String
    let content: CraftDocument
    /// `blockResources[nodeId].resources[name]`, flattened to `[nodeId: [name: value]]`.
    let blockResources: [String: [String: JSONValue]]
    /// Screen-level resources: a Template Screen serves its bound record here
    /// (`resources.Episode`).
    let resources: [String: JSONValue]
    let layoutId: String?
    let language: String?
    /// `blockResources[nodeId].paging`, only on the nodes the server lets the shell page
    /// (awe#5318). A node without it is never paged, whatever its type or count.
    let paging: [String: BlockPaging]

    private struct Entry: Decodable {
        let resources: [String: JSONValue]?
        let paging: BlockPaging?

        private enum Keys: String, CodingKey { case resources, paging }

        /// A malformed `paging` reads as none. It never costs the node its resources.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            resources = try container.decodeIfPresent([String: JSONValue].self, forKey: .resources)
            paging = try? container.decode(BlockPaging.self, forKey: .paging)
        }
    }

    private enum Keys: String, CodingKey { case id, content, blockResources, resources, layoutId, language }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        content = (try? container.decode(CraftDocument.self, forKey: .content)) ?? CraftDocument(nodes: [:])
        let entries = (try? container.decode([String: Entry].self, forKey: .blockResources)) ?? [:]
        blockResources = entries.compactMapValues { $0.resources }
        paging = entries.compactMapValues { $0.paging }
        resources = (try? container.decode([String: JSONValue].self, forKey: .resources)) ?? [:]
        layoutId = try? container.decode(String.self, forKey: .layoutId)
        language = try? container.decode(String.self, forKey: .language)
    }
}

/// `{ page, hasMore }` on a pageable node: the last page served, and whether another follows.
struct BlockPaging: Decodable, Equatable {
    let page: Int
    let hasMore: Bool
}

/// `GET /v1/app/:appSlug/screens/:id/blocks/:nodeId?page=` — one more page of one node's list,
/// in the same card shape as page 1. `resources` defaults to empty; the numbers are required.
struct BlockPage: Decodable {
    let nodeId: String
    let page: Int
    let hasMore: Bool
    let resources: [String: JSONValue]

    private enum Keys: String, CodingKey { case nodeId, page, hasMore, resources }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        nodeId = try container.decode(String.self, forKey: .nodeId)
        page = try container.decode(Int.self, forKey: .page)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        resources = (try? container.decode([String: JSONValue].self, forKey: .resources)) ?? [:]
    }
}

enum ContractDecoder {
    static func manifest(_ data: Data) throws -> AppManifest {
        try JSONDecoder().decode(AppManifest.self, from: data)
    }

    static func screen(_ data: Data) throws -> AppScreen {
        try JSONDecoder().decode(AppScreen.self, from: data)
    }

    static func blockPage(_ data: Data) throws -> BlockPage {
        try JSONDecoder().decode(BlockPage.self, from: data)
    }
}

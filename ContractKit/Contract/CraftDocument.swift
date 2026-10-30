import Foundation

/// The block keys this renderer draws.
///
/// A closed enum with `.unsupported`: a key the CMS invents decodes to a known case and
/// renders as absent. It can never reach a renderer, and it can never fail a decode.
enum BlockKey: Hashable {
    case root
    case section
    case container
    case box
    case grid
    case contentPlaceholder
    case simpleText
    case image
    case button
    case richText
    case badge
    case divider
    case header
    case collection
    case collectionTeaser
    case collectionList
    case showList
    case episodesList
    case scheduleLive
    case livestreamPlayer
    case showDetail
    case episodeWatchHistory
    case episodePlayer
    case episodeDetail
    case showMeta
    case mediaSearch
    case mediaLibraryWatchlist
    case moviePlayer
    case movieDetail
    case movieList
    case movieCast
    case movieCrew
    case movieHero
    case movieMeta
    case unsupported(String)

    init(resolvedName: String) {
        self = BlockKey.byName[resolvedName] ?? .unsupported(resolvedName)
    }

    var name: String {
        if case let .unsupported(name) = self { return name }
        return BlockKey.registryKeys.first { BlockKey.byName[$0] == self } ?? "unknown"
    }

    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    /// The committed key list. `Registry/tvRegistryKeys.json` holds the same order and a
    /// test fails when the two drift (ADR-0164 point 4).
    static let registryKeys: [String] = [
        "Root",
        "Section",
        "Container",
        "Box",
        "Grid",
        "ContentPlaceholder",
        "SimpleText",
        "Image",
        "Button",
        "RichText",
        "Badge",
        "Divider",
        "Header",
        "Collection",
        "CollectionTeaser",
        "CollectionList",
        "ShowList",
        "EpisodesList",
        "ScheduleLive",
        "LivestreamPlayer",
        "ShowDetail",
        "EpisodeWatchHistory",
        "EpisodePlayer",
        "EpisodeDetail",
        "ShowMeta",
        "MediaSearch",
        "MediaLibraryWatchlist",
        "MoviePlayer",
        "MovieDetail",
        "MovieList",
        "MovieCast",
        "MovieCrew",
        "MovieHero",
        "MovieMeta",
    ]

    private static let byName: [String: BlockKey] = [
        "Root": .root,
        "Section": .section,
        "Container": .container,
        "Box": .box,
        "Grid": .grid,
        "ContentPlaceholder": .contentPlaceholder,
        "SimpleText": .simpleText,
        "Image": .image,
        "Button": .button,
        "RichText": .richText,
        "Badge": .badge,
        "Divider": .divider,
        "Header": .header,
        "Collection": .collection,
        "CollectionTeaser": .collectionTeaser,
        "CollectionList": .collectionList,
        "ShowList": .showList,
        "EpisodesList": .episodesList,
        "ScheduleLive": .scheduleLive,
        "LivestreamPlayer": .livestreamPlayer,
        "ShowDetail": .showDetail,
        "EpisodeWatchHistory": .episodeWatchHistory,
        "EpisodePlayer": .episodePlayer,
        "EpisodeDetail": .episodeDetail,
        "ShowMeta": .showMeta,
        "MediaSearch": .mediaSearch,
        "MediaLibraryWatchlist": .mediaLibraryWatchlist,
        "MoviePlayer": .moviePlayer,
        "MovieDetail": .movieDetail,
        "MovieList": .movieList,
        "MovieCast": .movieCast,
        "MovieCrew": .movieCrew,
        "MovieHero": .movieHero,
        "MovieMeta": .movieMeta,
    ]
}

/// One node of a Craft node map.
///
/// Every field is optional in the decoder. A half-authored node still decodes; it just
/// draws less.
struct CraftNode: Decodable {
    let resolvedName: String
    let key: BlockKey
    let props: JSONValue
    let custom: JSONValue
    let nodes: [String]
    let linkedNodes: [String: String]
    let hidden: Bool
    let isCanvas: Bool
    let parent: String?

    private enum Keys: String, CodingKey {
        case type, displayName, props, custom, nodes, linkedNodes, hidden, isCanvas, parent
    }

    private struct NodeType: Decodable {
        let resolvedName: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        // `type` is normally `{ resolvedName }`. A plain string is accepted so a
        // hand-written fixture stays readable.
        let typeName = (try? container.decode(NodeType.self, forKey: .type))?.resolvedName
            ?? (try? container.decode(String.self, forKey: .type))
        resolvedName = typeName ?? (try? container.decode(String.self, forKey: .displayName)) ?? ""
        key = BlockKey(resolvedName: resolvedName)
        props = (try? container.decode(JSONValue.self, forKey: .props)) ?? .object([:])
        custom = (try? container.decode(JSONValue.self, forKey: .custom)) ?? .object([:])
        nodes = (try? container.decode([String].self, forKey: .nodes)) ?? []
        linkedNodes = (try? container.decode([String: String].self, forKey: .linkedNodes)) ?? [:]
        hidden = (try? container.decode(Bool.self, forKey: .hidden)) ?? false
        isCanvas = (try? container.decode(Bool.self, forKey: .isCanvas)) ?? false
        parent = try? container.decode(String.self, forKey: .parent)
    }
}

/// A Craft node map, keyed by node id, rooted at `ROOT`.
struct CraftDocument: Decodable {
    static let rootId = "ROOT"

    let nodes: [String: CraftNode]

    init(from decoder: Decoder) throws {
        nodes = try decoder.singleValueContainer().decode([String: CraftNode].self)
    }

    init(nodes: [String: CraftNode]) {
        self.nodes = nodes
    }

    var root: CraftNode? { nodes[CraftDocument.rootId] }

    subscript(id: String) -> CraftNode? { nodes[id] }

    /// Every child id a node draws, linked nodes after positional ones.
    func children(of node: CraftNode) -> [String] {
        node.nodes + node.linkedNodes.keys.sorted().compactMap { node.linkedNodes[$0] }
    }
}

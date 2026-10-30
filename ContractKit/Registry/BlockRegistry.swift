// cspell:ignore magnifyingglass
import Foundation

/// Everything a block may read besides its own props.
struct RenderContext {
    let blockResources: [String: [String: JSONValue]]
    /// The screen-level `resources` (`resources.Episode` on the Episode Screen).
    let screenResources: [String: JSONValue]
    let images: ImageConfig
    /// The App Preset palette, for the block colors a layout block authors (awe#6239).
    let colors: PresetColorResolver
    /// `EpisodeWatchHistory` is client-owned: it has no screen resource. It draws the entries
    /// `WatchHistorySource` picks (device or member copy), or nothing.
    let watchHistory: [WatchProgressStore.Entry]
    /// Device-local resume points by progress key. Client-owned, like `watchHistory`.
    let resumePoints: [String: Double]
    /// Signed in: resume points by episode or movie (awe#6564). nil signed out.
    let memberResumePoints: [WatchHistoryItem: Double]?
    /// `MediaLibraryWatchlist` is client-owned too: the items `SavedItemList` picks (device or
    /// member list), newest first (awe#6869).
    let watchLater: [SavedItem]
    /// Whether a card target opens a screen (`AppRouter.canOpenCard`). A control that could open
    /// nothing is not built, so the view and the default-focus role agree.
    let canOpenCard: (CardTarget) -> Bool

    init(
        blockResources: [String: [String: JSONValue]] = [:],
        screenResources: [String: JSONValue] = [:],
        images: ImageConfig,
        colors: PresetColorResolver = .none,
        watchHistory: [WatchProgressStore.Entry] = [],
        resumePoints: [String: Double] = [:],
        memberResumePoints: [WatchHistoryItem: Double]? = nil,
        watchLater: [SavedItem] = [],
        canOpenCard: @escaping (CardTarget) -> Bool = { _ in true }
    ) {
        self.blockResources = blockResources
        self.screenResources = screenResources
        self.images = images
        self.colors = colors
        self.watchHistory = watchHistory
        self.resumePoints = resumePoints
        self.memberResumePoints = memberResumePoints
        self.watchLater = watchLater
        self.canOpenCard = canOpenCard
    }

    func resource(_ nodeId: String, _ name: String) -> JSONValue? {
        guard let value = blockResources[nodeId]?[name], !value.isNull else { return nil }
        return value
    }
}

/// The block registry.
///
/// This switch is the whole set of things the contract can put on screen. A key the CMS
/// invents cannot reach a renderer: it decodes to `.unsupported`, draws nothing and logs
/// once (invariant 2). The key list is committed as `Registry/tvRegistryKeys.json`.
enum BlockRegistry {
    static var keys: [String] { BlockKey.registryKeys }

    /// How deep a node map may nest. A Root → Section → Container → leaf tree uses four.
    static let maxDepth = 64

    /// Evaluates one node and, for a layout node, its children.
    ///
    /// nil means the node is absent — missing, hidden, or an unknown key. A node with
    /// `content == nil` rendered null.
    static func evaluate(nodeId: String, document: CraftDocument, context: RenderContext) -> EvaluatedNode? {
        var visited = Set<String>()
        return evaluate(nodeId: nodeId, document: document, context: context, visited: &visited, depth: 0)
    }

    /// A node map is a graph, not a proven tree: the server can serve a cycle, a diamond or a
    /// self-parent, and the byte cap does not bound graph depth — a cycle fits in a few bytes.
    /// A node already on this path, or past the depth cap, renders as absent.
    private static func evaluate(
        nodeId: String,
        document: CraftDocument,
        context: RenderContext,
        visited: inout Set<String>,
        depth: Int
    ) -> EvaluatedNode? {
        guard depth < maxDepth else {
            if RenderIssueLog.report("depth-cap") {
                print("[tv] Node map is deeper than \(maxDepth) levels; the rest is not drawn")
            }
            return nil
        }
        guard visited.insert(nodeId).inserted else {
            if RenderIssueLog.report("node-cycle") {
                print("[tv] Node map repeats \(nodeId) on one path; it is not drawn twice")
            }
            return nil
        }
        defer { visited.remove(nodeId) }

        guard let node = document[nodeId], !node.hidden else { return nil }

        guard node.key.isSupported else {
            if UnknownBlockLog.report(node.resolvedName) {
                print("[tv] Unknown block key: \(node.resolvedName)")
            }
            return EvaluatedNode(id: nodeId, key: node.key, content: nil, children: [])
        }

        if node.key == .collectionList {
            // Several shelves from one node: a column of evaluated shelves. Its Craft children
            // are not read. No shelf draws nothing.
            let shelves = collectionListShelves(nodeId: nodeId, node: node, context: context)
            return EvaluatedNode(id: nodeId, key: node.key, content: shelves.isEmpty ? nil : .stack(axis: .vertical),
                                 children: shelves)
        }

        let content = content(for: node, nodeId: nodeId, context: context)
        let children: [EvaluatedNode]

        if content == nil {
            // A block that rendered null never renders its children.
            children = []
        } else {
            let evaluated = document.children(of: node).compactMap {
                evaluate(nodeId: $0, document: document, context: context, visited: &visited, depth: depth + 1)
            }
            // A reverse `direction` draws its children in reversed order. Reversing them here
            // makes D-pad focus, the default focus and the leading hero follow the drawing.
            let reads = [BlockKey.section, .container, .box].contains(node.key)
            children = reads && axis(node.props).reversed ? evaluated.reversed() : evaluated
        }

        return EvaluatedNode(id: nodeId, key: node.key, content: content, children: children)
    }

    // MARK: - Per-key renderers

    /// The responsive breakpoints, smallest first. A responsive prop collapses to its lowest
    /// non-null one.
    private static let breakpoints = ["xs", "sm", "md", "lg", "xl", "2xl", "3xl"]

    /// The `Image` file (awe#6076). The editor saves it to `file`: a plain file, or a responsive
    /// map that collapses to its lowest non-null breakpoint, as the backend `useBaseImageFile`
    /// does. `image` is an old key the editor no longer writes; read it last.
    private static func imageFile(_ props: JSONValue) -> ImageFile? {
        responsiveFile(props["file"]) ?? ImageFile(props["image"])
    }

    /// A plain file, or a responsive map of files collapsed to its lowest non-null breakpoint.
    private static func responsiveFile(_ value: JSONValue) -> ImageFile? {
        ImageFile(value) ?? collapse(value).flatMap(ImageFile.init)
    }

    /// A responsive map → its lowest non-null breakpoint. Any other value passes as it is.
    private static func collapse(_ value: JSONValue) -> JSONValue? {
        guard case .object = value else { return value.isNull ? nil : value }
        return breakpoints.lazy.map { value[$0] }.first { !$0.isNull }
    }

    /// The Background panel of `Section`, `Container` and `Box` (awe#6239): one color and one
    /// image, read as `apps/mobile` reads them (`Box.tsx`, `backgroundLayers`). Mobile's Section
    /// and Container render its Box, so one reader serves all three.
    private static func layoutBackground(_ props: JSONValue, context: RenderContext) -> LayoutBackground? {
        // The editor's Box writes `backgroundColor`. An authored `bgColor` wins, also one that
        // does not resolve; `null` and a cleared `{}` give way.
        let bgColor = authored(props["bgColor"]) ?? props["backgroundColor"]
        // Only a solid type or no type draws the color. The tv editor writes no `bgType`; a node
        // from another design can carry one.
        let bgType = props["bgType"]
        let drawsColor = bgType.isNull || bgType.string == "" || bgType.string == "solid"
        let image = responsiveFile(props["bgImage"]).flatMap { file in
            // A background can span the stage, so it is asked for at the stage width.
            context.images.url(file, width: heroArtWidth).map {
                LayoutBackground.Image(url: $0, alignment: backgroundAlignment(props["bgImageAlign"]))
            }
        }
        return LayoutBackground(color: drawsColor ? color(bgColor, context: context) : nil, image: image)
    }

    /// `direction` of `Section`, `Container` and `Box`, collapsed to its lowest set breakpoint as
    /// mobile reads it: `x` and `x-reverse` are a row; `y`, `y-reverse` and no value a column. A
    /// reverse value draws the children in reversed order (CSS `row-reverse`, `column-reverse`).
    private static func axis(_ props: JSONValue) -> (axis: BlockContent.Axis, reversed: Bool) {
        switch collapse(props["direction"])?.string {
        case "x": return (.horizontal, false)
        case "x-reverse": return (.horizontal, true)
        case "y-reverse": return (.vertical, true)
        default: return (.vertical, false)
        }
    }

    /// The layout styling of `Section`, `Container` and `Box` (awe#6297), read as mobile
    /// `blocks/styles.ts` reads it, for all three blocks. A value that does not map is not drawn:
    /// never a guessed 0, never a fallback color (ADR-0122).
    private static func layoutStyle(_ props: JSONValue, context: RenderContext) -> LayoutStyle {
        let padding = props["padding"]
        let corners = props["borderRadius"]
        return LayoutStyle(
            padding: LayoutStyle.Insets(top: scaleStep(padding["top"]) ?? 0, right: scaleStep(padding["right"]) ?? 0,
                                        bottom: scaleStep(padding["bottom"]) ?? 0, left: scaleStep(padding["left"]) ?? 0),
            minHeight: length(props["minHeight"]),
            height: customHeight(props["height"]),
            align: keyword(props["align"], flexAligns) ?? .stretch,
            justify: keyword(props["justify"], flexJustify) ?? .start,
            border: border(props["border"], context: context),
            radius: LayoutStyle.Corners(topLeft: keyword(corners["tl"], borderRadii) ?? 0,
                                        topRight: keyword(corners["tr"], borderRadii) ?? 0,
                                        bottomLeft: keyword(corners["bl"], borderRadii) ?? 0,
                                        bottomRight: keyword(corners["br"], borderRadii) ?? 0)
        )
    }

    /// A responsive keyword prop → its value in `map`. nil for an unknown or absent keyword.
    private static func keyword<T>(_ value: JSONValue, _ map: [String: T]) -> T? {
        collapse(value)?.string.flatMap { map[$0] }
    }

    private static let flexAligns: [String: LayoutStyle.Align] = [
        "start": .start, "center": .center, "end": .end, "baseline": .baseline, "stretch": .stretch,
    ]

    private static let flexJustify: [String: LayoutStyle.Justify] = [
        "start": .start, "center": .center, "end": .end, "between": .between, "around": .around, "evenly": .evenly,
    ]

    /// `AWEBorderWidth` in points; `xs` is the bare Tailwind `border`.
    private static let borderWidths: [String: CGFloat] = ["none": 0, "xs": 1, "sm": 2, "md": 4, "lg": 8]

    private static let borderLines: [String: LayoutStyle.Border.Line] = ["solid": .solid, "dashed": .dashed, "dotted": .dotted]

    /// `AWEBorderRadius` in points (mobile `BORDER_RADII`). `full` is a pill.
    private static let borderRadii: [String: CGFloat] = [
        "none": 0, "xs": 2, "sm": 4, "base": 4, "md": 6, "lg": 8, "xl": 12, "2xl": 16, "3xl": 24, "full": 9999,
    ]

    /// The `padding` aliases (`apps/backend/app/designs/common/settings/paddings.js`).
    private static let paddingAliases: [String: String] = [
        "zero": "0", "none": "0", "pixel": "px", "2xs": "0.5", "xs": "1", "sm": "2", "md": "4", "lg": "8",
        "xl": "16", "2xl": "24", "3xl": "32",
    ]

    /// `border { width: { t, r, b, l }, color, style }` (mobile `borderStyle`). `style: none` drops
    /// the whole border. A border needs one width above 0 and a color that resolves; with no color
    /// it draws nothing (mobile draws the RN default black).
    private static func border(_ value: JSONValue, context: RenderContext) -> LayoutStyle.Border? {
        let line = collapse(value["style"])?.string
        guard line != "none" else { return nil }
        let width = value["width"]
        let widths = LayoutStyle.Insets(top: keyword(width["t"], borderWidths) ?? 0,
                                        right: keyword(width["r"], borderWidths) ?? 0,
                                        bottom: keyword(width["b"], borderWidths) ?? 0,
                                        left: keyword(width["l"], borderWidths) ?? 0)
        guard max(widths.top, widths.right, widths.bottom, widths.left) > 0,
              let color = color(value["color"], context: context) else { return nil }
        // RN paints solid for no style and for one it cannot paint (`double`).
        return LayoutStyle.Border(widths: widths, color: color, line: line.flatMap { borderLines[$0] } ?? .solid)
    }

    /// A spacing-scale step → points (mobile `toScaleDp`): an alias, else a unitless step × 4; `px`
    /// is 1. A unit, a negative step or anything else is nil.
    private static func scaleStep(_ value: JSONValue) -> CGFloat? {
        guard let leaf = collapse(value) else { return nil }
        let token = leaf.string.flatMap { paddingAliases[$0] }.map(JSONValue.string) ?? leaf
        if token.string?.trimmingCharacters(in: .whitespaces) == "px" { return 1 }
        guard let (amount, unit) = magnitude(token), unit.isEmpty, amount >= 0 else { return nil }
        return amount * 4
    }

    /// A CSS length → points: px and unitless 1:1, rem 16 (mobile `toDp`), and, on tvOS only, vw
    /// and vh as a share of the 1920 x 1080 stage. A zero is 0 in any unit. `%`, `em`, a negative
    /// and any other unit are nil: a screen scrolls, so a percent has no parent height to read.
    private static func length(_ value: JSONValue) -> CGFloat? {
        guard let leaf = collapse(value), let (amount, unit) = magnitude(leaf) else { return nil }
        if amount == 0 { return 0 }
        guard amount > 0 else { return nil }
        switch unit {
        case "", "px": return amount
        case "rem": return amount * 16
        case "vw": return amount * Layout.stageWidth / 100
        case "vh": return amount * Layout.stageHeight / 100
        default: return nil
        }
    }

    /// The Box `height`, `AWECustomHeight { value, unit }` (mobile `customHeightLeaf`): `px` and
    /// `rem` join the value; any other unit leaves the value as it is.
    private static func customHeight(_ value: JSONValue) -> CGFloat? {
        guard case .object = value, let leaf = collapse(value["value"]) else { return nil }
        guard let unit = value["unit"].string, unit == "px" || unit == "rem" else { return length(leaf) }
        guard let text = leaf.string ?? leaf.double.map({ "\($0)" }) else { return nil }
        return length(.string(text + unit))
    }

    /// Built once: `magnitude` runs for every length prop on every evaluation.
    private static let magnitudePattern = #/(-?(?:\d+\.?\d*|\.\d+))([a-zA-Z%]*)/#

    /// One number and its unit (mobile `parseMagnitude`): `12`, `"2.5rem"`, `" 50vh "`. The unit
    /// is lower-cased; `""` is unitless. A text longer than 32 characters is not a length.
    private static func magnitude(_ value: JSONValue) -> (amount: CGFloat, unit: String)? {
        if let number = value.double { return number.isFinite ? (CGFloat(number), "") : nil }
        guard let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 32,
              let match = text.wholeMatch(of: magnitudePattern),
              let amount = Double(match.1) else { return nil }
        return (CGFloat(amount), match.2.lowercased())
    }

    /// A color prop (a token, maybe responsive) through the App Preset palette.
    private static func color(_ value: JSONValue, context: RenderContext) -> RGBAColor? {
        context.colors.color(collapse(value)?.string)
    }

    /// `null` and `{}` (the editor's cleared prop) are not authored, as mobile `authored` reads them.
    private static func authored(_ value: JSONValue) -> JSONValue? {
        if case let .object(fields) = value, fields.isEmpty { return nil }
        return value.isNull ? nil : value
    }

    /// `bgImageAlign` → where the cover-sized image sits (mobile `backgroundGeometry.ts`
    /// `ALIGNMENTS`). `custom` reads `bgImagePosition`, which the tv design does not offer, so it
    /// centers, as an unknown or absent key does.
    private static func backgroundAlignment(_ value: JSONValue) -> BackgroundAlignment {
        collapse(value)?.string.flatMap { backgroundAlignments[$0] } ?? .center
    }

    private static let backgroundAlignments: [String: BackgroundAlignment] = [
        "top left": BackgroundAlignment(x: 0, y: 0),
        "top": BackgroundAlignment(x: 0.5, y: 0),
        "top right": BackgroundAlignment(x: 1, y: 0),
        "center left": BackgroundAlignment(x: 0, y: 0.5),
        "center": .center,
        "center right": BackgroundAlignment(x: 1, y: 0.5),
        "bottom left": BackgroundAlignment(x: 0, y: 1),
        "bottom": BackgroundAlignment(x: 0.5, y: 1),
        "bottom right": BackgroundAlignment(x: 1, y: 1),
    ]

    private static func content(for node: CraftNode, nodeId: String, context: RenderContext) -> BlockContent? {
        switch node.key {
        case .root, .grid:
            return .stack(axis: .vertical)

        case .section, .container, .box:
            let direction = axis(node.props)
            var style = layoutStyle(node.props, context: context)
            // A reverse direction starts at the right or bottom edge: `start` and `end` swap.
            if direction.reversed {
                switch style.justify {
                case .start: style.justify = .end
                case .end: style.justify = .start
                case .center, .between, .around, .evenly: break
                }
            }
            return .stack(axis: direction.axis, background: layoutBackground(node.props, context: context),
                          style: style)

        case .contentPlaceholder:
            // A color only, as mobile's `ContentPlaceholder` reads it: no `bgType` gate, no image.
            return .contentSlot(background: LayoutBackground(color: color(node.props["bgColor"], context: context),
                                                             image: nil))

        case .simpleText:
            guard let text = node.props["text"].text else { return nil }
            return .text(TextModel(text: text, as: node.props["as"].string))

        case .image:
            guard let file = imageFile(node.props),
                  let url = context.images.url(file, width: node.props["width"].int ?? 960) else { return nil }
            return .image(ImageModel(url: url, blurhash: file.blurhash))

        case .button:
            return .button(ButtonModel(
                label: node.props["label"].text ?? ChromeText.string(.open),
                screenId: node.props["screen"].text,
                screenParam: node.props["screenParam"].text,
                linkType: node.props["linkType"].string,
                disabled: node.props["disabled"].bool ?? false
            ))

        case .richText:
            // A field binding (`source`) is not resolved on TV, as for `SimpleText`: the
            // authored doc draws.
            return RichTextReader.model(node.props["doc"]).map(BlockContent.richText)

        case .badge:
            // The `screen` link is ignored: the D-pad cannot reach a badge.
            guard let label = node.props["label"].text else { return nil }
            return .badge(BadgeModel(label: label, symbol: badgeSymbol(node.props["icon"].string)))

        case .divider:
            // As on web and mobile: nothing until a height resolves.
            let height = node.props["height"]
            guard let key = height.string ?? breakpoints.lazy.compactMap({ height[$0].string }).first,
                  let thickness = dividerThickness[key], thickness > 0 else { return nil }
            return .divider(DividerModel(thickness: thickness))

        case .header:
            return header(node.props)

        case .collection:
            return collectionShelf(nodeId: nodeId, node: node, resourceName: "collection",
                                   fallbackTitle: ChromeText.string(.collection), allowsGrid: true, context: context)

        case .collectionTeaser:
            return collectionShelf(nodeId: nodeId, node: node, resourceName: "collectionTeaser",
                                   fallbackTitle: ChromeText.string(.featured), context: context)

        case .collectionList:
            // `evaluate` builds it: one child shelf per Collection.
            return nil

        case .showList:
            let shows = context.resource(nodeId, "shows")
            let items = shows?["items"].array ?? []
            let count = shows?["count"].int ?? items.count
            return .shelf(ShelfModel(
                nodeId: nodeId,
                title: items.isEmpty
                    ? ChromeText.string(.shows)
                    : ChromeText.string(.showsWithCount, ["count": "\(count)"]),
                cards: items.enumerated().map {
                    showCard(nodeId: nodeId, index: $0.offset, show: $0.element, context: context)
                },
                layout: .grid,
                emptyMessage: items.isEmpty ? ChromeText.string(.noShows) : nil
            ))

        case .movieList:
            // `movies` `{ items, count }` (awe#6870). Poster cards in both layouts: `layout: "grid"`
            // draws a poster grid, any other value a row. An item with no poster draws a landscape
            // card. An empty list draws nothing: the server also serves one when the `movies` flag is off.
            // Only the grid pages, so only the grid names the count; a row shows the first page only (awe#7032).
            let movies = context.resource(nodeId, "movies")
            let items = movies?["items"].array ?? []
            guard !items.isEmpty else { return nil }
            let layout: ShelfModel.Layout = node.props["layout"].string == "grid" ? .grid : .row
            let cardStyle = ShelfModel.CardStyle.posters
            return .shelf(ShelfModel(
                nodeId: nodeId,
                title: layout == .grid
                    ? ChromeText.string(.moviesWithCount, ["count": "\(movies?["count"].int ?? items.count)"])
                    : ChromeText.string(.movies),
                cards: items.enumerated().map {
                    movieCard(nodeId: nodeId, index: $0.offset, movie: $0.element, context: context, cardStyle: cardStyle)
                },
                layout: layout,
                cardStyle: cardStyle,
                emptyMessage: nil
            ))

        case .episodesList:
            // `episodes` is a list resource `{ items, count }` (Frontend API
            // `modules/media-library/blocks/EpisodesList`), inlined with the first page. The
            // heading is the block's own `title` prop, as on the web; empty draws none.
            // `layout: "list"` draws one row per episode; any other value draws the grid. The
            // duration draws only when the author turns on `showDuration`.
            let episodes = context.resource(nodeId, "episodes")
            let items = episodes?["items"].array ?? []
            let cards = items.enumerated().map {
                episodeCard(nodeId: nodeId, index: $0.offset, episode: $0.element,
                            context: context, style: .grid,
                            showDuration: node.props["showDuration"].bool == true)
            }
            return .shelf(ShelfModel(
                nodeId: nodeId,
                title: node.props["title"].text,
                cards: cards,
                layout: node.props["layout"].string == "list" ? .list : .grid,
                emptyMessage: items.isEmpty ? ChromeText.string(.noEpisodes) : nil,
                seasons: seasonFilter(context.resource(nodeId, "show"), cards: cards),
                titleLines: 2
            ))

        case .scheduleLive:
            return schedule(node: node, nodeId: nodeId, context: context)

        case .livestreamPlayer:
            let channel = context.resource(nodeId, "channel")
            // Its own `broadcastsLive` feeds the full-screen Schedule tab (awe#6553). An old
            // server serves none: the player opens with no tab.
            let broadcasts = context.resource(nodeId, "broadcastsLive")
            let schedule = scheduleEntries(broadcasts, nodeId: nodeId, context: context)
            guard let request = PlaybackService.liveRequest(channel, images: context.images, schedule: schedule) else {
                return .message(ChromeText.string(.noLiveStream))
            }
            // The card draws the on-air image across the stage, so its rows ask for stage-width art.
            let posters = scheduleEntries(broadcasts, nodeId: nodeId, context: context, imageWidth: Int(Layout.stageWidth))
            return .player(PlayerModel(nodeId: nodeId, request: request, broadcasts: posters))

        case .episodePlayer:
            // Never plays inline (ruled 2026-09-23): the poster and Play / Resume open the
            // full-screen player. No resource is no episode, and draws nothing. A served one
            // that names no source this device can play (YouTube, Vimeo, Jetstream live) says so.
            guard let resource = context.resource(nodeId, "episodePlayer") else { return nil }
            let metadata = PlaybackMetadata.episode(
                context.screenResources["Episode"] ?? .null,
                blockResources: context.blockResources,
                poster: resource["poster"].string,
                images: context.images
            )
            return playAction(nodeId: nodeId, resource: resource, metadata: metadata, playlist: Playlist(resource),
                              related: RelatedEpisodes(context.resource(nodeId, "relatedEpisodes")),
                              cannotPlay: .cannotPlayEpisode, context: context)

        case .moviePlayer:
            // `EpisodePlayer` with no playlist (awe#6270): the same source rule, never inline.
            // `{ error: 'NO_SOURCE' }` names no provider, so it draws the message. Progress follows the
            // episode rule by `movieId`: the device signed out, the member's server copy signed in.
            guard let resource = context.resource(nodeId, "moviePlayer") else { return nil }
            let metadata = PlaybackMetadata.movie(
                context.screenResources["Movie"] ?? .null,
                blockResources: context.blockResources,
                poster: resource["poster"].string,
                images: context.images
            )
            return playAction(nodeId: nodeId, resource: resource, metadata: metadata, playlist: nil,
                              related: nil, cannotPlay: .cannotPlayMovie, context: context)

        case .movieDetail:
            return movieDetail(node: node, nodeId: nodeId, context: context)

        case .movieCast:
            return movieCast(nodeId: nodeId, context: context)

        case .movieCrew:
            // Always tiles: tvOS never draws the web `credits` table, whatever `displayMode` says.
            return movieCrew(nodeId: nodeId, context: context)

        case .movieHero:
            return movieHero(node: node, nodeId: nodeId, context: context)

        case .movieMeta:
            return movieMetaRows(node: node, nodeId: nodeId, context: context)

        case .episodeDetail:
            // Text only, as the web block draws it. Every prop defaults to on, as the builder's
            // `EpisodeDetail.craft.props` do.
            guard let detail = context.resource(nodeId, "episodeDetail") else { return nil }
            let shows = { (prop: String) in node.props[prop].bool != false }
            let views = detail["episodeViews"].int ?? 0
            let show = detail["show"]
            let title = shows("showTitle") ? detail["title"].text : nil
            let showTitle = shows("showShowTitle") ? show["title"].text : nil
            let drawsHeading = title != nil || showTitle != nil
            // Watch later (awe#6869) and Like (awe#6871) share the snapshot, heading group only, as Go to show.
            // An episode the screen's player cannot play here offers neither.
            let saved = drawsHeading && !cannotPlay("episodePlayer", context: context)
                ? savable(.episode, id: detail["_id"].text ?? detail["id"].text,
                          title: detail["title"].text ?? ChromeText.string(.untitled),
                          image: ImageFile(detail["image"]) ?? ImageCatalog.pick(detail["images"]), context: context)
                : nil
            return .episodeDetail(EpisodeDetailModel(
                title: title,
                showTitle: showTitle,
                views: shows("showViews") && views > 0 ? views : nil,
                abstract: shows("showAbstract") ? detail["abstract"].text : nil,
                paragraphs: shows("showBody") ? tiptapParagraphs(detail["body"]) : [],
                // Opens the show like a show card: the convention, by the show's id. Only the
                // instance that draws the heading offers it, so a second, body-only instance on
                // the same screen draws no second button.
                showTarget: drawsHeading
                    ? CardTarget.show(id: show["_id"].text ?? show["id"].text).flatMap { context.canOpenCard($0) ? $0 : nil }
                    : nil,
                // Served already resolved (Episode, else Show; the language also falls back to
                // the channel), so the block draws them as served. Heading group only, as above.
                ageRating: drawsHeading ? AgeRatingFormat.primaryLabel(detail["ageRatings"]) : nil,
                language: drawsHeading ? detail["language"].text : nil,
                watchLater: saved,
                like: saved
            ))

        case .showDetail:
            return showDetail(node: node, nodeId: nodeId, context: context)

        case .showMeta:
            return showMeta(node: node, nodeId: nodeId, context: context)

        case .episodeWatchHistory:
            // No screen resource by design (spec §8 Q4): the entries come from `WatchHistorySource`.
            // Nothing watched yet draws nothing.
            guard !context.watchHistory.isEmpty else { return nil }
            let showDuration = node.props["showDuration"].bool == true
            return .shelf(ShelfModel(
                nodeId: nodeId,
                title: node.props["title"].text ?? ChromeText.string(.keepWatching),
                cards: context.watchHistory.prefix(node.props["pageSize"].int ?? 6).map {
                    watchHistoryCard($0, showDuration: showDuration)
                },
                layout: .row,
                emptyMessage: nil
            ))

        case .mediaSearch:
            // The view asks the search route for this node (awe#5947). The one resource is the
            // tiles for an empty field (awe#5956).
            return .mediaSearch(MediaSearchModel(nodeId: nodeId, tiles: collectionTiles(nodeId: nodeId, context: context)))

        case .mediaLibraryWatchlist:
            // Watch later (awe#6869): client-owned like `EpisodeWatchHistory`, no screen resource.
            // An empty list hides the whole block. `showTitle` defaults to on, as the builder's
            // `MediaLibraryWatchlist.craft.props` do; an empty `title` draws "Watch later".
            guard !context.watchLater.isEmpty else { return nil }
            return .shelf(ShelfModel(
                nodeId: nodeId,
                title: node.props["showTitle"].bool == false ? nil : node.props["title"].text ?? ChromeText.string(.watchLater),
                cards: context.watchLater.map(savedCard),
                layout: .row,
                emptyMessage: nil
            ))

        case .unsupported:
            return nil
        }
    }

    /// A search answer `{ episodes, shows }` as two grids (awe#5947). Each item has the shape of
    /// an `EpisodesList` or `ShowList` item, so the list card readers build it, served link
    /// included. A record served twice draws once, because card ids key the grid. A group with
    /// no items draws no grid.
    static func searchResults(_ answer: JSONValue, nodeId: String, context: RenderContext) -> MediaSearchResults {
        let episodes = answer["episodes"].array.enumerated().map {
            // `.shelf`: results mix shows, so the card names its show beside the duration.
            // `MediaSearch` has no `showDuration` setting, so the duration always draws.
            episodeCard(nodeId: nodeId, index: $0.offset, episode: $0.element, context: context, style: .shelf,
                        showDuration: true)
        }
        let shows = answer["shows"].array.enumerated().map {
            showCard(nodeId: nodeId, index: $0.offset, show: $0.element, context: context)
        }
        let grid = { (suffix: String, title: ChromeText.Key, cards: [CardModel], lines: Int) -> ShelfModel? in
            var seen = Set<String>()
            let unique = cards.filter { seen.insert($0.id).inserted }
            guard !unique.isEmpty else { return nil }
            return ShelfModel(nodeId: "\(nodeId)-\(suffix)", title: ChromeText.string(title), cards: unique,
                              layout: .grid, emptyMessage: nil, titleLines: lines)
        }
        return MediaSearchResults(
            episodes: grid("episodes", .episodesLabel, episodes, 2),
            shows: grid("shows", .shows, shows, 1)
        )
    }

    // MARK: - Resource readers

    /// `collectionTiles` `{ items: [{ _id, title, image, screenLink? }] }` (awe#5956). Each tile
    /// opens its Collection like a card: the served link, else the convention. `image` is the
    /// stored File Manager object the editor picked, so its URL is built as the `Image` block's.
    /// A Collection served twice draws once, because card ids key the grid.
    private static func collectionTiles(nodeId: String, context: RenderContext) -> [CardModel] {
        var seen = Set<String>()
        return (context.resource(nodeId, "collectionTiles")?["items"].array ?? []).enumerated().compactMap { index, tile in
            let recordId = tile["_id"].text ?? tile["id"].text
            let file = ImageFile(tile["image"])
            let card = CardModel(
                id: recordId ?? "\(nodeId):tile:\(index)",
                title: tile["title"].text ?? ChromeText.string(.untitled),
                subtitle: nil,
                imageURL: context.images.url(file, width: 640),
                blurhash: file?.blurhash,
                badge: nil,
                progress: nil,
                target: target(resourceType: "collection", itemId: recordId, link: ScreenLink(tile["screenLink"]))
            )
            return seen.insert(card.id).inserted ? card : nil
        }
    }

    private static func collectionShelf(
        nodeId: String,
        node: CraftNode,
        resourceName: String,
        fallbackTitle: String,
        allowsGrid: Bool = false,
        context: RenderContext
    ) -> BlockContent? {
        guard let collection = context.resource(nodeId, resourceName) else { return nil }
        // Only `Collection` reads its `layout` prop; `CollectionTeaser`'s web prop is out of scope.
        return collectionShelf(collection, nodeId: nodeId, props: node.props,
                               blockLayout: allowsGrid ? node.props["layout"].string : nil,
                               fallbackTitle: fallbackTitle, context: context)
    }

    /// One served Collection record as one shelf: a `Collection`, a `CollectionTeaser`, or one
    /// record of a `CollectionList`. `props` are the block's own. `blockLayout` is the block
    /// `layout` prop where the TV builder offers it, else nil.
    private static func collectionShelf(
        _ collection: JSONValue,
        nodeId: String,
        props: JSONValue,
        blockLayout: String?,
        fallbackTitle: String,
        context: RenderContext
    ) -> BlockContent? {
        // The record keeps several arrays; one its `contentType` does not name can hold raw ids
        // (a show filter on an episodes Collection), so `contentType` picks the list. Without
        // it, `shows` when not empty, else `episodes`, as before. A `mixed` record lists typed
        // items in `items`. A type this build does not know draws nothing, so a new type on the
        // server cannot break the screen.
        let listKey: String
        switch collection["contentType"].string {
        case "shows": listKey = "shows"
        case "episodes": listKey = "episodes"
        case "movies": listKey = "movies"
        case "mixed": listKey = "items"
        case "continueWatching":
            return continueWatchingShelf(collection, nodeId: nodeId, props: props, blockLayout: blockLayout,
                                         context: context)
        case nil: listKey = collection["shows"].array.isEmpty ? "episodes" : "shows"
        case let other?:
            if RenderIssueLog.report("collection-type-\(other)") {
                print("[tv] Collection type \"\(other)\" is not drawn on TV")
            }
            return nil
        }
        let hideTitle = props["hideTitle"].bool == true || collection["hideTitle"].bool == true
        var layout = ShelfModel.Layout.resolve(block: blockLayout, record: collection["listLayout"].string)
        // A paged grid ignores the record's card style, so a hero record never draws a hero. A
        // movies grid draws posters, as the `MovieList` grid does (awe#7033). Every other record
        // draws landscape cards (awe#5982 D3). Else the block prop wins over the record's
        // `layout` (ruled).
        let gridStyle: ShelfModel.CardStyle = listKey == "movies" ? .posters : .cards
        let cardStyle = layout == .grid ? gridStyle : ShelfModel.CardStyle.resolve(
            prop: props["itemLayout"].string,
            record: collection["layout"].string
        )
        // A hero or a banner row is always a row, never cards in a sideways grid.
        if layout == .sidewaysGrid, cardStyle == .hero || cardStyle == .banner { layout = .row }
        // A hero draws only an authored title, never the renderer's fallback over its art. A
        // banner row is a normal row and takes the fallback.
        let title = hideTitle ? nil : (collection["title"].text ?? (cardStyle == .hero ? nil : fallbackTitle))

        // The duration draws only when the author turns on `showDuration` (awe#6055).
        let showDuration = props["showDuration"].bool == true
        let episode = { (index: Int, item: JSONValue) in
            episodeCard(nodeId: nodeId, index: index, episode: item,
                        context: context, style: .shelf, cardStyle: cardStyle, showDuration: showDuration)
        }
        let movie = { (index: Int, item: JSONValue) in
            movieCard(nodeId: nodeId, index: index, movie: item, context: context, cardStyle: cardStyle)
        }
        let show = { (index: Int, item: JSONValue) in
            showCard(nodeId: nodeId, index: index, show: item, context: context, cardStyle: cardStyle)
        }
        var cards: [CardModel] = collection[listKey].array.enumerated().compactMap { index, item in
            switch listKey {
            case "episodes": return episode(index, item)
            case "movies": return movie(index, item)
            case "shows": return show(index, item)
            default:
                // A `mixed` item names its own type and has that type's list shape. An unknown
                // type is dropped.
                switch item["type"].string {
                case "episode": return episode(index, item)
                case "movie": return movie(index, item)
                case "show": return show(index, item)
                default: return nil
                }
            }
        }
        if listKey == "items" {
            // Card ids key the shelf, and the server does not stop an author from adding one item
            // twice. The first one stays.
            var seen = Set<String>()
            cards = cards.filter { seen.insert($0.id).inserted }
        }

        if cards.isEmpty {
            return .shelf(ShelfModel(nodeId: nodeId, title: title, cards: [], layout: layout,
                                     cardStyle: cardStyle, emptyMessage: ChromeText.string(.nothingToWatch)))
        }
        return .shelf(ShelfModel(nodeId: nodeId, title: title, cards: cards, layout: layout,
                                 cardStyle: cardStyle, emptyMessage: nil))
    }

    /// A Continue watching Collection is client-owned, like `EpisodeWatchHistory`. The served
    /// `entries` are ignored (always `[]` on the App Contract): the cards are the entries
    /// `WatchHistorySource` picks. Signed out, it draws only when the record has `showToGuests`.
    /// An empty list draws nothing. It never pages.
    private static func continueWatchingShelf(
        _ collection: JSONValue,
        nodeId: String,
        props: JSONValue,
        blockLayout: String?,
        context: RenderContext
    ) -> BlockContent? {
        let signedIn = context.memberResumePoints != nil
        guard signedIn || collection["showToGuests"].bool == true else { return nil }
        // The block `limit`, else the record `maxItems`. Never more than the source holds.
        let limit = [props["limit"].int, collection["maxItems"].int].compactMap { $0 }.first { $0 > 0 }
        let entries = context.watchHistory.prefix(limit ?? context.watchHistory.count)
        guard !entries.isEmpty else { return nil }
        let hideTitle = props["hideTitle"].bool == true || collection["hideTitle"].bool == true
        let showDuration = props["showDuration"].bool == true
        // A history entry keeps one landscape image, so the cards are always landscape. A
        // carousel reads as a row.
        return .shelf(ShelfModel(
            nodeId: nodeId,
            title: hideTitle ? nil : collection["title"].text ?? ChromeText.string(.keepWatching),
            cards: entries.map { watchHistoryCard($0, showDuration: showDuration) },
            layout: ShelfModel.Layout.resolve(block: blockLayout, record: collection["listLayout"].string),
            emptyMessage: nil
        ))
    }

    /// `CollectionList` (`collections { items, count }`): one shelf per served Collection, in
    /// served order. TV does not read the block's own `layout` prop: each record's `listLayout`
    /// decides. No paging. A card opens the served `screenLink` (the block's Screen pickers), else
    /// the convention. A shelf id is
    /// `<nodeId>-<Collection id>`, unique and stable across refetches. A record served twice
    /// draws once. A record with no card to draw (a `mixed` record of unknown item types) is
    /// left out, as the server and the web leave out an empty Collection.
    private static func collectionListShelves(nodeId: String, node: CraftNode, context: RenderContext) -> [EvaluatedNode] {
        var seen = Set<String>()
        let items = context.resource(nodeId, "collections")?["items"].array ?? []
        return items.enumerated().compactMap { index, collection in
            let id = "\(nodeId)-\(collection["_id"].text ?? collection["id"].text ?? "\(index)")"
            guard seen.insert(id).inserted,
                  let content = collectionShelf(collection, nodeId: id, props: node.props, blockLayout: nil,
                                                fallbackTitle: ChromeText.string(.collection), context: context),
                  case let .shelf(model) = content, !model.cards.isEmpty
            else { return nil }
            return EvaluatedNode(id: id, key: .collectionList, content: content, children: [])
        }
    }

    private static func schedule(node: CraftNode, nodeId: String, context: RenderContext) -> BlockContent {
        let channel = context.resource(nodeId, "channel")
        let entries = scheduleEntries(context.resource(nodeId, "broadcastsLive"), nodeId: nodeId, context: context)

        return .schedule(ScheduleModel(
            // The block's own `title` prop, as the EpisodesList heading is.
            // Only an empty prop falls back to the renderer's "On <channel>" label.
            title: node.props["title"].text
                ?? channel?["title"].text.map { ChromeText.string(.onChannel, ["name": $0]) }
                ?? ChromeText.string(.onNow),
            entries: entries,
            emptyMessage: entries.isEmpty ? ChromeText.string(.noSchedule) : nil,
            // The same channel record and request as `LivestreamPlayer` (invariant 4 included).
            // The full-screen Schedule tab lists the rows this block loaded (awe#6553).
            live: PlaybackService.liveRequest(channel, images: context.images, schedule: entries)
        ))
    }

    /// The rows of a `broadcastsLive` resource, as served: `current` first when it is an object
    /// (as on the web `ScheduleLive`, awe#5033), then `items`. One reader for `ScheduleLive` and
    /// the `LivestreamPlayer` Schedule tab (awe#6553).
    private static func scheduleEntries(
        _ broadcasts: JSONValue?, nodeId: String, context: RenderContext, imageWidth: Int = 640
    ) -> [ScheduleModel.Entry] {
        let broadcasts = broadcasts ?? .null
        var entries = broadcasts["items"].array.enumerated().map { index, item in
            scheduleEntry(item, fallbackId: "\(nodeId):\(index)", context: context, imageWidth: imageWidth)
        }
        if case .object = broadcasts["current"] {
            var current = scheduleEntry(broadcasts["current"], fallbackId: "\(nodeId):current", context: context,
                                        imageWidth: imageWidth)
            current.isCurrent = true
            // Both bounds are inclusive, so a broadcast starting at `now` is also in `items`.
            entries = [current] + entries.filter { $0.id != current.id }
        }
        return entries
    }

    /// One `broadcastsLive` row: an `items` entry or `current`, which share one shape.
    private static func scheduleEntry(
        _ item: JSONValue, fallbackId: String, context: RenderContext, imageWidth: Int
    ) -> ScheduleModel.Entry {
        let episode = item["episode"]
        // A row the import linked to a Movie carries `movie` instead (awe#6185).
        let movie = item["movie"]
        // Same shell image config as a card: the flat `episode.image`, else the show's main
        // image through the slot ladder, else the movie's.
        let file = ImageFile(episode["image"]) ?? ImageCatalog.pick(episode["show"]["images"])
            ?? ImageCatalog.pick(movie["images"])
        // `broadcastsLive` items carry `startsAt` (Frontend API
        // `modules/media-library/resources/broadcastsLive.js`); `startTime` is accepted in case
        // an older shape appears.
        let startsAt = ContractDate.parse(item["startsAt"].string ?? item["startTime"].string)
        // A Broadcast has no `title` of its own: it carries `episodeTitle` / `showTitle` plus a
        // populated `episode` or `movie`.
        let title = item["episodeTitle"].text ?? episode["title"].text ?? movie["title"].text
            ?? item["showTitle"].text ?? ChromeText.string(.broadcast)
        let showTitle = episode["show"]["title"].text ?? item["showTitle"].text
        return ScheduleModel.Entry(
            id: item["id"].text ?? item["_id"].text ?? fallbackId,
            time: TimeOfDayFormatter.string(from: startsAt),
            title: title,
            showTitle: showTitle == title ? nil : showTitle,
            target: broadcastTarget(item),
            imageURL: context.images.url(file, width: imageWidth),
            blurhash: file?.blurhash,
            startsAt: startsAt,
            endsAt: ContractDate.parse(item["endsAt"].string)
        )
    }

    /// A shelf card names the show's title and the duration; a grid card on the show's own
    /// screen names only the duration, because the show is already the screen it sits on.
    enum EpisodeCardStyle { case shelf, grid }

    private static func showCard(
        nodeId: String,
        index: Int,
        show: JSONValue,
        context: RenderContext,
        cardStyle: ShelfModel.CardStyle = .cards
    ) -> CardModel {
        let art = art(images: show["images"], cardStyle: cardStyle)
        let episodes = show["episodeCount"].int
        let recordId = show["id"].text ?? show["_id"].text
        let title = show["title"].text ?? ChromeText.string(.untitled)
        let imageURL = context.images.url(art.file, width: artWidth(art.style))
        var card = CardModel(
            id: recordId ?? "\(nodeId):\(index)",
            title: title,
            subtitle: episodes.map { ChromeText.count(.episodesCount, $0) },
            imageURL: imageURL,
            blurhash: art.file?.blurhash,
            badge: nil,
            progress: nil,
            target: target(resourceType: "show", itemId: recordId, link: ScreenLink(show["screenLink"])),
            style: art.style,
            artIsFallback: art.fallback
        )
        card.menu = savable(.show, id: recordId, title: title, image: ImageCatalog.pick(show["images"]), context: context)
            .map(CardMenu.watchLater)
        if art.style == .hero {
            let seasons = show["seasonCount"].int ?? 0
            let meta = [
                seasons > 0 ? ChromeText.count(.seasonsCount, seasons) : nil,
                (episodes ?? 0) > 0 ? ChromeText.count(.episodesCount, episodes ?? 0) : nil,
            ]
            card.hero = hero(item: show, title: title, meta: meta, imageURL: imageURL, context: context)
            // Only a show serves a preview, as only the web `ShowHero` passes one.
            card.hero?.previewURL = HeroPreview.source(show["previewVideo"])
        }
        return card
    }

    private static func episodeCard(
        nodeId: String,
        index: Int,
        episode: JSONValue,
        context: RenderContext,
        style: EpisodeCardStyle,
        cardStyle: ShelfModel.CardStyle = .cards,
        showDuration: Bool
    ) -> CardModel {
        let art = art(images: episode["images"], flat: episode["image"], cardStyle: cardStyle)
        let duration = showDuration ? DurationFormatter.short(seconds: episode["duration"].double) : nil
        let parts = (style == .shelf ? [episode["show"]["title"].text, duration] : [duration]).compactMap { $0 }
        let recordId = episode["id"].text ?? episode["_id"].text
        let title = episode["title"].text ?? ChromeText.string(.untitled)
        let imageURL = context.images.url(art.file, width: artWidth(art.style))
        var card = CardModel(
            id: recordId ?? "\(nodeId):\(index)",
            title: title,
            subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
            imageURL: imageURL,
            blurhash: art.file?.blurhash,
            badge: nil,
            progress: nil,
            target: target(resourceType: "episode", itemId: recordId, link: ScreenLink(episode["screenLink"])),
            style: art.style,
            artIsFallback: art.fallback,
            seasonId: episode["season"]["_id"].text ?? episode["season"]["id"].text,
            abstract: episode["abstract"].text,
            // The API serves 0 for an episode with no number.
            number: episode["number"].int.flatMap { $0 > 0 ? $0 : nil }
        )
        card.menu = savable(.episode, id: recordId, title: title,
                            image: ImageFile(episode["image"]) ?? ImageCatalog.pick(episode["images"]), context: context)
            .map(CardMenu.watchLater)
        if art.style == .hero {
            card.hero = hero(item: episode, title: title, meta: [episode["show"]["title"].text, duration],
                             imageURL: imageURL, context: context)
        }
        return card
    }

    /// A `MovieList` or movie Collection card (awe#6870): the title and "2019 · 1h 52m", as the
    /// web `MovieCard`. It opens the served `screenLink`, else the one `movie` Template Screen.
    /// A hero card draws the hero with the same meta line; movies serve no categories.
    private static func movieCard(
        nodeId: String,
        index: Int,
        movie: JSONValue,
        context: RenderContext,
        cardStyle: ShelfModel.CardStyle
    ) -> CardModel {
        let art = art(images: movie["images"], cardStyle: cardStyle)
        let recordId = movie["id"].text ?? movie["_id"].text
        let title = movie["title"].text ?? ChromeText.string(.untitled)
        let imageURL = context.images.url(art.file, width: artWidth(art.style))
        let meta = movieMeta(movie)
        var card = CardModel(
            id: recordId ?? "\(nodeId):\(index)",
            title: title,
            subtitle: meta.isEmpty ? nil : meta.joined(separator: " · "),
            imageURL: imageURL,
            blurhash: art.file?.blurhash,
            badge: nil,
            progress: nil,
            target: target(resourceType: "movie", itemId: recordId, link: ScreenLink(movie["screenLink"])),
            style: art.style,
            artIsFallback: art.fallback
        )
        card.menu = savable(.movie, id: recordId, title: title, image: ImageCatalog.pick(movie["images"]), context: context)
            .map(CardMenu.watchLater)
        if art.style == .hero {
            card.hero = hero(item: movie, title: title, meta: meta, imageURL: imageURL, context: context)
        }
        return card
    }

    /// The movie meta parts, "2019" and "1h 52m": `releaseYear`, then `duration`. A missing part is left out.
    private static func movieMeta(_ movie: JSONValue) -> [String] {
        [movie["releaseYear"].int.map(String.init), DurationFormatter.short(seconds: movie["duration"].double)]
            .compactMap { $0 }
    }

    /// A "Keep watching" card: "Show · 25m · 15m left". `showDuration` adds the media duration
    /// and the time left; an entry saved without a duration draws neither. No served link on a
    /// device or member-copy card: the convention opens the Episode Screen, or the movie
    /// Template Screen for a movie entry.
    private static func watchHistoryCard(_ entry: WatchProgressStore.Entry, showDuration: Bool) -> CardModel {
        let duration = showDuration ? entry.duration : nil
        let parts = [
            entry.subtitle.isEmpty ? nil : entry.subtitle,
            DurationFormatter.short(seconds: duration),
            DurationFormatter.short(seconds: duration.map { $0 * (1 - entry.fraction) })
                .map { ChromeText.string(.timeLeft, ["time": $0]) },
        ].compactMap { $0 }
        return CardModel(
            id: entry.playableId,
            title: entry.title,
            subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
            imageURL: entry.imageURL,
            blurhash: nil,
            badge: nil,
            progress: entry.fraction,
            target: entry.episodeId.map { CardTarget(resourceType: "episode", itemId: $0) }
                ?? entry.movieId.map { CardTarget(resourceType: "movie", itemId: $0) },
            // An episode or movie card too, so it offers Watch later (awe#6869). The entry keeps the art URL.
            menu: (entry.episodeId.map { (SavedItem.ItemType.episode, $0) } ?? entry.movieId.map { (.movie, $0) })
                .flatMap { itemType, id in
                    ContractValidator.isObjectId(id)
                        ? .watchLater(SavedItem(itemType: itemType, itemId: id, title: entry.title, imageURL: entry.imageURL,
                                                savedAt: .distantPast))
                        : nil
                }
        )
    }

    /// A Watch later card. It opens its item by the card convention only: the one Template Screen
    /// of its type (ruled D2: the device keeps no screen link). A manifest with no `movie`
    /// template opens nothing for a movie; the card still draws, so the viewer can remove it.
    /// The card id carries the type: an episode and a movie can share an id.
    private static func savedCard(_ item: SavedItem) -> CardModel {
        CardModel(
            id: item.id,
            title: item.title,
            subtitle: nil,
            imageURL: item.imageURL,
            blurhash: nil,
            badge: nil,
            progress: nil,
            target: CardTarget(resourceType: item.itemType.rawValue, itemId: item.itemId),
            menu: .removeFromWatchLater(item)
        )
    }

    /// What a card or a detail block saves to Watch later: an ObjectId item only, so the id is
    /// safe in a route path. The image is the landscape card art, as the shelf draws it.
    private static func savable(_ itemType: SavedItem.ItemType, id: String?, title: String, image: ImageFile?,
                                context: RenderContext) -> SavedItem? {
        guard let id, ContractValidator.isObjectId(id) else { return nil }
        return SavedItem(itemType: itemType, itemId: id, title: title, imageURL: context.images.url(image, width: 640),
                         savedAt: .distantPast)
    }

    /// The poster and Play / Resume of `EpisodePlayer` and `MoviePlayer`. A served resource that
    /// names no source this device can play draws `cannotPlay` where the button would be.
    private static func playAction(nodeId: String, resource: JSONValue, metadata: PlaybackMetadata, playlist: Playlist?,
                                   related: RelatedEpisodes?, cannotPlay: ChromeText.Key, context: RenderContext) -> BlockContent {
        let play = playRequest(resource: resource, metadata: metadata, playlist: playlist, related: related, context: context)
        let request = play?.request
        let resumes = play?.resumes == true
        return .playAction(PlayActionModel(
            nodeId: nodeId,
            posterURL: ContractValidator.playableURL(resource["poster"].string) ?? metadata.artworkURL,
            request: request,
            label: request == nil ? nil : ChromeText.string(resumes ? .resume : .play),
            message: request == nil ? ChromeText.string(cannotPlay) : nil
        ))
    }

    /// Whether the screen serves a `name` player resource (`episodePlayer`, `moviePlayer`) and none
    /// of them resolves a source here: the player draws its "can't play" message. A Template
    /// Screen binds one item, so every player on it plays the item the detail block shows. No
    /// player resource is not known to be unplayable.
    private static func cannotPlay(_ name: String, context: RenderContext) -> Bool {
        let players = context.blockResources.values.compactMap { $0[name] }.filter { !$0.isNull }
        return !players.isEmpty && players.allSatisfy { PlaybackService.episodeSource($0) == nil }
    }

    /// The one Play rule of `EpisodePlayer`, `MoviePlayer` and the `MovieHero` Watch now: the
    /// source by `PlaybackService.episodeSource` (the `mediaLinks` fallback included), and
    /// whether the device or member progress holds a resume point. nil when nothing can play here.
    private static func playRequest(resource: JSONValue, metadata: PlaybackMetadata, playlist: Playlist?,
                                    related: RelatedEpisodes?, context: RenderContext) -> (request: PlaybackRequest, resumes: Bool)? {
        guard let source = PlaybackService.episodeSource(resource) else { return nil }
        let request = PlaybackRequest(url: source.url, metadata: metadata, playlist: playlist, related: related, isHLS: source.isHLS)
        let resumes = request.resumeFraction(resumePoints: context.resumePoints,
                                             memberResumePoints: context.memberResumePoints) != nil
        return (request, resumes)
    }

    /// `MovieDetail` (awe#6270), drawn by the `ShowDetail` view: text only, as `EpisodeDetail` (the
    /// `MoviePlayer` poster is the art). The props default as the builder's
    /// `MovieDetail.craft.props` do: `showTitle`, `showMeta`, `showBody` and `showWatchlistToggle`
    /// on, `showAbstract` and `showTrailer` off. The meta line (year · runtime) and the heading row
    /// (the age badge, the quality badge, the language label, the genres) draw only with the
    /// title and `showMeta`, so a body-only second instance repeats none of them. Not drawn:
    /// `showImage`, the `showAgeRatings` list, and the raw `language` code.
    private static func movieDetail(node: CraftNode, nodeId: String, context: RenderContext) -> BlockContent? {
        guard let detail = context.resource(nodeId, "movieDetail") else { return nil }
        let on = { (prop: String, fallback: Bool) in node.props[prop].bool ?? fallback }
        let title = detail["title"].text ?? ChromeText.string(.untitled)
        let heading = on("showTitle", true)
        let meta = heading && on("showMeta", true)
        let parts = movieMeta(detail)
        let genres = detail["genres"].array.compactMap { $0["title"].text }
        let image = ImageCatalog.pick(detail["images"])
        // A movie the screen's player cannot play here offers no Watch later and no Like.
        let saved = heading && !cannotPlay("moviePlayer", context: context)
            ? savable(.movie, id: detail["_id"].text ?? detail["id"].text, title: title, image: image, context: context)
            : nil
        let model = ShowDetailModel(
            title: heading ? title : nil,
            subtitle: meta && !parts.isEmpty ? parts.joined(separator: " · ") : nil,
            abstract: on("showAbstract", false) ? detail["abstract"].text : nil,
            paragraphs: on("showBody", true) ? tiptapParagraphs(detail["body"]) : [],
            imageURL: nil,
            blurhash: nil,
            trailer: on("showTrailer", false)
                ? PlaybackService.trailerRequest(detail["trailer"], title: title, description: detail["abstract"].text,
                                                 artworkURL: context.images.url(image, width: 1280))
                : nil,
            ageRating: meta ? AgeRatingFormat.primaryLabel(detail["ageRatings"]) : nil,
            // The Watch later toggle (awe#6869), with the title only, as on `ShowDetail`.
            watchLater: on("showWatchlistToggle", true) ? saved : nil,
            // Like (awe#6871), with the title. The block has no prop for it.
            like: saved,
            // awe#6870: the server resolves the label ("Deutsch"); the raw `language` code is not drawn.
            language: meta ? detail["languageLabel"].text : nil,
            videoQuality: meta ? detail["videoQuality"].string.flatMap { videoQualityLabels[$0] } : nil,
            genres: meta && !genres.isEmpty ? genres.joined(separator: ", ") : nil
        )
        let empty = model.title == nil && model.abstract == nil && model.paragraphs.isEmpty && model.trailer == nil
        return empty ? nil : .detail(model)
    }

    /// `MovieCast` (awe#7035): `movieCast { id, cast: [{ person, role, image }] }`, one tile per
    /// member with a name, in served order, as the web `MovieCast`. No tile renders null.
    private static func movieCast(nodeId: String, context: RenderContext) -> BlockContent? {
        let members = context.resource(nodeId, "movieCast")?["cast"].array ?? []
        let tiles = members.enumerated().compactMap { index, member in
            personTile(id: "\(index)", member: member, role: member["role"].text, context: context)
        }
        return tiles.isEmpty ? nil : .people(PeopleRowModel(heading: ChromeText.string(.cast), tiles: tiles))
    }

    /// `MovieCrew` (awe#7035): `movieCrew { id, crew: [{ job, label?, members }] }`, filtered as the
    /// web `MovieCrew`: a job of `MOVIE_CREW_JOBS` only, and a `custom` group needs its `label`.
    /// One tile per named member across the groups, the group label as the role. `note` is not
    /// drawn. No tile renders null.
    private static func movieCrew(nodeId: String, context: RenderContext) -> BlockContent? {
        let groups = context.resource(nodeId, "movieCrew")?["crew"].array ?? []
        let tiles = groups.enumerated().flatMap { groupIndex, group -> [PeopleRowModel.Tile] in
            let job = group["job"].string ?? ""
            guard let label = job == "custom" ? group["label"].text : crewJobs[job].map({ ChromeText.string($0) })
            else { return [] }
            return group["members"].array.enumerated().compactMap { index, member in
                personTile(id: "\(groupIndex):\(index)", member: member, role: label, context: context)
            }
        }
        return tiles.isEmpty ? nil : .people(PeopleRowModel(heading: ChromeText.string(.crew), tiles: tiles))
    }

    /// The fixed jobs of `MOVIE_CREW_JOBS` (`packages/utils/src/media-library.ts`) and their
    /// chrome labels. `custom` brings its own label. Any other job is dropped. A hand copy of that
    /// list: change both together.
    private static let crewJobs: [String: ChromeText.Key] = [
        "director": .crewJobDirector, "writer": .crewJobWriter, "author": .crewJobAuthor,
        "producer": .crewJobProducer, "executiveProducer": .crewJobExecutiveProducer,
        "cinematography": .crewJobCinematography, "editing": .crewJobEditing, "music": .crewJobMusic,
        "editorial": .crewJobEditorial, "casting": .crewJobCasting, "productionDesign": .crewJobProductionDesign,
        "costumeDesign": .crewJobCostumeDesign, "sound": .crewJobSound, "visualEffects": .crewJobVisualEffects,
    ]

    /// One person tile, or nil when the person has no name. `image` is a File Manager file, asked
    /// at twice the circle size; `null` draws the neutral circle.
    private static func personTile(id: String, member: JSONValue, role: String?,
                                   context: RenderContext) -> PeopleRowModel.Tile? {
        let name = PersonName.display(member["person"])
        guard !name.isEmpty else { return nil }
        return PeopleRowModel.Tile(id: id, name: name, role: role,
                                   imageURL: context.images.url(ImageFile(member["image"]), width: PersonTileMetrics.photoWidth))
    }

    /// `MovieHero`: the `movieHero` resource (`apis/frontend/.../resources/movieHero.js`) as a one-page
    /// hero, read as the web `shared/MovieHero.js`. The props default as the builder's
    /// `MovieHero.craft.props`. The art is `images.banner` first, as on a hero card. Watch now
    /// plays the movie through the `MoviePlayer` rule (`playRequest`: the source with the
    /// `mediaLinks` fallback, Resume from device or member progress; `player.resumeSeconds` is not
    /// read). Nothing this device can play draws the "can't play" message instead of Watch now. An
    /// empty label prop draws the chrome string. No resource renders null.
    private static func movieHero(node: CraftNode, nodeId: String, context: RenderContext) -> BlockContent? {
        guard let movie = context.resource(nodeId, "movieHero") else { return nil }
        let on = { (prop: String, fallback: Bool) in node.props[prop].bool ?? fallback }
        let label = { (prop: String) in node.props[prop].text }
        let recordId = movie["id"].text ?? movie["_id"].text
        let title = movie["title"].text ?? ChromeText.string(.untitled)
        let art = art(images: movie["images"], cardStyle: .hero)
        let imageURL = context.images.url(art.file, width: heroArtWidth)

        var model = hero(item: movie, title: title, meta: [], imageURL: imageURL, context: context)
        model.abstract = on("showAbstract", true) ? model.abstract : nil
        model.metaParts = movieHeroMeta(movie, fields: node.props["metaFields"])
        model.metaBeforeAbstract = true
        // The categories follow the genres in the same list, as on the web.
        let genres = on("showGenres", true) ? movie["genres"].array.compactMap { $0["title"].text } : []
        let categories = on("showCategories", false) ? movie["categories"].array.compactMap { $0["title"].text } : []
        model.categories = genres + categories
        if node.props["genresDisplay"].string == "text" {
            model.tagSeparator = node.props["tagsSeparator"].string == "pipe" ? " | " : " • "
        }
        model.trailer = on("showTrailer", true) ? model.trailer : nil
        model.trailerLabel = label("trailerLabel")
        model.watchNow = nil
        // The server also serves `player: null` when the prop is off.
        let player = movie["player"]
        if on("showPlayButton", true), !player.isNull {
            // `PlaybackMetadata.movie` reads the age rating and the first genre from a `movieDetail` of
            // the same movie; the hero serves its own, so a screen without one still fills the Info panel.
            var metadata = PlaybackMetadata.movie(movie, blockResources: context.blockResources,
                                                  poster: player["poster"].string, images: context.images)
            metadata.contentRating = metadata.contentRating ?? AgeRatingFormat.primaryLabel(movie["ageRatings"])
            metadata.genre = metadata.genre ?? movie["genres"].array.first?["title"].text
            if let play = playRequest(resource: player, metadata: metadata, playlist: nil, related: nil, context: context) {
                model.watchNow = .play(play.request, label: play.resumes
                    ? label("resumeLabel") ?? ChromeText.string(.resume)
                    : label("watchNowLabel") ?? ChromeText.string(.watchNow))
            }
        }
        // A movie with nothing to play here says so, and offers no Watch later. With
        // `showPlayButton` off the server serves `player: null` for a playable movie too, so the
        // toggle stays and no message draws.
        let unplayable = on("showPlayButton", true) && model.watchNow == nil
        model.cannotPlayMessage = unplayable ? ChromeText.string(.cannotPlayMovie) : nil
        if on("showWatchlistToggle", true), !unplayable {
            // The same `.movie` item as the `MovieDetail` toggle, with the title.
            model.watchLater = savable(.movie, id: recordId, title: title, image: ImageCatalog.pick(movie["images"]),
                                      context: context)
            model.watchLaterLabel = label("watchlistLabel")
            model.watchLaterSavedLabel = label("watchlistSavedLabel")
        }

        var card = CardModel(id: recordId ?? nodeId, title: title, subtitle: nil, imageURL: imageURL,
                             blurhash: art.file?.blurhash, badge: nil, progress: nil, target: nil,
                             style: .hero, artIsFallback: art.fallback)
        card.hero = model
        return .shelf(ShelfModel(nodeId: nodeId, title: nil, cards: [card], layout: .row, cardStyle: .hero,
                                 emptyMessage: nil))
    }

    /// The `MovieHero` meta line, in the normalized `metaFields` order (`MovieFields.heroMeta`). The
    /// age rating, the quality and each accessibility flag are badges. A part with no value is left out.
    private static func movieHeroMeta(_ movie: JSONValue, fields: JSONValue) -> [HeroModel.MetaPart] {
        MovieFields.enabledNames(fields, defaults: MovieFields.heroMeta).flatMap { name -> [HeroModel.MetaPart] in
            switch name {
            case "releaseYear":
                return year(movie["releaseYear"]).map { [.text($0)] } ?? []
            case "duration":
                return runtime(movie["duration"]).map { [.text($0)] } ?? []
            case "ageRating":
                return AgeRatingFormat.primaryLabel(movie["ageRatings"]).map { [.badge($0)] } ?? []
            case "countries":
                let names = movie["countries"].array.compactMap { $0["name"].text }
                return names.isEmpty ? [] : [.text(names.joined(separator: ", "))]
            case "originalReleaseYear":
                // Labeled, so it does not read as a second release year.
                return year(movie["originalReleaseYear"]).map { [.text(ChromeText.string(.originalReleaseYear, ["year": $0]))] } ?? []
            case "accessibility":
                return accessibilityBadges(movie["accessibility"]).map { HeroModel.MetaPart.badge($0.text, spoken: $0.spoken) }
            case "videoQuality":
                return movie["videoQuality"].string.flatMap { videoQualityLabels[$0] }.map { [.badge($0)] } ?? []
            default:
                return []
            }
        }
    }

    /// `MovieMeta`: the `movieMeta` resource (`toMovieMeta`) as label / value rows in one reading
    /// panel, drawn by the `ShowMeta` view. The rows follow the normalized `fields` prop
    /// (`MovieFields.meta`), as the web `MovieMeta.js`; a row with an empty value is left out. No row
    /// renders null.
    private static func movieMetaRows(node: CraftNode, nodeId: String, context: RenderContext) -> BlockContent? {
        guard let meta = context.resource(nodeId, "movieMeta") else { return nil }
        let list = { (values: [String], separator: String) in values.isEmpty ? nil : values.joined(separator: separator) }
        let countries = meta["countries"].array.compactMap { $0["name"].text }
        let flags = accessibilityBadges(meta["accessibility"])
        let rows = MovieFields.enabledNames(node.props["fields"], defaults: MovieFields.meta).compactMap { name -> ShowMetaModel.Row? in
            let row: (label: ChromeText.Key, value: String?)
            switch name {
            // One company per line, as the web draws them.
            case "productionCompanies": row = (.productionLabel, list(meta["productionCompanies"].array.compactMap(\.text), "\n"))
            case "countries": row = (countries.count == 1 ? .countryLabel : .countriesLabel, list(countries, ", "))
            case "originalTitle": row = (.originalTitleLabel, meta["originalTitle"].text)
            case "originalLanguage": row = (.originalLanguageLabel, meta["originalLanguage"]["name"].text)
            case "originalReleaseYear": row = (.originalReleaseLabel, year(meta["originalReleaseYear"]))
            case "releaseYear": row = (.releaseYearLabel, year(meta["releaseYear"]))
            case "duration": row = (.durationLabel, runtime(meta["duration"]))
            case "genres": row = (.genresLabel, list(meta["genres"].array.compactMap { $0["title"].text }, ", "))
            case "playbackLanguages": row = (.playbackLanguagesLabel, list(meta["audioTracks"].array.compactMap(audioTrack), ", "))
            case "subtitleLanguages": row = (.subtitlesLabel, list(meta["subtitleLanguages"].array.compactMap { $0["name"].text }, ", "))
            case "accessibility": row = (.accessibilityLabel, list(flags.map(\.text), ", "))
            case "videoQuality": row = (.videoQualityLabel, meta["videoQuality"].string.flatMap { videoQualityLabels[$0] })
            case "availability": row = (.availabilityLabel, availability(ContractDate.parse(meta["videoOnDemandEndsAt"].string)))
            default: return nil
            }
            // VoiceOver reads the flags by their full words; the panel draws "OV, CC".
            let spoken = name == "accessibility" ? list(flags.map(\.spoken), ", ") : nil
            return row.value.map { ShowMetaModel.Row(label: ChromeText.string(row.label), value: $0, spokenValue: spoken) }
        }
        return rows.isEmpty ? nil : .showMeta(ShowMetaModel(rows: rows))
    }

    /// A served year, or nil for none and for 0 (the web reads a falsy year as none).
    private static func year(_ value: JSONValue) -> String? {
        value.int.flatMap { $0 == 0 ? nil : String($0) }
    }

    /// The true accessibility flags in badge order: the short text ("OV", "CC", "AD", "SL") and the
    /// words VoiceOver reads, as the web `AccessibilityBadges` labels them.
    private static func accessibilityBadges(_ accessibility: JSONValue) -> [(text: String, spoken: String)] {
        MovieFields.accessibilityFlags.compactMap { flag in
            guard accessibility[flag].bool == true, let keys = accessibilityKeys[flag] else { return nil }
            return (ChromeText.string(keys.text), ChromeText.string(keys.spoken))
        }
    }

    private static let accessibilityKeys: [String: (text: ChromeText.Key, spoken: ChromeText.Key)] = [
        "ov": (.accessibilityOv, .accessibilityLabelOv), "ut": (.accessibilityUt, .accessibilityLabelUt),
        "ad": (.accessibilityAd, .accessibilityLabelAd), "dgs": (.accessibilityDgs, .accessibilityLabelDgs),
    ]

    /// The runtime as `DurationFormatter.short`, left out when it rounds to 0 minutes (under 30 s),
    /// as the web `getRuntimeMinutes`.
    private static func runtime(_ duration: JSONValue) -> String? {
        guard let seconds = duration.double, (seconds / 60).rounded() > 0 else { return nil }
        return DurationFormatter.short(seconds: seconds)
    }

    /// One audio track as the web `formatAudioTrack`: "Deutsch Audio description (5.1)". A track
    /// with no language name is left out. Only `MOVIE_AUDIO_SUFFIX_KINDS` add the kind, and only
    /// `MOVIE_AUDIO_SHOWN_FORMATS` add the format.
    private static func audioTrack(_ track: JSONValue) -> String? {
        guard let name = track["language"]["name"].text else { return nil }
        let kind = track["kind"].string.flatMap { audioKinds[$0] }.map { " " + ChromeText.string($0) } ?? ""
        let format = track["format"].string.flatMap { audioFormats[$0] }.map { " (\($0))" } ?? ""
        return name + kind + format
    }

    private static let audioKinds: [String: ChromeText.Key] = [
        "audioDescription": .audioKindAudioDescription, "dialogueBoost": .audioKindDialogueBoost,
    ]

    private static let audioFormats = ["5.1": "5.1", "atmos": "Atmos"]

    /// The availability row: "Only 3 days left online", or "Online today only", in the last
    /// `MovieFields.availabilityWarningDays` days of the VOD window (device time zone). Else nil.
    private static func availability(_ endsAt: Date?) -> String? {
        guard let days = MovieFields.daysLeft(endsAt: endsAt, now: Date()) else { return nil }
        return days == 0 ? ChromeText.string(.availabilityToday) : ChromeText.count(.availabilityDaysLeft, days)
    }

    /// The stored `Movie.videoQuality` values (lowercase) and the badge text. Any other value draws no badge.
    private static let videoQualityLabels = ["720p": "720p", "1080p": "1080p", "4k": "4K"]

    /// The hero art is requested at the stage width.
    private static let heroArtWidth = Int(Layout.stageWidth)

    /// The CDN width for one card's art. A banner card takes the hero width: no image needs more
    /// than the stage art.
    private static func artWidth(_ style: ShelfModel.CardStyle) -> Int {
        switch style {
        case .hero, .banner: return heroArtWidth
        case .cards, .posters: return 640
        }
    }

    /// The hero parts of a show or an episode. A part the item does not serve is left out:
    /// an episode usually has no logo and no categories.
    private static func hero(
        item: JSONValue,
        title: String,
        meta: [String?],
        imageURL: URL?,
        context: RenderContext
    ) -> HeroModel {
        let logo = ImageFile(item["images"]["logo"])
        let abstract = item["abstract"].text
        let parts = meta.compactMap { $0 }
        return HeroModel(
            logoURL: context.images.url(logo, width: 1600),
            logoAspect: logo.flatMap { file in
                guard let width = file.width, let height = file.height, width > 0, height > 0 else { return nil }
                return CGFloat(height) / CGFloat(width)
            },
            abstract: abstract,
            metaParts: parts.map(HeroModel.MetaPart.text),
            // Served as localized name strings; a `{ title }` object is read the same way.
            categories: item["categories"].array.compactMap { $0.text ?? $0["title"].text },
            trailer: PlaybackService.trailerRequest(item["trailer"], title: title, description: abstract, artworkURL: imageURL)
        )
    }

    /// `ShowDetail`. The props default as the builder's `ShowDetail.craft.props` do:
    /// `showTitle`, `showBody` and `showImage` on, `showAbstract` and `showTrailer` off. With
    /// nothing to draw, it renders null.
    private static func showDetail(node: CraftNode, nodeId: String, context: RenderContext) -> BlockContent? {
        guard let detail = context.resource(nodeId, "showDetail") else { return nil }
        let on = { (prop: String, fallback: Bool) in node.props[prop].bool ?? fallback }
        let title = detail["title"].text ?? ChromeText.string(.untitled)
        // The show's main image first, as the web block draws `images.default`.
        let file = on("showImage", true) ? ImageCatalog.pick(detail["images"]) : nil
        let imageURL = context.images.url(file, width: 1280)
        let model = ShowDetailModel(
            heading: node.props["title"].text,
            title: on("showTitle", true) ? title : nil,
            subtitle: on("showTitle", true) ? detail["subtitle"].text : nil,
            abstract: on("showAbstract", false) ? detail["abstract"].text : nil,
            paragraphs: on("showBody", true) ? tiptapParagraphs(detail["body"]) : [],
            imageURL: imageURL,
            blurhash: imageURL == nil ? nil : file?.blurhash,
            trailer: on("showTrailer", false)
                ? PlaybackService.trailerRequest(detail["trailer"], title: title,
                                                 description: detail["abstract"].text, artworkURL: imageURL)
                : nil,
            // With the title only, so a body-only second instance draws no second badge.
            ageRating: on("showTitle", true) ? AgeRatingFormat.primaryLabel(detail["ageRatings"]) : nil,
            // The Watch later toggle (awe#6869), with the title only, as the badge.
            watchLater: on("showTitle", true)
                ? savable(.show, id: detail["_id"].text ?? detail["id"].text, title: title,
                          image: ImageCatalog.pick(detail["images"]), context: context)
                : nil
        )
        let empty = model.title == nil && model.abstract == nil && model.paragraphs.isEmpty
            && model.imageURL == nil && model.trailer == nil
        return empty ? nil : .detail(model)
    }

    /// `ShowMeta`: the `showMetaData` resource as label / value rows. Every prop defaults to on,
    /// as the builder's `ShowMeta.craft.props` do. Counts of zero and empty lists draw no row. A
    /// host is named by `PersonName.display` (awe#7116); a host with no name draws no entry.
    /// Nothing to draw (the resource is `{}`) renders null.
    private static func showMeta(node: CraftNode, nodeId: String, context: RenderContext) -> BlockContent? {
        guard let meta = context.resource(nodeId, "showMetaData") else { return nil }
        let on = { (prop: String) in node.props[prop].bool != false }
        let list = { (values: [String]) in values.isEmpty ? nil : values.joined(separator: ", ") }
        let seasons = meta["seasonsCount"].int ?? 0
        let episodes = meta["episodesCount"].int ?? 0

        let rows: [(ChromeText.Key, String?)] = [
            (.showLabel, on("showTitle") ? meta["title"].text : nil),
            (.hostsLabel, on("showHosts") ? list(meta["hosts"].array.map(PersonName.display).filter { !$0.isEmpty }) : nil),
            (.categoriesLabel, on("showCategories") ? list(meta["categories"].array.compactMap { $0["title"].text ?? $0.text }) : nil),
            (.languageLabel, on("showLanguage") ? meta["language"].text : nil),
            (.seasonsLabel, on("showSeasons") && seasons > 0 ? "\(seasons)" : nil),
            (.episodesLabel, on("showEpisodes") && episodes > 0 ? "\(episodes)" : nil),
        ]
        let drawn = rows.compactMap { label, value in value.map { ShowMetaModel.Row(label: ChromeText.string(label), value: $0) } }
        return drawn.isEmpty ? nil : .showMeta(ShowMetaModel(rows: drawn))
    }

    /// The Divider height key → points, as the editor's own options and mobile's `HEIGHTS` map
    /// them (`key * 4` px of the Tailwind step). `none` is a zero line.
    private static let dividerThickness: [String: CGFloat] = ["none": 0, "xs": 1, "sm": 2, "md": 4, "lg": 8]

    /// The `tv` design's icon list (`apps/backend/app/designs/tv/index.js` `icons`) → SF Symbols.
    /// A bare name is the `classic/regular/` Icon Key, as on mobile. Any other icon has no symbol.
    private static let badgeSymbols: [String: String] = [
        "classic/regular/arrow-right": "arrow.right",
        "classic/regular/calendar": "calendar",
        "classic/regular/check": "checkmark",
        "classic/regular/chevron-down": "chevron.down",
        "classic/regular/chevron-left": "chevron.left",
        "classic/regular/chevron-right": "chevron.right",
        "classic/regular/chevron-up": "chevron.up",
        "classic/regular/circle-play": "play.circle",
        "classic/solid/pause": "pause.fill",
        "classic/solid/play": "play.fill",
        "classic/regular/globe": "globe",
        "classic/regular/magnifying-glass": "magnifyingglass",
        "classic/regular/play": "play",
        "classic/regular/user": "person",
        "classic/regular/video": "video",
        "classic/regular/xmark": "xmark",
    ]

    private static func badgeSymbol(_ icon: String?) -> String? {
        guard let name = icon?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return badgeSymbols[name.contains("/") ? name : "classic/regular/\(name)"]
    }

    /// `Header`, as the mobile renderer reads it: no kicker, title or subtitle draws nothing. The
    /// link row is the `Button`'s `screen` link, drawn only with a target and a `linkLabel`. A tv
    /// Header stores `linkType: "screen"` from the start (awe#6113), so the type alone is no link.
    private static func header(_ props: JSONValue) -> BlockContent? {
        let kicker = props["kicker"].text
        let title = props["title"].text
        let subtitle = props["subtitle"].text
        guard kicker != nil || title != nil || subtitle != nil else { return nil }

        var link: ButtonModel?
        if props["linkType"].string == "screen", let screenId = props["screen"].text,
           let label = props["linkLabel"].text {
            link = ButtonModel(label: label, screenId: screenId, screenParam: props["screenParam"].text,
                               linkType: "screen", disabled: false)
        }
        let level = ["h1": 1, "h2": 2, "h3": 3][props["as"].string ?? ""] ?? 1
        return .header(HeaderModel(kicker: kicker, title: title, level: level, subtitle: subtitle, link: link))
    }

    /// The season chips of an `EpisodesList`: every season of `show.seasons`, in authored order,
    /// that holds at least one of the served episodes. The served `episodeCount` per season is
    /// not trusted, so the count comes from the cards.
    private static func seasonFilter(_ show: JSONValue?, cards: [CardModel]) -> [ShelfModel.Season] {
        let used = Set(cards.compactMap(\.seasonId))
        guard !used.isEmpty else { return [] }
        return (show?["seasons"].array ?? []).enumerated().compactMap { index, season in
            guard let id = season["_id"].text ?? season["id"].text, used.contains(id) else { return nil }
            // A season with no title is named by its authored position, never by its id.
            let title = season["title"].text ?? season["groupName"].text
                ?? ChromeText.string(.seasonNumber, ["number": "\(index + 1)"])
            return ShelfModel.Season(id: id, title: title)
        }
    }

    /// The image and the shape ONE card draws.
    ///
    /// A posters shelf asks for portrait art. An item that has none keeps the poster shape
    /// (ruled 2026-10-26) and is flagged `fallback` unless its art is about portrait, because
    /// cropping a 16:9 image into a portrait frame cuts the subject out. A hero or banner card
    /// asks for the wide `banner` slot first, for the same reason, and is flagged `fallback`
    /// when its art is not about 16:9, whichever slot it came from. A flagged card draws its art
    /// aspect-fit over a blurred copy instead of cropping it (ruled, awe#4951). A file without
    /// dimensions is trusted only when it is the shape's own slot (`poster`, `banner`).
    /// `flat` is the episode's own `image`, which a show does not carry.
    private static func art(
        images: JSONValue,
        flat: JSONValue = .null,
        cardStyle: ShelfModel.CardStyle
    ) -> (file: ImageFile?, style: ShelfModel.CardStyle, fallback: Bool) {
        switch cardStyle {
        case .posters:
            if let poster = ImageFile(images["poster"]) { return (poster, .posters, false) }
            let file = ImageFile(flat) ?? ImageCatalog.pick(images)
            return (file, .posters, file?.fits(aspect: CardShape.poster.artAspect) != true)
        case .banner, .hero:
            let aspect = CardShape.hero.artAspect
            if let banner = ImageFile(images["banner"]) {
                return (banner, cardStyle, banner.fits(aspect: aspect) == false)
            }
            let file = ImageFile(flat) ?? ImageCatalog.pick(images)
            return (file, cardStyle, file?.fits(aspect: aspect) != true)
        case .cards:
            return (ImageFile(flat) ?? ImageCatalog.pick(images), .cards, false)
        }
    }

    /// A Broadcast row opens its episode, resolved like an episode card: the served
    /// `episode.screenLink` first, else the convention (ruled 2026-09-23, awe#4989). A
    /// title-only row has no episode record, so it carries no target and draws without a button.
    ///
    /// An explicit `episode.screenLink: null` means the episode is not linkable (ruling A): the
    /// server says its Episode screen would not open, so the row is an information row. A missing
    /// key keeps the convention. Broadcast rows only; every other card reads a missing link and
    /// `null` alike.
    ///
    /// A Movie row (awe#6185) opens only through its served `movie.screenLink`, which names the
    /// movie Template Screen (awe#6270). A movie row has no convention (contract rule 1): a
    /// missing, `null`, or malformed link leaves an information row.
    private static func broadcastTarget(_ item: JSONValue) -> CardTarget? {
        let episode = item["episode"]
        if episode.hasKey("screenLink"), episode["screenLink"].isNull { return nil }
        if let episodeTarget = target(resourceType: "episode", itemId: episode["id"].text ?? episode["_id"].text,
                                      link: ScreenLink(episode["screenLink"])) {
            return episodeTarget
        }
        let movie = item["movie"]
        guard let link = ScreenLink(movie["screenLink"]) else { return nil }
        return target(resourceType: "movie", itemId: movie["id"].text ?? movie["_id"].text, link: link)
    }

    /// An item with no record id carries no target, so its card opens nothing.
    private static func target(resourceType: String, itemId: String?, link: ScreenLink? = nil) -> CardTarget? {
        guard let itemId else { return nil }
        return CardTarget(resourceType: resourceType, itemId: itemId, link: link)
    }

    /// Flattens a Tiptap document into paragraph strings. An unknown node contributes nothing.
    static func tiptapParagraphs(_ body: JSONValue) -> [String] {
        body["content"].array
            .map { node in
                node["content"].array
                    .map { $0["type"].string == "text" ? ($0["text"].string ?? "") : "" }
                    .joined()
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Which registry keys drew markup, and which drew null.
extension EvaluatedNode {
    func collectKeys(rendered: inout Set<String>, null: inout Set<String>) {
        if key.isSupported {
            if content == nil {
                null.insert(key.name)
            } else {
                rendered.insert(key.name)
            }
        }
        for child in children {
            child.collectKeys(rendered: &rendered, null: &null)
        }
    }

    var keyReport: (rendered: Set<String>, null: Set<String>) {
        var rendered = Set<String>()
        var null = Set<String>()
        collectKeys(rendered: &rendered, null: &null)
        return (rendered, null)
    }

    /// True when a `ScheduleLive` drew on this tree: the screen refetches itself on a timer.
    var holdsSchedule: Bool {
        first { if case .schedule = $0.content { return true }; return false } != nil
    }

    /// True when a `MediaSearch` drew on this tree: the screen draws without its own scroll view.
    var holdsSearch: Bool {
        first { if case .mediaSearch = $0.content { return true }; return false } != nil
    }

    /// The node id of a hero shelf that is the first thing this tree draws, else nil. Only that
    /// hero may draw its art up to the stage top: nothing is above it to cover.
    var leadingHeroId: String? {
        guard let leaf = firstDrawnLeaf, case let .shelf(model) = leaf.content,
              model.cardStyle == .hero, model.emptyMessage == nil, !model.cards.isEmpty else { return nil }
        return leaf.id
    }

    /// The padding and border of the layout blocks around the first drawn block (awe#6297),
    /// summed along the path to it. A leading hero adds them to its bleed, so its art still
    /// reaches the stage edges.
    var leadingHeroInsets: LayoutStyle.Insets {
        guard case let .stack(_, _, style) = content else { return LayoutStyle.Insets() }
        for child in children where child.firstDrawnLeaf != nil {
            let own = style.contentInsets
            let below = child.leadingHeroInsets
            return LayoutStyle.Insets(top: own.top + below.top, right: own.right + below.right,
                                      bottom: own.bottom + below.bottom, left: own.left + below.left)
        }
        return LayoutStyle.Insets()
    }

    /// The block that gets a pushed screen's default focus: the first focusable block in document
    /// order, when its view asks for focus (`TakesDefaultFocus`). A block that takes focus but
    /// cannot ask (a reading panel) ends the search with nil: tvOS then chooses, and focus never
    /// jumps past text the viewer has not read yet.
    var firstFocusNodeId: String? {
        switch firstFocusStop {
        case let .asks(id)?: return id
        case .readsOnly?, nil: return nil
        }
    }

    enum FocusStop: Equatable {
        /// The block's view asks for the default focus.
        case asks(String)
        /// The block takes focus, but its view cannot ask for it.
        case readsOnly
    }

    var firstFocusStop: FocusStop? {
        if let role = focusRole { return role }
        for child in children {
            if let found = child.firstFocusStop { return found }
        }
        return nil
    }

    /// Must match the views: `asks` exactly where the view applies `TakesDefaultFocus` or
    /// `DefaultFocusRequest`.
    private var focusRole: FocusStop? {
        switch content {
        case let .shelf(model):
            guard model.emptyMessage == nil, let first = model.cards.first else { return nil }
            // A one-page hero with no focus stop (a `MovieHero` with every button off) takes no focus.
            if model.cardStyle == .hero, model.cards.count == 1, let hero = first.hero, hero.firstFocus == nil { return nil }
            return .asks(id)
        case let .schedule(model):
            return model.entries.isEmpty ? nil : .asks(id)
        case let .playAction(model):
            return model.request == nil ? nil : .asks(id)
        case let .detail(model):
            if model.trailer != nil || model.watchLater != nil || model.like != nil { return .asks(id) }
            return model.title != nil || model.abstract != nil || !model.paragraphs.isEmpty ? .readsOnly : nil
        case let .episodeDetail(model):
            if model.showTarget != nil || model.watchLater != nil || model.like != nil { return .asks(id) }
            let reads = model.title != nil || model.showTitle != nil || model.views != nil
                || model.abstract != nil || !model.paragraphs.isEmpty
            return reads ? .readsOnly : nil
        case .showMeta: return .readsOnly
        // Prose is one reading stop, like `ShowMeta`.
        case .richText: return .readsOnly
        // The search field takes focus; `.searchable` gives the view no way to ask for it.
        case .mediaSearch: return .readsOnly
        case .button, .player: return .asks(id)
        // A row of focusable person tiles, like a card row: its first tile asks.
        case .people: return .asks(id)
        // Only the link row takes focus, and it asks as a `Button` does.
        case let .header(model): return model.link == nil ? nil : .asks(id)
        case .stack, .contentSlot, .text, .image, .message, .divider, .badge, nil: return nil
        }
    }

    /// The first node in document order that draws something of its own. A layout node draws
    /// only its children; a node that rendered null draws nothing.
    private var firstDrawnLeaf: EvaluatedNode? {
        switch content {
        case .stack:
            for child in children {
                if let leaf = child.firstDrawnLeaf { return leaf }
            }
            return nil
        case nil:
            return nil
        default:
            return self
        }
    }

    /// Depth-first lookup, for tests and for the content slot.
    func first(where matches: (EvaluatedNode) -> Bool) -> EvaluatedNode? {
        if matches(self) { return self }
        for child in children {
            if let found = child.first(where: matches) { return found }
        }
        return nil
    }
}

enum ContractDate {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return formatter.date(from: value) ?? plain.date(from: value)
    }
}

extension BlockRegistry {
    /// Tap-to-play (awe#6549): the request of the screen's first `EpisodePlayer` Play, or nil when
    /// the screen has none or its source cannot play here. It evaluates the screen as `ScreenBody`
    /// draws it, so the metadata and the `progressId` are the Play button's own.
    static func playRequest(on screen: AppScreen, images: ImageConfig) -> PlaybackRequest? {
        let context = RenderContext(blockResources: screen.blockResources, screenResources: screen.resources, images: images)
        let node = evaluate(nodeId: CraftDocument.rootId, document: screen.content, context: context)
        let play = node?.first { if case .playAction = $0.content { return true }; return false }
        guard case let .playAction(model)? = play?.content else { return nil }
        return model.request
    }
}

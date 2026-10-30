import CoreGraphics
import Foundation

/// A Screen link the contract served with an item (awe#4519).
///
/// Shape: `{ linkType: "screen", screen: <screenId>, screenParam: <id> }` —
/// `apis/frontend/modules/media-library/resources/helpers/addScreenLinks.js`. It names the
/// Screen AND the param, so the renderer still builds no route of its own.
struct ScreenLink: Hashable {
    let screenId: String
    let param: String

    /// Any other `linkType` is not a TV route, and reads as absent.
    init?(_ value: JSONValue) {
        guard value["linkType"].string == "screen",
              let screenId = value["screen"].text,
              let param = value["screenParam"].text else { return nil }
        self.screenId = screenId
        self.param = param
    }
}

/// Where a card press goes.
///
/// The renderer never builds a route from content: it names the item's type and id, and the
/// router resolves the Template Screen. `nil` on a `CardModel` means the item carries no
/// record id, so nothing can open.
struct CardTarget: Hashable {
    /// The `resourceType` a Template Screen must declare to match — `show`, `episode`.
    let resourceType: String
    let itemId: String
    /// The link the contract served with the item (awe#4519). It wins over the convention.
    var link: ScreenLink? = nil

    /// "Go to show" from a served show id: the one rule for the `EpisodeDetail` button and the
    /// player's Info panel. An ObjectId only, never free text; nil draws no control.
    static func show(id: String?) -> CardTarget? {
        guard let id, ContractValidator.isObjectId(id) else { return nil }
        return CardTarget(resourceType: "show", itemId: id)
    }
}

/// What one card draws. Built by the evaluator, never by a view.
struct CardModel: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let blurhash: String?
    let badge: String?
    let progress: Double?
    var target: CardTarget? = nil
    /// The shape THIS card draws.
    var style: ShelfModel.CardStyle = .cards
    /// True on a hero or banner card whose art is not about 16:9 (no `images.banner`, or a
    /// slot image that is too tall), and on a poster card whose art is not about portrait (no
    /// `images.poster`, ruled 2026-10-26). The card keeps its frame and draws the art
    /// aspect-fit over a blurred copy instead of cropping it (ruled, awe#4951). Never true for
    /// a landscape card.
    var artIsFallback = false
    /// What a hero card draws beside its art. nil for the other shapes.
    var hero: HeroModel? = nil
    /// The episode's `season._id`, for the `EpisodesList` season filter. nil for a show card.
    var seasonId: String? = nil
    /// The episode's `abstract`, drawn by an `EpisodesList` list row. nil for a show card.
    var abstract: String? = nil
    /// The episode's `number` when above zero, drawn by an `EpisodesList` list row.
    var number: Int? = nil
    /// The long-press menu (ADR-0259 §5). nil: the card has no menu.
    var menu: CardMenu? = nil
}

/// What a card's long-press menu offers (ADR-0259 §5). The view reads the saved state when it
/// draws the menu, so the model never goes stale after a save.
enum CardMenu: Equatable {
    /// A show, episode or movie card: "Watch later", or "Remove from Watch later" when saved.
    case watchLater(SavedItem)
    /// A card on the Watch later shelf: "Remove".
    case removeFromWatchLater(SavedItem)

    /// The item the menu also offers "Like" or "Unlike" for (awe#6871): an episode or a movie. A
    /// show has none.
    var likeItem: SavedItem? {
        switch self {
        case let .watchLater(item), let .removeFromWatchLater(item):
            return Likes.canLike(item.itemType) ? item : nil
        }
    }
}

/// The full-screen hero of a `hero` shelf: the item's logo or title, its abstract, a meta
/// line, its categories, and the actions. "Watch now" is the card press (`CardModel.target`).
/// A `MovieHero` block (one page) plays its movie with "Watch now" and can add Watch later.
struct HeroModel: Equatable {
    /// What "Watch now" does.
    enum WatchNow: Equatable {
        /// The card press (`router.select`): a hero shelf.
        case select
        /// Plays the request full screen, with this label ("Watch now", or "Resume"). `MovieHero`.
        case play(PlaybackRequest, label: String)

        var label: String {
            switch self {
            case .select: return ChromeText.string(.watchNow)
            case let .play(_, label): return label
            }
        }
    }

    /// One part of the meta line. Text parts take a bullet between them; badges in a row do not.
    enum MetaPart: Equatable {
        case text(String)
        /// An outlined badge (`AgeRatingBadge`): the age rating, the quality, an accessibility flag.
        /// `spoken` is what VoiceOver reads ("Original version" for "OV"); nil reads the text.
        case badge(String, spoken: String? = nil)

        var text: String {
            switch self {
            case let .text(text), let .badge(text, _): return text
            }
        }
    }

    /// One hero focus stop. `watch`, `trailer` and `watchLater` are the buttons, in drawing order.
    /// `message` is the "can't play" text: a stop only when the hero has no button.
    enum Action: Hashable { case watch, trailer, watchLater, message }

    /// `images.logo`. nil draws the title text instead.
    let logoURL: URL?
    /// height ÷ width of the logo file, when it carries its size. The logo box keeps it.
    let logoAspect: CGFloat?
    var abstract: String?
    /// "10 seasons • 17 episodes", or the show and duration of an episode.
    var metaParts: [MetaPart]
    var categories: [String]
    /// The trailer, only when it resolves to a source this device can play.
    var trailer: PlaybackRequest?
    /// nil draws no Watch now button (a `MovieHero` with no source this device can play).
    var watchNow: WatchNow? = .select
    /// "This movie can't play on this device.", drawn where Watch now would be (`MovieHero`).
    var cannotPlayMessage: String? = nil
    /// The categories as one text line joined with this separator (" • ", " | "), not as chips.
    var tagSeparator: String? = nil
    /// The Trailer button label. nil draws the chrome string.
    var trailerLabel: String? = nil
    /// The Watch later toggle (`MovieHero`). nil draws none.
    var watchLater: SavedItem? = nil
    /// The toggle labels. nil draws the chrome strings.
    var watchLaterLabel: String? = nil
    var watchLaterSavedLabel: String? = nil

    /// `MovieHero`: the meta line draws above the abstract, as the web `metaBeforeDescription`. A
    /// hero shelf keeps it below.
    var metaBeforeAbstract = false

    /// A show's served `previewVideo` (`HeroPreview.source`): the muted loop over the art. Only a
    /// show on a hero shelf sets it; an episode, a movie and `MovieHero` never do.
    var previewURL: URL? = nil

    /// The meta line as text: every part joined with " • ". nil when there is none. Tests only.
    var meta: String? {
        metaParts.isEmpty ? nil : metaParts.map(\.text).joined(separator: " • ")
    }

    /// The buttons the hero draws, in order. The one list for the view and the focus role.
    var actions: [Action] {
        [watchNow == nil ? nil : .watch, trailer == nil ? nil : .trailer, watchLater == nil ? nil : .watchLater]
            .compactMap { $0 }
    }

    /// False when the hero draws no button.
    var hasActions: Bool { !actions.isEmpty }

    /// The stop that takes the default focus: the first button, else the "can't play" message.
    /// The message keeps the hero reachable, so the screen opens on it, not on the block below.
    /// nil: the hero takes no focus.
    var firstFocus: Action? {
        actions.first ?? (cannotPlayMessage == nil ? nil : .message)
    }
}

struct ShelfModel: Equatable {
    /// `row` is a shelf, `grid` a wall of landscape cards (Browse, a show's episodes; posters for a
    /// `posters` shelf, `MovieList`), `list`
    /// one full-width row per episode (`EpisodesList` with `layout: "list"`). `sidewaysGrid` is
    /// two rows that scroll sideways together: a Collection with `listLayout: "grid"`.
    enum Layout {
        case row, grid, list, sidewaysGrid

        /// The list layout of a Collection shelf (ruled 2026-10-23). The block `layout` prop wins
        /// where the TV builder offers it (`Collection` only): `grid` is the paged Browse grid,
        /// `slider` a row. Else the record's `listLayout`: `grid` is the sideways grid; `slider`,
        /// `carousel` and none draw a row. Any other value reads as unset.
        static func resolve(block: String?, record: String?) -> Layout {
            switch block {
            case "grid": return .grid
            case "slider": return .row
            default: return record == "grid" ? .sidewaysGrid : .row
            }
        }
    }

    /// One chip of the `EpisodesList` season filter.
    struct Season: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// The shape of one card, which is a separate choice from the arrangement above: a
    /// shelf row holds landscape cards, portrait posters or large image-only banner cards; a
    /// `hero` shelf is the full-screen hero.
    enum CardStyle {
        case cards, posters, banner, hero

        /// The ruled precedence: the block prop `itemLayout` when set, else the Collection
        /// record's `layout`, else `cards`. `banner` is the image-only 16:9 card and `hero` the
        /// hero (ruled 2026-10-24). A value neither side recognizes reads as unset, the same
        /// way an unknown block key reads as absent.
        static func resolve(prop: String?, record: String?) -> CardStyle {
            named(prop) ?? named(record) ?? .cards
        }

        private static func named(_ value: String?) -> CardStyle? {
            switch value {
            case "cards": return .cards
            case "posters": return .posters
            case "banner": return .banner
            case "hero": return .hero
            default: return nil
            }
        }
    }

    let nodeId: String
    let title: String?
    let cards: [CardModel]
    let layout: Layout
    /// Browse is a fixed grid of landscape cards (ruled), so it keeps the default.
    var cardStyle: CardStyle = .cards
    /// Shown instead of the cards when the resource is served but empty.
    let emptyMessage: String?
    /// The season filter chips, in authored order. Empty draws no filter.
    var seasons: [Season] = []
    /// How many lines a card title may take.
    var titleLines = 1

    /// The cards one season chip shows. nil is "All".
    func cards(inSeason seasonId: String?) -> [CardModel] {
        guard let seasonId else { return cards }
        return cards.filter { $0.seasonId == seasonId }
    }
}

struct ScheduleModel: Equatable {
    struct Entry: Identifiable, Hashable {
        /// How a row takes a press. Every row is a focus stop, so the D-pad can reach the strip
        /// below the player (awe#5036).
        enum Kind: Equatable {
            /// The on-air row: plays the channel's livestream full screen.
            case live(PlaybackRequest)
            /// Opens its episode, like an episode card.
            case linked(CardTarget)
            /// Shows its data only. A press does nothing.
            case information
        }

        let id: String
        let time: String?
        let title: String
        /// The episode's show. nil when it is not served, or says the same as `title`.
        var showTitle: String? = nil
        /// A row opens its episode, like an episode card. A title-only row has no episode
        /// record, so it is `nil`.
        var target: CardTarget?
        /// The episode image, else the show's. `nil` draws a placeholder in the same slot.
        var imageURL: URL?
        var blurhash: String?
        /// The on-air broadcast. It draws first and larger, with "Now" for its time.
        var isCurrent: Bool = false
        /// The served window. The clock tick reads it (`ScheduleModel.entries(at:)`).
        var startsAt: Date? = nil
        var endsAt: Date? = nil
        /// The channel's livestream, set by `ScheduleModel.entries(at:)` on the on-air row only.
        var live: PlaybackRequest? = nil

        /// The on-air row plays the livestream; without one it falls back to its episode.
        var kind: Kind {
            if let live { return .live(live) }
            return target.map(Kind.linked) ?? .information
        }

        /// How far the broadcast is through its window, 0...1. nil without both bounds.
        func progress(at now: Date) -> Double? {
            guard let startsAt, let endsAt, endsAt > startsAt else { return nil }
            return min(max(now.timeIntervalSince(startsAt) / endsAt.timeIntervalSince(startsAt), 0), 1)
        }
    }

    let title: String
    /// As served: `current` first, then `items`. The view reads `entries(at:)`.
    let entries: [Entry]
    let emptyMessage: String?
    /// The channel's livestream request, the same one `LivestreamPlayer` opens
    /// (`PlaybackService.liveRequest`). nil: the on-air row keeps its episode target.
    var live: PlaybackRequest? = nil

    /// The rows to draw at `now`, from the served windows and no network call: a row whose
    /// `endsAt` has passed is dropped, and the first row whose window holds `now` is the
    /// current one. A row without both bounds keeps the flag it was served with. The current
    /// row carries the livestream, so the live action moves with the clock.
    func entries(at now: Date) -> [Entry] {
        Self.entries(entries, at: now, live: live)
    }

    /// The rule above for any served rows. The player's Schedule tab reads it too (awe#6553).
    static func entries(_ entries: [Entry], at now: Date, live: PlaybackRequest?) -> [Entry] {
        var foundCurrent = false
        return entries.compactMap { entry in
            if let endsAt = entry.endsAt, endsAt < now { return nil }
            var entry = entry
            if let startsAt = entry.startsAt, let endsAt = entry.endsAt {
                entry.isCurrent = startsAt <= now && now <= endsAt
            }
            entry.isCurrent = entry.isCurrent && !foundCurrent
            foundCurrent = foundCurrent || entry.isCurrent
            entry.live = entry.isCurrent ? live : nil
            return entry
        }
    }
}

struct ShowDetailModel: Equatable {
    /// The block's own `title` prop, drawn as a section heading. nil when empty.
    var heading: String? = nil
    /// nil when `showTitle` is off.
    let title: String?
    /// Drawn under the title when the contract serves it. Absent means no line at all.
    let subtitle: String?
    let abstract: String?
    let paragraphs: [String]
    let imageURL: URL?
    let blurhash: String?
    /// `showTrailer`, only when the trailer resolves to a source this device can play.
    var trailer: PlaybackRequest? = nil
    /// The primary age rating's text (`AgeRatingFormat`), drawn as a badge under the title. nil
    /// when the title is off or nothing is served.
    var ageRating: String? = nil
    /// The Watch later toggle (awe#6869). Like the badge, only with the title. nil draws none.
    var watchLater: SavedItem? = nil
    /// The Like button (awe#6871), `MovieDetail` only, with the title. nil draws none.
    var like: SavedItem? = nil
    /// `MovieDetail` only (awe#6870), beside the badge and under the same gates. nil draws nothing.
    /// The served language label ("Deutsch").
    var language: String? = nil
    /// The quality badge text: "720p", "1080p" or "4K".
    var videoQuality: String? = nil
    /// The genre titles, joined ("Drama, Family").
    var genres: String? = nil
}

/// `ShowMeta`: label / value rows, in the web block's order. A row with no value is left out.
struct ShowMetaModel: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
        /// What VoiceOver reads for the value, when it differs from the drawn text ("Original
        /// version, Subtitles" for "OV, CC"). nil reads `value`.
        var spokenValue: String? = nil
    }

    let rows: [Row]
}

struct TextModel: Equatable {
    enum Style: Equatable { case heading(level: Int), paragraph, quote }

    let text: String
    let style: Style

    init(text: String, as tag: String?) {
        self.text = text
        switch tag {
        case "h1": style = .heading(level: 1)
        case "h2": style = .heading(level: 2)
        case "h3": style = .heading(level: 3)
        case "h4": style = .heading(level: 4)
        case "h5": style = .heading(level: 5)
        case "h6": style = .heading(level: 6)
        case "blockquote": style = .quote
        default: style = .paragraph
        }
    }
}

struct ButtonModel: Equatable {
    let label: String
    /// Only `linkType: "screen"` opens anything on a TV. Any other link type renders a
    /// focusable that reports itself and goes nowhere.
    let screenId: String?
    let screenParam: String?
    let linkType: String?
    let disabled: Bool
}

/// `Divider`: a static line. Not focusable.
struct DividerModel: Equatable {
    /// The line thickness in points, from the stored height key.
    let thickness: CGFloat
}

/// `Badge`: a label chip with an optional icon. Not focusable: the D-pad cannot reach it, so
/// its `screen` link is ignored.
struct BadgeModel: Equatable {
    let label: String
    /// The SF Symbol for the authored icon. nil draws the label alone.
    let symbol: String?
}

/// `Header`: a kicker, a title and a subtitle, and an optional link row. Only a `screen` link
/// with a target and a label draws the row; it is the `Button`'s link, so it takes focus.
struct HeaderModel: Equatable {
    let kicker: String?
    let title: String?
    /// The title's heading level, from `as` (h1–h3).
    let level: Int
    let subtitle: String?
    let link: ButtonModel?
}

/// `RichText`: read-only prose from a Tiptap doc. tvOS opens no URLs, so a link is plain text.
struct RichTextModel: Equatable {
    /// One run of text and the marks the TV draws.
    struct Run: Equatable {
        enum Mark: Equatable, Hashable { case bold, italic, underline, strike }

        let text: String
        var marks: Set<Mark> = []
    }

    indirect enum Block: Equatable {
        case paragraph([Run])
        case heading(level: Int, [Run])
        /// Each item is the blocks of one list item.
        case list(ordered: Bool, start: Int, items: [[Block]])
        case quote([Block])
        case rule
    }

    let blocks: [Block]

    /// The prose as plain lines, for VoiceOver.
    var plainText: String {
        RichTextModel.lines(blocks).joined(separator: "\n")
    }

    private static func lines(_ blocks: [Block]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case let .paragraph(runs), let .heading(_, runs):
                return [runs.map(\.text).joined()]
            case let .list(ordered, start, items):
                return items.enumerated().flatMap { index, item in
                    let marker = ordered ? "\(start + index)." : "•"
                    return lines(item).enumerated().map { $0.offset == 0 ? "\(marker) \($0.element)" : $0.element }
                }
            case let .quote(inner):
                return lines(inner)
            case .rule:
                return []
            }
        }
    }
}

/// The `LivestreamPlayer` card. Nothing plays inline: Select opens `request` full screen
/// (awe#5044). An on-demand episode draws a `PlayActionModel` instead.
struct PlayerModel: Equatable {
    let nodeId: String
    let request: PlaybackRequest
    /// The served `broadcastsLive` rows, with stage-width art. The card draws the one on air.
    var broadcasts: [ScheduleModel.Entry] = []

    /// The broadcast on air at `now`, by the same clock rule as the schedule strip.
    func onAir(at now: Date) -> ScheduleModel.Entry? {
        ScheduleModel.entries(broadcasts, at: now, live: nil).first(where: \.isCurrent)
    }
}

/// An on-demand `EpisodePlayer`: the poster and one action (ruled 2026-09-23). Nothing plays
/// inline; the action opens the full-screen player.
struct PlayActionModel: Equatable {
    let nodeId: String
    let posterURL: URL?
    /// nil when no source can play on this device.
    let request: PlaybackRequest?
    /// "Play", or "Resume" when device-local progress holds a resume point. nil with no request.
    let label: String?
    /// Drawn where the button would be when there is no request.
    let message: String?
}

/// `EpisodeDetail`: text only, the same parts as the web block (no image, ruled 2026-09-23).
/// A part its prop hides, or the contract does not serve, is nil.
struct EpisodeDetailModel: Equatable {
    let title: String?
    let showTitle: String?
    /// `episodeDetail.episodeViews`. nil when hidden or zero.
    let views: Int?
    let abstract: String?
    let paragraphs: [String]
    /// "Go to show": the show by the card convention. nil when the show has no id.
    var showTarget: CardTarget? = nil
    /// The primary age rating's text (`AgeRatingFormat`), drawn as a badge. Like the language, only
    /// the instance that draws the heading carries it. nil draws no badge.
    var ageRating: String? = nil
    /// `episodeDetail.language`, a ready display label the server resolves. nil draws no line.
    var language: String? = nil
    /// The Watch later toggle (awe#6869). Like Go to show, only with the heading. nil draws none.
    var watchLater: SavedItem? = nil
    /// The Like button (awe#6871), beside the toggle and under the same gate. nil draws none.
    var like: SavedItem? = nil
}

/// `MediaSearch` (awe#5947): a search field and its results. The view asks the search route of
/// its own node. The `collectionTiles` resource (awe#5956) gives the tiles for an empty field.
struct MediaSearchModel: Equatable {
    let nodeId: String
    /// Editor-picked Collection cards, in served order. Empty draws nothing.
    var tiles: [CardModel] = []

    /// The "Categories" grid under the field. Only an empty field (after trimming) shows it
    /// (D7): one character shows neither the tiles nor results. nil when there are no tiles.
    func tileGrid(for text: String) -> ShelfModel? {
        guard !tiles.isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ShelfModel(nodeId: "\(nodeId)-tiles", title: ChromeText.string(.categoriesLabel), cards: tiles,
                          layout: .grid, emptyMessage: nil)
    }
}

struct ImageModel: Equatable {
    let url: URL
    let blurhash: String?
}

/// `MovieCast` and `MovieCrew` (awe#7035): a heading and a row of person tiles, as the Apple TV
/// "Cast & Crew" row. Each tile is a focus stop, so the D-pad can scroll the row. Select does
/// nothing. Empty draws nothing: the evaluator then answers nil.
struct PeopleRowModel: Equatable {
    struct Tile: Identifiable, Equatable {
        /// Unique in the row: one person can play two roles, or sit in two crew groups.
        let id: String
        let name: String
        /// The cast role, or the crew job label. nil draws no line.
        let role: String?
        /// The round photo. nil draws the neutral circle.
        let imageURL: URL?
    }

    let heading: String
    let tiles: [Tile]
}

/// The Background panel of a layout block (awe#6239): one color, and one image over it. The
/// children draw over both. The `tv` design offers no gradient, opacity, layer list or dark
/// variant.
struct LayoutBackground: Equatable {
    struct Image: Equatable {
        let url: URL
        let alignment: BackgroundAlignment
    }

    let color: RGBAColor?
    let image: Image?

    /// nil when there is nothing to draw, so a block with no background keeps its old content.
    init?(color: RGBAColor?, image: Image?) {
        guard color != nil || image != nil else { return nil }
        self.color = color
        self.image = image
    }
}

/// Where a cover-sized background image sits in its block. `x` and `y` go from 0 (leading,
/// top) to 1 (trailing, bottom), as the CSS `background-position` percents do.
struct BackgroundAlignment: Equatable {
    let x: Double
    let y: Double

    static let center = BackgroundAlignment(x: 0.5, y: 0.5)
}

/// The layout styling of `Section`, `Container` and `Box` (awe#6297), in points. The default
/// value draws as a plain stack: no padding, no border, children stretched across, packed at
/// the start. The `tv` editor canvas is 1920 px wide, the tvOS stage is 1920 pt, so 1 px = 1 pt.
struct LayoutStyle: Equatable {
    /// `align`: where the children sit across the axis. `stretch` (the default, as RN
    /// `alignItems`) makes a layout child fill the cross axis; a content block keeps its size.
    enum Align { case start, center, end, baseline, stretch }
    /// `justify`: how the free space along the axis is spread.
    enum Justify { case start, center, end, between, around, evenly }

    struct Insets: Equatable {
        var top: CGFloat = 0
        var right: CGFloat = 0
        var bottom: CGFloat = 0
        var left: CGFloat = 0
    }

    struct Corners: Equatable {
        var topLeft: CGFloat = 0
        var topRight: CGFloat = 0
        var bottomLeft: CGFloat = 0
        var bottomRight: CGFloat = 0
    }

    struct Border: Equatable {
        enum Line { case solid, dashed, dotted }
        let widths: Insets
        let color: RGBAColor
        let line: Line
    }

    var padding = Insets()
    var minHeight: CGFloat?
    /// The Box `height`. A block with a height does not stretch to the row height.
    var height: CGFloat?
    var align = Align.stretch
    var justify = Justify.start
    var border: Border?
    var radius = Corners()

    /// Padding plus the border widths: the children start inside both, as with CSS
    /// `box-sizing: border-box`.
    var contentInsets: Insets {
        let widths = border?.widths ?? Insets()
        return Insets(top: padding.top + widths.top, right: padding.right + widths.right,
                      bottom: padding.bottom + widths.bottom, left: padding.left + widths.left)
    }
}

/// What a block key resolved to. `nil` from the evaluator means the block rendered
/// nothing — the Swift equal of a React renderer returning `null`.
enum BlockContent: Equatable {
    enum Axis { case vertical, horizontal }

    /// A layout node. Its children render inside it, over its background.
    case stack(axis: Axis, background: LayoutBackground? = nil, style: LayoutStyle = LayoutStyle())
    /// The layout's one content slot: the screen tree renders here, over its background.
    case contentSlot(background: LayoutBackground? = nil)
    case text(TextModel)
    case image(ImageModel)
    case button(ButtonModel)
    case divider(DividerModel)
    case badge(BadgeModel)
    case header(HeaderModel)
    case richText(RichTextModel)
    case shelf(ShelfModel)
    case schedule(ScheduleModel)
    case player(PlayerModel)
    case playAction(PlayActionModel)
    case detail(ShowDetailModel)
    case episodeDetail(EpisodeDetailModel)
    case showMeta(ShowMetaModel)
    case mediaSearch(MediaSearchModel)
    case people(PeopleRowModel)
    /// A sentence where a block has nothing to draw but must not vanish.
    case message(String)
}

/// One node of the evaluated tree. `content == nil` is "rendered null"; its children are
/// not evaluated, the same way a React `null` never renders its children.
struct EvaluatedNode: Identifiable {
    let id: String
    let key: BlockKey
    let content: BlockContent?
    let children: [EvaluatedNode]
}

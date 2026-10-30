// cspell:ignore subview subviews Subviews TVUI
import SwiftUI

/// Draws one evaluated node and its children.
///
/// Every decision about *what* is on screen was made by `BlockRegistry`; this file only
/// decides how it looks. `slot` is the layout's content slot — the
/// screen tree renders there.
struct NodeView: View {
    let node: EvaluatedNode
    var slot: AnyView?
    /// How the parent stack stretches this node (awe#6297). Only a layout block stretches; a
    /// content block keeps its own size, so focusable chrome does not grow.
    var stretch = Stretch.none

    enum Stretch { case none, width, height }

    @Environment(\.appTheme) private var theme
    @Environment(AppRouter.self) private var router

    var body: some View {
        switch node.content {
        case let .stack(axis, background, style):
            // No `if` around the stack: a background that comes or goes on a refresh must not
            // replace the subtree (scroll position and state).
            stack(axis, style)
                .padding(EdgeInsets(style.contentInsets))
                // The stretch is inside the background, so the background fills it. A block with
                // a fixed height keeps it, as CSS `align-items: stretch` does.
                .frame(maxWidth: stretch == .width ? .infinity : nil,
                       maxHeight: stretch == .height && style.height == nil ? .infinity : nil,
                       alignment: .topLeading)
                .background {
                    // Nothing to draw adds no view: an empty background view still adds an
                    // accessibility container, and over the layout slot it hid the tab bar from
                    // the hit test.
                    if background != nil || style.border != nil {
                        LayoutDecorationView(background: background, style: style)
                    }
                }

        case let .contentSlot(background):
            // The screen paints its own page color, so it draws the slot color (`ScreenBody`).
            slot.environment(\.contentSlotColor, background?.color)

        case let .text(model):
            TextBlockView(model: model)

        case let .image(model):
            RemoteImage(url: model.url, blurhash: model.blurhash, contentMode: .fit)
                .frame(maxWidth: 960)

        case let .button(model):
            ScreenLinkButton(model: model)

        case let .divider(model):
            DividerBlockView(model: model)

        case let .badge(model):
            BadgeBlockView(model: model)

        case let .header(model):
            HeaderBlockView(model: model)

        case let .richText(model):
            RichTextBlockView(model: model)

        case let .shelf(model):
            ShelfView(model: model)

        case let .schedule(model):
            ScheduleView(model: model)

        case let .player(model):
            LiveCardView(model: model)

        case let .playAction(model):
            PlayActionView(model: model)

        case let .detail(model):
            ShowDetailBlockView(model: model)

        case let .episodeDetail(model):
            EpisodeDetailBlockView(model: model)

        case let .showMeta(model):
            ShowMetaBlockView(model: model)

        case let .mediaSearch(model):
            MediaSearchView(model: model)

        case let .people(model):
            PeopleRowView(model: model)

        case let .message(text):
            Text(text)
                .font(.system(size: Layout.text(26)))
                .foregroundStyle(theme.textSecondary)

        case nil:
            EmptyView()
        }
    }

    /// The children in a `FlexStackLayout`. The gaps are the minimum gap, as CSS `gap` with
    /// `justify-content` (awe#6297). A row of a detail block or a player is a column on a phone:
    /// authors place them side by side for a 1920 pt stage.
    private func stack(_ axis: BlockContent.Axis, _ style: LayoutStyle) -> some View {
        let insets = style.contentInsets
        // `box-sizing: border-box`: the heights include the padding and the border.
        let inner = { (height: CGFloat?) in height.map { max(0, $0 - insets.top - insets.bottom) } }
        let stretches = style.align == .stretch
        let axis = node.children.contains(where: \.isWideBlock) ? .vertical : axis
        return FlexStackLayout(axis: axis, spacing: axis == .horizontal ? Layout.rowGap : Layout.columnGap, justify: style.justify,
                               align: style.align, minHeight: inner(style.minHeight), height: inner(style.height),
                               fillsWidth: stretch == .width, fillsHeight: stretch == .height && style.height == nil) {
            ForEach(node.children) { child in
                if axis == .horizontal {
                    NodeView(node: child, slot: slot, stretch: stretches ? .height : .none)
                        .frame(maxHeight: .infinity, alignment: Self.rowAlignment(style.align))
                } else {
                    NodeView(node: child, slot: slot, stretch: stretches ? .width : .none)
                }
            }
        }
    }

    private static func rowAlignment(_ align: LayoutStyle.Align) -> Alignment {
        switch align {
        case .center: return .center
        case .end: return .bottom
        // `FlexStackLayout` moves a baseline child down by its offset.
        case .start, .baseline, .stretch: return .top
        }
    }
}

// MARK: - Layout backgrounds

/// The background clipped to the corner radius, then the border over it (awe#6239, awe#6297).
/// The children draw over both and are not clipped.
private struct LayoutDecorationView: View {
    let background: LayoutBackground?
    let style: LayoutStyle

    var body: some View {
        let shape = LayoutCornerShape(corners: style.radius)
        ZStack {
            if let background {
                LayoutBackgroundView(background: background).clipShape(shape)
            }
            if let border = style.border {
                LayoutBorderView(border: border, shape: shape)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Four equal sides stroke the corner shape. Sides of different widths draw one line each,
/// cut to the corner shape.
private struct LayoutBorderView: View {
    let border: LayoutStyle.Border
    let shape: LayoutCornerShape

    var body: some View {
        let widths = border.widths
        let color = Color(border.color)
        if widths.top == widths.right, widths.top == widths.bottom, widths.top == widths.left {
            shape.strokeBorder(color, style: stroke(widths.top))
        } else {
            ZStack {
                ForEach([(Edge.top, widths.top), (.trailing, widths.right), (.bottom, widths.bottom),
                         (.leading, widths.left)].filter { $0.1 > 0 }, id: \.0) { side in
                    LayoutBorderSide(edge: side.0, width: side.1).stroke(color, style: stroke(side.1))
                }
            }
            .clipShape(shape)
        }
    }

    private func stroke(_ width: CGFloat) -> StrokeStyle {
        switch border.line {
        case .solid: return StrokeStyle(lineWidth: width)
        case .dashed: return StrokeStyle(lineWidth: width, dash: [width * 3, width * 2])
        case .dotted: return StrokeStyle(lineWidth: width, lineCap: .round, dash: [0, width * 2])
        }
    }
}

private extension EdgeInsets {
    init(_ insets: LayoutStyle.Insets) {
        self.init(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }
}

/// The color, then the image over it, sized to cover the block at its alignment and clipped to
/// the block. Decoration only: no hit tests, hidden from VoiceOver. An image that does
/// not load draws nothing, so the color shows.
private struct LayoutBackgroundView: View {
    let background: LayoutBackground

    var body: some View {
        ZStack {
            if let color = background.color {
                Color(color)
            }
            if let image = background.image {
                // `Color.clear` keeps the block size; the cover-sized image overflows it at its
                // alignment. A `.frame(maxWidth: .infinity)` would grow to the image instead.
                Color.clear.overlay(alignment: Alignment(image.alignment)) {
                    RemoteImage(url: image.url, blurhash: nil, contentMode: .fill, drawsPlaceholder: false)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Alignment {
    init(_ alignment: BackgroundAlignment) {
        self.init(
            horizontal: alignment.x < 0.5 ? .leading : (alignment.x > 0.5 ? .trailing : .center),
            vertical: alignment.y < 0.5 ? .top : (alignment.y > 0.5 ? .bottom : .center)
        )
    }
}

/// The `ContentPlaceholder` color of the layout around a screen. nil draws the page color only.
private struct ContentSlotColorKey: EnvironmentKey {
    static let defaultValue: RGBAColor? = nil
}

extension EnvironmentValues {
    var contentSlotColor: RGBAColor? {
        get { self[ContentSlotColorKey.self] }
        set { self[ContentSlotColorKey.self] = newValue }
    }
}

// MARK: - Content blocks

private struct TextBlockView: View {
    let model: TextModel

    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(model.text)
            .font(font)
            .foregroundStyle(model.style == .paragraph ? theme.textSecondary : theme.textPrimary)
            .frame(maxWidth: 1200, alignment: .leading)
    }

    private var font: Font {
        switch model.style {
        case let .heading(level): return BlockFont.heading(level: level, theme: theme)
        case .paragraph, .quote: return BlockFont.body(theme: theme)
        }
    }
}

/// The text faces of the content blocks: `SimpleText`, `Header` and `RichText` share them.
enum BlockFont {
    static func heading(level: Int, theme: AppTheme) -> Font {
        let sizes: [CGFloat] = [28, 24, 21, 19, 17, 15]
        let size = sizes[min(max(level, 1), 6) - 1]
        if let name = theme.headingFont {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: level <= 2 ? .bold : .semibold)
    }

    /// The preset body face when set, else the system face at `weight`. `size` is the tvOS size.
    static func body(theme: AppTheme, size: CGFloat = 28, weight: Font.Weight = .regular) -> Font {
        let size = Layout.text(size)
        if let name = theme.bodyFont {
            let face = Font.custom(name, size: size)
            return weight == .regular ? face : face.weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

/// The Button block, and the link row of a `Header`. Only `linkType: "screen"` opens anything,
/// as on tvOS: an external link needs its own review on a phone.
struct ScreenLinkButton: View {
    let model: ButtonModel

    @Environment(AppRouter.self) private var router

    var body: some View {
        Button(model.label) {
            guard model.linkType == "screen" else {
                print("[tv] Button link type \"\(model.linkType ?? "none")\" does not open on TV")
                return
            }
            router.open(screenId: model.screenId, param: model.screenParam)
        }
        .disabled(model.disabled)
    }
}

struct ShelfView: View {
    let model: ShelfModel

    @Environment(\.appTheme) private var theme
    @Environment(\.loadNextPage) private var loadNextPage
    /// The season chip in use. nil is "All".
    @State private var season: String?

    /// The grid's measured width. nil until the first layout.
    @State private var gridAvailableWidth: CGFloat?

    private let gridSpacing = GridColumns.spacing
    /// As many columns as fit the width the grid gets.
    private var gridColumns: Int { GridColumns.count(width: gridAvailableWidth, metrics: model.gridMetrics) }
    private var gridCardWidth: CGFloat {
        GridColumns.cardWidth(width: gridAvailableWidth, columns: gridColumns, metrics: model.gridMetrics)
    }
    private var gridWidth: CGFloat { CGFloat(gridColumns) * gridCardWidth + CGFloat(gridColumns - 1) * gridSpacing }

    /// The shape ONE card draws: its own card style.
    private func shape(of card: CardModel) -> CardShape {
        switch card.style {
        case .cards: return .wide
        case .posters: return .poster
        case .banner: return .banner
        case .hero: return .hero
        }
    }

    /// The row keeps one height: a portrait card's as soon as one card is a poster.
    private var rowShape: CardShape {
        if model.cards.contains(where: { $0.style == .posters }) { return .poster }
        switch model.cardStyle {
        case .banner: return .banner
        case .hero: return .hero
        case .cards, .posters: return .wide
        }
    }

    var body: some View {
        if model.cardStyle == .hero, model.emptyMessage == nil, !model.cards.isEmpty {
            HeroShelfView(model: model)
        } else {
            shelf
        }
    }

    /// A card of the last rows that appears asks for the next page. The store gates it: paging
    /// served, has more, one at a time.
    private func pageIfLast(_ card: CardModel, in visible: [CardModel]) {
        guard let index = visible.firstIndex(where: { $0.id == card.id }),
              GridPaging.triggers(index: index, count: visible.count, columns: gridColumns) else { return }
        loadNextPage?(model.nodeId)
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = model.title, !title.isEmpty {
                ShelfHeading(title: title)
                    // UI tests find a header by id: a search grid's title is chrome text.
                    .accessibilityIdentifier("shelf-title-\(model.nodeId)")
            }

            if let message = model.emptyMessage {
                Text(message)
                    .font(.system(size: Layout.text(26)))
                    .foregroundStyle(theme.textSecondary)
            } else if model.layout == .grid {
                if !model.seasons.isEmpty {
                    SeasonChips(seasons: model.seasons, selected: $season)
                }
                let visible = model.cards(inSeason: season)
                LazyVStack(alignment: .leading, spacing: gridSpacing) {
                    ForEach(Array(stride(from: 0, to: visible.count, by: gridColumns)), id: \.self) { start in
                        // Top-aligned: a poster grid's no-poster card is shorter. Every card of any
                        // other grid has one height, so it draws as before.
                        HStack(alignment: .top, spacing: gridSpacing) {
                            ForEach(visible[start..<min(start + gridColumns, visible.count)]) { card in
                                CardButton(card: card, shape: model.gridShape(card), width: gridCardWidth,
                                           titleLines: model.titleLines)
                                    .onAppear { pageIfLast(card, in: visible) }
                            }
                        }
                        .frame(width: gridWidth, alignment: .leading)
                    }
                }
                // Takes the offered width and no more, so the rows never set the shelf's width.
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridAvailableWidth = $0 }
            } else if model.layout == .list {
                if !model.seasons.isEmpty {
                    SeasonChips(seasons: model.seasons, selected: $season)
                }
                let visible = model.cards(inSeason: season)
                // All cards, not the filtered ones, so a chip never moves the columns.
                let numbered = model.cards.contains { $0.number != nil }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, card in
                        if index > 0 {
                            Rectangle().fill(theme.surfaceSelected).frame(height: 1)
                        }
                        EpisodeListRow(card: card, numbered: numbered)
                            .onAppear { pageIfLast(card, in: visible) }
                    }
                }
            } else if model.layout == .sidewaysGrid {
                // Two rows that scroll sideways together (a Collection record with `listLayout:
                // "grid"`). The cards fill each column top to bottom, so the order reads left to
                // right. Page 1 only, as a row. One card draws one row.
                let rows = model.cards.count < 2 ? 1 : 2
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(rowShape.shelfHeight), spacing: gridSpacing,
                                                              alignment: .top), count: rows),
                              alignment: .top, spacing: Layout.cardGap) {
                        ForEach(model.cards) { card in
                            CardButton(card: card, shape: shape(of: card))
                        }
                    }
                    .padding(.horizontal, Layout.screenMargin)
                }
                .frame(height: CGFloat(rows) * rowShape.shelfHeight + CGFloat(rows - 1) * gridSpacing)
                .padding(.horizontal, -Layout.screenMargin)
                // UI tests find the grid by id; the cards inside keep their own labels.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sideways-grid-\(model.nodeId)")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Layout.cardGap) {
                        ForEach(model.cards) { card in
                            CardButton(card: card, shape: shape(of: card))
                        }
                    }
                    .padding(.horizontal, Layout.screenMargin)
                }
                .frame(height: rowShape.shelfHeight)
                .padding(.horizontal, -Layout.screenMargin)
            }
        }
    }
}

/// A shelf's title, as the website draws it: uppercase with wide letter spacing.
struct ShelfHeading: View {
    let title: String

    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 17, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(theme.textPrimary)
            .lineLimit(2)
    }
}

/// One `EpisodesList` list row: the episode number, a 16:9 thumbnail, then the title, the duration
/// and the abstract (2 lines). The whole row is one button.
private struct EpisodeListRow: View {
    let card: CardModel
    /// Reserves the number column. True when any row of the list has a number.
    let numbered: Bool

    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            router.select(card.target)
        } label: {
            EpisodeListRowFace(card: card, numbered: numbered)
        }
        .buttonStyle(PressableCardStyle())
        .modifier(SelectionCue(target: card.target))
        .modifier(CardMenuModifier(menu: card.menu))
        .accessibilityLabel(card.title)
    }
}

private struct EpisodeListRowFace: View {
    let card: CardModel
    let numbered: Bool

    @Environment(\.appTheme) private var theme

    private let thumbnail = CGSize(width: 128, height: 72)

    var body: some View {
        // The text starts at the thumbnail's top; the number stays centered on the thumbnail.
        HStack(alignment: .top, spacing: 12) {
            if numbered {
                Text(card.number.map(String.init) ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 24, height: thumbnail.height)
                    .accessibilityHidden(true)
            }
            RemoteImage(url: card.imageURL, blurhash: card.blurhash)
                .frame(width: thumbnail.width, height: thumbnail.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                // An `EpisodesList` card's subtitle is its duration, or nil.
                if let duration = card.subtitle {
                    Text(duration)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                if let abstract = card.abstract {
                    Text(abstract)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

extension ScheduleModel.Entry {
    /// What Select on this row does. The on-air row plays the livestream (`router.play`, never
    /// tap-to-play). The on-air row with no live source keeps its link (`openCard`, rule 7).
    /// Another linked row is a card press with tap-to-play. An information row does nothing.
    @MainActor
    func press(router: AppRouter) {
        switch kind {
        case let .live(request):
            router.play(request)
        case let .linked(target):
            if isCurrent {
                router.openCard(target)
            } else {
                router.select(target)
            }
        case .information:
            break
        }
    }
}

/// One schedule row: the thumbnail, the title and the show, the time at the right. A linked row
/// shows `play.fill` beside its time and goes through the same `select` path a card uses
/// (tap-to-play). A title-only row is not a button: a press does nothing.
///
/// Every row has the same size: the thumbnail slot is always there, and a row with no image
/// draws a placeholder in it. The on-air row is larger, says "Now" in the accent color, and
/// draws its progress through the broadcast.
///
/// The live player's schedule draws its information rows with this view too (awe#6553).
struct ScheduleRow: View {
    let entry: ScheduleModel.Entry
    let now: Date

    @Environment(\.appTheme) private var theme
    @Environment(AppRouter.self) private var router

    var body: some View {
        switch entry.kind {
        case .live:
            Button {
                entry.press(router: router)
            } label: {
                face(linked: true)
            }
            .buttonStyle(PressableCardStyle())
            .accessibilityLabel(label)
        case let .linked(target):
            Button {
                entry.press(router: router)
            } label: {
                face(linked: true)
            }
            .buttonStyle(PressableCardStyle())
            .modifier(SelectionCue(target: target))
            .accessibilityLabel(label)
        case .information:
            face(linked: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    private var label: String {
        entry.isCurrent ? ChromeText.string(.onNowTitle, ["title": entry.title]) : entry.title
    }

    private var thumbnail: CGSize { ScheduleRowMetrics.thumbnail(isCurrent: entry.isCurrent) }

    private func face(linked: Bool) -> some View {
        HStack(alignment: .center, spacing: ScheduleRowMetrics.spacing) {
            thumbnailView
            VStack(alignment: .leading, spacing: 2) {
                if entry.isCurrent {
                    Text(ChromeText.string(.now))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 4))
                }
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let show = entry.showTitle {
                    Text(show)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                if entry.isCurrent, let progress = entry.progress(at: now) {
                    ProgressBar(fraction: progress)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            timeLine(linked: linked)
        }
        .padding(ScheduleRowMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ScheduleRowMetrics.rowHeight(isCurrent: entry.isCurrent))
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The slot is always reserved, so every row keeps one size.
    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let url = entry.imageURL {
                RemoteImage(url: url, blurhash: entry.blurhash)
            } else {
                ZStack {
                    theme.surfaceSelected
                    Image(systemName: "tv")
                        .font(.system(size: entry.isCurrent ? 28 : 20))
                        .foregroundStyle(theme.textSecondary)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(width: thumbnail.width, height: thumbnail.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func timeLine(linked: Bool) -> some View {
        HStack(spacing: 4) {
            if linked {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
            }
            Text(entry.time ?? "")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
        }
        .foregroundStyle(theme.accent)
    }
}

/// The fixed sizes of a schedule row. A row's size depends only on whether it is the on-air
/// row, never on its image or its text, so every row of the list is the same size.
enum ScheduleRowMetrics {
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 12

    static func thumbnail(isCurrent: Bool) -> CGSize {
        isCurrent ? CGSize(width: 128, height: 72) : CGSize(width: 96, height: 54)
    }

    /// Two title lines, the show line, and on the on-air row the badge and the progress fit.
    static func rowHeight(isCurrent: Bool) -> CGFloat {
        isCurrent ? 108 : 80
    }
}

private struct ProgressBar: View {
    let fraction: Double

    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.textSecondary.opacity(0.35))
                Capsule().fill(theme.accent).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A press hands the item's type and id to the router, which resolves the Template Screen — the
/// view never builds a route. An episode plays at once when it can (`AppRouter.select`,
/// tap-to-play).
private struct CardButton: View {
    let card: CardModel
    let shape: CardShape
    var width: CGFloat?
    var titleLines = 1

    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            router.select(card.target)
        } label: {
            // The shape names the hit area: the blurred backdrop of fallback art takes no touches.
            MediaCard(card: card, shape: shape, width: width, titleLines: titleLines)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableCardStyle())
        .modifier(SelectionCue(target: card.target))
        .modifier(CardMenuModifier(menu: card.menu))
        .accessibilityLabel(card.accessibilityLabel(shape: shape))
        .modifier(BannerCardIdentifier(enabled: shape == .banner))
    }
}

/// A banner card draws no text, so UI tests find it by the id `banner-card`. Other cards keep no
/// identifier.
private struct BannerCardIdentifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityIdentifier("banner-card")
        } else {
            content
        }
    }
}

/// The long-press menu of a card (ADR-0259 §5). It reads the saved state when it draws, so it
/// offers "Watch later" or "Remove from Watch later". On the Watch later shelf it offers "Remove".
/// An episode or movie card also offers "Like" or "Unlike" (awe#6871). A card with no menu gets
/// no context menu at all.
private struct CardMenuModifier: ViewModifier {
    let menu: CardMenu?

    @Environment(SavedItemList.self) private var watchLater
    @Environment(Likes.self) private var likes

    func body(content: Content) -> some View {
        if let menu {
            content.contextMenu {
                switch menu {
                case let .watchLater(item):
                    WatchLaterButton(item: item, watchLater: watchLater)
                case let .removeFromWatchLater(item):
                    Button(ChromeText.string(.remove), systemImage: "minus.circle") {
                        Task { await watchLater.remove(item.itemType, item.itemId) }
                    }
                    .accessibilityIdentifier("watch-later-remove")
                }
                if let item = menu.likeItem {
                    let liked = likes.isLiked(item)
                    // The filled heart shows the liked state; the label names the action.
                    Button(ChromeText.string(liked ? .unlike : .like), systemImage: liked ? "heart.fill" : "heart") {
                        Task { await likes.toggle(item) }
                    }
                    .accessibilityIdentifier("card-like")
                }
            }
        } else {
            content
        }
    }
}

/// "Watch later", or "Remove from Watch later" when the item is saved. One control for the card
/// menu and the detail toggle. An unknown state (signed in, the list did not load) offers the
/// save: a `PUT` of a saved item changes nothing.
struct WatchLaterButton: View {
    let item: SavedItem
    let watchLater: SavedItemList
    /// Author labels (`MovieHero` `watchlistLabel`, `watchlistSavedLabel`). nil draws the chrome
    /// strings. A saved item with no saved label takes `label`, as on the web.
    var label: String? = nil
    var savedLabel: String? = nil

    var body: some View {
        let saved = watchLater.isSaved(item.itemType, item.itemId) == true
        Button(Self.title(saved: saved, label: label, savedLabel: savedLabel),
               systemImage: saved ? "checkmark" : "plus") {
            Task {
                if saved {
                    await watchLater.remove(item.itemType, item.itemId)
                } else {
                    await watchLater.save(item)
                }
            }
        }
        .accessibilityIdentifier("watch-later")
        .accessibilityValue(saved ? "saved" : "")
    }

    /// The button text. An author label wins; a saved item with no saved label takes `label`, as
    /// on the web. nil labels draw the chrome strings.
    static func title(saved: Bool, label: String?, savedLabel: String?) -> String {
        saved
            ? savedLabel ?? label ?? ChromeText.string(.removeFromWatchLater)
            : label ?? ChromeText.string(.watchLater)
    }
}

/// The Watch later toggle of a detail block (awe#6869). Signed in with no loaded list, it asks
/// `/contains` for its one item when it shows.
private struct WatchLaterToggle: View {
    let item: SavedItem

    @Environment(SavedItemList.self) private var watchLater

    var body: some View {
        WatchLaterButton(item: item, watchLater: watchLater)
            .task(id: item.id) { await watchLater.check(item.itemType, item.itemId) }
    }
}

/// The Like button of the Episode and Movie detail blocks (awe#6871): "Like", or "Liked" with a
/// filled heart. A press toggles it. Signed in with no loaded list, it asks `/contains` when it shows.
private struct LikeToggle: View {
    let item: SavedItem

    @Environment(Likes.self) private var likes

    var body: some View {
        let liked = likes.isLiked(item)
        Button(ChromeText.string(liked ? .liked : .like), systemImage: liked ? "heart.fill" : "heart") {
            Task { await likes.toggle(item) }
        }
        .accessibilityIdentifier("like")
        .accessibilityValue(liked ? "liked" : "")
        .task(id: item.id) { await likes.list.check(item.itemType, item.itemId) }
    }
}

/// Tap-to-play: a spinner over the pressed control while its episode loads
/// (`AppRouter.selecting`). It shows after a short wait, so a screen already in memory or in the
/// cache plays with no flash.
private struct SelectionCue: ViewModifier {
    let target: CardTarget?

    @Environment(AppRouter.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var shows = false

    func body(content: Content) -> some View {
        let loading = target != nil && router.selecting == target
        content
            .overlay {
                if shows {
                    ProgressView()
                        .tint(theme.accent)
                        .accessibilityIdentifier("selection-loading")
                }
            }
            .task(id: loading) {
                shows = false
                guard loading, (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
                shows = true
            }
    }
}

/// The hero of a `hero` shelf, like the app.hopetv.de home hero: art across the whole screen, with
/// the item's logo (else its title), its abstract, a meta line, its categories and the actions over
/// the bottom of the art.
///
/// "Watch now" is the card press (`router.select`: served link first, and an episode plays at once
/// when it can); "Trailer" draws only when the trailer resolves to a playable source and plays it
/// full screen. A swipe pages through the items. The hero also goes to the next item after
/// `autoAdvanceInterval`. A hero that leads the screen draws its art up under the status bar. A
/// show with a served preview fades to its muted loop (`HeroPreviewVideo`) while `HeroPreview.Gate`
/// allows it.
private struct HeroShelfView: View {
    let model: ShelfModel

    @Environment(\.appTheme) private var theme
    @Environment(AppRouter.self) private var router
    @Environment(\.leadingHero) private var leadingHero
    @Environment(SavedItemList.self) private var watchLater
    @Environment(\.stackEntry) private var stackEntry
    @Environment(ContractStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var index = 0
    /// Between `onAppear` and `onDisappear`. A covered NavigationStack root and an unselected tab
    /// still get changes, so the preview also checks that its screen is the one on show.
    @State private var appeared = false
    /// At least half the hero is in the scroll view's visible area, as the web `useInView`.
    @State private var inView = true

    /// The time one item shows, as on the app.hopetv.de home hero (`duration: 15e3`).
    static let autoAdvanceInterval: Duration = .seconds(15)

    /// Restarts the auto-advance wait. A page change (manual or automatic) starts a full wait.
    /// The full-screen player covers this view without removing it, so the wait stops while it
    /// plays. A pushed screen removes the view, which cancels the wait. A tab out of view keeps it,
    /// so `onShow` stops the wait there.
    private struct AutoAdvance: Equatable {
        let index: Int
        let playing: Bool
    }

    private var stageWidth: CGFloat { Layout.phoneWidth }
    private var height: CGFloat { Layout.heroHeight(width: stageWidth) }
    private var columnWidth: CGFloat { stageWidth - 2 * Layout.screenMargin }

    private var card: CardModel { model.cards[min(index, model.cards.count - 1)] }
    /// This hero's screen is the one on show: not a tab out of view, not under a pushed screen.
    private var onShow: Bool { stackEntry.map { router.state.current == $0 } ?? true }

    var body: some View {
        let card = card
        let hero = card.hero
        let leads = leadingHero?.nodeId == model.nodeId
        let bleed = leads ? leadingHero?.bleed ?? 0 : 0
        let shift = leads ? leadingHero?.shift ?? 0 : 0
        // Mobile art centers the person, so the text would cover them: the logo and one button
        // draw centered under the face. The rest is on the show screen.
        let centered = mobileBanner(for: card) != nil

        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            // Only an authored title draws, as a quiet overline above the logo.
            if let title = model.title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
            }
            identity(card: card, hero: hero)
            if !centered {
                details(hero)
            }
            if let hero, let message = hero.cannotPlayMessage {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("cannot-play")
            }
            if let hero, hero.hasActions {
                if centered {
                    watchNow(card: card, hero: hero)
                        .padding(.top, 10)
                } else {
                    actions(card: card, hero: hero)
                }
            }
            if model.cards.count > 1 {
                PageDots(count: model.cards.count, index: index)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: columnWidth, alignment: centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .bottomLeading)
        .background(alignment: .top) {
            art(card: card, height: height + bleed)
                .offset(x: shift, y: -bleed)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.35), value: index)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { drag in
            guard abs(drag.translation.width) > max(abs(drag.translation.height), 40) else { return }
            page(drag.translation.width < 0 ? 1 : -1)
        })
        .task(id: AutoAdvance(index: index, playing: router.playback != nil || !onShow)) {
            guard model.cards.count > 1, router.playback == nil, onShow else { return }
            guard (try? await Task.sleep(for: Self.autoAdvanceInterval)) != nil else { return }
            page(1)
        }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .onScrollVisibilityChange(threshold: 0.5) { inView = $0 }
    }

    /// The abstract, the meta line and the categories, in the order the block serves them.
    @ViewBuilder
    private func details(_ hero: HeroModel?) -> some View {
        if let hero, hero.metaBeforeAbstract, !hero.metaParts.isEmpty {
            HeroMetaLine(parts: hero.metaParts)
        }
        if let abstract = hero?.abstract {
            Text(abstract)
                .font(.system(size: 14))
                .foregroundStyle(theme.textPrimary.opacity(0.9))
                .lineLimit(2)
        }
        if let hero, !hero.metaBeforeAbstract, !hero.metaParts.isEmpty {
            HeroMetaLine(parts: hero.metaParts)
        }
                if let categories = hero?.categories, !categories.isEmpty, let separator = hero?.tagSeparator {
            // `MovieHero` with `genresDisplay: "text"`: one line in the meta style, not chips.
            Text(categories.joined(separator: separator))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        } else if let categories = hero?.categories, !categories.isEmpty {
            OneLineRow(spacing: 8) {
                ForEach(categories, id: \.self) { category in
                    Text(category)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(theme.textPrimary.opacity(0.6), lineWidth: 1))
                        .fixedSize()
                }
            }
            .frame(width: columnWidth, alignment: .leading)
            .clipped()
        }
    }

    /// The item's `images.bannerMobile`, read from the screen's raw resource: `BlockRegistry` picks
    /// the TV `banner` and the card keeps only that URL. nil keeps the card's art.
    private func mobileBanner(for card: CardModel) -> (url: URL, blurhash: String?)? {
        guard let stackEntry else { return nil }
        let key = store.key(for: stackEntry.screenId, param: stackEntry.param)
        let resources = store.blockResources(for: key)[model.nodeId] ?? [:]
        guard let file = MobileBanner.file(recordId: card.id, in: .object(resources)),
              let url = ImageConfig(cdn: store.config.imagesCDN, bucket: store.config.imagesBucket)
                  .url(file, width: MobileBanner.artWidth) else { return nil }
        return (url, file.blurhash)
    }

    /// The preview gate for the item on show.
    private func previewGate(_ hero: HeroModel?) -> HeroPreview.Gate {
        return HeroPreview.Gate(hasSource: hero?.previewURL != nil, reduceMotion: reduceMotion,
                                playbackOpen: router.playback != nil, onScreen: appeared && onShow && inView,
                                sceneActive: scenePhase == .active)
    }

    @ViewBuilder
    private func identity(card: CardModel, hero: HeroModel?) -> some View {
        if let logo = hero?.logoURL {
            let size = Self.logoSize(aspect: hero?.logoAspect)
            RemoteImage(url: logo, blurhash: nil, contentMode: .fit, drawsPlaceholder: false)
                .frame(width: size.width, height: size.height)
                .accessibilityLabel(card.title)
        } else {
            Text(card.title)
                .font(theme.headingFont.map { .custom($0, size: 30) } ?? .system(size: 30, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    /// The logo box: at most 260 x 90 pt, the file's own aspect when it carries its size.
    static func logoSize(aspect: CGFloat?) -> CGSize {
        let box = CGSize(width: 260, height: 90)
        guard let aspect, aspect > 0 else { return box }
        return box.width * aspect <= box.height
            ? CGSize(width: box.width, height: box.width * aspect)
            : CGSize(width: box.height / aspect, height: box.height)
    }

    @ViewBuilder
    private func watchNow(card: CardModel, hero: HeroModel) -> some View {
        if let watchNow = hero.watchNow {
            Button {
                switch watchNow {
                case .select: router.select(card.target)
                case let .play(request, _): router.play(request)
                }
            } label: {
                Label(watchNow.label, systemImage: "play.fill")
            }
            .buttonStyle(ActionButtonStyle(prominent: true))
            .modifier(SelectionCue(target: card.target))
            .accessibilityIdentifier("watch-now")
        }
    }

    private func actions(card: CardModel, hero: HeroModel) -> some View {
        ActionRow {
            watchNow(card: card, hero: hero)

            if let trailer = hero.trailer {
                Button {
                    router.play(trailer)
                } label: {
                    Label(hero.trailerLabel ?? ChromeText.string(.trailer), systemImage: "film")
                }
            }

            if let item = hero.watchLater {
                WatchLaterButton(item: item, watchLater: watchLater, label: hero.watchLaterLabel,
                                 savedLabel: hero.watchLaterSavedLabel)
                    .task(id: item.id) { await watchLater.check(item.itemType, item.itemId) }
            }
        }
    }

    private func page(_ delta: Int) {
        let count = model.cards.count
        guard count > 1 else { return }
        index = (index + delta + count) % count
    }

    private func art(card: CardModel, height: CGFloat) -> some View {
        ZStack {
            HeroArt(card: card, width: stageWidth, height: height, fillsFromTop: true, art: mobileBanner(for: card))
                .id(card.id)
                .transition(.opacity)
            let gate = previewGate(card.hero)
            HeroPreviewVideo(index: index, key: card.id, url: gate.mayPlay ? card.hero?.previewURL : nil,
                             hold: gate.hold)
            // The top meets the status bar band; the bottom fades into the next shelf.
            LinearGradient(stops: [
                .init(color: theme.background, location: 0),
                .init(color: theme.background.opacity(0), location: 0.12),
                .init(color: theme.background.opacity(0), location: 0.4),
                .init(color: theme.background.opacity(0.75), location: 0.72),
                .init(color: theme.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: stageWidth, height: height)
    }
}

/// The hero meta line: text parts joined with " • ", and outlined badges (`MovieHero`). A run of
/// badges takes no bullet inside it, as the web `Hero` groups them. A line of text only draws as
/// one `Text`, as before.
private struct HeroMetaLine: View {
    let parts: [HeroModel.MetaPart]

    @Environment(\.appTheme) private var theme

    var body: some View {
        if parts.contains(where: { if case .badge = $0 { return true }; return false }) {
            HStack(spacing: 8) {
                ForEach(Array(Self.groups(parts).enumerated()), id: \.offset) { index, group in
                    if index > 0 { text("•") }
                    switch group {
                    case let .text(value): text(value)
                    case let .badges(badges):
                        HStack(spacing: 8) {
                            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                                AgeRatingBadge(label: badge.text)
                                    .accessibilityLabel(badge.spoken ?? badge.text)
                            }
                        }
                    }
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        } else {
            text(parts.map(\.text).joined(separator: " • "))
        }
    }

    private enum Group { case text(String), badges([(text: String, spoken: String?)]) }

    /// Each text part alone, and each run of badges together (the web `groupMetaData`).
    private static func groups(_ parts: [HeroModel.MetaPart]) -> [Group] {
        parts.reduce(into: [Group]()) { groups, part in
            switch (part, groups.last) {
            case let (.badge(text, spoken), .badges(badges)?): groups[groups.count - 1] = .badges(badges + [(text, spoken)])
            case let (.badge(text, spoken), _): groups.append(.badges([(text, spoken)]))
            case let (.text(value), _): groups.append(.text(value))
            }
        }
    }

    private func text(_ value: String) -> some View {
        Text(value)
            .font(.system(size: Layout.text(24), weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? theme.textPrimary : theme.textPrimary.opacity(0.35))
                    .frame(width: dot == index ? 18 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Places its children on one line and leaves out every child that does not fit whole.
private struct OneLineRow: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let next = width == 0 ? size.width : width + spacing + size.width
            guard next <= limit else { break }
            width = next
            height = max(height, size.height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var fits = true
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            fits = fits && x + size.width <= bounds.maxX + 0.5
            // A child that does not fit goes outside the clipped row, so it never draws cut.
            let origin = fits ? CGPoint(x: x, y: bounds.minY) : CGPoint(x: bounds.maxX + 10_000, y: bounds.minY)
            subview.place(at: origin, proposal: .unspecified)
            x += size.width + spacing
        }
    }
}

/// The `EpisodesList` season filter: "All", then every season that holds an episode.
private struct SeasonChips: View {
    let seasons: [ShelfModel.Season]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(ChromeText.string(.allSeasons), id: nil)
                ForEach(seasons) { season in chip(season.title, id: season.id) }
            }
            .padding(.horizontal, Layout.screenMargin)
            .padding(.vertical, 4)
        }
        .padding(.horizontal, -Layout.screenMargin)
    }

    private func chip(_ title: String, id: String?) -> some View {
        Button(title) { selected = id }
            .buttonStyle(ChipButtonStyle(selected: selected == id))
            // UI tests find a chip by id: "All" is chrome text and can be translated.
            .accessibilityIdentifier(id == nil ? "season-chip-all" : "season-chip")
    }
}

private struct ChipButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChipFace(label: configuration.label, pressed: configuration.isPressed, selected: selected)
    }
}

private struct ChipFace<Label: View>: View {
    let label: Label
    let pressed: Bool
    let selected: Bool

    @Environment(\.appTheme) private var theme

    var body: some View {
        label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .foregroundStyle(selected ? theme.background : theme.textPrimary)
            .background(selected ? theme.accent : theme.surface, in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

private struct ScheduleView: View {
    let model: ScheduleModel

    @Environment(\.appTheme) private var theme
    /// The local clock. It moves every `ScheduleRefresh.interval`, with no network call.
    @State private var now = Date()
    #if DEBUG
    @Environment(AppRouter.self) private var router
    #endif

    var body: some View {
        let rows = model.entries(at: now)

        VStack(alignment: .leading, spacing: 12) {
            ShelfHeading(title: model.title)

            if rows.isEmpty {
                Text(model.emptyMessage ?? ChromeText.string(.noSchedule))
                    .font(.system(size: Layout.text(26)))
                    .foregroundStyle(theme.textSecondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { entry in ScheduleRow(entry: entry, now: now) }
                }
            }
        }
        // Canceled with the view, so no timer outlives the list. It restarts when the list
        // shows again (Back, a tab switch) and takes the time at once, so ended rows never draw.
        .task {
            await ScheduleClock.run { now = $0 }
        }
        #if DEBUG
        .task {
            DebugLaunch.pressLiveNow(in: model.entries(at: Date()), router: router)
        }
        #endif
    }
}

/// How often a schedule moves its clock, and how often the screen that holds it refetches.
enum ScheduleRefresh {
    static let interval: Duration = .seconds(60)

    /// Every `interval`, until canceled. It sleeps first: `ScreenHost` already fetches the screen
    /// each time it appears. The server caches a screen for about five minutes, so most runs
    /// return the same bytes; no cache buster is sent.
    static func loop(
        interval: Duration = ScheduleRefresh.interval,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        action: () async -> Void
    ) async {
        while true {
            do { try await sleep(interval) } catch { return }
            await action()
        }
    }
}

/// The schedule's local clock: the time at once, then every `interval`, until canceled.
enum ScheduleClock {
    static func run(
        interval: Duration = ScheduleRefresh.interval,
        now: () -> Date = Date.init,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        update: (Date) -> Void
    ) async {
        while true {
            update(now())
            do { try await sleep(interval) } catch { return }
        }
    }
}

private struct ShowDetailBlockView: View {
    let model: ShowDetailModel

    @Environment(\.appTheme) private var theme
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The block's own `title` prop, as the web draws it above the block.
            if let heading = model.heading {
                ShelfHeading(title: heading)
            }
            if let url = model.imageURL {
                DetailImage(url: url, blurhash: model.blurhash)
            }
            DetailColumn(
                hasLead: model.title != nil,
                hasAction: model.trailer != nil || model.watchLater != nil || model.like != nil,
                hasText: model.abstract != nil || !model.paragraphs.isEmpty
            ) {
                if let title = model.title {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                        // Served only by an App whose Show carries one; absent draws no line.
                        if let subtitle = model.subtitle {
                            Text(subtitle)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(theme.accent)
                        }
                        // `MovieDetail` adds the quality badge, the language and the genres (awe#6870).
                        if model.ageRating != nil || model.videoQuality != nil || model.language != nil
                            || model.genres != nil {
                            HStack(spacing: 10) {
                                if let ageRating = model.ageRating {
                                    AgeRatingBadge(label: ageRating)
                                }
                                if let quality = model.videoQuality {
                                    AgeRatingBadge(label: quality)
                                }
                                if let language = model.language {
                                    Text(language)
                                        .font(.system(size: Layout.text(24), weight: .medium))
                                        .foregroundStyle(theme.textSecondary)
                                        .accessibilityLabel(languageText ?? language)
                                }
                                if let genres = model.genres {
                                    Text(genres)
                                        .font(.system(size: Layout.text(24), weight: .medium))
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            } action: {
                ActionRow {
                    if let trailer = model.trailer {
                        Button {
                            router.play(trailer)
                        } label: {
                            Label(ChromeText.string(.watchTrailer), systemImage: "film")
                        }
                        .accessibilityIdentifier("watch-trailer")
                    }
                    if let item = model.watchLater {
                        WatchLaterToggle(item: item)
                    }
                    if let item = model.like {
                        LikeToggle(item: item)
                    }
                }
            } text: {
                DetailText(abstract: model.abstract, paragraphs: model.paragraphs)
            }
        }
    }

    /// What VoiceOver reads for the language: "Language: Deutsch", as on `EpisodeDetail`.
    private var languageText: String? {
        model.language.map { "\(ChromeText.string(.languageLabel)): \($0)" }
    }
}

/// A detail block's 16:9 image, as wide as the column. The art fills an overlay, so it never
/// sizes the block.
private struct DetailImage: View {
    let url: URL?
    let blurhash: String?

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { RemoteImage(url: url, blurhash: blurhash) }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// `EpisodeDetail`: text only, the same parts and order as the web block (ruled 2026-09-23) —
/// show name, title, view count, abstract, body — plus "Go to show" under the heading group.
private struct EpisodeDetailBlockView: View {
    let model: EpisodeDetailModel

    @Environment(\.appTheme) private var theme
    @Environment(AppRouter.self) private var router

    var body: some View {
        // The evaluator already dropped a target that could open nothing (`canOpenCard`).
        let showTarget = model.showTarget
        DetailColumn(
            hasLead: model.showTitle != nil || model.title != nil || model.views != nil,
            hasAction: showTarget != nil || model.watchLater != nil || model.like != nil,
            hasText: model.abstract != nil || !model.paragraphs.isEmpty
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if let showTitle = model.showTitle {
                    Text(showTitle.uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
                if let title = model.title {
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                }
                if model.ageRating != nil || model.language != nil {
                    HStack(spacing: 10) {
                        if let ageRating = model.ageRating {
                            AgeRatingBadge(label: ageRating)
                        }
                        if let language = model.language {
                            Text(language)
                                .font(.system(size: Layout.text(24), weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .accessibilityLabel(languageText ?? language)
                        }
                    }
                }
                if let views = model.views {
                    Text(ChromeText.count(.viewsCount, views, formatted: views.formatted()))
                        .font(.system(size: Layout.text(24)))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        } action: {
            ActionRow {
                if let target = showTarget {
                    Button {
                        router.openCard(target)
                    } label: {
                        Label(ChromeText.string(.goToShow), systemImage: "rectangle.stack")
                    }
                    .accessibilityIdentifier("go-to-show")
                }
                if let item = model.watchLater {
                    WatchLaterToggle(item: item)
                }
                if let item = model.like {
                    LikeToggle(item: item)
                }
            }
        } text: {
            DetailText(abstract: model.abstract, paragraphs: model.paragraphs)
        }
    }

    /// What VoiceOver reads for the language: "Language: Deutsch". The screen draws the label alone.
    private var languageText: String? {
        model.language.map { "\(ChromeText.string(.languageLabel)): \($0)" }
    }
}

/// `ShowMeta`: label / value rows, like the app.hopetv.de show page.
private struct ShowMetaBlockView: View {
    let model: ShowMetaModel

    @Environment(\.appTheme) private var theme

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label)
                        .font(.system(size: Layout.text(28), weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 100, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: Layout.text(28)))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityLabel(row.spokenValue ?? row.value)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A detail block's text column: the lead (the heading group), an optional action button, and
/// the text.
private struct DetailColumn<Lead: View, Action: View, Body: View>: View {
    let hasLead: Bool
    let hasAction: Bool
    let hasText: Bool
    let lead: Lead
    let action: Action
    let text: Body

    init(
        hasLead: Bool,
        hasAction: Bool,
        hasText: Bool,
        @ViewBuilder lead: () -> Lead,
        @ViewBuilder action: () -> Action,
        @ViewBuilder text: () -> Body
    ) {
        self.hasLead = hasLead
        self.hasAction = hasAction
        self.hasText = hasText
        self.lead = lead()
        self.action = action()
        self.text = text()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasLead { lead }
            if hasAction { action }
            if hasText { text }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The abstract and the body paragraphs of a detail block.
private struct DetailText: View {
    let abstract: String?
    let paragraphs: [String]

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let abstract {
                Text(abstract)
                    .font(.system(size: Layout.text(28)))
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: Layout.text(28)))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

/// An episode's poster and one action. Nothing plays here (ruled 2026-09-23): Select opens the
/// full-screen `PlayerView`, the only place that seeks to a resume point and writes progress.
private struct PlayActionView: View {
    let model: PlayActionModel

    @Environment(AppRouter.self) private var router
    @Environment(ContractStore.self) private var store
    @Environment(\.stackEntry) private var stackEntry
    @Environment(\.appTheme) private var theme

    /// A YouTube id, only when no native source plays: ContractKit answers "can't play" for
    /// YouTube, because tvOS has no web view. The source order stays the contract's.
    private var youTubeId: String? {
        guard model.request == nil, let stackEntry else { return nil }
        let key = store.key(for: stackEntry.screenId, param: stackEntry.param)
        let resources = store.blockResources(for: key)[model.nodeId]
        return (resources?["episodePlayer"] ?? resources?["moviePlayer"]).flatMap(YouTubeEmbed.videoId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let youTubeId {
                YouTubeEmbedView(videoId: youTubeId)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("youtube-embed")
            } else {
                DetailImage(url: model.posterURL, blurhash: nil)
            }

            if youTubeId == nil, let request = model.request {
                Button {
                    router.play(request)
                } label: {
                    Label(model.label ?? ChromeText.string(.play), systemImage: "play.fill")
                }
                .buttonStyle(ActionButtonStyle(prominent: true))
                .accessibilityIdentifier("play-action")
            } else if youTubeId == nil, let message = model.message {
                Text(message)
                    .font(.system(size: Layout.text(26)))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

/// The stack entry of the screen a view draws on. nil outside a screen (a layout's chrome).
private struct StackEntryKey: EnvironmentKey {
    static let defaultValue: StackEntry? = nil
}

extension EnvironmentValues {
    var stackEntry: StackEntry? {
        get { self[StackEntryKey.self] }
        set { self[StackEntryKey.self] = newValue }
    }
}

/// The hero shelf that leads its screen, and how far above its frame the stage top is. Only
/// that hero draws its art up to the stage top: nothing is above it to cover.
struct LeadingHero: Equatable {
    let nodeId: String
    /// How far above the hero frame the stage top is.
    let bleed: CGFloat
    /// How far the stage-wide art moves sideways to stay centered on the stage. Unequal side
    /// padding on the layout blocks around the hero moves its frame off center (awe#6297).
    let shift: CGFloat

    /// `screenTop` is the safe-area top plus the screen padding; `insets` are the padding and
    /// border of the layout blocks around the hero.
    init(nodeId: String, insets: LayoutStyle.Insets, screenTop: CGFloat) {
        self.nodeId = nodeId
        bleed = screenTop + insets.top
        shift = (insets.right - insets.left) / 2
    }
}

private struct LeadingHeroKey: EnvironmentKey {
    static let defaultValue: LeadingHero? = nil
}

extension EnvironmentValues {
    var leadingHero: LeadingHero? {
        get { self[LeadingHeroKey.self] }
        set { self[LeadingHeroKey.self] = newValue }
    }
}

/// The Live card: the on-air broadcast's image, a play button and its title. Nothing plays
/// inline. Select opens the stream full screen through `router.play`, the path the on-air
/// schedule row uses (awe#5044). `ScheduleClock` moves the on-air broadcast, as on the list.
/// No broadcast on air (or none served): the dark card and the play button only.
private struct LiveCardView: View {
    let model: PlayerModel

    @Environment(AppRouter.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var now = Date()

    var body: some View {
        let onAir = model.onAir(at: now)
        Button {
            router.play(model.request)
        } label: {
            // 16:9, as wide as the column. The art fills an overlay, so it never sizes the card.
            Color.black
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let onAir {
                        RemoteImage(url: onAir.imageURL, blurhash: onAir.blurhash)
                        LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                    }
                }
                .clipped()
                .overlay { playGlyph }
                .overlay(alignment: .bottomLeading) {
                    if let onAir { caption(onAir) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityLabel(ChromeText.string(.watchFullScreen))
        .accessibilityValue(onAir?.title ?? "")
        .accessibilityIdentifier("live-player")
        // Canceled with the card. It takes the time at once each time the card shows.
        .task {
            await ScheduleClock.run { now = $0 }
        }
    }

    private var playGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(.black.opacity(0.55), in: Circle())
    }

    /// "Now", then the broadcast title and its show, as the on-air schedule row says them.
    private func caption(_ entry: ScheduleModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ChromeText.string(.now))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.accent)
            Text(entry.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
            if let show = entry.showTitle {
                Text(show)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .lineLimit(1)
        .padding(12)
    }
}

/// The columns of a card grid in a given width: 2 under a 430 pt phone, 3 above. A poster grid
/// (`MovieList`, awe#6870) uses `Metrics.poster`: 3 columns on every phone. An unmeasured width
/// draws two wide columns or three poster columns at the metrics' card width.
enum GridColumns {
    struct Metrics: Equatable {
        let card: CGFloat
        let minimumCard: CGFloat
        let maximum: Int

        static let wide = Metrics(card: 180, minimumCard: 120, maximum: 3)
        static let poster = Metrics(card: 130, minimumCard: 100, maximum: 3)
    }

    static let spacing: CGFloat = 12

    static func count(width: CGFloat?, metrics: Metrics = .wide) -> Int {
        guard let width else { return metrics == .wide ? 2 : metrics.maximum }
        let fitting = Int(((width + spacing) / (metrics.minimumCard + spacing)).rounded(.down))
        return min(metrics.maximum, max(1, fitting))
    }

    /// The metrics' card width, or less to fit `columns` in `width`. One column never shrinks
    /// below the minimum.
    static func cardWidth(width: CGFloat?, columns: Int, metrics: Metrics = .wide) -> CGFloat {
        guard let width else { return metrics.card }
        let shared = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return min(metrics.card, max(metrics.minimumCard, shared.rounded(.down)))
    }
}

extension ShelfModel {
    /// The grid's column metrics: posters for a `posters` shelf, else the landscape grid.
    var gridMetrics: GridColumns.Metrics { cardStyle == .posters ? .poster : .wide }

    /// The shape one grid card draws. A posters grid draws posters, an item with no poster art
    /// too (fit over a blurred copy, `artIsFallback`). Every other grid draws landscape cards only.
    func gridShape(_ card: CardModel) -> CardShape {
        cardStyle == .posters && card.style == .posters ? .poster : .wide
    }
}

/// When an appearing grid card asks for the next page (awe#5318): it is one of the last `columns`
/// cards. That is the last row, plus the end of the row above when the last row is short.
enum GridPaging {
    static func triggers(index: Int, count: Int, columns: Int) -> Bool {
        (0..<count).contains(index) && index >= count - columns
    }
}

/// Asks the store for the next page of a node (`ContractStore.loadNextPage`). The store
/// decides whether the node pages at all; nil loads nothing.
private struct LoadNextPageKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var loadNextPage: ((String) -> Void)? {
        get { self[LoadNextPageKey.self] }
        set { self[LoadNextPageKey.self] = newValue }
    }
}

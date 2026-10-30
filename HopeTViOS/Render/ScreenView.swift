// cspell:ignore subview subviews Subviews TVUI
import SwiftUI

/// Draws one evaluated node and its children.
///
/// Every decision about *what* is on screen was made by `BlockRegistry`; this file only
/// decides how it looks and how focus moves. `slot` is the layout's content slot — the
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
    @Environment(\.defaultFocusNodeId) private var defaultFocusNodeId

    var body: some View {
        // Each node says whether it is the default one, so a child never inherits its parent's.
        block.environment(\.isDefaultFocusBlock, defaultFocusNodeId != nil && defaultFocusNodeId == node.id)
    }

    @ViewBuilder
    private var block: some View {
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
                .font(.system(size: 26))
                .foregroundStyle(theme.textSecondary)

        case nil:
            EmptyView()
        }
    }

    /// The children in a `FlexStackLayout`. The gaps stay 40 pt in a row and 44 pt in a column
    /// (a decision, awe#6297): the minimum gap, as CSS `gap` with `justify-content`.
    private func stack(_ axis: BlockContent.Axis, _ style: LayoutStyle) -> some View {
        let insets = style.contentInsets
        // `box-sizing: border-box`: the heights include the padding and the border.
        let inner = { (height: CGFloat?) in height.map { max(0, $0 - insets.top - insets.bottom) } }
        let stretches = style.align == .stretch
        return FlexStackLayout(axis: axis, spacing: axis == .horizontal ? 40 : 44, justify: style.justify,
                               align: style.align, minHeight: inner(style.minHeight), height: inner(style.height),
                               fillsWidth: stretch == .width, fillsHeight: stretch == .height && style.height == nil) {
            ForEach(node.children) { child in
                if axis == .horizontal {
                    // Each column is a focus section as tall as the row. A move sideways from a
                    // button low in one column (Play under a poster) then lands in the next column,
                    // on its first focusable (Go to show at its top), instead of finding nothing in
                    // the button's own band.
                    NodeView(node: child, slot: slot, stretch: stretches ? .height : .none)
                        .frame(maxHeight: .infinity, alignment: Self.rowAlignment(style.align))
                        .focusSection()
                } else {
                    NodeView(node: child, slot: slot, stretch: stretches ? .width : .none)
                        .focusSection()
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
/// The children draw over both and are not clipped, so a focused card can still lift past a
/// rounded corner.
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
/// the block. Decoration only: no focus, no hit tests, hidden from VoiceOver. An image that does
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
        let sizes: [CGFloat] = [76, 64, 54, 46, 38, 32]
        let size = sizes[min(max(level, 1), 6) - 1]
        if let name = theme.headingFont {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: level <= 2 ? .bold : .semibold)
    }

    /// The preset body face when set, else the system face at `weight`.
    static func body(theme: AppTheme, size: CGFloat = 28, weight: Font.Weight = .regular) -> Font {
        if let name = theme.bodyFont {
            let face = Font.custom(name, size: size)
            return weight == .regular ? face : face.weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

/// The Button block, and the link row of a `Header`. Only `linkType: "screen"` opens anything:
/// a TV has no browser to hand a `url` to.
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
        .font(.system(size: 30, weight: .semibold))
        .disabled(model.disabled)
        .modifier(TakesDefaultFocus())
        .focusSection()
    }
}

struct ShelfView: View {
    let model: ShelfModel

    @Environment(\.appTheme) private var theme
    @Environment(\.loadNextPage) private var loadNextPage
    /// The season chip in use. nil is "All".
    @State private var season: String?
    /// The focused grid card, so focus on the last row can load the next page.
    @FocusState private var focusedCard: String?

    /// The grid's measured width. nil until the first layout, which then assumes the full four
    /// columns.
    @State private var gridAvailableWidth: CGFloat?

    private let gridSpacing = GridColumns.spacing
    /// Four columns, or as many as fit the width the grid gets: the search results sit beside
    /// the grid keyboard, so they get less than the screen width.
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

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let title = model.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    // UI tests find a header by id: a search grid's title is chrome text.
                    .accessibilityIdentifier("shelf-title-\(model.nodeId)")
            }

            if let message = model.emptyMessage {
                Text(message)
                    .font(.system(size: 26))
                    .foregroundStyle(theme.textSecondary)
            } else if model.layout == .grid {
                if !model.seasons.isEmpty {
                    SeasonChips(seasons: model.seasons, selected: $season)
                }
                let visible = model.cards(inSeason: season)
                // Each row is a focus section as wide as the grid, so Down from a column with no
                // card below still enters a short last row (awe#6458). A LazyVGrid gives Down no
                // target under an empty column.
                LazyVStack(alignment: .leading, spacing: gridSpacing) {
                    ForEach(Array(stride(from: 0, to: visible.count, by: gridColumns)), id: \.self) { start in
                        // Top-aligned: a poster grid's no-poster card is shorter. Every card of any
                        // other grid has one height, so it draws as before.
                        HStack(alignment: .top, spacing: gridSpacing) {
                            ForEach(visible[start..<min(start + gridColumns, visible.count)]) { card in
                                CardButton(card: card, shape: model.gridShape(card), width: gridCardWidth,
                                           titleLines: model.titleLines)
                                    .focused($focusedCard, equals: card.id)
                                    .modifier(DefaultFocusRequest(enabled: card.id == model.cards.first?.id) { focusedCard = card.id })
                            }
                        }
                        .frame(width: gridWidth, alignment: .leading)
                        .focusSection()
                    }
                }
                .padding(.vertical, Layout.focusGrowth)
                // Takes the offered width and no more, so the rows never set the shelf's width.
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridAvailableWidth = $0 }
                // Focus on the last row of the grid on show (a season chip filters it) asks for
                // the next page. The store gates it: paging served, has more, one at a time.
                .onChange(of: focusedCard) { _, id in
                    guard let id, let index = visible.firstIndex(where: { $0.id == id }),
                          GridPaging.triggers(index: index, count: visible.count, columns: gridColumns) else { return }
                    loadNextPage?(model.nodeId)
                }
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
                            .focused($focusedCard, equals: card.id)
                            .modifier(DefaultFocusRequest(enabled: card.id == model.cards.first?.id) { focusedCard = card.id })
                    }
                }
                // The same rule as the grid: focus on one of the last rows asks for the next page.
                .onChange(of: focusedCard) { _, id in
                    guard let id, let index = visible.firstIndex(where: { $0.id == id }),
                          GridPaging.triggers(index: index, count: visible.count, columns: gridColumns) else { return }
                    loadNextPage?(model.nodeId)
                }
            } else if model.layout == .sidewaysGrid {
                // Two rows that scroll sideways together (a Collection record with `listLayout:
                // "grid"`). The cards fill each column top to bottom, so the order reads left to
                // right. Up from the top row and Down from the bottom row leave for the next block.
                // Page 1 only, as a row. One card draws one row.
                let rows = model.cards.count < 2 ? 1 : 2
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(rowShape.shelfHeight), spacing: gridSpacing,
                                                              alignment: .top), count: rows),
                              alignment: .top, spacing: 40) {
                        ForEach(model.cards) { card in
                            CardButton(card: card, shape: shape(of: card))
                                .modifier(TakesDefaultFocus(enabled: card.id == model.cards.first?.id))
                        }
                    }
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.vertical, Layout.focusGrowth)
                }
                .frame(height: CGFloat(rows) * rowShape.shelfHeight + CGFloat(rows - 1) * gridSpacing
                    + Layout.focusGrowth * 2)
                .padding(.horizontal, -Layout.screenMargin)
                // UI tests find the grid by id; the cards inside keep their own labels.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sideways-grid-\(model.nodeId)")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(model.cards) { card in
                            CardButton(card: card, shape: shape(of: card))
                                .modifier(TakesDefaultFocus(enabled: card.id == model.cards.first?.id))
                        }
                    }
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.vertical, Layout.focusGrowth)
                }
                .frame(height: rowShape.shelfHeight + Layout.focusGrowth * 2)
                .padding(.horizontal, -Layout.screenMargin)
            }
        }
        .focusSection()
    }
}

/// One `EpisodesList` list row: the episode number, a 16:9 thumbnail, then the title with the
/// duration on its right and the abstract (3 lines) below. The whole row is one button. Focus
/// draws a `surfaceSelected` panel with no lift or scale, so the text stays still and readable.
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
        .buttonStyle(EpisodeListRowStyle())
        .modifier(SelectionCue(target: card.target))
        .modifier(CardMenuModifier(menu: card.menu))
        .accessibilityLabel(card.title)
    }
}

private struct EpisodeListRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        EpisodeListRowPlate(label: configuration.label)
    }
}

/// The focus panel behind a row, read from the focus state as `ChipFace` does.
private struct EpisodeListRowPlate<Label: View>: View {
    let label: Label

    @Environment(\.isFocused) private var focused
    @Environment(\.appTheme) private var theme

    var body: some View {
        label
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? theme.surfaceSelected : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct EpisodeListRowFace: View {
    let card: CardModel
    let numbered: Bool

    @Environment(\.appTheme) private var theme

    private let thumbnail = CGSize(width: 330, height: 186)

    var body: some View {
        // The text starts at the thumbnail's top; the number stays centered on the thumbnail.
        HStack(alignment: .top, spacing: 32) {
            if numbered {
                Text(card.number.map(String.init) ?? "")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 80, height: thumbnail.height)
                    .accessibilityHidden(true)
            }
            RemoteImage(url: card.imageURL, blurhash: card.blurhash)
                .frame(width: thumbnail.width, height: thumbnail.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Text(card.title)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // An `EpisodesList` card's subtitle is its duration, or nil.
                    if let duration = card.subtitle {
                        Text(duration)
                            .font(.system(size: 24))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if let abstract = card.abstract {
                    Text(abstract)
                        .font(.system(size: 24))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

/// One schedule row. Every row is a focus stop, because the strip sits below the player and a
/// tvOS ScrollView scrolls only to focus (awe#5036).
///
/// A linked row shows `play.fill` beside its time, gets card lift on focus, and goes through the
/// same `select` path a card uses (tap-to-play). A title-only row is not a button: a press does nothing. On
/// focus it swaps its surface for `surfaceSelected` and draws a 4 pt `focusRing` border, with no
/// lift, so it reads across a room.
///
/// Every row has the same size: the thumbnail slot is always there, and a row with no image
/// draws a placeholder in it. The on-air row is larger, says "Now" in the accent color, and
/// draws its progress through the broadcast.
///
/// The live player's Schedule tab draws its information rows with this view too (awe#6553).
struct ScheduleRow: View {
    let entry: ScheduleModel.Entry
    let now: Date
    let focus: FocusState<String?>.Binding

    @Environment(\.appTheme) private var theme
    @Environment(AppRouter.self) private var router

    var body: some View {
        switch entry.kind {
        case .live:
            Button {
                entry.press(router: router)
            } label: {
                face(linked: true, fill: theme.surface)
            }
            .buttonStyle(.card)
            .focused(focus, equals: entry.id)
            .accessibilityLabel(label)
        case let .linked(target):
            Button {
                entry.press(router: router)
            } label: {
                face(linked: true, fill: theme.surface)
            }
            .buttonStyle(.card)
            .modifier(SelectionCue(target: target))
            .focused(focus, equals: entry.id)
            .accessibilityLabel(label)
        case .information:
            let focused = focus.wrappedValue == entry.id
            face(linked: false, fill: focused ? theme.surfaceSelected : theme.surface)
                // An overlay, so the layout does not move when focus arrives.
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(theme.focusRing, lineWidth: 4)
                    }
                }
                .focusable()
                .focused(focus, equals: entry.id)
                .focusEffectDisabled()
                .animation(.easeOut(duration: 0.15), value: focused)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    private var label: String {
        entry.isCurrent ? ChromeText.string(.onNowTitle, ["title": entry.title]) : entry.title
    }

    private var thumbnail: CGSize { ScheduleRowMetrics.thumbnail(isCurrent: entry.isCurrent) }

    private func face(linked: Bool, fill: Color) -> some View {
        let text = ScheduleRowMetrics.text(isCurrent: entry.isCurrent)
        return HStack(alignment: .top, spacing: ScheduleRowMetrics.spacing) {
            thumbnailView
            Group {
                if entry.isCurrent {
                    currentText(linked: linked)
                } else {
                    rowText(linked: linked)
                }
            }
            .frame(width: text.width, height: text.height, alignment: .topLeading)
        }
        .padding(ScheduleRowMetrics.padding)
        .background(fill, in: RoundedRectangle(cornerRadius: 12))
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
                        .font(.system(size: entry.isCurrent ? 64 : 40))
                        .foregroundStyle(theme.textSecondary)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(width: thumbnail.width, height: thumbnail.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func timeLine(linked: Bool, size: CGFloat) -> some View {
        HStack(spacing: 10) {
            if linked {
                Image(systemName: "play.fill")
                    .font(.system(size: size - 4))
                    .accessibilityHidden(true)
            }
            if entry.isCurrent {
                // The on-air row says "Now" in place of its start time, as the web does.
                Text(ChromeText.string(.now)).font(.system(size: size, weight: .bold))
                if let range = timeRange {
                    Text(range).font(.system(size: size - 2)).foregroundStyle(theme.textSecondary)
                }
            } else {
                Text(entry.time ?? "").font(.system(size: size))
            }
        }
        .foregroundStyle(theme.accent)
    }

    private var timeRange: String? {
        guard let start = entry.time, let end = TimeOfDayFormatter.string(from: entry.endsAt) else { return nil }
        return "\(start) – \(end)"
    }

    private func rowText(linked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            timeLine(linked: linked, size: 22)
            Text(entry.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            if let show = entry.showTitle {
                Text(show)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func currentText(linked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            timeLine(linked: linked, size: 26)
            Text(entry.title)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            if let show = entry.showTitle {
                Text(show)
                    .font(.system(size: 24))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let progress = entry.progress(at: now) {
                ProgressBar(fraction: progress)
            }
        }
    }
}

/// The fixed sizes of a schedule row. A row's size depends only on whether it is the on-air
/// row, never on its image or its text, so every row of the strip is the same size.
enum ScheduleRowMetrics {
    static let padding: CGFloat = 24
    static let spacing: CGFloat = 24

    static func thumbnail(isCurrent: Bool) -> CGSize {
        isCurrent ? CGSize(width: 384, height: 216) : CGSize(width: 192, height: 108)
    }

    /// Two title lines, the show line and the time line fit in the regular row.
    static func text(isCurrent: Bool) -> CGSize {
        isCurrent ? CGSize(width: 640, height: 216) : CGSize(width: 420, height: 132)
    }

    static func rowSize(isCurrent: Bool) -> CGSize {
        let image = thumbnail(isCurrent: isCurrent)
        let text = text(isCurrent: isCurrent)
        return CGSize(width: image.width + spacing + text.width + padding * 2,
                      height: max(image.height, text.height) + padding * 2)
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
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// A card keeps Apple's focus engine: `Button` + `.buttonStyle(.card)` gives parallax,
/// lift and hover for free. A press hands the item's type and id to the router, which
/// resolves the Template Screen — the view never builds a route. An episode plays at once when
/// it can (`AppRouter.select`, tap-to-play).
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
            MediaCard(card: card, shape: shape, width: width, titleLines: titleLines)
        }
        .buttonStyle(.card)
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
    /// The block's first action asks for the default focus, as Go to show does.
    var takesDefaultFocus = true

    @Environment(SavedItemList.self) private var watchLater

    var body: some View {
        WatchLaterButton(item: item, watchLater: watchLater)
            .font(.system(size: 28, weight: .semibold))
            .modifier(TakesDefaultFocus(enabled: takesDefaultFocus))
            .task(id: item.id) { await watchLater.check(item.itemType, item.itemId) }
    }
}

/// The Like button of the Episode and Movie detail blocks (awe#6871): "Like", or "Liked" with a
/// filled heart. A press toggles it. Signed in with no loaded list, it asks `/contains` when it shows.
private struct LikeToggle: View {
    let item: SavedItem
    /// The block's first action asks for the default focus.
    var takesDefaultFocus = false

    @Environment(Likes.self) private var likes

    var body: some View {
        let liked = likes.isLiked(item)
        Button(ChromeText.string(liked ? .liked : .like), systemImage: liked ? "heart.fill" : "heart") {
            Task { await likes.toggle(item) }
        }
        .font(.system(size: 28, weight: .semibold))
        .modifier(TakesDefaultFocus(enabled: takesDefaultFocus))
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

/// The full-screen hero of a `hero` shelf, like the app.hopetv.de home hero: 16:9 art across
/// the whole stage, darkened on the leading side, with the item's logo (else its title), its
/// abstract, a meta line, its categories and the actions on the left.
///
/// It is not a lifted card: the buttons take focus. "Watch now" is the card press
/// (`router.select`: served link first, and an episode plays at once when it can); "Trailer"
/// draws only when the trailer resolves to a playable source and plays it full screen. Left on
/// the first button and right on the last button page through the items. The hero also goes to
/// the next item after `autoAdvanceInterval`. The art runs under the next shelf; a hero that leads
/// the screen also draws its art up to the stage top. A show with a served preview fades to its
/// muted loop (`HeroPreviewVideo`) while `HeroPreview.Gate` allows it.
private struct HeroShelfView: View {
    let model: ShelfModel

    @Environment(\.appTheme) private var theme
    @Environment(AppRouter.self) private var router
    @Environment(\.leadingHero) private var leadingHero
    @Environment(SavedItemList.self) private var watchLater
    @Environment(\.stackEntry) private var stackEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var index = 0
    @FocusState private var focus: HeroModel.Action?
    /// Between `onAppear` and `onDisappear`. A covered NavigationStack root and an unselected tab
    /// still get changes, so the preview also checks that its screen is the one on show.
    @State private var appeared = false
    /// At least half the hero is in the scroll view's visible area, as the web `useInView`.
    @State private var inView = true

    /// The time one item shows, as on the app.hopetv.de home hero (`duration: 15e3`).
    static let autoAdvanceInterval: Duration = .seconds(15)

    /// Restarts the auto-advance wait. A page change (manual or automatic) starts a full wait.
    /// The full-screen player covers this view without removing it, so the wait stops while it
    /// plays. A pushed screen or another tab removes the view, which cancels the wait.
    private struct AutoAdvance: Equatable {
        let index: Int
        let playing: Bool
    }

    /// The text column. The rest of the stage is the art.
    private let columnWidth: CGFloat = 900

    private var card: CardModel { model.cards[min(index, model.cards.count - 1)] }

    var body: some View {
        let card = card
        let hero = card.hero
        let leads = leadingHero?.nodeId == model.nodeId
        let bleed = leads ? leadingHero?.bleed ?? 0 : 0
        let shift = leads ? leadingHero?.shift ?? 0 : 0

        VStack(alignment: .leading, spacing: 22) {
            // Only an authored title draws, as a quiet overline above the logo.
            if let title = model.title {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
            }
            identity(card: card, hero: hero)
            if let hero, hero.metaBeforeAbstract, !hero.metaParts.isEmpty {
                HeroMetaLine(parts: hero.metaParts)
            }
            if let abstract = hero?.abstract {
                Text(abstract)
                    .font(.system(size: 28))
                    .foregroundStyle(theme.textPrimary.opacity(0.9))
                    .lineLimit(3)
            }
            if let hero, !hero.metaBeforeAbstract, !hero.metaParts.isEmpty {
                HeroMetaLine(parts: hero.metaParts)
            }
            if let categories = hero?.categories, !categories.isEmpty, let separator = hero?.tagSeparator {
                // `MovieHero` with `genresDisplay: "text"`: one line in the meta style, not chips.
                Text(categories.joined(separator: separator))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            } else if let categories = hero?.categories, !categories.isEmpty {
                OneLineRow(spacing: 12) {
                    ForEach(categories, id: \.self) { category in
                        Text(category)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .overlay(Capsule().strokeBorder(theme.textPrimary.opacity(0.6), lineWidth: 2))
                            .fixedSize()
                    }
                }
                .frame(width: columnWidth, alignment: .leading)
                .clipped()
            }
            if let hero, let message = hero.cannotPlayMessage {
                cannotPlay(message, focusable: hero.firstFocus == .message)
                    .padding(.top, 8)
            }
            if let hero, hero.hasActions {
                actions(card: card, hero: hero)
                    .padding(.top, 8)
            }
            if model.cards.count > 1 {
                PageDots(count: model.cards.count, index: index)
            }
        }
        .frame(width: columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Layout.heroHeight, alignment: .bottomLeading)
        .background(alignment: .top) {
            art(card: card)
                .offset(x: shift, y: -bleed)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.35), value: index)
        .focusSection()
        .modifier(DefaultFocusRequest { focus = hero?.firstFocus })
        .onChange(of: index) { _, _ in
            // The Trailer button goes away on an item that has none; focus stays in the hero.
            if focus == .trailer, self.card.hero?.trailer == nil { focus = .watch }
        }
        .task(id: AutoAdvance(index: index, playing: router.playback != nil)) {
            guard model.cards.count > 1, router.playback == nil else { return }
            guard (try? await Task.sleep(for: Self.autoAdvanceInterval)) != nil else { return }
            page(1)
        }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .onScrollVisibilityChange(threshold: 0.5) { inView = $0 }
    }

    /// The preview gate for the item on show.
    private func previewGate(_ hero: HeroModel?) -> HeroPreview.Gate {
        let onShow = stackEntry.map { router.state.current == $0 } ?? true
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
                .font(theme.headingFont.map { .custom($0, size: 72) } ?? .system(size: 72, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
        }
    }

    /// The logo box: at most 800 x 220 pt, the file's own aspect when it carries its size.
    static func logoSize(aspect: CGFloat?) -> CGSize {
        let box = CGSize(width: 800, height: 220)
        guard let aspect, aspect > 0 else { return box }
        return box.width * aspect <= box.height
            ? CGSize(width: box.width, height: box.width * aspect)
            : CGSize(width: box.height / aspect, height: box.height)
    }

    /// The "can't play" text where Watch now would be. With no button it is the hero's focus stop,
    /// so Up from the block below scrolls back to the hero. Focus draws a quiet `surfaceSelected`
    /// panel with no lift, as `ReadingPanel`: it is text, not a button.
    private func cannotPlay(_ message: String, focusable: Bool) -> some View {
        Text(message)
            .font(.system(size: 26))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(focus == .message ? theme.surfaceSelected : .clear, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, -20)
            .padding(.vertical, -12)
            .focusable(focusable)
            .focusEffectDisabled()
            .focused($focus, equals: .message)
            .animation(.easeOut(duration: 0.15), value: focus)
            .accessibilityIdentifier("cannot-play")
    }

    private func actions(card: CardModel, hero: HeroModel) -> some View {
        let buttons = hero.actions
        // Left on the first button and Right on the last one page through the items.
        let paging = { (action: HeroModel.Action, direction: MoveCommandDirection) in
            if direction == .left, action == buttons.first {
                page(-1)
            } else if direction == .right, action == buttons.last {
                page(1)
            }
        }
        return HStack(spacing: 24) {
            if let watchNow = hero.watchNow {
                Button {
                    switch watchNow {
                    case .select: router.select(card.target)
                    case let .play(request, _): router.play(request)
                    }
                } label: {
                    Label(watchNow.label, systemImage: "play.fill")
                }
                .modifier(SelectionCue(target: card.target))
                .accessibilityIdentifier("watch-now")
                .focused($focus, equals: .watch)
                .onMoveCommand { paging(.watch, $0) }
            }

            if let trailer = hero.trailer {
                Button {
                    router.play(trailer)
                } label: {
                    Label(hero.trailerLabel ?? ChromeText.string(.trailer), systemImage: "film")
                }
                .focused($focus, equals: .trailer)
                .onMoveCommand { paging(.trailer, $0) }
            }

            if let item = hero.watchLater {
                WatchLaterButton(item: item, watchLater: watchLater, label: hero.watchLaterLabel,
                                 savedLabel: hero.watchLaterSavedLabel)
                    .focused($focus, equals: .watchLater)
                    .onMoveCommand { paging(.watchLater, $0) }
                    .task(id: item.id) { await watchLater.check(item.itemType, item.itemId) }
            }
        }
        .font(.system(size: 30, weight: .semibold))
    }

    private func page(_ delta: Int) {
        let count = model.cards.count
        guard count > 1 else { return }
        index = (index + delta + count) % count
    }

    private func art(card: CardModel) -> some View {
        ZStack {
            HeroArt(card: card, width: Layout.stageWidth, height: Layout.stageHeight, fillsFromTop: true)
                .id(card.id)
                .transition(.opacity)
            let gate = previewGate(card.hero)
            HeroPreviewVideo(index: index, key: card.id, url: gate.mayPlay ? card.hero?.previewURL : nil,
                             hold: gate.hold)
            // The leading side goes dark for the text; the bottom fades into the next shelf.
            LinearGradient(stops: [
                .init(color: theme.background.opacity(0.95), location: 0),
                .init(color: theme.background.opacity(0.7), location: 0.35),
                .init(color: theme.background.opacity(0), location: 0.72),
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: theme.background.opacity(0.55), location: 0),
                .init(color: theme.background.opacity(0), location: 0.18),
                .init(color: theme.background.opacity(0), location: 0.6),
                .init(color: theme.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: Layout.stageWidth, height: Layout.stageHeight)
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
            HStack(spacing: 12) {
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
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? theme.textPrimary : theme.textPrimary.opacity(0.35))
                    .frame(width: dot == index ? 36 : 12, height: 12)
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
            HStack(spacing: 20) {
                chip(ChromeText.string(.allSeasons), id: nil)
                ForEach(seasons) { season in chip(season.title, id: season.id) }
            }
            .padding(.horizontal, Layout.screenMargin)
            .padding(.vertical, 16)
        }
        .padding(.horizontal, -Layout.screenMargin)
        .focusSection()
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

    @Environment(\.isFocused) private var focused
    @Environment(\.appTheme) private var theme

    var body: some View {
        label
            .font(.system(size: 24, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .foregroundStyle(focused ? Color.black : theme.textPrimary)
            .background(focused ? Color.white : (selected ? theme.accent : theme.surface), in: Capsule())
            .scaleEffect(focused ? 1.08 : (pressed ? 0.96 : 1))
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct ScheduleView: View {
    let model: ScheduleModel

    @Environment(\.appTheme) private var theme
    /// The focused row's id. It drives the title-only row's highlight.
    @FocusState private var focusedRow: String?
    /// The local clock. It moves every `ScheduleRefresh.interval`, with no network call.
    @State private var now = Date()
    /// The last row that had focus while the strip had it. When that row goes away (it ended, or
    /// a refresh dropped it), focus moves to the nearest row instead of the top of the screen.
    @State private var lastFocusedRow: String?
    #if DEBUG
    @Environment(AppRouter.self) private var router
    @Environment(\.debugScreen) private var debugScreen
    #endif

    var body: some View {
        let rows = model.entries(at: now)

        VStack(alignment: .leading, spacing: 18) {
            Text(model.title)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            if rows.isEmpty {
                Text(model.emptyMessage ?? ChromeText.string(.noSchedule))
                    .font(.system(size: 26))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 32) {
                        ForEach(rows) { entry in ScheduleRow(entry: entry, now: now, focus: $focusedRow) }
                    }
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.vertical, Layout.focusGrowth)
                }
                .padding(.horizontal, -Layout.screenMargin)
            }
        }
        .focusSection()
        .modifier(DefaultFocusRequest { focusedRow = model.entries(at: Date()).first?.id })
        .onChange(of: focusedRow) { _, id in
            if let id {
                lastFocusedRow = id
            } else if let last = lastFocusedRow, model.entries(at: now).contains(where: { $0.id == last }) {
                // The row is still there, so the viewer moved focus out of the strip.
                lastFocusedRow = nil
            }
        }
        .onChange(of: rows.map(\.id)) { old, new in
            guard let last = lastFocusedRow,
                  let next = ScheduleFocus.replacement(for: last, old: old, new: new) else { return }
            lastFocusedRow = next
            focusedRow = next
        }
        // Canceled with the view, so no timer outlives the strip. It restarts when the strip
        // shows again (Back, a tab switch) and takes the time at once, so ended rows never draw.
        .task {
            await ScheduleClock.run { now = $0 }
        }
        #if DEBUG
        .task {
            if let id = await DebugLaunch.focusScheduleRow(in: model.entries(at: Date()), screen: debugScreen, router: router) {
                focusedRow = id
                DebugLaunch.pressLiveNow(in: model.entries(at: Date()), router: router)
            }
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

/// Where focus goes when the focused schedule row goes away. Pure, so the rule is testable.
enum ScheduleFocus {
    /// The row now at the removed row's position, else the last row. nil when the row is still
    /// there, was not in the old list, or no row is left.
    static func replacement(for id: String, old: [String], new: [String]) -> String? {
        guard !new.contains(id), let index = old.firstIndex(of: id), !new.isEmpty else { return nil }
        // Rows before it that also went away shift the position left.
        let removedBefore = old[..<index].filter { !new.contains($0) }.count
        return new[min(index - removedBefore, new.count - 1)]
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
        VStack(alignment: .leading, spacing: 24) {
            // The block's own `title` prop, as the web draws it above the block.
            if let heading = model.heading {
                Text(heading)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            HStack(alignment: .top, spacing: 48) {
                if let url = model.imageURL {
                    RemoteImage(url: url, blurhash: model.blurhash)
                        .frame(width: 720, height: 405)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                DetailColumn(
                    hasLead: model.title != nil,
                    hasAction: model.trailer != nil || model.watchLater != nil || model.like != nil,
                    hasText: model.abstract != nil || !model.paragraphs.isEmpty,
                    leadText: [model.title, model.subtitle, model.ageRating, model.videoQuality, languageText, model.genres]
                        .compactMap { $0 }.joined(separator: "\n"),
                    bodyText: ([model.abstract].compactMap { $0 } + model.paragraphs).joined(separator: "\n")
                ) {
                    if let title = model.title {
                        VStack(alignment: .leading, spacing: 24) {
                            Text(title)
                                .font(.system(size: 60, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                            // Served only by an App whose Show carries one; absent draws no line.
                            if let subtitle = model.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 34, weight: .medium))
                                    .foregroundStyle(theme.accent)
                            }
                            // `MovieDetail` adds the quality badge, the language and the genres (awe#6870).
                            if model.ageRating != nil || model.videoQuality != nil || model.language != nil
                                || model.genres != nil {
                                HStack(spacing: 20) {
                                    if let ageRating = model.ageRating {
                                        AgeRatingBadge(label: ageRating)
                                    }
                                    if let quality = model.videoQuality {
                                        AgeRatingBadge(label: quality)
                                    }
                                    if let language = model.language {
                                        Text(language)
                                            .font(.system(size: 24, weight: .medium))
                                            .foregroundStyle(theme.textSecondary)
                                            .accessibilityLabel(languageText ?? language)
                                    }
                                    if let genres = model.genres {
                                        Text(genres)
                                            .font(.system(size: 24, weight: .medium))
                                            .foregroundStyle(theme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                } action: {
                    HStack(spacing: 24) {
                        if let trailer = model.trailer {
                            Button {
                                router.play(trailer)
                            } label: {
                                Label(ChromeText.string(.watchTrailer), systemImage: "film")
                            }
                            .font(.system(size: 30, weight: .semibold))
                            .modifier(TakesDefaultFocus())
                            .accessibilityIdentifier("watch-trailer")
                        }
                        if let item = model.watchLater {
                            WatchLaterToggle(item: item, takesDefaultFocus: model.trailer == nil)
                        }
                        if let item = model.like {
                            LikeToggle(item: item, takesDefaultFocus: model.trailer == nil && model.watchLater == nil)
                        }
                    }
                } text: {
                    DetailText(abstract: model.abstract, paragraphs: model.paragraphs)
                }
                // Beside the image the column is narrower; alone it takes the reading width.
                .frame(maxWidth: model.imageURL == nil ? 1200 : 900, alignment: .leading)
            }
        }
    }

    /// What VoiceOver reads for the language: "Language: Deutsch", as on `EpisodeDetail`.
    private var languageText: String? {
        model.language.map { "\(ChromeText.string(.languageLabel)): \($0)" }
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
            hasText: model.abstract != nil || !model.paragraphs.isEmpty,
            leadText: [model.showTitle, model.title, model.ageRating, languageText,
                       model.views.map { ChromeText.count(.viewsCount, $0, formatted: $0.formatted()) }]
                .compactMap { $0 }.joined(separator: "\n"),
            bodyText: ([model.abstract].compactMap { $0 } + model.paragraphs).joined(separator: "\n")
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let showTitle = model.showTitle {
                    Text(showTitle)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                if let title = model.title {
                    Text(title)
                        .font(.system(size: 60, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                }
                if model.ageRating != nil || model.language != nil {
                    HStack(spacing: 20) {
                        if let ageRating = model.ageRating {
                            AgeRatingBadge(label: ageRating)
                        }
                        if let language = model.language {
                            Text(language)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .accessibilityLabel(languageText ?? language)
                        }
                    }
                }
                if let views = model.views {
                    Text(ChromeText.count(.viewsCount, views, formatted: views.formatted()))
                        .font(.system(size: 24))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        } action: {
            HStack(spacing: 24) {
                if let target = showTarget {
                    Button {
                        router.openCard(target)
                    } label: {
                        Label(ChromeText.string(.goToShow), systemImage: "rectangle.stack")
                    }
                    .font(.system(size: 28, weight: .semibold))
                    .modifier(TakesDefaultFocus())
                    .accessibilityIdentifier("go-to-show")
                }
                if let item = model.watchLater {
                    WatchLaterToggle(item: item, takesDefaultFocus: showTarget == nil)
                }
                if let item = model.like {
                    LikeToggle(item: item, takesDefaultFocus: showTarget == nil && model.watchLater == nil)
                }
            }
        } text: {
            DetailText(abstract: model.abstract, paragraphs: model.paragraphs)
        }
        .frame(maxWidth: 1200, alignment: .leading)
    }

    /// What VoiceOver reads for the language: "Language: Deutsch". The screen draws the label alone.
    private var languageText: String? {
        model.language.map { "\(ChromeText.string(.languageLabel)): \($0)" }
    }
}

/// `ShowMeta`: label / value rows, like the app.hopetv.de show page. One focus stop.
private struct ShowMetaBlockView: View {
    let model: ShowMetaModel

    @Environment(\.appTheme) private var theme

    var body: some View {
        ReadingPanel(accessibilityText: model.rows.map { "\($0.label): \($0.spokenValue ?? $0.value)" }.joined(separator: "\n")) {
            Grid(alignment: .topLeading, horizontalSpacing: 32, verticalSpacing: 14) {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 260, alignment: .leading)
                        Text(row.value)
                            .font(.system(size: 28))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: 1200, alignment: .leading)
    }
}

/// A detail block's text column: the lead (the heading group), an optional action button, and
/// the text.
///
/// Reading focus is one stop per text block. With no button the lead and the text are ONE
/// `ReadingPanel`. With a button the lead stays plain above it, and the text below is the panel,
/// so the button sits under the heading group; that panel is a stop only when it scrolls.
private struct DetailColumn<Lead: View, Action: View, Body: View>: View {
    let hasLead: Bool
    let hasAction: Bool
    let hasText: Bool
    let lead: Lead
    let action: Action
    let text: Body

    /// What VoiceOver reads for the lead and for the text, when a panel holds them.
    let leadText: String
    let bodyText: String

    init(
        hasLead: Bool,
        hasAction: Bool,
        hasText: Bool,
        leadText: String,
        bodyText: String,
        @ViewBuilder lead: () -> Lead,
        @ViewBuilder action: () -> Action,
        @ViewBuilder text: () -> Body
    ) {
        self.hasLead = hasLead
        self.hasAction = hasAction
        self.hasText = hasText
        self.leadText = leadText
        self.bodyText = bodyText
        self.lead = lead()
        self.action = action()
        self.text = text()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if hasAction {
                if hasLead { lead }
                action
                // The button above already brings short text into view, so the text is a stop
                // only when it must scroll: no dead stop between the button and the next block.
                if hasText { ReadingPanel(focusableWhenShort: false, accessibilityText: bodyText) { text } }
            } else if hasLead || hasText {
                ReadingPanel(accessibilityText: [hasLead ? leadText : "", hasText ? bodyText : ""]
                    .filter { !$0.isEmpty }.joined(separator: "\n")) {
                    VStack(alignment: .leading, spacing: 24) {
                        if hasLead { lead }
                        if hasText { text }
                    }
                }
            }
        }
    }
}

/// The abstract and the body paragraphs of a detail block.
private struct DetailText: View {
    let abstract: String?
    let paragraphs: [String]

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let abstract {
                Text(abstract)
                    .font(.system(size: 28))
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 28))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

/// One focus stop for a block's whole text column, for text a viewer reads, not presses.
///
/// A tvOS ScrollView scrolls only to bring the focused view into view, so text with no focus
/// stop can never be read. Focus draws a quiet `surfaceSelected` panel, with no lift and no
/// shadow, so it never reads as a button. The negative margins take the panel's padding back
/// out, so the unfocused layout is exactly the plain text.
///
/// Text taller than `maxHeight` draws in a bounded panel that fades at a clipped edge. While it
/// has focus, Up and Down scroll it by a third of the panel; at the top or the bottom edge the
/// move leaves the panel as usual. Short text has no panel: Up and Down leave at once.
struct ReadingPanel<Content: View>: View {
    var maxHeight: CGFloat = ReadingScroll.maxHeight
    /// False: text that fits takes no focus (a button right above it is the stop).
    var focusableWhenShort = true
    /// What VoiceOver reads when the panel has focus. tvOS VoiceOver follows focus, so a focused
    /// panel reads its text; the drawn text is then hidden from it, so nothing reads twice.
    var accessibilityText = ""
    @ViewBuilder let content: Content

    @Environment(\.appTheme) private var theme
    @State private var focused = false
    @State private var contentHeight: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        let scroll = ReadingScroll(contentHeight: contentHeight, maxHeight: maxHeight)
        let focusable = focusableWhenShort || scroll.scrolls

        content
            .accessibilityHidden(focusable && !accessibilityText.isEmpty)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                contentHeight = height
                offset = ReadingScroll(contentHeight: height, maxHeight: maxHeight).clamp(offset)
            }
            .offset(y: -offset)
            .frame(maxWidth: .infinity, maxHeight: scroll.scrolls ? maxHeight : nil, alignment: .topLeading)
            .clipped()
            .mask { fade(scroll) }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(focused ? theme.surfaceSelected : .clear, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, -20)
            .padding(.vertical, -12)
            .background {
                FocusCatcher(focused: $focused, enabled: focusable, label: accessibilityText) { down in
                    let current = ReadingScroll(contentHeight: contentHeight, maxHeight: maxHeight)
                    guard let next = current.step(from: offset, down: down) else { return false }
                    withAnimation(.easeOut(duration: 0.25)) { offset = next }
                    return true
                }
            }
            .animation(.easeOut(duration: 0.15), value: focused)
    }

    /// A soft edge where text is clipped, so the viewer sees there is more.
    @ViewBuilder
    private func fade(_ scroll: ReadingScroll) -> some View {
        if scroll.scrolls {
            VStack(spacing: 0) {
                LinearGradient(colors: [offset > 0 ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 64)
                Color.black
                LinearGradient(colors: [.black, offset < scroll.overflow ? .clear : .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 64)
            }
        } else {
            Color.black
        }
    }
}

/// The scroll arithmetic of a `ReadingPanel`. Pure, so the rule is testable.
struct ReadingScroll: Equatable {
    /// The tallest a text panel draws before it scrolls.
    static let maxHeight: CGFloat = 620

    let contentHeight: CGFloat
    let maxHeight: CGFloat

    var overflow: CGFloat { max(contentHeight - maxHeight, 0) }
    var scrolls: Bool { overflow > 0.5 }
    /// One press moves a third of the panel.
    var stepSize: CGFloat { maxHeight / 3 }

    func clamp(_ offset: CGFloat) -> CGFloat { min(max(offset, 0), overflow) }

    /// The next offset for one press, or nil when there is nothing more to scroll that way —
    /// then focus leaves the panel.
    func step(from offset: CGFloat, down: Bool) -> CGFloat? {
        if down {
            guard offset < overflow - 0.5 else { return nil }
            return clamp(offset + stepSize)
        }
        guard offset > 0.5 else { return nil }
        return clamp(offset - stepSize)
    }
}

/// The focusable surface under a `ReadingPanel`.
///
/// SwiftUI has no way to keep focus in a view while it still has text to scroll: the focus
/// engine moves to the next focusable before `onMoveCommand` sees the press. This UIKit view
/// asks first. It refuses a vertical focus move (`shouldUpdateFocus`) or takes an arrow press
/// (`pressesBegan`) while `onMove` still scrolls, and lets the move through when it does not.
private struct FocusCatcher: UIViewRepresentable {
    @Binding var focused: Bool
    /// False: the view takes no focus.
    var enabled = true
    /// What VoiceOver reads while it has focus.
    var label = ""
    /// `true` is down. Answers true when it scrolled, so the move must not leave.
    let onMove: (Bool) -> Bool

    func makeUIView(context: Context) -> CatcherView { CatcherView() }

    func updateUIView(_ view: CatcherView, context: Context) {
        view.onMove = onMove
        view.onFocus = { focused = $0 }
        view.enabled = enabled
        // An accessibility element in every build, so VoiceOver reads the focused panel.
        view.isAccessibilityElement = enabled && !label.isEmpty
        view.accessibilityLabel = label
        #if DEBUG
        // The UI tests find a focusable panel by this id (`HopeTVUITests`).
        view.accessibilityIdentifier = enabled ? "reading-panel" : nil
        #endif
    }

    final class CatcherView: UIView {
        var onMove: ((Bool) -> Bool)?
        var onFocus: ((Bool) -> Void)?
        var enabled = true
        /// Arrow presses this view took, so their end and cancel events stay here too.
        private var taken = Set<UIPress.PressType>()
        /// A press and a focus move can report the same gesture; only the first one scrolls.
        private var lastStep = Date.distantPast

        override var canBecomeFocused: Bool { enabled }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            guard context.previouslyFocusedItem === self else { return true }
            let heading = context.focusHeading
            guard heading.contains(.down) || heading.contains(.up) else { return true }
            if Date().timeIntervalSince(lastStep) < 0.2 { return false }
            return !scroll(down: heading.contains(.down))
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            if context.nextFocusedItem === self {
                onFocus?(true)
            } else if context.previouslyFocusedItem === self {
                onFocus?(false)
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var rest = Set<UIPress>()
            for press in presses {
                if isFocused, press.type == .downArrow || press.type == .upArrow, scroll(down: press.type == .downArrow) {
                    taken.insert(press.type)
                } else {
                    rest.insert(press)
                }
            }
            if !rest.isEmpty { super.pressesBegan(rest, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = release(presses)
            if !rest.isEmpty { super.pressesEnded(rest, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = release(presses)
            if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
        }

        private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
            presses.filter { taken.remove($0.type) == nil }
        }

        private func scroll(down: Bool) -> Bool {
            guard onMove?(down) == true else { return false }
            lastStep = Date()
            return true
        }
    }
}

/// An episode's poster and one action. Nothing plays here (ruled 2026-09-23): Select opens the
/// full-screen `PlayerView`, the only place that seeks to a resume point and writes progress.
/// The poster is 720 x 405, the size of the `ShowDetail` image, so the block fits beside an
/// `EpisodeDetail` in a `direction: x` Container.
private struct PlayActionView: View {
    let model: PlayActionModel

    @Environment(AppRouter.self) private var router
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            RemoteImage(url: model.posterURL, blurhash: nil)
                .frame(width: 720, height: 405)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if let request = model.request {
                Button {
                    router.play(request)
                } label: {
                    Label(model.label ?? ChromeText.string(.play), systemImage: "play.fill")
                }
                .font(.system(size: 30, weight: .semibold))
                .modifier(TakesDefaultFocus())
                .accessibilityIdentifier("play-action")
            } else if let message = model.message {
                Text(message)
                    .font(.system(size: 26))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 720, alignment: .leading)
            }
        }
        .focusSection()
    }
}

/// The first action of a pushed screen takes focus once, when the screen first draws.
///
/// tvOS focuses the item nearest the top-left corner, so a Show screen opened on its first
/// episode card and scrolled the show header away. `prefersDefaultFocus` is not read inside
/// the screen's ScrollView, so the block's first action asks for focus itself. Once per view:
/// Back to this screen, or a refetched copy, keeps the focus where the viewer left it.
private struct TakesDefaultFocus: ViewModifier {
    var enabled = true

    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .modifier(DefaultFocusRequest(enabled: enabled) { focused = true })
    }
}

/// The request itself, for a block that moves focus through its own `@FocusState` (the hero,
/// the schedule strip, the person row). It runs `focus` once, when its block is the screen's default.
struct DefaultFocusRequest: ViewModifier {
    var enabled = true
    let focus: () -> Void

    @Environment(\.isDefaultFocusBlock) private var isDefault
    @State private var requested = false

    func body(content: Content) -> some View {
        content.task(id: isDefault && enabled) {
            guard isDefault && enabled, !requested else { return }
            // One layout pass first, so the focusable exists for the focus engine.
            guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
            requested = true
            focus()
        }
    }
}

/// The node id of the block that takes the default focus. Set on a pushed Screen and on the bare
/// entry (`AppRouter.takesDefaultFocus`). On a tab root, focus stays in the tab bar.
private struct DefaultFocusNodeKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct IsDefaultFocusBlockKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var defaultFocusNodeId: String? {
        get { self[DefaultFocusNodeKey.self] }
        set { self[DefaultFocusNodeKey.self] = newValue }
    }

    fileprivate var isDefaultFocusBlock: Bool {
        get { self[IsDefaultFocusBlockKey.self] }
        set { self[IsDefaultFocusBlockKey.self] = newValue }
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

/// How far the screen content starts below the stage top: the top safe area (overscan and the
/// tab bar) plus `ScreenBody`'s padding. 0 until measured.
private struct ScreenContentTopKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var screenContentTop: CGFloat? {
        get { self[ScreenContentTopKey.self] }
        set { self[ScreenContentTopKey.self] = newValue }
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
/// schedule row uses (awe#5044). `ScheduleClock` moves the on-air broadcast, as on the strip.
/// No broadcast on air (or none served): the dark card and the play button only.
private struct LiveCardView: View {
    let model: PlayerModel

    @Environment(AppRouter.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.screenContentTop) private var contentTop
    @State private var now = Date()

    var body: some View {
        let onAir = model.onAir(at: now)
        Button {
            router.play(model.request)
        } label: {
            // 16:9, as wide as fits (`InlineCardSize`), centered in the content column. The art
            // fills an overlay, so it never sizes the card.
            Color.black
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: InlineCardSize.maxWidth(contentTop: contentTop))
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
        }
        .buttonStyle(.card)
        .frame(maxWidth: .infinity)
        .modifier(TakesDefaultFocus())
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
            .font(.system(size: 64, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 140, height: 140)
            .background(.black.opacity(0.55), in: Circle())
    }

    /// "Now", then the broadcast title and its show, as the on-air schedule row says them.
    private func caption(_ entry: ScheduleModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ChromeText.string(.now))
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(theme.accent)
            Text(entry.title)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
            if let show = entry.showTitle {
                Text(show)
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .lineLimit(1)
        .padding(40)
    }
}

/// How big the Live card may draw. Pure, so the rule is testable.
///
/// Up from the top focusable reaches the tab bar only when the focused item fits on the stage
/// with the content scrolled to its top. A full-width card (1632 x 918 pt, about 1010 pt lifted)
/// did not fit under the tab bar, so tvOS kept the content scrolled and Up went nowhere.
enum InlineCardSize {
    /// `.buttonStyle(.card)` grows a focused card by about a tenth.
    static let focusScale: CGFloat = 1.1
    /// Room kept under the lifted card at the stage bottom.
    static let bottomMargin: CGFloat = 60

    /// The content top before the first measure: the tvOS tab-bar layout (safe area 140 +
    /// padding 60, measured on the tvOS simulator). With it the first layout already has the
    /// measured size, so the card does not jump.
    static let assumedContentTop: CGFloat = 200
    /// Never smaller than this, even for an odd safe area.
    static let minWidth: CGFloat = 640

    /// The widest 16:9 card whose lifted height fits between the content top and the stage
    /// bottom. `contentTop` is the stage-to-content distance (safe area + screen padding); nil
    /// until measured.
    static func maxWidth(contentTop: CGFloat?) -> CGFloat {
        let height = (Layout.stageHeight - (contentTop ?? assumedContentTop) - bottomMargin) / focusScale
        return max(height * 16.0 / 9.0, minWidth)
    }
}

/// The columns of a card grid in a given width. Four 392 pt cards fit inside the screen margins,
/// so a grid card is narrower than the same card on a shelf. A narrower grid (the search results
/// beside the grid keyboard) takes as many columns as fit at 360 pt or more, at least one, and
/// shares the width out. An unmeasured width draws four 392 pt columns.
///
/// A poster grid (`MovieList`, awe#6870) uses `Metrics.poster`: up to six 260 pt portrait columns,
/// at least 230 pt, so a tab's measured 1632 pt still takes six (238 pt). Every other grid uses
/// the default `Metrics.wide`.
enum GridColumns {
    struct Metrics: Equatable {
        let card: CGFloat
        let minimumCard: CGFloat
        let maximum: Int

        static let wide = Metrics(card: 392, minimumCard: 360, maximum: 4)
        static let poster = Metrics(card: 260, minimumCard: 230, maximum: 6)
    }

    static let spacing: CGFloat = 40

    static func count(width: CGFloat?, metrics: Metrics = .wide) -> Int {
        guard let width else { return metrics.maximum }
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

/// When a focused grid card asks for the next page (awe#5318): it is one of the last `columns`
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

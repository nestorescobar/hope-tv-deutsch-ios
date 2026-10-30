import SwiftUI

/// `MovieCast` and `MovieCrew` (awe#7035): a heading, then one row of round person tiles, as the
/// Apple TV "Cast & Crew" row.
///
/// Every tile is a focus stop, so Left and Right scroll the row and a row below the fold is
/// reachable: a tvOS screen scrolls only on a focus move. Select does nothing, as on an information
/// `ScheduleRow`, so a tile is `focusable`, not a `Button`. Focus draws on the circle (a lift and a
/// `focusRing` ring), not on a rectangular platter.
struct PeopleRowView: View {
    let model: PeopleRowModel

    @Environment(\.appTheme) private var theme
    @FocusState private var focusedTile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The web block heading is an `h5`.
            Text(model.heading)
                .font(BlockFont.heading(level: 5, theme: theme))
                .foregroundStyle(theme.textPrimary)

            // The same bleed as a shelf row: the row scrolls to the stage edges, and the vertical
            // slack keeps a lifted circle inside the scroll view.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: PersonTileMetrics.spacing) {
                    ForEach(model.tiles) { tile in
                        PersonTileView(tile: tile, focused: focusedTile == tile.id)
                            .focusable()
                            .focused($focusedTile, equals: tile.id)
                            .focusEffectDisabled()
                            .modifier(DefaultFocusRequest(enabled: tile.id == model.tiles.first?.id) { focusedTile = tile.id })
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel([tile.name, tile.role].compactMap { $0 }.joined(separator: ", "))
                            .accessibilityIdentifier("person-tile")
                    }
                }
                .padding(.horizontal, Layout.screenMargin)
                .padding(.vertical, Layout.focusGrowth)
            }
            .padding(.horizontal, -Layout.screenMargin)
        }
        .focusSection()
    }
}

/// The sizes of a person tile. The photo is requested at twice the circle (`photoWidth`), for a
/// 4K stage.
enum PersonTileMetrics {
    static let circle: CGFloat = 180
    static let width: CGFloat = 220
    static let spacing: CGFloat = 32
    static let photoWidth = Int(circle * 2)
}

/// One tile: the round photo (the neutral circle when there is none, or while it loads), the
/// name, then the role in the secondary color. Every tile has the same height.
private struct PersonTileView: View {
    let tile: PeopleRowModel.Tile
    let focused: Bool

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                theme.surfaceSelected
                if let url = tile.imageURL {
                    RemoteImage(url: url, blurhash: nil, contentMode: .fill, drawsPlaceholder: false)
                }
            }
            .frame(width: PersonTileMetrics.circle, height: PersonTileMetrics.circle)
            .clipShape(Circle())
            .overlay {
                if focused {
                    Circle().strokeBorder(theme.focusRing, lineWidth: 6)
                }
            }
            .scaleEffect(focused ? 1.1 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 12, y: 6)

            // Every tile has one height: the name and the role each reserve two lines, and the role
            // slot draws with no role. A lazy row sizes from the tiles it built, so a taller tile
            // scrolled in later was cut, or grew the row and moved the blocks below.
            Text(tile.name)
                .font(BlockFont.body(theme: theme, size: 24, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
            Text(tile.role ?? "")
                .font(BlockFont.body(theme: theme, size: 22))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
        }
        .frame(width: PersonTileMetrics.width, alignment: .top)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

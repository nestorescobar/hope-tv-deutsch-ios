import SwiftUI

/// `MovieCast` and `MovieCrew` (awe#7035): a heading, then one row of round person tiles, as the
/// Apple TV "Cast & Crew" row. A press does nothing, as on an information `ScheduleRow`.
struct PeopleRowView: View {
    let model: PeopleRowModel

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The web block heading is an `h5`.
            Text(model.heading)
                .font(BlockFont.heading(level: 5, theme: theme))
                .foregroundStyle(theme.textPrimary)

            // The same bleed as a shelf row: the row scrolls to the screen edges.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: PersonTileMetrics.spacing) {
                    ForEach(model.tiles) { tile in
                        PersonTileView(tile: tile)
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
    }
}

/// The sizes of a person tile. ContractKit requests the photo at `photoWidth`, the tvOS size, which
/// is also enough for this circle on a 3x screen.
enum PersonTileMetrics {
    static let circle: CGFloat = 84
    static let width: CGFloat = 104
    static let spacing: CGFloat = 12
    static let photoWidth = 360
}

/// One tile: the round photo (the neutral circle when there is none, or while it loads), the
/// name, then the role in the secondary color. Every tile has the same height.
private struct PersonTileView: View {
    let tile: PeopleRowModel.Tile

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                theme.surfaceSelected
                if let url = tile.imageURL {
                    RemoteImage(url: url, blurhash: nil, contentMode: .fill, drawsPlaceholder: false)
                }
            }
            .frame(width: PersonTileMetrics.circle, height: PersonTileMetrics.circle)
            .clipShape(Circle())

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
    }
}

import CoreGraphics

/// Ten-foot layout constants owned by the design system.
///
/// The document can choose which components appear and in what order; it has no way
/// to set margins, spacing, or focus growth.
enum Layout {
    /// Screen edge margin for titles and full-width blocks.
    static let screenMargin: CGFloat = 64

    /// Slack a shelf leaves around its cards so the tvOS focus effect can grow the
    /// focused card without being clipped by the scroll view's bounds.
    static let focusGrowth: CGFloat = 30

    /// Inset for a card's caption. The artwork is full-bleed to the card's edges, but
    /// the text sits inside the focus plate and needs to breathe away from it.
    static let cardCaptionInset: CGFloat = 18

    /// The tvOS stage in points, at 1080p and 4K alike.
    static let stageWidth: CGFloat = 1920
    static let stageHeight: CGFloat = 1080

    /// `ScreenBody`'s padding above and below the screen content.
    static let screenTopPadding: CGFloat = 60

    /// The layout height of a hero. Its art is taller (a full 16:9 stage) and runs under the
    /// first shelf, so that shelf's title shows at the stage bottom.
    static let heroHeight: CGFloat = 740

    /// The width of a `banner` card (16:9, image only). The ruled 1280 pt did not fit: with the
    /// shelf title above it, the focused card made tvOS scroll the tab bar away, so Up never
    /// reached the bar. At 1200 x 675 the focused card ends near y 997 (measured on the tvOS 27
    /// simulator, `BannerRowUITests`).
    static let bannerCardWidth: CGFloat = 1200
}

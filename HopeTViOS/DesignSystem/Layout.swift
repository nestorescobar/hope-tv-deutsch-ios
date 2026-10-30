import UIKit

/// Phone layout constants owned by the design system.
///
/// The document can choose which components appear and in what order; it has no way
/// to set margins or spacing.
enum Layout {
    /// Screen edge margin for titles and full-width blocks.
    static let screenMargin: CGFloat = 16

    /// tvOS slack for focus growth. Touch has no focus effect.
    static let focusGrowth: CGFloat = 0

    /// Inset for a card's caption.
    static let cardCaptionInset: CGFloat = 10

    /// The tvOS stage in points. ContractKit reads it for the hero art width and for `vw` and
    /// `vh` units, so it stays the authored stage. The hero art needs these pixels on a 3x
    /// screen: a tall hero crops the sides of 16:9 art.
    static let stageWidth: CGFloat = 1920
    static let stageHeight: CGFloat = 1080

    /// The phone's width in points. The app stays portrait, so the short side is the width, also
    /// under the landscape player.
    static var phoneWidth: CGFloat { UIScreen.main.bounds.size.shortSide }

    /// The device size for Umami's `screen`, portrait first.
    static var screenName: String {
        let size = UIScreen.main.bounds.size
        return "\(Int(size.shortSide))x\(Int(max(size.width, size.height)))"
    }

    /// `ScreenBody`'s padding above the screen content. The safe area does the work.
    static let screenTopPadding: CGFloat = 0

    /// `ScreenBody`'s padding below the screen content, above the floating tab bar.
    static let screenBottomPadding: CGFloat = 24

    /// The gaps of a `Container`, between its children. tvOS uses 40 pt and 44 pt.
    static let rowGap: CGFloat = 16
    static let columnGap: CGFloat = 28

    /// The gap between the cards of a shelf.
    static let cardGap: CGFloat = 12

    /// The layout height of a hero: taller than wide, as the website, with a cap for large phones.
    static func heroHeight(width: CGFloat) -> CGFloat {
        min(width * 1.1, 520)
    }

    /// The width of a `banner` card (16:9, image only). The next card peeks in only on a wide
    /// phone; a banner row pages by swipe.
    static var bannerCardWidth: CGFloat { phoneWidth - 2 * screenMargin }

    /// A tvOS type size on the phone. A 38 pt tvOS title is about 22 pt here. The seeded views
    /// keep their tvOS numbers, so a later upstream port reads the same.
    static func text(_ tvSize: CGFloat) -> CGFloat {
        (tvSize * 0.58).rounded()
    }
}

private extension CGSize {
    var shortSide: CGFloat { min(width, height) }
}

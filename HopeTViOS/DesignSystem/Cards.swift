import SwiftUI

/// The four card shapes this renderer ships.
///
/// The contract chooses which shelf appears, what is on it and which shape it asks for; it
/// cannot set pixel dimensions.
enum CardShape {
    case poster
    case wide
    /// The full-screen hero: 16:9 art across the whole stage (`HeroShelfView`).
    case hero
    /// A large image-only 16:9 card in a row (ruled 2026-10-24): the art carries the data.
    case banner

    /// artwork height ÷ artwork width
    var artAspect: CGFloat {
        switch self {
        case .poster: return 360.0 / 260.0
        case .wide: return 248.0 / 440.0
        case .hero, .banner: return 9.0 / 16.0
        }
    }

    var shelfWidth: CGFloat {
        switch self {
        case .poster: return 260
        case .wide: return 440
        // The hero is not a lifted card: its buttons take focus, so it can use the whole stage.
        case .hero: return Layout.stageWidth
        // A lifted card: focused, plus the shelf title, it still fits under the tab bar.
        case .banner: return Layout.bannerCardWidth
        }
    }

    /// The hero writes its caption over the artwork, and a banner card draws none, so neither
    /// reserves room under the art.
    var captionHeight: CGFloat { self == .hero || self == .banner ? 0 : 92 }

    /// One more line of title text under the card art.
    static let titleLineHeight: CGFloat = 30

    func height(forWidth width: CGFloat, titleLines: Int = 1) -> CGFloat {
        width * artAspect + captionHeight + CGFloat(max(titleLines - 1, 0)) * CardShape.titleLineHeight
    }

    var shelfHeight: CGFloat { height(forWidth: shelfWidth) }
}

extension CardModel {
    /// What VoiceOver reads for the card. A banner card draws no text, so it also names the
    /// subtitle; the other shapes draw it and read the title only.
    func accessibilityLabel(shape: CardShape) -> String {
        guard shape == .banner, let subtitle, !subtitle.isEmpty else { return title }
        return "\(title), \(subtitle)"
    }
}

struct MediaCard: View {
    let card: CardModel
    var shape: CardShape = .wide
    var width: CGFloat?
    var titleLines = 1

    private var cardWidth: CGFloat { width ?? shape.shelfWidth }

    var body: some View {
        if shape == .banner {
            // Image only: no title, subtitle or gradient, as the web banner. Art that is not
            // about 16:9 draws aspect-fit over a blurred copy (`artIsFallback`).
            HeroArt(card: card, width: cardWidth, height: cardWidth * shape.artAspect)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            captioned
        }
    }

    private var captioned: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A poster card whose art is not portrait draws it fit over a blurred copy (`artIsFallback`).
            HeroArt(card: card, width: cardWidth, height: cardWidth * shape.artAspect)
                .overlay(alignment: .topTrailing) { BadgeView(text: card.badge) }
                .overlay(alignment: .bottom) { ProgressStrip(progress: card.progress) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            CardCaption(card: card, width: cardWidth, titleLines: titleLines)
        }
        .frame(width: cardWidth, height: shape.height(forWidth: cardWidth, titleLines: titleLines), alignment: .top)
    }
}

/// Card art at a fixed frame (hero, banner, poster, landscape). Art that does not fit the frame
/// (`artIsFallback`) keeps the frame: the image is drawn aspect-fit, centered over a blurred copy
/// of itself, so nothing is cut (awe#4951).
struct HeroArt: View {
    let card: CardModel
    let width: CGFloat
    let height: CGFloat
    /// The hero shelf (ruled 2026-10-27, the one exception to awe#4951): every image fills the
    /// width and is cut at the bottom, as the web `Hero` (`object-cover object-top`).
    var fillsFromTop = false

    /// The backdrop takes the frame itself and flattens its blur into one layer. Measured on the
    /// simulator: an unframed fill layer under `.blur` drew crisp and full-width over the fit
    /// layer; framed and in a `drawingGroup` it blurs.
    var body: some View {
        Group {
            if card.artIsFallback, !fillsFromTop {
                ZStack {
                    RemoteImage(url: card.imageURL, blurhash: card.blurhash)
                        .frame(width: width, height: height)
                        .blur(radius: 48, opaque: true)
                        .drawingGroup()
                    RemoteImage(url: card.imageURL, blurhash: card.blurhash, contentMode: .fit, drawsPlaceholder: false)
                }
            } else {
                RemoteImage(url: card.imageURL, blurhash: card.blurhash)
            }
        }
        // A fill image is larger than the frame on one axis: the frame alignment picks the part kept.
        .frame(width: width, height: height, alignment: fillsFromTop ? .top : .center)
        .clipped()
    }
}

/// Title and subtitle. Width-limited so a long title truncates instead of widening the card
/// and breaking shelf alignment.
private struct CardCaption: View {
    let card: CardModel
    let width: CGFloat
    var titleLines = 1

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(titleLines)
                // A multi-line title reserves its lines, so every card of a grid keeps one height.
                .frame(height: titleLines > 1 ? CGFloat(titleLines) * CardShape.titleLineHeight : nil, alignment: .topLeading)
            Text(card.subtitle ?? "")
                .font(.system(size: 19))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: width - Layout.cardCaptionInset * 2, alignment: .leading)
        .padding(.horizontal, Layout.cardCaptionInset)
        .padding(.bottom, Layout.cardCaptionInset - 4)
    }
}

private struct BadgeView: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 16, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(text == "LIVE" ? Color.red : Color.black.opacity(0.65))
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(10)
        }
    }
}

private struct ProgressStrip: View {
    let progress: Double?

    var body: some View {
        if let progress {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.25))
                    Rectangle().fill(.white).frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 6)
        }
    }
}

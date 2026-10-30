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
        case .wide, .hero, .banner: return 9.0 / 16.0
        }
    }

    var shelfWidth: CGFloat {
        switch self {
        case .poster: return 130
        // Part of the next card shows at the right edge, as on the website.
        case .wide: return 248
        case .hero: return Layout.stageWidth
        case .banner: return Layout.bannerCardWidth
        }
    }

    /// Only a wide card has a caption: the hero writes it over the artwork, and a poster and a
    /// banner card are image only, as on the website. It fits the show name and two title lines.
    var captionHeight: CGFloat { self == .wide ? 72 : 0 }

    /// One more line of title text under the card art.
    static let titleLineHeight: CGFloat = 18

    func height(forWidth width: CGFloat, titleLines: Int = 1) -> CGFloat {
        width * artAspect + captionHeight + CGFloat(max(titleLines - 2, 0)) * CardShape.titleLineHeight
    }

    var shelfHeight: CGFloat { height(forWidth: shelfWidth) }
}

extension CardModel {
    /// What VoiceOver reads for the card. A banner or poster card draws no text, so it also names
    /// the subtitle; the other shapes draw it and read the title only.
    func accessibilityLabel(shape: CardShape) -> String {
        guard shape == .banner || shape == .poster, let subtitle, !subtitle.isEmpty else { return title }
        return "\(title), \(subtitle)"
    }
}

struct MediaCard: View {
    let card: CardModel
    var shape: CardShape = .wide
    var width: CGFloat?
    var titleLines = 1

    @Environment(\.appTheme) private var theme

    private var cardWidth: CGFloat { width ?? shape.shelfWidth }

    var body: some View {
        if shape == .wide {
            captioned
        } else {
            // Image only: no title, subtitle or gradient, as the web banner and poster. Art that is
            // not about the card's shape draws aspect-fit over a blurred copy (`artIsFallback`).
            HeroArt(card: card, width: cardWidth, height: cardWidth * shape.artAspect)
                .overlay(alignment: .topTrailing) { BadgeView(text: card.badge) }
                .overlay(alignment: .bottom) { ProgressStrip(progress: card.progress) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var captioned: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeroArt(card: card, width: cardWidth, height: cardWidth * shape.artAspect)
                .overlay(alignment: .topTrailing) { BadgeView(text: card.badge) }
                .overlay(alignment: .bottom) { ProgressStrip(progress: card.progress) }
            CardCaption(card: card, width: cardWidth)
        }
        .frame(width: cardWidth, height: shape.height(forWidth: cardWidth, titleLines: titleLines), alignment: .top)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

/// The website's caption: the show name uppercase in the accent color, then the title in up to two
/// lines. Width-limited so a long title truncates instead of widening the card.
private struct CardCaption: View {
    let card: CardModel
    let width: CGFloat

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
            }
            Text(card.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(width: width - Layout.cardCaptionInset * 2, alignment: .leading)
        .padding(.horizontal, Layout.cardCaptionInset)
        .padding(.vertical, 8)
    }
}

private struct BadgeView: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(text == "LIVE" ? Color.red : Color.black.opacity(0.65))
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(6)
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
            .frame(height: 3)
        }
    }
}

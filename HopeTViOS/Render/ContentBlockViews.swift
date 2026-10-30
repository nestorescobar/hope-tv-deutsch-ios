import SwiftUI

// The static content blocks of the `tv` design (awe#6116). `BlockRegistry` decides what draws;
// these views only decide how it looks. Colors and faces come from the theme seam.

/// `Divider`: a full-width line in the row-divider color (`surfaceSelected`), as the
/// `EpisodesList` rows use.
struct DividerBlockView: View {
    let model: DividerModel

    @Environment(\.appTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.surfaceSelected)
            .frame(maxWidth: .infinity)
            .frame(height: model.thickness)
            .accessibilityHidden(true)
    }
}

/// `Badge`: a label chip. Not a focus stop.
struct BadgeBlockView: View {
    let model: BadgeModel

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if let symbol = model.symbol {
                Image(systemName: symbol)
            }
            Text(model.label)
        }
        .font(BlockFont.body(theme: theme, size: 24, weight: .semibold))
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.surfaceSelected, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// An age rating ("FSK 12", awe#6867): the text in an outlined box, as the system player's Info
/// panel draws its content rating. Not a focus stop. Shared by the Episode and Show detail blocks
/// (and the Movie screens to come); the caller decides that a rating exists.
struct AgeRatingBadge: View {
    let label: String

    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(label)
            .font(.system(size: Layout.text(24), weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.textSecondary, lineWidth: 1))
            .fixedSize()
    }
}

/// `Header`: the kicker, the title, the subtitle, and the link row. The row is the `Button`
/// block's view, so it presses and takes the default focus the same way.
struct HeaderBlockView: View {
    let model: HeaderModel

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let kicker = model.kicker {
                Text(kicker)
                    .font(BlockFont.body(theme: theme, size: 26, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            if let title = model.title {
                Text(title)
                    .font(BlockFont.heading(level: model.level, theme: theme))
                    .foregroundStyle(theme.textPrimary)
            }
            if let subtitle = model.subtitle {
                Text(subtitle)
                    .font(BlockFont.body(theme: theme))
                    .foregroundStyle(theme.textSecondary)
            }
            if let link = model.link {
                ScreenLinkButton(model: link)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: 1200, alignment: .leading)
    }
}

/// `RichText`: read-only prose. The screen's own scroll view scrolls it.
struct RichTextBlockView: View {
    let model: RichTextModel

    var body: some View {
        RichTextBlocks(blocks: model.blocks)
            .frame(maxWidth: 1200, alignment: .leading)
    }
}

/// A run of Tiptap blocks. Lists and quotes draw their inner blocks with this view again.
private struct RichTextBlocks: View {
    let blocks: [RichTextModel.Block]
    /// Inside a quote, body text takes the primary color, as `SimpleText`'s quote does.
    var quoted = false

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: RichTextModel.Block) -> some View {
        switch block {
        case let .paragraph(runs):
            let font = BlockFont.body(theme: theme)
            Text(Self.attributed(runs, font: font))
                .font(font)
                .foregroundStyle(quoted ? theme.textPrimary : theme.textSecondary)
        case let .heading(level, runs):
            let font = BlockFont.heading(level: level, theme: theme)
            Text(Self.attributed(runs, font: font))
                .font(font)
                .foregroundStyle(theme.textPrimary)
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(ordered ? "\(start + index)." : "•")
                            .font(BlockFont.body(theme: theme))
                            .foregroundStyle(theme.textSecondary)
                        RichTextBlocks(blocks: item, quoted: quoted)
                    }
                }
            }
        case let .quote(inner):
            HStack(spacing: 24) {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 4)
                RichTextBlocks(blocks: inner, quoted: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle()
                .fill(theme.surfaceSelected)
                .frame(maxWidth: .infinity)
                .frame(height: 2)
        }
    }

    /// The runs as one attributed string. A mark sets the run's own face, so it holds under a
    /// custom preset font.
    private static func attributed(_ runs: [RichTextModel.Run], font: Font) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var part = AttributedString(run.text)
            switch (run.marks.contains(.bold), run.marks.contains(.italic)) {
            case (true, true): part.font = font.bold().italic()
            case (true, false): part.font = font.bold()
            case (false, true): part.font = font.italic()
            case (false, false): break
            }
            // The SwiftUI scope: a bare `.single` can resolve to the UIKit `NSUnderlineStyle` key.
            if run.marks.contains(.underline) { part.underlineStyle = Text.LineStyle.single }
            if run.marks.contains(.strike) { part.strikethroughStyle = Text.LineStyle.single }
            result += part
        }
    }
}

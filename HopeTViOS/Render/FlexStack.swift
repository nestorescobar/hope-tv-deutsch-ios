// cspell:ignore subview subviews Subviews Insettable
import SwiftUI

/// The children of one layout block, as a small flex box (awe#6297): along `axis` with at least
/// `spacing` between them, the free space spread by `justify`, and placed across by `align`.
///
/// Main-axis sizing follows `HStack` / `VStack`: the least flexible child is sized first, and each
/// child gets an equal share of the length that is left. A row asks its children for their height
/// at their width, as the old `.fixedSize(horizontal: false, vertical: true)` HStack did.
///
/// The layout never stretches a child. A child that fills the cross axis does it in its own
/// `NodeView`, before its background (AGENTS.md → Parent frames), and tells its own layout to
/// fill (`fillsWidth`, `fillsHeight`), so that `align` and `justify` have the room.
struct FlexStackLayout: SwiftUI.Layout {
    let axis: BlockContent.Axis
    let spacing: CGFloat
    let justify: LayoutStyle.Justify
    let align: LayoutStyle.Align
    /// The minimum and the fixed height inside the padding and the border.
    let minHeight: CGFloat?
    let height: CGFloat?
    /// The parent stretches this block: it takes the finite width or height on offer.
    var fillsWidth = false
    var fillsHeight = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let sizes = childSizes(proposal, subviews).sizes
        let content = sizes.reduce(0) { $0 + main($1) } + spacing * CGFloat(max(0, sizes.count - 1))
        // No spread takes the length on offer: `justify` spreads only space the block owns (a
        // stretch, `minHeight` or `height`), as on mobile and in the editor.
        let mainLength = content
        let crossLength: CGFloat
        if let offsets = baselineOffsets(sizes, subviews) {
            crossLength = zip(offsets, sizes).map { $0 + $1.height }.max() ?? 0
        } else {
            crossLength = sizes.map(cross).max() ?? 0
        }
        var size = axis == .horizontal
            ? CGSize(width: mainLength, height: crossLength)
            : CGSize(width: crossLength, height: mainLength)
        if fillsWidth, let offered = proposal.width, offered.isFinite { size.width = max(size.width, offered) }
        if fillsHeight, let offered = proposal.height, offered.isFinite { size.height = max(size.height, offered) }
        size.height = height ?? max(size.height, minHeight ?? 0)
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        let (sizes, offers) = childSizes(proposal, subviews)
        let positions = Self.mainPositions(sizes: sizes.map(main), spacing: spacing, length: main(bounds.size),
                                           justify: justify)
        let offsets = baselineOffsets(sizes, subviews)
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            // Along the axis, a child gets the offer it was sized with, as the system stacks do. A
            // measured length offered back re-runs a child stack's share-out: a horizontal shelf
            // then takes the free height from its siblings.
            if axis == .horizontal {
                // Each row child takes the row height; its own frame aligns it (`NodeView`).
                let y = offsets?[index] ?? 0
                subview.place(at: CGPoint(x: bounds.minX + positions[index], y: bounds.minY + y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: offers[index], height: bounds.height - y))
            } else {
                let x: CGFloat
                switch align {
                case .center: x = (bounds.width - size.width) / 2
                case .end: x = bounds.width - size.width
                case .start, .baseline, .stretch: x = 0
                }
                // At the start, the column width: a child that stretches fills it.
                let width = x == 0 ? bounds.width : size.width
                subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + positions[index]), anchor: .topLeading,
                              proposal: ProposedViewSize(width: width, height: offers[index]))
            }
        }
    }

    /// Where each child starts along the axis, from the free space and `justify`, as CSS
    /// `justify-content` with a `gap` spreads it. No free space packs the children at the start.
    static func mainPositions(sizes: [CGFloat], spacing: CGFloat, length: CGFloat, justify: LayoutStyle.Justify) -> [CGFloat] {
        let count = CGFloat(sizes.count)
        let free = length - sizes.reduce(0, +) - spacing * max(0, count - 1)
        var lead: CGFloat = 0
        var gap = spacing
        if free > 0, count > 0 {
            switch justify {
            case .start: break
            case .center: lead = free / 2
            case .end: lead = free
            case .between: if count > 1 { gap += free / (count - 1) }
            case .around: lead = free / count / 2; gap += free / count
            case .evenly: lead = free / (count + 1); gap += free / (count + 1)
            }
        }
        var position = lead
        return sizes.map { size in
            defer { position += size + gap }
            return position
        }
    }

    // MARK: - Sizing

    /// Each child's size, and the length along the axis it was offered (nil is its ideal length).
    private func childSizes(_ proposal: ProposedViewSize, _ subviews: LayoutSubviews) -> (sizes: [CGSize], offers: [CGFloat?]) {
        let crossOffer = axis == .horizontal ? nil : proposal.width
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        var offer = axis == .horizontal ? proposal.width : proposal.height
        if axis == .vertical, let height {
            // A fixed height is the offer only when the children fit in it. An over-full column
            // keeps their own size and overflows (RN `flexShrink: 0`, web `min-height: auto`).
            // The parent's offer cannot be used: a frame places the stack at its own height.
            let ideal = subviews.map { $0.sizeThatFits(propose(main: nil, cross: crossOffer)) }
            if ideal.reduce(0, { $0 + $1.height }) + gaps > height {
                return (ideal, Array(repeating: nil, count: subviews.count))
            }
            offer = height
        }
        guard let offered = offer, offered.isFinite, subviews.count > 1 else {
            return (subviews.map { $0.sizeThatFits(propose(main: offer, cross: crossOffer)) },
                    Array(repeating: offer, count: subviews.count))
        }
        // As the system stacks: the least flexible child first, each an equal share of the rest.
        let flexibility = subviews.map {
            main($0.sizeThatFits(propose(main: .infinity, cross: crossOffer)))
                - main($0.sizeThatFits(propose(main: 0, cross: crossOffer)))
        }
        let order = subviews.indices.sorted { (flexibility[$0], $0) < (flexibility[$1], $1) }
        var sizes = Array(repeating: CGSize.zero, count: subviews.count)
        var offers = Array(repeating: CGFloat?.none, count: subviews.count)
        var remaining = offered - gaps
        for (placed, index) in order.enumerated() {
            let share = max(0, remaining / CGFloat(subviews.count - placed))
            offers[index] = share
            sizes[index] = subviews[index].sizeThatFits(propose(main: share, cross: crossOffer))
            remaining -= main(sizes[index])
        }
        return (sizes, offers)
    }

    /// `align: baseline` in a row: how far down each child starts so that the first text
    /// baselines line up. In a column, baseline packs at the start, as CSS does.
    private func baselineOffsets(_ sizes: [CGSize], _ subviews: LayoutSubviews) -> [CGFloat]? {
        guard axis == .horizontal, align == .baseline else { return nil }
        let baselines = subviews.indices.map {
            subviews[$0].dimensions(in: ProposedViewSize(width: sizes[$0].width, height: nil))[VerticalAlignment.firstTextBaseline]
        }
        let deepest = baselines.max() ?? 0
        return baselines.map { deepest - $0 }
    }

    private func propose(main: CGFloat?, cross: CGFloat?) -> ProposedViewSize {
        axis == .horizontal ? ProposedViewSize(width: main, height: cross) : ProposedViewSize(width: cross, height: main)
    }

    private func main(_ size: CGSize) -> CGFloat { axis == .horizontal ? size.width : size.height }
    private func cross(_ size: CGSize) -> CGFloat { axis == .horizontal ? size.height : size.width }
}

/// The corners of a layout block (`borderRadius`). A radius is at most half the shorter side, so
/// `full` (9999) draws a pill. Insettable, so a border strokes inside the edge.
struct LayoutCornerShape: InsettableShape {
    let corners: LayoutStyle.Corners
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        guard !box.isNull, box.width > 0, box.height > 0 else { return Path() }
        let limit = min(box.width, box.height) / 2
        let radius = { (value: CGFloat) in min(max(0, value - inset), limit) }
        return UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: radius(corners.topLeft),
            bottomLeading: radius(corners.bottomLeft),
            bottomTrailing: radius(corners.bottomRight),
            topTrailing: radius(corners.topRight)
        )).path(in: box)
    }

    func inset(by amount: CGFloat) -> LayoutCornerShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// One side of a border with its own width: a line along the edge, inside the block.
struct LayoutBorderSide: Shape {
    let edge: Edge
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        let half = width / 2
        var path = Path()
        switch edge {
        case .top:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + half))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + half))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - half))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - half))
        case .leading:
            path.move(to: CGPoint(x: rect.minX + half, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + half, y: rect.maxY))
        case .trailing:
            path.move(to: CGPoint(x: rect.maxX - half, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - half, y: rect.maxY))
        }
        return path
    }
}

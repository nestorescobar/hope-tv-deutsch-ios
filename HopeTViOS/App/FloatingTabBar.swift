import SwiftUI

/// The manifest's Font Awesome names as SF Symbols. Pure, so the table is testable.
enum TabIcon {
    private static let symbols = [
        "house": "house",
        "circle-play": "play.circle",
        "magnifying-glass": "magnifyingglass",
        "video": "tv",
        "tv": "tv",
        "clock-rotate-left": "clock.arrow.circlepath",
        "download": "arrow.down.circle",
        "user": "person",
    ]

    /// An unknown or missing name draws a plain circle, so the tab stays tappable.
    static func symbol(for name: String?) -> String {
        name.flatMap { symbols[$0] } ?? "circle"
    }
}

/// The website's floating tab bar: rounded, inset from the screen edges, icon only, the active
/// tab in an accent pill. `LayoutTabs` keeps the tabs; this bar only selects.
struct FloatingTabBar: View {
    struct Item: Identifiable {
        let id: String
        let label: String
        let symbol: String
    }

    let items: [Item]
    @Binding var selection: String

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let active = item.id == selection
                Button {
                    selection = item.id
                } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(active ? theme.background : theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(active ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityIdentifier("tab-\(item.id)")
            }
        }
        .padding(6)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.horizontal, Layout.screenMargin)
        .padding(.bottom, 4)
    }
}

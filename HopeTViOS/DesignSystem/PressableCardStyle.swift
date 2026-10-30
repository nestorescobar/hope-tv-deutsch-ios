import SwiftUI

/// The press feedback of every card: touch has no focus lift.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A text action: Watch now, Play, Go to show. A prominent action is the website's light pill; the
/// others draw on `surface`. tvOS draws its own button platter; iOS has no such default on this
/// dark surface.
struct ActionButtonStyle: ButtonStyle {
    var prominent = false

    @Environment(\.appTheme) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? theme.background : theme.textPrimary)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(prominent ? theme.textPrimary.opacity(0.9) : theme.surfaceSelected, in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A row of text actions that stacks when the German labels do not fit one line.
struct ActionRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

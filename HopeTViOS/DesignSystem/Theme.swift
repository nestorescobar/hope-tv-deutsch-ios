import SwiftUI

/// The theme seam, layer two.
///
/// `PresetTokens` resolves the merged Design Preset to nine optional strings; this type
/// turns them into SwiftUI values. It adds no policy: a token that resolved to nil stays
/// nil here (ADR-0122), and the build's own floor is applied where a color is DRAWN — the
/// accessors below. The design system keeps every other decision (sizes, spacing, focus
/// behavior).
struct AppTheme: Equatable {
    /// What the preset resolved. A nil member is a real answer: the preset says nothing
    /// about this key, so the draw accessor uses `Floor`.
    var accentToken: Color?
    var focusRingToken: Color?
    var backgroundToken: Color?
    var surfaceToken: Color?
    var surfaceSelectedToken: Color?
    var textPrimaryToken: Color?
    var textSecondaryToken: Color?
    /// Read here, not in `PresetTokens`: only the phone's LIVE badge draws it.
    var dangerToken: Color?
    var headingFont: String?
    var bodyFont: String?

    /// This build's dark floor. A renderer decision, never a token value.
    enum Floor {
        static let accent = Color(hex: "#3F77B4") ?? .gray
        static let background = Color(hex: "#07090E") ?? .black
        static let surface = Color(hex: "#161B26") ?? .gray
        static let surfaceSelected = Color(hex: "#232B3A") ?? .gray
        static let textPrimary = Color.white
        static let textSecondary = Color(hex: "#9AA4B8") ?? .gray
        static let danger = Color.red
    }

    /// Nothing resolved: every accessor answers `Floor`. It is the environment default and
    /// the floor a refusal screen draws on.
    static let fallback = AppTheme()

    init() {}

    init(preset: JSONValue) {
        let tokens = PresetTokens(preset: preset)
        self.init(tokens: tokens)
        dangerToken = Color(hex: preset["colors"][tokens.semanticToKey["danger"] ?? "danger"]["500"].string)
    }

    init(tokens: PresetTokens) {
        accentToken = Color(hex: tokens.accent)
        focusRingToken = Color(hex: tokens.focusRing)
        backgroundToken = Color(hex: tokens.background)
        surfaceToken = Color(hex: tokens.surface)
        surfaceSelectedToken = Color(hex: tokens.surfaceSelected)
        textPrimaryToken = Color(hex: tokens.textPrimary)
        textSecondaryToken = Color(hex: tokens.textSecondary)
        headingFont = tokens.headingFont
        bodyFont = tokens.bodyFont
    }

    // MARK: - Drawing

    var accent: Color { accentToken ?? Floor.accent }
    /// The focus ring reads the same ramp step as the accent. tvOS draws card focus itself,
    /// so this is the color for chrome the renderer draws by hand.
    var focusRing: Color { focusRingToken ?? Floor.accent }
    var background: Color { backgroundToken ?? Floor.background }
    var surface: Color { surfaceToken ?? Floor.surface }
    /// The surface under a selected or pressed row.
    var surfaceSelected: Color { surfaceSelectedToken ?? Floor.surfaceSelected }
    var textPrimary: Color { textPrimaryToken ?? Floor.textPrimary }
    var textSecondary: Color { textSecondaryToken ?? Floor.textSecondary }
    var danger: Color { dangerToken ?? Floor.danger }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.fallback
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension Color {
    /// Accepts `#RRGGBB` and `#RRGGBBAA`, in either case (`RGBAColor(hex:)`). Anything else
    /// answers nil, so the caller omits the style instead of drawing a wrong color.
    init?(hex: String) {
        guard let rgba = RGBAColor(hex: hex) else { return nil }
        self.init(rgba)
    }

    init(_ rgba: RGBAColor) {
        self = Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.opacity)
    }

    /// An absent token stays absent.
    init?(hex: String?) {
        guard let hex else { return nil }
        self.init(hex: hex)
    }
}

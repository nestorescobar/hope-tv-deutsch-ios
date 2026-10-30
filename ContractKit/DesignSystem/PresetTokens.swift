import Foundation

/// The App Preset token mapper (ADR-0164 point 8).
///
/// Pure: the merged Design Preset in, nine optional strings out. It knows nothing about
/// SwiftUI — `AppTheme` turns these strings into colors and fonts.
///
/// ADR-0122 discipline: an unresolvable leaf answers **nil**, and the renderer omits the
/// style key. Never a fallback `0`, never a thrown error. This build's own floor belongs at
/// the use site (`AppTheme.Floor`), not in a token.
///
/// A token is the preset string **verbatim**: the mapper looks a value up, it never rewrites
/// one. `#3F77B4` stays `#3F77B4` — casing and prefix are the author's, and `Color(hex:)`
/// parses either case. The JS reader does the same (`typeof value === "string" ? value :
/// null`), so the three renderers can compare strings.
///
/// Three renderers carry a copy of this rule — Swift, Kotlin, and the JS
/// `resolveEffectiveColors` that `apps/mobile` and `apps/tv/web` share. The shared fixture
/// `fixtures/app-contract/preset-resolution.json` asserts all three. **If this file
/// disagrees with the fixture, this file is wrong.**
struct PresetTokens: Equatable {
    /// Ramp step per token. A TV draws on a dark surface, so every ramp is read at its
    /// dark end: 950 is the page, 50 is the text.
    let accent: String?
    let focusRing: String?
    let background: String?
    let surface: String?
    let surfaceSelected: String?
    let textPrimary: String?
    let textSecondary: String?
    let headingFont: String?
    let bodyFont: String?

    /// Semantic slot → palette key. The one computed step of the mapper; everything else
    /// is a lookup.
    let semanticToKey: [String: String]

    init(preset: JSONValue) {
        let colors = preset["colors"]
        // The App Contract serves no `colorTheme` today, so `defaultTheme` is the selection
        // in practice. Both are read, because the JS helper reads both and the shared
        // fixture exercises the `colorTheme` branch.
        let semanticToKey = SemanticColors.resolve(
            colors: colors,
            themes: preset["themes"],
            colorTheme: preset["colorTheme"].string,
            defaultTheme: preset["defaultTheme"].string
        )
        let primary = semanticToKey["primary"]
        let neutral = semanticToKey["neutral"]

        // No slot, no palette, no token: a path that reaches no string resolves to nil.
        func hex(_ palette: String?, _ step: String) -> String? {
            guard let palette else { return nil }
            return colors[palette][step].string
        }

        self.accent = hex(primary, "400")
        self.focusRing = hex(primary, "400")
        self.background = hex(neutral, "950")
        self.surface = hex(neutral, "900")
        self.surfaceSelected = hex(neutral, "800")
        self.textPrimary = hex(neutral, "50")
        self.textSecondary = hex(neutral, "400")
        self.headingFont = PresetTokens.fontName(preset, element: "h1")
        self.bodyFont = PresetTokens.fontName(preset, element: "p")
        self.semanticToKey = semanticToKey
    }

    /// A typography element names a font ROLE (`heading`, `body`); the role names a face in
    /// `preset.fonts`, whose own key is `family` (`FrontendFontDefinition`). The `tv` design
    /// serves `fonts: {}`, so both font tokens are nil and the system face draws.
    private static func fontName(_ preset: JSONValue, element: String) -> String? {
        guard let role = preset["typography"]["elements"][element]["family"].string else { return nil }
        return preset["fonts"][role]["family"].string
    }
}

/// Semantic slot → palette key, for one theme selection.
///
/// A port of `packages/designs/src/helpers/resolveEffectiveColors.ts`, narrowed to what a TV
/// needs: no alpha, no contrast, no light/dark resolution.
enum SemanticColors {
    /// Palette keys that already name a semantic slot.
    private static let directKeys: Set<String> = [
        "primary", "secondary", "tertiary", "neutral", "error", "warning", "success",
    ]

    /// Legacy palette keys and the slot each one fills. `danger` → `error` and `warn` →
    /// `warning` live here and nowhere else.
    private static let legacyKeys: [String: String] = [
        "theme": "primary",
        "neutral": "neutral",
        "danger": "error",
        "warn": "warning",
        "success": "success",
    ]

    /// `colorTheme` wins over `defaultTheme`; `"default"` on either means "no selection".
    static func resolve(
        colors: JSONValue,
        themes: JSONValue,
        colorTheme: String? = nil,
        defaultTheme: String?
    ) -> [String: String] {
        var map: [String: String] = [:]

        // Sorted, because a Swift dictionary has no insertion order to walk. It changes no
        // answer: a direct key always overwrites, and no two legacy keys share a slot.
        for key in colors.object.keys.sorted() {
            if directKeys.contains(key) {
                map[key] = key
            } else if let slot = legacyKeys[key], map[slot] == nil {
                map[slot] = key
            }
        }

        let selected = colorTheme == "default" ? nil : colorTheme
        let fallback = defaultTheme == "default" ? nil : defaultTheme
        guard let candidate = selected ?? fallback, !candidate.isEmpty else { return map }
        let themes = themes.array

        // The legacy `customTheme-<code>` form. No match keeps the base map; it never falls
        // through to the plain-code branch.
        if candidate.hasPrefix("customTheme-") {
            guard let theme = themes.first(where: { "customTheme-\($0["code"].string ?? "")" == candidate }) else {
                return map
            }
            apply(theme["colors"], to: &map, colors: colors)
            return map
        }

        if let theme = themes.first(where: { $0["code"].string == candidate }) {
            apply(theme["colors"], to: &map, colors: colors)
            return map
        }

        // The direct palette-key form: the candidate names a palette, which becomes primary.
        if !colors[candidate].isNull {
            map["primary"] = candidate
        }

        // An unknown code applies no override.
        return map
    }

    /// An override counts only when the palette it names exists.
    private static func apply(_ overrides: JSONValue, to map: inout [String: String], colors: JSONValue) {
        for (slot, value) in overrides.object {
            guard let paletteKey = value.string, !colors[paletteKey].isNull else { continue }
            map[slot] = paletteKey
        }
    }
}

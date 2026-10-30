import Foundation

/// A color as sRGB channels from 0 to 1. Pure, so the evaluator and its tests need no SwiftUI.
struct RGBAColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// Accepts `#RRGGBB` and `#RRGGBBAA`, in either case. Anything else answers nil, so the
    /// caller omits the style instead of drawing a wrong color. Exactly ONE leading `#` is
    /// dropped: `"#abcdef#"` is not a color. `Color(hex:)` reads through this.
    init?(hex: String) {
        var value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if value.count == 6 { value += "FF" }
        guard value.count == 8, let raw = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((raw & 0xFF00_0000) >> 24) / 255,
            green: Double((raw & 0x00FF_0000) >> 16) / 255,
            blue: Double((raw & 0x0000_FF00) >> 8) / 255,
            opacity: Double(raw & 0x0000_00FF) / 255
        )
    }

    /// The same color with its opacity multiplied by `factor`.
    func multiplyingOpacity(by factor: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, opacity: opacity * factor)
    }
}

/// Block color tokens → colors, for one App Preset (awe#6239).
///
/// A port of `apps/mobile` `createColorResolver` (`src/preset/colors.ts`). The theme map is
/// `SemanticColors.resolve`, the one the nine theme tokens use. The rules, in order:
///
/// 1. `transparent` is a clear color.
/// 2. A value that starts with `#` is a raw hex color (`RGBAColor(hex:)`), or nothing.
/// 3. A Tailwind alpha suffix (`primary-500/40`) is split off. An integer from 1 to 99 is the
///    opacity; any other suffix drops and the color stays opaque (ADR-0071).
/// 4. `white` and `black` are themselves.
/// 5. Else `<palette>-<step>`, split on the LAST dash. The palette goes through the theme map
///    (`primary` → the palette the theme picks), then `colors[palette][step]` is read.
///
/// A token that reaches no color answers nil, and the block draws no color (ADR-0122).
struct PresetColorResolver {
    private let colors: JSONValue
    private let semanticToKey: [String: String]

    /// No preset: every token answers nil.
    static let none = PresetColorResolver(preset: .null)

    init(preset: JSONValue) {
        colors = preset["colors"]
        semanticToKey = SemanticColors.resolve(
            colors: colors,
            themes: preset["themes"],
            colorTheme: preset["colorTheme"].string,
            defaultTheme: preset["defaultTheme"].string
        )
    }

    func color(_ token: String?) -> RGBAColor? {
        guard let token, !token.isEmpty else { return nil }
        if token == "transparent" { return RGBAColor(red: 0, green: 0, blue: 0, opacity: 0) }
        if token.hasPrefix("#") { return RGBAColor(hex: token) }

        let (base, alpha) = Self.splitAlpha(token)
        guard let color = paletteColor(base) else { return nil }
        return alpha.map { color.multiplyingOpacity(by: $0) } ?? color
    }

    private func paletteColor(_ token: String) -> RGBAColor? {
        switch token {
        case "white": return RGBAColor(red: 1, green: 1, blue: 1, opacity: 1)
        case "black": return RGBAColor(red: 0, green: 0, blue: 0, opacity: 1)
        default: break
        }
        // A Custom Palette key may hold a dash, so the step is after the LAST one.
        guard let dash = token.lastIndex(of: "-"), dash > token.startIndex else { return nil }
        let palette = String(token[..<dash])
        let step = String(token[token.index(after: dash)...])
        return colors[semanticToKey[palette] ?? palette][step].string.flatMap(RGBAColor.init(hex:))
    }

    private static func splitAlpha(_ token: String) -> (base: String, alpha: Double?) {
        guard let slash = token.firstIndex(of: "/") else { return (token, nil) }
        let base = String(token[..<slash])
        let suffix = token[token.index(after: slash)...]
        guard !suffix.contains("/"), let percent = Double(suffix), percent.rounded() == percent,
              percent > 0, percent < 100 else { return (base, nil) }
        return (base, percent / 100)
    }
}

import SwiftUI
import XCTest
@testable import HopeTViOS

/// The App Preset token mapper against the shared fixture (ADR-0122, ADR-0164 point 8).
///
/// `fixtures/app-contract/preset-resolution.json` drives the Swift, Kotlin and Vitest
/// suites. Every token is compared VERBATIM, and nil must meet `null` — a renderer that
/// substitutes its own floor here would hide the bug the fixture exists to catch.
final class PresetResolutionTests: XCTestCase {

    private static let fixtureName = "preset-resolution.json"

    /// Case names this suite knows how to read. A name outside the set fails on purpose:
    /// a case added to the shared file must be ported here, not skipped silently.
    private static let knownCases: Set<String> = [
        "tv-preset",
        "absent-leaf",
        "theme-default",
        "legacy-customTheme-prefix",
        "unknown-theme-code",
        "font-present",
        "uppercase-hex",
    ]

    private func fixture() throws -> JSONValue {
        guard Fixtures.exists(Self.fixtureName) else {
            throw XCTSkip("\(Self.fixtureName) is not in fixtures/app-contract yet")
        }
        return try Fixtures.shared(Self.fixtureName)
    }

    func testEveryCaseResolvesToTheExpectedTokens() throws {
        let cases = try fixture()["cases"].array
        XCTAssertFalse(cases.isEmpty, "the fixture carries no cases")

        for entry in cases {
            let name = try XCTUnwrap(entry["name"].text, "a case has no name")
            guard Self.knownCases.contains(name) else {
                XCTFail("\(name): this case is new to the shared fixture and is not ported to Swift yet")
                continue
            }

            let preset = try resolvePreset(entry["preset"])
            let tokens = PresetTokens(preset: preset)
            let expected = entry["expected"]

            guard case let .object(map) = expected["semanticToKey"] else {
                XCTFail("\(name): the case has no semanticToKey object")
                continue
            }
            XCTAssertEqual(tokens.semanticToKey, map.compactMapValues(\.string), "\(name): semanticToKey")

            for (token, value) in expected["tokens"].object {
                XCTAssertEqual(read(token, of: tokens), value.string, "\(name): \(token)")
            }
        }
    }

    /// The manifest's own preset resolves to the values the renderer draws with today.
    /// They are listed here so a palette edit shows up as a diff, not as a repaint.
    func testTheStagingManifestPresetResolvesTheDarkEndOfEachRamp() throws {
        let manifest = try ContractDecoder.manifest(Fixtures.data("manifest"))
        let tokens = PresetTokens(preset: manifest.preset)

        // Verbatim: the `hope-tv` preset stores lowercase, so the tokens read lowercase.
        XCTAssertEqual(tokens.accent, "#3f77b4")
        XCTAssertEqual(tokens.focusRing, "#3f77b4")
        XCTAssertEqual(tokens.background, "#0a0a0a")
        XCTAssertEqual(tokens.surface, "#171717")
        XCTAssertEqual(tokens.surfaceSelected, "#262626")
        XCTAssertEqual(tokens.textPrimary, "#fafafa")
        XCTAssertEqual(tokens.textSecondary, "#a3a3a3")
        // The `tv` design serves `fonts: {}`, so the system face draws and no font key is set.
        XCTAssertNil(tokens.headingFont)
        XCTAssertNil(tokens.bodyFont)

        // `danger` and `warn` are legacy palette keys; the aliasing lives only in this map.
        XCTAssertEqual(tokens.semanticToKey["error"], "danger")
        XCTAssertEqual(tokens.semanticToKey["warning"], "warn")
        XCTAssertEqual(tokens.semanticToKey["primary"], "primary")
    }

    /// An empty preset resolves nothing, and the theme then draws this build's floor.
    func testAnEmptyPresetResolvesNoTokenAndTheThemeFallsToItsFloor() throws {
        let tokens = PresetTokens(preset: .object([:]))

        XCTAssertNil(tokens.accent)
        XCTAssertNil(tokens.background)
        XCTAssertNil(tokens.textPrimary)
        XCTAssertTrue(tokens.semanticToKey.isEmpty)

        let theme = AppTheme(tokens: tokens)
        XCTAssertNil(theme.accentToken, "a nil token stays nil; the floor is applied at the use site")
        XCTAssertEqual(theme.accent, AppTheme.Floor.accent)
        XCTAssertEqual(theme, AppTheme.fallback)
    }

    /// Verbatim: the mapper looks a value up, it never rewrites one. The parse is
    /// case-insensitive, so an uppercase token draws the same color.
    func testAnUppercaseHexTokenIsCarriedVerbatim() throws {
        let preset = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {
          "colors": {
            "primary": { "400": "#3F77B4" },
            "neutral": { "950": "#0A0A0A", "900": "#171717", "800": "#262626",
                         "400": "#A3A3A3", "50": "#FAFAFA" }
          }
        }
        """.utf8))
        let tokens = PresetTokens(preset: preset)

        XCTAssertEqual(tokens.accent, "#3F77B4")
        XCTAssertEqual(tokens.background, "#0A0A0A")
        XCTAssertEqual(tokens.textPrimary, "#FAFAFA")
        XCTAssertEqual(AppTheme(tokens: tokens).accent, Color(hex: "#3f77b4"))
    }

    /// Exactly one leading `#`, then six or eight hex digits. Anything else is not a color,
    /// so the style key is omitted instead of drawing something wrong.
    func testTheColorParserAcceptsOneLeadingHashOnly() {
        XCTAssertNotNil(Color(hex: "#3F77B4"))
        XCTAssertNotNil(Color(hex: "3f77b4"))
        XCTAssertNotNil(Color(hex: "#3f77b4ff"))
        XCTAssertNil(Color(hex: "#abcdef#"))
        XCTAssertNil(Color(hex: "##abcdef"))
        XCTAssertNil(Color(hex: "rgb(63, 119, 180)"))
        XCTAssertNil(Color(hex: ""))
    }

    // MARK: - Fixture plumbing

    /// A case carries its preset inline, or as `{ "$ref": "<file>#/<pointer>" }` relative to
    /// `fixtures/app-contract`.
    private func resolvePreset(_ value: JSONValue) throws -> JSONValue {
        guard let ref = value["$ref"].text else { return value }
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let document = try Fixtures.shared(String(parts[0]))
        let resolved = parts.count == 2
            ? parts[1]
                .split(separator: "/")
                .reduce(document) { $0[String($1).replacingOccurrences(of: "~1", with: "/")] }
            : document

        // A pointer that reaches nothing would test an empty preset and pass by accident.
        guard case .object = resolved else {
            XCTFail("the $ref \"\(ref)\" reaches no object")
            return .object([:])
        }
        return resolved
    }

    private func read(_ token: String, of tokens: PresetTokens) -> String? {
        switch token {
        case "accent": return tokens.accent
        case "focusRing": return tokens.focusRing
        case "background": return tokens.background
        case "surface": return tokens.surface
        case "surfaceSelected": return tokens.surfaceSelected
        case "textPrimary": return tokens.textPrimary
        case "textSecondary": return tokens.textSecondary
        case "headingFont": return tokens.headingFont
        case "bodyFont": return tokens.bodyFont
        default:
            XCTFail("the fixture names a token this renderer does not map: \(token)")
            return nil
        }
    }
}

/// The semantic remap, in isolation.
///
/// A port of `packages/designs/src/helpers/resolveEffectiveColors.ts`. These cases pin the
/// branches the shared fixture may not carry yet.
final class SemanticColorsTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private let palettes = """
    {
      "primary": { "400": "#111111" },
      "neutral": { "950": "#222222" },
      "danger": { "400": "#333333" },
      "warn": { "400": "#444444" },
      "ocean": { "400": "#555555" }
    }
    """

    private func resolve(defaultTheme: String?, themes: String = "null") throws -> [String: String] {
        SemanticColors.resolve(
            colors: try json(palettes),
            themes: try json(themes),
            defaultTheme: defaultTheme
        )
    }

    func testTheBaseMapSendsEachSemanticSlotToItsOwnPalette() throws {
        let map = try resolve(defaultTheme: nil)

        XCTAssertEqual(map["primary"], "primary")
        XCTAssertEqual(map["neutral"], "neutral")
        // The legacy keys, aliased: `danger` fills `error`, `warn` fills `warning`.
        XCTAssertEqual(map["error"], "danger")
        XCTAssertEqual(map["warning"], "warn")
        // A Custom Palette fills no slot by itself.
        XCTAssertNil(map["ocean"])
    }

    func testAThemeCodeAppliesItsOverrides() throws {
        let themes = #"[{ "code": "sea", "colors": { "primary": "ocean" } }]"#
        XCTAssertEqual(try resolve(defaultTheme: "sea", themes: themes)["primary"], "ocean")
    }

    func testTheLegacyCustomThemePrefixMatchesTheSameTheme() throws {
        let themes = #"[{ "code": "sea", "colors": { "primary": "ocean" } }]"#
        XCTAssertEqual(try resolve(defaultTheme: "customTheme-sea", themes: themes)["primary"], "ocean")
        // No match keeps the base map; it never falls through to the plain-code branch.
        XCTAssertEqual(try resolve(defaultTheme: "customTheme-none", themes: themes)["primary"], "primary")
    }

    func testAnOverrideNamingAnAbsentPaletteIsIgnored() throws {
        let themes = #"[{ "code": "sea", "colors": { "primary": "not-a-palette" } }]"#
        XCTAssertEqual(try resolve(defaultTheme: "sea", themes: themes)["primary"], "primary")
    }

    /// A candidate that names a palette instead of a theme remaps `primary` to it.
    func testAPaletteKeyUsedAsTheThemeBecomesPrimary() throws {
        XCTAssertEqual(try resolve(defaultTheme: "ocean")["primary"], "ocean")
    }

    func testAnUnknownCodeAndTheLiteralDefaultApplyNoOverride() throws {
        XCTAssertEqual(try resolve(defaultTheme: "not-a-theme")["primary"], "primary")
        XCTAssertEqual(try resolve(defaultTheme: "default")["primary"], "primary")
        XCTAssertEqual(try resolve(defaultTheme: "")["primary"], "primary")
    }

    /// The remap moves the token, not only the map: a themed primary changes the accent.
    func testAThemedPrimaryMovesTheAccentToken() throws {
        let preset = try json("""
        {
          "colors": \(palettes),
          "themes": [{ "code": "sea", "colors": { "primary": "ocean" } }],
          "defaultTheme": "sea"
        }
        """)

        XCTAssertEqual(PresetTokens(preset: preset).accent, "#555555")
    }
}

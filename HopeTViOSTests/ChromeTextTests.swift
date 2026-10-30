// cspell:ignore Abspielen Aufrufe Eine Folge Folgen Gerätecode Jetzt Sendung Sprache Staffel Staffeln kann nicht öffnen
import Foundation
import Observation
import XCTest
@testable import HopeTViOS

/// The string seam: served `manifest.chrome.strings` first, then the English default.
final class ChromeTextTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        super.tearDown()
    }

    func testEveryKeyHasANonEmptyDefault() {
        for key in ChromeText.Key.allCases {
            XCTAssertFalse(ChromeText.string(key).isEmpty, key.rawValue)
        }
        for key in ChromeText.CountKey.allCases {
            XCTAssertFalse(ChromeText.count(key, 2).isEmpty, key.rawValue)
        }
    }

    func testCountsPickTheOneForm() {
        XCTAssertEqual(ChromeText.count(.episodesCount, 1), "1 episode")
        XCTAssertEqual(ChromeText.count(.episodesCount, 26), "26 episodes")
        XCTAssertEqual(ChromeText.count(.seasonsCount, 1), "1 season")
        XCTAssertEqual(ChromeText.count(.viewsCount, 6730, formatted: "6,730"), "6,730 views")
    }

    func testPlaceholdersAreFilled() {
        XCTAssertEqual(ChromeText.string(.onChannel, ["name": "Hope TV Deutsch"]), "On Hope TV Deutsch")
        XCTAssertEqual(ChromeText.string(.showsWithCount, ["count": "39"]), "Shows (39)")
        XCTAssertEqual(ChromeText.string(.cannotOpenApp, ["name": "Hope TV"]), "Hope TV cannot open this App")
    }

    // MARK: - Key mapping

    func testKeysMapToTheTvPrefixedManifestName() {
        XCTAssertEqual(ChromeText.manifestKey(.goToShow), "tvGoToShow")
        XCTAssertEqual(ChromeText.manifestKey(.languageLabel), "tvLanguageLabel")
        XCTAssertEqual(ChromeText.manifestKey(.open), "tvOpen")
        XCTAssertEqual(ChromeText.manifestKeys(.episodesCount).one, "tvEpisodesCount_one")
        XCTAssertEqual(ChromeText.manifestKeys(.episodesCount).other, "tvEpisodesCount_other")
        XCTAssertEqual(ChromeText.manifestKeys(.seasonsCount).one, "tvSeasonsCount_one")
        XCTAssertEqual(ChromeText.manifestKeys(.viewsCount).other, "tvViewsCount_other")

        var names = Set<String>()
        for key in ChromeText.Key.allCases {
            let name = ChromeText.manifestKey(key)
            XCTAssertTrue(name.hasPrefix("tv"), name)
            XCTAssertEqual(name.dropFirst(2).first?.isUppercase, true, name)
            XCTAssertEqual(name.dropFirst(2).prefix(1).lowercased() + name.dropFirst(3), key.rawValue, name)
            names.insert(name)
        }
        for key in ChromeText.CountKey.allCases {
            let base = "tv" + key.rawValue.prefix(1).uppercased() + key.rawValue.dropFirst()
            XCTAssertEqual(ChromeText.manifestKeys(key).one, "\(base)_one")
            XCTAssertEqual(ChromeText.manifestKeys(key).other, "\(base)_other")
            names.insert(ChromeText.manifestKeys(key).one)
            names.insert(ChromeText.manifestKeys(key).other)
        }
        XCTAssertEqual(names.count, ChromeText.Key.allCases.count + 2 * ChromeText.CountKey.allCases.count, "no two keys share a name")
    }

    /// Every key is read through its mapped name: a served value under that name wins.
    func testEveryKeyReadsItsServedValue() {
        var served: [String: String] = [:]
        for key in ChromeText.Key.allCases {
            served[ChromeText.manifestKey(key)] = "» " + ChromeText.english(key)
        }
        for key in ChromeText.CountKey.allCases {
            served[ChromeText.manifestKeys(key).one] = "» " + ChromeText.english(key).one
            served[ChromeText.manifestKeys(key).other] = "» " + ChromeText.english(key).other
        }
        ChromeText.served.strings = served

        for key in ChromeText.Key.allCases {
            let values = Dictionary(uniqueKeysWithValues: placeholders(ChromeText.english(key)).map { ($0, "x") })
            XCTAssertTrue(ChromeText.string(key, values).hasPrefix("» "), key.rawValue)
        }
        for key in ChromeText.CountKey.allCases {
            XCTAssertTrue(ChromeText.count(key, 1).hasPrefix("» "), key.rawValue)
            XCTAssertTrue(ChromeText.count(key, 3).hasPrefix("» "), key.rawValue)
        }
    }

    // MARK: - Served values and the fallback rule

    func testAServedValueIsUsed() {
        ChromeText.served.strings = ["tvGoToShow": "Zur Sendung", "tvOnChannel": "Auf {{name}}"]

        XCTAssertEqual(ChromeText.string(.goToShow), "Zur Sendung")
        XCTAssertEqual(ChromeText.string(.onChannel, ["name": "Hope TV"]), "Auf Hope TV")
        XCTAssertEqual(ChromeText.string(.play), "Play", "a key the manifest does not serve draws English")
    }

    func testAMobileKeyNeverFeedsATvKey() {
        // Production serves the mobile bag today: `languageLabel`, not `tvLanguageLabel`.
        ChromeText.served.strings = ["languageLabel": "Sprache", "deviceCodeLabel": "Gerätecode"]

        XCTAssertEqual(ChromeText.string(.languageLabel), "Language")
    }

    func testAnEmptyValueFallsBackToEnglish() {
        ChromeText.served.strings = ["tvPlay": "", "tvResume": "  \n"]

        XCTAssertEqual(ChromeText.string(.play), "Play")
        XCTAssertEqual(ChromeText.string(.resume), "Resume")
    }

    func testABadPlaceholderFallsBackToEnglish() {
        ChromeText.served.strings = [
            "tvOnChannel": "Auf Sendung",                       // the filled placeholder is missing
            "tvSeasonNumber": "Staffel {number}",               // single braces are not a placeholder
            "tvCannotOpenApp": "{{app}} kann das nicht öffnen", // a name the call site does not fill
            "tvOnNowTitle": "Jetzt: {{title}} {{extra}}",       // one extra placeholder
        ]

        XCTAssertEqual(ChromeText.string(.onChannel, ["name": "Hope TV"]), "On Hope TV")
        XCTAssertEqual(ChromeText.string(.seasonNumber, ["number": "2"]), "Season 2")
        XCTAssertEqual(ChromeText.string(.cannotOpenApp, ["name": "Hope TV"]), "Hope TV cannot open this App")
        XCTAssertEqual(ChromeText.string(.onNowTitle, ["title": "News"]), "On now: News")
    }

    /// The token grammar of the Backend translation editor: spaces inside the braces, and a
    /// format part after a comma, still name the placeholder.
    func testATokenMayHaveSpacesAndAFormatPart() {
        ChromeText.served.strings = [
            "tvOnChannel": "Auf {{ name }}",
            "tvShowsWithCount": "Sendungen ({{count, number}})",
            "tvEpisodesCount_other": "{{ count , number }} Folgen",
        ]

        XCTAssertEqual(ChromeText.string(.onChannel, ["name": "Hope TV"]), "Auf Hope TV")
        XCTAssertEqual(ChromeText.string(.showsWithCount, ["count": "39"]), "Sendungen (39)")
        XCTAssertEqual(ChromeText.count(.episodesCount, 17), "17 Folgen")
    }

    func testABadTokenStillFallsBackToEnglish() {
        ChromeText.served.strings = [
            "tvOnChannel": "Auf {{ nme }}",                  // a misspelled name
            "tvOnNowTitle": "Jetzt: {{title}} {{",           // an unclosed pair
            "tvSeasonNumber": "Staffel {{ , number}}",       // a format part with no name
            "tvShowsWithCount": "Sendungen ({{count})",      // one closing brace
        ]

        XCTAssertEqual(ChromeText.string(.onChannel, ["name": "Hope TV"]), "On Hope TV")
        XCTAssertEqual(ChromeText.string(.onNowTitle, ["title": "News"]), "On now: News")
        XCTAssertEqual(ChromeText.string(.seasonNumber, ["number": "2"]), "Season 2")
        XCTAssertEqual(ChromeText.string(.showsWithCount, ["count": "39"]), "Shows (39)")
    }

    func testAFilledValueIsNeverReadAsAToken() {
        XCTAssertEqual(ChromeText.string(.onNowTitle, ["title": "{{title}}"]), "On now: {{title}}")
    }

    func testAValueNeverDrawsAnUnfilledPlaceholder() {
        ChromeText.served.strings = ["tvPlay": "{{label}}", "tvOnChannel": "{{name}} {{name}}"]

        XCTAssertEqual(ChromeText.string(.play), "Play")
        XCTAssertEqual(ChromeText.string(.onChannel, ["name": "Hope"]), "Hope Hope", "a repeated placeholder fills each time")
    }

    // MARK: - Plurals

    func testPluralsPickOneForExactlyOne() {
        ChromeText.served.strings = [
            "tvEpisodesCount_one": "{{count}} Folge",
            "tvEpisodesCount_other": "{{count}} Folgen",
            "tvViewsCount_other": "{{count}} Aufrufe",
        ]

        XCTAssertEqual(ChromeText.count(.episodesCount, 1), "1 Folge")
        XCTAssertEqual(ChromeText.count(.episodesCount, 0), "0 Folgen")
        XCTAssertEqual(ChromeText.count(.episodesCount, 26), "26 Folgen")
        XCTAssertEqual(ChromeText.count(.viewsCount, 6730, formatted: "6.730"), "6.730 Aufrufe", "the digits are the formatted ones")
    }

    func testAMissingOneFormFallsBackToEnglishOne() {
        ChromeText.served.strings = ["tvViewsCount_other": "{{count}} Aufrufe"]

        XCTAssertEqual(ChromeText.count(.viewsCount, 1), "1 view")
        XCTAssertEqual(ChromeText.count(.viewsCount, 2), "2 Aufrufe")
    }

    func testAPluralFormWithoutTheCountFallsBackToEnglish() {
        ChromeText.served.strings = ["tvSeasonsCount_one": "Eine Staffel", "tvSeasonsCount_other": "Staffeln"]

        XCTAssertEqual(ChromeText.count(.seasonsCount, 1), "1 season")
        XCTAssertEqual(ChromeText.count(.seasonsCount, 4), "4 seasons")
    }

    // MARK: - Redraw

    /// A view body that read a chrome string is invalidated when the strings change.
    func testAChangeOfStringsNotifiesTheReader() {
        let changed = expectation(description: "the reader is told")
        withObservationTracking {
            _ = ChromeText.string(.play)
        } onChange: {
            changed.fulfill()
        }

        ChromeText.served.strings = ["tvPlay": "Abspielen"]

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(ChromeText.string(.play), "Abspielen")
    }

    // MARK: - Manifest decode

    func testTheManifestKeepsOnlyStringValues() throws {
        let manifest = try ContractDecoder.manifest(Data("""
        {"contractVersion": 1, "app": {}, "layouts": [], "screens": [],
         "chrome": {"ttlSec": 300, "strings": {
           "tvPlay": "Abspielen", "tvCount": 3, "tvNested": {"a": "b"}, "tvList": ["x"], "tvNull": null, "tvFlag": true
         }}}
        """.utf8))

        XCTAssertEqual(manifest.chromeStrings, ["tvPlay": "Abspielen"])
    }

    func testAManifestWithoutUsableChromeStillDecodes() throws {
        for chrome in ["", #", "chrome": null"#, #", "chrome": {"strings": "no"}"#, #", "chrome": ["x"]"#] {
            let manifest = try ContractDecoder.manifest(Data("""
            {"contractVersion": 1, "app": {"slug": "a"}, "layouts": [], "screens": []\(chrome)}
            """.utf8))

            XCTAssertEqual(manifest.chromeStrings, [:], chrome)
            XCTAssertEqual(manifest.app.slug, "a", chrome)
        }
    }

    func testTheFixtureManifestServesTheMobileBag() throws {
        let manifest = try ContractDecoder.manifest(Fixtures.data("manifest"))

        XCTAssertEqual(manifest.chromeStrings["languageLabel"], "Language")
        XCTAssertFalse(manifest.chromeStrings.isEmpty)
    }

    private func placeholders(_ template: String) -> [String] {
        template.components(separatedBy: "{{").dropFirst().compactMap { $0.components(separatedBy: "}}").first }
    }
}

/// Drift guard: the backend's English bag carries every tvOS default verbatim, so the English
/// the server merges under a translation is the English this build falls back to. CI does not
/// build tvOS, so it runs only in a local unit run.
final class ChromeTextEnglishDriftTests: XCTestCase {

    private func englishBag() throws -> [String: String] {
        let url = Fixtures.repository.appendingPathComponent("apps/backend/public/locales/mobile/en.json")
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    /// No stale `tv…` key: en.json holds exactly the names this renderer reads.
    func testEnJsonHoldsNoTvKeyThisRendererDoesNotRead() throws {
        let tvKeys = try englishBag().keys.filter { $0.range(of: "^tv[A-Z]", options: .regularExpression) != nil }
        var mapped = Set(ChromeText.Key.allCases.map(ChromeText.manifestKey))
        for key in ChromeText.CountKey.allCases {
            mapped.insert(ChromeText.manifestKeys(key).one)
            mapped.insert(ChromeText.manifestKeys(key).other)
        }

        XCTAssertEqual(Set(tvKeys).subtracting(mapped).sorted(), [], "tv keys in en.json that no ChromeText key reads")
        XCTAssertEqual(mapped.subtracting(tvKeys).sorted(), [], "ChromeText keys missing from en.json")
    }

    func testEnJsonCarriesEveryEnglishDefault() throws {
        let bag = try englishBag()

        for key in ChromeText.Key.allCases {
            let name = ChromeText.manifestKey(key)
            XCTAssertEqual(bag[name], ChromeText.english(key), name)
        }
        for key in ChromeText.CountKey.allCases {
            let names = ChromeText.manifestKeys(key)
            XCTAssertEqual(bag[names.one], ChromeText.english(key).one, names.one)
            XCTAssertEqual(bag[names.other], ChromeText.english(key).other, names.other)
        }
    }
}

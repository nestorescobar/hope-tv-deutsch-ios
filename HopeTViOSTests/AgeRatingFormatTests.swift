// cspell:ignore classind tvpg mpaa Kijkwijzer BBFC
import XCTest
@testable import HopeTViOS

/// `AgeRatingFormat` is a port of `packages/utils/src/media-library.ts`. These cases mirror the
/// `media-library.test.ts` tests of the option table, `getAgeRatingOption`, `formatAgeRating` and
/// `getPrimaryAgeRating`. The TS-only constants (systems, descriptors, limits) have no port.
final class AgeRatingFormatTests: XCTestCase {

    private func rating(_ json: String) throws -> JSONValue { try TestDocument.value(json) }

    // MARK: AGE_RATING_OPTIONS

    /// The whole table, copied from `AGE_RATING_OPTIONS`: every system, and per option its value,
    /// minimum age and label, in display order. tvpg and mpa use the value as the label.
    func testTheOptionTableEqualsTheTSCatalog() {
        typealias Row = (value: String, minAge: Int, label: String)
        let expected: [String: [Row]] = [
            "fsk": [("0", 0, "FSK 0"), ("6", 6, "FSK 6"), ("12", 12, "FSK 12"), ("16", 16, "FSK 16"), ("18", 18, "FSK 18")],
            "classind": [("L", 0, "ClassInd L"), ("10", 10, "ClassInd 10"), ("12", 12, "ClassInd 12"),
                         ("14", 14, "ClassInd 14"), ("16", 16, "ClassInd 16"), ("18", 18, "ClassInd 18")],
            "tvpg": [("TV-Y", 0, "TV-Y"), ("TV-Y7", 7, "TV-Y7"), ("TV-Y7-FV", 7, "TV-Y7-FV"), ("TV-G", 0, "TV-G"),
                     ("TV-PG", 10, "TV-PG"), ("TV-14", 14, "TV-14"), ("TV-MA", 17, "TV-MA")],
            "mpa": [("G", 0, "G"), ("PG", 10, "PG"), ("PG-13", 13, "PG-13"), ("R", 17, "R"), ("NC-17", 18, "NC-17")],
        ]

        XCTAssertEqual(Set(AgeRatingFormat.options.keys), Set(expected.keys), "no options for custom")
        for (system, rows) in expected {
            XCTAssertEqual(AgeRatingFormat.options[system], rows.map { .init(value: $0.value, minAge: $0.minAge, label: $0.label) }, system)
        }
    }

    // MARK: getAgeRatingOption

    func testFindsTheOptionOfAKnownSystem() {
        XCTAssertEqual(AgeRatingFormat.option(system: "fsk", value: "12"), .init(value: "12", minAge: 12, label: "FSK 12"))
        XCTAssertEqual(AgeRatingFormat.option(system: "classind", value: "L"), .init(value: "L", minAge: 0, label: "ClassInd L"))
    }

    func testNoOptionForAnUnknownValueCustomOrAnUnknownSystem() {
        XCTAssertNil(AgeRatingFormat.option(system: "fsk", value: "13"))
        XCTAssertNil(AgeRatingFormat.option(system: "custom", value: "12"))
        XCTAssertNil(AgeRatingFormat.option(system: "mpaa", value: "R"))
        XCTAssertNil(AgeRatingFormat.option(system: "constructor", value: "x"))
    }

    // MARK: formatAgeRating

    func testShowsTheOptionLabelOfAKnownSystem() throws {
        XCTAssertEqual(AgeRatingFormat.label(try rating(#"{ "system": "fsk", "value": "16" }"#)), "FSK 16")
        XCTAssertEqual(AgeRatingFormat.label(try rating(#"{ "system": "mpa", "value": "PG-13" }"#)), "PG-13")
        // The other two systems, as the catalog labels them.
        XCTAssertEqual(AgeRatingFormat.label(try rating(#"{ "system": "classind", "value": "14" }"#)), "ClassInd 14")
        XCTAssertEqual(AgeRatingFormat.label(try rating(#"{ "system": "tvpg", "value": "TV-14" }"#)), "TV-14")
    }

    func testNothingForAKnownSystemWithoutAValidValue() throws {
        XCTAssertNil(AgeRatingFormat.label(try rating(#"{ "system": "fsk" }"#)))
        XCTAssertNil(AgeRatingFormat.label(try rating(#"{ "system": "tvpg", "value": "X" }"#)))
    }

    func testShowsLabelAndValueOfACustomRating() throws {
        XCTAssertEqual(AgeRatingFormat.label(try rating(#"{ "system": "custom", "label": "BBFC", "value": "12A" }"#)), "BBFC 12A")
        XCTAssertEqual(AgeRatingFormat.label(try rating(#"{ "system": "custom", "value": "12A" }"#)), "12A")
    }

    func testFallsBackToTheMinimumAgeOfACustomRating() throws {
        XCTAssertEqual(AgeRatingFormat.label(try rating(#"{ "system": "custom", "label": "Kijkwijzer", "minAge": 9 }"#)), "Kijkwijzer 9+")
        XCTAssertEqual(AgeRatingFormat.label(try rating(#"{ "system": "custom", "minAge": 0 }"#)), "0+")
    }

    func testShowsTheLabelAloneWhenNothingElseIsSet() throws {
        XCTAssertEqual(AgeRatingFormat.label(try rating(#"{ "system": "custom", "label": "Family", "minAge": null }"#)), "Family")
    }

    func testNothingWhenNothingIsUsable() throws {
        XCTAssertNil(AgeRatingFormat.label(.null))
        XCTAssertNil(AgeRatingFormat.label(try rating(#"{ "system": "custom", "label": "  ", "value": "" }"#)))
    }

    // MARK: getPrimaryAgeRating

    func testThePrimaryRatingIsTheFirstItem() throws {
        let list = try rating(#"[{ "system": "fsk", "value": "12" }, { "system": "mpa", "value": "R" }]"#)
        XCTAssertEqual(AgeRatingFormat.primary(list), try rating(#"{ "system": "fsk", "value": "12" }"#))
        XCTAssertEqual(AgeRatingFormat.primaryLabel(list), "FSK 12")
    }

    func testNoPrimaryForAnEmptyOrMissingList() throws {
        XCTAssertNil(AgeRatingFormat.primary(try rating("[]")))
        XCTAssertNil(AgeRatingFormat.primary(.null))
        XCTAssertNil(AgeRatingFormat.primaryLabel(try rating("[]")))
        XCTAssertNil(AgeRatingFormat.primaryLabel(.null))
    }

    /// The first item is the primary, even when it formats to nothing: the badge never falls
    /// through to the second item.
    func testAnUnusablePrimaryDrawsNoBadge() throws {
        XCTAssertNil(AgeRatingFormat.primaryLabel(try rating(#"[{ "system": "fsk", "value": "13" }, { "system": "mpa", "value": "R" }]"#)))
    }
}

// cspell:ignore classind tvpg
import Foundation

/// The display text of a served `ageRatings` list (awe#6867).
///
/// A port of `packages/utils/src/media-library.ts`: `AGE_RATING_OPTIONS`, `getAgeRatingOption`,
/// `formatAgeRating` and `getPrimaryAgeRating`. **The TS file is the source of truth.** Change
/// both together; `AgeRatingFormatTests` mirrors `media-library.test.ts`.
enum AgeRatingFormat {
    /// One rating a known system defines. `minAge` is the machine value.
    struct Option: Equatable {
        let value: String
        let minAge: Int
        let label: String

        init(value: String, minAge: Int, label: String? = nil) {
            self.value = value
            self.minAge = minAge
            self.label = label ?? value
        }
    }

    /// The options of each known system, in display order. `custom` is free text and has none.
    static let options: [String: [Option]] = [
        "fsk": [
            Option(value: "0", minAge: 0, label: "FSK 0"),
            Option(value: "6", minAge: 6, label: "FSK 6"),
            Option(value: "12", minAge: 12, label: "FSK 12"),
            Option(value: "16", minAge: 16, label: "FSK 16"),
            Option(value: "18", minAge: 18, label: "FSK 18"),
        ],
        "classind": [
            Option(value: "L", minAge: 0, label: "ClassInd L"),
            Option(value: "10", minAge: 10, label: "ClassInd 10"),
            Option(value: "12", minAge: 12, label: "ClassInd 12"),
            Option(value: "14", minAge: 14, label: "ClassInd 14"),
            Option(value: "16", minAge: 16, label: "ClassInd 16"),
            Option(value: "18", minAge: 18, label: "ClassInd 18"),
        ],
        "tvpg": [
            Option(value: "TV-Y", minAge: 0),
            Option(value: "TV-Y7", minAge: 7),
            Option(value: "TV-Y7-FV", minAge: 7),
            Option(value: "TV-G", minAge: 0),
            Option(value: "TV-PG", minAge: 10),
            Option(value: "TV-14", minAge: 14),
            Option(value: "TV-MA", minAge: 17),
        ],
        "mpa": [
            Option(value: "G", minAge: 0),
            Option(value: "PG", minAge: 10),
            Option(value: "PG-13", minAge: 13),
            Option(value: "R", minAge: 17),
            Option(value: "NC-17", minAge: 18),
        ],
    ]

    /// `getAgeRatingOption`: the catalog option for a known `system` and `value`; nil for
    /// `custom` or no match.
    static func option(system: String, value: String) -> Option? {
        options[system]?.first { $0.value == value }
    }

    /// `formatAgeRating`: a known system shows its option label. A `custom` rating shows
    /// `label value`, else `label minAge+`, else `label`. nil when nothing is usable.
    static func label(_ rating: JSONValue) -> String? {
        guard case .object = rating else { return nil }
        let system = rating["system"].string
        guard system == "custom" else {
            return option(system: system ?? "", value: rating["value"].string ?? "")?.label
        }
        let label = trimmed(rating["label"].string)
        let value = trimmed(rating["value"].string)
        if !value.isEmpty {
            return trimmed("\(label) \(value)")
        }
        if let minAge = rating["minAge"].double, minAge.isFinite {
            return trimmed("\(label) \(number(minAge))+")
        }
        return label.isEmpty ? nil : label
    }

    /// `getPrimaryAgeRating`: the first item of the ordered list.
    static func primary(_ ratings: JSONValue) -> JSONValue? {
        ratings.array.first
    }

    /// The badge text: the primary rating's label. An unusable first item draws nothing; the
    /// second item never stands in for it.
    static func primaryLabel(_ ratings: JSONValue) -> String? {
        primary(ratings).flatMap(label)
    }

    private static func trimmed(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A JS number in a template string: `9`, not `9.0`.
    private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

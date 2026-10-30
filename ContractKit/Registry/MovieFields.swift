import Foundation

/// The field lists of the `MovieHero` meta line and the `MovieMeta` rows, and the "days left"
/// rule of the `MovieMeta` availability row.
///
/// A port of `packages/utils/src/media-library.ts`: `MOVIE_HERO_META_FIELDS`, `MOVIE_META_FIELDS`,
/// `normalizeMovieFields` and `getMovieDaysLeft`. **The TS file is the source of truth.** Change
/// both together, as `AgeRatingFormat`.
enum MovieFields {
    struct Field: Equatable {
        let name: String
        let enabled: Bool
    }

    /// `MOVIE_HERO_META_FIELDS`: year, runtime and age rating on; the rest off.
    static let heroMeta: [Field] = [
        Field(name: "releaseYear", enabled: true),
        Field(name: "duration", enabled: true),
        Field(name: "ageRating", enabled: true),
        Field(name: "countries", enabled: false),
        Field(name: "originalReleaseYear", enabled: false),
        Field(name: "accessibility", enabled: false),
        Field(name: "videoQuality", enabled: false),
    ]

    /// `MOVIE_META_FIELDS`: every row on, in this order.
    static let meta: [Field] = [
        "productionCompanies", "countries", "originalTitle", "originalLanguage", "originalReleaseYear",
        "releaseYear", "duration", "genres", "playbackLanguages", "subtitleLanguages", "accessibility",
        "videoQuality", "availability",
    ].map { Field(name: $0, enabled: true) }

    /// `MOVIE_ACCESSIBILITY_FLAGS`, in badge order.
    static let accessibilityFlags = ["ov", "ut", "ad", "dgs"]

    /// `MOVIE_AVAILABILITY_WARNING_DAYS`.
    static let availabilityWarningDays = 7

    /// `normalizeMovieFields`: the stored list as exactly the known fields, in the stored order. A
    /// non-array gives the defaults. An unknown name is dropped; for a duplicate name the first
    /// wins. A non-boolean `enabled` reads as that field's default. A missing known field is
    /// appended with its default.
    static func normalize(_ stored: JSONValue, defaults: [Field]) -> [Field] {
        let defaultEnabled = Dictionary(uniqueKeysWithValues: defaults.map { ($0.name, $0.enabled) })
        var seen = Set<String>()
        var result: [Field] = []
        for item in stored.array {
            guard let name = item["name"].string, let fallback = defaultEnabled[name], seen.insert(name).inserted
            else { continue }
            result.append(Field(name: name, enabled: item["enabled"].bool ?? fallback))
        }
        return result + defaults.filter { !seen.contains($0.name) }
    }

    /// The enabled names, in order.
    static func enabledNames(_ stored: JSONValue, defaults: [Field]) -> [String] {
        normalize(stored, defaults: defaults).filter(\.enabled).map(\.name)
    }

    /// `getMovieDaysLeft`: the calendar days left before the VOD window ends, in the device time
    /// zone. 0 is "ends today". nil without an end, once it has ended, or when it ends later than
    /// `availabilityWarningDays`. An end at exactly local midnight counts as the day before.
    static func daysLeft(endsAt: Date?, now: Date, calendar: Calendar = .current) -> Int? {
        guard let endsAt, endsAt > now else { return nil }
        // The last available instant: an end at 00:00 means "through the day before".
        let last = calendar.startOfDay(for: endsAt.addingTimeInterval(-0.001))
        guard let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: last).day
        else { return nil }
        return days <= availabilityWarningDays ? days : nil
    }
}

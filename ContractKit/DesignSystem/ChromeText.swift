import Foundation
import Observation

/// The one seam for every string the renderer itself draws (chrome), as opposed to content the
/// contract serves.
///
/// Lookup order: the served `manifest.chrome.strings` value, then the English default here.
/// The served key is `tv` + the case name with its first letter upper-cased (`goToShow` →
/// `tvGoToShow`); a count adds the i18next suffix `_one` (count 1) or `_other`. Placeholders are
/// i18next `{{name}}`. `apps/backend/public/locales/mobile/en.json` carries these English
/// defaults verbatim (`ChromeTextEnglishDriftTests`).
///
/// Fallback rule: a served value is used only when it is not blank and names exactly the
/// placeholders the call site fills (`{{ name }}` and `{{name, format}}` name `name`). Else that
/// one key draws English, so a bad translation never draws `{{name}}`.
enum ChromeText {
    enum Key: String, CaseIterable {
        case open
        case collection
        case featured
        case shows
        case showsWithCount
        case noShows
        case movies
        case moviesWithCount
        case noEpisodes
        case noLiveStream
        case play
        case resume
        case cannotPlayEpisode
        case cannotPlayMovie
        case untitled
        case keepWatching
        case nothingToWatch
        case onChannel
        case onNow
        case onNowTitle
        case noSchedule
        case broadcast
        case now
        case episode
        case watchNow
        case trailer
        case watchTrailer
        case watchFullScreen
        case goToShow
        case allSeasons
        case seasonNumber
        case showLabel
        case hostsLabel
        case categoriesLabel
        case languageLabel
        case seasonsLabel
        case episodesLabel
        case contentUnavailable
        case pressBackToReturn
        case cannotOpenApp
        case noTabs
        case searchPrompt
        case searchNoResults
        case searchUnavailable
        case timeLeft
        case upNext
        case upNextCountdown
        case playNow
        case stillWatching
        case continueWatching
        case nowPlaying
        case scheduleLabel
        case relatedLabel
        case account
        case signIn
        case signOut
        case signInPrompt
        case signedInAs
        case signInVisit
        case signInScan
        case signInWaiting
        case signInExpired
        case signInNewCode
        case signInUnavailable
        case signInFailed
        case signInContinue
        case watchHistoryHint
        case quality
        case qualityAuto
        case qualityUpTo
        case watchLater
        case removeFromWatchLater
        case remove
        case like
        case liked
        case unlike
        case cast
        case crew
        case crewJobDirector
        case crewJobWriter
        case crewJobAuthor
        case crewJobProducer
        case crewJobExecutiveProducer
        case crewJobCinematography
        case crewJobEditing
        case crewJobMusic
        case crewJobEditorial
        case crewJobCasting
        case crewJobProductionDesign
        case crewJobCostumeDesign
        case crewJobSound
        case crewJobVisualEffects
        case productionLabel
        case countryLabel
        case countriesLabel
        case originalTitleLabel
        case originalLanguageLabel
        case originalReleaseLabel
        case originalReleaseYear
        case releaseYearLabel
        case durationLabel
        case genresLabel
        case playbackLanguagesLabel
        case subtitlesLabel
        case accessibilityLabel
        case videoQualityLabel
        case availabilityLabel
        case availabilityToday
        case audioKindAudioDescription
        case audioKindDialogueBoost
        case accessibilityOv
        case accessibilityUt
        case accessibilityAd
        case accessibilityDgs
        case accessibilityLabelOv
        case accessibilityLabelUt
        case accessibilityLabelAd
        case accessibilityLabelDgs
    }

    /// A count with a one / other pair.
    enum CountKey: String, CaseIterable {
        case episodesCount
        case seasonsCount
        case viewsCount
        case availabilityDaysLeft
    }

    /// The served strings. The app sets them each time a manifest activates.
    static let served = ChromeStrings()

    static func string(_ key: Key, _ values: [String: String] = [:]) -> String {
        fill(template(served: served[manifestKey(key)], english: english(key), filling: values.keys), values)
    }

    /// `count` picks the `one` form for exactly 1, in every language (no locale plural rules).
    /// `formatted` replaces the digits the viewer reads (a grouped number, for example); the rule
    /// still reads `count`. Each form falls back on its own: a missing `_one` draws English `_one`.
    static func count(_ key: CountKey, _ count: Int, formatted: String? = nil) -> String {
        let forms = english(key)
        let keys = manifestKeys(key)
        let values = ["count": formatted ?? "\(count)"]
        let one = count == 1
        return fill(template(served: served[one ? keys.one : keys.other], english: one ? forms.one : forms.other,
                             filling: values.keys), values)
    }

    /// The `manifest.chrome.strings` key: `tv` + the case name with its first letter upper-cased.
    static func manifestKey(_ key: Key) -> String { "tv" + capitalizedFirst(key.rawValue) }

    /// The i18next plural pair of a count key.
    static func manifestKeys(_ key: CountKey) -> (one: String, other: String) {
        let base = "tv" + capitalizedFirst(key.rawValue)
        return ("\(base)_one", "\(base)_other")
    }

    /// The served value when it is usable (see the fallback rule above), else English.
    static func template(served: String?, english: String, filling names: some Collection<String>) -> String {
        guard let served, !served.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(tokens(in: served).map(\.name)) == Set(names) else { return english }
        // A `{{` outside a token (unclosed, nested) would draw as text.
        return replacingTokens(in: served) { _ in "" }.contains("{{") ? english : served
    }

    private static func capitalizedFirst(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    /// One i18next token, read as the Backend translation editor reads it
    /// (`apps/backend/modules/ui-translations/helpers/interpolations.js`): `{{ name, format }}`.
    /// The name is the text before the first comma, trimmed; the format part is ignored.
    private static let tokenPattern = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)

    private static func tokens(in text: String) -> [(range: Range<String.Index>, name: String)] {
        tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { return nil }
            let name = text[inner].split(separator: ",", omittingEmptySubsequences: false).first ?? ""
            return (range, name.trimmingCharacters(in: .whitespaces))
        }
    }

    /// One pass, so a filled value is never read as a token itself.
    private static func replacingTokens(in text: String, _ replacement: (_ name: String) -> String?) -> String {
        var result = ""
        var cursor = text.startIndex
        for token in tokens(in: text) {
            result += text[cursor..<token.range.lowerBound]
            result += replacement(token.name) ?? String(text[token.range])
            cursor = token.range.upperBound
        }
        return result + text[cursor...]
    }

    private static func fill(_ template: String, _ values: [String: String]) -> String {
        replacingTokens(in: template) { values[$0] }
    }

    /// The English default, and the fallback. `en.json` must carry it verbatim.
    static func english(_ key: Key) -> String {
        switch key {
        case .open: return "Open"
        case .collection: return "Collection"
        case .featured: return "Featured"
        case .shows: return "Shows"
        case .showsWithCount: return "Shows ({{count}})"
        case .noShows: return "No shows are published on this channel."
        case .movies: return "Movies"
        case .moviesWithCount: return "Movies ({{count}})"
        case .noEpisodes: return "No episodes are published for this show."
        case .noLiveStream: return "This channel has no live stream."
        case .play: return "Play"
        case .resume: return "Resume"
        case .cannotPlayEpisode: return "This episode can't play on this device."
        case .cannotPlayMovie: return "This movie can't play on this device."
        case .untitled: return "Untitled"
        case .keepWatching: return "Keep watching"
        case .nothingToWatch: return "Nothing to watch here yet."
        case .onChannel: return "On {{name}}"
        case .onNow: return "On now"
        case .onNowTitle: return "On now: {{title}}"
        case .noSchedule: return "No broadcast schedule is published for this channel."
        case .broadcast: return "Broadcast"
        case .now: return "Now"
        case .episode: return "Episode"
        case .watchNow: return "Watch now"
        case .trailer: return "Trailer"
        case .watchTrailer: return "Watch trailer"
        case .watchFullScreen: return "Watch full screen"
        case .goToShow: return "Go to show"
        case .allSeasons: return "All"
        case .seasonNumber: return "Season {{number}}"
        case .showLabel: return "Show"
        case .hostsLabel: return "Hosts"
        case .categoriesLabel: return "Categories"
        case .languageLabel: return "Language"
        case .seasonsLabel: return "Seasons"
        case .episodesLabel: return "Episodes"
        case .contentUnavailable: return "This content is not available."
        case .pressBackToReturn: return "Press Back to return."
        case .cannotOpenApp: return "{{name}} cannot open this App"
        case .noTabs: return "this App has no tabs to open"
        case .searchPrompt: return "Search episodes and shows"
        case .searchNoResults: return "No results"
        case .searchUnavailable: return "Search is not available"
        case .timeLeft: return "{{time}} left"
        case .upNext: return "Up Next"
        case .upNextCountdown: return "Plays in {{seconds}} s"
        case .playNow: return "Play now"
        case .stillWatching: return "Still watching?"
        case .continueWatching: return "Continue watching"
        case .nowPlaying: return "Now playing"
        case .scheduleLabel: return "Schedule"
        case .relatedLabel: return "Related"
        case .account: return "Account"
        case .signIn: return "Sign in"
        case .signOut: return "Sign out"
        case .signInPrompt: return "Sign in to use your account on this TV."
        case .signedInAs: return "Signed in as {{name}}"
        case .signInVisit: return "On your phone or computer, go to {{url}} and enter this code."
        case .signInScan: return "Or scan the QR code with your phone."
        case .signInWaiting: return "Waiting for approval"
        case .signInExpired: return "This code has expired."
        case .signInNewCode: return "Get a new code"
        case .signInUnavailable: return "Sign-in is not available for this App."
        case .signInFailed: return "Sign-in could not start. Try again."
        case .signInContinue: return "Continue"
        case .watchHistoryHint: return "Turn on watch history at {{site}}"
        case .quality: return "Quality"
        case .qualityAuto: return "Auto"
        case .qualityUpTo: return "Up to {{label}}"
        case .watchLater: return "Watch later"
        case .removeFromWatchLater: return "Remove from Watch later"
        case .remove: return "Remove"
        case .like: return "Like"
        case .liked: return "Liked"
        case .unlike: return "Unlike"
        case .cast: return "Cast"
        case .crew: return "Crew"
        case .crewJobDirector: return "Director"
        case .crewJobWriter: return "Screenplay"
        case .crewJobAuthor: return "Author"
        case .crewJobProducer: return "Producer"
        case .crewJobExecutiveProducer: return "Executive producer"
        case .crewJobCinematography: return "Cinematography"
        case .crewJobEditing: return "Editing"
        case .crewJobMusic: return "Music"
        case .crewJobEditorial: return "Editorial"
        case .crewJobCasting: return "Casting"
        case .crewJobProductionDesign: return "Production design"
        case .crewJobCostumeDesign: return "Costume design"
        case .crewJobSound: return "Sound"
        case .crewJobVisualEffects: return "Visual effects"
        case .productionLabel: return "Production"
        case .countryLabel: return "Country"
        case .countriesLabel: return "Countries"
        case .originalTitleLabel: return "Original title"
        case .originalLanguageLabel: return "Original language"
        case .originalReleaseLabel: return "Original release"
        case .originalReleaseYear: return "Original release {{year}}"
        case .releaseYearLabel: return "Release year"
        case .durationLabel: return "Duration"
        case .genresLabel: return "Genres"
        case .playbackLanguagesLabel: return "Playback languages"
        case .subtitlesLabel: return "Subtitles"
        case .accessibilityLabel: return "Accessibility"
        case .videoQualityLabel: return "Video quality"
        case .availabilityLabel: return "Availability"
        case .availabilityToday: return "Online today only"
        case .audioKindAudioDescription: return "Audio description"
        case .audioKindDialogueBoost: return "Dialogue Boost"
        case .accessibilityOv: return "OV"
        case .accessibilityUt: return "CC"
        case .accessibilityAd: return "AD"
        case .accessibilityDgs: return "SL"
        case .accessibilityLabelOv: return "Original version"
        case .accessibilityLabelUt: return "Subtitles"
        case .accessibilityLabelAd: return "Audio description"
        case .accessibilityLabelDgs: return "Sign language"
        }
    }

    /// The English `_one` / `_other` pair.
    static func english(_ key: CountKey) -> (one: String, other: String) {
        switch key {
        case .episodesCount: return ("{{count}} episode", "{{count}} episodes")
        case .seasonsCount: return ("{{count}} season", "{{count}} seasons")
        case .viewsCount: return ("{{count}} view", "{{count}} views")
        case .availabilityDaysLeft: return ("Only {{count}} day left online", "Only {{count}} days left online")
        }
    }
}

/// The served `manifest.chrome.strings`. The app writes it on the main actor when a manifest
/// activates; the evaluator reads it from any thread, so a lock guards the value. SwiftUI
/// observes it: a view whose body read a chrome string redraws when the strings change.
final class ChromeStrings: Observable, @unchecked Sendable {
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    var strings: [String: String] {
        get {
            registrar.access(self, keyPath: \.strings)
            return lock.withLock { storage }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.strings) {
                lock.withLock { storage = newValue }
            }
        }
    }

    subscript(key: String) -> String? { strings[key] }
}

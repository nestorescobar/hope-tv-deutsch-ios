// cspell:ignore Jetzt ansehen Weiterschauen Vorschau Merken Gemerkt Stimme Laufzeit
import XCTest
@testable import HopeTViOS

/// The field rules of `MovieHero` and `MovieMeta`: a port of `normalizeMovieFields`,
/// `MOVIE_HERO_META_FIELDS`, `MOVIE_META_FIELDS` and `getMovieDaysLeft`
/// (`packages/utils/src/media-library.ts`).
final class MovieFieldsTests: XCTestCase {

    private func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testANonArrayGivesTheDefaults() throws {
        XCTAssertEqual(MovieFields.normalize(.null, defaults: MovieFields.heroMeta), MovieFields.heroMeta)
        XCTAssertEqual(MovieFields.normalize(try value(#"{ "name": "duration" }"#), defaults: MovieFields.meta), MovieFields.meta)
        XCTAssertEqual(MovieFields.enabledNames(.null, defaults: MovieFields.heroMeta), ["releaseYear", "duration", "ageRating"])
    }

    /// Stored order wins. An unknown name is dropped, the first duplicate wins, a non-boolean
    /// `enabled` reads as the field's default, and a missing known field is appended.
    func testTheStoredListKeepsItsOrderAndIsCleaned() throws {
        let stored = try value("""
        [
          { "name": "videoQuality", "enabled": true },
          { "name": "bogus", "enabled": true },
          { "name": "releaseYear", "enabled": false },
          { "name": "videoQuality", "enabled": false },
          { "name": "ageRating", "enabled": "yes" },
          { "name": "countries" },
          null, 7
        ]
        """)
        XCTAssertEqual(MovieFields.normalize(stored, defaults: MovieFields.heroMeta).map(\.name),
                       ["videoQuality", "releaseYear", "ageRating", "countries", "duration", "originalReleaseYear", "accessibility"])
        XCTAssertEqual(MovieFields.enabledNames(stored, defaults: MovieFields.heroMeta),
                       ["videoQuality", "ageRating", "duration"])
    }

    func testTheMetaRowsAreAllOnInTheWebOrder() {
        XCTAssertEqual(MovieFields.meta.map(\.name), [
            "productionCompanies", "countries", "originalTitle", "originalLanguage", "originalReleaseYear", "releaseYear",
            "duration", "genres", "playbackLanguages", "subtitleLanguages", "accessibility", "videoQuality", "availability",
        ])
        XCTAssertTrue(MovieFields.meta.allSatisfy(\.enabled))
    }

    func testDaysLeftCountsLocalCalendarDaysInTheWarningWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15))!
        let at = { (day: Int, hour: Int) in calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }

        XCTAssertNil(MovieFields.daysLeft(endsAt: nil, now: now, calendar: calendar))
        XCTAssertNil(MovieFields.daysLeft(endsAt: at(19, 10), now: now, calendar: calendar), "ended")
        XCTAssertEqual(MovieFields.daysLeft(endsAt: at(19, 23), now: now, calendar: calendar), 0, "ends today")
        XCTAssertEqual(MovieFields.daysLeft(endsAt: at(20, 0), now: now, calendar: calendar), 0,
                       "an end at local midnight counts as the day before")
        XCTAssertEqual(MovieFields.daysLeft(endsAt: at(22, 9), now: now, calendar: calendar), 3)
        XCTAssertEqual(MovieFields.daysLeft(endsAt: at(26, 9), now: now, calendar: calendar), 7)
        XCTAssertNil(MovieFields.daysLeft(endsAt: at(27, 9), now: now, calendar: calendar), "later than the warning window")
    }
}

/// `MovieHero` (the `movieHero` resource, `apis/frontend/.../resources/movieHero.js`) as a one-page
/// hero, read as the web `shared/MovieHero.js`.
final class MovieHeroTests: XCTestCase {

    private let movieId = "6a1f0c2bd9c698836400aa01"
    private let stream = "https://media.test/movie.m3u8"
    private let banner = #"{ "name": "banner.jpg", "containerId": "c1", "width": 1920, "height": 1080 }"#

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        super.tearDown()
    }

    private func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// A served hero. `player` and the other parts take the JSON the test passes.
    private func movie(player: String? = nil) -> String {
        """
        {
          "id": "\(movieId)", "title": "Hope Rising", "abstract": "A film about hope.",
          "images": { "banner": \(banner), "default": { "name": "default.jpg", "containerId": "c1" } },
          "releaseYear": 2019, "duration": 6720,
          "ageRatings": [{ "system": "fsk", "value": "12" }],
          "genres": [{ "id": "g1", "title": "Drama" }, { "id": "g2", "title": "Family" }],
          "categories": [{ "id": "c1", "title": "Faith" }],
          "trailer": { "provider": "jetstream", "videoId": "jsv:trailer1" },
          "countries": [{ "code": "DE", "name": "Germany" }, { "code": "AT", "name": "Austria" }],
          "originalReleaseYear": 1999,
          "accessibility": { "ov": true, "ut": true, "ad": false, "dgs": true },
          "videoQuality": "4k",
          "player": \(player ?? #"{ "provider": "hls", "id": "\#(stream)", "poster": null, "resumeSeconds": 900 }"#)
        }
        """
    }

    private func evaluate(_ resource: String?, props: String = "{}", resumePoints: [String: Double] = [:],
                          memberResumePoints: [WatchHistoryItem: Double]? = nil) throws -> EvaluatedNode {
        let resources = resource.map { #"{ "hero": { "movieHero": \#($0) } }"# } ?? "{}"
        let document = try JSONDecoder().decode(CraftDocument.self, from: Data("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["hero"] },
          "hero": { "type": { "resolvedName": "MovieHero" }, "props": \(props), "parent": "ROOT", "nodes": [] }
        }
        """.utf8))
        let blockResources = try JSONDecoder().decode([String: [String: JSONValue]].self, from: Data(resources.utf8))
        let context = RenderContext(blockResources: blockResources, images: ImageConfig(cdn: "https://images.test", bucket: "bucket"),
                                    resumePoints: resumePoints, memberResumePoints: memberResumePoints)
        return try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: document, context: context))
    }

    private func shelf(_ resource: String?, props: String = "{}", resumePoints: [String: Double] = [:],
                       memberResumePoints: [WatchHistoryItem: Double]? = nil) throws -> ShelfModel? {
        let node = try evaluate(resource, props: props, resumePoints: resumePoints, memberResumePoints: memberResumePoints)
        guard case let .shelf(model)? = node.first(where: { $0.id == "hero" })?.content else { return nil }
        return model
    }

    private func hero(_ resource: String?, props: String = "{}", resumePoints: [String: Double] = [:],
                      memberResumePoints: [WatchHistoryItem: Double]? = nil) throws -> HeroModel {
        let model = try XCTUnwrap(try shelf(resource, props: props, resumePoints: resumePoints, memberResumePoints: memberResumePoints))
        return try XCTUnwrap(model.cards.first?.hero)
    }

    private func playRequest(_ hero: HeroModel) -> (request: PlaybackRequest, label: String)? {
        guard case let .play(request, label)? = hero.watchNow else { return nil }
        return (request, label)
    }

    func testTheKeysAreInTheRegistry() {
        XCTAssertEqual(BlockKey(resolvedName: "MovieHero"), .movieHero)
        XCTAssertEqual(BlockKey(resolvedName: "MovieMeta"), .movieMeta)
        XCTAssertTrue(BlockRegistry.keys.contains("MovieHero"))
        XCTAssertTrue(BlockRegistry.keys.contains("MovieMeta"))
    }

    func testNoResourceAndANullResourceDrawNothing() throws {
        XCTAssertNil(try shelf(nil))
        XCTAssertNil(try shelf("null"))
    }

    /// The defaults: a one-page hero (not the 2026-10-24 banner card) with the banner art, the
    /// abstract, "2019 • 1h 52m" and the age badge, the genres as chips, Watch now, the trailer,
    /// and Watch later.
    func testTheDefaultHeroIsOneHeroPage() throws {
        let model = try XCTUnwrap(try shelf(movie()))
        XCTAssertEqual(model.cardStyle, .hero)
        XCTAssertNil(model.title)
        XCTAssertEqual(model.cards.count, 1, "one page: no paging and no auto-advance")
        let card = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(card.title, "Hope Rising")
        XCTAssertEqual(card.style, .hero)
        XCTAssertNil(card.target, "Watch now plays; it is not a card press")
        XCTAssertEqual(card.imageURL, ImageConfig(cdn: "https://images.test", bucket: "bucket")
            .url(ImageFile(try value(banner)), width: Int(Layout.stageWidth)), "images.banner first")
        XCTAssertFalse(card.artIsFallback)

        let hero = try XCTUnwrap(card.hero)
        XCTAssertEqual(hero.abstract, "A film about hope.")
        XCTAssertEqual(hero.metaParts, [.text("2019"), .text("1h 52m"), .badge("FSK 12")])
        XCTAssertTrue(hero.metaBeforeAbstract, "the meta line draws above the abstract, as the web hero")
        XCTAssertEqual(hero.actions, [.watch, .trailer, .watchLater])
        XCTAssertEqual(hero.categories, ["Drama", "Family"], "genres on, categories off")
        XCTAssertNil(hero.tagSeparator, "tags draw as chips")
        XCTAssertNotNil(hero.trailer, "a Jetstream VOD trailer resolves")
        XCTAssertEqual(playRequest(hero)?.label, "Watch now")
        XCTAssertEqual(playRequest(hero)?.request.url.absoluteString, stream)
        XCTAssertEqual(hero.watchLater, SavedItem(itemType: .movie, itemId: movieId, title: "Hope Rising",
                                                  imageURL: ImageConfig(cdn: "https://images.test", bucket: "bucket")
                                                      .url(ImageFile(try value(#"{ "name": "default.jpg", "containerId": "c1" }"#)), width: 640),
                                                  savedAt: .distantPast))
    }

    /// The meta line follows the normalized `metaFields`: stored order, the enabled parts only.
    func testTheMetaLineFollowsTheMetaFields() throws {
        let props = """
        { "metaFields": [
          { "name": "videoQuality", "enabled": true },
          { "name": "accessibility", "enabled": true },
          { "name": "countries", "enabled": true },
          { "name": "originalReleaseYear", "enabled": true },
          { "name": "releaseYear", "enabled": false },
          { "name": "ageRating", "enabled": "on" },
          { "name": "unknown", "enabled": true }
        ] }
        """
        XCTAssertEqual(try hero(movie(), props: props).metaParts, [
            .badge("4K"), .badge("OV", spoken: "Original version"), .badge("CC", spoken: "Subtitles"),
            .badge("SL", spoken: "Sign language"), .text("Germany, Austria"),
            .text("Original release 1999"), .badge("FSK 12"), .text("1h 52m"),
        ], "ageRating keeps its default (on) for a non-boolean flag; the missing duration is appended on")
        XCTAssertEqual(try hero(movie(), props: props).meta, "4K • OV • CC • SL • Germany, Austria • Original release 1999 • FSK 12 • 1h 52m")
    }

    func testAPartWithNoValueIsLeftOut() throws {
        let bare = """
        { "id": "\(movieId)", "title": "Bare", "images": {}, "releaseYear": 0, "duration": 0, "ageRatings": [],
          "countries": [], "originalReleaseYear": null, "accessibility": { "ov": false }, "videoQuality": "",
          "genres": [], "categories": [], "player": null }
        """
        let props = #"{ "metaFields": [{ "name": "countries", "enabled": true }, { "name": "originalReleaseYear", "enabled": true }, { "name": "accessibility", "enabled": true }, { "name": "videoQuality", "enabled": true }] }"#
        let hero = try hero(bare, props: props)
        XCTAssertEqual(hero.metaParts, [])
        XCTAssertNil(hero.meta)
        XCTAssertEqual(hero.categories, [])
    }

    /// The runtime rounds to minutes as the web `getRuntimeMinutes`: under 30 s draws no part.
    func testAVeryShortRuntimeIsLeftOut() throws {
        XCTAssertEqual(try hero(movie().replacingOccurrences(of: #""duration": 6720"#, with: #""duration": 29"#)).metaParts,
                       [.text("2019"), .badge("FSK 12")])
        XCTAssertEqual(try hero(movie().replacingOccurrences(of: #""duration": 6720"#, with: #""duration": 30"#)).metaParts,
                       [.text("2019"), .text("30s"), .badge("FSK 12")])
    }

    func testTheGenresAndCategoriesDrawAsTagsOrAsTextWithTheSeparator() throws {
        XCTAssertEqual(try hero(movie(), props: #"{ "showCategories": true }"#).categories, ["Drama", "Family", "Faith"],
                       "the categories follow the genres")
        XCTAssertEqual(try hero(movie(), props: #"{ "showGenres": false, "showCategories": true }"#).categories, ["Faith"])
        XCTAssertEqual(try hero(movie(), props: #"{ "showGenres": false }"#).categories, [])

        XCTAssertEqual(try hero(movie(), props: #"{ "genresDisplay": "text" }"#).tagSeparator, " • ")
        XCTAssertEqual(try hero(movie(), props: #"{ "genresDisplay": "text", "tagsSeparator": "pipe" }"#).tagSeparator, " | ")
        XCTAssertEqual(try hero(movie(), props: #"{ "genresDisplay": "text", "tagsSeparator": "comma" }"#).tagSeparator, " • ",
                       "an unknown separator reads as the dot")
        XCTAssertNil(try hero(movie(), props: #"{ "genresDisplay": "tags", "tagsSeparator": "pipe" }"#).tagSeparator)
        XCTAssertNil(try hero(movie(), props: #"{ "genresDisplay": "list" }"#).tagSeparator, "any other value draws chips")
    }

    func testTheAbstractFollowsShowAbstract() throws {
        XCTAssertNil(try hero(movie(), props: #"{ "showAbstract": false }"#).abstract)
    }

    func testAuthorLabelsWinAndEmptyLabelsDrawTheChromeStrings() throws {
        let labels = """
        { "watchNowLabel": "Jetzt ansehen", "resumeLabel": "Weiterschauen", "trailerLabel": "Vorschau",
          "watchlistLabel": "Merken", "watchlistSavedLabel": "Gemerkt" }
        """
        let custom = try hero(movie(), props: labels)
        XCTAssertEqual(playRequest(custom)?.label, "Jetzt ansehen")
        XCTAssertEqual(custom.trailerLabel, "Vorschau")
        XCTAssertEqual(custom.watchLaterLabel, "Merken")
        XCTAssertEqual(custom.watchLaterSavedLabel, "Gemerkt")
        XCTAssertEqual(playRequest(try hero(movie(), props: labels, resumePoints: [stream: 0.4]))?.label, "Weiterschauen")

        let blank = try hero(movie(), props: #"{ "watchNowLabel": "", "resumeLabel": " ", "trailerLabel": "", "watchlistLabel": "" }"#)
        XCTAssertEqual(playRequest(blank)?.label, "Watch now")
        XCTAssertNil(blank.trailerLabel, "nil draws the chrome Trailer string")
        XCTAssertNil(blank.watchLaterLabel)
    }

    func testTheWatchLaterTitleRule() {
        XCTAssertEqual(WatchLaterButton.title(saved: false, label: nil, savedLabel: nil), "Watch later")
        XCTAssertEqual(WatchLaterButton.title(saved: true, label: nil, savedLabel: nil), "Remove from Watch later")
        XCTAssertEqual(WatchLaterButton.title(saved: false, label: "Merken", savedLabel: "Gemerkt"), "Merken")
        XCTAssertEqual(WatchLaterButton.title(saved: true, label: "Merken", savedLabel: "Gemerkt"), "Gemerkt")
        XCTAssertEqual(WatchLaterButton.title(saved: true, label: "Merken", savedLabel: nil), "Merken",
                       "no saved label takes the label, as on the web")
    }

    /// Resume follows the `MoviePlayer` rule: device progress by URL signed out, the member copy by
    /// movie signed in. The served `player.resumeSeconds` is not read.
    func testResumeFollowsDeviceOrMemberProgressNotResumeSeconds() throws {
        XCTAssertEqual(playRequest(try hero(movie()))?.label, "Watch now", "resumeSeconds alone is not a resume point")
        XCTAssertEqual(playRequest(try hero(movie(), resumePoints: [stream: 0.4]))?.label, "Resume")
        XCTAssertEqual(playRequest(try hero(movie(), memberResumePoints: [.movie(movieId): 0.3]))?.label, "Resume")
        XCTAssertEqual(playRequest(try hero(movie(), resumePoints: [stream: 0.4], memberResumePoints: [:]))?.label, "Watch now",
                       "signed in, the device copy is not read")
    }

    /// The request is the `MoviePlayer` request: progress kept by movie id, the Info panel fields
    /// from the hero resource.
    func testWatchNowPlaysTheMovieRequest() throws {
        let request = try XCTUnwrap(playRequest(try hero(movie()))?.request)
        XCTAssertTrue(request.recordsProgress)
        XCTAssertTrue(request.isHLS)
        XCTAssertNil(request.playlist)
        XCTAssertEqual(request.metadata.title, "Hope Rising")
        XCTAssertEqual(request.metadata.description, "A film about hope.")
        XCTAssertEqual(request.metadata.historyItem, .movie(movieId))
        XCTAssertEqual(request.metadata.contentRating, "FSK 12")
        XCTAssertEqual(request.metadata.genre, "Drama")
    }

    func testNothingPlayableDrawsNoWatchNow() throws {
        XCTAssertNil(try hero(movie(player: "null")).watchNow, "no player (no link, or showPlayButton off on the server)")
        XCTAssertNil(try hero(movie(player: #"{ "provider": "youtube", "id": "abc", "poster": null }"#)).watchNow,
                     "YouTube with no mediaLinks fallback")
        XCTAssertNil(try hero(movie(), props: #"{ "showPlayButton": false }"#).watchNow)
        XCTAssertEqual(try hero(movie(player: "null")).actions, [.trailer], "nothing to play offers no Watch later")
        XCTAssertEqual(try hero(movie(player: "null"), props: #"{ "showTrailer": false, "showWatchlistToggle": false }"#).actions, [])
        let fallback = #"{ "provider": "youtube", "id": "abc", "mediaLinks": { "youtube": { "link": "abc" }, "jetstream": { "link": "jsv:abc123" } } }"#
        XCTAssertEqual(playRequest(try hero(movie(player: fallback)))?.request.url.absoluteString,
                       "https://jstre.am/videos/jsv:abc123/hls/main.m3u8", "the mediaLinks fallback plays")
    }

    /// Nothing playable says so where Watch now would be. `showPlayButton: false` hides Watch now
    /// by choice (the movie can still play), so no message draws.
    func testNothingPlayableDrawsTheCannotPlayMessage() throws {
        let message = "This movie can't play on this device."
        XCTAssertEqual(try hero(movie(player: "null")).cannotPlayMessage, message)
        XCTAssertEqual(try hero(movie(player: #"{ "provider": "youtube", "id": "abc", "poster": null }"#)).cannotPlayMessage,
                       message)
        XCTAssertNil(try hero(movie()).cannotPlayMessage)
        XCTAssertNil(try hero(movie(), props: #"{ "showPlayButton": false }"#).cannotPlayMessage)
        XCTAssertNil(try hero(movie(player: "null"), props: #"{ "showPlayButton": false }"#).cannotPlayMessage)
    }

    /// The first button takes the focus; with no button, the message does.
    func testTheFirstFocusIsTheFirstButtonElseTheMessage() throws {
        XCTAssertEqual(try hero(movie()).firstFocus, .watch)
        XCTAssertEqual(try hero(movie(player: "null")).firstFocus, .trailer)
        XCTAssertEqual(try hero(movie(player: "null"), props: #"{ "showTrailer": false }"#).firstFocus, .message)
        XCTAssertNil(try hero(movie(), props: #"{ "showPlayButton": false, "showTrailer": false, "showWatchlistToggle": false }"#)
            .firstFocus)
    }

    func testTheTrailerDrawsOnlyWhenOnAndPlayable() throws {
        XCTAssertNil(try hero(movie(), props: #"{ "showTrailer": false }"#).trailer)
        let youtube = movie().replacingOccurrences(of: #""provider": "jetstream", "videoId": "jsv:trailer1""#,
                                                   with: #""provider": "youtube", "videoId": "abc""#)
        XCTAssertNil(try hero(youtube).trailer, "a YouTube trailer cannot play here")
        XCTAssertEqual(try hero(movie()).trailer?.recordsProgress, false)
    }

    func testWatchLaterFollowsTheToggleAndNeedsAnObjectId() throws {
        XCTAssertNil(try hero(movie(), props: #"{ "showWatchlistToggle": false }"#).watchLater)
        let freeText = movie().replacingOccurrences(of: movieId, with: "m1")
        XCTAssertNil(try hero(freeText).watchLater)
    }

    /// No Watch now because nothing can play hides Watch later. `showPlayButton: false` hides
    /// Watch now for a playable movie, so Watch later stays.
    func testWatchLaterNeedsAPlayableMovie() throws {
        XCTAssertNil(try hero(movie(player: "null")).watchLater)
        XCTAssertNil(try hero(movie(player: #"{ "provider": "youtube", "id": "abc", "poster": null }"#)).watchLater)
        XCTAssertEqual(try hero(movie(player: "null"), props: #"{ "showPlayButton": false }"#).watchLater?.id,
                       "movie:\(movieId)")
        XCTAssertEqual(try hero(movie()).watchLater?.id, "movie:\(movieId)")
    }

    /// The hero takes the default focus (Watch now first) and leads the screen. A movie that
    /// cannot play keeps the focus on its message, so the screen does not open on the block below.
    /// With no stop at all (every button off), it takes no focus, so tvOS picks.
    func testFocusRoleAndLeadingHero() throws {
        let node = try evaluate(movie())
        XCTAssertEqual(node.firstFocusNodeId, "hero")
        XCTAssertEqual(node.leadingHeroId, "hero")

        let unplayable = try evaluate(movie(player: "null"), props: #"{ "showTrailer": false, "showWatchlistToggle": false }"#)
        XCTAssertEqual(unplayable.firstFocusNodeId, "hero", "the can't-play message is the stop")
        XCTAssertEqual(unplayable.leadingHeroId, "hero", "the art still leads the screen")

        let none = try evaluate(movie(), props: #"{ "showPlayButton": false, "showTrailer": false, "showWatchlistToggle": false }"#)
        XCTAssertNil(none.firstFocusNodeId)
    }

    /// A hero shelf keeps its card-press Watch now.
    func testAHeroShelfKeepsTheCardPress() throws {
        let document = try JSONDecoder().decode(CraftDocument.self, from: Data("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["teaser"] },
          "teaser": { "type": { "resolvedName": "CollectionTeaser" }, "props": { "itemLayout": "hero" }, "parent": "ROOT", "nodes": [] }
        }
        """.utf8))
        let resources = try JSONDecoder().decode([String: [String: JSONValue]].self, from: Data("""
        { "teaser": { "collectionTeaser": { "contentType": "shows", "shows": [{ "id": "s1", "title": "Show" }] } } }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: document,
                                                        context: TestRender.context(blockResources: resources)))
        guard case let .shelf(model)? = node.first(where: { $0.id == "teaser" })?.content else { return XCTFail("no shelf") }
        let hero = try XCTUnwrap(model.cards.first?.hero)
        XCTAssertEqual(hero.watchNow, .select)
        XCTAssertFalse(hero.metaBeforeAbstract, "a hero shelf keeps its meta line under the abstract")
        XCTAssertEqual(hero.actions, [.watch])
        XCTAssertEqual(hero.watchNow?.label, "Watch now")
        XCTAssertNil(hero.tagSeparator)
        XCTAssertNil(hero.watchLater)
    }
}

/// `MovieMeta` (the `movieMeta` resource, `toMovieMeta`) as label / value rows in one reading
/// panel, read as the web `MovieMeta.js`.
final class MovieMetaTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        super.tearDown()
    }

    private static let full = """
    {
      "id": "m1",
      "productionCompanies": ["Hope Media", "", "Stimme der Hoffnung"],
      "countries": [{ "code": "DE", "name": "Germany" }, { "code": "AT", "name": "Austria" }],
      "originalTitle": "Hoffnung",
      "originalLanguage": { "code": "de", "name": "German" },
      "originalReleaseYear": 1999, "releaseYear": 2019, "duration": 6720,
      "genres": [{ "id": "g1", "title": "Drama" }, { "id": "g2", "title": "Family" }],
      "audioTracks": [
        { "language": { "code": "de", "name": "German" }, "kind": "original", "format": "5.1" },
        { "language": { "code": "en", "name": "English" }, "kind": "audioDescription", "format": "stereo" },
        { "language": { "code": "de", "name": "German" }, "kind": "dialogueBoost", "format": "atmos" },
        { "language": { "code": "xx", "name": "" }, "kind": "dub", "format": "" }
      ],
      "subtitleLanguages": [{ "code": "de", "name": "German" }, { "code": "en", "name": "English" }],
      "accessibility": { "ov": true, "ut": true, "ad": true, "dgs": false },
      "videoQuality": "1080p",
      "videoOnDemandEndsAt": null
    }
    """

    private func rows(_ resource: String?, props: String = "{}") throws -> [ShowMetaModel.Row]? {
        try evaluate(resource, props: props).flatMap { node in
            guard case let .showMeta(model)? = node.first(where: { $0.id == "meta" })?.content else { return nil }
            return model.rows
        }
    }

    private func evaluate(_ resource: String?, props: String = "{}") throws -> EvaluatedNode? {
        let resources = resource.map { #"{ "meta": { "movieMeta": \#($0) } }"# } ?? "{}"
        let document = try JSONDecoder().decode(CraftDocument.self, from: Data("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["meta"] },
          "meta": { "type": { "resolvedName": "MovieMeta" }, "props": \(props), "parent": "ROOT", "nodes": [] }
        }
        """.utf8))
        let blockResources = try JSONDecoder().decode([String: [String: JSONValue]].self, from: Data(resources.utf8))
        return BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: document,
                                      context: TestRender.context(blockResources: blockResources))
    }

    func testEveryRowDrawsInTheDefaultOrder() throws {
        let rows = try XCTUnwrap(try rows(Self.full))
        XCTAssertEqual(rows.map(\.label), [
            "Production", "Countries", "Original title", "Original language", "Original release", "Release year",
            "Duration", "Genres", "Playback languages", "Subtitles", "Accessibility", "Video quality",
        ], "no availability row: the window does not end soon")
        XCTAssertEqual(rows.map(\.value), [
            "Hope Media\nStimme der Hoffnung", "Germany, Austria", "Hoffnung", "German", "1999", "2019", "1h 52m",
            "Drama, Family", "German (5.1), English Audio description, German Dialogue Boost (Atmos)", "German, English",
            "OV, CC, AD", "1080p",
        ])
    }

    /// VoiceOver reads the flags by their full words; the panel draws the short texts.
    func testTheAccessibilityRowSpeaksTheFullWords() throws {
        let row = try XCTUnwrap(try rows(Self.full)?.first { $0.label == "Accessibility" })
        XCTAssertEqual(row.value, "OV, CC, AD")
        XCTAssertEqual(row.spokenValue, "Original version, Subtitles, Audio description")
        XCTAssertNil(try rows(Self.full)?.first { $0.label == "Genres" }?.spokenValue)
    }

    func testAVeryShortDurationDrawsNoRow() throws {
        XCTAssertNil(try rows(#"{ "duration": 29 }"#))
        XCTAssertEqual(try rows(#"{ "duration": 30 }"#)?.first, ShowMetaModel.Row(label: "Duration", value: "30s"))
    }

    func testTheFieldsPropOrdersAndHidesRows() throws {
        let props = #"{ "fields": [{ "name": "genres", "enabled": true }, { "name": "productionCompanies", "enabled": false }, { "name": "duration", "enabled": true }, { "name": "nope", "enabled": true }] }"#
        let rows = try XCTUnwrap(try rows(Self.full, props: props))
        XCTAssertEqual(Array(rows.map(\.label).prefix(3)), ["Genres", "Duration", "Countries"],
                       "the stored order first, then the missing fields with their defaults")
        XCTAssertFalse(rows.map(\.label).contains("Production"))
    }

    func testOneCountryTakesTheSingularLabel() throws {
        let one = #"{ "countries": [{ "code": "DE", "name": "Germany" }] }"#
        XCTAssertEqual(try rows(one)?.first, ShowMetaModel.Row(label: "Country", value: "Germany"))
    }

    func testEmptyValuesDrawNoRowAndNoRowDrawsNothing() throws {
        let empty = """
        { "id": "m1", "productionCompanies": [], "countries": [], "originalTitle": "", "originalLanguage": null,
          "originalReleaseYear": null, "releaseYear": null, "duration": 0, "genres": [], "audioTracks": [],
          "subtitleLanguages": [], "accessibility": { "ov": false, "ut": false, "ad": false, "dgs": false },
          "videoQuality": "", "videoOnDemandEndsAt": null }
        """
        XCTAssertNil(try rows(empty))
        XCTAssertNil(try rows("null"))
        XCTAssertNil(try rows(nil))
        XCTAssertNil(try rows(#"{ "videoQuality": "8k", "releaseYear": 2019 }"#, props: #"{ "fields": [{ "name": "releaseYear", "enabled": false }] }"#),
                     "an unknown quality draws no row")
    }

    func testTheAvailabilityRowCountsTheDaysLeft() throws {
        let iso = ISO8601DateFormatter()
        let end = Date().addingTimeInterval(3 * 24 * 3600)
        // The day count itself is `MovieFieldsTests`; a DST change can make it 2 or 4 here.
        let days = try XCTUnwrap(MovieFields.daysLeft(endsAt: end, now: Date()))
        XCTAssertTrue((2...4).contains(days))
        let later = iso.string(from: Date().addingTimeInterval(30 * 24 * 3600))
        XCTAssertEqual(try rows(#"{ "videoOnDemandEndsAt": "\#(iso.string(from: end))" }"#)?.first,
                       ShowMetaModel.Row(label: "Availability", value: "Only \(days) days left online"))
        XCTAssertNil(try rows(#"{ "videoOnDemandEndsAt": "\#(later)" }"#))
        XCTAssertEqual(ChromeText.count(.availabilityDaysLeft, 1), "Only 1 day left online")
        XCTAssertEqual(ChromeText.string(.availabilityToday), "Online today only")
    }

    func testTheLabelsAreChromeStrings() throws {
        ChromeText.served.strings = ["tvGenresLabel": "Genres DE", "tvDurationLabel": "Laufzeit"]
        let rows = try XCTUnwrap(try rows(#"{ "duration": 600, "genres": [{ "title": "Drama" }] }"#))
        XCTAssertEqual(rows.map(\.label), ["Laufzeit", "Genres DE"])
    }

    /// One reading stop that cannot ask for the default focus, as `ShowMeta`.
    func testItIsOneReadingStop() throws {
        XCTAssertEqual(try XCTUnwrap(try evaluate(Self.full)).firstFocusStop, .readsOnly)
    }
}

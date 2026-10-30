import XCTest
@testable import HopeTViOS

private let movieId = "6a1f0c2bd9c698836400aa01"
private let vodId = "jsv:Ab12Cd34Ef5"
private let vodURL = "https://jstre.am/videos/jsv:Ab12Cd34Ef5/hls/main.m3u8"

/// The movie Template Screen (awe#6270): `MoviePlayer` on top, `MovieDetail` below, as the
/// Episode Screen draws `EpisodePlayer` and `EpisodeDetail`. The shapes are the Frontend API's:
/// `resources/moviePlayer.js` (`episodePlayer` with no playlist) and `resources/movieDetail.js`
/// (`movieServices.toMovieDetail`: `id`, not `_id`).
final class MovieScreenTests: XCTestCase {

    private let image = #"{ "containerId": "c1", "name": "movie.jpg" }"#

    private var movie: String {
        #"""
        { "id": "\#(movieId)", "title": "The Chosen Path", "abstract": "A film about faith.",
          "duration": 6720, "images": { "default": \#(image) } }
        """#
    }

    private func player(_ provider: String = "jetstream", id: String = vodId) -> String {
        #"""
        { "provider": "\#(provider)", "id": "\#(id)", "poster": "https://cdn.test/poster.jpg",
          "subtitles": [], "trailer": null, "watchHistoryMode": "standard", "resumeSeconds": null }
        """#
    }

    private func detail(trailer: String = "null", languageLabel: String = #""Deutsch""#, videoQuality: String = #""4k""#,
                        genres: String = #"[{ "id": "g1", "title": "Drama", "name": "drama" }, { "id": "g2", "title": "Family", "name": "family" }]"#) -> String {
        #"""
        { "id": "\#(movieId)", "title": "The Chosen Path", "abstract": "A film about faith.",
          "releaseYear": 2019, "duration": 6720, "language": "de", "languageLabel": \#(languageLabel),
          "videoQuality": \#(videoQuality), "genres": \#(genres),
          "ageRatings": [{ "system": "fsk", "value": "12" }],
          "body": { "type": "doc", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Body text" }] }] },
          "images": { "default": \#(image) }, "trailer": \#(trailer) }
        """#
    }

    /// `MoviePlayer` above `MovieDetail`. `nil` leaves a resource key out.
    private func screen(player: String? = nil, detail: String? = nil, detailProps: String = "{}",
                        movie: String? = nil) throws -> AppScreen {
        let playerResource = player.map { #""player": { "resources": { "moviePlayer": \#($0) } }"# }
        let detailResource = detail.map { #""detail": { "resources": { "movieDetail": \#($0) } }"# }
        return try ContractDecoder.screen(Data("""
        {
          "id": "movie-tpl",
          "kind": "template",
          "resources": { \(movie.map { #""Movie": \#($0)"# } ?? "") },
          "blockResources": { \([playerResource, detailResource].compactMap { $0 }.joined(separator: ", ")) },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["player", "detail"] },
            "player": {
              "type": { "resolvedName": "MoviePlayer" }, "props": {},
              "custom": { "type": "plugin", "resources": ["moviePlayer"] }, "parent": "ROOT", "nodes": []
            },
            "detail": {
              "type": { "resolvedName": "MovieDetail" }, "props": \(detailProps),
              "custom": { "type": "plugin", "resources": ["movieDetail"] }, "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
    }

    private func evaluate(_ screen: AppScreen, resumePoints: [String: Double] = [:],
                          memberResumePoints: [WatchHistoryItem: Double]? = nil) throws -> EvaluatedNode {
        try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: RenderContext(blockResources: screen.blockResources, screenResources: screen.resources,
                                   images: TestRender.context().images, resumePoints: resumePoints,
                                   memberResumePoints: memberResumePoints)
        ))
    }

    private func playAction(_ screen: AppScreen, resumePoints: [String: Double] = [:],
                            memberResumePoints: [WatchHistoryItem: Double]? = nil) throws -> PlayActionModel? {
        let node = try evaluate(screen, resumePoints: resumePoints, memberResumePoints: memberResumePoints)
        guard case let .playAction(model)? = node.first(where: { $0.id == "player" })?.content else { return nil }
        return model
    }

    private func detailModel(props: String = "{}", detail: String? = nil) throws -> ShowDetailModel? {
        let node = try evaluate(try screen(detail: detail ?? self.detail(), detailProps: props))
        guard case let .detail(model)? = node.first(where: { $0.id == "detail" })?.content else { return nil }
        return model
    }

    private var imageURL: URL? {
        let file = try? JSONDecoder().decode(JSONValue.self, from: Data(image.utf8))
        return TestRender.context().images.url(ImageFile(file ?? .null), width: 1280)
    }

    func testTheKeysAreInTheRegistry() {
        XCTAssertEqual(BlockKey(resolvedName: "MoviePlayer"), .moviePlayer)
        XCTAssertEqual(BlockKey(resolvedName: "MovieDetail"), .movieDetail)
        XCTAssertTrue(BlockRegistry.keys.contains("MoviePlayer"))
        XCTAssertTrue(BlockRegistry.keys.contains("MovieDetail"))
    }

    // MARK: MoviePlayer

    /// Never inline: the poster and Play open the full-screen player. The source rule is the
    /// episode's (a Jetstream VOD id → its HLS manifest). A movie has no playlist, so the player
    /// shows no Episodes tab and no Up Next.
    func testMoviePlayerOpensAJetstreamVodFullScreenWithNoPlaylist() throws {
        let model = try XCTUnwrap(try playAction(try screen(player: player(), detail: detail(), movie: movie)))
        let request = try XCTUnwrap(model.request)

        XCTAssertEqual(request.url.absoluteString, vodURL)
        XCTAssertTrue(request.isHLS)
        XCTAssertTrue(request.recordsProgress)
        XCTAssertNil(request.playlist)
        XCTAssertEqual(model.label, "Play")
        XCTAssertNil(model.message)
        XCTAssertEqual(model.posterURL?.absoluteString, "https://cdn.test/poster.jpg")
    }

    /// The transport bar and the Info panel read the bound `resources.Movie`, and the rating of the
    /// `movieDetail` for the same movie. No show: no show name and no "Go to show". No episode id, so
    /// a signed-in play never reports to the episode route.
    func testThePlayerMetadataComesFromTheMovieAndItsDetail() throws {
        let metadata = try XCTUnwrap(try playAction(try screen(player: player(), detail: detail(), movie: movie))?.request).metadata

        XCTAssertEqual(metadata.title, "The Chosen Path")
        XCTAssertEqual(metadata.description, "A film about faith.")
        XCTAssertEqual(metadata.artworkURL, imageURL)
        XCTAssertNil(metadata.showName)
        XCTAssertNil(metadata.showTarget)
        XCTAssertNil(metadata.episodeId)
        XCTAssertEqual(metadata.movieId, movieId)
        XCTAssertEqual(metadata.contentRating, "FSK 12")
    }

    /// The Info panel's genre slot is the FIRST genre title of the same `movieDetail` (ruled
    /// 2026-10-15): "Drama • 1h 52m • FSK 12". The language never goes there.
    func testThePlayerGenreIsTheFirstGenreOfTheDetail() throws {
        let metadata = try XCTUnwrap(try playAction(try screen(player: player(), detail: detail(), movie: movie))?.request).metadata

        XCTAssertEqual(metadata.genre, "Drama")
        let items = metadata.metadataItems()
        XCTAssertEqual(items.first { $0.identifier == .quickTimeMetadataGenre }?.value as? String, "Drama")
        XCTAssertFalse(items.contains { $0.identifier == .commonIdentifierLanguage })
    }

    /// No genres, or a first genre with no title, sets no genre: the Info panel draws no slot.
    func testNoGenreSetsNoGenreItem() throws {
        for genres in ["[]", "null", #"[{ "id": "g1" }]"#] {
            let metadata = try XCTUnwrap(try playAction(try screen(player: player(), detail: detail(genres: genres),
                                                                   movie: movie))?.request).metadata
            XCTAssertNil(metadata.genre, genres)
            XCTAssertFalse(metadata.metadataItems().contains { $0.identifier == .quickTimeMetadataGenre }, genres)
        }
        let noDetail = try XCTUnwrap(try playAction(try screen(player: player(), movie: movie))?.request).metadata
        XCTAssertNil(noDetail.genre, "no movieDetail on the screen")
    }

    /// Without `resources.Movie` no id matches a `movieDetail`, as on the Episode Screen. The
    /// template always binds it; the art falls back to the poster.
    func testWithoutTheBoundMovieThePlayerFallsBack() throws {
        let metadata = try XCTUnwrap(try playAction(try screen(player: player(), detail: detail()))?.request).metadata

        XCTAssertEqual(metadata.title, "Untitled", "no bound movie: no id to match a detail to")
        XCTAssertEqual(metadata.artworkURL?.absoluteString, "https://cdn.test/poster.jpg")
        XCTAssertNil(metadata.movieId)
    }

    /// `{ error: 'NO_SOURCE' }`, and a provider tvOS cannot play, draw the message where the button
    /// would be. The poster still draws.
    func testNoPlayableSourceDrawsTheMovieMessage() throws {
        for resource in [#"{ "error": "NO_SOURCE" }"#, player("youtube", id: "dQw4w9WgXcQ"), player("jetstream-live", id: "abc")] {
            let model = try XCTUnwrap(try playAction(try screen(player: resource, movie: movie)), resource)
            XCTAssertNil(model.request, resource)
            XCTAssertNil(model.label, resource)
            XCTAssertEqual(model.message, "This movie can't play on this device.", resource)
        }
    }

    /// `null` (the movie is not visible) and no resource at all draw nothing.
    func testNoResourceDrawsNothing() throws {
        for screen in [try screen(player: "null", movie: movie), try screen(movie: movie)] {
            let node = try evaluate(screen)
            let block = try XCTUnwrap(node.first { $0.id == "player" })
            XCTAssertNil(block.content)
        }
    }

    /// Signed out, resume reads the device store by media URL. Signed in, it reads the member copy
    /// by the movie item, as an episode does; an episode with the same id is a different item.
    func testResumeReadsTheDeviceSignedOutAndTheMovieItemSignedIn() throws {
        let screen = try screen(player: player(), movie: movie)

        XCTAssertEqual(try playAction(screen)?.label, "Play")
        XCTAssertEqual(try playAction(screen, resumePoints: [vodURL: 0.4])?.label, "Resume")
        XCTAssertEqual(try playAction(screen, resumePoints: [vodURL: 0.4], memberResumePoints: [:])?.label, "Play",
                       "signed in, the device entry is not read")
        XCTAssertEqual(try playAction(screen, memberResumePoints: [.episode(movieId): 0.7])?.label, "Play",
                       "an episode with the same id is not the movie")
        let signedIn: [WatchHistoryItem: Double] = [.movie(movieId): 0.7]
        XCTAssertEqual(try playAction(screen, resumePoints: [vodURL: 0.4], memberResumePoints: signedIn)?.request?
                        .resumeFraction(resumePoints: [vodURL: 0.4], memberResumePoints: signedIn), 0.7)
    }

    /// Signed in, a movie play reports to the member copy, as an episode play does: the player
    /// builds a reporter (`observeReports`), not the device writer.
    @MainActor
    func testASignedInMoviePlayReportsToTheMember() throws {
        let request = try XCTUnwrap(try playAction(try screen(player: player(), movie: movie))?.request)
        let store = MemorySessionStore()
        store.stored = MemberSession(token: "tok", expires: Date(timeIntervalSince1970: 2_000_000), name: "Ana")
        let account = MemberAccount(service: FakeMemberService(), store: store, now: { Date(timeIntervalSince1970: 1_000_000) })
        XCTAssertNotNil(account.session)

        XCTAssertEqual(request.metadata.historyItem, .movie(movieId))
        XCTAssertNotNil(MemberProgressReporter(request: request, account: account, progress: WatchProgressStore()))
    }

    // MARK: MovieDetail

    /// Text only, as `EpisodeDetail`: the title, the meta line (year · runtime), the primary age
    /// rating badge and the body. The builder's defaults: `showTitle`, `showMeta`, `showBody` and
    /// `showWatchlistToggle` on, `showAbstract` and `showTrailer` off. No image, even when served.
    func testMovieDetailDrawsTheDefaultParts() throws {
        let model = try XCTUnwrap(try detailModel())

        XCTAssertEqual(model.title, "The Chosen Path")
        XCTAssertEqual(model.subtitle, "2019 · 1h 52m")
        XCTAssertEqual(model.ageRating, "FSK 12")
        XCTAssertEqual(model.paragraphs, ["Body text"])
        XCTAssertNil(model.abstract)
        XCTAssertNil(model.imageURL)
        XCTAssertNil(model.trailer)
        XCTAssertNil(model.heading)
        XCTAssertEqual(model.watchLater?.itemType, .movie)
        XCTAssertEqual(model.watchLater?.itemId, movieId)
        XCTAssertEqual(model.watchLater?.title, "The Chosen Path")
    }

    /// The heading row beside the age badge (awe#6870): the served `languageLabel` as text, the
    /// `videoQuality` as an outlined badge, and the genre titles joined.
    func testTheHeadingRowDrawsLanguageQualityAndGenres() throws {
        let model = try XCTUnwrap(try detailModel())

        XCTAssertEqual(model.language, "Deutsch")
        XCTAssertEqual(model.videoQuality, "4K")
        XCTAssertEqual(model.genres, "Drama, Family")
    }

    /// `720p` and `1080p` keep their text, `4k` reads "4K". Anything else draws no badge.
    func testTheVideoQualityMapsOnlyTheThreeStoredValues() throws {
        let cases: [(String, String?)] = [
            (#""720p""#, "720p"), (#""1080p""#, "1080p"), (#""4k""#, "4K"),
            (#""""#, nil), (#""4K""#, nil), (#""8k""#, nil), ("null", nil), ("1080", nil),
        ]
        for (served, label) in cases {
            XCTAssertEqual(try detailModel(detail: detail(videoQuality: served))?.videoQuality, label, served)
        }
    }

    /// Each empty value draws nothing: a `null` or blank label, no genres, a genre with no title.
    func testEmptyValuesDrawNothing() throws {
        let model = try XCTUnwrap(try detailModel(detail: detail(languageLabel: "null", videoQuality: #""""#, genres: "[]")))
        XCTAssertNil(model.language)
        XCTAssertNil(model.videoQuality)
        XCTAssertNil(model.genres)
        XCTAssertEqual(model.ageRating, "FSK 12", "the badge still draws")

        XCTAssertNil(try detailModel(detail: detail(languageLabel: #""  ""#))?.language)
        XCTAssertEqual(try detailModel(detail: detail(genres: #"[{ "id": "g1" }, { "id": "g2", "title": "Drama" }]"#))?.genres,
                       "Drama")
        XCTAssertNil(try detailModel(detail: detail(genres: "null"))?.genres)
    }

    /// The same gates as the badge: `showMeta` off, or a body-only instance, draws none of them.
    func testTheHeadingRowFollowsTheBadgeGates() throws {
        for props in [#"{ "showMeta": false }"#, #"{ "showTitle": false }"#] {
            let model = try XCTUnwrap(try detailModel(props: props))
            XCTAssertNil(model.language, props)
            XCTAssertNil(model.videoQuality, props)
            XCTAssertNil(model.genres, props)
        }
    }

    func testPropsHideTheirParts() throws {
        let abstract = try XCTUnwrap(try detailModel(props: #"{ "showAbstract": true }"#))
        XCTAssertEqual(abstract.abstract, "A film about faith.")

        let noMeta = try XCTUnwrap(try detailModel(props: #"{ "showMeta": false }"#))
        XCTAssertNil(noMeta.subtitle)
        XCTAssertNil(noMeta.ageRating)
        XCTAssertEqual(noMeta.title, "The Chosen Path")

        let noToggle = try XCTUnwrap(try detailModel(props: #"{ "showWatchlistToggle": false }"#))
        XCTAssertNil(noToggle.watchLater)

        XCTAssertNil(try detailModel(props: #"{ "showTitle": false, "showBody": false }"#), "nothing to draw")
    }

    /// A body-only second instance draws no heading group: no meta line, no badge, no toggle.
    func testABodyOnlyInstanceDrawsNoHeadingGroup() throws {
        let model = try XCTUnwrap(try detailModel(props: #"{ "showTitle": false }"#))

        XCTAssertNil(model.title)
        XCTAssertNil(model.subtitle)
        XCTAssertNil(model.ageRating)
        XCTAssertNil(model.watchLater)
        XCTAssertEqual(model.paragraphs, ["Body text"])
    }

    /// `showTrailer` (off by default) draws Watch trailer only when the trailer resolves here, by
    /// the `ShowDetail` rule. A trailer keeps no watch progress.
    func testTheTrailerDrawsOnlyWhenOnAndPlayable() throws {
        let jetstream = #"{ "provider": "jetstream", "videoId": "jsv:Tr12Tr34Tr5" }"#
        let youtube = #"{ "provider": "youtube", "videoId": "dQw4w9WgXcQ" }"#

        XCTAssertNil(try detailModel(detail: detail(trailer: jetstream))?.trailer, "off by default")
        let trailer = try XCTUnwrap(try detailModel(props: #"{ "showTrailer": true }"#, detail: detail(trailer: jetstream))?.trailer)
        XCTAssertEqual(trailer.url.absoluteString, "https://jstre.am/videos/jsv:Tr12Tr34Tr5/hls/main.m3u8")
        XCTAssertFalse(trailer.recordsProgress)
        XCTAssertNil(try detailModel(props: #"{ "showTrailer": true }"#, detail: detail(trailer: youtube))?.trailer)
    }

    /// A free-text id is no ObjectId: no toggle, as for the other detail blocks.
    func testANonObjectIdDrawsNoToggle() throws {
        let detail = #"{ "id": "m1", "title": "T" }"#
        XCTAssertNil(try detailModel(detail: detail)?.watchLater)
    }

    // MARK: Focus

    /// The pushed screen opens on Play. With no source, the Watch later toggle asks instead, and
    /// with the toggle off the Like button (awe#6871). Both need the title.
    func testTheScreenOpensOnPlayElseOnTheToggle() throws {
        XCTAssertEqual(try evaluate(try screen(player: player(), detail: detail(), movie: movie)).firstFocusNodeId, "player")
        XCTAssertEqual(try evaluate(try screen(detail: detail(), movie: movie)).firstFocusNodeId, "detail",
                       "no player: the toggle asks")
        XCTAssertEqual(try evaluate(try screen(detail: detail(), detailProps: #"{ "showWatchlistToggle": false }"#,
                                               movie: movie)).firstFocusNodeId,
                       "detail", "the Like button asks")
        XCTAssertNil(try evaluate(try screen(player: #"{ "error": "NO_SOURCE" }"#, detail: detail(), movie: movie))
                        .firstFocusNodeId, "a movie that cannot play has no toggle and no Like: tvOS chooses")
        XCTAssertNil(try evaluate(try screen(detail: detail(), detailProps: #"{ "showTitle": false }"#, movie: movie))
                        .firstFocusNodeId, "text only: tvOS chooses")
    }

    // MARK: Keep watching

    /// A device entry a movie play left opens the movie Template Screen by the card convention,
    /// and offers Watch later as a movie.
    func testAKeepWatchingMovieCardOpensTheMovie() throws {
        let entry = WatchProgressStore.Entry(playableId: vodURL, showId: nil, episodeId: nil, movieId: movieId,
                                             title: "The Chosen Path", subtitle: "", imageURL: nil, fraction: 0.4,
                                             duration: 6720, updatedAt: Date())
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "home", "kind": "static",
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["history"] },
            "history": { "type": { "resolvedName": "EpisodeWatchHistory" }, "props": {}, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(watchHistory: [entry])))
        guard case let .shelf(model)? = node.first(where: { $0.id == "history" })?.content else {
            return XCTFail("EpisodeWatchHistory drew nothing")
        }
        let card = try XCTUnwrap(model.cards.first)

        XCTAssertEqual(card.target, CardTarget(resourceType: "movie", itemId: movieId))
        guard case let .watchLater(item)? = card.menu else { return XCTFail("no Watch later menu") }
        XCTAssertEqual(item.itemType, .movie)
        XCTAssertEqual(item.itemId, movieId)
    }
}

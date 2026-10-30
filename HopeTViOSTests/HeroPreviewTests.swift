// cspell:ignore ylub
import XCTest
@testable import HopeTViOS

/// The hero show preview (ruled 2026-10-26): the source allowlist, which hero items carry it, and
/// when it may play.
final class HeroPreviewTests: XCTestCase {
    private typealias F = CollectionFixtures

    private let account = "ras0w8c7cdq3ylub"
    private let video = "105586546a20dcc2549a49658ffaa1e8"

    private func preview(provider: String? = "cloudflare", accountId: String? = nil, videoId: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [:]
        object["provider"] = provider.map(JSONValue.string)
        object["accountId"] = .string(accountId ?? account)
        object["videoId"] = .string(videoId ?? video)
        return .object(object)
    }

    // MARK: - source

    func testACloudflarePreviewResolvesToTheWebUrl() {
        XCTAssertEqual(HeroPreview.source(preview())?.absoluteString,
                       "https://customer-ras0w8c7cdq3ylub.cloudflarestream.com/105586546a20dcc2549a49658ffaa1e8/manifest/video.m3u8")
    }

    func testAnotherProviderResolvesNothing() {
        for provider in ["youtube", "jetstream", "hls", "fileManager", "Cloudflare", ""] {
            XCTAssertNil(HeroPreview.source(preview(provider: provider)), provider)
        }
        XCTAssertNil(HeroPreview.source(preview(provider: nil)))
    }

    func testAMissingOrBlankFieldResolvesNothing() {
        XCTAssertNil(HeroPreview.source(.null))
        XCTAssertNil(HeroPreview.source(.object(["provider": .string("cloudflare"), "videoId": .string(video)])))
        XCTAssertNil(HeroPreview.source(.object(["provider": .string("cloudflare"), "accountId": .string(account)])))
        XCTAssertNil(HeroPreview.source(preview(accountId: "")))
        XCTAssertNil(HeroPreview.source(preview(videoId: " ")))
        XCTAssertNil(HeroPreview.source(.object(["provider": .string("cloudflare"), "accountId": .number(1),
                                                 "videoId": .string(video)])))
    }

    /// Each id lands in the host or the path, so nothing that adds a label, a segment, a query, a
    /// fragment or user info resolves.
    func testAnIdThatCouldChangeTheUrlResolvesNothing() {
        let hostile = ["a/b", "../x", "a.evil.com", "x?y=1", "x#y", "user@evil", "a b", "a%2Fb", "a:1", "a\\b",
                       String(repeating: "a", count: 65)]
        for value in hostile {
            XCTAssertNil(HeroPreview.source(preview(accountId: value)), "accountId \(value)")
            XCTAssertNil(HeroPreview.source(preview(videoId: value)), "videoId \(value)")
        }
        XCTAssertNotNil(HeroPreview.source(preview(videoId: String(repeating: "a", count: 64))))
    }

    // MARK: - the hero model, built through the evaluator

    private func heroCards(_ items: [[String: Any]]) throws -> [CardModel] {
        let record: [String: Any] = ["contentType": "mixed", "layout": "hero", "items": items]
        return try F.shelf(try F.node(try F.screen(record))).cards
    }

    private var served: [String: Any] {
        ["provider": "cloudflare", "accountId": account, "videoId": video]
    }

    func testOnlyAShowWithAServedPreviewCarriesIt() throws {
        var show = F.show()
        show["previewVideo"] = served
        var episode = F.episode()
        episode["previewVideo"] = served
        var movie = F.movie()
        movie["previewVideo"] = served
        let cards = try heroCards([F.typed(show, "show"), F.typed(episode, "episode"), F.typed(movie, "movie"),
                                   F.typed(F.show("6a0000000000000000000502"), "show")])

        XCTAssertEqual(cards.count, 4)
        XCTAssertTrue(cards.allSatisfy { $0.hero != nil }, "every item draws the hero")
        XCTAssertEqual(cards[0].hero?.previewURL, HeroPreview.source(preview()))
        XCTAssertNil(cards[1].hero?.previewURL, "an episode gets none")
        XCTAssertNil(cards[2].hero?.previewURL, "a movie gets none")
        XCTAssertNil(cards[3].hero?.previewURL, "a show with no preview gets none")
    }

    func testAShowWithAnUnknownProviderCarriesNone() throws {
        var show = F.show()
        show["previewVideo"] = ["provider": "youtube", "videoId": "abc"]
        XCTAssertNil(try heroCards([F.typed(show, "show")]).first?.hero?.previewURL)
    }

    func testANonHeroCardBuildsNoHeroAndSoNoPreview() throws {
        var show = F.show()
        show["previewVideo"] = served
        let record: [String: Any] = ["contentType": "shows", "layout": "cards", "shows": [show]]
        XCTAssertNil(try F.shelf(try F.node(try F.screen(record))).cards.first?.hero)
    }

    // MARK: - the gate

    private let open = HeroPreview.Gate(hasSource: true, reduceMotion: false, playbackOpen: false, onScreen: true,
                                        sceneActive: true)

    func testItPlaysOnlyWhenEveryInputAllows() {
        XCTAssertTrue(open.mayPlay)
        XCTAssertNil(open.hold)

        var gate = open
        gate.hasSource = false
        XCTAssertFalse(gate.mayPlay)
        gate = open
        gate.reduceMotion = true
        XCTAssertFalse(gate.mayPlay, "Reduce Motion keeps the art")
        gate = open
        gate.playbackOpen = true
        XCTAssertFalse(gate.mayPlay, "the full-screen player is open")
        gate = open
        gate.onScreen = false
        XCTAssertFalse(gate.mayPlay, "off screen: under a pushed screen, another tab, or scrolled out")
        gate = open
        gate.sceneActive = false
        XCTAssertFalse(gate.mayPlay, "the scene is not active")
    }

    func testEveryCombinationButOneHolds() {
        var plays = 0
        for mask in 0..<32 {
            let gate = HeroPreview.Gate(hasSource: mask & 1 != 0, reduceMotion: mask & 2 == 0,
                                        playbackOpen: mask & 4 == 0, onScreen: mask & 8 != 0,
                                        sceneActive: mask & 16 != 0)
            if gate.mayPlay { plays += 1 }
            XCTAssertEqual(gate.mayPlay, gate == open)
        }
        XCTAssertEqual(plays, 1)
    }

    func testTheTimingMatchesTheWeb() {
        XCTAssertEqual(HeroPreview.delay, .seconds(3))
        XCTAssertEqual(HeroPreview.fadeDuration, 0.8)
    }

    // MARK: - resume

    /// A new showing goes on from the saved position; with none (or a value AVFoundation cannot
    /// seek to) it starts from 0.
    func testANewShowingStartsWhereTheLastOneStopped() {
        XCTAssertEqual(HeroPreview.resumeTime(42.5)?.seconds, 42.5)
        for saved: Double? in [nil, 0, -3, .nan, .infinity] {
            XCTAssertNil(HeroPreview.resumeTime(saved), "\(String(describing: saved))")
        }
    }
}

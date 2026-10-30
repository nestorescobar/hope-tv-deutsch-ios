import XCTest
@testable import HopeTViOS

/// The Live card: nothing plays inline. The card draws the broadcast on air, by the clock, with
/// stage-width art, and Select opens the same live request as before. Built through the block
/// evaluator, not by hand.
@MainActor
final class LiveCardTests: XCTestCase {

    private let channel = #"{ "title": "Hope TV Deutsch", "hls": "https://live.example.org/hope/main.m3u8" }"#

    /// On air 15:00–15:30 with an episode image, then a row with no image, then a gap.
    private let broadcasts = """
    {
      "current": { "_id": "now", "episodeTitle": "On Air", "startsAt": "2026-10-10T15:00:00.000Z", "endsAt": "2026-10-10T15:30:00.000Z",
                   "episode": { "_id": "6a049248c6d68f1e30573241", "title": "On Air",
                                "image": { "containerId": "c1", "name": "on-air.jpg", "blurhash": "LEHV6nWB2yk8" },
                                "show": { "_id": "6a049248c6d68f1e30573200", "title": "Morning Show" } } },
      "items": [
        { "_id": "next", "episodeTitle": "Next Up", "startsAt": "2026-10-10T15:30:00.000Z", "endsAt": "2026-10-10T16:00:00.000Z" }
      ]
    }
    """

    private func date(_ value: String) throws -> Date { try XCTUnwrap(ContractDate.parse(value)) }

    /// The `LivestreamPlayer` model of a one-block Live screen. nil `schedule` leaves the key out.
    private func card(schedule: String?) throws -> PlayerModel {
        let served = schedule.map { #", "broadcastsLive": \#($0)"# } ?? ""
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1", "kind": "static",
          "blockResources": { "player": { "resources": { "channel": \(channel)\(served) } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["player"] },
            "player": { "type": { "resolvedName": "LivestreamPlayer" }, "props": {}, "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: screen.blockResources)))
        guard case let .player(model) = try XCTUnwrap(node.first { $0.key == .livestreamPlayer }).content else {
            XCTFail("LivestreamPlayer drew no card")
            throw CancellationError()
        }
        return model
    }

    func testTheCardShowsTheBroadcastOnAirWithStageWidthArt() throws {
        let model = try card(schedule: broadcasts)
        let onAir = try XCTUnwrap(model.onAir(at: try date("2026-10-10T15:10:00.000Z")))

        XCTAssertEqual(onAir.title, "On Air")
        XCTAssertEqual(onAir.showTitle, "Morning Show")
        XCTAssertEqual(onAir.blurhash, "LEHV6nWB2yk8")
        XCTAssertTrue(onAir.imageURL?.absoluteString.contains("/w:1920/") == true, "the card spans the stage")
        XCTAssertTrue(model.request.schedule?.first?.imageURL?.absoluteString.contains("/w:640/") == true,
                      "the Schedule tab keeps its row-size art")
    }

    /// The clock moves the card: the next row takes over at its start, and a row with no art
    /// draws the title on the dark card. After the last row nothing is on air.
    func testTheClockMovesTheBroadcastOnAir() throws {
        let model = try card(schedule: broadcasts)

        let next = try XCTUnwrap(model.onAir(at: try date("2026-10-10T15:40:00.000Z")))
        XCTAssertEqual(next.id, "next")
        XCTAssertNil(next.imageURL)
        XCTAssertNil(model.onAir(at: try date("2026-10-10T17:00:00.000Z")), "the play button only")
    }

    /// An old server serves only `channel`: the card still opens the stream, with no broadcast.
    func testACardWithoutBroadcastsStillOpensTheStream() throws {
        let model = try card(schedule: nil)

        XCTAssertTrue(model.broadcasts.isEmpty)
        XCTAssertNil(model.onAir(at: try date("2026-10-10T15:10:00.000Z")))
        XCTAssertEqual(model.request.url.absoluteString, "https://live.example.org/hope/main.m3u8")
        XCTAssertFalse(model.request.recordsProgress)
    }

    /// Nothing plays inline, so the Live tab root with nothing full screen is a safe boundary:
    /// a refetched Live screen applies at once, under the card.
    func testTheLiveTabRootIsASafeBoundaryUntilTheStreamOpens() throws {
        let manifest = try ContractDecoder.manifest(Fixtures.data("manifest"))
        let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
        XCTAssertTrue(router.isAtSafeBoundary)

        router.play(try card(schedule: broadcasts).request)
        XCTAssertFalse(router.isAtSafeBoundary, "the full-screen stream holds it")

        router.endPlayback()
        XCTAssertTrue(router.isAtSafeBoundary)
    }
}

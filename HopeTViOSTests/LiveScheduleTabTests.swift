import SwiftUI
import XCTest
@testable import HopeTViOS

/// The live player's Schedule tab (awe#6553). Both live entry points carry the channel's
/// schedule on the request: the inline `LivestreamPlayer` from its own `broadcastsLive`, the
/// on-air `ScheduleLive` row from the schedule its block loaded. Built through the block
/// evaluator, not by hand.
@MainActor
final class LiveScheduleTabTests: XCTestCase {

    private let channel = #"{ "title": "Hope TV Deutsch", "hls": "https://live.example.org/hope/main.m3u8" }"#

    /// On air 15:00–15:30, then two later rows. `items` repeats the on-air row, as the server
    /// can (both time bounds are inclusive).
    private let broadcasts = """
    {
      "current": { "_id": "now", "episodeTitle": "On Air", "showTitle": "Morning Show",
                   "startsAt": "2026-10-10T15:00:00.000Z", "endsAt": "2026-10-10T15:30:00.000Z" },
      "items": [
        { "_id": "now", "episodeTitle": "On Air", "startsAt": "2026-10-10T15:00:00.000Z", "endsAt": "2026-10-10T15:30:00.000Z" },
        { "_id": "next", "episodeTitle": "Next Up", "startsAt": "2026-10-10T15:30:00.000Z", "endsAt": "2026-10-10T16:00:00.000Z",
          "episode": { "_id": "6a049248c6d68f1e30573243", "title": "Next Up" } },
        { "_id": "later", "episodeTitle": "Later On", "startsAt": "2026-10-10T16:00:00.000Z", "endsAt": "2026-10-10T16:30:00.000Z" }
      ],
      "count": 3,
      "schedulePage": null
    }
    """

    private func date(_ value: String) throws -> Date { try XCTUnwrap(ContractDate.parse(value)) }

    /// A Live screen. `playerSchedule` is the `broadcastsLive` JSON on the player node; nil
    /// leaves the key out (an old server). `stripSchedule` adds a `ScheduleLive` block.
    private func evaluate(playerSchedule: String?, stripSchedule: String? = nil) throws -> EvaluatedNode {
        let player = playerSchedule.map { #", "broadcastsLive": \#($0)"# } ?? ""
        let strip = stripSchedule.map { #", "strip": { "resources": { "channel": \#(channel), "broadcastsLive": \#($0) } }"# } ?? ""
        let stripNode = stripSchedule == nil ? "" : #", "strip": { "type": { "resolvedName": "ScheduleLive" }, "props": {}, "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] }"#
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1", "kind": "static",
          "blockResources": { "player": { "resources": { "channel": \(channel)\(player) } }\(strip) },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["player"\(stripSchedule == nil ? "" : #", "strip""#)] },
            "player": { "type": { "resolvedName": "LivestreamPlayer" }, "props": {}, "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] }\(stripNode)
          }
        }
        """.utf8))
        return try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                    context: TestRender.context(blockResources: screen.blockResources)))
    }

    private func inlineRequest(_ node: EvaluatedNode) throws -> PlaybackRequest {
        guard case let .player(model) = try XCTUnwrap(node.first { $0.key == .livestreamPlayer }).content else {
            XCTFail("LivestreamPlayer drew no player")
            throw CancellationError()
        }
        return model.request
    }

    // MARK: Entry point (a): the inline LivestreamPlayer

    /// The player's own `broadcastsLive`, read as `ScheduleLive` reads it: `current` first, the
    /// repeated row once.
    func testTheInlinePlayerCarriesItsOwnSchedule() throws {
        let request = try inlineRequest(try evaluate(playerSchedule: broadcasts))
        let schedule = try XCTUnwrap(request.schedule, "a served broadcastsLive rides on the live request")

        XCTAssertEqual(schedule.map(\.id), ["now", "next", "later"])
        XCTAssertTrue(schedule[0].isCurrent)
        XCTAssertEqual(schedule[0].title, "On Air")
        XCTAssertEqual(schedule[0].showTitle, "Morning Show")
        XCTAssertFalse(request.recordsProgress, "still a live request")
        XCTAssertNil(request.playlist, "a live request has no Episodes tab")
    }

    /// An old server serves only `channel`: the player opens with no Schedule tab.
    func testAnOldServerWithoutBroadcastsLiveCarriesNoSchedule() throws {
        let request = try inlineRequest(try evaluate(playerSchedule: nil))
        XCTAssertNil(request.schedule)
        XCTAssertEqual(request.url.absoluteString, "https://live.example.org/hope/main.m3u8", "the stream still plays")
    }

    func testAnEmptyScheduleCarriesNone() throws {
        XCTAssertNil(try inlineRequest(try evaluate(playerSchedule: #"{ "current": null, "items": [], "count": 0 }"#)).schedule)
        XCTAssertNil(try inlineRequest(try evaluate(playerSchedule: "null")).schedule)
    }

    // MARK: Entry point (b): the on-air ScheduleLive row

    /// The on-air row opens the live request with the schedule its own block loaded.
    func testTheOnAirRowCarriesTheScheduleItsBlockLoaded() throws {
        let node = try evaluate(playerSchedule: nil, stripSchedule: broadcasts)
        guard case let .schedule(model) = try XCTUnwrap(node.first { $0.key == .scheduleLive }).content else {
            return XCTFail("ScheduleLive drew nothing")
        }
        guard case let .live(request) = try XCTUnwrap(model.entries(at: try date("2026-10-10T15:10:00.000Z")).first).kind else {
            return XCTFail("the on-air row is not the live kind")
        }

        XCTAssertEqual(request.schedule?.map(\.id), ["now", "next", "later"])
        XCTAssertEqual(request.schedule, model.entries, "the strip's own rows, as served")
    }

    /// When the player and the strip serve the same schedule, both entry points open one request.
    func testBothEntryPointsOpenTheSameRequest() throws {
        let node = try evaluate(playerSchedule: broadcasts, stripSchedule: broadcasts)
        guard case let .schedule(model) = try XCTUnwrap(node.first { $0.key == .scheduleLive }).content,
              case let .live(nowRow) = try XCTUnwrap(model.entries(at: try date("2026-10-10T15:10:00.000Z")).first).kind else {
            return XCTFail("no on-air live row")
        }
        XCTAssertEqual(try inlineRequest(node).url, nowRow.url)
        XCTAssertEqual(try inlineRequest(node).schedule?.map(\.id), nowRow.schedule?.map(\.id))
    }

    /// Ruling (i) condition 4 compares the stream, not the schedule: a refetch that only moves
    /// the schedule still applies at once under the inline player.
    func testAScheduleChangeIsNotALiveSourceChange() throws {
        let channelValue = try TestDocument.value(channel)
        let images = TestRender.context().images
        let plain = try XCTUnwrap(PlaybackService.liveRequest(channelValue, images: images))
        XCTAssertNil(plain.schedule, "the refresh check builds the request with no schedule")
    }

    // MARK: The tab rows

    /// Rows read the clock: an ended row drops and "On now" moves. Every row is information only,
    /// so Select never leaves the player.
    func testTheTabRowsFollowTheClockAndAreInformationOnly() throws {
        let schedule = try XCTUnwrap(try inlineRequest(try evaluate(playerSchedule: broadcasts)).schedule)

        let early = ScheduleTab.rows(schedule, at: try date("2026-10-10T15:10:00.000Z"))
        XCTAssertEqual(early.map(\.id), ["now", "next", "later"])
        XCTAssertEqual(early.map(\.isCurrent), [true, false, false])
        XCTAssertEqual(early.map(\.kind), [.information, .information, .information], "a linked row opens nothing here")

        let later = ScheduleTab.rows(schedule, at: try date("2026-10-10T15:40:00.000Z"))
        XCTAssertEqual(later.map(\.id), ["next", "later"], "the ended row drops")
        XCTAssertEqual(later.first?.isCurrent, true, "the on-air row moves with the clock")
        XCTAssertEqual(later.map(\.kind), [.information, .information])
    }

    /// No row: no tab. Absent, empty, or every row ended.
    func testNoRowsMeansNoTab() throws {
        XCTAssertEqual(ScheduleTab.rows(nil, at: Date()), [])
        let schedule = try XCTUnwrap(try inlineRequest(try evaluate(playerSchedule: broadcasts)).schedule)
        XCTAssertEqual(ScheduleTab.rows(schedule, at: try date("2026-10-10T17:00:00.000Z")), [], "every row ended")
    }

    // MARK: On demand stays as it was

    func testAnOnDemandRequestCarriesNoSchedule() throws {
        let screen = try ContractDecoder.screen(Fixtures.data("episode"))
        let images = ImageConfig(cdn: TestConfig.staging.imagesCDN, bucket: TestConfig.staging.imagesBucket)
        let request = try XCTUnwrap(BlockRegistry.playRequest(on: screen, images: images))
        XCTAssertNil(request.schedule, "an episode shows the Episodes tab only")
        XCTAssertNotNil(request.playlist)
    }

    /// AVKit shows the same tab again and again while the player stays open: each showing reads
    /// the clock, so "On now" moves.
    func testEachShowingReadsTheClock() {
        let clock = ScheduleTabClock()
        let controller = ScheduleTabController(rootView: AnyView(EmptyView()), clock: clock)
        clock.now = Date(timeIntervalSinceNow: -3600)

        controller.viewWillAppear(false)

        XCTAssertLessThan(abs(controller.clock.now.timeIntervalSinceNow), 5, "the clock moved to now")
    }

    func testTheTabTitleIsAChromeString() {
        XCTAssertEqual(ChromeText.manifestKey(.scheduleLabel), "tvScheduleLabel")
        XCTAssertEqual(ChromeText.english(.scheduleLabel), "Schedule")
    }
}

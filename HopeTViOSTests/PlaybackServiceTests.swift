// cspell:ignore Gute Nachricht Hdql Bibelkompass Verlauf
import AVFoundation
import XCTest
@testable import HopeTViOS

/// The Jetstream VOD rule (awe#4950).
///
/// The `episodePlayer` resource names a provider media id, not a url. A Jetstream VOD id maps to
/// its public HLS manifest. Every expected url is the one `apps/mobile`
/// `src/player/playerSource.ts` builds for the same input (its `playerSource.test.ts`), so the
/// two renderers play the same stream.
final class JetstreamSourceTests: XCTestCase {

    private func source(_ provider: String?, _ id: String?) throws -> String? {
        var fields: [String] = []
        if let provider { fields.append(#""provider": "\#(provider)""#) }
        if let id { fields.append(#""id": "\#(id)""#) }
        let resource = try TestDocument.value("{ \(fields.joined(separator: ", ")) }")
        return PlaybackService.episodeSource(resource)?.url.absoluteString
    }

    private func vod(_ host: String, _ id: String) -> String {
        "\(host)/videos/\(id)/hls/main.m3u8"
    }

    func testAPrefixedOrBareVideoIdPlaysItsManifest() throws {
        XCTAssertEqual(try source("jetstream", "jsv:Bc1mMeG7XdM"), vod("https://jstre.am", "jsv:Bc1mMeG7XdM"))
        // A bare id takes the provider's prefix.
        XCTAssertEqual(try source("jetstream", "Bc1mMeG7XdM"), vod("https://jstre.am", "jsv:Bc1mMeG7XdM"))
        XCTAssertEqual(try source("jetstream", "  jsv:Bc1mMeG7XdM "), vod("https://jstre.am", "jsv:Bc1mMeG7XdM"))
    }

    func testAStagingIdPlaysFromTheStagingHost() throws {
        XCTAssertEqual(
            try source("jetstream", "jsv:stage:Bc1mMeG7XdM"),
            vod("https://stage.jstre.am", "jsv:stage:Bc1mMeG7XdM")
        )
    }

    /// Core cuts a v1 id to 15 characters (21 with `:stage:`) before it builds a manifest path.
    func testALongV1IdIsCutToTheShortId() throws {
        XCTAssertEqual(try source("jetstream", "jsv:r7e8dQ17fnEZvp9Q2C3N"), vod("https://jstre.am", "jsv:r7e8dQ17fnE"))
        XCTAssertEqual(
            try source("jetstream", "jsv:stage:r7e8dQ17fnEZvp9Q2C3N"),
            vod("https://stage.jstre.am", "jsv:stage:r7e8dQ17fnE")
        )
        // The host reads the CUT id: a `:stage:` the cut drops no longer means staging.
        XCTAssertEqual(
            try source("jetstream", "jsv:abcdefghijklmnopq:stage:x"),
            vod("https://jstre.am", "jsv:abcdefghijklmnopq")
        )
    }

    /// The editor also stores an embed url. A `stage.` host picks the staging host on its own.
    func testAnEmbedUrlPlaysTheManifestOfItsId() throws {
        let prod = vod("https://jstre.am", "jsv:Bc1mMeG7XdM")
        XCTAssertEqual(try source("jetstream", "https://jstre.am/embed/jsv:Bc1mMeG7XdM"), prod)
        XCTAssertEqual(try source("jetstream", "jstre.am/embed/jsv:Bc1mMeG7XdM/"), prod)
        XCTAssertEqual(try source("jetstream", "https://www.jstre.am/embed/Bc1mMeG7XdM"), prod)
        XCTAssertEqual(
            try source("jetstream", "https://stage.jstre.am/embed/Bc1mMeG7XdM"),
            vod("https://stage.jstre.am", "jsv:Bc1mMeG7XdM")
        )
    }

    /// An allowlist, not an escape: an id that could add a path segment or a query plays nothing.
    func testAnIdOutsideTheAllowlistPlaysNothing() throws {
        for id in [
            "jsv:../../videos/other",
            "../../videos/other",
            "foo:Bc1mMeG7XdM",
            "jsv:a?b=1",
            "https://jstre.am/embed/jsv:x?autoplay=1",
            "https://evil.test/embed/jsv:x",
            "https://example.test/episode.m3u8",
            "   ",
        ] {
            XCTAssertNil(try source("jetstream", id), "\(id) must not reach the player")
        }
        XCTAssertNil(try source("jetstream", nil))
        XCTAssertNil(try source(nil, "jsv:Bc1mMeG7XdM"))
    }

    /// Live and audio have no derivable manifest. Mobile embeds them; tvOS has no web view.
    func testALiveOrAudioIdPlaysNothing() throws {
        XCTAssertNil(try source("jetstream", "jsl:Bc1mMeG7XdM"))
        XCTAssertNil(try source("jetstream", "jsa:Bc1mMeG7XdM"))
        XCTAssertNil(try source("jetstream-live", "jsl:stage:Bc1mMeG7XdM"))
        XCTAssertNil(try source("jetstream-live", "Bc1mMeG7XdM"))
        XCTAssertNil(try source("jetstream-audio", "Bc1mMeG7XdM"))
        XCTAssertNil(try source("jetstream-live", "https://stage.jstre.am/embed/jsl:Bc1mMeG7XdM"))
    }

    func testYouTubeAndVimeoPlayNothing() throws {
        XCTAssertNil(try source("youtube", "dQw4w9WgXcQ"))
        XCTAssertNil(try source("vimeo", "1084537"))
        // The id decides only under a Jetstream provider.
        XCTAssertNil(try source("youtube", "jsv:Bc1mMeG7XdM"))
    }

    func testTheServedIdWinsOverTheMap() throws {
        let resource = try TestDocument.value("""
        { "provider": "jetstream", "id": "jsv:Bc1mMeG7XdM",
          "mediaLinks": { "hls": { "link": "https://example.test/master.m3u8" } } }
        """)
        let resolved = try XCTUnwrap(PlaybackService.episodeSource(resource))

        XCTAssertEqual(resolved.url.absoluteString, vod("https://jstre.am", "jsv:Bc1mMeG7XdM"))
        XCTAssertEqual(resolved.rendition, "jetstream")
    }
}

/// The fallback rule: the served provider plays when it resolves, else the first `mediaLinks`
/// entry that resolves, in the order `jetstream`, `hls`, `mp4-hd`, `mp4-sd`. Each entry takes the
/// same per-provider rule as the served one.
final class MediaLinksFallbackTests: XCTestCase {

    private func resolved(_ json: String) throws -> PlaybackService.Resolved? {
        PlaybackService.episodeSource(try TestDocument.value(json))
    }

    func testTheFallbackOrder() {
        XCTAssertEqual(PlaybackService.fallbackOrder, ["jetstream", "hls", "mp4-hd", "mp4-sd"])
    }

    func testAServedJetstreamIdWinsOverAnMp4Link() throws {
        let source = try XCTUnwrap(try resolved("""
        { "provider": "jetstream", "id": "jsv:Bc1mMeG7XdM",
          "mediaLinks": { "jetstream": { "link": "jsv:Bc1mMeG7XdM" }, "mp4-hd": { "link": "https://example.test/hd.mp4" } } }
        """))
        XCTAssertEqual(source.url.absoluteString, "https://jstre.am/videos/jsv:Bc1mMeG7XdM/hls/main.m3u8")
        XCTAssertEqual(source.rendition, "jetstream")
    }

    func testAServedYouTubeFallsBackToJetstreamFirst() throws {
        let source = try XCTUnwrap(try resolved("""
        { "provider": "youtube", "id": "dQw4w9WgXcQ",
          "mediaLinks": { "youtube": { "link": "dQw4w9WgXcQ" }, "mp4-hd": { "link": "https://example.test/hd.mp4" },
                          "hls": { "link": "https://example.test/master.m3u8" }, "jetstream": { "link": "jsv:Bc1mMeG7XdM" } } }
        """))
        XCTAssertEqual(source.url.absoluteString, "https://jstre.am/videos/jsv:Bc1mMeG7XdM/hls/main.m3u8")
        XCTAssertEqual(source.rendition, "jetstream")
        XCTAssertTrue(source.isHLS)
    }

    func testAServedYouTubeWithAnMp4HdLinkPlaysTheMp4() throws {
        let source = try XCTUnwrap(try resolved("""
        { "provider": "youtube", "id": "dQw4w9WgXcQ",
          "mediaLinks": { "youtube": { "link": "dQw4w9WgXcQ" }, "mp4-hd": { "link": "https://example.test/hd.mp4" } } }
        """))
        XCTAssertEqual(source.url.absoluteString, "https://example.test/hd.mp4")
        XCTAssertEqual(source.rendition, "mp4-hd")
        // An MP4 offers no Quality picker.
        XCTAssertFalse(source.isHLS)
    }

    func testYouTubeAndVimeoOnlyResolveNothing() throws {
        XCTAssertNil(try resolved("""
        { "provider": "youtube", "id": "dQw4w9WgXcQ",
          "mediaLinks": { "youtube": { "link": "dQw4w9WgXcQ" }, "vimeo": { "link": "76979871" } } }
        """))
        // A live or audio Jetstream id under the `jetstream` key has no manifest either.
        XCTAssertNil(try resolved("""
        { "provider": "vimeo", "id": "76979871",
          "mediaLinks": { "jetstream": { "link": "jsl:Bc1mMeG7XdM" }, "jetstream-audio": { "link": "jsa:Bc1mMeG7XdM" } } }
        """))
    }

    /// Invariant 4: a non-https link is skipped, and the next entry plays.
    func testANonHttpsLinkIsSkipped() throws {
        let source = try XCTUnwrap(try resolved("""
        { "provider": "youtube", "id": "dQw4w9WgXcQ",
          "mediaLinks": { "mp4-hd": { "link": "http://example.test/hd.mp4" }, "mp4-sd": { "link": "https://example.test/sd.mp4" } } }
        """))
        XCTAssertEqual(source.url.absoluteString, "https://example.test/sd.mp4")
        XCTAssertNil(try resolved("""
        { "provider": "youtube", "id": "dQw4w9WgXcQ", "mediaLinks": { "hls": { "link": "http://example.test/master.m3u8" } } }
        """))
    }

    /// The `jetstream` entry takes the allowlist: an id that could add a path or a query is refused,
    /// and the next entry plays.
    func testAMaliciousJetstreamLinkIsRefused() throws {
        for link in ["jsv:../../videos/other", "jsv:a?b=1", "https://evil.test/embed/jsv:x", "https://example.test/hd.mp4"] {
            XCTAssertNil(try resolved("""
            { "provider": "youtube", "id": "dQw4w9WgXcQ", "mediaLinks": { "jetstream": { "link": "\(link)" } } }
            """), "\(link) must not reach the player")
        }
        let next = try XCTUnwrap(try resolved("""
        { "provider": "youtube", "id": "dQw4w9WgXcQ",
          "mediaLinks": { "jetstream": { "link": "jsv:a?b=1" }, "mp4-sd": { "link": "https://example.test/sd.mp4" } } }
        """))
        XCTAssertEqual(next.rendition, "mp4-sd")
    }

    /// A trailer serves `{ provider, videoId }` and no map: YouTube still plays nothing.
    func testATrailerKeepsItsRule() throws {
        XCTAssertNil(PlaybackService.trailerSource(try TestDocument.value(#"{ "provider": "youtube", "videoId": "dQw4w9WgXcQ" }"#)))
        XCTAssertEqual(
            PlaybackService.trailerSource(try TestDocument.value(#"{ "provider": "jetstream", "videoId": "jsv:Bc1mMeG7XdM" }"#))?.rendition,
            "jetstream"
        )
    }
}

/// The self-hosted rule (awe#5012).
///
/// Only `PlaybackService.renditions` (`hls`, `mp4-hd`, `mp4-sd`) store the stream url itself.
/// Every other provider — and a missing provider — resolves nothing, mirroring `apps/mobile`
/// `src/player/playerSource.ts`'s `SELF_HOSTED` set, even when its stored value is an https url.
final class SelfHostedSourceTests: XCTestCase {

    private func resource(_ provider: String?, link: String?) throws -> JSONValue {
        var fields: [String] = []
        if let provider { fields.append(#""provider": "\#(provider)""#) }
        if let link { fields.append(#""link": "\#(link)""#) }
        return try TestDocument.value("{ \(fields.joined(separator: ", ")) }")
    }

    private func source(_ provider: String?, link: String?) throws -> String? {
        try PlaybackService.episodeSource(try resource(provider, link: link))?.url.absoluteString
    }

    func testYouTubeAndVimeoWatchPagesPlayNothing() throws {
        XCTAssertNil(try source("youtube", link: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(try source("vimeo", link: "https://player.vimeo.com/video/1084537"))
    }

    func testSelfHostedProvidersPlayTheirStoredUrl() throws {
        for provider in PlaybackService.renditions {
            let url = "https://example.test/\(provider).m3u8"
            let resolved = try XCTUnwrap(PlaybackService.episodeSource(try resource(provider, link: url)))
            XCTAssertEqual(resolved.url.absoluteString, url, provider)
            XCTAssertEqual(resolved.rendition, provider)
        }
    }

    func testAnUnknownProviderPlaysNothingEvenWithAnHttpsUrl() throws {
        XCTAssertNil(try source("soundcloud", link: "https://example.test/track.mp3"))
        XCTAssertNil(try source("cloudflare", link: "https://example.test/video.mp4"))
    }

    func testAMissingProviderPlaysNothing() throws {
        XCTAssertNil(try source(nil, link: "https://example.test/master.m3u8"))
    }

    /// Mobile parity (`playerSource.test.ts:148-149`): a self-hosted link that is not an
    /// absolute https url plays nothing either.
    func testASelfHostedLinkThatIsNotAnHttpsUrlPlaysNothing() throws {
        XCTAssertNil(try source("hls", link: "/media/talk.mp4"))
        XCTAssertNil(try source("hls", link: "file:///etc/passwd"))
    }
}

/// An on-demand `EpisodePlayer` never plays inline (ruled 2026-09-23). It draws the poster and
/// one action; an unplayable source says so where the action would be.
final class EpisodePlayerBlockTests: XCTestCase {

    private let manifestURL = "https://jstre.am/videos/jsv:Bc1mMeG7XdM/hls/main.m3u8"

    private func content(_ resource: String, resumePoints: [String: Double] = [:]) throws -> BlockContent? {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1",
          "kind": "template",
          "blockResources": { "player": { "resources": { "episodePlayer": \(resource) } } },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["player"] },
            "player": {
              "type": { "resolvedName": "EpisodePlayer" },
              "props": {}, "custom": { "type": "plugin" },
              "parent": "ROOT", "nodes": []
            }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(
            nodeId: CraftDocument.rootId,
            document: screen.content,
            context: TestRender.context(blockResources: screen.blockResources, resumePoints: resumePoints)
        ))
        return try XCTUnwrap(node.first { $0.key == .episodePlayer }).content
    }

    private func action(_ content: BlockContent?) throws -> PlayActionModel {
        guard case let .playAction(model) = content else {
            XCTFail("EpisodePlayer drew no play action: \(String(describing: content))")
            throw CancellationError()
        }
        return model
    }

    func testAJetstreamVideoDrawsThePosterAndPlay() throws {
        let model = try action(try content("""
        { "provider": "jetstream", "id": "jsv:Bc1mMeG7XdM", "poster": "https://images.test/p.jpg" }
        """))

        XCTAssertEqual(model.request?.url.absoluteString, manifestURL)
        // A Jetstream manifest is HLS, so the player looks for a Quality picker (awe#6868).
        XCTAssertEqual(model.request?.isHLS, true)
        XCTAssertEqual(model.posterURL?.absoluteString, "https://images.test/p.jpg")
        XCTAssertEqual(model.label, "Play")
        XCTAssertNil(model.message)
    }

    /// The label reads the same progress key the full-screen player resumes from.
    func testAStoredResumePointReadsResume() throws {
        let resource = #"{ "provider": "jetstream", "id": "jsv:Bc1mMeG7XdM" }"#
        let resumed = try action(try content(resource, resumePoints: [manifestURL: 0.4]))
        XCTAssertEqual(resumed.request?.progressId, manifestURL)
        XCTAssertEqual(resumed.label, "Resume")

        // Progress on another episode is not this one's.
        let other = try action(try content(resource, resumePoints: ["https://example.test/other.m3u8": 0.4]))
        XCTAssertEqual(other.label, "Play")
    }

    func testAnUnplayableProviderDrawsTheMessageWhereTheButtonWouldBe() throws {
        for resource in [
            #"{ "provider": "vimeo", "id": "1084537", "poster": "https://images.test/p.jpg" }"#,
            #"{ "provider": "youtube", "id": "dQw4w9WgXcQ" }"#,
            #"{ "provider": "jetstream", "id": "jsl:Bc1mMeG7XdM" }"#,
            #"{ "error": "NO_SOURCE" }"#,
        ] {
            let model = try action(try content(resource))
            XCTAssertNil(model.request, resource)
            XCTAssertNil(model.label, resource)
            XCTAssertEqual(model.message, "This episode can't play on this device.", resource)
        }
        // The poster still draws beside the message.
        let vimeo = try action(try content(#"{ "provider": "vimeo", "id": "1084537", "poster": "https://images.test/p.jpg" }"#))
        XCTAssertEqual(vimeo.posterURL?.absoluteString, "https://images.test/p.jpg")
    }

    /// A non-https poster never loads.
    func testAnInsecurePosterIsDropped() throws {
        let model = try action(try content(#"{ "provider": "jetstream", "id": "jsv:Bc1mMeG7XdM", "poster": "http://images.test/p.jpg" }"#))
        XCTAssertNil(model.posterURL)
    }

    /// No served resource is no episode at all, not an unplayable one: the block draws nothing.
    func testAMissingResourceDrawsNothing() throws {
        XCTAssertNil(try content("null"))
    }
}

/// What the full-screen player shows in the transport bar and the Info panel.
final class PlaybackMetadataTests: XCTestCase {

    private let images = ImageConfig(cdn: "https://images.test", bucket: "bucket")

    private func value(_ json: String) throws -> JSONValue { try TestDocument.value(json) }

    func testTheEpisodeScreenGivesTitleDescriptionShowAndArtwork() throws {
        let screen = try ContractDecoder.screen(Fixtures.data("episode"))
        let episode = try XCTUnwrap(screen.resources["Episode"])
        let player = try XCTUnwrap(screen.blockResources["nnnTOtbL5k"]?["episodePlayer"])
        let detail = try XCTUnwrap(screen.blockResources.values.compactMap { $0["episodeDetail"] }.first)

        let metadata = PlaybackMetadata.episode(
            episode, blockResources: screen.blockResources, poster: player["poster"].string, images: images
        )

        XCTAssertEqual(metadata.title, episode["title"].string)
        XCTAssertEqual(metadata.description, episode["abstract"].string)
        // `resources.Episode.show` is only an id; the detail block carries the show record.
        XCTAssertEqual(metadata.showName, detail["show"]["title"].string)
        XCTAssertEqual(metadata.artworkURL, images.url(ImageFile(episode["image"]), width: 1280))
        // The "Keep watching" card opens the Episode Screen with this id.
        XCTAssertEqual(metadata.episodeId, episode["_id"].string)
    }

    func testThePosterIsTheArtworkWhenTheEpisodeHasNoImage() throws {
        let metadata = PlaybackMetadata.episode(
            try value(#"{ "_id": "e1", "title": "T" }"#), blockResources: [:], poster: "https://images.test/p.jpg", images: images
        )
        XCTAssertEqual(metadata.artworkURL?.absoluteString, "https://images.test/p.jpg")

        let insecure = PlaybackMetadata.episode(
            try value(#"{ "_id": "e1", "title": "T" }"#), blockResources: [:], poster: "http://images.test/p.jpg", images: images
        )
        XCTAssertNil(insecure.artworkURL)
    }

    /// A detail block bound to another episode never names this one's show.
    func testTheShowNameComesOnlyFromADetailOfTheSameEpisode() throws {
        let other = try value(#"{ "_id": "e2", "show": { "title": "Other Show" } }"#)
        let same = try value(#"{ "_id": "e1", "show": { "title": "Same Show" } }"#)
        let episode = try value(#"{ "_id": "e1", "title": "T", "abstract": "" }"#)

        XCTAssertNil(PlaybackMetadata.episode(episode, blockResources: ["d": ["episodeDetail": other]], poster: nil, images: images).showName)
        XCTAssertEqual(
            PlaybackMetadata.episode(episode, blockResources: ["d": ["episodeDetail": same]], poster: nil, images: images).showName,
            "Same Show"
        )
        // A blank abstract is no description.
        XCTAssertNil(PlaybackMetadata.episode(episode, blockResources: [:], poster: nil, images: images).description)
    }

    func testAScreenWithoutTheEpisodeRecordStillTitlesThePlayer() {
        let metadata = PlaybackMetadata.episode(.null, blockResources: [:], poster: nil, images: images)

        XCTAssertEqual(metadata.title, "Episode")
        XCTAssertNil(metadata.description)
        XCTAssertNil(metadata.showName)
        XCTAssertNil(metadata.artworkURL)
    }

    func testTheItemsUseTheStandardIdentifiers() throws {
        let metadata = PlaybackMetadata(title: "Lesson 1", description: "About", showName: "Hope Sabbath School", artworkURL: nil)

        let items = metadata.metadataItems()
        XCTAssertEqual(items.map(\.identifier), [.commonIdentifierTitle, .commonIdentifierDescription, .iTunesMetadataTrackSubTitle])
        XCTAssertEqual(items.map { $0.value as? String }, ["Lesson 1", "About", "Hope Sabbath School"])

        let artwork = Data([0x89, 0x50, 0x4E, 0x47])
        let withArt = metadata.metadataItems(artwork: artwork, artworkType: kCMMetadataBaseDataType_PNG as String)
        XCTAssertEqual(withArt.last?.identifier, .commonIdentifierArtwork)
        XCTAssertEqual(withArt.last?.value as? Data, artwork)
        XCTAssertEqual(withArt.last?.dataType, kCMMetadataBaseDataType_PNG as String)

        // Absent fields add no item.
        let bare = PlaybackMetadata(title: "T", description: nil, showName: nil, artworkURL: nil).metadataItems()
        XCTAssertEqual(bare.map(\.identifier), [.commonIdentifierTitle])
    }

    /// The age rating reaches the Info panel as the content rating (awe#6867), only with a value.
    func testTheContentRatingItemOnlyWithAValue() {
        var metadata = PlaybackMetadata(title: "T", description: nil, showName: nil, artworkURL: nil)
        metadata.contentRating = "FSK 12"

        let rating = metadata.metadataItems().first { $0.identifier == .iTunesMetadataContentRating }
        XCTAssertEqual(rating?.value as? String, "FSK 12")

        metadata.contentRating = nil
        XCTAssertFalse(metadata.metadataItems().contains { $0.identifier == .iTunesMetadataContentRating })
    }

    /// The rating comes from the `episodeDetail` of the SAME episode, already resolved Episode →
    /// Show on the server; its primary (first) item only.
    func testTheContentRatingComesFromTheDetailOfTheSameEpisode() throws {
        let ratings = #""ageRatings": [{ "system": "fsk", "value": "12", "descriptors": [] }, { "system": "mpa", "value": "R" }], "language": "Deutsch""#
        let same = try value(#"{ "_id": "e1", "show": { "title": "S" }, "# + ratings + "}")
        let other = try value(#"{ "_id": "e2", "show": { "title": "S" }, "# + ratings + "}")
        let episode = try value(#"{ "_id": "e1", "title": "T" }"#)

        let metadata = PlaybackMetadata.episode(episode, blockResources: ["d": ["episodeDetail": same]], poster: nil, images: images)
        XCTAssertEqual(metadata.contentRating, "FSK 12")

        XCTAssertNil(PlaybackMetadata.episode(episode, blockResources: ["d": ["episodeDetail": other]], poster: nil, images: images).contentRating)
        XCTAssertNil(PlaybackMetadata.episode(episode, blockResources: [:], poster: nil, images: images).contentRating)
        let unrated = try value(#"{ "_id": "e1", "ageRatings": [] }"#)
        XCTAssertNil(PlaybackMetadata.episode(episode, blockResources: ["d": ["episodeDetail": unrated]], poster: nil, images: images).contentRating)
    }

    /// The genre slot is for a movie only (ruled 2026-10-15): an episode sets none, also when its
    /// detail serves genres, so its Info panel meta line is unchanged.
    func testAnEpisodeSetsNoGenre() throws {
        let detail = try value(#"{ "_id": "e1", "genres": [{ "id": "g1", "title": "Drama" }] }"#)
        let episode = try value(#"{ "_id": "e1", "title": "T" }"#)
        let metadata = PlaybackMetadata.episode(episode, blockResources: ["d": ["episodeDetail": detail]], poster: nil, images: images)

        XCTAssertNil(metadata.genre)
        XCTAssertFalse(metadata.metadataItems().contains { $0.identifier == .quickTimeMetadataGenre })
    }

    /// The genre reaches the Info panel as `quickTimeMetadataGenre`, the first part of its meta
    /// line (measured 2026-10-14), only with a value.
    func testTheGenreItemOnlyWithAValue() {
        var metadata = PlaybackMetadata(title: "T", description: nil, showName: nil, artworkURL: nil)
        metadata.genre = "Drama"
        XCTAssertEqual(metadata.metadataItems().first { $0.identifier == .quickTimeMetadataGenre }?.value as? String, "Drama")

        metadata.genre = nil
        XCTAssertFalse(metadata.metadataItems().contains { $0.identifier == .quickTimeMetadataGenre })
    }

    /// A livestream has no episode, so no rating.
    func testALivestreamCarriesNoContentRating() throws {
        let channel = try value(#"{ "title": "Hope TV" }"#)
        XCTAssertNil(PlaybackMetadata.livestream(channel, images: images).contentRating)
    }
}

/// The full-screen player sits above the stack. Back from it returns to the Episode Screen.
@MainActor
final class PlaybackRouterTests: XCTestCase {

    func testPlayOpensFullScreenAndDismissKeepsTheEpisodeScreen() throws {
        let manifest = try ContractDecoder.manifest(Fixtures.data("manifest"))
        let router = AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
        let episode = try Fixtures.json("expectations")["screens"]["episode"]
        router.open(screenId: episode["id"].string, param: episode["param"].string)
        let stack = router.state.stack
        XCTAssertEqual(stack.count, 1)

        let url = try XCTUnwrap(URL(string: "https://jstre.am/videos/jsv:mmPNfkcIEdR/hls/main.m3u8"))
        let request = PlaybackRequest(url: url, metadata: PlaybackMetadata(title: "Lesson 1", description: nil, showName: nil, artworkURL: nil),
                                      isHLS: true)

        router.play(request)
        XCTAssertEqual(router.playback, request)
        XCTAssertFalse(router.isAtSafeBoundary)

        router.endPlayback()
        XCTAssertNil(router.playback)
        XCTAssertEqual(router.state.stack, stack, "back from full screen returns to the Episode Screen")
    }
}

/// The artwork fetch is bounded like a contract fetch: 200 only, a declared-length check before
/// the body, a running cap while it streams, and a JPEG or PNG type.
final class ArtworkLoaderTests: XCTestCase {

    func testOnlyA200UnderTheCapIsRead() {
        XCTAssertTrue(ArtworkLoader.accepts(statusCode: 200, declaredLength: 120_000))
        // No declared length: the running cap decides.
        XCTAssertTrue(ArtworkLoader.accepts(statusCode: 200, declaredLength: -1))
        XCTAssertFalse(ArtworkLoader.accepts(statusCode: 404, declaredLength: 10))
        XCTAssertFalse(ArtworkLoader.accepts(statusCode: 302, declaredLength: 10))
        XCTAssertFalse(ArtworkLoader.accepts(statusCode: 200, declaredLength: Int64(ArtworkLoader.maxBytes) + 1))
        XCTAssertTrue(ArtworkLoader.accepts(statusCode: 200, declaredLength: Int64(ArtworkLoader.maxBytes)))
    }

    func testTheCapAndTheTimeoutAreBounded() {
        XCTAssertEqual(ArtworkLoader.maxBytes, 5 * 1024 * 1024)
        XCTAssertEqual(ArtworkLoader.session.configuration.timeoutIntervalForResource, 15)
        // No credentials travel with the fetch.
        XCTAssertFalse(ArtworkLoader.session.configuration.httpShouldSetCookies)
        XCTAssertNil(ArtworkLoader.session.configuration.urlCredentialStorage)
    }

    func testOnlyJPEGAndPNGBecomeArtwork() {
        XCTAssertEqual(ArtworkLoader.dataType(mime: "image/jpeg"), kCMMetadataBaseDataType_JPEG as String)
        XCTAssertEqual(ArtworkLoader.dataType(mime: "image/png"), kCMMetadataBaseDataType_PNG as String)
        XCTAssertNil(ArtworkLoader.dataType(mime: "image/webp"))
        XCTAssertNil(ArtworkLoader.dataType(mime: "image/avif"))
        XCTAssertNil(ArtworkLoader.dataType(mime: nil))
    }
}

/// Back during the Resume seek dismisses the player before it exists. `start()` must then not
/// build a hidden player that keeps playing.
final class PlayerStartTests: XCTestCase {

    private func request(_ path: String) throws -> PlaybackRequest {
        PlaybackRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/\(path).m3u8")),
            metadata: PlaybackMetadata(title: "T", description: nil, showName: nil, artworkURL: nil),
            isHLS: true
        )
    }

    func testStartGoesOnOnlyWhileItsRequestIsStillShowing() throws {
        let mine = try request("a")

        XCTAssertTrue(PlayerView.isStillWanted(mine, showing: mine, cancelled: false))
        XCTAssertFalse(PlayerView.isStillWanted(mine, showing: nil, cancelled: false), "Back cleared the playback")
        XCTAssertFalse(PlayerView.isStillWanted(mine, showing: try request("b"), cancelled: false))
        XCTAssertFalse(PlayerView.isStillWanted(mine, showing: mine, cancelled: true))
    }
}

/// awe#5044: Select on the inline Live player opens the livestream full screen. One request
/// path serves both live entry points, built here through the block evaluator.
@MainActor
final class LivestreamFullScreenTests: XCTestCase {

    private let channel = """
    {
      "title": "Hope TV Deutsch",
      "hls": "https://live.example.org/hope/main.m3u8",
      "logo": { "containerId": "c1", "name": "logo.png", "width": 631, "height": 222 }
    }
    """

    private let onAir = #"{ "_id": "now", "episodeTitle": "On Air", "startsAt": "2026-09-28T15:00:00.000Z", "endsAt": "2026-09-28T15:30:00.000Z" }"#

    /// A Live screen: the inline player and a schedule on the same channel, as production serves
    /// it. The two `broadcastsLive` differ, as in production: the player serves its own rows for
    /// the Schedule tab (awe#6553), the strip only as many as its author allows.
    private func evaluate() throws -> EvaluatedNode {
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1", "kind": "static",
          "blockResources": {
            "player": { "resources": { "channel": \(channel), "broadcastsLive": { "current": \(onAir), "items": [
              { "_id": "next", "episodeTitle": "Next", "startsAt": "2026-09-28T15:30:00.000Z", "endsAt": "2026-09-28T16:00:00.000Z" }] } } },
            "strip": { "resources": { "channel": \(channel), "broadcastsLive": { "current": \(onAir), "items": [] } } }
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["player", "strip"] },
            "player": { "type": { "resolvedName": "LivestreamPlayer" }, "props": {}, "custom": { "type": "plugin", "resources": ["channel"] }, "parent": "ROOT", "nodes": [] },
            "strip": { "type": { "resolvedName": "ScheduleLive" }, "props": {}, "custom": { "type": "plugin", "resources": ["channel", "broadcastsLive"] }, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        return try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                    context: TestRender.context(blockResources: screen.blockResources)))
    }

    private func inlineRequest() throws -> PlaybackRequest {
        guard case let .player(model) = try XCTUnwrap(try evaluate().first { $0.key == .livestreamPlayer }).content else {
            XCTFail("LivestreamPlayer drew no player")
            throw CancellationError()
        }
        return model.request
    }

    func testTheInlinePlayerAndTheNowCardOpenTheSameLiveRequest() throws {
        let node = try evaluate()
        guard case let .schedule(schedule) = try XCTUnwrap(node.first { $0.key == .scheduleLive }).content else {
            return XCTFail("ScheduleLive drew nothing")
        }
        let now = try XCTUnwrap(ContractDate.parse("2026-09-28T15:10:00.000Z"))
        guard case let .live(nowCard) = try XCTUnwrap(schedule.entries(at: now).first).kind else {
            return XCTFail("the on-air row is not the live kind")
        }

        // One code path for the stream. Each entry point carries its own schedule rows.
        let inline = try inlineRequest()
        XCTAssertEqual(inline.url, nowCard.url, "one code path, one stream")
        XCTAssertEqual(inline.metadata, nowCard.metadata)
        XCTAssertEqual(inline.recordsProgress, nowCard.recordsProgress)
        XCTAssertEqual(inline.schedule?.map(\.id), ["now", "next"])
        XCTAssertEqual(nowCard.schedule?.map(\.id), ["now"])
        XCTAssertEqual(try inlineRequest().url.absoluteString, "https://live.example.org/hope/main.m3u8")
    }

    /// The livestream metadata shape: the channel title and image, no episode fields.
    func testTheLiveRequestCarriesTheChannelTitleAndImage() throws {
        let metadata = try inlineRequest().metadata

        XCTAssertEqual(metadata.title, "Hope TV Deutsch")
        XCTAssertEqual(metadata.artworkURL?.absoluteString.contains("logo.png"), true)
        XCTAssertNil(metadata.description)
        XCTAssertNil(metadata.showName)
        XCTAssertNil(metadata.episodeId, "no Keep watching card can come from it")
    }

    /// A live request never reads a resume point (so it never seeks) and is not observed for
    /// progress, whatever the store holds under its URL, and whatever duration the stream reports.
    func testALiveRequestNeverResumesOrRecords() throws {
        let key = "watch-progress-v2"
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        let request = try inlineRequest()
        let store = WatchProgressStore()
        store.record(0.5, for: request.progressId, title: "stale")

        XCTAssertEqual(store.fraction(for: request.progressId), 0.5, "the store holds a resume point under the URL")
        XCTAssertFalse(request.recordsProgress, "PlayerView neither seeks nor observes progress for it")
        XCTAssertNil(request.resumeFraction(in: store), "the player reads no resume point")

        let episode = PlaybackRequest(url: request.url, metadata: request.metadata, isHLS: true)
        XCTAssertEqual(episode.resumeFraction(in: store), 0.5, "an on-demand request still resumes")
    }

    /// No https live source: no request, and the block says so.
    func testAnInsecureLiveSourceOpensNothing() {
        let insecure = try? JSONDecoder().decode(JSONValue.self, from: Data(#"{ "title": "T", "hls": "http://live.example.org/x.m3u8" }"#.utf8))
        XCTAssertNil(PlaybackService.liveRequest(insecure, images: TestRender.context().images))
    }
}

/// Feedback round 3: "Go to show" in the player's Info panel. On-demand episodes only, from the
/// show id the served record carries; never a livestream or a trailer.
@MainActor
final class PlayerInfoGoToShowTests: XCTestCase {

    private let showId = "698b02ede9885270958aac85"

    /// The Episode screen's play request, built through the evaluator from the captured
    /// production screen (`EpisodeScreenSplit.json` in the UI-test target has the same shape).
    private func episodeRequest(showRef: String, detailShow: String?) throws -> PlaybackRequest {
        let detail = detailShow.map { #", "detail": { "resources": { "episodeDetail": { "_id": "e1", "title": "Gute Nachricht", "show": \#($0) } } }"# } ?? ""
        let screen = try ContractDecoder.screen(Data("""
        {
          "id": "s1", "kind": "template",
          "resources": { "Episode": { "_id": "e1", "title": "Gute Nachricht", "show": \(showRef) } },
          "blockResources": {
            "player": { "resources": { "episodePlayer": { "provider": "jetstream", "id": "jsv:0wHdqlG0gaY" } } }\(detail)
          },
          "content": {
            "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["player"] },
            "player": { "type": { "resolvedName": "EpisodePlayer" }, "props": {}, "custom": { "type": "plugin" }, "parent": "ROOT", "nodes": [] }
          }
        }
        """.utf8))
        let node = try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: screen.content,
                                                        context: TestRender.context(blockResources: screen.blockResources,
                                                                                    screenResources: screen.resources)))
        guard case let .playAction(model) = try XCTUnwrap(node.first { $0.key == .episodePlayer }).content,
              let request = model.request else {
            XCTFail("EpisodePlayer drew no play request")
            throw CancellationError()
        }
        return request
    }

    func testAnEpisodeOffersGoToShowFromItsServedShowId() throws {
        // Production serves `resources.Episode.show` as a bare id and `episodeDetail.show._id`.
        let request = try episodeRequest(showRef: #""\#(showId)""#, detailShow: #"{ "_id": "\#(showId)", "title": "Bibelkompass" }"#)

        XCTAssertEqual(request.metadata.showId, showId)
        XCTAssertEqual(PlayerInfoAction.actions(for: request, canOpen: { _ in true }), [.goToShow(CardTarget(resourceType: "show", itemId: showId))])
        XCTAssertEqual(PlayerInfoAction.goToShow(CardTarget(resourceType: "show", itemId: showId)).title, "Go to show")

        // Without an episodeDetail on the screen, the Episode record's own ref still names it.
        XCTAssertEqual(try episodeRequest(showRef: #""\#(showId)""#, detailShow: nil).metadata.showId, showId)
    }

    /// The id comes from the record, never free text: a value that is not an ObjectId is ignored.
    func testAShowRefThatIsNotAnIdOffersNothing() throws {
        let request = try episodeRequest(showRef: #""Bibelkompass""#, detailShow: nil)

        XCTAssertNil(request.metadata.showId)
        XCTAssertEqual(PlayerInfoAction.actions(for: request, canOpen: { _ in true }), [])
    }

    /// No action when the show cannot open (no or several `show` templates): no dead action.
    func testNoActionWhenTheShowCannotOpen() throws {
        let request = try episodeRequest(showRef: #""\#(showId)""#, detailShow: nil)
        XCTAssertEqual(PlayerInfoAction.actions(for: request, canOpen: { _ in false }), [])

        let router = try router()
        XCTAssertEqual(PlayerInfoAction.actions(for: request, canOpen: router.canOpenCard),
                       [.goToShow(CardTarget(resourceType: "show", itemId: showId))], "one show template opens")
    }

    func testALivestreamAndATrailerOfferNothing() throws {
        let images = TestRender.context().images
        let channel = try JSONDecoder().decode(JSONValue.self, from: Data(#"{ "title": "Hope TV Deutsch", "hls": "https://live.example.org/x.m3u8" }"#.utf8))
        let live = try XCTUnwrap(PlaybackService.liveRequest(channel, images: images))
        XCTAssertNil(live.metadata.showId)
        XCTAssertEqual(PlayerInfoAction.actions(for: live, canOpen: { _ in true }), [])

        let trailerJSON = try JSONDecoder().decode(JSONValue.self, from: Data(#"{ "provider": "jetstream", "videoId": "jsv:QBvi99xy28Q" }"#.utf8))
        let trailer = try XCTUnwrap(PlaybackService.trailerRequest(trailerJSON, title: "T", description: nil, artworkURL: nil))
        XCTAssertEqual(PlayerInfoAction.actions(for: trailer, canOpen: { _ in true }), [])
    }

    private func router() throws -> AppRouter {
        let manifest = try ContractDecoder.manifest(Data("""
        {
          "contractVersion": 1, "app": { "design": "tv" }, "defaultLayoutId": "l1",
          "layouts": [{ "id": "l1", "content": {}, "navigation": { "tabs": [{ "screenId": "home", "label": "Home" }] } }],
          "screens": [{ "id": "home", "kind": "static" },
                      { "id": "show-tpl", "kind": "template", "resourceType": "show" },
                      { "id": "episode-tpl", "kind": "template", "resourceType": "episode" }],
          "preset": {}
        }
        """.utf8))
        return AppRouter(tree: NavigationTree(manifest: manifest), diagnostics: Diagnostics())
    }

    /// Select: the player closes, and the show opens above the Episode screen.
    func testGoToShowClosesThePlayerAndOpensTheShow() throws {
        let router = try router()
        let request = try episodeRequest(showRef: #""\#(showId)""#, detailShow: nil)
        router.openCard(CardTarget(resourceType: "episode", itemId: "e1"))
        router.play(request)

        guard case let .goToShow(target)? = PlayerInfoAction.actions(for: request, canOpen: { _ in true }).first else { return XCTFail("no action") }
        router.leavePlayback(openingCard: target)

        XCTAssertNil(router.playback)
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "episode-tpl", param: "e1"), StackEntry(screenId: "show-tpl", param: showId)])
    }

    /// Show → Episode → "Go to show" returns to that Show screen instead of stacking a copy.
    func testGoToShowPopsBackToTheSameShowBelow() throws {
        let router = try router()
        router.openCard(CardTarget(resourceType: "show", itemId: showId))
        router.openCard(CardTarget(resourceType: "episode", itemId: "e1"))

        router.leavePlayback(openingCard: CardTarget(resourceType: "show", itemId: showId))
        XCTAssertEqual(router.state.stack, [StackEntry(screenId: "show-tpl", param: showId)])

        // Another show still pushes.
        router.openCard(CardTarget(resourceType: "episode", itemId: "e1"))
        router.openCard(CardTarget(resourceType: "show", itemId: "6565c837501cf1394985b9f4"))
        XCTAssertEqual(router.state.stack.count, 3)
    }
}

/// A failed image load retries, bounded (feedback round 3: "Verlauf" cards stayed blank after a
/// load was canceled while the full-screen player covered Home).
final class RemoteImageRetryTests: XCTestCase {

    func testACanceledLoadRetriesAtOnceAndEveryRetryIsBounded() {
        let cancelled = URLError(.cancelled)
        XCTAssertEqual(RemoteImageRetry.delay(after: cancelled, attempt: 0), .milliseconds(100))
        XCTAssertEqual(RemoteImageRetry.delay(after: CancellationError(), attempt: 0), .milliseconds(100),
                       "a canceled task counts as canceled too")
        XCTAssertEqual(RemoteImageRetry.delay(after: URLError(.timedOut), attempt: 0), .seconds(1))
        XCTAssertEqual(RemoteImageRetry.delay(after: URLError(.timedOut), attempt: 1), .seconds(2))
        XCTAssertNil(RemoteImageRetry.delay(after: cancelled, attempt: RemoteImageRetry.maxRetries), "a broken URL never loops")
    }
}

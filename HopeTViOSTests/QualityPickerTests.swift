// cspell:ignore bipbop Automatisch
import AVFoundation
import XCTest
@testable import HopeTViOS

/// The Quality picker (awe#6868, ADR-0260): the player's own parsed variants give one option per
/// height, and a choice is a cap, never a lock.
final class QualityVariantTests: XCTestCase {

    private func size(_ width: Double, _ height: Double) -> CGSize { CGSize(width: width, height: height) }

    func testAVideoVariantKeepsItsSizeAndPeakBitRate() {
        XCTAssertEqual(QualityLadder.variant(presentationSize: size(1920, 1080), peakBitRate: 2_200_000),
                       .init(width: 1920, height: 1080, bandwidth: 2_200_000))
    }

    /// The audio-only entry has no video attributes. A master with no `RESOLUTION` (bipbop 4x3)
    /// reports 0x0.
    func testNoVideoAttributesOrNoSizeIsSkipped() {
        XCTAssertNil(QualityLadder.variant(presentationSize: nil, peakBitRate: 41_457))
        XCTAssertNil(QualityLadder.variant(presentationSize: .zero, peakBitRate: 232_370))
        XCTAssertNil(QualityLadder.variant(presentationSize: size(1280, 0), peakBitRate: 1))
        XCTAssertNil(QualityLadder.variant(presentationSize: size(-1280, 720), peakBitRate: 1))
        // A size below 1 would become height 0, which reads as Auto.
        XCTAssertNil(QualityLadder.variant(presentationSize: size(0.5, 0.5), peakBitRate: 1))
    }

    func testANonFiniteSizeIsSkipped() {
        XCTAssertNil(QualityLadder.variant(presentationSize: size(.nan, 720), peakBitRate: 1))
        XCTAssertNil(QualityLadder.variant(presentationSize: size(1280, .nan), peakBitRate: 1))
        XCTAssertNil(QualityLadder.variant(presentationSize: size(.infinity, 720), peakBitRate: 1))
        XCTAssertNil(QualityLadder.variant(presentationSize: size(1280, .infinity), peakBitRate: 1))
    }

    /// A missing, negative (the header: "not declared") or non-finite peak never reaches
    /// `preferredPeakBitRate`: it reads as no bit-rate cap.
    func testAnUnusablePeakBitRateReadsAsNoBitRateCap() {
        for peak in [nil, -1, -500, 0, .nan, .infinity, -.infinity] as [Double?] {
            XCTAssertEqual(QualityLadder.variant(presentationSize: size(1280, 720), peakBitRate: peak)?.bandwidth, 0,
                           "\(String(describing: peak))")
        }
    }

    /// `Int(1e30)` traps. A huge value is clamped, never a crash.
    func testAHugeValueIsClampedAndDoesNotTrap() {
        let variant = QualityLadder.variant(presentationSize: size(1e30, 1e30), peakBitRate: 1e30)
        XCTAssertEqual(variant, .init(width: Int(Int32.max), height: Int(Int32.max), bandwidth: Int(Int32.max)))
    }
}

/// AVFoundation lists every variant in playlist order. It does not merge or sort them.
final class QualityLadderMergeTests: XCTestCase {

    /// The Jetstream master of `jsv:mmPNfkcIEdR` (captured 2026-10-14), as the player parses it.
    private let jetstream: [QualityLadder.Variant] = [
        .init(width: 1920, height: 1080, bandwidth: 2_200_000),
        .init(width: 1280, height: 720, bandwidth: 1_100_000),
        .init(width: 640, height: 360, bandwidth: 550_000),
        .init(width: 426, height: 240, bandwidth: 220_000),
    ]

    func testAMasterGivesOneVariantPerHeightHighestFirst() throws {
        let ladder = try XCTUnwrap(QualityLadder(raw: jetstream.reversed()))
        XCTAssertEqual(ladder.variants, jetstream)
    }

    /// Apple's advanced example lists each height several times, in no order.
    func testSeveralVariantsAtOneHeightKeepTheHighestBandwidthInAnyOrder() throws {
        let raw: [QualityLadder.Variant] = [
            .init(width: 960, height: 540, bandwidth: 2_227_464),
            .init(width: 1920, height: 1080, bandwidth: 6_453_202),
            .init(width: 1920, height: 1080, bandwidth: 8_178_040),
            .init(width: 1920, height: 1080, bandwidth: 5_054_232),
        ]
        let expected: [QualityLadder.Variant] = [
            .init(width: 1920, height: 1080, bandwidth: 8_178_040),
            .init(width: 960, height: 540, bandwidth: 2_227_464),
        ]
        XCTAssertEqual(QualityLadder.merged(raw), expected)
        XCTAssertEqual(QualityLadder.merged(raw.reversed()), expected)
        XCTAssertEqual(try XCTUnwrap(QualityLadder(raw: raw)).variants, expected)
    }

    /// The width and the bandwidth are separate maxima per height. An anamorphic 1440x1080 at a
    /// higher bit rate must not shrink the 1080p cap and exclude every 1920x1080 variant.
    func testEachHeightKeepsItsWidestWidthAndItsHighestBandwidth() {
        let raw: [QualityLadder.Variant] = [
            .init(width: 1440, height: 1080, bandwidth: 9_000_000),
            .init(width: 1920, height: 1080, bandwidth: 5_000_000),
        ]
        XCTAssertEqual(QualityLadder.merged(raw), [.init(width: 1920, height: 1080, bandwidth: 9_000_000)])
        XCTAssertEqual(QualityLadder.merged(raw.reversed()), [.init(width: 1920, height: 1080, bandwidth: 9_000_000)])
    }

    /// A hostile master with thousands of heights still builds a short menu: the highest ones.
    func testOnlyTheHighestHeightsAreKept() {
        let raw = (1...6000).map { QualityLadder.Variant(width: $0, height: $0, bandwidth: $0) }
        let variants = QualityLadder.merged(raw.shuffled())
        XCTAssertEqual(variants.count, QualityLadder.maxHeights)
        XCTAssertEqual(QualityLadder.maxHeights, 16)
        XCTAssertEqual(variants.first?.height, 6000)
        XCTAssertEqual(variants.last?.height, 6000 - QualityLadder.maxHeights + 1)
    }

    func testNoChoiceGivesNoLadder() {
        // No video variant: an MP4, a media playlist, or a master with no RESOLUTION.
        XCTAssertNil(QualityLadder(raw: []))
        // One height: nothing to choose.
        XCTAssertNil(QualityLadder(raw: [
            .init(width: 1920, height: 1080, bandwidth: 2_200_000),
            .init(width: 1920, height: 1080, bandwidth: 1_800_000),
        ]))
    }
}

/// The glue to AVFoundation: an asset that does not load gives no menu.
final class QualityLadderLoadTests: XCTestCase {

    func testAnAssetThatCannotLoadGivesNoLadder() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-master-\(UUID()).m3u8")
        let ladder = await QualityLadder.load(from: AVURLAsset(url: missing))
        XCTAssertNil(ladder)
    }

    /// Only an `AVURLAsset` has variants. Any other asset (here a composition) gives no menu.
    func testAnAssetThatIsNotAnAVURLAssetGivesNoLadder() async {
        let ladder = await QualityLadder.load(from: AVMutableComposition())
        XCTAssertNil(ladder)
    }
}

/// The height → label rule. Resolution names are not translated.
final class QualityLabelTests: XCTestCase {

    func testHeightsReadAsTheirCommonName() {
        XCTAssertEqual(QualityLadder.label(height: 4320), "8K")
        XCTAssertEqual(QualityLadder.label(height: 2160), "4K")
        XCTAssertEqual(QualityLadder.label(height: 1440), "1440p")
        XCTAssertEqual(QualityLadder.label(height: 1080), "1080p")
        XCTAssertEqual(QualityLadder.label(height: 720), "720p")
        XCTAssertEqual(QualityLadder.label(height: 240), "240p")
        // Any other height reads as itself, also above 4K.
        XCTAssertEqual(QualityLadder.label(height: 2880), "2880p")
        XCTAssertEqual(QualityLadder.label(height: 800), "800p")
    }
}

/// A stored cap on a stream: which variant the menu checks, and what the item is capped to.
final class QualityCapTests: XCTestCase {

    private let ladder = QualityLadder(variants: [
        .init(width: 1920, height: 1080, bandwidth: 2_200_000),
        .init(width: 1280, height: 720, bandwidth: 1_100_000),
        .init(width: 640, height: 360, bandwidth: 550_000),
    ])

    func testAutoChecksAutoAndCapsNothing() {
        XCTAssertNil(ladder.selection(cap: QualityPreference.auto))
        XCTAssertNil(ladder.constraint(cap: QualityPreference.auto))
    }

    func testAVariantHeightCapsAtThatVariant() {
        XCTAssertEqual(ladder.selection(cap: 720)?.height, 720)
        XCTAssertEqual(ladder.constraint(cap: 720), .init(width: 1280, height: 720, bandwidth: 1_100_000))
    }

    /// The best variant is the same as no cap: the item gets none.
    func testTheBestVariantOrAboveCapsNothing() {
        XCTAssertEqual(ladder.selection(cap: 1080)?.height, 1080)
        XCTAssertNil(ladder.constraint(cap: 1080))
        // A 4K choice on a 1080p stream has no effect, and the menu checks 1080p.
        XCTAssertEqual(ladder.selection(cap: 2160)?.height, 1080)
        XCTAssertNil(ladder.constraint(cap: 2160))
    }

    func testAHeightBetweenVariantsCapsAtTheNearestBelow() {
        XCTAssertEqual(ladder.selection(cap: 900)?.height, 720)
        XCTAssertEqual(ladder.constraint(cap: 900)?.height, 720)
    }

    /// The viewer asked for less data than this stream's lowest variant: the lowest it is.
    func testAHeightBelowEveryVariantCapsAtTheLowest() {
        XCTAssertEqual(ladder.selection(cap: 240)?.height, 360)
        XCTAssertEqual(ladder.constraint(cap: 240)?.height, 360)
    }

    func testTheOptionsAreAutoThenEveryHeightHighestFirstAsACap() {
        let options = ladder.options(cap: 720)
        XCTAssertEqual(options.map(\.title), ["Auto", "Up to 1080p", "Up to 720p", "Up to 360p"])
        XCTAssertEqual(options.map(\.cap), [0, 1080, 720, 360])
        XCTAssertEqual(options.map(\.isOn), [false, false, true, false])
        XCTAssertEqual(ladder.options(cap: QualityPreference.auto).map(\.isOn), [true, false, false, false])
    }

    func testTheOptionTitlesReadTheServedStrings() {
        defer { ChromeText.served.strings = [:] }
        ChromeText.served.strings = ["tvQualityAuto": "Automatisch", "tvQualityUpTo": "Bis {{label}}"]
        XCTAssertEqual(ladder.options(cap: 0).map(\.title), ["Automatisch", "Bis 1080p", "Bis 720p", "Bis 360p"])
    }
}

/// The cap the item gets: a variant's size and bandwidth, or nothing.
final class QualityItemLimitTests: XCTestCase {

    func testAVariantGivesItsSizeAndBandwidthAndNoneClearsBoth() {
        let capped = QualityLadder.limits(.init(width: 1280, height: 720, bandwidth: 1_100_000))
        XCTAssertEqual(capped.maximumResolution, CGSize(width: 1280, height: 720))
        XCTAssertEqual(capped.peakBitRate, 1_100_000)

        let none = QualityLadder.limits(nil)
        XCTAssertEqual(none.maximumResolution, .zero)
        XCTAssertEqual(none.peakBitRate, 0)
    }

    /// The same call the player makes, on a real item (setting the two properties needs no network).
    func testTheCapReachesARealItemAndAutoClearsIt() throws {
        let item = AVPlayerItem(url: try XCTUnwrap(URL(string: "https://example.test/master.m3u8")))
        let ladder = QualityLadder(variants: [
            .init(width: 1920, height: 1080, bandwidth: 2_200_000),
            .init(width: 1280, height: 720, bandwidth: 1_100_000),
        ])

        QualityLadder.apply(ladder.constraint(cap: 720), to: item)
        XCTAssertEqual(item.preferredMaximumResolution, CGSize(width: 1280, height: 720))
        XCTAssertEqual(item.preferredPeakBitRate, 1_100_000)

        QualityLadder.apply(ladder.constraint(cap: QualityPreference.auto), to: item)
        XCTAssertEqual(item.preferredMaximumResolution, .zero)
        XCTAssertEqual(item.preferredPeakBitRate, 0)
    }
}

/// The choice is the device's, a height in `UserDefaults`, read by every next item.
final class QualityPreferenceTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "QualityPreferenceTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testNothingStoredIsAuto() {
        XCTAssertEqual(QualityPreference(defaults: defaults).cap, QualityPreference.auto)
    }

    func testAChoiceIsStoredAsAHeightAndReadByTheNextPlayer() {
        QualityPreference(defaults: defaults).cap = 720
        XCTAssertEqual(defaults.integer(forKey: QualityPreference.key), 720)
        XCTAssertEqual(QualityPreference(defaults: defaults).cap, 720)
        QualityPreference(defaults: defaults).cap = QualityPreference.auto
        XCTAssertEqual(QualityPreference(defaults: defaults).cap, QualityPreference.auto)
    }

    func testANegativeStoredValueReadsAsAuto() {
        defaults.set(-5, forKey: QualityPreference.key)
        XCTAssertEqual(QualityPreference(defaults: defaults).cap, QualityPreference.auto)
    }
}

/// Only an HLS source asks for a picker: an MP4 rendition never loads variants.
@MainActor
final class QualitySourceKindTests: XCTestCase {

    private func resolved(_ provider: String, _ link: String) throws -> PlaybackService.Resolved {
        let resource = try TestDocument.value(#"{ "provider": "\#(provider)", "link": "\#(link)" }"#)
        return try XCTUnwrap(PlaybackService.episodeSource(resource))
    }

    func testHLSAndJetstreamAreHLSAndMP4IsNot() throws {
        XCTAssertTrue(try resolved("hls", "https://example.test/master.m3u8").isHLS)
        XCTAssertTrue(try resolved("jetstream", "jsv:Bc1mMeG7XdM").isHLS)
        XCTAssertFalse(try resolved("mp4-hd", "https://example.test/hd.mp4").isHLS)
        XCTAssertFalse(try resolved("mp4-sd", "https://example.test/sd.mp4").isHLS)
        // A `mediaLinks` entry with no provider too.
        let ladder = try TestDocument.value(#"{ "mediaLinks": { "mp4-sd": { "link": "https://example.test/sd.mp4" } } }"#)
        XCTAssertEqual(PlaybackService.episodeSource(ladder)?.isHLS, false)
    }

    func testTheRequestCarriesTheKind() throws {
        let channel = try TestDocument.value(#"{ "title": "Live", "hls": "https://live.example.org/main.m3u8" }"#)
        XCTAssertEqual(PlaybackService.liveRequest(channel, images: ImageConfig(cdn: "https://images.test", bucket: "bucket"))?.isHLS, true)
        let trailer = try TestDocument.value(#"{ "provider": "jetstream", "videoId": "jsv:Bc1mMeG7XdM" }"#)
        XCTAssertEqual(PlaybackService.trailerRequest(trailer, title: "T", description: nil, artworkURL: nil)?.isHLS, true)
    }
}

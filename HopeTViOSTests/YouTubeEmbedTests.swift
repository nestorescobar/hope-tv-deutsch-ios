import XCTest
@testable import HopeTViOS

final class YouTubeEmbedTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"

    func testEveryLinkShapeGivesTheId() {
        for link in [id, "https://www.youtube.com/watch?v=\(id)&t=3", "https://youtu.be/\(id)?si=x", "https://www.youtube.com/embed/\(id)",
                     "https://www.youtube-nocookie.com/embed/\(id)", "https://m.youtube.com/shorts/\(id)", "https://youtube.com/live/\(id)"] {
            XCTAssertEqual(YouTubeEmbed.videoId(fromLink: link), id, link)
        }
    }

    func testAnotherHostOrAnIdThatAddsAPathIsRefused() {
        for link in ["https://evil.example/watch?v=\(id)", "https://www.youtube.com/watch?v=abc/../x", "https://www.youtube.com/playlist?list=PL",
                     "\(id)/x", "", "\"><script>"] {
            XCTAssertNil(YouTubeEmbed.videoId(fromLink: link), link)
        }
    }

    func testTheServedProviderIsRead() {
        XCTAssertEqual(YouTubeEmbed.videoId(.object(["provider": .string("youtube"), "id": .string(id)])), id)
        XCTAssertEqual(YouTubeEmbed.videoId(.object(["provider": .string("youtube"), "videoId": .string(id)])), id)
    }

    func testAMediaLinksEntryIsRead() {
        let links = JSONValue.object(["youtube": .object(["link": .string("https://youtu.be/\(id)")])])
        XCTAssertEqual(YouTubeEmbed.videoId(.object(["provider": .null, "mediaLinks": links])), id)
    }

    func testAnotherProviderHasNoVideo() {
        XCTAssertNil(YouTubeEmbed.videoId(.object(["provider": .string("vimeo"), "id": .string(id)])))
    }

    func testTheEmbedIsHttpsOnTheNoCookieHost() throws {
        let url = try XCTUnwrap(YouTubeEmbed.embedURL(videoId: id))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.youtube-nocookie.com")
        XCTAssertNil(YouTubeEmbed.embedURL(videoId: "not an id"))
    }

    func testThePageHoldsTheIframeWithAReferrer() throws {
        let page = YouTubeEmbed.page(embedURL: try XCTUnwrap(YouTubeEmbed.embedURL(videoId: id)))
        XCTAssertTrue(page.contains("<iframe src=\"https://www.youtube-nocookie.com/embed/\(id)"))
        XCTAssertTrue(page.contains("referrerpolicy=\"strict-origin-when-cross-origin\""))
    }
}

final class MobileBannerTests: XCTestCase {
    private func show(_ id: String, banner: JSONValue) -> JSONValue {
        .object(["_id": .string(id), "images": .object(["bannerMobile": banner])])
    }
    private let file = JSONValue.object(["name": .string("a.jpg"), "containerId": .string("c")])

    func testTheRecordIsFoundInsideItsList() {
        let resources = JSONValue.object(["collectionTeaser": .object(["shows": .array([show("a", banner: .null), show("b", banner: file)])])])
        XCTAssertEqual(MobileBanner.file(recordId: "b", in: resources)?.name, "a.jpg")
    }

    func testARecordWithNoMobileBannerKeepsTheCardArt() {
        let resources = JSONValue.array([show("a", banner: .null), show("b", banner: file)])
        XCTAssertNil(MobileBanner.file(recordId: "a", in: resources))
    }

    func testAnUnknownRecordFindsNothing() {
        XCTAssertNil(MobileBanner.file(recordId: "z", in: show("b", banner: file)))
    }
}

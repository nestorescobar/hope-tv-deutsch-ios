import XCTest
@testable import HopeTViOS

/// The manifest sends Font Awesome names in `tabs[].icon` (docs/PORTING.md Section 5).
final class TabIconTests: XCTestCase {
    func testEveryNameOfTheTableIsAnSFSymbol() {
        let table = ["circle-play": "play.circle", "magnifying-glass": "magnifyingglass", "video": "tv", "house": "house",
                     "clock-rotate-left": "clock.arrow.circlepath", "download": "arrow.down.circle"]
        for (name, symbol) in table {
            XCTAssertEqual(TabIcon.symbol(for: name), symbol)
            XCTAssertNotNil(UIImage(systemName: symbol), symbol)
        }
    }

    func testAnUnknownOrMissingNameIsACircle() {
        XCTAssertEqual(TabIcon.symbol(for: "no-such-icon"), "circle")
        XCTAssertEqual(TabIcon.symbol(for: nil), "circle")
    }
}

import XCTest
@testable import SymphonyBarCore

final class StatusMenuTests: XCTestCase {
    func testQuitItemUsesCommandQ() {
        XCTAssertEqual(StatusMenu.quitKeyEquivalent, "q")
        XCTAssertFalse(StatusMenu.quitTitle.isEmpty)
    }

    func testIconSymbolIsSet() {
        XCTAssertFalse(StatusMenu.iconSymbolName.isEmpty)
        XCTAssertFalse(StatusMenu.accessibilityLabel.isEmpty)
    }
}

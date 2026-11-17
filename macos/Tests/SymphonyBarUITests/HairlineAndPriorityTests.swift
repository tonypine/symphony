import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1485: the shared hairline divider and priority mark the ticket page's header composes.
@MainActor
final class HairlineAndPriorityTests: XCTestCase {
    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testAVerticalHairlineIsOnePointWideAndTheLengthItsCallerSets() {
        let size = fittingSize(HairlineDivider(.vertical, length: 14))
        XCTAssertEqual(size.width, 1, accuracy: 0.5)
        XCTAssertEqual(size.height, 14, accuracy: 0.5)
        XCTAssertEqual(fittingSize(HairlineDivider(.vertical, length: 20)).height, 20, accuracy: 0.5)
    }

    func testAHorizontalHairlineIsOnePointTallAndTakesTheWidthItIsGiven() {
        XCTAssertEqual(fittingSize(HairlineDivider().frame(width: 120)).height, 1, accuracy: 0.5)
        let set = fittingSize(HairlineDivider(.horizontal, length: 40))
        XCTAssertEqual(set.width, 40, accuracy: 0.5)
        XCTAssertEqual(set.height, 1, accuracy: 0.5)
    }

    func testThePriorityMarkReadsItsWordAndKeepsItWhole() {
        XCTAssertEqual(PriorityMark("Urgent").accessibilityText, "Priority: Urgent")
        // It never wraps or cuts: offered too little width, it still takes its own.
        let whole = fittingSize(PriorityMark("Medium")).width
        XCTAssertGreaterThan(whole, 0)
        XCTAssertEqual(fittingSize(PriorityMark("Medium").frame(minWidth: 0)).width, whole, accuracy: 0.5)
    }
}

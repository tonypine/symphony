import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1506: the catalog's Badge, Count badge, Status dot and Keyboard hint as the app draws them.
@MainActor
final class BadgeComponentsTests: XCTestCase {
    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // MARK: - Badge

    func testABadgeIsItsSizesHeightInEveryRole() {
        let heights: [(DesignTokens.Badge.Size, CGFloat)] = [(.small, 18), (.regular, 20), (.large, 24)]
        for (size, height) in heights {
            for status in DesignTokens.Status.allCases {
                XCTAssertEqual(fittingSize(Badge(status: status, size: size)).height, height, accuracy: 0.5, "\(size) \(status)")
            }
            XCTAssertEqual(fittingSize(Badge.recommended(size: size)).height, height, accuracy: 0.5, "\(size) recommended")
        }
    }

    func testABadgeSaysItsStatusWordUnlessGivenOneAndCarriesItsGlyph() {
        let badge = Badge(status: .problem)
        XCTAssertEqual(badge.word, DesignTokens.Status.problem.word)
        XCTAssertEqual(badge.symbol, DesignTokens.Status.problem.symbol)
        XCTAssertEqual(Badge(status: .working, word: "Code Review").word, "Code Review")
        XCTAssertNil(Badge(status: .idle, word: "Default", glyph: false).symbol)
        // The glyph and its gap widen the badge beside the same word without one.
        let with = fittingSize(Badge(status: .idle, word: "Default")).width
        let without = fittingSize(Badge(status: .idle, word: "Default", glyph: false)).width
        XCTAssertEqual(with - without, DesignTokens.Badge.Size.regular.glyph + DesignTokens.Badge.gap, accuracy: 0.5)
    }

    func testRecommendedIsTheAccentWithoutAGlyph() {
        let badge = Badge.recommended()
        XCTAssertEqual(badge.role, .accent)
        XCTAssertEqual(badge.word, "Recommended")
        XCTAssertNil(badge.symbol)
    }

    func testTheLargeBadgeIsSetInSixHundredAtThirteenPoints() {
        XCTAssertEqual(DesignTokens.Badge.Size.large.textSize, 13)
        XCTAssertEqual(DesignTokens.Badge.Size.large.weight, 600)
        XCTAssertEqual(DesignTokens.Badge.Size.small.textSize, 10.5)
        XCTAssertEqual(DesignTokens.Badge.Size.regular.weight, DesignTokens.TypeStyle.label.weight)
    }

    // MARK: - Count badge

    func testACountReadsUpToNinetyNineThenNinetyNinePlus() {
        XCTAssertEqual(DesignTokens.CountBadge.text(1), "1")
        XCTAssertEqual(DesignTokens.CountBadge.text(99), "99")
        XCTAssertEqual(DesignTokens.CountBadge.text(100), "99+")
        XCTAssertEqual(DesignTokens.CountBadge.text(128), "99+")
    }

    func testACountIsColouredOnlyForNeedsYouAndProblem() {
        XCTAssertEqual(CountBadge(4, role: .you).colour, .you)
        XCTAssertEqual(CountBadge(2, role: .problem).colour, .problem)
        for role in [DesignTokens.Status.working, .done, .idle, .forced] {
            XCTAssertNil(CountBadge(3, role: role).colour, "\(role)")
        }
        XCTAssertNil(CountBadge(12).colour)
    }

    func testACountOfZeroIsNotDrawn() {
        XCTAssertEqual(fittingSize(CountBadge(0, role: .you)), .zero)
        XCTAssertEqual(fittingSize(CountBadge(0, role: .you, form: .dot)), .zero)
        XCTAssertEqual(fittingSize(CountBadge(4, role: .you)).height, 18, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(fittingSize(CountBadge(1)).width, 18)
        XCTAssertEqual(fittingSize(CountBadge(4, role: .you, form: .dot)), CGSize(width: 8, height: 8))
    }

    func testACountReadsAsPartOfItsPlace() {
        XCTAssertEqual(CountBadge(4).spoken, "4 waiting")
        XCTAssertEqual(CountBadge(2, spoken: "Setup: 2 errors").spoken, "Setup: 2 errors")
        XCTAssertEqual(CountBadge.announcement(place: "Inbox", spoken: CountBadge.spoken(4)), "Inbox, 4 waiting")
    }

    // MARK: - Status dot

    func testADotIsEightOrTenPoints() {
        XCTAssertEqual(fittingSize(StatusDot(.working)), CGSize(width: 8, height: 8))
        XCTAssertEqual(fittingSize(StatusDot(.done, size: .large)), CGSize(width: 10, height: 10))
        // The live ring is drawn behind the dot and never widens it.
        XCTAssertEqual(fittingSize(StatusDot(.working, live: true)), CGSize(width: 8, height: 8))
    }

    // MARK: - Keyboard hint

    func testAHintSplitsItsKeysAndReadsThemAsWords() {
        XCTAssertEqual(DesignTokens.KeyHint.keys("⌘ ⇧ F"), ["⌘", "⇧", "F"])
        XCTAssertEqual(DesignTokens.KeyHint.keys(" 1 "), ["1"])
        XCTAssertEqual(DesignTokens.KeyHint.spoken(["⌘", "⇧", "F"]), "Command Shift F")
        XCTAssertEqual(DesignTokens.KeyHint.spoken(["⌃", "⌥", "↩"]), "Control Option Return")
        XCTAssertEqual(KeyboardHint("⌘ L").keys, ["⌘", "L"])
        XCTAssertFalse(KeyboardHint("⌘ L", plain: true).highlighted)
        XCTAssertTrue(KeyboardHint("⌘ L", plain: true, highlighted: true).highlighted)
    }

    func testAKeyCapIsTwentyPointsSquareAtLeastAndAPlainHintHasNoCap() {
        XCTAssertEqual(fittingSize(KeyboardHint("1")), CGSize(width: 20, height: 20))
        let caps = fittingSize(KeyboardHint("⌘ ⇧ F")).width
        XCTAssertGreaterThanOrEqual(caps, 3 * 20 + 2 * DesignTokens.KeyHint.gap)
        XCTAssertLessThan(fittingSize(KeyboardHint("⌘ ⇧ F", plain: true)).width, caps)
    }

    // MARK: - Fonts outside the scale

    func testAWeightBetweenNamedOnesSitsBetweenThem() {
        XCTAssertEqual(DesignTokens.TypeStyle.systemWeight(css: 600), 0.3)
        XCTAssertEqual(DesignTokens.TypeStyle.systemWeight(css: 650), 0.35, accuracy: 0.0001)
        XCTAssertEqual(DesignTokens.TypeStyle.label.systemWeight, DesignTokens.TypeStyle.systemWeight(css: 550))
    }
}

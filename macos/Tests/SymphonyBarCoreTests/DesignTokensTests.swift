import XCTest
@testable import SymphonyBarCore

/// The catalog's shared tokens (`docs/design/catalog/tokens.css`, `director-ticket-page.md` §3 and §4): control
/// sizes, state surfaces, the focus ring, the situation kinds and the motion rules with Reduce Motion.
final class DesignTokensTests: XCTestCase {
    // MARK: - Controls

    func testThreeControlSizesWithConcentricRadii() {
        XCTAssertEqual(DesignTokens.Control.allCases.map(\.height), [24, 30, 36])
        XCTAssertEqual(DesignTokens.Control.allCases.map(\.radius), [7, 9, 11])
        XCTAssertEqual(DesignTokens.Control.allCases.map(\.padding), [10, 14, 18])
        XCTAssertEqual(DesignTokens.Control.allCases.map(\.fontSize), [12, 13, 14])
    }

    // MARK: - States

    func testEachStateLaysItsSurface() {
        XCTAssertNil(DesignTokens.Interaction.rest.surface)
        XCTAssertEqual(DesignTokens.Interaction.hover.surface, .hover)
        XCTAssertEqual(DesignTokens.Interaction.press.surface, .pressed)
        XCTAssertEqual(DesignTokens.Interaction.selection.surface, .selected)
        XCTAssertNil(DesignTokens.Interaction.focus.surface)
        // Pressed wins over selected, selected over hover; a disabled control takes none.
        XCTAssertEqual(DesignTokens.Interaction(hovered: true, pressed: true, selected: true).surface, .pressed)
        XCTAssertEqual(DesignTokens.Interaction(hovered: true, selected: true).surface, .selected)
        XCTAssertNil(DesignTokens.Interaction(hovered: true, pressed: true, disabled: true).surface)
        XCTAssertNil(DesignTokens.Interaction.off.surface)
    }

    func testRingsShowForSelectionAndKeyboardFocusButNotWhenDisabled() {
        XCTAssertTrue(DesignTokens.Interaction.selection.showsSelectionRing)
        XCTAssertFalse(DesignTokens.Interaction.hover.showsSelectionRing)
        XCTAssertTrue(DesignTokens.Interaction.focus.showsFocusRing)
        XCTAssertFalse(DesignTokens.Interaction.rest.showsFocusRing)
        XCTAssertFalse(DesignTokens.Interaction(selected: true, focused: true, disabled: true).showsSelectionRing)
        XCTAssertFalse(DesignTokens.Interaction(selected: true, focused: true, disabled: true).showsFocusRing)
    }

    func testStateSurfacesMapToSystemColorsAtTheCatalogsOpacities() {
        XCTAssertEqual(DesignTokens.StateSurface.hover.color, .primary)
        XCTAssertEqual(DesignTokens.StateSurface.pressed.color, .primary)
        XCTAssertEqual(DesignTokens.StateSurface.selected.color, .accent)
        XCTAssertEqual(DesignTokens.StateSurface.allCases.map { $0.opacity(dark: false) }, [0.05, 0.09, 0.1])
        XCTAssertEqual(DesignTokens.StateSurface.allCases.map { $0.opacity(dark: true) }, [0.06, 0.1, 0.18])
        XCTAssertEqual(DesignTokens.Selection.color, .accent)
        XCTAssertEqual(DesignTokens.Selection.rowRingWidth, 1.5)
        XCTAssertEqual(DesignTokens.Selection.cardRingWidth, 2)
    }

    func testTheFocusRingIsTheAccentTwoPointsOutside() {
        XCTAssertEqual(DesignTokens.FocusRing.color, .accent)
        XCTAssertEqual(DesignTokens.FocusRing.width, 2)
        XCTAssertEqual(DesignTokens.FocusRing.offset, 2)
        XCTAssertEqual(DesignTokens.FocusRing.opacity(dark: false), 0.55)
        XCTAssertEqual(DesignTokens.FocusRing.opacity(dark: true), 0.7)
    }

    // MARK: - Situation kinds

    func testEverySituationKindHasItsGlyphColorAndWord() {
        let expected: [DesignTokens.SituationKind: (DesignTokens.Status, String, String)] = [
            .working: (.working, "circle.dotted.circle", "Working"),
            .slot: (.idle, "clock", "Waiting for a slot"),
            .ci: (.working, "circle.dotted.circle", "Waiting for CI"),
            .build: (.working, "shippingbox", "Waiting for a build"),
            .you: (.you, "person.crop.circle.badge.exclamationmark", "Waiting on you"),
            .blocked: (.idle, "lock.fill", "Blocked"),
            .paused: (.idle, "pause.circle", "Paused"),
            .retrying: (.problem, "arrow.clockwise", "Retrying"),
            .done: (.done, "checkmark.circle.fill", "Shipped"),
            .cancelled: (.idle, "circle.slash", "Cancelled"),
        ]
        XCTAssertEqual(Set(DesignTokens.SituationKind.allCases), Set(expected.keys))
        for kind in DesignTokens.SituationKind.allCases {
            let (status, symbol, word) = expected[kind]!
            XCTAssertEqual(kind.status, status, "\(kind)")
            XCTAssertEqual(kind.symbol, symbol, "\(kind)")
            XCTAssertEqual(kind.word, word, "\(kind)")
        }
    }

    func testTheFirstSituationByPrecedenceIsShown() {
        XCTAssertEqual(
            DesignTokens.SituationKind.allCases,
            [.you, .retrying, .blocked, .paused, .ci, .build, .slot, .working, .done, .cancelled]
        )
        XCTAssertEqual(DesignTokens.SituationKind.you.precedence, 0)
        XCTAssertEqual(DesignTokens.SituationKind.cancelled.precedence, 9)
        XCTAssertEqual(DesignTokens.SituationKind.shown([.working, .paused, .blocked]), .blocked)
        XCTAssertEqual(DesignTokens.SituationKind.shown([.done, .you]), .you)
        XCTAssertNil(DesignTokens.SituationKind.shown([]))
    }

    // MARK: - Motion

    func testEveryCurveHasItsTiming() {
        let expected: [DesignTokens.Motion.Curve: DesignTokens.Motion.Timing] = [
            .instant: .eased(duration: 0.1),
            .fast: .eased(duration: 0.16),
            .standard: .eased(duration: 0.28),
            .slow: .eased(duration: 0.45),
            .fold: .spring(duration: 0.5, bounce: 0.1),
            .sheet: .spring(duration: 0.5, bounce: 0.1),
            .lift: .spring(duration: 0.28, bounce: 0.1),
        ]
        XCTAssertEqual(Set(DesignTokens.Motion.Curve.allCases), Set(expected.keys))
        for curve in DesignTokens.Motion.Curve.allCases {
            XCTAssertEqual(curve.timing(reduceMotion: false), expected[curve], "\(curve)")
        }
    }

    func testReduceMotionCollapsesEveryCurveAndStopsScalingAndLifting() {
        for curve in DesignTokens.Motion.Curve.allCases {
            XCTAssertEqual(curve.timing(reduceMotion: true), .eased(duration: 0.01), "\(curve)")
        }
        XCTAssertEqual(DesignTokens.Motion.scale(DesignTokens.Motion.pressScale, pressed: true, reduceMotion: false), 0.97)
        XCTAssertEqual(DesignTokens.Motion.scale(DesignTokens.Motion.cardPressScale, pressed: true, reduceMotion: false), 0.99)
        XCTAssertEqual(DesignTokens.Motion.scale(DesignTokens.Motion.rowPressScale, pressed: true, reduceMotion: false), 0.995)
        XCTAssertEqual(DesignTokens.Motion.scale(DesignTokens.Motion.pressScale, pressed: true, reduceMotion: true), 1)
        XCTAssertEqual(DesignTokens.Motion.scale(DesignTokens.Motion.pressScale, pressed: false, reduceMotion: false), 1)
        XCTAssertEqual(DesignTokens.Motion.lift(hovered: true, reduceMotion: false), 1)
        XCTAssertEqual(DesignTokens.Motion.lift(hovered: true, reduceMotion: true), 0)
        XCTAssertEqual(DesignTokens.Motion.lift(hovered: false, reduceMotion: false), 0)
        XCTAssertEqual(DesignTokens.Motion.staggerDelay(3, reduceMotion: false), 0.105, accuracy: 1e-9)
        XCTAssertEqual(DesignTokens.Motion.staggerDelay(3, reduceMotion: true), 0)
        XCTAssertEqual(DesignTokens.Motion.staggerDelay(-1, reduceMotion: false), 0)
    }
}

import AppKit
import SwiftUI
import XCTest
import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1480's QA: what keeps the ticket page busy with nobody touching it, and a click on a run's fold.
@MainActor
final class TicketPageIdleTests: XCTestCase {
    // MARK: - A history read whole enters at once

    func testOnlyAFewEventsComingInOntoAShownTimelineEnterWithTheMotion() {
        XCTAssertTrue(TimelineSection.moves(arriving: 1, seen: 12))
        XCTAssertTrue(TimelineSection.moves(arriving: TimelineSection.enteringAtMost, seen: 12))
        // A long history read whole after the page drew: 500 rows at once would each animate and mark themselves seen.
        XCTAssertFalse(TimelineSection.moves(arriving: 500, seen: 3))
        XCTAssertFalse(TimelineSection.moves(arriving: TimelineSection.enteringAtMost + 1, seen: 12))
        // The first history of a page that drew before its feed came in.
        XCTAssertFalse(TimelineSection.moves(arriving: 2, seen: 0))
    }

    // MARK: - A click on a fold

    func testAPressReleasedWhereItBeganIsAClick() {
        XCTAssertTrue(FoldHeader<EmptyView>.isClick(.zero))
        XCTAssertTrue(FoldHeader<EmptyView>.isClick(CGSize(width: FoldHeader<EmptyView>.clickSlop, height: -FoldHeader<EmptyView>.clickSlop)))
        XCTAssertFalse(FoldHeader<EmptyView>.isClick(CGSize(width: 0, height: 30)))
        XCTAssertFalse(FoldHeader<EmptyView>.isClick(CGSize(width: -12, height: 0)))
    }

    // MARK: - The working pulses run on Core Animation

    func testThePulseRunsForeverThereAndBack() throws {
        let breath = try XCTUnwrap(LayerPulse.animation(StepBars.breath, duration: StepBars.breathDuration) as? CABasicAnimation)
        XCTAssertEqual(breath.keyPath, "opacity")
        XCTAssertEqual(breath.fromValue as? Double, 1)
        XCTAssertEqual(breath.toValue as? Double, 0.45)
        XCTAssertEqual(breath.duration, 0.9)
        XCTAssertTrue(breath.autoreverses)
        XCTAssertEqual(breath.repeatCount, .infinity)
        XCTAssertFalse(breath.isRemovedOnCompletion)

        let scale = try XCTUnwrap(LayerPulse.animation(.scale(from: 1.6, to: 2.2), duration: 1.2) as? CABasicAnimation)
        XCTAssertEqual(scale.keyPath, "transform.scale")
        XCTAssertEqual(scale.fromValue as? Double, 1.6)
        XCTAssertEqual(scale.toValue as? Double, 2.2)
        XCTAssertEqual(scale.duration, 1.2)
    }

    func testTheLiveDotSendsARingOutEveryPeriodAndWaits() throws {
        let ring = try XCTUnwrap(
            LayerPulse.animation(StatusDot.ring, duration: DesignTokens.StatusDot.ringPeriod) as? CAAnimationGroup
        )
        XCTAssertEqual(ring.duration, 1.8)
        XCTAssertEqual(ring.repeatCount, .infinity)
        XCTAssertFalse(ring.autoreverses)
        XCTAssertFalse(ring.isRemovedOnCompletion)
        let tracks = try XCTUnwrap(ring.animations as? [CAKeyframeAnimation])
        XCTAssertEqual(tracks.map(\.keyPath), ["transform.scale", "opacity"])
        XCTAssertEqual(tracks[0].values as? [Double], [1, 2.6, 2.6])
        XCTAssertEqual(tracks[1].values as? [Double], [0.6, 0, 0])
        XCTAssertEqual(tracks[0].keyTimes?.map(\.doubleValue), [0, 0.7, 1])
        XCTAssertEqual(tracks[1].duration, 1.8)
    }

    func testTheLiveDotRingsOnlyWhileLiveAndReduceMotionIsOff() {
        XCTAssertTrue(StatusDot.rings(live: true, reduceMotion: false))
        XCTAssertFalse(StatusDot.rings(live: true, reduceMotion: true))
        XCTAssertFalse(StatusDot.rings(live: false, reduceMotion: false))
    }

    func testThePulseViewStartsItsAnimationOnceAndAgainWhenItsMotionChanges() throws {
        let view = LayerPulseView(frame: CGRect(x: 0, y: 0, width: 14, height: 4))
        let bar = LayerPulse(shape: .capsule, color: .green, motion: StepBars.breath, duration: StepBars.breathDuration)
        view.configure(bar)
        let first = try XCTUnwrap(view.shapeLayer.animation(forKey: LayerPulseView.animationKey) as? CABasicAnimation)
        XCTAssertEqual(first.keyPath, "opacity")

        // The page drawing again hands it the same pulse: the running animation stays as it is.
        view.configure(bar)
        XCTAssertTrue(view.shapeLayer.animation(forKey: LayerPulseView.animationKey) === first)
        view.viewDidMoveToWindow()
        XCTAssertTrue(view.shapeLayer.animation(forKey: LayerPulseView.animationKey) === first)

        // Another motion replaces it.
        view.configure(LayerPulse(shape: .circle, color: .green, motion: StatusDot.ring, duration: DesignTokens.StatusDot.ringPeriod))
        let second = try XCTUnwrap(view.shapeLayer.animation(forKey: LayerPulseView.animationKey) as? CAAnimationGroup)
        XCTAssertEqual(second.duration, 1.8)
        XCTAssertEqual(view.pulse?.shape, .circle)
    }

    func testThePulseViewCentresItsShapeTakesItsColourAndLetsClicksThrough() {
        let view = LayerPulseView(frame: CGRect(x: 0, y: 0, width: 14, height: 4))
        XCTAssertTrue(view.wantsUpdateLayer)
        // No pulse yet: nothing to colour.
        view.updateLayer()
        XCTAssertNil(view.shapeLayer.backgroundColor)

        view.configure(LayerPulse(shape: .capsule, color: .red, motion: StepBars.breath, duration: StepBars.breathDuration))
        view.layout()
        XCTAssertEqual(view.shapeLayer.bounds.size, CGSize(width: 14, height: 4))
        XCTAssertEqual(view.shapeLayer.position, CGPoint(x: 7, y: 2))
        XCTAssertEqual(view.shapeLayer.cornerRadius, 2)
        view.updateLayer()
        XCTAssertNotNil(view.shapeLayer.backgroundColor)
        XCTAssertNil(view.hitTest(CGPoint(x: 7, y: 2)))
    }

    func testTwoPulsesCompareByWhatTheyDraw() {
        let pulse = LayerPulse(shape: .capsule, color: .blue, motion: StepBars.breath, duration: StepBars.breathDuration)
        XCTAssertEqual(pulse, LayerPulse(shape: .capsule, color: .blue, motion: StepBars.breath, duration: StepBars.breathDuration))
        XCTAssertNotEqual(pulse.motion, StatusDot.ring)
    }
}

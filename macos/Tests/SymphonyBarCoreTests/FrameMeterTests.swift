import Foundation
@testable import SymphonyBarCore
import XCTest

/// The frame count behind the ticket page scroll test (TP-1491): late ticks are hitch time and dropped frames.
final class FrameMeterTests: XCTestCase {
    private let frame = 1.0 / 60

    private func meter(_ gaps: [Double], frame: Double? = nil) -> FrameMeter {
        var meter = FrameMeter()
        var time = 100.0
        meter.record(time, frame: frame ?? self.frame)
        for gap in gaps {
            time += gap
            meter.record(time, frame: frame ?? self.frame)
        }
        return meter
    }

    func testTicksOnTimeAreNoHitch() {
        let summary = meter(Array(repeating: frame, count: 60)).summary
        XCTAssertEqual(summary.frames, 61)
        XCTAssertEqual(summary.seconds, 1, accuracy: 1e-9)
        XCTAssertEqual(summary.hitchMs, 0)
        XCTAssertEqual(summary.dropped, 0)
        XCTAssertEqual(summary.hitchRatio, 0)
        XCTAssertEqual(summary.frameMs, 1000.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(summary.longestMs, 1000.0 / 60, accuracy: 1e-9)
    }

    func testAJitterUnderHalfAFrameIsNoHitch() {
        let summary = meter([frame * 1.4, frame * 0.6]).summary
        XCTAssertEqual(summary.hitchMs, 0)
        XCTAssertEqual(summary.dropped, 0)
    }

    func testALateTickCountsTheTimePastOneFrameAndTheFramesItMissed() {
        // 100 ms busy: 6 frames' time, one shown, five dropped, 83.3 ms late.
        let summary = meter([frame, 0.1, frame]).summary
        XCTAssertEqual(summary.dropped, 5)
        XCTAssertEqual(summary.hitchMs, 100 - 1000.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(summary.longestMs, 100, accuracy: 1e-6)
        XCTAssertEqual(summary.hitchRatio, summary.hitchMs / summary.seconds, accuracy: 1e-9)
    }

    func testTheDisplaysOwnFrameIsUsedAndANonPositiveOneKeepsTheLast() {
        var meter = FrameMeter()
        meter.record(10, frame: 1.0 / 120)
        meter.record(10 + 1.0 / 60, frame: 0)
        XCTAssertEqual(meter.frame, 1.0 / 120, accuracy: 1e-12)
        // One 120 Hz frame dropped in a 60 Hz gap.
        XCTAssertEqual(meter.summary.dropped, 1)
        XCTAssertEqual(meter.summary.hitchMs, 1000.0 / 120, accuracy: 1e-6)
    }

    func testNoTicksIsAnEmptySummary() {
        let summary = FrameMeter().summary
        XCTAssertEqual(summary.frames, 0)
        XCTAssertEqual(summary.seconds, 0)
        XCTAssertEqual(summary.hitchRatio, 0)
        XCTAssertEqual(summary.frameMs, 1000.0 / 60, accuracy: 1e-9)
    }

    func testTheSummaryIsWrittenWithTheKeysTheScrollTestReads() throws {
        let data = try meter([frame, 0.05]).json()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["frames", "seconds", "frame_ms", "hitch_ms", "dropped", "longest_ms", "hitch_ratio"]
        )
        XCTAssertEqual(try JSONDecoder().decode(FrameMeter.Summary.self, from: data), meter([frame, 0.05]).summary)
        XCTAssertEqual(FrameMeter.fileName, "frames.json")
    }
}

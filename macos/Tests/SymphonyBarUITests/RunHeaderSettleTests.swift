import AppKit
import SwiftUI
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// TP-1466: the ticket page with a working run laid itself out forever once it re-read the ticket, so it answered no
/// accessibility read, no scroll and no key. QA's main-thread sample named the run now's header, whose `ViewThatFits`
/// tore down and rebuilt the losing line's views on every pass. The header now places one copy of its parts.
@MainActor
final class RunHeaderSettleTests: XCTestCase {
    /// An `NSHostingView` that counts its layout passes.
    private final class CountingHost<Content: View>: NSHostingView<Content> {
        var layouts = 0

        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    /// The run now as one read of the ticket gives it: working on its tests, `minutes` in.
    private func read(minutes: Int, lines: Int) -> RunGroupModel {
        let said = (0..<lines).map { TranscriptLine(kind: .say, text: "Line \($0)", at: "2026-11-11T12:00:0\($0 % 10)Z") }
        return RunGroupModel(
            id: "run-4", title: "Implementation run 4", state: .running, word: "Running",
            durationSeconds: minutes * 60, tokens: 12_400 * minutes, model: "claude-opus-5-5 · high",
            steps: [
                RunStep(id: "code", stepID: "code", title: "Write the code", state: .done, durationSeconds: 300),
                RunStep(id: "tests", stepID: "tests", title: "Tests", state: .current, liveLines: said),
            ]
        )
    }

    /// The run in a vertical scroll view, as the ticket page's timeline has it, with animations off: the working dot
    /// and step bar breathe forever, which lays the host out on every frame by design and isn't what this checks.
    private func page(_ run: RunGroupModel, transcripts: StepTranscripts) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                RunGroup(run: run, transcripts: transcripts)
            }
            .padding(16)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Renders the page `width` wide, publishes two reads of the working run, and checks no layout pass follows.
    private func assertSettles(width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let transcripts = StepTranscripts(get: { _ in .unreachable })
        let host = CountingHost(rootView: page(read(minutes: 9, lines: 2), transcripts: transcripts))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        host.layoutSubtreeIfNeeded()
        spin(0.2)

        host.rootView = page(read(minutes: 10, lines: 3), transcripts: transcripts)
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        host.rootView = page(read(minutes: 11, lines: 4), transcripts: transcripts)
        host.layoutSubtreeIfNeeded()
        spin(0.3)

        let settled = host.layouts
        spin(0.5)
        XCTAssertEqual(host.layouts, settled, "the page kept laying itself out after the second read", file: file, line: line)
        XCTAssertFalse(host.needsLayout, file: file, line: line)
    }

    func testTheRunNowSettlesAfterTwoReadsInAWideColumn() {
        assertSettles(width: 900)
    }

    func testTheRunNowSettlesAfterTwoReadsInAColumnTooNarrowForOneLine() {
        assertSettles(width: 360)
    }

    func testTheFactsShareTheLineOnlyWhenBothPartsFitWhole() {
        let gap = RunHeaderLayout.gap
        XCTAssertTrue(RunHeaderLayout.fitsOneLine(lead: 300, facts: 100, width: 400 + gap))
        XCTAssertFalse(RunHeaderLayout.fitsOneLine(lead: 300, facts: 100, width: 399 + gap))
        XCTAssertTrue(RunHeaderLayout.fitsOneLine(lead: 300, facts: 0, width: 300))
        XCTAssertFalse(RunHeaderLayout.fitsOneLine(lead: 300, facts: 0, width: 299))
        XCTAssertTrue(RunHeaderLayout.fitsOneLine(lead: 300, facts: 100, width: nil))
        XCTAssertTrue(RunHeaderLayout.fitsOneLine(lead: 300, facts: 100, width: .infinity))
    }
}

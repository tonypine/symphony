import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// The Conductor's message as the views draw it: the phrases' fonts and colours, and the shapes' sizes.
@MainActor
final class ConductorMessageViewsTests: XCTestCase {
    private func runs(_ text: String, bold: Bool = false) -> [(text: String, run: AttributedString.Runs.Element)] {
        let phrases = ConductorMarkup.phrases(in: text)
        let attributed = ConductorMarkupText.attributed(phrases, style: .reading, bold: bold)
        return attributed.runs.map { (String(attributed[$0.range].characters), $0) }
    }

    func testAStatusPhraseTakesItsStatusTextColour() throws {
        let runs = runs("the {problem}build{/} and {done}tests{/} and {you}you{/}")
        func colour(of word: String) throws -> Color? { runs.first { $0.text == word }?.run.foregroundColor }
        XCTAssertEqual(try colour(of: "build"), DesignTokens.Status.problem.text)
        XCTAssertEqual(try colour(of: "tests"), DesignTokens.Status.done.text)
        XCTAssertEqual(try colour(of: "you"), DesignTokens.Status.you.text)
        XCTAssertNil(try colour(of: "the "), "plain words take the colour the paragraph gives them")
    }

    func testALinkIsALinkInTheAccentTextColour() throws {
        let link = try XCTUnwrap(runs("see [the finding](https://example.com/f)").first { $0.text == "the finding" })
        XCTAssertEqual(link.run.link, URL(string: "https://example.com/f"))
        XCTAssertEqual(link.run.foregroundColor, DesignTokens.ColorToken.accentText.color)
    }

    func testInlineCodeIsMonoOnTheHoverSurface() throws {
        let code = try XCTUnwrap(runs("run `make all` now").first { $0.text == "make all" })
        XCTAssertEqual(code.run.backgroundColor, DesignTokens.StateSurface.hover.color.color)
    }

    func testCodeLinesTakeTheirChangesColour() {
        XCTAssertEqual(ConductorCodeBlock.color(.added), DesignTokens.Status.done.text)
        XCTAssertEqual(ConductorCodeBlock.color(.removed), DesignTokens.Status.problem.text)
        XCTAssertEqual(ConductorCodeBlock.color(.unchanged), DesignTokens.TextColor.primary.color)
    }

    func testTheMarkIsTwentyEightPointsBetweenRunsAndEighteenInsideOne() {
        XCTAssertEqual(ConductorMark.Size.regular.side, 28)
        XCTAssertEqual(ConductorMark.Size.small.side, 18)
        XCTAssertGreaterThan(ConductorMark.Size.regular.ring, 0)
        XCTAssertEqual(ConductorMark.Size.small.ring, 0)
    }

    func testTheMessageReadsInItsOwnMeasure() {
        XCTAssertGreaterThan(ConductorVoice.measure, CGFloat(DesignTokens.Measure.reading), "16 pt characters are wider than 13 pt")
    }

    func testAQuietLineAndASteerAreOneAccessibilityElementEach() {
        let quiet = ConductorMessage(id: "q", at: nil, text: "Leaving the run to fix it.", watch: ConductorWatch(runID: "r"))
        let steer = ConductorMessage(id: "s", at: nil, text: "Look at `a.swift`.", watch: ConductorWatch(runID: "r", steered: true, when: "now"))
        XCTAssertTrue(quiet.accessibilityLabel(time: "09:02").hasPrefix("Conductor"))
        XCTAssertEqual(steer.accessibilityLabel(time: "09:04"), "Conductor, steered this run, now, 09:04, Look at a.swift.")
        for message in [quiet, steer] {
            let host = NSHostingView(rootView: ConductorRunNote(message: message).frame(width: 600))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }
}

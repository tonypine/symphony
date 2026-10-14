import AppKit
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// The chips (N1) in the plan, pull request, clarify and blocked reviews and on the ticket page (TP-988), read from
/// the `inbox-decision` fixture as the views lay out each text.
final class ReviewChipsTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 13)
    /// A ticket identifier or a pull request number, as the Director reads them.
    private let mentionPattern = try! NSRegularExpression(pattern: #"[A-Z]+-\d+|#\d+"#)

    func testEveryTicketAndPullRequestInThePlanReviewIsAChip() throws {
        let item = try item("TP-923")
        let brief = try parsedBrief(item)
        XCTAssertEqual(try chips(in: [item.ask] + briefTexts(brief), of: item), ["TP-947", "TP-923", "TP-923"])
    }

    func testEveryTicketAndPullRequestInThePullRequestReviewIsAChip() throws {
        let item = try item("TP-895")
        let brief = try parsedBrief(item)
        // The line that is only the pull request's link stays a link (`LinkText`), not a chip.
        let lines = brief.whatToReview.filter { line in line.links.first?.label != line.text }
        XCTAssertEqual(lines.count, 1)
        var texts = [item.ask] + lines.map(\.text) + brief.whatChanged
        texts += brief.moves.map(\.text)
        XCTAssertEqual(try chips(in: texts, of: item), ["PR #451", "#448", "TP-892", "#448", "TP-895", "PR #451", "PR #451", "TP-895"])
    }

    func testEveryTicketAndPullRequestInTheClarifyReviewIsAChip() throws {
        let item = try item("TP-896")
        let clarify = try XCTUnwrap(item.review.clarify)
        let texts = [item.ask] + [try XCTUnwrap(clarify.found)] + clarify.questions + [clarify.nextLine]
        XCTAssertEqual(try chips(in: texts, of: item), ["TP-896", "#448", "TP-892", "#448"])
    }

    func testEveryTicketAndPullRequestInTheBlockedReviewIsAChip() throws {
        let item = try item("TP-897")
        let blocked = try XCTUnwrap(item.review.blocked)
        let texts = [item.ask, try XCTUnwrap(blocked.reason), blocked.nextLine]
        XCTAssertEqual(try chips(in: texts, of: item), ["#448", "TP-897", "TP-892"])
    }

    func testTheTicketPagesBriefAndHistoryHaveChips() throws {
        let items = try fixtureItems()
        let brief = try XCTUnwrap(TicketPage.Brief(identifier: "TP-892", items: items))
        let texts = brief.paragraphs + brief.decisions.compactMap(\.title) + brief.decisions.compactMap(\.answer)
            + [try XCTUnwrap(brief.summary)]
        let keys = try chips(in: texts, references: brief.references)
        XCTAssertTrue(keys.contains("#448"), "the brief's #448")
        XCTAssertEqual(keys.last, "TP-880", "the earlier decision's answer")
    }

    func testTextWithNoReferencesIsPlainTextAsBefore() throws {
        XCTAssertNil(ChipTextContent.chips("TP-892 waits on #448.", references: [:]))
        XCTAssertNil(ChipTextContent.chips("TP-892 waits on #448.", references: [:], lead: "Approve:"))
        let item = try item("TP-897")
        let content = try XCTUnwrap(ChipTextContent.chips("TP-892 waits on #448.", references: item.references, lead: "Approve:"))
        XCTAssertEqual(content, ChipTextContent("TP-892 waits on #448.", references: item.references, lead: "Approve:"))
        XCTAssertEqual(content.mentions.map(\.key), ["TP-892", "#448"])
    }

    func testCopyingASentenceOfABlockedReasonKeepsItsIdentifiersInPlace() throws {
        let item = try item("TP-897")
        let reason = try XCTUnwrap(item.review.blocked?.reason)
        let view = ChipTextView(content: try XCTUnwrap(ChipTextContent.chips(reason, references: item.references)), style: ChipTextStyle(font: font))
        view.setFrameSize(CGSize(width: 320, height: view.height(forWidth: 320)))
        let whole = NSRange(location: 0, length: (reason as NSString).length)
        XCTAssertEqual(view.copiedText(for: whole), reason)
        view.setSelectedRange((reason as NSString).range(of: "so TP-897 can't post TP-892's QA screenshots"))
        XCTAssertEqual(view.copiedSelection, "so TP-897 can't post TP-892's QA screenshots")
    }

    func testCopyingAMoveWithItsLeadKeepsThePullRequestInPlace() throws {
        let item = try item("TP-895")
        let move = try XCTUnwrap(parsedBrief(item).moves.first)
        let view = ChipTextView(
            content: try XCTUnwrap(ChipTextContent.chips(move.text, references: item.references, lead: "Approve:")),
            style: ChipTextStyle(font: font)
        )
        XCTAssertEqual(view.copiedText(for: NSRange(location: 0, length: (view.content.source as NSString).length)),
                       "Approve: move TP-895 to Merging; Symphony merges PR #451.")
    }

    // MARK: - Helpers

    /// The keys of the chips in `texts`, in reading order. Each text's every ticket identifier and pull request number
    /// sits in a resolved chip that never splits across lines, at the review's width beside the list and in a narrow
    /// pane.
    private func chips(in texts: [String], of item: InboxItem) throws -> [String] {
        try chips(in: texts, references: item.references)
    }

    private func chips(in texts: [String], references: [String: Reference]) throws -> [String] {
        var keys: [String] = []
        for text in texts {
            let content = try XCTUnwrap(ChipTextContent.chips(text, references: references))
            XCTAssertFalse(content.mentions.contains(where: \.isMissing), text)
            for match in mentionPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                XCTAssertTrue(content.mentions.contains { NSIntersectionRange($0.range, match.range) == match.range },
                              "\((text as NSString).substring(with: match.range)) isn't a chip in: \(text)")
            }
            let view = ChipTextView(content: content, style: ChipTextStyle(font: font))
            for width in [1200.0 - 340, 400] {
                view.setFrameSize(CGSize(width: width, height: view.height(forWidth: width)))
                for index in content.mentions.indices {
                    XCTAssertEqual(view.chipRects(index).count, 1, "\(content.mentions[index].key) splits at \(width) pt in: \(text)")
                }
            }
            keys += content.mentions.map(\.key)
        }
        return keys
    }

    /// The parsed brief's texts the review draws as paragraphs: What to review, What changed and the moves.
    private func briefTexts(_ brief: InboxReview.ParsedBrief) -> [String] {
        brief.whatToReview.map(\.text) + brief.whatChanged + brief.moves.map(\.text)
    }

    private func parsedBrief(_ item: InboxItem) throws -> InboxReview.ParsedBrief {
        guard case let .parsed(brief)? = item.review.brief else {
            return try XCTUnwrap(nil as InboxReview.ParsedBrief?, "\(item.identifier) has no parsed brief")
        }
        return brief
    }

    private func item(_ identifier: String) throws -> InboxItem {
        try XCTUnwrap(try fixtureItems().first { $0.identifier == identifier })
    }

    private func fixtureItems() throws -> [InboxItem] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/inbox-decision/api/v1/inbox.json")
        return try XCTUnwrap(InboxPayload.decode(Data(contentsOf: url))?.items)
    }
}

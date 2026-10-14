import Foundation
import XCTest
@testable import SymphonyBarCore

final class MentionsTests: XCTestCase {
    private let ticket = Reference.ticket(.init(identifier: "TP-891", title: "Remove the retired review states and the version switch from the code", state: "Code Review"))
    private let pullRequest = Reference.pullRequest(.init(number: 448, title: "Remove the Final verification and Supervisor check flows", reviewState: .changesRequested, reviewRounds: 2))

    private func found(_ text: String, _ references: [String: Reference]) -> [String] {
        Mentions.find(in: text, references: references).map { (text as NSString).substring(with: $0.range) }
    }

    func testTheLongestMentionWinsWhereTwoOverlap() {
        let mentions = Mentions.find(in: "Code Review sent PR #448 back.", references: ["#448": pullRequest, "PR #448": pullRequest])
        XCTAssertEqual(mentions.map(\.key), ["PR #448"])
        XCTAssertEqual(mentions.first?.range, NSRange(location: 17, length: 7))
        XCTAssertEqual(mentions.first?.kind, .pullRequest)
        XCTAssertFalse(mentions.first?.isMissing ?? true)
    }

    func testAMentionAtTheStartAndAtTheEndOfTheText() {
        XCTAssertEqual(found("TP-891 deletes them, then #448", ["TP-891": ticket, "#448": pullRequest]), ["TP-891", "#448"])
        XCTAssertEqual(Mentions.find(in: "TP-891", references: ["TP-891": ticket]).first?.range, NSRange(location: 0, length: 6))
    }

    func testPunctuationAfterAMentionStaysOutOfIt() {
        XCTAssertEqual(found("Leave them to TP-891. Or #448, or (TP-891)!", ["TP-891": ticket, "#448": pullRequest]), ["TP-891", "#448", "TP-891"])
    }

    func testAMentionInsideALongerWordIsNotThatMention() {
        let mentions = Mentions.find(in: "TP-8910 and XTP-891 and TP-891-b and a#448 and &#448", references: ["TP-891": ticket, "#448": pullRequest])
        // Two other identifiers, which the references don't hold.
        XCTAssertEqual(mentions.map(\.key), ["TP-8910", "XTP-891"])
        XCTAssertTrue(mentions.allSatisfy(\.isMissing))
    }

    func testWithoutReferencesTheMentionsAreFoundAndMissing() {
        let mentions = Mentions.find(in: "TP-892 waits on PR #448.", references: [:])
        XCTAssertEqual(mentions.map(\.key), ["TP-892", "PR #448"])
        XCTAssertEqual(mentions.map(\.kind), [.ticket, .pullRequest])
        XCTAssertTrue(mentions.allSatisfy(\.isMissing))
        XCTAssertEqual(mentions.first?.accessibilityLabel, "TP-892, Symphony can't see it")
        XCTAssertEqual(Mentions.find(in: "Nothing to see here.", references: [:]), [])
    }

    func testAReferenceSymphonyCouldNotReadIsMissingWithItsLink() {
        let url = URL(string: "https://linear.app/t/issue/TP-999")
        let mention = Mentions.find(in: "See TP-999.", references: ["TP-999": .missing(url: url)]).first
        XCTAssertEqual(mention?.isMissing, true)
        XCTAssertEqual(mention?.reference.url, url)
    }

    func testAReferenceKeyThePatternMissesIsFoundByItsKey() {
        XCTAssertEqual(found("Merged in PR#448 today.", ["PR#448": pullRequest]), ["PR#448"])
    }

    func testATicketsShortNameInBracketsJoinsItsChip() {
        let text = "TP-891 (Remove the retired review states) deletes them."
        let mention = Mentions.find(in: text, references: ["TP-891": ticket]).first
        XCTAssertEqual(mention?.shortName, "Remove the retired review states")
        XCTAssertEqual(mention?.range, NSRange(location: 0, length: 41))
        XCTAssertEqual(mention?.chipText, "TP-891 · Remove the retired review states")
        XCTAssertEqual((mention?.chipText as NSString?)?.length, mention?.range.length)
        XCTAssertEqual(mention?.accessibilityLabel, "TP-891, Remove the retired review states, Code Review")
    }

    func testBracketsThatAreNotAShortNameStayText() {
        XCTAssertNil(Mentions.find(in: "TP-891 (see (this)) and TP-891  (two spaces)", references: ["TP-891": ticket]).first?.shortName)
        XCTAssertNil(Mentions.find(in: "#448 (the PR)", references: ["#448": pullRequest]).first?.shortName)
        // A bracket holding the next mention stays out of the chip, so the two never overlap.
        let mentions = Mentions.find(in: "TP-891 (TP-880)", references: ["TP-891": ticket])
        XCTAssertEqual(mentions.map(\.key), ["TP-891", "TP-880"])
        XCTAssertNil(mentions.first?.shortName)
    }

    func testEachKindReadsForVoiceOver() {
        let mentions = Mentions.find(in: "TP-891 and #448", references: ["TP-891": ticket, "#448": pullRequest])
        XCTAssertEqual(mentions.map(\.accessibilityLabel), [
            "TP-891, Remove the retired review states and the version switch from the code, Code Review",
            "PR #448, Remove the Final verification and Supervisor check flows, Changes asked",
        ])
        XCTAssertEqual(
            [.open, .changesRequested, .approved, .merged, .closed].map { (state: Reference.PullRequest.ReviewState) in state.word },
            ["Open", "Changes asked", "Approved", "Merged", "Closed"]
        )
    }

    func testTheDecisionFixtureFindsEveryMentionInItsQuestionStoryAndOptions() throws {
        let item = try XCTUnwrap(decisionItem())
        let action = try XCTUnwrap(item.review.action)
        let question = Mentions.find(in: action.question ?? "", references: item.references)
        XCTAssertEqual(question.map(\.chipText), [
            "TP-892 · Retire two old review steps", "TP-891 · Remove the retired review states", "TP-892", "TP-891",
        ])
        XCTAssertEqual(question[1].accessibilityLabel, "TP-891, Remove the retired review states, Code Review")
        XCTAssertEqual(Mentions.find(in: action.why ?? "", references: item.references).map(\.key), ["#448", "TP-880", "TP-891"])
        XCTAssertEqual(Mentions.find(in: action.ifUnanswered ?? "", references: item.references).map(\.key), ["TP-892", "TP-893", "TP-892"])
        let options = action.options.flatMap { option in
            ([option.label, option.effect ?? ""] + option.tradeoffs.map(\.text)).flatMap { Mentions.find(in: $0, references: item.references) }
        }
        XCTAssertFalse(options.isEmpty)
        XCTAssertFalse(options.contains(where: \.isMissing))
        XCTAssertEqual(Set(options.map(\.key)), ["TP-891", "TP-892", "TP-893"])
    }

    func decisionItem() throws -> InboxItem? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/inbox-decision/api/v1/inbox.json")
        return try InboxPayload.decode(Data(contentsOf: url))?.items.first { $0.identifier == "TP-892" }
    }
}

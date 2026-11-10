import XCTest
@testable import SymphonyBarCore

/// The Send of a Question block and of the decision sheet (the catalog's Question block and Decision sheet): what it
/// says, the answer it repeats, and why it stays off.
final class QuestionSendTests: XCTestCase {
    /// Two options, neither recommended, so nothing is picked to start with.
    private let open = InboxReview.Action(
        question: "Close TP-612 as a duplicate?", steps: [],
        options: [.init(label: "Close as duplicate", effect: "TP-612 moves to Done.", recommended: false), .init(label: "Keep it open", effect: nil, recommended: false)],
        commentID: "c-1"
    )
    /// The same with its second option recommended, so it starts picked.
    private var recommended: InboxReview.Action {
        var action = open
        action.options[1].recommended = true
        return action
    }

    func testSendStaysOffUntilAnAnswerIsPickedThenRepeatsIt() {
        let none = QuestionSend(question: open, picks: DecisionPicks())
        XCTAssertFalse(none.enabled)
        XCTAssertEqual(none.refusal, "Pick an answer first.")
        XCTAssertNil(none.answer)
        XCTAssertEqual(none.title, "Send Decision…")
        XCTAssertNil(none.progress)

        let picked = QuestionSend(question: open, picks: DecisionPicks(picks: [0: 0]))
        XCTAssertTrue(picked.enabled)
        XCTAssertNil(picked.refusal)
        XCTAssertEqual(picked.answer, "Close as duplicate")
        XCTAssertEqual(picked.answered, 1)
        XCTAssertEqual(picked.total, 1)

        // The recommended option is picked to start with, so Send is on at once.
        XCTAssertEqual(QuestionSend(question: recommended, picks: DecisionPicks()).answer, "Keep it open")
    }

    func testTheOwnWordsCardNeedsWordsBeforeSendTurnsOn() {
        let writeIn = open.writeInIndex
        let blank = QuestionSend(question: open, picks: DecisionPicks(picks: [0: writeIn], writeIn: "  \n"))
        XCTAssertEqual(blank.refusal, "Write your answer first.")
        XCTAssertFalse(blank.enabled)

        let written = QuestionSend(question: open, picks: DecisionPicks(picks: [0: writeIn], writeIn: "Merge it into TP-612 instead."))
        XCTAssertTrue(written.enabled)
        XCTAssertEqual(written.answer, "In your own words")
    }

    func testAQuestionAnswersByItsPlaceInThePicks() {
        let picks = DecisionPicks(picks: [2: 1])
        XCTAssertEqual(QuestionSend(question: open, decision: 2, picks: picks).answer, "Keep it open")
        XCTAssertEqual(QuestionSend(question: open, decision: 0, picks: picks).refusal, "Pick an answer first.")
        XCTAssertTrue(open.isWriteIn(DecisionPicks(picks: [1: open.writeInIndex]), decision: 1))
        XCTAssertFalse(open.isWriteIn(DecisionPicks(picks: [1: open.writeInIndex])))
    }

    func testTheSheetsSendCountsWhatIsAnsweredAndLeavesTheRestOpen() {
        let questions = [open, open]
        let none = QuestionSend(questions: questions, picks: DecisionPicks())
        XCTAssertEqual(none.refusal, "Answer at least one question first.")
        XCTAssertEqual(none.progress, "Answered 0 of 2")
        XCTAssertEqual(none.title, "Send Decision…")
        XCTAssertNil(none.answer)

        let one = QuestionSend(questions: questions, picks: DecisionPicks(picks: [0: 1]))
        XCTAssertTrue(one.enabled)
        XCTAssertEqual(one.progress, "Answered 1 of 2")
        XCTAssertEqual(one.title, "Send Decision…")
        XCTAssertNil(one.answer)

        let both = QuestionSend(questions: questions, picks: DecisionPicks(picks: [0: 1, 1: open.writeInIndex], writeIns: [1: "Ask TP-612's author."]))
        XCTAssertEqual(both.answered, 2)
        XCTAssertEqual(both.title, "Send 2 Decisions…")

        // A question with no options has nothing to pick.
        XCTAssertEqual(QuestionSend(question: InboxReview.Action(steps: ["Add the key."], options: []), picks: DecisionPicks()).refusal, "Pick an answer first.")
    }

    func testTheSheetsHeaderAndKickersCountItsQuestions() {
        XCTAssertEqual(DecisionSheetLayout.title(count: 1), "Your decision")
        XCTAssertEqual(DecisionSheetLayout.title(count: 2), "2 decisions wait on you")
        XCTAssertNil(DecisionSheetLayout.kicker(index: 0, count: 1))
        XCTAssertEqual(DecisionSheetLayout.kicker(index: 1, count: 2), "Question 2 of 2")
        XCTAssertLessThan(DecisionSheetLayout.laptopWidth, DecisionSheetLayout.desktopWidth)
    }
}

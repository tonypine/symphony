import Foundation
import XCTest
@testable import SymphonyBarCore

/// Answering a Question from the ticket page (TP-1450), with the `ticket-page` fixture server: TP-1245 waits on your
/// answer; Send on the page picks the Inbox's item, opens the Inbox's consequence sheet and sends its `decide`; then the
/// page and the Inbox both read the answer from Symphony, not from what the app holds.
final class TicketPageAnswerTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var root: URL!
    private var fixtures: APIFixtures!

    private static var director: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/ticket-page", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = uniqueTemporaryDirectory("ticket-page-answer")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixtures = APIFixtures(directory: Self.director, requestLog: root.appendingPathComponent("api-requests.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A GET as the window's client makes it, answered by the fixtures.
    private func get(_ path: String, from fixtures: APIFixtures) throws -> Data {
        let url = try XCTUnwrap(URL(string: path, relativeTo: APIFixtures.baseURL))
        let (data, response) = fixtures.answer(URLRequest(url: url))
        XCTAssertEqual(response.statusCode, 200, path)
        return data
    }

    /// What the window reads for TP-1245's page and the Inbox.
    private func read(_ fixtures: APIFixtures) throws -> (page: TicketPage, items: [InboxItem]) {
        let identifier = "TP-1245"
        let events = try get(TicketPage.eventsPath(identifier, repoKey: "symphony"), from: fixtures)
        let page = TicketPage(
            identifier: identifier,
            sources: TicketPage.Sources(
                state: try get("api/v1/state", from: fixtures),
                issue: try get(TicketPage.issuePath(identifier), from: fixtures),
                events: TicketEventsPayload.decode(events)
            ),
            timeZone: utc
        )
        let items = try XCTUnwrap(InboxPayload.decode(get(InboxPayload.path, from: fixtures))).items
        return (page, items)
    }

    private func send(_ action: ControlAction, to fixtures: APIFixtures) -> ControlResult {
        let (data, response) = fixtures.answer(ControlAPI.request(action, base: APIFixtures.baseURL, token: APIFixtures.token))
        return ControlAPI.result(action, statusCode: response.statusCode, data: data)
    }

    func testSendOnThePageSendsTheInboxsDecideAndThePageAndTheInboxReadTheAnswerNext() throws {
        let before = try read(fixtures)
        var open = TicketQuestions(identifier: "TP-1245", in: before.items)
        XCTAssertEqual(open.items.map(\.identifier), ["TP-1245"])
        XCTAssertEqual(open.questions, TicketPage.questions(of: "TP-1245", in: before.items))
        XCTAssertTrue(DecisionsLine(openQuestions: before.page.openQuestions, questions: open.questions).waiting)
        XCTAssertEqual(before.page.situation?.kind, .you)

        // The page's pick is the Inbox item's: picking on either shows on both. The recommended one is picked to start.
        var inboxPicks = InboxPicks()
        let item = try XCTUnwrap(open.item(0))
        XCTAssertNil(open.item(1))
        XCTAssertEqual(QuestionSend(questions: open.questions, picks: open.picks(inboxPicks)).answer, "For how long")
        inboxPicks.pick(1, decision: 0, itemID: item.id)
        XCTAssertEqual(open.picks(inboxPicks).picks, [0: 1])
        inboxPicks.pick(0, decision: 0, itemID: item.id)

        // Send opens the Inbox's own consequence sheet on that item, and its button sends the Inbox's `decide`.
        let answered = try XCTUnwrap(open.toSend(inboxPicks))
        XCTAssertEqual(answered, item)
        let sheet = ConsequenceSheet(move: .decide, item: answered, picks: inboxPicks[answered.id])
        XCTAssertEqual(sheet.title, "Send \"For how long\"?")
        XCTAssertEqual(sheet.happens, "The line reads 'Paused for 2 h 10 min', and the next run changes it.")
        XCTAssertTrue(sheet.holdsForUndo)
        XCTAssertEqual(sheet.heldBanner.text, "Sending your decision")
        let action = try XCTUnwrap(sheet.action())
        let question = try XCTUnwrap(item.review.action?.question)
        XCTAssertEqual(action, .decide("TP-1245", request: .comment("c-1245-request"), picks: [.init(question: question, answer: "For how long")], move: nil))
        XCTAssertEqual(send(action, to: fixtures), .done)
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome).text, "Sent your decision")
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.requestLog)) as? [String: Any])
        XCTAssertEqual(entry["path"] as? String, "/api/v1/control/decide")
        XCTAssertEqual(entry["body"] as? NSDictionary, [
            "issue_identifier": "TP-1245", "request_comment_id": "c-1245-request", "picks": [["question": question, "answer": "For how long"]],
        ] as NSDictionary)

        // The next read: the Question is gone from the page and from the Inbox, the situation says a run is starting,
        // and the timeline has the answer and the cleared pause at its top.
        let after = try read(fixtures)
        open = TicketQuestions(identifier: "TP-1245", in: after.items)
        XCTAssertTrue(open.items.isEmpty)
        XCTAssertNil(open.toSend(inboxPicks))
        XCTAssertFalse(after.items.contains { $0.identifier == "TP-1245" })
        XCTAssertEqual(after.page.openQuestions, [])
        let line = DecisionsLine(openQuestions: after.page.openQuestions, questions: open.questions)
        XCTAssertFalse(line.waiting)
        XCTAssertEqual(line.title, DecisionsLine.quietTitle)
        XCTAssertEqual(after.page.situation?.word, "Starting a run")
        XCTAssertEqual(after.page.situation?.kind, .working)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let history = try XCTUnwrap(after.page.history)
        let timeline = TimelineModel.build(history, runNow: after.page.runNow, reference: after.page.reference, calendar: calendar)
        let top = timeline.items.prefix(2).compactMap { item -> TimelineEntry.Kind? in
            if case let .entry(entry) = item { return entry.kind }
            return nil
        }
        XCTAssertEqual(Set(top), [.questionAnswered, .pauseCleared])
    }

    /// Symphony refuses the answer: the call fails with its reason, which the page shows under Send, and the page
    /// and the Inbox still read the Question.
    func testARefusedSendSaysSymphonysReasonAndLeavesTheQuestionOnThePage() throws {
        let copy = root.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.copyItem(at: Self.director, to: copy)
        let control = copy.appendingPathComponent("api/v1/control", isDirectory: true)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try Data(#"{"error":{"code":"not_waiting","message":"TP-1245 is not waiting on a decision"}}"#.utf8)
            .write(to: control.appendingPathComponent("decide.409.json"))
        let refusing = APIFixtures(directory: copy, requestLog: root.appendingPathComponent("refused.jsonl"))

        let before = try read(refusing)
        let open = TicketQuestions(identifier: "TP-1245", in: before.items)
        let item = try XCTUnwrap(open.toSend(InboxPicks()))
        let action = try XCTUnwrap(ConsequenceSheet(move: .decide, item: item).action())
        guard case let .failed(message) = send(action, to: refusing) else { return XCTFail("the send wasn't refused") }
        XCTAssertTrue(message.contains("TP-1245 is not waiting on a decision"), message)

        let after = try read(refusing)
        XCTAssertEqual(TicketQuestions(identifier: "TP-1245", in: after.items).items, open.items)
        XCTAssertEqual(after.page.openQuestions, before.page.openQuestions)
    }
}

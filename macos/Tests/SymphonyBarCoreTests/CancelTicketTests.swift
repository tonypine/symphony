import Foundation
import XCTest
@testable import SymphonyBarCore

/// Cancel Ticket… (TP-1317): the consequence sheet, the request its button sends, the banner after Symphony's answer,
/// and the `ticket-page` and `ticket-cancel-refused` fixtures QA drives it with.
final class CancelTicketTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var root: URL!

    private static func director(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = uniqueTemporaryDirectory("cancel-ticket")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixtures(_ name: String) -> APIFixtures {
        APIFixtures(directory: Self.director(name), requestLog: root.appendingPathComponent("\(name)-requests.jsonl"))
    }

    private func get(_ path: String, from fixtures: APIFixtures) throws -> Data {
        let url = try XCTUnwrap(URL(string: path, relativeTo: APIFixtures.baseURL))
        let (data, response) = fixtures.answer(URLRequest(url: url))
        XCTAssertEqual(response.statusCode, 200, path)
        return data
    }

    /// The page the window builds for `identifier` from the fixtures.
    private func page(_ identifier: String, from fixtures: APIFixtures) throws -> TicketPage {
        TicketPage(
            identifier: identifier,
            sources: TicketPage.Sources(
                state: try get("api/v1/state", from: fixtures),
                issue: try get(TicketPage.issuePath(identifier), from: fixtures)
            ),
            timeZone: utc
        )
    }

    private func send(_ action: ControlAction, to fixtures: APIFixtures) -> ControlResult {
        let (data, response) = fixtures.answer(ControlAPI.request(action, base: APIFixtures.baseURL, token: APIFixtures.token))
        return ControlAPI.result(action, statusCode: response.statusCode, data: data)
    }

    /// The bodies of the POSTs to `path` the request log holds, oldest first.
    private func posted(_ path: String, in name: String) throws -> [[String: String]] {
        let text = try String(contentsOf: root.appendingPathComponent("\(name)-requests.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").compactMap { line in
            let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard entry["path"] as? String == path else { return nil }
            return entry["body"] as? [String: String]
        }
    }

    // MARK: - The sheet

    func testTheSheetSaysEverythingTheCancelDoesOnARunningTicketWithAnOpenPullRequest() {
        let sheet = CancelTicketSheet(identifier: "TP-1", from: " Rework ", isRunning: true, hasOpenPullRequest: true)

        XCTAssertEqual(sheet.id, "TP-1")
        XCTAssertEqual(sheet.title, "Cancel TP-1?")
        XCTAssertEqual(sheet.happens, "Ends the agent working on TP-1. Closes its pull request, with your note as the closing "
            + "comment. Moves TP-1 from Rework to Canceled for good, withdraws its open questions and clears its holds. "
            + "Symphony doesn't work on it again.")
        XCTAssertEqual(sheet.stays, "Undo on the banner puts it back in Rework within 10 seconds; the pull request it closed, "
            + "the run it ended and the questions it withdrew stay as they are. Its branch stays.")
        XCTAssertEqual(CancelTicketSheet.verb, "Cancel Ticket")
        XCTAssertEqual(CancelTicketSheet.notePrompt, "Why it is cancelled")
    }

    func testTheSheetLeavesOutWhatThereIsNothingOf() {
        // A Backlog ticket with no run and no pull request: only the move.
        let backlog = CancelTicketSheet(identifier: "TP-1", from: "Backlog")
        XCTAssertEqual(backlog.happens, "Moves TP-1 from Backlog to Canceled for good, withdraws its open questions and clears "
            + "its holds. Symphony doesn't work on it again.")

        // A page that doesn't know the phase yet.
        let unknown = CancelTicketSheet(identifier: "TP-1", from: "  ")
        XCTAssertNil(unknown.from)
        XCTAssertTrue(unknown.happens.hasPrefix("Moves TP-1 to Canceled for good"))
        XCTAssertTrue(unknown.stays.hasPrefix("Undo on the banner puts it back where it was within 10 seconds"))
    }

    func testTheButtonSendsTheTrimmedNote_AndNoNoteWhenBlank() {
        let sheet = CancelTicketSheet(identifier: "TP-1", from: "Backlog")
        XCTAssertEqual(sheet.action(note: "  superseded by the secrets redesign \n"), .cancel("TP-1", note: "superseded by the secrets redesign"))
        XCTAssertEqual(sheet.action(note: " \n "), .cancel("TP-1", note: nil))
        XCTAssertEqual(sheet.action(note: "").body as? [String: String], ["issue_identifier": "TP-1"])
    }

    func testTheBannerOffersUndoOnlyWhenTheTicketMoved() {
        let sheet = CancelTicketSheet(identifier: "TP-1")
        let moved = sheet.banner(after: MoveOutcome(moved: true, toState: "Cancelled"))
        XCTAssertEqual(moved.text, "Cancelled, moved to Cancelled")
        XCTAssertTrue(moved.undo)
        XCTAssertEqual(moved.identifier, "TP-1")

        let unsaid = sheet.banner(after: sheet.expectedOutcome)
        XCTAssertEqual(unsaid.text, "Cancelled, moved to Canceled")

        let still = sheet.banner(after: MoveOutcome(moved: false, toState: nil))
        XCTAssertEqual(still.text, "Already in Canceled")
        XCTAssertFalse(still.undo)
        XCTAssertEqual(still.style, .info)
    }

    // MARK: - The fixtures

    func testTheTicketPageFixture_ARunningTicketCancelsWithItsNote_ADoneOneOffersNoCancel() throws {
        let fixtures = fixtures("ticket-page")
        let running = try page("TP-1244", from: fixtures)
        let rail = TicketActionRail(identifier: running.identifier, moves: try XCTUnwrap(running.moves))
        XCTAssertEqual(rail.request(.cancel), .sheet(.cancel))

        let sheet = running.cancelSheet
        XCTAssertEqual(sheet, CancelTicketSheet(identifier: "TP-1244", from: "Rework", isRunning: true, hasOpenPullRequest: true))

        let result = send(sheet.action(note: " superseded by the secrets redesign "), to: fixtures)
        XCTAssertEqual(result, .moved(MoveOutcome(moved: true, toState: "Canceled")))
        XCTAssertEqual(sheet.banner(after: try XCTUnwrap(result.moveOutcome)).text, "Cancelled, moved to Canceled")
        XCTAssertEqual(try posted("/api/v1/control/cancel", in: "ticket-page"), [
            ["issue_identifier": "TP-1244", "note": "superseded by the secrets redesign"],
        ])

        let done = try page("TP-1246", from: fixtures)
        let doneRail = TicketActionRail(identifier: done.identifier, moves: try XCTUnwrap(done.moves))
        XCTAssertFalse(doneRail.items.contains { $0.move == .cancel })
    }

    /// QA reaches TP-1244's page on both fixtures the way a person does: from its row in Tickets or on Home, so
    /// neither view draws "Update Symphony" for a read the fixtures lack. TP-1246, done, is in Tickets too.
    func testBothCancelFixturesOpenTP1244FromTicketsAndHome() throws {
        for name in ["ticket-page", "ticket-cancel-refused"] {
            let fixtures = fixtures(name)
            let path = TicketsQuery().path(scope: .all, now: Date())
            let tickets = try XCTUnwrap(TicketsPayload.decode(try get(path, from: fixtures)), name)
            XCTAssertNil(tickets.error, name)
            XCTAssertEqual(tickets.rows.map(\.identifier), ["TP-1244", "TP-1245", "TP-1246"], name)
            XCTAssertNotNil(TicketView.views(fromViews: try get(TicketsPayload.viewsPath, from: fixtures), catalog: TicketColumn.catalog), name)

            let home = try XCTUnwrap(HomeRead.decode(try get(HomeRead.path, from: fixtures)), name)
            let onHome: [String] = home.inProgress.compactMap { entry in
                if case let .ticket(ticket) = entry { return ticket.identifier }
                return nil
            }
            XCTAssertEqual(onHome, ["TP-1244", "TP-1245"], name)
            XCTAssertEqual(try page("TP-1244", from: fixtures).identifier, "TP-1244", name)
        }
    }

    /// Walkthrough step 2: once the cancel went through, every read the window makes again (the state, the ticket page,
    /// its feed, Tickets and Home) answers what Symphony serves after a cancel. TP-1244 leaves the running list and
    /// Home's In progress, reads Canceled with PR #741 closed and offers no Cancel Ticket… again, and its timeline has
    /// "Cancelled from Rework" with the note, after the run the cancel ended.
    func testTheTicketPageFixture_AfterTheCancel_TP1244LeavesTheRunningListAndItsPullRequestIsClosed() throws {
        let fixtures = fixtures("ticket-page")
        let before = try page("TP-1244", from: fixtures)
        XCTAssertTrue(before.isRunning)
        XCTAssertEqual(before.factsRead?.pullRequest?.state, "open")
        let runningBefore = try XCTUnwrap(JSONSerialization.jsonObject(with: try get("api/v1/state", from: fixtures)) as? [String: Any])
        XCTAssertEqual((runningBefore["running"] as? [[String: Any]])?.compactMap { $0["issue_identifier"] as? String }, ["TP-1244"])

        XCTAssertEqual(send(before.cancelSheet.action(note: "superseded by the secrets redesign"), to: fixtures),
                       .moved(MoveOutcome(moved: true, toState: "Canceled")))

        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: try get("api/v1/state", from: fixtures)) as? [String: Any])
        XCTAssertEqual((state["running"] as? [Any])?.count, 0)
        XCTAssertEqual((state["counts"] as? [String: Any])?["running"] as? Int, 0)

        let after = try page("TP-1244", from: fixtures)
        XCTAssertFalse(after.isRunning)
        // The page reads Cancelled from the ticket read itself: the lists the State fact comes from no longer hold it.
        XCTAssertEqual(after.situation?.kind, .cancelled)
        XCTAssertEqual(after.situation?.word, "Cancelled")
        XCTAssertEqual(after.lifecycleRead?.phasePath?.current, "Canceled")
        XCTAssertEqual(after.factsRead?.pullRequest?.state, "closed")
        XCTAssertEqual(after.factsRead?.pullRequest?.number, 741)
        let rail = TicketActionRail(identifier: after.identifier, moves: try XCTUnwrap(after.moves))
        XCTAssertFalse(rail.items.contains { $0.move == .cancel })

        let feed = try XCTUnwrap(TicketEventsPayload.decode(try get(
            "api/v1/repos/symphony/tickets/TP-1244/events", from: fixtures
        )))
        let cancelled = try XCTUnwrap(feed.events.first { $0.type == "ticket.cancelled" })
        XCTAssertEqual(cancelled.summary?.title, "Cancelled from Rework")
        XCTAssertEqual(cancelled.summary?.detail, "superseded by the secrets redesign")
        XCTAssertEqual(feed.runs["run-2"]?.exit, "stopped")

        let tickets = try XCTUnwrap(TicketsPayload.decode(try get(TicketsQuery().path(scope: .all, now: Date()), from: fixtures)))
        XCTAssertEqual(tickets.rows.first { $0.identifier == "TP-1244" }?.phase, "Canceled")
        let home = try XCTUnwrap(HomeRead.decode(try get(HomeRead.path, from: fixtures)))
        let onHome: [String] = home.inProgress.compactMap { entry in
            if case let .ticket(ticket) = entry { return ticket.identifier }
            return nil
        }
        XCTAssertEqual(onHome, ["TP-1245"])
    }

    func testTheRefusedFixtureAnswersTheCancelWithSymphonysReason() throws {
        let fixtures = fixtures("ticket-cancel-refused")
        let sheet = try page("TP-1244", from: fixtures).cancelSheet

        XCTAssertEqual(send(sheet.action(note: "dup"), to: fixtures), .failed(
            "Couldn't cancel TP-1244: TP-1244's team has no Canceled state, so it can't be cancelled (HTTP 409)"
        ))
    }
}

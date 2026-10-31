import XCTest
@testable import SymphonyBarCore

/// Move to… (TP-1328): the menu read from the state payload's `phases`, its sheet, the request it sends and the
/// banner after Symphony's answer.
final class TicketMoveTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:4010")!
    private let utc = TimeZone(identifier: "UTC")!

    private let phases = [
        MachinePhase(name: "Backlog", dispatches: false),
        MachinePhase(name: "Todo", dispatches: true),
        MachinePhase(name: "In Progress", dispatches: true),
        MachinePhase(name: "Done", dispatches: false),
        MachinePhase(name: "Canceled", dispatches: false),
    ]

    private static func parked(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/parked-backlog/api/v1/\(name).json"))
    }

    private func body(_ request: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }

    // MARK: - The state payload's phases

    func testThePhasesReadFromTheStatePayloadInItsOrder() {
        let state = Data(#"{"phases":[{"name":"Backlog","dispatches":false},{"name":"In Progress","dispatches":true},{"name":"QA"}]}"#.utf8)

        XCTAssertEqual(TicketMoveMenu.phases(inState: state), [
            MachinePhase(name: "Backlog", dispatches: false),
            MachinePhase(name: "In Progress", dispatches: true),
            // A phase without `dispatches` starts no run as far as the app knows.
            MachinePhase(name: "QA", dispatches: false),
        ])
        XCTAssertEqual(MachinePhase(name: "QA", dispatches: true).id, "QA")
    }

    func testAStatePayloadWithoutPhasesListsNone() {
        // A Symphony that predates TP-1333, no state yet, and one that doesn't read.
        XCTAssertEqual(TicketMoveMenu.phases(inState: Data(#"{"running":[]}"#.utf8)), [])
        XCTAssertEqual(TicketMoveMenu.phases(inState: nil), [])
        XCTAssertEqual(TicketMoveMenu.phases(inState: Data("not json".utf8)), [])
    }

    // MARK: - The menu

    func testTheMenuListsEveryPhaseWithTheTicketsOwnCheckedAndOff() throws {
        let menu = try XCTUnwrap(TicketMoveMenu(identifier: "SHOP-430", current: "backlog ", repoKey: "web-shop", phases: phases))

        XCTAssertEqual(menu.entries.map(\.name), ["Backlog", "Todo", "In Progress", "Done", "Canceled"])
        // Symphony compares phase names trimmed and case-insensitive.
        XCTAssertEqual(menu.entries.filter(\.isCurrent).map(\.id), ["Backlog"])
        XCTAssertNil(menu.sheet(for: menu.entries[0]))
        XCTAssertEqual(menu.sheet(for: menu.entries[2]), MoveSheet(identifier: "SHOP-430", from: "backlog ", to: phases[2]))
        XCTAssertEqual(TicketMoveMenu.accessibilityLabel(menu.entries[0]), "Backlog, the phase it is in")
        XCTAssertEqual(TicketMoveMenu.accessibilityLabel(menu.entries[2]), "Move to In Progress")
        XCTAssertEqual(TicketMoveMenu.title, "Move to…")
    }

    func testADoneOrCanceledTicketOffersEveryOtherPhaseToReopenIt() throws {
        // Symphony's move takes any phase it lists, so a closed ticket reopens into any of them.
        for closed in ["Done", "Canceled"] {
            let menu = try XCTUnwrap(TicketMoveMenu(identifier: "SHOP-1", current: closed, repoKey: "web-shop", phases: phases))
            XCTAssertEqual(menu.entries.filter(\.isCurrent).map(\.name), [closed])
            XCTAssertEqual(menu.entries.filter { !$0.isCurrent }.count, phases.count - 1)
        }
    }

    func testATicketInAnUnknownPhaseHasNothingChecked() throws {
        let menu = try XCTUnwrap(TicketMoveMenu(identifier: "SHOP-1", current: nil, repoKey: "web-shop", phases: phases))
        XCTAssertFalse(menu.entries.contains(where: \.isCurrent))
    }

    func testNoMenuWithoutPhasesOrOutsideARepository() {
        // Symphony refuses a ticket in no configured repository; an older Symphony lists no phases.
        XCTAssertNil(TicketMoveMenu(identifier: "SHOP-1", current: "Todo", repoKey: nil, phases: phases))
        XCTAssertNil(TicketMoveMenu(identifier: "SHOP-1", current: "Todo", repoKey: "", phases: phases))
        XCTAssertNil(TicketMoveMenu(identifier: "SHOP-1", current: "Todo", repoKey: "web-shop", phases: []))
    }

    // MARK: - The sheet and its request

    func testTheSheetSaysWhatTheMoveDoes() {
        let sheet = MoveSheet(identifier: "SHOP-430", from: "Backlog", to: phases[2])

        XCTAssertEqual(sheet.title, "Move SHOP-430 to In Progress?")
        XCTAssertEqual(sheet.happens, "Moves SHOP-430 from Backlog to In Progress, and Symphony starts its run there at once.")
        XCTAssertEqual(sheet.stays, "Its workspace, branch and pull request stay as they are. Undo on the banner puts it back within 10 seconds.")
        XCTAssertEqual(sheet.verb, "Move to In Progress")
        XCTAssertEqual(sheet.id, "SHOP-430→In Progress")

        let quiet = MoveSheet(identifier: "SHOP-430", from: nil, to: phases[3])
        XCTAssertEqual(quiet.happens, "Moves SHOP-430 to Done. Symphony starts no run there.")
    }

    func testTheButtonSendsTheMoveWithTheNoteWhenOneWasTyped() throws {
        let sheet = MoveSheet(identifier: "SHOP-430", from: "Backlog", to: phases[2])

        XCTAssertEqual(sheet.action(note: "  resume with the work \n"), .move("SHOP-430", to: "In Progress", note: "resume with the work"))
        XCTAssertEqual(sheet.action(note: "   "), .move("SHOP-430", to: "In Progress", note: nil))

        let request = ControlAPI.request(sheet.action(note: "resume with the work"), base: base, token: "secret")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/move")
        XCTAssertEqual(try body(request), ["issue_identifier": "SHOP-430", "to": "In Progress", "note": "resume with the work"])
        XCTAssertEqual(try body(ControlAPI.request(sheet.action(note: ""), base: base, token: "secret")),
                       ["issue_identifier": "SHOP-430", "to": "In Progress"])
        XCTAssertEqual(ControlAction.move("SHOP-430", to: "In Progress", note: nil).moveIdentifier, "SHOP-430")
    }

    func testSymphonysAnswerIsTheMovesOutcome() throws {
        let action = ControlAction.move("SHOP-430", to: "In Progress", note: nil)

        XCTAssertEqual(ControlAPI.result(action, statusCode: 200, data: try Self.parked("control/move")),
                       .moved(MoveOutcome(moved: true, toState: "In Progress")))
        let refused = Data(#"{"error":{"code":"conflict","message":"Symphony has no record of SHOP-430 yet, so it can't move it"}}"#.utf8)
        XCTAssertEqual(ControlAPI.result(action, statusCode: 409, data: refused),
                       .failed("Couldn't move SHOP-430 to In Progress: Symphony has no record of SHOP-430 yet, so it can't move it (HTTP 409)"))
    }

    func testTheBannerOffersUndoOnlyAfterTheTicketMoved() {
        let sheet = MoveSheet(identifier: "SHOP-430", from: "Backlog", to: phases[2])

        XCTAssertEqual(sheet.banner(after: MoveOutcome(moved: true, toState: "In Progress")),
                       InboxBanner(itemID: "SHOP-430", identifier: "SHOP-430", text: "Moved to In Progress", undo: true))
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome).text, "Moved to In Progress")
        XCTAssertEqual(sheet.banner(after: MoveOutcome(moved: false, toState: nil)),
                       InboxBanner(itemID: "SHOP-430", identifier: "SHOP-430", text: "Already in In Progress", undo: false, style: .info))
        XCTAssertEqual(sheet.banner(after: MoveOutcome(moved: true, toState: nil)).announcement,
                       "SHOP-430: Moved to In Progress. Undo is available for 10 seconds.")
    }

    // MARK: - The page

    func testAParkedBacklogTicketsPageOffersEveryPhaseWithBacklogChecked() throws {
        let page = TicketPage(
            identifier: "SHOP-430",
            sources: TicketPage.Sources(state: try Self.parked("state"), issue: try Self.parked("SHOP-430")),
            timeZone: utc
        )

        XCTAssertEqual(page.phaseName, "Backlog")
        let menu = try XCTUnwrap(page.moveMenu)
        XCTAssertEqual(menu.entries.count, 13)
        XCTAssertEqual(menu.entries.first?.name, "Backlog")
        XCTAssertEqual(menu.entries.last?.name, "Canceled")
        XCTAssertEqual(menu.entries.filter(\.isCurrent).map(\.name), ["Backlog"])
        XCTAssertEqual(menu.entries.first { $0.name == "In Progress" }?.phase.dispatches, true)
    }

    func testAPageWithoutPhasesHasNoMenu() {
        let page = TicketPage(
            identifier: "T-1",
            sources: TicketPage.Sources(issue: Data(#"{"repo_key":"web-shop","status":"dispatch_skipped"}"#.utf8)),
            timeZone: utc
        )
        XCTAssertNil(page.moveMenu)
    }
}

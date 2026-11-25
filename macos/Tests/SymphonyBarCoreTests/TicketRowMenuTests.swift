import XCTest
@testable import SymphonyBarCore

/// A Tickets row's context menu (TP-1611): Open Ticket, Start Now and Move to…, and no Force item since force was
/// removed from Symphony.
final class TicketRowMenuTests: XCTestCase {
    private let phases = [
        MachinePhase(name: "Todo", dispatches: true),
        MachinePhase(name: "In Progress", dispatches: true),
        MachinePhase(name: "Done", dispatches: false),
    ]
    private let forceTitles = ["Force", "Force a Ticket…", "Stop Forcing", "Forcing"]

    private func move(_ identifier: String, _ state: String) throws -> TicketMoveMenu {
        try XCTUnwrap(TicketMoveMenu(identifier: identifier, current: state, repoKey: "shop", phases: phases))
    }

    func testAWaitingTicketsRowMenuIsOpenStartNowAndMoveToWithNoForceItem() throws {
        let items = try TicketRowMenuItem.items(start: TicketStart(allowed: true), move: move("SHOP-320", "Todo"))

        XCTAssertEqual(items.map(\.title), ["Open Ticket", "Start Now", "Move to…"])
        XCTAssertEqual(items.map(\.isEnabled), [true, true, true])
        XCTAssertTrue(items.allSatisfy { !forceTitles.contains($0.title) && !$0.title.contains("Forc") })
    }

    func testAWorkingTicketsRowMenuDimsStartNowWithItsReasonAndHasNoForceItem() throws {
        let start = TicketStart(allowed: false, reason: "a run is already working on the ticket")
        let items = try TicketRowMenuItem.items(start: start, move: move("SHOP-305", "In Progress"))

        XCTAssertEqual(items.map(\.title), ["Open Ticket", "Start Now", "Move to…"])
        XCTAssertEqual(items.map(\.isEnabled), [true, false, true])
        XCTAssertEqual(items[1], .start(start))
        XCTAssertEqual(start.help("SHOP-305"), "A run is already working on the ticket")
        guard case let .move(menu) = items[2] else { return XCTFail("Move to… is not the third item") }
        XCTAssertEqual(menu.entries.map(\.name), ["Todo", "In Progress", "Done"])
        XCTAssertTrue(items.allSatisfy { !forceTitles.contains($0.title) && !$0.title.contains("Forc") })
    }

    func testARowMenuWithoutStartOrPhasesIsOpenTicketOnly() {
        XCTAssertEqual(TicketRowMenuItem.items(start: nil, move: nil), [.open])
    }
}

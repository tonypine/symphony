import SymphonyBarCore
@testable import SymphonyBarUI
import XCTest

/// A run's More › Read the whole session (TP-1452): the action the page hands its Run groups.
final class ReadSessionActionTests: XCTestCase {
    func testActionsForTheSameTicketAreEqualSoThePageKeepsItsMenusAcrossUpdates() {
        XCTAssertEqual(ReadSessionAction("TP-1244") { _ in }, ReadSessionAction("TP-1244") { _ in })
        XCTAssertNotEqual(ReadSessionAction("TP-1244") { _ in }, ReadSessionAction("TP-1246") { _ in })
    }

    func testCallingItOpensTheRunItIsGiven() {
        var opened: [String] = []
        let action = ReadSessionAction("TP-1244") { opened.append($0.id) }
        action(RunGroupModel(id: "run-1", title: "Implementation run 1", state: .failed, word: "Failed", steps: []))
        XCTAssertEqual(opened, ["run-1"])
    }
}

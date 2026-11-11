import SwiftUI
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// The Question block's number keys: 1 to 4 pick an option of TP-892's request (three options and the own-words card)
/// while the keyboard is not in a text field.
final class QuestionKeysTests: XCTestCase {
    private func item() throws -> InboxItem {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/inbox-decision/api/v1/inbox.json")
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: fixture)))
        return try XCTUnwrap(inbox.items.first { $0.identifier == "TP-892" })
    }

    private func option(_ characters: String, modifiers: EventModifiers = [], typing: Bool = false) throws -> Int? {
        let item = try item()
        return QuestionKeys.option(for: characters, modifiers: modifiers, typing: typing, optionIndex: item.optionIndex(forKey:))
    }

    func testPressingTwoPicksTheSecondOption() throws {
        XCTAssertEqual(try option("2"), 1)
        XCTAssertEqual(try option("1"), 0)
        // The number after the last option is the own-words card.
        let action = try XCTUnwrap(try item().review.action)
        XCTAssertEqual(try option("\(action.writeInIndex + 1)"), action.writeInIndex)
    }

    func testAKeyInATextFieldOrWithAModifierTypesInstead() throws {
        XCTAssertNil(try option("2", typing: true))
        XCTAssertNil(try option("2", modifiers: .command))
        XCTAssertNil(try option("2", modifiers: .option))
    }

    /// Return sends once an answer is picked, while the keyboard is not in the own-words field (TP-1450).
    func testReturnSendsAPickedAnswerOutsideTheField() {
        XCTAssertTrue(QuestionKeys.sends(modifiers: [], typing: false, enabled: true))
        // In the field Return types a new line; with nothing to send, or a modifier held, it does nothing here.
        XCTAssertFalse(QuestionKeys.sends(modifiers: [], typing: true, enabled: true))
        XCTAssertFalse(QuestionKeys.sends(modifiers: [], typing: false, enabled: false))
        XCTAssertFalse(QuestionKeys.sends(modifiers: .option, typing: false, enabled: true))
        // ⌘Return sends from anywhere, the field included, as the Options card's hint says; not with nothing to send.
        XCTAssertTrue(QuestionKeys.sends(modifiers: .command, typing: true, enabled: true))
        XCTAssertFalse(QuestionKeys.sends(modifiers: .command, typing: false, enabled: false))
    }

    func testAKeyPastTheOwnWordsCardOrNotADigitPicksNothing() throws {
        XCTAssertNil(try option("9"))
        XCTAssertNil(try option("0"))
        XCTAssertNil(try option("22"))
        XCTAssertNil(try option(""))
    }
}

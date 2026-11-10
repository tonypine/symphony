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

    func testAKeyPastTheOwnWordsCardOrNotADigitPicksNothing() throws {
        XCTAssertNil(try option("9"))
        XCTAssertNil(try option("0"))
        XCTAssertNil(try option("22"))
        XCTAssertNil(try option(""))
    }
}

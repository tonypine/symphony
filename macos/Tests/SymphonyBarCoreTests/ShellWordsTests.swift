import XCTest
@testable import SymphonyBarCore

final class ShellWordsTests: XCTestCase {
    func testSplitsOnWhitespace() {
        XCTAssertEqual(ShellWords.split("mise  exec\t--"), ["mise", "exec", "--"])
        XCTAssertEqual(ShellWords.split(""), [])
        XCTAssertEqual(ShellWords.split("   "), [])
    }

    func testHonoursQuotesAndEscapes() {
        XCTAssertEqual(ShellWords.split("env 'A=b c' \"D=e f\""), ["env", "A=b c", "D=e f"])
        XCTAssertEqual(ShellWords.split("a\\ b"), ["a b"])
        XCTAssertEqual(ShellWords.split("''"), [""])
        XCTAssertEqual(ShellWords.split("x'y'\"z\""), ["xyz"])
        XCTAssertEqual(ShellWords.split("'a\\b'"), ["a\\b"])
        XCTAssertEqual(ShellWords.split("\"a\\\"b\\\\c\\d\""), ["a\"b\\c\\d"])
    }

    func testRejectsUnbalancedInput() {
        XCTAssertNil(ShellWords.split("'open"))
        XCTAssertNil(ShellWords.split("\"open"))
        XCTAssertNil(ShellWords.split("\"open\\"))
        XCTAssertNil(ShellWords.split("trailing\\"))
    }
}

import XCTest
@testable import SymphonyBarCore

final class DrainStatusTests: XCTestCase {
    func testReadsTheDrainRequestsAnswer() {
        let data = Data(#"{"running": 3, "between_turns": 1, "paused": true}"#.utf8)

        XCTAssertEqual(DrainStatus.parse(data: data, statusCode: 200), DrainStatus(running: 3, betweenTurns: 1, paused: true))
        XCTAssertEqual(DrainStatus(running: 3, betweenTurns: 1, paused: true).activeRuns, 2)
        XCTAssertEqual(DrainStatus(running: 1, betweenTurns: 2, paused: true).activeRuns, 0)
    }

    func testAnErrorOrAnOlderSymphonyGivesNoRead() {
        let error = Data(#"{"error": {"code": "snapshot_timeout", "message": "Snapshot timed out"}}"#.utf8)

        XCTAssertNil(DrainStatus.parse(data: error, statusCode: 503))
        XCTAssertNil(DrainStatus.parse(data: error, statusCode: 200))
        XCTAssertNil(DrainStatus.parse(data: Data("Not Found".utf8), statusCode: 404), "a Symphony without the request")
    }

    func testTheRequestSitsBesideTheState() {
        XCTAssertEqual(
            DrainStatus.url(base: URL(string: "http://127.0.0.1:4000")!).absoluteString,
            "http://127.0.0.1:4000/api/v1/drain"
        )
    }
}

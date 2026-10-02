import XCTest
@testable import SymphonyBarCore

final class StateSnapshotTests: XCTestCase {
    /// `GET /api/v1/state` recorded from a running Symphony, with `run_history` trimmed to one entry.
    private func recordedState() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/state-running.json")
        return try Data(contentsOf: url)
    }

    /// The recorded state with its `pause` object replaced, as Symphony reports it after a dashboard pause.
    private func recordedState(pause: [String: Any]) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: recordedState()) as? [String: Any])
        object["pause"] = pause
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testDecodesTheRecordedState() throws {
        XCTAssertEqual(
            SymphonyState.poll(data: try recordedState(), statusCode: 200),
            .state(StateSnapshot(running: 1, retrying: 0, pause: nil))
        )
    }

    func testDecodesAPause() throws {
        let data = try recordedState(pause: ["paused": true, "reason": "deploy freeze", "paused_at": "2026-10-02T12:16:02Z"])

        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(
                StateSnapshot(
                    running: 1,
                    retrying: 0,
                    pause: .init(reason: "deploy freeze", since: Date(timeIntervalSince1970: 1_790_943_362))
                )
            )
        )
    }

    func testDecodesAPauseWithoutReasonOrTime() throws {
        let data = try recordedState(pause: ["paused": true, "reason": NSNull(), "paused_at": NSNull()])

        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(StateSnapshot(running: 1, retrying: 0, pause: .init()))
        )
    }

    func testRetryingDefaultsToZero() {
        XCTAssertEqual(
            SymphonyState.poll(data: Data(#"{"counts": {"running": 2}}"#.utf8), statusCode: 200),
            .state(StateSnapshot(running: 2))
        )
    }

    func testAnErrorPayloadFails() {
        let body = #"{"generated_at": "2026-10-02T12:16:02Z", "error": {"code": "snapshot_timeout", "message": "Snapshot timed out"}}"#

        XCTAssertEqual(SymphonyState.poll(data: Data(body.utf8), statusCode: 200), .failed("Snapshot timed out"))
        XCTAssertEqual(
            SymphonyState.poll(data: Data(#"{"error": {"code": "snapshot_unavailable"}}"#.utf8), statusCode: 200),
            .failed("snapshot_unavailable")
        )
        XCTAssertEqual(
            SymphonyState.poll(data: Data(#"{"error": {}}"#.utf8), statusCode: 200),
            .failed("Symphony reported an error")
        )
    }

    func testOtherStatusCodesFail() throws {
        XCTAssertEqual(SymphonyState.poll(data: try recordedState(), statusCode: 500), .failed("Symphony answered with HTTP 500"))
    }

    func testOtherBodiesFail() {
        for body in ["", "[]", "{}", #"{"counts": {}}"#, "<html>"] {
            XCTAssertEqual(
                SymphonyState.poll(data: Data(body.utf8), statusCode: 200),
                .failed("Symphony's state couldn't be read"),
                body
            )
        }
    }
}

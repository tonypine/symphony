import XCTest
@testable import SymphonyBarCore

final class ControlAPITests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:4010")!

    private func json(_ request: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }

    func testPauseRequest() throws {
        let request = ControlAPI.request(.pause, base: base, token: "secret")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/pause")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try json(request), ["reason": "paused from menu bar"])
    }

    func testResumeRequest() throws {
        let request = ControlAPI.request(.resume, base: base, token: "secret")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/resume")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(try json(request), [:])
    }

    func testResponses() {
        XCTAssertEqual(ControlAPI.result(.pause, statusCode: 200, data: Data("{}".utf8)), .done)
        XCTAssertEqual(
            ControlAPI.result(.pause, statusCode: 401, data: Data()),
            .failed("Couldn't pause Symphony: it rejected the control token (HTTP 401)")
        )
        XCTAssertEqual(
            ControlAPI.result(.resume, statusCode: 503, data: Data()),
            .failed("Couldn't resume Symphony: its orchestrator is unavailable (HTTP 503)")
        )
        XCTAssertEqual(
            ControlAPI.result(
                .resume,
                statusCode: 500,
                data: Data(#"{"error":{"code":"orchestrator_error","message":"Unexpected orchestrator error"}}"#.utf8)
            ),
            .failed("Couldn't resume Symphony: Unexpected orchestrator error (HTTP 500)")
        )
        XCTAssertEqual(ControlAPI.result(.pause, statusCode: 404, data: Data("<html>".utf8)), .failed("Couldn't pause Symphony: HTTP 404"))
    }

    // MARK: - send

    private var root: URL!

    override func setUpWithError() throws {
        root = uniqueTemporaryDirectory("control-api")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func response(_ statusCode: Int, for request: URLRequest) -> (Data, URLResponse) {
        (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
    }

    func testSendUsesTheControlURLAndTokenFromTheStateRoot() async throws {
        try "http://127.0.0.1:4010\n".write(to: root.appendingPathComponent("control_url"), atomically: false, encoding: .utf8)
        try "0123abcd\n".write(to: root.appendingPathComponent("control_token"), atomically: false, encoding: .utf8)
        var sent: URLRequest?

        let result = await ControlAPI.send(.pause, stateRoot: root) { request in
            sent = request
            return self.response(200, for: request)
        }

        XCTAssertEqual(result, .done)
        XCTAssertEqual(sent?.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/pause")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer 0123abcd")
    }

    func testSendFallsBackToTheDefaultURL() async throws {
        try "0123abcd".write(to: root.appendingPathComponent("control_token"), atomically: false, encoding: .utf8)
        var sent: URLRequest?

        let result = await ControlAPI.send(.resume, stateRoot: root) { request in
            sent = request
            return self.response(401, for: request)
        }

        XCTAssertEqual(sent?.url?.absoluteString, "http://127.0.0.1:4000/api/v1/control/resume")
        XCTAssertEqual(result, .failed("Couldn't resume Symphony: it rejected the control token (HTTP 401)"))
    }

    func testSendNeedsAControlToken() async {
        var called = false

        let result = await ControlAPI.send(.pause, stateRoot: root) { request in
            called = true
            return self.response(200, for: request)
        }

        XCTAssertFalse(called)
        guard case let .failed(message) = result else { return XCTFail("expected a failure, got \(result)") }
        XCTAssertTrue(message.hasPrefix("Couldn't pause Symphony: no control token in "), message)
        XCTAssertTrue(message.hasSuffix("/control_token"), message)
    }

    func testSendWithoutAFallbackNeedsTheControlURLFile() async throws {
        // QA mode: the token alone must not send the request to the default port.
        try "0123abcd".write(to: root.appendingPathComponent("control_token"), atomically: false, encoding: .utf8)
        var called = false

        let result = await ControlAPI.send(.pause, stateRoot: root, fallback: nil) { request in
            called = true
            return self.response(200, for: request)
        }

        XCTAssertFalse(called)
        guard case let .failed(message) = result else { return XCTFail("expected a failure, got \(result)") }
        XCTAssertTrue(message.hasPrefix("Couldn't pause Symphony: no control URL in "), message)
        XCTAssertTrue(message.hasSuffix("/control_url"), message)

        try "http://127.0.0.1:4010\n".write(to: root.appendingPathComponent("control_url"), atomically: false, encoding: .utf8)
        var sent: URLRequest?
        let sentResult = await ControlAPI.send(.pause, stateRoot: root, fallback: nil) { request in
            sent = request
            return self.response(200, for: request)
        }
        XCTAssertEqual(sentResult, .done)
        XCTAssertEqual(sent?.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/pause")
    }

    func testSendReportsAnUnreachableSymphony() async throws {
        try "0123abcd".write(to: root.appendingPathComponent("control_token"), atomically: false, encoding: .utf8)

        let result = await ControlAPI.send(.pause, stateRoot: root) { _ in throw URLError(.cannotConnectToHost) }

        XCTAssertEqual(result, .failed("Couldn't pause Symphony: nothing answered at http://127.0.0.1:4000"))
    }
}

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

    /// An update's pause names its reason's kind and the version as a field (TP-1251), with the line a Symphony that
    /// reads no kind makes the same `build` reason from.
    func testAnUpdatesPauseRequestCarriesABuildReasonAndItsVersion() throws {
        let request = ControlAPI.request(.pauseForUpdate(version: "0.0.1.700"), base: base, token: "secret")

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/pause")
        XCTAssertEqual(try json(request), ["kind": "build", "version": "0.0.1.700", "reason": "updating to v0.0.1.700"])
    }

    func testResumeRequest() throws {
        let request = ControlAPI.request(.resume, base: base, token: "secret")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/resume")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(try json(request), [:])
    }

    func testForceRequests() throws {
        let force = ControlAPI.request(.force("TP-123"), base: base, token: "secret")
        XCTAssertEqual(force.httpMethod, "POST")
        XCTAssertEqual(force.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/force")
        XCTAssertEqual(force.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(try json(force), ["identifier": "TP-123"])

        let stop = ControlAPI.request(.stopForcing("TP-123"), base: base, token: "secret")
        XCTAssertEqual(stop.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/force")
        XCTAssertEqual(try json(stop), ["identifier": "TP-123", "clear": "true"])
    }

    func testForceResponsesNameTheTicket() {
        XCTAssertEqual(ControlAPI.result(.force("TP-123"), statusCode: 200, data: Data("{}".utf8)), .done)
        XCTAssertEqual(
            ControlAPI.result(
                .force("TP-999"),
                statusCode: 404,
                data: Data(#"{"error":{"code":"issue_not_found","message":"TP-999 was not found in Linear"}}"#.utf8)
            ),
            .failed("Couldn't force TP-999: TP-999 was not found in Linear (HTTP 404)")
        )
        XCTAssertEqual(
            ControlAPI.result(.stopForcing("TP-123"), statusCode: 401, data: Data()),
            .failed("Couldn't stop forcing TP-123: it rejected the control token (HTTP 401)")
        )
        XCTAssertEqual(
            ControlAPI.unreachable(.force("TP-123"), base: base),
            .failed("Couldn't force TP-123: nothing answered at http://127.0.0.1:4010")
        )
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

    func testStopRequest() throws {
        let stop = ControlAPI.request(.stop("TP-7"), base: base, token: "secret")
        XCTAssertEqual(stop.httpMethod, "POST")
        XCTAssertEqual(stop.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/stop")
        XCTAssertEqual(stop.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(try json(stop), ["issue_identifier": "TP-7"])
    }

    func testStopResponses() {
        XCTAssertEqual(
            ControlAPI.result(.stop("TP-7"), statusCode: 200, data: Data(#"{"stopped":true,"issue_identifier":"TP-7"}"#.utf8)),
            .done
        )
        // Symphony answers 200 when no agent runs on the ticket, with `stopped: false`.
        XCTAssertEqual(
            ControlAPI.result(.stop("TP-7"), statusCode: 200, data: Data(#"{"stopped":false,"issue_id":"TP-7"}"#.utf8)),
            .failed("Couldn't stop TP-7: no agent runs on TP-7 anymore")
        )
        XCTAssertEqual(
            ControlAPI.result(.stop("TP-7"), statusCode: 200, data: Data("<html>".utf8)),
            .failed("Couldn't stop TP-7: no agent runs on TP-7 anymore")
        )
        XCTAssertEqual(
            ControlAPI.result(.stop("TP-7"), statusCode: 503, data: Data()),
            .failed("Couldn't stop TP-7: its orchestrator is unavailable (HTTP 503)")
        )
    }

    func testSendStopsARun() async throws {
        try "http://127.0.0.1:4010\n".write(to: root.appendingPathComponent("control_url"), atomically: false, encoding: .utf8)
        try "0123abcd\n".write(to: root.appendingPathComponent("control_token"), atomically: false, encoding: .utf8)
        var sent: URLRequest?

        let result = await ControlAPI.send(.stop("TP-7"), stateRoot: root) { request in
            sent = request
            return (
                Data(#"{"stopped":true}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        XCTAssertEqual(result, .done)
        XCTAssertEqual(sent?.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/stop")
        XCTAssertEqual(try json(XCTUnwrap(sent)), ["issue_identifier": "TP-7"])

        let unreachable = await ControlAPI.send(.stop("TP-7"), stateRoot: root) { _ in throw URLError(.cannotConnectToHost) }
        XCTAssertEqual(unreachable, .failed("Couldn't stop TP-7: nothing answered at http://127.0.0.1:4010"))
    }

    func testNoteRequest() throws {
        let note = ControlAPI.request(.note(repoKey: "web-shop", identifier: "SHOP-410", text: "Keep the header."), base: base, token: "secret")
        XCTAssertEqual(note.httpMethod, "POST")
        XCTAssertEqual(note.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/note")
        XCTAssertEqual(note.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(try json(note), ["repo_key": "web-shop", "issue_identifier": "SHOP-410", "text": "Keep the header."])
        XCTAssertNil(ControlAction.note(repoKey: "web-shop", identifier: "SHOP-410", text: "x").moveIdentifier)
    }

    func testNoteResponses() {
        let note = ControlAction.note(repoKey: "web-shop", identifier: "SHOP-410", text: "Keep the header.")
        // Symphony answers the recorded event: the note was written.
        XCTAssertEqual(
            ControlAPI.result(note, statusCode: 200, data: Data(#"{"event":{"id":"ev-1","type":"note","actor":{"kind":"person","name":"the Director"}}}"#.utf8)),
            .done
        )
        // A refusal says why, in Symphony's words: the text stays in the field with it.
        XCTAssertEqual(
            ControlAPI.result(note, statusCode: 400, data: Data(#"{"error":{"code":"invalid_note","message":"A note holds at most 4,000 characters; this one has 4,001"}}"#.utf8)),
            .failed("Couldn't add the note to SHOP-410: A note holds at most 4,000 characters; this one has 4,001 (HTTP 400)")
        )
        XCTAssertEqual(
            ControlAPI.result(note, statusCode: 404, data: Data(#"{"error":{"code":"ticket_not_found","message":"No ticket SHOP-410 in web-shop"}}"#.utf8)),
            .failed("Couldn't add the note to SHOP-410: No ticket SHOP-410 in web-shop (HTTP 404)")
        )
        XCTAssertEqual(
            ControlAPI.result(note, statusCode: 401, data: Data()),
            .failed("Couldn't add the note to SHOP-410: it rejected the control token (HTTP 401)")
        )
    }

    func testRepositoryPauseRequests() throws {
        let pause = ControlAPI.request(
            .pauseRepository(key: "web-shop", reason: "  focusing on Symphony this week "), base: base, token: "secret"
        )
        XCTAssertEqual(pause.httpMethod, "POST")
        XCTAssertEqual(pause.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/repos/web-shop/pause")
        XCTAssertEqual(pause.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(try json(pause), ["reason": "focusing on Symphony this week"])
        // Without a reason Symphony gives the pause its own line.
        XCTAssertEqual(try json(ControlAPI.request(.pauseRepository(key: "web-shop", reason: " "), base: base, token: "secret")), [:])

        let resume = ControlAPI.request(.resumeRepository(key: "web-shop"), base: base, token: "secret")
        XCTAssertEqual(resume.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/repos/web-shop/resume")
        XCTAssertEqual(try json(resume), [:])
        XCTAssertNil(ControlAction.pauseRepository(key: "web-shop", reason: "").moveIdentifier)
        XCTAssertNil(ControlAction.resumeRepository(key: "web-shop").moveIdentifier)
    }

    func testRepositoryPauseResponses() {
        let answer = Data(#"{"repository":{"repo_key":"web-shop","paused":true,"pause":{"reasons":[]}}}"#.utf8)
        XCTAssertEqual(ControlAPI.result(.pauseRepository(key: "web-shop", reason: ""), statusCode: 200, data: answer), .done)
        XCTAssertEqual(ControlAPI.result(.resumeRepository(key: "web-shop"), statusCode: 200, data: answer), .done)
        XCTAssertEqual(
            ControlAPI.result(
                .pauseRepository(key: "gone", reason: ""), statusCode: 404,
                data: Data(#"{"error":{"code":"repository_not_found","message":"Symphony has no repository gone"}}"#.utf8)
            ),
            .failed("Couldn't pause gone: Symphony has no repository gone (HTTP 404)")
        )
        XCTAssertEqual(
            ControlAPI.result(.resumeRepository(key: "web-shop"), statusCode: 401, data: Data()),
            .failed("Couldn't resume web-shop: it rejected the control token (HTTP 401)")
        )
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

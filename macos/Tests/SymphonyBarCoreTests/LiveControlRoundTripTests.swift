import Foundation
import XCTest
@testable import SymphonyBarCore

/// QA mode with `SYMPHONY_BAR_CONTROL_URL` and `SYMPHONY_BAR_CONTROL_TOKEN` sends the Director's moves over the network
/// to that URL with that token, as a live QA pass's server receives them.
final class LiveControlRoundTripTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = uniqueTemporaryDirectory("live-control")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testADecideReachesTheLiveControlURLWithItsToken() async throws {
        let server = try StubControlServer(answer: #"{"ok":true,"moved":true,"to_state":"Rework"}"#)
        defer { server.close() }
        let stores = AppStores(
            environment: [
                QAMode.environmentKey: root.path,
                QAMode.apiFixturesKey: root.appendingPathComponent("fixtures").path,
                QAMode.controlURLKey: "http://127.0.0.1:\(server.port)",
                QAMode.controlTokenKey: "qa-pass-token",
            ],
            home: root
        )
        let action = ControlAction.decide(
            "TP-7",
            request: .comment("comment-1"),
            picks: [ControlAction.DecisionPick(question: "Which layout?", answer: "Two columns")],
            move: nil
        )

        let result = await stores.sendControl(action, stateRoot: stores.qaMode!.stateRoot)

        XCTAssertEqual(result, .moved(MoveOutcome(moved: true, toState: "Rework")))
        let request = try XCTUnwrap(server.received())
        XCTAssertEqual(request.line, "POST /api/v1/control/decide HTTP/1.1")
        XCTAssertEqual(request.headers["authorization"], "Bearer qa-pass-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["issue_identifier"] as? String, "TP-7")
        XCTAssertEqual(body["request_comment_id"] as? String, "comment-1")
        // Nothing went to the fixtures' request log.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(APIFixtures.requestLogFileName).path))
    }
}

/// A control server on a loopback port that answers one request with `answer` and keeps what it received.
private final class StubControlServer {
    struct Request {
        let line: String
        let headers: [String: String]
        let body: Data
    }

    let port: UInt16
    private let socket: Int32
    private let done = DispatchSemaphore(value: 0)
    private var request: Request?

    init(answer: String) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socket, 1) == 0 else {
            Darwin.close(socket)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        self.socket = socket
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            let client = accept(socket, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            request = Self.read(client)
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(answer.utf8.count)\r\n"
                + "Connection: close\r\n\r\n\(answer)"
            _ = reply.withCString { write(client, $0, strlen($0)) }
        }
    }

    /// The request the server received, once it has answered.
    func received() -> Request? {
        _ = done.wait(timeout: .now() + 10)
        return request
    }

    func close() {
        Darwin.close(socket)
    }

    /// Reads the request line, the headers and a `Content-Length` body from `client`.
    private static func read(_ client: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let end = data.range(of: separator) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in head.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "") ?? 0
                if data.count - end.upperBound >= length {
                    let body = data.subdata(in: end.upperBound ..< end.upperBound + length)
                    return Request(line: head.first ?? "", headers: headers, body: body)
                }
            }
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
        }
    }
}

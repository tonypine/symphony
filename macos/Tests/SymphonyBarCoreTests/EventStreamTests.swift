import Combine
import XCTest
@testable import SymphonyBarCore

/// A clock the test advances by hand: it records each scheduled try and fires it on request.
@MainActor
private final class RetryScheduler: PollScheduler {
    final class Scheduled: PollTimer {
        let interval: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false

        init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.action = action
        }

        func cancel() { cancelled = true }
    }

    var scheduled: [Scheduled] = []

    nonisolated func schedule(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PollTimer {
        MainActor.assumeIsolated {
            let entry = Scheduled(interval: interval, action: action)
            scheduled.append(entry)
            return entry
        }
    }

    /// The try waiting to fire, if any.
    var pending: Scheduled? { scheduled.last.flatMap { $0.cancelled ? nil : $0 } }
}

/// Answers each opening of the channel with the next canned answer: a status code with a body the test feeds, or
/// a failure once they run out.
@MainActor
private final class FakeChannel {
    var answers: [Int] = []
    var requests: [URLRequest] = []
    var body: AsyncThrowingStream<Data, Error>.Continuation?

    var connect: EventStream.Connect {
        { [unowned self] request in
            requests.append(request)
            guard !answers.isEmpty else { throw URLError(.cannotConnectToHost) }
            let (body, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            self.body = continuation
            return EventStream.Response(statusCode: answers.removeFirst(), body: body)
        }
    }
}

/// Answers every request to its session with `body` in two chunks and a 200.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var chunks: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ServerSentEventParserTests: XCTestCase {
    func testReadsAnEventItsIDAndItsData() {
        XCTAssertEqual(
            ServerSentEventParser.parse("event: ticket\nid: 01A\ndata: {\"type\":\"note\"}\n\n"),
            [.event(ServerSentEvent(event: "ticket", data: #"{"type":"note"}"#, id: "01A"))]
        )
    }

    func testJoinsDataOverSeveralLinesAndNamesAnUnnamedEventMessage() {
        XCTAssertEqual(
            ServerSentEventParser.parse("data: one\ndata:two\ndata\ndata:  three\n\n"),
            [.event(ServerSentEvent(event: "message", data: "one\ntwo\n\n three"))]
        )
    }

    func testReadsCommentsAndDropsAMessageWithoutData() {
        XCTAssertEqual(ServerSentEventParser.parse(": keep-alive\n\n:\nevent: ticket\n\n"), [.comment("keep-alive"), .comment("")])
    }

    func testKeepsTheLastIDForLaterEventsAndIgnoresOtherFields() {
        let items = ServerSentEventParser.parse("id: 1\ndata: a\n\nretry: 10\nfoo: bar\ndata: b\n\nid: x\u{0}y\ndata: c\n\n")
        XCTAssertEqual(items, [
            .event(ServerSentEvent(data: "a", id: "1")),
            .event(ServerSentEvent(data: "b", id: "1")),
            .event(ServerSentEvent(data: "c", id: "1")),
        ])
    }

    func testEndsLinesWithCRLFOrCR() {
        XCTAssertEqual(
            ServerSentEventParser.parse("event: ticket\r\ndata: a\r\n\r\nevent: ticket\rdata: b\r\r"),
            [.event(ServerSentEvent(event: "ticket", data: "a")), .event(ServerSentEvent(event: "ticket", data: "b"))]
        )
    }

    func testLeavesAnUnfinishedMessageUntilItsBlankLine() {
        var parser = ServerSentEventParser()
        XCTAssertEqual(parser.feed(Data("data: a\n".utf8)), [])
        XCTAssertEqual(parser.feed(Data("\n".utf8)), [.event(ServerSentEvent(data: "a"))])
    }

    func testReadsTheSameItemsWhateverWhereTheChunksEnd() {
        let text = "event: ticket\r\nid: 7\r\ndata: café ✓\r\n\r\n: keep-alive\r\n\r\ndata: x\n\n"
        let whole = ServerSentEventParser.parse(text)
        XCTAssertEqual(whole.count, 3)

        var parser = ServerSentEventParser()
        let byteByByte = Data(text.utf8).flatMap { parser.feed(Data([$0])) }
        XCTAssertEqual(byteByByte, whole)
    }
}

@MainActor
final class EventStreamTests: XCTestCase {
    private var scheduler: RetryScheduler!
    private var channel: FakeChannel!
    private var base: URL? = URL(string: "http://127.0.0.1:4000")
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        scheduler = RetryScheduler()
        channel = FakeChannel()
        base = URL(string: "http://127.0.0.1:4000")
    }

    private func stream() -> EventStream {
        EventStream(base: { [unowned self] in base }, connect: channel.connect, scheduler: scheduler)
    }

    /// Fires the pending try and waits for it.
    private func retry(_ stream: EventStream) async throws {
        try XCTUnwrap(scheduler.pending).action()
        await stream.task?.value
    }

    private let notice = #"{"repo_key":"repo-a","issue_id":"issue-1","issue_identifier":"TP-1","event_id":"01A","type":"note","at":"2026-10-22T10:00:00Z"}"#

    func testPublishesEachTicketNoticeWhileConnected() async throws {
        channel.answers = [200]
        let stream = stream()
        var received: [EventStreamNotice] = []
        let arrived = expectation(description: "notice")
        stream.notices.sink { received.append($0); arrived.fulfill() }.store(in: &cancellables)

        stream.start()
        XCTAssertEqual(stream.state, .connecting)
        for _ in 0..<100 where channel.body == nil { await Task.yield() }
        let body = try XCTUnwrap(channel.body)
        body.yield(Data(": keep-alive\n\nevent: other\ndata: {}\n\nevent: ticket\ndata: not json\n\nevent: ticket\nid: 01A\n".utf8))
        body.yield(Data("data: \(notice)\n\n".utf8))
        await fulfillment(of: [arrived], timeout: 2)

        let expected = EventStreamNotice(
            repoKey: "repo-a", issueId: "issue-1", issueIdentifier: "TP-1", eventId: "01A", type: "note", at: "2026-10-22T10:00:00Z"
        )
        XCTAssertEqual(received, [expected])
        XCTAssertEqual(stream.lastNotice, expected)
        XCTAssertEqual(stream.state, .connected)

        let request = try XCTUnwrap(channel.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4000/api/v1/stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.timeoutInterval, EventStream.idleTimeout)
    }

    func testReconnectsADroppedConnectionAfterOneSecond() async throws {
        channel.answers = [200]
        let stream = stream()
        stream.start()
        for _ in 0..<100 where channel.body == nil { await Task.yield() }
        try XCTUnwrap(channel.body).finish()
        await stream.task?.value

        XCTAssertEqual(stream.state, .reconnecting(after: 1))
        XCTAssertEqual(scheduler.pending?.interval, 1)
    }

    func testBacksOffFromOneSecondDoublingToThirty() async throws {
        let stream = stream()
        stream.start()
        await stream.task?.value
        var delays = [scheduler.pending?.interval]
        for _ in 0..<6 {
            try await retry(stream)
            delays.append(scheduler.pending?.interval)
        }

        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30])
        XCTAssertEqual(stream.state, .reconnecting(after: 30))
        XCTAssertEqual(channel.requests.count, 7)
        XCTAssertEqual((0...8).map(EventStream.delay(afterFailures:)), [1, 2, 4, 8, 16, 30, 30, 30, 30])
    }

    func testAnAnswerFromSymphonyStartsTheBackoffOver() async throws {
        let stream = stream()
        stream.start()
        await stream.task?.value
        try await retry(stream)
        XCTAssertEqual(scheduler.pending?.interval, 2)

        // A server error is a failed try too; an answer that opens the channel starts over at one second.
        channel.answers = [500, 200]
        try await retry(stream)
        XCTAssertEqual(scheduler.pending?.interval, 4)
        // The 500's body is not the open channel's: wait for the 200's.
        channel.body = nil
        try XCTUnwrap(scheduler.pending).action()
        for _ in 0..<100 where channel.body == nil { await Task.yield() }
        try XCTUnwrap(channel.body).finish(throwing: URLError(.networkConnectionLost))
        await stream.task?.value
        XCTAssertEqual(scheduler.pending?.interval, 1)
    }

    func testA404LeavesTheChannelUnavailableUntilTheWindowConnectsAgain() async throws {
        channel.answers = [404]
        let stream = stream()
        stream.start()
        await stream.task?.value

        XCTAssertEqual(stream.state, .unavailable)
        XCTAssertNil(scheduler.pending)
        stream.start()
        XCTAssertEqual(channel.requests.count, 1)

        // The window connects to Symphony again: the channel is tried once more.
        channel.answers = [404]
        stream.stop()
        XCTAssertEqual(stream.state, .stopped)
        stream.start()
        await stream.task?.value
        XCTAssertEqual(channel.requests.count, 2)
        XCTAssertEqual(stream.state, .unavailable)
    }

    func testStopClosesTheConnectionAndCancelsTheNextTry() async throws {
        channel.answers = [200]
        let stream = stream()
        var received = 0
        stream.notices.sink { _ in received += 1 }.store(in: &cancellables)
        stream.start()
        for _ in 0..<100 where channel.body == nil { await Task.yield() }
        let task = stream.task

        stream.stop()
        channel.body?.yield(Data("event: ticket\ndata: \(notice)\n\n".utf8))
        channel.body?.finish()
        await task?.value
        XCTAssertEqual(stream.state, .stopped)
        XCTAssertEqual(received, 0)
        XCTAssertNil(scheduler.pending)

        stream.start()
        await stream.task?.value
        let next = try XCTUnwrap(scheduler.pending)
        stream.stop()
        XCTAssertTrue(next.cancelled)
    }

    func testAStopWhileOpeningIgnoresTheAnswer() async {
        channel.answers = [404]
        let stream = stream()
        stream.start()
        let task = stream.task
        stream.stop()
        await task?.value
        XCTAssertEqual(stream.state, .stopped)
        XCTAssertNil(scheduler.pending)
    }

    func testWaitsForAControlURL() async {
        base = nil
        let stream = stream()
        stream.start()
        XCTAssertEqual(stream.state, .reconnecting(after: 1))
        XCTAssertTrue(channel.requests.isEmpty)
    }

    func testBufferedOpensThroughATransportThatAnswersWholeBodies() async throws {
        let url = try XCTUnwrap(URL(string: "http://fixtures/api/v1/stream"))
        let connect = EventStream.buffered { request in
            (Data("data: a\n\n".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let response = try await connect(URLRequest(url: url))
        XCTAssertEqual(response.statusCode, 404)
        var chunks: [Data] = []
        for try await chunk in response.body { chunks.append(chunk) }
        XCTAssertEqual(chunks, [Data("data: a\n\n".utf8)])
    }

    func testStreamingReadsTheBodyALineAtATime() async throws {
        StubProtocol.chunks = [Data(": keep-alive\n\nevent: ti".utf8), Data("cket\ndata: x".utf8)]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let connect = EventStream.streaming(session: URLSession(configuration: configuration))

        let response = try await connect(URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:4000/api/v1/stream"))))
        XCTAssertEqual(response.statusCode, 200)
        var lines: [String] = []
        for try await chunk in response.body { lines.append(String(decoding: chunk, as: UTF8.self)) }
        XCTAssertEqual(lines, [": keep-alive\n", "\n", "event: ticket\n", "data: x"])
    }
}

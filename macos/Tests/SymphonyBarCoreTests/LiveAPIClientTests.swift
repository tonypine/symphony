import XCTest
@testable import SymphonyBarCore

/// A clock the test advances by hand: it records each scheduled poll and fires it on request.
@MainActor
private final class ManualScheduler: PollScheduler {
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

    /// The poll waiting to fire, if any.
    var pending: Scheduled? { scheduled.last.flatMap { $0.cancelled ? nil : $0 } }
}

@MainActor
final class LiveAPIClientTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var fetched: [String] = []
    private var answer = APIAnswer.answered(Data(#"{"build":{"version":"0.0.1.412"},"uptime_seconds":60}"#.utf8), statusCode: 200)

    override func setUp() {
        scheduler = ManualScheduler()
        fetched = []
    }

    private func client() -> LiveAPIClient {
        LiveAPIClient(
            fetch: { [unowned self] path in
                fetched.append(path)
                return answer
            },
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 1_791_000_000) }
        )
    }

    /// Fires the pending poll and waits for it.
    private func tick(_ client: LiveAPIClient) async throws {
        let pending = try XCTUnwrap(scheduler.pending)
        pending.action()
        await client.pollTask?.value
    }

    func testPollsEvery30SecondsWhileTheWindowIsHidden() async throws {
        let client = client()
        client.start()
        await client.pollTask?.value
        XCTAssertEqual(fetched, [LiveAPIClient.statePath])
        XCTAssertEqual(scheduler.pending?.interval, 30)

        try await tick(client)
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(scheduler.pending?.interval, 30)
    }

    func testPollsEvery2SecondsWhileTheWindowIsVisible() async throws {
        let client = client()
        client.start()
        await client.pollTask?.value

        client.isVisible = true
        // Showing the window polls straight away.
        await client.pollTask?.value
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(scheduler.pending?.interval, 2)

        try await tick(client)
        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(scheduler.pending?.interval, 2)
    }

    func testHidingTheWindowSlowsDownWithoutPolling() async {
        let client = client()
        client.isVisible = true
        client.start()
        await client.pollTask?.value
        let fast = scheduler.pending
        XCTAssertEqual(fast?.interval, 2)

        client.isVisible = false
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fast?.cancelled == true)
        XCTAssertEqual(scheduler.pending?.interval, 30)
    }

    func testNothingPollsBeforeStartOrAfterStop() async {
        let client = client()
        client.isVisible = true
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertNil(scheduler.pending)

        client.start()
        await client.pollTask?.value
        client.stop()
        XCTAssertNil(scheduler.pending)
    }

    func testRefreshDuringAPollPollsOnceMoreAfterIt() async {
        let client = client()
        client.start()
        let first = client.pollTask
        client.refresh()
        await first?.value
        await client.pollTask?.value
        XCTAssertEqual(fetched.count, 2)
    }

    func testKeepsTheStatePayloadAndWhenItCame() async throws {
        let client = client()
        client.start()
        await client.pollTask?.value

        XCTAssertEqual(client.diagnostics?.build?.version, "0.0.1.412")
        XCTAssertEqual(client.lastUpdate, Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertNil(client.stateResult)
        let text = try XCTUnwrap(client.stateJSONText)
        XCTAssertTrue(text.contains("\"uptime_seconds\" : 60"), text)

        // A later failure keeps the last payload for the views and says what happened.
        answer = .unreachable
        try await tick(client)
        XCTAssertEqual(client.diagnostics?.uptimeSeconds, 60)
        XCTAssertEqual(client.stateResult, .failed("Symphony isn't answering"))
    }

    func testASnapshotErrorKeepsTheLastPayload() async throws {
        let client = client()
        client.start()
        await client.pollTask?.value
        let first = client.stateJSON
        let firstUpdate = client.lastUpdate

        // Symphony answers a snapshot it couldn't take with 200 and an error in place of the state.
        answer = .answered(Data(#"{"generated_at":"2026-10-06T12:00:00Z","error":{"code":"snapshot_unavailable"}}"#.utf8), statusCode: 200)
        try await tick(client)
        XCTAssertEqual(client.stateJSON, first)
        XCTAssertEqual(client.diagnostics?.build?.version, "0.0.1.412")
        XCTAssertEqual(client.lastUpdate, firstUpdate)
        XCTAssertEqual(client.stateResult, .failed("snapshot_unavailable"))

        answer = .answered(Data(#"{"error":{"code":"snapshot_timeout","message":"Snapshot timed out"}}"#.utf8), statusCode: 200)
        try await tick(client)
        XCTAssertEqual(client.stateResult, .failed("Snapshot timed out"))

        answer = .answered(Data(#"{"error":{}}"#.utf8), statusCode: 200)
        try await tick(client)
        XCTAssertEqual(client.stateResult, .failed("Symphony reported an error"))

        // A 200 body that isn't a state payload is a failure too.
        answer = .answered(Data("not json".utf8), statusCode: 200)
        try await tick(client)
        XCTAssertEqual(client.stateJSON, first)
        XCTAssertEqual(client.stateResult, .failed("Symphony sent a state that couldn't be read"))
    }

    func testA404MeansUpdateSymphony() async {
        answer = .answered(Data("{}".utf8), statusCode: 404)
        let client = client()
        client.start()
        await client.pollTask?.value
        XCTAssertEqual(client.stateResult, .unsupported)
        XCTAssertNil(client.diagnostics)
        let other = await client.get("api/v1/inbox")
        XCTAssertEqual(other, .unsupported)
        XCTAssertEqual(EndpointPlaceholder.updateSymphony, "Update Symphony to see this view.")
    }

    func testEndpointResults() {
        XCTAssertEqual(EndpointResult(.answered(Data("x".utf8), statusCode: 200)), .loaded(Data("x".utf8)))
        XCTAssertEqual(EndpointResult(.answered(Data(), statusCode: 500)), .failed("Symphony answered with HTTP 500"))
        XCTAssertEqual(EndpointResult(.unreachable), .failed("Symphony isn't answering"))
    }

    func testFetchReadsThroughTheTransportAtTheControlURL() async {
        var requested: URL?
        let fetch = LiveAPIClient.fetch(base: { URL(string: "http://127.0.0.1:4010") }) { request in
            requested = request.url
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let answer = await fetch("api/v1/state")
        XCTAssertEqual(requested?.absoluteString, "http://127.0.0.1:4010/api/v1/state")
        XCTAssertEqual(answer, .answered(Data("{}".utf8), statusCode: 200))

        let none = LiveAPIClient.fetch(base: { nil }) { _ in throw URLError(.badURL) }
        let unreachable = await none("api/v1/state")
        XCTAssertEqual(unreachable, .unreachable)
    }
}

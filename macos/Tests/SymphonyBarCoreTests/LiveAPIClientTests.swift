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

    // MARK: - Publishing only what changed (TP-1480)

    private var clock = Date(timeIntervalSince1970: 1_791_000_000)

    /// A state payload with `running` entries and the time Symphony took it.
    private func state(_ generatedAt: String, running: [String] = ["TP-1"], uptime: Int = 60) -> APIAnswer {
        let entries = running.map { #"{"issue_identifier": "\#($0)", "state": "In Progress"}"# }.joined(separator: ",")
        let body = #"{"generated_at": "\#(generatedAt)", "build": {"version": "0.0.1.412"}, "uptime_seconds": \#(uptime), "counts": {"running": \#(running.count)}, "running": [\#(entries)]}"#
        return .answered(Data(body.utf8), statusCode: 200)
    }

    private func clockedClient() -> LiveAPIClient {
        LiveAPIClient(fetch: { [unowned self] _ in answer }, scheduler: scheduler, now: { [unowned self] in clock })
    }

    func testAPollThatMovesOnlyTheTimePublishesNothingButTheHeartbeat() async throws {
        answer = state("2026-11-12T10:00:00Z")
        let client = clockedClient()
        client.start()
        await client.pollTask?.value
        let first = try XCTUnwrap(client.stateJSON)
        XCTAssertEqual(client.overviewState?.running.map(\.identifier), ["TP-1"])

        var changes = 0
        let changed = client.objectWillChange.sink { changes += 1 }
        var beats = 0
        let beat = client.heartbeat.objectWillChange.sink { beats += 1 }
        var polled: [Data] = []
        let polls = client.statePolled.sink { polled.append($0) }

        answer = state("2026-11-12T10:00:02Z")
        clock += 2
        try await tick(client)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(beats, 1)
        XCTAssertEqual(client.lastUpdate, clock)
        XCTAssertEqual(client.stateJSON, first)
        XCTAssertEqual(polled.count, 1)
        // The newest payload is still at hand, for a read or the clipboard.
        guard case let .answered(newest, _) = answer else { return XCTFail() }
        XCTAssertEqual(client.latestStateJSON, newest)
        XCTAssertTrue(try XCTUnwrap(client.stateJSONText).contains("10:00:02"))

        // A changed state publishes what changed in it.
        answer = state("2026-11-12T10:00:04Z", running: ["TP-1", "TP-2"])
        clock += 2
        try await tick(client)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(client.overviewState?.running.map(\.identifier), ["TP-1", "TP-2"])
        XCTAssertNotEqual(client.stateJSON, first)

        // Diagnostics alone changed: the Overview's reading stays as it was.
        let overview = client.overviewState
        answer = state("2026-11-12T10:00:06Z", running: ["TP-1", "TP-2"], uptime: 66)
        clock += 2
        try await tick(client)
        XCTAssertEqual(client.diagnostics?.uptimeSeconds, 66)
        XCTAssertEqual(client.overviewState, overview)
        XCTAssertEqual(polled.count, 3)
        changed.cancel()
        beat.cancel()
        polls.cancel()
    }

    func testTheStateIsPublishedAgainOnceAMinuteSoTheCountedMinutesMove() async throws {
        answer = state("2026-11-12T10:00:00Z")
        let client = clockedClient()
        client.start()
        await client.pollTask?.value
        let generated = client.overviewState?.generatedAt

        var changes = 0
        let changed = client.objectWillChange.sink { changes += 1 }
        answer = state("2026-11-12T10:00:59Z")
        clock += 59
        try await tick(client)
        XCTAssertEqual(changes, 0)

        answer = state("2026-11-12T10:01:00Z")
        clock += 1
        try await tick(client)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertNotEqual(client.overviewState?.generatedAt, generated)
        changed.cancel()
    }

    func testAFailureRepeatedPublishesOnce() async throws {
        answer = .unreachable
        let client = clockedClient()
        client.start()
        await client.pollTask?.value
        XCTAssertEqual(client.stateResult, .failed("Symphony isn't answering"))

        var changes = 0
        let changed = client.objectWillChange.sink { changes += 1 }
        try await tick(client)
        XCTAssertEqual(changes, 0)
        changed.cancel()
    }

    func testTheStateIsReadOffTheMainThread() {
        let read = StateRead(state("2026-11-12T10:00:00Z"))
        XCTAssertNil(read.failure)
        XCTAssertEqual(read.parts?.overview?.running.map(\.identifier), ["TP-1"])
        // The time is not part of what the state says.
        XCTAssertEqual(read.parts?.content, StateRead(state("2026-11-12T11:00:00Z")).parts?.content)
        XCTAssertNotEqual(read.parts?.content, StateRead(state("2026-11-12T11:00:00Z", running: [])).parts?.content)
        XCTAssertNil(StateRead.content(Data("[1]".utf8)))
        XCTAssertTrue(LiveAPIClient.sameOverview(nil, nil))
        XCTAssertFalse(LiveAPIClient.sameOverview(nil, read.parts?.overview))
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

    func testReadsAPullRequestsPageAtItsPath() async {
        answer = .answered(Data(#"{"number": 448, "title": "TP-892 Retire two old review steps"}"#.utf8), statusCode: 200)
        let client = client()
        let result = await client.pullRequestPage(repoKey: "symphony", number: 448)
        XCTAssertEqual(fetched, ["api/v1/pull_requests/symphony/448"])
        guard case let .loaded(page) = result else { return XCTFail("not loaded: \(result)") }
        XCTAssertEqual(page.title, "TP-892 Retire two old review steps")

        answer = .answered(Data(#"{"error":{"code":"not_found","message":"Pull request not found"}}"#.utf8), statusCode: 404)
        let missing = await client.pullRequestPage(repoKey: "symphony", number: 9999)
        XCTAssertEqual(missing, .notFound)

        answer = .answered(Data(#"{"error":{"code":"request_failed","message":"Not Found"}}"#.utf8), statusCode: 404)
        let older = await client.pullRequestPage(repoKey: "symphony", number: 448)
        XCTAssertEqual(older, .unsupported)
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

    // MARK: - Conditional reads (TP-1492)

    func testConditionalFetchSendsTheTagAndReadsTheAnswersTag() async {
        var sent: [String?] = []
        let fetch = LiveAPIClient.conditionalFetch(base: { URL(string: "http://127.0.0.1:4010") }) { request in
            sent.append(request.value(forHTTPHeaderField: "If-None-Match"))
            let status = request.value(forHTTPHeaderField: "If-None-Match") == #""abc""# ? 304 : 200
            let headers = ["ETag": #""abc""#]
            let body = status == 304 ? Data() : Data("{}".utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        let first = await fetch("api/v1/SHOP-1", nil)
        XCTAssertEqual(first, TaggedAnswer(.answered(Data("{}".utf8), statusCode: 200), etag: #""abc""#))
        let second = await fetch("api/v1/SHOP-1", #""abc""#)
        XCTAssertEqual(second, TaggedAnswer(.answered(Data(), statusCode: 304), etag: #""abc""#))
        XCTAssertEqual(sent, [nil, #""abc""#])

        let none = LiveAPIClient.conditionalFetch(base: { nil }) { _ in throw URLError(.badURL) }
        let unreachable = await none("api/v1/SHOP-1", nil)
        XCTAssertEqual(unreachable, TaggedAnswer(.unreachable))
        let failing = LiveAPIClient.conditionalFetch(base: { URL(string: "http://127.0.0.1:4010") }) { _ in throw URLError(.timedOut) }
        let failed = await failing("api/v1/SHOP-1", #""abc""#)
        XCTAssertEqual(failed, TaggedAnswer(.unreachable))
    }

    func testAConditionalResultIsUnchangedOnlyForA304ToASentTag() {
        let body = Data("{}".utf8)
        XCTAssertEqual(ConditionalResult(TaggedAnswer(.answered(Data(), statusCode: 304), etag: "t"), sent: "t"), .unchanged)
        XCTAssertEqual(
            ConditionalResult(TaggedAnswer(.answered(Data(), statusCode: 304)), sent: nil),
            .changed(.failed("Symphony answered with HTTP 304"), etag: nil)
        )
        XCTAssertEqual(ConditionalResult(TaggedAnswer(.answered(body, statusCode: 200), etag: "t"), sent: nil), .changed(.loaded(body), etag: "t"))
        XCTAssertEqual(ConditionalResult(TaggedAnswer(.answered(body, statusCode: 404), etag: "t"), sent: "s"), .changed(.unsupported, etag: nil))
    }

    func testReadsSendTheHeldTagAndKeepThePageOnA304() async {
        let body = Data(#"{"identifier":"SHOP-1"}"#.utf8)
        var sent: [String?] = []
        var status = 200
        let client = LiveAPIClient(
            fetch: { _ in .unreachable },
            conditional: { _, tag in
                sent.append(tag)
                if status == 200 { return TaggedAnswer(.answered(body, statusCode: 200), etag: "v1") }
                if status == 304, tag == "v1" { return TaggedAnswer(.answered(Data(), statusCode: 304), etag: "v1") }
                return TaggedAnswer(.answered(Data(), statusCode: status))
            },
            scheduler: scheduler
        )
        var reads = ConditionalReads()
        let first = await client.read("api/v1/SHOP-1", through: &reads)
        XCTAssertEqual(first, .changed(body))
        XCTAssertEqual(reads.tag(for: "api/v1/SHOP-1"), "v1")

        status = 304
        let second = await client.read("api/v1/SHOP-1", through: &reads)
        XCTAssertEqual(second, .unchanged)
        XCTAssertEqual(reads.tag(for: "api/v1/SHOP-1"), "v1")

        // A failure drops the tag: the next read is in full.
        status = 500
        let third = await client.read("api/v1/SHOP-1", through: &reads)
        XCTAssertEqual(third, .changed(nil))
        XCTAssertNil(reads.tag(for: "api/v1/SHOP-1"))
        XCTAssertEqual(sent, [nil, "v1", "v1"])
    }

    func testWithoutAConditionalFetchEveryReadIsInFull() async {
        let body = Data("{}".utf8)
        let client = LiveAPIClient(fetch: { _ in .answered(body, statusCode: 200) }, scheduler: scheduler)
        let result = await client.get("api/v1/SHOP-1", ifNoneMatch: "v1")
        XCTAssertEqual(result, .changed(.loaded(body), etag: nil))
    }
}

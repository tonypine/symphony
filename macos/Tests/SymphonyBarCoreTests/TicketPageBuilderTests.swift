import Foundation
import XCTest
@testable import SymphonyBarCore

/// TP-1479: the window stores the ticket page and its Timeline, built off the main actor only when a source changed.
@MainActor
final class TicketPageBuilderTests: XCTestCase {
    /// A state poll: the ticket shown running, another ticket beside it, and the parts the page never reads.
    private func state(generatedAt: String, otherTokens: Int = 10, ownTokens: Int = 5) -> Data {
        Data("""
        {"generated_at": "\(generatedAt)",
         "counts": {"running": 2},
         "codex_totals": {"total_tokens": \(ownTokens + otherTokens)},
         "running": [
           {"issue_identifier": "TP-1", "title": "One", "repo_key": "symphony", "state": "In Progress",
            "started_at": "2026-11-12T09:00:00Z", "tokens": {"total_tokens": \(ownTokens)}},
           {"issue_identifier": "TP-2", "title": "Two", "repo_key": "symphony", "state": "In Progress",
            "started_at": "2026-11-12T09:30:00Z", "tokens": {"total_tokens": \(otherTokens)}}
         ],
         "issues": [{"identifier": "TP-2", "watch": {}}],
         "budget": {"per_issue_limit": 1000}}
        """.utf8)
    }

    private func sources(state: Data, issue: String? = nil) -> TicketPage.Sources {
        TicketPage.Sources(state: state, issue: issue.map { Data($0.utf8) })
    }

    // MARK: - Building once per change

    func testAPollTickWithUnchangedSourcesBuildsNothingAndOneChangedSourceBuildsOnce() async throws {
        let builder = TicketPageBuilder()
        await builder.update(identifier: "TP-1", sources: sources(state: state(generatedAt: "2026-11-12T10:00:00Z")))
        XCTAssertEqual(builder.builds, 1)
        let first = try XCTUnwrap(builder.model)
        XCTAssertEqual(first.identifier, "TP-1")
        XCTAssertEqual(first.title, "One")
        XCTAssertEqual(first.repoKey, "symphony")
        XCTAssertEqual(first.timeline, first.page.timelineModel(calendar: .current))

        // The same bytes again, then a poll that only moved Symphony's clock and another ticket's tokens: no build.
        await builder.update(identifier: "TP-1", sources: sources(state: state(generatedAt: "2026-11-12T10:00:00Z")))
        await builder.update(identifier: "TP-1", sources: sources(state: state(generatedAt: "2026-11-12T10:00:05Z", otherTokens: 99)))
        XCTAssertEqual(builder.builds, 1)
        XCTAssertEqual(builder.model, first)

        // One source changed (the ticket read): one build, published.
        await builder.update(
            identifier: "TP-1",
            sources: sources(state: state(generatedAt: "2026-11-12T10:00:10Z", otherTokens: 99), issue: #"{"repo_key": "elsewhere"}"#)
        )
        XCTAssertEqual(builder.builds, 2)
        XCTAssertEqual(builder.model?.repoKey, "elsewhere")

        // The ticket's own entry in the state changed: one more.
        await builder.update(
            identifier: "TP-1",
            sources: sources(state: state(generatedAt: "2026-11-12T10:00:15Z", otherTokens: 99, ownTokens: 6), issue: #"{"repo_key": "elsewhere"}"#)
        )
        XCTAssertEqual(builder.builds, 3)
        XCTAssertEqual(builder.model?.page.runTokens, 6)
    }

    func testTheBuildRunsOffTheMainThreadAndPublishesOnce() async {
        let onMain = Locked(false)
        let builder = TicketPageBuilder { key in
            onMain.set(Thread.isMainThread)
            return TicketPageModel.build(key)
        }
        var published: [TicketPageModel?] = []
        let subscription = builder.$model.dropFirst().sink { published.append($0) }
        await builder.update(identifier: "TP-1", sources: sources(state: state(generatedAt: "2026-11-12T10:00:00Z")))
        await builder.update(identifier: "TP-1", sources: sources(state: state(generatedAt: "2026-11-12T10:00:05Z")))
        subscription.cancel()

        XCTAssertFalse(onMain.value)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first??.identifier, "TP-1")
    }

    func testLeavingThePageClearsItAndAnotherTicketBuildsItsOwn() async {
        let builder = TicketPageBuilder()
        let poll = sources(state: state(generatedAt: "2026-11-12T10:00:00Z"))
        await builder.update(identifier: "TP-1", sources: poll)
        await builder.update(identifier: nil, sources: poll)
        XCTAssertNil(builder.model)
        // Clearing twice publishes nothing more.
        await builder.update(identifier: nil, sources: poll)
        XCTAssertNil(builder.model)

        await builder.update(identifier: "TP-2", sources: poll)
        XCTAssertEqual(builder.model?.title, "Two")
        XCTAssertEqual(builder.builds, 2)
        // Back on TP-1: built again, since the page shown was another.
        await builder.update(identifier: "TP-1", sources: poll)
        XCTAssertEqual(builder.model?.title, "One")
        XCTAssertEqual(builder.builds, 3)
    }

    func testANewerUpdateWinsOverOneStillOnItsWay() async {
        let builder = TicketPageBuilder()
        let first = Task { await builder.update(identifier: "TP-1", sources: sources(state: state(generatedAt: "2026-11-12T10:00:00Z"))) }
        let second = Task { await builder.update(identifier: "TP-2", sources: sources(state: state(generatedAt: "2026-11-12T10:00:00Z"))) }
        await first.value
        await second.value
        XCTAssertEqual(builder.model?.identifier, "TP-2")
    }

    func testAnUpdateForTheKeyBeingBuiltWaitsForThatBuild() async {
        let gate = Gate()
        let builder = TicketPageBuilder { key in
            gate.wait()
            return TicketPageModel.build(key)
        }
        let poll = sources(state: state(generatedAt: "2026-11-12T10:00:00Z"))
        let first = Task { await builder.update(identifier: "TP-1", sources: poll) }
        // Wait until the first build is under way.
        for _ in 0 ..< 1_000 where builder.builds == 0 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(builder.builds, 1)
        await builder.update(identifier: "TP-1", sources: poll)
        XCTAssertEqual(builder.builds, 1)
        gate.open()
        await first.value
        XCTAssertEqual(builder.builds, 1)
        XCTAssertEqual(builder.model?.identifier, "TP-1")
    }

    // MARK: - The state the page reads

    func testTheStateSliceKeepsTheTicketsOwnEntriesAndTheBlocksThePageReads() throws {
        let slice = try XCTUnwrap(TicketPage.stateSlice(state(generatedAt: "2026-11-12T10:00:00Z"), identifier: "TP-1"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: slice) as? [String: Any])

        XCTAssertNil(object["generated_at"])
        XCTAssertNil(object["counts"])
        XCTAssertNil(object["codex_totals"])
        let running = try XCTUnwrap(object["running"] as? [[String: Any]])
        XCTAssertEqual(running.map { $0["issue_identifier"] as? String }, ["TP-1"])
        XCTAssertEqual((object["issues"] as? [Any])?.count, 0)
        XCTAssertNotNil(object["budget"])
        // The same parts give the same bytes, whatever the time.
        XCTAssertEqual(TicketPage.stateSlice(state(generatedAt: "2026-11-12T11:00:00Z", otherTokens: 7), identifier: "TP-1"), slice)
        XCTAssertNil(TicketPage.stateSlice(Data("[1]".utf8), identifier: "TP-1"))
    }

    func testTheKeyCutsTheStateAndKeepsTheOtherSources() {
        let key = TicketPageKey(identifier: "TP-1", sources: TicketPage.Sources(state: Data("not json".utf8), issue: Data("{}".utf8)))
        XCTAssertNil(key.sources.state)
        XCTAssertEqual(key.sources.issue, Data("{}".utf8))
    }
}

/// A value the build closure writes from another thread.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) { lock.withLock { stored = value } }
}

/// Holds a build until the test opens it.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() { semaphore.wait() }

    func open() { semaphore.signal() }
}

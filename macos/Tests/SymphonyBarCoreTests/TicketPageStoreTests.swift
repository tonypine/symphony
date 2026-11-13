import Combine
import Foundation
import XCTest
@testable import SymphonyBarCore

/// TP-1480: the ticket page observes its own store; a poll that changes nothing reaches nothing on it, and an event
/// that changes only the timeline publishes only the Timeline.
@MainActor
final class TicketPageStoreTests: XCTestCase {
    /// A state poll: the ticket shown running and another ticket beside it.
    private func state(generatedAt: String, otherTokens: Int = 10) -> Data {
        Data("""
        {"generated_at": "\(generatedAt)",
         "counts": {"running": 2},
         "running": [
           {"issue_identifier": "TP-1", "title": "One", "repo_key": "symphony", "state": "In Progress",
            "started_at": "2026-11-12T09:00:00Z", "tokens": {"total_tokens": 5}},
           {"issue_identifier": "TP-2", "title": "Two", "repo_key": "symphony", "state": "In Progress",
            "started_at": "2026-11-12T09:30:00Z", "tokens": {"total_tokens": \(otherTokens)}}
         ],
         "budget": {"per_issue_limit": 1000}}
        """.utf8)
    }

    /// The ticket's events feed: two moves, the second titled `title`.
    private func events(secondTitle title: String = "Entered In Progress from Todo") throws -> TicketEventsPayload {
        let feed = """
        {"timeline": [
          {"id": "a1", "seq": 1, "at": "2026-11-12T08:00:00Z", "type": "ticket.moved", "actor": {"kind": "person", "name": "Tony"},
           "payload": {"from": "Backlog", "to": "Todo"}, "summary": {"title": "Moved to Todo from Backlog"}, "artifacts": [], "children": [], "new": false},
          {"id": "a2", "seq": 2, "at": "2026-11-12T08:30:00Z", "type": "phase.entered", "actor": {"kind": "machine"},
           "payload": {"from": "Todo", "to": "In Progress"}, "summary": {"title": "\(title)"}, "artifacts": [], "children": [], "new": false}
        ], "next_since": "2"}
        """
        return try XCTUnwrap(TicketEventsPayload.decode(Data(feed.utf8)))
    }

    private func sources(state: Data?, events: TicketEventsPayload?) -> TicketPage.Sources {
        TicketPage.Sources(state: state, issue: Data(#"{"repo_key": "symphony"}"#.utf8), events: events, feedAbsence: .unread)
    }

    /// Counts what an object publishes.
    private final class Counter {
        var count = 0
        private var subscription: AnyCancellable?

        init(_ publisher: ObservableObjectPublisher) {
            subscription = publisher.sink { [unowned self] in count += 1 }
        }
    }

    func testTwoIdenticalPollTicksReachNothingOnTheTicketPage() async throws {
        var answer = APIAnswer.answered(state(generatedAt: "2026-11-12T10:00:00Z"), statusCode: 200)
        let client = LiveAPIClient(fetch: { _ in answer }, scheduler: RunLoopScheduler())
        let store = TicketPageStore()
        let feed = try events()

        // The first poll builds the page.
        await client.refresh().value
        await store.update(identifier: "TP-1", sources: sources(state: client.latestStateJSON, events: feed))
        XCTAssertEqual(store.page?.identifier, "TP-1")
        XCTAssertNotNil(store.timeline.model)
        XCTAssertEqual(store.builder.builds, 1)

        let clientChanges = Counter(client.objectWillChange)
        let pageChanges = Counter(store.objectWillChange)
        let timelineChanges = Counter(store.timeline.objectWillChange)
        var polls = 0
        let polled = client.statePolled.sink { _ in polls += 1 }

        // Two more polls that move only Symphony's clock: the window reads after each, and the page takes nothing.
        for second in ["05", "07"] {
            answer = .answered(state(generatedAt: "2026-11-12T10:00:\(second)Z"), statusCode: 200)
            await client.refresh().value
            await store.update(identifier: "TP-1", sources: sources(state: client.latestStateJSON, events: feed))
        }
        polled.cancel()

        XCTAssertEqual(polls, 2)
        XCTAssertEqual(clientChanges.count, 0)
        XCTAssertEqual(pageChanges.count, 0)
        XCTAssertEqual(timelineChanges.count, 0)
        XCTAssertEqual(store.builder.builds, 1)
    }

    func testOneChangedEventPublishesOnlyTheTimeline() async throws {
        let store = TicketPageStore()
        let state = state(generatedAt: "2026-11-12T10:00:00Z")
        await store.update(identifier: "TP-1", sources: sources(state: state, events: try events()))
        let page = try XCTUnwrap(store.page)
        let before = try XCTUnwrap(store.timeline.model)

        let pageChanges = Counter(store.objectWillChange)
        let timelineChanges = Counter(store.timeline.objectWillChange)
        await store.update(identifier: "TP-1", sources: sources(state: state, events: try events(secondTitle: "Entered QA from In Progress")))

        XCTAssertEqual(store.builder.builds, 2)
        XCTAssertEqual(timelineChanges.count, 1)
        XCTAssertEqual(pageChanges.count, 0)
        XCTAssertEqual(store.page, page)
        XCTAssertNotEqual(store.timeline.model, before)
        // The whole page, its events too, is still what the window reads.
        XCTAssertEqual(store.model?.page.history?.events.count, 2)
    }

    func testTheShellKeepsTheRunsAndDropsTheEventsAndSteps() throws {
        var page = TicketPage(identifier: "TP-1", sources: sources(state: nil, events: try events()), now: Date(), timeZone: .current)
        XCTAssertFalse(page.timeline.isEmpty)
        let shell = TicketPageStore.shell(page)
        XCTAssertEqual(shell.timeline, [])
        XCTAssertEqual(shell.history?.events, [])
        XCTAssertEqual(shell.history?.runs, page.history?.runs)

        // A page that differs only in the moment it measures against shows the same.
        let same = shell
        page = shell
        page.reference = page.reference.addingTimeInterval(60)
        XCTAssertTrue(TicketPageStore.same(same, page))
        XCTAssertTrue(TicketPageStore.same(nil, nil))
        XCTAssertFalse(TicketPageStore.same(nil, page))
        page.title = "Another"
        XCTAssertFalse(TicketPageStore.same(same, page))
    }

    func testTheTimelineStorePublishesOnlyWhatDiffers() {
        let timeline = TicketTimelineStore()
        let changes = Counter(timeline.objectWillChange)
        timeline.show(nil)
        XCTAssertEqual(changes.count, 0)

        let model = TimelineModel(days: [], reference: Date(timeIntervalSince1970: 1))
        timeline.show(model)
        XCTAssertEqual(changes.count, 1)
        // The same timeline measured against another moment draws nothing.
        timeline.show(TimelineModel(days: [], reference: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(changes.count, 1)
        timeline.show(TimelineModel(days: [], marker: nil, reference: nil))
        XCTAssertEqual(changes.count, 1)
        timeline.show(nil)
        XCTAssertEqual(changes.count, 2)
    }

    func testTheContextPublishesOnlyWhenItDiffers() {
        let store = TicketPageStore()
        let changes = Counter(store.objectWillChange)
        store.show(TicketPageContext())
        XCTAssertEqual(changes.count, 0)
        store.show(TicketPageContext(sending: true, failure: "Refused", reviewItemID: "issue-1"))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(store.context.reviewItemID, "issue-1")
        store.show(TicketPageContext(sending: true, failure: "Refused", reviewItemID: "issue-1"))
        XCTAssertEqual(changes.count, 1)
    }

    func testLeavingThePageClearsItAndCallsBack() async throws {
        let store = TicketPageStore()
        var built: [String?] = []
        store.onBuilt = { built.append($0?.identifier) }
        await store.update(identifier: "TP-1", sources: sources(state: nil, events: try events()))
        await store.update(identifier: nil, sources: TicketPage.Sources())
        XCTAssertNil(store.page)
        XCTAssertNil(store.timeline.model)
        XCTAssertNil(store.model)
        XCTAssertEqual(built, ["TP-1", nil])
    }
}

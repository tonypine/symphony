import Foundation
@testable import SymphonyBarCore
import XCTest

/// The ticket page's marks (TP-1451): the read's `looked_at` and `new_since_looked`, and the look the page sends once
/// per visit, on leaving it, never from a read.
final class TicketMarksTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/director-app/ticket-marks", isDirectory: true)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: - The read

    func testTheReadSaysWhenThePersonLookedAndHowManyAreNew() throws {
        let read = try XCTUnwrap(TicketMarksRead.decode(Data(#"{"looked_at": "2026-10-08T16:50:00Z", "new_since_looked": 3}"#.utf8)))
        XCTAssertEqual(read, TicketMarksRead(lookedAt: date("2026-10-08T16:50:00Z"), newSinceLooked: 3))
        XCTAssertEqual(read.newText, "3 new")
        XCTAssertEqual(read.newAccessibilityLabel, "3 new since you last looked")
        XCTAssertEqual(TicketMarksRead.markerText(date("2026-10-08T16:50:00Z"), clock: TimelineModel.clock(utc)), "Since you last looked, at 16:50")
    }

    func testAFirstVisitAndNothingNewShowNoCount() throws {
        // Never looked: the read counts every event, and the page says nothing is new yet.
        let first = try XCTUnwrap(TicketMarksRead.decode(Data(#"{"looked_at": null, "new_since_looked": 12}"#.utf8)))
        XCTAssertNil(first.lookedAt)
        XCTAssertNil(first.newText)
        XCTAssertNil(first.newAccessibilityLabel)
        XCTAssertNil(TicketMarksRead(lookedAt: date("2026-10-08T16:50:00Z"), newSinceLooked: 0).newText)
        // A Symphony that predates the marks sends neither.
        XCTAssertEqual(TicketMarksRead.decode(Data(#"{"issue_identifier": "TP-1"}"#.utf8)), TicketMarksRead())
        XCTAssertEqual(TicketMarksRead.decode(Data(#"{"new_since_looked": -2}"#.utf8))?.newSinceLooked, 0)
        XCTAssertNil(TicketMarksRead.decode(Data("[]".utf8)))
    }

    func testThePageCarriesTheMarksOfItsRead() {
        let issue = Data(#"{"issue_identifier": "TP-1", "looked_at": "2026-10-08T16:50:00Z", "new_since_looked": 2}"#.utf8)
        let page = TicketPage(identifier: "TP-1", sources: TicketPage.Sources(issue: issue))
        XCTAssertEqual(page.marksRead?.newText, "2 new")
        XCTAssertNil(TicketPage(identifier: "TP-1", sources: TicketPage.Sources()).marksRead)
    }

    // MARK: - The look

    func testTheLookGoesOnceWhenThePageIsLeftAndNeverWhileItIsShown() {
        let opened = date("2026-10-08T16:50:00Z")
        var look = TicketLook()
        XCTAssertNil(look.show("TP-1", at: opened))
        XCTAssertFalse(look.looks(at: opened.addingTimeInterval(1)))
        // The same page shown again (a read, the place set again) is the same visit.
        XCTAssertNil(look.show("TP-1", at: opened.addingTimeInterval(30)))
        look.repoKnown("other", for: "TP-2")
        look.repoKnown("", for: "TP-1")
        look.repoKnown(nil, for: "TP-1")
        XCTAssertNil(look.visit?.repoKey)
        look.repoKnown("symphony", for: "TP-1")
        XCTAssertTrue(look.looks(at: opened.addingTimeInterval(TicketLook.minimumVisit)))
        // Another ticket's page: the first one's look, and a new visit.
        XCTAssertEqual(look.show("TP-2", at: opened.addingTimeInterval(60)), .looked("TP-1", repoKey: "symphony"))
        XCTAssertEqual(look.visit?.identifier, "TP-2")
        // Passed through in a second: no look.
        XCTAssertNil(look.show(nil, at: opened.addingTimeInterval(61)))
        XCTAssertNil(look.visit)
        XCTAssertNil(look.leave(at: opened.addingTimeInterval(90)))
        XCTAssertFalse(look.looks(at: opened.addingTimeInterval(90)))
        // The window closing leaves the page shown, once.
        XCTAssertNil(look.show("TP-3", at: opened))
        XCTAssertEqual(look.leave(at: opened.addingTimeInterval(5)), .looked("TP-3", repoKey: nil))
        XCTAssertNil(look.leave(at: opened.addingTimeInterval(6)))
    }

    func testTheLookIsAViewMarkPostedToSymphony() throws {
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:4000"))
        let request = ControlAPI.request(.looked("TP-1", repoKey: "symphony"), base: base, token: "secret")
        XCTAssertEqual(request.url?.path, "/api/v1/control/looked")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["issue_identifier": "TP-1", "repo_key": "symphony"])
        XCTAssertEqual(ControlAction.looked("TP-1", repoKey: nil).body as? [String: String], ["issue_identifier": "TP-1"])
        XCTAssertNil(ControlAction.looked("TP-1", repoKey: nil).moveIdentifier)
        XCTAssertEqual(
            ControlAPI.result(.looked("TP-1", repoKey: nil), statusCode: 200, data: Data(#"{"new_since_looked": 0}"#.utf8)), .done
        )
        XCTAssertEqual(
            ControlAPI.result(.looked("TP-1", repoKey: nil), statusCode: 404, data: Data()),
            .failed("Couldn't mark TP-1 as looked at: HTTP 404")
        )
    }

    /// The fixture server: the page read three times while it is open sends nothing; leaving it sends the look once,
    /// and the next visit's read, as Symphony serves it after the look, has nothing new.
    @MainActor
    func testWithTheFixtureServerTheLookIsSentOnceAndTheCountFollowsTheRead() async throws {
        let root = uniqueTemporaryDirectory("ticket-marks")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = APIFixtures(directory: Self.fixtures, requestLog: root.appendingPathComponent("requests.jsonl"))
        let client = LiveAPIClient(fetch: LiveAPIClient.fetch(base: { APIFixtures.baseURL }, transport: fixtures.transport))
        func read() async throws -> TicketPage {
            let answer = await client.get(TicketPage.issuePath("SHOP-412"))
            guard case let .loaded(data) = answer else { return TicketPage(identifier: "SHOP-412", sources: TicketPage.Sources()) }
            return TicketPage(identifier: "SHOP-412", sources: TicketPage.Sources(issue: data))
        }
        func looks() -> [[String: Any]] {
            let text = (try? String(contentsOf: fixtures.requestLog, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { $0["path"] as? String == "/api/v1/control/looked" }
        }

        let opened = date("2026-10-08T16:50:00Z")
        var look = TicketLook()
        XCTAssertNil(look.show("SHOP-412", at: opened))
        for second in 1 ... 3 {
            // A refresh while the page is open: the count follows the read, and nothing is sent.
            let page = try await read()
            XCTAssertEqual(page.marksRead?.lookedAt, date("2026-10-08T09:30:00Z"))
            XCTAssertEqual(page.marksRead?.newText, "3 new")
            look.repoKnown(page.repoKey, for: page.identifier)
            XCTAssertNil(look.show("SHOP-412", at: opened.addingTimeInterval(TimeInterval(second))))
        }
        XCTAssertTrue(looks().isEmpty)

        // The note panel says which run read the note, from the same read and the feed's run.
        let feed = TicketEventsReader(get: { TicketEventsResult(await client.answer($0)) })
        feed.follow(identifier: "SHOP-412", repoKey: "web-shop")
        await feed.settle()
        let history = try XCTUnwrap(feed.events)
        let page = try await read()
        let note = NotePanelModel.build(
            note: page.detailsRead?.note, move: nil, runs: history.runs, reference: date("2026-10-08T17:00:00Z"), calendar: utc
        )
        XCTAssertEqual(note.current?.readLine, "Read by implementation run 3 at 14:02")
        // The timeline: the marker above the newest thing seen, the dots on the note and the run.
        let timeline = TimelineModel.build(history, reference: date("2026-10-08T17:00:00Z"), calendar: utc, lookedAt: page.marksRead?.lookedAt)
        XCTAssertEqual(timeline.marker?.before, "entry-a1")
        XCTAssertEqual(timeline.items.filter(\.isNew).map(\.id), ["run-run-3", "entry-n1"])

        // Leaving the page: the look, once.
        let action = try XCTUnwrap(look.show(nil, at: opened.addingTimeInterval(30)))
        XCTAssertEqual(action, .looked("SHOP-412", repoKey: "web-shop"))
        let result = await ControlAPI.send(
            action, stateRoot: root, fallback: APIFixtures.baseURL, token: APIFixtures.token, transport: fixtures.transport
        )
        XCTAssertEqual(result, .done)
        XCTAssertNil(look.show(nil, at: opened.addingTimeInterval(31)))
        XCTAssertNil(look.leave(at: opened.addingTimeInterval(32)))
        let sent = looks()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["body"] as? [String: String], ["issue_identifier": "SHOP-412", "repo_key": "web-shop"])

        // The next visit: the read Symphony serves after the look has nothing new.
        let next = try await read()
        XCTAssertEqual(next.marksRead?.lookedAt, date("2026-10-08T16:50:00Z"))
        XCTAssertEqual(next.marksRead?.newSinceLooked, 0)
        XCTAssertNil(next.marksRead?.newText)
    }
}

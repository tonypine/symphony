import Foundation
import XCTest
@testable import SymphonyBarCore

/// The Situation line (C31, `director-ticket-page.md` §3): the ticket read's `situation` as the app decodes it from
/// `test/fixtures/api/situations.json`, one ticket per kind, and the words each kind's line says.
final class SituationTests: XCTestCase {
    private struct Sample {
        var now: Date
        var situations: [String: Situation]
    }

    private func sample() throws -> Sample {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test/fixtures/api/situations.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let now = try XCTUnwrap((root["now"] as? String).flatMap(SymphonyState.parseDate))
        let issues = try XCTUnwrap(root["issues"] as? [[String: Any]])
        var situations: [String: Situation] = [:]
        for issue in issues {
            let situation = try XCTUnwrap(Situation.decode(object: issue["situation"]), "\(issue["identifier"] ?? "?")")
            situations[situation.kind.apiKind] = situation
        }
        return Sample(now: now, situations: situations)
    }

    private func line(_ kind: String) throws -> (Situation, SituationText) {
        let sample = try sample()
        let situation = try XCTUnwrap(sample.situations[kind], "the fixture has no \(kind)")
        return (situation, SituationText(situation, reference: sample.now))
    }

    private func date(_ text: String) -> Date? { SymphonyState.parseDate(text) }

    // MARK: - The fixture

    func testTheFixtureCarriesEveryKindOnce() throws {
        XCTAssertEqual(Set(try sample().situations.keys), Set(DesignTokens.SituationKind.allCases.map(\.apiKind)))
    }

    func testEachAPIKindNamesOneOfTheTenKinds() {
        XCTAssertEqual(
            DesignTokens.SituationKind.allCases.map(\.apiKind),
            ["waiting_on_you", "retrying", "blocked_by_ticket", "paused_by_rule", "waiting_for_ci", "waiting_for_build",
             "waiting_for_slot", "working", "done", "cancelled"]
        )
        for kind in DesignTokens.SituationKind.allCases {
            XCTAssertEqual(DesignTokens.SituationKind(apiKind: kind.apiKind), kind)
        }
        XCTAssertNil(DesignTokens.SituationKind(apiKind: "needs_attention"))
    }

    // MARK: - One test per kind

    func testWorkingOnAStep() throws {
        let (situation, text) = try line("working")
        XCTAssertEqual(situation.kind, .working)
        XCTAssertEqual(situation.step, Situation.Step(id: "tests", title: "Tests and coverage"))
        XCTAssertEqual(situation.run, Situation.Run(id: "run-2", kind: "rework", number: 2, label: "Implementation run 2"))
        XCTAssertEqual(situation.since, date("2026-10-30T16:09:00Z"))
        XCTAssertEqual(
            text.sentence,
            "Working on the tests step · Implementation run 2 is answering Code Review's finding. · It hands off to Code Review when it pushes. · for 8 min"
        )
        XCTAssertEqual(text.age, "8 min")
        XCTAssertEqual(text.kind.status, .working)
        XCTAssertEqual(text.kind.symbol, "circle.dotted.circle")
    }

    func testWaitingForASlot() throws {
        let (situation, text) = try line("waiting_for_slot")
        XCTAssertEqual(situation.kind, .slot)
        XCTAssertEqual(
            text.sentence,
            "Waiting for a slot · Three runs are ahead of it; Symphony runs four at a time. · Starts when a slot frees. · for 12 min"
        )
        XCTAssertEqual(text.kind.status, .idle)
        XCTAssertEqual(text.kind.symbol, "clock")
    }

    func testWaitingForCI() throws {
        let (situation, text) = try line("waiting_for_ci")
        XCTAssertEqual(situation.kind, .ci)
        XCTAssertEqual(text.sentence, "Waiting for CI · Checks are running on PR #741. · Code Review starts when they pass. · for 6 min")
        XCTAssertEqual(text.kind.status, .working)
    }

    func testWaitingForABuild() throws {
        let (situation, text) = try line("waiting_for_build")
        XCTAssertEqual(situation.kind, .build)
        XCTAssertEqual(
            text.sentence,
            "Waiting for a build · The app for this commit is being built for QA. · QA starts when the build is ready. · for 4 min"
        )
        XCTAssertEqual(text.kind.status, .working)
        XCTAssertEqual(text.kind.symbol, "shippingbox")
    }

    func testWaitingOnYou() throws {
        let (situation, text) = try line("waiting_on_you")
        XCTAssertEqual(situation.kind, .you)
        XCTAssertEqual(
            text.sentence,
            "Waiting on you · Implementation run 3 asked how the paused line's times should read. · Answer below; the next run starts at once. · for 8 min"
        )
        XCTAssertEqual(text.kind.status, .you)
    }

    func testBlockedByATicket() throws {
        let (situation, text) = try line("blocked_by_ticket")
        XCTAssertEqual(situation.kind, .blocked)
        XCTAssertEqual(text.sentence, "Blocked by TP-1251 · It is in Code Review. · Starts when TP-1251 lands. · for 17 h")
        XCTAssertEqual(text.kind.status, .idle)
        XCTAssertEqual(text.kind.symbol, "lock.fill")
    }

    func testPausedByARule() throws {
        let (situation, text) = try line("paused_by_rule")
        XCTAssertEqual(situation.kind, .paused)
        XCTAssertEqual(situation.andMore, 0)
        XCTAssertEqual(text.sentence, "Paused · Dispatch is paused: Deploy freeze. · Starts when you resume dispatch. · for 1 h 4 min")
        XCTAssertEqual(text.kind.status, .idle)
    }

    func testRetrying() throws {
        let (situation, text) = try line("retrying")
        XCTAssertEqual(situation.kind, .retrying)
        XCTAssertEqual(situation.retry, Situation.Retry(attempt: 2, of: 3, at: date("2026-10-30T16:20:00Z")))
        XCTAssertEqual(text.sentence, "Retrying · The run stopped: the agent hit its usage limit. · Try 2 of 3 starts at 16:20. · for 3 min")
        XCTAssertEqual(text.kind.status, .problem)
        XCTAssertEqual(text.kind.symbol, "arrow.clockwise")
    }

    func testShippedHasNoNextAndNoAge() throws {
        let (situation, text) = try line("done")
        XCTAssertEqual(situation.kind, .done)
        XCTAssertNil(text.next)
        XCTAssertNil(text.age)
        XCTAssertEqual(text.sentence, "Shipped · Merged as PR #741 at 21:05.")
        XCTAssertEqual(text.spoken(), "Shipped: Merged as PR #741 at 21:05.")
        XCTAssertEqual(text.kind.status, .done)
    }

    func testCancelledSaysHowLongAgo() throws {
        let (situation, text) = try line("cancelled")
        XCTAssertEqual(situation.kind, .cancelled)
        XCTAssertEqual(text.sentence, "Cancelled · You cancelled it; PR #812 was closed. · 2 days ago")
        XCTAssertEqual(text.age, "2 days ago")
        XCTAssertEqual(text.spoken(), "Cancelled, 2 days ago: You cancelled it; PR #812 was closed.")
        XCTAssertEqual(text.kind.symbol, "circle.slash")
    }

    // MARK: - The line's words

    func testAndMoreJoinsTheCause() throws {
        var (situation, _) = try line("paused_by_rule")
        situation.andMore = 2
        let text = SituationText(situation, reference: try sample().now)
        XCTAssertEqual(text.cause, "Dispatch is paused: Deploy freeze, and 2 more.")
        XCTAssertEqual(SituationText.cause("Held by Deploy freeze", andMore: 1), "Held by Deploy freeze, and 1 more.")
        XCTAssertEqual(SituationText.cause("", andMore: 3), "And 3 more.")
    }

    func testVoiceOverReadsTheWordTheAgeAndTheCauseAsOneSentence() throws {
        let (_, text) = try line("waiting_for_ci")
        XCTAssertEqual(text.spokenAge, "for 6 minutes")
        XCTAssertEqual(text.spoken(), "Waiting for CI, for 6 minutes: Checks are running on PR #741.")
        XCTAssertEqual(text.spoken(forced: true), "Waiting for CI, for 6 minutes: Checks are running on PR #741. Forced.")
    }

    func testTheFullLineShowsTheAgeBesideTheWordAndARowTrailsIt() throws {
        let (_, text) = try line("paused_by_rule")
        XCTAssertEqual(text.ageLabel, "for 1 h 4 min")
        XCTAssertEqual(text.age, "1 h 4 min")
    }

    func testMissingFieldsFallBackToTheKind() throws {
        let situation = try XCTUnwrap(Situation.decode(Data(#"{"kind":"waiting_for_slot"}"#.utf8)))
        XCTAssertEqual(situation, Situation(kind: .slot, cause: ""))
        let text = SituationText(situation, reference: Date())
        XCTAssertEqual(text.word, "Waiting for a slot")
        XCTAssertNil(text.age)
        XCTAssertNil(text.next)
        XCTAssertEqual(text.sentence, "Waiting for a slot")
        XCTAssertEqual(text.spoken(), "Waiting for a slot.")

        let empty = SituationText(Situation(kind: .blocked, word: "", cause: "It is in QA.", next: ""), reference: Date())
        XCTAssertEqual(empty.word, "Blocked")
        XCTAssertNil(empty.next)
    }

    func testAFutureSinceReadsAsNow() {
        let now = Date()
        let text = SituationText(Situation(kind: .ci, cause: "Checks are running.", since: now.addingTimeInterval(30)), reference: now)
        XCTAssertEqual(text.age, "0 s")
    }

    func testAnythingElseIsNoSituation() {
        XCTAssertNil(Situation.decode(Data(#"{"kind":"needs_attention","word":"Needs attention"}"#.utf8)))
        XCTAssertNil(Situation.decode(Data("null".utf8)))
        XCTAssertNil(Situation.decode(object: nil))
        XCTAssertNil(Situation.decode(object: NSNull()))
        XCTAssertNil(Situation.decode(object: "working"))
        XCTAssertEqual(Situation.decode(object: ["kind": "done", "cause": "It is done."])?.kind, .done)
    }

    func testARetryPastTheLimitHasNoCount() throws {
        let situation = try XCTUnwrap(Situation.decode(Data(#"{"kind":"retrying","cause":"The run stopped.","retry":{"try":4,"of":null,"at":null}}"#.utf8)))
        XCTAssertEqual(situation.retry, Situation.Retry(attempt: 4))
    }

    // MARK: - Every ticket's situation in a state

    func testTheStateGivesEachTicketItsSituationByIdentifier() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/tickets/api/v1/state.json")
        let data = try Data(contentsOf: url)
        let situations = Situation.byTicket(state: data)
        XCTAssertEqual(situations.count, 15)
        XCTAssertEqual(situations["SHOP-301"]?.kind, .ci)
        XCTAssertEqual(situations["SHOP-301"]?.cause, "Checks are running on PR #741.")
        XCTAssertNil(situations["DOCS-41"], "a ticket no list names has none")

        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else { return XCTFail("not a state") }
        XCTAssertEqual(snapshot.situations, situations)
        XCTAssertEqual(snapshot.situation("shop-301")?.kind, .ci, "found whatever the case")
        XCTAssertNil(snapshot.situation(nil))
        XCTAssertNil(snapshot.situation("TP-404"))
    }

    func testTheGroupsComeFirstThenTheQueueThenTheWatchedIssues() {
        let data = Data("""
        {"order":{"groups":[{"kind":"working","tickets":[{"identifier":"A-1","situation":{"kind":"working","cause":"From the groups."}}]}],
                  "queue":[{"identifier":"A-1","situation":{"kind":"waiting_for_slot","cause":"From the queue."}},
                           {"identifier":"A-2","situation":{"kind":"waiting_for_slot","cause":"In line."}}]},
         "issues":[{"identifier":"A-3","situation":{"kind":"waiting_for_ci","cause":"Watched."}},
                   {"issue_identifier":"A-4","situation":{"kind":"done","cause":"Shipped."}},
                   {"identifier":"A-5","situation":{"kind":"needs_attention"}},
                   {"situation":{"kind":"done"}}]}
        """.utf8)
        let situations = Situation.byTicket(state: data)
        XCTAssertEqual(situations.keys.sorted(), ["A-1", "A-2", "A-3", "A-4"])
        XCTAssertEqual(situations["A-1"]?.cause, "From the groups.")
        XCTAssertEqual(situations["A-3"]?.kind, .ci)
        XCTAssertEqual(situations["A-4"]?.kind, .done)
        XCTAssertEqual(Situation.byTicket(state: Data("[]".utf8)), [:])
        XCTAssertEqual(Situation.byTicket(state: Data("not json".utf8)), [:])
        XCTAssertEqual(Situation.byTicket(state: Data("{}".utf8)), [:])
    }
}

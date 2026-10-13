import Foundation
@testable import SymphonyBarCore
import XCTest

final class AuditTests: XCTestCase {
    // MARK: - Records

    func testRecordsReadEachLineAndKeepItAsItCame() throws {
        let records = try fixtureRecords()
        XCTAssertEqual(records.count, 15)
        let move = try XCTUnwrap(records.first { $0.issueIdentifier == "SHOP-298" && $0.eventType == "director_move" })
        XCTAssertEqual(move.date, "2026-10-07")
        XCTAssertEqual(move.repoKey, "web-shop")
        XCTAssertEqual(move.actor, "You")
        XCTAssertEqual(move.kindTitle, "Your move")
        XCTAssertEqual(move.summary, "Sent to Rework: QA → Rework · “The rounding is still off for refunds”")
        XCTAssertEqual(move.timestamp, date("2026-10-07T12:40:10Z"))
        XCTAssertEqual(move.id, move.recordHash)
        XCTAssertTrue(move.prettyJSON.contains("\n  \"comment\" : \"The rounding is still off for refunds\""))
        let raw = try XCTUnwrap(String(data: fixture("audit.json"), encoding: .utf8)).split(separator: "\n").map(String.init)
        XCTAssertEqual(records.map(\.line), raw)

        XCTAssertEqual(AuditRecord.records(Data("not json\n{\"no_type\": 1}\n[1]\n\n".utf8)), [])
        XCTAssertNil(AuditRecord(line: #"{"event_type": ""}"#))
    }

    func testSummariesAndActorsByKind() throws {
        let records = try fixtureRecords()
        func summary(_ type: String, _ identifier: String? = nil) -> String? {
            records.first { $0.eventType == type && (identifier == nil || $0.issueIdentifier == identifier) }?.summary
        }
        XCTAssertEqual(summary("linear_state_change"), "Todo → In Progress")
        XCTAssertEqual(summary("prompt_sent"), "Turn 1 · You are working on SHOP-298: Round refunds to the cent")
        XCTAssertEqual(summary("tool_call", "SHOP-298"), "mix test test/refunds_test.exs")
        XCTAssertEqual(summary("tool_call", "API-131"), "linear_add_comment · completed")
        XCTAssertEqual(summary("file_change"), "lib/shop/refunds.ex and 1 more")
        XCTAssertEqual(summary("pr_opened"), "Opened https://github.com/acme/web-shop/pull/482")
        XCTAssertEqual(summary("token_usage_delta"), "18,420 tokens")
        XCTAssertEqual(summary("run_stopped"), "Stopped the run")
        XCTAssertEqual(summary("director_move", "API-127"), "Approved the PR: In Review → Merging")
        XCTAssertEqual(summary("director_move", "DOCS-40"), "Signed off: Human Review → Done")
        XCTAssertEqual(summary("poller_degraded"), #"{"poller":"ci_poller","reason":"GitHub answered 502 three times"}"#)
        XCTAssertEqual(records.first { $0.eventType == "poller_degraded" }?.actor, "Symphony")
        XCTAssertEqual(records.first { $0.eventType == "tool_call" }?.actor, "Agent")
        XCTAssertEqual(records.first { $0.eventType == "prompt_sent" }?.actor, "Symphony")
        XCTAssertEqual(records.first { $0.eventType == "run_stopped" }?.actor, "You")

        func record(_ json: String) throws -> AuditRecord { try XCTUnwrap(AuditRecord(line: json)) }
        XCTAssertEqual(try record(#"{"event_type": "director_move", "move": "approve_plan", "to_state": "Todo"}"#).summary, "Approved the plan: to Todo")
        XCTAssertEqual(try record(#"{"event_type": "director_move"}"#).summary, "Moved")
        XCTAssertEqual(try record(#"{"event_type": "director_move", "move": "force_it"}"#).summary, "Force it")
        XCTAssertEqual(try record(#"{"event_type": "linear_state_change"}"#).summary, "State changed")
        XCTAssertEqual(try record(#"{"event_type": "tool_call"}"#).summary, "Tool call")
        XCTAssertEqual(try record(#"{"event_type": "file_change", "paths": ["a.ex"]}"#).summary, "a.ex")
        XCTAssertEqual(try record(#"{"event_type": "file_change"}"#).summary, "Changed files")
        XCTAssertEqual(try record(#"{"event_type": "pr_opened"}"#).summary, "Opened a PR")
        XCTAssertEqual(try record(#"{"event_type": "token_usage_delta"}"#).summary, "Token usage")
        XCTAssertEqual(try record(#"{"event_type": "custom_thing", "date": "2026-10-07"}"#).summary, "")
        XCTAssertEqual(try record(#"{"event_type": "custom_thing", "actor": "QA"}"#).actor, "QA")
        XCTAssertEqual(try record(#"{"event_type": "custom_thing", "session_id": "s"}"#).actor, "Agent")
        let long = try record(#"{"event_type": "x", "note": "\#(String(repeating: "a", count: 300))"}"#)
        XCTAssertEqual(long.summary.count, 160)
        XCTAssertTrue(long.summary.hasSuffix("…"))
        // A record without a date is filed under its timestamp's UTC day; without a hash, its line is its id.
        let undated = try record(#"{"event_type": "x", "timestamp": "2026-10-06T23:30:00.123Z"}"#)
        XCTAssertEqual(undated.date, "2026-10-06")
        XCTAssertEqual(undated.id, undated.line)
        for move in ["decisions", "decide", "backlog", "restart", "unblock", "undo"] {
            XCTAssertFalse(AuditRecord.moveTitle(move).contains("_"), move)
        }
        XCTAssertEqual(AuditRecord.kindTitle("auto_merge_disabled"), "Auto-merge off")
        XCTAssertEqual(AuditRecord.kindTitle("agent_tool_secret_redaction"), "Agent tool secret redaction")
    }

    // MARK: - Verification

    func testVerificationNamesTheFirstBrokenRecord() throws {
        let verification = try fixtureVerification()
        XCTAssertEqual(verification.days.count, 7)
        XCTAssertTrue(verification.days.last?.verified == true)
        let broken = try XCTUnwrap(verification.days.first { $0.date == "2026-10-06" }?.broken)
        XCTAssertEqual(broken.line, 5)
        XCTAssertEqual(broken.reason, "chain_break")
        XCTAssertEqual(broken.record?.eventType, "pr_opened")
        XCTAssertEqual(broken.record?.issueIdentifier, "SHOP-298")
        XCTAssertEqual(broken.recordHash, broken.record?.recordHash)

        let invalid = AuditVerification.decode(Data(#"""
        {"days": [{"date": "2026-10-07", "verified": false, "broken": {"line": 2, "record_hash": null, "reason": "invalid_record", "record": null}},
                  {"date": "2026-10-08", "verified": true, "broken": {"line": 1}}, {"date": "2026-10-09"}]}
        """#.utf8))
        XCTAssertEqual(invalid?.days, [
            AuditVerification.Day(date: "2026-10-07", verified: false, broken: AuditVerification.Broken(line: 2, reason: "invalid_record")),
            AuditVerification.Day(date: "2026-10-08", verified: true),
        ])
        XCTAssertNil(AuditVerification.decode(Data(#"{"error": "down"}"#.utf8)))
    }

    // MARK: - The view

    func testListsRecordsNewestFirstAndEachDaysChain() throws {
        let audit = try view()
        XCTAssertEqual(audit.rows.count, 15)
        XCTAssertEqual(audit.rows.first?.record.eventType, "token_usage_delta")
        XCTAssertEqual(audit.rows.last?.record.eventType, "linear_state_change")
        XCTAssertEqual(audit.rows.map(\.timeSort), audit.rows.map(\.timeSort).sorted(by: >))
        XCTAssertEqual(audit.countText, "15 records")
        XCTAssertNil(audit.empty)
        XCTAssertEqual(audit.days, ["2026-10-07", "2026-10-06", "2026-10-05", "2026-10-04", "2026-10-03", "2026-10-02", "2026-10-01"])

        // Days with records, newest first: the first verified, the second broken, each with words and a symbol.
        XCTAssertEqual(audit.chain.map(\.date), ["2026-10-07", "2026-10-06"])
        let verified = audit.chain[0]
        XCTAssertTrue(verified.verified)
        XCTAssertEqual(verified.text, "Chain verified")
        XCTAssertEqual(verified.symbol, Audit.verifiedSymbol)
        XCTAssertEqual(verified.accessibilityLabel, "Today: Chain verified")
        let broken = audit.chain[1]
        XCTAssertFalse(broken.verified)
        XCTAssertEqual(broken.day, "Yesterday")
        XCTAssertEqual(broken.text, "Chain broken at line 5: PR opened on SHOP-298 at Oct 6 11:48:52.")
        XCTAssertEqual(broken.symbol, Audit.brokenSymbol)

        // The record that breaks the chain is marked in its row and its inspector.
        let breaking = try XCTUnwrap(audit.rows.first { $0.breaksChain })
        XCTAssertEqual(breaking.record.eventType, "pr_opened")
        XCTAssertTrue(breaking.accessibilityLabel.hasSuffix("breaks the chain"))
        XCTAssertEqual(audit.rows.filter(\.breaksChain).count, 1)
    }

    func testRowsCarryTheTableColumnsAndTheInspectorsFacts() throws {
        let row = try XCTUnwrap(try view().rows.first { $0.record.issueIdentifier == "SHOP-288" })
        XCTAssertEqual(row.timeText, "13:12:44")
        XCTAssertEqual(row.kindTitle, "Your move")
        XCTAssertEqual(row.ticketText, "SHOP-288")
        XCTAssertEqual(row.repoText, "web-shop")
        XCTAssertEqual(row.actor, "You")
        XCTAssertEqual(row.summary, "Approved the PR: In Review → Merging")
        XCTAssertEqual(row.facts.map(\.label), ["Time", "Kind", "Type", "Ticket", "Repo", "Actor", "Hash"])
        XCTAssertEqual(row.facts.first?.value, "2026-10-07T13:12:44Z")
        XCTAssertEqual(row.accessibilityLabel, "13:12:44, Your move, SHOP-288, web-shop, by You, Approved the PR: In Review → Merging")
        XCTAssertEqual(row, row)

        let system = try XCTUnwrap(try view().rows.first { $0.record.eventType == "poller_recovered" })
        XCTAssertEqual(system.ticketText, "")
        XCTAssertEqual(system.repoText, "")
        XCTAssertFalse(system.facts.contains { $0.label == "Ticket" })
    }

    func testKindAndSearchLeaveOnlyThatTicketsRecordsOfThatKind() throws {
        var filter = Audit.Filter(kind: "director_move")
        XCTAssertEqual(try view(filter: filter).rows.count, 5)
        filter.search = " shop-298 "
        let audit = try view(filter: filter)
        XCTAssertEqual(audit.rows.map(\.record.issueIdentifier), ["SHOP-298"])
        XCTAssertEqual(audit.rows.map(\.record.eventType), ["director_move"])
        XCTAssertEqual(audit.countText, "1 record")
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.query, Audit.Filter(kind: "director_move"))
    }

    func testTheKindPopUpListsEveryKnownKindAndEachKindRead() throws {
        let kinds = try view(filter: Audit.Filter(kind: "brand_new")).kinds
        XCTAssertEqual(kinds.map(\.title), kinds.map(\.title).sorted())
        XCTAssertTrue(kinds.contains(Audit.Kind(id: "director_move", title: "Your move")))
        XCTAssertTrue(kinds.contains { $0.id == "brand_new" })
        XCTAssertEqual(Set(kinds.map(\.id)).count, kinds.count)
    }

    func testOneDayShowsItsRecordsAndItsChainEvenWhenItVerifies() throws {
        let broken = try view(filter: Audit.Filter(date: .day("2026-10-06")))
        XCTAssertEqual(broken.rows.count, 6)
        XCTAssertEqual(broken.chain.map(\.date), ["2026-10-06"])
        XCTAssertTrue(broken.chain[0].text.hasPrefix("Chain broken at line 5"))

        let quiet = try view(filter: Audit.Filter(date: .day("2026-10-03")))
        XCTAssertEqual(quiet.rows, [])
        XCTAssertEqual(quiet.chain.map(\.text), ["Chain verified"])
        XCTAssertEqual(quiet.empty, Audit.Empty(title: "No audit records match.", action: .clearFilters))
    }

    func testTicketAndScopeFilters() throws {
        let ticket = try view(filter: Audit.Filter(ticket: "shop-305"))
        XCTAssertEqual(ticket.rows.map(\.record.eventType), ["director_move", "run_stopped"])
        XCTAssertEqual(try view(filter: Audit.Filter(ticket: "i-305")).rows.count, 2)

        let api = try view(scope: .repo("api"))
        XCTAssertEqual(Set(api.rows.compactMap(\.record.repoKey)), ["api"])
        XCTAssertEqual(api.rows.count, 3)
        // A repo with no records today still has its broken day: the chain is the whole file's.
        XCTAssertEqual(api.chain.map(\.date), ["2026-10-07", "2026-10-06"])

        let none = try view(scope: .repo("mobile"))
        XCTAssertEqual(none.empty, Audit.Empty(title: Audit.emptyTitle, action: .showAllRepos))
        XCTAssertEqual(none.chain.map(\.date), ["2026-10-06"])
        XCTAssertEqual(try view(records: []).empty, Audit.Empty(title: Audit.emptyTitle, action: nil))
        XCTAssertEqual(Audit.Empty.Action.clearFilters.title, "Clear Filters")
        XCTAssertEqual(Audit.Empty.Action.showAllRepos.title, "Show All Repos")
        XCTAssertFalse(Audit.Filter().isActive)
        XCTAssertTrue(Audit.Filter(date: .day("2026-10-06")).isActive)
        XCTAssertTrue(Audit.Filter(ticket: "SHOP-1").isActive)
    }

    func testWithoutAVerificationNoDayIsClaimed() throws {
        XCTAssertEqual(try view(verification: .some(nil)).chain, [])
        let unnamed = AuditVerification(days: [AuditVerification.Day(date: "2026-10-07", verified: false)])
        XCTAssertEqual(try view(verification: unnamed).chain.map(\.text), ["Chain broken"])
        let invalid = AuditVerification(days: [
            AuditVerification.Day(date: "2026-10-07", verified: false, broken: AuditVerification.Broken(line: 3, reason: "invalid_record")),
            AuditVerification.Day(date: "2026-10-06", verified: false, broken: AuditVerification.Broken(line: 1, reason: "chain_break")),
        ])
        XCTAssertEqual(try view(verification: invalid).chain.map(\.text), [
            "Chain broken at line 3: the line isn't an audit record.", "Chain broken at line 1.",
        ])
    }

    func testSaysWhenItShowsOnlyTheNewestRecords() throws {
        let record = try XCTUnwrap(try fixtureRecords().first)
        let many = Array(repeating: record, count: Audit.maxRecords)
        XCTAssertEqual(try view(records: many).countText, "The newest 1,000 records; narrow the filters to see older ones")
    }

    // MARK: - Reads and Export

    func testPathsAskSymphonyForTheFiltersItApplies() {
        XCTAssertEqual(Audit.path(Audit.Filter(), scope: .all, today: "2026-10-07"), "api/v1/audit?from=2026-10-01&to=2026-10-07&last=1000")
        let filter = Audit.Filter(kind: "director_move", date: .day("2026-10-06"), ticket: "SHOP-298", search: "rework")
        XCTAssertEqual(
            Audit.path(filter, scope: .repo("web shop&co"), today: "2026-10-07"),
            "api/v1/audit?from=2026-10-06&to=2026-10-06&type=director_move&issue=SHOP-298&repo=web%20shop%26co&last=1000"
        )
        XCTAssertEqual(
            Audit.exportPath(filter, scope: .all, today: "2026-10-07"),
            "api/v1/audit?from=2026-10-06&to=2026-10-06&type=director_move&issue=SHOP-298&download=1"
        )
        XCTAssertEqual(Audit.verifyPath(Audit.Filter(), today: "2026-10-07"), "api/v1/audit/verify?from=2026-10-01&to=2026-10-07")
        XCTAssertEqual(Audit.verifyPath(filter, today: "2026-10-07"), "api/v1/audit/verify?from=2026-10-06&to=2026-10-06")
        XCTAssertEqual(Audit.title(.recent, today: "2026-10-07"), "Last 7 Days")
        XCTAssertEqual(Audit.title(.day("2026-10-07"), today: "2026-10-07"), "Today")
        XCTAssertEqual(Audit.title(.day("2026-10-04"), today: "2026-10-07"), "Oct 4")
        XCTAssertEqual(Audit.title(.day("someday"), today: "2026-10-07"), "someday")
        XCTAssertEqual(Audit.days(today: "not a day"), ["not a day"])
        XCTAssertEqual(Audit.today(generatedAt: date("2026-10-07T23:59:00Z")), "2026-10-07")
        XCTAssertEqual(Audit.today(generatedAt: nil, now: date("2026-10-08T00:01:00Z")), "2026-10-08")
    }

    func testExportWritesTheFilteredRecordsOneLinePerRecordAsServed() throws {
        let filter = Audit.Filter(kind: "director_move", search: "web-shop")
        let lines = Audit.exportLines(try fixture("audit.json"), filter: filter, scope: .all, today: "2026-10-07")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.contains(#""event_type": "director_move""#) && $0.contains("web-shop") })
        let body = String(decoding: Audit.exportBody(lines), as: UTF8.self)
        XCTAssertEqual(body.split(separator: "\n", omittingEmptySubsequences: false).count, 4)
        XCTAssertTrue(body.hasSuffix("}\n"))
        XCTAssertEqual(Audit.exportBody([]), Data())

        XCTAssertEqual(Audit.exportFileName(Audit.Filter(), today: "2026-10-07"), "symphony-audit-2026-10-01-2026-10-07.ndjson")
        XCTAssertEqual(Audit.exportFileName(Audit.Filter(date: .day("2026-10-06"), ticket: "SHOP-298"), today: "2026-10-07"), "symphony-audit-SHOP-298-2026-10-06.ndjson")
        XCTAssertEqual(Audit.exportError(.unsupported), "Couldn't export: Update Symphony to see this view.")
        XCTAssertEqual(Audit.exportError(.failed("Symphony isn't answering")), "Couldn't export: Symphony isn't answering.")
        XCTAssertEqual(Audit.exportError(.loaded(Data())), "")
    }

    /// The walkthrough's reads all answer from the shipped audit fixtures, query strings included.
    @MainActor
    func testTheShippedFixturesAnswerAuditsReads() async throws {
        let fixtures = APIFixtures(directory: fixturesDirectory(), requestLog: FileManager.default.temporaryDirectory.appendingPathComponent("audit-requests.jsonl"))
        let client = LiveAPIClient(fetch: LiveAPIClient.fetch(base: { APIFixtures.baseURL }, transport: fixtures.transport))
        let filter = Audit.Filter(ticket: "SHOP-305")
        guard case let .loaded(records) = await client.get(Audit.path(filter, scope: .all, today: "2026-10-07")),
              case let .loaded(verification) = await client.get(Audit.verifyPath(filter, today: "2026-10-07")),
              case let .loaded(export) = await client.download(Audit.exportPath(filter, scope: .all, today: "2026-10-07")),
              case .loaded = await client.get(TicketPage.issuePath("SHOP-305"))
        else { return XCTFail("a fixture is missing") }
        let audit = Audit(
            records: AuditRecord.records(records), verification: AuditVerification.decode(verification), filter: filter, scope: .all,
            today: "2026-10-07", now: date("2026-10-07T14:20:00Z"), timeZone: utc
        )
        XCTAssertEqual(audit.rows.map(\.record.issueIdentifier), ["SHOP-305", "SHOP-305"])
        XCTAssertEqual(Audit.exportLines(export, filter: filter, scope: .all, today: "2026-10-07").count, 2)
    }

    // MARK: - Fixtures

    private let utc = TimeZone(identifier: "UTC")!

    private func view(
        records: [AuditRecord]? = nil, verification: AuditVerification?? = .none, filter: Audit.Filter = Audit.Filter(),
        scope: OverviewScope = .all
    ) throws -> Audit {
        Audit(
            records: try records ?? fixtureRecords(), verification: try verification ?? fixtureVerification(), filter: filter,
            scope: scope, today: "2026-10-07", now: date("2026-10-07T14:20:00Z"), timeZone: utc
        )
    }

    private func date(_ text: String) -> Date {
        Shipped.parseDate(text)!
    }

    private func fixturesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/audit", isDirectory: true)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixturesDirectory().appendingPathComponent("api/v1/\(name)"))
    }

    private func fixtureRecords() throws -> [AuditRecord] {
        AuditRecord.records(try fixture("audit.json"))
    }

    private func fixtureVerification() throws -> AuditVerification {
        try XCTUnwrap(AuditVerification.decode(fixture("audit/verify.json")))
    }
}

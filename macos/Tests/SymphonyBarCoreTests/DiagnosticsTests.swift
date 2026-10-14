import XCTest
@testable import SymphonyBarCore

final class DiagnosticsTests: XCTestCase {
    private let now = SymphonyState.parseDate("2026-10-07T14:03:12Z")!

    private func shippedState() throws -> Data {
        try Data(contentsOf: APIFixturesTests.shippedRunning.appendingPathComponent("api/v1/state.json"))
    }

    private func report(_ data: Data) throws -> DiagnosticsReport {
        let payload = try XCTUnwrap(DiagnosticsPayload.decode(data))
        return DiagnosticsReport(
            payload: payload,
            apiURL: URL(string: "http://127.0.0.1:4000"),
            lastUpdate: now,
            now: now
        )
    }

    private func rows(_ report: DiagnosticsReport, _ group: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (report.group(group)?.rows ?? []).map { ($0.label, $0.value) })
    }

    func testShowsTheFiveGroupsInPlainWords() throws {
        let report = try report(shippedState())
        XCTAssertEqual(report.groups.map(\.title), ["Connection", "Capacity", "Linear requests", "GitHub", "Stray processes"])

        let connection = rows(report, "Connection")
        XCTAssertEqual(connection["Version"], "Symphony 0.0.1.412 (9f54098)")
        XCTAssertEqual(connection["API"], "http://127.0.0.1:4000")
        XCTAssertEqual(connection["Uptime"], "3 h 13 min")
        XCTAssertNotNil(connection["Last update"])

        XCTAssertEqual(rows(report, "Capacity"), [
            "Agent slots": "1 of 10 in use",
            "Landing slots": "1 of 2 in use",
            "Forced allowance": "1 of 1 in use",
            "Initiative slots": "2 held: 1 working, 1 waiting · 1 initiative queued",
            "Slots for other work": "2 of 8 in use",
        ])

        XCTAssertEqual(rows(report, "Linear requests"), [
            "In the last hour": "1,284 requests",
            "poll": "720 requests",
            "reconcile": "402 requests",
            "agent_tool": "151 requests",
            "qa": "11 requests",
        ])

        XCTAssertEqual(rows(report, "GitHub"), [
            "CI poller": "Running, checks every 1 min",
            "Review poller": "Running, checks every 1 min",
            "Webhooks": "On through smee.io, last event 4 min ago",
            "Events received": "214 events (2 rejected)",
            "CI results": "96 by webhook, 7 by poll",
        ])

        let stray = try XCTUnwrap(report.group("Stray processes")?.rows.first)
        XCTAssertEqual(stray.label, "node /usr/local/bin/vite --port 5173")
        XCTAssertEqual(stray.value, "41 min of CPU, pid 48213")
        XCTAssertEqual(stray.detail, "/Users/director/symphony-workspaces/web-shop/SHOP-288")
        XCTAssertEqual(stray.status, .problem)
    }

    func testNoFieldSaysUnavailable() throws {
        // An older Symphony: pollers it doesn't run come as "unavailable", and the newer blocks are missing.
        let data = Data(#"{"counts":{"running":0},"pollers":{"ci":"unavailable","pr_review":"unavailable"}}"#.utf8)
        let report = try report(data)
        for group in report.groups {
            for row in group.rows {
                XCTAssertFalse(row.value.localizedCaseInsensitiveContains("unavailable"), "\(row)")
            }
        }
        XCTAssertNil(rows(report, "Connection")["Version"])
        XCTAssertNil(rows(report, "Connection")["Uptime"])
        XCTAssertEqual(rows(report, "Capacity"), ["Agent slots": "0 running"])
        XCTAssertEqual(rows(report, "Linear requests"), ["In the last hour": "0 requests"])
        XCTAssertEqual(rows(report, "GitHub"), [
            "CI poller": "Not running",
            "Review poller": "Not running",
            "Webhooks": "Off: CI results come from the poller",
        ])
        XCTAssertEqual(rows(report, "Stray processes"), ["Stray processes": "None"])
    }

    func testFailingPollersAndQuietWebhooks() throws {
        let data = Data(#"""
        {"pollers":{"ci":{"status":"running","consecutive_failures":3,"current_backoff_ms":120000,
          "webhooks":{"enabled":true,"events_received":1,"rejected":0}}},
         "epic_lanes":{"lanes":[],"queued_epics":[]},
         "linear_usage":{"window_ms":600000,"total":1,"callers":[{"caller":"poll","requests":1}]}}
        """#.utf8)
        let report = try report(data)
        let gitHub = try XCTUnwrap(report.group("GitHub"))
        XCTAssertEqual(gitHub.rows[0].value, "Failing: 3 failures in a row, next try in 2 min")
        XCTAssertEqual(gitHub.rows[0].status, .problem)
        XCTAssertEqual(rows(report, "GitHub")["Webhooks"], "On, no event yet")
        XCTAssertEqual(rows(report, "GitHub")["Events received"], "1 event")
        XCTAssertEqual(rows(report, "Capacity")["Initiative slots"], "No initiative holds a slot")
        XCTAssertEqual(rows(report, "Linear requests")["In the last 10 min"], "1 request")
    }

    func testDurations() {
        XCTAssertEqual(DiagnosticsReport.duration(seconds: -5), "0 s")
        XCTAssertEqual(DiagnosticsReport.duration(seconds: 45), "45 s")
        XCTAssertEqual(DiagnosticsReport.duration(seconds: 14 * 60 + 5), "14 min")
        XCTAssertEqual(DiagnosticsReport.duration(seconds: 3600), "1 h")
        XCTAssertEqual(DiagnosticsReport.duration(seconds: 3 * 3600 + 12 * 60), "3 h 12 min")
        XCTAssertEqual(DiagnosticsReport.duration(seconds: 86400 + 5), "1 day")
        XCTAssertEqual(DiagnosticsReport.duration(seconds: 2 * 86400), "2 days")
    }

    func testNotAStatePayload() {
        XCTAssertNil(DiagnosticsPayload.decode(Data("[]".utf8)))
    }
}

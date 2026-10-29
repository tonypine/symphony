import XCTest
@testable import SymphonyBarCore

final class SetupTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T12:10:00Z")!

    /// The shipped Setup fixtures QA points `SYMPHONY_BAR_QA_API_FIXTURES` at.
    static func fixture(_ name: String = "setup") -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1", isDirectory: true)
    }

    private static let payloadJSON = #"""
    {
      "problems": [
        {
          "id": "labels:missing:TP:Needs Decision", "severity": "error", "category": "labels",
          "title": "Team TP has no \"Needs Decision\" label",
          "consequence": "Decisions you are asked for can't be marked on the ticket.",
          "repos": ["web-shop"], "tickets": [],
          "details": [{"label": "Team", "value": "TP"}, {"label": "Label", "value": "Needs Decision"}],
          "fix": {"kind": "linear", "action": "create_label", "team": "TP", "name": "Needs Decision", "type": null}
        },
        {
          "id": "deprecated_key:auto_review.enabled", "severity": "warning", "category": "keys",
          "title": "symphony.yml sets auto_review.enabled, which is deprecated", "consequence": "Nothing uses it any more.",
          "repos": [], "tickets": [], "details": [],
          "fix": {"kind": "config_edit", "path": "auto_review.enabled", "action": "remove", "value": null}
        },
        {
          "id": "hold_drift:web-shop", "severity": "warning", "category": "labels",
          "title": "2 tickets in web-shop have hold labels that don't match their holds", "consequence": "Re-sync sets the label.",
          "repos": ["web-shop"],
          "tickets": [{"identifier": "TP-12", "url": "https://linear.app/t/issue/TP-12"}, {"identifier": "TP-13", "url": null}],
          "details": [{"label": "TP-12", "value": "Blocked label with no hold"}, {"label": "TP-13", "value": "Blocked hold with no label"}],
          "fix": {"kind": "linear", "action": "resync_hold", "repo": "web-shop", "tickets": ["TP-12", "TP-13"]}
        },
        {
          "id": "routing:unknown_team:web-shop", "severity": "error", "category": "routing",
          "title": "web-shop routes by team \"TQ\"", "consequence": "Tickets never reach it.",
          "fix": {"kind": "config_edit", "path": "repositories[web-shop].route.team", "action": "set", "value": "TP"}
        },
        {
          "id": "secrets:LINEAR_API_KEY", "severity": "error", "category": "secrets",
          "title": "Symphony can't read Linear: no ticket is picked up", "consequence": "Nothing runs.",
          "fix": {"kind": "open", "target": "settings", "url": null}
        },
        {
          "id": "future:x", "severity": "warning", "category": "budgets", "title": "Something new", "consequence": "Later.",
          "fix": {"kind": "teleport"}
        },
        {"severity": "error", "title": "no id: left out"}
      ],
      "not_checked": [{"id": "labels", "title": "Symphony's labels in each Linear team", "reason": "No Linear API key is set."}],
      "checked_at": "2026-10-19T12:00:00Z",
      "linear_checked_at": "2026-10-19T11:30:00Z"
    }
    """#

    private var payload: SetupPayload { SetupPayload.decode(Data(Self.payloadJSON.utf8))! }

    private func problem(_ id: String) -> SetupPayload.Problem {
        payload.problems.first { $0.id == id }!
    }

    // MARK: - Decoding (AC 1)

    func testDecodesProblemsNotCheckedAndTimes() {
        let payload = payload
        XCTAssertEqual(payload.problems.map(\.id), [
            "labels:missing:TP:Needs Decision", "deprecated_key:auto_review.enabled", "hold_drift:web-shop",
            "routing:unknown_team:web-shop", "secrets:LINEAR_API_KEY", "future:x",
        ])
        XCTAssertEqual(payload.errors.count, 3)
        XCTAssertEqual(payload.warnings.count, 3)
        XCTAssertEqual(payload.notChecked, [SetupPayload.NotChecked(id: "labels", title: "Symphony's labels in each Linear team", reason: "No Linear API key is set.")])
        XCTAssertEqual(payload.checkedAt, ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z"))
        XCTAssertEqual(payload.linearCheckedAt, ISO8601DateFormatter().date(from: "2026-10-19T11:30:00Z"))
        XCTAssertTrue(payload.isStale)

        let label = problem("labels:missing:TP:Needs Decision")
        XCTAssertEqual(label.severity, .error)
        XCTAssertEqual(label.category, "labels")
        XCTAssertEqual(label.repos, ["web-shop"])
        XCTAssertEqual(label.details, [.init(label: "Team", value: "TP"), .init(label: "Label", value: "Needs Decision")])
        XCTAssertEqual(label.fix, .linear(action: "create_label", team: "TP", name: "Needs Decision", type: nil))

        XCTAssertEqual(problem("deprecated_key:auto_review.enabled").fix, .configEdit(path: "auto_review.enabled", action: .remove, value: .null))
        XCTAssertEqual(problem("routing:unknown_team:web-shop").fix, .configEdit(path: "repositories[web-shop].route.team", action: .set, value: .string("TP")))
        XCTAssertEqual(problem("hold_drift:web-shop").fix, .resyncHold(repo: "web-shop", tickets: ["TP-12", "TP-13"]))
        XCTAssertEqual(problem("hold_drift:web-shop").tickets, [
            .init(identifier: "TP-12", url: URL(string: "https://linear.app/t/issue/TP-12")), .init(identifier: "TP-13"),
        ])
        XCTAssertEqual(problem("secrets:LINEAR_API_KEY").fix, .open(.settings, url: nil))
        XCTAssertEqual(problem("future:x").fix, .unknown("teleport"))
        XCTAssertEqual(problem("future:x").category, "budgets")
    }

    func testDecodesTheStatePayloadsSetup() throws {
        let data = try Data(contentsOf: Self.fixture().appendingPathComponent("state.json"))
        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else { return XCTFail("no state") }
        XCTAssertEqual(snapshot.setup?.problems.map(\.severity), [.error, .warning])
        XCTAssertNil(snapshot.serviceVersion)
        XCTAssertEqual(SetupPayload.decode(state: data), snapshot.setup)
    }

    func testAnOlderServiceHasNoSetup() {
        let data = Data(#"{"counts": {"running": 0}, "build": {"version": "0.0.1.500"}}"#.utf8)
        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else { return XCTFail("no state") }
        XCTAssertNil(snapshot.setup)
        XCTAssertEqual(snapshot.serviceVersion, "0.0.1.500")
        XCTAssertNil(SetupPayload.decode(state: data))
        XCTAssertEqual(SetupSummary(payload: nil), SetupSummary())

        let page = SetupPage(payload: nil, now: now)
        XCTAssertEqual(page.mood, .olderService)
        XCTAssertEqual(page.sentence, "This Symphony doesn't check its setup.")
        XCTAssertTrue(page.errors.isEmpty && page.warnings.isEmpty)
    }

    func testOddFixesReadAsUnknown() {
        let json = #"""
        {"problems": [
          {"id": "a", "severity": "warning", "title": "A", "fix": {"kind": "config_edit", "path": "x", "action": "rename"}},
          {"id": "b", "severity": "warning", "title": "B", "fix": {"kind": "linear", "action": "create_label"}},
          {"id": "c", "severity": "warning", "title": "C", "fix": {"kind": "open", "target": "update"}},
          {"id": "d", "severity": "warning", "title": "D", "fix": {"kind": "open", "target": "linear", "url": "https://linear.app/x"}},
          {"id": "e", "severity": "warning", "title": "E", "fix": {"kind": "config_edit", "path": "a.b", "action": "set", "value": [1, true, "x", {"k": 1}]}}
        ], "checked_at": null}
        """#
        let payload = SetupPayload.decode(Data(json.utf8))!
        XCTAssertEqual(payload.problems.map(\.fix), [
            .unknown("config_edit"), .unknown("linear"), .unknown("open"),
            .open(.linear, url: URL(string: "https://linear.app/x")),
            .configEdit(path: "a.b", action: .set, value: .list([.number(1), .bool(true), .string("x"), .null])),
        ])
        XCTAssertEqual(payload.problems[0].category, "runtime")
        XCTAssertNil(payload.checkedAt)
        XCTAssertNil(SetupPayload.decode(Data("[]".utf8)))
    }

    func testValueText() {
        XCTAssertEqual(SetupValue.number(3).scalarText, "3")
        XCTAssertEqual(SetupValue.number(2.5).scalarText, "2.5")
        XCTAssertEqual(SetupValue.bool(false).scalarText, "false")
        XCTAssertNil(SetupValue.null.scalarText)
        XCTAssertEqual(SetupValue.list([.string("a"), .number(1)]).listText, ["a", "1"])
        XCTAssertNil(SetupValue.list([.list([])]).listText)
        XCTAssertNil(SetupValue.string("a").listText)
        XCTAssertEqual(SetupValue.list([.string("a"), .string("b")]).display, "[a, b]")
        XCTAssertEqual(SetupValue.null.display, "nothing")
    }

    func testTheNewerPayloadWins() {
        let older = SetupPayload(checkedAt: Date(timeIntervalSince1970: 100))
        let newer = SetupPayload(problems: [problem("secrets:LINEAR_API_KEY")], checkedAt: Date(timeIntervalSince1970: 200))
        let unchecked = SetupPayload()
        XCTAssertEqual(SetupPayload.newest(older, newer), newer)
        XCTAssertEqual(SetupPayload.newest(newer, older), newer)
        XCTAssertEqual(SetupPayload.newest(nil, older), older)
        XCTAssertEqual(SetupPayload.newest(older, nil), older)
        XCTAssertEqual(SetupPayload.newest(unchecked, older), older)
        XCTAssertEqual(SetupPayload.newest(older, unchecked), older)
        // A tie keeps the state poll's.
        let tie = SetupPayload(problems: [problem("future:x")], checkedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(SetupPayload.newest(older, tie), older)
    }

    // MARK: - Badge, menu row and dot (AC 2)

    func testBadgeShowsErrorsInRedFirst() {
        let summary = SetupSummary(payload: payload)
        XCTAssertEqual(summary.errors, 3)
        XCTAssertEqual(summary.warnings, 3)
        XCTAssertEqual(summary.badge?.count, 3)
        XCTAssertEqual(summary.badge?.status, .problem)
        XCTAssertTrue(summary.showsMenuDot)
        XCTAssertEqual(summary.menuTitle, "Setup: 3 errors, 3 warnings")
        XCTAssertEqual(summary.attentionSentence, "Setup has 3 errors.")
        XCTAssertEqual(SetupSummary(errors: 1, warnings: 1).menuTitle, "Setup: 1 error, 1 warning")
        XCTAssertEqual(SetupSummary(errors: 1).menuTitle, "Setup: 1 error")
        XCTAssertEqual(SetupSummary(errors: 1).attentionSentence, "Setup has 1 error.")
    }

    func testBadgeShowsWarningsInOrangeWithoutErrors() {
        let summary = SetupSummary(payload: SetupPayload(problems: payload.warnings))
        XCTAssertEqual(summary.badge?.count, 3)
        XCTAssertEqual(summary.badge?.status, .you)
        XCTAssertFalse(summary.showsMenuDot)
        XCTAssertEqual(summary.menuTitle, "Setup: 3 warnings")
        XCTAssertNil(summary.attentionSentence)
        XCTAssertEqual(summary.accessibilityValue, "3 warnings")
    }

    func testHealthyShowsNothing() {
        let summary = SetupSummary(payload: SetupPayload(checkedAt: now))
        XCTAssertTrue(summary.isHealthy)
        XCTAssertNil(summary.badge)
        XCTAssertNil(summary.menuTitle)
        XCTAssertFalse(summary.showsMenuDot)
        XCTAssertEqual(summary.accessibilityValue, "")
    }

    func testTheBuildWarningCountsAsAWarning() {
        let warning = SetupBuildCheck.warning(serviceVersion: "0.0.1.500", app: AppBuild(build: 600, isDevelopment: false, version: "0.0.1.600"))
        let summary = SetupSummary(payload: SetupPayload(checkedAt: now), buildWarning: warning)
        XCTAssertEqual(summary.badge?.count, 1)
        XCTAssertEqual(summary.badge?.status, .you)
        XCTAssertEqual(summary.menuTitle, "Setup: 1 warning")
    }

    func testTheMenuFollowsTheSameRule() {
        let app = AppBuild(build: 600, isDevelopment: false, version: "0.0.1.600")
        var snapshot = StateSnapshot(setup: payload, serviceVersion: "0.0.1.600")
        XCTAssertEqual(StatusMenu.setupSummary(.running(snapshot, external: false), app: app).menuTitle, "Setup: 3 errors, 3 warnings")
        XCTAssertEqual(StatusMenu.setupSummary(.paused(snapshot, external: false), app: app).errors, 3)
        XCTAssertEqual(StatusMenu.setupSummary(.stopped, app: app), SetupSummary())
        XCTAssertEqual(StatusMenu.setupSummary(.error("x"), app: app), SetupSummary())

        let errors = StatusMenu.setupSummary(.running(snapshot, external: false), app: app)
        XCTAssertEqual(StatusMenu.iconDot(badge: nil, setup: errors), .problem)
        XCTAssertEqual(StatusMenu.iconDot(badge: 2, setup: errors), .problem)
        XCTAssertEqual(StatusMenu.iconDot(badge: 2, setup: SetupSummary(warnings: 1)), .you)
        XCTAssertNil(StatusMenu.iconDot(badge: nil, setup: SetupSummary(warnings: 1)))
        XCTAssertEqual(
            StatusMenu.iconLabel(for: .running(snapshot, external: false), badge: nil, setup: errors),
            "Symphony: running, Setup has 3 errors"
        )
        XCTAssertEqual(StatusMenu.iconLabel(for: .stopped, badge: nil, setup: SetupSummary()), "Symphony: stopped")

        snapshot.setup = nil
        XCTAssertEqual(StatusMenu.setupSummary(.running(snapshot, external: false), app: app), SetupSummary())
    }

    // MARK: - Builds (AC 6)

    func testDifferentBuildsShowTheBuildWarning() throws {
        let app = AppBuild(build: 600, isDevelopment: false, version: "0.0.1.600")
        let warning = try XCTUnwrap(SetupBuildCheck.warning(serviceVersion: "0.0.1.583", app: app))
        XCTAssertEqual(warning.severity, .warning)
        XCTAssertEqual(warning.title, "This app is 0.0.1.600 but Symphony runs 0.0.1.583")
        XCTAssertTrue(warning.consequence.hasPrefix("Settings this app writes may be ignored by Symphony 0.0.1.583"))
        XCTAssertEqual(warning.fix, .open(.update, url: nil))
        XCTAssertEqual(SetupPage.Row(problem: warning).actionTitle, "Check for Updates…")

        let older = try XCTUnwrap(SetupBuildCheck.warning(serviceVersion: "0.0.1.700", app: app))
        XCTAssertTrue(older.consequence.hasPrefix("Settings Symphony 0.0.1.700 writes may be ignored by this app"))
    }

    func testMatchingOrUnknownBuildsDont() {
        let app = AppBuild(build: 600, isDevelopment: false, version: "0.0.1.600")
        XCTAssertNil(SetupBuildCheck.warning(serviceVersion: "0.0.1.600", app: app))
        XCTAssertNil(SetupBuildCheck.warning(serviceVersion: nil, app: app))
        XCTAssertNil(SetupBuildCheck.warning(serviceVersion: " ", app: app))
        XCTAssertNil(SetupBuildCheck.warning(serviceVersion: "0.0.1.500", app: AppBuild(build: 600, isDevelopment: false)))
        // A development build runs a checkout's Symphony.
        XCTAssertNil(SetupBuildCheck.warning(serviceVersion: "0.0.1.500", app: AppBuild(build: 0, isDevelopment: true, version: "0.0.1")))
    }

    func testVersionsCompareNumberByNumber() {
        XCTAssertEqual(SetupBuildCheck.compare("0.0.1.600", "0.0.1.583"), .orderedDescending)
        XCTAssertEqual(SetupBuildCheck.compare("0.0.1", "0.0.1.0"), .orderedSame)
        XCTAssertEqual(SetupBuildCheck.compare("0.0.1.9", "0.0.1.10"), .orderedAscending)
    }

    // MARK: - The page (SU3–SU6)

    func testThePageGroupsErrorsAndWarningsByCategory() {
        let page = SetupPage(payload: payload, now: now, timeZone: utc)
        XCTAssertEqual(page.mood, .problems)
        XCTAssertEqual(page.sentence, "Setup has 3 errors and 3 warnings.")
        XCTAssertEqual(page.context, "Checked at 12:00.")
        XCTAssertEqual(page.errors.map(\.title), ["Routing", "Labels", "Secrets"])
        XCTAssertEqual(page.warnings.map(\.title), ["Labels", "Keys", "Budgets"])
        XCTAssertEqual(page.errors[1].rows.map(\.id), ["labels:missing:TP:Needs Decision"])
        XCTAssertEqual(page.notChecked.map(\.id), ["labels"])
        XCTAssertEqual(page.staleBanner, "Symphony couldn't reach Linear. Its teams, statuses and labels are as they were at 11:30.")
    }

    func testRowsShowTheirButtons() {
        let page = SetupPage(payload: payload, now: now, timeZone: utc)
        let rows = Dictionary(uniqueKeysWithValues: (page.errors + page.warnings).flatMap(\.rows).map { ($0.id, $0) })
        XCTAssertEqual(rows["labels:missing:TP:Needs Decision"]?.actionTitle, "Create Label…")
        XCTAssertEqual(rows["labels:missing:TP:Needs Decision"]?.reposLine, "Repo: web-shop")
        XCTAssertEqual(rows["deprecated_key:auto_review.enabled"]?.actionTitle, "Remove…")
        XCTAssertNil(rows["deprecated_key:auto_review.enabled"]?.reposLine)
        XCTAssertEqual(rows["routing:unknown_team:web-shop"]?.actionTitle, "Change…")
        XCTAssertEqual(rows["hold_drift:web-shop"]?.actionTitle, "Re-sync…")
        XCTAssertEqual(rows["hold_drift:web-shop"]?.resyncsPerTicket, true)
        XCTAssertEqual(rows["hold_drift:web-shop"]?.detail(for: "TP-13"), "Blocked hold with no label")
        XCTAssertEqual(rows["labels:missing:TP:Needs Decision"]?.resyncsPerTicket, false)
        XCTAssertEqual(rows["secrets:LINEAR_API_KEY"]?.actionTitle, "Open Settings…")
        XCTAssertEqual(rows["secrets:LINEAR_API_KEY"]?.action, .open(.settings))
        XCTAssertNil(rows["future:x"]?.actionTitle)
        XCTAssertNil(rows["future:x"]?.action)
        XCTAssertNil(SetupPage.Row(problem: SetupPayload.Problem(id: "n", severity: .warning, category: "keys", title: "N", consequence: "")).action)

        XCTAssertEqual(SetupPage.Row.fixTitle(.configEdit(path: "a", action: .add, value: .string("x"))), "Add…")
        XCTAssertEqual(SetupPage.Row.fixTitle(.linear(action: "create_state", team: "TP", name: "QA", type: "started")), "Create Status…")
        XCTAssertEqual(SetupPage.Row.fixTitle(.linear(action: "merge_labels", team: "TP", name: "QA", type: nil)), "Fix…")
        XCTAssertEqual(SetupPage.Row(problem: SetupPayload.Problem(
            id: "r", severity: .warning, category: "teams", title: "R", consequence: "", repos: ["a", "b"]
        )).reposLine, "Repos: a, b")
    }

    func testRowsKeepTheirPlacesAndNewOnesJoinBelow() {
        let first = SetupPage(payload: SetupPayload(problems: Array(payload.errors.reversed()), checkedAt: now), now: now)
        XCTAssertEqual(first.order, ["routing:unknown_team:web-shop", "labels:missing:TP:Needs Decision", "secrets:LINEAR_API_KEY"])
        // The service lists them in another order and one clears: the others stay where they were.
        let next = SetupPayload(problems: [problem("secrets:LINEAR_API_KEY"), problem("labels:missing:TP:Needs Decision")], checkedAt: now)
        XCTAssertEqual(SetupPage(payload: next, order: first.order, now: now).order, ["labels:missing:TP:Needs Decision", "secrets:LINEAR_API_KEY"])
        XCTAssertEqual(
            SetupPage(payload: next, order: ["secrets:LINEAR_API_KEY"], now: now).order,
            ["labels:missing:TP:Needs Decision", "secrets:LINEAR_API_KEY"]
        )
    }

    func testHealthySaysWhatWasCheckedAndWhen() {
        let page = SetupPage(payload: SetupPayload(checkedAt: ISO8601DateFormatter().date(from: "2026-10-19T12:05:00Z")), now: now, timeZone: utc)
        XCTAssertEqual(page.mood, .healthy)
        XCTAssertEqual(page.sentence, "Symphony is set up right.")
        XCTAssertEqual(
            page.context,
            "Checked routing, teams, labels, statuses, keys, secrets and runtime at 12:05. "
                + "Symphony checks again every 15 minutes and each time symphony.yml changes."
        )
        XCTAssertNil(page.staleBanner)
    }

    func testHealthyWithChecksThatCouldntRun() {
        let payload = SetupPayload(notChecked: [.init(id: "labels", title: "Labels", reason: "No key.")], checkedAt: now)
        let page = SetupPage(payload: payload, now: now, timeZone: utc)
        XCTAssertEqual(page.sentence, "Nothing is wrong in what Symphony could check.")
        XCTAssertEqual(page.context, "Checked routing, keys, secrets and runtime at 12:10. " + SetupPage.recheckNote)
        XCTAssertEqual(SetupPage.checkedAreas(SetupPayload()), "routing, teams, labels, statuses, keys, secrets and runtime")
    }

    func testCheckingBeforeTheFirstRun() {
        let page = SetupPage(payload: SetupPayload(), now: now)
        XCTAssertEqual(page.mood, .checking)
        XCTAssertEqual(page.sentence, "Checking Symphony's setup…")
        XCTAssertNil(page.context)
    }

    func testTheBuildWarningJoinsTheWarnings() {
        let warning = SetupBuildCheck.warning(serviceVersion: "0.0.1.500", app: AppBuild(build: 1, isDevelopment: false, version: "0.0.1.600"))
        let page = SetupPage(payload: SetupPayload(checkedAt: now), buildWarning: warning, now: now)
        XCTAssertEqual(page.mood, .problems)
        XCTAssertEqual(page.sentence, "Setup has 1 warning.")
        XCTAssertEqual(page.warnings.map(\.title), ["Runtime"])
    }

    func testCategoryTitles() {
        XCTAssertEqual(SetupPage.categories.map(SetupPage.categoryTitle), ["Routing", "Teams", "Labels", "Statuses", "Keys", "Secrets", "Runtime"])
        XCTAssertEqual(SetupPage.sentenceCounts(errors: 2, warnings: 0), "2 errors")
    }

    // MARK: - The Linear webhooks line

    func testTheLinearWebhooksLineFromAnOlderSymphonyIsNotAvailable() {
        let line = LinearWebhooksLine(health: nil, now: now)
        XCTAssertEqual(line.state, .notAvailable)
        XCTAssertFalse(line.isAvailable)
        XCTAssertFalse(line.isWarning)
        XCTAssertEqual(line.word, "Not available")
        XCTAssertEqual(line.detail, "Not available on this Symphony: update it to see Linear's deliveries here.")
    }

    func testTheLinearWebhooksLineOff() {
        let line = LinearWebhooksLine(health: LinearWebhookHealth(enabled: false, total: 4), now: now)
        XCTAssertEqual(line.state, .off)
        XCTAssertTrue(line.isAvailable)
        XCTAssertEqual(line.word, "Off")
        XCTAssertEqual(line.detail, "Symphony learns of Linear changes by polling. Turn the webhook on in Settings.")
    }

    func testTheLinearWebhooksLineWaitingForTheFirstDelivery() {
        let line = LinearWebhooksLine(health: LinearWebhookHealth(enabled: true, secretConfigured: true), now: now)
        XCTAssertEqual(line.state, .waiting)
        XCTAssertEqual(line.word, "On")
        XCTAssertEqual(line.detail, "No deliveries yet since Symphony started.")
    }

    /// The operator edited a ticket in Linear: the line counts the deliveries and says how long ago the last came.
    func testTheLinearWebhooksLineWithDeliveriesArriving() {
        let health = LinearWebhookHealth(enabled: true, secretConfigured: true, total: 1_204, lastAt: now.addingTimeInterval(-12))
        let line = LinearWebhooksLine(health: health, now: now)
        XCTAssertEqual(line.state, .arriving)
        XCTAssertFalse(line.isWarning)
        XCTAssertEqual(line.word, "On")
        XCTAssertEqual(line.detail, "1,204 deliveries, last 12 s ago.")

        let one = LinearWebhookHealth(enabled: true, secretConfigured: true, total: 1, lastAt: now.addingTimeInterval(-180))
        XCTAssertEqual(LinearWebhooksLine(health: one, now: now).detail, "1 delivery, last 3 min ago.")
        let undated = LinearWebhookHealth(enabled: true, secretConfigured: true, total: 2)
        XCTAssertEqual(LinearWebhooksLine(health: undated, now: now).detail, "2 deliveries.")
    }

    func testTheLinearWebhooksLineCallsOutRefusedDeliveriesWithTheLastReason() {
        let health = LinearWebhookHealth(
            enabled: true, secretConfigured: true, total: 3, rejected: 2, lastAt: now.addingTimeInterval(-12),
            lastRejectedAt: now.addingTimeInterval(-240), lastRejectedReason: "bad_signature"
        )
        let line = LinearWebhooksLine(health: health, now: now)
        XCTAssertEqual(line.state, .rejecting)
        XCTAssertTrue(line.isWarning)
        XCTAssertEqual(line.word, "Deliveries refused")
        XCTAssertEqual(
            line.detail,
            "3 deliveries, last 12 s ago. 2 refused, the last 4 min ago because its signature didn't match the secret."
        )

        let none = LinearWebhookHealth(enabled: true, rejected: 1, lastRejectedReason: "missing_secret")
        XCTAssertEqual(
            LinearWebhooksLine(health: none, now: now).detail,
            "No delivery accepted yet. 1 refused, the last because no signing secret is set."
        )
        let unexplained = LinearWebhookHealth(enabled: true, secretConfigured: true, rejected: 1)
        XCTAssertEqual(LinearWebhooksLine(health: unexplained, now: now).detail, "No delivery accepted yet. 1 refused.")
    }

    func testTheLinearWebhooksLineWarnsWithoutASigningSecret() {
        let line = LinearWebhooksLine(health: LinearWebhookHealth(enabled: true, secretConfigured: false), now: now)
        XCTAssertEqual(line.state, .rejecting)
        XCTAssertTrue(line.isWarning)
        XCTAssertEqual(line.word, "No signing secret")
        XCTAssertEqual(line.detail, "No signing secret is set, so Symphony will refuse every delivery. Set the secret in Settings.")
    }

    func testRefusalReasonsInPlainWords() {
        XCTAssertEqual(LinearWebhooksLine.reason("missing_signature"), "it had no signature")
        XCTAssertEqual(LinearWebhooksLine.reason("stale_timestamp"), "it was more than a minute old")
        XCTAssertEqual(LinearWebhooksLine.reason("too_large"), "too large")
    }

    // MARK: - The Dispatch shadow line

    /// Against an older Symphony the line says the feature is not available, greyed out with no differences.
    func testTheDispatchShadowLineFromAnOlderSymphonyIsNotAvailable() {
        let line = DispatchShadowLine(report: nil, now: now)
        XCTAssertEqual(line.state, .notAvailable)
        XCTAssertFalse(line.isAvailable)
        XCTAssertFalse(line.isWarning)
        XCTAssertEqual(line.word, "Not available")
        XCTAssertEqual(line.detail, "Not available on this Symphony: update it to compare dispatch from the record with the Linear poll.")
        XCTAssertEqual(line.rows, [])
    }

    /// The operator opens Setup with dispatch on the poll: the cycles compared and zero differences.
    func testTheDispatchShadowLineOnThePollWithNoDifferences() {
        let line = DispatchShadowLine(report: DispatchShadowReport(cyclesCompared: 140, windowCycles: 20), now: now)
        XCTAssertEqual(line.state, .pollClean)
        XCTAssertTrue(line.isAvailable)
        XCTAssertFalse(line.isWarning)
        XCTAssertEqual(line.word, "No differences")
        XCTAssertEqual(line.detail, "Dispatch runs from the Linear poll. 140 cycles compared, 0 differences in the last 20 cycles.")
        XCTAssertEqual(line.rows, [])

        let starting = DispatchShadowLine(report: DispatchShadowReport(cyclesCompared: 1, windowCycles: 1), now: now)
        XCTAssertEqual(starting.detail, "Dispatch runs from the Linear poll. 1 cycle compared, 0 differences in the last cycle.")
        let none = DispatchShadowLine(report: DispatchShadowReport(), now: now)
        XCTAssertEqual(none.detail, "Dispatch runs from the Linear poll. No cycle compared yet since Symphony started.")
    }

    /// An older difference left the window: the line is clean and still says when the last one was.
    func testTheDispatchShadowLineSaysWhenTheLastDifferenceWas() {
        let report = DispatchShadowReport(
            cyclesCompared: 1_204, cyclesWithDifferences: 1, windowCycles: 20,
            recent: [.init(identifier: "TP-1", side: .poll, field: "candidate", poll: "Todo", at: now.addingTimeInterval(-600))]
        )
        let line = DispatchShadowLine(report: report, now: now)
        XCTAssertEqual(line.state, .pollClean)
        XCTAssertEqual(
            line.detail,
            "Dispatch runs from the Linear poll. 1,204 cycles compared, 0 differences in the last 20 cycles. The last difference was 10 min ago."
        )
    }

    func testTheDispatchShadowLineCallsOutDifferencesWhileThePollDispatches() {
        let report = DispatchShadowReport(
            cyclesCompared: 140, cyclesWithDifferences: 2, windowCycles: 20, windowDifferences: 3,
            recent: [
                .init(identifier: "TP-1221", side: .both, field: "priority", poll: "1", record: "2", at: now.addingTimeInterval(-12)),
                .init(identifier: "TP-1222", side: .record, field: "candidate", record: "Todo", at: now.addingTimeInterval(-240)),
                .init(identifier: "TP-1223", side: .poll, field: "candidate", poll: "Todo"),
            ]
        )
        let line = DispatchShadowLine(report: report, now: now)
        XCTAssertEqual(line.state, .pollDiffering)
        XCTAssertTrue(line.isWarning)
        XCTAssertEqual(line.word, "3 differences")
        XCTAssertEqual(
            line.detail,
            "Dispatch runs from the Linear poll. 140 cycles compared, 3 differences in the last 20 cycles. The last difference was 12 s ago."
        )
        XCTAssertEqual(
            line.rows,
            [
                .init(id: 0, identifier: "TP-1221", side: "In both", field: "Priority", values: "1 in the poll, 2 in the record", ago: "12 s ago"),
                .init(id: 1, identifier: "TP-1222", side: "Only in the record", field: "Candidate", values: "none in the poll, Todo in the record", ago: "4 min ago"),
                .init(id: 2, identifier: "TP-1223", side: "Only in the poll", field: "Candidate", values: "Todo in the poll, none in the record", ago: nil),
            ]
        )

        let one = DispatchShadowLine(report: DispatchShadowReport(cyclesCompared: 3, windowCycles: 3, windowDifferences: 1), now: now)
        XCTAssertEqual(one.word, "1 difference")
        XCTAssertEqual(one.detail, "Dispatch runs from the Linear poll. 3 cycles compared, 1 difference in the last 3 cycles.")
    }

    /// The operator switched to Symphony's record: the line says so, and the window's differences are information.
    func testTheDispatchShadowLineFromTheRecord() {
        let report = DispatchShadowReport(
            source: .record, window: 5, cyclesCompared: 40, windowCycles: 9, windowDifferences: 2,
            recent: [.init(identifier: "TP-9", side: .other("some_side"), field: "due_date", at: now.addingTimeInterval(-180))]
        )
        let line = DispatchShadowLine(report: report, now: now)
        XCTAssertEqual(line.state, .record)
        XCTAssertTrue(line.isAvailable)
        XCTAssertFalse(line.isWarning)
        XCTAssertEqual(line.word, "From the record")
        XCTAssertEqual(
            line.detail,
            "Dispatch runs from Symphony's record. 40 cycles compared, 2 differences in the last 5 cycles, for information. "
                + "The last difference was 3 min ago."
        )
        XCTAssertEqual(line.rows, [.init(id: 0, identifier: "TP-9", side: "Some Side", field: "Due Date", values: nil, ago: "3 min ago")])

        let fresh = DispatchShadowLine(report: DispatchShadowReport(source: .record), now: now)
        XCTAssertEqual(fresh.detail, "Dispatch runs from Symphony's record. No cycle compared yet since Symphony started.")
    }

    // MARK: - Open fixes (AC 5)

    func testOpenFixesGoWhereTheOperatorFixesIt() {
        let url = URL(string: "https://linear.app/t/settings")!
        XCTAssertEqual(SetupDestination(.settings, url: nil), .settings)
        XCTAssertEqual(SetupDestination(.symphonyYML, url: nil), .symphonyYML)
        XCTAssertEqual(SetupDestination(.linear, url: url), .linear(url))
        XCTAssertEqual(SetupDestination(.drainReport, url: nil), .drainReport(nil))
        XCTAssertEqual(SetupDestination(.repos, url: nil), .repos)
        XCTAssertEqual(SetupDestination(.update, url: nil), .update)
        XCTAssertEqual(
            [SetupDestination.settings, .symphonyYML, .linear(nil), .drainReport(nil), .repos, .update].map(\.title),
            ["Open Settings…", "Open symphony.yml", "Open in Linear", "Open Drain Report", "Open Repos", "Check for Updates…"]
        )
        let row = SetupPage.Row(problem: SetupPayload.Problem(
            id: "o", severity: .error, category: "statuses", title: "O", consequence: "", fix: .open(.drainReport, url: url)
        ))
        XCTAssertEqual(row.action, .open(.drainReport(url)))
        XCTAssertEqual(row.actionTitle, "Open Drain Report")
    }

    // MARK: - Overview (SU1)

    func testOverviewHasOneRowForSetupErrors() throws {
        let data = try Data(contentsOf: Self.fixture().appendingPathComponent("state.json"))
        let state = try XCTUnwrap(OverviewState.decode(data))
        let overview = Overview(state: state, now: now)
        let row = try XCTUnwrap(overview.problems.first { $0.id == "setup" })
        XCTAssertEqual(row.sentence, "Setup has 1 error.")
        XCTAssertEqual(row.fixes, [.openSetup])
        XCTAssertEqual(row.severity, .problem)
        XCTAssertEqual(row.kinds, [.setup])
        XCTAssertNil(row.ticketIdentifier)
        XCTAssertEqual(Overview.Fix.openSetup.title, "Open Setup")
        XCTAssertEqual(overview.sentence, "1 thing needs attention.")

        var healthy = state
        healthy.snapshot.setup = SetupPayload(problems: [problem("future:x")], checkedAt: now)
        XCTAssertFalse(Overview(state: healthy, now: now).problems.contains { $0.id == "setup" })
    }

    // MARK: - Sidebar

    func testSetupSitsBetweenReposAndDiagnostics() {
        let sidebar = Sidebar()
        XCTAssertEqual(sidebar.sections.last?.views, [.repos, .setup, .diagnostics])
        XCTAssertEqual(SymphonyView.setup.title, "Setup")
        XCTAssertEqual(SymphonyView.setup.symbol, "wrench.and.screwdriver")
        XCTAssertEqual(SymphonyView.setup.section, .factory)
        XCTAssertFalse(SymphonyView.setup.opensOwnWindow)
        XCTAssertEqual(sidebar.restoredView(saved: "setup"), .setup)
        XCTAssertEqual(WindowState.Action.checkForUpdates.title, "Check for Updates…")
    }
}

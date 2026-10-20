import XCTest
@testable import SymphonyBarCore

final class SetupFixSheetTests: XCTestCase {
    private let label = SetupPayload.Problem(
        id: "labels:missing:TP:Needs Decision", severity: .error, category: "labels",
        title: "Team TP has no \"Needs Decision\" label",
        consequence: "Decisions you are asked for can't be marked on the ticket.",
        repos: ["web-shop"],
        fix: .linear(action: "create_label", team: "TP", name: "Needs Decision", type: nil)
    )

    private let key = SetupPayload.Problem(
        id: "deprecated_key:auto_review.enabled", severity: .warning, category: "keys",
        title: "symphony.yml sets auto_review.enabled, which is deprecated", consequence: "Nothing uses it any more.",
        fix: .configEdit(path: "auto_review.enabled", action: .remove, value: .null)
    )

    private let drift = SetupPayload.Problem(
        id: "hold_drift:web-shop", severity: .warning, category: "labels", title: "2 tickets", consequence: "Re-sync.",
        repos: ["web-shop"], tickets: [.init(identifier: "TP-12"), .init(identifier: "TP-13")],
        details: [.init(label: "TP-12", value: "Blocked label with no hold")],
        fix: .resyncHold(repo: "web-shop", tickets: ["TP-12", "TP-13"])
    )

    // MARK: - Linear (AC 4)

    func testALinearFixNamesTheActionTheNameAndTheTeam() throws {
        let sheet = try XCTUnwrap(SetupFixSheet(problem: label))
        XCTAssertEqual(sheet.title, "Create the label “Needs Decision” in team TP?")
        XCTAssertEqual(sheet.verb, "Create Label")
        XCTAssertEqual(sheet.kind, .linear(["Kind: Label", "Name: Needs Decision", "Team: TP"]))
        XCTAssertEqual(sheet.happens, "Symphony creates one label in Linear, “Needs Decision”, in team TP. Why: Decisions you are asked for can't be marked on the ticket.")
        XCTAssertEqual(sheet.stays, "No ticket gets the label, and the team's other labels stay as they are.")
        XCTAssertEqual(sheet.undo, "To undo it, delete the label “Needs Decision” in Linear: Settings › Teams › TP › Labels.")
        XCTAssertEqual(sheet.phase, .ready)
        XCTAssertEqual(sheet.confirmTitle, "Create Label")
        XCTAssertEqual(sheet.cancelTitle, "Cancel")
        XCTAssertTrue(sheet.canConfirm)
        XCTAssertEqual(sheet.fix.descriptor() as? [String: String], ["kind": "linear", "action": "create_label", "team": "TP", "name": "Needs Decision"])
    }

    func testAStatusFixNamesItsTypeAndPosition() throws {
        var problem = label
        problem.fix = .linear(action: "create_state", team: "TP", name: "Plan Review", type: "started")
        let sheet = try XCTUnwrap(SetupFixSheet(problem: problem))
        XCTAssertEqual(sheet.title, "Create the status “Plan Review” in team TP?")
        XCTAssertEqual(sheet.verb, "Create Status")
        XCTAssertEqual(sheet.kind, .linear(["Kind: Status", "Name: Plan Review", "Team: TP", "Type: Started", "Position: last of the Started statuses"]))
        XCTAssertEqual(sheet.undo, "To undo it, delete the status “Plan Review” in Linear: Settings › Teams › TP › Workflow.")
        XCTAssertEqual(sheet.stays, "No ticket moves, and the team's other statuses stay as they are.")
        XCTAssertEqual(sheet.fix.descriptor()?["type"] as? String, "started")
        XCTAssertEqual(
            ["backlog", "unstarted", "completed", "canceled", "triage", "other"].map(SetupFixSheet.stateTypeWord),
            ["Backlog", "Unstarted", "Completed", "Canceled", "Triage", "other"]
        )
    }

    func testAnUnknownLinearActionStillSaysWhere() throws {
        var problem = label
        problem.fix = .linear(action: "merge_labels", team: "TP", name: "x", type: nil)
        let sheet = try XCTUnwrap(SetupFixSheet(problem: problem))
        XCTAssertEqual(sheet.title, "Fix this in team TP?")
        XCTAssertEqual(sheet.verb, "Fix")
        XCTAssertTrue(sheet.happens.hasPrefix("Symphony makes this change in Linear in team TP."))
    }

    func testAReSyncListsItsTickets() throws {
        let all = try XCTUnwrap(SetupFixSheet(problem: drift))
        XCTAssertEqual(all.title, "Re-sync the hold labels of 2 tickets in web-shop?")
        XCTAssertEqual(all.tickets, ["TP-12", "TP-13"])
        XCTAssertEqual(all.kind, .linear(["TP-12: Blocked label with no hold", "TP-13"]))
        XCTAssertEqual(all.fix.descriptor(tickets: all.tickets)?["tickets"] as? [String], ["TP-12", "TP-13"])

        let one = try XCTUnwrap(SetupFixSheet(problem: drift, ticket: "TP-13"))
        XCTAssertEqual(one.title, "Re-sync the hold label of TP-13?")
        XCTAssertEqual(one.verb, "Re-sync")
        XCTAssertEqual(one.fix.descriptor(tickets: one.tickets) as NSDictionary?, ["kind": "linear", "action": "resync_hold", "repo": "web-shop", "tickets": ["TP-13"]])
        XCTAssertNotEqual(one.id, all.id)
    }

    func testOpenAndUnknownFixesHaveNoSheet() {
        var problem = label
        problem.fix = .open(.settings, url: nil)
        XCTAssertNil(SetupFixSheet(problem: problem))
        problem.fix = .unknown("x")
        XCTAssertNil(SetupFixSheet(problem: problem))
        problem.fix = nil
        XCTAssertNil(SetupFixSheet(problem: problem))
        XCTAssertNil(SetupPayload.Fix.open(.settings, url: nil).descriptor())
        XCTAssertNil(SetupPayload.Fix.configEdit(path: "a", action: .remove, value: .null).descriptor())
    }

    // MARK: - A fix that fails (AC 4, SU9)

    func testAFailedFixKeepsTheSheetWithTheReason() throws {
        var sheet = try XCTUnwrap(SetupFixSheet(problem: label))
        let shown = sheet
        XCTAssertNil(sheet.failedDestination)
        sheet.start()
        XCTAssertTrue(sheet.isWorking)
        XCTAssertFalse(sheet.canConfirm)
        sheet.fail("Linear refused to create the label \"Needs Decision\" in team TP: HTTP 403.")
        XCTAssertEqual(sheet.error, "Linear refused to create the label \"Needs Decision\" in team TP: HTTP 403.")
        XCTAssertEqual(sheet.confirmTitle, "Try Again")
        XCTAssertEqual(sheet.cancelTitle, "Close")
        XCTAssertEqual(sheet.failedDestination, .settings)
        XCTAssertEqual(sheet.failedDestination?.title, "Open Settings…")
        XCTAssertTrue(sheet.canConfirm)
        // Everything else the sheet shows stays.
        XCTAssertEqual(sheet.title, shown.title)
        XCTAssertEqual(sheet.kind, shown.kind)
        XCTAssertEqual(sheet.happens, shown.happens)
        XCTAssertEqual(sheet.id, shown.id)
        sheet.start()
        XCTAssertNil(sheet.error)
        XCTAssertNil(sheet.failedDestination)
    }

    // MARK: - Config (SU7)

    func testAConfigSheetShowsTheExactDiff() throws {
        let text = "auto_review:\n  enabled: true\nagent:\n  runtime: claude\n"
        let edited = try SetupConfigEdit.apply(path: "auto_review.enabled", action: .remove, value: .null, to: text)
        let sheet = try XCTUnwrap(SetupFixSheet(problem: key, text: text, edited: .success(edited)))
        XCTAssertEqual(sheet.title, "Remove auto_review.enabled from symphony.yml?")
        XCTAssertEqual(sheet.verb, "Remove")
        guard case let .config(diff?) = sheet.kind else { return XCTFail("no diff") }
        XCTAssertEqual(diff.removed, ["auto_review:", "  enabled: true"])
        XCTAssertTrue(sheet.happens.contains("symphony.yml.<time>.bak"))
        XCTAssertEqual(sheet.stays, "Every other line of symphony.yml stays as it is. Nothing changes in Linear.")
        XCTAssertTrue(sheet.undo.hasPrefix("Undo shows for 10 seconds"))
        XCTAssertTrue(sheet.canConfirm)
    }

    func testAConfigEditThatCantBeMadeOpensFailed() throws {
        let sheet = try XCTUnwrap(SetupFixSheet(problem: key, text: "x: 1\n", edited: .failure(SetupConfigEditError.notFound("auto_review.enabled"))))
        XCTAssertEqual(sheet.kind, .config(nil))
        XCTAssertEqual(sheet.error, "symphony.yml has no auto_review.enabled any more. Check Again to see whether the problem is gone.")
        XCTAssertFalse(sheet.canConfirm)
        let unread = try XCTUnwrap(SetupFixSheet(problem: key, fileName: "my.yml"))
        XCTAssertEqual(unread.error, "The app couldn't read my.yml.")
        XCTAssertEqual(unread.title, "Remove auto_review.enabled from my.yml?")
    }

    func testConfigTitlesAndVerbs() {
        XCTAssertEqual(SetupFixSheet.configTitle(path: "a.labels", action: .remove, value: .string("human-action"), fileName: "symphony.yml"), "Remove “human-action” from a.labels?")
        XCTAssertEqual(SetupFixSheet.configTitle(path: "repositories[w].route.team", action: .set, value: .string("TP"), fileName: "symphony.yml"), "Set repositories[w].route.team to TP?")
        XCTAssertEqual(SetupFixSheet.configTitle(path: "p", action: .add, value: .string("x"), fileName: "symphony.yml"), "Add x to p?")
        XCTAssertEqual([SetupPayload.ConfigAction.remove, .set, .add].map(SetupFixSheet.configVerb), ["Remove", "Change", "Add"])
    }

    // MARK: - Banner (SU10)

    func testBannersSayWhatTheFixDid() throws {
        let backup = SetupBackup(url: URL(fileURLWithPath: "/c/symphony.yml.20261019-233512.bak"), original: URL(fileURLWithPath: "/c/symphony.yml"))
        let removed = SetupBanner.fixed(try XCTUnwrap(SetupFixSheet(problem: key, text: "", edited: .success(""))), backup: backup)
        XCTAssertEqual(removed.text, "Removed auto_review.enabled from symphony.yml. The old file is symphony.yml.20261019-233512.bak.")
        XCTAssertTrue(removed.offersUndo)
        XCTAssertEqual(removed.style, .success)

        let created = SetupBanner.fixed(try XCTUnwrap(SetupFixSheet(problem: label)))
        XCTAssertEqual(created.text, "Created the label “Needs Decision” in team TP.")
        XCTAssertFalse(created.offersUndo)
        XCTAssertEqual(SetupBanner.fixed(try XCTUnwrap(SetupFixSheet(problem: drift, ticket: "TP-12"))).text, "Re-synced the hold label of TP-12.")
        XCTAssertEqual(SetupBanner.fixed(try XCTUnwrap(SetupFixSheet(problem: drift))).text, "Re-synced the hold labels of 2 tickets.")

        for (fix, text) in [
            (SetupPayload.Fix.configEdit(path: "l", action: .remove, value: .string("x")), "Removed “x” from l."),
            (.configEdit(path: "t", action: .set, value: .string("TP")), "Set t to TP."),
            (.configEdit(path: "p", action: .add, value: .string("y")), "Added y to p."),
            (.linear(action: "merge", team: "TP", name: "x", type: nil), "Symphony made the change in team TP."),
        ] {
            var problem = key
            problem.fix = fix
            let sheet = try XCTUnwrap(SetupFixSheet(problem: problem, text: "", edited: .success("")))
            XCTAssertEqual(SetupBanner.fixed(sheet).text, text)
        }
        XCTAssertEqual(SetupBanner.undone.style, .info)
        XCTAssertNotEqual(SetupBanner.undone.id, SetupBanner.undone.id)
        XCTAssertEqual(SetupBanner.failed("x").style, .error)
        XCTAssertEqual(SetupBanner.duration, 10)
    }

    // MARK: - Check Again and the fixes endpoint

    func testRequests() throws {
        let base = URL(string: "http://127.0.0.1:4000")!
        let refresh = SetupAPI.request(base: base)
        XCTAssertEqual(refresh.url?.absoluteString, "http://127.0.0.1:4000/api/v1/setup/refresh")
        XCTAssertEqual(refresh.httpMethod, "POST")
        XCTAssertNil(refresh.httpBody)
        XCTAssertNil(refresh.value(forHTTPHeaderField: "Origin"))

        let fix = SetupAPI.request(fix: ["kind": "linear", "action": "create_label", "team": "TP", "name": "Needs Decision"], base: base)
        XCTAssertEqual(fix.url?.path, "/api/v1/setup/fixes")
        XCTAssertEqual(fix.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(fix.httpBody)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"fix":{"action":"create_label","kind":"linear","name":"Needs Decision","team":"TP"}}"#)
    }

    func testAnswers() throws {
        let ok = Data(#"{"problems": [], "not_checked": [], "checked_at": "2026-10-19T12:01:00Z", "linear_checked_at": null}"#.utf8)
        guard case let .checked(payload) = SetupAPI.result(prefix: "p", statusCode: 200, data: ok) else { return XCTFail("not checked") }
        XCTAssertEqual(payload.checkedAt, ISO8601DateFormatter().date(from: "2026-10-19T12:01:00Z"))

        let refused = try Data(contentsOf: SetupTests.fixture("setup-refused").appendingPathComponent("setup/fixes.json"))
        XCTAssertEqual(
            SetupAPI.result(prefix: "The fix didn't run", statusCode: 422, data: refused),
            .failed("Linear refused to create the label \"Needs Decision\" in team TP: the Linear API key isn't allowed to (HTTP 403). Ask an admin of the team to do it, or use a key that may.")
        )
        // The fixtures answer every POST 200: the error still makes it a failure.
        XCTAssertEqual(SetupAPI.result(prefix: "p", statusCode: 200, data: refused), SetupAPI.result(prefix: "p", statusCode: 422, data: refused))

        let notProposed = Data(#"{"error": {"code": "fix_not_proposed", "message": "The latest setup check didn't propose this fix."}}"#.utf8)
        XCTAssertEqual(SetupAPI.result(prefix: "The fix didn't run", statusCode: 422, data: notProposed), .failed("The fix didn't run: The latest setup check didn't propose this fix."))
        XCTAssertEqual(SetupAPI.result(prefix: "p", statusCode: 500, data: Data(#"{"error": {"code": "boom"}}"#.utf8)), .failed("p: boom"))
        XCTAssertEqual(SetupAPI.result(prefix: "p", statusCode: 500, data: Data(#"{"error": {}}"#.utf8)), .failed("p: Symphony reported an error"))
        XCTAssertEqual(SetupAPI.result(prefix: "p", statusCode: 404, data: Data()), .failed("p: this Symphony predates Setup. Update it."))
        XCTAssertEqual(SetupAPI.result(prefix: "p", statusCode: 502, data: Data()), .failed("p: Symphony answered with HTTP 502."))
        XCTAssertEqual(SetupAPI.result(prefix: "p", statusCode: 200, data: Data("[]".utf8)), .failed("p: Symphony's answer couldn't be read."))
    }

    func testSendThroughATransport() async throws {
        let root = uniqueTemporaryDirectory("setup-api")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var sent: URLRequest?
        let answer = Data(#"{"problems": [], "checked_at": "2026-10-19T12:01:00Z"}"#.utf8)
        let result = await SetupAPI.send(stateRoot: root, fallback: URL(string: "http://127.0.0.1:4000")) { request in
            sent = request
            return (answer, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard case .checked = result else { return XCTFail("\(result)") }
        XCTAssertEqual(sent?.url?.path, "/api/v1/setup/refresh")

        let unreachable = await SetupAPI.send(fix: ["kind": "linear"], stateRoot: root, fallback: URL(string: "http://127.0.0.1:4000")) { _ in
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertEqual(unreachable, .failed("The fix didn't run: nothing answered at http://127.0.0.1:4000."))
        let nowhere = await SetupAPI.send(stateRoot: root, fallback: nil) { _ in throw URLError(.badURL) }
        XCTAssertEqual(nowhere, .failed("Couldn't check the setup again: Symphony hasn't said where it listens."))
    }

    // MARK: - QA fixtures: a POST answered in turn

    func testTheSetupFixturesAnswerFixUndoAndFixAgainInTurn() throws {
        let root = uniqueTemporaryDirectory("setup-fixtures")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fixtures = APIFixtures(directory: SetupTests.fixture().deletingLastPathComponent().deletingLastPathComponent(), requestLog: root.appendingPathComponent("log.jsonl"))
        func post(_ path: String) -> SetupPayload? {
            var request = URLRequest(url: APIFixtures.baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            return SetupPayload.decode(fixtures.answer(request).0)
        }

        XCTAssertEqual(post("api/v1/setup/fixes")?.problems.map(\.id), ["deprecated_key:auto_review.enabled"])
        let answers = (1...5).map { _ in post("api/v1/setup/refresh") }
        XCTAssertEqual(answers.map { $0?.problems.count }, [0, 1, 0, 0, 0])
        let times = answers.compactMap { $0?.checkedAt }
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(fixtures.postCount("/api/v1/setup/refresh"), 5)
        XCTAssertEqual(fixtures.postCount("/api/v1/setup/fixes"), 1)
        // A POST with no fixture at all answers as before.
        var other = URLRequest(url: APIFixtures.baseURL.appendingPathComponent("api/v1/control/pause"))
        other.httpMethod = "POST"
        XCTAssertEqual(String(decoding: fixtures.answer(other).0, as: UTF8.self), #"{"ok":true}"#)
    }
}

import Foundation
import XCTest
@testable import SymphonyBarCore

/// What needs attention, today's meters and the words every page writes durations in (`Overview`); Home's board is
/// `HomeBoardTests`.
final class OverviewTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// Never used while a fixture has `generated_at`: ages count from Symphony's clock.
    private let wallClock = Date(timeIntervalSince1970: 0)

    // MARK: - What needs attention, from the fixtures

    func testAFlowingFactoryNeedsNothing() throws {
        XCTAssertTrue(try problems("flowing").isEmpty)
        XCTAssertEqual(Overview.badgeCount(try state("flowing"), now: wallClock), 0)
        XCTAssertTrue(try problems("paused").isEmpty)
        XCTAssertTrue(try problems("idle").isEmpty)
    }

    func testAttentionListsAStuckForcedTicketAndAUsageLimitHoldWithTheirFixes() throws {
        let problems = try problems("attention")

        XCTAssertEqual(problems.count, 2)
        let stuck = problems[0]
        XCTAssertEqual(stuck.id, "SHOP-305")
        XCTAssertEqual(stuck.kinds, [.stuck, .staleForced])
        XCTAssertEqual(stuck.severity, .problem)
        XCTAssertEqual(
            stuck.sentence,
            "SHOP-305 shows no agent activity for 14 min. It has been forced for 3 days and is still not done."
        )
        XCTAssertEqual(stuck.age, "3 days")
        // J3: the stuck row's first fix is Stop Run…, then Open (the ticket page).
        XCTAssertEqual(stuck.fixes, [.stopRun("SHOP-305"), .open("SHOP-305"), .stopForcing("SHOP-305")])
        XCTAssertEqual(stuck.fixes.map(\.title), ["Stop Run…", "Open", "Stop Forcing"])

        let hold = problems[1]
        XCTAssertEqual(hold.kinds, [.usageLimit])
        XCTAssertEqual(hold.severity, .warning)
        XCTAssertEqual(hold.sentence, "The Codex 5-hour limit holds new runs until 15:40.")
        XCTAssertEqual(hold.note, "Runs resume by themselves.")
        XCTAssertEqual(hold.fixes, [.openUsage])
        XCTAssertEqual(hold.fixes.map(\.title), ["Open Usage"])
        XCTAssertEqual(Overview.badgeCount(try state("attention"), now: wallClock), 2)
    }

    func testTodaysMetersReadTheBudgetAndTheLimits() throws {
        let flowing = try meters("flowing")
        XCTAssertEqual(flowing.map(\.label), ["Tokens today"])
        XCTAssertEqual(flowing.first?.value, "3.1M of 5M")
        XCTAssertEqual(flowing.first?.level, .normal)
        XCTAssertEqual(flowing.first?.accessibilityLabel, "Tokens today, 62 percent of budget")

        let attention = try meters("attention")
        XCTAssertEqual(attention.map(\.label), ["Tokens today", "Codex 5-hour limit"])
        XCTAssertEqual(attention.map(\.level), [.near, .atLimit])
        XCTAssertEqual(attention[1].value, "100% used")
        XCTAssertEqual(attention[1].note, "resets 15:40")
        XCTAssertEqual(attention[1].accessibilityLabel, "Codex 5-hour limit, 100 percent used")
        XCTAssertEqual(try meters("idle").first?.value, "0 of 5M")
    }

    // MARK: - Stuck (DD7)

    func testARunCountsAsStuckFromTenMinutesWithoutAnAgentEvent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func problems(idle: TimeInterval) -> [Overview.Problem] {
            let run = OverviewState.Run(identifier: "SHOP-1", repoKey: "web-shop", startedAt: now.addingTimeInterval(-3_600), lastEventAt: now.addingTimeInterval(-idle))
            return Overview.problems(OverviewState(generatedAt: now, running: [run]), now: now, timeZone: utc)
        }

        XCTAssertTrue(problems(idle: 599).isEmpty)
        XCTAssertEqual(problems(idle: 600).map(\.kinds), [[.stuck]])
        XCTAssertEqual(problems(idle: 600).first?.sentence, "SHOP-1 shows no agent activity for 10 min.")
        XCTAssertFalse(Overview.isStuck(idleSeconds: 9 * 60 + 59))
        XCTAssertTrue(Overview.isStuck(idleSeconds: 10 * 60))
    }

    func testARunWithoutAnEventCountsFromItsStart() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let run = OverviewState.Run(identifier: "SHOP-1", startedAt: now.addingTimeInterval(-900))
        XCTAssertEqual(Overview.problems(OverviewState(generatedAt: now, running: [run]), now: now, timeZone: utc).map(\.id), ["SHOP-1"])
    }

    func testAgesUseTheWallClockWhenTheStateHasNoTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let run = OverviewState.Run(identifier: "SHOP-1", lastEventAt: now.addingTimeInterval(-700))
        XCTAssertEqual(Overview.problems(OverviewState(running: [run]), now: now, timeZone: utc).count, 1)
    }

    // MARK: - The other problems

    func testEveryOtherProblemKindCarriesItsFix() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ticket = OverviewState.Ticket(identifier: "API-9", repoKey: "api", url: URL(string: "https://linear.app/acme/issue/API-9/slug"))
        let state = OverviewState(
            generatedAt: now,
            watching: [ticket],
            retrying: [
                OverviewState.Retry(identifier: "API-7", repoKey: "api", attempt: 3, error: "agent exited: turn timeout"),
                OverviewState.Retry(identifier: "API-8", repoKey: "api", attempt: 2),
            ],
            conflicts: [OverviewState.Conflict(identifier: "SHOP-4", url: URL(string: "https://linear.app/acme/issue/SHOP-4"), repoKeys: ["web-shop", "api"])],
            strayProcesses: [OverviewState.StrayProcess(pid: 1), OverviewState.StrayProcess(pid: 2)]
        )
        let problems = Overview.problems(state, now: now, timeZone: utc)

        XCTAssertEqual(problems.map(\.id), ["API-7", "SHOP-4", "stray-processes"])
        XCTAssertEqual(problems[0].sentence, "API-7 keeps failing: agent exited: turn timeout.")
        XCTAssertEqual(problems[0].severity, .problem)
        XCTAssertEqual(problems[0].fixes, [.open("API-7"), .stopRun("API-7")])
        XCTAssertEqual(problems[0].fixes.map(\.title), ["Open", "Stop Run…"])
        XCTAssertEqual(problems[1].sentence, "SHOP-4 matches more than one repo (web-shop, api), so Symphony runs it in none.")
        XCTAssertEqual(problems[1].fixes.map(\.title), ["Open in Linear"])
        XCTAssertEqual(problems[2].sentence, "2 processes are still running from finished runs.")
        XCTAssertEqual(problems[2].fixes, [.openDiagnostics])
        XCTAssertEqual(Overview.Fix.openDiagnostics.title, "Open Diagnostics")

        let one = Overview.problems(OverviewState(generatedAt: now, strayProcesses: [OverviewState.StrayProcess()]), now: now, timeZone: utc)
        XCTAssertEqual(one.first?.sentence, "1 process is still running from a finished run.")
    }

    func testProblemsSortBySeverityThenAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = StateSnapshot()
        snapshot.forced = [
            StateSnapshot.ForcedTicket(identifier: "A-1", forcedForSeconds: 100_000, stale: true),
            StateSnapshot.ForcedTicket(identifier: "A-2", forcedForSeconds: 300_000, stale: true),
        ]
        snapshot.usageLimits = [StateSnapshot.UsageLimit(provider: "anthropic", phase: .headroom)]
        let state = OverviewState(
            snapshot: snapshot,
            generatedAt: now,
            running: [
                OverviewState.Run(identifier: "B-1", lastEventAt: now.addingTimeInterval(-700)),
                OverviewState.Run(identifier: "B-2", lastEventAt: now.addingTimeInterval(-1_800)),
            ]
        )
        let problems = Overview.problems(state, now: now, timeZone: utc)
        XCTAssertEqual(problems.map(\.id), ["B-2", "B-1", "A-2", "A-1", "usage-limit-anthropic-all"])
        XCTAssertEqual(problems.last?.sentence, "The Claude usage limit holds new runs.")
        // A forced ticket that isn't stale and a canary aren't problems.
        snapshot.forced = [StateSnapshot.ForcedTicket(identifier: "A-3", stale: false)]
        snapshot.usageLimits = [StateSnapshot.UsageLimit(phase: .canary)]
        XCTAssertTrue(Overview.problems(OverviewState(snapshot: snapshot, generatedAt: now), now: now, timeZone: utc).isEmpty)
    }

    func testAnUnreachableAPIHoldSaysWhenRunsTryAgain() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = StateSnapshot()
        snapshot.usageLimits = [StateSnapshot.UsageLimit(provider: "anthropic", resumeAt: now.addingTimeInterval(600), reason: "model_api_unreachable")]
        let problems = Overview.problems(OverviewState(snapshot: snapshot, generatedAt: now), now: now, timeZone: utc)
        XCTAssertEqual(problems.first?.sentence, "Claude API unreachable: new runs wait until 13:56.")
    }

    func testAFailingTicketsProblemCarriesItsSituation() throws {
        let problems = Overview.problems(try state("tickets"), now: wallClock, timeZone: utc)
        let failing = try XCTUnwrap(problems.first { $0.id == "SHOP-311" })
        XCTAssertEqual(failing.situation?.cause, "Third try of 5: mix test failed: 4 failures.")
        XCTAssertFalse(failing.sentence.contains("times"), "the count lives in the cause")
        XCTAssertNil(problems.first { $0.id == "DOCS-41" }?.situation)
    }

    // MARK: - Scope

    func testTheScopeFiltersWhatNeedsAttentionButNotTheBadge() throws {
        // The hold is on every repo; the stuck ticket is web-shop's. The badge counts both, whatever the scope.
        XCTAssertEqual(try problems("attention", scope: .repo("api")).map(\.kinds), [[.usageLimit]])
        XCTAssertEqual(Overview.badgeCount(try state("attention"), now: wallClock), 2)
    }

    func testAStaleForcedTicketWithNoKnownRepoShowsUnderEveryScope() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = StateSnapshot()
        snapshot.forced = [StateSnapshot.ForcedTicket(identifier: "A-1", forcedForSeconds: 300_000, stale: true)]
        let state = OverviewState(snapshot: snapshot, generatedAt: now)
        XCTAssertEqual(Overview.problems(state, scope: .repo("api"), now: now, timeZone: utc).map(\.kinds), [[.staleForced]])
    }

    func testTheScopeIsRememberedAsItsRepoKey() {
        XCTAssertEqual(OverviewScope(stored: nil), .all)
        XCTAssertEqual(OverviewScope(stored: " "), .all)
        XCTAssertEqual(OverviewScope(stored: "web-shop"), .repo("web-shop"))
        XCTAssertNil(OverviewScope.all.stored)
        XCTAssertEqual(OverviewScope.repo("web-shop").stored, "web-shop")
        XCTAssertEqual(OverviewScope.all.title, "All repos")
        XCTAssertEqual(OverviewScope.all.accessibilityLabel, "Scope, all repos")
        XCTAssertEqual(OverviewScope.repo("api").accessibilityLabel, "Scope, api")
        XCTAssertEqual(OverviewScope.choices(repos: ["web-shop", "api"], current: .all), [.all, .repo("api"), .repo("web-shop")])
        XCTAssertEqual(OverviewScope.choices(repos: ["api"], current: .repo("docs")), [.all, .repo("api"), .repo("docs")])
        XCTAssertTrue(OverviewScope.repo("api").includesAny(["web-shop", "api"]))
        XCTAssertFalse(OverviewScope.repo("api").includes(nil))
    }

    func testTheScopeIsStillThereAfterARelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(OverviewScope.load(from: PropertyListFileStore(file: file)), .all)
        OverviewScope.repo("web-shop").save(to: PropertyListFileStore(file: file))
        // A new store on the same file, as after a relaunch in QA mode.
        XCTAssertEqual(OverviewScope.load(from: PropertyListFileStore(file: file)), .repo("web-shop"))
        OverviewScope.all.save(to: PropertyListFileStore(file: file))
        XCTAssertEqual(OverviewScope.load(from: PropertyListFileStore(file: file)), .all)
    }

    // MARK: - Words, numbers, order

    func testDurationsAndTokensReadAsTheDesignSays() {
        XCTAssertEqual(Overview.duration(14), "14 s")
        XCTAssertEqual(Overview.duration(-3), "0 s")
        XCTAssertEqual(Overview.duration(840), "14 min")
        XCTAssertEqual(Overview.duration(11_520), "3 h 12 min")
        XCTAssertEqual(Overview.duration(7_200), "2 h")
        XCTAssertEqual(Overview.duration(86_400), "1 day")
        XCTAssertEqual(Overview.duration(200_000), "2 days")
        XCTAssertEqual(Overview.spokenDuration(1), "1 second")
        XCTAssertEqual(Overview.spokenDuration(60), "1 minute")
        XCTAssertEqual(Overview.spokenDuration(3_600), "1 hour")
        XCTAssertEqual(Overview.spokenDuration(90_000), "1 day")
        XCTAssertEqual(Overview.tokens(1_284), "1,284")
        XCTAssertEqual(Overview.tokens(845_000), "845K")
        XCTAssertEqual(Overview.tokens(3_100_000), "3.1M")
        XCTAssertEqual(Overview.tokens(5_000_000), "5M")
        XCTAssertEqual(Overview.phaseName("plan_revision"), "Plan revision")
        XCTAssertEqual(Overview.level(nil), .normal)
        XCTAssertEqual(Overview.level(0.7499), .normal)
        XCTAssertEqual(Overview.level(0.75), .near)
        XCTAssertEqual(Overview.level(0.95), .atLimit)
    }

    func testAPollKeepsTheRowsUnderThePointerInPlace() {
        XCTAssertEqual(Overview.holdingOrder(["c", "a", "b"], previous: ["a", "b"]), ["a", "b", "c"])
        XCTAssertEqual(Overview.holdingOrder(["b", "c"], previous: ["a", "b"]), ["b", "c"])
        XCTAssertEqual(Overview.holdingOrder(["b", "a"], previous: []), ["b", "a"])
    }

    func testABudgetWithoutALimitShowsTheTokensOnly() {
        var snapshot = StateSnapshot()
        snapshot.budget = StateSnapshot.Budget(dailyLimit: nil, dailyUsed: 1_284, dailyPaused: false)
        let meter = Overview.meters(snapshot, reference: wallClock, timeZone: utc).first
        XCTAssertEqual(meter?.value, "1,284 tokens, no daily budget")
        XCTAssertNil(meter?.fraction)
        XCTAssertEqual(meter?.accessibilityLabel, "Tokens today, 1,284 tokens, no daily budget")

        snapshot.budget = StateSnapshot.Budget(dailyLimit: 100, dailyUsed: 120, dailyPaused: true)
        let full = Overview.meters(snapshot, reference: wallClock, timeZone: utc).first
        XCTAssertEqual(full?.fraction, 1)
        XCTAssertEqual(full?.note, "The daily budget holds new runs.")
    }

    func testAStateThatIsntOneDecodesToNothing() {
        XCTAssertNil(OverviewState.decode(Data("nope".utf8)))
        XCTAssertNil(OverviewState.decode(Data(#"{"error":{"code":"snapshot_timeout"}}"#.utf8)))
    }

    // MARK: - Helpers

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1", isDirectory: true)
    }

    private func state(_ name: String) throws -> OverviewState {
        let data = try Data(contentsOf: fixture(name).appendingPathComponent("state.json"))
        return try XCTUnwrap(OverviewState.decode(data))
    }

    private func problems(_ name: String, scope: OverviewScope = .all) throws -> [Overview.Problem] {
        Overview.problems(try state(name), scope: scope, now: wallClock, timeZone: utc)
    }

    private func meters(_ name: String) throws -> [Overview.Meter] {
        let state = try state(name)
        return Overview.meters(state.snapshot, reference: state.generatedAt ?? wallClock, timeZone: utc)
    }
}

final class ReposEndpointResultTests: XCTestCase {
    func testTheWindowsClientAnswerReadsAsARepoPoll() {
        XCTAssertEqual(ReposAPI.poll(.unsupported), .unsupported)
        XCTAssertEqual(ReposAPI.poll(.failed("Symphony isn't answering")), .failed("Symphony isn't answering"))
        XCTAssertEqual(ReposAPI.poll(.loaded(Data(#"{"repos":[{"key":"api"}]}"#.utf8))), .repos([RepoStatus(key: "api", workflow: RepoStatus.Workflow(state: .other("unknown")))], warning: nil))
        XCTAssertEqual(ReposAPI.reposURL(base: URL(string: "http://127.0.0.1:4000")!).path, "/\(ReposAPI.path)")
    }
}

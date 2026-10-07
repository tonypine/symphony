import Foundation
import XCTest
@testable import SymphonyBarCore

final class OverviewTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// Never used while a fixture has `generated_at`: ages count from Symphony's clock.
    private let wallClock = Date(timeIntervalSince1970: 0)

    // MARK: - The four fixtures

    func testFlowingSaysSoWithItsContextAndDrawsNoNeedsAttention() throws {
        let overview = try overview("flowing")

        XCTAssertEqual(overview.mood, .flowing)
        XCTAssertEqual(overview.sentence, "The factory is flowing.")
        XCTAssertEqual(overview.context, "10 tickets in progress across 3 repos. 2 wait on you, the oldest for 3 h 12 min.")
        XCTAssertTrue(overview.problems.isEmpty)
        XCTAssertFalse(overview.showsResume)
        XCTAssertFalse(overview.showsAllCaughtUp)

        XCTAssertEqual(overview.stages.map(\.title), ["Queued", "Working", "Auto Review", "Waiting on you", "Merging", "Shipped today"])
        XCTAssertEqual(overview.stages.map(\.count), [2, 2, 2, 2, 2, 3])
        XCTAssertEqual(overview.stages.map(\.context), [
            "next: SHOP-320", "longest 22 min", "1 QA pass running", "oldest 3 h 12 min", "1 landing", "latest SHOP-288",
        ])
        XCTAssertEqual(overview.stages.filter(\.isTinted).map(\.kind), [.waitingOnYou])

        XCTAssertEqual(overview.working.map(\.identifier), ["SHOP-305", "API-131", "SHOP-298", "SHOP-301"])
        XCTAssertEqual(overview.working.map(\.kind), [.agent, .agent, .landing, .qaPass])
        let first = overview.working[0]
        XCTAssertEqual(first.detail, "Implementation · turn 7 · last activity 12 s ago")
        XCTAssertEqual(first.runningTime, "22 min")
        XCTAssertEqual(first.tokens, "1.2M tokens")
        XCTAssertEqual(first.lastMessage, "Running the checkout tests")
        XCTAssertFalse(first.isStuck)
        XCTAssertEqual(overview.working[1].phase, "Rework")
        XCTAssertEqual(overview.working[3].title, "Saved carts")
        XCTAssertEqual(overview.working[3].detail, "QA pass")

        XCTAssertEqual(overview.nextUp.map(\.identifier), ["SHOP-320", "API-133"])
        XCTAssertEqual(overview.nextUp.first?.reason, "work slots full")

        XCTAssertEqual(overview.meters.map(\.label), ["Tokens today"])
        XCTAssertEqual(overview.meters.first?.value, "3.1M of 5M")
        XCTAssertEqual(overview.meters.first?.level, .normal)
        XCTAssertEqual(overview.meters.first?.accessibilityLabel, "Tokens today, 62 percent of budget")
        XCTAssertEqual(overview.reposLine, "3 repos healthy.")
        XCTAssertEqual(Overview.badgeCount(try state("flowing"), now: wallClock), 0)
    }

    func testAttentionListsAStuckForcedTicketAndAUsageLimitHoldWithTheirFixes() throws {
        let overview = try overview("attention")

        XCTAssertEqual(overview.mood, .attention)
        XCTAssertEqual(overview.sentence, "2 things need attention.")
        XCTAssertEqual(overview.context, "10 tickets in progress across 3 repos. 2 wait on you, the oldest for 3 h 12 min.")

        XCTAssertEqual(overview.problems.count, 2)
        let stuck = overview.problems[0]
        XCTAssertEqual(stuck.id, "SHOP-305")
        XCTAssertEqual(stuck.kinds, [.stuck, .staleForced])
        XCTAssertEqual(stuck.severity, .problem)
        XCTAssertEqual(
            stuck.sentence,
            "SHOP-305 shows no agent activity for 14 min. It has been forced for 3 days and is still not done."
        )
        XCTAssertEqual(stuck.age, "3 days")
        let url = try XCTUnwrap(URL(string: "https://linear.app/acme/issue/SHOP-305"))
        XCTAssertEqual(stuck.fixes, [.open(url), .stopForcing("SHOP-305")])
        XCTAssertEqual(stuck.fixes.map(\.title), ["Open", "Stop Forcing"])

        let hold = overview.problems[1]
        XCTAssertEqual(hold.kinds, [.usageLimit])
        XCTAssertEqual(hold.severity, .warning)
        XCTAssertEqual(hold.sentence, "The Codex 5-hour limit holds new runs until 15:40.")
        XCTAssertEqual(hold.note, "Runs resume by themselves.")
        XCTAssertEqual(hold.fixes, [])

        XCTAssertTrue(overview.working[0].isStuck)
        XCTAssertEqual(Overview.badgeCount(try state("attention"), now: wallClock), 2)

        XCTAssertEqual(overview.meters.map(\.label), ["Tokens today", "Codex 5-hour limit"])
        XCTAssertEqual(overview.meters.map(\.level), [.near, .atLimit])
        XCTAssertEqual(overview.meters[1].value, "100% used")
        XCTAssertEqual(overview.meters[1].note, "resets 15:40")
        XCTAssertEqual(overview.meters[1].accessibilityLabel, "Codex 5-hour limit, 100 percent used")
        XCTAssertEqual(overview.reposLine, "2 of 3 repos healthy. web-shop needs attention.")
    }

    func testPausedSaysSinceWhenAndWhyAndOffersResume() throws {
        let overview = try overview("paused")

        XCTAssertEqual(overview.mood, .paused)
        XCTAssertEqual(overview.sentence, "Dispatch is paused since 14:03: Deploy freeze.")
        XCTAssertEqual(overview.context, "2 runs are finishing. No new run starts until you resume, forced tickets included.")
        XCTAssertTrue(overview.showsResume)
        XCTAssertEqual(Overview.resumeTitle, "Resume Dispatch")
        XCTAssertEqual(overview.stages[0].context, "held by the pause")
        XCTAssertEqual(overview.stages[1].context, "finishing")
        XCTAssertTrue(overview.problems.isEmpty)
    }

    func testIdleKeepsEveryStageAtZeroInPlaceAndIsAllCaughtUp() throws {
        let overview = try overview("idle")

        XCTAssertEqual(overview.mood, .idle)
        XCTAssertEqual(overview.sentence, "The factory is idle.")
        XCTAssertEqual(overview.context, "Nothing is queued and nothing waits on you. Tickets moved to Todo in Linear start here.")
        XCTAssertTrue(overview.showsAllCaughtUp)
        XCTAssertEqual(Overview.allCaughtUp, "All caught up.")
        XCTAssertEqual(overview.stages.map(\.kind), Overview.StageKind.allCases)
        XCTAssertTrue(overview.stages.allSatisfy(\.isZero))
        XCTAssertTrue(overview.stages.allSatisfy { !$0.isTinted })
        XCTAssertTrue(overview.working.isEmpty)
        XCTAssertTrue(overview.nextUp.isEmpty)
        XCTAssertTrue(overview.problems.isEmpty)
        XCTAssertEqual(overview.meters.first?.value, "0 of 5M")
    }

    func testTheRunningFixtureFromBeforeTheOverviewStillReads() throws {
        let overview = try overview("running")
        XCTAssertEqual(overview.stages.first { $0.kind == .shippedToday }?.count, 0)
        XCTAssertEqual(overview.stages.first { $0.kind == .waitingOnYou }?.count, 0)
    }

    // MARK: - Stuck (DD7)

    func testARunCountsAsStuckFromTenMinutesWithoutAnAgentEvent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func overview(idle: TimeInterval) -> Overview {
            let run = OverviewState.Run(identifier: "SHOP-1", repoKey: "web-shop", startedAt: now.addingTimeInterval(-3_600), lastEventAt: now.addingTimeInterval(-idle))
            return Overview(state: OverviewState(generatedAt: now, running: [run]), now: now, timeZone: utc)
        }

        XCTAssertTrue(overview(idle: 599).problems.isEmpty)
        XCTAssertFalse(overview(idle: 599).working[0].isStuck)
        XCTAssertEqual(overview(idle: 600).problems.map(\.kinds), [[.stuck]])
        XCTAssertEqual(overview(idle: 600).problems.first?.sentence, "SHOP-1 shows no agent activity for 10 min.")
        XCTAssertTrue(overview(idle: 600).working[0].isStuck)
        XCTAssertFalse(Overview.isStuck(idleSeconds: 9 * 60 + 59))
        XCTAssertTrue(Overview.isStuck(idleSeconds: 10 * 60))
    }

    func testARunWithoutAnEventCountsFromItsStart() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let run = OverviewState.Run(identifier: "SHOP-1", startedAt: now.addingTimeInterval(-900))
        let overview = Overview(state: OverviewState(generatedAt: now, running: [run]), now: now, timeZone: utc)
        XCTAssertEqual(overview.problems.map(\.id), ["SHOP-1"])
        XCTAssertNil(overview.working[0].lastActivity)
        XCTAssertEqual(overview.working[0].detail, "Working")
    }

    func testAgesUseTheWallClockWhenTheStateHasNoTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let run = OverviewState.Run(identifier: "SHOP-1", lastEventAt: now.addingTimeInterval(-700))
        XCTAssertEqual(Overview(state: OverviewState(running: [run]), now: now, timeZone: utc).problems.count, 1)
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
        let overview = Overview(state: state, now: now, timeZone: utc)

        XCTAssertEqual(overview.problems.map(\.id), ["API-7", "SHOP-4", "stray-processes"])
        XCTAssertEqual(overview.problems[0].sentence, "API-7 failed 3 times: agent exited: turn timeout.")
        XCTAssertEqual(overview.problems[0].severity, .problem)
        // Built from the workspace's issue path, as Symphony serves no URL with a retry.
        XCTAssertEqual(overview.problems[0].fixes, [.open(try XCTUnwrap(URL(string: "https://linear.app/acme/issue/API-7")))])
        XCTAssertEqual(overview.problems[1].sentence, "SHOP-4 matches more than one repo (web-shop, api), so Symphony runs it in none.")
        XCTAssertEqual(overview.problems[1].fixes.map(\.title), ["Open in Linear"])
        XCTAssertEqual(overview.problems[2].sentence, "2 processes are still running from finished runs.")
        XCTAssertEqual(overview.problems[2].fixes, [.openDiagnostics])
        XCTAssertEqual(Overview.Fix.openDiagnostics.title, "Open Diagnostics")
        XCTAssertEqual(overview.sentence, "3 things need attention.")
        XCTAssertEqual(overview.stages[0].count, 2)
        XCTAssertEqual(overview.nextUp.map(\.reason), ["retries after 3 failed attempts", "retries after 2 failed attempts"])

        let one = Overview(state: OverviewState(generatedAt: now, strayProcesses: [OverviewState.StrayProcess()]), now: now, timeZone: utc)
        XCTAssertEqual(one.problems.first?.sentence, "1 process is still running from a finished run.")
        XCTAssertEqual(one.sentence, "1 thing needs attention.")
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
        let overview = Overview(state: state, now: now, timeZone: utc)
        XCTAssertEqual(overview.problems.map(\.id), ["B-2", "B-1", "A-2", "A-1", "usage-limit-anthropic-all"])
        XCTAssertEqual(overview.problems.last?.sentence, "The Claude usage limit holds new runs.")
        // A forced ticket that isn't stale and a canary aren't problems.
        snapshot.forced = [StateSnapshot.ForcedTicket(identifier: "A-3", stale: false)]
        snapshot.usageLimits = [StateSnapshot.UsageLimit(phase: .canary)]
        XCTAssertTrue(Overview(state: OverviewState(snapshot: snapshot, generatedAt: now), now: now, timeZone: utc).problems.isEmpty)
    }

    func testAnUnreachableAPIHoldSaysWhenRunsTryAgain() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = StateSnapshot()
        snapshot.usageLimits = [StateSnapshot.UsageLimit(provider: "anthropic", resumeAt: now.addingTimeInterval(600), reason: "model_api_unreachable")]
        let overview = Overview(state: OverviewState(snapshot: snapshot, generatedAt: now), now: now, timeZone: utc)
        XCTAssertEqual(overview.problems.first?.sentence, "Claude API unreachable: new runs wait until 13:56.")
    }

    // MARK: - Scope

    func testTheScopeFiltersEveryCountAndRow() throws {
        let overview = try overview("flowing", scope: .repo("web-shop"))

        XCTAssertEqual(overview.stages.map(\.count), [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(overview.context, "5 tickets in progress in web-shop. 1 waits on you, for 40 min.")
        XCTAssertEqual(overview.working.map(\.identifier), ["SHOP-305", "SHOP-298", "SHOP-301"])
        XCTAssertEqual(overview.nextUp.map(\.identifier), ["SHOP-320"])
        XCTAssertEqual(overview.reposLine, "web-shop is healthy.")

        let api = try self.overview("attention", scope: .repo("api"))
        // The hold is on every repo; the stuck ticket is web-shop's. The badge counts both, whatever the scope.
        XCTAssertEqual(api.problems.map(\.kinds), [[.usageLimit]])
        XCTAssertEqual(api.sentence, "1 thing needs attention.")
        XCTAssertEqual(Overview.badgeCount(try state("attention"), now: wallClock), 2)
        XCTAssertEqual(try self.overview("attention", scope: .repo("web-shop")).reposLine, "web-shop needs attention.")
    }

    func testAScopedRepoWithNothingInProgressIsIdle() throws {
        let overview = try overview("flowing", scope: .repo("mobile"))
        XCTAssertEqual(overview.mood, .idle)
        XCTAssertNil(overview.reposLine)
        XCTAssertTrue(overview.stages.allSatisfy(\.isZero))
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

    func testTilesReadAsOneElement() throws {
        let tile = try XCTUnwrap(overview("flowing").stages.first { $0.kind == .waitingOnYou })
        XCTAssertEqual(tile.accessibilityLabel, "Waiting on you, 2, oldest 3 hours 12 minutes")
        let queued = try XCTUnwrap(overview("idle").stages.first)
        XCTAssertEqual(queued.accessibilityLabel, "Queued, 0, Nothing queued")
    }

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
        let meter = Overview(state: OverviewState(snapshot: snapshot), now: wallClock, timeZone: utc).meters.first
        XCTAssertEqual(meter?.value, "1,284 tokens, no daily budget")
        XCTAssertNil(meter?.fraction)
        XCTAssertEqual(meter?.accessibilityLabel, "Tokens today, 1,284 tokens, no daily budget")

        snapshot.budget = StateSnapshot.Budget(dailyLimit: 100, dailyUsed: 120, dailyPaused: true)
        let full = Overview(state: OverviewState(snapshot: snapshot), now: wallClock, timeZone: utc).meters.first
        XCTAssertEqual(full?.fraction, 1)
        XCTAssertEqual(full?.note, "The daily budget holds new runs.")
    }

    func testAPauseWithoutAReasonOrTime() {
        var snapshot = StateSnapshot()
        snapshot.pause = StateSnapshot.Pause()
        snapshot.runs = []
        let overview = Overview(state: OverviewState(snapshot: snapshot, running: [OverviewState.Run(identifier: "A-1")]), now: wallClock, timeZone: utc)
        XCTAssertEqual(overview.sentence, "Dispatch is paused.")
        XCTAssertEqual(overview.context, "1 run is finishing. No new run starts until you resume, forced tickets included.")
        snapshot.pause = StateSnapshot.Pause(reason: "Release.", since: Date(timeIntervalSince1970: 0))
        let other = Overview(state: OverviewState(snapshot: snapshot, generatedAt: Date(timeIntervalSince1970: 90_000)), now: wallClock, timeZone: utc)
        XCTAssertEqual(other.sentence, "Dispatch is paused since Jan 1, 00:00: Release.")
        XCTAssertEqual(other.context, "Nothing is running. No new run starts until you resume, forced tickets included.")
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

    private func overview(_ name: String, scope: OverviewScope = .all) throws -> Overview {
        let data = try Data(contentsOf: fixture(name).appendingPathComponent("repos.json"))
        return Overview(
            state: try state(name),
            scope: scope,
            repos: ReposAPI.poll(data: data, statusCode: 200),
            now: wallClock,
            timeZone: utc
        )
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

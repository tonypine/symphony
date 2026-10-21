import XCTest
@testable import SymphonyBarCore

/// A Symphony that answers the guided setup's requests from a section it keeps, as the service would: a step runs to
/// what the test queued for it (done by default), a test update waits until a read delivers it, leaving a repo on
/// polling forgets its steps.
final class FakeGitHubUpdates {
    typealias Status = GitHubUpdatesSection.Step.Status

    /// What a request for a step answers: the step's new state, or a request Symphony refuses.
    enum Answer {
        case status(Status, detail: String? = nil, fix: String? = nil, action: GitHubUpdatesSection.Step.Action? = nil)
        case refuse(String)
    }

    var section: GitHubUpdatesSection
    /// The answers `run_step` gives each step, in order; the last one stays. Done when none is queued.
    var runs: [String: [Answer]] = [:]
    var turnOn: Answer?
    var test: Answer?
    var leave: Answer?
    /// What each read changes before it answers, in order; the last one stays.
    var reads: [[String: Status]] = []
    /// Every request, as "run_step step=relay", "test repo=docs", "read".
    var calls: [String] = []
    var moves: [WebhookSecret.Move] = [.saved]
    var stored = false
    var terminalProblem: String?
    var terminals: [[String]] = []
    var restarts = 0
    var sleeps: [TimeInterval] = []
    /// While set, a sleep waits for the test to open it.
    var gate: Gate?

    final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var isWaiting: Bool { !waiters.isEmpty }

        func wait() async { await withCheckedContinuation { waiters.append($0) } }

        func open() {
            let waiting = waiters
            waiters = []
            waiting.forEach { $0.resume() }
        }
    }

    init(_ section: GitHubUpdatesSection) {
        self.section = section
    }

    var services: GitHubUpdatesSetupController.Services {
        GitHubUpdatesSetupController.Services(
            send: { await self.send($0, $1) },
            read: { self.read() },
            moveSecret: { self.moves.count > 1 ? self.moves.removeFirst() : self.moves[0] },
            secretStored: { self.stored },
            openTerminal: { self.terminals.append($0); return self.terminalProblem },
            restartSymphony: { self.restarts += 1 },
            sleep: { self.sleeps.append($0); await self.gate?.wait() }
        )
    }

    func send(_ action: GitHubUpdatesAPI.Action, _ params: [String: String]) async -> GitHubUpdatesAPI.Result {
        calls.append(([action.rawValue] + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: " "))
        switch action {
        case .turnOn:
            if case let .refuse(message)? = turnOn { return .failed(message) }
            section.mode = .settingUp
            section.enabled = true
            section.relay.kind = params["relay"] ?? "gh_webhook_forward"
            section.relay.runsInSymphony = section.relay.kind == "gh_webhook_forward"
            section.relay.url = params["url"]
        case .runStep:
            let step = params["step"] ?? ""
            var queue = runs[step] ?? []
            let answer = queue.first ?? .status(.done)
            if queue.count > 1 { queue.removeFirst() }
            runs[step] = queue
            switch answer {
            case let .refuse(message): return .failed(message)
            case let .status(status, detail, fix, action): set(step, status, detail: detail, fix: fix, action: action)
            }
        case .test:
            if case let .refuse(message)? = test { return .failed(message) }
            let keys = params["repo"].map { [$0] } ?? section.repos.filter(\.connected).map(\.key)
            for key in keys {
                if case let .status(status, detail, fix, _)? = test {
                    set("test:\(key)", status, detail: detail, fix: fix)
                } else {
                    set("test:\(key)", .waiting, detail: "Waiting for the test delivery.")
                }
            }
        case .leaveOnPolling:
            if case let .refuse(message)? = leave { return .failed(message) }
            let key = params["repo"] ?? ""
            set("repo:\(key)", .pending)
            set("test:\(key)", .pending)
        case .restartRelay, .recreateSecret, .changeRelay, .turnOff:
            break
        }
        return .updated(section)
    }

    func read() -> GitHubUpdatesAPI.Result {
        calls.append("read")
        let changes = reads.first ?? [:]
        if reads.count > 1 { reads.removeFirst() }
        for (step, status) in changes { set(step, status) }
        return .updated(section)
    }

    /// Sets a step; a repo whose `repo:` step is done connects, and the mode follows the steps as the service's does.
    func set(_ id: String, _ status: Status, detail: String? = nil, fix: String? = nil, action: GitHubUpdatesSection.Step.Action? = nil) {
        guard let index = section.steps.firstIndex(where: { $0.id == id }) else { return }
        section.steps[index].status = status
        section.steps[index].detail = detail ?? (id.hasPrefix("test:") && status == .done ? "received and verified" : nil)
        section.steps[index].fix = fix
        section.steps[index].action = action
        if id.hasPrefix("repo:"), let repo = section.repos.firstIndex(where: { "repo:\($0.key)" == id }) {
            section.repos[repo].connected = status == .done
        }
        if id == "secret" { section.secret.present = status == .done }
        let connected = section.repos.filter(\.connected).map(\.key)
        let needed = section.steps.filter { ["relay", "gh_ready", "secret", "port"].contains($0.kind) || ($0.kind == "test" && connected.contains($0.repo ?? "")) }
        if section.enabled, section.mode != .needsSetup {
            section.mode = !connected.isEmpty && needed.allSatisfy { $0.status == .done } ? .on : .settingUp
        }
    }

    /// The section of a Mac with three repos (acme/web-shop, acme/api, acme/docs), every step to do, Symphony on 4123.
    static func section(mode: GitHubUpdatesSection.Mode = .off, relay: String = "gh_webhook_forward", done: Set<String> = []) -> GitHubUpdatesSection {
        let repos = [("web-shop", "acme/web-shop"), ("api", "acme/api"), ("docs", "acme/docs")]
        let ids = ["relay", "gh_ready", "secret", "port"] + repos.map { "repo:\($0.0)" } + repos.map { "test:\($0.0)" }
        let steps = ids.map { id -> GitHubUpdatesSection.Step in
            let parts = id.split(separator: ":").map(String.init)
            return GitHubUpdatesSection.Step(
                id: id, kind: parts[0], repo: parts.count > 1 ? parts[1] : nil, title: id, status: done.contains(id) ? .done : .pending
            )
        }
        return GitHubUpdatesSection(
            mode: mode,
            relay: GitHubUpdatesSection.Relay(
                kind: relay, label: GitHubUpdatesSheet.relayLabel(relay), runsInSymphony: relay == "gh_webhook_forward",
                localURL: "http://127.0.0.1:4123/api/v1/github/webhook"
            ),
            secret: GitHubUpdatesSection.Secret(present: done.contains("secret"), item: WebhookSecret.item),
            steps: steps,
            repos: repos.map { GitHubUpdatesSection.Repo(key: $0.0, github: $0.1, connected: done.contains("repo:\($0.0)")) }
        )
    }
}

@MainActor
final class GitHubUpdatesSetupTests: XCTestCase {
    private let scope = (
        detail: "The GitHub CLI is signed in, but can't add webhooks to repositories (it lacks the admin:repo_hook scope).",
        fix: "Run gh auth refresh -h github.com -s admin:repo_hook in Terminal, then run this step again."
    )
    private let admin = (
        detail: "You need admin access to acme/docs to add a webhook.",
        fix: "Ask an owner of acme/docs for admin access, or leave docs on polling."
    )

    private func controller(_ fake: FakeGitHubUpdates, purpose: GitHubUpdatesSetup.Purpose = .turnOn) -> GitHubUpdatesSetupController {
        GitHubUpdatesSetupController(purpose: purpose, section: fake.section, services: fake.services)
    }

    private func row(_ setup: GitHubUpdatesSetup, _ id: String) throws -> GitHubUpdatesSetup.Row {
        try XCTUnwrap(setup.rows.first { $0.id == id }, "no row \(id) on \(setup.page)")
    }

    /// A setup that reached `page` with every step before it done, its requests forgotten unless `keepingCalls`.
    private func reach(_ page: GitHubUpdatesSetup.Page, _ fake: FakeGitHubUpdates, keepingCalls: Bool = false) async -> GitHubUpdatesSetupController {
        let controller = controller(fake)
        for _ in GitHubUpdatesSetup.Page.allCases where controller.setup.page < page {
            await controller.goForward()
        }
        XCTAssertEqual(controller.setup.page, page)
        if !keepingCalls { fake.calls = [] }
        return controller
    }

    // MARK: S2: the relay

    func testTurnOnOpensOnStepOneWithGitHubCLIForwardingPickedAndRecommended() throws {
        let setup = controller(FakeGitHubUpdates(FakeGitHubUpdates.section())).setup

        XCTAssertEqual(setup.page, .relay)
        XCTAssertEqual(setup.stepLabel, "Step 1 of 5")
        XCTAssertEqual(setup.page.title, "Choose how GitHub reaches this Mac")
        XCTAssertEqual(setup.relay, "gh_webhook_forward")
        XCTAssertEqual(setup.option?.label, "GitHub CLI forwarding")
        XCTAssertEqual(setup.relayOptions.filter(\.recommended).map(\.id), ["gh_webhook_forward"])
        XCTAssertEqual(setup.relayOptions.map(\.label), ["GitHub CLI forwarding", "smee.io", "Cloudflare Tunnel", "Tailscale Funnel"])
        XCTAssertTrue(setup.explanation.contains("every 30 s"), setup.explanation)
        XCTAssertTrue(setup.rows.isEmpty)
        XCTAssertTrue(setup.canContinue)
        XCTAssertEqual(setup.continueTitle, "Continue")
        XCTAssertFalse(setup.canGoBack)
        XCTAssertEqual(setup.turnOnParams, ["relay": "gh_webhook_forward"])
        XCTAssertEqual(setup.donePages, [])
    }

    func testAURLRelayNeedsItsPublicURLBeforeContinue() {
        let controller = controller(FakeGitHubUpdates(FakeGitHubUpdates.section()))
        controller.pick(relay: "smee")

        XCTAssertTrue(controller.setup.needsURL)
        XCTAssertEqual(controller.setup.continueProblem, "Paste the relay's public URL.")
        controller.setURL("  https://smee.io/abc ")
        XCTAssertTrue(controller.setup.canContinue)
        XCTAssertEqual(controller.setup.turnOnParams, ["relay": "smee", "url": "https://smee.io/abc"])
    }

    func testTurningOnThatFailsStaysOnTheRelayPageWithTheReason() async {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.turnOn = .refuse("Couldn't turn on instant updates: symphony.yml can't be written.")
        let controller = controller(fake)

        await controller.goForward()

        XCTAssertEqual(controller.setup.page, .relay)
        XCTAssertEqual(controller.setup.turnOnError, "Couldn't turn on instant updates: symphony.yml can't be written.")
        XCTAssertTrue(controller.setup.canContinue, "Continue tries again")
        XCTAssertEqual(fake.calls, ["turn_on relay=gh_webhook_forward"])

        // Picking another relay clears the reason.
        controller.pick(relay: "tailscale_funnel")
        XCTAssertNil(controller.setup.turnOnError)
    }

    // MARK: S3: the GitHub CLI

    func testContinueChecksTheGitHubCLIAndOffersGrantPermissionWhenTheScopeIsMissing() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.runs["gh_ready"] = [.status(.failed, detail: scope.detail, fix: scope.fix, action: .grantPermission)]
        let controller = controller(fake)
        var seen: [GitHubUpdatesSetup] = []
        controller.onChange = { seen.append($0) }

        await controller.goForward()

        let setup = controller.setup
        XCTAssertEqual(fake.calls, ["turn_on relay=gh_webhook_forward", "run_step step=relay", "run_step step=gh_ready"])
        XCTAssertEqual(setup.stepLabel, "Step 2 of 5")
        XCTAssertEqual(setup.page.title, "Check the GitHub CLI")
        let relay = try row(setup, "relay")
        XCTAssertEqual(relay.title, "GitHub CLI and its forwarding extension")
        XCTAssertEqual([relay.word, relay.detail], ["Done", "Installed."])
        let permission = try row(setup, "gh_ready")
        XCTAssertEqual(permission.tone, .problem)
        XCTAssertEqual(permission.detail, scope.detail)
        XCTAssertEqual(permission.buttons, [.grantPermission])
        XCTAssertEqual(GitHubUpdatesSetup.Button.grantPermission.title, "Grant Permission…")
        XCTAssertEqual(setup.continueProblem, "Continue is available once every row is done.")
        XCTAssertTrue(setup.canGoBack)
        // Each row worked while its request was out.
        XCTAssertTrue(seen.contains { $0.rows.first { $0.id == "gh_ready" }?.word == "Checking…" })
        XCTAssertTrue(seen.contains { $0.continueProblem == "Symphony is working on this step…" })
    }

    func testGrantPermissionOpensTerminalAndTheRowTurnsDoneByItself() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        let missing = FakeGitHubUpdates.Answer.status(.failed, detail: scope.detail, fix: scope.fix, action: .grantPermission)
        fake.runs["gh_ready"] = [missing, missing, .status(.done)]
        let controller = await reach(.gitHubCLI, fake)
        var fixes: [String?] = []
        controller.onChange = { fixes.append($0.rows.first { $0.id == "gh_ready" }?.fix) }

        await controller.perform(.grantPermission, on: "gh_ready")

        XCTAssertEqual(fake.terminals, [["auth", "refresh", "-h", "github.com", "-s", "admin:repo_hook"]])
        XCTAssertEqual(fake.sleeps, [3, 3])
        XCTAssertEqual(fake.calls, ["run_step step=gh_ready", "run_step step=gh_ready"])
        XCTAssertTrue(fixes.contains("Finish in Terminal. This row checks again every 3 seconds."))
        let permission = try row(controller.setup, "gh_ready")
        XCTAssertEqual([permission.word, permission.detail], ["Done", "The GitHub CLI can add webhooks to your repos."])
        XCTAssertTrue(controller.setup.awaiting.isEmpty)
        XCTAssertTrue(controller.setup.canContinue)
        XCTAssertEqual(controller.setup.donePages, [.relay, .gitHubCLI])
    }

    func testComingBackToTheAppChecksAtOnceAndTheTimerStops() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        let missing = FakeGitHubUpdates.Answer.status(.failed, detail: scope.detail, fix: scope.fix, action: .grantPermission)
        fake.runs["gh_ready"] = [missing, .status(.done)]
        let controller = await reach(.gitHubCLI, fake)
        let gate = FakeGitHubUpdates.Gate()
        fake.gate = gate

        // Before Grant Permission… nothing checks on activation.
        await controller.appActivated()
        XCTAssertEqual(fake.calls, [])

        let grant = Task { await controller.perform(.grantPermission, on: "gh_ready") }
        while !gate.isWaiting { await Task.yield() }
        // A second press opens Terminal again without a second timer.
        await controller.perform(.grantPermission, on: "gh_ready")
        await controller.appActivated()
        gate.open()
        await grant.value

        XCTAssertEqual(fake.terminals.count, 2)
        XCTAssertEqual(fake.calls, ["run_step step=gh_ready"], "the timer stops once activation found it done")
        XCTAssertEqual(try row(controller.setup, "gh_ready").word, "Done")
    }

    func testSignInOpensTerminalOnLoginAndATerminalThatWontOpenFailsTheRow() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.runs["gh_ready"] = [
            .status(.failed, detail: "The GitHub CLI isn't signed in.", fix: "Run gh auth login in Terminal, then run this step again.", action: .signIn),
        ]
        let controller = await reach(.gitHubCLI, fake)
        XCTAssertEqual(try row(controller.setup, "gh_ready").buttons, [.signIn])

        fake.terminalProblem = "Terminal.app was not found."
        await controller.perform(.signIn, on: "gh_ready")

        XCTAssertEqual(fake.terminals, [["auth", "login", "-h", "github.com"]])
        let failed = try row(controller.setup, "gh_ready")
        XCTAssertEqual([failed.word, failed.detail], ["Failed", "Terminal.app was not found."])
        XCTAssertEqual(failed.buttons, [.retry])
        XCTAssertEqual(fake.calls, [])
    }

    func testARequestThatFailsFailsItsRowWithRetry() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.runs["relay"] = [.refuse("Couldn't run the setup step: nothing answered at http://127.0.0.1:4123."), .status(.done)]
        fake.runs["gh_ready"] = [.status(.failed, detail: "The GitHub CLI (gh) isn't installed.", fix: "Install it with brew install gh.")]
        let controller = controller(fake)
        await controller.goForward()

        let relay = try row(controller.setup, "relay")
        XCTAssertEqual([relay.word, relay.detail], ["Failed", "Couldn't run the setup step: nothing answered at http://127.0.0.1:4123."])
        XCTAssertEqual(relay.buttons, [.retry])
        // A failure with no button of its own runs the step again.
        XCTAssertEqual(try row(controller.setup, "gh_ready").buttons, [.retry])

        await controller.perform(.retry, on: "relay")
        XCTAssertEqual(try row(controller.setup, "relay").word, "Done")
    }

    func testAURLRelayShowsItsAddressAndHooksInPlaceOfForwarding() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        let controller = controller(fake)
        controller.pick(relay: "smee")
        controller.setURL("https://smee.io/abc")
        await controller.goForward()

        XCTAssertEqual(fake.calls.first, "turn_on relay=smee url=https://smee.io/abc")
        let relay = try row(controller.setup, "relay")
        XCTAssertEqual([relay.title, relay.detail], ["Relay address", "Updates reach this Mac through https://smee.io/abc."])
        XCTAssertTrue(controller.setup.explanation.contains("pointing at your relay's address"))

        await controller.goForward()
        await controller.goForward()
        XCTAssertEqual(try row(controller.setup, "repo:web-shop").detail, "Webhook added")
        XCTAssertTrue(controller.setup.explanation.contains("adds a webhook to each repo"))
    }

    // MARK: S4: the secret and the port

    func testSecretAndPortTurnDoneWithTheSecretSavedInTheKeychain() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        let controller = await reach(.gitHubCLI, fake)

        await controller.goForward()

        let setup = controller.setup
        XCTAssertEqual(setup.page.title, "Secret and port")
        XCTAssertEqual(fake.calls, ["run_step step=secret", "run_step step=port"])
        XCTAssertEqual(try row(setup, "secret").detail, "Secret created and saved in your Keychain")
        XCTAssertEqual(try row(setup, "port").detail, "Fixing Symphony's port at 4123")
        XCTAssertTrue(setup.rows.allSatisfy(\.isDone))
        XCTAssertTrue(setup.canContinue)
        XCTAssertTrue(setup.explanation.contains("the app keeps it in your Keychain"))
    }

    func testASecretTheKeychainRefusesFailsAndRetrySavesItWithoutANewOne() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.moves = [.failed("Couldn't save the webhook secret in your Keychain: denied."), .saved]
        let controller = await reach(.gitHubCLI, fake)
        await controller.goForward()

        let failed = try row(controller.setup, "secret")
        XCTAssertEqual([failed.word, failed.detail, failed.fix], ["Failed", "Couldn't save the webhook secret in your Keychain: denied.", "Retry to save it again."])
        XCTAssertFalse(controller.setup.canContinue)

        fake.calls = []
        await controller.perform(.retry, on: "secret")
        XCTAssertEqual(fake.calls, [], "the secret Symphony made is kept, not made again")
        XCTAssertEqual(try row(controller.setup, "secret").detail, "Secret created and saved in your Keychain")
    }

    func testASecretAlreadyKeptReadsSavedAndOneSetElsewhereReadsSet() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section(mode: .needsSetup, done: ["secret"]))
        fake.moves = [.nothingHandedOff]
        fake.stored = true
        var controller = await reach(.secretAndPort, fake)
        XCTAssertEqual(try row(controller.setup, "secret").detail, "Secret saved in your Keychain")

        fake.stored = false
        fake.section = FakeGitHubUpdates.section(mode: .needsSetup, done: ["secret"])
        controller = await reach(.secretAndPort, fake, keepingCalls: true)
        XCTAssertEqual(try row(controller.setup, "secret").detail, "Symphony has a webhook secret.")
        XCTAssertFalse(fake.calls.contains("run_step step=secret"))
    }

    func testAPortThatMovedRestartsSymphonyAndChecksAgain() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        let moved = FakeGitHubUpdates.Answer.status(
            .failed, detail: "symphony.yml pins dashboard.port to 4040, but Symphony listens on another port.",
            fix: "Restart Symphony so it listens on 4040.", action: .restartSymphony
        )
        fake.runs["port"] = [moved, moved, .status(.done)]
        let controller = await reach(.gitHubCLI, fake)
        await controller.goForward()
        XCTAssertEqual(try row(controller.setup, "port").buttons, [.restartSymphony])

        var fixes: [String?] = []
        controller.onChange = { fixes.append($0.rows.first { $0.id == "port" }?.fix) }
        await controller.perform(.restartSymphony, on: "port")

        XCTAssertEqual(fake.restarts, 1)
        XCTAssertTrue(fixes.contains("Symphony is restarting. This row checks again every 3 seconds."))
        XCTAssertEqual(try row(controller.setup, "port").word, "Done")
    }

    // MARK: S5: the repos

    func testConnectingTheReposFailsAloneTheOneWithoutAdminAccess() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.runs["repo:docs"] = [.status(.failed, detail: admin.detail, fix: admin.fix)]
        let controller = await reach(.secretAndPort, fake)

        await controller.goForward()

        let setup = controller.setup
        XCTAssertEqual(setup.page.title, "Connect your repos")
        XCTAssertEqual(fake.calls, ["run_step step=repo:web-shop", "run_step step=repo:api", "run_step step=repo:docs"])
        XCTAssertEqual(setup.rows.map(\.title), ["acme/web-shop", "acme/api", "acme/docs"])
        XCTAssertEqual(try row(setup, "repo:web-shop").detail, "Forwarding through the GitHub CLI")
        XCTAssertTrue(try row(setup, "repo:api").isDone)
        let docs = try row(setup, "repo:docs")
        XCTAssertEqual([docs.word, docs.detail, docs.fix], ["Failed", admin.detail, admin.fix])
        XCTAssertEqual(docs.buttons, [.retry, .leaveOnPolling])
        XCTAssertEqual(docs.accessibilityLabel, "acme/docs, Failed, \(admin.detail), \(admin.fix)")
        XCTAssertEqual(setup.continueProblem, "Retry each failed repo, or leave it on polling.")
    }

    func testLeaveOnPollingLetsContinueAndRetryConnectsItAgain() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.runs["repo:docs"] = [.status(.failed, detail: admin.detail, fix: admin.fix), .status(.done)]
        let controller = await reach(.repos, fake)

        await controller.perform(.leaveOnPolling, on: "repo:docs")

        XCTAssertEqual(fake.calls, ["leave_on_polling repo=docs"])
        let docs = try row(controller.setup, "repo:docs")
        XCTAssertEqual([docs.word, docs.detail], ["Polling", "Left on polling: Symphony checks it every 30 s."])
        XCTAssertEqual(docs.buttons, [.retry])
        XCTAssertTrue(controller.setup.canContinue)

        await controller.perform(.retry, on: "repo:docs")
        XCTAssertTrue(try row(controller.setup, "repo:docs").isDone)
        XCTAssertFalse(controller.setup.leftOnPolling.contains("docs"))
    }

    func testLeaveOnPollingThatSymphonyRefusesKeepsTheRowFailed() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.runs["repo:docs"] = [.status(.failed, detail: admin.detail, fix: admin.fix)]
        fake.leave = .refuse("Couldn't leave the repo on polling: Instant GitHub updates are off.")
        let controller = await reach(.repos, fake)

        await controller.perform(.leaveOnPolling, on: "repo:docs")

        XCTAssertEqual(try row(controller.setup, "repo:docs").detail, "Couldn't leave the repo on polling: Instant GitHub updates are off.")
        XCTAssertFalse(controller.setup.canContinue)
    }

    func testEveryRepoLeftOnPollingKeepsContinueOff() async {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        for key in ["web-shop", "api", "docs"] { fake.runs["repo:\(key)"] = [.status(.failed, detail: "x")] }
        let controller = await reach(.repos, fake)
        for key in ["web-shop", "api", "docs"] { await controller.perform(.leaveOnPolling, on: "repo:\(key)") }

        XCTAssertEqual(controller.setup.continueProblem, "Connect at least one repo, or close and stay on polling.")
    }

    // MARK: S6: the test

    func testTheTestWaitsForEachUpdateThenDoneClosesOnInstant() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.runs["repo:docs"] = [.status(.failed, detail: admin.detail, fix: admin.fix)]
        let controller = await reach(.repos, fake)
        await controller.perform(.leaveOnPolling, on: "repo:docs")
        fake.calls = []
        fake.reads = [["test:web-shop": .done], ["test:api": .done]]
        var waiting: [String] = []
        controller.onChange = { waiting.append(contentsOf: $0.rows.filter { $0.word == "Waiting" }.map(\.id)) }

        await controller.goForward()

        let setup = controller.setup
        XCTAssertEqual(setup.page.title, "Send a test update")
        XCTAssertEqual(fake.calls, ["test", "read", "read"])
        XCTAssertEqual(fake.sleeps, [2, 2])
        XCTAssertTrue(waiting.contains("test:api"))
        XCTAssertEqual(setup.rows.map(\.id), ["test:web-shop", "test:api", "test:docs"])
        XCTAssertEqual(try row(setup, "test:web-shop").detail, "Received and verified")
        XCTAssertEqual(try row(setup, "test:api").detail, "Received and verified")
        XCTAssertEqual(try row(setup, "test:docs").word, "Polling")
        XCTAssertEqual(setup.continueTitle, "Done")
        XCTAssertTrue(setup.canContinue)
        XCTAssertEqual(setup.donePages, Set(GitHubUpdatesSetup.Page.allCases))

        var finished: GitHubUpdatesSection?
        controller.onFinish = { finished = $0 }
        await controller.goForward()
        XCTAssertEqual(finished?.mode, .on)
        XCTAssertEqual(finished.map { GitHubUpdatesCard(section: $0, now: Date()).word }, "Instant")
    }

    func testATestUpdateThatNeverArrivesOffersRetryAndLeaveOnPolling() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        let controller = await reach(.repos, fake)
        fake.reads = [["test:web-shop": .done, "test:api": .done, "test:docs": .failed]]

        await controller.goForward()

        let docs = try row(controller.setup, "test:docs")
        XCTAssertEqual(docs.word, "Failed")
        XCTAssertEqual(docs.buttons, [.retry, .leaveOnPolling])
        XCTAssertFalse(controller.setup.canContinue)

        fake.calls = []
        fake.reads = [["test:docs": .done]]
        await controller.perform(.retry, on: "test:docs")
        XCTAssertEqual(fake.calls, ["test repo=docs", "read"])
        XCTAssertTrue(try row(controller.setup, "test:docs").isDone)

        // Leaving a connected repo on polling takes it back, so Done works without it.
        fake.reads = [["test:docs": .failed]]
        await controller.perform(.retry, on: "test:docs")
        await controller.perform(.leaveOnPolling, on: "test:docs")
        XCTAssertEqual(fake.calls.last, "leave_on_polling repo=docs")
        XCTAssertEqual(try row(controller.setup, "test:docs").word, "Polling")
        XCTAssertTrue(controller.setup.canContinue)
        XCTAssertEqual(fake.section.mode, .on)
    }

    func testATestSymphonyNeverSettlesOrRefusesFailsWithWhy() async throws {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        let controller = await reach(.repos, fake)
        await controller.goForward()

        XCTAssertEqual(fake.sleeps.count, GitHubUpdatesSetupController.testPollLimit)
        XCTAssertEqual(try row(controller.setup, "test:api").detail, "Symphony didn't say whether the test update arrived.")

        fake.test = .refuse("Couldn't send a test update: No repository is connected yet.")
        await controller.perform(.retry, on: "test:api")
        XCTAssertEqual(try row(controller.setup, "test:api").detail, "Couldn't send a test update: No repository is connected yet.")
    }

    // MARK: Finish Setup, Back and Cancel

    func testFinishSetupKeepsTheRelayAndTicksAndSkipsWhatIsDone() async throws {
        var section = FakeGitHubUpdates.section(mode: .needsSetup, relay: "smee", done: ["relay", "gh_ready", "port"])
        section.relay.url = "https://smee.io/abc"
        let fake = FakeGitHubUpdates(section)
        let controller = controller(fake, purpose: .finishSetup)

        XCTAssertEqual(controller.setup.relay, "smee")
        XCTAssertEqual(controller.setup.url, "https://smee.io/abc")
        XCTAssertEqual(controller.setup.donePages, [.gitHubCLI], "turning on is what is left of the relay on a new Mac")

        await controller.goForward()
        XCTAssertEqual(fake.calls, ["turn_on relay=smee url=https://smee.io/abc"], "done steps don't run again")
        XCTAssertTrue(controller.setup.rows.allSatisfy(\.isDone))

        await controller.goForward()
        XCTAssertEqual(fake.calls.last, "run_step step=secret", "the port stays as it is")
    }

    func testBackShowsThePreviousPageWithoutRunningIt() async {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        let controller = await reach(.secretAndPort, fake)

        controller.goBack()
        XCTAssertEqual(controller.setup.page, .gitHubCLI)
        controller.goBack()
        XCTAssertEqual(controller.setup.page, .relay)
        XCTAssertFalse(controller.setup.canGoBack)
        controller.goBack()
        XCTAssertEqual(controller.setup.page, .relay)
        XCTAssertEqual(fake.calls, [])
    }

    func testCancelStopsTheChecksWaitingOnTerminal() async {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.runs["gh_ready"] = [.status(.failed, detail: scope.detail, action: .grantPermission)]
        let controller = await reach(.gitHubCLI, fake)
        let gate = FakeGitHubUpdates.Gate()
        fake.gate = gate

        let grant = Task { await controller.perform(.grantPermission, on: "gh_ready") }
        while !gate.isWaiting { await Task.yield() }
        controller.close()
        gate.open()
        await grant.value

        XCTAssertEqual(fake.calls, [])
        XCTAssertTrue(controller.setup.awaiting.isEmpty)
        await controller.goForward()
        await controller.perform(.retry, on: "gh_ready")
        XCTAssertEqual(fake.calls, [], "a closed setup sends nothing")
    }

    func testARowWaitingOnTerminalStopsCheckingAfterTenMinutes() async {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section())
        fake.runs["gh_ready"] = [.status(.failed, detail: scope.detail, action: .grantPermission)]
        let controller = await reach(.gitHubCLI, fake)

        await controller.perform(.grantPermission, on: "gh_ready")

        XCTAssertEqual(fake.calls.count, GitHubUpdatesSetupController.recheckLimit)
        XCTAssertEqual(Double(GitHubUpdatesSetupController.recheckLimit) * GitHubUpdatesSetup.recheckInterval, 600)
        XCTAssertTrue(controller.setup.awaiting.isEmpty)
    }

    // MARK: Terminal

    func testTheTerminalScriptRunsTheAppsGhAndPassesQAsStandIn() {
        let script = GitHubUpdatesSetup.terminalScript(
            gh: "/opt/homebrew/bin/gh", arguments: GitHubUpdatesSetupController.grantArguments, environment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(script, """
        #!/bin/zsh -l
        /opt/homebrew/bin/gh auth refresh -h github.com -s admin:repo_hook
        echo
        echo 'You can close this window: Symphony checks again by itself.'

        """)

        let qa = GitHubUpdatesSetup.terminalScript(
            gh: "/tmp/qa gh/gh", arguments: ["auth", "login"], environment: ["SYMPHONY_QA_GH_URL": "http://localhost:9101"]
        )
        XCTAssertTrue(qa.contains("export SYMPHONY_QA_GH_URL=http://localhost:9101\n"), qa)
        XCTAssertTrue(qa.contains("'/tmp/qa gh/gh' auth login\n"), qa)
    }
}

import XCTest
@testable import SymphonyBarCore

final class GitHubUpdatesCardTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// The QA fixtures' `generated_at`.
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!

    /// The shipped fixtures QA points `SYMPHONY_BAR_QA_API_FIXTURES` at.
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)", isDirectory: true)
    }

    /// The service's contract fixture, which its tests check the section against.
    static let contract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../test/fixtures/api/github_updates.json")
        .standardizedFileURL

    private func section(_ name: String) throws -> GitHubUpdatesSection {
        let data = try Data(contentsOf: Self.fixture(name).appendingPathComponent("api/v1/state.json"))
        return try XCTUnwrap(GitHubUpdatesSection.decode(state: data))
    }

    private func card(_ section: GitHubUpdatesSection) -> GitHubUpdatesCard {
        GitHubUpdatesCard(section: section, now: now, timeZone: utc)
    }

    // MARK: Decoding

    func testDecodesTheServicesContract() throws {
        let section = try XCTUnwrap(GitHubUpdatesSection.decode(try Data(contentsOf: Self.contract)))

        XCTAssertEqual(section.mode, .on)
        XCTAssertTrue(section.enabled)
        XCTAssertEqual(section.relay, GitHubUpdatesSection.Relay(
            kind: "gh_webhook_forward", label: "GitHub CLI forwarding", runsInSymphony: true,
            localURL: "http://127.0.0.1:4040/api/v1/github/webhook"
        ))
        XCTAssertEqual(section.secret, GitHubUpdatesSection.Secret(present: true, item: "symphony-github-webhook"))
        XCTAssertEqual(section.events, ["check_suite", "check_run", "workflow_run", "pull_request", "push", "release"])
        XCTAssertEqual(section.steps.map(\.id), ["relay", "gh_ready", "secret", "port", "repo:app", "repo:lib", "test:app", "test:lib"])
        XCTAssertEqual(section.step("repo:lib")?.status, .failed)
        XCTAssertEqual(section.step("repo:lib")?.fix, "Ask an owner of acme/lib for admin access, or leave lib on polling.")
        XCTAssertEqual(section.step("test:lib")?.status, .pending)
        XCTAssertEqual(section.repos.map(\.key), ["app", "lib"])
        let app = try XCTUnwrap(section.repos.first)
        XCTAssertTrue(app.connected)
        XCTAssertEqual(app.name, "acme/app")
        XCTAssertEqual(app.signatureFailures24h, 1)
        XCTAssertEqual(app.relayState, "running")
        XCTAssertEqual(app.pollIntervalMs, 300_000)
        XCTAssertEqual(app.lastDeliveryAt, ISO8601DateFormatter().date(from: "2026-10-17T09:00:05Z"))
        XCTAssertFalse(section.repos[1].connected)
        XCTAssertEqual(section.connected.map(\.key), ["app"])
        XCTAssertEqual(section.poll, GitHubUpdatesSection.Poll(intervalMs: 30_000, fallbackIntervalMs: 300_000, silenceAlertMinutes: 10))
        XCTAssertEqual(section.rateLimit, GitHubUpdatesSection.RateLimit(limit: 5000, remaining: 4321, resetAt: ISO8601DateFormatter().date(from: "2026-10-17T10:00:00Z")))
        XCTAssertEqual(card(section).state, .on)
    }

    func testTheSetupPayloadCarriesTheSectionFromTheStateAndTheSetupEndpoint() throws {
        let state = try Data(contentsOf: Self.fixture("github-updates").appendingPathComponent("api/v1/state.json"))
        XCTAssertEqual(SetupPayload.decode(state: state)?.githubUpdates?.mode, .on)
        XCTAssertEqual(SetupPayload.decode(try Data(contentsOf: Self.contract))?.githubUpdates?.mode, .on)
        XCTAssertEqual(OverviewState.decode(state)?.snapshot.setup?.githubUpdates?.mode, .on)

        // A Symphony that predates the section, or couldn't read it, reports none.
        let older = try Data(contentsOf: Self.fixture("add-repo-setup").appendingPathComponent("api/v1/state.json"))
        XCTAssertNotNil(SetupPayload.decode(state: older))
        XCTAssertNil(SetupPayload.decode(state: older)?.githubUpdates)
        XCTAssertNil(GitHubUpdatesSection.decode(state: Data(#"{"setup": {"problems": [], "github_updates": null}}"#.utf8)))
        XCTAssertNil(GitHubUpdatesSection.decode(Data(#"{"github_updates": {"mode": "sideways"}}"#.utf8)))
        XCTAssertNil(GitHubUpdatesSection.decode(Data("not json".utf8)))
    }

    func testMissingFieldsReadAsDefaults() throws {
        let data = Data(#"{"github_updates": {"mode": "off", "relay": {"kind": "smee"}, "steps": [{"id": "relay"}, {}], "repos": [{"key": "app"}, {}], "rate_limit": {"limit": 5000}}}"#.utf8)
        let section = try XCTUnwrap(GitHubUpdatesSection.decode(data))
        XCTAssertFalse(section.enabled)
        XCTAssertEqual(section.relay, GitHubUpdatesSection.Relay(kind: "smee", label: "smee.io", runsInSymphony: false))
        XCTAssertEqual(section.secret, GitHubUpdatesSection.Secret(present: false))
        XCTAssertEqual(section.steps, [GitHubUpdatesSection.Step(id: "relay", kind: "relay", title: "relay", status: .pending)])
        XCTAssertEqual(section.repos, [GitHubUpdatesSection.Repo(key: "app", connected: false)])
        XCTAssertEqual(section.poll, GitHubUpdatesSection.Poll())
        XCTAssertNil(section.rateLimit, "a limit without what remains says nothing")
    }

    // MARK: Card states

    /// S1.
    func testOffReadsPollingOnlyWithTurnOn() throws {
        let card = card(try section("github-updates-off"))
        XCTAssertEqual(card.state, .off)
        XCTAssertEqual(card.word, "Polling only")
        XCTAssertEqual(card.tone, .idle)
        XCTAssertEqual(card.primary, .turnOn)
        XCTAssertEqual(card.primary?.title, "Turn On Instant Updates…")
        XCTAssertEqual(card.secondary, [])
        XCTAssertTrue(card.sentence.hasPrefix("Symphony checks GitHub every 30 s"))
        XCTAssertEqual(card.repos, [])
        XCTAssertEqual(card.steps, [])
        XCTAssertFalse(card.showsDetails)
        XCTAssertEqual(card.accessibilityLabel, "GitHub updates, Polling only")
    }

    /// S7.
    func testOnReadsInstantWithEachRepoAndDetails() throws {
        let card = card(try section("github-updates"))
        XCTAssertEqual(card.state, .on)
        XCTAssertEqual(card.word, "Instant")
        XCTAssertEqual(card.tone, .done)
        XCTAssertNil(card.primary)
        XCTAssertEqual(card.secondary, [.turnOff])
        XCTAssertEqual(card.sentence, "GitHub tells Symphony about CI and pull requests in 2 repos at once, through GitHub CLI forwarding. "
            + "Symphony still checks every 5 min as a safety net.")
        XCTAssertEqual(card.repos.map(\.accessibilityLabel), [
            "acme/web-shop, Instant, Last update 2 min ago",
            "acme/api, Instant, Last update 19 min ago",
            "acme/docs, Polling only, You need admin access to acme/docs to add a webhook.",
        ])
        XCTAssertTrue(card.showsDetails)
        XCTAssertEqual(card.details.map(\.label), ["Relay", "Secret", "Events", "Address"])
        XCTAssertEqual(card.details[0].value, "GitHub CLI forwarding")
        XCTAssertEqual(card.details[0].action, .changeRelay)
        XCTAssertEqual(card.details[1].value, "Saved in your Keychain as symphony-github-webhook")
        XCTAssertEqual(card.details[1].action, .recreateSecret)
        XCTAssertEqual(card.details[2].value, "check_suite, check_run, workflow_run, pull_request, push, release")
        XCTAssertNil(card.details[2].action, "events are read-only")
        XCTAssertEqual(card.details[3].value, "http://127.0.0.1:4040/api/v1/github/webhook")
        XCTAssertEqual(card.safetyNetMinutes, 5)
        XCTAssertEqual(card.silenceAlertMinutes, 10)
        XCTAssertNil(card.requests)
    }

    func testAURLRelayShowsItsURLAndPublicAddress() throws {
        var section = try section("github-updates")
        section.relay = .init(kind: "smee", label: "smee.io", runsInSymphony: false, url: "https://smee.io/abc", payloadURL: "https://smee.io/abc",
                              localURL: "http://127.0.0.1:4040/api/v1/github/webhook")
        section.events = []
        section.repos[0].lastDeliveryAt = now.addingTimeInterval(-20)
        let card = card(section)
        XCTAssertEqual(card.details[0].value, "smee.io, https://smee.io/abc")
        XCTAssertEqual(card.details[2].value, "None")
        XCTAssertEqual(card.details[3].value, "https://smee.io/abc")
        XCTAssertEqual(card.repos[0].detail, "Last update just now")

        section.relay.payloadURL = nil
        section.relay.localURL = nil
        section.secret = .init(present: true)
        section.repos = [section.repos[0], .init(key: "new", connected: true)]
        let bare = self.card(section)
        XCTAssertEqual(bare.details.map(\.label), ["Relay", "Secret", "Events"])
        XCTAssertEqual(bare.details[1].value, "Saved in your Keychain")
        XCTAssertEqual(bare.repos[1].detail, "No update yet")
        XCTAssertTrue(bare.sentence.contains("in 2 repos"))

        section.repos = [section.repos[0], .init(key: "off", connected: false)]
        XCTAssertTrue(self.card(section).sentence.contains("in 1 repo at once"))
        XCTAssertEqual(self.card(section).repos[1].detail, "Not connected to instant updates.")
    }

    /// S8.
    func testDegradedReadsPollingWhileTheRelayIsDownWithRestartRelay() throws {
        let section = try section("github-updates-degraded")
        let card = card(section)
        XCTAssertEqual(card.state, .degraded)
        XCTAssertEqual(card.word, "Polling while the relay is down")
        XCTAssertEqual(card.tone, .warning)
        XCTAssertEqual(card.primary, .restartRelay)
        XCTAssertEqual(card.primary?.title, "Restart Relay")
        XCTAssertEqual(card.secondary, [.turnOff])
        XCTAssertEqual(card.sentence, "Symphony checks GitHub every 30 s until instant updates arrive again. "
            + "The relay can't start again: unable to connect to webhooks server, forwarding stopped.")
        XCTAssertEqual(card.repos[0].word, "Polling")
        XCTAssertEqual(card.repos[0].detail, "Checked every 30 s. The relay can't start again: unable to connect to webhooks server, forwarding stopped.")

        // A relay this Mac doesn't run can't be restarted from here; a quiet GitHub isn't a relay that is down.
        var url = section
        url.relay = .init(kind: "smee", label: "smee.io", runsInSymphony: false)
        url.repos = url.repos.map { repo in
            var repo = repo
            repo.relayState = nil
            repo.degradedReason = repo.degraded ? "No delivery for 10 minutes after a read found a change none reported" : nil
            repo.pollIntervalMs = nil
            return repo
        }
        let quiet = self.card(url)
        XCTAssertNil(quiet.primary)
        XCTAssertEqual(quiet.word, "Polling while GitHub is quiet")
        XCTAssertEqual(quiet.repos[0].detail, "Checked by polling. No delivery for 10 minutes after a read found a change none reported.")

        // A relay that keeps stopping is down too, and a degraded repo without a reason says how it is checked.
        var unstable = section
        unstable.repos[0].relayState = "running"
        unstable.repos[0].relayStable = false
        unstable.repos[0].degradedReason = nil
        unstable.repos[1].degraded = false
        XCTAssertEqual(self.card(unstable).word, "Polling while the relay is down")
        XCTAssertEqual(self.card(unstable).sentence, "Symphony checks GitHub every 30 s until instant updates arrive again.")
        XCTAssertEqual(self.card(unstable).repos[0].detail, "Checked every 30 s.")
    }

    /// S10.
    func testASecretThatFailsTheCheckOffersReCreateSecret() throws {
        var missing = try section("github-updates")
        missing.secret.present = false
        let card = card(missing)
        XCTAssertEqual(card.state, .secretFailing)
        XCTAssertEqual(card.word, "Secret check failing")
        XCTAssertEqual(card.tone, .problem)
        XCTAssertEqual(card.primary, .recreateSecret)
        XCTAssertEqual(card.primary?.title, "Re-create Secret…")
        XCTAssertEqual(card.secondary, [.turnOff])
        XCTAssertEqual(card.sentence, "Symphony has no webhook secret on this Mac, so it refuses GitHub's updates and checks every 30 s instead.")
        XCTAssertEqual(card.details[1].value, "Not created on this Mac")
        XCTAssertEqual(card.repos.count, 3)

        var refused = try section("github-updates-degraded")
        refused.repos[1].signatureFailures24h = 4
        refused.repos[1].lastDeliveryAt = nil
        XCTAssertEqual(self.card(refused).state, .secretFailing)
        XCTAssertEqual(self.card(refused).sentence, "Updates from acme/api failed the secret check, so Symphony refuses them and checks GitHub every 30 s "
            + "instead. Re-create the secret to connect them again.")

        // A failure next to deliveries that verify is noise, not a secret that is wrong.
        var noise = try section("github-updates")
        noise.repos[0].signatureFailures24h = 1
        XCTAssertEqual(self.card(noise).state, .on)
    }

    /// S14, and a setup still under way.
    func testNeedsSetupOnThisMacListsTheStepsWithFinishSetup() throws {
        var section = try section("github-updates")
        section.mode = .needsSetup
        section.steps[0].status = .pending
        section.steps[0].detail = nil
        section.steps[1].status = .waiting
        section.steps[1].detail = "Waiting for GitHub"
        let card = card(section)
        XCTAssertEqual(card.state, .needsSetup)
        XCTAssertEqual(card.word, "Needs setup on this Mac")
        XCTAssertEqual(card.tone, .warning)
        XCTAssertEqual(card.primary, .finishSetup)
        XCTAssertEqual(card.primary?.title, "Finish Setup…")
        XCTAssertEqual(card.secondary, [.turnOff])
        XCTAssertTrue(card.sentence.hasPrefix("symphony.yml turns instant updates on, but they were never set up on this Mac."))
        XCTAssertEqual(card.repos, [])
        XCTAssertFalse(card.showsDetails)
        XCTAssertEqual(card.steps.map(\.word), ["To do", "Waiting", "Done", "Done", "Done", "Done", "Failed", "Done", "Done", "To do"])
        XCTAssertEqual(card.steps[0].detail, nil)
        XCTAssertEqual(card.steps[1].detail, "Waiting for GitHub")
        XCTAssertEqual(card.steps[6].detail, "You need admin access to acme/docs to add a webhook. Ask an owner of acme/docs for admin access, or leave docs on polling.")
        XCTAssertEqual(card.steps[6].tone, .problem)

        section.mode = .settingUp
        let settingUp = self.card(section)
        XCTAssertEqual(settingUp.word, "Setting up")
        XCTAssertEqual(settingUp.tone, .working)
        XCTAssertEqual(settingUp.sentence, "6 of 10 setup steps done. Symphony checks GitHub every 30 s until they all are.")
    }

    /// S18.
    func testTheRequestsRowShowsWhileGitHubRequestsAreLowOrSpent() throws {
        var section = try section("github-updates")
        section.rateLimit = .init(limit: 5000, remaining: 412, resetAt: ISO8601DateFormatter().date(from: "2026-10-19T12:40:00Z"))
        XCTAssertEqual(card(section).requests, .init(tone: .warning, sentence: "GitHub requests are low: 412 of 5,000 left until 12:40."))

        section.rateLimit = .init(limit: 5000, remaining: 0, resetAt: ISO8601DateFormatter().date(from: "2026-10-20T08:00:00Z"))
        XCTAssertEqual(card(section).requests, .init(tone: .problem, sentence:
            "GitHub requests are used up until Oct 20, 08:00. Symphony can't read CI or pull requests until then. Instant updates still arrive."))

        var off = try self.section("github-updates-off")
        off.rateLimit = .init(remaining: 0)
        XCTAssertEqual(card(off).requests?.sentence, "GitHub requests are used up. Symphony can't read CI or pull requests until then.")
        off.rateLimit = .init(remaining: 12)
        XCTAssertNil(card(off).requests, "a limit Symphony doesn't know can't be low")
        off.rateLimit = .init(limit: 5000, remaining: 4321)
        XCTAssertNil(card(off).requests)
        off.rateLimit = nil
        XCTAssertNil(card(off).requests)
    }

    // MARK: The Overview's row (S9)

    func testTheOverviewShowsARowWhileInstantUpdatesStopped() throws {
        let data = try Data(contentsOf: Self.fixture("github-updates-degraded").appendingPathComponent("api/v1/state.json"))
        var state = try XCTUnwrap(OverviewState.decode(data))
        let row = try XCTUnwrap(Overview(state: state, now: now).problems.first { $0.id == "github-updates" })
        XCTAssertEqual(row.kinds, [.githubUpdates])
        XCTAssertEqual(row.severity, .warning)
        XCTAssertEqual(row.sentence, "Instant GitHub updates stopped: the relay is down.")
        XCTAssertEqual(row.note, "Symphony checks GitHub every 30 s meanwhile.")
        XCTAssertEqual(row.fixes, [.restartRelay, .openSetup])
        XCTAssertEqual(row.fixes.map(\.title), ["Restart Relay", "Open Setup"])
        XCTAssertNil(row.ticketIdentifier)

        state.snapshot.setup?.githubUpdates?.relay = .init(kind: "smee", label: "smee.io", runsInSymphony: false)
        state.snapshot.setup?.githubUpdates?.repos[0].relayState = nil
        state.snapshot.setup?.githubUpdates?.repos[1].relayState = nil
        let quiet = try XCTUnwrap(Overview(state: state, now: now).problems.first { $0.id == "github-updates" })
        XCTAssertEqual(quiet.sentence, "Instant GitHub updates stopped: GitHub went quiet.")
        XCTAssertEqual(quiet.fixes, [.openSetup])

        state.snapshot.setup?.githubUpdates?.secret.present = false
        let secret = try XCTUnwrap(Overview(state: state, now: now).problems.first { $0.id == "github-updates" })
        XCTAssertEqual(secret.sentence, "Instant GitHub updates fail the secret check.")
        XCTAssertEqual(secret.fixes, [.openSetup])

        // Instant, off, or a setup under way: no row.
        for name in ["github-updates", "github-updates-off"] {
            let healthy = try XCTUnwrap(OverviewState.decode(try Data(contentsOf: Self.fixture(name).appendingPathComponent("api/v1/state.json"))))
            XCTAssertFalse(Overview(state: healthy, now: now).problems.contains { $0.id == "github-updates" }, name)
        }
        state.snapshot.setup?.githubUpdates?.mode = .needsSetup
        XCTAssertFalse(Overview(state: state, now: now).problems.contains { $0.id == "github-updates" })
        XCTAssertNil(GitHubUpdatesCard.attention(nil))
    }

    // MARK: Sheets

    /// S12: Turn Off asks first, and says polling goes on.
    func testTurnOffAsksFirstAndSaysPollingGoesOn() throws {
        let sheet = try XCTUnwrap(GitHubUpdatesSheet(.turnOff, section: try section("github-updates")))
        XCTAssertEqual(sheet.kind, .turnOff)
        XCTAssertEqual(sheet.title, "Turn off instant GitHub updates?")
        XCTAssertEqual(sheet.happens, "Symphony stops forwarding GitHub's updates for 2 repos. It goes on checking GitHub every 30 s, "
            + "so tickets react within a minute instead of seconds.")
        XCTAssertTrue(sheet.stays.hasPrefix("The webhook secret stays in your Keychain"))
        XCTAssertEqual(sheet.verb, "Turn Off")
        XCTAssertTrue(sheet.isDestructive)
        XCTAssertFalse(sheet.picksRelay)
        XCTAssertEqual(sheet.request.action, .turnOff)
        XCTAssertEqual(sheet.request.params, [:])
        XCTAssertEqual(sheet.id, "turn_off")

        var url = try section("github-updates")
        url.relay = .init(kind: "smee", label: "smee.io", runsInSymphony: false, url: "https://smee.io/abc")
        url.repos = [url.repos[0]]
        XCTAssertEqual(GitHubUpdatesSheet(.turnOff, section: url)?.happens,
                       "Symphony stops listening through smee.io and removes the webhooks it added to 1 repo. It goes on checking GitHub every 30 s, "
                           + "so tickets react within a minute instead of seconds.")
    }

    /// S11.
    func testReCreateSecretSaysWhatHappensToTheOldOne() throws {
        let sheet = try XCTUnwrap(GitHubUpdatesSheet(.recreateSecret, section: try section("github-updates")))
        XCTAssertEqual(sheet.title, "Re-create the webhook secret?")
        XCTAssertTrue(sheet.happens.contains("connects 2 repos again"))
        XCTAssertTrue(sheet.happens.contains("Updates signed with the old secret are refused"))
        XCTAssertEqual(sheet.verb, "Re-create Secret")
        XCTAssertFalse(sheet.isDestructive)
        XCTAssertEqual(sheet.request.action, .recreateSecret)
        XCTAssertEqual(sheet.id, "recreate_secret")
        XCTAssertNil(GitHubUpdatesSheet(.restartRelay, section: try section("github-updates")), "Restart Relay needs no sheet")
    }

    func testTheRelaySheetChangesTheRelayPickedAndTurningOnOpensTheGuidedSetup() throws {
        // Turn On Instant Updates… and Finish Setup… open the guided setup (GitHubUpdatesSetup), not a sheet of their own.
        XCTAssertNil(GitHubUpdatesSheet(.turnOn, section: try section("github-updates-off")))
        XCTAssertNil(GitHubUpdatesSheet(.finishSetup, section: try section("github-updates")))

        var change = try XCTUnwrap(GitHubUpdatesSheet(.changeRelay, section: try section("github-updates")))
        XCTAssertEqual(change.title, "Change how GitHub reaches this Mac?")
        XCTAssertEqual(change.verb, "Change Relay")
        XCTAssertTrue(change.picksRelay)
        XCTAssertEqual(change.relay, "gh_webhook_forward")
        XCTAssertEqual(change.option?.label, "GitHub CLI forwarding")
        XCTAssertTrue(change.option?.note.hasPrefix("Recommended.") == true)
        XCTAssertTrue(change.option?.recommended == true)
        XCTAssertFalse(change.needsURL)
        XCTAssertTrue(change.canConfirm)
        XCTAssertEqual(change.request.params, ["relay": "gh_webhook_forward"])

        // A URL relay needs its public URL before it can change.
        change.relay = "smee"
        XCTAssertTrue(change.needsURL)
        XCTAssertFalse(change.canConfirm)
        XCTAssertEqual(change.option?.note, "Free, no account. Anyone with the channel URL can read the updates.")
        change.relay = "cloudflare_tunnel"
        change.url = "  https://hooks.example.com "
        XCTAssertTrue(change.canConfirm)
        XCTAssertEqual(change.request.action, .changeRelay)
        XCTAssertEqual(change.request.params, ["relay": "cloudflare_tunnel", "url": "https://hooks.example.com"])
        XCTAssertEqual(change.id, "change_relay")

        XCTAssertEqual(GitHubUpdatesSheet.relays.map(\.id), ["gh_webhook_forward", "smee", "cloudflare_tunnel", "tailscale_funnel"])
        XCTAssertEqual(GitHubUpdatesSheet.relayLabel("tailscale_funnel"), "Tailscale Funnel")
        XCTAssertEqual(GitHubUpdatesSheet.relayLabel("carrier_pigeon"), "carrier_pigeon")
    }

    func testASheetWorksThenShowsWhyItFailed() throws {
        var sheet = try XCTUnwrap(GitHubUpdatesSheet(.turnOff, section: try section("github-updates")))
        XCTAssertEqual(sheet.cancelTitle, "Cancel")
        XCTAssertEqual(sheet.confirmTitle, "Turn Off")
        XCTAssertNil(sheet.error)
        sheet.start()
        XCTAssertTrue(sheet.isWorking)
        XCTAssertFalse(sheet.canConfirm)
        sheet.fail("Couldn't turn off instant updates: gh isn't signed in.")
        XCTAssertFalse(sheet.isWorking)
        XCTAssertTrue(sheet.canConfirm)
        XCTAssertEqual(sheet.error, "Couldn't turn off instant updates: gh isn't signed in.")
        XCTAssertEqual(sheet.cancelTitle, "Close")
        XCTAssertEqual(sheet.confirmTitle, "Try Again")
    }

    // MARK: The API

    func testRequestsPostTheActionWithItsParams() throws {
        let base = URL(string: "http://127.0.0.1:4040")!
        let request = GitHubUpdatesAPI.request(.turnOn, params: ["relay": "smee", "url": "https://smee.io/abc"], base: base)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4040/api/v1/setup/github_updates/turn_on")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(request.timeoutInterval, GitHubUpdatesAPI.timeout)
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self), #"{"relay":"smee","url":"https:\/\/smee.io\/abc"}"#)
        XCTAssertEqual(GitHubUpdatesAPI.path(.restartRelay), "api/v1/setup/github_updates/restart_relay")
        XCTAssertEqual(GitHubUpdatesAPI.path(.recreateSecret), "api/v1/setup/github_updates/recreate_secret")
        XCTAssertEqual(GitHubUpdatesAPI.path(.changeRelay), "api/v1/setup/github_updates/change_relay")
    }

    func testAnswersReadAsTheSectionOrTheReason() throws {
        let answer = try Data(contentsOf: Self.fixture("github-updates").appendingPathComponent("api/v1/setup/github_updates/turn_off.json"))
        XCTAssertEqual(GitHubUpdatesAPI.result(.turnOff, statusCode: 200, data: answer), .updated(try XCTUnwrap(GitHubUpdatesSection.decode(answer))))

        let conflict = Data(#"{"error": {"code": "conflict", "message": "Instant GitHub updates are off. Turn them on first."}}"#.utf8)
        XCTAssertEqual(GitHubUpdatesAPI.result(.restartRelay, statusCode: 409, data: conflict),
                       .failed("Couldn't restart the relay: Instant GitHub updates are off. Turn them on first."))
        XCTAssertEqual(GitHubUpdatesAPI.result(.recreateSecret, statusCode: 200, data: Data("{}".utf8)),
                       .failed("Couldn't re-create the webhook secret: Symphony's answer couldn't be read."))
        XCTAssertEqual(GitHubUpdatesAPI.result(.changeRelay, statusCode: 404, data: Data()),
                       .failed("Couldn't change the relay: this Symphony predates instant updates. Update it."))
        XCTAssertEqual(GitHubUpdatesAPI.result(.turnOn, statusCode: 500, data: Data(#"{"error": {"message": " "}}"#.utf8)),
                       .failed("Couldn't turn on instant updates: Symphony answered with HTTP 500."))
    }

    /// Turn Off, confirmed in S12, against the QA fixtures' API: the answer reads "Polling only", and polling goes on.
    func testTurnOffAgainstAFakeAPILeavesPollingRunning() async throws {
        let root = uniqueTemporaryDirectory("github-updates-api")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = APIFixtures(directory: Self.fixture("github-updates"), requestLog: root.appendingPathComponent("qa/api-requests.jsonl"))
        let on = try section("github-updates")

        // The sheet sends nothing until its button.
        let sheet = try XCTUnwrap(GitHubUpdatesSheet(.turnOff, section: on))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtures.requestLog.path))

        let request = sheet.request
        let result = await GitHubUpdatesAPI.send(
            request.action, params: request.params, stateRoot: root, fallback: APIFixtures.baseURL, transport: fixtures.transport
        )
        guard case let .updated(off) = result else { return XCTFail("\(result)") }
        let card = card(off)
        XCTAssertEqual(card.state, .off)
        XCTAssertEqual(card.word, "Polling only")
        XCTAssertTrue(card.sentence.hasPrefix("Symphony checks GitHub every 30 s"))
        XCTAssertEqual(off.poll.intervalMs, 30_000)
        XCTAssertEqual(off.repos.map(\.connected), [false, false, false])
        XCTAssertTrue(try String(contentsOf: fixtures.requestLog, encoding: .utf8).contains(#""path":"/api/v1/setup/github_updates/turn_off""#))

        // The card shows the answer while the state poll still reports what it did before, then the poll's.
        let answer = GitHubUpdatesAnswer(section: off, baseline: on)
        XCTAssertEqual(GitHubUpdatesAnswer.shown(state: on, answer: answer), off)
        var later = off
        later.rateLimit = nil
        XCTAssertEqual(GitHubUpdatesAnswer.shown(state: later, answer: answer), later)
        XCTAssertEqual(GitHubUpdatesAnswer.shown(state: on, answer: nil), on)
    }

    /// Restart Relay against the degraded fixture brings back Instant.
    func testRestartRelayAgainstAFakeAPIReadsInstant() async throws {
        let root = uniqueTemporaryDirectory("github-updates-restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = APIFixtures(directory: Self.fixture("github-updates-degraded"), requestLog: root.appendingPathComponent("qa/api-requests.jsonl"))
        let result = await GitHubUpdatesAPI.send(.restartRelay, stateRoot: root, fallback: APIFixtures.baseURL, transport: fixtures.transport)
        guard case let .updated(section) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(card(section).word, "Instant")
        XCTAssertNil(GitHubUpdatesCard.attention(section))
    }

    func testSendSaysWhenNothingAnswers() async {
        let root = uniqueTemporaryDirectory("github-updates-down")
        defer { try? FileManager.default.removeItem(at: root) }
        let unreachable = await GitHubUpdatesAPI.send(.turnOff, stateRoot: root, fallback: URL(string: "http://127.0.0.1:9")!) { _ in
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertEqual(unreachable, .failed("Couldn't turn off instant updates: nothing answered at http://127.0.0.1:9."))
        let nowhere = await GitHubUpdatesAPI.send(.turnOff, stateRoot: root, fallback: nil)
        XCTAssertEqual(nowhere, .failed("Couldn't turn off instant updates: Symphony hasn't said where it listens."))
    }

    func testIntervalsReadInSecondsOrMinutes() {
        XCTAssertEqual(GitHubUpdatesCard.interval(30_000), "30 s")
        XCTAssertEqual(GitHubUpdatesCard.interval(300_000), "5 min")
        XCTAssertEqual(GitHubUpdatesCard.number(5000), "5,000")
        XCTAssertEqual(GitHubUpdatesCard.sentence(" Done. "), "Done.")
    }
}

import XCTest
@testable import SymphonyBarCore

/// S13: Add Repo's last step while instant updates are on, against a fake Symphony that reads the new repo late.
@MainActor
final class AddRepoInstantUpdatesTests: XCTestCase {
    /// The fake's Mac, instant updates on for acme/web-shop and acme/api, and Symphony not yet listing `widgets`.
    private func fake(listing: Bool = false) -> FakeGitHubUpdates {
        let fake = FakeGitHubUpdates(FakeGitHubUpdates.section(
            mode: .on, done: ["relay", "gh_ready", "secret", "port", "repo:web-shop", "repo:api", "test:web-shop", "test:api"]
        ))
        fake.section.enabled = true
        if listing { add(to: fake) }
        return fake
    }

    /// Symphony read the repo Add Repo saved: its steps and its row appear.
    private func add(to fake: FakeGitHubUpdates) {
        fake.section.steps += [
            GitHubUpdatesSection.Step(id: "repo:widgets", kind: "repo", repo: "widgets", title: "Webhook on acme/widgets", status: .pending),
            GitHubUpdatesSection.Step(id: "test:widgets", kind: "test", repo: "widgets", title: "Test delivery from acme/widgets", status: .pending),
        ]
        fake.section.repos.append(GitHubUpdatesSection.Repo(key: "widgets", github: "acme/widgets", connected: false))
    }

    private func controller(_ fake: FakeGitHubUpdates) -> AddRepoInstantUpdatesController {
        let services = fake.services
        return AddRepoInstantUpdatesController(key: "widgets", services: AddRepoInstantUpdatesController.Services(
            send: services.send, read: services.read, sleep: services.sleep
        ))
    }

    func testTheNewRepoConnectsAndItsTestUpdateArrivesOnceSymphonyReadIt() async throws {
        let fake = fake()
        let controller = controller(fake)
        XCTAssertEqual(controller.step.title, "Instant updates for widgets")
        XCTAssertEqual(controller.step.rows.first?.detail, "Waiting for Symphony to read widgets…")
        var reads = 0
        var seen: [AddRepoInstantUpdates] = []
        controller.onChange = { step in
            seen.append(step)
            // Symphony reads symphony.yml between the app's first and second read.
            if step.section != nil, reads == 0 { reads += 1; self.add(to: fake) }
        }
        fake.reads = [[:], [:], ["test:widgets": .done]]

        await controller.start()

        let step = controller.step
        XCTAssertEqual(fake.calls, ["read", "read", "run_step step=repo:widgets", "test repo=widgets", "read"])
        XCTAssertEqual(step.title, "Instant updates for acme/widgets")
        XCTAssertEqual(step.rows.map(\.title), ["Webhook added", "Test update"])
        XCTAssertEqual(step.rows.map(\.word), ["Done", "Done"])
        XCTAssertEqual(step.rows.map(\.detail), ["Forwarding through the GitHub CLI", "Received and verified"])
        XCTAssertTrue(step.canFinish)
        XCTAssertNil(step.doneProblem)
        XCTAssertTrue(step.explanation.contains("Skip leaves it on polling: Symphony checks it every 30 s."), step.explanation)
        XCTAssertTrue(seen.contains { $0.rows.last?.word == "Waiting" }, "the test row waits while the update is on its way")
        XCTAssertTrue(fake.section.repo("widgets")?.connected == true)
    }

    func testARepoSymphonyNeverReadsFailsAndRetryWaitsAgain() async throws {
        let fake = fake()
        let controller = controller(fake)

        await controller.start()

        XCTAssertEqual(fake.calls.count, AddRepoInstantUpdatesController.repoWaitLimit)
        XCTAssertEqual(AddRepoInstantUpdatesController.repoWaitLimit, 60)
        let webhook = try XCTUnwrap(controller.step.rows.first)
        XCTAssertEqual([webhook.word, webhook.detail], ["Failed", "Symphony hasn't read widgets from symphony.yml yet."])
        XCTAssertEqual(webhook.buttons, [.retry])
        XCTAssertEqual(controller.step.rows.last?.word, "To do")
        XCTAssertFalse(controller.step.canFinish)
        XCTAssertEqual(controller.step.doneProblem, "Done is available once the test update arrived. Skip leaves widgets on polling.")

        add(to: fake)
        fake.calls = []
        fake.test = .status(.done)
        await controller.retry("repo:widgets")
        XCTAssertEqual(fake.calls, ["read", "run_step step=repo:widgets", "test repo=widgets"])
        XCTAssertTrue(controller.step.canFinish)
    }

    func testASymphonyThatDoesntAnswerSaysWhy() async throws {
        let fake = fake()
        let services = fake.services
        let controller = AddRepoInstantUpdatesController(key: "widgets", services: AddRepoInstantUpdatesController.Services(
            send: services.send, read: { .failed("Couldn't read the setup: nothing answered at http://127.0.0.1:4123.") }, sleep: { _ in }
        ))

        await controller.start()

        XCTAssertEqual(controller.step.rows.first?.detail, "Couldn't read the setup: nothing answered at http://127.0.0.1:4123.")
    }

    func testAWebhookGitHubRefusesFailsWithRetryAndSendsNoTest() async throws {
        let fake = fake(listing: true)
        fake.runs["repo:widgets"] = [
            .status(.failed, detail: "You need admin access to acme/widgets to add a webhook.", fix: "Ask an owner of acme/widgets for admin access, or leave widgets on polling."),
            .status(.done),
        ]
        fake.test = .status(.done)
        let controller = controller(fake)

        await controller.start()

        let webhook = try XCTUnwrap(controller.step.rows.first)
        XCTAssertEqual([webhook.word, webhook.detail], ["Failed", "You need admin access to acme/widgets to add a webhook."])
        XCTAssertEqual(webhook.buttons, [.retry])
        XCTAssertEqual(fake.calls, ["read", "run_step step=repo:widgets"])
        XCTAssertFalse(controller.step.isConnected)

        fake.calls = []
        await controller.retry("repo:widgets")
        XCTAssertEqual(fake.calls, ["run_step step=repo:widgets", "test repo=widgets"])
        XCTAssertTrue(controller.step.canFinish)
    }

    func testAFailedTestUpdateRetriesTheTestAlone() async throws {
        let fake = fake(listing: true)
        fake.test = .status(.failed, detail: "No test delivery reached Symphony within 30 seconds.", fix: "Check that the relay is running.")
        let controller = controller(fake)
        await controller.start()

        let test = try XCTUnwrap(controller.step.rows.last)
        XCTAssertEqual([test.word, test.detail, test.fix], ["Failed", "No test delivery reached Symphony within 30 seconds.", "Check that the relay is running."])

        fake.calls = []
        fake.test = nil
        fake.reads = [["test:widgets": .done]]
        await controller.retry("test:widgets")
        XCTAssertEqual(fake.calls, ["test repo=widgets", "read"])
        XCTAssertTrue(controller.step.canFinish)
    }

    func testATestUpdateSymphonyNeverSettlesFails() async throws {
        let fake = fake(listing: true)
        let controller = controller(fake)
        await controller.start()

        XCTAssertEqual(controller.step.rows.last?.detail, "Symphony didn't say whether the test update arrived.")
    }

    func testSkipLeavesAConnectedRepoOnPollingAndARefusalKeepsTheSheet() async throws {
        let fake = fake(listing: true)
        fake.test = .status(.failed, detail: "No test delivery reached Symphony within 30 seconds.")
        var controller = controller(fake)
        await controller.start()
        XCTAssertTrue(controller.step.isConnected)

        fake.leave = .refuse("Couldn't leave the repo on polling: Instant GitHub updates are off.")
        let refused = await controller.skip()
        XCTAssertEqual(refused, "Couldn't leave the repo on polling: Instant GitHub updates are off.")
        XCTAssertEqual(controller.step.rows.first?.detail, refused)

        fake.leave = nil
        fake.calls = []
        let skipped = await controller.skip()
        XCTAssertNil(skipped)
        XCTAssertEqual(fake.calls, ["leave_on_polling repo=widgets"])
        XCTAssertEqual(fake.section.repo("widgets")?.connected, false)
        await controller.retry("test:widgets")
        XCTAssertEqual(fake.calls, ["leave_on_polling repo=widgets"], "a skipped step sends nothing more")

        // A repo that never connected has nothing to take back.
        fake.calls = []
        controller = self.controller(fake)
        controller.close()
        await controller.start()
        let nothing = await controller.skip()
        XCTAssertNil(nothing)
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: The sheet's steps

    func testInstantUpdatesIsTheLastStepOnlyWhileTheyAreOn() {
        XCTAssertEqual(AddRepoFlow().steps, [.source, .linear, .review, .check])
        let flow = AddRepoFlow(instantUpdates: true)
        XCTAssertEqual(flow.steps, [.source, .linear, .review, .check, .instantUpdates])
        XCTAssertEqual(AddRepoStep.instantUpdates.rawValue, "Instant updates")
        XCTAssertNil(flow.step(after: .check))
        XCTAssertNil(flow.step(after: .instantUpdates))
        XCTAssertNil(flow.step(before: .instantUpdates), "the repo is saved: there is no way back")
        XCTAssertNil(flow.step(before: .check))
        XCTAssertEqual(flow.step(before: .review), .linear)
        XCTAssertNil(flow.problem(at: .instantUpdates))
    }
}

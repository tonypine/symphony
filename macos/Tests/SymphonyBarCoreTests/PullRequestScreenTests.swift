import XCTest
@testable import SymphonyBarCore

/// D15 from the `pull-request` fixture's #448 and its variants: merged, closed, GitHub unavailable, untracked, not found.
final class PullRequestScreenTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let now = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!
    private let place = PullRequestPlace(repoKey: "symphony", number: 448)

    private var api: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/pull-request/api/v1", isDirectory: true)
    }

    /// #448 as the fixture serves it, with `change` applied to its JSON.
    private func result(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> PullRequestPageResult {
        let data = try Data(contentsOf: api.appendingPathComponent("pull_requests/symphony/448.json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&json)
        return PullRequestPageResult(.answered(try JSONSerialization.data(withJSONObject: json), statusCode: 200))
    }

    private func screen(_ result: PullRequestPageResult?, references: [String: Reference] = [:]) -> PullRequestScreen {
        PullRequestScreen(place, result: result, url: URL(string: "https://github.com/tonypine/symphony/pull/448"), references: references, now: now, timeZone: utc)
    }

    private func page(_ screen: PullRequestScreen) throws -> PullRequestScreen.Page {
        guard case let .page(page) = screen.content else { throw XCTSkip("no page: \(screen.content)") }
        return page
    }

    func testEverySectionFor448() throws {
        let screen = screen(try result())
        XCTAssertEqual(screen.title, "#448 · Remove the Final verification and Supervisor check flows")
        XCTAssertEqual(screen.subtitle, "symphony · for TP-892")
        XCTAssertFalse(screen.isLoading)
        XCTAssertEqual(screen.gitHubURL, URL(string: "https://github.com/tonypine/symphony/pull/448"))
        XCTAssertEqual(screen.ticket, "TP-892")

        let page = try page(screen)
        XCTAssertEqual(page.badge, .init(status: .you, word: "Changes asked"))
        XCTAssertEqual(page.dates, "Opened 1 day ago · last push 4 h 50 min ago")
        XCTAssertTrue(page.gitHubAvailable)
        XCTAssertEqual(page.summary?.hasPrefix("The Final verification and Supervisor check steps are gone"), true)

        XCTAssertEqual(page.history.map(\.badge.word), ["Changes asked", "Changes asked"])
        XCTAssertEqual(page.history.map(\.title), ["Code Review", "Code Review"])
        XCTAssertEqual(page.history.map(\.timeText), ["Oct 6, 11:40", "10:15"])
        XCTAssertEqual(page.history.first?.reason, "The old workflow's instructions still describe the Final verification step.")
        XCTAssertEqual(
            page.history.first?.accessibilityLabel,
            "Oct 6, 11:40, Code Review, Changes asked. The old workflow's instructions still describe the Final verification step."
        )

        XCTAssertEqual(page.areas?.map(\.name), ["Agent instructions", "Server", "Documentation", "Tests"])
        XCTAssertEqual(page.areas?.first, .init(
            name: "Agent instructions", files: "5 files", additions: "+18", deletions: "−240",
            accessibilityLabel: "Agent instructions, 5 files, 18 lines added, 240 removed"
        ))

        XCTAssertEqual(page.health, [
            .init(label: "Checks", value: "9 passed", status: .done),
            .init(label: "Code Review", value: "Changes asked · round 2", status: .you),
            .init(label: "QA", value: "Not run yet"),
            .init(label: "Overlaps", value: "#446 for TP-891"),
        ])
        XCTAssertEqual(page.size?.map(\.accessibilityLabel), ["14 files", "+120 −610 lines", "3 commits"])
        XCTAssertEqual(page.ticket, .init(text: "TP-892 (Retire two old review steps)", stage: .init(status: .you, word: "Rework"), waitingOn: "Waiting on you"))

        // The overlap and the ticket are chips.
        let health = Mentions.find(in: "#446 for TP-891", references: page.references)
        XCTAssertEqual(health.map(\.key), ["#446", "TP-891"])
        XCTAssertFalse(health.contains(where: \.isMissing))
        XCTAssertEqual(PullRequestPlace(page.references["#446"]!), PullRequestPlace(repoKey: "symphony", number: 446))
        let ticket = Mentions.find(in: page.ticket.text, references: page.references)
        XCTAssertEqual(ticket.map(\.chipText), ["TP-892 · Retire two old review steps"])
    }

    func testTheInboxsReferencesAreRicherThanThePagesOwn() throws {
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: api.appendingPathComponent("inbox.json"))))
        let references = inbox.items.reduce(into: [String: Reference]()) { $0.merge($1.references) { kept, _ in kept } }
        let page = try page(screen(try result(), references: references))
        guard case let .ticket(ticket)? = page.references["TP-891"] else { return XCTFail("TP-891 isn't a ticket") }
        XCTAssertNotNil(ticket.title, "TP-891's title comes from the Inbox")
        XCTAssertNil(page.references["TP-880"], "a mention the page doesn't make isn't one of its chips")
    }

    func testNoFileBranchOrCommitOnThePage() throws {
        let strings = screen(try result()).renderedStrings
        XCTAssertTrue(strings.contains("Agent instructions"))
        XCTAssertTrue(strings.contains(PullRequestScreen.areasFootnote))
        let file = try NSRegularExpression(pattern: #"[\w-]+/[\w./-]+|\b[\w-]+\.(ex|exs|swift|md|liquid|json|yml|yaml|sh|py|js|ts)\b"#)
        let hash = try NSRegularExpression(pattern: #"\b[0-9a-f]{7,40}\b"#)
        let branch = try NSRegularExpression(pattern: #"\b(auto|origin|feature|fix)/|\bmain\b|\bHEAD\b"#)
        for string in strings {
            let range = NSRange(location: 0, length: (string as NSString).length)
            for (name, pattern) in [("file name", file), ("commit hash", hash), ("branch name", branch)] {
                XCTAssertNil(pattern.firstMatch(in: string, range: range), "\"\(string)\" holds a \(name)")
            }
        }
    }

    func testLoadingShowsPlaceholdersAndTheNumber() {
        let screen = screen(nil)
        XCTAssertTrue(screen.isLoading)
        XCTAssertEqual(screen.content, .loading)
        XCTAssertEqual(screen.title, "#448")
        XCTAssertEqual(screen.subtitle, "symphony")
        // Open on GitHub works before Symphony answers.
        XCTAssertEqual(screen.gitHubURL, URL(string: "https://github.com/tonypine/symphony/pull/448"))
        XCTAssertNil(screen.ticket)
        XCTAssertEqual(screen.renderedStrings, ["#448", "symphony", PullRequestScreen.readingTitle])
    }

    func testMerged() throws {
        let screen = screen(try result {
            $0["state"] = "merged"
            $0["review_state"] = "merged"
            $0["merged_at"] = "2026-10-07T12:20:00Z"
            $0["review_history"] = ($0["review_history"] as? [Any] ?? []) + [
                ["at": "2026-10-07T11:00:00Z", "kind": "code_review", "verdict": "approve", "reason": "Only the new flow is left."],
                ["at": "2026-10-07T12:00:00Z", "kind": "qa", "verdict": "pass"],
            ]
            $0["health"] = ["checks": ["state": "passed", "passed": 9], "code_review": ["verdict": "approve", "round": 3], "qa": "pass"]
        })
        XCTAssertEqual(screen.subtitle, "symphony · for TP-892 · merged 2 h ago")
        let page = try page(screen)
        XCTAssertEqual(page.badge, .init(status: .done, word: "Merged"))
        XCTAssertEqual(page.dates, "Merged 2 h ago")
        XCTAssertEqual(page.history.map(\.badge.word), ["Changes asked", "Changes asked", "Approved", "Passed", "Merged"])
        XCTAssertEqual(page.history.last, .init(timeText: "12:20", title: "Pull request", badge: .init(status: .done, word: "Merged")))
        XCTAssertEqual(page.health.map(\.value), ["9 passed", "Approved · round 3", "Passed", "None"])
    }

    func testMergedWithoutItsTime() throws {
        let screen = screen(try result { $0["state"] = "merged" })
        XCTAssertEqual(screen.subtitle, "symphony · for TP-892 · merged")
        XCTAssertEqual(try page(screen).dates, "Merged")
        XCTAssertEqual(try page(screen).history.last?.timeText, nil)
    }

    func testClosed() throws {
        let screen = screen(try result {
            $0["state"] = "closed"
            $0["review_state"] = "closed"
        })
        XCTAssertEqual(screen.subtitle, "symphony · for TP-892 · closed")
        let page = try page(screen)
        XCTAssertEqual(page.badge, .init(status: .idle, word: "Closed"))
        XCTAssertEqual(page.dates, "Closed without merging")
        XCTAssertEqual(page.history.count, 2, "a closed pull request's history has no Merged")
    }

    func testGitHubUnavailableKeepsWhatIsKnown() throws {
        let screen = screen(try result {
            $0["github"] = "unavailable"
            for key in ["state", "summary", "size", "title", "url", "opened_at", "last_pushed_at"] { $0[key] = NSNull() }
            $0["areas"] = []
            $0["health"] = ["checks": NSNull(), "code_review": ["verdict": "request_changes", "round": 2], "qa": NSNull(), "overlaps": [["number": 446, "ticket": "TP-891"]]]
        })
        XCTAssertEqual(screen.title, "#448")
        XCTAssertEqual(screen.subtitle, "symphony · for TP-892")
        // The link the page was opened from.
        XCTAssertEqual(screen.gitHubURL, URL(string: "https://github.com/tonypine/symphony/pull/448"))
        let page = try page(screen)
        XCTAssertFalse(page.gitHubAvailable)
        XCTAssertEqual(page.badge, .init(status: .you, word: "Changes asked"))
        XCTAssertNil(page.dates)
        XCTAssertNil(page.summary)
        XCTAssertNil(page.areas)
        XCTAssertNil(page.size)
        XCTAssertEqual(page.history.count, 2)
        XCTAssertEqual(page.health.first, .init(label: "Checks", value: PullRequestScreen.gitHubUnavailable))
        XCTAssertEqual(page.health.map(\.label), ["Checks", "Code Review", "QA", "Overlaps"])
        XCTAssertEqual(page.ticket.waitingOn, "Waiting on you")
        // What it does, What it changes, Checks and Size each say so.
        XCTAssertEqual(screen.renderedStrings.filter { $0 == PullRequestScreen.gitHubUnavailable }.count, 4)
    }

    func testAPullRequestWithoutChangesChecksOrVerdicts() throws {
        let screen = screen(try result {
            $0["summary"] = "  "
            $0["areas"] = []
            $0["review_history"] = []
            $0["opened_at"] = NSNull()
            $0["last_pushed_at"] = NSNull()
            $0["review_state"] = "open"
            $0["health"] = ["checks": ["state": "pending", "passed": 0, "failed": 0, "pending": 0], "overlaps": [["number": 450]]]
            $0["size"] = ["files": 1, "additions": 0, "deletions": 0, "commits": 1]
            $0["ticket"] = ["identifier": "TP-892"]
        })
        let page = try page(screen)
        XCTAssertEqual(page.badge, .init(status: .working, word: "Open"))
        XCTAssertNil(page.dates)
        XCTAssertEqual(page.summary, PullRequestScreen.noSummary)
        XCTAssertEqual(page.areas, [])
        XCTAssertEqual(page.history, [])
        XCTAssertEqual(page.health.map(\.value), ["None", "Not reviewed yet", "Not run yet", "#450"])
        XCTAssertEqual(page.size?.map(\.accessibilityLabel), ["1 file", "+0 −0 lines", "1 commit"])
        XCTAssertEqual(page.ticket, .init(text: "TP-892", stage: nil, waitingOn: nil))
        XCTAssertTrue(screen.renderedStrings.contains(PullRequestScreen.noHistory))
        XCTAssertTrue(screen.renderedStrings.contains(PullRequestScreen.noAreas))
    }

    func testChecksCountWhatFailedAndRunsFirst() throws {
        let page = try page(screen(try result {
            $0["health"] = ["checks": ["state": "failed", "passed": 6, "failed": 1, "pending": 2], "qa": "fail"]
        }))
        XCTAssertEqual(page.health[0], .init(label: "Checks", value: "1 failed · 2 running · 6 passed", status: .problem))
        XCTAssertEqual(page.health[2], .init(label: "QA", value: "Failed", status: .problem))
    }

    func testVerdictsInWords() {
        let words = [
            (PullRequestPage.Verdict.Kind.codeReview, "approve", "Approved"), (.codeReview, "request_changes", "Changes asked"),
            (.codeReview, "rework", "Changes asked"), (.codeReview, "block", "Blocked"), (.qa, "pass", "Passed"), (.qa, "fail", "Failed"),
            (.qa, "blocked", "Blocked"), (.qa, "skip", "Skipped"), (.qa, "needs_rerun", "Needs rerun"),
        ]
        for (kind, verdict, word) in words {
            XCTAssertEqual(PullRequestScreen.badge(verdict, kind: kind).word, word, verdict)
        }
        XCTAssertEqual(PullRequestScreen.badge("skip", kind: .qa).status, .idle)
    }

    func testUntrackedShowsTheTitleAndOpenOnGitHubOnly() throws {
        let screen = screen(try result { $0["ticket"] = NSNull() })
        XCTAssertEqual(screen.title, "#448 · Remove the Final verification and Supervisor check flows")
        XCTAssertEqual(screen.subtitle, "symphony")
        XCTAssertNil(screen.ticket)
        XCTAssertEqual(screen.content, .untracked("Symphony doesn't track #448: no ticket it sees owns it."))
        XCTAssertNotNil(screen.gitHubURL)
    }

    func testNotFoundUnsupportedAndFailed() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("pull-request-\(UUID()).jsonl")
        let fixtures = APIFixtures(directory: api.deletingLastPathComponent().deletingLastPathComponent(), requestLog: log)
        let missing = fixtures.answer(URLRequest(url: APIFixtures.baseURL.appendingPathComponent(PullRequestPage.path(repoKey: "symphony", number: 9))))
        let notFound = PullRequestScreen(
            PullRequestPlace(repoKey: "symphony", number: 9), result: PullRequestPageResult(.answered(missing.0, statusCode: missing.1.statusCode)),
            url: URL(string: "https://github.com/tonypine/symphony/pull/9"), now: now
        )
        XCTAssertEqual(notFound.content, .notFound("Symphony can't find #9 in symphony."))
        XCTAssertEqual(notFound.gitHubURL, URL(string: "https://github.com/tonypine/symphony/pull/9"))
        XCTAssertEqual(notFound.renderedStrings.last, "Symphony can't find #9 in symphony.")

        XCTAssertEqual(screen(.unsupported).content, .unsupported)
        XCTAssertEqual(screen(.unsupported).renderedStrings.last, EndpointPlaceholder.updateSymphony)
        XCTAssertEqual(screen(.failed("Symphony isn't answering")).content, .failed("Symphony isn't answering"))
    }

    func testTitleDropsTheTicketItStartsWith() {
        XCTAssertEqual(PullRequestScreen.title("TP-892 Retire two old review steps"), "Retire two old review steps")
        XCTAssertEqual(PullRequestScreen.title("[TP-892]: Retire them"), "Retire them")
        XCTAssertEqual(PullRequestScreen.title("TP-892 – Retire them"), "Retire them")
        XCTAssertEqual(PullRequestScreen.title("Retire TP-892's steps"), "Retire TP-892's steps")
        // A title that is only the identifier leaves the number alone in the toolbar.
        let screen = screen(try? result { $0["title"] = "TP-892" })
        XCTAssertEqual(screen.title, "#448")
    }
}

final class PullRequestPlaceTests: XCTestCase {
    func testFromAReferenceOrALink() throws {
        XCTAssertEqual(PullRequestPlace(.pullRequest(.init(number: 448, repoKey: "symphony", reviewState: .open, reviewRounds: 0))), .init(repoKey: "symphony", number: 448))
        XCTAssertNil(PullRequestPlace(.pullRequest(.init(number: 448, reviewState: .open, reviewRounds: 0))), "no repo, no page")
        XCTAssertNil(PullRequestPlace(.ticket(.init(identifier: "TP-1"))))

        let url = try XCTUnwrap(URL(string: "https://github.com/tonypine/symphony/pull/448/files"))
        XCTAssertEqual(PullRequestPlace(repoKey: "symphony", url: url), .init(repoKey: "symphony", number: 448))
        XCTAssertNil(PullRequestPlace(repoKey: nil, url: url))
        XCTAssertNil(PullRequestPlace(repoKey: "symphony", url: try XCTUnwrap(URL(string: "https://github.com/tonypine/symphony/issues/4"))))
        XCTAssertNil(PullRequestPlace(repoKey: "symphony", url: try XCTUnwrap(URL(string: "https://github.com/tonypine/symphony/pull"))))
        XCTAssertNil(PullRequestPlace(repoKey: "symphony", url: try XCTUnwrap(URL(string: "https://github.com/tonypine/symphony/pull/new"))))
    }

    /// ⌘-click and ⌘Return on a chip: a ticket's page, a pull request's page, or a link.
    func testWhatAChipOpensDirectly() throws {
        let github = try XCTUnwrap(URL(string: "https://github.com/tonypine/symphony/pull/448"))
        let linear = try XCTUnwrap(URL(string: "https://linear.app/x/issue/TP-1"))
        let references: [String: Reference] = [
            "TP-1": .ticket(.init(identifier: "TP-1", url: linear)),
            "#448": .pullRequest(.init(number: 448, repoKey: "symphony", url: github, reviewState: .open, reviewRounds: 2)),
            "#7": .pullRequest(.init(number: 7, url: github, reviewState: .open, reviewRounds: 0)),
            "#8": .pullRequest(.init(number: 8, reviewState: .open, reviewRounds: 0)),
            "TP-2": .missing(url: linear),
        ]
        let mentions = Mentions.find(in: "TP-1 #448 #7 #8 TP-2 TP-3", references: references)
        XCTAssertEqual(mentions.map(MentionTarget.init), [
            .ticketPage("TP-1"),
            .pullRequestPage(.init(repoKey: "symphony", number: 448), url: github),
            .link(github),
            nil,
            .link(linear),
            nil,
        ])
    }
}

/// ⌘[ from a page returns to the Inbox with the same item, its picks and its scroll position: the history goes back to
/// the Inbox, and the window keeps the selection, the picks and the offsets apart from it, untouched by the page.
final class PullRequestNavigationTests: XCTestCase {
    func testBackFromThePageReturnsToTheSameItemPickAndScroll() {
        let item = "issue-892"
        var history = NavigationHistory(current: .view(.inbox))
        var picks = InboxPicks()
        var scroll = InboxScrollOffsets()
        let selection = item
        picks.pick(2, decision: 0, itemID: item)
        scroll[item] = 640

        let page = PullRequestPlace(repoKey: "symphony", number: 448)
        history.visit(.pullRequest(page))
        XCTAssertTrue(history.current.isPage)
        XCTAssertEqual(history.back, [.view(.inbox)])
        // The page opens the ticket, and back again.
        history.visit(.ticket("TP-892"))
        XCTAssertEqual(history.goBack(), .pullRequest(page))

        XCTAssertEqual(history.goBack(), .view(.inbox))
        XCTAssertFalse(history.current.isPage)
        XCTAssertEqual(selection, item)
        XCTAssertEqual(picks[item].picks, [0: 2])
        XCTAssertEqual(scroll[item], 640)
        XCTAssertEqual(history.goForward(), .pullRequest(page))
    }

    func testScrollOffsetsForgetTheTop() {
        var scroll = InboxScrollOffsets()
        XCTAssertNil(scroll["a"])
        scroll["a"] = 120
        scroll["b"] = 80
        scroll["a"] = 0
        XCTAssertNil(scroll["a"], "a review at its top starts at its top")
        XCTAssertEqual(scroll["b"], 80)
        scroll["b"] = nil
        XCTAssertNil(scroll["b"])
    }
}

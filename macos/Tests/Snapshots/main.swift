// Renders the Inbox review snapshots offscreen with `ImageRenderer`: no `NSApplication`, no window.
// `make snapshots` compiles it with the app's views and writes the PNGs next to it.
import AppKit
import ImageIO
import SwiftUI
import SymphonyBarCore
import UniformTypeIdentifiers

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
// The fixture's clock, in UTC: its earlier call, at 05:48 that day, reads as today's.
NSTimeZone.default = TimeZone(identifier: "UTC")!
let now = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!
let fixture = here.appendingPathComponent("../Fixtures/director-app/inbox-decision/api/v1/inbox.json").standardizedFileURL

guard let inbox = InboxPayload.decode(try Data(contentsOf: fixture)),
    let item = inbox.items.first(where: { $0.identifier == "TP-892" }),
    let action = item.review.action
else { fatalError("TP-892 is missing from \(fixture.path)") }

/// TP-892 with the write-in (N11) picked and an answer in it (D2c).
let picks = DecisionPicks(
    picks: [0: action.writeInIndex],
    writeIn: "Leave them to TP-891, and add a note on TP-891 so its run removes the mention too."
)

/// A mention in TP-892's question and story by its key (TP-999 is one Symphony can't see), as its chip finds it.
func mention(_ key: String) -> Mention {
    let text = key == "TP-999" ? "Ask TP-999 first." : [action.question, action.why].compactMap { $0 }.joined(separator: " ")
    guard let found = Mentions.find(in: text, references: item.references).first(where: { $0.key == key }) else {
        fatalError("\(key) is not mentioned in TP-892's text")
    }
    return found
}

/// TP-892 at `width`: the Inbox's narrow pane, or a 1200 pt window's.
@MainActor
func review(width: CGFloat, picks: DecisionPicks = DecisionPicks()) -> some View {
    review(item, width: width, picks: picks)
}

/// Another item of the fixture's review, by its ticket: the plan, the pull request, the clarify or the blocked one.
@MainActor
func review(_ identifier: String) -> some View {
    guard let other = inbox.items.first(where: { $0.identifier == identifier }) else { fatalError("\(identifier) is missing from \(fixture.path)") }
    return review(other, width: 640)
}

@MainActor
func review(_ item: InboxItem, width: CGFloat, picks: DecisionPicks = DecisionPicks()) -> some View {
    InboxReviewBody(item: item, picks: picks, perform: { _ in }, narrow: width < DesignTokens.Layout.narrowReviewWidth, now: now)
        .frame(width: width)
        .background(DesignTokens.Surface.content.color)
}

/// TP-892's ticket page (D3), its brief and earlier decisions from its Inbox item, in a 1200 pt window beside the
/// sidebar.
@MainActor
func ticketPage() -> some View {
    let state = try? Data(contentsOf: fixture.deletingLastPathComponent().appendingPathComponent("state.json"))
    let page = TicketPage(identifier: "TP-892", sources: TicketPage.Sources(state: state), timeZone: TimeZone(identifier: "UTC")!)
    let width = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth
    return TicketPageBody(page: page, brief: TicketPage.Brief(identifier: "TP-892", items: inbox.items), actions: TicketPageActions(), width: width)
        .frame(width: width)
        .background(DesignTokens.Surface.content.color)
}

/// A chip's popover (N2, N3, or a mention Symphony can't see). `ImageRenderer` draws no glass, so it sits on the
/// window's surface.
@MainActor
func popover(_ key: String) -> some View {
    ReferencePopoverView(popover: ReferencePopover(mention(key)))
        .background(DesignTokens.Surface.window.color)
}

/// A peek page (N4) as the inspector shows it, 340 pt wide: TP-891 as Symphony tracks it (its endpoint answers), or a
/// pull request.
@MainActor
func peekPage(_ key: String) -> some View {
    let api = fixture.deletingLastPathComponent()
    let entry = PeekEntry(mention(key))
    let content: PeekContent = if case let .ticket(ticket) = entry.reference {
        .ticket(TicketPeek(
            ticket, references: item.references,
            sources: PeekSources(
                inbox: inbox.items,
                state: try? Data(contentsOf: api.appendingPathComponent("state.json")),
                issue: try? Data(contentsOf: api.appendingPathComponent("\(key).json"))
            ),
            now: ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z") ?? Date()
        ))
    } else {
        .other(ReferencePopover(key: key, kind: entry.kind, reference: entry.reference))
    }
    return PeekPage(entry: entry, content: content, scrolls: false)
        .frame(width: PeekPresentation.idealInspectorWidth)
}

/// The walkthrough's moment: option 3 picked, and the TP-891 peek beside the review, which keeps the pick.
@MainActor
func peekBesideReview() -> some View {
    HStack(alignment: .top, spacing: 0) {
        review(width: 660, picks: DecisionPicks(picks: [0: 2]))
        Divider()
        peekPage("TP-891")
    }
    .background(DesignTokens.Surface.window.color)
}

// The PR and CI watcher's fixture (TP-946): its tickets measured against its state's clock.
let watchAPI = here.appendingPathComponent("../Fixtures/director-app/pr-watch/api/v1").standardizedFileURL
let watchState = try Data(contentsOf: watchAPI.appendingPathComponent("state.json"))
let watchNow = ISO8601DateFormatter().date(from: "2026-10-16T12:04:12Z")!
guard let watchInbox = InboxPayload.decode(try Data(contentsOf: watchAPI.appendingPathComponent("inbox.json"))) else {
    fatalError("The PR and CI fixture's Inbox doesn't read")
}

/// S15: a ticket's whole page with its PR and CI card, in a 1200 pt window beside the sidebar.
@MainActor
func watchPage(_ identifier: String) -> some View {
    let issue = try? Data(contentsOf: watchAPI.appendingPathComponent("\(identifier).json"))
    let decision = watchInbox.items.contains { $0.identifier == identifier && $0.isDecision }
    let page = TicketPage(
        identifier: identifier, sources: TicketPage.Sources(state: watchState, issue: issue, inboxDecision: decision),
        now: watchNow, timeZone: TimeZone(identifier: "UTC")!
    )
    let width = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth
    return TicketPageBody(page: page, actions: TicketPageActions(), width: width)
        .frame(width: width)
        .background(DesignTokens.Surface.content.color)
}

/// S16: the protected-paths decision's review, with what the watcher found above its options.
@MainActor
func watcherDecision() -> some View {
    guard let item = watchInbox.items.first(where: { $0.identifier == "TP-703" }) else { fatalError("TP-703 is missing") }
    let evidence = WatcherEvidence(item: item, watch: WatchState.decode(watchState).watches[item.identifier])
    return InboxReviewBody(item: item, perform: { _ in }, now: watchNow, evidence: evidence)
        .frame(width: 640)
        .background(DesignTokens.Surface.content.color)
}

/// S17: the Overview with the silent Rework ticket in Needs attention.
@MainActor
func silentWaitOverview() -> some View {
    guard let state = OverviewState.decode(watchState) else { fatalError("The PR and CI fixture's state doesn't read") }
    let width = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth
    return OverviewBody(overview: Overview(state: state, now: watchNow, timeZone: TimeZone(identifier: "UTC")!), actions: OverviewActions(resume: {}, perform: { _ in }), width: width)
        .frame(width: width)
        .background(DesignTokens.Surface.content.color)
}

// Setup (TP-910): SU3–SU9 from the Setup QA fixture, at its clock.
let setupAPI = here.appendingPathComponent("../Fixtures/director-app/setup/api/v1").standardizedFileURL
let setupConfig = here.appendingPathComponent("../Fixtures/director-app/setup/config/symphony.yml").standardizedFileURL
let setupNow = ISO8601DateFormatter().date(from: "2026-10-19T12:00:30Z")!
let setupState = SetupPayload.decode(state: try Data(contentsOf: setupAPI.appendingPathComponent("state.json")))!

func setupProblem(_ id: String) -> SetupPayload.Problem {
    guard let problem = setupState.problems.first(where: { $0.id == id }) else { fatalError("\(id) is missing from the Setup fixture") }
    return problem
}

/// A Setup page beside the sidebar of a 1200 pt window.
@MainActor
func setupPage(_ payload: SetupPayload, expanded: Set<String> = []) -> some View {
    let width = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth
    return SetupPageBody(page: SetupPage(payload: payload, now: setupNow, timeZone: TimeZone(identifier: "UTC")!), expanded: expanded)
        .frame(width: width)
        .background(DesignTokens.Surface.window.color)
}

/// SU4: a hold drift row with its Details open, one line per ticket with its own Re-sync, and a key's Details.
let setupDrift = SetupPayload.Problem(
    id: "hold_drift:web-shop", severity: .warning, category: "labels",
    title: "2 tickets in web-shop have hold labels that don't match their holds",
    consequence: "A ticket's label says it is paused when it isn't, or a paused ticket doesn't show it, and Symphony couldn't put it right on its own. "
        + "Re-sync sets the label from the hold Symphony keeps.",
    repos: ["web-shop"], tickets: [.init(identifier: "TP-412"), .init(identifier: "TP-415")],
    details: [
        .init(label: "TP-412", value: "Blocked label with no hold, since 2026-10-19 09:12 UTC"),
        .init(label: "TP-415", value: "Needs Decision hold with no label, since 2026-10-19 10:40 UTC"),
    ],
    fix: .resyncHold(repo: "web-shop", tickets: ["TP-412", "TP-415"])
)

/// SU6: no Linear API key, so the secrets error and the Linear-side checks under Not checked.
let setupNoKey = SetupPayload(
    problems: [SetupPayload.Problem(
        id: "secrets:LINEAR_API_KEY", severity: .error, category: "secrets",
        title: "Symphony can't read Linear: no ticket is picked up",
        consequence: "Without a Linear API key Symphony reads no tickets, so nothing runs, and Setup can't check the Linear teams, states and labels.",
        details: [.init(label: "Key", value: "issues.linear.api_key"), .init(label: "Variable", value: "LINEAR_API_KEY")],
        fix: .open(.settings, url: nil)
    )],
    notChecked: [
        ("routing", "Routing of each repository's tickets"), ("teams", "Each repository's Linear team"),
        ("labels", "Symphony's labels in each Linear team"), ("hold_drift", "Hold labels that don't match their holds"),
    ].map { SetupPayload.NotChecked(id: $0.0, title: $0.1, reason: "No Linear API key is set, so Symphony can't read Linear. Add one in Settings.") },
    checkedAt: setupState.checkedAt
)

/// SU7–SU9: a fix's sheet on the window's surface.
@MainActor
func setupSheet(_ sheet: SetupFixSheet) -> some View {
    SetupFixSheetView(sheet: sheet, cancel: {}, confirm: {})
        .background(DesignTokens.Surface.window.color)
}

@MainActor
func setupConfigSheet() -> some View {
    let text = (try? String(contentsOf: setupConfig, encoding: .utf8)) ?? ""
    let edited = Result { try SetupConfigEdit.apply(path: "auto_review.enabled", action: .remove, value: .null, to: text) }
    return setupSheet(SetupFixSheet(problem: setupProblem("deprecated_key:auto_review.enabled"), text: text, edited: edited)!)
}

@MainActor
func setupLabelSheet(failed: Bool = false) -> some View {
    var sheet = SetupFixSheet(problem: setupProblem("labels:missing:TP:Needs Decision"))!
    if failed {
        sheet.fail("Linear refused to create the label \"Needs Decision\" in team TP: the Linear API key isn't allowed to (HTTP 403). "
            + "Ask an admin of the team to do it, or use a key that may.")
    }
    return setupSheet(sheet)
}

// Add Repo's Check setup step (TP-911, SU11) from its QA fixtures, and the first launch's Setup page (SU12).
func addRepoAnswer(_ fixture: String, _ file: String) -> SetupPayload {
    let url = here.appendingPathComponent("../Fixtures/director-app/\(fixture)/api/v1/setup/\(file)").standardizedFileURL
    guard let payload = SetupPayload.decode(try! Data(contentsOf: url)) else { fatalError("\(url.path) isn't a setup payload") }
    return payload.forRepo("widgets")
}

/// The Add Repo sheet on its last step: its title, the steps, the page and the footer, at the sheet's size.
@MainActor
func addRepoCheck(_ phase: AddRepoSetupCheck.Phase, fixMessage: String? = nil) -> some View {
    let check = AddRepoSetupCheck(
        key: "widgets", route: RepositoryRoute(team: "QA", projects: ["8e6f0c39-6a8b-4c1e-9d0e-1f2a3b4c5d6e"]), phase: phase
    )
    return VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
            Text(AddRepo.sheetTitle).font(.headline)
            AddRepoStepIndicator(steps: [.source, .linear, .review, .check], current: .check)
        }
        .padding([.top, .horizontal], 16)
        .padding(.bottom, 8)
        Divider()
        AddRepoCheckPage(check: check, fixMessage: fixMessage, now: setupNow)
            .frame(maxHeight: .infinity, alignment: .top)
        Divider()
        AddRepoCheckFooter(check: check, canStart: true)
    }
    .frame(width: AddRepoView.size.width, height: AddRepoView.size.height)
    .background(DesignTokens.Surface.window.color)
}

@MainActor
func firstLaunchSetup() -> some View {
    let width = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth
    return SetupPageBody(page: SetupPage(payload: setupState, now: setupNow, timeZone: TimeZone(identifier: "UTC")!), welcome: SetupOnStart.welcome)
        .frame(width: width)
        .background(DesignTokens.Surface.window.color)
}

// GitHub updates (TP-953): S1, S7 with Details, S8, S10, S14 and the S12 and S11 sheets, from the card's QA fixtures.
let githubNow = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!

func githubSection(_ name: String) -> GitHubUpdatesSection {
    let state = here.appendingPathComponent("../Fixtures/director-app/\(name)/api/v1/state.json").standardizedFileURL
    guard let section = GitHubUpdatesSection.decode(state: try! Data(contentsOf: state)) else { fatalError("\(name) has no GitHub updates") }
    return section
}

/// A healthy Setup page with the GitHub updates card for `section`, beside the sidebar of a 1200 pt window.
@MainActor
func githubUpdatesPage(_ section: GitHubUpdatesSection, expanded: Bool = false) -> some View {
    let width = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth
    let utc = TimeZone(identifier: "UTC")!
    return SetupPageBody(
        page: SetupPage(payload: SetupPayload(checkedAt: githubNow), now: githubNow, timeZone: utc),
        githubUpdates: GitHubUpdatesCard(section: section, now: githubNow, timeZone: utc),
        githubExpanded: expanded
    )
    .frame(width: width)
    .background(DesignTokens.Surface.window.color)
}

/// S10: no webhook secret on this Mac while instant updates are on.
func githubSecretFailing() -> GitHubUpdatesSection {
    var section = githubSection("github-updates")
    section.secret.present = false
    return section
}

/// S14: a symphony.yml from another Mac turns instant updates on, and this Mac never ran the setup.
func githubNeedsSetup() -> GitHubUpdatesSection {
    var section = githubSection("github-updates-off")
    section.mode = .needsSetup
    section.enabled = true
    for index in section.steps.indices where ["gh_ready", "port"].contains(section.steps[index].id) {
        section.steps[index].status = .done
    }
    return section
}

@MainActor
func githubSheet(_ action: GitHubUpdatesCard.Action) -> some View {
    GitHubUpdatesSheetView(sheet: GitHubUpdatesSheet(action, section: githubSection("github-updates"))!, cancel: {}, confirm: {})
        .background(DesignTokens.Surface.window.color)
}

// The guided setup (TP-954): S2, S3 with the permission missing, S4, S5 with one repo failed, S6, and Add Repo's S13,
// from the walkthrough's QA fixtures.
func githubAnswer(_ fixture: String, _ file: String) -> GitHubUpdatesSection {
    let url = here.appendingPathComponent("../Fixtures/director-app/\(fixture)/api/v1/setup/\(file)").standardizedFileURL
    guard let section = GitHubUpdatesSection.decode(try! Data(contentsOf: url)) else { fatalError("\(url.path) has no GitHub updates") }
    return section
}

@MainActor
func githubSetup(_ page: GitHubUpdatesSetup.Page, answer: String? = nil, change: (inout GitHubUpdatesSetup) -> Void = { _ in }) -> some View {
    var setup = GitHubUpdatesSetup(purpose: .turnOn, section: githubSection("github-updates-off"))
    if let answer { setup.accept(githubAnswer("github-updates-setup", answer)) }
    setup.show(page)
    change(&setup)
    return GitHubUpdatesSetupView(setup: setup).background(DesignTokens.Surface.window.color)
}

@MainActor
func addRepoInstantUpdates(steps: [AddRepoStep] = [.source, .linear, .review, .check, .instantUpdates]) -> some View {
    var step = AddRepoInstantUpdates(key: "widgets")
    step.accept(githubAnswer("github-updates-add-repo", "github_updates/test.json"))
    return VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
            Text(AddRepo.sheetTitle).font(.headline)
            AddRepoStepIndicator(steps: steps, current: .instantUpdates)
        }
        .padding([.top, .horizontal], 16)
        .padding(.bottom, 8)
        Divider()
        AddRepoInstantUpdatesPage(step: step)
            .frame(maxHeight: .infinity, alignment: .top)
        Divider()
        AddRepoInstantUpdatesFooter(step: step)
    }
    .frame(width: AddRepoView.size.width, height: AddRepoView.size.height)
    .background(DesignTokens.Surface.window.color)
}

/// Add Repo's step indicator on each page of the six steps a repo without a WORKFLOW.md has while instant updates are on,
/// as wide as the sheet's header: the steps done by their tick alone, so each line fits.
@MainActor
func addRepoSixSteps() -> some View {
    VStack(alignment: .leading, spacing: 0) {
        ForEach(AddRepoStep.allCases, id: \.self) { current in
            AddRepoStepIndicator(steps: AddRepoStep.allCases, current: current)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
        }
    }
    .frame(width: AddRepoView.size.width)
    .background(DesignTokens.Surface.window.color)
}

// The pull request page (TP-961, D15): #448 from its QA fixture, and its states from variants of it.
let pullRequestAPI = here.appendingPathComponent("../Fixtures/director-app/pull-request/api/v1").standardizedFileURL
let pullRequestPlace = PullRequestPlace(repoKey: "symphony", number: 448)

/// #448 as the fixture serves it, with `change` applied to its JSON.
func pullRequest(_ change: (inout [String: Any]) -> Void = { _ in }) -> PullRequestPageResult {
    let data = try! Data(contentsOf: pullRequestAPI.appendingPathComponent("pull_requests/symphony/448.json"))
    var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    change(&json)
    return PullRequestPageResult(.answered(try! JSONSerialization.data(withJSONObject: json), statusCode: 200))
}

/// The page in a `window` pt wide window beside the sidebar, with the toolbar's title and subtitle above it.
@MainActor
func pullRequestPage(_ result: PullRequestPageResult?, window: CGFloat = DesignTokens.Layout.windowWidth) -> some View {
    let inbox = InboxPayload.decode(try! Data(contentsOf: pullRequestAPI.appendingPathComponent("inbox.json")))
    let references = (inbox?.items ?? []).reduce(into: [String: Reference]()) { $0.merge($1.references) { kept, _ in kept } }
    let screen = PullRequestScreen(
        pullRequestPlace, result: result, url: URL(string: "https://github.com/tonypine/symphony/pull/448"),
        references: references, now: now, timeZone: TimeZone(identifier: "UTC")!
    )
    let width = window - DesignTokens.Layout.sidebarWidth
    return VStack(alignment: .leading, spacing: 0) {
        // The window's toolbar holds the page's title and subtitle (with its spinner while it reads), cut short as the
        // window cuts them; the page's buttons are in its header, below.
        VStack(alignment: .leading, spacing: 0) {
            Text(screen.title).font(.headline).lineLimit(1)
            HStack(spacing: DesignTokens.Space.s1) {
                Text(screen.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                // `ImageRenderer` can't draw a spinner: its symbol stands in.
                if screen.isLoading { Image(systemName: "progress.indicator").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: DesignTokens.Layout.toolbarTitleMaxWidth, alignment: .leading)
        .padding(DesignTokens.Space.s3)
        Divider()
        PullRequestPageBody(screen: screen, actions: PullRequestPageActions(), width: width)
            .frame(minHeight: 360)
    }
    .frame(width: width)
    .background(DesignTokens.Surface.window.color)
}

let mergedPullRequest = pullRequest {
    $0["state"] = "merged"
    $0["review_state"] = "merged"
    $0["merged_at"] = "2026-10-07T12:20:00Z"
    $0["review_history"] = ($0["review_history"] as? [Any] ?? []) + [
        ["at": "2026-10-07T11:00:00Z", "kind": "code_review", "verdict": "approve", "reason": "Only the new flow is left."],
        ["at": "2026-10-07T12:00:00Z", "kind": "qa", "verdict": "pass", "reason": "Every journey passed."],
    ]
    $0["health"] = ["checks": ["state": "passed", "passed": 9], "code_review": ["verdict": "approve", "round": 3], "qa": "pass"]
}
let closedPullRequest = pullRequest {
    $0["state"] = "closed"
    $0["review_state"] = "closed"
}
let unavailablePullRequest = pullRequest {
    $0["github"] = "unavailable"
    for key in ["state", "summary", "size", "url", "opened_at", "last_pushed_at"] { $0[key] = NSNull() }
    $0["areas"] = []
    $0["health"] = ["checks": NSNull(), "code_review": ["verdict": "request_changes", "round": 2], "qa": NSNull(), "overlaps": [["number": 446, "ticket": "TP-891"]]]
}
let untrackedPullRequest = pullRequest { $0["ticket"] = NSNull() }

/// A plan's open questions (TP-1191): SHOP-330 from the Inbox fixture, its second question answered in the Director's
/// own words.
@MainActor
func planQuestions() -> some View {
    let api = here.appendingPathComponent("../Fixtures/director-app/inbox/api/v1/inbox.json").standardizedFileURL
    guard let plan = InboxPayload.decode(try! Data(contentsOf: api))?.items.first(where: { $0.identifier == "SHOP-330" }) else {
        fatalError("SHOP-330 is missing from \(api.path)")
    }
    let picks = DecisionPicks(picks: [1: plan.review.questions[1].writeInIndex], writeIns: [1: "Ask the finance team which currency the books use, then pick."])
    return review(plan, width: 640, picks: picks)
}

@MainActor
func render(_ view: some View, _ scheme: ColorScheme, to name: String) {
    let view = view
        .environment(\.colorScheme, scheme)
        .environment(\.offscreenSnapshot, true)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage else { fatalError("Could not render \(name)") }
    let url = here.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
    print("wrote \(url.path)")
}

MainActor.assumeIsolated {
    for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
        render(review(width: 640, picks: picks), scheme, to: "inbox-write-in-\(suffix).png")
        // Chips inside the question, story and options, wrapping with the text (TP-952).
        render(review(width: 1200), scheme, to: "decision-chips-wide-\(suffix).png")
        render(review(width: 420), scheme, to: "decision-chips-narrow-\(suffix).png")
        // Where this ticket sits (N9, N10), last in the review: two columns, and labels above values when narrow.
        render(review(width: 1200), scheme, to: "decision-context-\(suffix).png")
        render(review(width: 420), scheme, to: "decision-context-narrow-\(suffix).png")
        render(popover("TP-891"), scheme, to: "ticket-popover-\(suffix).png")
        render(popover("#448"), scheme, to: "pr-popover-\(suffix).png")
        render(popover("TP-999"), scheme, to: "missing-popover-\(suffix).png")
        // The peek (TP-956): a ticket Symphony tracks, a pull request, and the ticket beside the decision.
        render(peekPage("TP-891"), scheme, to: "peek-ticket-\(suffix).png")
        render(peekPage("#448"), scheme, to: "peek-pr-\(suffix).png")
        render(peekBesideReview(), scheme, to: "peek-beside-review-\(suffix).png")
        // The same chips in the other reviews and on the ticket page (TP-988).
        for (identifier, name) in [("TP-923", "plan"), ("TP-895", "pr"), ("TP-896", "clarify"), ("TP-897", "blocked")] {
            render(review(identifier), scheme, to: "\(name)-chips-\(suffix).png")
        }
        render(ticketPage(), scheme, to: "ticket-page-chips-\(suffix).png")
        render(planQuestions(), scheme, to: "plan-questions-\(suffix).png")
        // The PR and CI watcher (TP-946): S15's states, S16 and S17.
        for (identifier, name) in [("TP-701", "ci"), ("TP-704", "competing"), ("TP-707", "fix-ticket"), ("TP-703", "on-hold"), ("TP-709", "pr-closed")] {
            render(watchPage(identifier), scheme, to: "pr-watch-\(name)-\(suffix).png")
        }
        render(watcherDecision(), scheme, to: "watcher-decision-\(suffix).png")
        render(silentWaitOverview(), scheme, to: "silent-wait-\(suffix).png")
        // Setup (TP-910): the page with problems, its Details, healthy, no Linear key, and the fix sheets.
        render(setupPage(setupState), scheme, to: "setup-problems-\(suffix).png")
        render(setupPage(SetupPayload(problems: setupState.problems + [setupDrift], checkedAt: setupState.checkedAt),
                         expanded: ["hold_drift:web-shop", "deprecated_key:auto_review.enabled"]), scheme, to: "setup-details-\(suffix).png")
        render(setupPage(SetupPayload(checkedAt: setupState.checkedAt?.addingTimeInterval(300))), scheme, to: "setup-healthy-\(suffix).png")
        render(setupPage(setupNoKey), scheme, to: "setup-no-linear-key-\(suffix).png")
        render(setupConfigSheet(), scheme, to: "setup-config-sheet-\(suffix).png")
        render(setupLabelSheet(), scheme, to: "setup-label-sheet-\(suffix).png")
        render(setupLabelSheet(failed: true), scheme, to: "setup-fix-failed-\(suffix).png")
        // Add Repo's Check setup (TP-911): an error with its fix, the fix made, a warning only, Symphony stopped; and
        // the first launch's Setup page.
        render(addRepoCheck(.checked(addRepoAnswer("add-repo-setup", "refresh.1.json"))), scheme, to: "add-repo-check-error-\(suffix).png")
        render(addRepoCheck(.checked(addRepoAnswer("add-repo-setup", "fixes.json")), fixMessage: "Created the label “Blocked” in team QA."),
               scheme, to: "add-repo-check-fixed-\(suffix).png")
        render(addRepoCheck(.checked(addRepoAnswer("add-repo-setup-warning", "refresh.1.json"))), scheme, to: "add-repo-check-warning-\(suffix).png")
        render(addRepoCheck(.onNextStart), scheme, to: "add-repo-check-stopped-\(suffix).png")
        render(firstLaunchSetup(), scheme, to: "setup-first-launch-\(suffix).png")
        // GitHub updates (TP-953).
        render(githubUpdatesPage(githubSection("github-updates-off")), scheme, to: "github-updates-off-\(suffix).png")
        render(githubUpdatesPage(githubSection("github-updates"), expanded: true), scheme, to: "github-updates-on-\(suffix).png")
        render(githubUpdatesPage(githubSection("github-updates-degraded")), scheme, to: "github-updates-degraded-\(suffix).png")
        render(githubUpdatesPage(githubSecretFailing()), scheme, to: "github-updates-secret-\(suffix).png")
        render(githubUpdatesPage(githubNeedsSetup()), scheme, to: "github-updates-needs-setup-\(suffix).png")
        render(githubSheet(.turnOff), scheme, to: "github-updates-turn-off-sheet-\(suffix).png")
        render(githubSheet(.recreateSecret), scheme, to: "github-updates-recreate-secret-sheet-\(suffix).png")
        // The guided setup and Add Repo's Instant updates (TP-954).
        render(githubSetup(.relay), scheme, to: "github-setup-relay-\(suffix).png")
        render(githubSetup(.gitHubCLI, answer: "github_updates/run_step.2.json"), scheme, to: "github-setup-permission-\(suffix).png")
        render(githubSetup(.secretAndPort, answer: "github_updates/run_step.4.json") { $0.secretSave = .saved }, scheme, to: "github-setup-secret-\(suffix).png")
        render(githubSetup(.repos, answer: "github_updates/run_step.7.json"), scheme, to: "github-setup-repos-\(suffix).png")
        render(githubSetup(.test, answer: "github_updates/test.json") { $0.secretSave = .saved; $0.leftOnPolling = ["docs"] }, scheme,
               to: "github-setup-test-\(suffix).png")
        render(addRepoInstantUpdates(), scheme, to: "add-repo-instant-updates-\(suffix).png")
        render(addRepoInstantUpdates(steps: AddRepoStep.allCases), scheme, to: "add-repo-instant-updates-six-steps-\(suffix).png")
        render(addRepoSixSteps(), scheme, to: "add-repo-six-steps-\(suffix).png")
        // The pull request page (TP-961): #448 at 1200 and 960 pt, then its states.
        render(pullRequestPage(pullRequest()), scheme, to: "pr-page-\(suffix).png")
        render(pullRequestPage(pullRequest(), window: 960), scheme, to: "pr-page-960-\(suffix).png")
        render(pullRequestPage(nil), scheme, to: "pr-page-loading-\(suffix).png")
        render(pullRequestPage(mergedPullRequest), scheme, to: "pr-page-merged-\(suffix).png")
        render(pullRequestPage(closedPullRequest), scheme, to: "pr-page-closed-\(suffix).png")
        render(pullRequestPage(unavailablePullRequest), scheme, to: "pr-page-github-unavailable-\(suffix).png")
        render(pullRequestPage(untrackedPullRequest), scheme, to: "pr-page-untracked-\(suffix).png")
        render(pullRequestPage(.notFound), scheme, to: "pr-page-not-found-\(suffix).png")
    }
}

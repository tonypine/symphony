// The Component Gallery's stories: every shared component in each of its kinds, sizes and states, and the sections
// and pages built from them, each drawn from made-up inputs or a committed fixture. Nothing here is a picture: a
// story is a view, written once with the piece of UI it shows, and drawn when someone looks (GalleryApp.swift).
// `make gallery` compiles this folder with the app's views. Each `render(view, scheme, to: "<story>-<scheme>.png")`
// below names one story.
import AppKit
import ImageIO
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI
import UniformTypeIdentifiers

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
// The fixture's clock, in UTC: its earlier call, at 05:48 that day, reads as today's.
NSTimeZone.default = TimeZone(identifier: "UTC")!
let now = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!
let fixture = here.appendingPathComponent("../Tests/Fixtures/director-app/inbox-decision/api/v1/inbox.json").standardizedFileURL

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
let watchAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/pr-watch/api/v1").standardizedFileURL
let watchState = try Data(contentsOf: watchAPI.appendingPathComponent("state.json"))
let watchNow = ISO8601DateFormatter().date(from: "2026-10-16T12:04:12Z")!
guard let watchInbox = InboxPayload.decode(try Data(contentsOf: watchAPI.appendingPathComponent("inbox.json"))) else {
    fatalError("The PR and CI fixture's Inbox doesn't read")
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

// Setup (TP-910): SU3–SU9 from the Setup QA fixture, at its clock.
let setupAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/setup/api/v1").standardizedFileURL
let setupConfig = here.appendingPathComponent("../Tests/Fixtures/director-app/setup/config/symphony.yml").standardizedFileURL
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
    let url = here.appendingPathComponent("../Tests/Fixtures/director-app/\(fixture)/api/v1/setup/\(file)").standardizedFileURL
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
    let state = here.appendingPathComponent("../Tests/Fixtures/director-app/\(name)/api/v1/state.json").standardizedFileURL
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

/// A healthy Setup page with the Linear webhooks line for `health` (nil from an older Symphony), beside the sidebar of
/// a `window` pt wide window (TP-1212).
@MainActor
func linearWebhooksPage(_ health: LinearWebhookHealth?, window: CGFloat = 1440) -> some View {
    let utc = TimeZone(identifier: "UTC")!
    return SetupPageBody(
        page: SetupPage(payload: SetupPayload(checkedAt: githubNow), now: githubNow, timeZone: utc),
        githubUpdates: GitHubUpdatesCard(section: githubSection("github-updates"), now: githubNow, timeZone: utc),
        linearWebhooks: LinearWebhooksLine(health: health, now: githubNow)
    )
    .frame(width: window - DesignTokens.Layout.sidebarWidth)
    .background(DesignTokens.Surface.window.color)
}

/// The Linear webhooks line's states, by snapshot name.
let linearWebhookStates: [(String, LinearWebhookHealth?)] = [
    ("off", LinearWebhookHealth()),
    ("waiting", LinearWebhookHealth(enabled: true, secretConfigured: true)),
    ("arriving", LinearWebhookHealth(enabled: true, secretConfigured: true, total: 1_204, lastAt: githubNow.addingTimeInterval(-12))),
    ("refused", LinearWebhookHealth(
        enabled: true, secretConfigured: true, total: 3, rejected: 2, lastAt: githubNow.addingTimeInterval(-12),
        lastRejectedAt: githubNow.addingTimeInterval(-240), lastRejectedReason: "bad_signature"
    )),
    ("no-secret", LinearWebhookHealth(enabled: true)),
    ("not-available", nil),
]

/// A healthy Setup page with the Dispatch shadow line for `report` (nil from an older Symphony) under the Linear
/// webhooks line, beside the sidebar of a `window` pt wide window, its last differences open or closed (TP-1220).
@MainActor
func dispatchShadowPage(_ report: DispatchShadowReport?, expanded: Bool = false, window: CGFloat = 1440) -> some View {
    let utc = TimeZone(identifier: "UTC")!
    return SetupPageBody(
        page: SetupPage(payload: SetupPayload(checkedAt: githubNow), now: githubNow, timeZone: utc),
        githubUpdates: GitHubUpdatesCard(section: githubSection("github-updates"), now: githubNow, timeZone: utc),
        linearWebhooks: LinearWebhooksLine(health: linearWebhookStates[2].1, now: githubNow),
        dispatchShadow: DispatchShadowLine(report: report, now: githubNow),
        dispatchShadowExpanded: expanded
    )
    .frame(width: window - DesignTokens.Layout.sidebarWidth)
    .background(DesignTokens.Surface.window.color)
}

/// Ten differences, as many as Symphony keeps, newest first.
let dispatchShadowDifferences: [DispatchShadowReport.Difference] = (0..<10).map { index in
    let at = githubNow.addingTimeInterval(TimeInterval(-12 - index * 90))
    switch index % 3 {
    case 0: return .init(identifier: "TP-\(1221 + index)", side: .both, field: "priority", poll: "1", record: "2", at: at)
    case 1: return .init(identifier: "TP-\(1221 + index)", side: .record, field: "candidate", record: "Todo", at: at)
    default: return .init(identifier: "TP-\(1221 + index)", side: .poll, field: "candidate", poll: "In Progress", at: at)
    }
}

/// The Dispatch shadow line's states, by snapshot name, and whether the last differences are open.
let dispatchShadowStates: [(String, DispatchShadowReport?, Bool)] = [
    ("not-available", nil, false),
    ("poll-zero", DispatchShadowReport(cyclesCompared: 140, windowCycles: 20), false),
    ("poll-zero-open", DispatchShadowReport(cyclesCompared: 140, windowCycles: 20), true),
    ("poll-differences", DispatchShadowReport(
        cyclesCompared: 1_204, cyclesWithDifferences: 7, windowCycles: 20, windowDifferences: 12, recent: dispatchShadowDifferences
    ), false),
    ("poll-differences-open", DispatchShadowReport(
        cyclesCompared: 1_204, cyclesWithDifferences: 7, windowCycles: 20, windowDifferences: 12, recent: dispatchShadowDifferences
    ), true),
    ("record-open", DispatchShadowReport(
        source: .record, cyclesCompared: 3_410, cyclesWithDifferences: 7, windowCycles: 20, windowDifferences: 1,
        recent: Array(dispatchShadowDifferences.prefix(2))
    ), true),
]

/// A healthy Setup page with the Reconcile line for `report` (nil from an older Symphony) under the Dispatch shadow line,
/// beside the sidebar of a `window` pt wide window, its last drift open or closed (TP-1228).
@MainActor
func reconcilePage(_ report: ReconcileReport?, expanded: Bool = false, window: CGFloat = 1440) -> some View {
    let utc = TimeZone(identifier: "UTC")!
    return SetupPageBody(
        page: SetupPage(payload: SetupPayload(checkedAt: githubNow), now: githubNow, timeZone: utc),
        githubUpdates: GitHubUpdatesCard(section: githubSection("github-updates"), now: githubNow, timeZone: utc),
        linearWebhooks: LinearWebhooksLine(health: linearWebhookStates[2].1, now: githubNow),
        dispatchShadow: DispatchShadowLine(report: dispatchShadowStates[5].1, now: githubNow),
        reconcile: ReconcileLine(report: report, now: githubNow),
        reconcileExpanded: expanded
    )
    .frame(width: window - DesignTokens.Layout.sidebarWidth)
    .background(DesignTokens.Surface.window.color)
}

/// The repositories a running Symphony lists (TP-1238): web-shop paused this morning with the Director's reason, the
/// others dispatching.
let repositoryPauses: [RepoPauseControl] = [
    RepoPauseControl(
        key: "web-shop", state: .paused(reasons: ["focusing on Symphony this week"], since: githubNow.addingTimeInterval(-3_600)),
        now: githubNow, timeZone: TimeZone(identifier: "UTC")!
    ),
    RepoPauseControl(key: "api", state: .dispatching),
    RepoPauseControl(key: "symphony", state: .dispatching),
]

/// A healthy Setup page with its Repositories card, beside the sidebar of a `window` pt wide window (TP-1238).
@MainActor
func repositoriesPage(window: CGFloat = 1440) -> some View {
    let utc = TimeZone(identifier: "UTC")!
    return SetupPageBody(
        page: SetupPage(payload: SetupPayload(checkedAt: githubNow), now: githubNow, timeZone: utc),
        linearWebhooks: LinearWebhooksLine(health: linearWebhookStates[2].1, now: githubNow),
        repositories: repositoryPauses
    )
    .frame(width: window - DesignTokens.Layout.sidebarWidth)
    .background(DesignTokens.Surface.window.color)
}

/// The Repos window's Dispatch section for each repository, in a detail column `width` pt wide: the narrowest window
/// (720 pt less its 220 pt sidebar) and a laptop-wide one.
@MainActor
func repoPauseSection(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
        ForEach(repositoryPauses) { control in
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                Text("\(control.key) · \(RepoPauseControl.sectionTitle)").font(.headline)
                RepoPauseView(control: control, send: { _ in true })
                    .padding(DesignTokens.Space.s3)
                    .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
            }
        }
    }
    .padding(20)
    .frame(width: width, alignment: .leading)
    .background(DesignTokens.Surface.window.color)
}

/// The Repos window's sidebar rows from the `repo-paused` fixture QA walks (TP-1238): symphony, the default, paused
/// with an agent running, then api and docs, in a row as wide as a 200 pt sidebar leaves it.
@MainActor
func repoPausedSidebar() -> some View {
    let api = here.appendingPathComponent("../Tests/Fixtures/director-app/repo-paused/api/v1").standardizedFileURL
    let stateData = try! Data(contentsOf: api.appendingPathComponent("state.json"))
    guard case let .state(snapshot) = SymphonyState.poll(data: stateData, statusCode: 200) else {
        fatalError("the repo-paused fixture doesn't read as a state")
    }
    let window = ReposList.window(
        status: .running(snapshot, external: false),
        poll: ReposAPI.poll(data: try! Data(contentsOf: api.appendingPathComponent("repos.json")), statusCode: 200),
        config: ReposConfig(path: "", repos: .noPath), now: githubNow,
        isDirectory: { _ in false }, cloneRemoval: { _ in .blocked("") }
    )
    return VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
        ForEach(window.repos) { repo in
            // The default repo drawn selected, as the sidebar list draws it: its Default and Paused badges take the
            // catalog's selected form on the accent (TP-1506).
            let selected = repo.isDefault
            RepoSidebarRow(repo: repo)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(selected ? Color.accentColor : Color.clear)
                .environment(\.backgroundProminence, selected ? .increased : .standard)
        }
    }
    .frame(width: DesignTokens.Layout.sidebarWidth - 2 * DesignTokens.Space.s3, alignment: .leading)
    .padding(DesignTokens.Space.s3)
    .background(DesignTokens.Surface.window.color)
}

/// The sidebar's five destinations (TP-1455), Factory's pages under it: with Home's waiting-on-you count and Factory's
/// setup problems, and with neither.
@MainActor
func destinationsSidebar() -> some View {
    func column(waiting: Int, setup: SetupSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(Sidebar().items, id: \.self) { item in
                switch item {
                case let .destination(destination):
                    SidebarRowContent(
                        title: destination.title, symbol: destination.symbol,
                        badge: destination.badge(waitingOnYou: waiting, setup: setup)
                    )
                case let .page(page):
                    SidebarRowContent(title: page.title, symbol: page.symbol, badge: nil, indented: true)
                }
            }
        }
        .frame(width: DesignTokens.Layout.sidebarWidth - 2 * DesignTokens.Space.s3, alignment: .leading)
        .padding(DesignTokens.Space.s3)
    }
    return HStack(alignment: .top, spacing: DesignTokens.Space.s6) {
        column(waiting: 4, setup: SetupSummary(errors: 1, warnings: 2))
        column(waiting: 0, setup: SetupSummary())
    }
    .background(DesignTokens.Surface.window.color)
}

/// Ten drifts, as many as Symphony keeps, newest first; every third move back failed.
let reconcileDrifts: [ReconcileReport.Drift] = (0..<10).map { index in
    let at = githubNow.addingTimeInterval(TimeInterval(-40 - index * 120))
    let phases = [("Code Review", "Done"), ("QA", "In Progress"), ("Merging", "Todo")][index % 3]
    return .init(
        identifier: "TP-\(1300 + index)", recordPhase: phases.0, linearPhase: phases.1,
        outcome: index % 3 == 2 ? .failed : .reverted, at: at
    )
}

/// The Reconcile line's states, by snapshot name, and whether the last drift is open.
let reconcileStates: [(String, ReconcileReport?, Bool)] = [
    ("not-available", nil, false),
    ("waiting", ReconcileReport(), false),
    ("clean-open", ReconcileReport(lastRunAt: githubNow.addingTimeInterval(-120), applied: 14), true),
    ("reverted", ReconcileReport(
        lastRunAt: githubNow.addingTimeInterval(-60), applied: 2, detected: 1, reverted: 1, recent: [reconcileDrifts[0]]
    ), false),
    ("reverted-open", ReconcileReport(
        lastRunAt: githubNow.addingTimeInterval(-60), applied: 2, detected: 1, reverted: 1, recent: [reconcileDrifts[0]]
    ), true),
    ("failing-open", ReconcileReport(
        lastRunAt: githubNow.addingTimeInterval(-30), applied: 1_204, reapplied: 3, unobservedFilled: 12,
        detected: 31, reverted: 28, revertFailed: 3, recent: reconcileDrifts
    ), true),
]

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
    let url = here.appendingPathComponent("../Tests/Fixtures/director-app/\(fixture)/api/v1/setup/\(file)").standardizedFileURL
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
let pullRequestAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/pull-request/api/v1").standardizedFileURL
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
    let api = here.appendingPathComponent("../Tests/Fixtures/director-app/inbox/api/v1/inbox.json").standardizedFileURL
    guard let plan = InboxPayload.decode(try! Data(contentsOf: api))?.items.first(where: { $0.identifier == "SHOP-330" }) else {
        fatalError("SHOP-330 is missing from \(api.path)")
    }
    let picks = DecisionPicks(picks: [1: plan.review.questions[1].writeInIndex], writeIns: [1: "Ask the finance team which currency the books use, then pick."])
    return review(plan, width: 640, picks: picks)
}

/// SHOP-330 with two answers Symphony hasn't revised the plan from yet (TP-1202): the warning above its questions.
@MainActor
func planUnapplied() -> some View {
    let api = here.appendingPathComponent("../Tests/Fixtures/director-app/inbox/api/v1/inbox.json").standardizedFileURL
    guard var plan = InboxPayload.decode(try! Data(contentsOf: api))?.items.first(where: { $0.identifier == "SHOP-330" }) else {
        fatalError("SHOP-330 is missing from \(api.path)")
    }
    plan.review.unappliedAnswers = 2
    return review(plan, width: 640)
}

/// SHOP-330 of the `inbox-unasked-choices` fixture: choices its plan run could not ask.
@MainActor
func unaskedPlan() -> InboxItem {
    let api = here.appendingPathComponent("../Tests/Fixtures/director-app/inbox-unasked-choices/api/v1/inbox.json").standardizedFileURL
    guard let plan = InboxPayload.decode(try! Data(contentsOf: api))?.items.first(where: { $0.identifier == "SHOP-330" }) else {
        fatalError("SHOP-330 is missing from \(api.path)")
    }
    return plan
}

/// The plan's page: the warning says which choices were not asked, and the plan never reads as fully asked.
@MainActor
func planUnasked() -> some View {
    review(unaskedPlan(), width: 640)
}

/// The Approve sheet of the same plan, which says the same before the plan is approved.
@MainActor
func planUnaskedApprove() -> some View {
    ConsequenceSheetView(
        sheet: ConsequenceSheet(move: .approvePlan, item: unaskedPlan()), working: false, error: nil, cancel: {}, confirm: { _ in }
    )
    .background(DesignTokens.Surface.content.color)
}

// The ticket ledger's fixture (TP-1193, TP-1195): SHOP-410 with its events feed, and against an older Symphony without.
let ledgerAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/ticket-ledger/api/v1").standardizedFileURL
let ledgerNow = ISO8601DateFormatter().date(from: "2026-10-18T11:20:00Z")!

// A run's steps (TP-1413): SHOP-410 with a step history, its failed tests' output listed and its build's gone.
let stepsAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/ticket-steps/api/v1").standardizedFileURL

// The paused line (TP-1244): the `paused-ticket` fixture's tickets with one, two and three pause reasons.
let pausedAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/paused-ticket/api/v1").standardizedFileURL
let inboxPausedAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/inbox-paused/api/v1").standardizedFileURL

/// A blocked Inbox row's review reading its ticket's pause (TP-1253), in a window `window` pt wide: what is left
/// beside the sidebar and the list column, at the laptop viewport (1440) and the desktop one (2560).
@MainActor
func blockedReview(_ identifier: String, window: CGFloat) -> some View {
    guard let inbox = InboxPayload.decode(try! Data(contentsOf: inboxPausedAPI.appendingPathComponent("inbox.json")))?
        .withPauses(fromState: try? Data(contentsOf: inboxPausedAPI.appendingPathComponent("state.json"))),
        let item = inbox.items.first(where: { $0.identifier == identifier })
    else { fatalError("\(identifier) is missing from the paused Inbox fixture") }
    return review(item, width: window - DesignTokens.Layout.sidebarWidth - DesignTokens.Layout.listColumnWidth)
}

// Move to… (TP-1328): the `parked-backlog` fixture's SHOP-430, parked in Backlog by the dispatch loop.
let parkedAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/parked-backlog/api/v1").standardizedFileURL

/// The sheet Move to… → In Progress opens on SHOP-430, with the walkthrough's note typed.
@MainActor
func moveSheet(error: String? = nil) -> some View {
    let sheet = MoveSheet(identifier: "SHOP-430", from: "Backlog", to: MachinePhase(name: "In Progress", dispatches: true))
    return MoveSheetView(sheet: sheet, working: false, error: error, note: "resume with the work", cancel: {}, confirm: { _ in })
        .background(DesignTokens.Surface.window.color)
}

// Start now (TP-1330): the `start-now` fixture's SHOP-320, a Todo ticket waiting while every slot is busy, and the
// `start-now-paused` fixture's, on a paused Symphony.
let startAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/start-now/api/v1").standardizedFileURL
let startPausedAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/start-now-paused/api/v1").standardizedFileURL

/// Start Now disabled for each reason Symphony refuses a start with, the reason under it (also its tooltip).
@MainActor
func startDisabledReasons() -> some View {
    let reasons = [
        "dispatch is paused by the operator: Deploy freeze",
        "the repository is paused by you since 2026-10-07 14:03 UTC: Release branch cut",
        "a Question is waiting for an answer",
        "a run is already working on the ticket",
        "the ticket is in Backlog; move it first",
        "the ticket is Done; only an open ticket can be started",
        "the ticket's plan waits on a person",
        "the ticket waits on its sub-tickets",
    ]
    return VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
        ForEach(reasons, id: \.self) { reason in
            let start = TicketStart(allowed: false, reason: reason)
            Button(TicketStart.title) {}
                .accessibilityLabel(start.accessibilityLabel("SHOP-320"))
                .directorButton(disabledReason: start.help("SHOP-320"))
        }
    }
    .padding(DesignTokens.Space.s5)
    .frame(width: 760, alignment: .leading)
    .background(DesignTokens.Surface.window.color)
}

// The shared styles (TP-1438): one state per snapshot, each on the content surface with room for the focus ring.

/// The states a style is drawn in, by the name its snapshot takes.
let interactionStates: [(String, DesignTokens.Interaction)] = [
    ("rest", .rest), ("hover", .hover), ("pressed", .press), ("selected", .selection), ("focused", .focus),
]

@MainActor
func styleStage(_ view: some View, width: CGFloat = 360) -> some View {
    view
        .padding(DesignTokens.Space.s5)
        .frame(width: width, alignment: .leading)
        .background(DesignTokens.Surface.content.color)
}

/// A ticket row as today's lists draw it, in the row's face.
@MainActor
func styledRow(_ state: DesignTokens.Interaction, reduceMotion: Bool = false) -> some View {
    styleStage(
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            DesignTokens.SituationKind.ci.glyph
            VStack(alignment: .leading, spacing: 2) {
                Text("SHOP-305 · Checkout total rounding").font(DesignTokens.TypeStyle.rowTitle.font)
                Text("Checks are running on PR #741.").font(DesignTokens.TypeStyle.secondary.font).foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.Space.s2)
            Text("6 min").font(DesignTokens.TypeStyle.secondary.font).monospacedDigit().foregroundStyle(.secondary)
        }
        .modifier(RowFace(state: state, reduceMotion: reduceMotion))
    )
}

/// A clickable card, in the card's face; `reduceMotion` keeps a hovered card down and a pressed one at full size.
@MainActor
func styledCard(_ state: DesignTokens.Interaction, reduceMotion: Bool = false) -> some View {
    styleStage(
        Panel {
            Text("Answer in my own words").textStyle(.heading)
            Text("Tell the agent what to do instead.").font(DesignTokens.TypeStyle.secondary.font).foregroundStyle(.secondary)
        }
        .modifier(CardFace(state: state, reduceMotion: reduceMotion)),
        width: 400
    )
    .padding(DesignTokens.Space.s2)
    .background(DesignTokens.Surface.content.color)
}

/// A button of each kind side by side, in one state; `reduceMotion` keeps a pressed one at full size.
@MainActor
func styledButtons(_ state: DesignTokens.Interaction, reduceMotion: Bool = false) -> some View {
    styleStage(
        HStack(spacing: DesignTokens.Space.s3) {
            ButtonFace(label: Text("Approve Plan"), kind: .primary, state: state, reduceMotion: reduceMotion)
            ButtonFace(label: Text("Restart…"), kind: .secondary, state: state, reduceMotion: reduceMotion)
            ButtonFace(label: Text("Show All"), kind: .quiet, state: state, reduceMotion: reduceMotion)
        },
        width: 400
    )
}

/// The three control sizes, a primary and a secondary button at each.
@MainActor
func controlSizes() -> some View {
    styleStage(
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            ForEach(DesignTokens.Control.allCases, id: \.self) { size in
                HStack(spacing: DesignTokens.Space.s3) {
                    Text("\(size.rawValue.capitalized), \(Int(size.height)) pt")
                        .font(DesignTokens.TypeStyle.label.font)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    ButtonFace(label: Text("Send"), kind: .primary, size: size, state: .rest, reduceMotion: false)
                    ButtonFace(label: Text("Save Note"), kind: .secondary, size: size, state: .rest, reduceMotion: false)
                }
            }
        },
        width: 400
    )
}

/// A button off for a reason, pressed once: the reason shows under it.
@MainActor
func disabledWithReason() -> some View {
    styleStage(
        Button("Approve and Merge…") {}
            .directorButton(.primary)
            .disabledReason("Checks are still running on PR #812."),
        width: 400
    )
}

// MARK: - Panel, zone title and chip (TP-1484)

/// A component on the window surface, as the catalog's canvas draws it.
@MainActor
func componentStage(_ view: some View, width: CGFloat) -> some View {
    view
        .padding(DesignTokens.Space.s6)
        .frame(width: width, alignment: .leading)
        .background(DesignTokens.Surface.window.color)
}

/// The catalog's panel under its zone title: a facts panel, a zone title with a note over its panel, and a card (a
/// titled panel with its hint as the note).
@MainActor
func panelStories() -> some View {
    componentStage(
        VStack(alignment: .leading, spacing: DesignTokens.Space.s6) {
            TitledPanel(title: "Pull request") {
                Text("PR #812 · checks passing").textStyle(.body)
                Text("9 files · +505 −52").textStyle(.secondary).foregroundStyle(DesignTokens.TextColor.secondary.color)
            }
            VStack(alignment: .leading, spacing: ZoneTitle.gap) {
                ZoneTitle("Timeline", note: "8 new since you looked at 16:50")
                Panel { Text("Implementation run 2 opened PR #812.").textStyle(.body) }
            }
            Card(title: "What happened") {
                Text("Code Review sent PR #812 back once: the timeline missed the run that was stopped. Run 2 added it, and the checks pass.")
                    .textStyle(.body)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        },
        width: 520
    )
}

/// The catalog's Chip stories (Status, Status working, Repo, Epic, Label), a plain chip, and a status chip of every
/// status.
let chipStories: [(id: String, text: String, kind: Chip.Kind)] = [
    ("status", "Waiting on you", .status(.you)),
    ("status-working", "Working", .status(.working)),
    ("repo", "symphony", .repo),
    ("epic", "Phase 3b · The Director redesigned", .epic),
    ("label", "qa:skip", .label(.idle)),
]

@MainActor
func chipVariants() -> some View {
    componentStage(
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            HStack(spacing: DesignTokens.Space.s2) {
                ForEach(chipStories, id: \.id) { story in Chip(story.text, kind: story.kind) }
                Chip("design")
            }
            HStack(spacing: DesignTokens.Space.s2) {
                ForEach(DesignTokens.Status.allCases, id: \.self) { status in Chip(status.word, kind: .status(status)) }
            }
        },
        width: 820
    )
}

/// The ten situation kinds, each with its glyph in its status color and its word, in the order that picks one.
@MainActor
func situationKinds() -> some View {
    styleStage(
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(DesignTokens.SituationKind.allCases, id: \.self) { kind in
                Label {
                    Text(kind.word).font(DesignTokens.TypeStyle.rowTitle.font)
                } icon: {
                    kind.glyph
                }
            }
        }
    )
}

/// The Situation line (TP-1439): `test/fixtures/api/situations.json`, one ticket per kind, at the fixture's clock.
let situationSample: (now: Date, lines: [Situation]) = {
    let url = here.appendingPathComponent("../../../test/fixtures/api/situations.json").standardizedFileURL
    guard let root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
          let now = (root["now"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }),
          let issues = root["issues"] as? [[String: Any]]
    else { fatalError("Could not read \(url.path)") }
    return (now, issues.compactMap { Situation.decode(object: $0["situation"]) })
}()

/// Every kind's line in one size, in the order of the design's table.
@MainActor
func situationLines(_ size: SituationLine.Size) -> some View {
    styleStage(
        VStack(alignment: .leading, spacing: size == .full ? DesignTokens.Space.s4 : DesignTokens.Space.s3) {
            ForEach(Array(situationSample.lines.enumerated()), id: \.offset) { _, situation in
                SituationLine(situation, reference: situationSample.now, size: size)
            }
        },
        width: size == .full ? 900 : 640
    )
}

/// A forced ticket's line in both sizes, a pause with two more reasons, and both sizes in a narrow column, where the
/// cause wraps and the word stays whole.
@MainActor
func situationLineExtras() -> some View {
    let ci = situationSample.lines.first { $0.kind == .ci }!
    var paused = situationSample.lines.first { $0.kind == .paused }!
    paused.andMore = 2
    return styleStage(
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            SituationLine(ci, reference: situationSample.now, size: .full, forced: true)
            SituationLine(ci, reference: situationSample.now, size: .compact, forced: true)
            SituationLine(paused, reference: situationSample.now, size: .full)
            SituationLine(paused, reference: situationSample.now, size: .compact)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                SituationLine(situationSample.lines[0], reference: situationSample.now, size: .full)
                SituationLine(situationSample.lines[0], reference: situationSample.now, size: .compact)
            }
            .frame(width: 420, alignment: .leading)
        },
        width: 900
    )
}

// The Situation line everywhere (TP-1441): each list that names a ticket, from the fixtures' states at their clock.
let situationsAPI = here.appendingPathComponent("../Tests/Fixtures/director-app").standardizedFileURL
let situationsNow = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!

func situationsState(_ name: String) -> OverviewState {
    guard let state = OverviewState.decode(try! Data(contentsOf: situationsAPI.appendingPathComponent("\(name)/api/v1/state.json"))) else {
        fatalError("The \(name) fixture's state doesn't read")
    }
    return state
}

/// Tickets: the Situation column of each row, as the table draws it (a `Table` doesn't render offscreen), and the
/// inspector of a forced ticket beside it.
@MainActor
func ticketsSituations() -> some View {
    let list = TicketList(state: situationsState("tickets"), now: situationsNow, timeZone: TimeZone(identifier: "UTC")!)
    return styleStage(
        HStack(alignment: .top, spacing: DesignTokens.Space.s5) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    let selected = row.identifier == "SHOP-301"
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
                        Text(row.identifier).font(DesignTokens.TypeStyle.mono.font).frame(width: 90, alignment: .leading)
                        Text(row.titleText).lineLimit(1).frame(width: 180, alignment: .leading)
                        SituationLine(row.line, reference: list.reference, size: .compact).lineLimit(1)
                    }
                    .padding(.vertical, DesignTokens.Space.s1)
                    // SHOP-301 drawn selected, as the table draws it: white text on the accent, the word included.
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(selected ? Color.accentColor : Color.clear)
                    .environment(\.backgroundProminence, selected ? .increased : .standard)
                }
            }
            .frame(width: 900)
            TicketInspectorBody(row: list.row("SHOP-325")!, reference: list.reference, actions: TicketsActions())
                .frame(width: 300)
        },
        width: 1260
    )
}

/// Initiatives: BIL-200's sub-tickets, each with its line, the finished blockers struck through with their dates.
@MainActor
func initiativesSituations() -> some View {
    guard let payload = InitiativesPayload.decode(try! Data(contentsOf: situationsAPI.appendingPathComponent("inbox/api/v1/initiatives.json"))) else {
        fatalError("The inbox fixture's initiatives don't read")
    }
    let list = InitiativesList(initiatives: payload.initiatives, state: situationsState("inbox").snapshot)
    return VStack(alignment: .leading, spacing: 0) {
        ForEach(list.active) { initiative in
            InitiativeDetail(initiative: initiative, actions: InitiativeActions(), reference: situationsNow)
        }
    }
    .frame(width: 960)
    .background(DesignTokens.Surface.content.color)
}

// Initiatives as the epic's story (TP-1458): the `initiative-story` fixture's TP-1381 mid-chain, SHOP-500 done and
// BIL-300 with a canceled sub-ticket, as the tab draws them beside the list at the laptop's and the desktop's widths.
let storyAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/initiative-story/api/v1").standardizedFileURL

/// `identifier`'s story beside the Initiatives list, in a window `window` pt wide less its sidebar.
@MainActor
func initiativeStory(_ identifier: String, window: CGFloat) -> some View {
    func read(_ name: String) -> Data { try! Data(contentsOf: storyAPI.appendingPathComponent(name)) }
    guard let payload = InitiativesPayload.decode(read("initiatives.json")), let state = OverviewState.decode(read("state.json")),
          let records = TicketsPayload.decode(read("tickets.json"))?.rows
    else { fatalError("The initiative-story fixture doesn't read") }
    let list = InitiativesList(initiatives: payload.initiatives, state: state.snapshot)
    guard let initiative = list.ordered.first(where: { $0.identifier == identifier }) else { fatalError("\(identifier) is missing") }
    var connected: [String: TicketConnected] = [:]
    for ticket in initiative.subTickets {
        if let data = try? Data(contentsOf: storyAPI.appendingPathComponent("\(ticket.identifier).json")) {
            connected[ticket.identifier] = TicketFactsRead.decode(data)?.connected
        }
    }
    let reference = state.generatedAt ?? Date()
    let story = InitiativeStory(initiative: initiative, records: records, connected: connected, order: state.order, reference: reference)
    return HStack(alignment: .top, spacing: 0) {
        InitiativesListRows(list: list, selected: initiative.id, select: { _ in })
            .frame(width: DesignTokens.Layout.listColumnWidth, alignment: .top)
            .background(DesignTokens.Surface.content.color)
        Divider()
        InitiativeDetail(initiative: initiative, story: story, actions: InitiativeActions(), reference: reference)
    }
    .frame(width: window - DesignTokens.Layout.sidebarWidth, alignment: .top)
    .background(DesignTokens.Surface.content.color)
}

/// The Inbox: TP-892's context card with its line and its connected tickets' lines.
@MainActor
func inboxContextSituations() -> some View {
    InboxReviewBody(item: item, perform: { _ in }, now: now, state: situationsState("inbox-decision").snapshot)
        .frame(width: 900)
        .background(DesignTokens.Surface.content.color)
}

/// The menu bar: each Waiting on you item as the status menu titles it, with its kind's symbol.
@MainActor
func menuWaitingSituations() -> some View {
    let tickets = situationsState("inbox-decision").snapshot.waitingOnYou + situationsState("inbox").snapshot.waitingOnYou
    return styleStage(
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(StatusMenu.waitingTitle).foregroundStyle(.secondary)
            ForEach(Array(tickets.enumerated()), id: \.offset) { _, ticket in
                Label(StatusMenu.waitingLine(ticket), systemImage: ticket.situation?.kind.symbol ?? ticket.kind.symbol)
            }
        },
        width: 640
    )
}

/// Home's board (TP-1453) from `fixture`'s dispatch order, in a window `window` wide less its sidebar: every group
/// populated (`home`, SHOP-320 picked) or most empty with dispatch paused (`home-quiet`).
@MainActor
func homeBoard(_ fixture: String, window: CGFloat, selection: String? = nil) -> some View {
    let width = window - DesignTokens.Layout.sidebarWidth
    return HomeBody(
        board: HomeBoard(state: situationsState(fixture), now: situationsNow, timeZone: TimeZone(identifier: "UTC")!),
        actions: HomeActions(),
        selection: selection
    )
    .frame(width: width, alignment: .topLeading)
    .background(DesignTokens.Surface.window.color)
}

/// Home's top (TP-1454): the `home-questions` fixture's Inbox, two questions and a pause, read as the window reads it.
let homeQuestionsAPI = situationsAPI.appendingPathComponent("home-questions/api/v1")
let homeQuestionsInbox: InboxPayload = {
    guard let inbox = InboxPayload.decode(try! Data(contentsOf: homeQuestionsAPI.appendingPathComponent("inbox.json"))) else {
        fatalError("The home-questions fixture's Inbox doesn't read")
    }
    return inbox.withPauses(fromState: try? Data(contentsOf: homeQuestionsAPI.appendingPathComponent("state.json")))
}()

/// Home with the questions and the pause above the board, in a window `window` wide less its sidebar.
@MainActor
func homeWithQuestions(window: CGFloat) -> some View {
    let width = window - DesignTokens.Layout.sidebarWidth
    return HomeBody(
        board: HomeBoard(state: situationsState("home-questions"), now: situationsNow, timeZone: TimeZone(identifier: "UTC")!),
        actions: HomeActions(),
        inbox: HomeInbox(items: homeQuestionsInbox.items),
        now: situationsNow
    )
    .frame(width: width, alignment: .topLeading)
    .background(DesignTokens.Surface.window.color)
}

/// The Inbox's drawer beside Home: TP-892's review, at the drawer's ideal width.
@MainActor
func inboxDrawer() -> some View {
    guard let item = homeQuestionsInbox.items.first(where: { $0.identifier == "TP-892" }) else { fatalError("TP-892 is missing") }
    return VStack(spacing: 0) {
        InboxDrawerHeader(title: HomeInbox.drawerTitle, close: {})
        Divider()
        InboxReviewBody(item: item, perform: { _ in }, narrow: true, now: situationsNow, state: situationsState("home-questions").snapshot)
    }
    .frame(width: HomeInbox.drawerIdealWidth)
    .background(DesignTokens.Surface.content.color)
}

/// The status bar at `window`'s width less the sidebar: the dispatch control at rest, under the pointer and pressed,
/// then the health line; dispatch on and Symphony answering, or paused, or Symphony stopped.
@MainActor
func statusBar(window: CGFloat) -> some View {
    let width = window - DesignTokens.Layout.sidebarWidth
    let build = DiagnosticsPayload.decode(try! Data(contentsOf: homeQuestionsAPI.appendingPathComponent("state.json")))?.build
    let utc = TimeZone(identifier: "UTC")!
    func bar(_ window: WindowState, _ state: String?, _ face: DesignTokens.Interaction) -> some View {
        let control = DispatchControl(
            window: window, paused: false, state: state.map(situationsState), now: situationsNow, timeZone: utc
        )
        let line = HealthLine(window: window, dispatch: control, build: build, appVersion: "0.0.1.866", lastUpdate: situationsNow, timeZone: utc)
        return StatusBarContent(line: line) {
            ButtonFace(label: DispatchControlLabel(control: control), kind: .quiet, size: .small, state: face, reduceMotion: false)
        }
        .frame(width: width)
    }
    return VStack(spacing: DesignTokens.Space.s3) {
        bar(.connected, "home-questions", .rest)
        bar(.connected, "home-questions", .hover)
        bar(.connected, "home-questions", .press)
        bar(.connected, "paused", .rest)
        bar(.stopped, nil, .rest)
    }
    .padding(.vertical, DesignTokens.Space.s3)
    .background(DesignTokens.Surface.content.color)
}

/// The Action rail (TP-1440): `test/fixtures/api/ticket_moves.json`, the `moves` of a few tickets, by name.
let actionRailSample: [String: TicketMoves] = {
    let url = here.appendingPathComponent("../../../test/fixtures/api/ticket_moves.json").standardizedFileURL
    guard let root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
          let tickets = root["tickets"] as? [[String: Any]]
    else { fatalError("Could not read \(url.path)") }
    var reads: [String: TicketMoves] = [:]
    for ticket in tickets {
        guard let name = ticket["name"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: ticket),
              let moves = TicketMoves.of(issue: data)
        else { fatalError("Could not read a ticket of \(url.path)") }
        reads[name] = moves
    }
    return reads
}()

/// A rail with every move the read can allow, allowed.
let everyMoveAllowed = TicketMoves(Dictionary(uniqueKeysWithValues: TicketActionRail.Move.allCases.map {
    ($0.rawValue, TicketMoveRead(allowed: true, states: $0 == .moveTo ? ["Todo", "Code Review", "Done"] : []))
}))

/// Each rail under a caption naming the ticket it is drawn for, at the laptop's header width (1180 pt) or the
/// desktop's (2200 pt).
@MainActor
func actionRails(_ rails: [(String, TicketMoves)], width: CGFloat, moreOpen: Bool = false) -> some View {
    styleStage(
        VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
            ForEach(Array(rails.enumerated()), id: \.offset) { _, rail in
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    Text(rail.0)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(.secondary)
                    ActionRail(rail: TicketActionRail(identifier: "TP-1", moves: rail.1), perform: { _ in },
                               moreOpen: moreOpen)
                }
            }
        },
        width: width
    )
}

/// Every move allowed.
@MainActor
func actionRailAllowed(width: CGFloat) -> some View {
    actionRails([("Every move allowed", everyMoveAllowed)], width: width)
}

/// Each refusal the read gives, its reason shown under its move, and More open on each.
@MainActor
func actionRailRefusals(width: CGFloat) -> some View {
    actionRails(
        [("A run is working", actionRailSample["working"]!), ("Waiting on you", actionRailSample["waiting_on_you"]!),
         ("Held for a person", actionRailSample["held"]!), ("Nothing running", actionRailSample["nothing_running"]!),
         ("Done", actionRailSample["done"]!)],
        width: width, moreOpen: true
    )
}

// MARK: - The Question block and the decision sheet (TP-1442)

/// TP-892's request with no option recommended, so nothing is picked to start with.
let unpickedAction: InboxReview.Action = {
    var open = action
    for index in open.options.indices { open.options[index].recommended = false }
    return open
}()

/// A second Question for the sheet: TP-892's options under another question.
let secondAction: InboxReview.Action = {
    var second = unpickedAction
    second.question = "Let TP-892 change the file that sets how agents work?"
    second.why = "The change needs one line in the file that sets how agents work. Agents may change it only when you say so."
    second.ifUnanswered = "TP-892 leaves the line out."
    return second
}()

/// TP-892's Question block at the laptop's column width, with its own Send under the cards.
@MainActor
func questionBlock(_ question: InboxReview.Action = action, picks: DecisionPicks = DecisionPicks(), width: CGFloat = 720) -> some View {
    QuestionBlock(action: question, picks: picks, narrow: width < DesignTokens.Layout.narrowReviewWidth, send: {})
        .padding(DesignTokens.Space.s5)
        .frame(width: width)
        .background(DesignTokens.Surface.window.color)
        .environment(\.mentionReferences, item.references)
}

/// TP-892's first option card in each of its states, and hovered and pressed again under Reduce Motion (no lift, no
/// settle).
@MainActor
func optionCardStates() -> some View {
    let card = OptionCard.cards(for: action, writeIn: true)[0]
    let states: [(String, DesignTokens.Interaction, Bool)] = [
        ("Rest", .rest, false), ("Hover", .hover, false), ("Pressed", .press, false), ("Selected", .selection, false),
        ("Focused", .focus, false), ("Hover, Reduce Motion", .hover, true), ("Pressed, Reduce Motion", .press, true),
    ]
    return VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
        ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(entry.0).font(DesignTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
                OptionCardFace(card: card, state: entry.1, showsKey: true, reduceMotion: entry.2)
            }
        }
    }
    .padding(DesignTokens.Space.s5)
    .frame(width: 640)
    .background(DesignTokens.Surface.window.color)
    .environment(\.mentionReferences, item.references)
}

/// The decision sheet over a dimmed laptop page, 520 pt on its right.
@MainActor
func decisionSheet(_ questions: [InboxReview.Action], picks: DecisionPicks = DecisionPicks()) -> some View {
    DesignTokens.Surface.content.color
        .frame(width: 1180, height: 900)
        .decisionSheet(isPresented: .constant(true)) {
            DecisionSheet(questions: questions, picks: picks, subtitle: "TP-892 · Remove the Final verification and Supervisor check flows",
                          pick: { _, _ in }, send: {}, close: {})
                .frame(height: 900)
        }
        .environment(\.mentionReferences, item.references)
}

// MARK: - The Run group and the Step list (TP-1443)

/// TP-1376's runs (`Tests/Fixtures/run-steps`): run 1 failed on its tests, run 2 is live on its tests step.
let runStepsFixtures = here.appendingPathComponent("../Tests/Fixtures/run-steps").standardizedFileURL
let runStepsReference = ISO8601DateFormatter().date(from: "2026-10-07T12:27:00Z")!

/// The fixture's step transcripts, kept as a read of each would keep them.
@MainActor
func runStepTranscripts() -> StepTranscripts {
    let transcripts = StepTranscripts { _ in .unreachable }
    for id in ["tr-code-1", "tr-tests-1", "tr-code-2"] {
        guard let data = try? Data(contentsOf: runStepsFixtures.appendingPathComponent("artifacts/\(id).ndjson")) else {
            fatalError("\(id) is missing from \(runStepsFixtures.path)")
        }
        transcripts.keep(TranscriptLine.lines(data), for: id)
    }
    return transcripts
}

/// Run 1 and run 2, the run now with the ticket read's step and lines.
let runStepGroups: [RunGroupModel] = {
    guard let events = try? Data(contentsOf: runStepsFixtures.appendingPathComponent("events.json")),
          let history = TicketEventsPayload.decode(events),
          let issue = try? Data(contentsOf: runStepsFixtures.appendingPathComponent("issue.json"))
    else { fatalError("The run steps fixture is missing from \(runStepsFixtures.path)") }
    return RunGroupModel.groups(history, runNow: RunNow.decode(issue: issue), liveTokens: 920_000, reference: runStepsReference)
}()

/// A run group in the laptop's main column.
@MainActor
func runGroup(_ run: RunGroupModel, unfolded: Bool? = nil) -> some View {
    RunGroup(run: run, transcripts: runStepTranscripts(), unfolded: unfolded)
        .padding(DesignTokens.Space.s5)
        .frame(width: 760)
        .background(DesignTokens.Surface.content.color)
}

// MARK: - The Timeline section (TP-1444)

/// Two days of a ticket with every class of entry (`Tests/Fixtures/timeline`): a move, a phase entered, a pause the
/// rules wrote as seven records, a question asked and answered, a person's action, a rule's, a verdict, a finding, a
/// note, a write recorded twice, run 1 that failed and the run now.
let timelineFixtures = here.appendingPathComponent("../Tests/Fixtures/timeline").standardizedFileURL
let timelineReference = ISO8601DateFormatter().date(from: "2026-10-08T10:27:00Z")!
let timelineCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

let timelineModel: TimelineModel = {
    guard let events = try? Data(contentsOf: timelineFixtures.appendingPathComponent("events.json")),
          let history = TicketEventsPayload.decode(events)
    else { fatalError("The timeline fixture is missing from \(timelineFixtures.path)") }
    return TimelineModel.build(history, reference: timelineReference, calendar: timelineCalendar)
}()

/// The timeline in a main column `width` wide: the laptop's (780 pt, the column's widest) or the desktop's (1040 pt,
/// where the column stops at 780 pt).
@MainActor
func timeline(width: CGFloat, selection: String? = nil, unfoldedRuns: Set<String>? = nil) -> some View {
    TimelineSection(
        model: timelineModel, transcripts: StepTranscripts { _ in .unreachable }, calendar: timelineCalendar,
        selection: selection, unfoldedRuns: unfoldedRuns
    )
    .padding(DesignTokens.Space.s5)
    .frame(width: width, alignment: .leading)
    .background(DesignTokens.Surface.content.color)
}

// MARK: - The Lifecycle section and the Phase path (TP-1445)

/// Three tickets (`Tests/Fixtures/lifecycle`): one mid-way, back in Rework with Code Review entered three times; one
/// Done; one in QA at 95 % of its cap.
let lifecycleFixtures = here.appendingPathComponent("../Tests/Fixtures/lifecycle").standardizedFileURL
let lifecycleReference = ISO8601DateFormatter().date(from: "2026-10-08T11:21:00Z")!
let lifecycleTickets = ["mid-way", "done", "near-cap"]

func lifecycleRead(_ name: String) -> TicketLifecycleRead {
    guard let data = try? Data(contentsOf: lifecycleFixtures.appendingPathComponent("\(name).json")),
          let read = TicketLifecycleRead.decode(data), read.lifecycle != nil, read.phasePath != nil
    else { fatalError("The lifecycle fixture \(name) is missing from \(lifecycleFixtures.path)") }
    return read
}

/// The Lifecycle section of `name` in a main column `width` wide: the laptop's (780 pt) or the desktop's (1040 pt).
@MainActor
func lifecycle(_ name: String, width: CGFloat) -> some View {
    let read = lifecycleRead(name)
    return LifecycleSection(model: LifecycleModel.build(read.lifecycle!, phase: read.phasePath?.current))
        .padding(DesignTokens.Space.s5)
        .frame(width: width + 2 * DesignTokens.Space.s5, alignment: .leading)
        .background(DesignTokens.Surface.window.color)
}

/// The three tickets' phase paths, in full and compact (a board row's preview, 340 pt), in a column `width` wide.
@MainActor
func phasePaths(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
        ForEach(lifecycleTickets, id: \.self) { name in
            let model = PhasePathModel.build(lifecycleRead(name).phasePath!, reference: lifecycleReference, calendar: timelineCalendar)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                Text(name).font(DesignTokens.TypeStyle.caption.font).foregroundStyle(.tertiary)
                PhasePath(model: model)
                PhasePath(model: model, compact: true).frame(width: 340, alignment: .leading)
            }
        }
    }
    .padding(DesignTokens.Space.s5)
    .frame(width: width, alignment: .leading)
    .background(DesignTokens.Surface.content.color)
}

// MARK: - The facts rail's Pull request and Connected panels (TP-1446)

/// Three tickets (`Tests/Fixtures/facts-rail`): a green PR and nothing connected; a red PR with three workflows; no PR
/// yet, in an epic, with one blocker resolved yesterday and one open.
let factsFixtures = here.appendingPathComponent("../Tests/Fixtures/facts-rail").standardizedFileURL
let factsReference = ISO8601DateFormatter().date(from: "2026-11-10T15:00:00Z")!
let factsTickets = ["green-pr", "red-pr", "blockers"]

/// The two panels of `name`'s facts rail, one under the other, `width` wide: the laptop's (340 pt) or the desktop's
/// (440 pt).
@MainActor
func factsRail(_ name: String, width: CGFloat) -> some View {
    guard let data = try? Data(contentsOf: factsFixtures.appendingPathComponent("\(name).json")),
          let read = TicketFactsRead.decode(data)
    else { fatalError("The facts rail fixture \(name) is missing from \(factsFixtures.path)") }
    return VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
        PullRequestPanel(model: PullRequestPanelModel.build(read.pullRequest), open: { _ in })
        ConnectedPanel(
            model: ConnectedPanelModel.build(read.connected, reference: factsReference, calendar: timelineCalendar),
            openTicket: { _ in }, openInitiatives: {}
        )
    }
    .frame(width: width, alignment: .leading)
    .padding(DesignTokens.Space.s5)
    .background(DesignTokens.Surface.window.color)
}

// MARK: - The facts rail's Note, Decisions and Details panels (TP-1447)

/// Three tickets (`Tests/Fixtures/facts-rail/details*.json`, the runs' models from `details-events.json`): a note
/// implementation run 3 read, two decisions (the older unfolded) and every detail, the run models unfolded; a note no run
/// read yet with a new one typed in the field, no decisions and no brief; and a ticket Symphony holds nothing of, Save
/// Note off with its reason.
let factsDetailTickets = ["details", "details-unread", "details-empty"]

@MainActor
func factsDetails(_ name: String, width: CGFloat) -> some View {
    func data(_ file: String) -> Data {
        guard let data = try? Data(contentsOf: factsFixtures.appendingPathComponent("\(file).json")) else {
            fatalError("The facts rail fixture \(file) is missing from \(factsFixtures.path)")
        }
        return data
    }
    guard let read = TicketDetailsRead.decode(data(name)), let history = TicketEventsPayload.decode(data("details-events")) else {
        fatalError("The facts rail fixture \(name) doesn't decode")
    }
    let full = name == "details"
    let runs = name == "details-empty" ? [:] : history.runs
    let decisions: [TicketDecision] = full ? [
        TicketDecision(
            id: "D1", date: "2026-11-09", title: "Keep the facts rail at 340 pt on a laptop",
            question: "How wide is the facts rail on a laptop?", answer: "340 pt, as the catalog shows; the desktop keeps 440 pt.",
            scope: "The rail's width is fixed; the main column gives way."
        ),
        TicketDecision(id: "D2", date: "2026-11-10", answer: "Fold the agent description by default."),
    ] : []
    let composer = TicketNoteComposer(
        identifier: name, text: name == "details-unread" ? "Check the dark snapshots at 440 pt." : ""
    )
    let note = NotePanelModel.build(note: read.note, move: read.noteMove, runs: runs, reference: factsReference, calendar: timelineCalendar)
    let details = DetailsPanelModel.build(
        read, runs: runs, linearURL: full ? URL(string: "https://linear.app/acme/issue/TP-1447") : nil,
        pullRequest: full ? TicketPullRequest(number: 870, url: URL(string: "https://github.com/acme/symphony/pull/870")) : nil,
        description: full ? "## Goal\n\nThree more FactsRail panels: Note for the next run, Decisions and Details." : nil,
        reference: factsReference, calendar: timelineCalendar
    )
    return VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
        NotePanel(model: note, composer: composer, save: {})
        DecisionsPanel(model: DecisionsPanelModel.build(decisions), unfolded: ["D1"])
        DetailsPanel(model: details, open: { _ in }, copy: { _ in }, modelsUnfolded: full)
    }
    .frame(width: width, alignment: .leading)
    .padding(DesignTokens.Space.s5)
    .background(DesignTokens.Surface.window.color)
}

// MARK: - The ticket page at laptop width (TP-1448)

/// Three moments of one ticket (`Tests/Fixtures/director-app/ticket-page`): TP-1244 with a run working on its tests,
/// TP-1245 waiting on your answer, TP-1246 shipped, each read with its events feed, its decisions and the Inbox.
let ticketPageAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/ticket-page/api/v1").standardizedFileURL
let ticketPageMoments = [("TP-1244", "running"), ("TP-1245", "waiting"), ("TP-1246", "shipped")]
let ticketPageInbox: InboxPayload = {
    guard let inbox = InboxPayload.decode(try! Data(contentsOf: ticketPageAPI.appendingPathComponent("inbox.json"))) else {
        fatalError("The ticket page fixture's Inbox doesn't read")
    }
    return inbox
}()

/// `identifier`'s page as the window builds it from the fixture.
func ticketPageRead(_ identifier: String) -> TicketPage {
    func data(_ path: String) -> Data? { try? Data(contentsOf: ticketPageAPI.appendingPathComponent(path)) }
    let events = data("repos/symphony/tickets/\(identifier)/events.json").flatMap(TicketEventsPayload.decode)
    return TicketPage(
        identifier: identifier,
        sources: TicketPage.Sources(state: data("state.json"), issue: data("\(identifier).json"), events: events, feedAbsence: .unread),
        timeZone: TimeZone(identifier: "UTC")!
    )
}

/// The marks (TP-1451): TP-1244's Timeline as its page draws it, last looked at at 09:30, with its title's count, the
/// line "Since you last looked, at 09:30" and the dot on the three entries newer than it (the run now says it is live).
@MainActor
func timelineSinceLooked() -> some View {
    let page = ticketPageRead("TP-1244")
    let model = TimelineModel.build(
        page.history ?? TicketEventsPayload(), runNow: page.runNow, reference: page.reference, calendar: timelineCalendar,
        lookedAt: page.marksRead?.lookedAt
    )
    return VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
        TimelineTitle(marks: page.marksRead)
        TimelineSection(model: model, transcripts: StepTranscripts { _ in .unreachable }, calendar: timelineCalendar)
    }
    .padding(DesignTokens.Space.s5)
    .frame(width: 780, alignment: .leading)
    .background(DesignTokens.Surface.content.color)
}

// MARK: - The run in place (TP-1452)

/// `identifier`'s Timeline as its page draws it, in the laptop's 780 pt column: the run now on top with its step and
/// newest lines, or, with no run, the line from the situation (`situation` stands in for the read's own).
@MainActor
func timelineInPlace(_ identifier: String, situation: Situation? = nil) -> some View {
    let page = ticketPageRead(identifier)
    return VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
        TimelineTitle(marks: nil)
        TimelineSection(
            model: page.timelineModel(calendar: timelineCalendar),
            idle: TimelineIdleLine(situation ?? page.situation, reference: page.reference),
            transcripts: StepTranscripts { _ in .unreachable }, calendar: timelineCalendar
        )
        .environment(\.readSession, ReadSessionAction(identifier) { _ in })
    }
    .padding(DesignTokens.Space.s5)
    .frame(width: 780, alignment: .leading)
    .background(DesignTokens.Surface.content.color)
}

/// The three no-run lines: TP-1245 waiting on you, the same ticket waiting for a slot, and TP-1246 shipped.
let noRunMoments: [(String, String, Situation?)] = [
    ("waiting-on-you", "TP-1245", nil),
    ("waiting-for-slot", "TP-1245", Situation(
        kind: .slot, cause: "Every slot is taken: 3 of 3 runs are working.", next: "It starts when one frees up.",
        since: ISO8601DateFormatter().date(from: "2026-10-08T10:20:00Z")
    )),
    ("shipped", "TP-1246", nil),
]

/// The session reader on run 1 of TP-1376 (`Tests/Fixtures/run-steps`): every step's lines, the tests step's failing
/// result expanded in place.
@MainActor
func sessionReader() -> some View {
    let transcripts = runStepTranscripts()
    let reader = SessionReader.build(identifier: "TP-1376", run: runStepGroups[0]) { transcripts.lines($0) }
    let failing = reader.lines.first { $0.line.failed && $0.expands } ?? reader.lines.first { $0.expands }
    return SessionReaderPage(reader: reader, expanded: Set([failing?.id].compactMap { $0 }))
        .frame(width: 820, alignment: .topLeading)
}

/// `identifier`'s decisions, as the facts rail's Decisions panel reads them.
@MainActor
func ticketPageDecisions(_ identifier: String) -> [TicketDecision] {
    let editor = TicketDecisionsEditor()
    editor.show(identifier)
    editor.apply(try? Data(contentsOf: ticketPageAPI.appendingPathComponent("tickets/\(identifier)/decisions.json")), for: identifier)
    return editor.decisions
}

/// The whole page of `identifier` in a 1440 × 900 window beside the sidebar: about 1180 pt of content, the rail at
/// 340 pt. The page scrolls as one, so it is drawn at its whole height, down to the rail's foot.
@MainActor
func ticketPageLaptop(_ identifier: String) -> some View {
    let page = ticketPageRead(identifier)
    let width = TicketPageLayout.laptopPageWidth
    return TicketPageBody(
        page: page, questions: TicketPage.questions(of: identifier, in: ticketPageInbox.items), width: width,
        transcripts: StepTranscripts { _ in .unreachable }, note: TicketNoteComposer(identifier: identifier),
        decisions: ticketPageDecisions(identifier), calendar: timelineCalendar
    )
    .frame(width: width, alignment: .topLeading)
    .frame(minHeight: TicketPageLayout.laptopWindowHeight, alignment: .top)
    .background(DesignTokens.Surface.content.color)
}

/// TP-1245's answers on the ticket page (TP-1450): its second option picked, or its own-words card with words in it.
let ticketPagePicked = DecisionPicks(picks: [0: 1])
var ticketPageOwnWords: DecisionPicks {
    let action = TicketPage.questions(of: "TP-1245", in: ticketPageInbox.items)[0]
    return DecisionPicks(picks: [0: action.writeInIndex], writeIns: [0: "Use the secondary colour, and keep the times at 11 pt."])
}

/// TP-1245's page in the 1440 × 900 window with Answer pressed: the decision sheet over the dimmed page, the
/// recommended answer picked, or `picks`; Send on, or off with `sending` while the answer is on its way.
@MainActor
func ticketPageAnswering(picks: DecisionPicks = DecisionPicks(), sending: Bool = false) -> some View {
    let identifier = "TP-1245"
    let page = ticketPageRead(identifier)
    let width = TicketPageLayout.laptopPageWidth
    let questions = TicketPage.questions(of: identifier, in: ticketPageInbox.items)
    let answers = TicketPageAnswers(picks: picks, sending: sending)
    return TicketPageBody(
        page: page, questions: questions, width: width, transcripts: StepTranscripts { _ in .unreachable },
        note: TicketNoteComposer(identifier: identifier), decisions: ticketPageDecisions(identifier), sheetOpen: true,
        calendar: timelineCalendar
    )
    .frame(width: width, height: TicketPageLayout.laptopWindowHeight, alignment: .top)
    .clipped()
    .background(DesignTokens.Surface.content.color)
    .decisionSheet(isPresented: .constant(true)) {
        DecisionSheet(questions: questions, picks: answers.picks, subtitle: page.sheetSubtitle, pick: { _, _ in }, send: {}, close: {},
                      sendOff: answers.sendOff)
            .frame(height: TicketPageLayout.laptopWindowHeight)
    }
}

// MARK: - The ticket page at desktop width (TP-1449)

/// The whole page of `identifier` `width` wide in a window 1360 pt tall: at 2200 pt (a 1440p display) the desktop's
/// arrangement, with a waiting ticket's Questions as the column on the far right; at 1590 and 1610 pt the two sides of
/// the 1600 pt breakpoint. The page hasn't scrolled, and is drawn at its whole height.
@MainActor
func ticketPageWide(_ identifier: String, width: CGFloat = TicketPageLayout.desktopPageWidth, picks: DecisionPicks = DecisionPicks()) -> some View {
    let page = ticketPageRead(identifier)
    let height = TicketPageLayout.desktopPageHeight
    return TicketPageBody(
        page: page, questions: TicketPage.questions(of: identifier, in: ticketPageInbox.items), answers: TicketPageAnswers(picks: picks), width: width,
        transcripts: StepTranscripts { _ in .unreachable }, note: TicketNoteComposer(identifier: identifier),
        decisions: ticketPageDecisions(identifier), scroll: TicketPageScroll(viewport: height), calendar: timelineCalendar
    )
    .frame(width: width, alignment: .topLeading)
    .frame(minHeight: height, alignment: .top)
    .background(DesignTokens.Surface.content.color)
}

// MARK: - Work › Tickets as the table with filters (TP-1456)

/// The `tickets` fixture's answer to `GET /api/v1/tickets`, and its state for the forced marks and the drawer.
let ticketsPayload: TicketsPayload = {
    guard let payload = TicketsPayload.decode(try! Data(contentsOf: situationsAPI.appendingPathComponent("tickets/api/v1/tickets.json"))) else {
        fatalError("The tickets fixture's tickets read doesn't read")
    }
    return payload
}()

/// Tickets in a window `window` wide less its sidebar and 800 pt tall: the filter bar over the table, with the drawer
/// on SHOP-301 when `drawer` is set. With chips, the rows are the ones the server lets through, as it would answer.
@MainActor
func ticketsTable(window: CGFloat, query: TicketsQuery = TicketsQuery(), drawer: Bool = false) -> some View {
    let list = TicketList(state: situationsState("tickets"), now: situationsNow, timeZone: TimeZone(identifier: "UTC")!)
    var payload = ticketsPayload
    payload.rows = payload.rows.filter { row in
        query.chips.allSatisfy { chip in
            switch chip.filter {
            case .epic: chip.values.contains(row.epic ?? "")
            case .situation: chip.values.contains(row.text("situation") ?? "")
            case .priority: chip.values.contains(row.number("priority").map(String.init) ?? "")
            case .repo: chip.values.contains(row.repoKey ?? "")
            case .phase: chip.values.contains(row.phase ?? "")
            case .label: !Set(chip.values).isDisjoint(with: row.labels)
            case .since: true
            }
        }
    }
    var values = TicketFilterValues()
    values.learn(ticketsPayload.rows)
    return TicketsView(
        payload: payload, list: list, query: .constant(query), values: values, search: "", selection: .constant("SHOP-301"),
        drawerShown: .constant(drawer), reference: situationsNow, actions: TicketsActions(),
        viewsMenu: TicketViewsMenu(views: savedTicketViews, currentID: nil, query: query)
    )
    .frame(width: window - DesignTokens.Layout.sidebarWidth, height: 800, alignment: .top)
    .background(DesignTokens.Surface.content.color)
}

// MARK: - Saved views on Tickets (TP-1457)

/// The `ticket-views` fixture's views once "Epic 6 needs me" was saved: three, by name.
let savedTicketViews: [TicketView] = {
    let file = situationsAPI.appendingPathComponent("ticket-views/api/v1/views.after-view.1.json")
    guard let views = TicketView.views(fromViews: try! Data(contentsOf: file)), views.count == 3 else {
        fatalError("The ticket-views fixture's views don't read")
    }
    return views
}()

/// The views menu open on "Epic 6 needs me" with a filter changed since it was saved: the dot on its face, Update
/// View on.
@MainActor
func ticketViewsMenuOpen() -> some View {
    var query = savedTicketViews[0].query
    query.toggle(.priority, "1")
    return TicketViewsMenuPanel(menu: TicketViewsMenu(views: savedTicketViews, currentID: savedTicketViews[0].id, query: query))
        .padding(DesignTokens.Space.s4)
        .frame(width: 300, height: 330, alignment: .topLeading)
        .background(DesignTokens.Surface.content.color)
}

/// Save View… with the name typed.
@MainActor
func ticketViewSaveSheet() -> some View {
    TicketViewNameSheetView(sheet: .save, name: "Epic 6 needs me", working: false, error: nil, cancel: {}, confirm: { _ in })
        .background(DesignTokens.Surface.window.color)
}

/// Every column of the catalog shown, sorted by Age, youngest first.
let everyColumnQuery = TicketsQuery(columns: TicketColumn.catalog.map(\.name), sort: TicketSort(column: "created_at"))

/// Three chips: SHOP-280's sub-tickets, waiting for CI or working, urgent or high.
let threeChipsQuery = TicketsQuery(chips: [
    TicketFilterChip(filter: .epic, values: ["SHOP-280"]),
    TicketFilterChip(filter: .situation, values: ["waiting_for_ci", "working"]),
    TicketFilterChip(filter: .priority, values: ["1", "2"]),
])

// The Journal (TP-1459): the `journal` fixture's night across every ticket, at its state's clock, as the page draws it
// in a window `window` pt wide less its sidebar, unscrolled.
let journalAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/journal/api/v1").standardizedFileURL
let journalNow = ISO8601DateFormatter().date(from: "2026-11-12T03:30:00Z")!

/// The Journal under `query`, from the fixture's page that answers it (`file`).
@MainActor
func journalPage(_ file: String, query: JournalQuery = JournalQuery(), window: CGFloat) -> some View {
    guard let page = JournalPayload.decode(try! Data(contentsOf: journalAPI.appendingPathComponent("\(file).json"))),
          let initiatives = InitiativesPayload.decode(try! Data(contentsOf: journalAPI.appendingPathComponent("initiatives.json")))
    else { fatalError("The journal fixture's \(file) doesn't read") }
    var feed = JournalFeed()
    feed.takeNewest(page)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    return JournalView(
        model: JournalModel.build(feed, reference: journalNow, calendar: utc), query: .constant(query),
        values: JournalFilterValues(repos: ["api", "docs", "symphony", "web-shop"], epics: initiatives.initiatives.map(\.identifier), query: query),
        scrolls: false, calendar: utc
    )
    .frame(width: window - DesignTokens.Layout.sidebarWidth, alignment: .top)
    .background(DesignTokens.Surface.content.color)
}

/// The Journal with its reports (TP-1462): the `journal` fixture's night, its two reports pinned at the end of their
/// periods, the newer one's citations resolved by the night's events and the older one's by the read of its period, and
/// the newer one's Question open from the fixture's Inbox; with `reportsOnly`, the reports alone.
@MainActor
func journalReportsPage(window: CGFloat, reportsOnly: Bool = false) -> some View {
    func read(_ file: String) -> Data { try! Data(contentsOf: journalAPI.appendingPathComponent("\(file).json")) }
    guard let page = JournalPayload.decode(read("events")),
          let reports = JournalReportsPayload.decode(read("reports")),
          let period = JournalPayload.decode(read("events.limit=200&notable=true&since=2026-11-11T15:00:00Z&until=2026-11-11T21:00:00Z")),
          let inbox = InboxPayload.decode(read("inbox")),
          let initiatives = InitiativesPayload.decode(read("initiatives"))
    else { fatalError("The journal fixture's reports don't read") }
    var feed = JournalFeed()
    feed.takeNewest(page)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    var citations = JournalCitations(page.events)
    citations.take(period.events)
    let cards = reports.reports.compactMap { JournalReportCard.build($0, citations: citations, calendar: utc) }
    var questions: [String: JournalReportQuestion] = [:]
    for card in cards {
        guard let item = inbox.items.first(where: { $0.review.action?.questionID == card.questionID }), let action = item.review.action else { continue }
        questions[card.id] = JournalReportQuestion(itemID: item.id, action: action, picks: DecisionPicks(picks: [0: 0]))
    }
    let query = JournalQuery(reportsOnly: reportsOnly)
    return JournalView(
        model: JournalModel.build(feed, reports: cards, reportsOnly: reportsOnly, reference: journalNow, calendar: utc), query: .constant(query),
        values: JournalFilterValues(repos: ["api", "docs", "symphony", "web-shop"], epics: initiatives.initiatives.map(\.identifier), query: query),
        questions: questions, scrolls: false, calendar: utc
    )
    .frame(width: window - DesignTokens.Layout.sidebarWidth, alignment: .top)
    .background(DesignTokens.Surface.content.color)
}

// MARK: - Insights (TP-1463)

// Quality, Usage and Shipped under their shared control bar, from the `insights` fixture's week (Nov 6–12) by day, by
// 6 h and kept to epic TP-1381, on Symphony's day 2026-11-12.
let insightsAPI = here.appendingPathComponent("../Tests/Fixtures/director-app/insights/api/v1").standardizedFileURL
let insightsToday = "2026-11-12"
let insightsNow = ISO8601DateFormatter().date(from: "2026-11-12T03:30:00Z")!
let insightsQuery = "from=2026-11-06&to=2026-11-12&unit=%@&series=tokens,runs,verdicts,shipped"
let insightsSlices: [(name: String, slice: InsightsSlice, file: String)] = [
    ("daily", InsightsSlice(), "aggregate"),
    ("6h", InsightsSlice(unit: .sixHours), "aggregate." + String(format: insightsQuery, "6h")),
    ("epic", InsightsSlice(epic: "TP-1381"), "aggregate." + String(format: insightsQuery, "day&epic=TP-1381")),
]

func insightsRead(_ file: String) -> Data {
    try! Data(contentsOf: insightsAPI.appendingPathComponent("\(file).json"))
}

/// `page` (Quality, Usage or Shipped) under the control bar, as the window draws it beside the sidebar at `window`.
@MainActor
func insightsPage(_ page: SymphonyView, slice: InsightsSlice, file: String, window: CGFloat) -> some View {
    guard let aggregate = AggregatePayload.decode(insightsRead(file)), let state = OverviewState.decode(insightsRead("state")),
          let initiatives = InitiativesPayload.decode(insightsRead("initiatives")), let history = HistoryPayload.decode(insightsRead("history")),
          let runs = QualityRun.decode(insightsRead("runs")), let details = ShippedPayload.decode(insightsRead("shipped"))
    else { fatalError("The insights fixture's \(file) doesn't read") }
    let values = InsightsControlValues(repos: state.repos, epics: initiatives.initiatives.map(\.identifier), slice: slice)
    return VStack(spacing: 0) {
        InsightsControlBar(slice: .constant(slice), values: values, today: insightsToday, summary: Insights.summary(aggregate, slice: slice, scope: .all))
        switch page {
        case .usage:
            UsageCards(usage: Usage(aggregate: aggregate, slice: slice, snapshot: state.snapshot, today: insightsToday, now: insightsNow,
                                    timeZone: TimeZone(identifier: "UTC")!))
        case .quality:
            QualityCards(quality: Quality(aggregate: aggregate, slice: slice, review: .loaded(history.review ?? ReviewHistory(), runs: runs), today: insightsToday))
        default:
            ShippedCards(shipped: Shipped(aggregate: aggregate, slice: slice, details: details, today: insightsToday))
        }
    }
    .frame(width: window - DesignTokens.Layout.sidebarWidth, alignment: .top)
    .background(DesignTokens.Surface.content.color)
}

/// An Insights page whose Symphony predates the aggregate read (TP-1490), at the laptop's full page height: the control
/// bar stays at the top and "Update Symphony" sits centred below it.
@MainActor
func insightsUnavailablePage(window: CGFloat) -> some View {
    guard let state = OverviewState.decode(insightsRead("state")), let initiatives = InitiativesPayload.decode(insightsRead("initiatives"))
    else { fatalError("The insights fixture's state doesn't read") }
    let slice = insightsSlices[0].slice
    let values = InsightsControlValues(repos: state.repos, epics: initiatives.initiatives.map(\.identifier), slice: slice)
    return PinnedBarPage {
        InsightsControlBar(slice: .constant(slice), values: values, today: insightsToday, summary: nil)
    } content: {
        EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
    }
    .frame(width: window - DesignTokens.Layout.sidebarWidth, height: 800)
    .background(DesignTokens.Surface.content.color)
}

MainActor.assumeIsolated {
    for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
        // The shared styles (TP-1438): the control sizes, each state of a row, a card and the buttons (a selected
        // button, its menu or sheet open, stays pressed without shrinking), the pressed
        // and lifted ones with Reduce Motion off and on, a disabled button with its reason, and the situation kinds.
        render(controlSizes(), scheme, to: "style-control-sizes-\(suffix).png")
        for (name, state) in interactionStates {
            render(styledRow(state), scheme, to: "style-row-\(name)-\(suffix).png")
            render(styledCard(state), scheme, to: "style-card-\(name)-\(suffix).png")
            render(styledButtons(state), scheme, to: "style-button-\(name)-\(suffix).png")
        }
        render(styledButtons(.off), scheme, to: "style-button-disabled-\(suffix).png")
        render(styledRow(.press, reduceMotion: true), scheme, to: "style-row-pressed-reduce-motion-\(suffix).png")
        render(styledButtons(.press, reduceMotion: true), scheme, to: "style-button-pressed-reduce-motion-\(suffix).png")
        render(styledCard(.hover, reduceMotion: true), scheme, to: "style-card-hover-reduce-motion-\(suffix).png")
        render(styledCard(.press, reduceMotion: true), scheme, to: "style-card-pressed-reduce-motion-\(suffix).png")
        render(disabledWithReason(), scheme, to: "style-button-disabled-reason-\(suffix).png")
        render(situationKinds(), scheme, to: "style-situation-kinds-\(suffix).png")
        // The catalog's panel, zone title and chip (TP-1484).
        render(panelStories(), scheme, to: "component-panel-\(suffix).png")
        render(chipVariants(), scheme, to: "component-chip-\(suffix).png")
        // The catalog's Button, Icon button and Inline refusal stories (TP-1505), one snapshot each.
        // The catalog's Badge, Count badge, Status dot and Keyboard hint stories (TP-1506), one snapshot each.
        // The catalog's Row stories (TP-1507), one snapshot each; the tree and the progress strip from the catalog's Home
        // and Initiatives: the queue folded, its first chain opened, and the epics' strips.
        for story in componentStories + badgeStories + rowStories {
            render(componentStorySnapshot(story), scheme, to: "\(story.component)-\(story.id)-\(suffix).png")
        }
        render(homeTree(selected: .more("TP-1483")), scheme, to: "tree-home-\(suffix).png")
        render(homeTree(opened: ["TP-1481"], selected: .row("TP-1484")), scheme, to: "tree-home-chain-open-\(suffix).png")
        render(progressStrips(), scheme, to: "progress-strip-initiatives-\(suffix).png")
        // The Situation line (TP-1439): every kind in the full and the compact size, and forced, "and n more", narrow.
        render(situationLines(.full), scheme, to: "situation-line-full-\(suffix).png")
        render(situationLines(.compact), scheme, to: "situation-line-compact-\(suffix).png")
        render(situationLineExtras(), scheme, to: "situation-line-extras-\(suffix).png")
        // The Situation line everywhere (TP-1441): Tickets, Initiatives, the Inbox's context, the menu bar.
        render(ticketsSituations(), scheme, to: "situations-tickets-\(suffix).png")
        render(initiativesSituations(), scheme, to: "situations-initiatives-\(suffix).png")
        // Initiatives as the epic's story (TP-1458): mid-chain, done, and with a canceled sub-ticket, at both widths.
        for (window, name) in [(CGFloat(1440), "laptop"), (2560, "desktop")] {
            render(initiativeStory("TP-1381", window: window), scheme, to: "initiative-story-mid-chain-\(name)-\(suffix).png")
            render(initiativeStory("SHOP-500", window: window), scheme, to: "initiative-story-done-\(name)-\(suffix).png")
            render(initiativeStory("BIL-300", window: window), scheme, to: "initiative-story-canceled-\(name)-\(suffix).png")
        }
        render(inboxContextSituations(), scheme, to: "situations-inbox-context-\(suffix).png")
        render(menuWaitingSituations(), scheme, to: "situations-menu-waiting-\(suffix).png")
        // Home's board (TP-1453): every group populated and most empty with dispatch paused, at the laptop's and the
        // desktop's widths.
        for (window, name) in [(CGFloat(1440), "laptop"), (2560, "desktop")] {
            render(homeBoard("home", window: window, selection: "SHOP-320"), scheme, to: "home-board-\(name)-\(suffix).png")
            render(homeBoard("home-quiet", window: window), scheme, to: "home-board-quiet-\(name)-\(suffix).png")
        }
        // Home's top (TP-1454): two questions and a pause above the board, the drawer, the status bar, at the laptop's and
        // the desktop's widths.
        for (window, name) in [(CGFloat(1440), "laptop"), (2560, "desktop")] {
            render(homeWithQuestions(window: window), scheme, to: "home-questions-\(name)-\(suffix).png")
            render(statusBar(window: window), scheme, to: "status-bar-\(name)-\(suffix).png")
        }
        render(inboxDrawer(), scheme, to: "inbox-drawer-\(suffix).png")
        // The Action rail (TP-1440): every move allowed, and each refusal with its reason and More open, at the
        // laptop's and the desktop's header widths.
        for (width, name) in [(CGFloat(1180), "laptop"), (2200, "desktop")] {
            render(actionRailAllowed(width: width), scheme, to: "action-rail-allowed-\(name)-\(suffix).png")
            render(actionRailRefusals(width: width), scheme, to: "action-rail-refusals-\(name)-\(suffix).png")
        }
        // The Question block and the decision sheet (TP-1442): the option card's states, the block with nothing picked,
        // an option picked, the own-words card blank and written, and the sheet with one Question, one of two answered
        // and both.
        render(optionCardStates(), scheme, to: "question-option-card-states-\(suffix).png")
        render(questionBlock(unpickedAction), scheme, to: "question-block-unpicked-\(suffix).png")
        render(questionBlock(), scheme, to: "question-block-picked-\(suffix).png")
        render(questionBlock(picks: DecisionPicks(picks: [0: action.writeInIndex])), scheme, to: "question-block-own-words-blank-\(suffix).png")
        render(questionBlock(picks: picks), scheme, to: "question-block-own-words-\(suffix).png")
        render(questionBlock(width: 420), scheme, to: "question-block-narrow-\(suffix).png")
        render(decisionSheet([unpickedAction]), scheme, to: "decision-sheet-one-question-\(suffix).png")
        render(decisionSheet([unpickedAction, secondAction], picks: DecisionPicks(picks: [0: 0])), scheme, to: "decision-sheet-one-of-two-\(suffix).png")
        render(decisionSheet([unpickedAction, secondAction], picks: DecisionPicks(picks: [0: 0, 1: 1])), scheme, to: "decision-sheet-both-answered-\(suffix).png")
        // The Run group and the Step list (TP-1443): an ended run folded, the same run unfolded on its failed step, and
        // the run now live on its current step.
        render(runGroup(runStepGroups[0]), scheme, to: "run-group-folded-\(suffix).png")
        render(runGroup(runStepGroups[0], unfolded: true), scheme, to: "run-group-failed-step-\(suffix).png")
        render(runGroup(runStepGroups[1]), scheme, to: "run-group-run-now-\(suffix).png")
        // The Timeline section (TP-1444): a day with every entry class at the laptop's and the desktop's column widths,
        // and an entry selected with the failed run unfolded.
        render(timeline(width: 780), scheme, to: "timeline-laptop-\(suffix).png")
        render(timeline(width: 1040), scheme, to: "timeline-desktop-\(suffix).png")
        render(timeline(width: 780, selection: "entry-b2", unfoldedRuns: ["run-2", "run-1"]), scheme, to: "timeline-selected-\(suffix).png")
        // The marks (TP-1451): the Timeline title's count, the line where you last looked and the dots above it.
        render(timelineSinceLooked(), scheme, to: "timeline-since-looked-\(suffix).png")
        // The run in place (TP-1452): the run now on top with its newest lines, the no-run line for three situations, and
        // the session reader with a line expanded.
        render(timelineInPlace("TP-1244"), scheme, to: "timeline-run-now-\(suffix).png")
        for (name, identifier, situation) in noRunMoments {
            render(timelineInPlace(identifier, situation: situation), scheme, to: "timeline-no-run-\(name)-\(suffix).png")
        }
        render(sessionReader(), scheme, to: "session-reader-\(suffix).png")
        // The Lifecycle section and the Phase path (TP-1445): a ticket mid-way, one Done and one at 95 % of its cap, at
        // the laptop's and the desktop's column widths; their phase paths in full and compact.
        for name in lifecycleTickets {
            render(lifecycle(name, width: LifecycleSection.laptopWidth), scheme, to: "lifecycle-\(name)-laptop-\(suffix).png")
            render(lifecycle(name, width: LifecycleSection.desktopWidth), scheme, to: "lifecycle-\(name)-desktop-\(suffix).png")
        }
        render(phasePaths(width: 780), scheme, to: "phase-path-laptop-\(suffix).png")
        render(phasePaths(width: 1040), scheme, to: "phase-path-desktop-\(suffix).png")
        // The facts rail's Pull request and Connected panels (TP-1446): a green PR, a red PR with three workflows and a
        // ticket with a resolved and an open blocker, at the laptop's and the desktop's rail widths.
        for name in factsTickets {
            render(factsRail(name, width: FactsRail.laptopWidth), scheme, to: "facts-rail-\(name)-laptop-\(suffix).png")
            render(factsRail(name, width: FactsRail.desktopWidth), scheme, to: "facts-rail-\(name)-desktop-\(suffix).png")
        }
        // The Note for the next run, Decisions and Details panels (TP-1447): with every fact, with a note not read yet,
        // and with nothing, at both rail widths.
        for name in factsDetailTickets {
            render(factsDetails(name, width: FactsRail.laptopWidth), scheme, to: "facts-rail-\(name)-laptop-\(suffix).png")
            render(factsDetails(name, width: FactsRail.desktopWidth), scheme, to: "facts-rail-\(name)-desktop-\(suffix).png")
        }
        // The ticket page at laptop width (TP-1448): a run working, waiting on you, shipped; and Answer's sheet open.
        for (identifier, moment) in ticketPageMoments {
            render(ticketPageLaptop(identifier), scheme, to: "ticket-page-\(moment)-laptop-\(suffix).png")
        }
        render(ticketPageAnswering(), scheme, to: "ticket-page-answer-sheet-laptop-\(suffix).png")
        // Answering from the page (TP-1450): the sheet and the desktop's column with another option picked and with
        // the Director's own words, and the sheet while the answer is on its way, Send off.
        render(ticketPageAnswering(picks: ticketPagePicked), scheme, to: "ticket-page-answer-picked-laptop-\(suffix).png")
        render(ticketPageAnswering(picks: ticketPageOwnWords), scheme, to: "ticket-page-answer-own-words-laptop-\(suffix).png")
        render(ticketPageAnswering(sending: true), scheme, to: "ticket-page-answer-sending-laptop-\(suffix).png")
        render(ticketPageWide("TP-1245", picks: ticketPagePicked), scheme, to: "ticket-page-answer-picked-desktop-\(suffix).png")
        render(ticketPageWide("TP-1245", picks: ticketPageOwnWords), scheme, to: "ticket-page-answer-own-words-desktop-\(suffix).png")
        // The ticket page at desktop width (TP-1449): the three moments at 2200 pt, and the waiting ticket on either
        // side of the 1600 pt breakpoint.
        for (identifier, moment) in ticketPageMoments {
            render(ticketPageWide(identifier), scheme, to: "ticket-page-\(moment)-desktop-\(suffix).png")
        }
        for width in [CGFloat(1590), 1610] {
            render(ticketPageWide("TP-1245", width: width), scheme, to: "ticket-page-waiting-\(Int(width))-\(suffix).png")
        }
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
        // The same chips in the other reviews (TP-988).
        for (identifier, name) in [("TP-923", "plan"), ("TP-895", "pr"), ("TP-896", "clarify"), ("TP-897", "blocked")] {
            render(review(identifier), scheme, to: "\(name)-chips-\(suffix).png")
        }
        render(planQuestions(), scheme, to: "plan-questions-\(suffix).png")
        render(planUnapplied(), scheme, to: "plan-unapplied-\(suffix).png")
        render(planUnasked(), scheme, to: "plan-unasked-\(suffix).png")
        render(planUnaskedApprove(), scheme, to: "plan-unasked-approve-\(suffix).png")
        // The PR and CI watcher (TP-946): S16.
        render(watcherDecision(), scheme, to: "watcher-decision-\(suffix).png")
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
        // Tickets as the table with filters (TP-1456): the default columns with the drawer, every column, and three
        // chips set, at the laptop's and the desktop's widths.
        for (window, name) in [(CGFloat(1440), "laptop"), (2560, "desktop")] {
            render(ticketsTable(window: window, drawer: true), scheme, to: "tickets-table-default-\(name)-\(suffix).png")
            render(ticketsTable(window: window, query: everyColumnQuery), scheme, to: "tickets-table-every-column-\(name)-\(suffix).png")
            render(ticketsTable(window: window, query: threeChipsQuery), scheme, to: "tickets-table-three-chips-\(name)-\(suffix).png")
        }
        // The Journal (TP-1459): a night with every notable class, the Everything view and the epic filter, at the
        // laptop's and the desktop's widths.
        for (window, name) in [(CGFloat(1440), "laptop"), (2560, "desktop")] {
            render(journalPage("events", window: window), scheme, to: "journal-every-class-\(name)-\(suffix).png")
            render(journalPage("events.limit=200&notable=false", query: JournalQuery(everything: true), window: window), scheme,
                   to: "journal-everything-\(name)-\(suffix).png")
            render(journalPage("events.epic=TP-1381&limit=200&notable=true", query: JournalQuery(epic: "TP-1381"), window: window), scheme,
                   to: "journal-epic-\(name)-\(suffix).png")
            // Reports in the Journal (TP-1462): a report with its Question open and one without, among the events, and
            // the reports alone.
            render(journalReportsPage(window: window), scheme, to: "journal-reports-\(name)-\(suffix).png")
            render(journalReportsPage(window: window, reportsOnly: true), scheme, to: "journal-reports-only-\(name)-\(suffix).png")
        }
        // The Insights control bar (TP-1463): Quality, Usage and Shipped by day, by 6 h and with an epic set, at the
        // laptop's and the desktop's widths.
        for (window, name) in [(CGFloat(1440), "laptop"), (2560, "desktop")] {
            for (sliceName, slice, file) in insightsSlices {
                for page in [SymphonyView.quality, .usage, .shipped] {
                    render(insightsPage(page, slice: slice, file: file, window: window), scheme,
                           to: "insights-\(page.rawValue)-\(sliceName)-\(name)-\(suffix).png")
                }
            }
        }
        render(insightsUnavailablePage(window: 1440), scheme, to: "insights-unavailable-laptop-\(suffix).png")
        // Saved views (TP-1457): the menu with three views, and the save sheet.
        render(ticketViewsMenuOpen(), scheme, to: "ticket-views-menu-\(suffix).png")
        render(ticketViewSaveSheet(), scheme, to: "ticket-views-save-sheet-\(suffix).png")
        // GitHub updates (TP-953).
        render(githubUpdatesPage(githubSection("github-updates-off")), scheme, to: "github-updates-off-\(suffix).png")
        render(githubUpdatesPage(githubSection("github-updates"), expanded: true), scheme, to: "github-updates-on-\(suffix).png")
        render(githubUpdatesPage(githubSection("github-updates-degraded")), scheme, to: "github-updates-degraded-\(suffix).png")
        render(githubUpdatesPage(githubSecretFailing()), scheme, to: "github-updates-secret-\(suffix).png")
        render(githubUpdatesPage(githubNeedsSetup()), scheme, to: "github-updates-needs-setup-\(suffix).png")
        render(githubSheet(.turnOff), scheme, to: "github-updates-turn-off-sheet-\(suffix).png")
        render(githubSheet(.recreateSecret), scheme, to: "github-updates-recreate-secret-sheet-\(suffix).png")
        // The Linear webhooks line (TP-1212): every state at the laptop viewport, and deliveries arriving at the desktop's.
        for (name, health) in linearWebhookStates {
            render(linearWebhooksPage(health), scheme, to: "linear-webhooks-\(name)-laptop-\(suffix).png")
        }
        render(linearWebhooksPage(linearWebhookStates[2].1, window: 2560), scheme, to: "linear-webhooks-arriving-desktop-\(suffix).png")
        // The Dispatch shadow line (TP-1220): every state at the laptop viewport, and the ten differences at the desktop's.
        for (name, report, expanded) in dispatchShadowStates {
            render(dispatchShadowPage(report, expanded: expanded), scheme, to: "dispatch-shadow-\(name)-laptop-\(suffix).png")
        }
        render(dispatchShadowPage(dispatchShadowStates[4].1, expanded: true, window: 2560), scheme,
               to: "dispatch-shadow-poll-differences-open-desktop-\(suffix).png")
        // The Reconcile line (TP-1228): every state at the laptop viewport, and the ten drifts at the desktop's.
        for (name, report, expanded) in reconcileStates {
            render(reconcilePage(report, expanded: expanded), scheme, to: "reconcile-\(name)-laptop-\(suffix).png")
        }
        render(reconcilePage(reconcileStates[5].1, expanded: true, window: 2560), scheme, to: "reconcile-failing-open-desktop-\(suffix).png")
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
        // Pause one repository (TP-1238): Setup's Repositories card, the Repos window's Dispatch section at its
        // narrowest and at a laptop's width, and the sidebar.
        render(repositoriesPage(), scheme, to: "repo-pause-setup-laptop-\(suffix).png")
        render(repositoriesPage(window: 2560), scheme, to: "repo-pause-setup-desktop-\(suffix).png")
        render(repoPauseSection(width: 500), scheme, to: "repo-pause-repos-narrow-\(suffix).png")
        render(repoPauseSection(width: 1220), scheme, to: "repo-pause-repos-laptop-\(suffix).png")
        render(repoPausedSidebar(), scheme, to: "repo-pause-sidebar-\(suffix).png")
        // The five destinations (TP-1455): Home's and Factory's badges, and none.
        render(destinationsSidebar(), scheme, to: "sidebar-destinations-\(suffix).png")
        // Move to… (TP-1328): the move's sheet, also with a refusal.
        render(moveSheet(), scheme, to: "move-sheet-\(suffix).png")
        render(moveSheet(error: "Couldn't move SHOP-430 to In Progress: Symphony has no record of SHOP-430 yet, so it can't move it (HTTP 409)"),
               scheme, to: "move-sheet-refused-\(suffix).png")
        // Start now (TP-1330): each disabled reason.
        render(startDisabledReasons(), scheme, to: "start-now-disabled-reasons-\(suffix).png")
        // A blocked Inbox row's pause (TP-1253): stopped by the Director, and two reasons, one releasable.
        for (identifier, name) in [("TP-897", "stopped"), ("TP-899", "two-reasons")] {
            render(blockedReview(identifier, window: 1440), scheme, to: "inbox-blocked-\(name)-laptop-\(suffix).png")
            render(blockedReview(identifier, window: 2560), scheme, to: "inbox-blocked-\(name)-desktop-\(suffix).png")
        }
    }
}

MainActor.assumeIsolated { runGallery() }

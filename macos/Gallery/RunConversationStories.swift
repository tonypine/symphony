// The run conversation's components (TP-1688, `docs/design/prototypes/run-conversation/`, approved 2026-11-24): a
// note, a fold line with its chips (folded, unfolded, working), a failure row with its count, the minute line, and a
// whole step's conversation, the Implementation and Silent stretch scenes; and (TP-1689) the Code Review scene's run
// with no steps, running and finished with its saved session in the Sent back treatment, and the Blocked marks; and
// (TP-1698) the facts a run recorded, each component alone and the QA and Code Review scenes from the app's fixtures. Each
// is drawn by the shared views in `SymphonyBarUI/DesignSystem/RunConversation.swift` and `SymphonyBarUI/RunGroup.swift`;
// a fold line's click works on the live stories.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// A step's column on the ticket page.
let runConversationStoryWidth: CGFloat = 640

private func storyLine(_ kind: TranscriptLine.Kind, _ text: String, _ at: String, tool: String? = nil, file: String? = nil, failed: Bool = false, ms: Int? = nil)
    -> TranscriptLine
{
    TranscriptLine(kind: kind, text: text, at: "2026-11-24T" + at + "Z", durationMs: ms, failed: failed, tool: tool, file: file)
}

private func storyCall(_ tool: String, _ summary: String, _ at: String, file: String? = nil) -> TranscriptLine {
    storyLine(.tool, tool + ": " + summary, at, tool: tool, file: file)
}

private let testsFile = "macos/Tests/SymphonyBarCoreTests/RecentlyDoneTests.swift"
private let redTest = "Test Case '-[SymphonyBarCoreTests.RecentlyDoneTests testPickingWeekReadsTheWeek]' started.\n"
    + "macos/Tests/SymphonyBarCoreTests/RecentlyDoneTests.swift:142: error: XCTAssertEqual failed: (\"today\") is not equal to (\"week\")\n"
    + "Test Case '-[SymphonyBarCoreTests.RecentlyDoneTests testPickingWeekReadsTheWeek]' failed (0.010 seconds).\n"
    + "Executed 12 tests, with 1 failure (0 unexpected) in 0.214 (0.221) seconds"

/// The Implementation scene's lines: notes in Markdown, their actions, and the same failure three times back to back.
let implementationStoryLines: [TranscriptLine] = [
    storyLine(.say, "Let me view the render and the existing Swift code.", "12:30:02"),
    storyCall("Read", "macos/Sources/SymphonyBar/HomeView.swift", "12:30:04", file: "macos/Sources/SymphonyBar/HomeView.swift"),
    storyLine(.result, "     1\timport SwiftUI", "12:30:04", ms: 40),
    storyCall("Bash", "rg -n 'RecentlyDone' macos/Sources", "12:30:06"),
    storyLine(.result, "macos/Sources/SymphonyBarCore/Home/HomeRead.swift:88", "12:30:06", ms: 180),
    storyLine(.say, "Now the new Core tests for **Recently done**:\n\n- the range and the fold are remembered\n- `Today` empty keeps the head", "12:37:10"),
    storyCall("Write", testsFile, "12:37:20", file: testsFile),
    storyLine(.result, "File created successfully at: " + testsFile, "12:37:20", ms: 30),
    storyCall("Bash", "cd macos && swift test --filter RecentlyDoneTests", "12:37:30"),
    storyLine(.result, redTest, "12:38:11", failed: true, ms: 41_000),
    storyCall("Bash", "cd macos && swift test --filter RecentlyDoneTests", "12:38:20"),
    storyLine(.result, redTest, "12:39:01", failed: true, ms: 41_000),
    storyCall("Bash", "cd macos && swift test --filter RecentlyDoneTests", "12:39:10"),
    storyLine(.result, redTest, "12:39:51", failed: true, ms: 41_000),
    storyLine(.say, "Two fixes needed:\n\n```\nlet path = path(offset)\n```\n\nwon't compile (a self-referencing initializer). Fixing both.", "12:40:02"),
    storyCall("Edit", "macos/Sources/SymphonyBarCore/RecentlyDone.swift", "12:40:10", file: "macos/Sources/SymphonyBarCore/RecentlyDone.swift"),
    storyLine(.result, "The file has been updated.", "12:40:10", ms: 25),
    storyCall("Bash", "cd macos && swift test --filter RecentlyDoneTests", "12:40:20"),
    storyLine(.result, "Executed 12 tests, with 0 failures (0 unexpected) in 0.201 (0.209) seconds", "12:41:00", ms: 40_000),
    storyCall("mcp__symphony__ticket_record", #"{"type":"step.completed"}"#, "12:41:05"),
    storyLine(.result, #"{"event":{"type":"step.completed"}}"#, "12:41:06", ms: 900),
]

/// The Silent stretch scene's lines: 23 actions with no note, a red test, then a note the run is still working on.
let silentStoryLines: [TranscriptLine] = {
    var lines = [storyCall("Read", "macos/Sources/SymphonyBar/HomeView.swift", "12:29:02", file: "macos/Sources/SymphonyBar/HomeView.swift")]
    lines.append(storyLine(.result, "     1\timport SwiftUI", "12:29:02", ms: 40))
    for index in 0 ..< 22 {
        let at = String(format: "12:%02d:%02d", 29 + index / 8, (index % 8) * 7)
        lines.append(storyCall("Bash", "rg -n 'RecentlyDone' macos/Sources | head -\(index + 5)", at))
        lines.append(storyLine(.result, "macos/Sources/SymphonyBarCore/Home/HomeRead.swift:88", at, ms: 160))
    }
    lines.append(storyCall("Bash", "cd macos && swift test --disable-sandbox --build-system native --filter RecentlyDoneTests", "12:32:10"))
    lines.append(storyLine(.result, redTest, "12:32:51", failed: true, ms: 41_000))
    lines.append(storyLine(.say, "Found a subtle bug: switching back to a range whose read was tagged would get \"unchanged\" and leave the list empty.", "12:38:00"))
    lines.append(storyCall("Bash", "rg -n 'etag' macos/Sources/SymphonyBarCore", "12:38:05"))
    lines.append(storyLine(.result, "macos/Sources/SymphonyBarCore/LiveAPIClient.swift:72", "12:38:05", ms: 150))
    lines.append(storyCall("Bash", "sed -n 60,90p macos/Sources/SymphonyBarCore/LiveAPIClient.swift", "12:38:09"))
    return lines
}()

/// The Code Review scene's session (TP-1689): six actions, the verdict among them, then the review's note.
let reviewStoryLines: [TranscriptLine] = [
    storyCall("Bash", "git diff 2b54b5258..HEAD -- macos/Sources/SymphonyBarCore/HomeRead.swift macos/Sources/SymphonyBarCore/HomeQueue.swift", "12:50:21"),
    storyLine(.result, "diff --git a/macos/Sources/SymphonyBarCore/HomeQueue.swift b/macos/Sources/SymphonyBarCore/HomeQueue.swift", "12:50:22", ms: 900),
    storyCall("Bash", "git diff 2b54b5258..HEAD -- macos/Sources/SymphonyBarUI macos/Sources/SymphonyBar", "12:50:33"),
    storyLine(.result, "diff --git a/macos/Sources/SymphonyBar/HomeView.swift b/macos/Sources/SymphonyBar/HomeView.swift", "12:50:34", ms: 700),
    storyCall("Bash", "cat macos/Tests/SymphonyBarCoreTests/RecentlyDoneTests.swift", "12:50:34"),
    storyLine(.result, "import Foundation\nimport XCTest\n@testable import SymphonyBarCore", "12:50:35", ms: 200),
    storyCall("Bash", "sed -n 1,200p lib/symphony_elixir/home/recently_done.ex | grep -nE \"epic|done_at\"", "12:50:57"),
    storyLine(.result, "5:  Symphony saw reach done in a range, most recent first", "12:50:58", ms: 150),
    storyCall("Bash", "sed -n 60,100p lib/symphony_elixir/home/recently_done.ex", "12:51:00"),
    storyLine(.result, "value ->\n        case Integer.parse(to_string(value)) do", "12:51:01", ms: 150),
    storyCall("review_verdict", "{\"verdict\": \"request_changes\", \"reason\": \"The proof of c6 tests a function the row never draws with.\"}", "12:51:20"),
    storyLine(.result, "{\"recorded\": true, \"verdict\": \"request_changes\"}", "12:51:21", ms: 600),
    storyLine(.say, "I've finished the review of TP-1644 (pull request #1070) and recorded **request changes**. I read the code and did not run any tests.\n\n**Blocking findings:**\n1. **The test for c6 doesn't test what's drawn.** c6 says the place that uses the done row picks its cells (all of them, pull request and when, or when only). Its test checks `DoneRow.parts(_:epic:)`, but the row's `body` never calls that function; it picks the cells again with its own branches. So `parts` is only used by tests, and the test would still pass if the drawn row stopped matching it. The fix is to draw the trailing cells from `parts`, or to remove `parts` and test the rendered row.\n2. **The `recentHeight` token is never used.** It's set to 216 and a test asserts that value. The section's height actually comes from `HomeRecentlyDone.listHeight(rows:)`, which gives 214 because it leaves out the gap after the last row. The fix is to remove the token, or make the view use it and agree on the value.\n\n**What looks right:**\n- The app's decode matches what `GET /api/v1/home` returns (`recently_done.ex`): the range, both counts, the paging fields and every entry field, with the epic and pull request optional. No server change was needed.\n- Switching between Today and Week can't leave the list stale or empty. Reading past the first page appends rows correctly, and a page left over from the other range is ignored.\n- The relaunch test (c3) really builds a new model on the same store. The finish test (c5) goes through the queue notice and the re-read.\n\n**Not blocking:** each done row is identified by its ticket identifier alone. If a ticket finishes twice in a week, or a ticket finishes while a later page is being read, the same identifier can appear twice in the list. SwiftUI's `ForEach` misbehaves with duplicate identifiers.", "12:51:26"),
]

/// The Code Review scene's run: running on no step with its newest lines, or ended with its saved session and a verdict
/// that sent the work back.
func reviewStoryRun(running: Bool) -> RunGroupModel {
    var run = RunGroupModel(
        id: running ? "review-now" : "review-1", title: "Code Review run 1", state: running ? .running : .sentBack,
        word: running ? "Running" : RunGroupModel.requestChanges, durationSeconds: running ? 60 : 120, tokens: running ? nil : 675_000,
        model: "Claude Opus 5.5"
    )
    if running {
        run.liveLines = Array(reviewStoryLines.prefix(4))
            + [storyLine(.say, "Reading the diff against the plan's checks before I judge it.", "12:50:40")]
            + Array(reviewStoryLines.dropFirst(4).prefix(6))
    } else {
        run.transcript = reviewStoryTranscript
    }
    return run
}

let reviewStoryTranscript = TicketOutput(id: "review-1-session/lines", label: "Session", path: "api/v1/artifacts/review-1-session/lines", available: true)

/// A QA run whose verdict was blocked: its header alone, folded.
let blockedStoryRun = RunGroupModel(
    id: "qa-blocked", title: "QA run 1", state: .blocked, word: RunStep.State.blocked.word, durationSeconds: 1_200, model: "Claude Opus 5.5"
)

/// A QA run with a check that could not judge: the Blocked step's row in its run.
let blockedStepStoryRun = RunGroupModel(
    id: "qa-step-blocked", title: "QA run 2", state: .passed, word: "Passed", durationSeconds: 900, model: "Claude Opus 5.5",
    steps: [
        RunStep(id: "walk", stepID: "walk_1", title: "Walk step 1", state: .done, durationSeconds: 240),
        RunStep(id: "design", stepID: "design_check", title: "Design check", state: .blocked, reason: "no signing identity", durationSeconds: 60),
    ]
)

/// A run's group at the step column's width, its saved session already read.
@MainActor
func runGroupStory(_ run: RunGroupModel, unfolded: Bool) -> AnyView {
    let transcripts = StepTranscripts { _ in .unreachable }
    transcripts.keep(reviewStoryLines, for: reviewStoryTranscript.id)
    return AnyView(
        RunGroup(run: run, transcripts: transcripts, unfolded: unfolded, unfoldedSteps: [])
            .frame(width: runConversationStoryWidth, alignment: .topLeading)
    )
}

/// A whole step's conversation, its groups folded or not.
private struct LiveConversation: View {
    let entries: [ConversationEntry]
    @State var folds: ConversationFolds

    var body: some View {
        RunConversationView(entries: entries, folds: $folds)
            .frame(width: runConversationStoryWidth, alignment: .topLeading)
    }
}

@MainActor
func runConversationStory(_ lines: [TranscriptLine], live: Bool = false, open: Int? = nil, showsAll: Bool = false) -> AnyView {
    let entries = RunConversation.entries(lines, live: live, timeZone: TimeZone(identifier: "UTC")!)
    let opened = open.map { Set([entries.filter(\.hasFold)[$0].id]) } ?? []
    return AnyView(LiveConversation(entries: entries, folds: ConversationFolds(opened: opened, showsAll: showsAll)))
}

/// One component alone at the column's width.
@MainActor
private func alone(_ view: some View) -> AnyView {
    AnyView(view.frame(width: runConversationStoryWidth, alignment: .leading))
}

@MainActor
let runConversationStories: [ComponentStory] = {
    func story(_ id: String, height: CGFloat, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "run-conversation", id: id, title: "Run conversation", width: runConversationStoryWidth, height: height, draw: draw)
    }
    let notes = RunConversation.entries(implementationStoryLines, timeZone: TimeZone(identifier: "UTC")!)
    let written = notes[1]
    let failure = notes[2]
    return [
        story("note", height: 120) { alone(ConversationNote(text: implementationStoryLines[5].text)) },
        story("note-code-block", height: 160) { alone(ConversationNote(text: implementationStoryLines[14].text)) },
        story("fold-line-folded", height: 32) { alone(ConversationFoldLine(gist: notes[0].gist, open: false)) },
        story("fold-line-chips", height: 32) { alone(ConversationFoldLine(gist: written.gist, open: false)) },
        story("fold-line-working", height: 32) { alone(ConversationFoldLine(gist: ActionGist(notes[3].actions), open: false, working: true)) },
        story("failure-row", height: 120) { alone(ConversationFailureRow(action: failure.failure ?? RunAction(), repeats: 1)) },
        story("failure-row-repeated", height: 120) { alone(ConversationFailureRow(action: failure.failure ?? RunAction(), repeats: 8)) },
        story("minute-line", height: 24) { alone(ConversationMinuteLine(minute: "12:38")) },
        story("implementation", height: 520) { runConversationStory(implementationStoryLines) },
        story("implementation-group-open", height: 620) { runConversationStory(implementationStoryLines, open: 0) },
        story("implementation-show-all", height: 760) { runConversationStory(implementationStoryLines, showsAll: true) },
        story("silent-stretch-working", height: 320) { runConversationStory(silentStoryLines, live: true) },
        story("review-running", height: 260) { runGroupStory(reviewStoryRun(running: true), unfolded: true) },
        story("review-finished", height: 640) { runGroupStory(reviewStoryRun(running: false), unfolded: true) },
        story("review-finished-folded", height: 72) { runGroupStory(reviewStoryRun(running: false), unfolded: false) },
        story("run-blocked", height: 72) { runGroupStory(blockedStoryRun, unfolded: false) },
        story("step-blocked", height: 140) { runGroupStory(blockedStepStoryRun, unfolded: true) },
    ] + runFactStories
}()

// MARK: - Facts (TP-1698)

// The facts a run recorded, drawn where it recorded them: each component alone, then the QA and Code Review scenes read
// from the app's own fixtures (`director-app/ticket-facts`, `director-app/ticket-review-conversation`), so a story draws
// what the ticket page draws, the real picture included.

/// The facts fixture's directory, and the review fixture's.
let factsAPI = ticketPageAPI.appendingPathComponent("../../../ticket-facts/api/v1").standardizedFileURL
let reviewConversationAPI = ticketPageAPI.appendingPathComponent("../../../ticket-review-conversation/api/v1").standardizedFileURL

/// The runs of SHOP-410 in a fixture, as the ticket page builds them.
func factsStoryRuns(_ api: URL) -> [RunGroupModel] {
    guard let data = try? Data(contentsOf: api.appendingPathComponent("repos/web-shop/tickets/SHOP-410/events.json")),
          let history = TicketEventsPayload.decode(data)
    else { return [] }
    return RunGroupModel.groups(history, reference: Date(timeIntervalSince1970: 1_800_000_000))
}

/// The transcripts of `runs` read from the fixture, at the addresses the app reads them from.
@MainActor
func factsStoryTranscripts(_ api: URL, _ runs: [RunGroupModel]) -> StepTranscripts {
    let transcripts = StepTranscripts { _ in .unreachable }
    let outputs = runs.flatMap { run in run.steps.compactMap(\.transcript) + [run.transcript].compactMap { $0 } }
    for output in outputs {
        let file = api.appendingPathComponent(output.path.replacingOccurrences(of: "api/v1/", with: "") + ".txt")
        if let data = try? Data(contentsOf: file) { transcripts.keep(TranscriptLine.lines(data), for: output.id) }
    }
    return transcripts
}

/// The fixture's pictures, kept by their artifact's id as the app reads them.
@MainActor
func factsStoryImages(_ api: URL) -> ArtifactImages {
    let images = ArtifactImages { _ in .unreachable }
    let artifacts = api.appendingPathComponent("artifacts")
    for file in (try? FileManager.default.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "png" {
        if let data = try? Data(contentsOf: file) { images.keep(data, for: file.deletingPathExtension().lastPathComponent) }
    }
    return images
}

/// The run `title` of a fixture, unfolded with every step open, at the step column's width.
@MainActor
func factsSceneStory(_ api: URL, _ title: String) -> AnyView {
    let runs = factsStoryRuns(api)
    guard let run = runs.first(where: { $0.title == title }) else { return AnyView(Text("No \(title) in the fixture")) }
    return AnyView(
        RunGroup(run: run, transcripts: factsStoryTranscripts(api, runs), unfolded: true, unfoldedSteps: Set(run.steps.map(\.id)))
            .frame(width: runConversationStoryWidth, alignment: .topLeading)
            .environment(\.artifactImages, factsStoryImages(api))
    )
}

private let storyPicture = TicketPicture(
    caption: "Settings after the relaunch, filter still Failed", step: "1",
    screenshot: TicketScreenshot(
        id: "7763409689b96f805ef476477c10d809e7c5e3b42df5f4ceb05f69833bb1582d", label: "Settings after the relaunch",
        path: "api/v1/artifacts/7763409689b96f805ef476477c10d809e7c5e3b42df5f4ceb05f69833bb1582d", available: true
    )
)

private let storyFindings = [
    ReviewFinding(summary: "The test for c6 doesn't test what's drawn.", file: "macos/Sources/SymphonyBarUI/DoneRow.swift", lineRange: .init(start: 70, end: 79)),
    ReviewFinding(summary: "The recentHeight token is never used.", file: "macos/Sources/SymphonyBarCore/DesignTokens.swift", lineRange: .init(start: 1883, end: 1885)),
]

private let storyChanges = RunChanges(
    startHead: "aaa1111", head: "bbb2222",
    commits: [RunChanges.Commit(sha: "c0ffee1a2b3c4d5e6f708192a3b4c5d6e7f80912", subject: "Keep the filter in settings"),
              RunChanges.Commit(sha: "bbb2222aa41f00d", subject: "Restore the filter at launch")],
    files: [RunChanges.File(path: "lib/web_shop/filter.ex", status: .added), RunChanges.File(path: "lib/web_shop/settings.ex", status: .modified),
            RunChanges.File(path: "lib/web_shop/tab.ex", status: .renamed, from: "lib/web_shop/pane.ex")],
    commitCount: 3
)

@MainActor
let runFactStories: [ComponentStory] = {
    func story(_ id: String, height: CGFloat, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "run-conversation", id: id, title: "Run conversation", width: runConversationStoryWidth, height: height, draw: draw)
    }
    func fact(_ kind: RunFact.Kind) -> AnyView {
        AnyView(ConversationFact(fact: RunFact(id: "story", date: nil, kind: kind)).frame(width: runConversationStoryWidth, alignment: .leading))
    }
    let measures = [
        TicketMeasure(name: "Window width", value: 1440, unit: "pt", expected: 1440),
        TicketMeasure(name: "Filter restored after launch", value: 0.42, unit: "s"),
        TicketMeasure(name: "Menu label width", value: 0, unit: "pt", expected: 80),
    ]
    return [
        story("fact-verdict-request-changes", height: 40) {
            fact(.verdict(RunFact.Verdict(word: RunGroupModel.requestChanges, state: .sentBack, findings: storyFindings)))
        },
        story("fact-verdict-approved", height: 40) { fact(.verdict(RunFact.Verdict(word: "Approved", state: .passed))) },
        story("fact-step-answers", height: 40) {
            fact(.answer([RunFact.Mark(title: "Step 2", state: .done), RunFact.Mark(title: "Step 3", state: .failed),
                          RunFact.Mark(title: "Step 6", state: .blocked)], measures: []))
        },
        story("fact-evidence-counts", height: 40) {
            fact(.evidence(counts: [.init(step: "6", count: 4), .init(step: "12", count: 4)], measures: [], pictures: []))
        },
        story("fact-measures", height: 80) { fact(.evidence(counts: [.init(step: nil, count: 1)], measures: measures, pictures: [])) },
        story("fact-pictures", height: 160) {
            AnyView(fact(.evidence(counts: [.init(step: "1", count: 1)], measures: [], pictures: [storyPicture])).environment(\.artifactImages, factsStoryImages(factsAPI)))
        },
        story("fact-test-result", height: 28) { fact(.testResult(TicketTestResult(passed: 41, failed: 1, skipped: 2, durationMs: 95_000))) },
        story("fact-test-result-green", height: 28) { fact(.testResult(TicketTestResult(passed: 12, failed: 0, durationMs: 41_000))) },
        story("fact-proved-checks", height: 32) {
            fact(.provedChecks(test: "test/web_shop/filter_test.exs: keeps the filter after a relaunch", checkIDs: ["c1", "c4"]))
        },
        story("fact-changes", height: 80) { fact(.changes(storyChanges)) },
        story("qa-walk-facts", height: 1100) { factsSceneStory(factsAPI, "QA run 1") },
        story("review-finished-facts", height: 700) { factsSceneStory(reviewConversationAPI, "Code Review run 1") },
        story("implementation-facts", height: 200) { factsSceneStory(factsAPI, "Implementation run 1") },
    ]
}()

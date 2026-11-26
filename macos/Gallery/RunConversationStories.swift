// The run conversation's components (TP-1688, `docs/design/prototypes/run-conversation/`, approved 2026-11-24): a
// note, a fold line with its chips (folded, unfolded, working), a failure row with its count, the minute line, and a
// whole step's conversation, the Implementation and Silent stretch scenes. Each is drawn by the shared views in
// `SymphonyBarUI/DesignSystem/RunConversation.swift`; a fold line's click works on the live stories.
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
    ]
}()

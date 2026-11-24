// The Home queue's components (TP-1608), drawn from the approved prototype's sample tickets
// (`docs/design/prototypes/home-queue/page.js`): the slot card now, waiting on the person, needing attention and empty;
// the folded strip line; the checks bar; the token line; the slot count control; and the queue row at rest, hovered
// and dragged. Drag and drop (TP-1610) adds the row left behind while it is dragged with the drop line in a gap, and
// the slot card, the empty slot and the strip line as the target under a dragged row. Each story is a variation of its
// own (`slot-card-now`). The slot count control is live: in the gallery
// it steps between 1 and 6. Recently done (TP-1644) adds the done row with every cell, with the pull request and when,
// with when alone, without an epic, with a long title and hovered, and the section's head with a count, without one, on
// Week and folded; the head's range control and fold are live.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// A live story's value, kept while the gallery shows it.
private struct HomeQueueLiveValue<Value, Content: View>: View {
    @State var value: Value
    let content: (Binding<Value>) -> Content

    var body: some View { content($value) }
}

/// A slot card's width on a laptop's Home: the content column inside its 32 pt gutters.
let slotCardStoryWidth: CGFloat = 1120
let slotCardStoryHeight: CGFloat = 300
let queueRowStoryWidth: CGFloat = 1120

/// TP-1576 in QA, working: the prototype's first slot.
let slotNow = SlotCardModel(
    identifier: "TP-1576", title: "Rebuild the Settings page's sections from the design-system Gallery components", epic: "Settings as a real page",
    status: .working, stage: 2, since: "2 h 40 min", word: "QA", sentence: "walking the Settings sections, check 6 of 9",
    tokens: [
        TokenLine.Stage(name: "Coding", tokens: 9_600_000, series: .series1),
        TokenLine.Stage(name: "Code Review", tokens: 3_100_000, series: .series2),
        TokenLine.Stage(name: "QA", tokens: 8_700_000, series: .series3),
        TokenLine.Stage(name: "Merging", tokens: 0, series: .series4),
    ],
    tokenTotal: 21_400_000, tokenCap: 100_000_000,
    plan: "Each Settings section is rebuilt from Gallery components: rows, toggles, number fields and the save bar. No section keeps a hand-built control, and every setting keeps its binding and its validation.",
    proved: 5, checks: 9, next: "The Runs section saves a changed model and shows Saved.",
    pullRequest: SlotCardModel.PullRequest(
        number: "#1041", size: "38 files · +1,412 −986", branch: "auto/TP-1576 into main", ci: .init(.done, "18 checks passed"),
        review: .init(.done, "Approved on 507db3b")
    )
)

/// TP-1594 in Code Review, waiting on the person: the prototype's second slot.
let slotWaiting = SlotCardModel(
    identifier: "TP-1594", title: "A QA pass walks the checks that share a screen and state in one session", status: .you, stage: 1,
    since: "48 min", word: "Waiting on you", sentence: "may a grouped step hold more than six checks?",
    tokens: [
        TokenLine.Stage(name: "Coding", tokens: 7_900_000, series: .series1),
        TokenLine.Stage(name: "Code Review", tokens: 1_900_000, series: .series2),
    ],
    tokenTotal: 9_800_000, tokenCap: 100_000_000,
    plan: "The plan of a pass groups the checks that share a screen and state, and each group is walked in one session. Every check keeps its own result and its own evidence.",
    proved: 8, checks: 9, next: "The timeline shows each check of a grouped step with its own result.",
    pullRequest: SlotCardModel.PullRequest(
        number: "#1043", size: "11 files · +524 −61", branch: "auto/TP-1594 into main", ci: .init(.done, "17 checks passed"),
        review: .init(.you, "Review asked a question")
    )
)

/// TP-1590 in Coding with failing checks, needing attention, before its pull request is opened.
let slotAttention = SlotCardModel(
    identifier: "TP-1590", title: "App updates stop the factory for most of an hour when several tickets merge in a row",
    epic: "Updates without a stop", status: .problem, stage: 0, since: "1 h 05 min", word: "Needs attention",
    sentence: "two tests failed in the update drain, retrying at 16:02",
    tokens: [TokenLine.Stage(name: "Coding", tokens: 4_200_000, series: .series1)], tokenTotal: 4_200_000, tokenCap: 100_000_000,
    plan: "An update waits, with dispatch on, for a moment with no agent run, and installs then. Nothing stops the factory to wait for it.",
    proved: 0, checks: 6, next: "The update installs in the first moment no run is working.", pullRequest: nil
)

@MainActor
private func slotCardStory(_ ticket: SlotCardModel?, slot: Int, dropTarget: Bool = false) -> AnyView {
    AnyView(
        SlotCard(slot: slot, ticket: ticket, dropTarget: dropTarget)
            .frame(width: slotCardStoryWidth, alignment: .topLeading)
            .padding(DesignTokens.Space.s4)
            .background(DesignTokens.Surface.sunken.color)
    )
}

/// The queue's sample rows: the prototype's first tickets, and one far down the queue with four digits and a long title.
let queueStoryRows: [QueueRowModel] = [
    QueueRowModel(
        number: 1, identifier: "TP-1592", title: "A check that needs the pull request's own CI run is proved between handoff and merge",
        lead: .dot(.working, live: false), marks: [.init(.idle, "Code Review")], repo: "symphony"
    ),
    QueueRowModel(
        number: 2, identifier: "TP-1596", title: "An answer that says “back to Code Review unchanged” moves the ticket there",
        lead: .glyph("pause.circle", .textSecondary), marks: [.init(.idle, "Stopped in Coding")], repo: "symphony"
    ),
    QueueRowModel(
        number: 7, identifier: "TP-976", title: "Record every protected-change request and its answer as ticket events",
        lead: .status(.you), marks: [.init(.you, "Needs your approval")], repo: "symphony"
    ),
    QueueRowModel(
        number: 8, identifier: "TP-977", title: "Give agents one tool to request a protected change, and pause the ticket on it",
        lead: .glyph("clock", .textSecondary), after: "TP-976", repo: "symphony"
    ),
    QueueRowModel(
        number: 1_243, identifier: "MOT-1331",
        title: "Remember the outreach calendar from the keyboard when the window is narrow, for every repo, in the Director's words, beside its ticket",
        lead: .glyph("clock", .textSecondary), repo: "cycle"
    ),
]

/// The queue's rows, the one at `index` in `look`, the others at rest: the number cell as wide as the widest number.
@MainActor
private func queueRowStory(_ look: QueueRow.Look, index: Int) -> AnyView {
    let width = QueueRow.numberWidth(widest: queueStoryRows.map(\.number).max() ?? 0)
    return AnyView(
        VStack(spacing: DesignTokens.Space.s1) {
            ForEach(Array(queueStoryRows.enumerated()), id: \.offset) { offset, row in
                QueueRow(row, numberWidth: width, look: offset == index ? look : .rest)
            }
        }
        .frame(width: queueRowStoryWidth)
        .padding(DesignTokens.Space.s4)
        .background(DesignTokens.Surface.window.color)
    )
}

/// The queue's rows on the list's pitch while the one at `picked` is dragged: it stays in its place, dimmed, its handle in
/// the number's place, and the drop line marks the gap before the row at `gap`.
@MainActor
private func queueDropStory(picked: Int, gap: Int) -> AnyView {
    let width = QueueRow.numberWidth(widest: queueStoryRows.map(\.number).max() ?? 0)
    return AnyView(
        ZStack(alignment: .topLeading) {
            ForEach(Array(queueStoryRows.enumerated()), id: \.offset) { offset, row in
                QueueRow(row, numberWidth: width, look: offset == picked ? .hover : .rest, picked: offset == picked)
                    .offset(y: Double(offset) * HomeQueuePager.pitch)
            }
            QueueDropLine().offset(y: HomeQueueDrag.lineY(gap))
        }
        .frame(width: queueRowStoryWidth, height: Double(queueStoryRows.count) * HomeQueuePager.pitch, alignment: .topLeading)
        .padding(DesignTokens.Space.s4)
        .background(DesignTokens.Surface.window.color)
    )
}

/// The strip: one line per slot, over the queue's columns.
@MainActor
private func stripStory(hover: Int? = nil, drop: Int? = nil) -> AnyView {
    let width = QueueRow.numberWidth(widest: queueStoryRows.map(\.number).max() ?? 0)
    let slots: [SlotCardModel?] = [slotNow, slotWaiting, slotAttention, nil]
    return AnyView(
        VStack(spacing: DesignTokens.Space.s1 / 2) {
            ForEach(Array(slots.enumerated()), id: \.offset) { offset, ticket in
                SlotStripLine(
                    slot: offset + 1, ticket: ticket, numberWidth: width, state: offset == hover ? .hover : .rest, dropTarget: offset == drop
                )
            }
        }
        .frame(width: queueRowStoryWidth)
        .padding(DesignTokens.Space.s4)
        .background(DesignTokens.Surface.window.color)
    )
}

@MainActor
private func padded(_ view: some View, width: CGFloat) -> AnyView {
    AnyView(view.frame(width: width, alignment: .leading).padding(DesignTokens.Space.s4))
}

/// The slot count control on a live value, so its steppers move it.
@MainActor
private func slotCountStory(_ value: Int) -> AnyView {
    padded(HomeQueueLiveValue(value: value) { SlotCountControl(count: $0) }, width: 120)
}

/// A store kept in memory, for the screens drawn with Recently done's choices.
final class GalleryChoices: KeyValueStore {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// The prototype's Recently done (`docs/design/prototypes/home-queue/page.js`): its first rows, and one with no epic and
/// one with a long title.
let doneStoryRows: [DoneRowModel] = [
    DoneRowModel(
        identifier: "TP-1622", title: "Engine: the queue's order is stored as one sort key per ticket", epic: "TP-1597", pullRequest: "#1053",
        repo: "symphony", when: "20 min ago"
    ),
    DoneRowModel(
        identifier: "MOT-104", title: "Record a ride's track while the screen is off", epic: "MOT-105", pullRequest: "#88", repo: "cycle",
        when: "1 h ago"
    ),
    DoneRowModel(
        identifier: "TP-1606", title: "Engine: a ticket without a slot does not react to anything", epic: "TP-1597", pullRequest: "#1052",
        repo: "symphony", when: "3 h ago"
    ),
    DoneRowModel(identifier: "HUB-208", title: "Show a company's open invoices on its page", pullRequest: "#412", repo: "hub", when: "yesterday"),
    DoneRowModel(
        identifier: "TP-983",
        title: "Read the list of protected paths from one place, for every repo, in the Director's words, beside its ticket and its pull request",
        epic: "TP-975", pullRequest: "#611", repo: "symphony", when: "Sat"
    ),
]

/// Done rows with `cells`, every one of `rows` at rest but the one at `hovered`.
@MainActor
private func doneRowStory(_ rows: [DoneRowModel], cells: DoneRow.Cells, hovered: Int? = nil) -> AnyView {
    AnyView(
        VStack(spacing: DesignTokens.HomeQueue.doneRowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                DoneRow(row, cells: cells, hovered: offset == hovered)
            }
        }
        .frame(width: queueRowStoryWidth)
        .padding(DesignTokens.Space.s4)
        .background(DesignTokens.Surface.window.color)
    )
}

/// Recently done's head on `range`, with `count` (nil for none), open or folded; its control and fold are live.
@MainActor
private func recentlyDoneHeadStory(_ range: HomeRead.DoneRange, count: String?, open: Bool = true, hovered: Bool? = nil) -> AnyView {
    AnyView(
        HomeQueueLiveValue(value: RecentlyDoneChoices(range: range, open: open)) { choices in
            RecentlyDoneHead(range: choices.range, count: count, open: choices.wrappedValue.open, hovered: hovered) {
                choices.wrappedValue.open.toggle()
            }
        }
        .frame(width: queueRowStoryWidth)
        .padding(DesignTokens.Space.s4)
        .background(DesignTokens.Surface.window.color)
    )
}

@MainActor
let homeQueueStories: [ComponentStory] = {
    func card(_ id: String, height: CGFloat = slotCardStoryHeight, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "slot-card", id: id, title: "Slot card", width: slotCardStoryWidth, height: height, draw: draw)
    }
    func strip(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "slot-strip-line", id: id, title: "Slot strip line", width: queueRowStoryWidth, height: 160, draw: draw)
    }
    func checks(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "checks-bar", id: id, title: "Checks bar", width: 320, height: 32, draw: draw)
    }
    func tokens(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "token-line", id: id, title: "Token line", width: 560, height: 32, draw: draw)
    }
    func count(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "slot-count", id: id, title: "Slot count", width: 160, height: 40, draw: draw)
    }
    func row(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "queue-row", id: id, title: "Queue row", width: queueRowStoryWidth, height: 220, draw: draw)
    }
    func done(_ id: String, height: CGFloat = 220, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "done-row", id: id, title: "Done row", width: queueRowStoryWidth, height: height, draw: draw)
    }
    func head(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "recently-done-head", id: id, title: "Recently done head", width: queueRowStoryWidth, height: 60, draw: draw)
    }
    return [
        card("now") { slotCardStory(slotNow, slot: 1) },
        card("waiting-on-you") { slotCardStory(slotWaiting, slot: 2) },
        card("needs-attention") { slotCardStory(slotAttention, slot: 3) },
        card("empty", height: 100) { slotCardStory(nil, slot: 4) },
        card("drop-target") { slotCardStory(slotNow, slot: 1, dropTarget: true) },
        card("empty-drop-target", height: 100) { slotCardStory(nil, slot: 4, dropTarget: true) },
        strip("lines") { stripStory() },
        strip("hover") { stripStory(hover: 0) },
        strip("drop-target") { stripStory(drop: 1) },
        strip("empty-drop-target") { stripStory(drop: 3) },
        checks("five-of-nine") { padded(ChecksBar(proved: 5, total: 9), width: 280) },
        checks("none-proved") { padded(ChecksBar(proved: 0, total: 6), width: 280) },
        checks("all-proved") { padded(ChecksBar(proved: 9, total: 9), width: 280) },
        tokens("three-stages") { padded(TokenLine(stages: slotNow.tokens, total: slotNow.tokenTotal, cap: slotNow.tokenCap), width: 520) },
        tokens("two-stages") { padded(TokenLine(stages: slotWaiting.tokens, total: slotWaiting.tokenTotal, cap: slotWaiting.tokenCap), width: 520) },
        count("three-slots") { slotCountStory(3) },
        count("one-slot") { slotCountStory(1) },
        count("six-slots") { slotCountStory(6) },
        row("at-rest") { queueRowStory(.rest, index: 4) },
        row("hovered") { queueRowStory(.hover, index: 4) },
        row("dragged") { queueRowStory(.dragged, index: 4) },
        row("drop-line") { queueDropStory(picked: 4, gap: 1) },
        done("all-cells") { doneRowStory(doneStoryRows, cells: .all) },
        done("pull-request-and-when") { doneRowStory(doneStoryRows, cells: .slotCard) },
        done("when-only") { doneRowStory(doneStoryRows, cells: .queue) },
        done("without-an-epic", height: 80) { doneRowStory([doneStoryRows[3]], cells: .all) },
        done("long-title", height: 80) { doneRowStory([doneStoryRows[4]], cells: .all) },
        done("hovered") { doneRowStory(doneStoryRows, cells: .all, hovered: 1) },
        head("with-a-count") { recentlyDoneHeadStory(.today, count: "5") },
        head("without-a-count") { recentlyDoneHeadStory(.today, count: nil) },
        head("week") { recentlyDoneHeadStory(.week, count: "10") },
        head("folded") { recentlyDoneHeadStory(.week, count: "10", open: false) },
        head("hovered") { recentlyDoneHeadStory(.today, count: "5", hovered: true) },
    ]
}()

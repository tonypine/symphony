import AppKit
import SwiftUI
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// TP-1481: a long timeline makes only the rows near the screen, so opening a ticket with a long history costs what a
/// short one does. The page's timeline sits in its main column beside the facts rail, under the header, in the page's
/// scroll view; these tests draw it that way, 1,000 events long, in a window-sized host.
@MainActor
final class TimelineLazyTests: XCTestCase {
    /// The most timeline rows whose bodies SwiftUI evaluates when the page first shows: a 900 pt window shows about 20
    /// rows, and the lazy stack makes a few more on either side of what it shows. The eager timeline evaluated all 1,000.
    static let firstDisplayBound = 80

    /// The page's size on the laptop.
    private static let size = NSSize(width: 1440, height: 900)

    private static let start = Date(timeIntervalSince1970: 1_793_000_000)

    override func tearDown() {
        TimelineRowBodies.recorded = nil
        super.tearDown()
    }

    /// 1,000 events over 20 days, newest first: each day 45 entries and 5 ended runs of one step each, folded.
    static func model() -> TimelineModel {
        var days: [TimelineDay] = []
        var event = 1_000
        for day in 0 ..< 20 {
            var items: [TimelineItem] = []
            for index in 0 ..< 50 {
                let at = start.addingTimeInterval(TimeInterval((20 - day) * 86_400 - index * 600))
                if index % 10 == 9 {
                    let run = RunGroupModel(
                        id: "run-\(event)", title: "Implementation run \(event)", state: .passed, word: "Handoff",
                        durationSeconds: 600, steps: [RunStep(id: "code-\(event)", stepID: "code", title: "Write the code", state: .done)]
                    )
                    items.append(.run(run, at: at))
                } else {
                    items.append(.entry(TimelineEntry(id: "e\(event)", kind: .phase, at: at, title: "Moved to Code Review", actor: "Symphony")))
                }
                event -= 1
            }
            days.append(TimelineDay(id: "day-\(day)", relative: nil, date: "Day \(day)", span: "8 h", items: items))
        }
        return TimelineModel(days: days)
    }

    /// The page around the timeline: the header's room on top, the main column beside the 340 pt rail.
    private func page(_ model: TimelineModel, focus: TimelineFocus? = nil) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                Color.clear.frame(height: 160)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        TimelineTitle(marks: nil)
                        TimelineSection(model: model, transcripts: StepTranscripts { _ in .unreachable }, calendar: utc, focus: focus)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    Color.clear.frame(width: 340, height: 1_200)
                }
            }
            .padding(24)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func show<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        spin(0.3)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testTheFixtureHolds1000EventsWithItsRunsFolded() {
        let model = Self.model()
        XCTAssertEqual(model.items.count, 1_000)
        XCTAssertEqual(model.items.compactMap(\.run).count, 100)
        XCTAssertTrue(model.items.compactMap(\.run).allSatisfy { !$0.opensByDefault })
    }

    func testA1000EventTimelineMakesOnlyTheRowsNearTheScreenAtFirstDisplay() {
        TimelineRowBodies.recorded = []
        let host = show(page(Self.model()))
        let made = TimelineRowBodies.recorded ?? []
        print("TimelineLazyTests: \(made.count) row bodies evaluated at first display of 1,000 events (bound \(Self.firstDisplayBound))")
        XCTAssertFalse(made.isEmpty, "the timeline drew no row")
        XCTAssertLessThan(made.count, Self.firstDisplayBound, "the timeline made \(made.count) rows at first display")
        // The rows made are the newest, at the top of the page.
        XCTAssertTrue(made.contains("entry-e1000"))
        XCTAssertFalse(made.contains("entry-e1"))
        withExtendedLifetime(host) {}
    }

    /// The page opened at an event far down: the timeline asks its scroll view for that item's row, a line of the lazy
    /// stack not made yet, and makes nothing past the screen meanwhile. A scroll view hosted without a window never
    /// scrolls, so the scroll itself is the Mac build's scroll test's and QA's to see.
    func testThePageOpenedAtAnEventFarDownAsksForItsRowBeforeItWasMade() throws {
        let model = Self.model()
        let target = try XCTUnwrap(model.items.dropLast(5).last)
        guard case let .entry(entry) = target else { return XCTFail("the target is not an entry") }
        TimelineRowBodies.recorded = []
        TimelineScrolls.recorded = []
        defer { TimelineScrolls.recorded = nil }
        let host = show(page(model, focus: TimelineFocus(identifier: "TP-1463", eventID: entry.id)))
        XCTAssertEqual(TimelineScrolls.recorded, [target.id])
        // The item's row is one of the stack's own lines, so the scroll finds it before it is made.
        XCTAssertTrue(TimelineSection.lines(model, idle: nil, clock: { _ in "" }).contains { $0.id == target.id })
        let made = TimelineRowBodies.recorded ?? []
        XCTAssertFalse(made.contains(target.id), "the row far down was made before any scroll")
        XCTAssertLessThan(Set(made).count, Self.firstDisplayBound)
        withExtendedLifetime(host) {}
    }

    // MARK: - An unfolded run is drawn whole, outside the lazy stacks (TP-1688)

    /// An `NSHostingView` that counts its layout passes.
    private final class CountingHost<Content: View>: NSHostingView<Content> {
        var layouts = 0

        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    /// The long history with a running run on top whose current step's conversation is far taller than the window: 60
    /// notes in Markdown, each followed by its tool calls, and a failure repeated back to back.
    static func longModelWithATallRunNow() -> TimelineModel {
        var lines: [TranscriptLine] = []
        for index in 0 ..< 60 {
            let at = String(format: "2026-11-11T12:%02d:00Z", index % 60)
            lines.append(TranscriptLine(kind: .say, text: "**Note \(index)**: wrote `File\(index).swift`.\n\n- one\n- two", at: at))
            lines.append(TranscriptLine(kind: .tool, text: "Write: File\(index).swift", at: at, tool: "Write", file: "Sources/File\(index).swift"))
            lines.append(TranscriptLine(kind: .result, text: "ok", at: at))
            lines.append(TranscriptLine(kind: .tool, text: "Bash: swift build", at: at, tool: "Bash"))
            lines.append(TranscriptLine(kind: .result, text: "error: no such module\nline two", at: at, failed: true))
            lines.append(TranscriptLine(kind: .tool, text: "Bash: swift build", at: at, tool: "Bash"))
            lines.append(TranscriptLine(kind: .result, text: "error: no such module\nline two", at: at, failed: true))
        }
        let now = RunGroupModel(
            id: "run-now", title: "Implementation run 101", state: .running, word: "Running", durationSeconds: 600,
            steps: [RunStep(id: "code-now", stepID: "code", title: "Write the code", state: .current, liveLines: lines)]
        )
        var long = model()
        long.days[0].items.insert(.run(now, at: start.addingTimeInterval(21 * 86_400)), at: 0)
        return long
    }

    func testAnUnfoldedRunIsDrawnWholeBetweenLazyStretchesOfShortLines() {
        let at = Self.start
        func entry(_ id: String) -> TimelineItem { .entry(TimelineEntry(id: id, kind: .phase, at: at, title: id, actor: "Symphony")) }
        func run(_ id: String) -> TimelineItem { .run(RunGroupModel(id: id, title: id, state: .passed, word: "Passed"), at: at) }
        let model = TimelineModel(days: [
            TimelineDay(id: "today", relative: "Today", date: "13 Nov", span: nil, items: [run("now"), entry("a"), run("old"), run("older"), entry("b")]),
        ])
        let lines = TimelineSection.lines(model, idle: nil, clock: { _ in "" })
        let open: Set<String> = ["now", "older"]
        let segments = TimelineSection.segments(lines) { open.contains($0.id) }
        func ids(_ segment: TimelineSection.Segment) -> [String] {
            switch segment {
            case let .lazy(_, lines): ["lazy"] + lines.map(\.id)
            case let .eager(lines): ["eager"] + lines.map(\.id)
            }
        }
        XCTAssertEqual(segments.map(ids), [
            ["lazy", "day-today"],
            ["eager", run("now").id],
            ["lazy", entry("a").id, run("old").id],
            ["eager", run("older").id],
            ["lazy", entry("b").id],
        ])
        let stretchIDs = ["lazy-head", "eager-\(run("now").id)", "lazy-after-\(run("now").id)", "eager-\(run("older").id)", "lazy-after-\(run("older").id)"]
        XCTAssertEqual(segments.map(\.id), stretchIDs)

        // A stretch is known by the unfolded run before it, not by its first line: an event landing at the head of the
        // history under the run now, as every event does while it works, keeps every stretch's identity, so no lazy
        // stack is torn down and built again.
        let grown = TimelineModel(days: [
            TimelineDay(id: "today", relative: "Today", date: "13 Nov", span: nil, items: [run("now"), entry("new"), entry("a"), run("old"), run("older"), entry("b")]),
        ])
        let grownSegments = TimelineSection.segments(TimelineSection.lines(grown, idle: nil, clock: { _ in "" })) { open.contains($0.id) }
        XCTAssertEqual(grownSegments.map(\.id), stretchIDs)
        XCTAssertEqual(grownSegments.map(ids)[2], ["lazy", entry("new").id, entry("a").id, run("old").id])

        // Every run folded: one lazy stretch of every line; no line, no stretch.
        XCTAssertEqual(TimelineSection.segments(lines) { _ in false }, [.lazy(after: nil, lines)])
        XCTAssertEqual(TimelineSection.segments([]) { _ in true }, [])
    }

    /// QA's hang on TP-1688: a step unfolded into a conversation taller than the window, in a long history the lazy
    /// stack makes. The run now's tall conversation and an older run unfolded are drawn whole, the history around them
    /// stays lazy, and the page stops laying itself out.
    func testALongHistoryWithATallUnfoldedConversationSettlesAndStaysLazy() throws {
        let model = Self.longModelWithATallRunNow()
        let older = try XCTUnwrap(model.items.compactMap(\.run).dropFirst(3).first)
        let lines = TimelineSection.lines(model, idle: nil, clock: { _ in "" })
        let unfolded: Set<String> = ["run-now", older.id]
        XCTAssertEqual(TimelineSection.segments(lines) { unfolded.contains($0.id) }.count(where: { if case .eager = $0 { true } else { false } }), 2)

        TimelineRowBodies.recorded = []
        let page = ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                TimelineSection(model: model, transcripts: StepTranscripts { _ in .unreachable }, calendar: utc, unfoldedRuns: unfolded)
            }
            .padding(24)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        let host = CountingHost(rootView: page)
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        spin(0.3)
        host.layoutSubtreeIfNeeded()
        spin(0.3)

        let settled = host.layouts
        spin(0.5)
        XCTAssertEqual(host.layouts, settled, "the page kept laying itself out")
        XCTAssertFalse(host.needsLayout)
        // The run now is made; the history under its tall conversation is not.
        let made = TimelineRowBodies.recorded ?? []
        XCTAssertTrue(made.contains("run-run-now"))
        XCTAssertLessThan(Set(made).count, Self.firstDisplayBound)
        XCTAssertFalse(made.contains("entry-e1"))
        withExtendedLifetime(host) {}
    }

    // MARK: - The flat list of lines

    func testTheLinesAreEachDaysSeparatorThenItsItemsWithTheMarkerAndTheIdleLine() {
        let at = Self.start
        let first = TimelineItem.entry(TimelineEntry(id: "a", kind: .phase, at: at, title: "A", actor: "Symphony"))
        let second = TimelineItem.entry(TimelineEntry(id: "b", kind: .note, at: at, title: "B", actor: "Tony"))
        let model = TimelineModel(
            days: [
                TimelineDay(id: "today", relative: "Today", date: "13 Nov", span: nil, items: [first]),
                TimelineDay(id: "yesterday", relative: "Yesterday", date: "12 Nov", span: nil, items: [second]),
            ],
            marker: TimelineMarker(lookedAt: at, before: second.id)
        )
        let idle = TimelineIdleLine(kind: .you, word: "Waiting on you", detail: nil)
        let lines = TimelineSection.lines(model, idle: idle, clock: { _ in "16:50" })
        XCTAssertEqual(lines.map(\.id), ["day-today", "idle", first.id, "day-yesterday", "marker-\(second.id)", second.id])
        XCTAssertEqual(lines[4], .marker(before: second.id, text: TicketMarksRead.markerText(at, clock: { _ in "16:50" })))

        // An empty timeline holds only the idle line; without one, nothing.
        XCTAssertEqual(TimelineSection.lines(TimelineModel(days: []), idle: idle, clock: { _ in "" }).map(\.id), ["idle"])
        XCTAssertEqual(TimelineSection.lines(TimelineModel(days: []), idle: nil, clock: { _ in "" }), [])
        XCTAssertEqual(TimelineSection.lines(model, idle: nil, clock: { _ in "" }).count, 5)
    }

    func testTheRuleLineJoinsAnEntryToTheEntryUnderItInItsDay() {
        let at = Self.start
        func entry(_ id: String) -> TimelineItem { .entry(TimelineEntry(id: id, kind: .phase, at: at, title: id, actor: "Symphony")) }
        let run = TimelineItem.run(RunGroupModel(id: "r", title: "Run", state: .passed, word: "Passed"), at: at)
        let model = TimelineModel(days: [
            TimelineDay(id: "today", relative: "Today", date: "13 Nov", span: nil, items: [entry("a"), entry("b"), run, entry("c")]),
            TimelineDay(id: "yesterday", relative: "Yesterday", date: "12 Nov", span: nil, items: [entry("d"), entry("e")]),
        ])
        let lines = TimelineSection.lines(model, idle: nil, clock: { _ in "" })
        // a joins b; b stops at the run; c is the day's last; d joins e; the day's separator breaks the line.
        XCTAssertEqual(TimelineSection.connected(lines), [entry("a").id, entry("d").id])
    }

    // MARK: - The page keeps its place when the timeline grows above it

    func testAGrowthAboveWhatThePageShowsIsScrolledAwayOnce() {
        let growth = TimelineGrowth()
        let now = Self.start
        growth.top = -400
        growth.grew(now: now)
        XCTAssertEqual(growth.compensation(for: 44, now: now.addingTimeInterval(0.1)), 44)
        // Answered once: the next height change is something else.
        XCTAssertEqual(growth.compensation(for: 44, now: now.addingTimeInterval(0.2)), 0)
    }

    func testAGrowthWhileTheTimelinesTopIsInViewMovesNothing() {
        let growth = TimelineGrowth()
        growth.top = 120
        growth.grew(now: Self.start)
        XCTAssertEqual(growth.compensation(for: 44, now: Self.start), 0)
        // Scrolled past, then back up before the change came: the top is in view again.
        growth.top = -10
        growth.grew(now: Self.start)
        growth.top = 30
        growth.grew(now: Self.start)
        XCTAssertEqual(growth.compensation(for: 44, now: Self.start), 0)
    }

    func testAHeightChangeLongAfterTheGrowthOrWithoutOneMovesNothing() {
        let growth = TimelineGrowth()
        XCTAssertEqual(growth.compensation(for: 44, now: Self.start), 0)
        growth.top = -400
        growth.grew(now: Self.start)
        // No height change yet: the growth stays pending.
        XCTAssertEqual(growth.compensation(for: 0, now: Self.start), 0)
        XCTAssertEqual(growth.compensation(for: 44, now: Self.start.addingTimeInterval(TimelineGrowth.window + 0.1)), 0)
    }
}

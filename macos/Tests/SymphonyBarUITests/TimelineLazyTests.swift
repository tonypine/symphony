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

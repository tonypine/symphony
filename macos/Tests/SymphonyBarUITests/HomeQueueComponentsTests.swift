import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1608: the Home queue's components in the design system, before the Home screen uses them: the slot card, its
/// empty outline and its strip line, the checks bar, the token line, the slot count control and the queue row.
@MainActor
final class HomeQueueComponentsTests: XCTestCase {
    // MARK: - Sample tickets, as the gallery's stories draw them

    private func slot(_ status: DesignTokens.Status, stage: Int = 2, pullRequest: Bool = true) -> SlotCardModel {
        SlotCardModel(
            identifier: "TP-1576", title: "Rebuild the Settings page's sections", epic: "Settings as a real page", status: status, stage: stage,
            since: "2 h 40 min", word: "QA", sentence: "walking the Settings sections, check 6 of 9",
            tokens: [
                TokenLine.Stage(name: "Coding", tokens: 9_600_000, series: .series1),
                TokenLine.Stage(name: "Code Review", tokens: 3_100_000, series: .series2),
                TokenLine.Stage(name: "QA", tokens: 8_700_000, series: .series3),
                TokenLine.Stage(name: "Merging", tokens: 0, series: .series4),
            ],
            tokenTotal: 21_400_000, tokenCap: 100_000_000, plan: "Each Settings section is rebuilt from Gallery components.", proved: 5,
            checks: 9, next: "The Runs section saves a changed model and shows Saved.",
            pullRequest: pullRequest
                ? SlotCardModel.PullRequest(
                    number: "#1041", size: "38 files · +1,412 −986", branch: "auto/TP-1576 into main", ci: .init(.done, "18 checks passed"),
                    review: .init(.done, "Approved on 507db3b")
                )
                : nil
        )
    }

    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.environment(\.offscreenSnapshot, true))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // MARK: - c1: the Gallery lists the components and their stories

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testTheGalleryListsEachHomeQueueComponentWithItsStories() throws {
        let variations = try String(contentsOf: Self.root.appendingPathComponent("macos/Gallery/component-variations.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        for name in [
            "slot-card-now", "slot-card-waiting-on-you", "slot-card-needs-attention", "slot-card-empty", "slot-strip-line-lines",
            "checks-bar-five-of-nine", "token-line-three-stages", "slot-count-three-slots", "queue-row-at-rest", "queue-row-hovered",
            "queue-row-dragged",
        ] {
            XCTAssertTrue(variations.contains(name), "the gallery lists \(name)")
        }
        let entries = try String(contentsOf: Self.root.appendingPathComponent("macos/Gallery/Entries.swift"), encoding: .utf8)
        for id in ["slot-card", "slot-strip-line", "checks-bar", "token-line", "slot-count", "queue-row"] {
            XCTAssertTrue(entries.contains("id: \"\(id)\""), "the gallery has an entry for \(id)")
        }
    }

    // MARK: - c2: the slot card's header and columns

    func testAnswerIsOnTheHeaderOnlyWhileTheCardWaitsOnThePerson() {
        XCTAssertEqual(slot(.you).actions, [.answer, .message, .stop])
        XCTAssertEqual(slot(.working).actions, [.message, .stop])
        XCTAssertEqual(slot(.problem).actions, [.message, .stop])
        XCTAssertEqual(SlotCardModel.Action.allCases.map(\.rawValue), ["Answer…", "Message…", "Stop"])
    }

    func testTheCardHasTheThreeLabelledColumnsWithStatusAboutHalfOfIt() {
        XCTAssertEqual(SlotCard.columns, ["Status", "Plan", "Pull request"])
        let width: CGFloat = 1080
        let columns = SlotColumnsLayout.columns(width: width)
        XCTAssertEqual(columns.count, 3)
        let separators = SlotColumnsLayout.separators(width: width)
        XCTAssertEqual(separators.count, 2)
        let statusShare = (separators[0]) / width
        XCTAssertGreaterThan(statusShare, 0.45)
        XCTAssertLessThan(statusShare, 0.55)
        // Each column's content sits inside its hairlines, the first at the card's edge, the last at its end.
        XCTAssertEqual(columns[0].x, 0)
        XCTAssertEqual(columns[1].x, separators[0] + DesignTokens.HomeQueue.columnInset, accuracy: 0.5)
        XCTAssertEqual(columns[2].x + columns[2].width, width, accuracy: 0.5)
        XCTAssertLessThanOrEqual(columns[0].x + columns[0].width, separators[0] - DesignTokens.HomeQueue.columnInset + 0.5)
    }

    func testTheCardDrawsItsHeaderOnOneLineAndItsRowsUnderIt() {
        let card = fittingSize(SlotCard(slot: 1, ticket: slot(.working)).frame(width: 1120))
        XCTAssertEqual(card.width, 1120, accuracy: 0.5)
        let queue = DesignTokens.HomeQueue.self
        XCTAssertGreaterThan(card.height, queue.cardTopPadding + queue.headerHeight + queue.cardGap + queue.cardBottomPadding + 3 * queue.rowGap)
        // Without a pull request the card is drawn too, its column saying it is not opened yet.
        XCTAssertGreaterThan(fittingSize(SlotCard(slot: 1, ticket: slot(.problem, pullRequest: false)).frame(width: 1120)).height, 0)
    }

    func testAnEmptySlotIsAnOutlineReadingItsNumber() {
        XCTAssertEqual(SlotCard.emptyLabel(3), "Slot 3")
        let empty = fittingSize(SlotCard(slot: 3, ticket: nil).frame(width: 600))
        XCTAssertEqual(empty.height, DesignTokens.HomeQueue.emptyHeight, accuracy: 0.5)
        let strip = fittingSize(SlotStripLine(slot: 3, ticket: nil, numberWidth: 20).frame(width: 600))
        XCTAssertEqual(strip.height, DesignTokens.HomeQueue.stripHeight, accuracy: 0.5)
    }

    func testTheStripLineIsOneLine() {
        let line = fittingSize(SlotStripLine(slot: 1, ticket: slot(.working), numberWidth: 20).frame(width: 900))
        XCTAssertEqual(line.height, DesignTokens.HomeQueue.stripHeight, accuracy: 0.5)
    }

    // MARK: - c3: the ticket page's stepper, without run counts and timings

    func testTheCardsStepperIsTheTicketPagesWithItsWordsAlone() {
        let working = slot(.working, stage: 2)
        XCTAssertEqual(working.stages.map(\.title), ["Coding", "Code Review", "QA", "Merging", "Done"])
        XCTAssertEqual(working.stages.map(\.line), ["Passed", "Passed", "Now", "Not yet", "Not yet"])
        XCTAssertEqual(working.stages.map(\.state), [.passed, .passed, .current, .notYet, .notYet])
        XCTAssertEqual(working.stages[2].status, .working)
        XCTAssertEqual(slot(.you, stage: 1).stages.map(\.line), ["Passed", "Waiting on you", "Not yet", "Not yet", "Not yet"])
        XCTAssertEqual(slot(.problem, stage: 0).stages[0].line, "Needs attention")
        XCTAssertEqual(slot(.problem, stage: 0).stages[0].status, .problem)
        for stage in working.stages { XCTAssertFalse(stage.line.contains("·"), "no visits or time: \(stage.line)") }
        // The very component the ticket page draws.
        let stepper: StageStrip = SlotCard.stepper(working)
        XCTAssertEqual(stepper.stages, working.stages)
    }

    /// The card's five stages stand side by side in its Status column, on a laptop's 1120 pt card, as the prototype
    /// draws them; the ticket page's equal cells would stack there.
    func testTheCardsStagesStandSideBySideInTheStatusColumn() {
        let body = 1120 - 2 * CGFloat(DesignTokens.HomeQueue.cardSidePadding)
        let status = SlotColumnsLayout.columns(width: body)[0].width
        let wide = fittingSize(SlotCard.stepper(slot(.working)).frame(width: 1600)).height
        for ticket in [slot(.working), slot(.you, stage: 1), slot(.problem, stage: 0)] {
            let stepper = SlotCard.stepper(ticket)
            XCTAssertEqual(stepper.fit, .content)
            XCTAssertLessThanOrEqual(stepper.sideBySideWidth, status)
            XCTAssertEqual(fittingSize(stepper.frame(width: status)).height, wide, accuracy: 0.5, "one row of tiles")
        }
        // The ticket page's strip keeps its equal cells and its stacked fallback.
        let page = StageStrip(stages: slot(.working).stages)
        XCTAssertEqual(page.fit, .equal)
        XCTAssertEqual(page.sideBySideWidth, LifecycleSection.stripWidth(titles: SlotCardModel.stageNames.map(\.name)))
        XCTAssertGreaterThan(fittingSize(page.frame(width: 300)).height, wide)
        XCTAssertEqual(LifecycleSection.contentStripWidth(stages: []), 0)
    }

    func testTheTicketPagesStepperStillSaysItsVisitsAndTime() {
        let lifecycle = TicketLifecycle(
            current: "coding",
            stages: [
                TicketLifecycle.Stage(id: "coding", name: "Coding", state: .current, visits: 2, timeMs: 3_600_000),
                TicketLifecycle.Stage(id: "code_review", name: "Code Review", state: .notYet),
                TicketLifecycle.Stage(id: "qa", name: "QA", state: .notYet),
                TicketLifecycle.Stage(id: "merging", name: "Merging", state: .notYet),
                TicketLifecycle.Stage(id: "done", name: "Done", state: .notYet),
            ],
            tokens: TicketLifecycle.Tokens(total: 0)
        )
        let model = LifecycleModel.build(lifecycle)
        XCTAssertEqual(model.stages.map(\.title), ["Coding", "Code Review", "QA", "Merging", "Done"])
        XCTAssertTrue(model.stages[0].line.hasPrefix("Now · "), model.stages[0].line)
        XCTAssertTrue(model.stages[0].line.contains("times"), model.stages[0].line)
        XCTAssertGreaterThan(fittingSize(LifecycleSection(model: model).frame(width: LifecycleSection.laptopWidth)).height, 0)
    }

    // MARK: - c4: the checks bar and the token line

    func testTheChecksBarReadsItsCount() {
        XCTAssertEqual(ChecksBar(proved: 5, total: 9).text, "5 of 9 checks proved")
        XCTAssertEqual(ChecksBar(proved: 1, total: 1).text, "1 of 1 check proved")
        XCTAssertEqual(DesignTokens.HomeQueue.checksFraction(proved: 5, total: 10), 0.5)
        XCTAssertEqual(DesignTokens.HomeQueue.checksFraction(proved: 3, total: 0), 0)
        XCTAssertEqual(DesignTokens.HomeQueue.checksFraction(proved: 12, total: 9), 1)
    }

    func testTheTokenLineHasADotPerStageThatRanAndTheTotalWithoutABar() {
        let ticket = slot(.working)
        let line = TokenLine(stages: ticket.tokens, total: ticket.tokenTotal, cap: ticket.tokenCap)
        XCTAssertEqual(line.totalText, "21.4M of 100M tokens · 21 %")
        XCTAssertEqual(line.shown.map(\.name), ["Coding", "Code Review", "QA"], "Merging has not run: no dot")
        XCTAssertEqual(line.shown.map(\.value), ["9.6M", "3.1M", "8.7M"])
        XCTAssertEqual(line.accessibilityText, "Coding 9.6M, Code Review 3.1M, QA 8.7M, 21.4M of 100M tokens · 21 %")
        XCTAssertEqual(DesignTokens.HomeQueue.tokens(2_400_000, cap: nil), "2.4M tokens")
        // One line of secondary text: no bar under or beside it.
        let size = fittingSize(line.frame(width: 560))
        XCTAssertLessThanOrEqual(size.height, DesignTokens.TypeStyle.secondary.scaledLineHeight(by: DesignTokens.TypeStyle.textScale) + 1)
    }

    // MARK: - c5: the slot count takes 1 to 6

    func testTheSlotCountTakesOneToSixAndNoOther() {
        XCTAssertEqual(SlotCountControl.range, 1...6)
        var value = 1
        let control = SlotCountControl(count: Binding(get: { value }, set: { value = $0 }))
        var seen: Set<Int> = [value]
        for _ in 0..<10 {
            control.step(1)
            seen.insert(value)
        }
        XCTAssertEqual(value, 6, "it stops at six")
        for _ in 0..<10 {
            control.step(-1)
            seen.insert(value)
        }
        XCTAssertEqual(value, 1, "it stops at one")
        XCTAssertEqual(seen, Set(1...6))
        XCTAssertFalse(SlotCountControl.canStep(1, by: -1))
        XCTAssertFalse(SlotCountControl.canStep(6, by: 1))
        XCTAssertTrue(SlotCountControl.canStep(3, by: 1))
        XCTAssertTrue(SlotCountControl.canStep(3, by: -1))
        XCTAssertEqual(DesignTokens.HomeQueue.slots(9, step: 0), 6)
        XCTAssertEqual(DesignTokens.HomeQueue.slots(-2, step: 0), 1)
        XCTAssertEqual(DesignTokens.HomeQueue.slotsWord(1), "1 slot")
        XCTAssertEqual(DesignTokens.HomeQueue.slotsWord(3), "3 slots")
        XCTAssertGreaterThan(fittingSize(control).width, 0)
    }

    // MARK: - c6: on hover the handle and Start take the number's and the repo's places, and nothing shifts

    private let row = QueueRowModel(
        number: 1_243, identifier: "TP-977", title: "Give agents one tool to request a protected change, and pause the ticket on it",
        lead: .glyph("clock", .textSecondary), after: "TP-976", marks: [.init(.you, "Needs your approval")], repo: "symphony"
    )

    /// Where each part of the row stands, in a row 900 wide, drawn in `look`.
    private func parts(_ look: QueueRow.Look) -> [QueueRow.Part: CGRect] {
        let probes = Dictionary(uniqueKeysWithValues: QueueRow.Part.allCases.map { ($0, NSView()) })
        let width = QueueRow.numberWidth(widest: row.number)
        let host = NSHostingView(
            rootView: QueueRow(row, numberWidth: width, look: look)
                .frame(width: 900)
                .environment(\.queueRowProbes, probes)
                .environment(\.offscreenSnapshot, true)
        )
        host.frame = CGRect(x: 0, y: 0, width: 900, height: DesignTokens.HomeQueue.rowHeight)
        host.layoutSubtreeIfNeeded()
        return probes.mapValues { $0.convert($0.bounds, to: host) }
    }

    /// Where each part of a strip line stands, in a line 900 wide on the same number cell as `parts`.
    private func stripParts() -> [QueueRow.Part: CGRect] {
        let probes = Dictionary(uniqueKeysWithValues: QueueRow.Part.allCases.map { ($0, NSView()) })
        let host = NSHostingView(
            rootView: SlotStripLine(slot: 1, ticket: slot(.working), numberWidth: QueueRow.numberWidth(widest: row.number))
                .frame(width: 900)
                .environment(\.queueRowProbes, probes)
                .environment(\.offscreenSnapshot, true)
        )
        host.frame = CGRect(x: 0, y: 0, width: 900, height: DesignTokens.HomeQueue.stripHeight)
        host.layoutSubtreeIfNeeded()
        return probes.mapValues { $0.convert($0.bounds, to: host) }
    }

    /// TP-1609 QA (steps 8 and 10): the strip's dot, identifier and title start where the queue row's do, its state
    /// badge ends where the row's badges end and its time ends where the row's repo ends, so the strip stands over the
    /// queue's columns. A gap or a cell width changed in one of them and not the other fails here.
    func testTheStripLinesColumnsStandOverTheQueueRowsColumns() {
        let row = parts(.rest)
        let strip = stripParts()
        for part in [QueueRow.Part.lead, .identifier, .title] {
            let line = strip[part] ?? .null, under = row[part] ?? .null
            XCTAssertGreaterThan(line.width, 0, "the strip draws its \(part)")
            XCTAssertEqual(line.minX, under.minX, accuracy: 0.5, "the strip's \(part) starts over the row's")
        }
        XCTAssertEqual((strip[.marks] ?? .null).maxX, (row[.marks] ?? .null).maxX, accuracy: 0.5, "the state badge ends over the row's badges")
        XCTAssertEqual((strip[.repo] ?? .null).maxX, (row[.repo] ?? .null).maxX, accuracy: 0.5, "the time ends over the row's repo")
    }

    func testOnHoverTheHandleAndStartTakeTheNumbersAndTheReposPlacesAndNothingShifts() {
        let rest = parts(.rest)
        let hover = parts(.hover)
        let dragged = parts(.dragged)
        for part in [QueueRow.Part.lead, .identifier, .title, .after, .marks] {
            let at = rest[part] ?? .null
            XCTAssertGreaterThan(at.width, 0, "\(part) is drawn")
            XCTAssertEqual(hover[part] ?? .null, at, "\(part) keeps its place and width on hover")
            XCTAssertEqual(dragged[part] ?? .null, at, "\(part) keeps its place and width when dragged")
        }
        for look in [rest, hover] {
            let number = look[.number] ?? .null, handle = look[.handle] ?? .null
            XCTAssertEqual(number.midX, handle.midX, accuracy: 0.5, "the handle stands where the number is")
            let repo = look[.repo] ?? .null, start = look[.start] ?? .null
            XCTAssertEqual(repo.maxX, start.maxX, accuracy: 0.5, "Start stands where the repo is")
        }
        XCTAssertEqual(rest[.number], hover[.number])
        XCTAssertEqual(rest[.repo], hover[.repo])
        XCTAssertFalse(QueueRow.handles(.rest))
        XCTAssertTrue(QueueRow.handles(.hover))
        XCTAssertTrue(QueueRow.handles(.dragged))
        XCTAssertTrue(QueueRow.starts(.hover))
        XCTAssertFalse(QueueRow.starts(.rest))
        XCTAssertFalse(QueueRow.starts(.dragged))
    }

    func testTheNumberCellIsAsWideAsTheWidestNumberOnScreen() {
        XCTAssertEqual(DesignTokens.HomeQueue.number(1_243), "1,243")
        XCTAssertEqual(DesignTokens.HomeQueue.numberTemplate(widest: 1_243), "0,000")
        XCTAssertEqual(DesignTokens.HomeQueue.numberTemplate(widest: 7), "00")
        XCTAssertEqual(QueueRow.numberWidth(widest: 7), QueueRow.numberWidth(widest: 42), "never less than two digits")
        XCTAssertGreaterThan(QueueRow.numberWidth(widest: 1_243), QueueRow.numberWidth(widest: 999))
        XCTAssertGreaterThan(QueueRow.identifierWidth, 0)
    }
}

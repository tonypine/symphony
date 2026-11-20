import Foundation
@testable import SymphonyBarCore
import XCTest

/// The ticket read's `brief`, `ticket` and `workspace`, the ticket's decisions and its runs' models as the facts rail's
/// Decisions and Details panels say them, from the fixtures in `Tests/Fixtures/facts-rail`: a ticket with every fact,
/// one with fewer, and one Symphony holds nothing of. The read's `note`, which an older Symphony still serves, is not
/// read.
@MainActor
final class FactsRailDetailsTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/facts-rail")

    private let reference = ISO8601DateFormatter().date(from: "2026-11-10T15:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
    }

    private func read(_ name: String) throws -> TicketDetailsRead {
        try XCTUnwrap(TicketDetailsRead.decode(try data(name)))
    }

    private func runs() throws -> [String: TicketEventsPayload.Run] {
        try XCTUnwrap(TicketEventsPayload.decode(try data("details-events"))).runs
    }

    // MARK: - Decoding

    func testTheTicketReadDecodesTheTicketTheBriefAndTheWorkspace() throws {
        let read = try read("details")
        XCTAssertEqual(read.repoKey, "symphony")
        XCTAssertEqual(read.ticket, TicketRecordRead(
            title: "The facts rail's Note, Decisions and Details panels", phase: "In Progress", priority: 1,
            labels: ["skip-update-hold", "qa:fixture"]
        ))
        XCTAssertEqual(read.brief?.at, ISO8601DateFormatter().date(from: "2026-11-10T09:12:00Z"))
        XCTAssertNotNil(read.brief?.walkthrough)
        XCTAssertEqual(read.workspace, TicketWorkspaceRead(path: "/Users/tonypine/symphony-workspaces/symphony/TP-1447"))
    }

    func testAReadSymphonyHoldsNothingOfDecodesEmptyAndAnythingButAnObjectIsNone() throws {
        let read = try read("details-empty")
        XCTAssertEqual(read, TicketDetailsRead(ticket: TicketRecordRead()))
        XCTAssertEqual(TicketDetailsRead.decode(Data("{}".utf8)), TicketDetailsRead())
        XCTAssertEqual(
            TicketDetailsRead.decode(Data(#"{"note":{"text":null},"brief":{},"ticket":{}}"#.utf8)),
            TicketDetailsRead(ticket: TicketRecordRead(), brief: TicketBriefRead(text: ""))
        )
        XCTAssertNil(TicketDetailsRead.decode(Data("[]".utf8)))
    }

    // MARK: - The Decisions panel

    func testDecisionsReadNewestFirstEachWithItsQuestionAndAnswer() {
        let model = DecisionsPanelModel.build([
            TicketDecision(
                id: "D1", date: "2026-11-09", title: "Keep the facts rail at 340 pt",
                question: "How wide is the rail on a laptop?", answer: "340 pt, as the catalog shows.", scope: "The rail's width is fixed."
            ),
            TicketDecision(id: "D2", date: "2026-11-10", question: "  ", answer: "Fold the agent description by default."),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["D2", "D1"])
        XCTAssertEqual(model.rows[0], DecisionsPanelModel.Row(
            id: "D2", headline: "Fold the agent description by default.", date: "2026-11-10", question: nil,
            answer: "Fold the agent description by default.", scope: nil,
            accessibilityLabel: "Decision D2, Fold the agent description by default., decided 2026-11-10"
        ))
        XCTAssertEqual(model.rows[1].headline, "Keep the facts rail at 340 pt")
        XCTAssertEqual(model.rows[1].question, "How wide is the rail on a laptop?")
        XCTAssertEqual(model.rows[1].answer, "340 pt, as the catalog shows.")
        XCTAssertEqual(model.rows[1].scope, "The rail's width is fixed.")
        XCTAssertEqual(DecisionsPanelModel.build([]).rows, [])
        XCTAssertEqual(DecisionsPanelModel.build([TicketDecision(id: "D3", answer: "Yes.")]).rows[0].accessibilityLabel, "Decision D3, Yes.")
    }

    // MARK: - The Details panel

    func testDetailsSayTheRepoPriorityLabelsWorkspaceModelsLinksAndBrief() throws {
        let pr = TicketPullRequest(number: 870, url: URL(string: "https://github.com/acme/symphony/pull/870"))
        let model = DetailsPanelModel.build(
            try read("details"), runs: try runs(), linearURL: URL(string: "https://linear.app/acme/issue/TP-1447"), pullRequest: pr,
            description: "  ## Goal\nThree more panels.  ", reference: reference, calendar: utc
        )
        XCTAssertEqual(model.repo, "symphony")
        XCTAssertEqual(model.priority, "Urgent")
        XCTAssertEqual(model.labels, ["skip-update-hold", "qa:fixture"])
        XCTAssertEqual(model.workspace, "/Users/tonypine/symphony-workspaces/symphony/TP-1447")
        XCTAssertNil(model.workspaceHost)
        XCTAssertEqual(model.models, [
            DetailsPanelModel.RunModel(id: "run-1", run: "Implementation run 1", model: "Claude Opus 5.5 · high effort"),
            DetailsPanelModel.RunModel(id: "run-2", run: "Code Review run 1", model: "Claude Sonnet 5.5"),
            DetailsPanelModel.RunModel(id: "run-3", run: "Implementation run 3", model: "Claude Opus 5.5 · high effort"),
        ])
        XCTAssertEqual(model.modelsSummary, "3 runs · Claude Opus 5.5, Claude Sonnet 5.5")
        XCTAssertEqual(model.links.map(\.title), ["Ticket in Linear", "PR #870 on GitHub"])
        XCTAssertEqual(model.links.map(\.id), ["Ticket in Linear", "PR #870 on GitHub"])
        XCTAssertEqual(model.brief?.written, "Written today at 09:12")
        XCTAssertNotNil(model.brief?.walkthrough)
        XCTAssertEqual(model.agentDescription, "## Goal\nThree more panels.")
    }

    func testDetailsOfATicketSymphonyHoldsNothingOfLeaveTheUnknownOut() throws {
        let model = DetailsPanelModel.build(
            try read("details-empty"), runs: [:], linearURL: nil, pullRequest: TicketPullRequest(number: 1), description: " ",
            reference: reference, calendar: utc
        )
        XCTAssertNil(model.repo)
        XCTAssertNil(model.priority)
        XCTAssertEqual(model.labels, [])
        XCTAssertNil(model.workspace)
        XCTAssertEqual(model.models, [])
        XCTAssertNil(model.modelsSummary)
        XCTAssertEqual(model.links, [])
        XCTAssertNil(model.brief)
        XCTAssertNil(model.agentDescription)
        XCTAssertEqual(DetailsPanelModel.build(nil, runs: [:], linearURL: nil, pullRequest: nil, description: nil, reference: reference).repo, nil)
    }

    func testEachPriorityHasItsWordAndAWorkspaceElsewhereNamesItsMachine() {
        XCTAssertEqual([0, 1, 2, 3, 4, 9].map(DetailsPanelModel.priorityWord), ["No priority", "Urgent", "High", "Medium", "Low", nil])
        let read = TicketDetailsRead(workspace: TicketWorkspaceRead(path: "/srv/w/TP-1", host: "builder-2"))
        XCTAssertEqual(DetailsPanelModel.build(read, runs: [:], linearURL: nil, pullRequest: nil, description: nil, reference: reference).workspaceHost, "builder-2")
        let blank = TicketDetailsRead(brief: TicketBriefRead(text: " ", walkthrough: "Steps"))
        XCTAssertNil(DetailsPanelModel.build(blank, runs: [:], linearURL: nil, pullRequest: nil, description: nil, reference: reference).brief)
        let undated = TicketDetailsRead(brief: TicketBriefRead(text: "What it does.", walkthrough: " "))
        let brief = DetailsPanelModel.build(undated, runs: [:], linearURL: nil, pullRequest: nil, description: nil, reference: reference).brief
        XCTAssertEqual(brief, DetailsPanelModel.Brief(text: "What it does.", walkthrough: nil, written: nil))
    }

    func testOneRunsModelIsSummedUpAsOneRun() {
        let runs = ["a": TicketEventsPayload.Run(runID: "a", runKind: "implementation", runNumber: 1, model: "gpt-6", effort: " ")]
        let models = DetailsPanelModel.runModels(runs)
        XCTAssertEqual(models.map(\.model), ["GPT 6"])
        XCTAssertEqual(DetailsPanelModel.modelsSummary(models), "1 run · GPT 6")
    }
}

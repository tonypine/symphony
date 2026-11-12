import Foundation
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// TP-1480: the ticket page's cards and the Timeline's rows draw again only when what they show changed. A new closure
/// for the same action, which the page makes each time it draws, doesn't open the gate.
@MainActor
final class EquatableGatesTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_791_000_000)

    func testTheFactsRailCardsCompareTheirModelsAndNotTheirActions() {
        let connected = ConnectedPanelModel.build(nil, reference: reference)
        XCTAssertEqual(
            ConnectedPanel(model: connected, openTicket: { _ in }, openInitiatives: {}),
            ConnectedPanel(model: connected, openTicket: { _ in XCTFail() }, openInitiatives: { XCTFail() })
        )
        XCTAssertEqual(PullRequestPanel(model: nil, open: { _ in }), PullRequestPanel(model: nil, open: { _ in XCTFail() }))

        let one = DecisionsPanelModel.build([TicketDecision(id: "D1", answer: "Keep it")])
        let two = DecisionsPanelModel.build([TicketDecision(id: "D1", answer: "Keep it"), TicketDecision(id: "D2", answer: "Drop it")])
        XCTAssertEqual(DecisionsPanel(model: one), DecisionsPanel(model: one))
        XCTAssertNotEqual(DecisionsPanel(model: one), DecisionsPanel(model: two))

        let details = DetailsPanelModel.build(nil, runs: [:], linearURL: nil, pullRequest: nil, description: nil, reference: reference)
        let linked = DetailsPanelModel.build(
            nil, runs: [:], linearURL: URL(string: "https://linear.app/t/issue/TP-1"), pullRequest: nil, description: nil, reference: reference
        )
        XCTAssertEqual(DetailsPanel(model: details, open: { _ in }), DetailsPanel(model: details, open: { _ in XCTFail() }, copy: { _ in }))
        XCTAssertNotEqual(DetailsPanel(model: details, open: { _ in }), DetailsPanel(model: linked, open: { _ in }))

        let note = NotePanelModel.build(note: nil, move: nil, runs: [:], reference: reference)
        let composer = TicketNoteComposer()
        XCTAssertEqual(NotePanel(model: note, composer: composer, save: {}), NotePanel(model: note, composer: composer, save: { XCTFail() }))
        XCTAssertNotEqual(NotePanel(model: note, composer: composer, save: {}), NotePanel(model: note, composer: TicketNoteComposer(), save: {}))
    }

    func testTheLifecycleCardComparesItsModel() {
        let lifecycle = TicketLifecycle(
            current: "coding", stages: [.init(id: "coding", name: "Coding", state: .current)], tokens: .init(total: 0)
        )
        let model = LifecycleModel.build(lifecycle)
        XCTAssertEqual(LifecycleSection(model: model), LifecycleSection(model: model))
    }

    func testATimelineRowComparesWhatItShowsAndNotItsSelect() {
        let entry = TimelineEntry(id: "a1", kind: .phase, at: reference, title: "Moved to Todo from Backlog", actor: "Tony")
        let row = TimelineEntryRow(entry: entry, time: "09:00", selected: false) {}
        XCTAssertEqual(row, TimelineEntryRow(entry: entry, time: "09:00", selected: false) { XCTFail() })
        XCTAssertNotEqual(row, TimelineEntryRow(entry: entry, time: "09:00", selected: true) {})
        XCTAssertNotEqual(row, TimelineEntryRow(entry: entry, time: "09:01", selected: false) {})
    }
}

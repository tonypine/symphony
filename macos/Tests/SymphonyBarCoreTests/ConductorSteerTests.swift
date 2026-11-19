import XCTest
@testable import SymphonyBarCore

/// The Conductor's steer of a running run (`conductor.steer`), from `Tests/Fixtures/timeline/conductor-steer.json`: one
/// entry inside the run's group, "Conductor steered" with the message whole, and no entry of its own on the timeline.
final class ConductorSteerTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/timeline/conductor-steer.json")

    private func model() throws -> TimelineModel {
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixture)))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return TimelineModel.build(history, reference: Date(timeIntervalSince1970: 1_791_450_000), calendar: utc)
    }

    func testTheSteerIsAnEntryInsideItsRunsGroupAndNoneOfItsOwn() throws {
        let model = try model()
        let runs = model.items.compactMap(\.run)
        let run = try XCTUnwrap(runs.first { $0.id == "run-2" })
        XCTAssertEqual(run.steers.map(\.text), ["The build fails the same way twice. Read its first error before you change the code again."])
        XCTAssertEqual(run.steers.first?.id, "s2")
        XCTAssertNotNil(run.steers.first?.at)
        XCTAssertEqual(RunSteer.title, "Conductor steered")

        let entries = model.items.filter { if case .entry = $0 { return true } else { return false } }
        XCTAssertTrue(entries.isEmpty, "the steer folds into its run's group")
    }

    func testOnlyASteerWithTextIsOne() throws {
        func event(_ type: String, text: String) throws -> TicketEventsPayload.Event {
            let json: [String: Any] = [
                "id": "e1", "seq": 1, "at": "2026-10-08T09:20:00Z", "type": type, "run_id": "run-2",
                "payload": ["text": text], "artifacts": [], "children": [],
            ]
            return try JSONDecoder().decode(TicketEventsPayload.Event.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertNotNil(RunSteer(event: try event("conductor.steer", text: "Read the error.")))
        XCTAssertNil(RunSteer(event: try event("conductor.steer", text: "  ")))
        XCTAssertNil(RunSteer(event: try event("note", text: "Read the error.")))
    }
}

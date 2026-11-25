import XCTest
@testable import SymphonyBarCore

/// TP-1677: QA mode's element report, which the QA driver reads (`SymphonyElixir.QaDriver.Elements`).
final class QAElementReportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-elements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func report(_ name: String = "queue-row-TP-1") -> QAElementReport {
        QAElementReport(
            at: Date(timeIntervalSince1970: 1_800_000_000), pid: 42,
            windows: [.init(number: 7, title: "Symphony", frame: .init(x: 0, y: 25, w: 1000, h: 500), key: true)],
            state: .init(page: "overview", pageTitle: "Home", ticket: "TP-9", selected: ["sidebar-home"], focused: []),
            elements: [
                .init(
                    name: name, frame: .init(x: 100.004, y: 100, w: 800, h: 32), visible: true, window: 7, selected: false,
                    focused: false, parts: ["title": .init(x: 180, y: 108, w: 300, h: 16)]
                ),
            ]
        )
    }

    /// The file the driver reads: `<QA root>/elements/<pid>.json`, the folder the driver's contract names.
    func testTheReportLivesUnderTheQARootOneFilePerProcess() {
        let qaMode = QAMode(root: root)
        XCTAssertEqual(QAMode.elementsFolder, "elements")
        XCTAssertEqual(qaMode.elementsReport(pid: 42), root.appendingPathComponent("elements/42.json"))
    }

    /// The keys the driver reads, in snake case, with frames to a hundredth of a point and the naming scheme.
    func testTheReportHoldsTheKeysTheDriverReads() throws {
        let data = try report().encoded()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["pid"] as? Int, 42)
        XCTAssertNotNil(json["at"] as? String)
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertEqual(state["page"] as? String, "overview")
        XCTAssertEqual(state["page_title"] as? String, "Home")
        XCTAssertEqual(state["ticket"] as? String, "TP-9")
        XCTAssertEqual(state["selected"] as? [String], ["sidebar-home"])
        let element = try XCTUnwrap((json["elements"] as? [[String: Any]])?.first)
        XCTAssertEqual(element["name"] as? String, "queue-row-TP-1")
        XCTAssertEqual(element["visible"] as? Bool, true)
        XCTAssertEqual(element["fully_visible"] as? Bool, true)
        XCTAssertEqual((element["shown"] as? [String: Double])?["h"], 32)
        XCTAssertEqual((element["frame"] as? [String: Double])?["x"], 100)
        XCTAssertEqual((element["parts"] as? [String: [String: Double]])?["title"]?["y"], 108)
        let windows = try XCTUnwrap(json["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.first?["key"] as? Bool, true)
        let names = try XCTUnwrap(json["names"] as? [[String: Any]])
        XCTAssertEqual(names.count, QAElementNames.scheme.count)

        XCTAssertEqual(try QAElementReport.decoded(data), report())
    }

    /// The writer replaces the file whole, and a burst of requests writes once, the last.
    func testTheWriterWritesTheLastRequestOfABurstAtomically() throws {
        let file = QAMode(root: root).elementsReport(pid: 42)
        let queue = DispatchQueue(label: "qa-elements-test")
        let writer = QAElementReportWriter(file: file, delay: 0.05, queue: queue)
        var built: [String] = []

        writer.schedule { built.append("first"); return self.report("first") }
        writer.schedule { built.append("second"); return self.report("second") }
        let written = expectation(description: "written")
        queue.asyncAfter(deadline: .now() + 0.3) { written.fulfill() }
        wait(for: [written], timeout: 5)

        XCTAssertEqual(queue.sync { built }, ["second"])
        XCTAssertEqual(try QAElementReport.decoded(Data(contentsOf: file)).elements.map(\.name), ["second"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["42.json"])
    }

    /// The scheme keeps the identifiers window tests already find rows by, and the playbook quotes every pattern,
    /// so a QA plan names elements without searching the code.
    func testTheSchemeKeepsTheOldIdentifiersAndThePlaybookQuotesIt() throws {
        XCTAssertEqual(QAElementNames.queueRow("TP-1"), "queue-row-TP-1")
        XCTAssertEqual(QAElementNames.doneRow("TP-1"), "done-row-TP-1")
        XCTAssertEqual(QAElementNames.queueDropLine, "queue-drop-line")
        XCTAssertEqual(QAElementNames.queueDoneCount, "queue-done-count")
        XCTAssertEqual(QAElementNames.recentlyDoneHead, "recently-done-head")
        XCTAssertEqual(QAElementNames.recentlyDoneRange, "recently-done-range")
        XCTAssertEqual(QAElementNames.slotCard(2), "slot-card-2")
        XCTAssertEqual(QAElementNames.slotLine(2), "slot-line-2")
        XCTAssertEqual(QAElementNames.epicSlotCard(1), "epic-slot-card-1")
        XCTAssertEqual(QAElementNames.epicSlotBand(1), "epic-slot-band-1")
        XCTAssertEqual(QAElementNames.epicSlotDoneCount(1), "epic-slot-done-count-1")
        XCTAssertEqual(QAElementNames.epicSlotUpcoming(1), "epic-slot-upcoming-1")
        XCTAssertEqual(QAElementNames.epicSlotDone(1), "epic-slot-done-1")
        XCTAssertEqual(QAElementNames.sidebar("Home"), "sidebar-home")
        XCTAssertEqual(QAElementNames.sidebar("Runs & Fallbacks"), "sidebar-runs-fallbacks")
        XCTAssertEqual(QAElementNames.section("Runs & Fallbacks"), "section-runs-fallbacks")
        XCTAssertEqual(QAElementNames.inboxReview("TP-1"), "inbox-review-TP-1")
        XCTAssertEqual(QAElementNames.inboxAction("Send Decision"), "inbox-action-send-decision")
        XCTAssertEqual(QAElementNames.decision(2), "decision-2")
        XCTAssertEqual(QAElementNames.ticketsRow("TP-1"), "tickets-row-TP-1")
        XCTAssertEqual(QAElementNames.initiativeCard("TP-1"), "initiative-card-TP-1")
        XCTAssertEqual(QAElementNames.initiativeRow("TP-1"), "initiative-row-TP-1")
        XCTAssertEqual(QAElementNames.step("Write the code"), "step-write-the-code")
        XCTAssertEqual(QAElementNames.settingsRow("Summary size limit"), "settings-row-summary-size-limit")
        XCTAssertEqual(QAElementNames.providerCard("OpenCode Go"), "provider-card-opencode-go")

        let playbook = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("priv/qa_playbooks/macos_app.md"),
            encoding: .utf8
        )
        for entry in QAElementNames.scheme {
            XCTAssertTrue(playbook.contains("`\(entry.pattern)`"), "the playbook's QA names lack \(entry.pattern)")
        }
    }
}

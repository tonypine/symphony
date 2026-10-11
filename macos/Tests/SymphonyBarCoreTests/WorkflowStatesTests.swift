import XCTest
@testable import SymphonyBarCore

final class WorkflowStatesTests: XCTestCase {
    func testReadsTheFiveNamesFromABlock() throws {
        let yaml = """
            issues:
              states:
                code_review: Review
                qa: QA
                plan_review: Plan Review
                epic_review: Epic Review
                ci_fix: CI Fix
            """
        XCTAssertEqual(
            try WorkflowStates.values(in: yaml),
            WorkflowStates(codeReview: "Review", qa: "QA", planReview: "Plan Review", epicReview: "Epic Review", ciFix: "CI Fix")
        )
    }

    func testMissingKeysFallBackToSymphonyDefaults() throws {
        XCTAssertEqual(try WorkflowStates.values(in: ""), WorkflowStates())
        XCTAssertEqual(try WorkflowStates.values(in: "issues:\n  states:\n    qa: QA\n").qa, "QA")
        XCTAssertEqual(try WorkflowStates.values(in: "issues:\n  states:\n    qa: QA\n").ciFix, "CI Fix")
    }

    func testNullAndBlankReadAsAPhaseWithNoState() throws {
        XCTAssertEqual(try WorkflowStates.values(in: "issues:\n  states:\n    qa: null\n").qa, "")
        XCTAssertEqual(try WorkflowStates.values(in: "issues:\n  states:\n    qa: ~\n").qa, "")
        XCTAssertEqual(try WorkflowStates.values(in: "issues:\n  states:\n    qa:\n").qa, "")
    }

    func testAnInlineSectionIsReported() {
        XCTAssertThrowsError(try WorkflowStates.values(in: "issues: {states: {qa: QA}}\n")) { error in
            XCTAssertEqual(error as? WorkflowStatesError, .notABlock("issues"))
        }
        XCTAssertThrowsError(try WorkflowStates.values(in: "issues:\n  states: {qa: QA}\n")) { error in
            XCTAssertEqual(error as? WorkflowStatesError, .notABlock("states"))
        }
    }

    func testWritesOnlyTheNamesThatChanged() throws {
        let yaml = "issues:\n  states:\n    qa: QA\n"
        let updated = try WorkflowStates.updating(
            yaml,
            from: WorkflowStates(),
            to: WorkflowStates(codeReview: "Review", qa: "QA", planReview: "Plan Review", epicReview: "Epic Review", ciFix: "CI Fix")
        )
        XCTAssertTrue(updated.contains("code_review: Review"))
        XCTAssertTrue(updated.contains("qa: QA"))
        XCTAssertEqual(try WorkflowStates.values(in: updated).codeReview, "Review")
    }

    func testClearingANameWritesNull() throws {
        let yaml = "issues:\n  states:\n    qa: QA\n"
        let updated = try WorkflowStates.updating(yaml, from: WorkflowStates(), to: WorkflowStates(qa: "  "))
        XCTAssertTrue(updated.contains("qa: null"))
        XCTAssertEqual(try WorkflowStates.values(in: updated).qa, "")
    }

    func testAnUnchangedEditLeavesTheTextAlone() throws {
        let yaml = "issues:\n  states:\n    qa: QA\n"
        XCTAssertEqual(try WorkflowStates.updating(yaml, from: WorkflowStates(), to: WorkflowStates()), yaml)
    }

    func testWritingIntoAnInlineSectionIsReported() {
        XCTAssertThrowsError(
            try WorkflowStates.updating("issues: {states: {qa: QA}}\n", from: WorkflowStates(), to: WorkflowStates(qa: "Quality"))
        ) { error in
            XCTAssertEqual(error as? WorkflowStatesError, .notABlock("issues"))
        }
    }

    func testTheErrorMessageNamesTheKey() {
        XCTAssertEqual(
            WorkflowStatesError.notABlock("issues").errorDescription,
            "`issues:` in symphony.yml is not an indented block. Change the board states by hand."
        )
    }

    func testConfigFileReadsWritesAndChecksTheNames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("symphony-\(UUID().uuidString).yml")
        try "issues:\n  states:\n    qa: QA\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = SymphonyConfigFile(path: url.path)
        XCTAssertEqual(try file.readWorkflowStates().qa, "QA")

        let new = WorkflowStates(codeReview: "Review")
        let checked = try await file.checkWorkflowStates(new, from: try file.readWorkflowStates()) { _ in .passed }
        XCTAssertEqual(checked, .passed)
        XCTAssertEqual(try file.readWorkflowStates().codeReview, "Code Review")

        let result = try await file.writeWorkflowStates(new, from: try file.readWorkflowStates()) { _ in .passed }
        XCTAssertEqual(result, .passed)
        XCTAssertEqual(try file.readWorkflowStates().codeReview, "Review")
    }
}

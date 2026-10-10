import Foundation
import XCTest
@testable import SymphonyBarCore

final class TranscriptTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// The attention state's own time: SHOP-305's last call started 14 min before it.
    private lazy var reference = TicketPage.date("2026-10-07T14:20:00Z")!

    // MARK: - D4 from the shipped fixture

    func testTheFixtureGroupsEventsByTurnAndTheLastCallSaysHowLongItHasBeenSilent() throws {
        let transcript = try fixtureTranscript()

        XCTAssertEqual(transcript.identifier, "SHOP-305")
        XCTAssertEqual(transcript.windowTitle, "SHOP-305 · Transcript")
        XCTAssertEqual(transcript.sessionID, "session-SHOP-305")
        XCTAssertEqual(transcript.startedAt, TicketPage.date("2026-10-07T13:58:00Z"))
        XCTAssertEqual(transcript.turns.map(\.number), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(transcript.turns.map(\.title).first, "Turn 1")
        XCTAssertEqual(transcript.turns.map(\.ended), [true, true, true, true, true, true, false])
        XCTAssertFalse(transcript.isEmpty)

        // Turn 1: the session, a message, and a command with its result and duration.
        let first = transcript.turns[0].items
        XCTAssertEqual(first.map(\.kind), [.event, .message, .toolCall])
        XCTAssertEqual(first[0].title, "Session started")
        XCTAssertEqual(first[0].summary, #"{"session_id":"session-SHOP-305"}"#)
        XCTAssertEqual(first[1].title, "Agent")
        XCTAssertEqual(first[1].timeText, "13:58:20")
        XCTAssertEqual(first[2].title, "Command")
        XCTAssertEqual(first[2].summary, "Command rg -n \"round\" lib/shop/checkout")
        XCTAssertEqual(first[2].result?.hasPrefix("lib/shop/checkout/total.ex:41"), true)
        XCTAssertEqual(first[2].duration, "1.0 s")
        XCTAssertTrue(first[2].detail.contains("→ lib/shop/checkout/total.ex:41"))

        // Turn 3: a file change joined to its result.
        XCTAssertEqual(transcript.turns[2].items[0].title, "File change")
        XCTAssertEqual(transcript.turns[2].items[0].summary, "File change lib/shop/checkout/total.ex")
        XCTAssertEqual(transcript.turns[2].items[0].result, "Updated lib/shop/checkout/total.ex")

        // J3 step 3: the last call hasn't returned.
        let last = try XCTUnwrap(transcript.turns.last?.items.last)
        XCTAssertEqual(last.summary, "Command mix test test/checkout/total_test.exs")
        XCTAssertNil(last.result)
        XCTAssertEqual(last.silentSeconds, 840)
        XCTAssertEqual(last.silence, "silent for 14 min")
        XCTAssertEqual(last.trailing, "silent for 14 min")
        XCTAssertEqual(last.accessibilityLabel, "14:06:00, Command mix test test/checkout/total_test.exs, silent for 14 min")
        XCTAssertEqual(first[1].accessibilityLabel, "13:58:20, Agent, " + first[1].summary)
        // Only the open turn's waiting call is silent.
        XCTAssertEqual(transcript.items.filter { $0.silentSeconds != nil }.count, 1)
    }

    func testToolsAndASearchListOnlyTheMatchingCalls() throws {
        let transcript = try fixtureTranscript()

        // J3 step 4: Tools, then `mix test`.
        let tools = transcript.turns(filter: .tools, query: "mix test")
        XCTAssertEqual(tools.map(\.number), [5, 7])
        XCTAssertEqual(tools.flatMap(\.items).map(\.summary), [
            "Command mix test test/checkout/total_test.exs:12", "Command mix test test/checkout/total_test.exs",
        ])
        XCTAssertEqual(tools.flatMap(\.items).first?.duration, "9.0 s")

        XCTAssertEqual(transcript.turns(filter: .messages).flatMap(\.items).count, 5)
        XCTAssertTrue(transcript.turns(filter: .messages).flatMap(\.items).allSatisfy { $0.kind == .message })
        XCTAssertEqual(transcript.turns(filter: .all).flatMap(\.items).count, transcript.items.count)
        // The search matches the message text, whatever the case.
        XCTAssertEqual(transcript.turns(filter: .all, query: "  HUNG IN RUN 1 ").flatMap(\.items).map(\.turn), [6])
        XCTAssertEqual(transcript.turns(filter: .tools, query: "no such thing"), [])

        let errors = transcript.turns(filter: .errors).flatMap(\.items)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].turn, 4)
        XCTAssertEqual(errors[0].summary, "linear_graphql: Linear rate-limited the request; retrying in 30 s")
        XCTAssertEqual(Transcript.Filter.allCases.map(\.title), ["All", "Messages", "Tools", "Errors"])
        XCTAssertEqual(Transcript.Filter.tools.id, "tools")
    }

    // MARK: - Claude Code's events

    func testClaudesDeltasJoinIntoOneMessageAndAFailedTurnIsAnError() throws {
        let events: [Any] = [
            ["event": "agent_text", "timestamp": "2026-10-07T10:00:00Z", "payload": ["method": "agent_message_delta", "params": ["msg": ["content": "Reading "]]]],
            ["event": "agent_text", "timestamp": "2026-10-07T10:00:01Z", "payload": ["method": "agent_message_delta", "params": ["msg": ["content": "the test."]]]],
            ["event": "tool_use", "timestamp": "2026-10-07T10:00:02Z", "payload": ["method": "item/tool/call", "params": ["tool": "Bash"]]],
            ["event": "token_count", "timestamp": "2026-10-07T10:00:03Z", "payload": ["method": "token_count"]],
            ["event": "tool_progress", "payload": ["tool": "Bash"]],
            ["event": "tool_result", "timestamp": "2026-10-07T10:00:32Z", "payload": ["method": "item/tool/result", "params": ["text": "ok"]]],
            ["event": "tool_result", "timestamp": "2026-10-07T10:00:33Z", "payload": ["method": "item/tool/result", "params": ["text": "orphan"]]],
            ["event": "notification", "timestamp": "2026-10-07T10:00:34Z", "payload": "Claude 5-hour limit at 80%"],
            ["event": "turn_failed", "timestamp": "2026-10-07T10:00:40Z", "reason": "usage limit reached", "payload": ["method": "turn/failed", "params": ["error": ["message": "usage limit reached"]]]],
            ["event": "agent_text", "agent_phase": "reviewer", "timestamp": "2026-10-07T10:01:00Z",
             "payload": ["method": "item/agentMessage/delta", "params": ["delta": "Looks "]]],
            ["event": "agent_text", "agent_phase": "reviewer", "timestamp": "2026-10-07T10:01:01Z",
             "payload": ["method": "item/agentMessage/delta", "params": ["delta": "good"]]],
            ["event": "notification", "agent_phase": "reviewer", "timestamp": "2026-10-07T10:01:02Z",
             "payload": ["method": "item/completed", "params": ["item": ["type": "agentMessage", "text": "Looks good to me."]]]],
            ["event": "notification", "timestamp": "2026-10-07T10:01:03Z", "payload": ["method": "thread/started", "params": [:] as [String: Any]]],
            ["event": "notification", "timestamp": "2026-10-07T10:01:04Z", "payload": ["method": "item/agentMessage/delta", "params": [:] as [String: Any]]],
            "a line that wasn't JSON",
        ]
        let transcript = try XCTUnwrap(Transcript.decode(payload(events), reference: reference, timeZone: utc))

        XCTAssertEqual(transcript.turns.map(\.number), [1, 2])
        let first = transcript.turns[0].items
        XCTAssertEqual(first.map(\.kind), [.message, .toolCall, .toolCall, .event, .error])
        XCTAssertEqual(first[0].detail, "Reading the test.")
        XCTAssertEqual(first[1].title, "Bash")
        XCTAssertEqual(first[1].result, "ok")
        XCTAssertEqual(first[1].duration, "30 s")
        XCTAssertEqual(first[2].title, "Tool result")
        XCTAssertEqual(first[3].title, "Notification")
        XCTAssertEqual(first[3].summary, "Claude 5-hour limit at 80%")
        XCTAssertEqual(first[4].title, "Turn failed")
        XCTAssertEqual(first[4].summary, "usage limit reached")

        let second = transcript.turns[1].items
        XCTAssertEqual(second.map(\.title), ["Reviewer", "Event"])
        XCTAssertEqual(second[0].detail, "Looks good to me.")
        XCTAssertEqual(second[1].summary, "a line that wasn't JSON")
        XCTAssertNil(transcript.sessionID)
    }

    func testCodexCommandsAndErrorsReadFromTheirOtherShapes() throws {
        let events: [[String: Any]] = [
            ["event": "notification", "timestamp": "2026-10-07T10:00:00Z",
             "payload": ["method": "codex/event/exec_command_begin", "params": ["msg": ["command": ["bash", "-lc", "mix compile"]], "call_id": "c1"]]],
            ["event": "notification", "timestamp": "2026-10-07T10:00:02Z",
             "payload": ["method": "codex/event/exec_command_end", "params": ["msg": ["exit_code": 1], "call_id": "c1"]]],
            ["event": "notification", "timestamp": "2026-10-07T10:00:03Z",
             "payload": ["method": "codex/event/exec_command_begin", "params": ["msg": ["command": ["git", "status"]]]]],
            ["event": "notification", "payload": ["method": "item/commandExecution/outputDelta", "params": ["delta": "."]]],
            ["event": "notification", "timestamp": "2026-10-07T10:00:04Z", "payload": ["method": "item/tool/call", "params": ["name": "linear", "arguments": ["q": 1]]]],
            ["event": "notification", "timestamp": "2026-10-07T10:00:05Z", "payload": ["method": "item/tool/call", "params": [:] as [String: Any]]],
            ["event": "startup_failed", "timestamp": "2026-10-07T10:00:06Z", "payload": ["method": "x"]],
            ["event": "notification", "timestamp": "2026-10-07T10:00:07Z", "payload": ["payload": ["method": "item/started",
              "params": ["item": ["type": "commandExecution", "command": ""]]]]],
            ["event": "turn_completed", "payload": ["method": "turn/completed"]],
        ]
        let transcript = try XCTUnwrap(Transcript.decode(payload(events, sessionID: "n/a"), reference: reference, timeZone: utc))
        let items = transcript.turns[0].items

        XCTAssertEqual(items.map(\.summary), [
            "Command mix compile", "Command git status", "linear {", "Tool call", "{", "Command",
        ])
        XCTAssertEqual(items[0].result, "exit 1")
        XCTAssertEqual(items[0].duration, "2.0 s")
        XCTAssertNil(items[1].result)
        // A call in an ended turn isn't silent: the turn is over.
        XCTAssertNil(items[1].silentSeconds)
        XCTAssertEqual(items[4].kind, .error)
        XCTAssertNil(transcript.sessionID)
        XCTAssertTrue(transcript.turns[0].ended)
    }

    func testAnEmptyTranscriptAndOneThatIsNot() {
        let empty = Transcript.decode(payload([]), reference: reference)
        XCTAssertEqual(empty?.turns, [])
        XCTAssertEqual(empty?.isEmpty, true)
        XCTAssertNil(Transcript.decode(Data(#"{"error":{"code":"not_found"}}"#.utf8), reference: reference))
        XCTAssertNil(Transcript.decode(Data("[]".utf8), reference: reference))
        XCTAssertEqual(Transcript.oneLine(String(repeating: "a", count: 300)).count, 200)
        XCTAssertEqual(Transcript.Event.eventTitle(""), "Event")
        XCTAssertEqual(Transcript.Event.commandText(["ls", "-la"]), "ls -la")
        XCTAssertNil(Transcript.Event.commandText(nil))
    }

    // MARK: - Helpers

    private func fixtureTranscript() throws -> Transcript {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/attention/api/v1/repos/web-shop/issues/SHOP-305/transcript.json")
        return try XCTUnwrap(Transcript.decode(try Data(contentsOf: file), reference: reference, timeZone: utc))
    }

    private func payload(_ events: [Any], sessionID: String? = nil) -> Data {
        var object: [String: Any] = ["issue_identifier": "T-1", "events": events]
        if let sessionID { object["session_id"] = sessionID }
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

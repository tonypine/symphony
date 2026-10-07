import Foundation

/// D4: a run's transcript from the transcript endpoint, grouped by turn: the agent's messages, each tool call with its
/// result and duration, and errors. Events come as the agent wrote them (Codex's app-server methods, or the ones
/// Symphony maps Claude Code's stream to), so each is read loosely, as the web dashboard's transcript reads them.
public struct Transcript: Equatable {
    /// All / Messages / Tools / Errors.
    public enum Filter: String, CaseIterable, Equatable, Identifiable {
        case all, messages, tools, errors

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: "All"
            case .messages: "Messages"
            case .tools: "Tools"
            case .errors: "Errors"
            }
        }

        func includes(_ kind: Item.Kind) -> Bool {
            switch self {
            case .all: true
            case .messages: kind == .message
            case .tools: kind == .toolCall
            case .errors: kind == .error
            }
        }
    }

    /// A row of the transcript.
    public struct Item: Equatable, Identifiable {
        public enum Kind: Equatable {
            case message, toolCall, error, event
        }

        public var id: Int
        public var turn: Int
        public var kind: Kind
        public var time: Date?
        /// "14:06:12".
        public var timeText: String?
        /// "Agent", "Reviewer", the tool's name, "Error", or the event's name.
        public var title: String
        /// One line for the list.
        public var summary: String
        /// The event in full: the message, or the call's input and its result.
        public var detail: String
        /// A tool call's result, nil until it returns.
        public var result: String?
        public var durationSeconds: Double?
        /// For a call that hasn't returned: seconds since it started.
        public var silentSeconds: Int?
        /// The Codex item id that joins a call to its result.
        var itemID: String?
        /// Whether its text came in deltas still being joined.
        var streaming = false

        /// "2.1 s", "3 min"; nil for a call without both ends.
        public var duration: String? {
            guard let durationSeconds else { return nil }
            return durationSeconds < 10 ? String(format: "%.1f s", durationSeconds) : Overview.duration(Int(durationSeconds))
        }

        /// "silent for 14 min".
        public var silence: String? { silentSeconds.map { "silent for \(Overview.duration($0))" } }

        /// The trailing words of the row: its duration, or how long it has been silent.
        public var trailing: String? { silence ?? duration }

        /// "14:06:00, Command mix test, silent for 14 min": a call's summary already starts with its name.
        public var accessibilityLabel: String {
            let what = summary.hasPrefix(title) ? summary : "\(title), \(summary)"
            return [timeText, what, trailing].compactMap { $0 }.joined(separator: ", ")
        }

        func matches(_ query: String) -> Bool {
            [title, summary, detail, result ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// A turn and its rows.
    public struct Turn: Equatable, Identifiable {
        public var number: Int
        public var items: [Item]
        /// The turn ended (completed or failed); the last turn of a run under way hasn't.
        public var ended: Bool

        public var id: Int { number }
        public var title: String { "Turn \(number)" }
    }

    public static let copySessionIDTitle = "Copy Session ID"
    public static let searchPrompt = "Search the transcript"

    public var identifier: String
    public var sessionID: String?
    public var startedAt: Date?
    public var turns: [Turn]

    public var items: [Item] { turns.flatMap(\.items) }
    public var isEmpty: Bool { turns.allSatisfy(\.items.isEmpty) }

    /// The window's title: "SHOP-305 · Transcript".
    public var windowTitle: String { "\(identifier) · Transcript" }

    /// The turns with only the rows `filter` keeps and `query` matches; turns left empty are dropped.
    public func turns(filter: Filter, query: String = "") -> [Turn] {
        let query = query.trimmingWhitespace()
        return turns.compactMap { turn in
            var turn = turn
            turn.items = turn.items.filter { filter.includes($0.kind) && (query.isEmpty || $0.matches(query)) }
            return turn.items.isEmpty ? nil : turn
        }
    }

    public init(identifier: String, sessionID: String?, startedAt: Date? = nil, turns: [Turn]) {
        self.identifier = identifier
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.turns = turns
    }

    /// The transcript in an endpoint's body, nil when it isn't one. `reference` is the time silence is measured
    /// against: the state's own time, so it agrees with the ticket page.
    public static func decode(_ data: Data, reference: Date, timeZone: TimeZone = .current) -> Transcript? {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let identifier = payload["issue_identifier"] as? String
        else { return nil }
        let events = payload["events"] as? [Any] ?? []
        return Transcript(
            identifier: identifier,
            sessionID: (payload["session_id"] as? String).flatMap { $0.isEmpty || $0 == "n/a" ? nil : $0 },
            startedAt: (payload["started_at"] as? String).flatMap(TicketPage.date),
            turns: build(events, reference: reference, timeZone: timeZone)
        )
    }

    // MARK: - Reading events

    static func build(_ events: [Any], reference: Date, timeZone: TimeZone) -> [Turn] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"

        var turns: [Turn] = [Turn(number: 1, items: [], ended: false)]
        var sequence = 0

        for raw in events {
            let event = Event(raw)
            let time = event.timestamp
            let current = turns.count - 1

            switch event.kind {
            case .skip:
                continue
            case .turnEnd(let failure):
                if let failure {
                    sequence += 1
                    turns[current].items.append(Item(
                        id: sequence, turn: turns[current].number, kind: .error, time: time,
                        timeText: time.map(formatter.string), title: "Turn failed", summary: oneLine(failure), detail: failure
                    ))
                }
                turns[current].ended = true
                turns.append(Turn(number: turns[current].number + 1, items: [], ended: false))
                continue
            default:
                break
            }
            switch event.kind {
            case let .message(text, delta):
                if delta, let last = turns[current].items.last, last.kind == .message, last.streaming, last.title == event.agentName {
                    let index = turns[current].items.count - 1
                    turns[current].items[index].detail += text
                    turns[current].items[index].summary = oneLine(turns[current].items[index].detail)
                } else if !delta, let last = turns[current].items.last, last.kind == .message, last.streaming, last.title == event.agentName {
                    // The completed message after its deltas carries the whole text.
                    let index = turns[current].items.count - 1
                    turns[current].items[index].detail = text
                    turns[current].items[index].summary = oneLine(text)
                    turns[current].items[index].streaming = false
                } else {
                    sequence += 1
                    turns[current].items.append(Item(
                        id: sequence, turn: turns[current].number, kind: .message, time: time,
                        timeText: time.map(formatter.string), title: event.agentName, summary: oneLine(text), detail: text,
                        streaming: delta
                    ))
                }
            case let .toolCall(name, input):
                sequence += 1
                let summary = input.map { "\(name) \(oneLine($0))" } ?? name
                turns[current].items.append(Item(
                    id: sequence, turn: turns[current].number, kind: .toolCall, time: time,
                    timeText: time.map(formatter.string), title: name, summary: summary, detail: input ?? name,
                    itemID: event.itemID
                ))
            case let .toolResult(text):
                // The result joins its call: by item id when there is one, else the oldest call still waiting.
                let pending = turns[current].items.indices.filter { turns[current].items[$0].kind == .toolCall && turns[current].items[$0].result == nil }
                let index = pending.first { event.itemID != nil && turns[current].items[$0].itemID == event.itemID } ?? pending.first
                if let index {
                    var call = turns[current].items[index]
                    call.result = text ?? ""
                    if let start = call.time, let time { call.durationSeconds = max(time.timeIntervalSince(start), 0) }
                    call.detail = [call.detail, text.map { "→ \($0)" }].compactMap { $0 }.joined(separator: "\n\n")
                    turns[current].items[index] = call
                } else {
                    sequence += 1
                    let text = text ?? ""
                    turns[current].items.append(Item(
                        id: sequence, turn: turns[current].number, kind: .toolCall, time: time,
                        timeText: time.map(formatter.string), title: "Tool result", summary: oneLine(text), detail: text,
                        result: text
                    ))
                }
            case let .error(text):
                sequence += 1
                turns[current].items.append(Item(
                    id: sequence, turn: turns[current].number, kind: .error, time: time,
                    timeText: time.map(formatter.string), title: "Error", summary: oneLine(text), detail: text
                ))
            case let .other(name, text, summary):
                sequence += 1
                turns[current].items.append(Item(
                    id: sequence, turn: turns[current].number, kind: .event, time: time,
                    timeText: time.map(formatter.string), title: name, summary: oneLine(summary), detail: text
                ))
            case .skip, .turnEnd:
                break
            }
        }

        // A call still waiting in the open turn says how long it has been silent.
        if let last = turns.indices.last {
            for index in turns[last].items.indices where turns[last].items[index].kind == .toolCall && turns[last].items[index].result == nil {
                turns[last].items[index].silentSeconds = turns[last].items[index].time.map { max(Int(reference.timeIntervalSince($0)), 0) }
            }
        }
        for turn in turns.indices {
            for item in turns[turn].items.indices { turns[turn].items[item].streaming = false }
        }
        return turns.filter { !$0.items.isEmpty }
    }

    /// The first line, cut to a list row's length.
    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingWhitespace() ?? ""
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    /// One transcript event, read the way `SymphonyElixirWeb.TranscriptLive` reads it.
    struct Event {
        enum Kind {
            case message(String, delta: Bool)
            case toolCall(name: String, input: String?)
            case toolResult(String?)
            case error(String)
            /// `failure` when the turn failed.
            case turnEnd(failure: String?)
            /// `summary` is the value on one line; `text` is it in full.
            case other(name: String, text: String, summary: String)
            /// Token counts and heartbeats: not rows.
            case skip
        }

        let kind: Kind
        let timestamp: Date?
        let itemID: String?
        /// "Agent", or "Reviewer" for the review agent's events.
        let agentName: String

        init(_ raw: Any) {
            guard let event = raw as? [String: Any] else {
                kind = .other(name: "Event", text: String(describing: raw), summary: String(describing: raw))
                timestamp = nil
                itemID = nil
                agentName = "Agent"
                return
            }
            timestamp = (event["timestamp"] as? String).flatMap(TicketPage.date)
            agentName = (event["agent_phase"] as? String) == "reviewer" ? "Reviewer" : "Agent"
            let payload = event["payload"] as? [String: Any]
            let inner = payload?["payload"] as? [String: Any]
            let method = (payload?["method"] as? String ?? inner?["method"] as? String ?? "").lowercased()
            let params = payload?["params"] as? [String: Any] ?? inner?["params"] as? [String: Any]
            let item = params?["item"] as? [String: Any]
            let itemType = (item?["type"] as? String)?.lowercased() ?? ""
            let name = (event["event"] as? String) ?? method
            let lowerName = name.lowercased()
            itemID = item?["id"] as? String ?? params?["itemId"] as? String ?? params?["call_id"] as? String

            if ["token_count", "tool_progress"].contains(lowerName) || method == "token_count" || method.contains("tokenusage") {
                kind = .skip
            } else if lowerName == "turn_failed" || method == "turn/failed" {
                kind = .turnEnd(failure: Self.errorText(event, params: params) ?? "The turn failed.")
            } else if lowerName == "turn_completed" || method == "turn/completed" {
                kind = .turnEnd(failure: nil)
            } else if lowerName.contains("error") || lowerName.contains("failed") || method.contains("error") || method.contains("failed")
                || ["unsupported_tool_call"].contains(lowerName) {
                kind = .error(Self.errorText(event, params: params) ?? Self.text(event["payload"] ?? event))
            } else if ["tool_call_completed", "tool_result"].contains(lowerName) || method.hasSuffix("tool_call_end")
                || method.contains("item/tool/result") || method.contains("exec_command_end")
                || (method == "item/completed" && ["commandexecution", "filechange"].contains(itemType)) {
                kind = .toolResult(Self.resultText(params: params, item: item))
            } else if method.contains("output_delta") || method.contains("outputdelta") {
                kind = .skip
            } else if method.contains("item/tool/call") || method.hasSuffix("tool_call_begin") || method.contains("exec_command_begin")
                || method.contains("requestapproval") || method.contains("tool/requestuserinput")
                || (method == "item/started" && ["commandexecution", "filechange"].contains(itemType)) {
                let (toolName, input) = Self.call(params: params, item: item, itemType: itemType)
                kind = .toolCall(name: toolName, input: input)
            } else if method.contains("agent_message") || method.contains("agentmessage")
                || (method == "item/completed" && itemType == "agentmessage") {
                if let text = Self.messageText(params: params) {
                    kind = .message(text, delta: method.contains("delta"))
                } else {
                    kind = .skip
                }
            } else if method.hasPrefix("item/") || method.hasPrefix("thread/") || method.hasPrefix("turn/") {
                // Codex's other item and thread notifications carry nothing a person reads.
                kind = .skip
            } else {
                let value = event["payload"] ?? event["message"] ?? event
                kind = .other(name: Self.eventTitle(name), text: Self.text(value), summary: Self.text(value, pretty: false))
            }
        }

        /// "session_started" → "Session started".
        static func eventTitle(_ name: String) -> String {
            guard !name.isEmpty else { return "Event" }
            return Overview.phaseName(name.replacingOccurrences(of: "/", with: " "))
        }

        static func messageText(params: [String: Any]?) -> String? {
            let msg = params?["msg"] as? [String: Any]
            let item = params?["item"] as? [String: Any]
            for value in [msg?["content"], params?["delta"], item?["text"]] {
                if let text = value as? String, !text.isEmpty { return text }
            }
            return nil
        }

        static func call(params: [String: Any]?, item: [String: Any]?, itemType: String) -> (String, String?) {
            if let item, itemType == "commandexecution" {
                return ("Command", commandText(item["command"]))
            }
            if let item, itemType == "filechange" {
                let paths = (item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
                return ("File change", paths.isEmpty ? nil : paths.joined(separator: ", "))
            }
            let msg = params?["msg"] as? [String: Any]
            if let command = commandText(msg?["command"] ?? params?["command"]) { return ("Command", command) }
            let name = (params?["tool"] ?? params?["name"]) as? String ?? "Tool call"
            let arguments = params?["arguments"] ?? params?["input"]
            return (name, arguments.map { text($0) })
        }

        static func commandText(_ value: Any?) -> String? {
            if let text = value as? String, !text.isEmpty { return text }
            if let parts = value as? [String], !parts.isEmpty {
                // Codex wraps commands in a login shell: ["bash", "-lc", "mix test"] reads as the command.
                if parts.count == 3, ["-lc", "-c"].contains(parts[1]) { return parts[2] }
                return parts.joined(separator: " ")
            }
            return nil
        }

        static func resultText(params: [String: Any]?, item: [String: Any]?) -> String? {
            let msg = params?["msg"] as? [String: Any]
            for value in [params?["text"], item?["aggregatedOutput"], item?["aggregated_output"], msg?["formatted_output"],
                          msg?["stdout"], params?["output"]] {
                if let text = value as? String { return text }
            }
            if let exit = (item?["exitCode"] ?? msg?["exit_code"]) as? Int { return "exit \(exit)" }
            return nil
        }

        static func errorText(_ event: [String: Any], params: [String: Any]?) -> String? {
            let error = params?["error"] as? [String: Any]
            for value in [error?["message"], params?["message"], event["reason"], event["message"], event["error"]] {
                if let text = value as? String, !text.isEmpty { return text }
            }
            return nil
        }

        /// A value as text: a string as it is, anything else as sorted JSON, on one line unless `pretty`.
        static func text(_ value: Any, pretty: Bool = true) -> String {
            if let text = value as? String { return text }
            let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
            if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: options) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: value)
        }
    }
}

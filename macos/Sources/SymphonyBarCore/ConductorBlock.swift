import Foundation

/// A block of a Conductor message (`blocks` of a `conductor.update`'s payload): data Symphony resolved from the ticket's
/// own records, which the app draws with its components. The Conductor only picks the block; the numbers, states and
/// words in it are Symphony's, so the app draws them as they come.
///
/// Reading is lenient. A block of a type this app does not know, or one that lacks its main data, is skipped; every
/// other field is optional, and a field of another type reads as missing.
public enum ConductorBlock: Equatable {
    case steps(Steps)
    case evidence(Evidence)
    case budget(Budget)
    case path(Path)
    case attempts(Attempts)
    case compare(Compare)
    case findings(Findings)
    case epic(Epic)
    case question(Question)

    /// A run's steps, as its group shows them (at most the newest eight).
    public struct Steps: Equatable {
        public struct Step: Equatable {
            public enum Outcome: String, Equatable { case passed, failed, skipped }

            public var stepID: String?
            public var title: String
            public var outcome: Outcome
            public var durationMs: Int?
            public var returnsTo: String?
        }

        public var runID: String?
        public var runKind: String?
        public var steps: [Step]
    }

    /// Screenshots of evidence or findings, one to four.
    public struct Evidence: Equatable {
        public struct Item: Equatable {
            public var eventID: String?
            public var artifactID: String
            public var caption: String?

            /// The screenshot as the timeline's finding card draws it.
            public var screenshot: TicketScreenshot {
                TicketScreenshot(
                    id: artifactID, label: caption ?? Evidence.uncaptioned, path: "api/v1/artifacts/\(artifactID)", available: true
                )
            }
        }

        public var items: [Item]
        public static let uncaptioned = "Screenshot"
    }

    /// The tokens the ticket has used, against its cap when it has one, by the kind of run.
    public struct Budget: Equatable {
        public struct Part: Equatable {
            public var kind: String
            public var runs: Int
            public var tokens: Int
        }

        public var tokensUsed: Int
        public var tokensCap: Int?
        public var parts: [Part]

        /// What is left before the cap; nil with no cap.
        public var tokensLeft: Int? { tokensCap.map { max($0 - tokensUsed, 0) } }

        /// The share used, a whole percent; nil with no cap.
        public var percent: Int? { tokensCap.map { ProgressMeterReading.percent(used: Double(tokensUsed), cap: Double($0)) } }
    }

    /// The phases the ticket has been through, is in and is still to meet.
    public struct Path: Equatable {
        public struct Stop: Equatable {
            public enum State: String, Equatable { case done, failed, current, upcoming }

            public var phase: String
            public var state: State
            /// How many times in a row the ticket met it; 1 when the block does not say.
            public var times: Int
            public var runNumber: Int?
        }

        public var stops: [Stop]
        /// How many times the ticket went round QA and rework.
        public var loops: Int
        public var elapsedMs: Int?
    }

    /// One step across its tries.
    public struct Attempts: Equatable {
        public struct Try: Equatable {
            public var at: Date?
            public var outcome: String?
            public var durationMs: Int?
            /// The last line of error the try printed, or its last line.
            public var line: String?

            public var failed: Bool { outcome?.lowercased() == "failed" }
        }

        public var runID: String?
        public var stepID: String?
        public var title: String?
        public var tries: [Try]
        /// Every failed try printed the same line.
        public var sameLine: Bool
    }

    /// What was expected against what was seen: each a text or a screenshot.
    public struct Compare: Equatable {
        public enum Side: Equatable {
            case text(String)
            case screenshot(artifactID: String, eventID: String?)
        }

        public var expected: Side
        public var actual: Side

        public init(expected: Side, actual: Side) {
            self.expected = expected
            self.actual = actual
        }
    }

    /// Every finding on the ticket and what became of it.
    public struct Findings: Equatable {
        public struct Item: Equatable {
            public var id: String?
            public var title: String
            public var resolved: Bool
            public var severity: String?
        }

        public var items: [Item]
        public var open: Int
        public var resolved: Int
    }

    /// The ticket's epic and its sub-tickets, the current ticket marked.
    public struct Epic: Equatable {
        public struct Row: Equatable {
            public var identifier: String
            public var title: String?
            public var state: String?
            public var current: Bool
        }

        public var identifier: String?
        public var title: String?
        public var rows: [Row]
    }

    /// A decision the Conductor asks of the person, as the Inbox holds it.
    public struct Question: Equatable {
        public struct Option: Equatable {
            public var label: String
            public var recommended: Bool
        }

        public var decisionID: String
        public var title: String?
        public var question: String?
        public var options: [Option]
    }
}

// MARK: - Reading

extension ConductorBlock {
    /// The blocks a JSON list holds, as the events feed writes them (snake-case keys); a block that does not read is
    /// left out. The Gallery draws its variations from these.
    public static func read(json: String) -> [ConductorBlock] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return ((try? decoder.decode([LossyConductorBlock].self, from: Data(json.utf8))) ?? []).compactMap(\.block)
    }
}

/// A block, or nothing: one that does not read is skipped without failing the list around it.
struct LossyConductorBlock: Decodable {
    let block: ConductorBlock?

    init(from decoder: Decoder) throws {
        block = BlockFields(decoder).flatMap(ConductorBlock.init(fields:))
    }
}

struct BlockKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A map of a block, read field by field: a field of another type is missing.
struct BlockFields: Decodable {
    private let container: KeyedDecodingContainer<BlockKey>

    init?(_ decoder: Decoder) {
        guard let container = try? decoder.container(keyedBy: BlockKey.self) else { return nil }
        self.container = container
    }

    init(from decoder: Decoder) throws {
        container = try decoder.container(keyedBy: BlockKey.self)
    }

    func text(_ key: String) -> String? {
        guard let text = (try? container.decodeIfPresent(String.self, forKey: BlockKey(key))) ?? nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func number(_ key: String) -> Int? {
        if let value = (try? container.decodeIfPresent(Int.self, forKey: BlockKey(key))) ?? nil { return value }
        return ((try? container.decodeIfPresent(Double.self, forKey: BlockKey(key))) ?? nil).map { Int($0.rounded()) }
    }

    func flag(_ key: String) -> Bool? { (try? container.decodeIfPresent(Bool.self, forKey: BlockKey(key))) ?? nil }

    func map(_ key: String) -> BlockFields? { (try? container.decodeIfPresent(BlockFields.self, forKey: BlockKey(key))) ?? nil }

    /// The maps of a list; an element that is not a map is left out.
    func list(_ key: String) -> [BlockFields] {
        let boxes = (try? container.decodeIfPresent([LossyFields].self, forKey: BlockKey(key))) ?? nil
        return (boxes ?? []).compactMap(\.fields)
    }

    /// The strings of a list; an element that is not a string is left out.
    func strings(_ key: String) -> [String] {
        let boxes = (try? container.decodeIfPresent([LossyString].self, forKey: BlockKey(key))) ?? nil
        return (boxes ?? []).compactMap(\.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private struct LossyString: Decodable {
        let text: String?
        init(from decoder: Decoder) throws { text = try? decoder.singleValueContainer().decode(String.self) }
    }

    private struct LossyFields: Decodable {
        let fields: BlockFields?
        init(from decoder: Decoder) throws { fields = BlockFields(decoder) }
    }
}

extension ConductorBlock {
    init?(fields: BlockFields) {
        let block: ConductorBlock?
        switch fields.text("type") {
        case "steps": block = Self.readSteps(fields)
        case "evidence": block = Self.readEvidence(fields)
        case "budget": block = Self.readBudget(fields)
        case "path": block = Self.readPath(fields)
        case "attempts": block = Self.readAttempts(fields)
        case "compare": block = Self.readCompare(fields)
        case "findings": block = Self.readFindings(fields)
        case "epic": block = Self.readEpic(fields)
        case "question": block = Self.readQuestion(fields)
        default: block = nil
        }
        guard let block else { return nil }
        self = block
    }

    private static func readSteps(_ fields: BlockFields) -> ConductorBlock? {
        let steps = fields.list("steps").compactMap { step -> Steps.Step? in
            guard let title = step.text("title") ?? step.text("stepId") else { return nil }
            let outcome = step.text("outcome").flatMap(Steps.Step.Outcome.init(rawValue:)) ?? .passed
            return Steps.Step(stepID: step.text("stepId"), title: title, outcome: outcome, durationMs: step.number("durationMs"), returnsTo: step.text("returnsTo"))
        }
        return steps.isEmpty ? nil : .steps(Steps(runID: fields.text("runId"), runKind: fields.text("runKind"), steps: steps))
    }

    private static func readEvidence(_ fields: BlockFields) -> ConductorBlock? {
        let items = fields.list("items").compactMap { item -> Evidence.Item? in
            guard let artifact = item.text("artifactId") else { return nil }
            return Evidence.Item(eventID: item.text("eventId"), artifactID: artifact, caption: item.text("caption"))
        }
        return items.isEmpty ? nil : .evidence(Evidence(items: items))
    }

    private static func readBudget(_ fields: BlockFields) -> ConductorBlock? {
        guard let used = fields.number("tokensUsed") else { return nil }
        let parts = fields.list("parts").compactMap { part -> Budget.Part? in
            guard let kind = part.text("kind"), let tokens = part.number("tokens") else { return nil }
            return Budget.Part(kind: kind, runs: part.number("runs") ?? 0, tokens: tokens)
        }
        return .budget(Budget(tokensUsed: used, tokensCap: fields.number("tokensCap"), parts: parts))
    }

    private static func readPath(_ fields: BlockFields) -> ConductorBlock? {
        let stops = fields.list("stops").compactMap { stop -> Path.Stop? in
            guard let phase = stop.text("phase"), let state = stop.text("state").flatMap(Path.Stop.State.init(rawValue:)) else { return nil }
            return Path.Stop(phase: phase, state: state, times: max(stop.number("times") ?? 1, 1), runNumber: stop.number("runNumber"))
        }
        return stops.isEmpty ? nil : .path(Path(stops: stops, loops: max(fields.number("loops") ?? 0, 0), elapsedMs: fields.number("elapsedMs")))
    }

    private static func readAttempts(_ fields: BlockFields) -> ConductorBlock? {
        let tries = fields.list("tries").map { attempt in
            Attempts.Try(
                at: attempt.text("at").flatMap(TicketPage.date), outcome: attempt.text("outcome"), durationMs: attempt.number("durationMs"),
                line: attempt.text("line")
            )
        }
        guard !tries.isEmpty else { return nil }
        return .attempts(Attempts(
            runID: fields.text("runId"), stepID: fields.text("stepId"), title: fields.text("title"), tries: tries,
            sameLine: fields.flag("sameLine") ?? false
        ))
    }

    private static func readCompare(_ fields: BlockFields) -> ConductorBlock? {
        func side(_ key: String) -> Compare.Side? {
            guard let side = fields.map(key) else { return nil }
            if let text = side.text("text") { return .text(text) }
            if let artifact = side.text("artifactId") { return .screenshot(artifactID: artifact, eventID: side.text("eventId")) }
            return nil
        }
        guard let expected = side("expected"), let actual = side("actual") else { return nil }
        return .compare(Compare(expected: expected, actual: actual))
    }

    private static func readFindings(_ fields: BlockFields) -> ConductorBlock? {
        let items = fields.list("items").compactMap { item -> Findings.Item? in
            guard let title = item.text("title") else { return nil }
            return Findings.Item(id: item.text("id"), title: title, resolved: item.text("state") == "resolved", severity: item.text("severity"))
        }
        guard !items.isEmpty else { return nil }
        let resolved = items.filter(\.resolved).count
        return .findings(Findings(items: items, open: fields.number("open") ?? items.count - resolved, resolved: fields.number("resolved") ?? resolved))
    }

    private static func readEpic(_ fields: BlockFields) -> ConductorBlock? {
        let rows = fields.list("rows").compactMap { row -> Epic.Row? in
            guard let identifier = row.text("identifier") else { return nil }
            return Epic.Row(identifier: identifier, title: row.text("title"), state: row.text("state"), current: row.flag("current") ?? false)
        }
        return rows.isEmpty ? nil : .epic(Epic(identifier: fields.text("identifier"), title: fields.text("title"), rows: rows))
    }

    private static func readQuestion(_ fields: BlockFields) -> ConductorBlock? {
        guard let decision = fields.text("decisionId") else { return nil }
        let options = fields.list("options").compactMap { option -> Question.Option? in
            guard let label = option.text("label") else { return nil }
            return Question.Option(label: label, recommended: option.flag("recommended") ?? false)
        }
        return .question(Question(decisionID: decision, title: fields.text("title"), question: fields.text("question"), options: options))
    }
}

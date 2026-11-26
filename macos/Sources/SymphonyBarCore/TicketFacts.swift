import Foundation

/// A measured value, as Symphony keeps one (a QA tool's measure, an evidence's `measures`, a step answer's): what was
/// measured, the number, its unit and, when there is one, the number expected.
public struct TicketMeasure: Equatable, Hashable {
    public var name: String
    public var value: Double
    public var unit: String
    public var expected: Double?

    public init(name: String, value: Double, unit: String, expected: Double? = nil) {
        self.name = name
        self.value = value
        self.unit = unit
        self.expected = expected
    }

    /// The measures of a list; one without its name, its number or its unit is left out.
    static func list(_ fields: BlockFields?, _ key: String) -> [TicketMeasure] {
        (fields?.list(key) ?? []).compactMap { item in
            guard let name = item.text("name"), let value = item.decimal("value"), let unit = item.text("unit") else { return nil }
            return TicketMeasure(name: name, value: value, unit: unit, expected: item.decimal("expected"))
        }
    }
}

/// A picture a run took (a QA tool's screenshot): the evidence that carries it, the step it was taken in and the
/// artifact's address.
public struct TicketPicture: Equatable, Hashable {
    /// What the evidence says it shows.
    public var caption: String?
    /// The QA step it was taken in, as the evidence names it ("1", "check_2"); nil when it names none.
    public var step: String?
    /// The artifact: its id, its label, its path on Symphony's API and whether Symphony still keeps it.
    public var screenshot: TicketScreenshot

    public init(caption: String?, step: String?, screenshot: TicketScreenshot) {
        self.caption = caption
        self.step = step
        self.screenshot = screenshot
    }
}

/// One finding of a code review's verdict: what it is, the file and the lines it is about, the code it quotes and the
/// fix it suggests.
public struct ReviewFinding: Equatable, Hashable {
    /// The lines a finding is about, 1-based, both included.
    public struct LineRange: Equatable, Hashable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    /// Whether the code it is about changed since the pull request was last reviewed.
    public enum SinceLastReview: Equatable, Hashable {
        case changed, unchanged
        /// A word this app does not know.
        case unknown(String)

        init(_ word: String) {
            switch word {
            case "changed": self = .changed
            case "unchanged": self = .unchanged
            default: self = .unknown(word)
            }
        }
    }

    public var summary: String?
    public var file: String?
    public var lineRange: LineRange?
    public var quotedSnippet: String?
    public var suggestedFix: String?
    /// The recorded decision it is about ("D1").
    public var decision: String?
    /// Nil on a first review, and on a verdict recorded before Symphony said it.
    public var sinceLastReview: SinceLastReview?

    public init(
        summary: String? = nil, file: String? = nil, lineRange: LineRange? = nil, quotedSnippet: String? = nil, suggestedFix: String? = nil,
        decision: String? = nil, sinceLastReview: SinceLastReview? = nil
    ) {
        self.summary = summary
        self.file = file
        self.lineRange = lineRange
        self.quotedSnippet = quotedSnippet
        self.suggestedFix = suggestedFix
        self.decision = decision
        self.sinceLastReview = sinceLastReview
    }

    /// A verdict's findings; one that names neither what it is nor its file is left out.
    static func list(_ fields: BlockFields?) -> [ReviewFinding] {
        (fields?.list("findings") ?? []).compactMap { item in
            let range = item.map("lineRange").flatMap { range -> LineRange? in
                guard let start = range.number("start"), let end = range.number("end") else { return nil }
                return LineRange(start: start, end: end)
            }
            let finding = ReviewFinding(
                summary: item.text("summary"), file: item.text("file"), lineRange: range, quotedSnippet: item.verbatim("quotedSnippet"),
                suggestedFix: item.text("suggestedFix"), decision: item.text("decision"),
                sinceLastReview: item.text("sinceLastReview").map(SinceLastReview.init)
            )
            return finding.summary == nil && finding.file == nil ? nil : finding
        }
    }
}

/// What a run that changed code changed (`run.changed`): the head it started and ended on, its commits and the files
/// that differ between them.
public struct RunChanges: Equatable, Hashable {
    /// One commit of the run, first parent only.
    public struct Commit: Equatable, Hashable {
        public var sha: String
        public var subject: String?

        public init(sha: String, subject: String? = nil) {
            self.sha = sha
            self.subject = subject
        }
    }

    /// One file the run changed.
    public struct File: Equatable, Hashable {
        public enum Status: Equatable, Hashable {
            case added, modified, deleted, renamed
            /// A word this app does not know.
            case unknown(String)

            init(_ word: String) {
                switch word {
                case "added": self = .added
                case "modified": self = .modified
                case "deleted": self = .deleted
                case "renamed": self = .renamed
                default: self = .unknown(word)
                }
            }
        }

        public var path: String
        public var status: Status
        /// The path a renamed file had.
        public var from: String?

        public init(path: String, status: Status, from: String? = nil) {
            self.path = path
            self.status = status
            self.from = from
        }
    }

    public var startHead: String?
    public var head: String?
    public var commits: [Commit]
    public var files: [File]
    /// How many commits and files there were when the lists were cut to their most entries; else the lists' counts.
    public var commitCount: Int
    public var fileCount: Int

    public init(startHead: String? = nil, head: String? = nil, commits: [Commit] = [], files: [File] = [], commitCount: Int? = nil, fileCount: Int? = nil) {
        self.startHead = startHead
        self.head = head
        self.commits = commits
        self.files = files
        self.commitCount = max(commitCount ?? commits.count, commits.count)
        self.fileCount = max(fileCount ?? files.count, files.count)
    }

    /// The changes a `run.changed` payload holds; nil when it names no head, no commit and no file. A commit without
    /// its sha and a file without its path are left out; a file without its status reads as an unknown status.
    init?(fields: BlockFields?) {
        guard let fields else { return nil }
        let commits = fields.list("commits").compactMap { item in item.text("sha").map { Commit(sha: $0, subject: item.text("subject")) } }
        let files = fields.list("files").compactMap { item -> File? in
            guard let path = item.text("path") else { return nil }
            return File(path: path, status: File.Status(item.text("status") ?? ""), from: item.text("from"))
        }
        let startHead = fields.text("startHead"), head = fields.text("head")
        guard startHead != nil || !commits.isEmpty || !files.isEmpty else { return nil }
        self.init(
            startHead: startHead, head: head, commits: commits, files: files, commitCount: fields.number("commitCount"),
            fileCount: fields.number("fileCount")
        )
    }
}

/// A run's test result (`tests.ran`), as the run that ran the tests recorded it: how many passed and failed and, when
/// it said, how many were skipped and how long they took. Never read from a command's output.
public struct TicketTestResult: Equatable, Hashable {
    public var passed: Int
    public var failed: Int
    public var skipped: Int?
    public var durationMs: Int?

    public init(passed: Int, failed: Int, skipped: Int? = nil, durationMs: Int? = nil) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.durationMs = durationMs
    }

    /// The result a payload holds; nil without its passed or its failed count, or with either of another type.
    init?(fields: BlockFields?) {
        guard let fields, let passed = fields.number("passed"), let failed = fields.number("failed") else { return nil }
        self.init(passed: passed, failed: failed, skipped: fields.number("skipped"), durationMs: fields.number("durationMs"))
    }
}

/// The check a test proves (`check.proved` whose `by` is `test`): the check's id in the plan and the test, as the run
/// named it.
public struct TicketProvedCheck: Equatable, Hashable {
    public var checkID: String
    public var test: String

    public init(checkID: String, test: String) {
        self.checkID = checkID
        self.test = test
    }

    /// The check a payload proves by a test; nil when it is proved another way or names no check or no test.
    init?(fields: BlockFields?) {
        guard let fields, fields.text("by") == "test", let checkID = fields.text("checkId"), let test = fields.text("test") else { return nil }
        self.init(checkID: checkID, test: test)
    }
}

/// The facts an event of the ticket's history carries in a fixed shape, read from its fields as Symphony records them,
/// never from its summary or any other text: the pictures an evidence holds, the values it measured, a QA step's
/// answer, a code review's findings, what a run changed, a run's test result, the check a test proves. An event in an
/// older shape, or of any other type, has none.
public struct TicketFacts: Equatable {
    public var pictures: [TicketPicture] = []
    /// An evidence's measured values (`measures`); a step answer's own are on its result.
    public var measures: [TicketMeasure] = []
    /// A QA step's answer: an evidence's or a check step's `result`, a grouped walk's `results`.
    public var answer: StepAnswer?
    /// A code review verdict's findings.
    public var findings: [ReviewFinding] = []
    /// What a run changed (`run.changed`).
    public var changes: RunChanges?
    /// A run's test result (`tests.ran`).
    public var testResult: TicketTestResult?
    /// The check a test proves (`check.proved` by a test).
    public var provedCheck: TicketProvedCheck?

    public init(
        pictures: [TicketPicture] = [], measures: [TicketMeasure] = [], answer: StepAnswer? = nil, findings: [ReviewFinding] = [],
        changes: RunChanges? = nil, testResult: TicketTestResult? = nil, provedCheck: TicketProvedCheck? = nil
    ) {
        self.pictures = pictures
        self.measures = measures
        self.answer = answer
        self.findings = findings
        self.changes = changes
        self.testResult = testResult
        self.provedCheck = provedCheck
    }

    public var isEmpty: Bool {
        pictures.isEmpty && measures.isEmpty && answer == nil && findings.isEmpty && changes == nil && testResult == nil && provedCheck == nil
    }
}

extension TicketEventsPayload.Event {
    /// The facts it carries in a fixed shape (`TicketFacts`).
    public var facts: TicketFacts {
        let pictures = type == "evidence"
            ? artifacts.filter(\.isImage).map { TicketPicture(caption: payload.caption, step: payload.step, screenshot: $0.screenshot) }
            : []
        return TicketFacts(
            pictures: pictures, measures: payload.measures, answer: payload.answer.flatMap(Self.stepAnswer),
            findings: type == "verdict.recorded" ? payload.findings : [], changes: type == "run.changed" ? payload.changes : nil,
            testResult: type == "tests.ran" ? payload.testResult : nil, provedCheck: type == "check.proved" ? payload.provedCheck : nil
        )
    }

    /// A QA step's answer: its result or a grouped walk's results; a step's other answers (a plan, rechecks, a
    /// non-QA step's entries) are not a QA step's answer.
    private static func stepAnswer(_ answer: StepAnswer) -> StepAnswer? {
        answer.result == nil && answer.results.isEmpty ? nil : StepAnswer(result: answer.result, results: answer.results)
    }
}

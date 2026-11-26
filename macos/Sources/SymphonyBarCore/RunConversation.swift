import Foundation

// A step's lines read as a conversation (`docs/design/prototypes/run-conversation/`, approved 2026-11-24): what the
// agent wrote is the content, and what it did after each note folds into one line under that note. Built from the
// lines alone, live or saved: a tool call's tool and file come from the line's fields (`TranscriptLine.tool` and
// `.file`), never from its text, so a transcript saved before Symphony carried them still folds and counts, and its
// gist names only what the fields give.

/// One action: a tool call and what came back, either missing while the call runs or when the source lost it.
public struct RunAction: Equatable {
    public var call: TranscriptLine?
    public var result: TranscriptLine?

    public init(call: TranscriptLine? = nil, result: TranscriptLine? = nil) {
        self.call = call
        self.result = result
    }

    /// Its tool failed: a failed command, a red test.
    public var failed: Bool { result?.failed == true }

    /// The lines it was drawn from, call first.
    public var lines: [TranscriptLine] { [call, result].compactMap { $0 } }

    /// The same failure as `other`: the same call and the same words back.
    public func isSameFailure(as other: RunAction) -> Bool {
        failed && other.failed && call?.text == other.call?.text && result?.text == other.result?.text
    }

    /// What came back, its first `count` lines.
    public func firstLines(_ count: Int = RunAction.shownLines) -> [String] {
        Array((result?.text ?? "").split(separator: "\n", omittingEmptySubsequences: true).prefix(count).map(String.init))
    }

    /// How many lines of what came back a failure row shows.
    public static let shownLines = 4
}

/// What a group of actions did, in one line: "wrote RecentlyDone.swift, ran 2 commands". Built from each call's tool and
/// file fields only.
public struct ActionGist: Equatable {
    public enum Part: Equatable {
        /// The files written: "wrote" and a chip a file.
        case wrote([String])
        /// The files edited: "edited" and a chip a file.
        case edited([String])
        /// A count in words: "read 1 file", "ran 22 commands", "ticket record ×3".
        case words(String)
    }

    public var count: Int
    public var parts: [Part]

    public init(_ actions: [RunAction]) {
        count = actions.count
        var order: [String] = []
        var tally: [String: Int] = [:]
        var files: [String: [String]] = [:]
        for action in actions {
            guard let tool = action.call?.tool?.trimmingCharacters(in: .whitespaces), !tool.isEmpty else { continue }
            let kind = Self.kind(of: tool)
            if tally[kind] == nil { order.append(kind) }
            tally[kind, default: 0] += 1
            if let file = action.call?.file.map(Self.fileName), !file.isEmpty, !(files[kind] ?? []).contains(file) {
                files[kind, default: []].append(file)
            }
        }
        parts = order.compactMap { kind in
            let count = tally[kind] ?? 0
            switch kind {
            case Self.write: return files[kind].map(Part.wrote) ?? .words("wrote " + Self.counted(count, "file"))
            case Self.edit: return files[kind].map(Part.edited) ?? .words("edited " + Self.counted(count, "file"))
            case Self.read: return .words("read " + Self.counted(count, "file"))
            case Self.command: return .words("ran " + Self.counted(count, "command"))
            case Self.search: return .words("searched " + Self.counted(count, "time"))
            default: return .words(count == 1 ? kind : "\(kind) ×\(count)")
            }
        }
    }

    /// "3 actions", "1 action"; "2 actions so far" while the run works on them.
    public func countText(soFar: Bool = false) -> String {
        Self.counted(count, "action") + (soFar ? " so far" : "")
    }

    /// The gist in words, the chips' files named: what VoiceOver reads after the count.
    public var text: String {
        parts.map { part in
            switch part {
            case let .wrote(files): "wrote " + files.joined(separator: ", ")
            case let .edited(files): "edited " + files.joined(separator: ", ")
            case let .words(words): words
            }
        }.joined(separator: ", ")
    }

    // The kinds a tool's name falls into; any other tool is named in words.
    static let write = "\u{1}write", edit = "\u{1}edit", read = "\u{1}read", command = "\u{1}command", search = "\u{1}search"

    /// A tool's kind: Claude's and OpenCode's names for writing, editing, reading, running a command and searching,
    /// else its name in words, an MCP tool's without its server ("mcp__symphony__ticket_record" is "ticket record").
    static func kind(of tool: String) -> String {
        switch tool.lowercased() {
        case "write": write
        case "edit", "multiedit", "notebookedit", "str_replace_based_edit_tool": edit
        case "read", "notebookread": read
        case "bash", "shell", "bashoutput": command
        case "grep", "glob", "ls", "list": search
        default: words(tool)
        }
    }

    static func words(_ tool: String) -> String {
        var name = Substring(tool)
        if name.hasPrefix("mcp__"), let server = name.dropFirst(5).range(of: "__") { name = name[server.upperBound...] }
        return name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").lowercased()
    }

    public static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

/// One entry of a step's conversation: a note with the actions after it, a run of actions with no note before them,
/// a failure, never folded, with how many times it came back to back, or a fact the run recorded there.
public struct ConversationEntry: Equatable, Identifiable {
    public enum Kind: Equatable {
        case note, actions, failure, fact
    }

    /// Stays with the entry as the run now's lines grow and its oldest drop out of the buffer.
    public var id: String
    public var kind: Kind
    /// The note, on a `.note` entry.
    public var note: TranscriptLine?
    /// The actions folded under the note, or the run of actions on an `.actions` entry.
    public var actions: [RunAction] = []
    /// The failed action, on a `.failure` entry.
    public var failure: RunAction?
    /// The fact, on a `.fact` entry.
    public var fact: RunFact?
    /// How many times the same failure came back to back.
    public var repeats = 1
    /// The minute line above the entry ("12:30"), only when the minute differs from the entry before.
    public var minute: String?
    /// The run works on it: the run now's last entry.
    public var working = false

    public init(id: String, kind: Kind, note: TranscriptLine? = nil, actions: [RunAction] = [], failure: RunAction? = nil, fact: RunFact? = nil) {
        self.id = id
        self.kind = kind
        self.note = note
        self.actions = actions
        self.failure = failure
        self.fact = fact
    }

    public var gist: ActionGist { ActionGist(actions) }

    /// Whether it draws a fold line: actions to fold, or the run working on a note.
    public var hasFold: Bool { !actions.isEmpty || (working && kind == .note) }

    /// When it began: its note's, its first action's, its failure's or its fact's time.
    public var date: Date? {
        note?.date ?? (actions.first?.lines ?? failure?.lines ?? []).lazy.compactMap(\.date).first ?? fact?.date
    }
}

public enum RunConversation {
    /// The conversation of `lines`, top to bottom, with each of `facts` where the run recorded it: after the lines
    /// written up to its time, before the first written later; one with no time, or recorded after the last line, comes
    /// last. Facts side by side of a kind that reads as one (evidence, the checks of one test, answers) are one entry.
    /// `live`: the run works on the last entry.
    public static func entries(
        _ lines: [TranscriptLine], facts: [RunFact] = [], live: Bool = false, timeZone: TimeZone = .current
    ) -> [ConversationEntry] {
        var entries: [ConversationEntry] = []
        var ids: [String: Int] = [:]
        func id(_ line: TranscriptLine?, _ kind: ConversationEntry.Kind) -> String {
            let base = "\(kind)|\(line?.at ?? "")|\(line?.text ?? "")"
            ids[base, default: 0] += 1
            return ids[base]! == 1 ? base : "\(base)#\(ids[base]!)"
        }

        var pending = facts.enumerated().sorted { lhs, rhs in
            switch (lhs.element.date, rhs.element.date) {
            case let (left?, right?): left == right ? lhs.offset < rhs.offset : left < right
            case (nil, nil): lhs.offset < rhs.offset
            case (_?, nil): true
            case (nil, _?): false
            }
        }.map(\.element)[...]
        func place(_ fact: RunFact) {
            if let last = entries.indices.last, entries[last].kind == .fact, let earlier = entries[last].fact, let merged = earlier.merged(with: fact) {
                entries[last].fact = merged
            } else {
                entries.append(ConversationEntry(id: "fact|" + fact.id, kind: .fact, fact: fact))
            }
        }

        for item in items(lines) {
            if let date = item.date {
                while let fact = pending.first, let at = fact.date, at < date {
                    place(fact)
                    pending.removeFirst()
                }
            }
            switch item {
            case let .note(line):
                entries.append(ConversationEntry(id: id(line, .note), kind: .note, note: line))
            case let .action(action) where action.failed:
                if let last = entries.indices.last, entries[last].kind == .failure, let earlier = entries[last].failure,
                   action.isSameFailure(as: earlier) {
                    entries[last].repeats += 1
                } else {
                    entries.append(ConversationEntry(id: id(action.call ?? action.result, .failure), kind: .failure, failure: action))
                }
            case let .action(action):
                if let last = entries.indices.last, entries[last].kind != .failure, entries[last].kind != .fact {
                    entries[last].actions.append(action)
                } else {
                    entries.append(ConversationEntry(id: id(action.call ?? action.result, .actions), kind: .actions, actions: [action]))
                }
            }
        }

        pending.forEach(place)

        var shown: String?
        for index in entries.indices {
            guard let date = entries[index].date else { continue }
            let minute = SharedDateFormatter.string(date, format: "HH:mm", timeZone: timeZone)
            if minute != shown { entries[index].minute = minute }
            shown = minute
        }
        if live, !entries.isEmpty { entries[entries.count - 1].working = true }
        return entries
    }

    enum Item: Equatable {
        case note(TranscriptLine)
        case action(RunAction)

        /// When it was written: a note's, or an action's call's (else its result's).
        var date: Date? {
            switch self {
            case let .note(line): line.date
            case let .action(action): action.lines.lazy.compactMap(\.date).first
            }
        }
    }

    /// The lines as notes and actions, each result with the oldest call still waiting on one (calls made together come
    /// back in the order they were made). An action stands where its call was made.
    static func items(_ lines: [TranscriptLine]) -> [Item] {
        var items: [Item] = []
        var actions: [Int: RunAction] = [:]
        var waiting: [Int] = []
        for line in lines {
            switch line.kind {
            case .say:
                items.append(.note(line))
            case .tool:
                actions[items.count] = RunAction(call: line)
                waiting.append(items.count)
                items.append(.action(RunAction(call: line)))
            case .result:
                if let index = waiting.first {
                    waiting.removeFirst()
                    actions[index]?.result = line
                } else {
                    actions[items.count] = RunAction(result: line)
                    items.append(.action(RunAction(result: line)))
                }
            }
        }
        return items.enumerated().map { index, item in actions[index].map(Item.action) ?? item }
    }
}

/// Which groups of a step's conversation are unfolded: each by a click on its fold line, or all at once by the step's
/// "Show all events".
public struct ConversationFolds: Equatable {
    public private(set) var opened: Set<String>
    public private(set) var showsAll: Bool

    public init(opened: Set<String> = [], showsAll: Bool = false) {
        self.opened = opened
        self.showsAll = showsAll
    }

    public func isOpen(_ id: String) -> Bool { showsAll || opened.contains(id) }

    /// Folds or unfolds the group `id` alone; with every group shown, the others stay open.
    public mutating func toggle(_ id: String, among ids: [String]) {
        if showsAll {
            showsAll = false
            opened = Set(ids).subtracting([id])
        } else if opened.contains(id) {
            opened.remove(id)
        } else {
            opened.insert(id)
        }
    }

    /// "Show all events": unfolds every group; again, folds them all.
    public mutating func toggleAll() {
        showsAll.toggle()
        opened = []
    }

    public static let showAll = "Show all events"
    public static let foldAll = "Fold all events"
}

/// A note's Markdown as the blocks the conversation draws (`ConductorMarkup`: paragraphs, bold, italic, inline code,
/// lists and code blocks). A `* ` bullet reads as a `- ` one and a heading as a bold paragraph; a numbered line keeps its
/// number. Every paragraph is body text: a note has no headline.
public enum RunNote {
    public static func markup(_ text: String) -> ConductorMarkup {
        var inCode = false
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); return line }
            if inCode { return line }
            if trimmed.hasPrefix("* ") { return "- " + String(trimmed.dropFirst(2)) }
            if let heading = heading(trimmed) { return "**" + heading + "**" }
            return line
        }
        var markup = ConductorMarkup(lines.joined(separator: "\n"))
        markup.roles = markup.blocks.map { _ in .body }
        return markup
    }

    static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let words = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words
    }
}

// MARK: - Facts

/// A fact a run recorded, drawn in its conversation where the run recorded it (TP-1698, the design's "facts drawn as
/// components"): a review's verdict with its findings, a QA step's answer, evidence with its counts, measured values
/// and pictures, a test result, the checks a test proves, the files and commits a run changed. Read from the event's
/// decoded facts (`TicketEventsPayload.Event.facts`) and, for a verdict, its kind and outcome; never from a line's text
/// or a command's output.
public struct RunFact: Equatable, Identifiable {
    /// A review's verdict: its word and the state its chip takes, and its findings.
    public struct Verdict: Equatable {
        public var word: String
        public var state: RunGroupModel.State
        public var findings: [ReviewFinding]

        public init(word: String, state: RunGroupModel.State, findings: [ReviewFinding] = []) {
            self.word = word
            self.state = state
            self.findings = findings
        }
    }

    /// One judged step of an answer: "Step 3", failed.
    public struct Mark: Equatable {
        public var title: String
        public var state: RunStep.State
        /// What it judged: "Passed", "Failed", "Blocked", with the status when it says more ("Done · plan_mismatch").
        public var word: String

        public init(title: String, state: RunStep.State, word: String? = nil) {
            self.title = title
            self.state = state
            self.word = word ?? Self.word(state)
        }

        /// A judgement's word: a pass reads "Passed", not the step's "Done".
        static func word(_ state: RunStep.State) -> String { state == .done ? "Passed" : state.word }

        /// A result's word: its judgement's, or "Done" for a status that is not one, with that status after it.
        static func word(_ result: StepAnswer.Result) -> String {
            (result.judgement.map { Self.word($0) } ?? RunStep.State.done.word) + (result.extraWord.map { " · " + $0 } ?? "")
        }
    }

    /// How many evidence events the run recorded for a step ("Step 6 evidence 4"); `step` nil when they name none.
    public struct EvidenceCount: Equatable {
        public var step: String?
        public var count: Int

        public init(step: String?, count: Int) {
            self.step = step
            self.count = count
        }

        /// "Step 6 evidence", "Evidence".
        public var title: String { step.map { "Step \($0) evidence" } ?? "Evidence" }
    }

    public enum Kind: Equatable {
        case verdict(Verdict)
        /// A QA step's answer: its judged steps, and the values it measured.
        case answer([Mark], measures: [TicketMeasure])
        case evidence(counts: [EvidenceCount], measures: [TicketMeasure], pictures: [TicketPicture])
        case testResult(TicketTestResult)
        /// The checks one test proves, in the order the run proved them.
        case provedChecks(test: String, checkIDs: [String])
        case changes(RunChanges)
    }

    /// The event's id, with the kind's when one event gives more than one fact.
    public var id: String
    /// When the run recorded it: where it stands in the conversation.
    public var date: Date?
    public var kind: Kind

    public init(id: String, date: Date?, kind: Kind) {
        self.id = id
        self.date = date
        self.kind = kind
    }

    /// The pictures it shows.
    public var pictures: [TicketPicture] {
        if case let .evidence(_, _, pictures) = kind { return pictures }
        return []
    }

    /// The facts `event` gives, in the order they are drawn: a verdict, the evidence, the answer, a test result, the
    /// checks a test proves, the changes. None for an event that carries no fact.
    public static func facts(_ event: TicketEventsPayload.Event) -> [RunFact] {
        let facts = event.facts
        var kinds: [(String, Kind)] = []
        if event.type == "verdict.recorded", let verdict = verdict(kind: event.payload.kind, outcome: event.payload.outcome, findings: facts.findings) {
            kinds.append(("verdict", .verdict(verdict)))
        }
        if event.type == "evidence" || !facts.measures.isEmpty || !facts.pictures.isEmpty {
            let counts = event.type == "evidence" ? [EvidenceCount(step: event.payload.step?.trimmingWhitespace().nonEmpty, count: 1)] : []
            kinds.append(("evidence", .evidence(counts: counts, measures: facts.measures, pictures: facts.pictures)))
        }
        if let answer = facts.answer {
            let marks = self.marks(answer, title: event.payload.step?.trimmingWhitespace().nonEmpty.map { "Step \($0)" } ?? event.payload.title)
            let measures = (answer.result?.measures ?? []) + answer.results.flatMap(\.result.measures)
            if !marks.isEmpty || !measures.isEmpty { kinds.append(("answer", .answer(marks, measures: measures))) }
        }
        if let result = facts.testResult { kinds.append(("tests", .testResult(result))) }
        if let proved = facts.provedCheck { kinds.append(("check", .provedChecks(test: proved.test, checkIDs: [proved.checkID]))) }
        if let changes = facts.changes { kinds.append(("changes", .changes(changes))) }
        return kinds.enumerated().map { index, kind in
            RunFact(id: index == 0 ? event.id : event.id + "|" + kind.0, date: event.date, kind: kind.1)
        }
    }

    /// A verdict's word and state from its kind and outcome as Symphony records them: a review that sent the work back
    /// reads "Request changes" in the Sent back treatment, a blocked one "Blocked"; nil without an outcome.
    static func verdict(kind: String?, outcome: String?, findings: [ReviewFinding]) -> Verdict? {
        if let picked = RunGroupModel.State.verdict(kind: kind, outcome: outcome) {
            return Verdict(word: picked.1, state: picked.0, findings: findings)
        }
        guard let outcome = outcome?.trimmingWhitespace().lowercased().nonEmpty else { return nil }
        switch outcome {
        case "approve", "approved": return Verdict(word: "Approved", state: .passed, findings: findings)
        case "pass", "passed": return Verdict(word: "Passed", state: .passed, findings: findings)
        case "fail", "failed": return Verdict(word: "Failed", state: .failed, findings: findings)
        default:
            let words = outcome.replacingOccurrences(of: "_", with: " ")
            return Verdict(word: words.prefix(1).uppercased() + words.dropFirst(), state: .passed, findings: findings)
        }
    }

    /// An answer's judged steps: its result, titled as `title` says, or each step a grouped walk judged.
    static func marks(_ answer: StepAnswer, title: String?) -> [Mark] {
        var marks: [Mark] = []
        if let result = answer.result, result.status != nil {
            marks.append(Mark(title: title?.trimmingWhitespace().nonEmpty ?? "Answer", state: result.judgement ?? .done, word: Mark.word(result)))
        }
        marks += answer.results.map { Mark(title: $0.title, state: $0.state, word: Mark.word($0.result)) }
        return marks
    }

    /// `next` folded into this fact when they are drawn as one: evidence after evidence (their counts by step summed,
    /// measures and pictures kept in order), the checks of the same test, one answer after another. Nil otherwise.
    func merged(with next: RunFact) -> RunFact? {
        var kind: Kind
        switch (self.kind, next.kind) {
        case let (.evidence(counts, measures, pictures), .evidence(moreCounts, moreMeasures, morePictures)):
            var summed = counts
            for count in moreCounts {
                if let index = summed.firstIndex(where: { $0.step == count.step }) { summed[index].count += count.count } else { summed.append(count) }
            }
            kind = .evidence(counts: summed, measures: measures + moreMeasures, pictures: pictures + morePictures)
        case let (.provedChecks(test, checks), .provedChecks(nextTest, more)) where test == nextTest:
            kind = .provedChecks(test: test, checkIDs: checks + more.filter { !checks.contains($0) })
        case let (.answer(marks, measures), .answer(more, moreMeasures)):
            kind = .answer(marks + more, measures: measures + moreMeasures)
        default:
            return nil
        }
        return RunFact(id: id, date: date, kind: kind)
    }
}

extension [RunFact] {
    /// The ids of the pictures the facts show: a screenshot drawn in the conversation is not drawn again beside it.
    public var pictureIDs: Set<String> { Set(flatMap(\.pictures).map(\.screenshot.id)) }
}

extension TicketMeasure {
    /// "1440 pt", "0.42 s": the number as short as it reads, then its unit.
    public var valueText: String { Self.number(value) + (unit.isEmpty ? "" : " " + unit) }

    /// "expected 80 pt", nil when no number was expected.
    public var expectedText: String? { expected.map { "expected " + Self.number($0) + (unit.isEmpty ? "" : " " + unit) } }

    /// It missed the number expected.
    public var missed: Bool { expected.map { $0 != value } ?? false }

    /// "Window width 1440 pt", "Menu label width 0 pt, expected 80 pt".
    public var text: String { ([name + " " + valueText, missed ? expectedText : nil].compactMap { $0 }).joined(separator: ", ") }

    static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}

extension TicketTestResult {
    /// "41 passed, 1 failed, 2 skipped · 1 min 35 s".
    public var text: String {
        var counts = ["\(passed) passed", "\(failed) failed"]
        if let skipped, skipped > 0 { counts.append("\(skipped) skipped") }
        let time = durationMs.map { Self.duration($0) }
        return ([counts.joined(separator: ", "), time].compactMap { $0 }).joined(separator: " · ")
    }

    /// It recorded a failure.
    public var isRed: Bool { failed > 0 }

    static func duration(_ ms: Int) -> String {
        let seconds = ms / 1_000
        if seconds < 60 { return seconds == 0 ? "\(ms) ms" : "\(seconds) s" }
        return "\(seconds / 60) min" + (seconds % 60 == 0 ? "" : " \(seconds % 60) s")
    }
}

extension ReviewFinding {
    /// The file's name, the last part of its path.
    public var fileName: String? { file.map(ActionGist.fileName) }

    /// "70–79", "9": the lines it is about.
    public var linesText: String? {
        lineRange.map { $0.start == $0.end ? "\($0.start)" : "\($0.start)–\($0.end)" }
    }
}

extension RunChanges.Commit {
    /// The sha's first seven characters.
    public var shortSHA: String { String(sha.prefix(7)) }
}

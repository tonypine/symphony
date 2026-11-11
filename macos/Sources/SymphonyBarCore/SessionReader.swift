import Foundation

// The session reader (`docs/design/director-ticket-page.md` §2 question 3, analysis §2.5 decision (c) and §6.1): the
// window that reads one run's whole session, opened from its Run group's More as "Read the whole session". Its lines
// are the run's steps' transcripts top to bottom, the step the run now is on with its newest lines; each line reads
// in short and expands in place to its full text.

/// One run's whole session, step by step, as the reader shows it.
public struct SessionReader: Equatable {
    /// What one step holds in the reader.
    public enum Content: Equatable {
        case lines([Line])
        /// Its transcript is being read.
        case loading
        /// Symphony no longer keeps it.
        case unavailable
        /// It couldn't be read just now.
        case failed
        /// Its transcript, or the run now's step, holds no line.
        case empty
        /// Symphony kept no lines for it: a step Symphony ran itself, or one skipped.
        case noTranscript
    }

    /// One line with the key that stays with it as the run now's lines come in.
    public struct Line: Equatable, Identifiable {
        public var id: String
        public var line: TranscriptLine
        /// Its short form cuts something off: it has more than one line, or more than `shortLength` characters.
        public var expands: Bool

        public init(id: String, line: TranscriptLine) {
            self.id = id
            self.line = line
            expands = line.text.contains(where: \.isNewline) || line.text.count > SessionReader.shortLength
        }
    }

    /// One step: its header and its lines.
    public struct Section: Equatable, Identifiable {
        public var step: RunStep
        public var content: Content

        public var id: String { step.id }

        public init(step: RunStep, content: Content) {
            self.step = step
            self.content = content
        }
    }

    /// The ticket the run worked on.
    public var identifier: String
    public var run: RunGroupModel
    public var sections: [Section]

    public init(identifier: String, run: RunGroupModel, sections: [Section]) {
        self.identifier = identifier
        self.run = run
        self.sections = sections
    }

    /// The characters a line shows in short.
    public static let shortLength = 160

    /// The window's title: "TP-1452 · Implementation run 2".
    public var windowTitle: String { "\(identifier) · \(run.title)" }

    /// Every line of the session, top to bottom.
    public var lines: [Line] {
        sections.flatMap { section -> [Line] in
            if case let .lines(lines) = section.content { return lines }
            return []
        }
    }

    /// The menu item on a Run group's More that opens it.
    public static let menuTitle = "Read the whole session"
    /// Why the item is off: the run has no step with lines to read.
    public static let nothingToRead = "This run has nothing to read yet"
    public static let noSteps = "This run recorded no steps."

    /// Whether `run` has anything for the reader: a step with a transcript, or lines, or the step the run now is on.
    public static func canRead(_ run: RunGroupModel) -> Bool {
        run.steps.contains(where: \.canUnfold)
    }

    /// The reader of `run` on ticket `identifier`, each step's transcript as `lines` has it now.
    public static func build(
        identifier: String, run: RunGroupModel, lines: (TicketOutput) -> StepTranscripts.Lines
    ) -> SessionReader {
        let sections = run.steps.map { step -> Section in
            if step.isLive, !step.liveLines.isEmpty || step.transcript == nil {
                return Section(step: step, content: keyed(step.liveLines, step: step))
            }
            guard let transcript = step.transcript else { return Section(step: step, content: .noTranscript) }
            switch lines(transcript) {
            case .loading: return Section(step: step, content: .loading)
            case .unavailable: return Section(step: step, content: .unavailable)
            case .failed: return Section(step: step, content: .failed)
            case let .loaded(read): return Section(step: step, content: keyed(read, step: step))
            }
        }
        return SessionReader(identifier: identifier, run: run, sections: sections)
    }

    /// `lines` keyed under their step, so two steps' alike lines never share a key.
    static func keyed(_ lines: [TranscriptLine], step: RunStep) -> Content {
        guard !lines.isEmpty else { return .empty }
        var seen: [String: Int] = [:]
        return .lines(lines.map { line in
            let base = "\(step.id)|\(line.at ?? "")|\(line.kind.rawValue)|\(line.text)"
            seen[base, default: 0] += 1
            let count = seen[base]!
            return Line(id: count == 1 ? base : "\(base)#\(count)", line: line)
        })
    }

    /// What a step without lines says.
    public static func note(_ content: Content, live: Bool) -> String? {
        switch content {
        case .lines: nil
        case .loading: "Reading what happened in this step…"
        case .unavailable: "Symphony no longer keeps what happened in this step."
        case .failed: "Couldn't read what happened in this step. Close the window and open it again to try again."
        case .empty: live ? "The agent hasn't said anything in this step yet." : "The agent said nothing in this step."
        case .noTranscript: "Symphony kept no lines for this step."
        }
    }

    /// The expand control's words for VoiceOver.
    public static func expandLabel(expanded: Bool) -> String { expanded ? "Show less" : "Show all" }
}

/// The line at the top of the timeline when no run works on the ticket: why nothing runs, in the situation's words,
/// in the place the run now takes, so the page keeps its shape (§2 question 3).
public struct TimelineIdleLine: Equatable {
    public var kind: DesignTokens.SituationKind
    /// "No run now".
    public var lead: String
    /// The situation's word: "Waiting on you", "Waiting for a slot", "Shipped".
    public var word: String
    /// Its cause and what moves it next.
    public var detail: String?

    public init(kind: DesignTokens.SituationKind, word: String, detail: String?) {
        self.kind = kind
        lead = Self.noRun
        self.word = word
        self.detail = detail
    }

    public static let noRun = "No run now"

    /// The line for `situation`; nil when there is none.
    public init?(_ situation: Situation?, reference: Date) {
        guard let situation else { return nil }
        let text = SituationText(situation, reference: reference)
        let detail = [text.cause, text.next].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        self.init(kind: text.kind, word: text.word, detail: detail.isEmpty ? nil : detail)
    }

    /// What VoiceOver reads: "No run now. Waiting on you: Answer the question."
    public var accessibilityLabel: String {
        "\(lead). " + (detail.map { "\(word): \($0)" } ?? word)
    }
}

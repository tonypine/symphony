import Foundation

// The brief on top of the ticket page's main column (`docs/design/director-window-and-home.md`, The ticket page; the
// catalog's `briefBlock` and `briefTitle`, TP-1504): what the ticket did and how to see it, in the words of the run
// that wrote it, under a label naming that run and when. Before a run has written one, the same place is "Asked for",
// with the ticket's goal (the first section of its description).

/// What the brief's label and panel say.
public struct BriefPanelModel: Equatable {
    public enum Kind: Equatable {
        /// The newest brief a run wrote: three lines, and the fold that shows the rest.
        case brief
        /// No run has written one: the ticket's goal, without a fold.
        case askedFor
    }

    public var kind: Kind
    /// "Brief", "Asked for".
    public var title: String
    /// "written by Implementation run 2 at 11:20", "no run has written a brief yet".
    public var note: String?
    /// The text the panel opens with: the brief, or the ticket's goal.
    public var text: String
    /// The brief's walkthrough, shown unfolded.
    public var walkthrough: String?
    /// The ticket's description as the agent received it, shown unfolded under "What was asked".
    public var asked: String?

    public static let briefTitle = "Brief"
    public static let askedForTitle = "Asked for"
    public static let noBriefNote = "no run has written a brief yet"
    public static let walkthroughTitle = "Walkthrough"
    public static let askedTitle = "What was asked"
    public static let readAllTitle = "Read all of it, with the walkthrough"
    public static let showLessTitle = "Show less"
    /// The lines the folded brief shows.
    public static let foldedLines = 3

    /// Whether the panel has a fold: only a brief does.
    public var folds: Bool { kind == .brief }

    /// The fold control's title as it reads while `open`.
    public static func foldTitle(open: Bool) -> String { open ? showLessTitle : readAllTitle }

    /// The panel from the ticket read: its newest brief, named after the run that wrote it (`runs`, by run id, from
    /// the events feed); else the goal of its description. Nil for a ticket with neither. Times read in `calendar`,
    /// against `reference`'s day.
    public static func build(
        _ read: TicketDetailsRead?, runs: [String: TicketEventsPayload.Run], reference: Date, calendar: Calendar = .current
    ) -> BriefPanelModel? {
        let description = read?.ticket?.description?.trimmingWhitespace()
        let markdown = description.flatMap { $0.isEmpty ? nil : $0 }
        let asked = markdown.map(prose(of:)).flatMap { $0.isEmpty ? nil : $0 }
        if let brief = read?.brief, !brief.text.trimmingWhitespace().isEmpty {
            let text = brief.text.trimmingWhitespace()
            let walkthrough = brief.walkthrough?.trimmingWhitespace()
            return BriefPanelModel(
                kind: .brief, title: briefTitle, note: writtenNote(brief, runs: runs, reference: reference, calendar: calendar),
                text: text, walkthrough: walkthrough.flatMap { $0.isEmpty ? nil : $0 }, asked: asked
            )
        }
        guard let markdown, let goal = goal(of: markdown).map(prose(of:)), !goal.isEmpty else { return nil }
        return BriefPanelModel(kind: .askedFor, title: askedForTitle, note: noBriefNote, text: goal, walkthrough: nil, asked: nil)
    }

    /// "written by Implementation run 2 at 11:20": the run that wrote it, when the feed knows it, and when; nil when
    /// the read says neither.
    static func writtenNote(_ brief: TicketBriefRead, runs: [String: TicketEventsPayload.Run], reference: Date, calendar: Calendar) -> String? {
        var who: String?
        if let runID = brief.runID, let run = runs[runID] {
            who = TicketEventsPayload.runTitle(kind: run.runKind, number: run.runNumber)
        } else if let kind = brief.runKind {
            who = TicketEventsPayload.runTitle(kind: kind, number: nil)
        }
        let when = brief.at.map { moment($0, reference: reference, calendar: calendar) }
        guard who != nil || when != nil else { return nil }
        return (["written"] + [who.map { "by \($0)" }, when].compactMap { $0 }).joined(separator: " ")
    }

    /// "at 11:20" today, "yesterday at 09:10", "on Fri 6 Nov at 18:40".
    static func moment(_ date: Date, reference: Date, calendar: Calendar) -> String {
        let said = FactsMoment.say(date, reference: reference, calendar: calendar)
        if said.hasPrefix("today ") { return String(said.dropFirst("today ".count)) }
        if said.hasPrefix("yesterday ") { return said }
        return "on " + said
    }

    /// The description's first section: the text before its first heading, else the first heading's text, without
    /// the heading; nil when no section holds text.
    public static func goal(of description: String) -> String? {
        var sections: [[String]] = [[]]
        for line in description.components(separatedBy: "\n") {
            if isHeading(line) {
                sections.append([])
            } else {
                sections[sections.count - 1].append(line)
            }
        }
        return sections.lazy
            .map { $0.joined(separator: "\n").trimmingWhitespace() }
            .first { !$0.isEmpty }
    }

    /// The description's Markdown as plain prose, the way the catalog's `briefBlock` reads it: a heading is its words
    /// on a line of their own, a list item or a quote loses its marker (and a task's box), emphasis loses its stars
    /// and underscores, a link is its text, and an image, a rule, a code fence and Linear's fold marker (`+++`) go;
    /// a fold's title stays as a line. Code in backticks stays, for the mono face; runs of blank lines are one.
    public static func prose(of markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") || isRule(line) { continue }
            if line.hasPrefix("+++") {
                line = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }
            if isHeading(line) { line = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            line = replacing(listMarker, in: line, with: "")
            line = replacing(taskBox, in: line, with: "")
            line = replacing(image, in: line, with: "")
            line = replacing(link, in: line, with: "$1")
            line = replacing(emphasis, in: line, with: "$2")
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingWhitespace()
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^(?:[-*+]|\d{1,3}[.)])\s+"#)
    private static let taskBox = try! NSRegularExpression(pattern: #"^\[[ xX]\]\s+"#)
    private static let image = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<![\w*])(\*\*|__|\*|_)(?=\S)(.+?)(?<=\S)\1(?![\w*])"#)

    private static func replacing(_ pattern: NSRegularExpression, in line: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: template)
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func isHeading(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        let rest = trimmed.dropFirst(hashes.count)
        return rest.first == " " && !rest.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Code and paths in reading text

/// Reading text cut into its prose and its code: a span in backticks, a path (`docs/design/catalog/index.html`,
/// `~/Library`) or a file name (`Entries.swift`), which the brief sets in the mono face at 0.85 of its size.
public enum ReadingSpans {
    public struct Span: Equatable {
        public var text: String
        public var code: Bool

        public init(_ text: String, code: Bool) {
            self.text = text
            self.code = code
        }
    }

    /// The mono face's size, as a fraction of the reading text's.
    public static let codeScale = 0.85

    private static let pattern = try! NSRegularExpression(
        pattern: #"`([^`\n]+)`|(?<![\w/.~-])(?:(?:~|\.{1,2})?(?:/[\w.-]+)+|[\w.-]+(?:/[\w.-]+)+)/?|(?<![\w/.-])[\w-]+\.(?:swift|exs?|md|json|ya?ml|js|ts|css|html|py|sh|txt|png|toml|liquid)\b"#
    )

    /// `text`'s spans in order; adjacent prose stays one span. A word with one slash between two letters ("and/or")
    /// is prose: a path has a dot, a leading slash or tilde, or two slashes. A sentence's full stop after a path is
    /// prose.
    public static func split(_ text: String) -> [Span] {
        let whole = NSRange(text.startIndex..., in: text)
        var spans: [Span] = []
        var cursor = text.startIndex
        func prose(upTo end: String.Index) {
            guard cursor < end else { return }
            let piece = String(text[cursor..<end])
            if let last = spans.last, !last.code {
                spans[spans.count - 1].text += piece
            } else {
                spans.append(Span(piece, code: false))
            }
        }
        for match in pattern.matches(in: text, range: whole) {
            guard var range = Range(match.range, in: text) else { continue }
            var code: String
            if let quoted = Range(match.range(at: 1), in: text) {
                code = String(text[quoted])
            } else {
                while let last = text[range].last, last == "." || last == "-" {
                    range = range.lowerBound..<text.index(before: range.upperBound)
                }
                code = String(text[range])
                guard isPath(code) else { continue }
            }
            prose(upTo: range.lowerBound)
            spans.append(Span(code, code: true))
            cursor = range.upperBound
        }
        prose(upTo: text.endIndex)
        return spans
    }

    private static func isPath(_ token: String) -> Bool {
        let slashes = token.filter { $0 == "/" }.count
        if slashes == 0 { return token.contains(".") }
        return token.contains(".") || token.hasPrefix("/") || token.hasPrefix("~") || slashes >= 2
    }
}

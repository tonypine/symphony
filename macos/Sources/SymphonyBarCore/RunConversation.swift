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

    static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

/// One entry of a step's conversation: a note with the actions after it, a run of actions with no note before them,
/// or a failure, never folded, with how many times it came back to back.
public struct ConversationEntry: Equatable, Identifiable {
    public enum Kind: Equatable {
        case note, actions, failure
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
    /// How many times the same failure came back to back.
    public var repeats = 1
    /// The minute line above the entry ("12:30"), only when the minute differs from the entry before.
    public var minute: String?
    /// The run works on it: the run now's last entry.
    public var working = false

    public init(id: String, kind: Kind, note: TranscriptLine? = nil, actions: [RunAction] = [], failure: RunAction? = nil) {
        self.id = id
        self.kind = kind
        self.note = note
        self.actions = actions
        self.failure = failure
    }

    public var gist: ActionGist { ActionGist(actions) }

    /// Whether it draws a fold line: actions to fold, or the run working on a note.
    public var hasFold: Bool { !actions.isEmpty || (working && kind == .note) }

    /// When it began: its note's, its first action's or its failure's time.
    public var date: Date? {
        note?.date ?? (actions.first?.lines ?? failure?.lines ?? []).lazy.compactMap(\.date).first
    }
}

public enum RunConversation {
    /// The conversation of `lines`, top to bottom. `live`: the run works on the last entry.
    public static func entries(_ lines: [TranscriptLine], live: Bool = false, timeZone: TimeZone = .current) -> [ConversationEntry] {
        var entries: [ConversationEntry] = []
        var ids: [String: Int] = [:]
        func id(_ line: TranscriptLine?, _ kind: ConversationEntry.Kind) -> String {
            let base = "\(kind)|\(line?.at ?? "")|\(line?.text ?? "")"
            ids[base, default: 0] += 1
            return ids[base]! == 1 ? base : "\(base)#\(ids[base]!)"
        }

        for item in items(lines) {
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
                if let last = entries.indices.last, entries[last].kind != .failure {
                    entries[last].actions.append(action)
                } else {
                    entries.append(ConversationEntry(id: id(action.call ?? action.result, .actions), kind: .actions, actions: [action]))
                }
            }
        }

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

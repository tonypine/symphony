import Foundation

/// What the Conductor writes for a person, read into the blocks and phrases the timeline draws. The Conductor's text is
/// plain words with a little markup: paragraphs (a blank line between), `**bold**`, `*italic*`, `` `code` ``,
/// `[a link](https://…)`, `- ` bullet lists, a fenced code block whose lines starting `+` or `-` read as added and
/// removed, and a status tag around a phrase, `{problem}…{/}`, `{done}…{/}` or `{you}…{/}`.
///
/// Reading never fails and never drops a word: a marker without its partner, a tag it does not know and a link whose
/// address is not a web address stay in the text as written, and a text with no markup is its paragraphs (the
/// Conductor's older updates are plain).
public struct ConductorMarkup: Equatable {
    /// One phrase of a paragraph, a list item or a code line.
    public indirect enum Phrase: Equatable {
        case plain(String)
        case bold([Phrase])
        case italic([Phrase])
        case code(String)
        case link(label: [Phrase], destination: URL)
        /// A phrase in a status's text colour, semibold.
        case status(DesignTokens.Status, [Phrase])
    }

    /// One line of a fenced code block.
    public struct CodeLine: Equatable {
        public enum Change: Equatable {
            case added, removed, unchanged
        }

        public var text: String
        public var change: Change

        public init(text: String, change: Change) {
            self.text = text
            self.change = change
        }
    }

    public enum Block: Equatable {
        case paragraph([Phrase])
        case list([[Phrase]])
        case codeBlock([CodeLine])
    }

    /// What a paragraph is to the message around it.
    public enum Role: Equatable {
        /// The first paragraph, drawn semibold.
        case headline
        case body
        /// A last paragraph starting `Next:`, drawn in the secondary text colour.
        case next
    }

    public var blocks: [Block]
    /// The role of each block, in order.
    public var roles: [Role]

    public init(blocks: [Block]) {
        self.blocks = blocks
        roles = blocks.indices.map { index in
            guard case let .paragraph(phrases) = blocks[index] else { return .body }
            if index == 0 { return .headline }
            let isLast = index == blocks.count - 1
            return isLast && Self.plainText(of: phrases).hasPrefix(Self.nextPrefix) ? .next : .body
        }
    }

    /// Reads `text`.
    public init(_ text: String) {
        let blocks = Self.blocks(of: text)
        // A text with no markup at all is plain words (the Conductor's older updates): each line is a paragraph.
        let isPlain = blocks.allSatisfy { block in
            if case let .paragraph(phrases) = block { return phrases.allSatisfy { if case .plain = $0 { true } else { false } } }
            return false
        }
        if isPlain, blocks.count == 1 || text.contains("\n") {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self.init(blocks: lines.map { .paragraph([.plain($0)]) })
        } else {
            self.init(blocks: blocks)
        }
    }

    /// The word a last paragraph starts with when it says what happens next.
    public static let nextPrefix = "Next:"

    public var isEmpty: Bool { blocks.isEmpty }

    /// The words without any markup, one paragraph, list item or code line after another, a line break between: what
    /// VoiceOver reads.
    public var plainText: String {
        blocks.map { block in
            switch block {
            case let .paragraph(phrases): Self.plainText(of: phrases)
            case let .list(items): items.map { "- " + Self.plainText(of: $0) }.joined(separator: "\n")
            case let .codeBlock(lines): lines.map(\.text).joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    /// The words without any markup on one line, for a line that has room for one.
    public var oneLine: String {
        plainText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func plainText(of phrases: [Phrase]) -> String {
        phrases.map { phrase in
            switch phrase {
            case let .plain(text), let .code(text): text
            case let .bold(inner), let .italic(inner), let .status(_, inner), let .link(inner, _): plainText(of: inner)
            }
        }.joined()
    }

    // MARK: - Blocks

    private static let fence = "```"
    private static let bullet = "- "

    static func blocks(of text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var items: [[Phrase]] = []

        func endParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(phrases(in: paragraph.joined(separator: "\n"))))
            paragraph = []
        }
        func endList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items))
            items = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence), let close = closingFence(in: lines, after: index) {
                endParagraph()
                endList()
                blocks.append(.codeBlock(lines[(index + 1)..<close].map(codeLine)))
                index = close + 1
                continue
            }
            if trimmed.isEmpty {
                endParagraph()
                endList()
            } else if trimmed.hasPrefix(bullet) {
                endParagraph()
                items.append(phrases(in: String(trimmed.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)))
            } else {
                endList()
                paragraph.append(trimmed)
            }
            index += 1
        }
        endParagraph()
        endList()
        return blocks
    }

    private static func closingFence(in lines: [String], after open: Int) -> Int? {
        ((open + 1)..<lines.count).first { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(fence) }
    }

    private static func codeLine(_ line: String) -> CodeLine {
        switch line.first {
        case "+": CodeLine(text: line, change: .added)
        case "-": CodeLine(text: line, change: .removed)
        default: CodeLine(text: line, change: .unchanged)
        }
    }

    // MARK: - Phrases

    private static let statusTags: [String: DesignTokens.Status] = ["problem": .problem, "done": .done, "you": .you]
    private static let statusEnd = "{/}"

    /// `text` as phrases. Each marker is read where it opens: a partner found after it makes the phrase, none leaves
    /// the marker as written.
    static func phrases(in text: String) -> [Phrase] {
        var parsed: [Phrase] = []
        var plain = ""
        var rest = Substring(text)

        func flush() {
            guard !plain.isEmpty else { return }
            parsed.append(.plain(plain))
            plain = ""
        }
        /// Takes `phrase` and moves past `consumed` characters of the text.
        func take(_ phrase: Phrase, _ consumed: Int) {
            flush()
            parsed.append(phrase)
            rest = rest.dropFirst(consumed)
        }
        func literal(_ count: Int) {
            plain += rest.prefix(count)
            rest = rest.dropFirst(count)
        }

        while let first = rest.first {
            switch first {
            case "`":
                if let end = rest.dropFirst().firstIndex(of: "`") {
                    let code = String(rest[rest.index(after: rest.startIndex)..<end])
                    if code.isEmpty { literal(1) } else { take(.code(code), code.count + 2) }
                } else {
                    literal(1)
                }
            case "*":
                if rest.hasPrefix("**") {
                    if let (inner, consumed) = delimited(rest, marker: "**") {
                        take(.bold(phrases(in: inner)), consumed)
                    } else {
                        literal(2)
                    }
                } else if let (inner, consumed) = delimited(rest, marker: "*") {
                    take(.italic(phrases(in: inner)), consumed)
                } else {
                    literal(1)
                }
            case "[":
                if let (label, destination, consumed) = link(rest) {
                    take(.link(label: phrases(in: label), destination: destination), consumed)
                } else {
                    literal(1)
                }
            case "{":
                if let (status, inner, consumed) = statusPhrase(rest) {
                    take(.status(status, phrases(in: inner)), consumed)
                } else {
                    literal(1)
                }
            default:
                literal(1)
            }
        }
        flush()
        return parsed
    }

    /// The text between `marker` at the start of `text` and the next `marker`, and how many characters the two
    /// markers and the text take; nil when there is no closing marker, the text between is empty, or it starts or
    /// ends with a space (`2 * 3 * 4` is arithmetic, not italic).
    private static func delimited(_ text: Substring, marker: String) -> (String, Int)? {
        let body = text.dropFirst(marker.count)
        guard let close = body.range(of: marker) else { return nil }
        let inner = String(body[body.startIndex..<close.lowerBound])
        guard let first = inner.first, let last = inner.last, !first.isWhitespace, !last.isWhitespace else { return nil }
        // A single `*` does not close on the first star of a `**`.
        if marker == "*", body[close.upperBound...].hasPrefix("*"), !body[body.startIndex..<close.lowerBound].isEmpty { return nil }
        return (inner, inner.count + 2 * marker.count)
    }

    /// `[label](address)` at the start of `text`: the label, a web address and the characters it takes.
    private static func link(_ text: Substring) -> (String, URL, Int)? {
        guard let labelEnd = text.range(of: "](") else { return nil }
        let label = String(text[text.index(after: text.startIndex)..<labelEnd.lowerBound])
        guard !label.isEmpty, !label.contains("["), !label.contains("\n") else { return nil }
        let afterOpen = text[labelEnd.upperBound...]
        guard let close = afterOpen.firstIndex(of: ")") else { return nil }
        let address = String(afterOpen[afterOpen.startIndex..<close])
        guard !address.isEmpty, !address.contains(where: \.isWhitespace), let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return nil }
        return (label, url, text.distance(from: text.startIndex, to: afterOpen.index(after: close)))
    }

    /// `{problem}…{/}` at the start of `text`: the status, the words between and the characters it takes.
    private static func statusPhrase(_ text: Substring) -> (DesignTokens.Status, String, Int)? {
        guard let tagEnd = text.firstIndex(of: "}") else { return nil }
        let name = String(text[text.index(after: text.startIndex)..<tagEnd])
        guard let status = statusTags[name] else { return nil }
        let body = text[text.index(after: tagEnd)...]
        guard let close = body.range(of: statusEnd) else { return nil }
        let inner = String(body[body.startIndex..<close.lowerBound])
        guard !inner.isEmpty else { return nil }
        return (status, inner, name.count + 2 + inner.count + statusEnd.count)
    }
}

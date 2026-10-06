import Foundation

/// Why `agent.concurrency.max_total` can't be changed by editing one line.
public enum MaxConcurrentAgentsError: LocalizedError, Equatable {
    /// The key holds an inline value (for example `concurrency: {max_total: 2}`) instead of an indented block.
    case notABlock(String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change max_total by hand."
        }
    }
}

/// Reads and changes `agent.concurrency.max_total` in the text of a `symphony.yml`. Only that one line is
/// rewritten, or inserted when missing, so comments, ordering and indentation stay as they are.
public enum MaxConcurrentAgents {
    /// Values offered in Settings.
    public static let range = 1...10

    /// What Symphony uses when the key is missing.
    public static let symphonyDefault = 10

    /// The `max_total` value, or nil when the key is missing or not a whole number.
    public static func value(in yaml: String) -> Int? {
        (try? AgentSetting.value("max_total", in: "concurrency", of: yaml)).flatMap { Int($0) }
    }

    /// The same text with `max_total` set to `value`. Inserts the key, and `concurrency:` or `agent:` when
    /// they are missing too.
    public static func setting(_ value: Int, in yaml: String) throws -> String {
        try AgentSetting.setting("max_total", in: "concurrency", to: String(value), in: yaml)
    }
}

/// One `agent.<section>.<key>` value in the text of a `symphony.yml`. Only that one line is rewritten, or
/// inserted when missing, so comments, ordering and indentation stay as they are.
enum AgentSetting {
    /// Indent added for a new nested key when the file gives no example to follow.
    static let defaultIndentStep = 2

    /// The value after `key:` without its comment, "" when empty, or nil when the key or a section above it
    /// is missing. Throws `MaxConcurrentAgentsError.notABlock` when a section above it holds an inline value.
    static func value(_ key: String, in section: String, of yaml: String) throws -> String? {
        let document = Document(yaml)
        guard let agent = document.child("agent", in: document.all) else { return nil }
        let agentBlock = try document.block(of: agent)
        guard let sectionKey = document.child(section, in: agentBlock) else { return nil }
        let sectionBlock = try document.block(of: sectionKey)
        return document.child(key, in: sectionBlock).map { ValueLine($0.rest).value }
    }

    /// The same text with `key` set to `value`. Inserts the key, and the section or `agent:` when they are
    /// missing too.
    static func setting(_ key: String, in section: String, to value: String, in yaml: String) throws -> String {
        var document = Document(yaml)

        guard let agent = document.child("agent", in: document.all) else {
            let step = defaultIndentStep
            document.append([
                "agent:",
                String(repeating: " ", count: step) + "\(section):",
                String(repeating: " ", count: step * 2) + "\(key): \(value)",
            ])
            return document.text
        }
        let agentBlock = try document.block(of: agent)
        let agentChildIndent = document.childIndent(in: agentBlock) ?? agent.indent + defaultIndentStep

        guard let sectionKey = document.child(section, in: agentBlock) else {
            let step = agentChildIndent - agent.indent
            document.insert(
                [
                    String(repeating: " ", count: agentChildIndent) + "\(section):",
                    String(repeating: " ", count: agentChildIndent + step) + "\(key): \(value)",
                ],
                after: agent.index
            )
            return document.text
        }
        let sectionBlock = try document.block(of: sectionKey)

        guard let line = document.child(key, in: sectionBlock) else {
            let indent = document.childIndent(in: sectionBlock)
                ?? sectionKey.indent + (agentChildIndent - agent.indent)
            document.insert([String(repeating: " ", count: indent) + "\(key): \(value)"], after: sectionKey.index)
            return document.text
        }

        let prefix = String(repeating: " ", count: line.indent) + "\(key):"
        document.lines[line.index] = prefix + ValueLine(line.rest).replacingValue(with: value)
        return document.text
    }
}

/// Reads and edits a `symphony.yml` on disk.
public struct SymphonyConfigFile {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func readMaxConcurrentAgents() throws -> Int? {
        MaxConcurrentAgents.value(in: try read())
    }

    /// Sets `max_total`. Leaves the file untouched when it already has that value.
    public func writeMaxConcurrentAgents(_ value: Int) throws {
        try rewrite { try MaxConcurrentAgents.setting(value, in: $0) }
    }

    func read() throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Replaces the file's text with `transform` of it. Leaves the file untouched when the text doesn't
    /// change or `transform` throws. A symlinked file is written through the link, and the file keeps its
    /// permissions.
    func rewrite(_ transform: (String) throws -> String) throws {
        let url = url
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = try transform(text)
        guard updated != text else { return }
        try replace(url, with: writeSibling(of: url, updated))
    }

    /// Like `rewrite`, but runs `check` (such as `symphony check`) on a sibling copy of the new text first,
    /// and replaces the file only when it passes. Returns the check's result, or `.passed` when the text
    /// doesn't change. The copy sits next to the file, so relative paths in it resolve the same way; a failure
    /// names the file, not the copy.
    public func rewrite(
        _ transform: (String) throws -> String,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        let url = url
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = try transform(text)
        guard updated != text else { return .passed }
        let candidate = try writeSibling(of: url, updated)
        let result = await check(candidate.path).naming(url, for: candidate)
        guard result == .passed else {
            try? FileManager.default.removeItem(at: candidate)
            return result
        }
        try replace(url, with: candidate)
        return .passed
    }

    /// Runs `check` on a sibling copy of `transform` of the file's text, then removes the copy and leaves the
    /// file as it is. Returns `.passed` when the text doesn't change; a failure names the file, not the copy.
    public func checking(
        _ transform: (String) throws -> String,
        with check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        let url = url
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = try transform(text)
        guard updated != text else { return .passed }
        let candidate = try writeSibling(of: url, updated)
        defer { try? FileManager.default.removeItem(at: candidate) }
        return await check(candidate.path).naming(url, for: candidate)
    }

    /// Writes `text` to a new hidden file next to `url`.
    private func writeSibling(of url: URL, _ text: String) throws -> URL {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try Data(text.utf8).write(to: temporary)
        return temporary
    }

    /// Renames `temporary` over `url`, so Symphony's config watcher never reads a half-written file. The file
    /// keeps its permissions; `temporary` is removed when this fails.
    private func replace(_ url: URL, with temporary: URL) throws {
        let files = FileManager.default
        do {
            if let permissions = try files.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? files.removeItem(at: temporary)
            throw error
        }
    }

    private var url: URL {
        URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
}

/// Block-style YAML lines, enough to find one nested key by indentation. Shared with `RunProfilesConfig`.
struct Document {
    /// A `key:` line.
    struct Key {
        let name: String
        let index: Int
        let indent: Int
        /// Text after the colon.
        let rest: String
    }

    var lines: [String]
    let newline: String

    init(_ text: String) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        lines = text.components(separatedBy: newline)
    }

    var text: String { lines.joined(separator: newline) }

    var all: Range<Int> { 0..<lines.count }

    /// Indent of a line holding YAML structure, or nil for blank and comment-only lines.
    func indent(at index: Int) -> Int? {
        let line = lines[index]
        let indent = line.prefix { $0 == " " }.count
        let content = line.dropFirst(indent)
        if content.allSatisfy(\.isWhitespace) || content.hasPrefix("#") { return nil }
        return indent
    }

    /// Indent of the first structural line in the range: the indent of the block's direct children.
    func childIndent(in range: Range<Int>) -> Int? {
        range.lazy.compactMap { indent(at: $0) }.first
    }

    /// The direct child `key:` line in the range.
    func child(_ key: String, in range: Range<Int>) -> Key? {
        guard let childIndent = childIndent(in: range) else { return nil }
        return child(key, in: range, indent: childIndent)
    }

    /// The `key:` line at `childIndent` in the range.
    func child(_ key: String, in range: Range<Int>, indent childIndent: Int) -> Key? {
        let marker = key + ":"
        for index in range where indent(at: index) == childIndent {
            let content = lines[index].dropFirst(childIndent)
            guard content.hasPrefix(marker) else { continue }
            let rest = content.dropFirst(marker.count)
            if let next = rest.first, !next.isWhitespace { continue }
            return Key(name: key, index: index, indent: childIndent, rest: String(rest))
        }
        return nil
    }

    /// Lines nested under the key: up to the next structural line at the key's indent or less.
    func block(of key: Key) throws -> Range<Int> {
        guard ValueLine(key.rest).value.isEmpty else {
            throw MaxConcurrentAgentsError.notABlock(key.name)
        }
        return children(of: key)
    }

    /// Lines after the key up to the next structural line at the key's indent or less, whatever its value.
    func children(of key: Key) -> Range<Int> {
        let start = key.index + 1
        let end = (start..<lines.count).first { index in
            indent(at: index).map { $0 <= key.indent } ?? false
        } ?? lines.count
        return start..<end
    }

    /// The last structural line in the range.
    func lastStructural(in range: Range<Int>) -> Int? {
        range.reversed().first { indent(at: $0) != nil }
    }

    /// `last` moved past the comment lines right after it that are indented deeper than `column`, which
    /// belong to the same block.
    func blockEnd(_ last: Int, deeperThan column: Int) -> Int {
        var end = last
        while end + 1 < lines.count {
            let line = lines[end + 1]
            let indent = line.prefix { $0 == " " }.count
            guard indent > column, line.dropFirst(indent).hasPrefix("#") else { break }
            end += 1
        }
        return end
    }

    mutating func insert(_ newLines: [String], after index: Int) {
        lines.insert(contentsOf: newLines, at: index + 1)
    }

    /// Adds lines at the end, before the final newline when there is one.
    mutating func append(_ newLines: [String]) {
        if lines.last == "" {
            lines.insert(contentsOf: newLines, at: lines.count - 1)
        } else {
            lines.append(contentsOf: newLines)
        }
    }
}

/// The text after `key:`, split into spacing, value and an optional `# comment`.
struct ValueLine {
    let leadingSpace: Substring
    let value: String
    /// Spacing between the value and the comment, then the comment itself.
    let tail: String

    init(_ rest: String) {
        let rest = Substring(rest)
        leadingSpace = rest.prefix { $0 == " " || $0 == "\t" }
        let afterSpace = rest.dropFirst(leadingSpace.count)

        // A comment starts at a `#` that begins the value or follows whitespace.
        var commentStart = afterSpace.endIndex
        var previous: Character = " "
        for index in afterSpace.indices {
            if afterSpace[index] == "#" && previous.isWhitespace {
                commentStart = index
                break
            }
            previous = afterSpace[index]
        }
        let valuePart = afterSpace[..<commentStart]
        value = String(valuePart).trimmingWhitespace()
        tail = String(valuePart.dropFirst(value.count) + afterSpace[commentStart...])
    }

    func replacingValue(with newValue: String) -> String {
        if value.isEmpty {
            return " " + newValue + (tail.isEmpty ? "" : " " + tail.trimmingWhitespace())
        }
        return String(leadingSpace) + newValue + tail
    }
}

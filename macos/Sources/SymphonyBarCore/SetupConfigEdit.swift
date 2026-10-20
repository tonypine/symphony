import Foundation

/// Why a `config_edit` fix can't be made by the app.
public enum SetupConfigEditError: LocalizedError, Equatable {
    /// The key, or the list item, the fix names isn't in symphony.yml (any more).
    case notFound(String)
    /// The app can't make this edit safely; the operator makes it by hand.
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(what):
            "symphony.yml has no \(what) any more. Check Again to see whether the problem is gone."
        case let .unsupported(reason):
            "The app can't make this change itself: \(reason). Change it in symphony.yml by hand."
        }
    }
}

/// SU7: the edit a `config_edit` fix makes to the text of a `symphony.yml`, line by line, so comments, ordering and
/// every other line stay as they are. A `repositories[<key>].…` path goes through `RepositoriesConfig`, the editor
/// the Repos window writes with; any other path is a dotted key path (`auto_review.enabled`).
public enum SetupConfigEdit {
    /// The text with the edit made. `remove` without a value removes the key and its block (and the sections above
    /// it it leaves empty); with a value, it removes that item from the list. `set` sets the value; `add` adds an
    /// item to the list, making the list when it is missing.
    public static func apply(path: String, action: SetupPayload.ConfigAction, value: SetupValue, to yaml: String) throws -> String {
        if let (key, field) = repositoryPath(path) {
            return try applyToRepository(key, field: field, path: path, action: action, value: value, yaml: yaml)
        }
        let keys = path.split(separator: ".").map(String.init)
        guard !keys.isEmpty, !keys.contains(where: { $0.isEmpty || $0.contains("[") }) else {
            throw SetupConfigEditError.unsupported("\(path) isn't a key path it knows")
        }
        switch (action, value) {
        case (.remove, .null):
            return try removingKey(keys, path: path, in: yaml)
        case let (.remove, item):
            guard let text = item.scalarText else { throw SetupConfigEditError.unsupported("it can only remove one item at a time") }
            return try removingItem(text, from: keys, path: path, in: yaml)
        case let (.set, item):
            return try setting(keys, to: item, path: path, in: yaml)
        case let (.add, item):
            guard let text = item.scalarText else { throw SetupConfigEditError.unsupported("it can only add one item at a time") }
            return try adding(text, to: keys, path: path, in: yaml)
        }
    }

    /// `repositories[web-shop].route.team` → (`web-shop`, `route.team`).
    static func repositoryPath(_ path: String) -> (key: String, field: String)? {
        let prefix = "repositories["
        guard path.hasPrefix(prefix), let close = path.range(of: "].") else { return nil }
        let key = String(path[path.index(path.startIndex, offsetBy: prefix.count)..<close.lowerBound])
        return (key, String(path[close.upperBound...]))
    }

    // MARK: Repositories

    private static let stringFields: [String: WritableKeyPath<RepositoryEntry, String?>] = [
        "route.team": \.route.team,
        "route.assignee": \.route.assignee,
        "base_branch": \.baseBranch,
        "workflow": \.workflow,
        "manual_review": \.manualReview,
    ]

    private static let listFields: [String: WritableKeyPath<RepositoryEntry, [String]?>] = [
        "route.projects": \.route.projects,
        "route.labels": \.route.labels,
    ]

    private static func applyToRepository(
        _ key: String, field: String, path: String, action: SetupPayload.ConfigAction, value: SetupValue, yaml: String
    ) throws -> String {
        guard var entry = try RepositoriesConfig.entries(in: yaml).first(where: { $0.key == key }) else {
            throw SetupConfigEditError.notFound("repository \(key)")
        }
        if let keyPath = stringFields[field] {
            switch (action, value) {
            case (.remove, _):
                guard entry[keyPath: keyPath] != nil else { throw SetupConfigEditError.notFound(path) }
                entry[keyPath: keyPath] = nil
            case let (.set, item):
                guard let text = item.scalarText else { throw SetupConfigEditError.unsupported("\(path) holds one value, not a list") }
                entry[keyPath: keyPath] = text
            case (.add, _):
                throw SetupConfigEditError.unsupported("\(path) holds one value, not a list")
            }
        } else if let keyPath = listFields[field] {
            var items = entry[keyPath: keyPath]
            switch (action, value) {
            case (.remove, .null):
                guard items != nil else { throw SetupConfigEditError.notFound(path) }
                items = nil
            case let (.remove, item):
                guard let text = item.scalarText, let found = items, found.contains(text) else {
                    throw SetupConfigEditError.notFound("\(item.display) in \(path)")
                }
                items = found.filter { $0 != text }
            case let (.set, item):
                guard let list = item.listText ?? item.scalarText.map({ [$0] }) else {
                    throw SetupConfigEditError.unsupported("\(path) takes a list of values")
                }
                items = list
            case let (.add, item):
                guard let text = item.scalarText else { throw SetupConfigEditError.unsupported("it can only add one item at a time") }
                if items?.contains(text) != true { items = (items ?? []) + [text] }
            }
            entry[keyPath: keyPath] = items
        } else {
            throw SetupConfigEditError.unsupported("the Repos editor doesn't know \(field)")
        }
        return try RepositoriesConfig.updating(key, to: entry, in: yaml)
    }

    // MARK: Key paths

    /// The `key:` line of each name of `keys` down to the last, nil when one is missing.
    private static func chain(_ keys: [String], in document: Document) throws -> [Document.Key]? {
        var range = document.all
        var found: [Document.Key] = []
        for (depth, name) in keys.enumerated() {
            guard let key = document.child(name, in: range) else { return nil }
            found.append(key)
            if depth < keys.count - 1 { range = try block(of: key, in: document) }
        }
        return found
    }

    private static func block(of key: Document.Key, in document: Document) throws -> Range<Int> {
        do {
            return try document.block(of: key)
        } catch {
            throw SetupConfigEditError.unsupported("`\(key.name):` holds an inline value, not an indented block")
        }
    }

    /// The last line of `key` and the block under it, with the comments indented under it.
    private static func end(of key: Document.Key, in document: Document) -> Int {
        let last = document.lastStructural(in: document.children(of: key)) ?? key.index
        return document.blockEnd(last, deeperThan: key.indent)
    }

    private static func removingKey(_ keys: [String], path: String, in yaml: String) throws -> String {
        var document = Document(yaml)
        guard let chain = try chain(keys, in: document) else { throw SetupConfigEditError.notFound(path) }
        var level = chain.count - 1
        var removed = chain[level].index...end(of: chain[level], in: document)
        // A section the removal leaves with no key goes too: `auto_review:` with nothing under it reads as null.
        while level > 0 {
            let parent = chain[level - 1]
            let others = document.children(of: parent).filter { !removed.contains($0) && document.indent(at: $0) != nil }
            guard others.isEmpty else { break }
            level -= 1
            removed = parent.index...end(of: parent, in: document)
        }
        document.lines.removeSubrange(removed)
        return document.text
    }

    private static func removingItem(_ item: String, from keys: [String], path: String, in yaml: String) throws -> String {
        var document = Document(yaml)
        guard let key = try chain(keys, in: document)?.last else { throw SetupConfigEditError.notFound(path) }
        let line = ValueLine(key.rest)
        let prefix = String(repeating: " ", count: key.indent) + "\(key.name):"

        if line.value.hasPrefix("[") {
            let items = try flowItems(line.value, path: path)
            guard items.contains(where: { unquote($0) == item }) else { throw SetupConfigEditError.notFound("\(item) in \(path)") }
            let kept = items.filter { unquote($0) != item }
            document.lines[key.index] = prefix + line.replacingValue(with: "[" + kept.joined(separator: ", ") + "]")
            return document.text
        }
        if !line.value.isEmpty {
            guard unquote(line.value) == item else { throw SetupConfigEditError.notFound("\(item) in \(path)") }
            document.lines[key.index] = prefix + line.replacingValue(with: "[]")
            return document.text
        }
        let children = blockItems(of: key, in: document)
        guard let index = children.first(where: { unquote($0.text) == item })?.index else {
            throw SetupConfigEditError.notFound("\(item) in \(path)")
        }
        document.lines.removeSubrange(index...document.blockEnd(index, deeperThan: document.indent(at: index) ?? key.indent))
        if children.count == 1 {
            document.lines[key.index] = prefix + line.replacingValue(with: "[]")
        }
        return document.text
    }

    private static func setting(_ keys: [String], to value: SetupValue, path: String, in yaml: String) throws -> String {
        let rendered: String
        if let list = value.listText {
            rendered = "[" + list.map(RepositoriesConfig.scalar).joined(separator: ", ") + "]"
        } else if case let .string(string) = value {
            rendered = RepositoriesConfig.scalar(string)
        } else if let text = value.scalarText {
            rendered = text
        } else {
            throw SetupConfigEditError.unsupported("it has no value to set \(path) to")
        }

        var document = Document(yaml)
        guard let key = try chain(keys, in: document)?.last else {
            return try ConfigSetting.setting(at: keys, to: rendered, in: yaml)
        }
        // A block under the key (a block list) is replaced by the value.
        let children = document.children(of: key)
        if let last = document.lastStructural(in: children) {
            document.lines.removeSubrange(children.lowerBound...document.blockEnd(last, deeperThan: key.indent))
        }
        let prefix = String(repeating: " ", count: key.indent) + "\(key.name):"
        document.lines[key.index] = prefix + ValueLine(key.rest).replacingValue(with: rendered)
        return document.text
    }

    private static func adding(_ item: String, to keys: [String], path: String, in yaml: String) throws -> String {
        let rendered = RepositoriesConfig.scalar(item)
        var document = Document(yaml)
        guard let key = try chain(keys, in: document)?.last else {
            return try ConfigSetting.setting(at: keys, to: "[\(rendered)]", in: yaml)
        }
        let line = ValueLine(key.rest)
        let prefix = String(repeating: " ", count: key.indent) + "\(key.name):"

        if line.value.hasPrefix("[") {
            let items = try flowItems(line.value, path: path)
            guard !items.contains(where: { unquote($0) == item }) else { return yaml }
            document.lines[key.index] = prefix + line.replacingValue(with: "[" + (items + [rendered]).joined(separator: ", ") + "]")
            return document.text
        }
        if !line.value.isEmpty {
            guard unquote(line.value) != item else { return yaml }
            document.lines[key.index] = prefix + line.replacingValue(with: "[\(line.value), \(rendered)]")
            return document.text
        }
        let children = blockItems(of: key, in: document)
        guard let last = children.last else {
            document.lines[key.index] = prefix + line.replacingValue(with: "[\(rendered)]")
            return document.text
        }
        guard !children.contains(where: { unquote($0.text) == item }) else { return yaml }
        let indent = document.indent(at: last.index) ?? key.indent
        document.insert([String(repeating: " ", count: indent) + "- " + rendered], after: document.blockEnd(last.index, deeperThan: indent))
        return document.text
    }

    /// The `- item` lines right under `key`, with each item's text (no comment).
    private static func blockItems(of key: Document.Key, in document: Document) -> [(index: Int, text: String)] {
        document.children(of: key).compactMap { index in
            guard let indent = document.indent(at: index) else { return nil }
            let content = document.lines[index].dropFirst(indent)
            guard content == "-" || content.hasPrefix("- ") else { return nil }
            return (index, ValueLine(String(content.dropFirst())).value)
        }
    }

    /// The items of a one-line flow list, `[a, "b c"]`, as written.
    private static func flowItems(_ value: String, path: String) throws -> [String] {
        guard value.hasSuffix("]") else { throw SetupConfigEditError.unsupported("\(path) is a list over several lines") }
        let inner = value.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var quote: Character?
        for character in inner {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                items.append(current.trimmingWhitespace())
                current = ""
            } else if "[]{}".contains(character) {
                throw SetupConfigEditError.unsupported("\(path) holds a nested list")
            } else {
                current.append(character)
            }
        }
        let last = current.trimmingWhitespace()
        if !last.isEmpty { items.append(last) }
        return items.filter { !$0.isEmpty }
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else { return text }
        let inner = String(text.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") : inner
            .replacingOccurrences(of: "''", with: "'")
    }
}

// MARK: - Diff

/// SU7's exact diff of `symphony.yml`: the lines an edit removes and adds, with a little context around each change.
public struct SetupDiff: Equatable {
    public struct Line: Equatable, Identifiable {
        public enum Kind: Equatable {
            case context, removed, added
            /// Unchanged lines left out between two changes.
            case gap
        }

        public var kind: Kind
        /// The line's number in the file before the edit (after it, for an added line); nil for a gap.
        public var number: Int?
        public var text: String
        public var id: String { "\(kind)-\(number ?? -1)-\(text)" }

        /// The line as a unified diff prints it.
        public var marked: String {
            switch kind {
            case .context: "  " + text
            case .removed: "- " + text
            case .added: "+ " + text
            case .gap: "…"
            }
        }
    }

    public var lines: [Line]

    public var removed: [String] { lines.filter { $0.kind == .removed }.map(\.text) }
    public var added: [String] { lines.filter { $0.kind == .added }.map(\.text) }
    public var isEmpty: Bool { removed.isEmpty && added.isEmpty }

    /// The diff from `old` to `new`, with `context` unchanged lines around each change.
    public init(old: String, new: String, context: Int = 2) {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        let script = Self.script(before, after)
        let changed = script.indices.filter { script[$0].kind != .context }
        var shown = Set<Int>()
        for index in changed {
            for near in max(0, index - context)...min(script.count - 1, index + context) { shown.insert(near) }
        }
        var lines: [Line] = []
        var previous: Int?
        for index in shown.sorted() {
            if let previous, index > previous + 1 { lines.append(Line(kind: .gap, number: nil, text: "")) }
            lines.append(script[index])
            previous = index
        }
        self.lines = lines
    }

    /// Every line of both texts in order, marked kept, removed or added, from their longest common subsequence.
    private static func script(_ old: [String], _ new: [String]) -> [Line] {
        let n = old.count, m = new.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var lines: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                lines.append(Line(kind: .context, number: i + 1, text: old[i]))
                i += 1
                j += 1
            } else if j < m, i == n || table[i][j + 1] > table[i + 1][j] {
                lines.append(Line(kind: .added, number: j + 1, text: new[j]))
                j += 1
            } else {
                lines.append(Line(kind: .removed, number: i + 1, text: old[i]))
                i += 1
            }
        }
        return lines
    }
}

// MARK: - Backup and Undo

/// SU7, SU10: the copy of `symphony.yml` a settings fix makes before it writes, `symphony.yml.<timestamp>.bak` next to
/// the file. The last `keep` stay; Undo writes one back byte for byte.
public struct SetupBackup: Equatable {
    public static let keep = 10

    /// The `.bak` file.
    public let url: URL
    /// The file it is a copy of (a symlinked `symphony.yml` resolved).
    public let original: URL

    /// `symphony.yml.20261019-233512.bak`.
    public static func name(for fileName: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(fileName).\(formatter.string(from: date)).bak"
    }

    /// Copies `file` byte for byte next to it, then removes the oldest copies past `keep`. A name already taken this
    /// second gets `-2`, `-3`… before `.bak`.
    public static func make(of file: SymphonyConfigFile, at date: Date, timeZone: TimeZone = .current) throws -> SetupBackup {
        let original = file.url
        let directory = original.deletingLastPathComponent()
        let data = try Data(contentsOf: original)
        let base = name(for: original.lastPathComponent, at: date, timeZone: timeZone)
        var url = directory.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(String(base.dropLast(4)) + "-\(suffix).bak")
            suffix += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        prune(original)
        return SetupBackup(url: url, original: original)
    }

    /// The backups of `original`, oldest first.
    public static func backups(of original: URL) -> [URL] {
        let directory = original.deletingLastPathComponent()
        let prefix = original.lastPathComponent + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { name in
            guard name.hasPrefix(prefix), name.hasSuffix(".bak") else { return false }
            let stamp = name.dropFirst(prefix.count).dropLast(4)
            return stamp.count >= 15 && stamp.prefix(15).enumerated().allSatisfy { offset, character in
                offset == 8 ? character == "-" : character.isASCII && character.isNumber
            }
        }
        .sorted()
        .map { directory.appendingPathComponent($0) }
    }

    /// Removes the oldest backups of `original` past `keep`.
    static func prune(_ original: URL, keep: Int = SetupBackup.keep) {
        let all = backups(of: original)
        for url in all.dropLast(keep) { try? FileManager.default.removeItem(at: url) }
    }

    /// Undo: writes the copy back over the file byte for byte, atomically, keeping the file's permissions.
    public func restore() throws {
        let file = SymphonyConfigFile(path: original.path)
        try file.replace(original, with: file.writeSibling(of: original, data: Data(contentsOf: url)))
    }

    /// Removes the copy: the fix it was made for didn't write.
    public func discard() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// How a settings fix went.
public enum SetupConfigFixResult: Equatable {
    /// Written; the backup is what Undo restores.
    case applied(SetupBackup)
    /// The edit changes nothing (the key is gone already): nothing was written and no backup kept.
    case unchanged
    /// `symphony check` refused the edited file: nothing was written and no backup kept.
    case rejected(String)
}

extension SymphonyConfigFile {
    /// SU7: makes a `config_edit` fix. Copies the file to its `.bak` first, then writes `edit` of its text through
    /// the settings writer once `check` (`symphony check`) passes on it. Nothing is half applied: when the check
    /// refuses it or the write fails, the file stays as it was and the backup goes.
    public func applySetupFix(
        _ edit: (String) throws -> String,
        at date: Date,
        timeZone: TimeZone = .current,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> SetupConfigFixResult {
        let text = try read()
        guard try edit(text) != text else { return .unchanged }
        let backup = try SetupBackup.make(of: self, at: date, timeZone: timeZone)
        do {
            let result = try await rewrite(edit, checkingWith: check)
            guard case let .failed(message) = result else { return .applied(backup) }
            backup.discard()
            return .rejected(message)
        } catch {
            backup.discard()
            throw error
        }
    }
}

extension SymphonyConfigFile {
    /// The file Settings names, with `~` expanded; nil while none is set.
    public init?(settingsPath: String) {
        let path = settingsPath.trimmingWhitespace()
        guard !path.isEmpty else { return nil }
        self.init(path: (path as NSString).expandingTildeInPath)
    }

    /// The file's name, `symphony.yml` as Settings names it.
    public var fileName: String { (path as NSString).lastPathComponent }

    /// The file's text, nil when it can't be read.
    public func text() -> String? { try? read() }
}

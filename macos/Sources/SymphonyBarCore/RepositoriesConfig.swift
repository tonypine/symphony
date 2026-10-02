import Foundation

/// Why the `repositories:` section of a `symphony.yml` can't be read or changed.
public enum RepositoriesConfigError: LocalizedError, Equatable {
    /// The section uses YAML the line editor doesn't handle. `line` counts from 1.
    case unsupported(line: Int, reason: String)
    /// Another repository already uses the key.
    case duplicateKey(String)
    /// No repository has the key.
    case notFound(String)
    /// The entry can't be written as it is.
    case invalidEntry(String)
    /// Symphony needs at least one repository.
    case lastRepository(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let line, let reason):
            return "symphony.yml line \(line): \(reason). Edit repositories by hand."
        case .duplicateKey(let key):
            return "A repository with key `\(key)` already exists."
        case .notFound(let key):
            return "symphony.yml has no repository with key `\(key)`."
        case .invalidEntry(let reason):
            return reason
        case .lastRepository(let key):
            return "`\(key)` is the only repository, and Symphony needs at least one."
        }
    }
}

/// Which Linear issues go to a repository. A nil field is missing from the file.
public struct RepositoryRoute: Equatable {
    public var team: String?
    public var projects: [String]?
    public var labels: [String]?
    public var assignee: String?

    public init(team: String? = nil, projects: [String]? = nil, labels: [String]? = nil, assignee: String? = nil) {
        self.team = team
        self.projects = projects
        self.labels = labels
        self.assignee = assignee
    }
}

/// How issue workspaces for a repository are made. A nil field is missing from the file.
public struct RepositoryWorkspace: Equatable {
    /// `worktree` or `clone`.
    public var strategy: String?
    /// A local checkout to make workspaces from.
    public var repo: String?
    /// A git URL Symphony clones and manages itself, used instead of `repo`.
    public var source: String?
    public var fetchBeforeDispatch: Bool?

    public init(strategy: String? = nil, repo: String? = nil, source: String? = nil, fetchBeforeDispatch: Bool? = nil) {
        self.strategy = strategy
        self.repo = repo
        self.source = source
        self.fetchBeforeDispatch = fetchBeforeDispatch
    }
}

/// One entry of `repositories:`. A nil field is missing from the file; keys the model doesn't know are left
/// in the file as they are.
public struct RepositoryEntry: Equatable {
    public var key: String
    public var isDefault: Bool?
    public var baseBranch: String?
    public var workflow: String?
    public var route: RepositoryRoute
    public var workspace: RepositoryWorkspace

    public init(
        key: String,
        isDefault: Bool? = nil,
        baseBranch: String? = nil,
        workflow: String? = nil,
        route: RepositoryRoute = RepositoryRoute(),
        workspace: RepositoryWorkspace = RepositoryWorkspace()
    ) {
        self.key = key
        self.isDefault = isDefault
        self.baseBranch = baseBranch
        self.workflow = workflow
        self.route = route
        self.workspace = workspace
    }
}

/// Reads and edits the `repositories:` list in the text of a `symphony.yml`. Only the lines of the targeted
/// entry change, so comments, blank lines, key order and the other entries stay byte for byte. YAML the
/// line editor can't change safely (flow style, anchors, aliases, tags, block scalars, duplicate keys) is
/// refused with an error instead.
public enum RepositoriesConfig {
    /// The entries in file order. Empty when the file has no `repositories:` section.
    public static func entries(in yaml: String) throws -> [RepositoryEntry] {
        try Section(ConfigLines(yaml)).items.map(\.entry)
    }

    /// The same text with `entry` added after the last repository, laid out like the existing ones.
    /// Adds the `repositories:` section at the end when the file has none.
    public static func adding(_ entry: RepositoryEntry, to yaml: String) throws -> String {
        try validate(entry)
        var text = ConfigLines(yaml)
        let section = try Section(text)
        guard section.item(entry.key) == nil else { throw RepositoriesConfigError.duplicateKey(entry.key) }
        let newLines = render(entry, layout: section.layout)

        guard let keyIndex = section.keyIndex else {
            text.append(["repositories:"] + newLines)
            return text.text
        }
        guard let last = section.items.last else {
            text.lines.insert(contentsOf: newLines, at: keyIndex + 1)
            return text.text
        }
        let separator = section.itemsAreSeparatedByBlankLines(in: text) ? [""] : []
        text.lines.insert(contentsOf: separator + newLines, at: text.end(of: last) + 1)
        return text.text
    }

    /// The same text with the entry `key` changed to `entry`, field by field: changed values are rewritten
    /// on their line (keeping a trailing comment), new fields are inserted in the usual key order, and
    /// fields set to nil are removed. Unchanged lines, comments and unknown keys stay as they are.
    public static func updating(_ key: String, to entry: RepositoryEntry, in yaml: String) throws -> String {
        try validate(entry)
        var text = ConfigLines(yaml)
        let section = try Section(text)
        guard let item = section.item(key) else { throw RepositoriesConfigError.notFound(key) }
        guard item.entry != entry else { return yaml }

        if entry.key != key {
            guard section.item(entry.key) == nil else { throw RepositoriesConfigError.duplicateKey(entry.key) }
            guard let keyNode = item.nodes.named("key") else { throw RepositoriesConfigError.notFound(key) }
            text.replaceValue(of: keyNode, with: scalar(entry.key))
        }
        let step = section.layout.step

        for field in fields where field.path.count == 1 {
            try set(field, to: field.get(entry), of: entry.key, in: &text, step: step)
        }
        for group in groups {
            let groupFields = fields.filter { $0.path.count == 2 && $0.path[0] == group }
            let item = try currentItem(entry.key, in: text)
            guard item.nodes.named(group) != nil else {
                let newLines = render(group, of: entry, column: item.column, step: step)
                if !newLines.isEmpty {
                    let index = insertionIndex(for: group, among: item.nodes, order: entryOrder, parent: item.dashIndex, in: text)
                    text.lines.insert(contentsOf: newLines, at: index)
                }
                continue
            }
            for field in groupFields {
                try set(field, to: field.get(entry), of: entry.key, in: &text, step: step)
            }
            // A block this edit emptied goes too, with any comments inside it.
            let emptied = groupFields.allSatisfy { $0.get(entry) == nil } && groupFields.contains { $0.get(item.entry) != nil }
            if emptied, let node = try currentItem(entry.key, in: text).nodes.named(group), node.children.isEmpty {
                text.lines.removeSubrange(node.line.index...text.blockEnd(node.lastIndex, deeperThan: node.line.column))
            }
        }
        return text.text
    }

    /// The same text without the entry `key`. Comments around it stay; a blank line that separated it from
    /// its neighbours goes with it.
    public static func removing(_ key: String, from yaml: String) throws -> String {
        var text = ConfigLines(yaml)
        let section = try Section(text)
        guard let item = section.item(key) else { throw RepositoriesConfigError.notFound(key) }
        guard section.items.count > 1 else { throw RepositoriesConfigError.lastRepository(key) }

        let start = item.dashIndex
        text.lines.removeSubrange(start...text.end(of: item))
        if start < text.lines.count, text.isBlank(start) {
            if text.isBlank(start - 1) {
                text.lines.remove(at: start - 1)
            } else if start - 1 == section.keyIndex, start + 1 < text.lines.count {
                text.lines.remove(at: start)
            }
        }
        return text.text
    }

    // MARK: Fields

    /// Keys of an entry in the order new ones are written.
    static let entryOrder = ["key", "default", "base_branch", "workflow", "route", "workspace"]
    static let groups = ["route", "workspace"]

    /// The fields the model knows, in the order they are written. Fields of one group stay together.
    fileprivate static let fields: [Field] = [
        .bool(["default"], \.isDefault),
        .string(["base_branch"], \.baseBranch),
        .string(["workflow"], \.workflow),
        .string(["route", "team"], \.route.team),
        .list(["route", "projects"], \.route.projects),
        .list(["route", "labels"], \.route.labels),
        .string(["route", "assignee"], \.route.assignee),
        .string(["workspace", "strategy"], \.workspace.strategy),
        .string(["workspace", "repo"], \.workspace.repo),
        .string(["workspace", "source"], \.workspace.source),
        .bool(["workspace", "fetch_before_dispatch"], \.workspace.fetchBeforeDispatch),
    ]

    private static func validate(_ entry: RepositoryEntry) throws {
        guard !entry.key.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RepositoriesConfigError.invalidEntry("A repository needs a key.")
        }
    }

    /// The entry `key`, read again from the text so its line numbers are current.
    private static func currentItem(_ key: String, in text: ConfigLines) throws -> Item {
        guard let item = try Section(text).item(key) else { throw RepositoriesConfigError.notFound(key) }
        return item
    }

    /// Sets one field of the entry `key`.
    private static func set(_ field: Field, to value: Value?, of key: String, in text: inout ConfigLines, step: Int) throws {
        let item = try currentItem(key, in: text)
        var nodes = item.nodes
        var parent = item.dashIndex
        var column = item.column
        var order = entryOrder
        if field.path.count == 2 {
            guard let group = item.nodes.named(field.path[0]) else { return }
            nodes = try group.mapping()
            parent = group.line.index
            column = nodes.first?.line.column ?? group.line.column + step
            order = fields.filter { $0.path[0] == field.path[0] }.map { $0.path[1] }
        }
        let name = field.path[field.path.count - 1]

        guard let node = nodes.named(name) else {
            if let value {
                let index = insertionIndex(for: name, among: nodes, order: order, parent: parent, in: text)
                text.lines.insert(String(repeating: " ", count: column) + name + ": " + render(value), at: index)
            }
            return
        }
        let old = try node.read(field.kind)
        guard let value else {
            if old != nil {
                text.lines.removeSubrange(node.line.index...text.blockEnd(node.lastIndex, deeperThan: node.line.column))
            }
            return
        }
        guard value != old else { return }
        if case .list(let items) = value, node.value.text.isEmpty, let first = node.children.first {
            text.replaceBlockList(node, with: items, column: first.column)
        } else {
            text.replaceValue(of: node, with: render(value))
        }
    }

    /// Where a new key goes: after the nearest key that comes before it in `order`, or else first.
    private static func insertionIndex(for name: String, among nodes: [Node], order: [String], parent: Int, in text: ConfigLines) -> Int {
        let earlier = order.prefix { $0 != name }
        let previous = nodes.filter { earlier.contains($0.name) }.max { $0.lastIndex < $1.lastIndex }
        guard let previous else { return parent + 1 }
        return text.blockEnd(previous.lastIndex, deeperThan: previous.line.column) + 1
    }

    // MARK: Rendering

    private static func render(_ entry: RepositoryEntry, layout: Layout) -> [String] {
        let dash = String(repeating: " ", count: layout.item) + "-" + String(repeating: " ", count: layout.content - layout.item - 1)
        var lines = [dash + "key: " + scalar(entry.key)]
        for field in fields where field.path.count == 1 {
            if let value = field.get(entry) {
                lines.append(String(repeating: " ", count: layout.content) + field.path[0] + ": " + render(value))
            }
        }
        for group in groups {
            lines += render(group, of: entry, column: layout.content, step: layout.step)
        }
        return lines
    }

    /// `group:` and its fields, or nothing when every field is nil.
    private static func render(_ group: String, of entry: RepositoryEntry, column: Int, step: Int) -> [String] {
        let children = fields.filter { $0.path.count == 2 && $0.path[0] == group }.compactMap { field in
            field.get(entry).map { String(repeating: " ", count: column + step) + field.path[1] + ": " + render($0) }
        }
        return children.isEmpty ? [] : [String(repeating: " ", count: column) + group + ":"] + children
    }

    fileprivate static func render(_ value: Value) -> String {
        switch value {
        case .string(let string): return scalar(string)
        case .bool(let bool): return bool ? "true" : "false"
        case .list(let items): return "[" + items.map(scalar).joined(separator: ", ") + "]"
        }
    }

    private static let reservedWords: Set = ["true", "false", "yes", "no", "on", "off", "null", "y", "n"]

    /// `string` as a YAML scalar: plain when that reads back as the same string, double-quoted otherwise.
    static func scalar(_ string: String) -> String {
        let plainCharacters = string.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_./~@+:-".contains($0)) }
        let plainStart = string.first.map { $0.isLetter || $0 == "_" || $0 == "/" } ?? false
            || string.hasPrefix("~/") || string.hasPrefix("./") || string.hasPrefix("../")
        if plainCharacters && plainStart && !string.hasSuffix(":") && !reservedWords.contains(string.lowercased()) {
            return string
        }
        var quoted = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\t": quoted += "\\t"
            case "\r": quoted += "\\r"
            case _ where scalar.value < 0x20: quoted += String(format: "\\u%04X", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}

/// Repository edits to a `symphony.yml` on disk. Each one writes atomically, and leaves the file untouched
/// when it throws.
extension SymphonyConfigFile {
    public func readRepositories() throws -> [RepositoryEntry] {
        try RepositoriesConfig.entries(in: read())
    }

    public func addRepository(_ entry: RepositoryEntry) throws {
        try rewrite { try RepositoriesConfig.adding(entry, to: $0) }
    }

    public func updateRepository(_ key: String, to entry: RepositoryEntry) throws {
        try rewrite { try RepositoriesConfig.updating(key, to: entry, in: $0) }
    }

    public func removeRepository(_ key: String) throws {
        try rewrite { try RepositoriesConfig.removing(key, from: $0) }
    }
}

// MARK: - Field table

private enum Value: Equatable {
    case string(String)
    case bool(Bool)
    case list([String])
}

private enum Kind {
    case string, bool, list
}

/// A field of `RepositoryEntry` and where it lives in the entry, such as `["route", "team"]`.
private struct Field {
    let path: [String]
    let kind: Kind
    let get: (RepositoryEntry) -> Value?
    let set: (inout RepositoryEntry, Value) -> Void

    static func string(_ path: [String], _ keyPath: WritableKeyPath<RepositoryEntry, String?>) -> Field {
        Field(path: path, kind: .string, get: { $0[keyPath: keyPath].map(Value.string) }) { entry, value in
            if case .string(let string) = value { entry[keyPath: keyPath] = string }
        }
    }

    static func bool(_ path: [String], _ keyPath: WritableKeyPath<RepositoryEntry, Bool?>) -> Field {
        Field(path: path, kind: .bool, get: { $0[keyPath: keyPath].map(Value.bool) }) { entry, value in
            if case .bool(let bool) = value { entry[keyPath: keyPath] = bool }
        }
    }

    static func list(_ path: [String], _ keyPath: WritableKeyPath<RepositoryEntry, [String]?>) -> Field {
        Field(path: path, kind: .list, get: { $0[keyPath: keyPath].map(Value.list) }) { entry, value in
            if case .list(let items) = value { entry[keyPath: keyPath] = items }
        }
    }
}

// MARK: - Lines

/// The file as lines, keeping its line ending.
private struct ConfigLines {
    var lines: [String]
    let newline: String

    init(_ text: String) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        lines = text.components(separatedBy: newline)
    }

    var text: String { lines.joined(separator: newline) }

    /// Indent of a line holding YAML structure, or nil for blank and comment-only lines.
    func indent(at index: Int) -> Int? {
        let line = lines[index]
        let indent = line.prefix { $0 == " " }.count
        let content = line.dropFirst(indent)
        if content.allSatisfy(\.isWhitespace) || content.hasPrefix("#") { return nil }
        return indent
    }

    func isBlank(_ index: Int) -> Bool {
        lines.indices.contains(index) && lines[index].allSatisfy(\.isWhitespace)
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

    /// The last line of a repository entry.
    func end(of item: Item) -> Int {
        blockEnd(item.lastIndex, deeperThan: item.dashColumn)
    }

    /// Rewrites the value after `key:` on the node's line, keeping the spacing and any trailing comment.
    mutating func replaceValue(of node: Node, with rendered: String) {
        let index = node.line.index
        let head = lines[index].prefix(node.line.column + node.name.count + 1)
        let value = node.value
        if value.text.isEmpty {
            let comment = value.tail.drop { $0 == " " || $0 == "\t" }
            lines[index] = head + " " + rendered + (comment.isEmpty ? "" : " " + comment)
        } else {
            lines[index] = head + value.leading + rendered + value.tail
        }
    }

    /// Replaces the `- item` lines of a block-style list, keeping comment lines between them.
    mutating func replaceBlockList(_ node: Node, with items: [String], column: Int) {
        let first = node.children[0].index
        for child in node.children.reversed() {
            lines.remove(at: child.index)
        }
        if items.isEmpty {
            replaceValue(of: node, with: "[]")
        } else {
            let prefix = String(repeating: " ", count: column) + "- "
            lines.insert(contentsOf: items.map { prefix + RepositoriesConfig.scalar($0) }, at: first)
        }
    }

    /// Adds lines at the end after a blank line, before the final newline when there is one.
    mutating func append(_ newLines: [String]) {
        let hasFinalNewline = lines.last == ""
        if hasFinalNewline { lines.removeLast() }
        if let last = lines.last, !last.allSatisfy(\.isWhitespace) { lines.append("") }
        lines += newLines + (hasFinalNewline ? [""] : [])
    }
}

/// A line holding YAML structure. For the first line of a list item, the content after `- `.
private struct Line {
    let index: Int
    /// Column where `content` starts.
    let column: Int
    let content: Substring

    var isDash: Bool { content == "-" || content.hasPrefix("- ") }

    func unsupported(_ reason: String) -> RepositoriesConfigError {
        .unsupported(line: index + 1, reason: reason)
    }
}

/// A `key:` line of a block mapping and the lines nested under it.
private struct Node {
    let name: String
    let line: Line
    let value: InlineValue
    let children: [Line]

    var lastIndex: Int { children.last?.index ?? line.index }

    func read(_ kind: Kind) throws -> Value? {
        switch kind {
        case .string: return try string().map(Value.string)
        case .bool: return try bool().map(Value.bool)
        case .list: return try list().map(Value.list)
        }
    }

    func mapping() throws -> [Node] {
        guard value.text.isEmpty else { throw line.unsupported("`\(name):` should be an indented block") }
        guard let first = children.first else { return [] }
        guard !first.isDash else { throw first.unsupported("`\(name):` should hold keys, not a list") }
        return try parseMapping(children, column: first.column)
    }

    func string() throws -> String? {
        if let child = children.first { throw child.unsupported("`\(name)` should be a single value") }
        guard value.text.first != "[" else { throw line.unsupported("`\(name)` should be a single value") }
        return try decodeScalar(value.text, on: line)
    }

    func bool() throws -> Bool? {
        switch try string() {
        case nil: return nil
        case "true"?, "True"?, "TRUE"?: return true
        case "false"?, "False"?, "FALSE"?: return false
        default: throw line.unsupported("`\(name)` should be true or false")
        }
    }

    func list() throws -> [String]? {
        if !value.text.isEmpty {
            guard value.text.first == "[" else {
                if try decodeScalar(value.text, on: line) == nil { return nil }
                throw line.unsupported("`\(name)` should be a list")
            }
            return try flowItems(value.text, on: line)
        }
        guard let first = children.first else { return nil }
        return try children.map { child in
            guard child.isDash, child.column == first.column else {
                throw child.unsupported("`\(name)` should be a list of `- value` lines")
            }
            let item = try InlineValue(child.content.dropFirst().drop { $0 == " " }, on: child)
            guard let string = try decodeScalar(item.text, on: child) else { throw child.unsupported("empty list item") }
            return string
        }
    }
}

extension Array where Element == Node {
    fileprivate func named(_ name: String) -> Node? {
        first { $0.name == name }
    }
}

/// The text after `key:`, split into spacing, value and an optional `# comment`.
private struct InlineValue {
    let leading: Substring
    let text: Substring
    /// Spacing after the value, then the comment.
    let tail: Substring

    init(_ rest: Substring, on line: Line) throws {
        leading = rest.prefix { $0 == " " || $0 == "\t" }
        let body = rest[leading.endIndex...]
        var end = body.startIndex
        switch body.first {
        case "\""?, "'"?:
            end = try endOfQuoted(body, on: line)
        case "["?:
            end = try endOfFlowList(body, on: line)
        default:
            // A comment starts at a `#` that begins the value or follows whitespace.
            var previous: Character = " "
            for index in body.indices {
                let character = body[index]
                if character == "#" && previous.isWhitespace { break }
                if !character.isWhitespace { end = body.index(after: index) }
                previous = character
            }
        }
        text = body[..<end]
        tail = body[end...]

        let afterValue = tail.drop { $0 == " " || $0 == "\t" }
        guard afterValue.isEmpty || afterValue.hasPrefix("#") else {
            throw line.unsupported("unexpected text after a value")
        }
        if let first = text.first, "&*!|>{}%@`?".contains(first) {
            throw line.unsupported("anchors, aliases, tags, block scalars and flow mappings aren't supported")
        }
        if text == "-" || text.hasPrefix("- ") {
            throw line.unsupported("lists should start on the next line")
        }
        if text.first != "\"" && text.first != "'" && text.first != "[" && (text.contains(": ") || text.hasSuffix(":")) {
            throw line.unsupported("nested keys should go on their own lines")
        }
    }
}

// MARK: - Section

/// Column layout of the entries: where `-` goes, where keys go, and how far nested keys are indented.
private struct Layout {
    var item = 2
    var content = 4
    var step = 2
}

/// One `- key: ...` entry.
private struct Item {
    let dashIndex: Int
    let dashColumn: Int
    /// Column of the entry's keys.
    let column: Int
    let nodes: [Node]
    let entry: RepositoryEntry
    /// The last line holding structure.
    let lastIndex: Int

    init(_ lines: [Line]) throws {
        let dash = lines[0]
        let afterDash = dash.content.dropFirst()
        let spaces = afterDash.prefix { $0 == " " }.count
        let content = afterDash.dropFirst(spaces)
        guard spaces > 0, !content.isEmpty, !content.hasPrefix("#") else {
            throw dash.unsupported("put each repository's first key on its `-` line")
        }
        let first = Line(index: dash.index, column: dash.column + 1 + spaces, content: content)

        dashIndex = dash.index
        dashColumn = dash.column
        column = first.column
        nodes = try parseMapping([first] + lines.dropFirst(), column: first.column)
        lastIndex = lines[lines.count - 1].index

        guard let keyNode = nodes.named("key"), let key = try keyNode.string(), !key.isEmpty else {
            throw dash.unsupported("a repository has no `key`")
        }
        var entry = RepositoryEntry(key: key)
        for field in RepositoriesConfig.fields {
            var scope = nodes
            for name in field.path.dropLast() {
                scope = try scope.named(name)?.mapping() ?? []
            }
            if let node = scope.named(field.path[field.path.count - 1]), let value = try node.read(field.kind) {
                field.set(&entry, value)
            }
        }
        self.entry = entry
    }
}

/// The `repositories:` section: its key line and entries.
private struct Section {
    private(set) var keyIndex: Int?
    private(set) var items: [Item] = []

    init(_ text: ConfigLines) throws {
        for index in text.lines.indices where text.indent(at: index) == 0 {
            let line = Line(index: index, column: 0, content: text.lines[index][...])
            guard let (name, rest) = parseKey(line.content), name == "repositories" else { continue }
            guard keyIndex == nil else { throw line.unsupported("`repositories:` appears twice") }
            guard try InlineValue(rest, on: line).text.isEmpty else {
                throw line.unsupported("`repositories:` should be followed by indented `- key: ...` entries")
            }
            keyIndex = index
        }
        guard let keyIndex else { return }

        var structure: [Line] = []
        for index in (keyIndex + 1)..<text.lines.count {
            guard let indent = text.indent(at: index) else { continue }
            let raw = text.lines[index]
            let line = Line(index: index, column: indent, content: raw.dropFirst(indent))
            if raw.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") {
                throw line.unsupported("tabs in indentation aren't supported")
            }
            if indent == 0 && !line.isDash { break }
            try Self.check(line)
            structure.append(line)
        }
        items = try Self.items(structure)

        var keys = Set<String>()
        for item in items where !keys.insert(item.entry.key).inserted {
            throw RepositoriesConfigError.duplicateKey(item.entry.key)
        }
    }

    func item(_ key: String) -> Item? {
        items.first { $0.entry.key == key }
    }

    var layout: Layout {
        var layout = Layout()
        if let first = items.first {
            layout.item = first.dashColumn
            layout.content = first.column
        }
        for node in items.flatMap(\.nodes) {
            if let child = node.children.first, !child.isDash {
                layout.step = child.column - node.line.column
                break
            }
        }
        return layout
    }

    func itemsAreSeparatedByBlankLines(in text: ConfigLines) -> Bool {
        zip(items, items.dropFirst()).contains { previous, next in
            ((text.end(of: previous) + 1)..<next.dashIndex).contains { text.isBlank($0) }
        }
    }

    /// Refuses YAML features on any line of the section, including keys the model doesn't read.
    private static func check(_ line: Line) throws {
        var content = line.content
        while content == "-" || content.hasPrefix("- ") {
            content = content.dropFirst().drop { $0 == " " }
        }
        if let (_, rest) = parseKey(content) {
            _ = try InlineValue(rest, on: line)
        } else {
            _ = try InlineValue(content, on: line)
        }
    }

    private static func items(_ structure: [Line]) throws -> [Item] {
        guard let first = structure.first else { return [] }
        guard first.isDash else {
            throw first.unsupported("`repositories:` should hold `- key: ...` entries")
        }
        var groups: [[Line]] = []
        for line in structure {
            if line.column == first.column && line.isDash {
                groups.append([line])
            } else if line.column > first.column {
                groups[groups.count - 1].append(line)
            } else {
                throw line.unsupported("unexpected indentation")
            }
        }
        return try groups.map(Item.init)
    }
}

// MARK: - Parsing

/// `name` and the text after the colon, for a `name:` line with a plain key.
private func parseKey(_ content: Substring) -> (String, Substring)? {
    guard let first = content.first, first.isASCII, first.isLetter || first == "_" else { return nil }
    let name = content.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    let afterName = content.dropFirst(name.count)
    guard afterName.first == ":" else { return nil }
    let rest = afterName.dropFirst()
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    return (String(name), rest)
}

/// The keys of a block mapping whose keys all start at `column`.
private func parseMapping(_ lines: [Line], column: Int) throws -> [Node] {
    var nodes: [Node] = []
    var index = 0
    while index < lines.count {
        let line = lines[index]
        guard line.column == column else { throw line.unsupported("unexpected indentation") }
        guard let (name, rest) = parseKey(line.content) else { throw line.unsupported("expected `key: value`") }
        guard nodes.named(name) == nil else { throw line.unsupported("`\(name)` appears twice") }
        let value = try InlineValue(rest, on: line)

        // Nested lines, and `- item` lines at the key's own column when the key holds a list.
        var next = index + 1
        while next < lines.count,
              lines[next].column > column || (value.text.isEmpty && lines[next].column == column && lines[next].isDash) {
            next += 1
        }
        let children = Array(lines[(index + 1)..<next])
        if !value.text.isEmpty, let child = children.first {
            throw child.unsupported("values spread over several lines aren't supported")
        }
        nodes.append(Node(name: name, line: line, value: value, children: children))
        index = next
    }
    return nodes
}

/// The string a scalar holds, or nil for null.
private func decodeScalar(_ text: Substring, on line: Line) throws -> String? {
    guard let first = text.first, !["~", "null", "Null", "NULL"].contains(text) else { return nil }
    switch first {
    case "\"":
        return try unescape(text.dropFirst().dropLast(), on: line)
    case "'":
        return text.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
    case _ where "&*!|>{}[]%@`?,".contains(first):
        throw line.unsupported("unexpected `\(first)`")
    default:
        return String(text)
    }
}

private func unescape(_ text: Substring, on line: Line) throws -> String {
    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        index = text.index(after: index)
        guard character == "\\" else {
            result.append(character)
            continue
        }
        guard index < text.endIndex else { throw line.unsupported("unfinished escape in a quoted value") }
        let escape = text[index]
        index = text.index(after: index)
        switch escape {
        case "\\", "\"", "/": result.append(escape)
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "r": result.append("\r")
        case "u":
            let hex = text[index...].prefix(4)
            guard hex.count == 4, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                throw line.unsupported("bad `\\u` escape in a quoted value")
            }
            result.unicodeScalars.append(scalar)
            index = hex.endIndex
        default:
            throw line.unsupported("unsupported escape `\\\(escape)` in a quoted value")
        }
    }
    return result
}

/// The index after the closing quote of the quoted scalar that `text` starts with.
private func endOfQuoted(_ text: Substring, on line: Line) throws -> Substring.Index {
    let quote = text[text.startIndex]
    var index = text.index(after: text.startIndex)
    while index < text.endIndex {
        let character = text[index]
        index = text.index(after: index)
        if quote == "\"" && character == "\\" {
            if index < text.endIndex { index = text.index(after: index) }
        } else if character == quote {
            // In single quotes, `''` is an escaped quote.
            guard quote == "'", index < text.endIndex, text[index] == "'" else { return index }
            index = text.index(after: index)
        }
    }
    throw line.unsupported("quoted values must end on the same line")
}

/// The index after the `]` that closes the flow list `text` starts with.
private func endOfFlowList(_ text: Substring, on line: Line) throws -> Substring.Index {
    var index = text.index(after: text.startIndex)
    while index < text.endIndex {
        switch text[index] {
        case "\"", "'":
            index = try endOfQuoted(text[index...], on: line)
        case "]":
            return text.index(after: index)
        case "[", "{":
            throw line.unsupported("nested lists and mappings aren't supported")
        default:
            index = text.index(after: index)
        }
    }
    throw line.unsupported("`[` lists must end on the same line")
}

/// The items of a one-line `[a, "b"]` list.
private func flowItems(_ text: Substring, on line: Line) throws -> [String] {
    let inner = text.dropFirst().dropLast()
    var parts: [Substring] = []
    var start = inner.startIndex
    var index = inner.startIndex
    while index < inner.endIndex {
        switch inner[index] {
        case "\"", "'":
            index = try endOfQuoted(inner[index...], on: line)
        case ",":
            parts.append(inner[start..<index])
            index = inner.index(after: index)
            start = index
        default:
            index = inner.index(after: index)
        }
    }
    parts.append(inner[start...])

    var items = parts.map { $0.trimmingCharacters(in: .whitespaces)[...] }
    // `[]` and a trailing comma leave one empty part at the end.
    if items.last?.isEmpty == true { items.removeLast() }
    return try items.map { item in
        if item.contains(": ") || item.hasSuffix(":") { throw line.unsupported("mappings inside `[` lists aren't supported") }
        guard let string = try decodeScalar(item, on: line) else { throw line.unsupported("empty list item") }
        return string
    }
}

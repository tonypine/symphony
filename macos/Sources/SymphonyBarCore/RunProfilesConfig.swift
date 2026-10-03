import Foundation

/// Why the model and effort keys of a `symphony.yml` can't be read or changed.
public enum RunProfilesConfigError: LocalizedError, Equatable {
    /// The keys use YAML the line editor doesn't handle. `line` counts from 1.
    case unsupported(line: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let line, let reason):
            return "symphony.yml line \(line): \(reason). Edit models by hand."
        }
    }
}

/// A kind of run Symphony can give its own model and effort, keyed by its `agent.run_profiles` name.
public enum RunKind: String, CaseIterable, Identifiable {
    case breakdown
    case closeOut = "close_out"
    case finalVerification = "final_verification"
    case implementation
    case rework
    case ciFix = "ci_fix"
    case reviewFeedback = "review_feedback"
    case landing
    case prePushReview = "pre_push_review"
    case qa

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .breakdown: return "Breakdown"
        case .closeOut: return "Close-out"
        case .finalVerification: return "Final verification"
        case .implementation: return "Implementation"
        case .rework: return "Rework"
        case .ciFix: return "CI fix"
        case .reviewFeedback: return "Review feedback"
        case .landing: return "Landing"
        case .prePushReview: return "Pre-push review"
        case .qa: return "QA"
        }
    }
}

/// A field of a run profile, named as its YAML key.
public enum RunProfileField: String, CaseIterable {
    case model, effort
}

/// The model and effort for one kind of run, or the defaults. A nil field is missing from the file.
public struct RunProfile: Equatable {
    public var model: String?
    public var effort: String?

    public init(model: String? = nil, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }

    public subscript(field: RunProfileField) -> String? {
        get { field == .model ? model : effort }
        set {
            if field == .model { model = newValue } else { effort = newValue }
        }
    }
}

/// `agent.model` / `agent.effort` and `agent.run_profiles`.
public struct RunProfiles: Equatable {
    public var defaults: RunProfile
    public var kinds: [RunKind: RunProfile]

    public init(defaults: RunProfile = RunProfile(), kinds: [RunKind: RunProfile] = [:]) {
        self.defaults = defaults
        self.kinds = kinds
    }

    /// The profile of `kind`, or the defaults for nil. An empty profile reads the same as a missing one.
    public subscript(kind: RunKind?) -> RunProfile {
        get { kind.map { kinds[$0] ?? RunProfile() } ?? defaults }
        set {
            if let kind {
                kinds[kind] = newValue == RunProfile() ? nil : newValue
            } else {
                defaults = newValue
            }
        }
    }
}

/// A value offered in a picker.
public struct RunProfileChoice: Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Reads and changes the model and effort keys in the text of a `symphony.yml`, one line at a time, so
/// comments, ordering and unrelated keys stay as they are.
public enum RunProfilesConfig {
    /// The Default row first, then every run kind.
    public static let scopes: [RunKind?] = [nil] + RunKind.allCases

    public static let models = [
        RunProfileChoice(id: "claude-opus-5-5", title: "Opus 5.5"),
        RunProfileChoice(id: "claude-sonnet-5-5", title: "Sonnet 5.5"),
        RunProfileChoice(id: "claude-haiku-4-5-20251001", title: "Haiku 4.5"),
    ]

    public static let efforts = ["low", "medium", "high", "xhigh", "max"].map { RunProfileChoice(id: $0, title: $0) }

    /// `choices`, plus `current` when the file holds a value they don't list.
    public static func choices(_ choices: [RunProfileChoice], including current: String?) -> [RunProfileChoice] {
        guard let current, !choices.contains(where: { $0.id == current }) else { return choices }
        return choices + [RunProfileChoice(id: current, title: current)]
    }

    /// The title of a picker's default entry: "default", or what `agent.command` passes, as in
    /// "Opus 5.5, from command".
    public static func defaultTitle(_ choices: [RunProfileChoice], inherited: String?) -> String {
        guard let inherited else { return "default" }
        return (choices.first { $0.id == inherited }?.title ?? inherited) + ", from command"
    }

    /// Keys of `agent:` in the order new ones are written.
    static let agentOrder = ["runtime", "command", "model", "effort", "run_profiles"]
    static let fieldOrder = RunProfileField.allCases.map(\.rawValue)
    static let defaultIndentStep = 2

    // MARK: Reading

    public static func profiles(in yaml: String) throws -> RunProfiles {
        let document = Document(yaml)
        guard let agent = try agentKey(in: document) else { return RunProfiles() }
        let agentRange = document.children(of: agent)
        var profiles = RunProfiles()
        for field in RunProfileField.allCases {
            profiles.defaults[field] = try scalar(field.rawValue, in: agentRange, of: document)
        }
        guard let runProfiles = document.child("run_profiles", in: agentRange) else { return profiles }
        let inline = try InlineText(runProfiles)

        if inline.isFlowMap {
            for entry in try inline.flowMap(runProfiles) {
                guard let kind = RunKind(rawValue: entry.key) else { continue }
                guard case .map(let fields) = entry.value else { throw runProfiles.unsupported("`\(kind.rawValue)` should hold model and/or effort") }
                profiles[kind] = try profile(from: fields, on: runProfiles)
            }
            return profiles
        }
        try requireBlock(runProfiles, inline)
        let range = document.children(of: runProfiles)
        for kind in RunKind.allCases {
            guard let key = document.child(kind.rawValue, in: range) else { continue }
            let kindInline = try InlineText(key)
            if kindInline.isFlowMap {
                profiles[kind] = try profile(from: kindInline.flowMap(key), on: key)
            } else {
                try requireBlock(key, kindInline)
                let kindRange = document.children(of: key)
                var profile = RunProfile()
                for field in RunProfileField.allCases {
                    profile[field] = try scalar(field.rawValue, in: kindRange, of: document)
                }
                profiles[kind] = profile
            }
        }
        return profiles
    }

    private static func profile(from entries: [FlowEntry], on key: Document.Key) throws -> RunProfile {
        var profile = RunProfile()
        for entry in entries {
            guard let field = RunProfileField(rawValue: entry.key) else { continue }
            guard case .text(let raw) = entry.value else { throw key.unsupported("`\(field.rawValue)` should be a single value") }
            profile[field] = try decodeScalar(Substring(raw), on: key)
        }
        return profile
    }

    /// The `--model` and `--effort` that `agent.command` passes, which runs use while `agent.model` and
    /// `agent.effort` are unset.
    public static func commandProfile(in yaml: String) throws -> RunProfile {
        let document = Document(yaml)
        guard let key = try commandKey(in: document),
              let command = try decodeScalar(InlineText(key).value, on: key) else { return RunProfile() }
        return splitCommandFlags(command).flags
    }

    /// The command without its `--model` / `--effort` flags (`--model x` or `--model=x`), and their values.
    /// Matches the flags Symphony rejects in `agent.command` once any model or effort is set.
    static func splitCommandFlags(_ command: String) -> (command: String, flags: RunProfile) {
        var rest = command
        var flags = RunProfile()
        for field in RunProfileField.allCases {
            let pattern = #"(^|\s+)--"# + field.rawValue + #"(?:=(\S*)|\s+(?!-)(\S+))?(?=\s|$)"#
            let regex = try! NSRegularExpression(pattern: pattern)
            let matches = regex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest))
            // The CLI takes the last one.
            for match in matches {
                for group in [2, 3] {
                    if let value = Range(match.range(at: group), in: rest), let unquoted = unquoted(rest[value]) {
                        flags[field] = unquoted
                    }
                }
            }
            for match in matches.reversed() {
                rest.removeSubrange(Range(match.range, in: rest)!)
            }
        }
        if command.first?.isWhitespace != true {
            rest = String(rest.drop { $0.isWhitespace })
        }
        return (rest, flags)
    }

    private static func unquoted(_ value: Substring) -> String? {
        var value = value
        if value.count >= 2, let quote = value.first, quote == "'" || quote == "\"", value.last == quote {
            value = value.dropFirst().dropLast()
        }
        return value.isEmpty ? nil : String(value)
    }

    /// The value of a direct child `name:` of the range.
    private static func scalar(_ name: String, in range: Range<Int>, of document: Document) throws -> String? {
        guard let key = document.child(name, in: range) else { return nil }
        try requireScalar(key, in: document)
        return try decodeScalar(InlineText(key).value, on: key)
    }

    // MARK: Writing

    /// The same text with every field that differs between `old` and `new` written, and nothing else.
    ///
    /// Symphony rejects `--model` / `--effort` in `agent.command` once any model or effort is set, so when
    /// the result sets one, those flags move out of the command into `agent.model` / `agent.effort`, unless
    /// `new` sets those itself. Runs then use the same model and effort as before.
    public static func updating(_ yaml: String, from old: RunProfiles, to new: RunProfiles) throws -> String {
        guard old != new else { return yaml }
        var text = yaml
        var new = new
        let flags = try commandProfile(in: yaml)
        if flags != RunProfile() && (new.defaults != RunProfile() || !new.kinds.isEmpty) {
            for field in RunProfileField.allCases where new.defaults[field] == nil {
                new.defaults[field] = flags[field]
            }
            text = try removingCommandFlags(in: text)
        }
        for kind in scopes {
            for field in RunProfileField.allCases where old[kind][field] != new[kind][field] {
                text = try setting(field, of: kind, to: new[kind][field], in: text)
            }
        }
        return text
    }

    /// The same text with one field set: `agent.<field>` for a nil kind, else
    /// `agent.run_profiles.<kind>.<field>`. Rewrites only that value, keeping a trailing comment, or inserts
    /// the key and any missing parent. A nil value removes the key, then a kind or `run_profiles:` it left
    /// empty (Symphony rejects an empty one).
    public static func setting(_ field: RunProfileField, of kind: RunKind?, to value: String?, in yaml: String) throws -> String {
        var document = Document(yaml)
        let rendered = value.map(RepositoriesConfig.scalar)
        let step = defaultIndentStep

        guard let agent = try agentKey(in: document) else {
            guard let rendered else { return yaml }
            let pad = String(repeating: " ", count: step)
            if let kind {
                document.append(["agent:", pad + "run_profiles:", pad + pad + flowLine(kind, field, rendered)])
            } else {
                document.append(["agent:", pad + field.rawValue + ": " + rendered])
            }
            return document.text
        }
        let agentRange = document.children(of: agent)
        let column = document.childIndent(in: agentRange) ?? agent.indent + step
        let agentStep = column - agent.indent

        guard let kind else {
            try set(field.rawValue, to: rendered, under: agent, column: column, order: agentOrder, in: &document)
            return document.text
        }

        guard let runProfiles = document.child("run_profiles", in: agentRange) else {
            guard let rendered else { return yaml }
            let index = insertionIndex(for: "run_profiles", in: agentRange, order: agentOrder, after: agent, of: document)
            let pad = String(repeating: " ", count: column)
            document.lines.insert(
                contentsOf: [pad + "run_profiles:", pad + String(repeating: " ", count: agentStep) + flowLine(kind, field, rendered)],
                at: index
            )
            return document.text
        }
        let inline = try InlineText(runProfiles)

        if inline.isFlowMap {
            var entries = try inline.flowMap(runProfiles)
            if entries.isEmpty {
                // `run_profiles: {}` turns into a block holding the new kind.
                guard let rendered else { return yaml }
                document.lines[runProfiles.index] = inline.replacingValue(in: runProfiles, with: "")
                let pad = String(repeating: " ", count: runProfiles.indent + agentStep)
                document.lines.insert(pad + flowLine(kind, field, rendered), at: runProfiles.index + 1)
                return document.text
            }
            let entryIndex = entries.firstIndex { $0.key == kind.rawValue }
            var fields: [FlowEntry] = []
            if let entryIndex {
                guard case .map(let existing) = entries[entryIndex].value else {
                    throw runProfiles.unsupported("`\(kind.rawValue)` should hold model and/or effort")
                }
                fields = existing
            }
            guard set(field, to: rendered, in: &fields) else { return yaml }
            if let entryIndex {
                if fields.isEmpty { entries.remove(at: entryIndex) } else { entries[entryIndex].value = .map(fields) }
            } else {
                entries.append(FlowEntry(key: kind.rawValue, value: .map(fields)))
            }
            if entries.isEmpty {
                document.lines.remove(at: runProfiles.index)
            } else {
                document.lines[runProfiles.index] = inline.replacingValue(in: runProfiles, with: renderFlow(entries, padded: inline.isPadded))
            }
            return document.text
        }

        try requireBlock(runProfiles, inline)
        let profilesRange = document.children(of: runProfiles)
        let kindColumn = document.childIndent(in: profilesRange) ?? runProfiles.indent + agentStep

        guard let kindKey = document.child(kind.rawValue, in: profilesRange) else {
            guard let rendered else { return yaml }
            let last = document.lastStructural(in: profilesRange) ?? runProfiles.index
            let index = document.blockEnd(last, deeperThan: kindColumn) + 1
            let pad = String(repeating: " ", count: kindColumn)
            if try siblingsUseBlocks(in: profilesRange, of: document) {
                let fieldPad = String(repeating: " ", count: kindColumn + agentStep)
                document.lines.insert(contentsOf: [pad + kind.rawValue + ":", fieldPad + field.rawValue + ": " + rendered], at: index)
            } else {
                document.lines.insert(pad + flowLine(kind, field, rendered), at: index)
            }
            return document.text
        }
        let kindInline = try InlineText(kindKey)

        if kindInline.isFlowMap {
            var fields = try kindInline.flowMap(kindKey)
            guard set(field, to: rendered, in: &fields) else { return yaml }
            if fields.isEmpty {
                document.lines.remove(at: kindKey.index)
            } else {
                document.lines[kindKey.index] = kindInline.replacingValue(in: kindKey, with: renderFlow(fields, padded: kindInline.isPadded))
            }
        } else {
            try requireBlock(kindKey, kindInline)
            let fieldColumn = document.childIndent(in: document.children(of: kindKey)) ?? kindKey.indent + agentStep
            try set(field.rawValue, to: rendered, under: kindKey, column: fieldColumn, order: fieldOrder, in: &document)
            if let emptied = document.child(kind.rawValue, in: document.children(of: runProfiles)),
               document.childIndent(in: document.children(of: emptied)) == nil {
                document.lines.remove(at: emptied.index)
            }
        }
        if let profiles = document.child("run_profiles", in: document.children(of: agent)),
           document.childIndent(in: document.children(of: profiles)) == nil {
            document.lines.remove(at: profiles.index)
        }
        return document.text
    }

    /// The text with `--model` / `--effort` taken out of `agent.command`, keeping the rest of the line, its
    /// quoting and any trailing comment.
    private static func removingCommandFlags(in yaml: String) throws -> String {
        var document = Document(yaml)
        guard let key = try commandKey(in: document) else { return yaml }
        let inline = try InlineText(key)
        let rendered: String
        switch inline.value.first {
        case "'"?:
            guard let command = try decodeScalar(inline.value, on: key) else { return yaml }
            rendered = "'" + splitCommandFlags(command).command.replacingOccurrences(of: "'", with: "''") + "'"
        case "\""?:
            guard let command = try decodeScalar(inline.value, on: key) else { return yaml }
            rendered = RepositoriesConfig.scalar(splitCommandFlags(command).command)
        default:
            rendered = splitCommandFlags(String(inline.value)).command
        }
        document.lines[key.index] = inline.replacingValue(in: key, with: rendered)
        return document.text
    }

    /// Sets the scalar child `name:` of `parent`: rewrites its value, inserts it in `order`, or removes it for nil.
    private static func set(
        _ name: String,
        to rendered: String?,
        under parent: Document.Key,
        column: Int,
        order: [String],
        in document: inout Document
    ) throws {
        let range = document.children(of: parent)
        guard let key = document.child(name, in: range) else {
            guard let rendered else { return }
            let index = insertionIndex(for: name, in: range, order: order, after: parent, of: document)
            document.lines.insert(String(repeating: " ", count: column) + name + ": " + rendered, at: index)
            return
        }
        try requireScalar(key, in: document)
        let inline = try InlineText(key)
        guard let rendered else {
            document.lines.remove(at: key.index)
            return
        }
        guard try decodeScalar(inline.value, on: key) != decodeScalar(Substring(rendered), on: key) else { return }
        document.lines[key.index] = inline.replacingValue(in: key, with: rendered)
    }

    /// Sets a field in flow-map entries. Returns false when nothing changed.
    private static func set(_ field: RunProfileField, to rendered: String?, in entries: inout [FlowEntry]) -> Bool {
        let index = entries.firstIndex { $0.key == field.rawValue }
        switch (index, rendered) {
        case (nil, nil):
            return false
        case (let index?, nil):
            entries.remove(at: index)
        case (let index?, let rendered?):
            guard entries[index].value != .text(rendered) else { return false }
            entries[index].value = .text(rendered)
        case (nil, let rendered?):
            // Model goes before effort.
            let position = field == .model ? 0 : entries.count
            entries.insert(FlowEntry(key: field.rawValue, value: .text(rendered)), at: position)
        }
        return true
    }

    /// Where a new key goes: after the block of the nearest key that comes before it in `order`, or else
    /// right after the parent line.
    private static func insertionIndex(
        for name: String,
        in range: Range<Int>,
        order: [String],
        after parent: Document.Key,
        of document: Document
    ) -> Int {
        let earlier = order.prefix { $0 != name }
        let previous = earlier.compactMap { document.child($0, in: range) }.max { $0.index < $1.index }
        guard let previous else { return parent.index + 1 }
        let last = document.lastStructural(in: document.children(of: previous)) ?? previous.index
        return document.blockEnd(last, deeperThan: previous.indent) + 1
    }

    /// Whether the existing kinds are written as indented blocks rather than `{ ... }`.
    private static func siblingsUseBlocks(in range: Range<Int>, of document: Document) throws -> Bool {
        guard let column = document.childIndent(in: range) else { return false }
        guard let first = range.first(where: { document.indent(at: $0) == column }) else { return false }
        let content = document.lines[first].dropFirst(column)
        guard let colon = content.firstIndex(of: ":") else { return false }
        let key = Document.Key(name: String(content[..<colon]), index: first, indent: column, rest: String(content[content.index(after: colon)...]))
        return try InlineText(key).value.isEmpty
    }

    private static func flowLine(_ kind: RunKind, _ field: RunProfileField, _ rendered: String) -> String {
        kind.rawValue + ": { " + field.rawValue + ": " + rendered + " }"
    }

    // MARK: Checks

    /// The top-level `agent:` key, or nil when it's missing.
    private static func agentKey(in document: Document) throws -> Document.Key? {
        guard let agent = document.child("agent", in: document.all) else { return nil }
        try requireBlock(agent, InlineText(agent))
        return agent
    }

    /// `agent.command`, or nil when it's missing.
    private static func commandKey(in document: Document) throws -> Document.Key? {
        guard let agent = try agentKey(in: document),
              let key = document.child("command", in: document.children(of: agent)) else { return nil }
        try requireScalar(key, in: document)
        return key
    }

    private static func requireBlock(_ key: Document.Key, _ inline: InlineText) throws {
        guard inline.isNull else { throw key.unsupported("`\(key.name):` should be an indented block") }
    }

    private static func requireScalar(_ key: Document.Key, in document: Document) throws {
        guard document.childIndent(in: document.children(of: key)) == nil else {
            throw key.unsupported("`\(key.name)` should be a single value")
        }
        let first = try InlineText(key).value.first
        guard first != "{" && first != "[" else { throw key.unsupported("`\(key.name)` should be a single value") }
    }
}

/// Run profile edits to a `symphony.yml` on disk.
extension SymphonyConfigFile {
    public func readRunProfiles() throws -> RunProfiles {
        try RunProfilesConfig.profiles(in: read())
    }

    /// The `--model` / `--effort` that `agent.command` passes.
    public func readCommandProfile() throws -> RunProfile {
        try RunProfilesConfig.commandProfile(in: read())
    }

    /// Writes the fields that differ between `old` and `new`. Leaves the file untouched when none do.
    public func writeRunProfiles(_ new: RunProfiles, from old: RunProfiles) throws {
        try rewrite { try RunProfilesConfig.updating($0, from: old, to: new) }
    }
}

// MARK: - Inline values

extension Document.Key {
    fileprivate func unsupported(_ reason: String) -> RunProfilesConfigError {
        .unsupported(line: index + 1, reason: reason)
    }
}

/// One `key: value` of a flow mapping, as written.
private struct FlowEntry: Equatable {
    let key: String
    var value: FlowValue
}

private enum FlowValue: Equatable {
    /// A scalar or list, as written.
    case text(String)
    case map([FlowEntry])
}

/// The text after `key:`, split into spacing, value and an optional `# comment`.
private struct InlineText {
    let leading: Substring
    let value: Substring
    /// Spacing after the value, then the comment.
    let tail: Substring

    init(_ key: Document.Key) throws {
        let rest = Substring(key.rest)
        leading = rest.prefix { $0 == " " || $0 == "\t" }
        let body = rest[leading.endIndex...]
        var end = body.startIndex
        switch body.first {
        case "\""?, "'"?, "{"?, "["?:
            var scanner = FlowScanner(body, key: key)
            try scanner.skipValue()
            end = scanner.index
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
        value = body[..<end]
        tail = body[end...]

        let afterValue = tail.drop { $0 == " " || $0 == "\t" }
        guard afterValue.isEmpty || afterValue.hasPrefix("#") else {
            throw key.unsupported("unexpected text after a value")
        }
        if let first = value.first, "&*!|>%@`".contains(first) {
            throw key.unsupported("anchors, aliases, tags and block scalars aren't supported")
        }
    }

    var isNull: Bool { ["", "~", "null", "Null", "NULL"].contains(value) }

    var isFlowMap: Bool { value.first == "{" }

    /// Whether the braces have spaces inside them, as in `{ effort: high }`.
    var isPadded: Bool { value.dropFirst().first == " " || value == "{}" }

    func flowMap(_ key: Document.Key) throws -> [FlowEntry] {
        var scanner = FlowScanner(value, key: key)
        return try scanner.map()
    }

    /// The key's line with the value replaced, keeping the spacing and any trailing comment. An empty
    /// `rendered` leaves `key:` with only the comment.
    func replacingValue(in key: Document.Key, with rendered: String) -> String {
        let head = String(repeating: " ", count: key.indent) + key.name + ":"
        let comment = tail.drop { $0 == " " || $0 == "\t" }
        if rendered.isEmpty {
            return head + (comment.isEmpty ? "" : " " + comment)
        }
        if value.isEmpty {
            return head + " " + rendered + (comment.isEmpty ? "" : " " + comment)
        }
        return head + leading + rendered + tail
    }
}

/// Reads flow-style YAML (`{ key: value, ... }`, quoted strings and lists) one character at a time.
private struct FlowScanner {
    let text: Substring
    let key: Document.Key
    var index: Substring.Index

    init(_ text: Substring, key: Document.Key) {
        self.text = text
        self.key = key
        index = text.startIndex
    }

    var current: Character? { index < text.endIndex ? text[index] : nil }

    mutating func advance() { index = text.index(after: index) }

    mutating func skipSpace() {
        while let character = current, character == " " || character == "\t" { advance() }
    }

    func error(_ reason: String = "a `{ ... }` value couldn't be read") -> RunProfilesConfigError {
        key.unsupported(reason)
    }

    /// Moves past one quoted string, list or mapping.
    mutating func skipValue() throws {
        switch current {
        case "\""?, "'"?:
            try skipQuoted()
        case "{"?:
            _ = try map()
        default:
            try skipList()
        }
    }

    mutating func skipQuoted() throws {
        let quote = current
        advance()
        while let character = current {
            advance()
            if character == "\\" && quote == "\"" {
                guard current != nil else { break }
                advance()
            } else if character == quote {
                // `''` inside single quotes is an escaped quote.
                guard quote == "'" && current == "'" else { return }
                advance()
            }
        }
        throw error("a quoted value has no closing quote")
    }

    mutating func skipList() throws {
        advance()
        while let character = current {
            switch character {
            case "\"", "'": try skipQuoted()
            case "[": try skipList()
            case "]":
                advance()
                return
            default: advance()
            }
        }
        throw error("a `[` list has no closing `]`")
    }

    mutating func map() throws -> [FlowEntry] {
        advance()
        var entries: [FlowEntry] = []
        skipSpace()
        if current == "}" {
            advance()
            return entries
        }
        while true {
            skipSpace()
            let keyStart = index
            if current == "\"" || current == "'" { try skipQuoted() }
            while let character = current, character != ":", character != ",", character != "}" { advance() }
            guard current == ":" else { throw error() }
            let rawKey = text[keyStart..<index].trimmingCharacters(in: .whitespaces)
            guard let name = try decodeScalar(Substring(rawKey), on: key) else { throw error() }
            advance()
            skipSpace()

            let value: FlowValue
            switch current {
            case "{"?:
                value = .map(try map())
            case "\""?, "'"?, "["?:
                let start = index
                try skipValue()
                value = .text(String(text[start..<index]))
            default:
                let start = index
                while let character = current, character != ",", character != "}" { advance() }
                value = .text(text[start..<index].trimmingCharacters(in: .whitespaces))
            }
            entries.append(FlowEntry(key: name, value: value))
            skipSpace()
            switch current {
            case ","?:
                advance()
            case "}"?:
                advance()
                return entries
            default:
                throw error()
            }
        }
    }
}

/// A scalar's string, or nil for an empty or null value.
private func decodeScalar(_ text: Substring, on key: Document.Key) throws -> String? {
    switch text.first {
    case "\""?:
        var result = ""
        var escaped = false
        for character in text.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    case "'"?:
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    case "["?, "{"?:
        throw key.unsupported("`\(key.name)` should be a single value")
    default:
        return ["", "~", "null", "Null", "NULL"].contains(text) ? nil : String(text)
    }
}

private func renderFlow(_ entries: [FlowEntry], padded: Bool) -> String {
    guard !entries.isEmpty else { return "{}" }
    let body = entries.map { entry -> String in
        switch entry.value {
        case .text(let text): return entry.key + ": " + text
        case .map(let fields): return entry.key + ": " + renderFlow(fields, padded: padded)
        }
    }.joined(separator: ", ")
    return padded ? "{ " + body + " }" : "{" + body + "}"
}

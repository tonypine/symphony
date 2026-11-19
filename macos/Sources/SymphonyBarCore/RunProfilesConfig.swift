import Foundation

/// Why the `runs` and `execution.harnesses` keys of a `symphony.yml` can't be read or changed.
public enum RunProfilesConfigError: LocalizedError, Equatable {
    /// The keys use YAML the line editor doesn't handle. `line` counts from 1.
    case unsupported(line: Int, reason: String)
    /// No `repositories[]` entry has the key.
    case repositoryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let line, let reason):
            return "symphony.yml line \(line): \(reason). Edit models by hand."
        case .repositoryNotFound(let key):
            return "symphony.yml has no repository with key `\(key)`."
        }
    }
}

/// A kind of run Symphony starts with its own harness, provider, model and effort, keyed by its `runs` name.
public enum RunKind: String, CaseIterable, Identifiable {
    case breakdown
    case implementation
    case rework
    case ciFix = "ci_fix"
    case reviewFeedback = "review_feedback"
    case landing
    case codeReview = "code_review"
    case epicReview = "epic_review"
    case qa
    /// The Conductor's turn at a junction of a ticket's life. It takes no step list, so it is no `PhaseKind`.
    case conductor

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .breakdown: return "Breakdown"
        case .implementation: return "Implementation"
        case .rework: return "Rework"
        case .ciFix: return "CI fix"
        case .reviewFeedback: return "Review feedback"
        case .landing: return "Landing"
        case .codeReview: return "Code review"
        case .epicReview: return "Epic review"
        case .qa: return "QA"
        case .conductor: return "Conductor"
        }
    }
}

/// The agent program that runs a session, keyed by its `execution.harnesses` name. The facts match
/// `SymphonyElixir.Harnesses`.
public enum Harness: String, CaseIterable, Identifiable {
    case claude, codex, opencode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    /// The providers the harness reaches.
    public var providers: [String] {
        switch self {
        case .claude: return [RunProfilesConfig.anthropic, RunProfilesConfig.openRouter, RunProfilesConfig.openCodeGo]
        case .codex: return [RunProfilesConfig.openAI, RunProfilesConfig.openCodeGo]
        case .opencode: return [RunProfilesConfig.openCodeGo]
        }
    }

    /// Whether the harness calls a small model in the background, which it then needs for the run's provider.
    public var callsSmallModel: Bool { self != .codex }
}

/// `execution.harnesses.<harness>`: the harness's command, and the small model it calls in the background, by
/// provider.
public struct HarnessSettings: Equatable {
    public var command: String?
    public var smallModels: [String: String]

    public init(command: String? = nil, smallModels: [String: String] = [:]) {
        self.command = command
        self.smallModels = smallModels
    }
}

/// A field of a run profile, named as its YAML key, in the order new ones are written.
public enum RunProfileField: String, CaseIterable {
    case harness, provider, model, effort
    case smallModel = "small_model"
    case command
}

/// What one kind of run starts with, or the `default` entry. A nil field is missing from the file. `command`
/// is a run kind's own: Symphony rejects it in `default`.
public struct RunProfile: Equatable {
    public var model: String?
    public var effort: String?
    public var provider: String?
    public var harness: String?
    public var smallModel: String?
    public var command: String?

    public init(
        model: String? = nil,
        effort: String? = nil,
        provider: String? = nil,
        harness: String? = nil,
        smallModel: String? = nil,
        command: String? = nil
    ) {
        self.model = model
        self.effort = effort
        self.provider = provider
        self.harness = harness
        self.smallModel = smallModel
        self.command = command
    }

    public subscript(field: RunProfileField) -> String? {
        get {
            switch field {
            case .harness: return harness
            case .provider: return provider
            case .model: return model
            case .effort: return effort
            case .smallModel: return smallModel
            case .command: return command
            }
        }
        set {
            switch field {
            case .harness: harness = newValue
            case .provider: provider = newValue
            case .model: model = newValue
            case .effort: effort = newValue
            case .smallModel: smallModel = newValue
            case .command: command = newValue
            }
        }
    }

    /// Each field of this profile, or of `fallback` where this one is unset.
    public func merged(over fallback: RunProfile) -> RunProfile {
        var merged = self
        for field in RunProfileField.allCases where merged[field] == nil {
            merged[field] = fallback[field]
        }
        return merged
    }

    /// The fields a run kind inherits from this `default` entry: every one but `command`.
    var inheritable: RunProfile {
        var profile = self
        profile.command = nil
        return profile
    }
}

/// One alternative of an entry's `fallbacks` list: what it sets on top of the entry's own choice. A nil field is
/// missing from the file. See `RunsEditor` for how it resolves.
public struct RunFallback: Equatable {
    public var harness: String?
    public var provider: String?
    public var model: String?
    public var effort: String?
    public var smallModel: String?

    public init(
        harness: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        smallModel: String? = nil
    ) {
        self.harness = harness
        self.provider = provider
        self.model = model
        self.effort = effort
        self.smallModel = smallModel
    }

    /// The fields a fallback may set: every run profile field but `command`.
    public static let fields: [RunProfileField] = [.harness, .provider, .model, .effort, .smallModel]

    public subscript(field: RunProfileField) -> String? {
        get {
            switch field {
            case .harness: return harness
            case .provider: return provider
            case .model: return model
            case .effort: return effort
            case .smallModel: return smallModel
            case .command: return nil
            }
        }
        set {
            switch field {
            case .harness: harness = newValue
            case .provider: provider = newValue
            case .model: model = newValue
            case .effort: effort = newValue
            case .smallModel: smallModel = newValue
            case .command: break
            }
        }
    }
}

/// A `runs` block: its `default` entry, the run kinds it sets, and the `fallbacks` lists its entries set, keyed
/// by run kind (nil for `default`). A missing list is unset; Symphony reads an empty one the same way.
public struct RunProfiles: Equatable {
    public var defaults: RunProfile
    public var kinds: [RunKind: RunProfile]
    public var fallbacks: [RunKind?: [RunFallback]]

    public init(
        defaults: RunProfile = RunProfile(),
        kinds: [RunKind: RunProfile] = [:],
        fallbacks: [RunKind?: [RunFallback]] = [:]
    ) {
        self.defaults = defaults
        self.kinds = kinds
        self.fallbacks = fallbacks
    }

    /// The `fallbacks` list the entry for `kind` sets itself, or nil. An empty list reads the same as a missing one.
    public func fallbacks(of kind: RunKind?) -> [RunFallback]? {
        fallbacks[kind].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Sets the entry's own `fallbacks` list; nil or an empty list removes it.
    public mutating func setFallbacks(_ list: [RunFallback]?, of kind: RunKind?) {
        fallbacks[kind] = list.flatMap { $0.isEmpty ? nil : $0 }
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

/// Which `runs` block of a `symphony.yml` the profiles are in: the top-level one, or a `repositories[]`
/// entry's.
public enum RunProfilesScope: Hashable {
    case global
    case repository(String)
}

/// The profiles of the top-level `runs` block and of each repository's `runs` block, keyed by repository key,
/// and `execution.harnesses`. A repository without a block holds empty profiles.
public struct ScopedRunProfiles: Equatable {
    public var global: RunProfiles
    public var repositories: [String: RunProfiles]
    public var harnesses: [Harness: HarnessSettings]

    public init(
        global: RunProfiles = RunProfiles(),
        repositories: [String: RunProfiles] = [:],
        harnesses: [Harness: HarnessSettings] = [:]
    ) {
        self.global = global
        self.repositories = repositories
        self.harnesses = harnesses
    }

    public subscript(scope: RunProfilesScope) -> RunProfiles {
        get {
            switch scope {
            case .global: return global
            case .repository(let key): return repositories[key] ?? RunProfiles()
            }
        }
        set {
            switch scope {
            case .global: global = newValue
            case .repository(let key): repositories[key] = newValue
            }
        }
    }

    /// The settings of `harness`. Empty settings read the same as missing ones.
    public subscript(harness: Harness) -> HarnessSettings {
        get { harnesses[harness] ?? HarnessSettings() }
        set { harnesses[harness] = newValue == HarnessSettings() ? nil : newValue }
    }

    /// What the row for `kind` (nil for the Default row) in `scope` resolves to where it sets nothing, the way
    /// Symphony resolves each field: the repository's kind, the repository's `default`, `runs.<kind>`, then
    /// `runs.default`. Nothing is built in, so the top-level Default row inherits nothing.
    public func inherited(_ kind: RunKind?, in scope: RunProfilesScope) -> RunProfile {
        let global = global.defaults.inheritable
        switch (scope, kind) {
        case (.global, nil):
            return RunProfile()
        case (.global, _?):
            return global
        case (.repository, nil):
            return global
        case (.repository, let kind?):
            return self[scope].defaults.inheritable.merged(over: self.global[kind].merged(over: global))
        }
    }

    /// The providers each harness runs on in some scope's run kind, first choices and fallbacks as they
    /// resolve: the small models those harnesses need.
    public var providersInUse: [Harness: Set<String>] {
        var inUse: [Harness: Set<String>] = [:]
        for scope in [RunProfilesScope.global] + repositories.keys.map(RunProfilesScope.repository) {
            for kind in RunKind.allCases {
                for line in lines(kind, in: scope) {
                    guard let harness = line.harness.value.flatMap(Harness.init) else { continue }
                    inUse[harness, default: []].formUnion(line.provider.value.map { [$0] } ?? [])
                }
            }
        }
        return inUse
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

/// Reads and changes the `runs` and `execution.harnesses` keys in the text of a `symphony.yml`, one line at a
/// time, so comments, ordering and unrelated keys stay as they are.
public enum RunProfilesConfig {
    /// The Default row first, then every run kind.
    public static let scopes: [RunKind?] = [nil] + RunKind.allCases

    /// Anthropic's models, in the order Claude Code's own model picker lists them: the current ones, then the
    /// older ones it keeps under More models. The ids are the ones the `claude` CLI takes with `--model`.
    public static let models = [
        RunProfileChoice(id: "claude-opus-5-5", title: "Opus 5.5"),
        RunProfileChoice(id: "claude-fable-5-2", title: "Fable 5.2"),
        RunProfileChoice(id: "claude-sonnet-5-5", title: "Sonnet 5.5"),
        RunProfileChoice(id: "claude-haiku-5-5", title: "Haiku 5.5"),
        RunProfileChoice(id: "claude-fable-5-1", title: "Fable 5.1"),
        RunProfileChoice(id: "claude-haiku-4-5-20251001", title: "Haiku 4.5"),
        RunProfileChoice(id: "claude-sonnet-5", title: "Sonnet 5"),
        RunProfileChoice(id: "claude-opus-5", title: "Opus 5"),
        RunProfileChoice(id: "claude-fable-5", title: "Fable 5"),
        RunProfileChoice(id: "claude-opus-4-8", title: "Opus 4.8"),
        RunProfileChoice(id: "claude-opus-4-7", title: "Opus 4.7"),
        RunProfileChoice(id: "claude-opus-4-6", title: "Opus 4.6"),
        RunProfileChoice(id: "claude-sonnet-4-6", title: "Sonnet 4.6"),
    ]

    /// OpenAI's models for Codex runs.
    public static let openAIModels = [
        RunProfileChoice(id: "gpt-5.5", title: "GPT-5.5"),
    ]

    public static let efforts = ["low", "medium", "high", "xhigh", "max"].map { RunProfileChoice(id: $0, title: $0) }

    public static let harnesses = Harness.allCases.map { RunProfileChoice(id: $0.rawValue, title: $0.title) }

    public static let anthropic = "anthropic"
    public static let openRouter = "openrouter"
    public static let openCodeGo = "opencode-go"
    public static let openAI = "openai"

    public static let providers = [
        RunProfileChoice(id: anthropic, title: "Anthropic"),
        RunProfileChoice(id: openRouter, title: "OpenRouter"),
        RunProfileChoice(id: openCodeGo, title: "OpenCode Go"),
        RunProfileChoice(id: openAI, title: "OpenAI"),
    ]

    /// The providers `harness` reaches, or every provider for no harness or one Symphony doesn't know.
    public static func providers(for harness: String?) -> [RunProfileChoice] {
        guard let harness = harness.flatMap(Harness.init) else { return providers }
        return providers.filter { harness.providers.contains($0.id) }
    }

    /// `choices`, plus `current` when the file holds a value they don't list.
    public static func choices(_ choices: [RunProfileChoice], including current: String?) -> [RunProfileChoice] {
        guard let current, !choices.contains(where: { $0.id == current }) else { return choices }
        return choices + [RunProfileChoice(id: current, title: current)]
    }

    /// The title of a picker's unset entry: the value it falls back to, or "none".
    public static func inheritedTitle(_ choices: [RunProfileChoice], inherited: String?) -> String {
        guard let inherited else { return "none" }
        return choices.first { $0.id == inherited }?.title ?? inherited
    }

    static let runsSection = "runs"
    static let defaultEntry = "default"
    static let harnessesPath = ["execution", "harnesses"]
    static let commandKey = "command"
    static let fallbacksKey = "fallbacks"
    static let smallModelKey = "small_model"
    static let fieldOrder = RunProfileField.allCases.map(\.rawValue)
    static let defaultIndentStep = 2

    /// The name of the `runs` entry for `kind`, or of the defaults for nil.
    static func entryName(_ kind: RunKind?) -> String { kind?.rawValue ?? defaultEntry }

    // MARK: Reading

    /// The profiles of the top-level `runs` block, or of a repository's `runs` block for `scope`.
    public static func profiles(in yaml: String, scope: RunProfilesScope = .global) throws -> RunProfiles {
        let document = Document(yaml)
        var profiles = RunProfiles()
        guard let runs = try runsKey(in: document, scope: scope) else { return profiles }
        let inline = try InlineText(runs)

        if inline.isFlowMap {
            for entry in try inline.flowMap(runs) {
                guard let kind = kind(named: entry.key) else { continue }
                guard case .map(let fields) = entry.value else { throw runs.unsupported(notAnEntry(entry.key)) }
                profiles[kind] = try profile(from: fields, on: runs)
                profiles.setFallbacks(try fallbacks(from: fields, on: runs), of: kind)
            }
            return profiles
        }
        try requireBlock(runs, inline)
        let range = document.children(of: runs)
        for kind in scopes {
            guard let key = document.child(entryName(kind), in: range) else { continue }
            let entryInline = try InlineText(key)
            if entryInline.isFlowMap {
                let fields = try entryInline.flowMap(key)
                profiles[kind] = try profile(from: fields, on: key)
                profiles.setFallbacks(try fallbacks(from: fields, on: key), of: kind)
            } else {
                try requireBlock(key, entryInline)
                let entryRange = document.children(of: key)
                var profile = RunProfile()
                for field in RunProfileField.allCases {
                    profile[field] = try scalar(field.rawValue, in: entryRange, of: document)
                }
                profiles[kind] = profile
                profiles.setFallbacks(try fallbacks(under: key, in: document), of: kind)
            }
        }
        return profiles
    }

    /// The `fallbacks` list among an entry's `{ ... }` keys.
    private static func fallbacks(from entries: [FlowEntry], on key: Document.Key) throws -> [RunFallback]? {
        guard let entry = entries.first(where: { $0.key == fallbacksKey }) else { return nil }
        guard case .text(let raw) = entry.value else { throw key.unsupported(notAList) }
        return try fallbacks(fromFlow: Substring(raw), on: key)
    }

    /// A `[ { ... }, ... ]` list, or nil for a null value.
    private static func fallbacks(fromFlow text: Substring, on key: Document.Key) throws -> [RunFallback]? {
        if ["", "~", "null", "Null", "NULL"].contains(text) { return nil }
        guard text.first == "[" else { throw key.unsupported(notAList) }
        var scanner = FlowScanner(text, key: key)
        return try scanner.list().map { item -> RunFallback in
            guard case .map(let fields) = item else { throw key.unsupported(notAFallback) }
            return try fallback(from: fields, on: key)
        }
    }

    /// The `fallbacks:` child of a block entry: an inline `[ ... ]` list, or `- ` items under it, each a
    /// `{ ... }` map or indented keys.
    private static func fallbacks(under entry: Document.Key, in document: Document) throws -> [RunFallback]? {
        guard let key = document.child(fallbacksKey, in: document.children(of: entry)) else { return nil }
        let inline = try InlineText(key)
        guard inline.isNull else { return try fallbacks(fromFlow: inline.value, on: key) }
        return try listItems(of: key, in: document).items.map { try fallback(of: $0, in: document) }
    }

    /// One `- ` item of a block `fallbacks` list: a `{ ... }` map, or keys indented under the `-`.
    private static func fallback(of item: ListItems.Item, in document: Document) throws -> RunFallback {
        if item.isFlow {
            guard document.childIndent(in: item.body) == nil else { throw item.key.unsupported(notAFallback) }
            return try fallback(from: InlineText(item.key).flowMap(item.key), on: item.key)
        }
        var alternative = RunFallback()
        for field in RunFallback.fields {
            let name = field.rawValue
            let fieldKey = item.key.name == name ? item.key : document.child(name, in: item.body, indent: item.column)
            guard let fieldKey else { continue }
            try requireScalar(fieldKey, in: document)
            alternative[field] = try decodeScalar(InlineText(fieldKey).value, on: fieldKey)
        }
        return alternative
    }

    private static func fallback(from entries: [FlowEntry], on key: Document.Key) throws -> RunFallback {
        var fallback = RunFallback()
        for entry in entries {
            guard let field = RunProfileField(rawValue: entry.key), RunFallback.fields.contains(field) else { continue }
            guard case .text(let raw) = entry.value else { throw key.unsupported("`\(field.rawValue)` should be a single value") }
            fallback[field] = try decodeScalar(Substring(raw), on: key)
        }
        return fallback
    }

    /// The `- ` items of a block list under `key`, which may sit at the key's own column.
    struct ListItems {
        struct Item {
            /// The item's first key, on its `-` line, or a `{ ... }` map as the value of a key named `fallbacks`.
            let key: Document.Key
            /// The text after `- `.
            let content: Substring
            /// Column of the item's keys.
            let column: Int
            /// The lines after the `-` line, up to the next item.
            let body: Range<Int>

            var isFlow: Bool { content.first == "{" }

            /// The item's lines, from its `-` line to its last structural line.
            func lines(in document: Document) -> ClosedRange<Int> {
                key.index...(document.lastStructural(in: body) ?? key.index)
            }
        }

        let items: [Item]
        /// Column of the `-` lines, or nil for an empty list.
        let indent: Int?
        /// The list's last structural line, or nil for an empty list.
        let last: Int?
    }

    static func listItems(of key: Document.Key, in document: Document) throws -> ListItems {
        func isDash(_ index: Int, _ indent: Int) -> Bool {
            let content = document.lines[index].dropFirst(indent)
            return content == "-" || content.hasPrefix("- ")
        }
        var structure: [Int] = []
        var listIndent: Int?
        for index in (key.index + 1)..<document.lines.count {
            guard let indent = document.indent(at: index) else { continue }
            let column = listIndent ?? indent
            if listIndent == nil {
                guard indent > key.indent || (indent == key.indent && isDash(index, indent)) else { break }
                guard isDash(index, indent) else { throw key.unsupported(notAList) }
                listIndent = indent
            }
            guard indent > column || (indent == column && isDash(index, indent)) else { break }
            structure.append(index)
        }
        guard let dashIndent = listIndent, let last = structure.last else { return ListItems(items: [], indent: nil, last: nil) }
        let dashes = structure.filter { document.indent(at: $0) == dashIndent }
        let items = try dashes.enumerated().map { position, dash -> ListItems.Item in
            let body = (dash + 1)..<(position + 1 < dashes.count ? dashes[position + 1] : last + 1)
            let afterDash = document.lines[dash].dropFirst(dashIndent + 1)
            let spaces = afterDash.prefix { $0 == " " }.count
            let content = afterDash.dropFirst(spaces)
            let column = dashIndent + 1 + spaces
            if content.first == "{" {
                return ListItems.Item(
                    key: Document.Key(name: fallbacksKey, index: dash, indent: column, rest: " " + String(content)),
                    content: content, column: column, body: body
                )
            }
            guard spaces > 0, let colon = content.firstIndex(of: ":"), !content.hasPrefix("#") else {
                throw key.unsupported(notAFallback, line: dash)
            }
            return ListItems.Item(
                key: Document.Key(name: String(content[..<colon]), index: dash, indent: column, rest: String(content[content.index(after: colon)...])),
                content: content, column: column, body: body
            )
        }
        return ListItems(items: items, indent: dashIndent, last: last)
    }

    private static let notAList = "`fallbacks` should be a list of `- { ... }` alternatives"

    private static var notAFallback: String {
        "each fallback should be a map with any of: \(RunFallback.fields.map(\.rawValue).joined(separator: ", "))"
    }

    /// The profiles of the top-level `runs` block and of every repository, and `execution.harnesses`.
    public static func scopedProfiles(in yaml: String) throws -> ScopedRunProfiles {
        var profiles = ScopedRunProfiles(global: try self.profiles(in: yaml), harnesses: try harnesses(in: yaml))
        for key in try repositoryKeys(in: yaml) {
            profiles.repositories[key] = try self.profiles(in: yaml, scope: .repository(key))
        }
        return profiles
    }

    /// `execution.harnesses`: each harness that sets a command or a small model.
    public static func harnesses(in yaml: String) throws -> [Harness: HarnessSettings] {
        let document = Document(yaml)
        var harnesses: [Harness: HarnessSettings] = [:]
        for harness in Harness.allCases {
            var settings = HarnessSettings(command: try scalar(at: commandPath(harness), in: document))
            for provider in harness.providers {
                settings.smallModels[provider] = try scalar(at: smallModelPath(harness, provider), in: document)
            }
            if settings != HarnessSettings() { harnesses[harness] = settings }
        }
        return harnesses
    }

    /// The keys of the `repositories[]` entries, in file order.
    public static func repositoryKeys(in yaml: String) throws -> [String] {
        try repositoryItems(in: Document(yaml)).map(\.key)
    }

    public static func commandPath(_ harness: Harness) -> [String] {
        harnessesPath + [harness.rawValue, commandKey]
    }

    public static func smallModelPath(_ harness: Harness, _ provider: String) -> [String] {
        harnessesPath + [harness.rawValue, smallModelKey, provider]
    }

    /// The run kind an entry name stands for: `.some(nil)` for `default`, nil for a name that is no entry.
    private static func kind(named name: String) -> RunKind?? {
        name == defaultEntry ? .some(nil) : RunKind(rawValue: name).map(Optional.some)
    }

    private static func notAnEntry(_ name: String) -> String {
        "`\(name)` should hold any of: \(fieldOrder.joined(separator: ", "))"
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

    /// The value of a direct child `name:` of the range.
    private static func scalar(_ name: String, in range: Range<Int>, of document: Document) throws -> String? {
        guard let key = document.child(name, in: range) else { return nil }
        try requireScalar(key, in: document)
        return try decodeScalar(InlineText(key).value, on: key)
    }

    /// The value at a key path from the top level, through indented blocks and `{ ... }` values, or nil when a
    /// key on the way is missing.
    private static func scalar(at path: [String], in document: Document) throws -> String? {
        var range = document.all
        for (depth, name) in path.enumerated() {
            guard let key = document.child(name, in: range) else { return nil }
            let inline = try InlineText(key)
            let rest = path[(depth + 1)...]
            guard !rest.isEmpty else {
                try requireScalar(key, in: document)
                return try decodeScalar(inline.value, on: key)
            }
            if inline.isFlowMap {
                return try scalar(at: rest, in: inline.flowMap(key), on: key)
            }
            try requireBlock(key, inline)
            range = document.children(of: key)
        }
        return nil
    }

    private static func scalar(at path: ArraySlice<String>, in entries: [FlowEntry], on key: Document.Key) throws -> String? {
        guard let name = path.first, let entry = entries.first(where: { $0.key == name }) else { return nil }
        switch (entry.value, path.count) {
        case (.text(let raw), 1):
            return try decodeScalar(Substring(raw), on: key)
        case (.map(let nested), 2...):
            return try scalar(at: path.dropFirst(), in: nested, on: key)
        case (.text(let raw), _):
            guard try decodeScalar(Substring(raw), on: key) == nil else { throw key.unsupported("`\(name)` should hold keys") }
            return nil
        case (.map, _):
            throw key.unsupported("`\(name)` should be a single value")
        }
    }

    // MARK: Writing

    /// The same text with every field that differs between `old` and `new` written, and nothing else.
    public static func updating(_ yaml: String, from old: RunProfiles, to new: RunProfiles) throws -> String {
        try updating(yaml, from: ScopedRunProfiles(global: old), to: ScopedRunProfiles(global: new))
    }

    /// `updating(_:from:to:)` for the top-level `runs` block, every repository's, and `execution.harnesses`.
    public static func updating(_ yaml: String, from old: ScopedRunProfiles, to new: ScopedRunProfiles) throws -> String {
        guard old != new else { return yaml }
        var text = yaml
        let scopes = [RunProfilesScope.global] + Set(old.repositories.keys).union(new.repositories.keys).sorted().map(RunProfilesScope.repository)
        for scope in scopes {
            for kind in self.scopes {
                for field in RunProfileField.allCases where old[scope][kind][field] != new[scope][kind][field] {
                    text = try setting(field, of: kind, to: new[scope][kind][field], in: text, scope: scope)
                }
                if old[scope].fallbacks(of: kind) != new[scope].fallbacks(of: kind) {
                    text = try settingFallbacks(new[scope].fallbacks(of: kind), of: kind, in: text, scope: scope)
                }
            }
        }
        for harness in Harness.allCases {
            if old[harness].command != new[harness].command {
                text = try settingCommand(new[harness].command, of: harness, in: text)
            }
            for provider in harness.providers where old[harness].smallModels[provider] != new[harness].smallModels[provider] {
                text = try settingSmallModel(new[harness].smallModels[provider], of: harness, on: provider, in: text)
            }
        }
        return text
    }

    /// The same text with `execution.harnesses.<harness>.command` set, inserting it and any missing parent, or
    /// removed for nil along with a parent it left empty.
    public static func settingCommand(_ value: String?, of harness: Harness, in yaml: String) throws -> String {
        try setting(at: commandPath(harness), to: value, in: yaml)
    }

    /// The same text with `execution.harnesses.<harness>.small_model.<provider>` set, inserting it and any
    /// missing parent, or removed for nil along with a parent it left empty.
    public static func settingSmallModel(_ value: String?, of harness: Harness, on provider: String, in yaml: String) throws -> String {
        try setting(at: smallModelPath(harness, provider), to: value, in: yaml)
    }

    /// Sets the scalar at a key path from the top level, through indented blocks and `{ ... }` values. Missing
    /// keys are inserted as indented blocks at the end of their parent's; a nil value removes the key, then
    /// each parent it left empty.
    private static func setting(at path: [String], to value: String?, in yaml: String) throws -> String {
        var document = Document(yaml)
        let rendered = value.map(RepositoriesConfig.scalar)
        var range = document.all
        var parents: [Document.Key] = []
        var step = defaultIndentStep

        for (depth, name) in path.enumerated() {
            guard let key = document.child(name, in: range) else {
                guard let rendered else { return yaml }
                let column = document.childIndent(in: range) ?? parents.last.map { $0.indent + step } ?? 0
                let missing = Array(path[depth...])
                let lines = missing.enumerated().map { offset, name in
                    let line = String(repeating: " ", count: column + offset * step) + name + ":"
                    return offset == missing.count - 1 ? line + " " + rendered : line
                }
                guard let parent = parents.last else {
                    document.append(lines)
                    return document.text
                }
                let last = document.lastStructural(in: range) ?? parent.index
                document.lines.insert(contentsOf: lines, at: document.blockEnd(last, deeperThan: column) + 1)
                return document.text
            }
            let inline = try InlineText(key)
            let rest = path[(depth + 1)...]

            if rest.isEmpty {
                try set(name, to: rendered, under: parents.last, column: key.indent, order: [], in: &document)
            } else if inline.isFlowMap {
                var entries = try inline.flowMap(key)
                guard try set(rest, to: rendered, in: &entries, on: key) else { return yaml }
                if entries.isEmpty {
                    document.lines.remove(at: key.index)
                } else {
                    document.lines[key.index] = inline.replacingValue(in: key, with: renderFlow(entries, padded: inline.isPadded))
                }
            } else {
                try requireBlock(key, inline)
                range = document.children(of: key)
                if let childIndent = document.childIndent(in: range) { step = childIndent - key.indent }
                parents.append(key)
                continue
            }
            for parent in parents.reversed() where document.childIndent(in: document.children(of: parent)) == nil {
                document.lines.remove(at: parent.index)
            }
            return document.text
        }
        return document.text
    }

    /// The same text with one field set: `runs.<kind>.<field>`, with `default` for a nil kind, or the same
    /// keys under `repositories[<key>].runs` for a repository `scope`. Rewrites only that value, keeping a
    /// trailing comment, or inserts the key and any missing parent. A nil value removes the key, then an entry
    /// or `runs:` it left empty.
    public static func setting(
        _ field: RunProfileField,
        of kind: RunKind?,
        to value: String?,
        in yaml: String,
        scope: RunProfilesScope = .global
    ) throws -> String {
        let value = EntryValue(name: field.rawValue, inline: value.map(RepositoriesConfig.scalar), items: nil)
        return try setting(value, of: kind, in: yaml, scope: scope)
    }

    /// The same text with the entry's `fallbacks` list replaced by `list`, or removed for nil or an empty list,
    /// then an entry or `runs:` it left empty. The list's own lines are written again; nothing else changes.
    public static func settingFallbacks(
        _ list: [RunFallback]?,
        of kind: RunKind?,
        in yaml: String,
        scope: RunProfilesScope = .global
    ) throws -> String {
        let items = (list ?? []).map(renderFallback)
        let value = EntryValue(name: fallbacksKey, inline: items.isEmpty ? nil : "[" + items.joined(separator: ", ") + "]", items: items)
        return try setting(value, of: kind, in: yaml, scope: scope)
    }

    /// A fallback as a `{ ... }` map, its keys in field order.
    static func renderFallback(_ fallback: RunFallback) -> String {
        let entries = RunFallback.fields.compactMap { field in
            fallback[field].map { FlowEntry(key: field.rawValue, value: .text(RepositoriesConfig.scalar($0))) }
        }
        return renderFlow(entries, padded: true)
    }

    private static func setting(_ value: EntryValue, of kind: RunKind?, in yaml: String, scope: RunProfilesScope) throws -> String {
        var document = Document(yaml)
        let rendered = value.inline
        let name = entryName(kind)
        var step = defaultIndentStep
        let blocks: Bool
        if case .repository = scope { blocks = true } else { blocks = false }
        // New entries of a repository are written as indented blocks: `RepositoriesConfig` reads no `{ ... }`.
        var item: RepositoryItem?
        if case .repository(let key) = scope {
            item = try repositoryItem(key, in: document)
            step = item?.step ?? step
        }

        guard let runs = try runsKey(in: document, scope: scope) else {
            guard rendered != nil else { return yaml }
            guard let item else {
                document.append([runsSection + ":"] + entryLines(name, value, column: step, step: step, blocks: blocks))
                return document.text
            }
            let pad = String(repeating: " ", count: item.column)
            document.lines.insert(
                contentsOf: [pad + runsSection + ":"] + entryLines(name, value, column: item.column + step, step: step, blocks: blocks),
                at: item.insertionIndex(in: document)
            )
            return document.text
        }
        let inline = try InlineText(runs)

        if inline.isFlowMap {
            var entries = try inline.flowMap(runs)
            if entries.isEmpty {
                // `runs: {}` turns into a block holding the new entry.
                guard rendered != nil else { return yaml }
                document.lines[runs.index] = inline.replacingValue(in: runs, with: "")
                document.lines.insert(
                    contentsOf: entryLines(name, value, column: runs.indent + step, step: step, blocks: blocks),
                    at: runs.index + 1
                )
                return document.text
            }
            guard try set([name, value.name], to: rendered, in: &entries, on: runs) else { return yaml }
            if entries.isEmpty {
                document.lines.remove(at: runs.index)
            } else {
                document.lines[runs.index] = inline.replacingValue(in: runs, with: renderFlow(entries, padded: inline.isPadded))
            }
            return document.text
        }

        try requireBlock(runs, inline)
        let runsRange = document.children(of: runs)
        let entryColumn = document.childIndent(in: runsRange) ?? runs.indent + step
        let runsStep = entryColumn - runs.indent

        guard let entry = document.child(name, in: runsRange) else {
            guard rendered != nil else { return yaml }
            // `default` leads the block; a run kind goes after the last entry.
            var index = runs.index + 1
            if kind != nil, let last = document.lastStructural(in: runsRange) {
                index = document.blockEnd(last, deeperThan: entryColumn) + 1
            }
            document.lines.insert(
                contentsOf: entryLines(name, value, column: entryColumn, step: runsStep, blocks: blocks),
                at: index
            )
            return document.text
        }
        let entryInline = try InlineText(entry)

        if entryInline.isFlowMap {
            var fields = try entryInline.flowMap(entry)
            guard try set([value.name], to: rendered, in: &fields, on: entry) else { return yaml }
            if fields.isEmpty {
                document.lines.remove(at: entry.index)
            } else {
                document.lines[entry.index] = entryInline.replacingValue(in: entry, with: renderFlow(fields, padded: entryInline.isPadded))
            }
        } else {
            try requireBlock(entry, entryInline)
            let fieldColumn = document.childIndent(in: document.children(of: entry)) ?? entry.indent + runsStep
            if value.items != nil {
                try setList(value, under: entry, column: fieldColumn, step: runsStep, in: &document)
            } else {
                try set(value.name, to: rendered, under: entry, column: fieldColumn, order: fieldOrder, in: &document)
            }
            if document.childIndent(in: document.children(of: entry)) == nil {
                document.lines.remove(at: entry.index)
            }
        }
        if document.childIndent(in: document.children(of: runs)) == nil {
            document.lines.remove(at: runs.index)
        }
        return document.text
    }

    /// Sets a list child of a block entry: rewrites an inline `[ ... ]` value in place, writes a block list's
    /// items again at their column, inserts a new list as a block after the entry's other keys, or removes the
    /// list for nil.
    private static func setList(
        _ value: EntryValue,
        under entry: Document.Key,
        column: Int,
        step: Int,
        in document: inout Document
    ) throws {
        let range = document.children(of: entry)
        guard let key = document.child(value.name, in: range) else {
            guard value.inline != nil else { return }
            let index = insertionIndex(for: value.name, in: range, order: fieldOrder + [value.name], after: entry, of: document)
            document.lines.insert(contentsOf: fieldLines(value, column: column, step: step), at: index)
            return
        }
        let inline = try InlineText(key)
        guard inline.isNull else {
            if let rendered = value.inline {
                document.lines[key.index] = inline.replacingValue(in: key, with: rendered)
            } else {
                document.lines.remove(at: key.index)
            }
            return
        }
        let list = try listItems(of: key, in: document)
        guard value.inline != nil, let items = value.items else {
            document.lines.removeSubrange(key.index...(list.last ?? key.index))
            return
        }
        // Item by item, from the end: new items go after the last one, extra ones go, and a changed one is
        // written again on one line, so comments between the items stay.
        let pad = String(repeating: " ", count: list.indent ?? key.indent + step)
        let old = list.items
        let end = old.last.map { $0.lines(in: document).upperBound } ?? key.index
        document.lines.insert(contentsOf: items.dropFirst(old.count).map { pad + "- " + $0 }, at: end + 1)
        for item in old.dropFirst(items.count).reversed() {
            document.lines.removeSubrange(item.lines(in: document))
        }
        for (item, rendered) in zip(old, items).reversed() {
            guard try renderFallback(fallback(of: item, in: document)) != rendered else { continue }
            var line = pad + "- " + rendered
            if item.isFlow, let tail = try? InlineText(item.key).tail, tail.contains("#") { line += tail }
            document.lines.replaceSubrange(item.lines(in: document), with: [line])
        }
        if !inline.value.isEmpty { document.lines[key.index] = inline.replacingValue(in: key, with: "") }
    }

    /// Sets the scalar child `name:` of `parent` (the top level for nil): rewrites its value, inserts it in
    /// `order`, or removes it for nil.
    private static func set(
        _ name: String,
        to rendered: String?,
        under parent: Document.Key?,
        column: Int,
        order: [String],
        in document: inout Document
    ) throws {
        let range = parent.map { document.children(of: $0) } ?? document.all
        guard let key = document.child(name, in: range) else {
            guard let rendered, let parent else { return }
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

    /// Sets the value at a key path in flow-map entries, adding the maps on the way and dropping the ones it
    /// leaves empty. A new run profile field goes in `fieldOrder`; any other new key goes last. Returns false
    /// when nothing changed.
    private static func set(
        _ path: ArraySlice<String>,
        to rendered: String?,
        in entries: inout [FlowEntry],
        on key: Document.Key
    ) throws -> Bool {
        guard let name = path.first else { return false }
        let index = entries.firstIndex { $0.key == name }
        guard path.count == 1 else {
            var nested: [FlowEntry] = []
            if let index {
                switch entries[index].value {
                case .map(let existing): nested = existing
                case .text(let raw):
                    guard try decodeScalar(Substring(raw), on: key) == nil else { throw key.unsupported("`\(name)` should hold keys") }
                }
            }
            guard try set(path.dropFirst(), to: rendered, in: &nested, on: key) else { return false }
            switch (index, nested.isEmpty) {
            case (let index?, true): entries.remove(at: index)
            case (let index?, false): entries[index].value = .map(nested)
            case (nil, true): return false
            case (nil, false): entries.append(FlowEntry(key: name, value: .map(nested)))
            }
            return true
        }
        switch (index, rendered) {
        case (nil, nil):
            return false
        case (let index?, nil):
            entries.remove(at: index)
        case (let index?, let rendered?):
            guard entries[index].value != .text(rendered) else { return false }
            entries[index].value = .text(rendered)
        case (nil, let rendered?):
            let later = fieldOrder.drop { $0 != name }.dropFirst()
            let position = entries.firstIndex { later.contains($0.key) } ?? entries.count
            entries.insert(FlowEntry(key: name, value: .text(rendered)), at: position)
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

    /// A value written under a `runs` entry: a field's scalar, or a list.
    struct EntryValue {
        let name: String
        /// The value as it goes on the key's line, in flow style; nil removes the key.
        let inline: String?
        /// A list's items in flow style, written one `- ` line each under a block entry.
        let items: [String]?
    }

    /// A new entry holding one value, at `column`: `name: { key: value }`, or `name:` with the value
    /// indented under it.
    private static func entryLines(_ name: String, _ value: EntryValue, column: Int, step: Int, blocks: Bool) -> [String] {
        let pad = String(repeating: " ", count: column)
        guard blocks else { return [pad + name + ": { " + value.name + ": " + (value.inline ?? "") + " }"] }
        return [pad + name + ":"] + fieldLines(value, column: column + step, step: step)
    }

    /// `key: value` at `column`, or for a list `key:` with its `- ` items indented under it.
    private static func fieldLines(_ value: EntryValue, column: Int, step: Int) -> [String] {
        let pad = String(repeating: " ", count: column)
        guard let items = value.items else { return [pad + value.name + ": " + (value.inline ?? "")] }
        return [pad + value.name + ":"] + items.map { pad + String(repeating: " ", count: step) + "- " + $0 }
    }

    // MARK: Checks

    /// The top-level `runs:` key, or a repository's `runs:` key, or nil when it's missing.
    private static func runsKey(in document: Document, scope: RunProfilesScope) throws -> Document.Key? {
        guard case .repository(let key) = scope else { return document.child(runsSection, in: document.all) }
        let item = try repositoryItem(key, in: document)
        if item.firstKey == runsSection {
            throw Document.Key(name: runsSection, index: item.dash, indent: item.column, rest: "").unsupported(
                "put `key:` first, not `runs:`, on the repository's `-` line"
            )
        }
        return document.child(runsSection, in: item.body, indent: item.column)
    }

    /// One `- key: ...` entry of `repositories:`.
    struct RepositoryItem {
        let key: String
        /// The `-` line, and the name of the key on it.
        let dash: Int
        let firstKey: String
        let dashIndent: Int
        /// Column of the entry's keys.
        let column: Int
        /// The lines after the `-` line, up to the next entry.
        let body: Range<Int>
        /// How far the entry indents nested keys.
        let step: Int

        /// Where a new key goes: after the entry's last line and the comments indented under it.
        func insertionIndex(in document: Document) -> Int {
            let last = document.lastStructural(in: body) ?? dash
            return document.blockEnd(last, deeperThan: dashIndent) + 1
        }
    }

    private static func repositoryItem(_ key: String, in document: Document) throws -> RepositoryItem {
        guard let item = try repositoryItems(in: document).first(where: { $0.key == key }) else {
            throw RunProfilesConfigError.repositoryNotFound(key)
        }
        return item
    }

    /// The entries of the top-level `repositories:` list, which may start at the section's own column.
    static func repositoryItems(in document: Document) throws -> [RepositoryItem] {
        guard let section = document.child("repositories", in: document.all) else { return [] }
        guard try InlineText(section).isNull else { throw section.unsupported("`repositories:` should hold `- key: ...` entries") }
        func isDash(_ index: Int, _ indent: Int) -> Bool {
            let content = document.lines[index].dropFirst(indent)
            return content == "-" || content.hasPrefix("- ")
        }

        var structure: [Int] = []
        for index in (section.index + 1)..<document.lines.count {
            guard let indent = document.indent(at: index) else { continue }
            if indent < section.indent || (indent == section.indent && !isDash(index, indent)) { break }
            structure.append(index)
        }
        guard let first = structure.first, let end = structure.last.map({ $0 + 1 }) else { return [] }
        let dashIndent = document.indent(at: first) ?? 0
        let dashes = structure.filter { document.indent(at: $0) == dashIndent }
        if let stray = dashes.first(where: { !isDash($0, dashIndent) }) {
            throw section.unsupported("`repositories:` should hold `- key: ...` entries", line: stray)
        }

        return try dashes.enumerated().map { position, dash in
            let body = (dash + 1)..<(position + 1 < dashes.count ? dashes[position + 1] : end)
            let afterDash = document.lines[dash].dropFirst(dashIndent + 1)
            let spaces = afterDash.prefix { $0 == " " }.count
            let content = afterDash.dropFirst(spaces)
            guard spaces > 0, let colon = content.firstIndex(of: ":"), !content.hasPrefix("#") else {
                throw section.unsupported("put each repository's first key on its `-` line", line: dash)
            }
            let column = dashIndent + 1 + spaces
            let firstKey = String(content[..<colon])
            let keyLine = firstKey == "key"
                ? Document.Key(name: "key", index: dash, indent: column, rest: String(content[content.index(after: colon)...]))
                : document.child("key", in: body, indent: column)
            guard let keyLine, let key = try decodeScalar(InlineText(keyLine).value, on: keyLine), !key.isEmpty else {
                throw section.unsupported("a repository has no `key`", line: dash)
            }
            let nested = body.lazy.compactMap { document.indent(at: $0) }.first { $0 > column }
            return RepositoryItem(
                key: key, dash: dash, firstKey: firstKey, dashIndent: dashIndent, column: column, body: body,
                step: nested.map { $0 - column } ?? defaultIndentStep
            )
        }
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

    /// Writes the fields that differ between `old` and `new`. Leaves the file untouched when none do.
    public func writeRunProfiles(_ new: RunProfiles, from old: RunProfiles) throws {
        try rewrite { try RunProfilesConfig.updating($0, from: old, to: new) }
    }

    /// The profiles of the top-level `runs` block and of every repository, and `execution.harnesses`.
    public func readScopedRunProfiles() throws -> ScopedRunProfiles {
        try RunProfilesConfig.scopedProfiles(in: read())
    }

    /// Writes the fields that differ between `old` and `new` once `check` passes on the result; see
    /// `rewrite(_:checkingWith:)`.
    public func writeRunProfiles(
        _ new: ScopedRunProfiles,
        from old: ScopedRunProfiles,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try RunProfilesConfig.updating($0, from: old, to: new) }, checkingWith: check)
    }
}

// MARK: - Inline values

extension Document.Key {
    /// An error on this key's line, or on `line` (counted from 0) when given.
    fileprivate func unsupported(_ reason: String, line: Int? = nil) -> RunProfilesConfigError {
        .unsupported(line: (line ?? index) + 1, reason: reason)
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

    /// The items of a `[ ... ]` list: maps, or other values as written.
    mutating func list() throws -> [FlowValue] {
        advance()
        var items: [FlowValue] = []
        skipSpace()
        if current == "]" {
            advance()
            return items
        }
        while true {
            skipSpace()
            switch current {
            case "{"?:
                items.append(.map(try map()))
            case "\""?, "'"?, "["?:
                let start = index
                try skipValue()
                items.append(.text(String(text[start..<index])))
            default:
                let start = index
                while let character = current, character != ",", character != "]" { advance() }
                items.append(.text(text[start..<index].trimmingCharacters(in: .whitespaces)))
            }
            skipSpace()
            switch current {
            case ","?:
                advance()
            case "]"?:
                advance()
                return items
            default:
                throw error("a `[` list has no closing `]`")
            }
        }
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

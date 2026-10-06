import Foundation

/// Why the model and effort keys of a `symphony.yml` can't be read or changed.
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

/// A field of a run profile, named as its YAML key, in the order new ones are written.
public enum RunProfileField: String, CaseIterable {
    case provider, model, effort

    /// The fields `agent.command` can pass as `--model` / `--effort`.
    static let commandFlags: [RunProfileField] = [.model, .effort]
}

/// The provider, model and effort for one kind of run, or the defaults. A nil field is missing from the file.
public struct RunProfile: Equatable {
    public var model: String?
    public var effort: String?
    public var provider: String?

    public init(model: String? = nil, effort: String? = nil, provider: String? = nil) {
        self.model = model
        self.effort = effort
        self.provider = provider
    }

    public subscript(field: RunProfileField) -> String? {
        get {
            switch field {
            case .provider: return provider
            case .model: return model
            case .effort: return effort
            }
        }
        set {
            switch field {
            case .provider: provider = newValue
            case .model: model = newValue
            case .effort: effort = newValue
            }
        }
    }

    /// Each field of this profile, or of `fallback` where this one is unset.
    public func merged(over fallback: RunProfile) -> RunProfile {
        RunProfile(model: model ?? fallback.model, effort: effort ?? fallback.effort, provider: provider ?? fallback.provider)
    }

    /// Whether a model or effort is set, which Symphony passes as `--model` / `--effort`. A provider alone isn't.
    var setsModelOrEffort: Bool { model != nil || effort != nil }
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

    /// Whether Symphony passes a model or effort to every run from these profiles, so it rejects
    /// `--model` / `--effort` in `agent.command`.
    var setsCommandFlags: Bool { defaults.setsModelOrEffort || !kinds.isEmpty }

    /// Whether these profiles give `kind` a model or effort, or a profile of its own.
    func setsCommandFlags(for kind: RunKind) -> Bool { defaults.setsModelOrEffort || kinds[kind] != nil }
}

/// Which `agent` block of a `symphony.yml` the profiles are in: the top-level one, or a `repositories[]`
/// entry's.
public enum RunProfilesScope: Hashable {
    case global
    case repository(String)
}

/// The profiles of the top-level `agent` block and of each repository's `agent` block, keyed by
/// repository key. A repository without a block holds empty profiles. `smallModel` is `agent.small_model`, the
/// OpenRouter model for Claude Code's background calls on OpenRouter runs; nil leaves them on the run's model.
public struct ScopedRunProfiles: Equatable {
    public var global: RunProfiles
    public var repositories: [String: RunProfiles]
    public var smallModel: String?

    public init(global: RunProfiles = RunProfiles(), repositories: [String: RunProfiles] = [:], smallModel: String? = nil) {
        self.global = global
        self.repositories = repositories
        self.smallModel = smallModel
    }

    /// Whether any row in any scope picks OpenRouter, so `smallModel` has runs to serve.
    public var usesOpenRouter: Bool {
        ([global] + repositories.values).contains { profiles in
            ([profiles.defaults] + profiles.kinds.values).contains { $0.provider == RunProfilesConfig.openRouter }
        }
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

    /// What the row for `kind` (nil for the Default row) in `scope` resolves to where it sets nothing, the way
    /// Symphony resolves each field: the repository's kind, the repository's defaults, `agent.run_profiles`'s
    /// kind, `agent`'s defaults, then the flags in `agent.command` (`command`) and the `anthropic` provider.
    public func inherited(_ kind: RunKind?, in scope: RunProfilesScope, command: RunProfile) -> RunProfile {
        let base = RunProfile(model: command.model, effort: command.effort, provider: RunProfilesConfig.anthropic)
        let global = global.defaults.merged(over: base)
        switch (scope, kind) {
        case (.global, nil):
            return base
        case (.global, _?):
            return global
        case (.repository, nil):
            return global
        case (.repository, let kind?):
            return self[scope].defaults.merged(over: self.global[kind].merged(over: global))
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

    public static let anthropic = "anthropic"
    public static let openRouter = "openrouter"

    public static let providers = [
        RunProfileChoice(id: anthropic, title: "Anthropic"),
        RunProfileChoice(id: openRouter, title: "OpenRouter"),
    ]

    /// `choices`, plus `current` when the file holds a value they don't list.
    public static func choices(_ choices: [RunProfileChoice], including current: String?) -> [RunProfileChoice] {
        guard let current, !choices.contains(where: { $0.id == current }) else { return choices }
        return choices + [RunProfileChoice(id: current, title: current)]
    }

    /// The title of a picker's default entry: "default", or the value it falls back to and where from, as in
    /// "Opus 5.5, from command".
    public static func defaultTitle(_ choices: [RunProfileChoice], inherited: String?, source: String = "from command") -> String {
        guard let inherited else { return "default" }
        return (choices.first { $0.id == inherited }?.title ?? inherited) + ", " + source
    }

    /// Keys of `agent:` in the order new ones are written.
    static let agentOrder = ["runtime", "command", "provider", "model", "effort", smallModelKey, "run_profiles"]
    public static let smallModelKey = "small_model"
    static let fieldOrder = RunProfileField.allCases.map(\.rawValue)
    static let defaultIndentStep = 2

    // MARK: Reading

    /// The profiles of the top-level `agent` block, or of a repository's `agent` block for `scope`.
    public static func profiles(in yaml: String, scope: RunProfilesScope = .global) throws -> RunProfiles {
        let document = Document(yaml)
        guard let agent = try agentKey(in: document, scope: scope) else { return RunProfiles() }
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

    /// The profiles of the top-level `agent` block and of every repository, and `agent.small_model`.
    public static func scopedProfiles(in yaml: String) throws -> ScopedRunProfiles {
        var profiles = ScopedRunProfiles(global: try self.profiles(in: yaml), smallModel: try smallModel(in: yaml))
        for key in try repositoryKeys(in: yaml) {
            profiles.repositories[key] = try self.profiles(in: yaml, scope: .repository(key))
        }
        return profiles
    }

    /// `agent.small_model`, or nil when it's missing.
    public static func smallModel(in yaml: String) throws -> String? {
        let document = Document(yaml)
        guard let agent = try agentKey(in: document) else { return nil }
        return try scalar(smallModelKey, in: document.children(of: agent), of: document)
    }

    /// The keys of the `repositories[]` entries, in file order.
    public static func repositoryKeys(in yaml: String) throws -> [String] {
        try repositoryItems(in: Document(yaml)).map(\.key)
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
    /// `agent.effort` are unset. `section` reads another section's command, such as `pre_push_review`.
    public static func commandProfile(in yaml: String, section: String = "agent") throws -> RunProfile {
        let document = Document(yaml)
        guard let key = try commandKey(in: document, section: section),
              let command = try decodeScalar(InlineText(key).value, on: key) else { return RunProfile() }
        return splitCommandFlags(command).flags
    }

    /// The command without its `--model` / `--effort` flags (`--model x` or `--model=x`), and their values.
    /// Matches the flags Symphony rejects in `agent.command` once any model or effort is set.
    static func splitCommandFlags(_ command: String) -> (command: String, flags: RunProfile) {
        var rest = command
        var flags = RunProfile()
        for field in RunProfileField.commandFlags {
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
    /// `new` sets those itself. It rejects them in `pre_push_review.command` once a model or effort resolves
    /// for pre-push review. `pre_push_review.model` / `.effort` outrank the `pre_push_review` kind and name no
    /// provider, so a model there would also be checked against the provider the kind picks, such as
    /// OpenRouter. When the result sets a default or the `pre_push_review` kind, the section's keys, else
    /// its flags, move into `agent.run_profiles.pre_push_review`, the row Settings shows, for each field
    /// that row keeps from `old`; a moved model keeps the provider the kind had in `old`. A row whose model
    /// or provider changes drops the section's model, which names a model of the old provider.
    /// `auto_review` and the `qa` kind work the same way. Runs then use the same model, effort and provider
    /// as before, except where the rows change them or a repository's rows set them.
    public static func updating(_ yaml: String, from old: RunProfiles, to new: RunProfiles) throws -> String {
        try updating(yaml, from: ScopedRunProfiles(global: old), to: ScopedRunProfiles(global: new))
    }

    /// `updating(_:from:to:)` for the top-level `agent` block and every repository's. A repository's model,
    /// effort or `run_profiles` count like the top-level ones for moving the command flags, as Symphony
    /// rejects those flags in the commands either way.
    public static func updating(_ yaml: String, from old: ScopedRunProfiles, to new: ScopedRunProfiles) throws -> String {
        guard old != new else { return yaml }
        var text = yaml
        var new = new
        let flags = try commandProfile(in: yaml)
        if flags != RunProfile() && ([new.global] + new.repositories.values).contains(where: \.setsCommandFlags) {
            for field in RunProfileField.commandFlags where new.global.defaults[field] == nil {
                new.global.defaults[field] = flags[field]
            }
            text = try removingCommandFlags(in: text)
        }
        // After the move, as `agent.model` / `.effort` set from the flags count too.
        let all = [new.global] + new.repositories.values
        for (section, kind) in [(prePushReview, RunKind.prePushReview), (autoReview, .qa)] {
            let moving = try sectionProfile(in: yaml, section: section)
            guard moving != RunProfile() && all.contains(where: { $0.setsCommandFlags(for: kind) }) else { continue }
            let kept = old.global[kind]
            var row = new.global[kind]
            if let model = moving.model, row.model == kept.model, row.provider == kept.provider {
                row.model = model
                let previous = provider(of: kind, in: old.global)
                if row.provider == nil && provider(of: kind, in: new.global) != previous { row.provider = previous }
            }
            if let effort = moving.effort, row.effort == kept.effort { row.effort = effort }
            new.global[kind] = row
            text = try removingCommandFlags(in: text, section: section)
            text = try removingSectionKeys(section, in: text)
        }
        let scopes = [RunProfilesScope.global] + Set(old.repositories.keys).union(new.repositories.keys).sorted().map(RunProfilesScope.repository)
        for scope in scopes {
            for kind in self.scopes {
                for field in RunProfileField.allCases where old[scope][kind][field] != new[scope][kind][field] {
                    text = try setting(field, of: kind, to: new[scope][kind][field], in: text, scope: scope)
                }
            }
        }
        if old.smallModel != new.smallModel {
            text = try settingSmallModel(new.smallModel, in: text)
        }
        return text
    }

    /// The same text with `agent.small_model` set, inserting it and any missing `agent:`, or removed for nil.
    public static func settingSmallModel(_ value: String?, in yaml: String) throws -> String {
        var document = Document(yaml)
        let rendered = value.map(RepositoriesConfig.scalar)
        guard let agent = try agentKey(in: document) else {
            guard let rendered else { return yaml }
            document.append(["agent:", String(repeating: " ", count: defaultIndentStep) + smallModelKey + ": " + rendered])
            return document.text
        }
        let column = document.childIndent(in: document.children(of: agent)) ?? agent.indent + defaultIndentStep
        try set(smallModelKey, to: rendered, under: agent, column: column, order: agentOrder, in: &document)
        return document.text
    }

    /// The same text with one field set: `agent.<field>` for a nil kind, else
    /// `agent.run_profiles.<kind>.<field>`, or the same keys under `repositories[<key>].agent` for a
    /// repository `scope`. Rewrites only that value, keeping a trailing comment, or inserts the key and any
    /// missing parent. A nil value removes the key, then a kind, `run_profiles:` or repository `agent:` it
    /// left empty (Symphony rejects an empty one).
    public static func setting(
        _ field: RunProfileField,
        of kind: RunKind?,
        to value: String?,
        in yaml: String,
        scope: RunProfilesScope = .global
    ) throws -> String {
        let text = try settingField(field, of: kind, to: value, in: yaml, scope: scope)
        guard value == nil, case .repository = scope else { return text }
        var document = Document(text)
        guard let agent = try agentKey(in: document, scope: scope),
              document.childIndent(in: document.children(of: agent)) == nil else { return text }
        document.lines.remove(at: agent.index)
        return document.text
    }

    private static func settingField(
        _ field: RunProfileField,
        of kind: RunKind?,
        to value: String?,
        in yaml: String,
        scope: RunProfilesScope
    ) throws -> String {
        var document = Document(yaml)
        let rendered = value.map(RepositoriesConfig.scalar)
        var step = defaultIndentStep
        // New kinds of a repository are written as indented blocks, which `RepositoriesConfig` can read.
        var item: RepositoryItem?
        if case .repository(let key) = scope {
            item = try repositoryItem(key, in: document)
            step = item?.step ?? step
        }

        guard let agent = try agentKey(in: document, scope: scope) else {
            guard let rendered else { return yaml }
            guard let item else {
                let pad = String(repeating: " ", count: step)
                if let kind {
                    document.append(["agent:", pad + "run_profiles:", pad + pad + flowLine(kind, field, rendered)])
                } else {
                    document.append(["agent:", pad + field.rawValue + ": " + rendered])
                }
                return document.text
            }
            let pad = String(repeating: " ", count: item.column)
            var lines = [pad + "agent:"]
            if let kind {
                lines.append(pad + String(repeating: " ", count: step) + "run_profiles:")
                lines += kindLines(kind, field, rendered, column: item.column + 2 * step, step: step, blocks: true)
            } else {
                lines.append(pad + String(repeating: " ", count: step) + field.rawValue + ": " + rendered)
            }
            document.lines.insert(contentsOf: lines, at: item.insertionIndex(in: document))
            return document.text
        }
        let agentRange = document.children(of: agent)
        let column = document.childIndent(in: agentRange) ?? agent.indent + step
        let agentStep = column - agent.indent
        let preferBlocks = item != nil

        guard let kind else {
            try set(field.rawValue, to: rendered, under: agent, column: column, order: agentOrder, in: &document)
            return document.text
        }

        guard let runProfiles = document.child("run_profiles", in: agentRange) else {
            guard let rendered else { return yaml }
            let index = insertionIndex(for: "run_profiles", in: agentRange, order: agentOrder, after: agent, of: document)
            let pad = String(repeating: " ", count: column)
            document.lines.insert(
                contentsOf: [pad + "run_profiles:"]
                    + kindLines(kind, field, rendered, column: column + agentStep, step: agentStep, blocks: preferBlocks),
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
                document.lines.insert(
                    contentsOf: kindLines(kind, field, rendered, column: runProfiles.indent + agentStep, step: agentStep, blocks: preferBlocks),
                    at: runProfiles.index + 1
                )
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
            let blocks = try document.childIndent(in: profilesRange) == nil ? preferBlocks : siblingsUseBlocks(in: profilesRange, of: document)
            document.lines.insert(
                contentsOf: kindLines(kind, field, rendered, column: kindColumn, step: agentStep, blocks: blocks),
                at: index
            )
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

    static let prePushReview = "pre_push_review"
    static let autoReview = "auto_review"

    /// The model and effort `<section>` gives its runs: its `model` / `effort` keys, else the `--model` /
    /// `--effort` in its command. A `<section>: { ... }` line only matters, and so only fails, when its command
    /// passes one of them; its keys stay where they are.
    private static func sectionProfile(in yaml: String, section name: String) throws -> RunProfile {
        let flags = try commandFlags(in: yaml, section: name)
        let document = Document(yaml)
        guard let section = document.child(name, in: document.all), try InlineText(section).isNull else { return flags }
        let range = document.children(of: section)
        let keys = RunProfile(
            model: try scalar("model", in: range, of: document),
            effort: try scalar("effort", in: range, of: document)
        )
        return keys.merged(over: flags)
    }

    /// The `--model` / `--effort` in `<section>.command`. A `<section>: { ... }` line only matters, and so
    /// only fails, when its command passes one of them.
    private static func commandFlags(in yaml: String, section name: String) throws -> RunProfile {
        let document = Document(yaml)
        if let section = document.child(name, in: document.all), try InlineText(section).isFlowMap {
            let command = try InlineText(section).flowMap(section).first { $0.key == "command" }
            guard case .text(let raw)? = command?.value,
                  let value = try decodeScalar(Substring(raw), on: section),
                  splitCommandFlags(value).flags != RunProfile() else { return RunProfile() }
            throw section.unsupported("`\(name):` should be an indented block")
        }
        return try commandProfile(in: yaml, section: name)
    }

    /// The text with `--model` / `--effort` taken out of `<section>.command`, keeping the rest of the line,
    /// its quoting and any trailing comment.
    private static func removingCommandFlags(in yaml: String, section: String = "agent") throws -> String {
        var document = Document(yaml)
        guard let key = try commandKey(in: document, section: section) else { return yaml }
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

    /// The text without `<name>.model` / `.effort`.
    private static func removingSectionKeys(_ name: String, in yaml: String) throws -> String {
        var document = Document(yaml)
        guard let section = try sectionKey(name, in: document) else { return yaml }
        for field in RunProfileField.commandFlags {
            try set(field.rawValue, to: nil, under: section, column: 0, order: [], in: &document)
        }
        return document.text
    }

    /// The provider runs of `kind` get from the top-level `agent` block.
    private static func provider(of kind: RunKind, in profiles: RunProfiles) -> String {
        profiles[kind].provider ?? profiles.defaults.provider ?? anthropic
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
            // Provider, then model, then effort.
            let later = RunProfileField.allCases.drop { $0 != field }.dropFirst().map(\.rawValue)
            let position = entries.firstIndex { later.contains($0.key) } ?? entries.count
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

    /// A new kind holding one field, at `column`: `kind: { field: value }`, or `kind:` with the field
    /// indented under it.
    private static func kindLines(
        _ kind: RunKind,
        _ field: RunProfileField,
        _ rendered: String,
        column: Int,
        step: Int,
        blocks: Bool
    ) -> [String] {
        let pad = String(repeating: " ", count: column)
        guard blocks else { return [pad + flowLine(kind, field, rendered)] }
        return [pad + kind.rawValue + ":", pad + String(repeating: " ", count: step) + field.rawValue + ": " + rendered]
    }

    // MARK: Checks

    /// The top-level `agent:` key, or a repository's `agent:` key, or nil when it's missing.
    private static func agentKey(in document: Document, scope: RunProfilesScope = .global) throws -> Document.Key? {
        guard case .repository(let key) = scope else { return try sectionKey("agent", in: document) }
        let item = try repositoryItem(key, in: document)
        if item.firstKey == "agent" {
            throw Document.Key(name: "agent", index: item.dash, indent: item.column, rest: "").unsupported(
                "put `key:` first, not `agent:`, on the repository's `-` line"
            )
        }
        guard let agent = document.child("agent", in: item.body, indent: item.column) else { return nil }
        try requireBlock(agent, InlineText(agent))
        return agent
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

    /// The top-level `name:` key, or nil when it's missing.
    private static func sectionKey(_ name: String, in document: Document) throws -> Document.Key? {
        guard let section = document.child(name, in: document.all) else { return nil }
        try requireBlock(section, InlineText(section))
        return section
    }

    /// `<section>.command`, or nil when it's missing.
    private static func commandKey(in document: Document, section: String) throws -> Document.Key? {
        guard let parent = try sectionKey(section, in: document),
              let key = document.child("command", in: document.children(of: parent)) else { return nil }
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

    /// The profiles of the top-level `agent` block and of every repository.
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

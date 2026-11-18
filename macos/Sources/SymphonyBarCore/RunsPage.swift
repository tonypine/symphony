import Foundation

/// Factory › Runs (TP-1538), as the catalog draws it (`runsPage` in `docs/design/catalog/stories.js`): Default and the
/// nine kinds of run, each always open, with one line per choice, the first choice then each fallback in the order
/// Symphony tries them. Each line has Harness, Provider, Model and Effort. A value the kind takes from Default is
/// drawn grey, one it sets itself dark. Nothing is applied until Save; the Save bar counts the changes and has Revert.
/// The edits are `RunsEditor`'s (TP-1537); this is what the page shows of it and the page's own steps around it.
public struct RunsPage: Equatable {
    /// Where the page's Save stands.
    public enum Save: Equatable {
        /// Editing: the bar counts the changes not saved.
        case editing
        /// `symphony check` and the write are under way.
        case saving
        /// Just saved: the bar says "Saved" until the next edit or until the page takes it away.
        case saved
        /// The save was refused: why; every change stays.
        case refused(String)
    }

    /// A choice of a pop-up: a value, or nil for none set ("None").
    public struct Choice: Equatable, Hashable {
        public let value: String?
        public let title: String

        public init(_ value: String?, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    /// One pop-up of a line: what it's called, the value it shows and whether the kind sets it itself, and its choices.
    public struct Field: Equatable {
        public let field: RunProfileField
        public let label: String
        public let value: String?
        public let title: String
        public let isOwn: Bool
        public let choices: [Choice]

        /// The model is picked from a searchable list, in the mono face, as identifiers are.
        public var isSearchable: Bool { field == .model }
    }

    /// One line of a kind: its place (0 for the first choice), its four pop-ups and whether it can be removed.
    public struct Line: Equatable, Identifiable {
        public let id: Int
        public let fields: [Field]
        public let removable: Bool

        /// The remove button's help.
        public var removeHelp: String { Self.removeHelp(id) }

        /// "Remove; the next one becomes the first choice" on the first line, "Remove this fallback" on the others.
        public static func removeHelp(_ place: Int) -> String {
            place == 0 ? "Remove; the next one becomes the first choice" : "Remove this fallback"
        }
    }

    /// One kind of run, or Default: its name, its lines, whether "Use Default's" has something to clear, and the line
    /// under a kind with no fallback.
    public struct Row: Equatable, Identifiable {
        public let kind: RunKind?
        public let title: String
        public let lines: [Line]
        public let canUseDefaults: Bool
        public let waits: String?

        public var id: String { kind?.rawValue ?? RunsPage.defaultID }
        public var isDefault: Bool { kind == nil }
    }

    /// A choice of the For pop-up.
    public struct ScopeChoice: Equatable {
        public let scope: RunProfilesScope
        public let title: String
    }

    /// The editor once the file is read; nil while it is read, or when it couldn't be.
    public private(set) var editor: RunsEditor?
    /// Why the file couldn't be read.
    public private(set) var loadError: String?
    /// The keys of the repositories, in file order: the For pop-up's choices after All repositories.
    public private(set) var repositories: [String] = []
    /// All repositories, or the one whose own values the page shows.
    public private(set) var scope: RunProfilesScope = .global
    /// The models each provider offers, and whether the page asked for them yet.
    public var lists = RunModelLists()
    public var listsRequested = false
    public private(set) var save: Save = .editing

    public init() {}

    static let defaultID = "default"
    public static let useDefaults = "Use Default’s"
    public static let addFallback = "Add a Fallback"
    public static let allRepositories = "All repositories"
    public static let scopeLabel = "For"
    public static let none = "None"
    public static let reading = "Reading symphony.yml…"
    public static let readAgain = "Read Again"

    /// Default first, then the nine kinds in the catalog's order.
    public static let kinds: [RunKind?] = [nil, .implementation, .breakdown, .rework, .codeReview, .qa, .ciFix, .reviewFeedback, .landing, .epicReview]

    /// A kind's name on the page, as the workflow's states name them.
    public static func title(_ kind: RunKind?) -> String {
        switch kind {
        case nil: "Default"
        case .implementation: "Implementation"
        case .breakdown: "Breakdown"
        case .rework: "Rework"
        case .codeReview: "Code Review"
        case .qa: "QA"
        case .ciFix: "CI Fix"
        case .reviewFeedback: "Review Feedback"
        case .landing: "Landing"
        case .epicReview: "Epic Review"
        }
    }

    // MARK: Reading

    /// Reads the run profiles and the repositories of `file`, nil while Settings names none. A page holding changes
    /// not saved keeps them and reads only the repositories again.
    public mutating func read(_ file: SymphonyConfigFile?) {
        do {
            guard let file else { throw RunsPageError.noFile }
            let text = try file.read()
            let profiles = try RunProfilesConfig.scopedProfiles(in: text)
            load(profiles, repositories: try RunProfilesConfig.repositoryKeys(in: text))
        } catch {
            guard editor?.hasChanges != true else { return }
            editor = nil
            loadError = error.localizedDescription
        }
    }

    /// Takes in what was read. Changes not saved are kept; a repository gone from the file sends For back to All
    /// repositories.
    public mutating func load(_ profiles: ScopedRunProfiles, repositories: [String]) {
        if editor?.hasChanges != true { editor = RunsEditor(profiles) }
        loadError = nil
        self.repositories = repositories
        if case .repository(let key) = scope, !repositories.contains(key) { scope = .global }
    }

    // MARK: What the page shows

    /// The For pop-up's choices: All repositories, then each repository.
    public var scopes: [ScopeChoice] {
        [ScopeChoice(scope: .global, title: Self.allRepositories)] + repositories.map { ScopeChoice(scope: .repository($0), title: $0) }
    }

    /// Every row in the page's order, for the scope shown; none until the file is read.
    public var rows: [Row] {
        guard let editor else { return [] }
        return Self.kinds.map { row($0, editor: editor) }
    }

    public var changeCount: Int { editor?.changeCount ?? 0 }

    private func row(_ kind: RunKind?, editor: RunsEditor) -> Row {
        let lines = editor.lines(kind, in: scope)
        let shown = lines.enumerated().map { place, line in
            Line(id: place, fields: fields(of: line), removable: editor.canRemove(place, of: kind, in: scope))
        }
        let waits = lines.count == 1 ? Self.waits(provider: lines[0].provider.value) : nil
        return Row(kind: kind, title: Self.title(kind), lines: shown, canUseDefaults: editor.canUseDefaults(kind, in: scope), waits: waits)
    }

    /// "No fallback: a run waits when Anthropic can’t take it".
    static func waits(provider: String?) -> String {
        let name = provider.map(Self.providerTitle) ?? "its provider"
        return "No fallback: a run waits when \(name) can’t take it"
    }

    static func providerTitle(_ id: String) -> String {
        RunProfilesConfig.providers.first { $0.id == id }?.title ?? id
    }

    static func harnessTitle(_ id: String) -> String {
        Harness(rawValue: id)?.title ?? id
    }

    private func fields(of line: RunLine) -> [Field] {
        let harness = line.harness
        let provider = line.provider
        let model = line.model
        let effort = line.effort
        let models = lists.models(for: provider.value, including: model.value)
            ?? model.value.map { [RunProfileChoice(id: $0, title: $0)] } ?? []
        return [
            Self.field(.harness, "Harness", harness, RunProfilesConfig.harnesses, title: Self.harnessTitle),
            Self.field(.provider, "Provider", provider, RunProfilesConfig.providers(for: harness.value), title: Self.providerTitle),
            Self.field(.model, "Model", model, models.map { RunProfileChoice(id: $0.id, title: $0.id) }, title: { $0 }),
            Self.field(.effort, "Effort", effort, RunProfilesConfig.efforts, title: { $0 }),
        ]
    }

    private static func field(
        _ field: RunProfileField, _ label: String, _ value: RunLineValue, _ list: [RunProfileChoice], title: (String) -> String
    ) -> Field {
        var choices = RunProfilesConfig.choices(list, including: value.value).map { Choice($0.id, title($0.id)) }
        if value.value == nil { choices.insert(Choice(nil, none), at: 0) }
        return Field(
            field: field, label: label, value: value.value, title: value.value.map(title) ?? none, isOwn: value.isOwn, choices: choices
        )
    }

    // MARK: Editing

    /// Shows the values of `scope`. Changes not saved in any scope stay.
    public mutating func show(_ scope: RunProfilesScope) {
        self.scope = scope
    }

    /// Picks `value` for `field` of line `line` of `kind`. A harness that doesn't reach the line's provider takes its
    /// first one, and a provider whose models are known and don't hold the line's model takes its first model, so the
    /// line stays one Symphony can run.
    public mutating func pick(_ field: RunProfileField, of line: Int, kind: RunKind?, to value: String?) {
        guard var editor else { return }
        guard editor.set(field, of: line, kind: kind, in: scope, to: value) else { return }
        if field == .harness, let reached = value.flatMap(Harness.init)?.providers,
           let provider = editor.lines(kind, in: scope)[line].provider.value, !reached.contains(provider) {
            editor.set(.provider, of: line, kind: kind, in: scope, to: reached.first)
        }
        if field == .harness || field == .provider {
            let now = editor.lines(kind, in: scope)[line]
            if let models = lists.models(for: now.provider.value), let first = models.first,
               !models.contains(where: { $0.id == now.model.value }) {
                editor.set(.model, of: line, kind: kind, in: scope, to: first.id)
            }
        }
        edited(editor)
    }

    /// "Use Default's": the kind takes everything from Default again.
    public mutating func useDefaults(_ kind: RunKind?) {
        guard var editor, editor.useDefaults(kind, in: scope) else { return }
        edited(editor)
    }

    /// Adds a fallback after the last line of `kind`.
    public mutating func addFallback(_ kind: RunKind?) {
        guard var editor else { return }
        editor.addFallback(kind, in: scope)
        edited(editor)
    }

    /// Removes line `line` of `kind`, when it can be.
    public mutating func remove(_ line: Int, of kind: RunKind?) {
        guard var editor, editor.remove(line, of: kind, in: scope) else { return }
        edited(editor)
    }

    /// Takes the order the list was left in (the lines' places before the move, in their new order) and moves the line
    /// that moved. A move the editor refuses leaves the order as it was.
    public mutating func reorder(_ kind: RunKind?, to order: [Int]) {
        guard var editor, let moved = Self.move(in: order), editor.move(moved.from, to: moved.to, of: kind, in: scope) else { return }
        edited(editor)
    }

    /// The one line that moved in `order`, a permutation of `0..<order.count`: where it was and where it is now.
    static func move(in order: [Int]) -> (from: Int, to: Int)? {
        let before = Array(order.indices)
        for (to, from) in order.enumerated() where from != to {
            var old = before
            old.remove(at: from)
            var new = order
            new.remove(at: to)
            if old == new { return (from, to) }
        }
        return nil
    }

    /// Puts every value back as it was read.
    public mutating func revert() {
        guard var editor else { return }
        editor.revert()
        edited(editor)
    }

    private mutating func edited(_ editor: RunsEditor) {
        self.editor = editor
        save = .editing
    }

    // MARK: Saving

    /// Whether Save can be pressed: something changed and no save is under way.
    public var canSave: Bool { changeCount > 0 && save != .saving }

    /// Starts a save: the editor to save, or nil when there is nothing to save or a save is under way.
    public mutating func beginSave() -> RunsEditor? {
        guard canSave, let editor else { return nil }
        save = .saving
        return editor
    }

    /// Takes in a save's outcome: the values read back from the file become the page's, or the reason stays in the bar
    /// with every change.
    public mutating func finishSave(_ outcome: RunsSaveOutcome) {
        editor?.apply(outcome)
        switch outcome {
        case .saved: save = .saved
        case .refused(let reason): save = .refused(reason)
        }
    }

    /// Takes "Saved" away once it has shown.
    public mutating func clearSaved() {
        if save == .saved { save = .editing }
    }
}

/// Why the page has nothing to read.
enum RunsPageError: LocalizedError {
    case noFile

    var errorDescription: String? {
        switch self {
        case .noFile: "Choose symphony.yml in Settings to set the runs."
        }
    }
}

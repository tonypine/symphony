import Foundation

/// Factory › Runs (TP-1538), as the catalog draws it (`runsPage` in `docs/design/catalog/stories.js`): Default and the
/// ten kinds of run (the catalog's nine and the Conductor's turn), each always open, with one line per choice, the first
/// choice then each fallback in the order Symphony tries them. Each line has Harness, Provider, Model and Effort. A value the kind takes from Default is
/// drawn grey, one it sets itself dark. Under them the Harnesses block (TP-1539) sets each harness's command and its
/// small model per provider. Nothing is applied until Save; the Save bar counts the changes and has Revert.
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

    /// What a line says when its provider can't take a new run now (TP-1534): "Anthropic is paused" beside a Status
    /// dot in the "waiting on you" orange, or "Anthropic is at its limit" beside a red one.
    public struct ProviderNote: Equatable {
        public let status: DesignTokens.Status
        public let text: String

        /// The note for `provider` as the state lists it; nil while it can take new runs. The Director's pause reads
        /// before a usage limit's hold.
        public static func of(_ provider: StateSnapshot.Provider) -> ProviderNote? {
            if provider.paused { return ProviderNote(status: .you, text: "\(provider.name) is paused") }
            if provider.held { return ProviderNote(status: .problem, text: "\(provider.name) is at its limit") }
            return nil
        }
    }

    /// One line of a kind: its place (0 for the first choice), its four pop-ups, whether it can be removed, and what it
    /// says when its provider is paused or held by a usage limit.
    public struct Line: Equatable, Identifiable {
        public let id: Int
        public let fields: [Field]
        public let removable: Bool
        public var providerNote: ProviderNote? = nil

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

    /// A small model of the Harnesses block: the provider it is for, its pop-up's label, its value and its choices.
    public struct SmallModel: Equatable, Identifiable {
        public let provider: String
        public let label: String
        public let value: String?
        public let title: String
        public let choices: [Choice]

        public var id: String { provider }
    }

    /// One harness of the Harnesses block: its name, its command and a small model for each provider it needs one for.
    public struct HarnessRow: Equatable, Identifiable {
        public let harness: Harness
        public let command: String
        public let smallModels: [SmallModel]

        public var id: String { harness.rawValue }
        public var title: String { harness.title }
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
    /// What a line on each paused or held provider says, by provider id, from the state's `providers`.
    public private(set) var providerNotes: [String: ProviderNote] = [:]

    public init() {}

    static let defaultID = "default"
    public static let useDefaults = "Use Default’s"
    public static let addFallback = "Add a Fallback"
    public static let allRepositories = "All repositories"
    public static let scopeLabel = "For"
    public static let none = "None"
    public static let reading = "Reading symphony.yml…"
    public static let readAgain = "Read Again"
    public static let harnessesTitle = "Harnesses"
    public static let commandLabel = "Command"
    public static let savingReason = "Saving symphony.yml…"

    /// "Small model on Anthropic".
    public static func smallModelLabel(_ provider: String) -> String {
        "Small model on \(providerTitle(provider))"
    }

    /// Default first, then the catalog's nine kinds in its order, then the Conductor's turn.
    public static let kinds: [RunKind?] = [
        nil, .implementation, .breakdown, .rework, .codeReview, .qa, .ciFix, .reviewFeedback, .landing, .epicReview, .conductor,
    ]

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
        case .conductor: "Conductor"
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

    /// Takes in the providers the state lists, so each line whose provider is paused or held says so.
    public mutating func showProviders(_ providers: [StateSnapshot.Provider]?) {
        var notes: [String: ProviderNote] = [:]
        for provider in providers ?? [] {
            notes[provider.id] = ProviderNote.of(provider)
        }
        providerNotes = notes
    }

    /// The page with the providers the state lists: what the window draws.
    public func showing(_ providers: [StateSnapshot.Provider]?) -> RunsPage {
        var page = self
        page.showProviders(providers)
        return page
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

    /// The Harnesses block: each harness a line runs on or the file sets, with its command and a small model per
    /// provider it needs one for. Harnesses are set once for every repository, so a repository's values show none.
    public var harnessRows: [HarnessRow] {
        guard let editor, scope == .global else { return [] }
        // A harness read with settings stays while its command is cleared, so the field isn't taken away mid-edit.
        let shown = Harness.allCases.filter { editor.harnesses.contains($0) || editor.loaded[$0] != HarnessSettings() }
        return shown.map { harness in
            let settings = editor.profiles[harness]
            let models = editor.smallModelProviders(of: harness).map { provider in
                smallModel(settings.smallModels[provider], on: provider)
            }
            return HarnessRow(harness: harness, command: settings.command ?? "", smallModels: models)
        }
    }

    private func smallModel(_ value: String?, on provider: String) -> SmallModel {
        let models = lists.models(for: provider, including: value) ?? value.map { [RunProfileChoice(id: $0, title: $0)] } ?? []
        var choices = models.map { Choice($0.id, $0.id) }
        if value == nil { choices.insert(Choice(nil, Self.none), at: 0) }
        return SmallModel(provider: provider, label: Self.smallModelLabel(provider), value: value, title: value ?? Self.none, choices: choices)
    }

    private func row(_ kind: RunKind?, editor: RunsEditor) -> Row {
        let lines = editor.lines(kind, in: scope)
        let shown = lines.enumerated().map { place, line in
            Line(
                id: place, fields: fields(of: line), removable: editor.canRemove(place, of: kind, in: scope),
                providerNote: line.provider.value.flatMap { providerNotes[$0] }
            )
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
        guard var editor = editable else { return }
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
        guard var editor = editable, editor.useDefaults(kind, in: scope) else { return }
        edited(editor)
    }

    /// Adds a fallback after the last line of `kind`.
    public mutating func addFallback(_ kind: RunKind?) {
        guard var editor = editable else { return }
        editor.addFallback(kind, in: scope)
        edited(editor)
    }

    /// Removes line `line` of `kind`, when it can be.
    public mutating func remove(_ line: Int, of kind: RunKind?) {
        guard var editor = editable, editor.remove(line, of: kind, in: scope) else { return }
        edited(editor)
    }

    /// Takes the order the list was left in (the lines' places before the move, in their new order) and moves the line
    /// that moved. A move the editor refuses leaves the order as it was.
    public mutating func reorder(_ kind: RunKind?, to order: [Int]) {
        guard var editor = editable, let moved = Self.move(in: order),
              editor.move(moved.from, to: moved.to, of: kind, in: scope) else { return }
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

    /// Sets the command `harness` is started with; an empty one clears it.
    public mutating func setCommand(_ value: String, of harness: Harness) {
        guard var editor = editable, editor.setCommand(value, of: harness) else { return }
        edited(editor)
    }

    /// Picks the small model `harness` calls on `provider`.
    public mutating func pickSmallModel(_ value: String?, of harness: Harness, on provider: String) {
        guard var editor = editable, editor.setSmallModel(value, of: harness, on: provider) else { return }
        edited(editor)
    }

    /// Puts every value back as it was read.
    public mutating func revert() {
        guard var editor = editable else { return }
        editor.revert()
        edited(editor)
    }

    /// Whether the values can be edited: the file is read and no save is under way. An edit made while `symphony check`
    /// runs would be lost when the saved values come back, so the page takes none until the save ends.
    public var isEditable: Bool { editor != nil && save != .saving }

    /// The editor to edit, nil while a save is under way.
    private var editable: RunsEditor? { save == .saving ? nil : editor }

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

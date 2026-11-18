import Foundation

/// A value on a line of a kind of run, and whether the kind sets it itself or takes it from elsewhere: from
/// Default (the entries Symphony falls back to) for a first choice, or from the first choice for a fallback.
public struct RunLineValue: Equatable {
    public var value: String?
    public var isOwn: Bool

    public init(_ value: String?, isOwn: Bool) {
        self.value = value
        self.isOwn = isOwn
    }
}

/// One line of a kind of run: its first choice, or one of its fallbacks, each field resolved as Symphony
/// resolves it (`SymphonyElixir.Config.Runs.candidates/4`).
public struct RunLine: Equatable {
    public var values: [RunProfileField: RunLineValue]

    public init(values: [RunProfileField: RunLineValue] = [:]) {
        self.values = values
    }

    public subscript(field: RunProfileField) -> RunLineValue {
        get { values[field] ?? RunLineValue(nil, isOwn: false) }
        set { values[field] = newValue }
    }

    public var harness: RunLineValue { self[.harness] }
    public var provider: RunLineValue { self[.provider] }
    public var model: RunLineValue { self[.model] }
    public var effort: RunLineValue { self[.effort] }

    /// Whether the line runs on the same harness and provider as `first`, so it keeps its model and small model.
    func sharesHarnessAndProvider(with first: RunLine) -> Bool {
        harness.value == first.harness.value && provider.value == first.provider.value
    }
}

extension ScopedRunProfiles {
    /// The `fallbacks` list a run of `kind` (nil for the Default row) in `scope` takes when its own entry sets
    /// none: the first that sets one of the repository's kind, the repository's `default`, `runs.<kind>`, then
    /// `runs.default`.
    public func inheritedFallbacks(_ kind: RunKind?, in scope: RunProfilesScope) -> [RunFallback]? {
        switch (scope, kind) {
        case (.global, nil):
            return nil
        case (.global, _?), (.repository, nil):
            return global.fallbacks(of: nil)
        case (.repository, let kind?):
            return self[scope].fallbacks(of: nil) ?? global.fallbacks(of: kind) ?? global.fallbacks(of: nil)
        }
    }

    /// The list of fallbacks a run of `kind` in `scope` tries: its own, or the one it takes.
    func effectiveFallbacks(_ kind: RunKind?, in scope: RunProfilesScope) -> [RunFallback] {
        self[scope].fallbacks(of: kind) ?? inheritedFallbacks(kind, in: scope) ?? []
    }

    /// The first choice of `kind` in `scope`, then each fallback in the order Symphony tries them.
    public func lines(_ kind: RunKind?, in scope: RunProfilesScope) -> [RunLine] {
        let own = self[scope][kind]
        let inherited = self.inherited(kind, in: scope)
        var first = RunLine()
        for field in RunProfileField.allCases {
            first[field] = RunLineValue(own[field] ?? inherited[field], isOwn: own[field] != nil)
        }
        let ownList = self[scope].fallbacks(of: kind) != nil
        return [first] + effectiveFallbacks(kind, in: scope).map { RunsEditor.resolve($0, over: first, isOwn: ownList) }
    }
}

/// What a save did: the profiles read back from the saved file, or why nothing was written.
public enum RunsSaveOutcome: Equatable {
    case saved(ScopedRunProfiles)
    case refused(String)
}

/// The model behind Factory › Runs: every kind of run's lines in each scope, the edits the page makes to them,
/// the count of changes not saved, Revert and Save. Edits change `profiles` only; Save writes the differences
/// from `loaded` to `symphony.yml`.
public struct RunsEditor: Equatable {
    /// The profiles as last read from the file.
    public private(set) var loaded: ScopedRunProfiles
    /// The profiles with the edits not saved yet.
    public private(set) var profiles: ScopedRunProfiles

    public init(_ profiles: ScopedRunProfiles) {
        loaded = profiles
        self.profiles = profiles
    }

    /// The first choice of `kind` (nil for Default) in `scope`, then its fallbacks in order.
    public func lines(_ kind: RunKind?, in scope: RunProfilesScope = .global) -> [RunLine] {
        profiles.lines(kind, in: scope)
    }

    // MARK: Editing

    /// Sets `field` of line `line` (0 for the first choice) to `value`. A nil or empty value clears what the
    /// kind sets itself: the first choice then takes it from Default, a fallback from the first choice. A
    /// fallback sets no `command`. Returns false when the line doesn't exist or nothing changed.
    @discardableResult
    public mutating func set(
        _ field: RunProfileField,
        of line: Int,
        kind: RunKind?,
        in scope: RunProfilesScope = .global,
        to value: String?
    ) -> Bool {
        let value = value.flatMap { $0.trimmingWhitespace().isEmpty ? nil : $0 }
        let before = profiles
        if line == 0 {
            profiles[scope][kind][field] = value
        } else {
            var list = profiles.effectiveFallbacks(kind, in: scope)
            guard list.indices.contains(line - 1), RunFallback.fields.contains(field) else { return false }
            list[line - 1][field] = value
            profiles[scope].setFallbacks(list, of: kind)
        }
        return profiles != before
    }

    /// Whether the kind sets something of its own that "Use Default's" would clear: a value of its first choice,
    /// or its own fallbacks. The Default row of all repositories takes nothing from anywhere.
    public func canUseDefaults(_ kind: RunKind?, in scope: RunProfilesScope = .global) -> Bool {
        if kind == nil, scope == .global { return false }
        let own = profiles[scope][kind]
        return Self.lineFields.contains { own[$0] != nil } || profiles[scope].fallbacks(of: kind) != nil
    }

    /// "Use Default's": clears the kind's own harness, provider, model and effort and its own fallbacks, so it
    /// takes them all from Default. Its small model and command, which the page doesn't show, stay.
    @discardableResult
    public mutating func useDefaults(_ kind: RunKind?, in scope: RunProfilesScope = .global) -> Bool {
        guard canUseDefaults(kind, in: scope) else { return false }
        for field in Self.lineFields { profiles[scope][kind][field] = nil }
        profiles[scope].setFallbacks(nil, of: kind)
        return true
    }

    /// Adds a fallback after the last line. It sets nothing yet, so it runs as the first choice does until a
    /// value is picked. A kind taking Default's fallbacks gets its own copy of them first.
    public mutating func addFallback(_ kind: RunKind?, in scope: RunProfilesScope = .global) {
        profiles[scope].setFallbacks(profiles.effectiveFallbacks(kind, in: scope) + [RunFallback()], of: kind)
    }

    /// Whether line `line` can be removed: never the only line, and never the last fallback of a kind that would
    /// then take Default's list, since Symphony reads an empty list as none set.
    public func canRemove(_ line: Int, of kind: RunKind?, in scope: RunProfilesScope = .global) -> Bool {
        let count = lines(kind, in: scope).count
        guard count > 1, (0..<count).contains(line) else { return false }
        return count > 2 || profiles.inheritedFallbacks(kind, in: scope) == nil
    }

    /// Removes line `line`. Removing the first choice makes the first fallback the first choice, with the
    /// values it ran with. Returns false when `canRemove` is false.
    @discardableResult
    public mutating func remove(_ line: Int, of kind: RunKind?, in scope: RunProfilesScope = .global) -> Bool {
        guard canRemove(line, of: kind, in: scope) else { return false }
        if line == 0 { move(1, to: 0, of: kind, in: scope) }
        var list = profiles.effectiveFallbacks(kind, in: scope)
        list.remove(at: line == 0 ? 0 : line - 1)
        profiles[scope].setFallbacks(list, of: kind)
        return true
    }

    /// Moves line `from` to position `to`, the first choice included. Every line keeps the harness, provider,
    /// model and effort it runs with: when a fallback becomes the first choice, the others are written again
    /// against it. Returns false for a move that changes nothing.
    @discardableResult
    public mutating func move(_ from: Int, to: Int, of kind: RunKind?, in scope: RunProfilesScope = .global) -> Bool {
        let lines = self.lines(kind, in: scope)
        guard from != to, lines.indices.contains(from), lines.indices.contains(to) else { return false }
        var order = Array(lines.indices)
        order.insert(order.remove(at: from), at: to)
        let list = profiles.effectiveFallbacks(kind, in: scope)

        guard let leader = order.first, leader != 0 else {
            profiles[scope].setFallbacks(order.dropFirst().map { list[$0 - 1] }, of: kind)
            return true
        }
        let oldFirst = profiles[scope][kind]
        let promoted = list[leader - 1]
        let keepsModel = lines[leader].sharesHarnessAndProvider(with: lines[0])
        var first = oldFirst
        for field in RunFallback.fields {
            if let value = promoted[field] {
                first[field] = value
            } else if !keepsModel && (field == .model || field == .smallModel) {
                first[field] = nil
            }
        }
        profiles[scope][kind] = first
        let newFirst = profiles.lines(kind, in: scope)[0]
        var demoted = RunFallback()
        for field in RunFallback.fields { demoted[field] = oldFirst[field] }
        let rest = order.dropFirst().map { index in
            Self.expressing(lines[index], over: newFirst, from: index == 0 ? demoted : list[index - 1])
        }
        profiles[scope].setFallbacks(rest, of: kind)
        return true
    }

    /// The harness, provider, model and effort fields a line shows.
    public static let lineFields: [RunProfileField] = [.harness, .provider, .model, .effort]

    // MARK: The Harnesses block

    /// The harnesses the Harnesses block shows: those a line runs on, and those that set a command or a small model.
    public var harnesses: [Harness] {
        let inUse = profiles.providersInUse
        return Harness.allCases.filter { inUse[$0] != nil || profiles[$0] != HarnessSettings() }
    }

    /// The providers `harness` needs a small model for, in its own order: those its lines run on, when it calls
    /// one, and those it sets one for.
    public func smallModelProviders(of harness: Harness) -> [String] {
        guard harness.callsSmallModel else { return [] }
        let inUse = profiles.providersInUse[harness] ?? []
        return harness.providers.filter { inUse.contains($0) || profiles[harness].smallModels[$0] != nil }
    }

    /// Sets `execution.harnesses.<harness>.command`; nil or empty clears it.
    @discardableResult
    public mutating func setCommand(_ value: String?, of harness: Harness) -> Bool {
        let before = profiles
        profiles[harness].command = value.flatMap { $0.trimmingWhitespace().isEmpty ? nil : $0 }
        return profiles != before
    }

    /// Sets `execution.harnesses.<harness>.small_model.<provider>`; nil or empty clears it.
    @discardableResult
    public mutating func setSmallModel(_ value: String?, of harness: Harness, on provider: String) -> Bool {
        let before = profiles
        profiles[harness].smallModels[provider] = value.flatMap { $0.trimmingWhitespace().isEmpty ? nil : $0 }
        return profiles != before
    }

    // MARK: Changes

    /// How many changes are not saved: each field of an entry or of the Harnesses block that differs, and each
    /// place in a `fallbacks` list whose fallback differs.
    public var changeCount: Int {
        var count = 0
        let keys = Set(loaded.repositories.keys).union(profiles.repositories.keys).sorted()
        for scope in [RunProfilesScope.global] + keys.map(RunProfilesScope.repository) {
            let old = loaded[scope]
            let new = profiles[scope]
            for kind in RunProfilesConfig.scopes {
                count += RunProfileField.allCases.filter { old[kind][$0] != new[kind][$0] }.count
                let oldList = old.fallbacks(of: kind) ?? []
                let newList = new.fallbacks(of: kind) ?? []
                count += (0..<max(oldList.count, newList.count)).filter { oldList.element(at: $0) != newList.element(at: $0) }.count
            }
        }
        for harness in Harness.allCases {
            let old = loaded[harness]
            let new = profiles[harness]
            if old.command != new.command { count += 1 }
            count += Set(old.smallModels.keys).union(new.smallModels.keys).filter { old.smallModels[$0] != new.smallModels[$0] }.count
        }
        return count
    }

    public var hasChanges: Bool { profiles != loaded }

    /// Puts every value back as it was loaded.
    public mutating func revert() {
        profiles = loaded
    }

    /// Writes the changes to `file` once `check` (`symphony check` on the whole new file) passes, and reads the
    /// file back. A refused save writes nothing, and the editor keeps every change.
    public func save(
        to file: SymphonyConfigFile,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async -> RunsSaveOutcome {
        do {
            let result = try await file.writeRunProfiles(profiles, from: loaded, checkingWith: check)
            if case .failed(let message) = result { return .refused(ConfigCheck.reasonFirst(message)) }
            return .saved(try file.readScopedRunProfiles())
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// Takes in a save's outcome: a saved file becomes the loaded values; a refused one changes nothing.
    public mutating func apply(_ outcome: RunsSaveOutcome) {
        guard case .saved(let saved) = outcome else { return }
        loaded = saved
        profiles = saved
    }

    // MARK: Resolution

    /// A fallback as Symphony resolves it on top of the entry's first choice: what it sets, then the first
    /// choice's harness, provider and effort, and its model and small model only when the fallback keeps the
    /// harness and the provider.
    static func resolve(_ fallback: RunFallback, over first: RunLine, isOwn: Bool) -> RunLine {
        let harness = fallback.harness ?? first.harness.value
        let keepsModel = harness == first.harness.value && (fallback.provider ?? first.provider.value) == first.provider.value
        var line = RunLine()
        for field in RunFallback.fields {
            let taken = (field == .model || field == .smallModel) && !keepsModel ? nil : first[field].value
            line[field] = RunLineValue(fallback[field] ?? taken, isOwn: isOwn && fallback[field] != nil)
        }
        return line
    }

    /// `seed` with the fields added that make it resolve to `target`'s values over `first`.
    static func expressing(_ target: RunLine, over first: RunLine, from seed: RunFallback) -> RunFallback {
        var fallback = seed
        for field in RunFallback.fields {
            let resolved = resolve(fallback, over: first, isOwn: true)[field].value
            if resolved != target[field].value, let value = target[field].value { fallback[field] = value }
        }
        return fallback
    }
}

extension Array {
    fileprivate func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import Combine
import Foundation

/// `auto_review.acceptance_gate.mode`, the acceptance gate's kill switch, as `docs/acceptance_gate.md` describes it.
public enum AcceptanceGateMode: String, CaseIterable, Identifiable {
    case off
    case shadow
    case enforce

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .shadow: return "Shadow"
        case .enforce: return "Enforce"
        }
    }

    /// One line on what the gate does in this mode.
    public var explanation: String {
        switch self {
        case .off:
            return "The gate never runs. Every PR waits in In Review for a person."
        case .shadow:
            return "The gate records a verdict and moves nothing. Every PR still waits in In Review for a person."
        case .enforce:
            return "The gate's verdict moves the issue: approve to Merging, rework back to In Progress, escalate to "
                + "In Review."
        }
    }

    /// The mode a `mode:` value names, nil for a value Symphony rejects. Symphony matches it exactly.
    public init?(value: String?) {
        guard let value, let mode = AcceptanceGateMode(rawValue: value) else { return nil }
        self = mode
    }
}

/// What a repository's Edit sheet picks for `repositories[<key>].acceptance_gate.mode`: the global mode, or one of
/// its own.
public enum AcceptanceGateChoice: Hashable, Identifiable {
    case inherit
    case mode(AcceptanceGateMode)

    public static let allCases: [AcceptanceGateChoice] = [.inherit] + AcceptanceGateMode.allCases.map { .mode($0) }

    public var id: String { override ?? "inherit" }

    /// The choice for the value in the file: nil is Inherit.
    public init(override: String?) {
        self = AcceptanceGateMode(value: override).map { .mode($0) } ?? .inherit
    }

    /// The value written to `symphony.yml`, nil to remove the key.
    public var override: String? {
        guard case let .mode(mode) = self else { return nil }
        return mode.rawValue
    }

    /// "Inherit (Shadow)", or the mode's title.
    public func title(inheriting global: AcceptanceGateMode) -> String {
        switch self {
        case .inherit: return "Inherit (\(global.title))"
        case let .mode(mode): return mode.title
        }
    }

    /// One line on what the choice does: the mode's explanation, or where Inherit takes the mode from.
    public func explanation(inheriting global: AcceptanceGateMode) -> String {
        switch self {
        case .inherit: return "Follows the mode in Settings, now \(global.title)."
        case let .mode(mode): return mode.explanation
        }
    }

    /// The mode the repository runs with.
    public func effective(inheriting global: AcceptanceGateMode) -> AcceptanceGateMode {
        switch self {
        case .inherit: return global
        case let .mode(mode): return mode
        }
    }
}

/// Why the acceptance gate's mode can't be read or changed in a `symphony.yml`.
public enum AcceptanceGateConfigError: LocalizedError, Equatable {
    /// A section on the way holds an inline value instead of an indented block.
    case notABlock(String)
    /// `mode:` holds a value Symphony rejects.
    case unknownMode(String)

    public var errorDescription: String? {
        switch self {
        case let .notABlock(key):
            return "`\(key):` in symphony.yml is not an indented block. Change the acceptance gate's mode by hand."
        case let .unknownMode(value):
            return "auto_review.acceptance_gate.mode is `\(value)`, which Symphony rejects. Set it to off, shadow or "
                + "enforce."
        }
    }
}

/// The acceptance gate's controls in the app: the global mode in Settings, a repository's own mode in its Edit
/// sheet and the Repos window, the kill switch in the status menu, and the agreement stats from
/// `/api/v1/state`.
public enum AcceptanceGate {
    public static let sectionTitle = "Acceptance gate (saved in symphony.yml)"
    public static let pickerTitle = "Acceptance gate"
    public static let repoFieldLabel = "Gate"

    /// The alert Enforce opens before it is picked.
    public static let confirmTitle = "Turn on Enforce?"
    public static let confirmMessage = "PRs the gate approves merge without a person reviewing them. Escalations "
        + "still wait in In Review. Switch back to Shadow or Off at any time, from Settings or the status menu."
    public static let confirmButton = "Enforce"

    /// The line shown in place of the stats while Symphony isn't answering.
    public static let notRunningLine = "Start Symphony to see the gate's record."
    /// The line for a Symphony that doesn't report the stats.
    public static let unsupportedLine = "This Symphony doesn't report the gate's record. Update it to see it."
    /// The stats line of a repository with no decided verdict yet.
    public static let noRecordLine = "No verdicts decided by a person yet."

    /// Whether moving from `current` to `new` asks first: only a move into Enforce does.
    public static func needsConfirmation(from current: AcceptanceGateMode, to new: AcceptanceGateMode) -> Bool {
        new == .enforce && current != .enforce
    }

    // MARK: Agreement stats

    /// For example "12 judged · 92% agreement · 0 unsafe approvals · not ready: at least 20 judged tickets
    /// (12 so far)", or "… · ready to enforce".
    public static func agreementLine(_ stats: StateSnapshot.GateAgreement?) -> String {
        guard let stats else { return noRecordLine }
        let agreement = stats.agreementRate.map { "\(Int(($0 * 100).rounded()))% agreement" } ?? "no agreement yet"
        let unsafe = stats.unsafeApprovals == 1 ? "1 unsafe approval" : "\(stats.unsafeApprovals) unsafe approvals"
        let readiness = stats.readyToEnforce ? "ready to enforce" : "not ready: \(stats.unmetCondition ?? "unknown")"
        return "\(stats.judged) judged · \(agreement) · \(unsafe) · \(readiness)"
    }

    /// The line for the repository `key` in a Symphony's state, nil while Symphony isn't answering.
    public static func agreementLine(for key: String, in snapshot: StateSnapshot?) -> String {
        guard let snapshot else { return notRunningLine }
        guard let agreement = snapshot.gateAgreement else { return unsupportedLine }
        return agreementLine(agreement[key])
    }

    /// Settings' lines: one per repository, "key: …", in `keys` order, then any other repository the stats name.
    public static func agreementLines(keys: [String], in snapshot: StateSnapshot?) -> [String] {
        guard let snapshot else { return [notRunningLine] }
        guard let agreement = snapshot.gateAgreement else { return [unsupportedLine] }
        let all = keys + agreement.keys.filter { !keys.contains($0) }.sorted()
        guard !all.isEmpty else { return [noRecordLine] }
        return all.map { "\($0): \(agreementLine(agreement[$0]))" }
    }

    /// The Edit Repo sheet's stats line for one repository, refreshed with each state poll while the sheet is open,
    /// as Settings' lines are.
    public final class RepoAgreement: ObservableObject {
        public let key: String
        /// Symphony's latest state, nil while it isn't answering.
        @Published public var state: StateSnapshot?

        public init(key: String, state: StateSnapshot?) {
            self.key = key
            self.state = state
        }

        public var line: String {
            AcceptanceGate.agreementLine(for: key, in: state)
        }
    }

    // MARK: Status menu kill switch

    /// A status menu item for a repository the gate runs on, with a submenu to switch it to Shadow or Off.
    public struct MenuItem: Equatable {
        /// The repository, nil for a `symphony.yml` without `repositories:`, where the item sets the global mode.
        public var key: String?
        public var mode: AcceptanceGateMode

        public init(key: String?, mode: AcceptanceGateMode) {
            self.key = key
            self.mode = mode
        }

        /// "Acceptance gate: Enforce (symphony)".
        public var title: String {
            "Acceptance gate: \(mode.title)" + (key.map { " (\($0))" } ?? "")
        }

        /// The modes the submenu switches to; the current one shows checked.
        public static let choices: [AcceptanceGateMode] = [.shadow, .off]
    }

    /// One item per repository whose gate runs (Shadow or Enforce), in file order. Without repositories, one item
    /// for the global mode while it isn't Off.
    public static func menuItems(global: AcceptanceGateMode, entries: [RepositoryEntry]) -> [MenuItem] {
        guard !entries.isEmpty else { return global == .off ? [] : [MenuItem(key: nil, mode: global)] }
        return entries.compactMap { entry in
            let mode = AcceptanceGateChoice(override: entry.acceptanceGateMode).effective(inheriting: global)
            return mode == .off ? nil : MenuItem(key: entry.key, mode: mode)
        }
    }

    // MARK: Repos window

    /// The row's Gate field when the repository's own mode differs from the global one, nil otherwise.
    public static func repoField(_ entry: RepositoryEntry, global: AcceptanceGateMode) -> RepoField? {
        guard let value = entry.acceptanceGateMode else { return nil }
        guard let mode = AcceptanceGateMode(value: value) else {
            return RepoField(repoFieldLabel, value, detail: "Symphony accepts off, shadow or enforce.", tone: .problem)
        }
        return mode == global ? nil : RepoField(repoFieldLabel, mode.title)
    }

    /// `display` with a Gate field on each row whose repository's own mode, in `entries`, differs from `global`.
    public static func withGateFields(_ display: ReposDisplay, entries: [RepositoryEntry], global: AcceptanceGateMode) -> ReposDisplay {
        var display = display
        for index in display.rows.indices {
            guard let entry = entries.first(where: { $0.key == display.rows[index].key }),
                  let field = repoField(entry, global: global) else { continue }
            display.rows[index].fields.append(field)
        }
        return display
    }

    // MARK: symphony.yml

    static let autoReviewKey = "auto_review"
    static let gateKey = "acceptance_gate"
    static let modeKey = "mode"

    /// `auto_review.acceptance_gate.mode`, or Off, Symphony's default, when it is missing.
    public static func globalMode(in yaml: String) throws -> AcceptanceGateMode {
        let document = Document(yaml)
        guard let mode = try modeKey(in: document) else { return .off }
        let value = unquoted(ValueLine(mode.rest).value)
        guard !value.isEmpty else { return .off }
        guard let parsed = AcceptanceGateMode(value: value) else { throw AcceptanceGateConfigError.unknownMode(value) }
        return parsed
    }

    /// The same text with `auto_review.acceptance_gate.mode` set to `mode`. Rewrites only that value, keeping a
    /// trailing comment, or inserts the key and `acceptance_gate:` or `auto_review:` when they are missing.
    public static func settingGlobalMode(_ mode: AcceptanceGateMode, in yaml: String) throws -> String {
        var document = Document(yaml)
        let rendered = RepositoriesConfig.scalar(mode.rawValue)
        let step = AgentSetting.defaultIndentStep
        let pad = { (column: Int) in String(repeating: " ", count: column) }

        guard let autoReview = document.child(autoReviewKey, in: document.all) else {
            document.append([autoReviewKey + ":", pad(step) + gateKey + ":", pad(2 * step) + modeKey + ": " + rendered])
            return document.text
        }
        let autoReviewBlock = try block(of: autoReview, in: document)
        let gateColumn = document.childIndent(in: autoReviewBlock) ?? autoReview.indent + step
        let gateStep = gateColumn - autoReview.indent

        guard let gate = document.child(gateKey, in: autoReviewBlock) else {
            document.insert(
                [pad(gateColumn) + gateKey + ":", pad(gateColumn + gateStep) + modeKey + ": " + rendered],
                after: autoReview.index
            )
            return document.text
        }
        let gateBlock = try block(of: gate, in: document)

        guard let line = document.child(modeKey, in: gateBlock) else {
            let column = document.childIndent(in: gateBlock) ?? gate.indent + gateStep
            document.insert([pad(column) + modeKey + ": " + rendered], after: gate.index)
            return document.text
        }
        let current = ValueLine(line.rest)
        guard unquoted(current.value) != mode.rawValue else { return yaml }
        document.lines[line.index] = pad(line.indent) + modeKey + ":" + current.replacingValue(with: rendered)
        return document.text
    }

    /// The same text with `repositories[<key>].acceptance_gate.mode` set to `mode`'s value, or removed for
    /// Inherit, with an `acceptance_gate:` block it left empty.
    public static func settingRepositoryMode(_ choice: AcceptanceGateChoice, of key: String, in yaml: String) throws -> String {
        guard var entry = try RepositoriesConfig.entries(in: yaml).first(where: { $0.key == key }) else {
            throw RepositoriesConfigError.notFound(key)
        }
        entry.acceptanceGateMode = choice.override
        return try RepositoriesConfig.updating(key, to: entry, in: yaml)
    }

    private static func modeKey(in document: Document) throws -> Document.Key? {
        guard let autoReview = document.child(autoReviewKey, in: document.all) else { return nil }
        guard let gate = document.child(gateKey, in: try block(of: autoReview, in: document)) else { return nil }
        return document.child(modeKey, in: try block(of: gate, in: document))
    }

    private static func block(of key: Document.Key, in document: Document) throws -> Range<Int> {
        guard ValueLine(key.rest).value.isEmpty else { throw AcceptanceGateConfigError.notABlock(key.name) }
        return document.children(of: key)
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let quote = value.first, quote == "'" || quote == "\"", value.last == quote else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

/// Acceptance gate edits to a `symphony.yml` on disk.
extension SymphonyConfigFile {
    public func readAcceptanceGateMode() throws -> AcceptanceGateMode {
        try AcceptanceGate.globalMode(in: read())
    }

    /// Sets `auto_review.acceptance_gate.mode` once `check` passes on the result; see `rewrite(_:checkingWith:)`.
    public func writeAcceptanceGateMode(
        _ mode: AcceptanceGateMode,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try AcceptanceGate.settingGlobalMode(mode, in: $0) }, checkingWith: check)
    }

    /// Sets `repositories[<key>].acceptance_gate.mode` straight away, as the status menu's kill switch does: a
    /// switch to Shadow or Off must not wait on, or fail, a `symphony check`.
    public func writeRepositoryAcceptanceGateMode(_ choice: AcceptanceGateChoice, of key: String) throws {
        try rewrite { try AcceptanceGate.settingRepositoryMode(choice, of: key, in: $0) }
    }

    /// Sets `auto_review.acceptance_gate.mode` straight away, for the kill switch of a file without repositories.
    public func writeAcceptanceGateMode(_ mode: AcceptanceGateMode) throws {
        try rewrite { try AcceptanceGate.settingGlobalMode(mode, in: $0) }
    }
}

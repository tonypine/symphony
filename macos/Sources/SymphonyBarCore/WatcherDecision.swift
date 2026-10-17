import Foundation

/// S16: what the PR and CI watcher found behind a decision it asks in the Inbox, shown above the decision's cards: the
/// files, the checks and the error lines. It covers the watcher's questions (R6 no PR, R7 another base, R17 a required
/// check that never reported, R18 protected files) and the self-heal lane's escalation, when the same check fails
/// again after its fix ticket landed. Nil for any other item.
public struct WatcherEvidence: Equatable {
    public static let title = "What the watcher found"

    /// A row of the card: a label over one value per line.
    public struct Row: Equatable {
        public var label: String
        public var values: [String]
        /// File names and error lines read in the monospaced face.
        public var monospaced: Bool

        public init(label: String, values: [String], monospaced: Bool = false) {
            self.label = label
            self.values = values
            self.monospaced = monospaced
        }

        /// One element for VoiceOver: "Protected files: WORKFLOW.md, config/settings_ui_exempt.yml".
        public var accessibilityLabel: String { "\(label): \(values.joined(separator: ", "))" }
    }

    /// What the watcher asks about, in a few words: "Protected files changed".
    public var subject: String
    public var rows: [Row]
    /// The rule, for the help tag.
    public var help: String

    /// The evidence of `item` from its ticket's watch block; nil when the item isn't a decision the watcher (or the
    /// self-heal lane over its fix ticket) asked.
    public init?(item: InboxItem, watch: WatchBlock?) {
        guard item.isDecision, let watch else { return nil }
        let facts = watch.facts
        let head = watch.head.map(PRWatchCard.short)
        let pr = facts.prNumber.map { "PR #\($0)" } ?? "The pull request"
        var rows: [Row] = []
        let rule: String
        if let asked = watch.decisionRule {
            rule = asked
        } else if facts.hold == "needs_decision", watch.latestActions.first?.action == "file_fix_ticket" {
            rule = "R20"
        } else {
            return nil
        }

        switch rule {
        case "R18":
            subject = "Protected files changed"
            rows.append(Row(label: "Failing check", values: [[facts.failingCheck ?? "protected paths", head.map { "on \($0)" }].compactMap { $0 }.joined(separator: " ")]))
            if !facts.protectedFiles.isEmpty {
                rows.append(Row(label: "Protected files the PR changes", values: facts.protectedFiles, monospaced: true))
            }
        case "R17":
            subject = "A required check never reported"
            rows.append(Row(label: "Required checks that never reported", values: facts.missingChecks.isEmpty ? ["a required check"] : facts.missingChecks))
            if let head { rows.append(Row(label: "Head", values: [head], monospaced: true)) }
        case "R7":
            subject = "The PR merges into another branch"
            rows.append(Row(label: "\(pr) merges into", values: [facts.baseRef ?? "another branch"], monospaced: true))
        case "R6":
            subject = "No pull request"
            rows.append(Row(label: "Pull request", values: ["None found for the ticket"]))
        case "R20":
            subject = "The same check failed again after its fix landed"
            let check = watch.decisionCheck ?? facts.fixFailures.last?.check ?? facts.failingCheck ?? "a check"
            rows.append(Row(label: "Failing check", values: [check]))
            let errors = facts.fixFailures.map { failure in
                [failure.head.map(PRWatchCard.short), failure.error].compactMap { $0 }.joined(separator: " · ")
            }.filter { !$0.isEmpty }
            if !errors.isEmpty { rows.append(Row(label: "Error lines", values: errors, monospaced: true)) }
            rows.append(Row(label: "CI Fix runs", values: ["\(facts.redAttempts ?? 0) of \(facts.maxRedAttempts ?? 10)"]))
        default:
            return nil
        }
        self.rows = rows
        help = "Rule \(rule)"
    }
}

/// The Inbox items that left by themselves (S16): the watcher's question no longer stands because what it asked about
/// cleared, not because the Director answered it. Each leaves with the watcher's reason in the banner.
public enum WatcherDeparture {
    /// The banners for the decisions in `previous` that `current` no longer lists, the Director didn't answer
    /// (`answered`, by issue id) and the watcher watches (`watches`, by identifier). The first one is shown.
    public static func banners(
        previous: [InboxItem], current: [InboxItem], answered: Set<String>, watches: [String: WatchBlock]
    ) -> [InboxBanner] {
        let listed = Set(current.map(\.id))
        return previous.compactMap { item in
            guard item.isDecision, !listed.contains(item.id), !answered.contains(item.id), let watch = watches[item.identifier] else { return nil }
            let reason = watch.reason.map(PRWatchCard.plain).map { ": \($0)" } ?? ""
            return InboxBanner(itemID: item.id, identifier: item.identifier, text: "No longer needs you\(reason)", undo: false, style: .info)
        }
    }
}

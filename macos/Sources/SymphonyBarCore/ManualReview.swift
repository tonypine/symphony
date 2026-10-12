import Foundation

/// `repositories[<key>].manual_review`, the repo's manual review setting: who decides that a verified
/// ticket merges, as `docs/design/state-machine.md` describes it. `off` is the default, so its choice
/// removes the key.
public enum ManualReviewChoice: String, CaseIterable, Identifiable {
    case off
    case on

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        }
    }

    /// One line on what the choice does to a ticket that passes review and QA.
    public var explanation: String {
        switch self {
        case .off:
            return "Verdicts move the ticket: Code Review approve → QA, QA pass → Merging. "
                + "The machine stops for a person only on escalations and holds."
        case .on:
            return "The step into Merging pauses on you: a Needs Decision hold with the summary. "
                + "Confirm to merge, or redirect the ticket."
        }
    }

    /// The choice for the value in the file: nil or an unknown value is Off, the default.
    public init(override: String?) {
        self = override.flatMap(ManualReviewChoice.init(rawValue:)) ?? .off
    }

    /// The value written to `symphony.yml`; nil for Off, the default, removes the key.
    public var override: String? {
        self == .off ? nil : rawValue
    }
}

/// The manual review control's labels.
public enum ManualReview {
    public static let pickerTitle = "Manual review"
    static let repoFieldLabel = "Manual review"

    /// The repo's Manual review line in the Repos window: its setting (`On`/`Off`) and, while the repo
    /// writes no key, that this is the default. A value Symphony rejects is shown as it is, in the problem
    /// tone, so it stays visible until another one is picked.
    public static func repoField(_ entry: RepositoryEntry) -> RepoField {
        guard let raw = entry.manualReview else {
            return RepoField(repoFieldLabel, ManualReviewChoice.off.title, detail: "The default.")
        }
        guard let choice = ManualReviewChoice(rawValue: raw) else {
            return RepoField(repoFieldLabel, raw, detail: "Symphony accepts on or off.", tone: .problem)
        }
        return RepoField(repoFieldLabel, choice.title, detail: choice.explanation)
    }
}

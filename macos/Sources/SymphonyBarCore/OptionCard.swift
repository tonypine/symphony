import Foundation

/// N7: one option of a decision as its card draws it, for a request (D2c) and for a plan's decisions (C16, DD-4):
/// the label, its effect under it, the trade-off tags (N8), and why it is recommended on the recommended card.
public struct OptionCard: Equatable, Identifiable {
    /// The option's number, from 1: its number key.
    public var number: Int
    /// How many options the decision offers.
    public var count: Int
    public var label: String
    public var effect: String?
    public var recommended: Bool
    public var tradeoffs: [InboxReview.Action.Tradeoff]
    /// Why we recommend it, on the recommended card only.
    public var reason: String?

    public var id: Int { number }
    /// The option's index in its decision: what a pick records.
    public var index: Int { number - 1 }

    public init(
        number: Int,
        count: Int,
        label: String,
        effect: String? = nil,
        recommended: Bool = false,
        tradeoffs: [InboxReview.Action.Tradeoff] = [],
        reason: String? = nil
    ) {
        self.number = number
        self.count = count
        self.label = label
        self.effect = effect
        self.recommended = recommended
        self.tradeoffs = tradeoffs
        self.reason = reason
    }

    /// The line on the recommended card: "Why we recommend it:" and the reason.
    public static let reasonLead = "Why we recommend it:"

    /// The cards of a request's options, the recommendation's reason on the recommended one.
    public static func cards(for action: InboxReview.Action) -> [OptionCard] {
        action.options.enumerated().map { index, option in
            OptionCard(
                number: index + 1,
                count: action.options.count,
                label: option.label,
                effect: option.effect,
                recommended: option.recommended,
                tradeoffs: option.tradeoffs,
                reason: option.recommended ? action.recommendationReason : nil
            )
        }
    }

    /// The cards of a plan's decision: a brief gives labels only, and its recommendation line is the reason.
    public static func cards(for decision: InboxReview.Decision) -> [OptionCard] {
        decision.options.enumerated().map { index, label in
            let recommended = index == decision.recommended
            return OptionCard(
                number: index + 1,
                count: decision.options.count,
                label: label,
                recommended: recommended,
                reason: recommended ? decision.recommendation : nil
            )
        }
    }

    /// What VoiceOver reads for the card, as one element: "Option 1 of 3, Leave it to TP-891, recommended, selected.
    /// TP-892 goes back to Code Review. Good: TP-892 can merge today. Why we recommend it: …"
    public func accessibilityLabel(selected: Bool) -> String {
        let head = ["Option \(number) of \(count)", label, recommended ? "recommended" : nil, selected ? "selected" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
        let parts = [head, effect]
            + tradeoffs.map { "\($0.kind.word): \($0.text)" }
            + [reason.map { "\(Self.reasonLead) \($0)" }]
        return parts.compactMap { $0 }.map(Self.sentence).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `text` ending as a sentence, without doubling the stop it already has.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }
}

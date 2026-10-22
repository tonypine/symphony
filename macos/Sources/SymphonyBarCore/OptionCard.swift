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
    /// True on the write-in (N11), the last card of a request the Inbox answers: picked, it takes the Director's own
    /// words.
    public var isWriteIn: Bool

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
        reason: String? = nil,
        isWriteIn: Bool = false
    ) {
        self.number = number
        self.count = count
        self.label = label
        self.effect = effect
        self.recommended = recommended
        self.tradeoffs = tradeoffs
        self.reason = reason
        self.isWriteIn = isWriteIn
    }

    /// The line on the recommended card: "Why we recommend it:" and the reason.
    public static let reasonLead = "Why we recommend it:"

    /// N11's label, the line under it, and the hint under its field.
    public static let writeInLabel = "Answer in my own words…"
    public static let writeInEffect = "Tell the agent what to do instead."
    public static let writeInHint = "The agent reads this as your answer. Name tickets by their number; they become links."

    /// The cards of a request's options, the recommendation's reason on the recommended one; with `writeIn` (a request
    /// the Inbox answers), the write-in after them, its number the one after the last option.
    public static func cards(for action: InboxReview.Action, writeIn: Bool = false) -> [OptionCard] {
        let count = action.options.count + (writeIn && !action.options.isEmpty ? 1 : 0)
        let options = action.options.enumerated().map { index, option in
            OptionCard(
                number: index + 1,
                count: count,
                label: option.label,
                effect: option.effect,
                recommended: option.recommended,
                tradeoffs: option.tradeoffs,
                reason: option.recommended ? action.recommendationReason : nil
            )
        }
        guard count > action.options.count else { return options }
        return options + [OptionCard(number: count, count: count, label: writeInLabel, effect: writeInEffect, isWriteIn: true)]
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

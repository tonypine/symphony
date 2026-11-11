import Foundation

/// What the Send under a Question block, or at the foot of the decision sheet, says (the catalog's Question block and
/// Decision sheet): its title, the answer it repeats, how many Questions are answered, and why it is off while there is
/// nothing to send.
public struct QuestionSend: Equatable {
    /// How many Questions the Send answers.
    public var total: Int
    /// How many of them have an answer to send.
    public var answered: Int
    /// The one Question's answer as Send repeats it: the picked option's label, or "In your own words"; nil while it
    /// has none, and with more than one Question.
    public var answer: String?
    /// Why Send is off: "Pick an answer first.", "Write your answer first.", or with more than one Question "Answer at
    /// least one question first."; nil when there is an answer to send.
    public var refusal: String?

    /// The line Send repeats for an answer written in the Director's own words.
    public static let ownWords = "In your own words"
    public static let pickFirst = "Pick an answer first."
    public static let writeFirst = "Write your answer first."
    public static let answerOneFirst = "Answer at least one question first."

    /// The Send of `questions` with the Director's `picks`, each Question answered by its index in `picks`.
    public init(questions: [InboxReview.Action], picks: DecisionPicks) {
        self.init(states: questions.enumerated().map { Self.state(of: $0.element, at: $0.offset, picks: picks) })
    }

    /// The Send of one Question, answered by `index` in `picks` (0 for a request).
    public init(question: InboxReview.Action, decision index: Int = 0, picks: DecisionPicks) {
        self.init(states: [Self.state(of: question, at: index, picks: picks)])
    }

    private init(states: [State]) {
        total = states.count
        answered = states.filter { if case .answered = $0 { true } else { false } }.count
        if states.count == 1, let state = states.first {
            switch state {
            case let .answered(text): answer = text
            case let .refused(reason): refusal = reason
            }
        } else if answered == 0 {
            refusal = Self.answerOneFirst
        }
    }

    /// True when there is an answer to send.
    public var enabled: Bool { refusal == nil }

    /// "Send Decision…", or "Send 2 Decisions…" once more than one is answered.
    public var title: String { answered > 1 ? "Send \(answered) Decisions…" : "Send Decision…" }

    /// The line above Send in the decision sheet: "Answered 1 of 2"; nil for one Question, whose answer shows instead.
    public var progress: String? { total > 1 ? "Answered \(answered) of \(total)" : nil }

    private enum State {
        case answered(String)
        case refused(String)
    }

    private static func state(of question: InboxReview.Action, at index: Int, picks: DecisionPicks) -> State {
        guard let pick = question.pickedIndex(picks, decision: index) else { return .refused(pickFirst) }
        guard pick == question.writeInIndex else { return .answered(question.options[pick].label) }
        let text = (picks.writeIns[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .refused(writeFirst) : .answered(ownWords)
    }
}

/// The decision sheet's sizes and motion (the catalog's Decision sheet): 520 pt over the right of a laptop's page,
/// 600 pt as the desktop's column; it slides in on `motion.sheet` while the page behind it dims on `motion.standard`.
public enum DecisionSheetLayout {
    public static let laptopWidth: Double = 520
    public static let desktopWidth: Double = 600
    /// How dark the page behind the laptop's sheet goes.
    public static let scrimOpacity: Double = 0.18

    /// The header's title: "Your decision", or "2 decisions wait on you".
    public static func title(count: Int) -> String {
        count == 1 ? "Your decision" : "\(count) decisions wait on you"
    }

    /// A Question's kicker in the sheet: "QUESTION 1 OF 2" with more than one, else nil (the block's "Your decision").
    public static func kicker(index: Int, count: Int) -> String? {
        count > 1 ? "Question \(index + 1) of \(count)" : nil
    }
}

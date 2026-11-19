import SwiftUI
import SymphonyBarCore

// The blocks inside a Conductor message, each drawn by the component the Gallery has for it: the run group's own step
// rows, the finding card's screenshot thumbnails, the Progress meter with a Key-value list, the Question block, the story
// rows, and the four made for the message (Run path, Attempts, Expected and actual, Findings ledger).

/// What the ticket page hands the Conductor's Question blocks: the open Questions with their picks, and what answering
/// does, which is the Inbox's one decision path; and the decisions recorded, for a Question already answered.
public struct ConductorQuestionContext {
    public var questions: [InboxReview.Action]
    public var picks: DecisionPicks
    /// Picks option (first) in Question (second).
    public var pick: (Int, Int) -> Void
    /// Keeps a Question's own words: (text, Question).
    public var writeIn: (String, Int) -> Void
    public var send: () -> Void
    public var decisions: [TicketDecision]
    public var narrow: Bool

    public init(
        questions: [InboxReview.Action] = [], picks: DecisionPicks = DecisionPicks(), pick: @escaping (Int, Int) -> Void = { _, _ in },
        writeIn: @escaping (String, Int) -> Void = { _, _ in }, send: @escaping () -> Void = {}, decisions: [TicketDecision] = [],
        narrow: Bool = false
    ) {
        self.questions = questions
        self.picks = picks
        self.pick = pick
        self.writeIn = writeIn
        self.send = send
        self.decisions = decisions
        self.narrow = narrow
    }

    /// The open Question `decisionID` names, with its place among them.
    func open(_ decisionID: String) -> (index: Int, action: InboxReview.Action)? {
        questions.enumerated().first { $0.element.questionID == decisionID || $0.element.commentID == decisionID }
            .map { ($0.offset, $0.element) }
    }

    /// "Answered: Stop and send back", "No longer open": what became of a Question that is not open.
    func outcome(_ decisionID: String) -> String {
        guard let decision = decisions.first(where: { $0.id == decisionID }) else { return "No longer open" }
        return "Answered: " + decision.answer
    }
}

public extension EnvironmentValues {
    @Entry var conductorQuestions = ConductorQuestionContext()
}

/// The blocks of one message, in order, one under another.
public struct ConductorBlocksView: View {
    let blocks: [ConductorBlock]

    /// A block runs no wider than this, as the bench draws it.
    public static let maxWidth: CGFloat = 620

    public init(blocks: [ConductorBlock]) {
        self.blocks = blocks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ConductorBlockView(block: block)
                    .frame(maxWidth: Self.maxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConductorBlockView: View {
    let block: ConductorBlock

    var body: some View {
        switch block {
        case let .steps(steps): StepsBlockView(steps: steps)
        case let .evidence(evidence): EvidenceBlockView(evidence: evidence)
        case let .budget(budget): BudgetBlockView(budget: budget)
        case let .path(path): RunPath(path: path)
        case let .attempts(attempts): AttemptsList(attempts: attempts)
        case let .compare(compare): ExpectedAndActual(compare: compare)
        case let .findings(findings): FindingsLedger(findings: findings)
        case let .epic(epic): EpicBlockView(epic: epic)
        case let .question(question): QuestionBlockView(question: question)
        }
    }
}

// MARK: - Steps

/// The run's steps, as the run group's own rows draw them, not expandable here.
struct StepsBlockView: View {
    let steps: ConductorBlock.Steps

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(Self.runSteps(steps).enumerated()), id: \.offset) { _, step in
                StepSummaryRow(step: step)
            }
        }
        .padding(.leading, DesignTokens.Space.s2)
        .overlay(alignment: .leading) {
            Rectangle().fill(DesignTokens.Surface.separator.color).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(StepList.accessibilityLabel)
    }

    static func runSteps(_ block: ConductorBlock.Steps) -> [RunStep] {
        block.steps.enumerated().map { index, step in
            var row = RunStep(
                id: "\(index)", stepID: step.stepID ?? "\(index)", title: step.title,
                state: step.outcome == .failed ? .failed : step.outcome == .skipped ? .skipped : .done
            )
            row.durationSeconds = step.durationMs.map { $0 / 1_000 }
            row.reason = step.returnsTo.map { "back to \($0)" }
            return row
        }
    }
}

// MARK: - Evidence

/// The screenshots a QA finding shows on the timeline, loaded the same way and opening the same way.
private struct EvidenceBlockView: View {
    let evidence: ConductorBlock.Evidence

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: FindingShot.size.width), spacing: DesignTokens.Space.s2, alignment: .topLeading)], alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(Array(evidence.items.enumerated()), id: \.offset) { _, item in
                FindingShot(shot: item.screenshot)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Budget

/// The Progress meter for the tokens used against the cap, then a Key-value list: the tokens by kind of run, and what is
/// left before the cap.
struct BudgetBlockView: View {
    let budget: ConductorBlock.Budget

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            if let percent = budget.percent {
                ProgressMeter(line: Self.meterLabel, percent: percent)
            }
            KeyValueList(style: .secondary, rowGap: DesignTokens.KeyValue.compactRowGap) {
                if budget.parts.isEmpty {
                    KeyValueRow(Self.usedLabel, text: Overview.tokens(budget.tokensUsed))
                }
                ForEach(Array(budget.parts.enumerated()), id: \.offset) { _, part in
                    KeyValueRow(Self.label(part), text: Overview.tokens(part.tokens))
                }
                if let left = budget.tokensLeft {
                    KeyValueRow(Self.leftLabel, text: Overview.tokens(left))
                }
            }
        }
    }

    static let meterLabel = "Tokens"
    static let usedLabel = "Used"
    static let leftLabel = "Left before the cap"

    /// "QA, 2 runs", "Implementation, 3 runs": the kind of run and how many.
    static func label(_ part: ConductorBlock.Budget.Part) -> String {
        let words = part.kind.replacingOccurrences(of: "_", with: " ")
        let name = words.prefix(1).uppercased() + words.dropFirst()
        let title = ["qa": "QA", "ci fix": "CI fix"][words.lowercased()] ?? name
        return part.runs > 0 ? "\(title), \(part.runs) \(part.runs == 1 ? "run" : "runs")" : title
    }
}

// MARK: - Epic

/// The ticket's epic as story rows, the current ticket's row marked.
struct EpicBlockView: View {
    let epic: ConductorBlock.Epic

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(epic.rows.enumerated()), id: \.offset) { index, row in
                StoryRow(
                    number: index + 1, mark: Self.mark(row), identifier: row.identifier, title: row.title ?? row.identifier,
                    quiet: Self.status(row.state) == .done, struck: row.state?.lowercased().contains("cancel") == true, current: row.current,
                    label: Self.label(row), open: {}
                ) {
                    EmptyView()
                } trail: {
                    if let state = row.state { Text(Self.words(state)) }
                }
            }
        }
    }

    static func status(_ state: String?) -> DesignTokens.Status {
        let state = state?.lowercased() ?? ""
        if ["done", "merged", "shipped", "landed"].contains(where: state.contains) { return .done }
        if ["fix", "problem", "fail", "stuck"].contains(where: state.contains) { return .problem }
        if ["progress", "review", "working", "qa", "rework", "coding", "merging"].contains(where: state.contains) { return .working }
        if ["wait", "decision", "question"].contains(where: state.contains) { return .you }
        return .idle
    }

    static func mark(_ row: ConductorBlock.Epic.Row) -> RowLead { .status(status(row.state)) }

    /// "in_review" as "In review".
    static func words(_ state: String) -> String {
        let words = state.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func label(_ row: ConductorBlock.Epic.Row) -> String {
        [row.identifier, row.title, row.state.map(words), row.current ? "this ticket" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Question

/// A Question the Conductor asks. While the Inbox holds it open it is the Question block, answered through the Inbox's
/// one decision path; once it is answered, or when the app cannot find it, its title and outcome on one line.
private struct QuestionBlockView: View {
    let question: ConductorBlock.Question
    @Environment(\.conductorQuestions) private var context

    var body: some View {
        if let open = context.open(question.decisionID) {
            QuestionBlock(
                action: open.action, picks: context.picks, index: open.index, pick: { context.pick($0, open.index) },
                writeIn: { context.writeIn($0, open.index) }, narrow: context.narrow, showsKeys: false, send: context.send
            ) {
                EmptyView()
            }
        } else {
            HStack(spacing: DesignTokens.Space.s2) {
                BlockMark(kind: .upcoming)
                Text(question.title ?? question.question ?? "Question")
                    .font(DesignTokens.TypeStyle.body.font.weight(.semibold))
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(context.outcome(question.decisionID))
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

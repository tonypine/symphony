import AppKit
import SwiftUI
import SymphonyBarCore

// The catalog's Step list and Run group (`docs/design/director-ticket-page.md` §1 facts 4, 8 and 13, §4): a run folds
// into its steps and a step into its conversation (`RunConversationView`): what the agent wrote, what it did after
// each note folded into one line, and each failure in its own row. The fold opens its height on the standard easing
// and its chevron turns on a spring; under Reduce Motion everything is there at once.

// MARK: - Fold keys

/// Return and Space toggle the fold that has the keyboard (§4 Keyboard).
public enum FoldKeys {
    public static let keys: Set<KeyEquivalent> = [.return, .space]

    /// Whether `key` toggles a focused fold: Return or Space with no modifier held.
    public static func toggles(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        modifiers.subtracting(.numericPad).isEmpty && keys.contains(key)
    }
}

// MARK: - A transcript line

/// One line of a step, as a group of its conversation unfolds into: its time, a glyph for what it is, and its text.
/// What the agent said reads in `ChipText`, its ticket and PR mentions chips; a tool call names its tool and its
/// arguments in short; a result says how long its tool took and is marked when it failed.
struct TranscriptLineRow: View {
    let line: TranscriptLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(line.date.map(Self.clock) ?? "")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(line.failed ? DesignTokens.Status.problem.tint : .secondary)
                .frame(width: 14)
                .help(Self.glyphHelp(line))
            text
                .frame(maxWidth: DesignTokens.Measure.reading + 120, alignment: .leading)
            Spacer(minLength: 0)
            if line.kind == .result {
                HStack(spacing: DesignTokens.Space.s1) {
                    if line.failed {
                        Text(Self.failedWord)
                            .font(DesignTokens.TypeStyle.label.font)
                            .foregroundStyle(DesignTokens.Status.problem.tint)
                    }
                    if let duration = line.durationText {
                        Text(duration)
                            .font(DesignTokens.TypeStyle.caption.font)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel)
    }

    @ViewBuilder private var text: some View {
        switch line.kind {
        case .say:
            ChipText(text: line.text, font: DesignTokens.TypeStyle.secondary.nsFont)
        case .tool:
            (Text(line.toolName.map { $0 + "  " } ?? "").fontWeight(.semibold) + Text(line.body))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
        case .result:
            Text(line.text.isEmpty ? Self.emptyResult : line.text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(line.failed ? AnyShapeStyle(DesignTokens.Status.problem.tint) : AnyShapeStyle(.secondary))
                .lineLimit(3)
                .truncationMode(.tail)
        }
    }

    private var glyph: String {
        switch line.kind {
        case .say: "text.bubble"
        case .tool: "wrench.and.screwdriver"
        case .result: line.failed ? "xmark.octagon.fill" : "arrow.turn.down.right"
        }
    }

    static let failedWord = "Failed"
    static let emptyResult = "(nothing came back)"

    static func glyphHelp(_ line: TranscriptLine) -> String {
        switch line.kind {
        case .say: "The agent said"
        case .tool: "A tool call"
        case .result: line.failed ? "What it returned: the tool failed" : "What it returned"
        }
    }

    /// "14:02:07".
    static func clock(_ date: Date) -> String {
        SharedDateFormatter.string(date, format: "HH:mm:ss", timeZone: NSTimeZone.default)
    }
}

// MARK: - Step list

/// A run's steps, top to bottom, each unfolding into what the agent did in it. A completed step's lines are its
/// transcript artifact, read on its first unfold and kept by `transcripts`; the step the run now is on shows its
/// newest lines live. The step it is on, and one that failed or asked a question, start unfolded.
public struct StepList: View {
    let steps: [RunStep]
    /// What the Conductor said while it watched the run, each between the steps its time puts it.
    let conductorMessages: [RunConductorMessage]
    @ObservedObject var transcripts: StepTranscripts
    @State private var folds: FoldState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `unfolded` pins which steps are open (a render's fixed state); nil opens each step that opens by default,
    /// as the ticket read brings it, until the person folds it.
    public init(steps: [RunStep], transcripts: StepTranscripts, unfolded: Set<String>? = nil, conductorMessages: [RunConductorMessage] = []) {
        self.steps = steps
        self.conductorMessages = conductorMessages
        self.transcripts = transcripts
        _folds = State(initialValue: unfolded.map { FoldState(ids: steps.map(\.id), unfolded: $0) } ?? FoldState())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            conductorNotes(after: nil)
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                StepRow(step: step, transcripts: transcripts, unfolded: folds.isUnfolded(step)) {
                    withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { folds.toggle(step) }
                }
                conductorNotes(after: index)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel)
    }

    /// The Conductor's messages that come after step `index` (nil: before the first).
    @ViewBuilder private func conductorNotes(after index: Int?) -> some View {
        ForEach(conductorMessages.filter { $0.afterStep == index }) { placed in
            ConductorRunNote(message: placed.message)
        }
    }

    public static let accessibilityLabel = "Steps of the run"
}

/// One step: its header line and, unfolded, its conversation, with "Show all events" in the header to unfold every
/// group of it at once.
private struct StepRow: View {
    let step: RunStep
    @ObservedObject var transcripts: StepTranscripts
    let unfolded: Bool
    let toggle: () -> Void
    @State private var groups = ConversationFolds()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The step has lines to show: its transcript or the run now's.
    private var showsAllToggle: Bool { unfolded && (step.transcript != nil || !step.liveLines.isEmpty) }

    /// A step's lines start under its name: past the chevron, the mark and the gaps between them.
    static let linesLeading: CGFloat = {
        let gaps: CGFloat = 2 * DesignTokens.Space.s2
        return 12 + StepMark.size + gaps
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleHead(
                expanded: unfolded, style: .line, disabledReason: step.cannotUnfoldReason,
                accessibilityLabel: step.canUnfold ? step.foldAccessibilityLabel(folded: !unfolded) : step.accessibilityLabel,
                toggle: toggle
            ) {
                StepHeaderLabel(step: step, reserved: showsAllToggle ? StepShowAllButton.width : 0)
            }
            .overlay(alignment: .trailing) {
                if showsAllToggle {
                    StepShowAllButton(on: groups.showsAll) {
                        withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { groups.toggleAll() }
                    }
                    .padding(.trailing, StepHeaderLabel.stateColumn + StepHeaderLabel.durationColumn + 2 * DesignTokens.Space.s2)
                }
            }
            .qaPart("head")
            // A walk that judged several walkthrough steps in one session: one line per step, with its own status,
            // folded or not.
            if let results = step.answer?.results, !results.isEmpty {
                CheckResultRows(results: results)
                    .padding(.leading, Self.linesLeading)
                    .padding(.vertical, DesignTokens.Space.s1)
            }
            // The screenshots the run recorded in this step, folded or not.
            if !step.screenshots.isEmpty {
                ScreenshotRow(shots: step.screenshots)
                    .padding(.leading, Self.linesLeading)
                    .padding(.vertical, DesignTokens.Space.s1)
            }
            if unfolded {
                if step.answer != nil || step.hasLongReason {
                    StepAnswerView(answer: step.answer ?? StepAnswer(), reason: step.hasLongReason ? step.reasonDetail : nil)
                        .padding(.leading, Self.linesLeading)
                        .padding(.top, DesignTokens.Space.s1)
                }
                StepLines(step: step, transcripts: transcripts, groups: $groups)
                    .padding(.leading, Self.linesLeading)
                    .padding(.top, DesignTokens.Space.s1)
                    .padding(.bottom, DesignTokens.Space.s2)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .background {
            if unfolded {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .fill(step.state.status.tint.opacity(step.state == .done || step.state == .skipped ? 0.0 : 0.06))
                    .padding(.horizontal, -DesignTokens.Space.s2)
            }
        }
        .clipped()
        .qaSection(QAElementNames.step(step.title))
    }
}

/// A step's row as the run group draws it, with no fold: its mark, name and reason, state and duration. A Conductor
/// message draws the steps of a run with it, where the lines of a step are not the point.
struct StepSummaryRow: View {
    let step: RunStep

    var body: some View {
        StepHeaderLabel(step: step)
            .padding(.vertical, DesignTokens.Space.s1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(step.accessibilityLabel)
    }
}

/// A step's head (the catalog's `.sl-head`): its mark, its name with its reason after it, then its state and its
/// duration in right-aligned columns, so the steps of a run line up.
private struct StepHeaderLabel: View {
    let step: RunStep
    /// Room kept before the state column for what the row draws over it ("Show all events").
    var reserved: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            StepMark(step: step)
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text(step.title)
                    .font(DesignTokens.TypeStyle.body.font.weight(step.isLive ? .semibold : .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let reason = step.reason {
                    Text(reason)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if reserved > 0 { Color.clear.frame(width: reserved, height: 1) }
            Text(step.state.word + (step.answer?.result?.extraWord.map { " · " + $0 } ?? ""))
                .font(DesignTokens.TypeStyle.secondary.font.weight(.medium))
                .foregroundStyle(stateStyle)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: Self.stateColumn, alignment: .trailing)
            Text(step.duration ?? "")
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: Self.durationColumn, alignment: .trailing)
        }
    }

    /// A finished or skipped step's state reads quietly; any other in its status's colour.
    private var stateStyle: AnyShapeStyle {
        switch step.state {
        case .done, .skipped: AnyShapeStyle(.secondary)
        default: AnyShapeStyle(step.state.status.text)
        }
    }

    /// The state's column, wide enough for "Asked a question" to keep the durations in one column.
    static let stateColumn: CGFloat = 96
    /// The duration's column (`.sl-dur`: at least 52 px, right-aligned).
    static let durationColumn: CGFloat = 52
}

/// The walkthrough steps a grouped walk judged, one line each in the step row's style: the check's mark, "Step 2" with
/// what it saw after it, and its own state in the state column, so a failed check stands apart from those that passed.
struct CheckResultRows: View {
    let results: [StepAnswer.CheckResult]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(Array(results.enumerated()), id: \.offset) { _, check in
                CheckResultRow(check: check)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel)
    }

    static let accessibilityLabel = "Checks of the step"
}

private struct CheckResultRow: View {
    let check: StepAnswer.CheckResult

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            TimelineMark(symbol: check.state.markSymbol, tint: check.state.status.tint, fill: check.state.status.badgeFill, kind: .step)
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text(check.title)
                    .font(DesignTokens.TypeStyle.body.font.weight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let actual = check.result.actual {
                    Text(actual)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(check.word)
                .font(DesignTokens.TypeStyle.secondary.font.weight(.medium))
                .foregroundStyle(check.state == .done ? DesignTokens.TextColor.secondary.color : check.state.status.text)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: StepHeaderLabel.stateColumn, alignment: .trailing)
            // The step's duration column, empty: a check has no time of its own.
            Color.clear.frame(width: StepHeaderLabel.durationColumn, height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(check.accessibilityLabel)
    }
}

/// A step's mark (`.sl-mark`): its state's glyph in a 20 pt circle of its tint, or the live dot while it works.
private struct StepMark: View {
    let step: RunStep

    static let size: CGFloat = TimelineMark.stepSize

    var body: some View {
        TimelineMark(
            symbol: step.state.markSymbol,
            tint: step.state.status.tint,
            fill: step.state.status.badgeFill,
            kind: .step,
            live: step.isLive
        )
    }
}

/// An unfolded step's conversation: the run now's lines, else its transcript, read on the first unfold.
private struct StepLines: View {
    let step: RunStep
    @ObservedObject var transcripts: StepTranscripts
    @Binding var groups: ConversationFolds

    var body: some View {
        Group {
            if step.isLive, !step.liveLines.isEmpty || step.transcript == nil {
                RunConversationView(entries: RunConversation.entries(step.liveLines, live: true), folds: $groups)
            } else if let transcript = step.transcript {
                switch transcripts.lines(transcript) {
                case .loading:
                    Note(text: Self.loading)
                case let .loaded(lines):
                    if lines.isEmpty { Note(text: Self.empty) } else { RunConversationView(entries: RunConversation.entries(lines), folds: $groups) }
                case .unavailable:
                    Note(text: Self.unavailable)
                case .failed:
                    Note(text: Self.failed)
                }
            }
        }
        .onAppear { if let transcript = step.transcript { transcripts.load(transcript) } }
    }

    static let loading = "Reading what happened in this step…"
    static let empty = "The agent said nothing in this step."
    static let unavailable = "Symphony no longer keeps what happened in this step."
    static let failed = "Couldn't read what happened in this step. Fold it and unfold it to try again."

    private struct Note: View {
        let text: String
        var body: some View {
            Text(text).font(DesignTokens.TypeStyle.secondary.font).foregroundStyle(.secondary)
        }
    }
}

/// "Show all events" in an unfolded step's header: unfolds every group of the step's conversation at once; on, it is
/// selected, and a click folds them all again.
private struct StepShowAllButton: View {
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        Button(ConversationFolds.showAll, action: toggle)
            .directorButton(.quiet, size: .small, glyph: on ? "checkmark" : nil, selected: on)
            .fixedSize()
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(on ? "On" : "Off")
            .qaPart("show-all")
    }

    /// The room the header keeps for it.
    static let width: CGFloat = 132
}

// MARK: - Marks

/// A state's mark: its symbol in its tint, or the live status dot while it works.
struct StateMark: View {
    let symbol: String
    let status: DesignTokens.Status
    let live: Bool
    var size: Double = 14

    var body: some View {
        Group {
            if live {
                StatusDot(.working, size: size < 15 ? .regular : .large, live: true)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(status.tint)
            }
        }
        .frame(width: size + 2, height: size + 2)
        .accessibilityHidden(true)
    }
}


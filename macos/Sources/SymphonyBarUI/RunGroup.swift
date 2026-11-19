import SwiftUI
import SymphonyBarCore

/// One run of an agent as a foldable group (the catalog's Run group): its header line (the kind and number, the state
/// mark and word, a short bar per step, where it stopped when folded, and its duration), the meta line under it (the
/// model by its name, the time and the tokens: "Claude Opus 5.5 · 12 min · 600K tokens", the prototype's `.run-meta`),
/// and unfolded, its steps in a `StepList`. The run now starts unfolded and live; an ended run starts folded.
public struct RunGroup: View {
    let run: RunGroupModel
    @ObservedObject var transcripts: StepTranscripts
    let unfoldedSteps: Set<String>?
    /// The person's own fold, over the run's default: the run now opens, and folds once it ended, until they fold it.
    @State private var folded: Bool?
    /// The fold, when the view around it keeps it (the timeline, whose Return folds the selected run).
    let fold: Binding<Bool>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.readSession) private var readSession

    /// `unfolded` and `unfoldedSteps` say what is open to start with; nil opens what opens by default. `fold`, when
    /// given, keeps whether the run is unfolded instead, and `unfolded` is ignored.
    public init(
        run: RunGroupModel, transcripts: StepTranscripts, unfolded: Bool? = nil, unfoldedSteps: Set<String>? = nil,
        fold: Binding<Bool>? = nil
    ) {
        self.run = run
        self.transcripts = transcripts
        self.unfoldedSteps = unfoldedSteps
        self.fold = fold
        _folded = State(initialValue: unfolded.map { !$0 })
    }

    private var unfolded: Bool { fold?.wrappedValue ?? folded.map { !$0 } ?? run.opensByDefault }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DesignTokens.Space.s1) {
                CollapsibleHead(expanded: unfolded, style: .line, accessibilityLabel: run.foldAccessibilityLabel(folded: !unfolded) + ", " + run.accessibilityLabel, toggle: toggle) {
                    RunHeaderLabel(run: run, folded: !unfolded)
                }
                if let readSession {
                    RunMoreMenu(run: run, readSession: readSession)
                }
            }
            .padding(.vertical, DesignTokens.Space.s1)
            if run.meta != nil {
                RunMetaLine(run: run)
                    .padding(.leading, Self.metaIndent)
                    .padding(.bottom, DesignTokens.Space.s1)
            }
            if unfolded {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    if !run.steps.isEmpty {
                        StepList(steps: run.steps, transcripts: transcripts, unfolded: unfoldedSteps, conductorMessages: run.conductorMessages)
                    } else {
                        ForEach(run.conductorMessages) { placed in
                            ConductorRunNote(message: placed.message)
                        }
                    }
                    // The run now on no step (a QA or Code Review run walks none) has its newest lines here.
                    if !run.liveLines.isEmpty {
                        LineList(lines: run.liveLines, live: true)
                    }
                    if !run.screenshots.isEmpty {
                        ScreenshotRow(shots: run.screenshots)
                    }
                    ForEach(run.steers) { steer in
                        RunSteerEntry(steer: steer)
                    }
                    if run.steps.isEmpty, run.liveLines.isEmpty, run.screenshots.isEmpty, run.steers.isEmpty, run.conductorMessages.isEmpty {
                        Text(Self.noSteps)
                            .font(DesignTokens.TypeStyle.secondary.font)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, DesignTokens.Space.s4)
                .padding(.vertical, DesignTokens.Space.s2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(DesignTokens.Surface.separator.color)
                        .frame(width: 1.5)
                        .padding(.leading, 5)
                }
                .padding(.leading, DesignTokens.Space.s1)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DesignTokens.Space.s2)
        .background {
            if unfolded {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .fill(DesignTokens.StateSurface.hover.fill.opacity(0.6))
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
    }

    private func toggle() {
        withAnimation(.motion(.standard, reduceMotion: reduceMotion)) {
            if let fold { fold.wrappedValue.toggle() } else { folded = unfolded }
        }
    }

    public static let noSteps = "This run recorded no steps."
    /// The meta line starts under the run's title: past the fold's chevron and the run's mark.
    static let metaIndent: CGFloat = 12 + DesignTokens.Space.s2 + TimelineMark.size + DesignTokens.Space.s2
}

/// The line under a run's head: its model by name, its time (counting on while it runs) and its tokens.
struct RunMetaLine: View {
    let run: RunGroupModel
    @Environment(\.timelineReference) private var reference

    var body: some View {
        LiveDurationText(seconds: run.durationSeconds ?? 0, reference: run.isLive && run.durationSeconds != nil ? reference : nil) { seconds in
            var run = run
            if run.durationSeconds != nil { run.durationSeconds = seconds }
            return run.meta ?? ""
        }
        .font(DesignTokens.TypeStyle.secondary.font)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
        .help(run.endAnswer.map(Self.entriesHelp) ?? Self.help)
    }

    static let help = "The model, how long the run took and the tokens it spent"

    /// What the run answered when it ended, a line each: "Verdict: approved".
    static func entriesHelp(_ answer: StepAnswer) -> String {
        answer.entries.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}

/// Opens the session reader on a run: the window that reads its whole session (TP-1452). A Run group shows its More
/// menu only where the view around it gives one.
///
/// Two actions for the same ticket are equal, so a page that draws again (each read, each scroll the page measures)
/// hands its Run groups the same value and SwiftUI leaves their More menus as they are, instead of rebuilding every
/// run's menu on every update of a long timeline.
public struct ReadSessionAction: Equatable {
    /// The ticket whose runs it opens.
    let identifier: String
    let handler: (RunGroupModel) -> Void

    public init(_ identifier: String, _ handler: @escaping (RunGroupModel) -> Void) {
        self.identifier = identifier
        self.handler = handler
    }

    public func callAsFunction(_ run: RunGroupModel) { handler(run) }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identifier == rhs.identifier }
}

public extension EnvironmentValues {
    @Entry var readSession: ReadSessionAction?
}

/// The run's More (C54): "Read the whole session", off with its reason while the run has nothing to read. A quiet
/// small menu button whose menu exists only while it is open, so a long timeline with the run now live builds none up
/// front (a stock `Menu` built an AppKit pop-up per run and kept the page from answering, TP-1452's QA on TP-1244).
private struct RunMoreMenu: View {
    let run: RunGroupModel
    let readSession: ReadSessionAction

    var body: some View {
        MenuButton(
            Self.title, glyph: "ellipsis", size: .small, quiet: true, alignment: .trailing,
            help: SessionReader.canRead(run) ? Self.title : SessionReader.nothingToRead,
            accessibilityLabel: Self.title + ", " + run.title
        ) {
            [MenuItem(SessionReader.menuTitle, disabledReason: SessionReader.canRead(run) ? nil : SessionReader.nothingToRead) { readSession(run) }]
        }
    }

    static let title = "More"
}

/// The run's header line. In a column too narrow for it on one line (the desktop's main column beside the decisions,
/// TP-1449), its tokens, model and duration go to a second line under it, and where it stopped gives way first, so
/// nothing runs past the column.
///
/// `RunHeaderLayout` places one copy of the line's parts, not a `ViewThatFits` between two copies: picking between
/// copies tore down and rebuilt the losing one's views (the live dot, the step bars) on every pass of the page's
/// layout, and the run now's header kept the ticket page laying itself out forever, so it answered no accessibility
/// read and no key (TP-1466, QA's main-thread sample on TP-1244).
private struct RunHeaderLabel: View {
    let run: RunGroupModel
    let folded: Bool
    @Environment(\.timelineReference) private var reference

    var body: some View {
        RunHeaderLayout {
            HStack(alignment: .center, spacing: DesignTokens.Space.s2) { lead }
            HStack(alignment: .center, spacing: DesignTokens.Space.s2) { facts }
        }
    }

    @ViewBuilder private var lead: some View {
        RunMark(run: run)
        if run.showsNewDot {
            Circle()
                .fill(DesignTokens.ColorToken.accent.color)
                .frame(width: 6, height: 6)
                .help(TimelineEntry.newHelp)
        }
        Text(run.title)
            .font(DesignTokens.TypeStyle.body.font.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
        Badge(status: run.state.status, word: run.word)
            .fixedSize()
        if !run.steps.isEmpty {
            StepBars(steps: run.steps)
        }
        if folded, let whereText = run.whereText {
            Text(whereText)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
    }

    // The model and tokens are the meta line's, under the head; the head keeps the duration at its end (`.dur`).
    @ViewBuilder private var facts: some View {
        if let seconds = run.durationSeconds {
            // The run now's time so far counts on by itself; the timeline isn't built again for it (TP-1479).
            LiveDurationText(seconds: seconds, reference: run.isLive ? reference : nil) { seconds in
                var run = run
                run.durationSeconds = seconds
                return run.duration ?? ""
            }
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .help(Self.durationHelp)
        }
    }

    static let durationHelp = "How long the run took"
}

/// A run's mark (the catalog's `.run-head .mark`): its state's glyph in a 24 pt circle of its tint, or the live dot
/// while it works.
struct RunMark: View {
    let run: RunGroupModel

    var body: some View {
        TimelineMark(
            symbol: run.state.markSymbol,
            tint: run.state.status.tint,
            fill: run.state.status.badgeFill,
            kind: .run,
            live: run.isLive
        )
    }
}

/// Lays a run's header out as two parts, its lead (the mark, title, state, step bars and where it stopped) and its
/// facts (its duration): on one line, the facts at the trailing edge, when both fit whole in the width
/// offered; otherwise the facts on a second line under the lead, indented past the mark, and the lead gets the width,
/// so where it stopped is cut short first. The choice depends only on the two parts' ideal widths and the width
/// offered, and both parts stay the same views either way.
struct RunHeaderLayout: Layout {
    /// The least room between the lead and the facts on one line.
    static let gap: CGFloat = DesignTokens.Space.s2
    /// The room between the two lines.
    static let lineSpacing: CGFloat = DesignTokens.Space.s1
    /// The second line starts past the header's mark.
    static let factsIndent: CGFloat = TimelineMark.size + DesignTokens.Space.s2

    /// Whether a lead and facts `lead` and `facts` wide sit whole on one line in `width` (nil: any width).
    static func fitsOneLine(lead: CGFloat, facts: CGFloat, width: CGFloat?) -> Bool {
        guard let width, width.isFinite else { return true }
        return needed(lead: lead, facts: facts) <= width
    }

    /// The width one line needs: the lead, and the facts after the gap when there are any.
    static func needed(lead: CGFloat, facts: CGFloat) -> CGFloat {
        facts > 0 ? lead + gap + facts : lead
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let lead = subviews[0].sizeThatFits(.unspecified), facts = subviews[1].sizeThatFits(.unspecified)
        if Self.fitsOneLine(lead: lead.width, facts: facts.width, width: proposal.width) {
            let needed = Self.needed(lead: lead.width, facts: facts.width)
            let width = proposal.width.map { $0.isFinite ? max($0, needed) : needed } ?? needed
            return CGSize(width: width, height: max(lead.height, facts.height))
        }
        let width = proposal.width ?? lead.width
        let shortLead = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let factsHeight = facts.width > 0 ? Self.lineSpacing + facts.height : 0
        return CGSize(width: max(shortLead.width, width), height: shortLead.height + factsHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let lead = subviews[0].sizeThatFits(.unspecified), facts = subviews[1].sizeThatFits(.unspecified)
        if Self.fitsOneLine(lead: lead.width, facts: facts.width, width: bounds.width) {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(lead)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(facts)
            )
            return
        }
        let shortLead = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: shortLead.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + Self.factsIndent, y: bounds.minY + shortLead.height + Self.lineSpacing),
            anchor: .topLeading, proposal: ProposedViewSize(facts)
        )
    }
}

/// A short bar per step, in its state's tint; the one it is on breathes while it works, still under Reduce Motion. On
/// the window's page it breathes on Core Animation (`LayerPulse`), off the main thread (TP-1480); a snapshot draws it
/// still.
public struct StepBars: View {
    let steps: [RunStep]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveDurations) private var live

    public init(steps: [RunStep]) {
        self.steps = steps
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(steps) { step in
                bar(step)
                    .frame(width: 14, height: 4)
                    .help("\(step.title): \(step.state.word.lowercased())")
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    @ViewBuilder private func bar(_ step: RunStep) -> some View {
        if live, step.isLive, !reduceMotion {
            LayerPulse(shape: .capsule, color: step.state.status.tint, motion: Self.breath, duration: Self.breathDuration)
        } else {
            Capsule()
                .fill(step.state == .skipped ? AnyShapeStyle(.quaternary) : AnyShapeStyle(step.state.status.tint))
        }
    }

    /// The working bar's breath: down to 45 % and back, 0.9 s each way.
    static let breath = LayerPulse.Motion.opacity(from: 1, to: 0.45)
    static let breathDuration = 0.9
}

/// The Conductor's guidance inside a run's group: its time, "Conductor steered" and the message, whole.
struct RunSteerEntry: View {
    let steer: RunSteer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            if let at = steer.at {
                Text(at, format: .dateTime.hour().minute())
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(RunSteer.title)
                    .font(DesignTokens.TypeStyle.body.font)
                Text(steer.text)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

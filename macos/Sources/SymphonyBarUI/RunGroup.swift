import SwiftUI
import SymphonyBarCore

/// One run of an agent as a foldable group (the catalog's Run group): its header line (the kind and number, the state
/// glyph and word, a short bar per step, where it stopped when folded, its tokens, model and duration), and unfolded,
/// its steps in a `StepList`. The run now starts unfolded and live; an ended run starts folded.
public struct RunGroup: View {
    let run: RunGroupModel
    @ObservedObject var transcripts: StepTranscripts
    let unfoldedSteps: Set<String>?
    /// The person's own fold, over the run's default: the run now opens, and folds once it ended, until they fold it.
    @State private var folded: Bool?
    /// The fold, when the view around it keeps it (the timeline, whose Return folds the selected run).
    let fold: Binding<Bool>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
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
                FoldHeader(unfolded: unfolded, accessibilityLabel: run.foldAccessibilityLabel(folded: !unfolded) + ", " + run.accessibilityLabel, toggle: toggle) {
                    RunHeaderLabel(run: run, folded: !unfolded)
                }
                if let readSession {
                    RunMoreMenu(run: run, readSession: readSession)
                }
            }
            .padding(.vertical, DesignTokens.Space.s1)
            if unfolded {
                Group {
                    if run.steps.isEmpty {
                        Text(Self.noSteps)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(.secondary)
                    } else {
                        StepList(steps: run.steps, transcripts: transcripts, unfolded: unfoldedSteps)
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
                    .fill(DesignTokens.StateSurface.hover.fill(dark: colorScheme == .dark).opacity(0.6))
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

/// The run's More: "Read the whole session", off with its reason while the run has nothing to read.
///
/// A plain button that opens a small popover, not a SwiftUI `Menu`: a `Menu` is an AppKit pop-up button with its menu
/// built up front, one per run, and on a long timeline with the run now live (its breathing step bar and flowing mark
/// redrawing the page all the time) those pop-ups kept the page from answering accessibility reads and keys (TP-1452's
/// QA on TP-1244). The popover and its one button exist only while it is open.
private struct RunMoreMenu: View {
    let run: RunGroupModel
    let readSession: ReadSessionAction

    @State private var open = false

    private var canRead: Bool { SessionReader.canRead(run) }

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(canRead ? Self.title : SessionReader.nothingToRead)
        .accessibilityLabel(Self.title + ", " + run.title)
        .accessibilityHint(canRead ? SessionReader.menuTitle : SessionReader.nothingToRead)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Button(SessionReader.menuTitle) {
                    open = false
                    readSession(run)
                }
                .disabled(!canRead)
                if !canRead {
                    Text(SessionReader.nothingToRead)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(DesignTokens.Space.s3)
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
        StateMark(symbol: run.state.symbol, status: run.state.status, live: run.isLive, size: 15)
        if run.showsNewDot {
            Circle()
                .fill(DesignTokens.SystemColor.accent.color)
                .frame(width: 6, height: 6)
                .help(TimelineEntry.newHelp)
        }
        Text(run.title)
            .font(DesignTokens.TypeStyle.body.font.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
        StatusBadge(status: run.state.status, word: run.word)
            .fixedSize()
        if !run.steps.isEmpty {
            StepBars(steps: run.steps)
        }
        if folded, let whereText = run.whereText {
            Text(whereText)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
    }

    @ViewBuilder private var facts: some View {
        ForEach([run.tokensText, run.model].compactMap { $0 }, id: \.self) { fact in
            Text(fact)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        if let seconds = run.durationSeconds {
            // The run now's time so far counts on by itself; the timeline isn't built again for it (TP-1479).
            LiveDurationText(seconds: seconds, reference: run.isLive ? reference : nil) { seconds in
                var run = run
                run.durationSeconds = seconds
                return run.duration ?? ""
            }
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .help(Self.durationHelp)
        }
    }

    static let durationHelp = "How long the run took"
}

/// Lays a run's header out as two parts, its lead (the mark, title, state, step bars and where it stopped) and its
/// facts (tokens, model, duration): on one line, the facts at the trailing edge, when both fit whole in the width
/// offered; otherwise the facts on a second line under the lead, indented past the mark, and the lead gets the width,
/// so where it stopped is cut short first. The choice depends only on the two parts' ideal widths and the width
/// offered, and both parts stay the same views either way.
struct RunHeaderLayout: Layout {
    /// The least room between the lead and the facts on one line.
    static let gap: CGFloat = DesignTokens.Space.s2
    /// The room between the two lines.
    static let lineSpacing: CGFloat = DesignTokens.Space.s1
    /// The second line starts past the header's 15 pt mark.
    static let factsIndent: CGFloat = 15 + DesignTokens.Space.s2

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

/// A short bar per step, in its state's tint; the one it is on breathes while it works, still under Reduce Motion.
struct StepBars: View {
    let steps: [RunStep]
    @State private var flowing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(steps) { step in
                Capsule()
                    .fill(step.state == .skipped ? AnyShapeStyle(.quaternary) : AnyShapeStyle(step.state.status.tint))
                    .frame(width: 14, height: 4)
                    .opacity(step.isLive && flowing ? 0.45 : 1)
                    .help("\(step.title): \(step.state.word.lowercased())")
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion, steps.contains(where: \.isLive) else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { flowing = true }
        }
    }
}

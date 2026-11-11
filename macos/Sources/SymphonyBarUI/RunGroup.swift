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
/// built up front, one per run, and on a long timeline with the run now live those pop-ups kept the page from answering
/// accessibility reads and keys (TP-1452's QA on TP-1244). The popover and its one button exist only while it is open.
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
private struct RunHeaderLabel: View {
    let run: RunGroupModel
    let folded: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
                lead(whereFixed: true)
                Spacer(minLength: DesignTokens.Space.s2)
                facts
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                HStack(alignment: .center, spacing: DesignTokens.Space.s2) { lead(whereFixed: false) }
                HStack(alignment: .center, spacing: DesignTokens.Space.s2) { facts }
                    .padding(.leading, 15 + DesignTokens.Space.s2)
            }
        }
    }

    @ViewBuilder private func lead(whereFixed: Bool) -> some View {
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
                .fixedSize(horizontal: whereFixed, vertical: false)
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
        if let duration = run.duration {
            Text(duration)
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

/// A short bar per step, in its state's tint. The one it is on holds still, as the live dot does: a bar that breathed
/// forever kept a long live page from answering accessibility reads (TP-1452).
struct StepBars: View {
    let steps: [RunStep]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(steps) { step in
                Capsule()
                    .fill(step.state == .skipped ? AnyShapeStyle(.quaternary) : AnyShapeStyle(step.state.status.tint))
                    .frame(width: 14, height: 4)
                    .help("\(step.title): \(step.state.word.lowercased())")
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

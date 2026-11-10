import SwiftUI
import SymphonyBarCore

/// One run of an agent as a foldable group (the catalog's Run group): its header line (the kind and number, the state
/// glyph and word, a short bar per step, where it stopped when folded, its tokens, model and duration), and unfolded,
/// its steps in a `StepList`. The run now starts unfolded and live; an ended run starts folded.
public struct RunGroup: View {
    let run: RunGroupModel
    @ObservedObject var transcripts: StepTranscripts
    let unfoldedSteps: Set<String>?
    @State private var unfolded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// `unfolded` and `unfoldedSteps` say what is open to start with; nil opens what opens by default.
    public init(run: RunGroupModel, transcripts: StepTranscripts, unfolded: Bool? = nil, unfoldedSteps: Set<String>? = nil) {
        self.run = run
        self.transcripts = transcripts
        self.unfoldedSteps = unfoldedSteps
        _unfolded = State(initialValue: unfolded ?? run.opensByDefault)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoldHeader(unfolded: unfolded, accessibilityLabel: run.foldAccessibilityLabel(folded: !unfolded) + ", " + run.accessibilityLabel, toggle: toggle) {
                RunHeaderLabel(run: run, folded: !unfolded)
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
        withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { unfolded.toggle() }
    }

    public static let noSteps = "This run recorded no steps."
}

/// The run's header line.
private struct RunHeaderLabel: View {
    let run: RunGroupModel
    let folded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            StateMark(symbol: run.state.symbol, status: run.state.status, live: run.isLive, size: 15)
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
                    .fixedSize()
            }
            Spacer(minLength: DesignTokens.Space.s2)
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
    }

    static let durationHelp = "How long the run took"
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

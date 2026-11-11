import AppKit
import SwiftUI
import SymphonyBarCore

// The catalog's Step list and Run group (`docs/design/director-ticket-page.md` §1 facts 4, 8 and 13, §4): a run folds
// into its steps and a step into what the agent said, the tools it called and what came back. The fold opens its
// height on the standard easing, its lines fade down into place 35 ms apart and its chevron turns on a spring; a new
// line of the run now fades up at the bottom and flashes the working tint, and the agent's newest words carry a caret.
// Under Reduce Motion everything is there at once and nothing flashes.

// MARK: - Fold keys

/// Return and Space toggle the fold that has the keyboard (§4 Keyboard).
public enum FoldKeys {
    public static let keys: Set<KeyEquivalent> = [.return, .space]

    /// Whether `key` toggles a focused fold: Return or Space with no modifier held.
    public static func toggles(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        modifiers.subtracting(.numericPad).isEmpty && keys.contains(key)
    }
}

// MARK: - Fold header

/// A fold's header line: the chevron, then `label`. It has a row's hover, pressed and focus states, toggles on a
/// click, Return or Space, and when it can't unfold says why under the pointer and takes no focus.
struct FoldHeader<Label: View>: View {
    let unfolded: Bool
    /// Why it can't unfold, nil when it can.
    var disabledReason: String?
    let accessibilityLabel: String
    let toggle: () -> Void
    @ViewBuilder var label: Label

    @State private var hovered = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var enabled: Bool { disabledReason == nil }

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? .secondary : .quaternary)
                .rotationEffect(.degrees(unfolded ? 90 : 0))
                .animation(.motion(.fold, reduceMotion: reduceMotion), value: unfolded)
                .frame(width: 12)
                .accessibilityHidden(true)
            label
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RowFace(
            state: DesignTokens.Interaction(hovered: hovered && enabled, pressed: pressed && enabled, focused: focused),
            reduceMotion: reduceMotion,
            bleed: EdgeInsets(top: DesignTokens.Space.s1, leading: DesignTokens.Space.s2, bottom: DesignTokens.Space.s1, trailing: DesignTokens.Space.s2)
        ))
        .contentShape(Rectangle())
        .focusable(enabled)
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .onTapGesture { if enabled { toggle() } }
        .onKeyPress(keys: FoldKeys.keys, phases: .down) { press in
            guard enabled, FoldKeys.toggles(press.key, modifiers: press.modifiers) else { return .ignored }
            toggle()
            return .handled
        }
        .help(disabledReason ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(disabledReason ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { toggle() } }
    }
}

// MARK: - Line entering

/// How a line comes into an unfolded step: down into place with the fold, `delay` after the one above it, or up at
/// the bottom of the run now with a flash of the working tint.
private struct LineEntering: ViewModifier {
    enum Entry: Equatable {
        case fold(delay: Double)
        case live
    }

    let entry: Entry
    @State private var shown = false
    @State private var flash = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    func body(content: Content) -> some View {
        let still = reduceMotion || offscreenSnapshot
        let visible = shown || still
        content
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous)
                    .fill(DesignTokens.Status.working.tint.opacity(0.18 * flash))
                    .padding(.horizontal, -DesignTokens.Space.s1)
            }
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : (entry == .live ? 6 : -6))
            .onAppear {
                guard !still else { return }
                switch entry {
                case let .fold(delay):
                    withAnimation(.motion(.standard, reduceMotion: false).delay(delay)) { shown = true }
                case .live:
                    flash = 1
                    withAnimation(.motion(.standard, reduceMotion: false)) { shown = true }
                    withAnimation(.easeOut(duration: 1.2).delay(DesignTokens.Motion.standardDuration)) { flash = 0 }
                }
            }
    }
}

// MARK: - A transcript line

/// One line of a step: its time, a glyph for what it is, and its text. What the agent said reads in `ChipText`, its
/// ticket and PR mentions chips; a tool call names its tool and its arguments in short; a result says how long its
/// tool took and is marked when it failed. The agent's newest words in the run now carry a caret.
struct TranscriptLineRow: View {
    let line: TranscriptLine
    var typing = false

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
            if typing {
                // The newest words, still being written: plain text with the caret after the last word.
                (Text(line.text) + Text(" ▍").foregroundStyle(DesignTokens.Status.working.tint))
                    .font(DesignTokens.TypeStyle.callout.font)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ChipText(text: line.text, font: DesignTokens.TypeStyle.callout.nsFont)
            }
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = NSTimeZone.default
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Step list

/// A run's steps, top to bottom, each unfolding into what the agent did in it. A completed step's lines are its
/// transcript artifact, read on its first unfold and kept by `transcripts`; the step the run now is on shows its
/// newest lines live. The step it is on, and one that failed or asked a question, start unfolded.
public struct StepList: View {
    let steps: [RunStep]
    @ObservedObject var transcripts: StepTranscripts
    @State private var folds: FoldState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `unfolded` pins which steps are open (a render's fixed state); nil opens each step that opens by default,
    /// as the ticket read brings it, until the person folds it.
    public init(steps: [RunStep], transcripts: StepTranscripts, unfolded: Set<String>? = nil) {
        self.steps = steps
        self.transcripts = transcripts
        _folds = State(initialValue: unfolded.map { FoldState(ids: steps.map(\.id), unfolded: $0) } ?? FoldState())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(steps) { step in
                StepRow(step: step, transcripts: transcripts, unfolded: folds.isUnfolded(step)) {
                    withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { folds.toggle(step) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel)
    }

    public static let accessibilityLabel = "Steps of the run"
}

/// One step: its header line and, unfolded, its lines.
private struct StepRow: View {
    let step: RunStep
    @ObservedObject var transcripts: StepTranscripts
    let unfolded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoldHeader(
                unfolded: unfolded, disabledReason: step.cannotUnfoldReason,
                accessibilityLabel: step.canUnfold ? step.foldAccessibilityLabel(folded: !unfolded) : step.accessibilityLabel,
                toggle: toggle
            ) {
                StepHeaderLabel(step: step)
            }
            if unfolded {
                StepLines(step: step, transcripts: transcripts)
                    .padding(.leading, 12 + DesignTokens.Space.s2 + 18 + DesignTokens.Space.s2)
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
    }
}

/// A step's mark, name, state, reason and duration.
private struct StepHeaderLabel: View {
    let step: RunStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            StateMark(symbol: step.state.symbol, status: step.state.status, live: step.isLive, size: 14)
                .frame(width: 18)
            Text(step.title)
                .font(DesignTokens.TypeStyle.body.font.weight(step.isLive ? .semibold : .regular))
                .lineLimit(1)
            Text(step.state.word)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(step.state == .failed ? AnyShapeStyle(DesignTokens.Status.problem.tint) : AnyShapeStyle(.secondary))
            if let reason = step.reason {
                Text(reason)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if let duration = step.duration {
                Text(duration)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// An unfolded step's lines: the run now's, else its transcript, read on the first unfold.
private struct StepLines: View {
    let step: RunStep
    @ObservedObject var transcripts: StepTranscripts

    var body: some View {
        Group {
            if step.isLive, !step.liveLines.isEmpty || step.transcript == nil {
                LineList(lines: step.liveLines, live: true)
            } else if let transcript = step.transcript {
                switch transcripts.lines(transcript) {
                case .loading:
                    Note(text: Self.loading)
                case let .loaded(lines):
                    if lines.isEmpty { Note(text: Self.empty) } else { LineList(lines: lines, live: false) }
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
            Text(text).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
        }
    }
}

/// The lines of a step, top to bottom. With the fold they fade down 35 ms apart; in the run now a line that comes
/// after the step unfolded fades up at the bottom and flashes, and the agent's newest words carry a caret.
struct LineList: View {
    let lines: [TranscriptLine]
    let live: Bool
    /// The lines there when the step unfolded: they came with the fold, the rest came live.
    @State private var known: Set<String>

    init(lines: [TranscriptLine], live: Bool) {
        self.lines = lines
        self.live = live
        _known = State(initialValue: Set(Self.keyed(lines).map(\.key)))
    }

    var body: some View {
        let keyed = Self.keyed(lines)
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(Array(keyed.enumerated()), id: \.element.key) { index, entry in
                TranscriptLineRow(line: entry.line, typing: live && index == keyed.count - 1 && entry.line.kind == .say)
                    .modifier(LineEntering(entry: known.contains(entry.key) ? .fold(delay: DesignTokens.Motion.staggerDelay(index, reduceMotion: false)) : .live))
            }
        }
    }

    /// Each line with a key that stays with it as the run now's window of lines slides.
    static func keyed(_ lines: [TranscriptLine]) -> [(key: String, line: TranscriptLine)] {
        var seen: [String: Int] = [:]
        return lines.map { line in
            let base = "\(line.at ?? "")|\(line.kind.rawValue)|\(line.text)"
            seen[base, default: 0] += 1
            return (seen[base]! == 1 ? base : "\(base)#\(seen[base]!)", line)
        }
    }
}

// MARK: - Marks

/// A state's mark: its symbol in its tint, or the live dot while it works.
struct StateMark: View {
    let symbol: String
    let status: DesignTokens.Status
    let live: Bool
    var size: Double = 14

    var body: some View {
        Group {
            if live {
                LiveDot(size: size * 0.6)
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

/// The working dot, breathing while it works (its halo on a layer: `Breathing`); still under Reduce Motion and in a
/// snapshot.
struct LiveDot: View {
    var size: Double = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    /// The halo's size against the dot's: at rest, and at the top of a breath.
    static let haloScale = (rest: 1.6, breath: 2.2)
    static let breathDuration = 1.2

    var body: some View {
        let halo = DesignTokens.Status.working.tint.opacity(0.25)
        Circle()
            .fill(DesignTokens.Status.working.tint)
            .frame(width: size, height: size)
            .background {
                if reduceMotion || offscreenSnapshot {
                    Circle().fill(halo).scaleEffect(Self.haloScale.rest)
                } else {
                    Breathing(color: halo, change: .scale, from: Self.haloScale.rest, to: Self.haloScale.breath, duration: Self.breathDuration)
                }
            }
    }
}

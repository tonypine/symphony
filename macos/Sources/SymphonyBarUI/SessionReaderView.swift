import SwiftUI
import SymphonyBarCore

// The session reader (`docs/design/director-ticket-page.md` §2 question 3, analysis §2.5 decision (c) and §6.1): one
// run's whole session in a window of its own, opened from the run's More as "Read the whole session". Its header says
// the run as its Run group does; under it every step of the run, top to bottom, with every line the agent wrote in
// it. A line reads in short; a click, Return or Space expands it in place to its full text, selectable, and folds it
// back.

/// The reader's content: the run's header, then its steps and their lines, in a scroll view.
public struct SessionReaderView: View {
    let reader: SessionReader
    @Binding var expanded: Set<String>

    public init(reader: SessionReader, expanded: Binding<Set<String>>) {
        self.reader = reader
        _expanded = expanded
    }

    public var body: some View {
        VStack(spacing: 0) {
            SessionReaderHeader(run: reader.run)
                .padding(.horizontal, DesignTokens.Space.s5)
                .padding(.vertical, DesignTokens.Space.s3)
            Divider()
            ScrollView {
                SessionReaderSections(reader: reader, expanded: $expanded)
                    .padding(DesignTokens.Space.s5)
            }
            .frame(maxHeight: .infinity)
        }
        .background(DesignTokens.Surface.window.color)
    }
}

/// The reader drawn whole, without its scroll view: what a snapshot renders.
public struct SessionReaderPage: View {
    let reader: SessionReader
    let expanded: Set<String>

    public init(reader: SessionReader, expanded: Set<String> = []) {
        self.reader = reader
        self.expanded = expanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionReaderHeader(run: reader.run)
                .padding(.horizontal, DesignTokens.Space.s5)
                .padding(.vertical, DesignTokens.Space.s3)
            Divider()
            SessionReaderSections(reader: reader, expanded: .constant(expanded))
                .padding(DesignTokens.Space.s5)
        }
        .background(DesignTokens.Surface.window.color)
    }
}

/// The run's mark, its title and state word, and its tokens, model and duration.
private struct SessionReaderHeader: View {
    let run: RunGroupModel

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            StateMark(symbol: run.state.symbol, status: run.state.status, live: run.isLive, size: 15)
            Text(run.title)
                .font(DesignTokens.TypeStyle.section.font)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            StatusBadge(status: run.state.status, word: run.word)
                .fixedSize()
            Spacer(minLength: DesignTokens.Space.s2)
            ForEach([run.tokensText, run.model, run.duration].compactMap { $0 }, id: \.self) { fact in
                Text(fact)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.accessibilityLabel)
    }
}

/// Every step of the run with its lines.
private struct SessionReaderSections: View {
    let reader: SessionReader
    @Binding var expanded: Set<String>

    var body: some View {
        LazyVStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            if reader.sections.isEmpty {
                Text(SessionReader.noSteps)
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(.secondary)
            }
            ForEach(reader.sections) { section in
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    SessionStepHeader(step: section.step)
                    switch section.content {
                    case let .lines(lines):
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(lines) { line in
                                SessionLineRow(line: line, expanded: expanded.contains(line.id)) { toggle(line.id) }
                            }
                        }
                    default:
                        Text(SessionReader.note(section.content, live: section.step.isLive) ?? "")
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(.secondary)
                            .padding(.leading, SessionLineRow.indent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// A step's mark, title, state word, reason and duration, over its lines.
private struct SessionStepHeader: View {
    let step: RunStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            StateMark(symbol: step.state.symbol, status: step.state.status, live: step.isLive, size: 14)
                .frame(width: 18)
            Text(step.title)
                .font(DesignTokens.TypeStyle.body.font.weight(.semibold))
                .lineLimit(1)
            Text(step.state.word)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(step.state == .failed ? AnyShapeStyle(DesignTokens.Status.problem.tint) : AnyShapeStyle(.secondary))
            if let reason = step.reason {
                Text(reason)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if let duration = step.duration {
                Text(duration)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, DesignTokens.Space.s1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.Surface.separator.color).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.accessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One line: its time, its glyph and its text, in short or, expanded, in full and selectable. A line with more than
/// its short form shows a chevron that turns as it expands.
struct SessionLineRow: View {
    let line: SessionReader.Line
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where a line's text starts: past its time and glyph.
    static let indent: CGFloat = 58 + 14 + 2 * DesignTokens.Space.s2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(line.line.date.map(TranscriptLineRow.clock) ?? "")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(line.line.failed ? DesignTokens.Status.problem.tint : .secondary)
                .frame(width: 14)
                .help(TranscriptLineRow.glyphHelp(line.line))
            text
                .frame(maxWidth: DesignTokens.Measure.reading + 160, alignment: .leading)
            Spacer(minLength: 0)
            if line.line.kind == .result {
                HStack(spacing: DesignTokens.Space.s1) {
                    if line.line.failed {
                        Text(TranscriptLineRow.failedWord)
                            .font(DesignTokens.TypeStyle.label.font)
                            .foregroundStyle(DesignTokens.Status.problem.tint)
                    }
                    if let duration = line.line.durationText {
                        Text(duration)
                            .font(DesignTokens.TypeStyle.caption.font)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .fixedSize()
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12)
                .opacity(line.expands ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .modifier(RowFace(
            state: DesignTokens.Interaction(hovered: hovered && line.expands, focused: focused), reduceMotion: reduceMotion,
            bleed: EdgeInsets(top: 0, leading: DesignTokens.Space.s2, bottom: 0, trailing: DesignTokens.Space.s2)
        ))
        .contentShape(Rectangle())
        .focusable(line.expands)
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovered = $0 }
        .onTapGesture { if line.expands { flip() } }
        .onKeyPress(keys: FoldKeys.keys, phases: .down) { press in
            guard line.expands, FoldKeys.toggles(press.key, modifiers: press.modifiers) else { return .ignored }
            flip()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.line.accessibilityLabel)
        .accessibilityAddTraits(line.expands ? .isButton : [])
        .accessibilityAction(named: SessionReader.expandLabel(expanded: expanded)) { if line.expands { flip() } }
    }

    private func flip() {
        withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { toggle() }
    }

    @ViewBuilder private var text: some View {
        let words = line.line.kind == .tool
            ? Text(line.line.toolName.map { $0 + "  " } ?? "").fontWeight(.semibold) + Text(line.line.body)
            : Text(line.line.text.isEmpty && line.line.kind == .result ? TranscriptLineRow.emptyResult : line.line.text)
        let styled = words
            .font(line.line.kind == .say ? DesignTokens.TypeStyle.callout.font : .system(.callout, design: .monospaced))
            .foregroundStyle(line.line.kind == .result
                ? (line.line.failed ? AnyShapeStyle(DesignTokens.Status.problem.tint) : AnyShapeStyle(.secondary))
                : AnyShapeStyle(.primary))
        if expanded {
            styled
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            styled
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private var glyph: String {
        switch line.line.kind {
        case .say: "text.bubble"
        case .tool: "wrench.and.screwdriver"
        case .result: line.line.failed ? "xmark.octagon.fill" : "arrow.turn.down.right"
        }
    }
}

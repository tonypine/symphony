import SwiftUI
import SymphonyBarCore

// The four components made for the Conductor's message blocks: the Run path, Attempts, Expected and actual, and the
// Findings ledger. Each draws data Symphony resolved (`ConductorBlock`); none holds a fold or a control of its own.

/// A round mark of `status`, 20 pt: the step list's mark for a state, bare. An upcoming state is a ring.
struct BlockMark: View {
    enum Kind: Equatable {
        case done, failed, current, upcoming, open
    }

    let kind: Kind
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            switch kind {
            case .upcoming:
                Circle().strokeBorder(DesignTokens.Surface.strong.color, lineWidth: 1.5)
            case .current:
                Circle().fill(DesignTokens.Status.working.badgeFill)
                Circle().fill(DesignTokens.Status.working.tint).frame(width: size * 0.4, height: size * 0.4)
            default:
                Circle().fill(status.badgeFill)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(status.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var status: DesignTokens.Status {
        switch kind {
        case .done: .done
        case .failed, .open: .problem
        case .current: .working
        case .upcoming: .idle
        }
    }

    private var symbol: String {
        switch kind {
        case .done: "checkmark"
        case .failed: "xmark"
        case .open: "exclamationmark"
        case .current, .upcoming: ""
        }
    }
}

// MARK: - Run path

/// The Run path: where a ticket has been, is and goes next, always on one line that never wraps or scrolls. It shows the
/// last stop that ended, the stop the ticket is at (a highlighted pill) and the next to come; what is earlier folds into
/// a leading count and what is later into a trailing "+N", both listed in the help and read by VoiceOver. Names
/// truncate before anything wraps. Under it, when the ticket went round QA and rework, one line says how often and how
/// long.
public struct RunPath: View {
    let reading: ConductorPathReading

    public init(path: ConductorBlock.Path) {
        reading = ConductorPathReading(path)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(spacing: DesignTokens.Space.s1) {
                if let earlier = reading.earlierText {
                    Text(earlier)
                        .font(DesignTokens.TypeStyle.secondary.font.weight(reading.earlierFailed ? .semibold : .regular))
                        .foregroundStyle(reading.earlierFailed ? DesignTokens.Status.problem.text : DesignTokens.TextColor.secondary.color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, DesignTokens.Space.s2)
                    arrow
                }
                if let ended = reading.lastEnded {
                    stop(ended)
                    if reading.current != nil || reading.next != nil { arrow }
                }
                if let current = reading.current {
                    stop(current)
                    if reading.next != nil { arrow }
                }
                if let next = reading.next { stop(next) }
                if let later = reading.laterText {
                    Text(later)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, DesignTokens.Space.s2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            if let loops = reading.loopsLine {
                Text(loops)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .lineLimit(1)
            }
        }
        .help(reading.help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibilityLabel)
    }

    private var arrow: some View {
        Rectangle()
            .fill(DesignTokens.Surface.strong.color)
            .frame(width: 16, height: 1)
            .padding(.horizontal, 2)
    }

    private func stop(_ stop: ConductorBlock.Path.Stop) -> some View {
        let current = stop.state == .current
        return HStack(spacing: DesignTokens.Space.s1 + 2) {
            BlockMark(kind: Self.mark(stop.state))
            Text(ConductorPathReading.name(stop))
                .font(DesignTokens.TypeStyle.body.font.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? DesignTokens.Status.working.text : DesignTokens.TextColor.secondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, DesignTokens.Space.s1)
        .padding(.trailing, DesignTokens.Space.s3 - 2)
        .padding(.vertical, 3)
        .background(Capsule().fill(current ? DesignTokens.Status.working.badgeFill : Color.clear))
        .layoutPriority(current ? 1 : 0)
    }

    static func mark(_ state: ConductorBlock.Path.Stop.State) -> BlockMark.Kind {
        switch state {
        case .done: .done
        case .failed: .failed
        case .current: .current
        case .upcoming: .upcoming
        }
    }
}

// MARK: - Attempts

/// Attempts: one step across its tries, a row each: the state's mark, the line it failed on (or its outcome) in the mono
/// font on one line, and the time. When every failed try printed the same line, a last line says so in the problem colour.
public struct AttemptsList: View {
    let attempts: ConductorBlock.Attempts

    public init(attempts: ConductorBlock.Attempts) {
        self.attempts = attempts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2 - 2) {
            ForEach(Array(attempts.tries.enumerated()), id: \.offset) { _, attempt in
                HStack(spacing: DesignTokens.Space.s3) {
                    BlockMark(kind: attempt.failed ? .failed : .done)
                    Text(attempt.line ?? Self.words(attempt))
                        .font(DesignTokens.TypeStyle.mono.font)
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(attempt.at.map(Self.clock) ?? "")
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            if attempts.sameLine {
                Text(Self.sameLineWords)
                    .font(DesignTokens.TypeStyle.secondary.font.weight(.semibold))
                    .foregroundStyle(DesignTokens.Status.problem.text)
                    .padding(.leading, 18 + DesignTokens.Space.s3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(attempts))
    }

    public static let sameLineWords = "Same error every time"

    static func words(_ attempt: ConductorBlock.Attempts.Try) -> String { attempt.failed ? "Failed" : "Passed" }

    static func clock(_ date: Date) -> String {
        SharedDateFormatter.string(date, format: "HH:mm", timeZone: NSTimeZone.default)
    }

    /// "Attempts at Build: failed, a.swift:443; passed. Same error every time".
    static func accessibilityLabel(_ attempts: ConductorBlock.Attempts) -> String {
        let tries = attempts.tries.map { ($0.failed ? "failed" : "passed") + ($0.line.map { ", " + $0 } ?? "") }
        return "Attempts" + (attempts.title.map { " at " + $0 } ?? "") + ": " + tries.joined(separator: "; ")
            + (attempts.sameLine ? ". " + sameLineWords : "")
    }
}

// MARK: - Expected and actual

/// Expected and actual: two equal panes, "Expected" and "QA saw", each a text or a screenshot's thumbnail. Side by side
/// while the width gives each pane its least width, stacked below that.
public struct ExpectedAndActual: View {
    let compare: ConductorBlock.Compare
    let actualLabel: String
    /// A text pane longer than this many lines is cut there, with "Show more" under it; nil shows every line.
    let lineLimit: Int?

    public init(compare: ConductorBlock.Compare, actualLabel: String = ExpectedAndActual.actualLabel, lineLimit: Int? = nil) {
        self.compare = compare
        self.actualLabel = actualLabel
        self.lineLimit = lineLimit
    }

    /// Two texts, as a check step's result gives them: "Expected" and "Actual", each cut at `lineLimit` lines.
    public init(expected: String?, actual: String?, lineLimit: Int? = nil) {
        self.init(
            compare: ConductorBlock.Compare(expected: .text(expected ?? Self.nothing), actual: .text(actual ?? Self.nothing)),
            actualLabel: Self.stepActualLabel, lineLimit: lineLimit
        )
    }

    public static let stepActualLabel = "Actual"
    static let nothing = "Nothing recorded"

    public static let expectedLabel = "Expected"
    public static let actualLabel = "QA saw"
    /// The least width of a pane before the two stack.
    static let paneMinimum: CGFloat = 220

    public var body: some View {
        EqualPanes(minimum: Self.paneMinimum, gap: DesignTokens.Space.s3 - 2) {
            pane(Self.expectedLabel, compare.expected)
            pane(actualLabel, compare.actual)
        }
        .accessibilityElement(children: .contain)
    }

    private func pane(_ label: String, _ side: ConductorBlock.Compare.Side) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        return VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(label.uppercased())
                .font(DesignTokens.TypeStyle.label.font)
                .tracking(CGFloat(DesignTokens.KeyValue.groupHeadingTracking * DesignTokens.TypeStyle.label.size))
                .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                .accessibilityHidden(true)
            switch side {
            case let .text(text):
                ClampedText(text: text, lines: lineLimit)
                    .accessibilityLabel(label + ": " + text)
            case let .screenshot(artifactID, _):
                ScreenshotThumbnail(
                    shot: TicketScreenshot(id: artifactID, label: label, path: "api/v1/artifacts/\(artifactID)", available: true),
                    size: FindingShot.size
                )
            }
        }
        .padding(.vertical, DesignTokens.Space.s2 + 2)
        .padding(.horizontal, DesignTokens.Space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.Surface.content.color, in: shape)
        .overlay(shape.strokeBorder(DesignTokens.Surface.separator.color, lineWidth: 1))
    }
}

/// Two panes of one height: side by side with `gap` between, or one over the other when each would be under `minimum`.
struct EqualPanes: Layout {
    let minimum: CGFloat
    let gap: CGFloat

    private func sideBySide(_ width: CGFloat?) -> Bool {
        guard let width, width.isFinite else { return true }
        return width >= 2 * minimum + gap
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 2 * minimum + gap
        if sideBySide(proposal.width) {
            let pane = (width - gap) / 2
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: pane, height: nil)).height }
            return CGSize(width: width, height: heights.max() ?? 0)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if sideBySide(bounds.width) {
            let pane = (bounds.width - gap) / 2
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: pane, height: nil)).height }.max() ?? 0
            for (index, subview) in subviews.enumerated() {
                subview.place(
                    at: CGPoint(x: bounds.minX + CGFloat(index) * (pane + gap), y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: pane, height: height)
                )
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + gap
        }
    }
}

// MARK: - Findings ledger

/// The Findings ledger: every finding on the ticket and what became of it. A row is a mark, the finding's title (struck
/// through and tertiary once resolved) and, at the right, "Fixed" or "Still open".
public struct FindingsLedger: View {
    let findings: ConductorBlock.Findings

    public init(findings: ConductorBlock.Findings) {
        self.findings = findings
    }

    public static let fixedWord = "Fixed"
    public static let openWord = "Still open"

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2 - 2) {
            ForEach(Array(findings.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: DesignTokens.Space.s2 + 2) {
                    BlockMark(kind: item.resolved ? .done : .open)
                    Text(item.title)
                        .font(DesignTokens.TypeStyle.body.font)
                        .strikethrough(item.resolved)
                        .foregroundStyle((item.resolved ? DesignTokens.TextColor.tertiary : DesignTokens.TextColor.primary).color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.resolved ? Self.fixedWord : Self.openWord)
                        .font(DesignTokens.TypeStyle.secondary.font.weight(item.resolved ? .regular : .semibold))
                        .foregroundStyle(item.resolved ? DesignTokens.Status.done.text : DesignTokens.Status.problem.text)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.title), \(item.resolved ? Self.fixedWord : Self.openWord)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Findings, \(findings.open) open, \(findings.resolved) fixed")
    }
}

/// A text that wraps whole, or, past `lines` lines, is cut there with "Show more" under it and "Show less" once open.
struct ClampedText: View {
    let text: String
    let lines: Int?
    @State private var expanded = false
    @State private var wholeHeight: CGFloat = 0
    @State private var clampedHeight: CGFloat = 0

    static let showMore = "Show more"
    static let showLess = "Show less"

    private var cut: Bool { lines != nil && wholeHeight > clampedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Text(text)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .lineLimit(expanded ? nil : lines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) { measure }
            if cut {
                Button(expanded ? Self.showLess : Self.showMore) { expanded.toggle() }
                    .directorButton(.quiet, size: .small)
            }
        }
    }

    /// The text's height whole and cut at `lines`, measured out of sight.
    private var measure: some View {
        ZStack {
            Text(text).font(DesignTokens.TypeStyle.body.font).fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { Color.clear.preference(key: WholeHeightKey.self, value: $0.size.height) })
            if let lines {
                Text(text).font(DesignTokens.TypeStyle.body.font).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { Color.clear.preference(key: ClampedHeightKey.self, value: $0.size.height) })
            }
        }
        .hidden()
        .onPreferenceChange(WholeHeightKey.self) { wholeHeight = $0 }
        .onPreferenceChange(ClampedHeightKey.self) { clampedHeight = $0 }
        .accessibilityHidden(true)
    }
}

private struct WholeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ClampedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

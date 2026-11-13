import SwiftUI
import SymphonyBarCore

/// C31: where a ticket stands, in one line that is the same on every page (`director-ticket-page.md` §3): the word in
/// its status color with its glyph, the cause, what moves it next and since when. The full line heads a ticket page,
/// its word and age in one status pill; the compact one sits in a row, the word and the cause with the age trailing.
/// The cause wraps at the reading measure and the word is never cut. Color never says it alone: the glyph and the word
/// always come with it, and VoiceOver reads the word, the age and the cause as one sentence. A forced ticket shows the
/// Forced chip beside the line; the phase is not part of it. On a selected row (the background's prominence raised, as a
/// table draws its selection) the word and glyph take the row's text color, so they never vanish on the highlight.
struct SituationLine: View {
    enum Size { case full, compact }

    let text: SituationText
    var size: Size = .full
    var forced = false
    @Environment(\.backgroundProminence) private var prominence

    init(_ situation: Situation, reference: Date = Date(), size: Size = .full, forced: Bool = false) {
        text = SituationText(situation, reference: reference)
        self.size = size
        self.forced = forced
    }

    private var kind: DesignTokens.SituationKind { text.kind }

    /// The word and glyph color: the kind's tint, or the row's own text color on a selection highlight.
    private var wordStyle: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(kind.tint)
    }

    private var glyph: some View {
        Image(systemName: kind.symbol).foregroundStyle(wordStyle).accessibilityHidden(true)
    }

    var body: some View {
        Group {
            switch size {
            case .full: full
            case .compact: compact
            }
        }
        .help(text.sentence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.spoken(forced: forced))
        .accessibilityHint(size == .full ? text.next ?? "" : "")
    }

    // MARK: - Full

    private var full: some View {
        SituationFlow(spacing: DesignTokens.Space.s3) {
            HStack(spacing: DesignTokens.Space.s2) {
                pill
                if forced { Badge(status: .forced) }
            }
            .fixedSize()
            reading
                .font(DesignTokens.TypeStyle.body.font)
                .frame(maxWidth: DesignTokens.Measure.reading, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The word and its age in one capsule tinted with the kind's color, so the age always reads beside the word.
    private var pill: some View {
        HStack(spacing: 6) {
            Label {
                Text(text.word).fontWeight(.semibold).foregroundStyle(wordStyle)
            } icon: {
                glyph
            }
            .labelStyle(.titleAndIcon)
            if let age = text.ageLabel {
                Label {
                    Text(age).monospacedDigit().foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "clock").foregroundStyle(kind.tint)
                }
                .labelStyle(.titleAndIcon)
                .font(DesignTokens.TypeStyle.label.font)
                .padding(.leading, 7)
                .padding(.trailing, 9)
                .padding(.vertical, 2)
                .background(DesignTokens.Surface.content.color, in: Capsule())
            }
        }
        .font(DesignTokens.TypeStyle.body.font)
        .padding(.leading, 10)
        .padding(.trailing, text.ageLabel == nil ? 10 : 3)
        .padding(.vertical, 3)
        .background(kind.status.badgeFill, in: Capsule())
    }

    /// The cause, then what moves it next in secondary text.
    private var reading: Text {
        guard let next = text.next else { return Text(text.cause) }
        return Text("\(text.cause) \(Text(next).foregroundStyle(.secondary))")
    }

    // MARK: - Compact

    private var compact: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            glyph
            Text(text.word)
                .fontWeight(.semibold)
                .foregroundStyle(wordStyle)
                .fixedSize()
            if forced { Badge(status: .forced).fixedSize() }
            Text(text.cause)
                .frame(maxWidth: DesignTokens.Measure.reading, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DesignTokens.Space.s2)
            if let age = text.age {
                Text(age)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .font(DesignTokens.TypeStyle.secondary.font)
    }
}

/// The full line's two parts: the pill, and the reading text beside it while at least `minReading` is left for the
/// text, under it otherwise, so a narrow column never squeezes the cause into a sliver. The text stops at the measure.
struct SituationFlow: Layout {
    var spacing: CGFloat
    var minReading: CGFloat = 280

    private struct Arrangement {
        var size: CGSize
        var beside: Bool
        var lead: CGSize
        var reading: CGSize
    }

    private func arrange(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Arrangement {
        guard subviews.count == 2 else {
            let size = subviews.first?.sizeThatFits(proposal) ?? .zero
            return Arrangement(size: size, beside: true, lead: size, reading: .zero)
        }
        let lead = subviews[0].sizeThatFits(.unspecified)
        let width = proposal.width ?? .infinity
        let measure = CGFloat(DesignTokens.Measure.reading)
        let remaining = width - lead.width - spacing
        if remaining >= minReading {
            let reading = subviews[1].sizeThatFits(ProposedViewSize(width: min(remaining, measure), height: nil))
            return Arrangement(
                size: CGSize(width: lead.width + spacing + reading.width, height: max(lead.height, reading.height)),
                beside: true, lead: lead, reading: reading
            )
        }
        let reading = subviews[1].sizeThatFits(ProposedViewSize(width: min(max(width, 0), measure), height: nil))
        return Arrangement(
            size: CGSize(width: max(lead.width, reading.width), height: lead.height + DesignTokens.Space.s2 + reading.height),
            beside: false, lead: lead, reading: reading
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(proposal, subviews)
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: proposal)
            return
        }
        if layout.beside {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            subviews[1].place(
                at: CGPoint(x: bounds.minX + layout.lead.width + spacing, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: layout.reading.width, height: nil)
            )
        } else {
            subviews[0].place(at: bounds.origin, proposal: .unspecified)
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + layout.lead.height + DesignTokens.Space.s2),
                proposal: ProposedViewSize(width: layout.reading.width, height: nil)
            )
        }
    }
}

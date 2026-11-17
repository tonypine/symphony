import AppKit
import SwiftUI
import SymphonyBarCore

// The shared parts of the Timeline section (TP-1487): the mark every entry, run and step draws, the rule line that
// joins the marks, and the card that shows what QA found with its screenshots.

/// A timeline mark (the catalog's `.tl-entry .mark`, `.run-head .mark` and `.sl-mark`): its glyph in its tint, in a
/// circle of its tint's fill, or the working dot while it is live. An entry's mark is 24 pt with a hairline of its tint
/// and a ring of the surface around it where the rule line meets it; a run's is 24 pt with the hairline; a step's is
/// 20 pt and bare.
struct TimelineMark: View {
    enum Kind { case entry, run, step }

    let symbol: String
    let tint: Color
    let fill: Color
    var kind: Kind = .entry
    var live = false

    static let size: CGFloat = 24
    static let stepSize: CGFloat = 20
    static let hairline: CGFloat = 1
    static let halo: CGFloat = 3

    init(symbol: String, tint: Color, fill: Color, kind: Kind = .entry, live: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.fill = fill
        self.kind = kind
        self.live = live
    }

    init(symbol: String, tone: TimelineEntry.Tone) {
        self.init(symbol: symbol, tint: TimelineEntryRow.color(tone), fill: TimelineEntryRow.fill(tone))
    }

    var body: some View {
        let side: CGFloat = kind == .step ? Self.stepSize : Self.size
        let ring: CGFloat = kind == .step ? 0 : Self.hairline
        let halo: CGFloat = kind == .entry ? Self.halo : 0
        Group {
            if live {
                StatusDot(.working, size: kind == .step ? .regular : .large, live: true)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: kind == .step ? 10 : 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: side, height: side)
        .background(Circle().fill(fill))
        .overlay(Circle().strokeBorder(tint.opacity(0.2), lineWidth: ring))
        .background(Circle().fill(DesignTokens.Surface.content.color).padding(-halo))
        .accessibilityHidden(true)
    }
}

/// The rule line joining one entry's mark to the next one's (`.timeline .tl-entry::before`): 1.5 pt, from the strong
/// stroke to the separator's.
struct TimelineRuleLine: View {
    static let width: CGFloat = 1.5

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(LinearGradient(
                colors: [DesignTokens.Surface.strong.color, DesignTokens.Surface.separator.color], startPoint: .top, endPoint: .bottom
            ))
            .frame(width: Self.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityHidden(true)
    }
}

/// What QA found, under its entry (the prototype's `.finding-card`): the Finding badge and the finding's line, QA's
/// description, and the screenshots QA attached as thumbnails, read through the page's `ArtifactImages`.
struct TimelineFindingCard: View {
    let finding: TimelineFinding

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
                Badge(status: .problem, word: TimelineFinding.word, size: .small)
                    .fixedSize()
                Text(finding.title)
                    .font(DesignTokens.TypeStyle.rowTitle.font)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let text = finding.text {
                Text(text)
                    .font(DesignTokens.TypeStyle.body.font)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !finding.screenshots.isEmpty {
                HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
                    ForEach(finding.screenshots) { shot in
                        FindingShot(shot: shot)
                    }
                }
            }
        }
        .padding(.vertical, DesignTokens.Space.s3)
        .padding(.horizontal, DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Surface.content.color, in: shape)
        .overlay(shape.strokeBorder(DesignTokens.Status.problem.tint.opacity(0.25), lineWidth: 1))
        .elevation(.level1, in: shape)
    }
}

/// One screenshot of a finding: its thumbnail, cut from its top left, and its label under it. The thumbnail is read
/// once through the page's `ArtifactImages`; without one (a snapshot that keeps none), or while it reads, the frame
/// holds its place.
struct FindingShot: View {
    let shot: TicketScreenshot
    @Environment(\.artifactImages) private var images

    static let size = CGSize(width: 160, height: 100)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Group {
                if let images {
                    FindingThumbnail(shot: shot, images: images)
                } else {
                    Self.placeholder(nil)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous)
                    .strokeBorder(DesignTokens.Surface.separator.color, lineWidth: 1)
            )
            Text(shot.label)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.size.width, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shot.available ? "Screenshot \(shot.label)" : shot.unavailableAccessibilityLabel)
    }

    static func placeholder(_ text: String?) -> some View {
        ZStack {
            DesignTokens.Surface.separator.color.opacity(0.4)
            if let text {
                Text(text)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(DesignTokens.Space.s2)
            }
        }
    }
}

private struct FindingThumbnail: View {
    let shot: TicketScreenshot
    @ObservedObject var images: ArtifactImages

    var body: some View {
        Group {
            switch images.image(shot) {
            case let .loaded(data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: FindingShot.size.width, height: FindingShot.size.height, alignment: .topLeading)
                } else {
                    FindingShot.placeholder(TicketScreenshot.unavailableTitle)
                }
            case .unavailable:
                FindingShot.placeholder(TicketScreenshot.unavailableTitle)
            case .loading, .failed:
                FindingShot.placeholder(nil)
            }
        }
        .onAppear { images.load(shot) }
    }
}

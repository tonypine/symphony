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
            if let resolution = finding.resolution {
                Label {
                    Text(resolution)
                } icon: {
                    Image(systemName: DesignTokens.Status.done.symbol)
                        .foregroundStyle(DesignTokens.Status.done.tint)
                }
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if !finding.screenshots.isEmpty {
                ThumbnailSet(shots: finding.screenshots, size: FindingShot.size, showsLabels: true)
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

/// The screenshots a run recorded, in its group: under the step they were recorded in, else under the run. Thumbnails
/// with no captions, wrapping in the width they are given (`ThumbnailSet`); each opens in the image viewer, which holds
/// the whole set.
public struct ScreenshotRow: View {
    let shots: [TicketScreenshot]
    /// The width the row is drawn at, when it is fixed (a snapshot); nil measures what the container gives.
    var width: CGFloat? = nil

    static let size = CGSize(width: 120, height: 75)

    public init(shots: [TicketScreenshot], width: CGFloat? = nil) {
        self.shots = shots
        self.width = width
    }

    public var body: some View {
        ThumbnailSet(shots: shots, size: Self.size, width: width)
    }
}

/// A set of thumbnails that never draws wider than the width it is given: they wrap onto further rows, leading
/// aligned, with `Space.s2` between them, in at most two rows. When the set does not fit two rows, the last cell of the
/// second is a "+N" tile that opens the image viewer on the first image not shown. The viewer always holds the whole
/// set.
struct ThumbnailSet: View {
    let shots: [TicketScreenshot]
    let size: CGSize
    /// Each thumbnail with its label under it (a finding's shots), else the thumbnail alone.
    var showsLabels = false
    var width: CGFloat? = nil

    @State private var measuredWidth: CGFloat?

    private static let spacing = DesignTokens.Space.s2
    /// Before the width is measured every thumbnail is drawn: wide enough to hold any set.
    private static let unmeasuredWidth: CGFloat = 100_000

    private var plan: ThumbnailRowPlan {
        ThumbnailRowPlan(
            count: shots.count, width: width ?? measuredWidth ?? Self.unmeasuredWidth, thumbnailWidth: size.width, spacing: Self.spacing
        )
    }

    var body: some View {
        let plan = plan
        ThumbnailWrap(cellWidth: size.width, columns: plan.columns, spacing: Self.spacing) {
            ForEach(0..<plan.shown, id: \.self) { index in
                if showsLabels {
                    FindingShot(shot: shots[index], set: shots)
                } else {
                    ScreenshotThumbnail(shot: shots[index], set: shots, size: size)
                }
            }
            if plan.hasMoreTile {
                MoreScreenshotsTile(hidden: plan.hidden, first: shots[plan.shown], set: shots, size: size)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { measuredWidth = $0 })
        .accessibilityElement(children: .contain)
    }
}

/// Lays its cells out in rows of `columns`, leading aligned, never wider than it is offered.
private struct ThumbnailWrap: Layout {
    let cellWidth: CGFloat
    let columns: Int
    let spacing: CGFloat

    private func rows(_ subviews: Subviews) -> [[Int]] {
        stride(from: 0, to: subviews.count, by: columns).map { Array($0..<min($0 + columns, subviews.count)) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cellProposal = ProposedViewSize(width: cellWidth, height: nil)
        var height: CGFloat = 0
        let rows = rows(subviews)
        for row in rows {
            height += row.map { subviews[$0].sizeThatFits(cellProposal).height }.max() ?? 0
        }
        height += spacing * CGFloat(max(0, rows.count - 1))
        let natural = CGFloat(min(columns, subviews.count)) * cellWidth + spacing * CGFloat(max(0, min(columns, subviews.count) - 1))
        return CGSize(width: min(natural, proposal.width ?? natural), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cellProposal = ProposedViewSize(width: cellWidth, height: nil)
        var y = bounds.minY
        for row in rows(subviews) {
            var rowHeight: CGFloat = 0
            for (column, index) in row.enumerated() {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (cellWidth + spacing), y: y), anchor: .topLeading, proposal: cellProposal
                )
                rowHeight = max(rowHeight, subviews[index].sizeThatFits(cellProposal).height)
            }
            y += rowHeight + spacing
        }
    }
}

/// The last cell of a set that does not fit: "+N", drawn like a thumbnail's frame. It opens the image viewer on the
/// first image not shown.
struct MoreScreenshotsTile: View {
    let hidden: Int
    let first: TicketScreenshot
    let set: [TicketScreenshot]
    let size: CGSize
    @Environment(\.artifactImages) private var images
    @Environment(\.openImageViewer) private var openImageViewer

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous)
        Button {
            if let images { openImageViewer?(set, current: first, images: images) }
        } label: {
            Text(ThumbnailRowPlan.moreText(hidden))
                .textStyle(.rowTitle)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .monospacedDigit()
                .frame(width: size.width, height: size.height)
                .background(DesignTokens.Surface.separator.color.opacity(0.4), in: shape)
                .overlay(shape.strokeBorder(DesignTokens.Surface.separator.color, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(ThumbnailRowPlan.moreAccessibilityLabel(hidden))
        .accessibilityLabel(ThumbnailRowPlan.moreAccessibilityLabel(hidden))
    }
}

/// A screenshot's thumbnail, cut from its top left in a hairline frame: a button that opens it in the image viewer,
/// on `set` (the images it sits among: its row, its finding, its evidence), which it is one of. It is read once through
/// the page's `ArtifactImages`; without one (a snapshot that keeps none), or while it reads, the frame holds its place.
struct ScreenshotThumbnail: View {
    let shot: TicketScreenshot
    var set: [TicketScreenshot]
    var size: CGSize = FindingShot.size
    @Environment(\.artifactImages) private var images
    @Environment(\.openImageViewer) private var openImageViewer

    init(shot: TicketScreenshot, set: [TicketScreenshot]? = nil, size: CGSize = FindingShot.size) {
        self.shot = shot
        self.set = set ?? [shot]
        self.size = size
    }

    var body: some View {
        Button {
            if let images { openImageViewer?(set, current: shot, images: images) }
        } label: {
            Group {
                if let images {
                    FindingThumbnail(shot: shot, images: images, size: size)
                } else {
                    FindingShot.placeholder(nil)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous)
                    .strokeBorder(DesignTokens.Surface.separator.color, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!shot.available)
        .help(shot.label)
        .accessibilityLabel(shot.available ? shot.accessibilityLabel : shot.unavailableAccessibilityLabel)
    }
}

/// One screenshot of a finding: its thumbnail, which opens it in the image viewer with the finding's other shots (`set`),
/// and its label under it.
struct FindingShot: View {
    let shot: TicketScreenshot
    var set: [TicketScreenshot]? = nil

    static let size = CGSize(width: 160, height: 100)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ScreenshotThumbnail(shot: shot, set: set, size: Self.size)
            Text(shot.label)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.size.width, alignment: .leading)
                .accessibilityHidden(true)
        }
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

struct FindingThumbnail: View {
    let shot: TicketScreenshot
    @ObservedObject var images: ArtifactImages
    var size: CGSize = FindingShot.size

    var body: some View {
        Group {
            switch images.image(shot) {
            case let .loaded(data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
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

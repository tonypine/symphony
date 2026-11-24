import SwiftUI
import SymphonyBarCore

// The done row (TP-1644, `.drow` in `docs/design/prototypes/home-queue/page.css`): a ticket that finished, on one line
// at the queue row's height, type and 8 pt inner padding. The green check of a passed stage, the identifier in the
// queue row's fixed column, the title; then the cells the place asks for: the ticket's epic as a quiet flag and
// identifier, the pull request number (58 pt), the repo (68 pt) and when it was done, right-aligned (76 pt). Recently
// done shows all of them; an epic's done list on a slot card shows the pull request and when; an epic's done rows in
// the queue show only when.

/// What a done row says about its ticket.
public struct DoneRowModel: Equatable, Identifiable {
    public var id: String { identifier }
    public var identifier: String
    public var title: String
    /// The epic's identifier, nil for a ticket on its own.
    public var epic: String?
    /// "#1053", nil before a pull request is known.
    public var pullRequest: String?
    public var repo: String
    /// "20 min ago", "yesterday", "Sat".
    public var when: String

    public init(identifier: String, title: String, epic: String? = nil, pullRequest: String? = nil, repo: String, when: String) {
        self.identifier = identifier
        self.title = title
        self.epic = epic
        self.pullRequest = pullRequest
        self.repo = repo
        self.when = when
    }
}

public struct DoneRow: View {
    /// The cells after the title, chosen by the place that draws the row.
    public struct Cells: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let epic = Cells(rawValue: 1 << 0)
        public static let pullRequest = Cells(rawValue: 1 << 1)
        public static let repo = Cells(rawValue: 1 << 2)
        public static let when = Cells(rawValue: 1 << 3)

        /// Recently done's: every cell.
        public static let all: Cells = [.epic, .pullRequest, .repo, .when]
        /// An epic's done list on a slot card: the pull request and when.
        public static let slotCard: Cells = [.pullRequest, .when]
        /// An epic's done rows in the queue: when alone.
        public static let queue: Cells = [.when]
    }

    /// The row's parts, each in its own cell, as `parts(_:)` lists them.
    public enum Part: String, CaseIterable, Hashable {
        case check, identifier, title, epic, pullRequest, repo, when
    }

    let row: DoneRowModel
    let cells: Cells
    let hovered: Bool?
    @State private var pointer = false

    /// The row of `row` with the trail's `cells`. `hovered` draws the hover still, for a story; nil follows the pointer.
    public init(_ row: DoneRowModel, cells: Cells = .all, hovered: Bool? = nil) {
        self.row = row
        self.cells = cells
        self.hovered = hovered
    }

    /// The parts a row with `cells` draws, in order. The epic's cell is drawn only for a ticket that has one; the pull
    /// request's cell keeps its width without one, so the columns stay level.
    public static func parts(_ cells: Cells, epic: Bool = true) -> [Part] {
        var parts: [Part] = [.check, .identifier, .title]
        if cells.contains(.epic), epic { parts.append(.epic) }
        if cells.contains(.pullRequest) { parts.append(.pullRequest) }
        if cells.contains(.repo) { parts.append(.repo) }
        if cells.contains(.when) { parts.append(.when) }
        return parts
    }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        HStack(spacing: queue.rowPartGap) {
            Image(systemName: queue.doneStatus.symbol)
                .font(DesignTokens.TypeStyle.font(size: DesignTokens.Row.leadGlyph, weight: DesignTokens.Row.titleWeight))
                .foregroundStyle(queue.doneStatus.tint)
                .frame(width: DesignTokens.Row.leadSize, height: DesignTokens.Row.leadSize)
                .padding(.leading, queue.doneLeadLeading)
                .padding(.trailing, queue.doneLeadTrailing)
                .accessibilityHidden(true)
            HStack(spacing: queue.rowMainGap) {
                Text(row.identifier)
                    .textStyle(.rowTitle)
                    .monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .frame(minWidth: QueueRow.identifierWidth, alignment: .leading)
                Text(row.title)
                    .font(DesignTokens.TypeStyle.font(size: DesignTokens.TypeStyle.rowTitle.size, weight: DesignTokens.Row.titleWeight))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trail
        }
        .padding(.horizontal, queue.rowInset)
        .frame(maxWidth: .infinity)
        .frame(height: queue.rowHeight)
        .background { if hovered ?? pointer { shape.fill(DesignTokens.StateSurface.hover.fill) } }
        .contentShape(shape)
        .onHover { pointer = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(row, cells: cells))
        .accessibilityIdentifier(Self.accessibilityIdentifier(row.identifier))
    }

    /// The row as VoiceOver reads it: done, the identifier and title, then the cells the place shows.
    public static func accessibilityLabel(_ row: DoneRowModel, cells: Cells) -> String {
        var words = ["Done", row.identifier, row.title]
        if cells.contains(.epic), let epic = row.epic { words.append("part of \(epic)") }
        if cells.contains(.pullRequest), let pullRequest = row.pullRequest { words.append("pull request \(pullRequest)") }
        if cells.contains(.repo) { words.append(row.repo) }
        if cells.contains(.when) { words.append(row.when) }
        return words.joined(separator: ", ")
    }

    /// The row's identifier in the accessibility tree, which a window test finds it by.
    public static func accessibilityIdentifier(_ ticket: String) -> String { "done-row-\(ticket)" }

    private var trail: some View {
        let queue = DesignTokens.HomeQueue.self
        return HStack(spacing: queue.rowMainGap) {
            if cells.contains(.epic), let epic = row.epic {
                glyphed(SymphonyView.initiatives.symbol, epic)
                    .foregroundStyle(DesignTokens.TextColor.tertiary.color)
            }
            if cells.contains(.pullRequest) {
                Group {
                    if let pullRequest = row.pullRequest {
                        glyphed(queue.pullRequestSymbol, pullRequest)
                            .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    }
                }
                .frame(width: queue.pullRequestCell, alignment: .leading)
            }
            if cells.contains(.repo) {
                Text(row.repo)
                    .textStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                    .frame(width: queue.repoCell, alignment: .trailing)
            }
            if cells.contains(.when) {
                Text(row.when)
                    .textStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .frame(width: queue.whenCell, alignment: .trailing)
            }
        }
        .fixedSize()
    }

    /// A cell's glyph, tertiary, and its words.
    private func glyphed(_ symbol: String, _ text: String) -> some View {
        let queue = DesignTokens.HomeQueue.self
        return HStack(spacing: queue.trailGlyphGap) {
            Image(systemName: symbol)
                .font(DesignTokens.TypeStyle.font(size: queue.trailGlyph, weight: DesignTokens.TypeStyle.label.weight))
                .foregroundStyle(DesignTokens.TextColor.tertiary.color)
            Text(text)
                .textStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
    }
}

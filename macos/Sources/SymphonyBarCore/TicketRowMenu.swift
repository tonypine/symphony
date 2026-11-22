import Foundation

/// A Tickets row's context menu, as a list the view draws (TP-1611): Open Ticket, Start Now when the state says
/// whether the ticket may start (dimmed, with Symphony's reason, when it may not), and Move to… when there are phases
/// to offer. The view renders these items in this order and nothing else.
public enum TicketRowMenuItem: Equatable {
    case open
    case start(TicketStart)
    case move(TicketMoveMenu)

    /// The item's title as the menu shows it.
    public var title: String {
        switch self {
        case .open: TicketList.openTitle
        case .start: TicketStart.title
        case .move: TicketMoveMenu.title
        }
    }

    /// Whether the item can be picked.
    public var isEnabled: Bool {
        if case let .start(start) = self { return start.allowed }
        return true
    }

    /// The items of ticket `identifier`'s row menu, given its Start now (nil when the state sends none) and its Move
    /// to… menu (nil when there is none to offer).
    public static func items(start: TicketStart?, move: TicketMoveMenu?) -> [TicketRowMenuItem] {
        [.open] + [start.map(TicketRowMenuItem.start), move.map(TicketRowMenuItem.move)].compactMap { $0 }
    }
}

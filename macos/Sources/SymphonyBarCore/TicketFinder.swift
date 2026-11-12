import Foundation

/// ⌘F from any page (TP-1455): a field that finds a ticket by its identifier or its title, and opens its page.
public enum TicketFinder {
    public static let title = "Find a Ticket"
    public static let menuTitle = "Find a Ticket…"
    public static let prompt = "Identifier or title"
    public static let openTitle = "Open"
    public static let noMatch = "No ticket Symphony tracks matches."
    public static let limit = 8

    /// The tracked tickets that match what was typed, best first: the identifier named exactly, then the identifiers
    /// that start with it, then the titles that hold every word of it. Nothing while the field is empty.
    public static func matches(_ query: String, in list: TicketList?) -> [TicketList.Row] {
        let query = query.trimmingWhitespace()
        guard !query.isEmpty, let list else { return [] }
        let upper = query.uppercased()
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let exact = list.rows.filter { $0.identifier.uppercased() == upper }
        let prefixed = list.rows.filter { $0.identifier.uppercased().hasPrefix(upper) && $0.identifier.uppercased() != upper }
        let titled = list.rows.filter { row in
            guard !row.identifier.uppercased().hasPrefix(upper), let title = row.title else { return false }
            return words.allSatisfy { title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return Array((exact + prefixed + titled).prefix(limit))
    }

    /// The ticket Return opens: the best match, else what was typed when it reads as an identifier ("tp-1455"), whose
    /// page says what Symphony knows of it. Nil while nothing would open.
    public static func target(_ query: String, in list: TicketList?) -> String? {
        if let row = matches(query, in: list).first { return row.identifier }
        let query = query.trimmingWhitespace()
        guard query.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return query.uppercased()
    }

    /// A match's line: "TP-1455 · The five destinations".
    public static func line(_ row: TicketList.Row) -> String {
        row.title.map { "\(row.identifier) · \($0)" } ?? row.identifier
    }
}

import Foundation

/// Why `tickets.priorities` can't be read or changed by editing one line.
public enum TicketPrioritiesError: LocalizedError, Equatable {
    /// The key holds an inline value under a section that is itself inline (for example
    /// `tickets: {priorities: [urgent]}`), instead of an indented block.
    case notABlock(String)
    /// A list item that is not one of Linear's priority names or numbers.
    case unreadable(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the allowed ticket priorities by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml is not a Linear priority. Change it by hand."
        }
    }
}

/// The Linear priorities an issue may carry to start new work, in Linear's own order.
public enum TicketPriority: String, CaseIterable, Hashable {
    case urgent, high, medium, low, none

    /// The name shown in Settings.
    public var title: String {
        switch self {
        case .urgent: return "Urgent"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .none: return "No priority"
        }
    }

    /// The priority as a human writes it in symphony.yml, and the name Linear returns for its number.
    static func named(_ value: String) -> TicketPriority? {
        aliases[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    private static let aliases: [String: TicketPriority] = [
        "1": .urgent, "urgent": .urgent,
        "2": .high, "high": .high,
        "3": .medium, "medium": .medium,
        "4": .low, "low": .low,
        "0": .none, "none": .none, "no priority": .none, "no_priority": .none
    ]
}

/// `tickets.priorities` in the text of a `symphony.yml`: the Linear priorities allowed to start new
/// work. An empty set means every priority may, which is Symphony's default.
public struct TicketPriorities: Equatable {
    public var priorities: Set<TicketPriority>

    public static let section = "tickets"
    public static let key = "priorities"

    public init(priorities: Set<TicketPriority> = []) {
        self.priorities = priorities
    }

    /// The filter in the file: an inline list such as `priorities: [urgent, high]` or a block list.
    /// A missing key, an empty list or `null` reads as every priority allowed.
    public static func values(in yaml: String) throws -> TicketPriorities {
        let raw = try blockSection { try ConfigSetting.value(at: [section, key], of: yaml) }
        guard let raw else { return TicketPriorities() }
        let items = raw.trimmingCharacters(in: .whitespaces).isEmpty ? try blockListItems(in: yaml) : inlineItems(raw)
        return TicketPriorities(priorities: try parse(items))
    }

    /// The same text with `tickets.priorities` set to `new`. Writes an inline list, and clears the
    /// filter to `priorities: []` when nothing is chosen, so no key is ever removed by hand.
    public static func updating(_ yaml: String, from old: TicketPriorities, to new: TicketPriorities) throws -> String {
        guard new != old else { return yaml }
        return try blockSection { try ConfigSetting.setting(at: [section, key], to: inline(new.priorities), in: yaml) }
    }

    /// The same text with `tickets.priorities` set to Symphony's default (every priority allowed).
    public static func cleared(_ yaml: String) throws -> String {
        try updating(yaml, from: try values(in: yaml), to: TicketPriorities())
    }

    /// `[urgent, high]`, in Linear's order.
    private static func inline(_ priorities: Set<TicketPriority>) -> String {
        "[" + TicketPriority.allCases.filter { priorities.contains($0) }.map(\.rawValue).joined(separator: ", ") + "]"
    }

    private static func parse(_ items: [String]) throws -> Set<TicketPriority> {
        try items.reduce(into: Set<TicketPriority>()) { result, item in
            if item.isEmpty { return }
            guard let priority = TicketPriority.named(item) else {
                throw TicketPrioritiesError.unreadable(key: key, value: item)
            }
            result.insert(priority)
        }
    }

    /// The items of an inline list, `[urgent, high]`, or a single bare value such as `urgent`.
    private static func inlineItems(_ raw: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("["), text.hasSuffix("]") else {
            return text.isEmpty || text == "~" || text == "null" ? [] : [text]
        }
        return text.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The items of a block list under `tickets.priorities`.
    private static func blockListItems(in yaml: String) throws -> [String] {
        let document = Document(yaml)
        var range = document.all
        for name in [section, key] {
            guard let child = document.child(name, in: range) else { return [] }
            if name == key { return document.blockListItems(child) }
            range = try document.block(of: child)
        }
        return []
    }

    /// Reports an inline `tickets:` as a priorities error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw TicketPrioritiesError.notABlock(key)
        }
    }
}

extension Document {
    /// The scalar items of the block list under `key`, the lines beginning `- `. Empty when the key
    /// holds no block list.
    func blockListItems(_ key: Key) -> [String] {
        children(of: key).compactMap { index in
            guard let indent = indent(at: index) else { return nil }
            let content = lines[index].dropFirst(indent)
            guard content.hasPrefix("- ") else { return nil }
            return String(content.dropFirst(2)).trimmingWhitespace()
        }
    }
}

extension SymphonyConfigFile {
    public func readTicketPriorities() throws -> TicketPriorities {
        try TicketPriorities.values(in: read())
    }

    /// Sets the allowed priorities once `check` passes on the result.
    public func writeTicketPriorities(
        _ new: TicketPriorities,
        from old: TicketPriorities,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try TicketPriorities.updating($0, from: old, to: new) }, checkingWith: check)
    }

    /// Runs `check` on a copy of the file with the priorities set, without changing the file.
    public func checkTicketPriorities(
        _ new: TicketPriorities,
        from old: TicketPriorities,
        with check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await checking({ try TicketPriorities.updating($0, from: old, to: new) }, with: check)
    }
}

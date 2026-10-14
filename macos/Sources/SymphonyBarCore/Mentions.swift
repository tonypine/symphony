import Foundation

/// A ticket or pull request an Inbox item's text mentions, as its chip (N1) shows it: the mention as written, the
/// ticket's short name when the text gives one in brackets right after it, and what Symphony resolved it to.
public struct Mention: Equatable {
    public enum Kind: Equatable {
        case ticket
        case pullRequest
    }

    /// The mention as written, the key of the item's `references`: "TP-891", "PR #448", "#448".
    public var key: String
    /// Where the chip sits in the text, in UTF-16 units, the short name and its brackets included.
    public var range: NSRange
    public var kind: Kind
    /// The name in brackets right after a ticket, as in "TP-891 (Remove the retired review states)".
    public var shortName: String?
    /// What Symphony resolved it to; `.missing` when it couldn't, or when the item's `references` lack it.
    public var reference: Reference

    public var isMissing: Bool {
        if case .missing = reference { return true }
        return false
    }

    /// The chip's text: the mention, then " · " and the short name. It has the same UTF-16 length as `range`, so a
    /// position in the chip's text is the same position in the item's.
    public var chipText: String {
        shortName.map { "\(key) · \($0)" } ?? key
    }

    /// VoiceOver's name for the chip: "TP-891, Remove the retired review states, Code Review".
    public var accessibilityLabel: String {
        switch reference {
        case let .ticket(ticket):
            return [key, shortName ?? ticket.title, ticket.state].compactMap { $0 }.joined(separator: ", ")
        case let .pullRequest(pullRequest):
            return ["PR #\(pullRequest.number)", pullRequest.title, pullRequest.reviewState.word].compactMap { $0 }.joined(separator: ", ")
        case .missing:
            return [key, shortName, "Symphony can't see it"].compactMap { $0 }.joined(separator: ", ")
        }
    }
}

/// Finds the mentions in a text the Inbox shows.
public enum Mentions {
    /// Symphony's own mention pattern (`SymphonyElixir.Inbox.Mentions`): a pull request, `PR #448` or a bare `#448`,
    /// or a ticket identifier, `TP-892`.
    static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w-])PR\s?#\d+(?![\w-])|(?<![\w&#/])#\d+(?![\w-])|(?<![\w-])[A-Z][A-Z0-9]*-\d+(?![\w-])"#
    )
    static let pullRequestKey = try! NSRegularExpression(pattern: #"^(?:PR\s?)?#\d+$"#)
    /// A ticket's short name: " (" then up to 80 characters without brackets or line breaks, then ")".
    static let shortName = try! NSRegularExpression(pattern: #" \(([^()\n]{1,80})\)"#)

    /// The mentions in `text`, in reading order. Each key of `references` and each match of Symphony's pattern is a
    /// candidate; the longest wins where two overlap, so "PR #448" wins over "#448". A mention outside `references`
    /// is missing.
    public static func find(in text: String, references: [String: Reference]) -> [Mention] {
        let string = text as NSString
        var candidates: [(range: NSRange, key: String)] = []
        for key in references.keys where !key.isEmpty {
            var searched = NSRange(location: 0, length: string.length)
            while true {
                let found = string.range(of: key, options: [], range: searched)
                guard found.location != NSNotFound else { break }
                if standsAlone(found, in: string, bareNumber: key.hasPrefix("#")) { candidates.append((found, key)) }
                let next = found.location + 1
                searched = NSRange(location: next, length: string.length - next)
            }
        }
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            candidates.append((match.range, string.substring(with: match.range)))
        }

        var taken: [(range: NSRange, key: String)] = []
        let longestFirst = candidates.sorted {
            $0.range.length != $1.range.length ? $0.range.length > $1.range.length : $0.range.location < $1.range.location
        }
        for candidate in longestFirst where !taken.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) {
            taken.append(candidate)
        }
        taken.sort { $0.range.location < $1.range.location }

        return taken.enumerated().map { index, candidate in
            let kind: Mention.Kind = isPullRequest(candidate.key) ? .pullRequest : .ticket
            var range = candidate.range
            var name: String?
            let nextStart = index + 1 < taken.count ? taken[index + 1].range.location : string.length
            if kind == .ticket,
                let match = shortName.firstMatch(in: text, options: .anchored, range: NSRange(location: NSMaxRange(range), length: string.length - NSMaxRange(range))),
                NSMaxRange(match.range) <= nextStart
            {
                name = string.substring(with: match.range(at: 1))
                range.length += match.range.length
            }
            return Mention(
                key: candidate.key, range: range, kind: kind, shortName: name,
                reference: references[candidate.key] ?? .missing(url: nil)
            )
        }
    }

    static func isPullRequest(_ key: String) -> Bool {
        pullRequestKey.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil
    }

    /// True when no word character or hyphen touches `range` (nor `&`, `#` or `/` before a bare `#448`), as the
    /// pattern's lookarounds ask.
    private static func standsAlone(_ range: NSRange, in string: NSString, bareNumber: Bool) -> Bool {
        // Whole characters, so a surrogate pair next to the mention is read as one character, not half a pair.
        let before = range.location > 0 ? string.substring(with: string.rangeOfComposedCharacterSequence(at: range.location - 1)) : ""
        let after = NSMaxRange(range) < string.length ? string.substring(with: string.rangeOfComposedCharacterSequence(at: NSMaxRange(range))) : ""
        let joins: (String) -> Bool = { character in
            character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
        }
        if joins(before) || joins(after) { return false }
        return !(bareNumber && ["&", "#", "/"].contains(before))
    }
}

extension Reference.PullRequest.ReviewState {
    /// The review state in the popover's words.
    public var word: String {
        switch self {
        case .open: "Open"
        case .changesRequested: "Changes asked"
        case .approved: "Approved"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

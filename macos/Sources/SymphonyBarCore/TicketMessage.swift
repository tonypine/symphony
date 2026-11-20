import Foundation

/// The box above a ticket's timeline (`docs/design/director-window-and-home.md`, "Writing to the ticket"): what the
/// Director writes to the ticket, which Symphony records as a message of the ticket's history
/// (`POST /api/v1/control/message`, a `message.sent` event); the ticket's Conductor answers it on a groomed ticket, and
/// on any other the next run reads it first. ⌘↩ or Send posts it; on success
/// the box clears and the page reads what is new in the feed, so the message is the timeline's newest entry at once. A
/// refusal keeps the text and says why under the box. What is typed and not sent stays with its ticket while the app
/// runs: leaving the page and coming back finds it there.
@MainActor
public final class TicketMessageComposer: ObservableObject {
    /// The most characters a message holds: the `message.sent` event type's bound, which Symphony checks too.
    public nonisolated static let maxLength = 4_000
    /// What VoiceOver reads the box as.
    public static let label = "Write to the ticket"
    public static let placeholder = "Write to the ticket. The next run reads it first."
    public static let sendTitle = "Send"
    public static let sendingTitle = "Sending…"
    /// The keys that send, as the hint beside Send shows them.
    public static let shortcut = "⌘ ↩"
    /// What VoiceOver says once a message is sent.
    public static let sentAnnouncement = "Message sent. The next run reads it first."
    /// What VoiceOver says once a message is sent on a groomed ticket.
    public static let groomedSentAnnouncement = "Message sent."

    /// What VoiceOver says once a message is sent, by whether the ticket is `groomed`.
    public static func sentAnnouncement(groomed: Bool) -> String { groomed ? groomedSentAnnouncement : sentAnnouncement }
    /// The reason under the box when Symphony doesn't serve the ticket's events feed (a 404 not the feed's own), which a
    /// message is written to.
    public static let unsupportedReason = "This version of Symphony can't take messages. Update Symphony to write to the ticket."
    /// The reason under the box when the feed has no record of the ticket (its own 404): Symphony writes one when the
    /// ticket's first run starts, and a message before then would be refused.
    public static let unknownTicketReason = "Symphony has no history for this ticket yet. A message can go on once its first run starts."
    /// The reason under the box while the ticket's history isn't read: before the first read, or after one that failed.
    public static let readingReason = "Reading the ticket's history…"

    @Published public var text = ""
    /// True while a message is on its way; ⌘↩ meanwhile posts nothing.
    @Published public private(set) var sending = false
    /// Why the last message wasn't sent: too long, or Symphony's answer.
    @Published public private(set) var refusal: String?
    /// The ticket whose box this is.
    public private(set) var identifier: String?
    /// What was typed on the other tickets and not sent, by ticket.
    private var drafts: [String: String] = [:]

    /// An empty box; or, for an offscreen render, ticket `identifier`'s box with `text` and the reason it shows.
    public init(identifier: String? = nil, text: String = "", refusal: String? = nil) {
        self.identifier = identifier
        self.text = text
        self.refusal = refusal
    }

    /// The refusal line for VoiceOver.
    public static func refusalLabel(_ reason: String) -> String { "Message not sent: \(reason)" }

    /// Why `message` is too long to be one, nil when it isn't: the reason Symphony would give.
    public nonisolated static func tooLong(_ message: String) -> String? {
        guard message.count > maxLength else { return nil }
        return "A message holds at most \(delimited(maxLength)) characters; this one has \(delimited(message.count))"
    }

    private nonisolated static func delimited(_ number: Int) -> String {
        number.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// Whether the box holds text, so the row with the ⌘↩ hint and Send shows under it.
    public var hasDraft: Bool { !text.trimmingWhitespace().isEmpty }

    /// The draft kept for ticket `identifier`, nil when there is none (its box is empty).
    public func draft(_ identifier: String) -> String? {
        identifier == self.identifier ? text.nonEmptyDraft : drafts[identifier]
    }

    /// Shows the box of ticket `identifier`: the ticket shown before keeps what was typed in its box, and this one finds
    /// its own draft, or starts empty. A message still on its way for the one before changes nothing here when it lands.
    public func show(_ identifier: String?) {
        guard identifier != self.identifier else { return }
        if let shown = self.identifier { drafts[shown] = text.nonEmptyDraft }
        self.identifier = identifier
        text = identifier.flatMap { drafts.removeValue(forKey: $0) } ?? ""
        refusal = nil
        sending = false
    }

    /// ⌘↩ or Send: posts the message on `page`'s ticket with `send`, then `read`s what is new in its feed. A page that
    /// takes no message says why under the box; blank text, or a message on its way, posts nothing; a message over the
    /// bound is refused here, with the reason. Returns whether the message was sent.
    @discardableResult
    public func submit(on page: TicketPage, send: (ControlAction) async -> ControlResult, read: () -> Void) async -> Bool {
        self.identifier = page.identifier
        guard hasDraft, !sending else { return false }
        guard page.acceptsMessages, let repoKey = page.repoKey else {
            refusal = page.messagesOffReason ?? Self.readingReason
            return false
        }
        return await submit(identifier: page.identifier, repoKey: repoKey, send: send, read: read)
    }

    /// Posts what the box of ticket `identifier` of repository `repoKey` holds with `send`, then `read`s.
    private func submit(identifier: String, repoKey: String, send: (ControlAction) async -> ControlResult, read: () -> Void) async -> Bool {
        let message = text.trimmingWhitespace()
        if let reason = Self.tooLong(message) {
            refusal = reason
            return false
        }
        sending = true
        refusal = nil
        let result = await send(.message(repoKey: repoKey, identifier: identifier, text: message))
        guard self.identifier == identifier else {
            // The page moved to another ticket meanwhile: the sent text leaves that ticket's draft; a refused one stays.
            if result == .done, drafts[identifier]?.trimmingWhitespace() == message { drafts[identifier] = nil }
            return result == .done
        }
        sending = false
        if case let .failed(reason) = result {
            refusal = reason
            return false
        }
        // What was typed while the message was on its way stays.
        if text.trimmingWhitespace() == message { text = "" }
        read()
        return true
    }
}

private extension String {
    /// The text as a draft worth keeping: nil when it holds nothing but blanks.
    var nonEmptyDraft: String? { trimmingWhitespace().isEmpty ? nil : self }
}

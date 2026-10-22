import Foundation

/// The note field under a ticket's timeline: the Director's note, which Symphony writes on the ticket as a `note` event
/// by the Director (`POST /api/v1/control/note`). It shows in the timeline as "Note by you", and the next agent run
/// reads it in the ticket's summary. Return posts it; on success the field clears and the page reads what is new in
/// the feed, so the row shows at once. A refusal keeps the text and says why under the field.
@MainActor
public final class TicketNoteComposer: ObservableObject {
    /// The most characters a note holds: the `note` event type's bound, which Symphony checks too.
    public static let maxLength = 4_000
    public static let placeholder = "Add a note for the next run"
    public static let hint = "Press Return to add it to the timeline. The next agent run reads it."
    public static let sendingTitle = "Adding the note…"
    /// The line under the field when Symphony doesn't serve the ticket's events feed (a 404), which a note is written to.
    public static let unsupportedReason = "This version of Symphony can't take notes. Update Symphony to add one."
    /// The line under the field while the ticket's history isn't read: before the first read, or after one that failed.
    public static let readingReason = "Reading the ticket's history…"

    @Published public var text = ""
    /// True while a note is on its way; a Return meanwhile posts nothing.
    @Published public private(set) var sending = false
    /// Why the last note wasn't added: too long, or Symphony's answer.
    @Published public private(set) var refusal: String?
    /// The ticket whose field this is.
    public private(set) var identifier: String?

    /// An empty field; or, for an offscreen render, ticket `identifier`'s field with `text` and the reason it shows.
    public init(identifier: String? = nil, text: String = "", refusal: String? = nil) {
        self.identifier = identifier
        self.text = text
        self.refusal = refusal
    }

    /// "Note on SHOP-410", the field's label for VoiceOver.
    public static func fieldLabel(_ identifier: String) -> String { "Note on \(identifier)" }

    /// The refusal line for VoiceOver.
    public static func refusalLabel(_ reason: String) -> String { "Note not added: \(reason)" }

    /// Why `note` is too long to be one, nil when it isn't: the reason Symphony would give.
    public static func tooLong(_ note: String) -> String? {
        guard note.count > maxLength else { return nil }
        return "A note holds at most \(delimited(maxLength)) characters; this one has \(delimited(note.count))"
    }

    private static func delimited(_ number: Int) -> String {
        number.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// Shows the field of ticket `identifier`: another ticket's starts empty, and a note still on its way for the one
    /// before changes nothing here when it lands.
    public func show(_ identifier: String?) {
        guard identifier != self.identifier else { return }
        self.identifier = identifier
        text = ""
        refusal = nil
        sending = false
    }

    /// Return in the field: posts the note on `page`'s ticket with `send`, then `read`s what is new in its feed. Posts
    /// nothing when the page takes no notes, the text is blank or a note is on its way; a note over the bound is
    /// refused here, with the reason. Returns whether the note was written.
    @discardableResult
    public func submit(on page: TicketPage, send: (ControlAction) async -> ControlResult, read: () -> Void) async -> Bool {
        // The field is the shown page's: what is typed in it is that ticket's note.
        identifier = page.identifier
        guard page.acceptsNotes, let repoKey = page.repoKey, !sending else { return false }
        let note = text.trimmingWhitespace()
        guard !note.isEmpty else { return false }
        if let reason = Self.tooLong(note) {
            refusal = reason
            return false
        }
        let identifier = page.identifier
        sending = true
        refusal = nil
        let result = await send(.note(repoKey: repoKey, identifier: identifier, text: note))
        // The page moved to another ticket meanwhile: its field is another one.
        guard self.identifier == identifier else { return result == .done }
        sending = false
        if case let .failed(message) = result {
            refusal = message
            return false
        }
        // What was typed while the note was on its way stays.
        if text.trimmingWhitespace() == note { text = "" }
        read()
        return true
    }
}

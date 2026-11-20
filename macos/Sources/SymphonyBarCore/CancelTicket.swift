import Foundation

/// TP-1317: the consequence sheet of the Action rail's Cancel Ticket…. It says what Symphony's cancel does
/// (`SymphonyElixir.DirectorMoves`' `:cancel`): it ends a running agent, closes the open pull request with the note as
/// its comment, moves the ticket to Canceled for good, withdraws its open questions and clears its holds. Its button
/// sends `POST /api/v1/control/cancel` with the note; a refusal keeps the sheet open with Symphony's reason, and a
/// cancel that went through offers Undo on the banner, as Move to… does.
public struct CancelTicketSheet: Equatable, Identifiable {
    public static let notePrompt = "Why it is cancelled"
    public static let notePlaceholder = "Why it is cancelled (optional)"
    /// The button.
    public static let verb = "Cancel Ticket"
    /// The button that closes the sheet without sending anything: "Cancel" would read as the move itself.
    public static let keepTitle = "Keep It"

    public var identifier: String
    /// The phase it leaves, when the page knows it.
    public var from: String?
    /// Whether an agent runs on the ticket, so the cancel ends it.
    public var isRunning: Bool
    /// Whether the ticket has an open pull request, so the cancel closes it.
    public var hasOpenPullRequest: Bool

    public var id: String { identifier }

    public init(identifier: String, from: String? = nil, isRunning: Bool = false, hasOpenPullRequest: Bool = false) {
        self.identifier = identifier
        let from = from?.trimmingWhitespace()
        self.from = from?.isEmpty == false ? from : nil
        self.isRunning = isRunning
        self.hasOpenPullRequest = hasOpenPullRequest
    }

    /// The title is the question.
    public var title: String { "Cancel \(identifier)?" }

    /// What happens, in the order Symphony does it.
    public var happens: String {
        var parts: [String] = []
        if isRunning { parts.append("Ends the agent working on \(identifier).") }
        if hasOpenPullRequest { parts.append("Closes its pull request, with your note as the closing comment.") }
        let move = from.map { "Moves \(identifier) from \($0) to Canceled for good" } ?? "Moves \(identifier) to Canceled for good"
        parts.append(move + ", withdraws its open questions and clears its holds. Symphony doesn't work on it again.")
        return parts.joined(separator: " ")
    }

    /// What Undo gives back, and what it doesn't.
    public var stays: String {
        let back = from.map { "puts it back in \($0)" } ?? "puts it back where it was"
        return "Undo on the banner \(back) within 10 seconds; the pull request it closed, the run it ended and the "
            + "questions it withdrew stay as they are. Its branch stays."
    }

    /// The request the button sends: the trimmed note, left out when blank.
    public func action(note: String) -> ControlAction {
        let note = note.trimmingWhitespace()
        return .cancel(identifier, note: note.isEmpty ? nil : note)
    }

    /// The banner once Symphony answered: Undo only when the ticket moved.
    public func banner(after outcome: MoveOutcome) -> InboxBanner {
        let state = outcome.toState ?? Self.canceledState
        if outcome.moved {
            return InboxBanner(itemID: identifier, identifier: identifier, text: "Cancelled, moved to \(state)", undo: true)
        }
        return InboxBanner(itemID: identifier, identifier: identifier, text: "Already in \(state)", undo: false, style: .info)
    }

    /// What Symphony is expected to answer, for an answer that didn't say.
    public var expectedOutcome: MoveOutcome { MoveOutcome(moved: true, toState: Self.canceledState) }

    static let canceledState = "Canceled"
}

extension TicketPage {
    /// The Cancel Ticket… sheet for the page: the phase it leaves, whether an agent runs and whether its pull request is
    /// open, so the sheet says only what the cancel will do.
    public var cancelSheet: CancelTicketSheet {
        CancelTicketSheet(
            identifier: identifier,
            from: phaseName,
            isRunning: isRunning,
            hasOpenPullRequest: factsRead?.pullRequest?.state.lowercased() == "open"
        )
    }
}

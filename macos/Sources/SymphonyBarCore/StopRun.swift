import Foundation

/// D12c (C17, P5): the consequence sheet of Stop Run. It says what Stop does, from the code: the orchestrator ends
/// the agent and removes the ticket's workspace (`Orchestrator.terminate_running_issue/4` with cleanup); the ticket
/// keeps its Linear state, so the next poll dispatches it again. **Also move to Backlog** sends the Director's
/// `backlog` move with the note after the stop, so the ticket stays put.
public struct StopRunSheet: Equatable, Identifiable {
    /// Where the sheet opened from: Also move to Backlog is on from Needs attention, off from the ticket page.
    public enum Origin: Equatable {
        case needsAttention, ticketPage
    }

    public static let buttonTitle = "Stop Run…"
    public static let alsoBacklogTitle = "Also move to Backlog"
    public static let notePrompt = "Note posted on the ticket"
    public static let notePlaceholder = "Why it goes to Backlog (optional)"

    public var identifier: String
    public var origin: Origin
    /// Whether an agent runs on the ticket; a failing ticket between attempts has none to stop.
    public var isRunning: Bool
    /// The ticket's Linear state, when known.
    public var state: String?

    public var id: String { identifier }
    public var alsoBacklogByDefault: Bool { origin == .needsAttention }

    public init(identifier: String, origin: Origin, isRunning: Bool, state: String? = nil) {
        self.identifier = identifier
        self.origin = origin
        self.isRunning = isRunning
        self.state = state
    }

    /// The title is the question.
    public var title: String {
        isRunning ? "Stop the run on \(identifier)?" : "Move \(identifier) to Backlog?"
    }

    /// What happens.
    public func happens(alsoBacklog: Bool) -> String {
        let backlog = "moves \(identifier) to Backlog and posts your note on it as a comment"
        guard isRunning else {
            return "No agent runs on \(identifier) right now, so there is nothing to stop. This " + backlog + "."
        }
        let stop = "Ends the agent working on \(identifier) and removes its workspace, with any work it hasn't pushed."
        return alsoBacklog ? stop + " Then " + backlog + "." : stop
    }

    /// What stays the same.
    public func stays(alsoBacklog: Bool) -> String {
        let keeps = state.map { "keeps its Linear state, \($0)" } ?? "keeps its Linear state"
        if alsoBacklog {
            return "Symphony leaves \(identifier) alone while it is in Backlog; move it back to Todo to have it worked again. Its pull request and branch stay as they are."
        }
        return "\(identifier) \(keeps), so Symphony starts it again on its next poll. Its pull request and branch stay as they are."
    }

    /// The button: "Stop Run", or "Move to Backlog" when nothing runs.
    public var verb: String { isRunning ? "Stop Run" : "Move to Backlog" }

    /// Whether the button is on: with nothing running, only the Backlog move is left to do.
    public func canSend(alsoBacklog: Bool) -> Bool { isRunning || alsoBacklog }

    /// The control requests, in order: the stop, then the Backlog move with the note.
    public func actions(alsoBacklog: Bool, note: String) -> [ControlAction] {
        let note = note.trimmingWhitespace()
        var actions: [ControlAction] = isRunning ? [.stop(identifier)] : []
        if alsoBacklog { actions.append(.backlog(identifier, note: note.isEmpty ? nil : note)) }
        return actions
    }
}

/// Where the Symphony window is: a sidebar view or a ticket page.
public enum WindowPlace: Equatable, Hashable {
    case view(SymphonyView)
    case ticket(String)
}

/// P10: ⌘[ and ⌘] go back and forward between the views and the ticket pages the window showed, as a browser does.
public struct NavigationHistory: Equatable {
    public static let backTitle = "Back"
    public static let forwardTitle = "Forward"

    public private(set) var current: WindowPlace
    public private(set) var back: [WindowPlace] = []
    public private(set) var forward: [WindowPlace] = []

    public init(current: WindowPlace) {
        self.current = current
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Shows `place`: the place left goes on the back list and the forward list clears. Showing where it is changes
    /// nothing.
    public mutating func visit(_ place: WindowPlace) {
        guard place != current else { return }
        back.append(current)
        forward.removeAll()
        current = place
    }

    /// ⌘[: the place before, nil when there is none.
    @discardableResult
    public mutating func goBack() -> WindowPlace? {
        guard let place = back.popLast() else { return nil }
        forward.append(current)
        current = place
        return place
    }

    /// ⌘]: the place after, nil when there is none.
    @discardableResult
    public mutating func goForward() -> WindowPlace? {
        guard let place = forward.popLast() else { return nil }
        back.append(current)
        current = place
        return place
    }
}

import Foundation

/// An operator control the app sends to Symphony's `POST /api/v1/control/*`.
public enum ControlAction: Equatable {
    case pause
    /// Pause Dispatch from the window's sheet, with the reason typed there; the menu's reason when none was.
    case pauseWithReason(String)
    /// An update's pause: a `build` reason waiting on the version the update installs.
    case pauseForUpdate(version: String)
    case resume
    /// Adds the force label to the ticket, so it skips the dispatch limits.
    case force(String)
    /// Removes the force label from the ticket.
    case stopForcing(String)
    /// Stops the agent running on the ticket.
    case stop(String)
    /// The Director's moves from the Inbox (DD4): each names the ticket; Symphony checks its state.
    case approvePlan(String)
    case rework(String, reason: String)
    /// The full reset (design doc D7): close the pull request, branch fresh from main, supersede the
    /// workpad, back to In Progress. A person's move; agents cannot ask for it.
    case restart(String, reason: String)
    /// Answers a plan's questions: each pick goes under the request it names.
    case decisions(String, picks: [DecisionPick])
    /// Asks for changes to a plan under review: the reason goes on it as a comment, and Symphony revises the plan
    /// in place, keeping its sub-tickets. `rework` is the rejection that cancels them.
    case changes(String, reason: String)
    case backlog(String, note: String?)
    /// The free move (TP-1327): puts the ticket in phase `to`, any phase the state payload lists, keeping its
    /// workspace, branch and pull request; the note goes on its timeline with the move.
    case move(String, to: String, note: String?)
    /// Answers a decision request: the picks, the request they answer, and the state the decision directs (`rework`,
    /// `done`) when it directs one.
    case decide(String, request: AnsweredRequest, picks: [DecisionPick], move: String?)
    /// Clears an access hold on the ticket; it continues where it is (state-machine §Holds).
    case unblock(String)
    /// Takes back the last move on the ticket, within 10 s of it.
    case undo(String)
    /// Writes the Director's note on the ticket of repo `repoKey`: it shows in the ticket's timeline, and the next
    /// agent run reads it in the ticket's summary.
    case note(repoKey: String, identifier: String, text: String)
    /// Pauses dispatch for the repository `key` alone, with the Director's reason when they typed one; its tickets
    /// stay where they are.
    case pauseRepository(key: String, reason: String)
    /// Resumes dispatch for the repository `key`.
    case resumeRepository(key: String)

    /// The request a decision answers: its Question, by the id the Inbox row carries (TP-1240), or, from a Symphony
    /// whose row names none, the request comment its answer replies under. Symphony accepts either.
    public enum AnsweredRequest: Equatable {
        case question(String)
        case comment(String)

        /// The id named by the row: the Question's when it has one, else the request comment's; nil with neither.
        public init?(questionID: String?, commentID: String?) {
            if let questionID {
                self = .question(questionID)
            } else if let commentID {
                self = .comment(commentID)
            } else {
                return nil
            }
        }

        /// The field of the decide request that names it.
        var body: (key: String, value: String) {
            switch self {
            case let .question(id): ("question_id", id)
            case let .comment(id): ("request_comment_id", id)
            }
        }
    }

    /// A decision's question and the option the Director picked, or their own words, as `decisions` posts them; a
    /// plan's pick also names the request comment it answers, so the answer goes under it.
    public struct DecisionPick: Equatable {
        public var question: String
        public var answer: String
        public var requestCommentID: String?

        public init(question: String, answer: String, requestCommentID: String? = nil) {
            self.question = question
            self.answer = answer
            self.requestCommentID = requestCommentID
        }

        var body: [String: String] {
            var body = ["question": question, "answer": answer]
            if let requestCommentID { body["request_comment_id"] = requestCommentID }
            return body
        }
    }

    /// Reason Symphony records for a pause from the menu; the dashboard and the menu show it.
    public static let pauseReason = "paused from menu bar"


    var path: String {
        switch self {
        case .pause, .pauseWithReason, .pauseForUpdate:
            return "api/v1/control/pause"
        case .resume:
            return "api/v1/control/resume"
        case .force, .stopForcing:
            return "api/v1/control/force"
        case .stop:
            return "api/v1/control/stop"
        case .approvePlan:
            return "api/v1/control/approve_plan"
        case .rework:
            return "api/v1/control/rework"
        case .restart:
            return "api/v1/control/restart"
        case .decisions:
            return "api/v1/control/decisions"
        case .changes:
            return "api/v1/control/changes"
        case .backlog:
            return "api/v1/control/backlog"
        case .move:
            return "api/v1/control/move"
        case .decide:
            return "api/v1/control/decide"
        case .unblock:
            return "api/v1/control/unblock"
        case .undo:
            return "api/v1/control/undo"
        case .note:
            return "api/v1/control/note"
        case let .pauseRepository(key, _):
            return "api/v1/control/repos/\(key)/pause"
        case let .resumeRepository(key):
            return "api/v1/control/repos/\(key)/resume"
        }
    }

    /// The ticket a Director's move names, nil for the other controls.
    public var moveIdentifier: String? {
        switch self {
        case let .approvePlan(identifier), let .rework(identifier, _),
             let .restart(identifier, _),
             let .decisions(identifier, _), let .changes(identifier, _), let .backlog(identifier, _),
             let .move(identifier, _, _),
             let .decide(identifier, _, _, _), let .unblock(identifier), let .undo(identifier):
            return identifier
        case .pause, .pauseWithReason, .pauseForUpdate, .resume, .force, .stopForcing, .stop, .note, .pauseRepository, .resumeRepository:
            return nil
        }
    }

    var body: [String: Any] {
        switch self {
        case .pause:
            return ["reason": Self.pauseReason]
        case let .pauseWithReason(reason):
            return ["reason": reason.isEmpty ? Self.pauseReason : reason]
        case let .pauseForUpdate(version):
            // The reason's kind and its field; `reason` is the line a Symphony that reads no kind makes it from.
            return ["kind": "build", "version": version, "reason": "updating to v\(version)"]
        case .resume, .resumeRepository:
            return [:]
        case let .pauseRepository(_, reason):
            // Without one, Symphony gives the pause its own line.
            let reason = reason.trimmingWhitespace()
            return reason.isEmpty ? [:] : ["reason": reason]
        case let .force(identifier):
            return ["identifier": identifier]
        case let .stopForcing(identifier):
            return ["identifier": identifier, "clear": "true"]
        case let .stop(identifier), let .approvePlan(identifier), let .unblock(identifier), let .undo(identifier):
            return ["issue_identifier": identifier]
        case let .rework(identifier, reason):
            return ["issue_identifier": identifier, "reason": reason]
        case let .restart(identifier, reason), let .changes(identifier, reason):
            return ["issue_identifier": identifier, "reason": reason]
        case let .decisions(identifier, picks):
            return ["issue_identifier": identifier, "picks": picks.map(\.body)]
        case let .backlog(identifier, note):
            return note.map { ["issue_identifier": identifier, "note": $0] } ?? ["issue_identifier": identifier]
        case let .move(identifier, to, note):
            var body = ["issue_identifier": identifier, "to": to]
            if let note { body["note"] = note }
            return body
        case let .decide(identifier, request, picks, move):
            var body: [String: Any] = [
                "issue_identifier": identifier,
                request.body.key: request.body.value,
                "picks": picks.map { ["question": $0.question, "answer": $0.answer] },
            ]
            if let move { body["move"] = move }
            return body
        case let .note(repoKey, identifier, text):
            return ["repo_key": repoKey, "issue_identifier": identifier, "text": text]
        }
    }

    /// Start of error messages, for example "Couldn't pause Symphony" or "Couldn't force TP-123".
    var failurePrefix: String {
        switch self {
        case .pause, .pauseWithReason, .pauseForUpdate:
            return "Couldn't pause Symphony"
        case .resume:
            return "Couldn't resume Symphony"
        case let .force(identifier):
            return "Couldn't force \(identifier)"
        case let .stopForcing(identifier):
            return "Couldn't stop forcing \(identifier)"
        case let .stop(identifier):
            return "Couldn't stop \(identifier)"
        case let .approvePlan(identifier):
            return "Couldn't approve the plan of \(identifier)"
        case let .rework(identifier, _):
            return "Couldn't send \(identifier) to Rework"
        case let .restart(identifier, _):
            return "Couldn't restart \(identifier)"
        case let .decisions(identifier, _):
            return "Couldn't send the decisions on \(identifier)"
        case let .changes(identifier, _):
            return "Couldn't ask for changes to the plan of \(identifier)"
        case let .backlog(identifier, _):
            return "Couldn't move \(identifier) to Backlog"
        case let .move(identifier, to, _):
            return "Couldn't move \(identifier) to \(to)"
        case let .decide(identifier, _, _, _):
            return "Couldn't send the decision on \(identifier)"
        case let .unblock(identifier):
            return "Couldn't unblock \(identifier)"
        case let .undo(identifier):
            return "Couldn't undo the move on \(identifier)"
        case let .note(_, identifier, _):
            return "Couldn't add the note to \(identifier)"
        case let .pauseRepository(key, _):
            return "Couldn't pause \(key)"
        case let .resumeRepository(key):
            return "Couldn't resume \(key)"
        }
    }
}

/// What Symphony answered to a Director's move: whether the ticket moved, and the state it is in now.
public struct MoveOutcome: Equatable {
    public var moved: Bool
    public var toState: String?

    public init(moved: Bool, toState: String?) {
        self.moved = moved
        self.toState = toState
    }
}

/// The outcome of sending a control action.
public enum ControlResult: Equatable {
    case done
    /// A Director's move was made; Symphony's answer says whether the ticket moved, and where.
    case moved(MoveOutcome)
    /// The message says what went wrong, for the menu.
    case failed(String)

    public var moveOutcome: MoveOutcome? {
        if case let .moved(outcome) = self { return outcome }
        return nil
    }
}

/// Sends control actions to Symphony's control plane.
public enum ControlAPI {
    public static let timeout: TimeInterval = 10

    /// Sends a request and returns the response; `URLSession.shared` in the app, a stub in tests.
    public typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    /// Sends `action` to the control URL in `stateRoot`, with the bearer token from the same directory.
    /// `fallback` is the control URL used while Symphony hasn't written one, and `token`, when given, is sent instead
    /// of the state directory's (the live Symphony's or the API fixtures' in QA mode).
    public static func send(
        _ action: ControlAction,
        stateRoot: URL,
        fallback: URL? = SymphonyState.defaultBaseURL,
        token: String? = nil,
        transport: Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> ControlResult {
        guard let base = StateRoot.controlURL(in: stateRoot, fallback: fallback) else {
            return missingControlURL(action, file: stateRoot.appendingPathComponent(StateRoot.controlURLFileName))
        }
        guard let token = token ?? StateRoot.controlToken(in: stateRoot) else {
            return missingToken(action, tokenFile: StateRoot.controlTokenFile(in: stateRoot))
        }
        guard let (data, response) = try? await transport(request(action, base: base, token: token)) else {
            return unreachable(action, base: base)
        }
        return result(action, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    /// The request for `action`, authenticated with the bearer token from the state directory.
    public static func request(_ action: ControlAction, base: URL, token: String) -> URLRequest {
        var request = URLRequest(
            url: base.appendingPathComponent(action.path),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Encoding strings, and arrays of string dictionaries, can't fail.
        request.httpBody = try? JSONSerialization.data(withJSONObject: action.body, options: [.sortedKeys])
        return request
    }

    /// Message for when the state directory holds no control token.
    public static func missingToken(_ action: ControlAction, tokenFile: URL) -> ControlResult {
        let path = (tokenFile.path as NSString).abbreviatingWithTildeInPath
        return .failed("\(action.failurePrefix): no control token in \(path)")
    }

    /// Message for when the state directory holds no control URL and there is no default to try.
    public static func missingControlURL(_ action: ControlAction, file: URL) -> ControlResult {
        let path = (file.path as NSString).abbreviatingWithTildeInPath
        return .failed("\(action.failurePrefix): no control URL in \(path)")
    }

    /// Message for when nothing answered on the control URL.
    public static func unreachable(_ action: ControlAction, base: URL) -> ControlResult {
        .failed("\(action.failurePrefix): nothing answered at \(base.absoluteString)")
    }

    /// Turns a control response into a result.
    public static func result(_ action: ControlAction, statusCode: Int, data: Data) -> ControlResult {
        let prefix = action.failurePrefix
        switch statusCode {
        case 200:
            // Symphony answers 200 with `stopped: false` when no agent runs on the ticket.
            if case let .stop(identifier) = action, !stopped(data) {
                return .failed("\(prefix): no agent runs on \(identifier) anymore")
            }
            return moveOutcome(action, data).map(ControlResult.moved) ?? .done
        case 401:
            return .failed("\(prefix): it rejected the control token (HTTP 401)")
        case 503:
            return .failed("\(prefix): its orchestrator is unavailable (HTTP 503)")
        default:
            if let message = errorMessage(data) { return .failed("\(prefix): \(message) (HTTP \(statusCode))") }
            return .failed("\(prefix): HTTP \(statusCode)")
        }
    }

    /// Symphony's answer to a Director's move (not Undo), nil when it doesn't read.
    private static func moveOutcome(_ action: ControlAction, _ data: Data) -> MoveOutcome? {
        struct Payload: Decodable {
            let moved: Bool?
            let to_state: String?
        }
        if case .undo = action { return nil }
        guard action.moveIdentifier != nil, let payload = try? JSONDecoder().decode(Payload.self, from: data), let moved = payload.moved
        else { return nil }
        return MoveOutcome(moved: moved, toState: payload.to_state)
    }

    private static func stopped(_ data: Data) -> Bool {
        struct Payload: Decodable {
            let stopped: Bool?
        }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.stopped ?? false
    }

    private static func errorMessage(_ data: Data) -> String? {
        struct Payload: Decodable {
            struct Failure: Decodable {
                let message: String?
            }

            let error: Failure?
        }
        guard let message = (try? JSONDecoder().decode(Payload.self, from: data))?.error?.message?.trimmingWhitespace(),
            !message.isEmpty
        else { return nil }
        return message
    }
}

import Foundation

/// An operator control the app sends to Symphony's `POST /api/v1/control/*`.
public enum ControlAction: Equatable {
    case pause
    case resume
    /// Adds the force label to the ticket, so it skips the dispatch limits.
    case force(String)
    /// Removes the force label from the ticket.
    case stopForcing(String)
    /// Stops the agent running on the ticket.
    case stop(String)
    /// The Director's moves from the Inbox (DD4): each names the ticket; Symphony checks its state.
    case approvePlan(String)
    case approvePR(String)
    case rework(String, reason: String)
    case decisions(String, picks: [DecisionPick])
    case signOff(String)
    case backlog(String, note: String?)
    /// Takes back the last move on the ticket, within 10 s of it.
    case undo(String)

    /// A decision's question and the option the Director picked, as `decisions` posts them.
    public struct DecisionPick: Equatable {
        public var question: String
        public var answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    /// Reason Symphony records for a pause from the menu; the dashboard and the menu show it.
    public static let pauseReason = "paused from menu bar"

    var path: String {
        switch self {
        case .pause:
            return "api/v1/control/pause"
        case .resume:
            return "api/v1/control/resume"
        case .force, .stopForcing:
            return "api/v1/control/force"
        case .stop:
            return "api/v1/control/stop"
        case .approvePlan:
            return "api/v1/control/approve_plan"
        case .approvePR:
            return "api/v1/control/approve_pr"
        case .rework:
            return "api/v1/control/rework"
        case .decisions:
            return "api/v1/control/decisions"
        case .signOff:
            return "api/v1/control/sign_off"
        case .backlog:
            return "api/v1/control/backlog"
        case .undo:
            return "api/v1/control/undo"
        }
    }

    /// The ticket a Director's move names, nil for the other controls.
    public var moveIdentifier: String? {
        switch self {
        case let .approvePlan(identifier), let .approvePR(identifier), let .rework(identifier, _),
             let .decisions(identifier, _), let .signOff(identifier), let .backlog(identifier, _), let .undo(identifier):
            return identifier
        case .pause, .resume, .force, .stopForcing, .stop:
            return nil
        }
    }

    var body: [String: Any] {
        switch self {
        case .pause:
            return ["reason": Self.pauseReason]
        case .resume:
            return [:]
        case let .force(identifier):
            return ["identifier": identifier]
        case let .stopForcing(identifier):
            return ["identifier": identifier, "clear": "true"]
        case let .stop(identifier), let .approvePlan(identifier), let .approvePR(identifier), let .signOff(identifier),
             let .undo(identifier):
            return ["issue_identifier": identifier]
        case let .rework(identifier, reason):
            return ["issue_identifier": identifier, "reason": reason]
        case let .decisions(identifier, picks):
            return ["issue_identifier": identifier, "picks": picks.map { ["question": $0.question, "answer": $0.answer] }]
        case let .backlog(identifier, note):
            return note.map { ["issue_identifier": identifier, "note": $0] } ?? ["issue_identifier": identifier]
        }
    }

    /// Start of error messages, for example "Couldn't pause Symphony" or "Couldn't force TP-123".
    var failurePrefix: String {
        switch self {
        case .pause:
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
        case let .approvePR(identifier):
            return "Couldn't move \(identifier) to Merging"
        case let .rework(identifier, _):
            return "Couldn't send \(identifier) to Rework"
        case let .decisions(identifier, _):
            return "Couldn't send the decisions on \(identifier)"
        case let .signOff(identifier):
            return "Couldn't sign off \(identifier)"
        case let .backlog(identifier, _):
            return "Couldn't move \(identifier) to Backlog"
        case let .undo(identifier):
            return "Couldn't undo the move on \(identifier)"
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
    /// of the state directory's (the API fixtures' in QA mode).
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

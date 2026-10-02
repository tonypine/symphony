import Foundation

/// An operator control the menu sends to Symphony's `POST /api/v1/control/*`.
public enum ControlAction: Equatable {
    case pause
    case resume

    /// Reason Symphony records for a pause from the menu; the dashboard and the menu show it.
    public static let pauseReason = "paused from menu bar"

    var path: String {
        switch self {
        case .pause:
            return "api/v1/control/pause"
        case .resume:
            return "api/v1/control/resume"
        }
    }

    var body: [String: String] {
        switch self {
        case .pause:
            return ["reason": Self.pauseReason]
        case .resume:
            return [:]
        }
    }

    /// Verb for error messages, for example "Couldn't pause Symphony".
    var verb: String {
        switch self {
        case .pause:
            return "pause"
        case .resume:
            return "resume"
        }
    }
}

/// The outcome of sending a control action.
public enum ControlResult: Equatable {
    case done
    /// The message says what went wrong, for the menu.
    case failed(String)
}

/// Sends control actions to Symphony's control plane.
public enum ControlAPI {
    public static let timeout: TimeInterval = 10

    /// Sends a request and returns the response; `URLSession.shared` in the app, a stub in tests.
    public typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    /// Sends `action` to the control URL in `stateRoot`, with the bearer token from the same directory.
    public static func send(
        _ action: ControlAction,
        stateRoot: URL,
        transport: Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> ControlResult {
        let base = StateRoot.controlURL(in: stateRoot)
        guard let token = StateRoot.controlToken(in: stateRoot) else {
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
        // Encoding a [String: String] can't fail.
        request.httpBody = try? JSONSerialization.data(withJSONObject: action.body, options: [.sortedKeys])
        return request
    }

    /// Message for when the state directory holds no control token.
    public static func missingToken(_ action: ControlAction, tokenFile: URL) -> ControlResult {
        let path = (tokenFile.path as NSString).abbreviatingWithTildeInPath
        return .failed("Couldn't \(action.verb) Symphony: no control token in \(path)")
    }

    /// Message for when nothing answered on the control URL.
    public static func unreachable(_ action: ControlAction, base: URL) -> ControlResult {
        .failed("Couldn't \(action.verb) Symphony: nothing answered at \(base.absoluteString)")
    }

    /// Turns a control response into a result.
    public static func result(_ action: ControlAction, statusCode: Int, data: Data) -> ControlResult {
        let prefix = "Couldn't \(action.verb) Symphony"
        switch statusCode {
        case 200:
            return .done
        case 401:
            return .failed("\(prefix): it rejected the control token (HTTP 401)")
        case 503:
            return .failed("\(prefix): its orchestrator is unavailable (HTTP 503)")
        default:
            if let message = errorMessage(data) { return .failed("\(prefix): \(message) (HTTP \(statusCode))") }
            return .failed("\(prefix): HTTP \(statusCode)")
        }
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

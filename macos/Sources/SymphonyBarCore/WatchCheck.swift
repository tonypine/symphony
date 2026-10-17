import Foundation

/// Check Now (S15, S17): `POST /api/v1/issues/<identifier>/watch/check` makes the ticket's PR and CI watcher read and
/// decide at once, and answers with its new `watch` block. It needs no control token: Symphony takes it from any
/// client that sends no `Origin` header, as the app doesn't.
public enum WatchCheck {
    public enum Result: Equatable {
        /// Symphony's answer, which carries the ticket's new `watch` block.
        case checked(Data)
        /// The message says what went wrong.
        case failed(String)
    }

    public static func path(_ identifier: String) -> String {
        let escaped = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? identifier
        return "api/v1/issues/\(escaped)/watch/check"
    }

    /// The request for ticket `identifier` against Symphony at `base`.
    public static func request(_ identifier: String, base: URL) -> URLRequest {
        var request = URLRequest(
            url: LiveAPIClient.url(path(identifier), base: base) ?? base,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: ControlAPI.timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Checks ticket `identifier` now through the control URL in `stateRoot` (or `fallback` while Symphony hasn't
    /// written one).
    public static func send(
        _ identifier: String,
        stateRoot: URL,
        fallback: URL? = SymphonyState.defaultBaseURL,
        transport: ControlAPI.Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> Result {
        guard let base = StateRoot.controlURL(in: stateRoot, fallback: fallback) else {
            return .failed("\(prefix(identifier)): Symphony hasn't said where it listens")
        }
        guard let (data, response) = try? await transport(request(identifier, base: base)) else {
            return .failed("\(prefix(identifier)): nothing answered at \(base.absoluteString)")
        }
        return result(identifier, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    /// Turns Symphony's answer into a result.
    public static func result(_ identifier: String, statusCode: Int, data: Data) -> Result {
        switch statusCode {
        case 200:
            return .checked(data)
        case 404:
            return .failed("\(prefix(identifier)): Symphony doesn't watch its pull request")
        default:
            struct Payload: Decodable {
                struct Failure: Decodable {
                    let message: String?
                }

                let error: Failure?
            }
            let message = (try? JSONDecoder().decode(Payload.self, from: data))?.error?.message?.trimmingWhitespace() ?? ""
            return .failed("\(prefix(identifier)): \(message.isEmpty ? "" : "\(message) ")(HTTP \(statusCode))")
        }
    }

    private static func prefix(_ identifier: String) -> String { "Couldn't check \(identifier) now" }
}

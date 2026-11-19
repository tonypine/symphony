import Foundation

/// What a restart or an update drain waits on, from Symphony's `GET /api/v1/drain`: its agent runs and whether
/// dispatch is paused. That request reads only the orchestrator's snapshot, so it answers when `GET /api/v1/state`
/// fails, and a broken state can't keep the app from installing the release that fixes it (TP-1550).
public struct DrainStatus: Equatable {
    public var running: Int
    public var betweenTurns: Int
    public var paused: Bool

    public init(running: Int, betweenTurns: Int = 0, paused: Bool) {
        self.running = running
        self.betweenTurns = betweenTurns
        self.paused = paused
    }

    /// The runs a drain waits for, as `StateSnapshot.activeRuns` counts them.
    public var activeRuns: Int { max(running - betweenTurns, 0) }

    public static func url(base: URL) -> URL {
        base.appendingPathComponent("api/v1/drain")
    }

    /// The drain read in a response, or nil when it isn't one: an error, an older Symphony without the request.
    public static func parse(data: Data, statusCode: Int) -> DrainStatus? {
        guard statusCode == 200, let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        return DrainStatus(running: payload.running, betweenTurns: payload.betweenTurns, paused: payload.paused)
    }

    private struct Payload: Decodable {
        let running: Int
        let betweenTurns: Int
        let paused: Bool
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

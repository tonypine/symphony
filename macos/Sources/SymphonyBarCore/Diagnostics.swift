import Foundation

/// The parts of `GET /api/v1/state` Diagnostics (D11) reads. Every field is optional: an older Symphony leaves some
/// out, and Diagnostics then leaves their rows out rather than calling them unavailable.
public struct DiagnosticsPayload: Decodable, Equatable {
    public struct Build: Decodable, Equatable {
        public var version: String?
        public var sha: String?
    }

    public struct Counts: Decodable, Equatable {
        public var running: Int?
        public var forced: Int?
    }

    public struct Concurrency: Decodable, Equatable {
        public var maxTotal: Int?
        public var finishingMax: Int?
        public var forcedMax: Int?
    }

    public struct Finishing: Decodable, Equatable {
        public var slots: Int?
        public var used: Int?
    }

    public struct EpicLanes: Decodable, Equatable {
        public struct Lane: Decodable, Equatable {
            public var identifier: String?
            public var status: String?
        }

        public struct Shared: Decodable, Equatable {
            public var slots: Int?
            public var used: Int?
        }

        public var lanes: [Lane]?
        public var queuedEpics: [Lane]?
        public var shared: Shared?
    }

    public struct LinearUsage: Decodable, Equatable {
        public struct Caller: Decodable, Equatable {
            public var caller: String
            public var requests: Int
        }

        public var windowMs: Int?
        public var total: Int?
        public var callers: [Caller]?
    }

    public struct Webhooks: Decodable, Equatable {
        public var enabled: Bool?
        public var relay: String?
        public var lastEventAt: String?
        public var eventsReceived: Int?
        public var rejected: Int?
        public var resultsViaWebhook: Int?
        public var resultsViaPoll: Int?
    }

    public struct Poller: Decodable, Equatable {
        public var status: String?
        public var consecutiveFailures: Int?
        public var currentBackoffMs: Int?
        public var pollIntervalMs: Int?
        public var webhooks: Webhooks?

        /// Symphony serves the string `"unavailable"` for a poller it doesn't run; that decodes to nil fields.
        public init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            status = try container.decodeIfPresent(String.self, forKey: .status)
            consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures)
            currentBackoffMs = try container.decodeIfPresent(Int.self, forKey: .currentBackoffMs)
            pollIntervalMs = try container.decodeIfPresent(Int.self, forKey: .pollIntervalMs)
            webhooks = try container.decodeIfPresent(Webhooks.self, forKey: .webhooks)
        }

        public init(
            status: String? = nil,
            consecutiveFailures: Int? = nil,
            currentBackoffMs: Int? = nil,
            pollIntervalMs: Int? = nil,
            webhooks: Webhooks? = nil
        ) {
            self.status = status
            self.consecutiveFailures = consecutiveFailures
            self.currentBackoffMs = currentBackoffMs
            self.pollIntervalMs = pollIntervalMs
            self.webhooks = webhooks
        }

        private enum CodingKeys: String, CodingKey {
            case status, consecutiveFailures, currentBackoffMs, pollIntervalMs, webhooks
        }
    }

    public struct Pollers: Decodable, Equatable {
        public var ci: Poller?
        public var prReview: Poller?
    }

    public struct StrayProcess: Decodable, Equatable {
        public var pid: Int
        public var command: String?
        public var cwd: String?
        public var cpuSeconds: Int?
    }

    /// What Symphony serves in place of a snapshot it couldn't take, such as `snapshot_unavailable`.
    public struct SnapshotError: Decodable, Equatable {
        public var code: String?
        public var message: String?
    }

    public var error: SnapshotError?
    public var build: Build?
    public var uptimeSeconds: Int?
    public var counts: Counts?
    public var concurrency: Concurrency?
    public var finishing: Finishing?
    public var epicLanes: EpicLanes?
    public var linearUsage: LinearUsage?
    public var pollers: Pollers?
    public var strayProcesses: [StrayProcess]?

    /// The payload in a state response, nil when it isn't one.
    public static func decode(_ data: Data) -> DiagnosticsPayload? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(DiagnosticsPayload.self, from: data)
    }
}

/// Diagnostics in plain words (design system §7): connection, capacity, Linear requests, GitHub, stray processes.
public struct DiagnosticsReport: Equatable {
    public struct Row: Equatable {
        public var label: String
        public var value: String
        /// A line under the value, such as a stray process's folder.
        public var detail: String?
        /// The status shown next to the value, when the row is one.
        public var status: DesignTokens.Status?
        /// Paths, URLs, commands and Symphony's own names show in the monospaced style; a detail always does.
        public var monospacedLabel: Bool
        public var monospacedValue: Bool

        public init(
            _ label: String,
            _ value: String,
            detail: String? = nil,
            status: DesignTokens.Status? = nil,
            monospacedLabel: Bool = false,
            monospacedValue: Bool = false
        ) {
            self.label = label
            self.value = value
            self.detail = detail
            self.status = status
            self.monospacedLabel = monospacedLabel
            self.monospacedValue = monospacedValue
        }
    }

    public struct Group: Equatable {
        public var title: String
        public var rows: [Row]
    }

    public var groups: [Group]

    public static let groupTitles = ["Connection", "Capacity", "Linear requests", "GitHub", "Stray processes"]

    /// `apiURL` is where the app reads Symphony from, `lastUpdate` when the payload arrived.
    public init(payload: DiagnosticsPayload, apiURL: URL?, lastUpdate: Date?, now: Date = Date()) {
        groups = [
            Group(title: Self.groupTitles[0], rows: Self.connection(payload, apiURL: apiURL, lastUpdate: lastUpdate)),
            Group(title: Self.groupTitles[1], rows: Self.capacity(payload)),
            Group(title: Self.groupTitles[2], rows: Self.linear(payload.linearUsage)),
            Group(title: Self.groupTitles[3], rows: Self.gitHub(payload.pollers, now: now)),
            Group(title: Self.groupTitles[4], rows: Self.stray(payload.strayProcesses ?? [])),
        ]
    }

    public func group(_ title: String) -> Group? {
        groups.first { $0.title == title }
    }

    // MARK: Groups

    private static func connection(_ payload: DiagnosticsPayload, apiURL: URL?, lastUpdate: Date?) -> [Row] {
        var rows: [Row] = []
        if let version = payload.build?.version {
            let sha = payload.build?.sha.map { " (\($0.prefix(7)))" } ?? ""
            rows.append(Row("Version", "Symphony \(version)\(sha)"))
        }
        if let apiURL { rows.append(Row("API", apiURL.absoluteString, monospacedValue: true)) }
        if let uptime = payload.uptimeSeconds { rows.append(Row("Uptime", duration(seconds: uptime))) }
        if let lastUpdate {
            rows.append(Row("Last update", lastUpdate.formatted(date: .omitted, time: .standard)))
        }
        return rows
    }

    private static func capacity(_ payload: DiagnosticsPayload) -> [Row] {
        var rows: [Row] = []
        let running = payload.counts?.running ?? 0
        rows.append(Row("Agent slots", inUse(running, of: payload.concurrency?.maxTotal, noun: "running")))
        if let finishing = payload.finishing, let slots = finishing.slots ?? payload.concurrency?.finishingMax {
            rows.append(Row("Landing slots", inUse(finishing.used ?? 0, of: slots, noun: "landing")))
        }
        if let forcedMax = payload.concurrency?.forcedMax {
            rows.append(Row("Forced allowance", inUse(payload.counts?.forced ?? 0, of: forcedMax, noun: "forced")))
        }
        if let lanes = payload.epicLanes {
            rows.append(Row("Initiative slots", initiativeSlots(lanes)))
            if let shared = lanes.shared, let slots = shared.slots, !(lanes.lanes ?? []).isEmpty {
                rows.append(Row("Slots for other work", inUse(shared.used ?? 0, of: slots, noun: "running")))
            }
        }
        return rows
    }

    private static func initiativeSlots(_ lanes: DiagnosticsPayload.EpicLanes) -> String {
        let held = lanes.lanes ?? []
        let queued = (lanes.queuedEpics ?? []).count
        let queuedText = queued == 0 ? "" : " · \(count(queued, "initiative", "initiatives")) queued"
        guard !held.isEmpty else { return "No initiative holds a slot" + queuedText }
        let working = held.filter { $0.status == "running" }.count
        let waiting = held.count - working
        return "\(held.count) held: \(working) working, \(waiting) waiting" + queuedText
    }

    private static func linear(_ usage: DiagnosticsPayload.LinearUsage?) -> [Row] {
        let window = usage?.windowMs.map { $0 == 3_600_000 ? "the last hour" : "the last \(duration(seconds: $0 / 1000))" }
            ?? "the last hour"
        let callers = usage?.callers ?? []
        var rows = [Row("In \(window)", count(usage?.total ?? 0, "request", "requests"))]
        rows += callers.map { Row($0.caller, count($0.requests, "request", "requests"), monospacedLabel: true) }
        return rows
    }

    private static func gitHub(_ pollers: DiagnosticsPayload.Pollers?, now: Date) -> [Row] {
        var rows = [
            poller("CI poller", pollers?.ci),
            poller("Review poller", pollers?.prReview),
        ]
        let webhooks = pollers?.ci?.webhooks
        guard let webhooks, webhooks.enabled == true else {
            rows.append(Row("Webhooks", "Off: CI results come from the poller", status: .idle))
            return rows
        }
        var value = "On"
        if let relay = webhooks.relay, !relay.isEmpty { value += " through \(relay)" }
        if let last = webhooks.lastEventAt.flatMap(SymphonyState.parseDate) {
            value += ", last event \(duration(seconds: max(Int(now.timeIntervalSince(last)), 0))) ago"
        } else {
            value += ", no event yet"
        }
        rows.append(Row("Webhooks", value, status: .done))
        let received = webhooks.eventsReceived ?? 0
        let rejected = webhooks.rejected ?? 0
        rows.append(
            Row(
                "Events received",
                count(received, "event", "events") + (rejected > 0 ? " (\(formatted(rejected)) rejected)" : ""),
                status: rejected > 0 ? .problem : nil
            )
        )
        rows.append(
            Row(
                "CI results",
                "\(formatted(webhooks.resultsViaWebhook ?? 0)) by webhook, \(formatted(webhooks.resultsViaPoll ?? 0)) by poll"
            )
        )
        return rows
    }

    private static func poller(_ label: String, _ poller: DiagnosticsPayload.Poller?) -> Row {
        guard let poller, let status = poller.status, status == "running" else {
            return Row(label, "Not running", status: .idle)
        }
        let failures = poller.consecutiveFailures ?? 0
        if failures > 0 {
            let retry = poller.currentBackoffMs.map { ", next try in \(duration(seconds: $0 / 1000))" } ?? ""
            return Row(label, "Failing: \(count(failures, "failure", "failures")) in a row\(retry)", status: .problem)
        }
        let every = poller.pollIntervalMs.map { ", checks every \(duration(seconds: $0 / 1000))" } ?? ""
        return Row(label, "Running\(every)", status: .done)
    }

    private static func stray(_ processes: [DiagnosticsPayload.StrayProcess]) -> [Row] {
        guard !processes.isEmpty else { return [Row("Stray processes", "None", status: .done)] }
        return processes.map { process in
            let cpu = process.cpuSeconds.map { "\(duration(seconds: $0)) of CPU, " } ?? ""
            return Row(
                process.command ?? "pid \(process.pid)",
                "\(cpu)pid \(process.pid)",
                detail: process.cwd,
                status: .problem,
                monospacedLabel: true
            )
        }
    }

    // MARK: Words

    /// "3 of 10 in use", or "3 running" when there's no limit.
    static func inUse(_ used: Int, of slots: Int?, noun: String) -> String {
        guard let slots else { return "\(formatted(used)) \(noun)" }
        return "\(formatted(used)) of \(formatted(slots)) in use"
    }

    /// Short, exact durations: "45 s", "14 min", "3 h 12 min", "2 days".
    public static func duration(seconds: Int) -> String {
        let seconds = max(seconds, 0)
        switch seconds {
        case ..<60:
            return "\(seconds) s"
        case ..<3600:
            return "\(seconds / 60) min"
        case ..<86400:
            let minutes = (seconds % 3600) / 60
            return "\(seconds / 3600) h" + (minutes == 0 ? "" : " \(minutes) min")
        default:
            let days = seconds / 86400
            return days == 1 ? "1 day" : "\(days) days"
        }
    }

    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(formatted(value)) \(value == 1 ? singular : plural)"
    }

    /// "1,284": numbers as the design system writes them.
    static func formatted(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

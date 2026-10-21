import Foundation

/// S13, the Add Repo sheet's last step while instant updates are on: "Instant updates for <repo>". Once Symphony has
/// read the repo saved, it connects it (`repo:<key>`) and sends it a test update (`test:<key>`), each row done, working
/// or failed with Retry. Done closes the sheet; Skip leaves the repo on polling. Kept free of SwiftUI, so every state
/// is unit tested.
public struct AddRepoInstantUpdates: Equatable {
    public static let skipTitle = "Skip"
    public static let doneTitle = "Done"
    public static let retryTitle = "Retry"
    /// The Check setup step's Done while this step follows it.
    public static let continueTitle = "Continue"

    public let key: String
    /// The section as Symphony's last answer left it, nil before the first.
    public private(set) var section: GitHubUpdatesSection?
    /// True while Symphony hasn't read the repo yet (a reload or restart after Add Repo's save).
    public var waitingForRepo = true
    /// The steps whose request is out.
    public var running: Set<String> = []
    /// Why the last request for a step failed, by step id.
    public var failures: [String: String] = [:]

    public init(key: String) {
        self.key = key
    }

    public mutating func accept(_ section: GitHubUpdatesSection) {
        self.section = section
        if section.step(connectStep) != nil { waitingForRepo = false }
    }

    public var connectStep: String { "repo:\(key)" }
    public var testStep: String { "test:\(key)" }

    /// The repo's GitHub name once Symphony lists it, else its key.
    public var repoName: String { section?.repo(key)?.name ?? key }

    public var title: String { "Instant updates for \(repoName)" }

    /// What the step does and why.
    public var explanation: String {
        let polling = section.map { GitHubUpdatesCard.interval($0.poll.intervalMs) } ?? "30 s"
        return "Instant updates are on, so Symphony connects \(repoName) the same way as your other repos and asks GitHub "
            + "for a test update. Skip leaves it on polling: Symphony checks it every \(polling)."
    }

    /// The two rows: the webhook, then the test update.
    public var rows: [GitHubUpdatesSetup.Row] {
        let forwards = section?.relay.runsInSymphony == true
        return [
            row(connectStep, title: "Webhook added", done: forwards ? "Forwarding through the GitHub CLI" : "On \(repoName)"),
            row(testStep, title: "Test update", done: "Received and verified"),
        ]
    }

    /// Done once both rows are.
    public var canFinish: Bool { rows.allSatisfy(\.isDone) }

    /// Why Done is off, beside it and as its help; nil while it is on.
    public var doneProblem: String? {
        canFinish ? nil : "Done is available once the test update arrived. Skip leaves \(key) on polling."
    }

    /// True once the repo connected, so Skip has something to take back to polling.
    public var isConnected: Bool { section?.step(connectStep)?.status == .done }

    private func row(_ id: String, title: String, done: String) -> GitHubUpdatesSetup.Row {
        typealias Row = GitHubUpdatesSetup.Row
        if running.contains(id) { return Row(id: id, title: title, tone: .working, word: "Checking…", buttons: []) }
        if let failure = failures[id] { return Row(id: id, title: title, tone: .problem, word: "Failed", detail: failure, buttons: [.retry]) }
        if id == connectStep, waitingForRepo {
            return Row(id: id, title: title, tone: .working, word: "Waiting", detail: "Waiting for Symphony to read \(key)…", buttons: [])
        }
        guard let step = section?.step(id) else { return Row(id: id, title: title, tone: .idle, word: "To do", buttons: []) }
        switch step.status {
        case .done: return Row(id: id, title: title, tone: .done, word: "Done", detail: done, buttons: [])
        case .waiting: return Row(id: id, title: title, tone: .working, word: "Waiting", detail: step.detail, buttons: [])
        case .pending: return Row(id: id, title: title, tone: .idle, word: "To do", buttons: [])
        case .failed: return Row(id: id, title: title, tone: .problem, word: "Failed", detail: step.detail, fix: step.fix, buttons: [.retry])
        }
    }
}

/// Runs S13 against Symphony: waits for it to read the repo, connects it, tests it and reads the setup until the test
/// update arrived. Every outside call goes through `services`, so the tests drive it against a fake Symphony.
@MainActor
public final class AddRepoInstantUpdatesController {
    public struct Services {
        public var send: (GitHubUpdatesAPI.Action, [String: String]) async -> GitHubUpdatesAPI.Result
        public var read: () async -> GitHubUpdatesAPI.Result
        public var sleep: (TimeInterval) async -> Void

        public init(
            send: @escaping (GitHubUpdatesAPI.Action, [String: String]) async -> GitHubUpdatesAPI.Result,
            read: @escaping () async -> GitHubUpdatesAPI.Result,
            sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        ) {
            self.send = send
            self.read = read
            self.sleep = sleep
        }
    }

    /// How many times it reads the setup, two seconds apart, while Symphony hasn't read the repo: as long as Check
    /// setup waits (`SetupAPI.repoCheckWait`).
    public static let repoWaitLimit = Int(SetupAPI.repoCheckWait / SetupAPI.repoCheckInterval)

    public private(set) var step: AddRepoInstantUpdates {
        didSet { if step != oldValue { onChange(step) } }
    }

    public var onChange: (AddRepoInstantUpdates) -> Void = { _ in }

    private let services: Services
    private var closed = false

    public init(key: String, services: Services) {
        step = AddRepoInstantUpdates(key: key)
        self.services = services
    }

    /// Connects the repo and tests it, once Symphony has read it.
    public func start() async {
        guard await waitForRepo() else { return }
        await connectAndTest()
    }

    /// A row's Retry.
    public func retry(_ rowID: String) async {
        guard !closed, step.running.isEmpty else { return }
        if step.section?.step(step.connectStep) == nil {
            // Symphony hadn't read the repo: wait for it again.
            step.failures[step.connectStep] = nil
            await start()
        } else if rowID == step.testStep {
            await test()
        } else {
            await connectAndTest()
        }
    }

    /// Skip: a repo already connected goes back to polling; the sheet closes either way. Answers the reason when
    /// Symphony couldn't take it back, so the sheet can stay open with it.
    public func skip() async -> String? {
        closed = true
        guard step.isConnected else { return nil }
        if case let .failed(message) = await services.send(.leaveOnPolling, ["repo": step.key]) {
            step.failures[step.connectStep] = message
            closed = false
            return message
        }
        return nil
    }

    /// Done, or the sheet going away: nothing more is sent.
    public func close() {
        closed = true
    }

    private func waitForRepo() async -> Bool {
        step.waitingForRepo = true
        var lastFailure: String?
        for attempt in 0..<Self.repoWaitLimit {
            if attempt > 0 { await services.sleep(SetupAPI.repoCheckInterval) }
            guard !closed else { return false }
            switch await services.read() {
            case let .updated(section):
                step.accept(section)
                if !step.waitingForRepo { return true }
            case let .failed(message):
                lastFailure = message
            }
        }
        step.waitingForRepo = false
        step.failures[step.connectStep] = lastFailure ?? "Symphony hasn't read \(step.key) from symphony.yml yet."
        return false
    }

    private func connectAndTest() async {
        if step.section?.step(step.connectStep)?.status != .done {
            await send(.runStep, ["step": step.connectStep], rows: [step.connectStep])
        }
        guard step.isConnected else { return }
        await test()
    }

    private func test() async {
        await send(.test, ["repo": step.key], rows: [step.testStep])
        for _ in 0..<GitHubUpdatesSetupController.testPollLimit {
            guard !closed, step.section?.step(step.testStep)?.status == .waiting else { return }
            await services.sleep(GitHubUpdatesSetup.testPollInterval)
            guard !closed else { return }
            if case let .updated(section) = await services.read() { step.accept(section) }
        }
        if step.section?.step(step.testStep)?.status == .waiting {
            step.failures[step.testStep] = "Symphony didn't say whether the test update arrived."
        }
    }

    private func send(_ action: GitHubUpdatesAPI.Action, _ params: [String: String], rows: [String]) async {
        guard !closed else { return }
        rows.forEach { step.running.insert($0); step.failures[$0] = nil }
        let result = await services.send(action, params)
        rows.forEach { step.running.remove($0) }
        guard !closed else { return }
        switch result {
        case let .updated(section): step.accept(section)
        case let .failed(message): rows.forEach { step.failures[$0] = message }
        }
    }
}

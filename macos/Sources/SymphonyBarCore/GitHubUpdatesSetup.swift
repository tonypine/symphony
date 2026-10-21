import Foundation

/// S2–S6: the guided sheet behind Turn On Instant Updates… and Finish Setup… (J1, J6). Five pages, each saying what it
/// does and why: the relay, the GitHub CLI, the secret and the port, the repos, a test update. Each page runs its steps
/// as it opens (`GitHubUpdatesSetupController`) and shows each one done, working or failed with what fixes it; Continue
/// is on once the page's steps are done. A repo can be left on polling, and Done works with some repos left so.
/// Kept free of SwiftUI, so every state is unit tested.
public struct GitHubUpdatesSetup: Equatable, Identifiable {
    public enum Purpose: Equatable {
        /// J1: from the card's Turn On Instant Updates….
        case turnOn
        /// J6: from Finish Setup…, with the steps already done shown done.
        case finishSetup
    }

    public enum Page: Int, CaseIterable, Equatable, Comparable {
        case relay = 1
        case gitHubCLI
        case secretAndPort
        case repos
        case test

        /// The page's question or task, at the top of the sheet.
        public var title: String {
            switch self {
            case .relay: "Choose how GitHub reaches this Mac"
            case .gitHubCLI: "Check the GitHub CLI"
            case .secretAndPort: "Secret and port"
            case .repos: "Connect your repos"
            case .test: "Send a test update"
            }
        }

        /// Its name in the step indicator.
        public var shortName: String {
            switch self {
            case .relay: "Relay"
            case .gitHubCLI: "GitHub CLI"
            case .secretAndPort: "Secret and port"
            case .repos: "Repos"
            case .test: "Test"
            }
        }

        public static func < (lhs: Page, rhs: Page) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A row's button.
    public enum Button: Equatable, Hashable {
        /// Opens Terminal on `gh auth refresh` with the webhook scope; the row checks again by itself.
        case grantPermission
        /// Opens Terminal on `gh auth login`; the row checks again by itself.
        case signIn
        /// Restarts Symphony through the app's restart, so it listens on the port symphony.yml pins.
        case restartSymphony
        case retry
        case leaveOnPolling

        public var title: String {
            switch self {
            case .grantPermission: "Grant Permission…"
            case .signIn: "Sign In…"
            case .restartSymphony: "Restart Symphony"
            case .retry: "Retry"
            case .leaveOnPolling: "Leave on Polling"
            }
        }
    }

    /// One step on a page: a symbol and a word for its state, never the color alone, then what it went through or
    /// what is wrong and what fixes it, and its buttons.
    public struct Row: Equatable, Identifiable {
        /// The step's id: `relay`, `gh_ready`, `secret`, `port`, `repo:<key>`, `test:<key>`.
        public var id: String
        public var title: String
        public var tone: GitHubUpdatesCard.Tone
        /// "Done", "Checking…", "Failed", "To do", "Waiting", "Polling".
        public var word: String
        /// What it went through, or what is wrong.
        public var detail: String?
        /// What fixes it.
        public var fix: String?
        public var buttons: [Button]

        public var isDone: Bool { tone == .done }
        public var isWorking: Bool { tone == .working }

        /// One element for VoiceOver: "acme/docs, Failed, You need admin access to acme/docs to add a webhook. …".
        public var accessibilityLabel: String { [title, word, detail, fix].compactMap { $0 }.joined(separator: ", ") }
    }

    /// Where the secret Symphony made went.
    public enum SecretSave: Equatable {
        /// The app moved it into its secret item.
        case saved
        /// The app's secret item couldn't be written, in plain words.
        case failed(String)
    }

    public static let continueTitle = "Continue"
    public static let doneTitle = "Done"
    public static let backTitle = "Back"
    public static let cancelTitle = "Cancel"
    public static let recommended = "Recommended"
    /// How often a row that waits on the person in Terminal checks again.
    public static let recheckInterval: TimeInterval = 3
    /// How often the test page reads the setup while a test update is on its way.
    public static let testPollInterval: TimeInterval = 2

    public let purpose: Purpose
    public private(set) var page: Page
    /// The section as Symphony's last answer left it.
    public private(set) var section: GitHubUpdatesSection
    /// The relay picked on the first page, and a URL relay's public URL.
    public var relay: String
    public var url: String
    /// The steps whose request is out (`turn_on` while turning on).
    public var running: Set<String> = []
    /// Why the last request for a step failed, by step id (`turn_on` for the first page).
    public var failures: [String: String] = [:]
    /// The repos the person left on polling.
    public var leftOnPolling: Set<String> = []
    /// What became of the secret Symphony made, nil until the app tried to move it.
    public var secretSave: SecretSave?
    /// True when the app's secret item already held the secret before this setup moved one.
    public var secretStored = false
    /// The steps that wait on the person in Terminal (Grant Permission…, Sign In…) or on a restart: they check again
    /// every `recheckInterval` seconds and when the app comes back to the front.
    public var awaiting: Set<String> = []

    public var id: String { "github_updates_setup" }

    public init(purpose: Purpose, section: GitHubUpdatesSection) {
        self.purpose = purpose
        self.section = section
        page = .relay
        // Turning on picks the recommended relay (D1); finishing keeps the one symphony.yml names.
        relay = purpose == .turnOn ? GitHubUpdatesSheet.relays[0].id : section.relay.kind
        url = section.relay.url ?? ""
    }

    // MARK: Changes

    /// Symphony's answer: the section as an action left it.
    public mutating func accept(_ section: GitHubUpdatesSection) {
        self.section = section
    }

    public mutating func show(_ page: Page) {
        self.page = page
    }

    // MARK: The pages

    /// "Step 2 of 5".
    public var stepLabel: String { "Step \(page.rawValue) of \(Page.allCases.count)" }

    /// True for a URL relay, which Symphony doesn't run: it adds a hook to each repo instead.
    public var forwards: Bool { section.relay.kind == "gh_webhook_forward" }

    /// What the page does and why, in plain words: the person never reads a doc to get here.
    public var explanation: String {
        let polling = GitHubUpdatesCard.interval(section.poll.intervalMs)
        switch page {
        case .relay:
            return "Today Symphony asks GitHub every \(polling) whether CI or a pull request changed. With instant updates, "
                + "GitHub tells Symphony the moment it happens. A relay carries those updates from GitHub to this Mac."
        case .gitHubCLI:
            return forwards
                ? "Symphony forwards GitHub's updates with the GitHub CLI (gh) and its forwarding extension, which it installs "
                + "if needed. gh also needs permission to manage your repos' webhooks."
                : "Symphony adds a webhook to each repo with the GitHub CLI (gh), pointing at your relay's address. "
                + "gh needs permission to manage your repos' webhooks."
        case .secretAndPort:
            return "GitHub signs every update with a secret only GitHub and this Mac know, so Symphony refuses anything else. "
                + "Symphony makes the secret and the app keeps it in your Keychain. The relay also needs Symphony at the "
                + "same address each time, so Symphony fixes its port in symphony.yml."
        case .repos:
            return forwards
                ? "Symphony starts forwarding each repo's updates. That needs admin access to the repo. A repo you leave on "
                + "polling works as it does now: Symphony checks it every \(polling)."
                : "Symphony adds a webhook to each repo that sends its updates to your relay. That needs admin access to the "
                + "repo. A repo you leave on polling works as it does now: Symphony checks it every \(polling)."
        case .test:
            return "Symphony asks GitHub for one update from each connected repo and checks that it arrives and its "
                + "signature verifies."
        }
    }

    /// The relays the first page offers, the recommended one first and picked.
    public var relayOptions: [GitHubUpdatesSheet.RelayOption] { GitHubUpdatesSheet.relays }

    public var option: GitHubUpdatesSheet.RelayOption? { relayOptions.first { $0.id == relay } }

    /// A URL relay needs its public URL before it can turn on.
    public var needsURL: Bool { option?.needsURL == true }

    /// What Continue on the first page sends.
    public var turnOnParams: [String: String] {
        var params = ["relay": relay]
        let url = url.trimmingWhitespace()
        if needsURL, !url.isEmpty { params["url"] = url }
        return params
    }

    /// The rows of the page shown; none on the first page.
    public var rows: [Row] { rows(on: page) }

    public func rows(on page: Page) -> [Row] {
        switch page {
        case .relay:
            return []
        case .gitHubCLI:
            return [
                stepRow("relay", title: forwards ? "GitHub CLI and its forwarding extension" : "Relay address",
                        done: forwards ? "Installed." : section.relay.url.map { "Updates reach this Mac through \($0)." }),
                permissionRow,
            ]
        case .secretAndPort:
            return [secretRow, portRow]
        case .repos:
            return section.repos.map(repoRow)
        case .test:
            return section.repos.compactMap(testRow)
        }
    }

    /// Continue's title: Done on the last page.
    public var continueTitle: String { page == .test ? Self.doneTitle : Self.continueTitle }

    /// Why Continue (or Done) is off, shown beside it and as its help; nil while it is on.
    public var continueProblem: String? {
        if page == .relay {
            if running.contains("turn_on") { return "Turning on instant updates…" }
            if needsURL, url.trimmingWhitespace().isEmpty { return "Paste the relay's public URL." }
            return nil
        }
        let rows = rows
        if rows.contains(where: \.isWorking) || !running.isEmpty { return "Symphony is working on this step…" }
        switch page {
        case .relay:
            return nil
        case .gitHubCLI, .secretAndPort:
            return rows.allSatisfy(\.isDone) ? nil : "Continue is available once every row is done."
        case .repos, .test:
            let active = rows.filter { !isLeft($0) }
            if active.isEmpty { return "Connect at least one repo, or close and stay on polling." }
            return active.allSatisfy(\.isDone) ? nil : "Retry each failed repo, or leave it on polling."
        }
    }

    public var canContinue: Bool { continueProblem == nil }

    public var canGoBack: Bool { page != .relay && running.isEmpty }

    /// The first page's failure, shown under the relays.
    public var turnOnError: String? { failures["turn_on"] }

    /// The pages whose steps are all done, ticked in the step indicator (J6).
    public var donePages: Set<Page> {
        var done: Set<Page> = []
        if section.mode != .off, section.mode != .needsSetup, section.step("relay")?.status == .done { done.insert(.relay) }
        for page in [Page.gitHubCLI, .secretAndPort] where rows(on: page).allSatisfy(\.isDone) {
            done.insert(page)
        }
        if section.repos.contains(where: \.connected) { done.insert(.repos) }
        if section.isInstant { done.insert(.test) }
        return done
    }

    // MARK: Rows

    private var permissionRow: Row {
        var row = stepRow("gh_ready", title: "Permission to manage webhooks", done: "The GitHub CLI can add webhooks to your repos.")
        if awaiting.contains("gh_ready"), row.tone == .problem, section.step("gh_ready")?.action != nil {
            row.fix = "Finish in Terminal. This row checks again every \(Int(Self.recheckInterval)) seconds."
        }
        return row
    }

    private var secretRow: Row {
        var row = stepRow("secret", title: "Webhook secret", done: nil)
        guard row.isDone else { return row }
        switch secretSave {
        case .saved:
            row.detail = "Secret created and saved in your Keychain"
        case let .failed(message):
            return Row(id: "secret", title: row.title, tone: .problem, word: "Failed", detail: message, fix: "Retry to save it again.", buttons: [.retry])
        case nil:
            row.detail = secretStored ? "Secret saved in your Keychain" : "Symphony has a webhook secret."
        }
        return row
    }

    private var portRow: Row {
        var row = stepRow("port", title: "Symphony's port", done: section.listeningPort.map { "Fixing Symphony's port at \($0)" } ?? "Symphony's port is fixed.")
        if awaiting.contains("port"), row.tone == .problem, section.step("port")?.action == .restartSymphony {
            row.fix = "Symphony is restarting. This row checks again every \(Int(Self.recheckInterval)) seconds."
        }
        return row
    }

    private func repoRow(_ repo: GitHubUpdatesSection.Repo) -> Row {
        let id = "repo:\(repo.key)"
        if leftOnPolling.contains(repo.key), !running.contains(id) {
            return leftRow(id: id, repo: repo, buttons: [.retry])
        }
        var row = stepRow(id, title: repo.name, done: forwards ? "Forwarding through the GitHub CLI" : "Webhook added")
        if row.tone == .problem { row.buttons = [.retry, .leaveOnPolling] }
        return row
    }

    /// A connected repo's test, or the line of a repo left on polling; nil for a repo that never connected.
    private func testRow(_ repo: GitHubUpdatesSection.Repo) -> Row? {
        let id = "test:\(repo.key)"
        if leftOnPolling.contains(repo.key), !running.contains(id) { return leftRow(id: id, repo: repo, buttons: []) }
        guard repo.connected || running.contains(id) || failures[id] != nil else { return nil }
        var row = stepRow(id, title: repo.name, done: "Received and verified")
        if row.tone == .problem { row.buttons = [.retry, .leaveOnPolling] }
        return row
    }

    private func leftRow(id: String, repo: GitHubUpdatesSection.Repo, buttons: [Button]) -> Row {
        let polling = GitHubUpdatesCard.interval(section.poll.intervalMs)
        return Row(id: id, title: repo.name, tone: .idle, word: "Polling", detail: "Left on polling: Symphony checks it every \(polling).", buttons: buttons)
    }

    private func isLeft(_ row: Row) -> Bool {
        guard let key = row.id.split(separator: ":", maxSplits: 1).last.map(String.init), row.id.contains(":") else { return false }
        return leftOnPolling.contains(key) && !running.contains(row.id)
    }

    /// A step as its row shows it: working while its request is out, failed with the reason when the request failed,
    /// else as Symphony reports it.
    private func stepRow(_ id: String, title: String, done: String?) -> Row {
        if running.contains(id) {
            return Row(id: id, title: title, tone: .working, word: "Checking…", buttons: [])
        }
        if let failure = failures[id] {
            return Row(id: id, title: title, tone: .problem, word: "Failed", detail: failure, buttons: [.retry])
        }
        guard let step = section.step(id) else {
            return Row(id: id, title: title, tone: .idle, word: "To do", buttons: [])
        }
        switch step.status {
        case .done:
            return Row(id: id, title: title, tone: .done, word: "Done", detail: done ?? step.detail, buttons: [])
        case .waiting:
            return Row(id: id, title: title, tone: .working, word: "Waiting", detail: step.detail, buttons: [])
        case .pending:
            return Row(id: id, title: title, tone: .idle, word: "To do", buttons: [])
        case .failed:
            let button: Button =
                switch step.action {
                case .grantPermission: .grantPermission
                case .signIn: .signIn
                case .restartSymphony: .restartSymphony
                case nil: .retry
                }
            return Row(id: id, title: title, tone: .problem, word: "Failed", detail: step.detail, fix: step.fix, buttons: [button])
        }
    }
}

/// Runs the guided setup against Symphony: the first page's Continue turns updates on, each page runs its steps as it
/// opens, Grant Permission… and Sign In… open Terminal and check again by themselves, the test page reads the setup
/// until each test update arrived, and Done hands the section back. Every outside call goes through `Services`, so the
/// tests drive it against a fake Symphony.
@MainActor
public final class GitHubUpdatesSetupController {
    public struct Services {
        /// `POST /api/v1/setup/github_updates/<action>`.
        public var send: (GitHubUpdatesAPI.Action, [String: String]) async -> GitHubUpdatesAPI.Result
        /// `GET /api/v1/setup`'s section.
        public var read: () async -> GitHubUpdatesAPI.Result
        /// Moves the secret Symphony handed off into the app's secret item (`WebhookSecret.moveHandOff`).
        public var moveSecret: () -> WebhookSecret.Move
        /// Whether the app's secret item holds a secret.
        public var secretStored: () -> Bool
        /// Opens Terminal on `gh` with these arguments; the reason when it couldn't.
        public var openTerminal: (_ ghArguments: [String]) -> String?
        /// The app's graceful restart of Symphony.
        public var restartSymphony: () -> Void
        public var sleep: (TimeInterval) async -> Void

        public init(
            send: @escaping (GitHubUpdatesAPI.Action, [String: String]) async -> GitHubUpdatesAPI.Result,
            read: @escaping () async -> GitHubUpdatesAPI.Result,
            moveSecret: @escaping () -> WebhookSecret.Move,
            secretStored: @escaping () -> Bool,
            openTerminal: @escaping (_ ghArguments: [String]) -> String?,
            restartSymphony: @escaping () -> Void,
            sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        ) {
            self.send = send
            self.read = read
            self.moveSecret = moveSecret
            self.secretStored = secretStored
            self.openTerminal = openTerminal
            self.restartSymphony = restartSymphony
            self.sleep = sleep
        }
    }

    /// `gh auth refresh` with the scope that lets gh manage webhooks.
    public static let grantArguments = ["auth", "refresh", "-h", "github.com", "-s", "admin:repo_hook"]
    public static let signInArguments = ["auth", "login", "-h", "github.com"]
    /// How many times a row waiting on Terminal or a restart checks again before it stops: ten minutes.
    public static let recheckLimit = 200
    /// How many times the test page reads the setup: past Symphony's 30 s wait for a test update.
    public static let testPollLimit = 25

    public private(set) var setup: GitHubUpdatesSetup {
        didSet { if setup != oldValue { onChange(setup) } }
    }

    /// Called after every change.
    public var onChange: (GitHubUpdatesSetup) -> Void = { _ in }
    /// Done: the sheet closes on the section as the setup left it.
    public var onFinish: (GitHubUpdatesSection) -> Void = { _ in }

    private let services: Services
    private var closed = false

    public init(purpose: GitHubUpdatesSetup.Purpose, section: GitHubUpdatesSection, services: Services) {
        setup = GitHubUpdatesSetup(purpose: purpose, section: section)
        self.services = services
        setup.secretStored = services.secretStored()
    }

    // MARK: The person

    /// A relay picked on the first page.
    public func pick(relay: String) {
        guard setup.page == .relay, !setup.running.contains("turn_on") else { return }
        setup.relay = relay
        setup.failures["turn_on"] = nil
    }

    public func setURL(_ url: String) {
        guard setup.page == .relay else { return }
        setup.url = url
    }

    /// Continue, or Done on the last page.
    public func goForward() async {
        guard !closed, setup.canContinue else { return }
        switch setup.page {
        case .relay:
            setup.running.insert("turn_on")
            setup.failures["turn_on"] = nil
            let result = await services.send(.turnOn, setup.turnOnParams)
            setup.running.remove("turn_on")
            guard case let .updated(section) = result else {
                if case let .failed(message) = result { setup.failures["turn_on"] = message }
                return
            }
            setup.accept(section)
            await enter(.gitHubCLI)
        case .test:
            close()
            onFinish(setup.section)
        case .gitHubCLI, .secretAndPort, .repos:
            if let next = GitHubUpdatesSetup.Page(rawValue: setup.page.rawValue + 1) { await enter(next) }
        }
    }

    public func goBack() {
        guard setup.canGoBack, let previous = GitHubUpdatesSetup.Page(rawValue: setup.page.rawValue - 1) else { return }
        setup.show(previous)
    }

    /// A row's button.
    public func perform(_ button: GitHubUpdatesSetup.Button, on rowID: String) async {
        guard !closed, !setup.running.contains(rowID) else { return }
        switch button {
        case .grantPermission:
            await waitOnTerminal(rowID, arguments: Self.grantArguments)
        case .signIn:
            await waitOnTerminal(rowID, arguments: Self.signInArguments)
        case .restartSymphony:
            services.restartSymphony()
            await recheck(rowID)
        case .retry:
            await retry(rowID)
        case .leaveOnPolling:
            await leaveOnPolling(rowID)
        }
    }

    /// The app came back to the front: a row waiting on Terminal checks at once.
    public func appActivated() async {
        for step in setup.awaiting.sorted() where !closed && setup.section.step(step)?.status != .done {
            await run(step)
        }
    }

    /// Cancel, Done or the sheet going away: nothing more is sent.
    public func close() {
        closed = true
        setup.awaiting = []
    }

    // MARK: Pages

    private func enter(_ page: GitHubUpdatesSetup.Page) async {
        setup.show(page)
        switch page {
        case .relay:
            break
        case .gitHubCLI:
            await runUnlessDone("relay")
            await runUnlessDone("gh_ready")
        case .secretAndPort:
            await runUnlessDone("secret")
            saveSecret()
            await runUnlessDone("port")
        case .repos:
            for repo in setup.section.repos where !setup.leftOnPolling.contains(repo.key) {
                await runUnlessDone("repo:\(repo.key)")
            }
        case .test:
            let untested = setup.section.repos.filter { $0.connected && setup.section.step("test:\($0.key)")?.status != .done }
            guard !untested.isEmpty else { return }
            await test(untested.map { "test:\($0.key)" }, params: [:])
        }
    }

    private func runUnlessDone(_ step: String) async {
        guard setup.section.step(step)?.status != .done else { return }
        await run(step)
    }

    /// Runs one step: the row works while it is out, then shows Symphony's answer, or why the request failed.
    private func run(_ step: String) async {
        guard !closed, !setup.running.contains(step) else { return }
        setup.running.insert(step)
        setup.failures[step] = nil
        let result = await services.send(.runStep, ["step": step])
        setup.running.remove(step)
        apply(result, to: [step])
        if setup.section.step(step)?.status == .done { setup.awaiting.remove(step) }
    }

    private func apply(_ result: GitHubUpdatesAPI.Result, to steps: [String]) {
        guard !closed else { return }
        switch result {
        case let .updated(section):
            setup.accept(section)
        case let .failed(message):
            for step in steps { setup.failures[step] = message }
        }
    }

    /// Moves the secret Symphony made into the app's secret item, once its step is done.
    private func saveSecret() {
        guard setup.section.step("secret")?.status == .done else { return }
        switch services.moveSecret() {
        case .saved:
            setup.secretSave = .saved
        case .nothingHandedOff:
            if setup.secretSave != .saved { setup.secretSave = nil }
            setup.secretStored = services.secretStored()
        case let .failed(message):
            setup.secretSave = .failed(message)
        }
    }

    private func retry(_ rowID: String) async {
        if rowID.hasPrefix("test:") {
            let key = String(rowID.dropFirst("test:".count))
            await test([rowID], params: ["repo": key])
            return
        }
        if rowID.hasPrefix("repo:") { setup.leftOnPolling.remove(String(rowID.dropFirst("repo:".count))) }
        if rowID == "secret", setup.section.step("secret")?.status == .done {
            saveSecret()
            return
        }
        await run(rowID)
        if rowID == "secret" { saveSecret() }
    }

    private func leaveOnPolling(_ rowID: String) async {
        guard let key = rowID.split(separator: ":", maxSplits: 1).last.map(String.init), rowID.contains(":") else { return }
        setup.running.insert(rowID)
        setup.failures[rowID] = nil
        let result = await services.send(.leaveOnPolling, ["repo": key])
        setup.running.remove(rowID)
        apply(result, to: [rowID])
        if case .updated = result { setup.leftOnPolling.insert(key) }
    }

    /// Sends a test update, then reads the setup until each test row is done or failed.
    private func test(_ rows: [String], params: [String: String]) async {
        guard !closed else { return }
        rows.forEach { setup.running.insert($0); setup.failures[$0] = nil }
        let result = await services.send(.test, params)
        rows.forEach { setup.running.remove($0) }
        apply(result, to: rows)
        guard case .updated = result else { return }
        for _ in 0..<Self.testPollLimit {
            guard !closed, rows.contains(where: { setup.section.step($0)?.status == .waiting }) else { return }
            await services.sleep(GitHubUpdatesSetup.testPollInterval)
            guard !closed else { return }
            if case let .updated(section) = await services.read() { setup.accept(section) }
        }
        for row in rows where setup.section.step(row)?.status == .waiting {
            setup.failures[row] = "Symphony didn't say whether the test update arrived."
        }
    }

    private func waitOnTerminal(_ step: String, arguments: [String]) async {
        if let problem = services.openTerminal(arguments) {
            setup.failures[step] = problem
            return
        }
        await recheck(step)
    }

    /// Checks `step` again every `recheckInterval` seconds until it is done, the page changes or the sheet closes.
    private func recheck(_ step: String) async {
        guard !setup.awaiting.contains(step) else { return }
        setup.awaiting.insert(step)
        let page = setup.page
        for _ in 0..<Self.recheckLimit {
            await services.sleep(GitHubUpdatesSetup.recheckInterval)
            guard !closed, setup.page == page, setup.awaiting.contains(step) else { return }
            await run(step)
            if setup.section.step(step)?.status == .done { return }
        }
        setup.awaiting.remove(step)
    }
}

extension GitHubUpdatesSetup {
    /// The `.command` script Terminal runs for Grant Permission… and Sign In…: the app's `gh` with `arguments`, and the
    /// QA stand-in's address when the app has one, since Terminal doesn't inherit the app's environment.
    public static func terminalScript(gh: String, arguments: [String], environment: [String: String]) -> String {
        var lines = ["#!/bin/zsh -l"]
        if let stub = environment[qaGitHubURLKey], !stub.isEmpty {
            lines.append("export \(qaGitHubURLKey)=" + ShellWords.quote(stub))
        }
        lines.append(([gh] + arguments).map(ShellWords.quote).joined(separator: " "))
        lines.append("echo")
        lines.append("echo 'You can close this window: Symphony checks again by itself.'")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Where QA's fake `gh` sends its calls.
    public static let qaGitHubURLKey = "SYMPHONY_QA_GH_URL"
    public static let terminalScriptFileName = "Symphony GitHub Permission.command"
}

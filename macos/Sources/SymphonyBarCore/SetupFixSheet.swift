import Foundation

/// SU7–SU9: the consequence sheet of a Setup fix. The title is the question; then what happens, what stays the same
/// and how to undo it, the exact change (the diff of `symphony.yml`, or what Linear gets), and Cancel with the verb.
/// Nothing changes until its button is pressed. A fix that fails keeps the sheet open with the reason, **Open
/// Settings…**, **Close** and **Try Again**.
public struct SetupFixSheet: Equatable, Identifiable {
    public enum Kind: Equatable {
        /// A `config_edit` fix: the diff of `symphony.yml`, nil when the edit can't be made.
        case config(SetupDiff?)
        /// A Linear fix: what it creates or re-syncs, one line each.
        case linear([String])
    }

    public enum Phase: Equatable {
        case ready
        /// The fix is on its way: a spinner in the footer, the buttons off.
        case working
        /// SU9: the service's or the file's reason, inline. Nothing was half applied.
        case failed(String)
    }

    public let problem: SetupPayload.Problem
    public let fix: SetupPayload.Fix
    public var kind: Kind
    public var title: String
    public var happens: String
    public var stays: String
    /// How to undo it: Undo for a settings fix, by hand in Linear for a Linear one.
    public var undo: String
    /// The verb on the button: Remove, Change, Add, Create Label, Create Status, Re-sync.
    public var verb: String
    /// The tickets a Re-sync sends, all of the problem's or the one picked on its Details line.
    public var tickets: [String]
    public var phase: Phase = .ready

    public var id: String { problem.id + "|" + tickets.joined(separator: ",") }

    // MARK: Building

    /// The sheet for `problem`'s fix; nil for one that has no sheet (an `open` fix, or none). A config fix needs the
    /// file's `text` and `edited`, the edit made to it (or the error making it); a Re-sync may name one `ticket`.
    public init?(
        problem: SetupPayload.Problem,
        text: String? = nil,
        edited: Result<String, Error>? = nil,
        ticket: String? = nil,
        fileName: String = "symphony.yml"
    ) {
        guard let fix = problem.fix else { return nil }
        self.problem = problem
        self.fix = fix
        tickets = []

        switch fix {
        case let .configEdit(path, action, value):
            title = Self.configTitle(path: path, action: action, value: value, fileName: fileName)
            verb = Self.configVerb(action)
            happens = "The app copies \(fileName) to \(fileName).<time>.bak next to it, makes this change, and saves it once "
                + "symphony check passes on it. Symphony reloads it and checks its setup again."
            stays = "Every other line of \(fileName) stays as it is. Nothing changes in Linear."
            undo = "Undo shows for 10 seconds afterwards and puts the file back as it was. The .bak copy stays next to it."
            switch edited {
            case let .success(new)?:
                kind = .config(SetupDiff(old: text ?? "", new: new))
            case let .failure(error)?:
                kind = .config(nil)
                phase = .failed(error.localizedDescription)
            case nil:
                kind = .config(nil)
                phase = .failed("The app couldn't read \(fileName).")
            }

        case let .linear(action, team, name, type, after):
            let what = SetupLinearKind(action: action)
            let typeWord = type.map(Self.stateTypeWord)
            title = what.noun == "change" ? "Fix this in team \(team)?" : "Create the \(what.noun) “\(name)” in team \(team)?"
            verb = what.noun == "change" ? "Fix" : "Create \(what.noun.capitalized)"
            var created = ["Kind: \(what.noun.capitalized)", "Name: \(name)", "Team: \(team)"]
            if let typeWord { created.append("Type: \(typeWord)") }
            if what.isStatus { created.append(after.map { "Position: after “\($0)”" } ?? "Position: first of the \(typeWord ?? "team's") statuses") }
            kind = .linear(created)
            happens = what.noun == "change"
                ? "Symphony makes this change in Linear in team \(team). Why: \(problem.consequence)"
                : "Symphony creates one \(what.noun) in Linear, “\(name)”, in team \(team). Why: \(problem.consequence)"
            stays = what.isStatus
                ? "No ticket moves, and the team's other statuses stay as they are."
                : "No ticket gets the \(what.noun), and the team's other labels stay as they are."
            undo = what.isStatus
                ? "To undo it, delete the status “\(name)” in Linear: Settings › Teams › \(team) › Workflow."
                : "To undo it, delete the \(what.noun) “\(name)” in Linear: Settings › Teams › \(team) › Labels."

        case let .resyncHold(repo, all):
            let picked = ticket.map { [$0] } ?? all
            tickets = picked
            title = picked.count == 1 ? "Re-sync the hold label of \(picked[0])?" : "Re-sync the hold labels of \(picked.count) tickets in \(repo)?"
            verb = "Re-sync"
            kind = .linear(picked.map { name in
                problem.details.first { $0.label == name }.map { "\(name): \($0.value)" } ?? name
            })
            happens = "Symphony sets each ticket's hold label in Linear from the hold it keeps: it adds a missing label or "
                + "removes one with no hold."
            stays = "The holds stay as they are, and no ticket moves."
            undo = "To undo it, add or remove the label on the ticket in Linear by hand."

        case .open, .unknown:
            return nil
        }
    }

    // MARK: State

    /// The button's title: the verb, or Try Again once it failed.
    public var confirmTitle: String {
        if case .failed = phase { return "Try Again" }
        return verb
    }

    /// The other button: Cancel, or Close once it failed.
    public var cancelTitle: String {
        if case .failed = phase { return "Close" }
        return "Cancel"
    }

    /// SU9: once a fix failed, the sheet also goes to Settings, where the Linear key and the `symphony.yml` the app
    /// edits are set, so a refusal can be answered there and the fix tried again.
    public var failedDestination: SetupDestination? {
        if case .failed = phase { return .settings }
        return nil
    }

    public var error: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    public var isWorking: Bool { phase == .working }

    /// The verb (or Try Again) is off while the fix is on its way, and for a config edit the app can't make.
    public var canConfirm: Bool {
        if isWorking { return false }
        if case .config(nil) = kind { return false }
        return true
    }

    public mutating func start() {
        phase = .working
    }

    /// The fix failed: the sheet keeps everything it shows, and says why.
    public mutating func fail(_ message: String) {
        phase = .failed(message)
    }

    // MARK: Text

    static func configTitle(path: String, action: SetupPayload.ConfigAction, value: SetupValue, fileName: String) -> String {
        switch (action, value) {
        case (.remove, .null): "Remove \(path) from \(fileName)?"
        case (.remove, _): "Remove “\(value.display)” from \(path)?"
        case (.set, _): "Set \(path) to \(value.display)?"
        case (.add, _): "Add \(value.display) to \(path)?"
        }
    }

    static func configVerb(_ action: SetupPayload.ConfigAction) -> String {
        switch action {
        case .remove: "Remove"
        case .set: "Change"
        case .add: "Add"
        }
    }

    /// Linear's state types in the operator's words: `started` → In progress.
    static func stateTypeWord(_ type: String) -> String {
        switch type {
        case "backlog": "Backlog"
        case "unstarted": "Unstarted"
        case "started": "Started"
        case "completed": "Completed"
        case "canceled": "Canceled"
        case "triage": "Triage"
        default: type
        }
    }
}

/// `POST /api/v1/setup/refresh` (Check Again) and `POST /api/v1/setup/fixes` (a Linear fix). They need no control
/// token: Symphony takes them from a client that sends no `Origin` header, as the app doesn't.
public enum SetupAPI {
    public static let refreshPath = "api/v1/setup/refresh"
    public static let fixesPath = "api/v1/setup/fixes"
    /// A fix runs the checks again after it, which reads Linear.
    public static let timeout: TimeInterval = 60
    /// What a repo key keeps unescaped in a query: a key holds letters, digits, `.`, `_` and `-`.
    private static let queryValue = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    public enum Result: Equatable {
        /// The problems after the check or the fix.
        case checked(SetupPayload)
        /// What went wrong, in plain words; for a refused fix, Linear's reason.
        case failed(String)
    }

    /// The request for Check Again, or for `descriptor`'s fix, against Symphony at `base`. With `repo`, Check Again
    /// answers with that repo's problems and the global ones only.
    public static func request(fix descriptor: [String: Any]? = nil, repo: String? = nil, base: URL) -> URLRequest {
        var path = descriptor == nil ? refreshPath : fixesPath
        if descriptor == nil, let repo, let query = repo.addingPercentEncoding(withAllowedCharacters: queryValue) {
            path += "?repo=" + query
        }
        var request = URLRequest(url: LiveAPIClient.url(path, base: base) ?? base, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let descriptor {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Strings and lists of strings always encode.
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["fix": descriptor], options: [.sortedKeys])
        }
        return request
    }

    /// Sends Check Again, or `descriptor`'s fix, to the control URL in `stateRoot` (or `fallback` while Symphony hasn't
    /// written one).
    public static func send(
        fix descriptor: [String: Any]? = nil,
        repo: String? = nil,
        stateRoot: URL,
        fallback: URL? = SymphonyState.defaultBaseURL,
        transport: ControlAPI.Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> Result {
        let prefix = descriptor == nil ? "Couldn't check the setup again" : "The fix didn't run"
        guard let base = StateRoot.controlURL(in: stateRoot, fallback: fallback) else {
            return .failed("\(prefix): Symphony hasn't said where it listens.")
        }
        guard let (data, response) = try? await transport(request(fix: descriptor, repo: repo, base: base)) else {
            return .failed("\(prefix): nothing answered at \(base.absoluteString).")
        }
        return result(prefix: prefix, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    /// How long Add Repo's check waits for Symphony to read the repo it saved: through a reload, or a restart that sets
    /// the repo up.
    public static let repoCheckWait: TimeInterval = 120
    /// How long it waits between two tries.
    public static let repoCheckInterval: TimeInterval = 2

    /// Add Repo's check of the repo `key` it saved: Check Again for that repo, asked again while Symphony hasn't read the
    /// repo yet or doesn't answer (it reloads `symphony.yml`, or restarts), until it answers or `wait` runs out. Its
    /// answer keeps only the repo's problems and the global ones, whatever Symphony sent.
    public static func checkRepo(
        _ key: String,
        wait: TimeInterval = repoCheckWait,
        interval: TimeInterval = repoCheckInterval,
        send: (_ repo: String) async -> Result,
        sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async -> Result {
        var waited: TimeInterval = 0
        while true {
            switch await send(key) {
            case let .checked(payload):
                return .checked(payload.forRepo(key))
            case let .failed(message):
                guard waited + interval <= wait, !Task.isCancelled else { return .failed(message) }
            }
            await sleep(interval)
            waited += interval
        }
    }

    /// Symphony's answer: the payload, or the error it names. An answer with an `error` is a failure whatever its
    /// status, as a refused fix answers 422 with the unchanged problems and the reason.
    public static func result(prefix: String, statusCode: Int, data: Data) -> Result {
        struct Failure: Decodable {
            struct Error: Decodable {
                let code: String?
                let message: String?
            }

            let error: Error?
        }
        if let error = (try? JSONDecoder().decode(Failure.self, from: data))?.error {
            let message = error.message?.trimmingWhitespace() ?? ""
            if error.code == "fix_refused", !message.isEmpty { return .failed(message) }
            return .failed("\(prefix): " + (message.isEmpty ? (error.code ?? "Symphony reported an error") : message))
        }
        switch statusCode {
        case 200:
            guard let payload = SetupPayload.decode(data) else { return .failed("\(prefix): Symphony's answer couldn't be read.") }
            return .checked(payload)
        case 404:
            return .failed("\(prefix): this Symphony predates Setup. Update it.")
        default:
            return .failed("\(prefix): Symphony answered with HTTP \(statusCode).")
        }
    }
}

/// C18 on the Setup page: after a fix, what it did; after a settings fix, with **Undo** for 10 seconds (SU10).
public struct SetupBanner: Equatable, Identifiable {
    public static let duration = InboxBanner.duration

    public let id = UUID()
    public var style: InboxBanner.Style
    public var text: String
    /// The copy Undo writes back, nil when the banner offers no Undo.
    public var backup: SetupBackup?

    public init(style: InboxBanner.Style, text: String, backup: SetupBackup? = nil) {
        self.style = style
        self.text = text
        self.backup = backup
    }

    public var offersUndo: Bool { backup != nil }

    /// After a fix that worked: what it did, from its sheet; a settings fix offers Undo.
    public static func fixed(_ sheet: SetupFixSheet, backup: SetupBackup? = nil) -> SetupBanner {
        let text: String
        switch sheet.fix {
        case let .configEdit(path, action, value):
            let done: String
            switch (action, value) {
            case (.remove, .null): done = "Removed \(path) from symphony.yml."
            case (.remove, _): done = "Removed “\(value.display)” from \(path)."
            case (.set, _): done = "Set \(path) to \(value.display)."
            case (.add, _): done = "Added \(value.display) to \(path)."
            }
            text = done + (backup.map { " The old file is \($0.url.lastPathComponent)." } ?? "")
        case let .linear(action, team, name, _, _):
            let noun = SetupLinearKind(action: action).noun
            text = noun == "change" ? "Symphony made the change in team \(team)." : "Created the \(noun) “\(name)” in team \(team)."
        case .resyncHold:
            text = sheet.tickets.count == 1 ? "Re-synced the hold label of \(sheet.tickets[0])." : "Re-synced the hold labels of \(sheet.tickets.count) tickets."
        case .open, .unknown:
            text = "Done."
        }
        return SetupBanner(style: .success, text: text, backup: backup)
    }

    /// After Undo: the file is back as it was.
    public static var undone: SetupBanner {
        SetupBanner(style: .info, text: "symphony.yml is back as it was. Symphony checks its setup again.")
    }

    public static func failed(_ message: String) -> SetupBanner {
        SetupBanner(style: .error, text: message)
    }
}

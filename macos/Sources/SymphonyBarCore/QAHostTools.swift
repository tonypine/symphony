import Foundation

/// Why `auto_review.playbooks.macos_app.requires` can't be read or changed by editing one line.
public enum QAHostToolsError: LocalizedError, Equatable {
    /// A section above the key is inline (for example `macos_app: {build: make app}`), not an indented block.
    case notABlock(String)
    /// The key holds a block list, which the field doesn't rewrite.
    case blockList
    /// A name that is not a plain executable name.
    case invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the QA host tools by hand."
        case .blockList:
            return "`requires:` in symphony.yml is a block list. Change the QA host tools by hand."
        case .invalidName(let name):
            return "`\(name)` is not an executable name. Use letters, digits, `.`, `_`, `+` or `-`."
        }
    }
}

/// `auto_review.playbooks.macos_app.requires` in the text of a `symphony.yml`: the executables a macOS app
/// QA pass needs on the QA host, such as `go` and `pg_ctl`. Symphony looks for each with `command -v` when the
/// pass starts, and blocks the pass on the first one missing. A repo's `WORKFLOW.md` may set its own list.
public struct QAHostTools: Equatable {
    public var tools: [String]

    public static let path = ["auto_review", "playbooks", "macos_app", "requires"]

    public init(tools: [String] = []) {
        self.tools = tools
    }

    /// The tools in the Settings field: names separated by commas or spaces, without repeats.
    public init(text: String) {
        let names = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        self.init(tools: names.reduce(into: [String]()) { result, name in
            if !result.contains(name) { result.append(name) }
        })
    }

    /// The tools as the Settings field shows them, `go, pg_ctl`.
    public var text: String { tools.joined(separator: ", ") }

    /// The list in the file: an inline list such as `requires: [go, pg_ctl]` or a block list. A missing key,
    /// an empty list or `null` reads as no tools.
    public static func values(in yaml: String) throws -> QAHostTools {
        let raw = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let raw else { return QAHostTools() }
        let items = raw.trimmingCharacters(in: .whitespaces).isEmpty ? try blockListItems(in: yaml) : inlineItems(raw)
        return QAHostTools(tools: items.filter { !$0.isEmpty })
    }

    /// The same text with the list set to `new`, written inline. Writes `requires: []` when it is empty, so
    /// no key is ever removed by hand.
    public static func updating(_ yaml: String, from old: QAHostTools, to new: QAHostTools) throws -> String {
        guard new != old else { return yaml }
        if let name = new.tools.first(where: { $0.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) == nil }) {
            throw QAHostToolsError.invalidName(name)
        }
        return try blockSection {
            if try !blockListItems(in: yaml).isEmpty { throw QAHostToolsError.blockList }
            return try ConfigSetting.setting(at: path, to: "[" + new.tools.joined(separator: ", ") + "]", in: yaml)
        }
    }

    /// The items of an inline list, `[go, pg_ctl]`, or a single bare value such as `go`.
    private static func inlineItems(_ raw: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("["), text.hasSuffix("]") else {
            return text.isEmpty || text == "~" || text == "null" ? [] : [text]
        }
        return text.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The items of a block list under the key.
    private static func blockListItems(in yaml: String) throws -> [String] {
        let document = Document(yaml)
        var range = document.all
        for name in path {
            guard let child = document.child(name, in: range) else { return [] }
            if name == path.last { return document.blockListItems(child) }
            range = try document.block(of: child)
        }
        return []
    }

    /// Reports an inline section above the key as a QA host tools error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw QAHostToolsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readQAHostTools() throws -> QAHostTools {
        try QAHostTools.values(in: read())
    }

    /// Sets the QA host tools once `check` passes on the result.
    public func writeQAHostTools(
        _ new: QAHostTools,
        from old: QAHostTools,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try QAHostTools.updating($0, from: old, to: new) }, checkingWith: check)
    }
}

import Foundation

/// A problem that stops the settings from being saved.
public enum SettingsIssue: Equatable {
    case checkoutPathMissing
    case checkoutPathNotAbsolute
    case checkoutPathNotDirectory
    case configPathMissing
    case configPathNotAbsolute
    case configPathNotFile
    case commandPrefixUnbalancedQuotes
    case stopTimeoutOutOfRange
    case linearAPIKeyMissing
    case environmentNameInvalid(String)
    case environmentNameDuplicate(String)
    case environmentNameReserved(String)
    case embeddedSymphonyMissing

    /// Text shown under the form.
    public var message: String {
        switch self {
        case .checkoutPathMissing:
            return "Choose the Symphony checkout folder."
        case .checkoutPathNotAbsolute:
            return "The checkout path must be absolute (start with /)."
        case .checkoutPathNotDirectory:
            return "The checkout path is not an existing folder."
        case .configPathMissing:
            return "Choose the symphony.yml file."
        case .configPathNotAbsolute:
            return "The symphony.yml path must be absolute (start with /)."
        case .configPathNotFile:
            return "The symphony.yml path is not an existing file."
        case .commandPrefixUnbalancedQuotes:
            return "The command prefix has an unclosed quote or a trailing backslash."
        case .stopTimeoutOutOfRange:
            let range = AppSettings.stopTimeoutRange
            return "The stop timeout must be between \(range.lowerBound) and \(range.upperBound) seconds."
        case .linearAPIKeyMissing:
            return "Enter a Linear API key."
        case .environmentNameInvalid(let name):
            return "\"\(name)\" is not a valid environment variable name (letters, digits and _, not starting with a digit)."
        case .environmentNameDuplicate(let name):
            return "\(name) is listed more than once."
        case .environmentNameReserved(let name):
            return "\(name) is set by its own field, not as an extra variable."
        case .embeddedSymphonyMissing:
            return EmbeddedSymphony.missingMessage
        }
    }
}

/// Answers questions about paths on disk, so validation can be tested without real files.
public protocol FileChecker {
    func isDirectory(atPath path: String) -> Bool
    func isFile(atPath path: String) -> Bool
}

/// `FileChecker` backed by `FileManager`.
public struct LocalFileChecker: FileChecker {
    public init() {}

    public func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func isFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

/// Checks settings before they are saved. Pass trimmed values.
/// The checkout folder and command prefix are checked only in Development mode; otherwise the embedded
/// Symphony at `embeddedSymphonyPath` must exist.
public struct SettingsValidator {
    private let files: FileChecker
    private let embeddedSymphonyPath: String?

    public init(files: FileChecker = LocalFileChecker(), embeddedSymphonyPath: String? = nil) {
        self.files = files
        self.embeddedSymphonyPath = embeddedSymphonyPath
    }

    public func validate(_ settings: AppSettings, _ secrets: SecretSettings) -> [SettingsIssue] {
        var issues: [SettingsIssue] = []

        if !settings.developmentMode {
            if !EmbeddedSymphony.isAvailable(at: embeddedSymphonyPath, files: files) {
                issues.append(.embeddedSymphonyMissing)
            }
        } else if settings.checkoutPath.isEmpty {
            issues.append(.checkoutPathMissing)
        } else if !settings.checkoutPath.hasPrefix("/") {
            issues.append(.checkoutPathNotAbsolute)
        } else if !files.isDirectory(atPath: settings.checkoutPath) {
            issues.append(.checkoutPathNotDirectory)
        }

        if settings.configPath.isEmpty {
            issues.append(.configPathMissing)
        } else if !settings.configPath.hasPrefix("/") {
            issues.append(.configPathNotAbsolute)
        } else if !files.isFile(atPath: settings.configPath) {
            issues.append(.configPathNotFile)
        }

        if settings.developmentMode, ShellWords.split(settings.commandPrefix) == nil {
            issues.append(.commandPrefixUnbalancedQuotes)
        }

        if !AppSettings.stopTimeoutRange.contains(settings.stopTimeoutSeconds) {
            issues.append(.stopTimeoutOutOfRange)
        }

        if secrets.linearAPIKey.isEmpty {
            issues.append(.linearAPIKeyMissing)
        }

        var seen = Set<String>()
        var duplicates = Set<String>()
        for variable in secrets.extraEnvironment {
            let name = variable.name
            if name == SecretSettings.linearAPIKeyName {
                issues.append(.environmentNameReserved(name))
            } else if !Self.isValidEnvironmentName(name) {
                issues.append(.environmentNameInvalid(name))
            } else if !seen.insert(name).inserted, duplicates.insert(name).inserted {
                issues.append(.environmentNameDuplicate(name))
            }
        }

        return issues
    }

    /// POSIX-style name: ASCII letters, digits and underscore, not starting with a digit.
    public static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "_"
        }
    }
}

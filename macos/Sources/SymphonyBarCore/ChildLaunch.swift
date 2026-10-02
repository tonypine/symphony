import Foundation

/// Everything needed to spawn Symphony: program, arguments, working directory and environment.
public struct ChildLaunch: Equatable {
    /// Login shell used so Finder-launched apps still get the user's PATH (and `mise`) from zsh startup files.
    public static let shell = "/bin/zsh"

    /// Path of the Symphony escript, relative to the checkout.
    public static let symphonyRelativePath = "./bin/symphony"

    /// Directories added to the end of PATH, for tools installed where a Finder-launched app can't see them.
    public static let fallbackPathDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]

    public init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// The shell script run by `zsh -lc`. Never holds a secret.
    public var script: String { arguments.last ?? "" }
}

/// Why Symphony can't be started with the current settings.
public enum LaunchProblem: LocalizedError, Equatable {
    case checkoutPathMissing
    case configPathMissing
    case commandPrefixInvalid
    case linearAPIKeyMissing
    case symphonyBinaryMissing(String)

    public var message: String {
        switch self {
        case .checkoutPathMissing:
            return "Choose the Symphony checkout folder in Settings."
        case .configPathMissing:
            return "Choose the symphony.yml file in Settings."
        case .commandPrefixInvalid:
            return "The command prefix has an unclosed quote or a trailing backslash."
        case .linearAPIKeyMissing:
            return "Linear API key not set. Add it in Settings."
        case .symphonyBinaryMissing(let path):
            return "\(path) was not found. Build it with `mise exec -- mix build` in the checkout."
        }
    }

    public var errorDescription: String? { message }

    /// Problems the user fixes in the Settings window.
    public var isFixedInSettings: Bool {
        if case .symphonyBinaryMissing = self { return false }
        return true
    }
}

/// Builds the child launch from the saved settings. Secrets only ever go into the environment.
public enum ChildLaunchBuilder {
    public static func build(
        settings: AppSettings,
        secrets: SecretSettings,
        baseEnvironment: [String: String],
        files: FileChecker = LocalFileChecker()
    ) throws -> ChildLaunch {
        let settings = settings.trimmed()
        let secrets = secrets.trimmed()

        guard !settings.checkoutPath.isEmpty else { throw LaunchProblem.checkoutPathMissing }
        guard !settings.configPath.isEmpty else { throw LaunchProblem.configPathMissing }
        guard let prefix = ShellWords.split(settings.commandPrefix) else { throw LaunchProblem.commandPrefixInvalid }
        // A blank Keychain item means "not set": starting would only fail on every Linear call.
        guard !secrets.linearAPIKey.isEmpty else { throw LaunchProblem.linearAPIKeyMissing }

        let binary = settings.checkoutPath + "/bin/symphony"
        guard files.isFile(atPath: binary) else { throw LaunchProblem.symphonyBinaryMissing(binary) }

        let words = prefix + [ChildLaunch.symphonyRelativePath, "--config", settings.configPath]
        let script = "exec " + words.map(ShellWords.quote).joined(separator: " ")

        return ChildLaunch(
            executable: ChildLaunch.shell,
            arguments: ["-lc", script],
            workingDirectory: settings.checkoutPath,
            environment: environment(base: baseEnvironment, secrets: secrets)
        )
    }

    /// The app's environment with PATH fallbacks, the extra variables and the Linear API key on top.
    static func environment(base: [String: String], secrets: SecretSettings) -> [String: String] {
        var environment = base
        environment["PATH"] = pathWithFallbacks(base["PATH"], home: base["HOME"])

        for variable in secrets.extraEnvironment where !variable.name.isEmpty {
            environment[variable.name] = variable.value
        }
        if !secrets.linearAPIKey.isEmpty {
            environment[SecretSettings.linearAPIKeyName] = secrets.linearAPIKey
        }
        return environment
    }

    static func pathWithFallbacks(_ path: String?, home: String?) -> String {
        var directories = (path ?? "").split(separator: ":").map(String.init)
        if directories.isEmpty { directories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }

        var fallbacks = ChildLaunch.fallbackPathDirectories
        if let home, !home.isEmpty { fallbacks.append(home + "/.local/bin") }
        for directory in fallbacks where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }
}

import Foundation

/// The script Open Dashboard in Terminal runs: `symphony dashboard` from the binary Start runs, against the
/// Symphony the app watches.
public enum TerminalDashboard {
    /// Name of the script file Terminal opens. Terminal runs `.command` files.
    public static let scriptFileName = "Symphony Dashboard.command"

    /// Bundle identifier of Terminal.app.
    public static let terminalBundleIdentifier = "com.apple.Terminal"

    /// Builds the script. It holds no secret: `symphony dashboard` only needs the control URL, and reads the
    /// control token from the state directory. Development mode runs the checkout's `bin/symphony` through
    /// the command prefix in a login shell, as Start does.
    public static func script(
        settings: AppSettings,
        embeddedSymphonyPath: String?,
        stateRoot: URL,
        controlURL: URL,
        files: FileChecker = LocalFileChecker()
    ) throws -> String {
        let settings = settings.trimmed()
        let dashboard = ["dashboard", "--url", controlURL.absoluteString]
        let command: [String]
        var lines = ["#!/bin/zsh -l"]

        if settings.developmentMode {
            guard !settings.checkoutPath.isEmpty else { throw LaunchProblem.checkoutPathMissing }
            guard let prefix = ShellWords.split(settings.commandPrefix) else { throw LaunchProblem.commandPrefixInvalid }
            let binary = settings.checkoutPath + "/bin/symphony"
            guard files.isFile(atPath: binary) else { throw LaunchProblem.symphonyBinaryMissing(binary) }
            lines.append("cd " + ShellWords.quote(settings.checkoutPath) + " || exit 1")
            command = prefix + [ChildLaunch.symphonyRelativePath] + dashboard
        } else {
            guard let binary = embeddedSymphonyPath, EmbeddedSymphony.isAvailable(at: binary, files: files) else {
                throw LaunchProblem.embeddedSymphonyMissing
            }
            command = [binary] + dashboard
        }

        lines.append("export \(StateRoot.environmentKey)=" + ShellWords.quote(stateRoot.path))
        lines.append("exec " + command.map(ShellWords.quote).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }
}

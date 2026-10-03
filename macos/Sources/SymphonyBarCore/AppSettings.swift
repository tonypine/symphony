/// Non-secret settings, stored in UserDefaults.
public struct AppSettings: Equatable {
    /// Bounds for the stop timeout, in seconds.
    public static let stopTimeoutRange = 1...600

    /// Command prefix used until the user saves one: run Symphony with the checkout's `mise` toolchain.
    public static let defaultCommandPrefix = "mise exec --"

    /// Stop timeout used until the user picks one.
    public static let defaultStopTimeoutSeconds = 30

    /// Bounds for the restart timeout, in minutes.
    public static let restartTimeoutRange = 1...1440

    /// Restart timeout used until the user picks one.
    public static let defaultRestartTimeoutMinutes = 30

    /// Absolute path to the Symphony checkout.
    public var checkoutPath: String

    /// Absolute path to the `symphony.yml` to run with.
    public var configPath: String

    /// Optional words put before the Symphony command, for example `mise exec --`.
    public var commandPrefix: String

    /// Seconds to wait for Symphony to exit after asking it to stop.
    public var stopTimeoutSeconds: Int

    /// Minutes Restart Symphony waits for agent runs to finish before it also offers Restart Now Anyway.
    public var restartTimeoutMinutes: Int

    /// Start Symphony when the app opens.
    public var startOnLaunch: Bool

    /// Run `bin/symphony` from the checkout instead of the Symphony embedded in the app.
    public var developmentMode: Bool

    public init(
        checkoutPath: String = "",
        configPath: String = "",
        commandPrefix: String = AppSettings.defaultCommandPrefix,
        stopTimeoutSeconds: Int = AppSettings.defaultStopTimeoutSeconds,
        restartTimeoutMinutes: Int = AppSettings.defaultRestartTimeoutMinutes,
        startOnLaunch: Bool = false,
        developmentMode: Bool = false
    ) {
        self.checkoutPath = checkoutPath
        self.configPath = configPath
        self.commandPrefix = commandPrefix
        self.stopTimeoutSeconds = stopTimeoutSeconds
        self.restartTimeoutMinutes = restartTimeoutMinutes
        self.startOnLaunch = startOnLaunch
        self.developmentMode = developmentMode
    }

    /// True while a path Start needs is still unset, so the app opens Settings at launch.
    /// The checkout folder is needed only in Development mode.
    public var needsSetup: Bool {
        let settings = trimmed()
        return settings.configPath.isEmpty || (settings.developmentMode && settings.checkoutPath.isEmpty)
    }

    /// The same settings with surrounding whitespace removed from the text fields.
    public func trimmed() -> AppSettings {
        AppSettings(
            checkoutPath: checkoutPath.trimmingWhitespace(),
            configPath: configPath.trimmingWhitespace(),
            commandPrefix: commandPrefix.trimmingWhitespace(),
            stopTimeoutSeconds: stopTimeoutSeconds,
            restartTimeoutMinutes: restartTimeoutMinutes,
            startOnLaunch: startOnLaunch,
            developmentMode: developmentMode
        )
    }
}

/// An environment variable passed to Symphony.
public struct EnvironmentVariable: Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Secret settings, stored only in the Keychain.
public struct SecretSettings: Equatable {
    /// Environment variable name, and Keychain account, of the Linear API key.
    public static let linearAPIKeyName = "LINEAR_API_KEY"

    /// Environment variable name, and Keychain account, of the OpenRouter API key.
    public static let openRouterAPIKeyName = "OPENROUTER_API_KEY"

    /// Names set by their own fields, never as extra variables.
    public static let reservedNames: Set<String> = [linearAPIKeyName, openRouterAPIKeyName]

    public var linearAPIKey: String

    /// Optional; empty means Symphony gets no `OPENROUTER_API_KEY`.
    public var openRouterAPIKey: String

    /// Extra environment variables, sorted by name when loaded.
    public var extraEnvironment: [EnvironmentVariable]

    public init(linearAPIKey: String = "", openRouterAPIKey: String = "", extraEnvironment: [EnvironmentVariable] = []) {
        self.linearAPIKey = linearAPIKey
        self.openRouterAPIKey = openRouterAPIKey
        self.extraEnvironment = extraEnvironment
    }

    /// The same secrets with whitespace trimmed from the keys and names, and fully blank extra rows dropped.
    /// Extra values are kept as typed.
    public func trimmed() -> SecretSettings {
        SecretSettings(
            linearAPIKey: linearAPIKey.trimmingWhitespace(),
            openRouterAPIKey: openRouterAPIKey.trimmingWhitespace(),
            extraEnvironment: extraEnvironment.compactMap { variable in
                let name = variable.name.trimmingWhitespace()
                if name.isEmpty && variable.value.isEmpty { return nil }
                return EnvironmentVariable(name: name, value: variable.value)
            }
        )
    }
}

extension String {
    func trimmingWhitespace() -> String {
        var scalars = Substring(self)
        while let first = scalars.first, first.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }
}

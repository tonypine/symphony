/// Non-secret settings, stored in UserDefaults.
public struct AppSettings: Equatable {
    /// Bounds for the stop timeout, in seconds.
    public static let stopTimeoutRange = 1...600

    /// Command prefix used until the user saves one: run Symphony with the checkout's `mise` toolchain.
    public static let defaultCommandPrefix = "mise exec --"

    /// Stop timeout used until the user picks one.
    public static let defaultStopTimeoutSeconds = 30

    /// Absolute path to the Symphony checkout.
    public var checkoutPath: String

    /// Absolute path to the `symphony.yml` to run with.
    public var configPath: String

    /// Optional words put before the Symphony command, for example `mise exec --`.
    public var commandPrefix: String

    /// Seconds to wait for Symphony to exit after asking it to stop.
    public var stopTimeoutSeconds: Int

    /// Start Symphony when the app opens.
    public var startOnLaunch: Bool

    public init(
        checkoutPath: String = "",
        configPath: String = "",
        commandPrefix: String = AppSettings.defaultCommandPrefix,
        stopTimeoutSeconds: Int = AppSettings.defaultStopTimeoutSeconds,
        startOnLaunch: Bool = false
    ) {
        self.checkoutPath = checkoutPath
        self.configPath = configPath
        self.commandPrefix = commandPrefix
        self.stopTimeoutSeconds = stopTimeoutSeconds
        self.startOnLaunch = startOnLaunch
    }

    /// The same settings with surrounding whitespace removed from the text fields.
    public func trimmed() -> AppSettings {
        AppSettings(
            checkoutPath: checkoutPath.trimmingWhitespace(),
            configPath: configPath.trimmingWhitespace(),
            commandPrefix: commandPrefix.trimmingWhitespace(),
            stopTimeoutSeconds: stopTimeoutSeconds,
            startOnLaunch: startOnLaunch
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

    public var linearAPIKey: String

    /// Extra environment variables, sorted by name when loaded.
    public var extraEnvironment: [EnvironmentVariable]

    public init(linearAPIKey: String = "", extraEnvironment: [EnvironmentVariable] = []) {
        self.linearAPIKey = linearAPIKey
        self.extraEnvironment = extraEnvironment
    }

    /// The same secrets with whitespace trimmed from the key and names, and fully blank extra rows dropped.
    /// Extra values are kept as typed.
    public func trimmed() -> SecretSettings {
        SecretSettings(
            linearAPIKey: linearAPIKey.trimmingWhitespace(),
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

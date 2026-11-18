import Foundation

/// Why a provider's model list couldn't be read, as the page shows it.
public struct ModelListFailure: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// The models the Runs page offers for each provider, so no model is typed: Anthropic's and OpenAI's from the
/// lists in `RunProfilesConfig`, OpenRouter's from its models API (the ones that support tools, as Settings
/// reads them), and OpenCode Go's from `opencode models`. A list that loads is nil until it has.
public struct RunModelLists: Equatable {
    public var openRouter: Result<[OpenRouterModel], OpenRouterFailure>?
    public var openCodeGo: Result<[RunProfileChoice], ModelListFailure>?

    public init(
        openRouter: Result<[OpenRouterModel], OpenRouterFailure>? = nil,
        openCodeGo: Result<[RunProfileChoice], ModelListFailure>? = nil
    ) {
        self.openRouter = openRouter
        self.openCodeGo = openCodeGo
    }

    /// The models of `provider`, plus `current` when the list doesn't hold it, so a value in the file is always
    /// offered. Nil while the list is loading or when it couldn't be read; see `failure(for:)`.
    public func models(for provider: String?, including current: String? = nil) -> [RunProfileChoice]? {
        let list: [RunProfileChoice]?
        switch provider {
        case RunProfilesConfig.anthropic:
            list = RunProfilesConfig.models
        case RunProfilesConfig.openAI:
            list = RunProfilesConfig.openAIModels
        case RunProfilesConfig.openRouter:
            guard case .success(let models)? = openRouter else { return nil }
            list = OpenRouterModel.toolModels(models, matching: "").map { RunProfileChoice(id: $0.id, title: $0.name) }
        case RunProfilesConfig.openCodeGo:
            guard case .success(let models)? = openCodeGo else { return nil }
            list = models
        default:
            list = []
        }
        return list.map { RunProfilesConfig.choices($0, including: current) }
    }

    /// Why the list of `provider` couldn't be read, or nil.
    public func failure(for provider: String?) -> String? {
        switch provider {
        case RunProfilesConfig.openRouter:
            guard case .failure(let failure)? = openRouter else { return nil }
            return failure.message
        case RunProfilesConfig.openCodeGo:
            guard case .failure(let failure)? = openCodeGo else { return nil }
            return failure.message
        default:
            return nil
        }
    }
}

/// OpenCode Go's models, as `opencode models opencode-go` lists them: one `opencode-go/<model>` per line. A
/// run names the model without the provider.
public enum OpenCodeModels {
    public static let timeout: TimeInterval = 30

    /// The models `output` lists for OpenCode Go, in its order, without repeats.
    public static func parse(_ output: String) -> [RunProfileChoice] {
        let prefix = RunProfilesConfig.openCodeGo + "/"
        var seen: Set<String> = []
        return output.components(separatedBy: .newlines).compactMap { line in
            let line = line.trimmingWhitespace()
            guard line.hasPrefix(prefix) else { return nil }
            let id = String(line.dropFirst(prefix.count))
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return RunProfileChoice(id: id, title: id)
        }
    }

    /// The shell line that lists the models: the program of the OpenCode harness's command when it sets one,
    /// else `opencode`.
    public static func script(command: String?) -> String {
        let program = command.flatMap(ShellWords.split)?.first ?? "opencode"
        return ShellWords.quote(program) + " models " + RunProfilesConfig.openCodeGo
    }

    /// `script(command:)` through a login shell, so the operator's PATH finds the program.
    public static func launch(command: String?, environment: [String: String], workingDirectory: String) -> ChildLaunch {
        ChildLaunch(
            executable: ChildLaunch.shell,
            arguments: ["-lc", script(command: command)],
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    /// Runs `launch` and reads the models it lists.
    public static func load(_ launch: ChildLaunch, timeout: TimeInterval = timeout) async -> Result<[RunProfileChoice], ModelListFailure> {
        await Task.detached(priority: .utility) { OpenCodeModels.run(launch, timeout: timeout) }.value
    }

    static func run(_ launch: ChildLaunch, timeout: TimeInterval) -> Result<[RunProfileChoice], ModelListFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory)
        process.environment = launch.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failure(ModelListFailure("Couldn't run opencode models: \(error.localizedDescription)"))
        }
        let output = Output()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            exited.wait()
            return .failure(ModelListFailure("opencode models took longer than \(Int(timeout)) seconds."))
        }
        let text = readDone.wait(timeout: .now() + 5) == .success ? String(decoding: output.data, as: UTF8.self) : ""
        return result(status: process.terminationStatus, output: text)
    }

    /// The models for an exit `status` and the output, or why there are none.
    public static func result(status: Int32, output: String) -> Result<[RunProfileChoice], ModelListFailure> {
        guard status == 0 else {
            let last = output.components(separatedBy: .newlines).map { $0.trimmingWhitespace() }.last { !$0.isEmpty }
            return .failure(ModelListFailure(last ?? "opencode models exited with status \(status)."))
        }
        let models = parse(output)
        guard !models.isEmpty else { return .failure(ModelListFailure("opencode models lists no OpenCode Go models.")) }
        return .success(models)
    }

    private final class Output: @unchecked Sendable {
        var data = Data()
    }
}

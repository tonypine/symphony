import Foundation

/// The outcome of `symphony check`.
public enum ConfigCheckResult: Equatable {
    case passed
    /// The message says what is wrong, from the check's output when it printed one.
    case failed(String)
}

/// Runs `symphony check --config <symphony.yml>`, which loads the config and every repo's WORKFLOW.md the way
/// Symphony does at boot, without starting it.
public enum ConfigCheck {
    /// Seconds the check may take. The embedded binary unpacks its runtime on first run.
    public static let timeout: TimeInterval = 60

    /// Longest message kept from the check's output.
    static let maxMessageLength = 600

    /// Runs `launch` (built with the `check` subcommand) off the main thread and waits for its result.
    public static func run(_ launch: ChildLaunch, timeout: TimeInterval = timeout) async -> ConfigCheckResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(launch, timeout: timeout))
            }
        }
    }

    static func runBlocking(_ launch: ChildLaunch, timeout: TimeInterval) -> ConfigCheckResult {
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
            return .failed("Couldn't run symphony check: \(error.localizedDescription)")
        }

        // Read while the check runs, so a full pipe can't block it.
        let output = OutputBuffer()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            exited.wait()
            return .failed("symphony check took longer than \(Int(timeout)) seconds.")
        }
        // Something the check started may still hold the pipe open; don't wait on it for long.
        let text = readDone.wait(timeout: .now() + 5) == .success ? String(decoding: output.data, as: UTF8.self) : ""
        let status = process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus
        return result(status: status, output: text)
    }

    /// The result for an exit `status` (negative for the signal that killed the check) and its combined output.
    public static func result(status: Int32, output: String) -> ConfigCheckResult {
        guard status != 0 else { return .passed }

        let lines = output.components(separatedBy: .newlines).map { $0.trimmingWhitespace() }.filter { !$0.isEmpty }
        // A login shell can print its own noise first; Symphony's own message is what matters.
        let message: String
        if let start = lines.lastIndex(where: { $0.hasPrefix("Config error") }) {
            message = lines[start...].joined(separator: " ")
        } else if let last = lines.last {
            message = last
        } else if status < 0 {
            message = "symphony check was killed by signal \(-status)"
        } else {
            message = "symphony check exited with status \(status)"
        }
        guard message.count > maxMessageLength else { return .failed(message) }
        return .failed(String(message.prefix(maxMessageLength)) + "…")
    }

    /// `message` with what is wrong first: "Config error in <path>: <reason>" reads "<reason> (in <path>)", so the
    /// key at fault isn't behind a long path. Other messages are returned as they are.
    public static func reasonFirst(_ message: String) -> String {
        let prefix = "Config error in "
        guard message.hasPrefix(prefix) else { return message }
        let rest = message.dropFirst(prefix.count)
        guard let colon = rest.range(of: ": ") else { return message }
        let path = rest[..<colon.lowerBound]
        let reason = String(rest[colon.upperBound...]).trimmingWhitespace()
        guard !path.isEmpty, !reason.isEmpty else { return message }
        return "\(reason) (in \(path))"
    }

    private final class OutputBuffer {
        var data = Data()
    }
}

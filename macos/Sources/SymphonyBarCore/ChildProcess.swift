import Darwin
import Dispatch
import Foundation

/// `posix_spawn` failed, so nothing was started.
public struct SpawnError: LocalizedError, Equatable, CustomStringConvertible {
    public let code: Int32
    public let step: String

    public var description: String { "Could not start Symphony (\(step)): \(String(cString: strerror(code)))" }
    public var errorDescription: String? { description }
}

/// A running Symphony process the app owns.
///
/// It runs in its own process group, with stdin from /dev/null and stdout and stderr appended to a log file.
/// Stopping sends SIGTERM to the group and SIGKILL after the timeout. Once the process exits, anything left in
/// its group, and the descendants it was last seen with (agent CLIs run in their own sessions), is killed.
///
/// Use it only from `queue`; `onExit` is called there, once.
public final class ChildProcess {
    public let pid: pid_t
    public private(set) var isRunning = true
    public private(set) var stopRequested = false

    private let queue: DispatchQueue
    private let onExit: (_ exit: ChildExit, _ requested: Bool) -> Void
    private var exitSource: DispatchSourceProcess?
    private var treeTimer: DispatchSourceTimer?
    private var killTimer: DispatchWorkItem?
    private var descendants: [ProcessRecord] = []

    /// Starts `launch` with output appended to `logURL`. `onExit` gets the exit and whether `stop` asked for it.
    public static func spawn(
        _ launch: ChildLaunch,
        logURL: URL,
        queue: DispatchQueue,
        treeRefreshInterval: TimeInterval = 5,
        onExit: @escaping (_ exit: ChildExit, _ requested: Bool) -> Void
    ) throws -> ChildProcess {
        let pid = try spawnProcess(launch, logPath: logURL.path)
        let child = ChildProcess(pid: pid, queue: queue, onExit: onExit)
        queue.async { child.watch(treeRefreshInterval: treeRefreshInterval) }
        return child
    }

    /// Starts `launch` in its own session, with output appended to `logURL`, and leaves it alone: it outlives the
    /// app. Used for the update helper, which swaps the app after it quits.
    @discardableResult
    public static func spawnDetached(_ launch: ChildLaunch, logURL: URL) throws -> pid_t {
        try spawnProcess(launch, logPath: logURL.path, detached: true)
    }

    private init(pid: pid_t, queue: DispatchQueue, onExit: @escaping (ChildExit, Bool) -> Void) {
        self.pid = pid
        self.queue = queue
        self.onExit = onExit
    }

    /// Sends SIGTERM to the process group now, and SIGKILL if it is still running after `timeout` seconds.
    public func stop(timeout: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning, !stopRequested else { return }
        stopRequested = true

        refreshDescendants()
        kill(-pid, SIGTERM)

        let escalate = DispatchWorkItem { [self] in
            guard isRunning else { return }
            refreshDescendants()
            kill(-pid, SIGKILL)
        }
        killTimer = escalate
        queue.asyncAfter(deadline: .now() + timeout, execute: escalate)
    }

    private func watch(treeRefreshInterval: TimeInterval) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in handleExit() }
        exitSource = source
        source.resume()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: treeRefreshInterval)
        timer.setEventHandler { [self] in refreshDescendants() }
        treeTimer = timer
        timer.resume()

        // The process may have exited before the source was watching it.
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
            handleExit()
        }
    }

    private func refreshDescendants() {
        let table = ProcessTree.snapshot()
        guard !table.isEmpty else { return }
        descendants = ProcessTree.descendants(of: pid, in: table)
    }

    private func handleExit() {
        guard isRunning else { return }
        isRunning = false
        exitSource?.cancel()
        treeTimer?.cancel()
        killTimer?.cancel()

        // The exited process is a zombie until reaped, so its pid can't be reused as a group id yet.
        kill(-pid, SIGKILL)
        for process in ProcessTree.survivors(of: descendants, in: ProcessTree.snapshot()) {
            if process.groupID == process.pid { kill(-process.pid, SIGKILL) }
            kill(process.pid, SIGKILL)
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        onExit(ChildExit(waitStatus: status), stopRequested)
    }

    private static func spawnProcess(_ launch: ChildLaunch, logPath: String, detached: Bool = false) throws -> pid_t {
        let logFD = open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard logFD >= 0 else { throw SpawnError(code: errno, step: "open log") }
        defer { close(logFD) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid = pid), or own session when detached, default signal handling, nothing blocked,
        // and no inherited descriptors.
        let group = detached ? POSIX_SPAWN_SETSID : POSIX_SPAWN_SETPGROUP
        let flags = group | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, launch.workingDirectory)

        let argv = [launch.executable] + launch.arguments
        let envp = launch.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let result = withCStringArray(argv) { argv in
            withCStringArray(envp) { envp in
                posix_spawn(&pid, launch.executable, &actions, &attributes, argv, envp)
            }
        }
        guard result == 0 else { throw SpawnError(code: result, step: "posix_spawn") }
        return pid
    }
}

/// Calls `body` with a NULL-terminated C array of copies of `strings`, freed afterwards.
private func withCStringArray<Result>(
    _ strings: [String],
    _ body: ([UnsafeMutablePointer<CChar>?]) -> Result
) -> Result {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}

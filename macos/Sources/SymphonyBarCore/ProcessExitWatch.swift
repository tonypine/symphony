import Darwin
import Dispatch

/// Calls `onExit` on `queue`, once, when a child process of the app exits, and reaps it.
///
/// The app watches the update helper with it: the helper outlives the app when the update goes through, so its exit
/// while the app still runs means the update didn't apply (TP-1475).
public final class ProcessExitWatch {
    public let pid: pid_t
    private let queue: DispatchQueue
    private let onExit: (ChildExit) -> Void
    private var source: DispatchSourceProcess?
    private var done = false

    public init(pid: pid_t, queue: DispatchQueue, onExit: @escaping (ChildExit) -> Void) {
        self.pid = pid
        self.queue = queue
        self.onExit = onExit
        queue.async { [self] in watch() }
    }

    /// Stops watching; `onExit` isn't called after this returns on `queue`.
    public func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        done = true
        source?.cancel()
    }

    private func watch() {
        guard !done else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in handleExit() }
        self.source = source
        source.resume()
        // The process may have exited before the source was watching it.
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
            handleExit()
        }
    }

    private func handleExit() {
        guard !done else { return }
        done = true
        source?.cancel()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        onExit(ChildExit(waitStatus: status))
    }
}

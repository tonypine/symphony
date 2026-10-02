import Darwin

/// One row of the system process table.
public struct ProcessRecord: Equatable, Hashable {
    public var pid: pid_t
    public var parentPID: pid_t
    public var groupID: pid_t
    /// Start time in microseconds since the epoch. Together with the pid it names one process, even after pid reuse.
    public var startTime: UInt64

    public init(pid: pid_t, parentPID: pid_t, groupID: pid_t, startTime: UInt64) {
        self.pid = pid
        self.parentPID = parentPID
        self.groupID = groupID
        self.startTime = startTime
    }
}

/// Reads the process table and finds a process's descendants.
///
/// Erlang starts port programs (the agent CLIs) in their own session, so signalling Symphony's process group
/// doesn't reach them. Recording the tree while Symphony runs lets the app clean them up after it exits.
public enum ProcessTree {
    /// Every process visible to this user, or an empty list when the table can't be read.
    public static func snapshot() -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }

        // Leave room for processes started between the two calls.
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return [] }

        return processes.prefix(size / stride).map { info in
            let started = info.kp_proc.p_un.__p_starttime
            return ProcessRecord(
                pid: info.kp_proc.p_pid,
                parentPID: info.kp_eproc.e_ppid,
                groupID: info.kp_eproc.e_pgid,
                startTime: UInt64(started.tv_sec) * 1_000_000 + UInt64(started.tv_usec)
            )
        }
    }

    /// All processes below `root` in `table`, children before grandchildren. `root` itself is not included.
    public static func descendants(of root: pid_t, in table: [ProcessRecord]) -> [ProcessRecord] {
        var children: [pid_t: [ProcessRecord]] = [:]
        for record in table where record.pid != record.parentPID {
            children[record.parentPID, default: []].append(record)
        }

        var found: [ProcessRecord] = []
        var seen: Set<pid_t> = [root]
        var queue = [root]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in children[parent] ?? [] where seen.insert(child.pid).inserted {
                found.append(child)
                queue.append(child.pid)
            }
        }
        return found
    }

    /// The recorded processes that are still running as the same process (same pid and start time).
    public static func survivors(of recorded: [ProcessRecord], in table: [ProcessRecord]) -> [ProcessRecord] {
        let current = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return recorded.filter { record in current[record.pid]?.startTime == record.startTime }
    }
}

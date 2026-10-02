/// How the Symphony process ended.
public enum ChildExit: Equatable {
    case exited(Int32)
    case signaled(Int32)

    /// Decodes a `waitpid` status (the `WIFEXITED` / `WTERMSIG` macros aren't available in Swift).
    public init(waitStatus status: Int32) {
        let signal = status & 0x7f
        if signal == 0 {
            self = .exited((status >> 8) & 0xff)
        } else {
            self = .signaled(signal)
        }
    }

    /// For example "exited with status 1" or "was killed by signal 9".
    public var summary: String {
        switch self {
        case .exited(let code):
            return "exited with status \(code)"
        case .signaled(let signal):
            return "was killed by signal \(signal)"
        }
    }
}

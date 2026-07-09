import Darwin
import Foundation

/// Finds Bash tool shells still running under a session's Claude process.
///
/// Background shells (`run_in_background`) fire no hook events, so the only
/// way to know one is running is the process table: every Bash tool command
/// runs wrapped in a shell that sources `~/.claude/shell-snapshots/snapshot-*`
/// — a signature no user process carries. Only *direct children* of a
/// session's recorded pid are considered, so shells orphaned to launchd
/// (their session died) are naturally excluded.
enum ShellScanner {
    static let signature = ".claude/shell-snapshots/snapshot-"

    /// Extracted commands of signature shells running directly under `pid`.
    static func runningShells(childrenOf pid: Int) -> [String] {
        processSnapshot()
            .filter { $0.ppid == pid_t(pid) }
            .sorted { $0.pid < $1.pid }
            .compactMap { argv(of: $0.pid) }
            .filter { $0.contains(signature) }
            .map { command(fromArgv: $0) }
    }

    /// The user-visible command inside the harness wrapper: the `eval '…'`
    /// argument, with shell quote-escaping undone. Unrecognized shapes come
    /// back unchanged rather than hiding a running shell.
    static func command(fromArgv argv: String) -> String {
        guard let start = argv.range(of: "eval '") else { return argv }
        var rest = String(argv[start.upperBound...])
        // The wrapper appends "< /dev/null" (background shells) and/or
        // "&& pwd -P >| …" after the closing quote.
        if let end = rest.range(of: "' < /dev/null", options: .backwards)
            ?? rest.range(of: "' && pwd -P", options: .backwards) {
            rest = String(rest[..<end.lowerBound])
        } else if rest.hasSuffix("'") {
            rest = String(rest.dropLast())
        }
        return rest.replacingOccurrences(of: "'\\''", with: "'")
    }

    // MARK: - Process table

    private static func processSnapshot() -> [(pid: pid_t, ppid: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Headroom for processes spawned between the two calls.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
    }

    /// Full argument list of a process as one space-joined string, or nil if
    /// it exited or belongs to another user. KERN_PROCARGS2 lays out
    /// argc, the exec path, then NUL-separated argv — NULs become spaces,
    /// which is fine for signature matching and eval extraction.
    private static func argv(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let joined = buf[4..<size].map { $0 == 0 ? UInt8(ascii: " ") : $0 }
        return String(decoding: joined, as: UTF8.self)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

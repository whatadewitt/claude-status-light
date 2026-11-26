import Foundation
import Testing
@testable import ClaudeStatusLight

struct ShellScannerTests {
    // MARK: - Command extraction from the harness wrapper argv

    @Test func extractsEvalCommand() {
        let argv = "/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-123.sh 2>/dev/null || true "
            + "&& setopt NO_EXTENDED_GLOB 2>/dev/null || true "
            + "&& eval 'uv run python feature_engineering/batch_features.py --start-date 2022-01-01' "
            + "&& pwd -P >| /tmp/claude-4b51-cwd"
        #expect(ShellScanner.command(fromArgv: argv)
                == "uv run python feature_engineering/batch_features.py --start-date 2022-01-01")
    }

    @Test func unescapesSingleQuotes() {
        let argv = "/bin/zsh -c source /x/.claude/shell-snapshots/snapshot-zsh-1.sh "
            + "&& eval 'echo '\\''hi there'\\''' && pwd -P >| /tmp/claude-1-cwd"
        #expect(ShellScanner.command(fromArgv: argv) == "echo 'hi there'")
    }

    @Test func cutsAtStdinRedirectTerminator() {
        // Background shells get their stdin detached after the eval argument.
        let argv = "/bin/zsh -c source /x/.claude/shell-snapshots/snapshot-zsh-2.sh 2>/dev/null || true "
            + "&& eval 'sleep 240 && echo demo-done' < /dev/null && pwd -P >| /tmp/claude-9-cwd"
        #expect(ShellScanner.command(fromArgv: argv) == "sleep 240 && echo demo-done")
    }

    @Test func fallsBackToRawArgvWithoutEval() {
        let argv = "/bin/zsh -c do_thing --flag"
        #expect(ShellScanner.command(fromArgv: argv) == argv)
    }

    // MARK: - KERN_PROCARGS2 decoding

    /// A KERN_PROCARGS2 buffer as the kernel lays it out: argc, exec path,
    /// NUL padding, argv, then the environment and Apple strings.
    private func procArgs2(execPath: String, argv: [String], trailing: [String]) -> ArraySlice<UInt8> {
        var buf = withUnsafeBytes(of: Int32(argv.count)) { Array($0) }
        buf += Array(execPath.utf8) + [0, 0, 0, 0]
        for s in argv + trailing { buf += Array(s.utf8) + [0] }
        return buf[...]
    }

    @Test func procArgsStopsAtArgcIgnoringEnvironment() {
        // GitHub's macOS runners expose the child's environment and Apple
        // strings after argv; they must not end up in the command.
        let buf = procArgs2(
            execPath: "/bin/zsh",
            argv: ["/bin/zsh", "-c", "true /Users/x/.claude/shell-snapshots/snapshot-zsh-test.sh && eval 'sleep 30'"],
            trailing: ["RUNNER_NAME=GitHub Actions 1000000707", "SHELL=/bin/bash", "",
                       "executable_file=0x1a0100000d,0xfffffff000a8e28", "ptrauth_disabled=1"])
        let argv = ShellScanner.argv(fromProcArgs2: buf)
        #expect(argv == "/bin/zsh -c true /Users/x/.claude/shell-snapshots/snapshot-zsh-test.sh && eval 'sleep 30'")
        #expect(ShellScanner.command(fromArgv: argv ?? "") == "sleep 30")
    }

    @Test func procArgsWithoutEnvironment() {
        let buf = procArgs2(execPath: "/bin/sleep", argv: ["sleep", "30"], trailing: [])
        #expect(ShellScanner.argv(fromProcArgs2: buf) == "sleep 30")
    }

    @Test func procArgsRejectsTruncatedBuffer() {
        #expect(ShellScanner.argv(fromProcArgs2: [1, 0][...]) == nil)
    }

    // MARK: - Live process scan

    @Test func findsSignatureChildAndIgnoresOthers() throws {
        // A real child carrying the wrapper signature in its argv…
        let marked = Process()
        marked.executableURL = URL(fileURLWithPath: "/bin/zsh")
        marked.arguments = ["-c", "true /Users/x/.claude/shell-snapshots/snapshot-zsh-test.sh && eval 'sleep 30'"]
        try marked.run()
        defer { marked.terminate() }
        // …and one without it.
        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: "/bin/sleep")
        plain.arguments = ["30"]
        try plain.run()
        defer { plain.terminate() }

        let shells = ShellScanner.runningShells(childrenOf: Int(ProcessInfo.processInfo.processIdentifier))
        #expect(shells == ["sleep 30"])
    }

    @Test func noChildrenMeansNoShells() {
        // A pid with no children at all: a fresh short-lived process's own pid
        // can't be probed safely, so use pid of /bin/sleep we just started.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try? proc.run()
        defer { proc.terminate() }
        #expect(ShellScanner.runningShells(childrenOf: Int(proc.processIdentifier)).isEmpty)
    }
}

import Foundation
import Testing
@testable import ClaudeStatusLight

struct ContextUsageTests {
    /// One transcript line in the shape Claude Code writes for an assistant
    /// message (only the fields extraction looks at).
    private func line(
        input: Int, cacheCreate: Int = 0, cacheRead: Int = 0, output: Int = 0,
        model: String = "claude-opus-4-5", sidechain: Bool = false
    ) -> String {
        "{\"type\":\"assistant\",\"isSidechain\":\(sidechain),"
            + "\"message\":{\"model\":\"\(model)\",\"usage\":{"
            + "\"input_tokens\":\(input),"
            + "\"cache_creation_input_tokens\":\(cacheCreate),"
            + "\"cache_read_input_tokens\":\(cacheRead),"
            + "\"output_tokens\":\(output)}}}"
    }

    // MARK: - Extraction

    @Test func newestMainChainMessageWins() {
        let tail = [line(input: 100), line(input: 4, cacheRead: 50_000, output: 96)]
            .joined(separator: "\n")
        #expect(StateStore.extractUsage(from: tail) == ContextUsage(tokens: 50_100, limit: 200_000))
    }

    @Test func allFourTokenBucketsAreSummed() {
        let tail = line(input: 10, cacheCreate: 20, cacheRead: 30, output: 40)
        #expect(StateStore.extractUsage(from: tail)?.tokens == 100)
    }

    @Test func sidechainMessagesAreSkipped() {
        // The subagent's window is not the session's window.
        let tail = [line(input: 80_000), line(input: 500, sidechain: true)]
            .joined(separator: "\n")
        #expect(StateStore.extractUsage(from: tail)?.tokens == 80_000)
    }

    @Test func truncatedFirstLineIsSkipped() {
        // The tail window can cut the oldest line mid-object; it must not
        // shadow a complete line below it.
        let tail = "okens\":12,\"usage\":{\"input_tokens\":9}}\n" + line(input: 42)
        #expect(StateStore.extractUsage(from: tail)?.tokens == 42)
    }

    @Test func zeroUsageEntriesAreSkipped() {
        let tail = [line(input: 1_000), line(input: 0, model: "<synthetic>")]
            .joined(separator: "\n")
        #expect(StateStore.extractUsage(from: tail)?.tokens == 1_000)
    }

    @Test func transcriptWithoutUsageYieldsNil() {
        #expect(StateStore.extractUsage(from: "{\"type\":\"user\"}\n{\"type\":\"summary\"}") == nil)
    }

    @Test func longContextModelsGetTheBiggerWindow() {
        let usage = StateStore.extractUsage(from: line(input: 300_000, model: "claude-sonnet-4-5[1m]"))
        #expect(usage == ContextUsage(tokens: 300_000, limit: 1_000_000))
    }

    // MARK: - Formatting

    @Test func percentSuffixAndDetailFormatting() {
        let usage = ContextUsage(tokens: 124_400, limit: 200_000)
        #expect(usage.percent == 62)
        #expect(usage.detail == "context: 124k / 200k tokens (62%)")

        var session = SessionState(
            sessionID: "s", state: .working, cwd: "/p/proj", termProgram: "t", tty: "",
            pid: 1, updatedAt: Date(), agents: 0, title: nil, shells: []
        )
        #expect(session.usageSuffix.isEmpty)
        session.contextUsage = usage
        #expect(session.usageSuffix == " · 62% ctx")
        #expect(session.tooltip.contains("context: 124k / 200k tokens (62%)"))
    }

    @Test func percentIsClampedTo100() {
        #expect(ContextUsage(tokens: 250_000, limit: 200_000).percent == 100)
    }

    // MARK: - End to end through the store

    @Test func activeSessionsCarryTranscriptUsage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let transcript = dir.appendingPathComponent("transcript.jsonl")
        try Data((line(input: 4, cacheRead: 99_996) + "\n").utf8).write(to: transcript)

        let now = Int(Date().timeIntervalSince1970)
        let session = "{\"state\":\"idle\",\"session_id\":\"s1\",\"cwd\":\"/p/proj\","
            + "\"transcript_path\":\"\(transcript.path)\",\"updated_at\":\(now)}"
        try Data(session.utf8).write(to: dir.appendingPathComponent("s1.json"))

        let store = StateStore(sessionsDir: dir, shellsForPid: { _ in [] })
        let sessions = store.activeSessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.contextUsage == ContextUsage(tokens: 100_000, limit: 200_000))
    }

    // MARK: - Wire

    @Test func wireRoundTripCarriesUsage() throws {
        var session = SessionState(
            sessionID: "s", state: .working, cwd: "/p/proj", termProgram: "t", tty: "/dev/ttys001",
            pid: 1, updatedAt: Date(timeIntervalSince1970: 1_000), agents: 0, title: nil, shells: []
        )
        session.contextUsage = ContextUsage(tokens: 50_000, limit: 200_000)

        let data = try JSONEncoder().encode(WireSession(from: session))
        let decoded = try JSONDecoder().decode(WireSession.self, from: data)
        let remote = try #require(decoded.sessionState(origin: "mini"))
        #expect(remote.contextUsage == ContextUsage(tokens: 50_000, limit: 200_000))
    }

    @Test func oldWireSessionsWithoutUsageDecodeAsNil() throws {
        let json = #"{"session_id":"s1","state":"working","cwd":"/p","term_program":"t","tty":"","updated_at":1000,"agents":0,"shells":[],"background":false}"#
        let decoded = try JSONDecoder().decode(WireSession.self, from: Data(json.utf8))
        #expect(decoded.sessionState(origin: "mini")?.contextUsage == nil)
    }
}

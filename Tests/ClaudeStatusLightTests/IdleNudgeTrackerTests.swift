import Foundation
import Testing
@testable import ClaudeStatusLight

struct IdleNudgeTrackerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let threshold: TimeInterval = 240

    private func session(
        _ id: String = "s1", _ state: LightState = .idle,
        tty: String = "/dev/ttys001", pid: Int? = 42,
        origin: String? = nil, updatedAt: Date? = nil
    ) -> SessionState {
        SessionState(
            sessionID: id, state: state, cwd: "/p/proj", termProgram: "iTerm.app",
            tty: tty, pid: pid, updatedAt: updatedAt ?? t0, agents: 0, title: nil,
            shells: [], origin: origin
        )
    }

    /// Start watching with `initial` already on screen, then return the tracker.
    private func primed(_ initial: [SessionState] = []) -> IdleNudgeTracker {
        var tracker = IdleNudgeTracker()
        _ = tracker.update(initial, now: t0, enabled: true, threshold: threshold)
        return tracker
    }

    @Test func nudgesOnceAfterThresholdForANewEpisode() {
        var tracker = primed()
        let working = session("s1", .working)
        _ = tracker.update([working], now: t0, enabled: true, threshold: threshold)
        let idle = session("s1", .idle)
        #expect(tracker.update([idle], now: t0 + 10, enabled: true, threshold: threshold).isEmpty)
        #expect(tracker.update([idle], now: t0 + 249, enabled: true, threshold: threshold).isEmpty)
        #expect(tracker.update([idle], now: t0 + 250, enabled: true, threshold: threshold).map(\.sessionID) == ["s1"])
        #expect(tracker.update([idle], now: t0 + 900, enabled: true, threshold: threshold).isEmpty)
    }

    @Test func rearmsAfterGoingBackToWork() {
        var tracker = primed()
        _ = tracker.update([session("s1", .attention)], now: t0, enabled: true, threshold: threshold)
        #expect(tracker.update([session("s1", .attention)], now: t0 + 240, enabled: true, threshold: threshold).count == 1)
        _ = tracker.update([session("s1", .working)], now: t0 + 300, enabled: true, threshold: threshold)
        _ = tracker.update([session("s1", .idle)], now: t0 + 400, enabled: true, threshold: threshold)
        #expect(tracker.update([session("s1", .idle)], now: t0 + 640, enabled: true, threshold: threshold).count == 1)
    }

    @Test func remoteSessionsNeverNudge() {
        var tracker = primed()
        let remote = session("r1", .idle, origin: "mini")
        _ = tracker.update([remote], now: t0, enabled: true, threshold: threshold)
        #expect(tracker.update([remote], now: t0 + 1_000, enabled: true, threshold: threshold).isEmpty)
    }

    @Test func backgroundSessionsNeverNudge() {
        var tracker = primed()
        let bg = session("b1", .idle, tty: "", pid: 99)
        _ = tracker.update([bg], now: t0, enabled: true, threshold: threshold)
        #expect(tracker.update([bg], now: t0 + 1_000, enabled: true, threshold: threshold).isEmpty)
    }

    @Test func sessionsAlreadyWaitingWhenWatchingStartsAreNotNudged() {
        // Long-idle sessions at launch (or when the setting is switched on)
        // shouldn't produce a burst of banners.
        var tracker = IdleNudgeTracker()
        let old = session("s1", .idle, updatedAt: t0 - 3_600)
        #expect(tracker.update([old], now: t0, enabled: true, threshold: threshold).isEmpty)
        #expect(tracker.update([old], now: t0 + 1_000, enabled: true, threshold: threshold).isEmpty)
        // …but its next episode does nudge.
        _ = tracker.update([session("s1", .working)], now: t0 + 1_100, enabled: true, threshold: threshold)
        _ = tracker.update([session("s1", .idle)], now: t0 + 1_200, enabled: true, threshold: threshold)
        #expect(tracker.update([session("s1", .idle)], now: t0 + 1_440, enabled: true, threshold: threshold).count == 1)
    }

    @Test func reEnablingDoesNotNudgeSessionsAlreadyWaiting() {
        var tracker = primed()
        _ = tracker.update([session("s1", .working)], now: t0, enabled: true, threshold: threshold)
        _ = tracker.update([session("s1", .idle)], now: t0 + 10, enabled: false, threshold: threshold)
        _ = tracker.update([session("s1", .idle)], now: t0 + 20, enabled: true, threshold: threshold)
        #expect(tracker.update([session("s1", .idle)], now: t0 + 1_000, enabled: true, threshold: threshold).isEmpty)
    }

    @Test func disabledNeverNudges() {
        var tracker = IdleNudgeTracker()
        _ = tracker.update([session("s1", .working)], now: t0, enabled: false, threshold: threshold)
        _ = tracker.update([session("s1", .idle)], now: t0 + 10, enabled: false, threshold: threshold)
        #expect(tracker.update([session("s1", .idle)], now: t0 + 1_000, enabled: false, threshold: threshold).isEmpty)
    }

    @Test func sessionAppearingIdleAfterWatchingStartsDoesNudge() {
        // A brand-new session whose first hook event is already "idle".
        var tracker = primed()
        _ = tracker.update([session("new", .idle)], now: t0 + 5, enabled: true, threshold: threshold)
        #expect(tracker.update([session("new", .idle)], now: t0 + 245, enabled: true, threshold: threshold).count == 1)
    }
}

import Foundation
import ResumeKit

// MARK: - Fake transport
//
// In a real app, `SessionTransport` wraps your actual WebSocket client
// (URLSessionWebSocketTask, Starscream, NWConnection, gRPC bidi, ...).
// For this demo we fake it in-process: `sendHandshake` / `sendHeartbeat`
// log what the coordinator asks us to do, and a mock "server" spawns
// a Task to feed replies back into the coordinator with realistic
// timing and a realistic scripted replay.
final class MockTransport: SessionTransport, @unchecked Sendable {
    // Weak back-reference so the mock server can push events into the
    // coordinator. Real transports don't need this — the WS receive
    // loop is the one feeding events in.
    weak var coordinator: SessionCoordinator?

    func sendHandshake(_ request: HandshakeRequest) async throws {
        print("  → \(describe(request))")
        // Simulate server round-trip + reply.
        Task { [weak coordinator] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let coordinator else { return }

            switch request.kind {
            case .identify:
                print("  ← Hello(heartbeatInterval: 30s), Ready(sessionId: demo-session-1, initialSeq: 0)")
                await coordinator.didReceive(.hello(heartbeatInterval: 30))
                await coordinator.didReceive(.ready(sessionId: "demo-session-1", initialSeq: 0))

            case .resume(_, let lastSeq):
                // Pretend the server buffered 2 events while we were offline.
                print("  ← Resumed(replayedCount: 2, currentSeq: \(lastSeq + 2))")
                await coordinator.didReceive(.resumed(
                    replayedCount: 2,
                    currentSeq: lastSeq + 2
                ))
                try? await Task.sleep(nanoseconds: 80_000_000)
                print("  ← PushEvent(seq: \(lastSeq + 1)) [replay]")
                await coordinator.didReceive(.pushEvent(seq: lastSeq + 1))
                try? await Task.sleep(nanoseconds: 80_000_000)
                print("  ← PushEvent(seq: \(lastSeq + 2)) [replay]")
                await coordinator.didReceive(.pushEvent(seq: lastSeq + 2))
            }
        }
    }

    func sendHeartbeat(_ request: HeartbeatRequest) async throws {
        print("  → Heartbeat(lastSeq: \(request.lastSeq))")
    }

    private func describe(_ request: HandshakeRequest) -> String {
        switch request.kind {
        case .identify(let props):
            return "Identify(platform: \(props.platform), device: \(props.deviceName))"
        case .resume(let sessionId, let lastSeq):
            return "Resume(sessionId: \(sessionId), lastSeq: \(lastSeq))"
        }
    }
}

// MARK: - Entry point

@main
struct BasicDemo {
    static func main() async {
        print("======================================================")
        print(" ResumeKit — BasicDemo")
        print(" Drives the coordinator through three common scenarios")
        print(" against a mocked in-process server.")
        print("======================================================\n")

        let transport = MockTransport()

        // Keep session storage in-memory so re-runs start fresh. In a
        // real app this would be a Keychain-backed implementation; see
        // the README section "Implement SessionStorage (use the Keychain)".
        let storage = InMemorySessionStorage()

        let coordinator = SessionCoordinator(
            transport: transport,
            storage: storage,
            token: { "demo-jwt-token" },
            clientProperties: ClientProperties(
                platform: "demo",
                appVersion: "0.1.0",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceName: ProcessInfo.processInfo.hostName,
                deviceId: "demo-device-id"
            ),
            configuration: {
                // Disable heartbeat so demo output doesn't get noisy.
                // Real apps leave it enabled.
                var c = SessionCoordinator.Configuration()
                c.autoHeartbeat = false
                return c
            }()
        )
        transport.coordinator = coordinator

        // Subscribe to high-level events. In a real app this is where
        // you'd toggle notification-suppression during replay, update
        // debug UI, or hook logout on session invalidation.
        let eventsTask = Task {
            for await event in await coordinator.events {
                print("  ▶ \(format(event: event))")
            }
        }

        // ─────────────────────────────────────────────────────────
        // Scenario 1 — fresh connect. No stored session → Identify.
        // ─────────────────────────────────────────────────────────
        print("━━━ Scenario 1: fresh connect (Identify) ━━━")
        await coordinator.connectionDidOpen()
        try? await Task.sleep(nanoseconds: 350_000_000)

        // Pretend some real-time events arrive while we're live.
        print("\n  simulating 3 incoming push events...")
        await coordinator.didReceive(.pushEvent(seq: 1))
        await coordinator.didReceive(.pushEvent(seq: 2))
        await coordinator.didReceive(.pushEvent(seq: 3))
        try? await Task.sleep(nanoseconds: 100_000_000)

        if let snap = await coordinator.currentSnapshot() {
            print("  cursor now at sessionId=\(snap.sessionId) lastSeq=\(snap.lastSeq)\n")
        }

        // ─────────────────────────────────────────────────────────
        // Scenario 2 — drop connection, come back, Resume replays.
        // ─────────────────────────────────────────────────────────
        print("━━━ Scenario 2: disconnect → reconnect (Resume + replay) ━━━")
        await coordinator.connectionDidClose(error: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await coordinator.connectionDidOpen()
        try? await Task.sleep(nanoseconds: 500_000_000)

        if let snap = await coordinator.currentSnapshot() {
            print("  cursor now at sessionId=\(snap.sessionId) lastSeq=\(snap.lastSeq)\n")
        }

        // ─────────────────────────────────────────────────────────
        // Scenario 3 — user logs out. Next connect Identifies fresh.
        // ─────────────────────────────────────────────────────────
        print("━━━ Scenario 3: logout ━━━")
        await coordinator.clearSession()
        try? await Task.sleep(nanoseconds: 50_000_000)

        await coordinator.connectionDidOpen()
        try? await Task.sleep(nanoseconds: 350_000_000)

        print("\n━━━ done ━━━")
        eventsTask.cancel()
    }

    /// Pretty-print helper for CoordinatorEvent cases.
    private static func format(event: SessionEvent) -> String {
        switch event {
        case .stateChanged(let state):
            return "state → \(describe(state))"
        case .replayStarted:
            return "replayStarted — suppress notifications here"
        case .replayFinished(let n):
            return "replayFinished (replayed: \(n)) — re-enable notifications"
        case .sessionInvalidated(let reason, let resumable):
            return "sessionInvalidated reason=\(reason) resumable=\(resumable)"
        }
    }

    private static func describe(_ state: SessionState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .handshaking: return "handshaking"
        case .replaying(let exp, let recv): return "replaying(\(recv)/\(exp))"
        case .live(let sid): return "live(\(sid))"
        }
    }
}

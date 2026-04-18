import XCTest
@testable import ResumeKit

final class StateMachineTests: XCTestCase {

    // MARK: - Helpers

    /// Spin up a coordinator with a mock transport, fresh storage,
    /// and a static token. Heartbeat disabled by default so tests don't
    /// race the timer.
    private func makeCoordinator(
        storage: any SessionStorage = InMemorySessionStorage(),
        autoHeartbeat: Bool = false,
        token: String? = "test-token"
    ) -> (SessionCoordinator, MockTransport) {
        let transport = MockTransport()
        var config = SessionCoordinator.Configuration()
        config.autoHeartbeat = autoHeartbeat
        let coord = SessionCoordinator(
            transport: transport,
            storage: storage,
            token: { token },
            clientProperties: .testFixture,
            configuration: config
        )
        return (coord, transport)
    }

    // MARK: - First connect → Identify

    func testFirstConnectSendsIdentify() async {
        let (coord, transport) = makeCoordinator()
        await coord.connectionDidOpen()

        let frames = await transport.handshakes
        XCTAssertEqual(frames.count, 1)
        guard case .identify(let props) = frames[0].kind else {
            return XCTFail("expected .identify, got \(frames[0].kind)")
        }
        XCTAssertEqual(props.platform, "ios")
        XCTAssertEqual(frames[0].token, "test-token")

        let state = await coord.state
        XCTAssertEqual(state, .handshaking)
    }

    // MARK: - Subsequent connect → Resume

    func testReconnectWithStoredSnapshotSendsResume() async {
        let storage = InMemorySessionStorage(
            initial: SessionSnapshot(sessionId: "abc", lastSeq: 17)
        )
        let (coord, transport) = makeCoordinator(storage: storage)
        await coord.connectionDidOpen()

        let frames = await transport.handshakes
        XCTAssertEqual(frames.count, 1)
        guard case .resume(let sid, let seq) = frames[0].kind else {
            return XCTFail("expected .resume, got \(frames[0].kind)")
        }
        XCTAssertEqual(sid, "abc")
        XCTAssertEqual(seq, 17)
    }

    // MARK: - Ready → live

    func testReadyTransitionsToLive() async {
        let (coord, _) = makeCoordinator()
        await coord.connectionDidOpen()
        await coord.didReceive(.ready(sessionId: "new-session", initialSeq: 0))

        let state = await coord.state
        XCTAssertEqual(state, .live(sessionId: "new-session"))

        let snap = await coord.currentSnapshot()
        XCTAssertEqual(snap?.sessionId, "new-session")
        XCTAssertEqual(snap?.lastSeq, 0)
    }

    // MARK: - Resume → replay → live (with events)

    func testResumeReplaysAndTransitionsToLive() async {
        let storage = InMemorySessionStorage(
            initial: SessionSnapshot(sessionId: "abc", lastSeq: 10)
        )
        let (coord, _) = makeCoordinator(storage: storage)

        // Drain events into a buffer for assertions.
        let collector = EventCollector()
        let stream = await coord.events
        let task = Task { for await ev in stream { await collector.append(ev) } }

        await coord.connectionDidOpen()
        await coord.didReceive(.resumed(replayedCount: 3, currentSeq: 13))

        // Coordinator is in .replaying(expected: 3, received: 0). Push events
        // arrive one by one.
        await coord.didReceive(.pushEvent(seq: 11))
        var state = await coord.state
        XCTAssertEqual(state, .replaying(expected: 3, received: 1))

        await coord.didReceive(.pushEvent(seq: 12))
        state = await coord.state
        XCTAssertEqual(state, .replaying(expected: 3, received: 2))

        await coord.didReceive(.pushEvent(seq: 13))
        state = await coord.state
        XCTAssertEqual(state, .live(sessionId: "abc"))

        let snap = await coord.currentSnapshot()
        XCTAssertEqual(snap?.lastSeq, 13)

        // Allow the AsyncStream to deliver buffered events.
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let events = await collector.events
        XCTAssertTrue(events.contains { if case .replayStarted = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .replayFinished(let n) = $0, n == 3 { return true }; return false })
    }

    // MARK: - Empty replay shortcut

    func testEmptyResumeGoesStraightToLive() async {
        let storage = InMemorySessionStorage(
            initial: SessionSnapshot(sessionId: "abc", lastSeq: 10)
        )
        let (coord, _) = makeCoordinator(storage: storage)

        let collector = EventCollector()
        let stream = await coord.events
        let task = Task { for await ev in stream { await collector.append(ev) } }

        await coord.connectionDidOpen()
        await coord.didReceive(.resumed(replayedCount: 0, currentSeq: 10))

        let state = await coord.state
        XCTAssertEqual(state, .live(sessionId: "abc"))

        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let events = await collector.events
        // Both replayStarted and replayFinished(0) must fire so the consumer
        // can pair start/finish symmetrically.
        XCTAssertTrue(events.contains { if case .replayStarted = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .replayFinished(let n) = $0, n == 0 { return true }; return false })
    }

    // MARK: - InvalidSession

    func testInvalidSessionClearsStorageAndDisconnects() async {
        let storage = InMemorySessionStorage(
            initial: SessionSnapshot(sessionId: "abc", lastSeq: 5)
        )
        let (coord, _) = makeCoordinator(storage: storage)

        let collector = EventCollector()
        let stream = await coord.events
        let task = Task { for await ev in stream { await collector.append(ev) } }

        await coord.connectionDidOpen()
        await coord.didReceive(.invalidSession(reason: "session_timeout", resumable: false))

        let state = await coord.state
        XCTAssertEqual(state, .disconnected)

        let snap = await coord.currentSnapshot()
        XCTAssertNil(snap)

        let stillStored = await storage.load()
        XCTAssertNil(stillStored, "storage must be cleared on InvalidSession")

        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let events = await collector.events
        XCTAssertTrue(events.contains {
            if case .sessionInvalidated(let r, _) = $0, r == "session_timeout" { return true }
            return false
        })
    }

    // MARK: - clearSession (logout)

    func testClearSessionWipesStorageAndForcesIdentifyNextConnect() async {
        let storage = InMemorySessionStorage(
            initial: SessionSnapshot(sessionId: "abc", lastSeq: 5)
        )
        let (coord, transport) = makeCoordinator(storage: storage)

        await coord.clearSession()
        await coord.connectionDidOpen()

        let frames = await transport.handshakes
        guard case .identify = frames[0].kind else {
            return XCTFail("after clearSession, next connect must Identify")
        }
    }

    // MARK: - Disconnect resets state

    func testConnectionClosedResetsState() async {
        let (coord, _) = makeCoordinator()
        await coord.connectionDidOpen()
        await coord.didReceive(.ready(sessionId: "new", initialSeq: 0))

        var state = await coord.state
        XCTAssertEqual(state, .live(sessionId: "new"))

        await coord.connectionDidClose(error: nil)
        state = await coord.state
        XCTAssertEqual(state, .disconnected)
    }

    // MARK: - No token blocks handshake

    func testNoTokenSkipsHandshake() async {
        let (coord, transport) = makeCoordinator(token: nil)
        await coord.connectionDidOpen()

        let frames = await transport.handshakes
        XCTAssertEqual(frames.count, 0, "no handshake must be sent when token is nil")
        let state = await coord.state
        XCTAssertEqual(state, .disconnected)
    }

    // MARK: - lastSeq update on push events

    func testPushEventBumpsLastSeq() async {
        let (coord, _) = makeCoordinator()
        await coord.connectionDidOpen()
        await coord.didReceive(.ready(sessionId: "x", initialSeq: 0))

        await coord.didReceive(.pushEvent(seq: 5))
        await coord.didReceive(.pushEvent(seq: 6))
        await coord.didReceive(.pushEvent(seq: 7))

        let snap = await coord.currentSnapshot()
        XCTAssertEqual(snap?.lastSeq, 7)
    }
}

// MARK: - Helpers

actor EventCollector {
    var events: [SessionEvent] = []
    func append(_ e: SessionEvent) { events.append(e) }
}

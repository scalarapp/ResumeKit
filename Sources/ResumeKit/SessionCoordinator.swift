import Foundation

/// Discord-style session-resume client. Runs as an actor so callers don't
/// have to worry about thread-safety; you can poke it from your transport
/// task and from the main actor freely.
///
/// # Architecture
///
/// The coordinator owns three pieces of state:
///   1. The in-memory `state` (handshaking / replaying / live / disconnected).
///   2. A persistent `(sessionId, lastSeq)` cursor in `SessionStorage`.
///   3. A heartbeat timer that fires while the connection is healthy.
///
/// It does **not** own the connection itself — that's your transport's
/// problem. The coordinator just decides what to send when you tell it
/// "the connection is open" or "I received this frame".
///
/// # Lifecycle (the seven calls you'll make)
///
/// ```swift
/// // 1. On WebSocket connect:
/// await coordinator.connectionDidOpen()
///        // → coordinator decides Identify vs Resume from storage,
///        //   asks transport to send the chosen handshake frame.
///
/// // 2. On every incoming frame your decoder parses:
/// await coordinator.didReceive(.ready(sessionId: "abc", initialSeq: 0))
/// await coordinator.didReceive(.pushEvent(seq: 17))
/// await coordinator.didReceive(.heartbeatAck)
/// // ...
///
/// // 3. On WebSocket close:
/// await coordinator.connectionDidClose(error: someError)
///
/// // 4. On user logout:
/// await coordinator.clearSession()
/// ```
///
/// # Subscribing to events
///
/// ```swift
/// Task {
///   for await event in await coordinator.events {
///     switch event {
///     case .replayStarted:           muteNotifications()
///     case .replayFinished:          unmuteNotifications()
///     case .sessionInvalidated(let r, _):
///       Log.warn("session invalidated: \(r)")
///     case .stateChanged(let s):     Log.info("state → \(s)")
///     }
///   }
/// }
/// ```
public actor SessionCoordinator {
    // MARK: - Configuration

    /// Tuning knobs. Defaults match Discord Gateway's recommended values
    /// and work out of the box with most server implementations.
    public struct Configuration: Sendable {
        /// Fallback heartbeat cadence used until the server's `Hello`
        /// frame overrides it. 30 s matches Discord Gateway's recommended
        /// interval and is a safe default for most setups.
        public var defaultHeartbeatInterval: TimeInterval = 30
        /// Auto-start the heartbeat timer once we go `.live`. Set to false
        /// if your transport handles its own keep-alive (rare).
        public var autoHeartbeat: Bool = true

        public init() {}
    }

    // MARK: - Public state

    /// Current state machine value. Equatable so SwiftUI / Observation can
    /// diff cheaply.
    public private(set) var state: SessionState = .disconnected {
        didSet {
            guard oldValue != state else { return }
            yield(.stateChanged(state))
        }
    }

    /// Stream of high-level events for UI / notification suppression.
    /// Multiple consumers are allowed; each gets an independent stream.
    public var events: AsyncStream<SessionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            // onTermination is a @Sendable closure invoked off-actor when
            // the consumer task finishes or cancels. Rebind self strongly
            // via `guard let` so the Task captures a non-optional value —
            // Swift 5.10 strict concurrency on Linux rejects capturing the
            // weak binding directly through the Sendable boundary.
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id) }
            }
        }
    }

    // MARK: - Private state

    private let transport: any SessionTransport
    private let storage: any SessionStorage
    private let token: @Sendable () async -> String?
    private let clientProperties: ClientProperties
    private var configuration: Configuration

    /// Cached snapshot. Loaded lazily from storage; written through to
    /// storage on every change.
    private var snapshot: SessionSnapshot?
    /// `true` between sending a handshake and receiving Ready/Resumed/InvalidSession.
    private var handshakeInFlight: Bool = false
    /// Active heartbeat task, cancelled on disconnect.
    private var heartbeatTask: Task<Void, Never>?
    /// Subscribers to the `events` stream.
    private var continuations: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

    // MARK: - Init

    /// - Parameters:
    ///   - transport: object that owns your WebSocket / RPC stream and can
    ///     send opaque frames the coordinator constructs.
    ///   - storage: persistent store for the session cursor. Use the
    ///     `InMemorySessionStorage` default for tests; ship a Keychain-backed
    ///     implementation for production.
    ///   - token: async closure returning the current access token. Called
    ///     each time a handshake is sent so the coordinator never holds a
    ///     stale token across refreshes.
    ///   - clientProperties: identity sent in `Identify`. Static across the
    ///     app's lifetime.
    ///   - configuration: tuning knobs (heartbeat cadence, etc.).
    public init(
        transport: any SessionTransport,
        storage: any SessionStorage = InMemorySessionStorage(),
        token: @escaping @Sendable () async -> String?,
        clientProperties: ClientProperties,
        configuration: Configuration = Configuration()
    ) {
        self.transport = transport
        self.storage = storage
        self.token = token
        self.clientProperties = clientProperties
        self.configuration = configuration
    }

    // MARK: - Transport callbacks

    /// Tell the coordinator the underlying connection just opened. It
    /// decides Identify-vs-Resume from storage and asks the transport to
    /// send the chosen handshake frame.
    public func connectionDidOpen() async {
        // Belt-and-suspenders: a stray re-open without a prior close
        // shouldn't pile heartbeat tasks on top of each other.
        cancelHeartbeat()

        let stored = await storage.load()
        snapshot = stored

        guard let token = await token() else {
            // No auth → can't handshake. Caller must retry once tokens
            // become available. We leave state as `.disconnected`.
            return
        }

        let request: HandshakeRequest
        if let stored {
            request = HandshakeRequest(
                kind: .resume(sessionId: stored.sessionId, lastSeq: stored.lastSeq),
                token: token
            )
        } else {
            request = HandshakeRequest(
                kind: .identify(clientProperties),
                token: token
            )
        }

        state = .handshaking
        handshakeInFlight = true

        do {
            try await transport.sendHandshake(request)
        } catch {
            // Send failed — connection is probably already half-dead. The
            // transport will tell us via `connectionDidClose` when it
            // confirms; until then we sit in `.handshaking` so a
            // re-attempted open knows we never finished.
            handshakeInFlight = false
        }
    }

    /// Tell the coordinator the connection just closed. The error (if any)
    /// is informational — we always tear down the heartbeat and reset
    /// in-flight state regardless.
    public func connectionDidClose(error: (any Error)?) async {
        _ = error // reserved for future telemetry hook
        cancelHeartbeat()
        handshakeInFlight = false
        state = .disconnected
    }

    /// Hand off a parsed frame from the wire. The coordinator routes it to
    /// the right state-machine transition.
    public func didReceive(_ event: IncomingEvent) async {
        switch event {
        case .hello(let interval):
            // Server-supplied cadence overrides the configuration default.
            // Don't start the timer yet — wait until we're actually `.live`.
            if interval > 0 {
                configuration.defaultHeartbeatInterval = interval
            }

        case .ready(let sessionId, let initialSeq):
            // Fresh session created. Persist sessionId; lastSeq starts at
            // initialSeq because the server tells us "events with seq >
            // initialSeq are new", so initialSeq itself is the high-water
            // mark we've already implicitly acknowledged.
            await storage.save(sessionId: sessionId)
            if initialSeq > 0 {
                await storage.updateLastSeq(initialSeq)
            }
            snapshot = SessionSnapshot(sessionId: sessionId, lastSeq: initialSeq)
            handshakeInFlight = false
            state = .live(sessionId: sessionId)
            startHeartbeat()

        case .resumed(let replayed, let currentSeq):
            // The server is about to send `replayed` buffered events. We
            // enter `.replaying`; transitions to `.live` happen when we
            // see `replayed` push events (or immediately if replayed == 0).
            handshakeInFlight = false
            yield(.replayStarted)
            if replayed == 0 {
                // Empty replay — we're already at the head. Switch to
                // live straight away and tell consumers replay is done.
                if let sid = snapshot?.sessionId {
                    state = .live(sessionId: sid)
                }
                if currentSeq > 0 {
                    await storage.updateLastSeq(currentSeq)
                    if let sid = snapshot?.sessionId {
                        snapshot = SessionSnapshot(sessionId: sid, lastSeq: currentSeq)
                    }
                }
                yield(.replayFinished(replayedCount: 0))
                startHeartbeat()
            } else {
                state = .replaying(expected: replayed, received: 0)
            }

        case .invalidSession(let reason, let resumable):
            // Server told us "your cursor is too old / session expired /
            // wrong user". Clear storage and switch to a fresh-Identify
            // posture; the transport will trigger that on its next reconnect.
            await storage.clear()
            snapshot = nil
            handshakeInFlight = false
            cancelHeartbeat()
            state = .disconnected
            yield(.sessionInvalidated(reason: reason, resumable: resumable))

        case .heartbeatAck:
            // Currently informational — no zombie-detection in v1.
            break

        case .pushEvent(let seq):
            // Bump cursor unconditionally. If we're replaying, also count
            // toward the expected total.
            await storage.updateLastSeq(seq)
            if let sid = snapshot?.sessionId, seq > (snapshot?.lastSeq ?? 0) {
                snapshot = SessionSnapshot(sessionId: sid, lastSeq: seq)
            }
            if case .replaying(let expected, let received) = state {
                let next = received + 1
                if next >= expected {
                    yield(.replayFinished(replayedCount: expected))
                    if let sid = snapshot?.sessionId {
                        state = .live(sessionId: sid)
                    }
                    startHeartbeat()
                } else {
                    state = .replaying(expected: expected, received: next)
                }
            }
        }
    }

    // MARK: - User-facing actions

    /// Drop the persisted session. Call on logout. The next connect will
    /// Identify fresh.
    public func clearSession() async {
        await storage.clear()
        snapshot = nil
        cancelHeartbeat()
    }

    /// Read the cached cursor. Useful for diagnostic UI ("last sync seq:
    /// 1234"). Returns the in-memory copy without re-reading storage.
    public func currentSnapshot() -> SessionSnapshot? { snapshot }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard configuration.autoHeartbeat else { return }
        cancelHeartbeat()
        let interval = configuration.defaultHeartbeatInterval
        guard interval > 0 else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.tickHeartbeat()
            }
        }
    }

    private func cancelHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func tickHeartbeat() async {
        // Only send while we're actually connected — `.disconnected` /
        // `.handshaking` should not produce heartbeats. (Replaying is
        // borderline; we let it through so that a slow replay doesn't
        // make the server consider us dead.)
        switch state {
        case .live, .replaying:
            let lastSeq = snapshot?.lastSeq ?? 0
            try? await transport.sendHeartbeat(HeartbeatRequest(lastSeq: lastSeq))
        case .disconnected, .handshaking:
            break
        }
    }

    // MARK: - Event stream plumbing

    private func yield(_ event: SessionEvent) {
        for c in continuations.values {
            c.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

import Foundation

// MARK: - Public types

/// Persistent handle on a running server-side session.
///
/// The coordinator keeps one of these in `SessionStorage` between app launches
/// so that when the network comes back (or the user reopens the app) we can
/// send `Resume(sessionId, lastSeq)` instead of starting a fresh session.
public struct SessionSnapshot: Sendable, Codable, Equatable {
    /// Server-issued opaque identifier. Treat as a secret — pairs with the
    /// JWT access token to re-establish a session.
    public let sessionId: String
    /// The highest sequence number the client has successfully processed.
    /// The server will replay everything with `seq > lastSeq` on resume.
    public let lastSeq: UInt64

    public init(sessionId: String, lastSeq: UInt64) {
        self.sessionId = sessionId
        self.lastSeq = lastSeq
    }
}

/// Identity metadata attached to the initial `Identify` frame.
///
/// Your app should build one of these once at launch and hand it to the
/// coordinator. It's sent only on the first handshake of a session; resumes
/// carry only `(sessionId, lastSeq, token)`.
public struct ClientProperties: Sendable {
    public let platform: String
    public let appVersion: String
    public let osVersion: String
    public let deviceName: String
    public let deviceId: String

    public init(
        platform: String,
        appVersion: String,
        osVersion: String,
        deviceName: String,
        deviceId: String
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.deviceName = deviceName
        self.deviceId = deviceId
    }
}

/// A frame the coordinator asks the transport to send when opening a
/// connection. Your transport turns it into whatever wire format you use
/// (protobuf, JSON, MessagePack…).
public struct HandshakeRequest: Sendable {
    public enum Kind: Sendable {
        /// First connect — the server will create a fresh session and reply
        /// with `Ready { sessionId, initialSeq }`.
        case identify(ClientProperties)
        /// Reconnect — the server will try to replay everything with
        /// `seq > lastSeq`. Reply is `Resumed` on success or `InvalidSession`
        /// if the session expired / seq is out of range.
        case resume(sessionId: String, lastSeq: UInt64)
    }

    public let kind: Kind
    /// Whatever your auth system uses — JWT, opaque bearer, etc. Rolled into
    /// the same frame so the server can validate in one step.
    public let token: String
}

/// Keep-alive frame the coordinator asks the transport to send periodically
/// while the connection is in `.live`. The server's `InvalidSession` reply
/// means "you missed too many — Identify fresh".
public struct HeartbeatRequest: Sendable {
    public let lastSeq: UInt64

    public init(lastSeq: UInt64) {
        self.lastSeq = lastSeq
    }
}

/// Incoming events the transport feeds back to the coordinator.
///
/// This enum is transport-agnostic — your WebSocket / gRPC / TCP layer
/// decodes raw bytes into one of these cases, then calls
/// `coordinator.didReceive(_:)`.
public enum IncomingEvent: Sendable {
    /// The server's first frame after WebSocket upgrade. Tells the client
    /// how often to heartbeat. If you don't implement Hello on the server,
    /// skip this and rely on the coordinator's default interval.
    case hello(heartbeatInterval: TimeInterval)

    /// Response to `Identify` — a new session has been created.
    case ready(sessionId: String, initialSeq: UInt64)

    /// Response to `Resume` — replay is about to begin. The coordinator
    /// transitions to `.replaying`; buffered events with `seq > lastSeq`
    /// arrive as `.pushEvent` in order. When the replay finishes the
    /// server sends `Resumed` — or, if the replay is empty, `Resumed`
    /// arrives immediately after this event.
    case resumed(replayedCount: UInt64, currentSeq: UInt64)

    /// Server rejected the handshake (session expired, seq invalid, etc.).
    /// Coordinator clears stored session and surfaces `.sessionInvalidated`.
    /// Your app should drop to a fresh `Identify` next connect.
    case invalidSession(reason: String, resumable: Bool)

    /// Keep-alive reply. Resets the coordinator's heartbeat-miss counter.
    case heartbeatAck

    /// Any business-level push event carrying a server-assigned `seq`.
    /// The coordinator uses this only to track `lastSeq`; your app does
    /// the actual work of decoding the payload.
    case pushEvent(seq: UInt64)
}

/// High-level state changes the coordinator emits through its `events`
/// stream so your UI / notification layer can react.
public enum SessionEvent: Sendable {
    /// State machine transitioned. Useful for debug overlays or reconnect
    /// spinners.
    case stateChanged(SessionState)

    /// Resume handshake succeeded and buffered events are about to flow.
    /// **Your notification layer should suppress alerts between here and
    /// `.replayFinished`** — replayed messages were already push-notified
    /// while the app was offline, so re-alerting is duplicate spam.
    case replayStarted

    /// All buffered events delivered. Switch notifications back on.
    /// `replayedCount` is the server's count of what it sent; the actual
    /// number of `.pushEvent` frames should match.
    case replayFinished(replayedCount: UInt64)

    /// Server said the session can't be resumed. Storage has been cleared,
    /// next connect will Identify fresh. Show a spinner; don't log the
    /// user out unless reason indicates auth failure.
    case sessionInvalidated(reason: String, resumable: Bool)
}

/// Current state of the handshake / session.
public enum SessionState: Sendable, Equatable {
    /// No active connection attempt. This is the state before
    /// `connectionDidOpen()` is ever called, and after
    /// `connectionDidClose()` until the next open.
    case disconnected

    /// Sent `Identify` or `Resume`, waiting for `Ready` / `Resumed` /
    /// `InvalidSession`.
    case handshaking

    /// Received `Resumed`, receiving buffered events. The server has told
    /// us how many to expect (`expected`); `received` grows as they arrive.
    /// Transition to `.live` when `received == expected`.
    case replaying(expected: UInt64, received: UInt64)

    /// Real-time mode. All handshake / replay business is done; this is
    /// just ordinary push-event delivery.
    case live(sessionId: String)
}

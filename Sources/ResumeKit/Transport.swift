import Foundation

/// Bridge between the coordinator and your actual connection (WebSocket,
/// gRPC bidi stream, raw TCP — whatever). The coordinator calls these to
/// ask the transport to emit a frame; it's up to the transport to encode
/// and put the bytes on the wire.
///
/// Errors thrown here are logged by the coordinator but do **not** change
/// its state — a failed `sendHandshake` doesn't automatically mean the
/// connection is dead. Your transport is responsible for observing the
/// socket health and calling `connectionDidClose(error:)` when it actually
/// goes down.
public protocol SessionTransport: AnyObject, Sendable {
    /// Emit an `Identify` or `Resume` frame. Called once per
    /// `connectionDidOpen()` invocation.
    func sendHandshake(_ request: HandshakeRequest) async throws

    /// Emit a `Heartbeat { lastSeq }` frame. Called by the coordinator's
    /// internal timer while the connection is `.live` or `.replaying`.
    func sendHeartbeat(_ request: HeartbeatRequest) async throws
}

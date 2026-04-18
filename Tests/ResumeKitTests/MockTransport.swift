import Foundation
@testable import ResumeKit

/// Test double that records every frame the coordinator asks it to send.
/// Records are protected by an `actor` so the coordinator's actor and the
/// test thread can read/write concurrently without data races.
final class MockTransport: SessionTransport, @unchecked Sendable {
    private let recorder = Recorder()

    actor Recorder {
        var handshakes: [HandshakeRequest] = []
        var heartbeats: [HeartbeatRequest] = []
        var sendHandshakeError: (any Error)?
        var sendHeartbeatError: (any Error)?

        func recordHandshake(_ r: HandshakeRequest) throws {
            if let e = sendHandshakeError { throw e }
            handshakes.append(r)
        }

        func recordHeartbeat(_ r: HeartbeatRequest) throws {
            if let e = sendHeartbeatError { throw e }
            heartbeats.append(r)
        }

        func failHandshakes(with error: any Error) { sendHandshakeError = error }
    }

    func sendHandshake(_ request: HandshakeRequest) async throws {
        try await recorder.recordHandshake(request)
    }

    func sendHeartbeat(_ request: HeartbeatRequest) async throws {
        try await recorder.recordHeartbeat(request)
    }

    var handshakes: [HandshakeRequest] {
        get async { await recorder.handshakes }
    }

    var heartbeats: [HeartbeatRequest] {
        get async { await recorder.heartbeats }
    }

    func failHandshakes(with error: any Error) async {
        await recorder.failHandshakes(with: error)
    }
}

enum MockError: Error { case generic }

extension ClientProperties {
    static let testFixture = ClientProperties(
        platform: "ios",
        appVersion: "1.0.0",
        osVersion: "17.0",
        deviceName: "Test iPhone",
        deviceId: "test-device-id"
    )
}

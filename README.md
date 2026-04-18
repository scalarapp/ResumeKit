# ResumeKit

[![CI](https://github.com/scalarapp/ResumeKit/actions/workflows/ci.yml/badge.svg)](https://github.com/scalarapp/ResumeKit/actions/workflows/ci.yml)
[![Swift 5.10+](https://img.shields.io/badge/swift-5.10%2B-orange)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2015%20%7C%20macOS%2012%20%7C%20tvOS%2015%20%7C%20watchOS%208-lightgrey)](Package.swift)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen)](https://swift.org/package-manager)
[![License MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-docs.getscalar.org%2Fresumekit-1DAF8A)](https://docs.getscalar.org/resumekit/)

Discord-style session-resume client for Swift. Drop it into any iOS / macOS
app that talks to a real-time backend over WebSocket (or anything else)
and stop losing messages on every network blip.

📖 **Full API reference: [docs.getscalar.org/resumekit](https://docs.getscalar.org/resumekit/documentation/resumekit/)**
🧪 **Runnable example: [Examples/BasicDemo](Examples/BasicDemo/)** (`swift run`)

```swift
let coordinator = SessionCoordinator(
    transport: myWebSocketTransport,
    storage: myKeychainStorage,
    token: { await AuthService.shared.token },
    clientProperties: .current
)

// On every connect / disconnect:
await coordinator.connectionDidOpen()
await coordinator.connectionDidClose(error: nil)

// On every incoming frame your decoder parses:
await coordinator.didReceive(.ready(sessionId: "abc", initialSeq: 0))
await coordinator.didReceive(.pushEvent(seq: 17))

// Subscribe to high-level events for UI / notification suppression:
for await event in await coordinator.events {
    switch event {
    case .replayStarted: muteNotifications()
    case .replayFinished: unmuteNotifications()
    case .sessionInvalidated(let reason, _): print("server kicked us: \(reason)")
    case .stateChanged(let s): print("state → \(s)")
    }
}
```

## What problem does this solve

Mobile apps drop their WebSocket all the time — network change, app
backgrounded, server restart, OS killed the socket because you locked
the screen. The naive fix ("reconnect, refetch everything from REST")
loses real-time push events that happened while you were offline,
double-fires notifications for messages your push-notification
already alerted, and burns server CPU on every reconnect.

Discord, Zulip, and Mattermost all solved this years ago with the same
basic protocol: server buffers the last N events per user with monotonic
sequence numbers, client persists `(sessionId, lastSeq)`, and on
reconnect the client says "resume me from seq 42" — server replays
everything since then over the freshly-opened socket. This package
ships the **client half** of that protocol, transport-agnostic.

## What's included

- A state-machine `SessionCoordinator` actor that handles the
  Identify-vs-Resume decision, replay tracking, and heartbeat timing.
- Protocol-only abstractions for `SessionTransport` (your
  WebSocket / gRPC / TCP code) and `SessionStorage` (your Keychain
  wrapper), so the package has zero runtime dependencies.
- An `InMemorySessionStorage` for tests.
- An `events: AsyncStream<SessionEvent>` so multiple consumers
  can react to replay start/finish, state transitions, and server-
  side session invalidations.

## What's not

- The wire protocol itself. You decide the shape of your `Identify`,
  `Resume`, `Heartbeat`, `Hello`, `Ready`, `Resumed`, `InvalidSession`,
  and `HeartbeatAck` frames; this package only describes their semantics.
- The transport. Bring your own `URLSessionWebSocketTask`, `Starscream`,
  `Network.framework`, gRPC stub, etc. — implement
  `SessionTransport` to wire it up.
- The persistence. Production apps should ship a `SessionStorage`
  implementation backed by the Keychain (the `sessionId` deserves the
  same protection as your access token). The package ships only an
  in-memory default to avoid forcing a Keychain dependency.
- The server. You implement the matching opcodes (see the protocol
  table below) in whichever language your backend speaks. The package
  is protocol-agnostic — any server that buffers per-user events with
  monotonic sequence numbers works. Common pairings: Redis Streams for
  the buffer + Rust/Go/Node for the gateway.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/scalarapp/ResumeKit", from: "0.1.0")
]
```

Then `import ResumeKit` in your client code.

## The protocol you have to implement on the server

The coordinator expects your server to implement these opcodes:

| Direction | Opcode | Purpose |
|---|---|---|
| `Hello` | server → client (on upgrade) | Tell the client how often to heartbeat |
| `Identify { token, properties }` | client → server | First connect — create a fresh session |
| `Ready { sessionId, initialSeq }` | server → client | Identify accepted; new session created |
| `Resume { token, sessionId, lastSeq }` | client → server | Reconnect — replay since `lastSeq` |
| `Resumed { replayedCount, currentSeq }` | server → client | Resume accepted; about to replay N buffered events |
| `InvalidSession { reason, resumable }` | server → client | Resume rejected (TTL expired, gap too large, etc.) — Identify fresh |
| `Heartbeat { lastSeq }` | client → server | Keep-alive |
| `HeartbeatAck` | server → client | Keep-alive reply |

Plus: every push event your server sends carries a monotonically
increasing per-user `seq`. The coordinator tracks the highest seen
`seq` and persists it; on reconnect, the server resumes from
`seq > lastSeq`.

## Usage walkthrough

### 1. Implement `SessionTransport`

```swift
final class WebSocketTransport: SessionTransport {
    let socket: URLSessionWebSocketTask

    func sendHandshake(_ request: HandshakeRequest) async throws {
        let bytes: Data
        switch request.kind {
        case .identify(let props):
            bytes = encode(IdentifyFrame(token: request.token, properties: props))
        case .resume(let sid, let lastSeq):
            bytes = encode(ResumeFrame(token: request.token, sessionId: sid, lastSeq: lastSeq))
        }
        try await socket.send(.data(bytes))
    }

    func sendHeartbeat(_ request: HeartbeatRequest) async throws {
        try await socket.send(.data(encode(HeartbeatFrame(lastSeq: request.lastSeq))))
    }
}
```

`encode(_:)` is whatever you use — Protobuf, MessagePack, JSON, raw
bytes. The coordinator doesn't care.

### 2. Implement `SessionStorage` (use the Keychain)

```swift
final class KeychainSessionStorage: SessionStorage {
    private let keychain = Keychain(service: "com.example.session")
    private let key = "session_snapshot"
    private let storage = ActorBox<SessionSnapshot?>(nil)

    init() {
        if let data = try? keychain.getData(key),
           let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            Task { await storage.set(snap) }
        }
    }

    func load() async -> SessionSnapshot? { await storage.value }

    func save(sessionId: String) async {
        let snap = SessionSnapshot(sessionId: sessionId, lastSeq: 0)
        await storage.set(snap)
        try? keychain.set(JSONEncoder().encode(snap), key: key)
    }

    func updateLastSeq(_ seq: UInt64) async {
        guard var current = await storage.value, seq >= current.lastSeq else { return }
        current = SessionSnapshot(sessionId: current.sessionId, lastSeq: seq)
        await storage.set(current)
        try? keychain.set(JSONEncoder().encode(current), key: key)
    }

    func clear() async {
        await storage.set(nil)
        try? keychain.remove(key)
    }
}

actor ActorBox<T> {
    var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { value = v }
}
```

### 3. Wire it into your connection loop

```swift
let coordinator = SessionCoordinator(
    transport: webSocketTransport,
    storage: keychainStorage,
    token: { await AuthService.shared.token },
    clientProperties: .current
)

// In your WebSocket delegate / receive loop:
func webSocketDidOpen() {
    Task { await coordinator.connectionDidOpen() }
}

func webSocketDidClose(error: Error?) {
    Task { await coordinator.connectionDidClose(error: error) }
}

func webSocketDidReceive(_ frame: ServerFrame) {
    Task {
        switch frame {
        case .hello(let interval):
            await coordinator.didReceive(.hello(heartbeatInterval: interval))
        case .ready(let sid, let seq):
            await coordinator.didReceive(.ready(sessionId: sid, initialSeq: seq))
        case .resumed(let count, let curr):
            await coordinator.didReceive(.resumed(replayedCount: count, currentSeq: curr))
        case .invalidSession(let reason, let resumable):
            await coordinator.didReceive(.invalidSession(reason: reason, resumable: resumable))
        case .heartbeatAck:
            await coordinator.didReceive(.heartbeatAck)
        case .pushEvent(let seq, let payload):
            await coordinator.didReceive(.pushEvent(seq: seq))
            myAppLogic.handle(payload)
        }
    }
}
```

### 4. Suppress notifications during replay

This is the important UX bit. When the user opens the app after a
30-minute disconnect, the server will replay 50 buffered messages.
Those messages were already push-notified to the user's lock screen
while the app was offline — re-firing in-app banners now would be
duplicate spam.

```swift
Task {
    for await event in await coordinator.events {
        switch event {
        case .replayStarted:
            NotificationCoordinator.shared.suppressInAppAlerts = true
        case .replayFinished:
            NotificationCoordinator.shared.suppressInAppAlerts = false
        default: break
        }
    }
}
```

### 5. Logout

```swift
func logout() async {
    await coordinator.clearSession()  // wipes (sessionId, lastSeq) so next connect starts fresh
    await AuthService.shared.clearTokens()
}
```

## Design decisions

A few non-obvious choices the package makes, and why:

- **Single-shot `withObservationTracking` is not used.** Push events
  carrying a `seq` may arrive in bursts — the coordinator processes
  each one synchronously inside its actor, which gives natural
  back-pressure and orders state transitions deterministically.
- **`InvalidSession` clears storage immediately.** A subsequent
  connect must Identify fresh — not Resume with a known-bad cursor
  that the server will reject again, leaving you in a redirect loop.
- **Heartbeat is internal.** Discord recommends the client manage the
  cadence (it knows about its own state); the server only suggests
  the interval via `Hello`. Set `Configuration.autoHeartbeat = false`
  if your transport does its own keep-alive (e.g. TCP-level pings).
- **No retry / backoff in the coordinator.** Reconnect timing is your
  transport's job — different apps want different behavior (immediate
  on app foreground, exponential backoff on flaky cell). The
  coordinator only reacts to `connectionDidOpen` / `connectionDidClose`.
- **`AsyncStream` over delegates.** Multiple consumers can observe
  events without coordination; canceling a subscription is just
  cancelling the consuming task. Closer to modern Swift Concurrency
  idioms.

## Status

v0.1.0 — extracted from a production iOS messenger codebase into a
reusable package. API may shift before 1.0 if real users surface
friction; semantic versioning kicks in after that.

## Maintainer

Built and maintained by [@silverhans](https://github.com/silverhans).
Issues and PRs welcome.

## License

MIT.

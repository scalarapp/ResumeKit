# BasicDemo

Minimal runnable example. Drives `SessionCoordinator` through three
common lifecycle scenarios against a mock in-process "server", so you
can see every state transition and event without setting up a real
WebSocket.

## Run it

```sh
cd Examples/BasicDemo
swift run
```

## What it demonstrates

```
━━━ Scenario 1: fresh connect (Identify) ━━━
  → Identify(platform: demo, device: ...)
  ← Hello(heartbeatInterval: 30s), Ready(sessionId: demo-session-1, initialSeq: 0)
  ▶ state → live(demo-session-1)
  simulating 3 incoming push events...
  cursor now at sessionId=demo-session-1 lastSeq=3

━━━ Scenario 2: disconnect → reconnect (Resume + replay) ━━━
  ▶ state → disconnected
  → Resume(sessionId: demo-session-1, lastSeq: 3)
  ▶ state → handshaking
  ← Resumed(replayedCount: 2, currentSeq: 5)
  ▶ replayStarted — suppress notifications here
  ▶ state → replaying(0/2)
  ← PushEvent(seq: 4) [replay]
  ▶ state → replaying(1/2)
  ← PushEvent(seq: 5) [replay]
  ▶ replayFinished (replayed: 2) — re-enable notifications
  ▶ state → live(demo-session-1)

━━━ Scenario 3: logout ━━━
  → Identify(platform: demo, device: ...)
  ← Hello, Ready
  ▶ state → live(demo-session-1)
```

Three things worth paying attention to while reading the source:

1. **`MockTransport`** implements `SessionTransport` in ~40 lines.
   In a real app, replace the `Task { … }` reply simulation with your
   actual WebSocket decoder calling `coordinator.didReceive(…)` on every
   frame it parses.

2. **The event-subscription `Task`** (`for await event in await
   coordinator.events`) is where you'd hook your notification layer
   on `replayStarted` / `replayFinished`, and route to login on
   `sessionInvalidated`.

3. **`InMemorySessionStorage`** keeps things simple for the demo. In
   production, ship a `SessionStorage` backed by the Keychain — see
   the [main README](../../README.md#2-implement-sessionstorage-use-the-keychain)
   for an example implementation.

## What it doesn't demonstrate

- A real WebSocket transport (use `URLSessionWebSocketTask`,
  `Starscream`, `Network.framework`, ...)
- Heartbeat timer (disabled in this demo to keep output clean;
  real apps leave it on)
- `InvalidSession` handling
- Multiple concurrent coordinators
- SwiftUI state binding

All covered by the [main README's walkthrough](../../README.md#usage-walkthrough).

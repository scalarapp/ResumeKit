# ResumeKit Examples

Runnable examples that show how to wire ResumeKit into a real app.

Each subdirectory is a standalone Swift package with its own
`Package.swift`, so you can `cd` into one and `swift run` without
touching the main library.

| Example | What it shows |
|---|---|
| [BasicDemo](BasicDemo/) | State machine walkthrough with a mocked in-process "server" — fresh connect, disconnect-with-replay, logout. Good first read. |

_More examples (real WebSocket transport, SwiftUI state binding, logout
cascade) will be added as the library matures. PRs welcome._

import Foundation

/// Persistent store for `(sessionId, lastSeq)` across app launches and
/// connection cycles. **Implement this with the Keychain** in a real app
/// — the session ID pairs with the access token, so it deserves the same
/// protection. This package ships only an in-memory default to avoid
/// forcing a dependency on `KeychainAccess` / `KeychainWrapper`.
///
/// All methods must be safe to call concurrently from the coordinator's
/// actor. Backing stores that aren't themselves thread-safe should be
/// wrapped in an `actor`, NOT in a `DispatchQueue`-based lock, so they
/// compose naturally with `async`.
public protocol SessionStorage: Sendable {
    /// Return the last persisted snapshot, or `nil` if the slot is empty
    /// (first launch, after logout, or after `clear()`).
    func load() async -> SessionSnapshot?

    /// Persist a newly-created session. Called on `Ready`. Overwrites
    /// whatever was there — Identify means a fresh session, so the old
    /// snapshot is already invalid.
    func save(sessionId: String) async

    /// Bump the stored `lastSeq`. Called on every push event that carries
    /// a sequence number. Must be monotonic — callers (the coordinator)
    /// never go backward, but an implementation that wraps a shared
    /// storage (e.g. multiple processes) may want to assert monotonicity
    /// to defend against bugs.
    func updateLastSeq(_ seq: UInt64) async

    /// Drop everything. Called on logout and on `InvalidSession`. The
    /// implementation should be durable — after `clear()` returns, the
    /// next `load()` (even after a crash) must see `nil`.
    func clear() async
}

// MARK: - InMemorySessionStorage (default / testing)

/// Zero-dependency default. **Not suitable for production** — data is
/// lost on process exit. Use it for tests and to avoid pulling in a
/// Keychain wrapper transitively.
public actor InMemorySessionStorage: SessionStorage {
    private var snapshot: SessionSnapshot?

    public init(initial: SessionSnapshot? = nil) {
        self.snapshot = initial
    }

    public func load() async -> SessionSnapshot? {
        snapshot
    }

    public func save(sessionId: String) async {
        snapshot = SessionSnapshot(sessionId: sessionId, lastSeq: 0)
    }

    public func updateLastSeq(_ seq: UInt64) async {
        guard let current = snapshot else { return }
        // Monotonic guard — noisy logs from a buggy caller beat a silent
        // regression of the stored cursor.
        guard seq >= current.lastSeq else { return }
        snapshot = SessionSnapshot(sessionId: current.sessionId, lastSeq: seq)
    }

    public func clear() async {
        snapshot = nil
    }
}

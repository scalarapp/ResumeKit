import XCTest
@testable import ResumeKit

final class StorageTests: XCTestCase {
    func testInMemoryStoresAndRetrievesSnapshot() async {
        let storage = InMemorySessionStorage()

        var loaded = await storage.load()
        XCTAssertNil(loaded, "fresh storage should be empty")

        await storage.save(sessionId: "abc-123")
        loaded = await storage.load()
        XCTAssertEqual(loaded?.sessionId, "abc-123")
        XCTAssertEqual(loaded?.lastSeq, 0, "lastSeq starts at 0 after save()")

        await storage.updateLastSeq(42)
        loaded = await storage.load()
        XCTAssertEqual(loaded?.lastSeq, 42)
    }

    func testInMemoryClearWipesEverything() async {
        let storage = InMemorySessionStorage()
        await storage.save(sessionId: "abc")
        await storage.updateLastSeq(10)

        await storage.clear()
        let loaded = await storage.load()
        XCTAssertNil(loaded)
    }

    func testInMemoryUpdateLastSeqIsMonotonic() async {
        let storage = InMemorySessionStorage()
        await storage.save(sessionId: "abc")

        await storage.updateLastSeq(50)
        await storage.updateLastSeq(40)  // backwards — should be ignored

        let loaded = await storage.load()
        XCTAssertEqual(loaded?.lastSeq, 50, "updateLastSeq must not regress")
    }

    func testInMemoryUpdateLastSeqOnEmptyIsNoop() async {
        let storage = InMemorySessionStorage()
        // Don't save first — updateLastSeq with no snapshot must not crash.
        await storage.updateLastSeq(99)
        let loaded = await storage.load()
        XCTAssertNil(loaded)
    }

    func testInMemoryAcceptsInitialSnapshot() async {
        let initial = SessionSnapshot(sessionId: "preloaded", lastSeq: 7)
        let storage = InMemorySessionStorage(initial: initial)

        let loaded = await storage.load()
        XCTAssertEqual(loaded?.sessionId, "preloaded")
        XCTAssertEqual(loaded?.lastSeq, 7)
    }
}

#if os(macOS)
//
//  PaneSessionRegistryTests.swift
//  ImpressLayoutTests
//
//  ADR-0031 D6. The registry's whole job is LIFETIME, and every rule it holds
//  is one a previous bug taught us:
//
//    * one session per id, ever (two sessions over one document is two undo
//      stacks and a lost buffer);
//    * eviction FLUSHES (the LRU is the only thing here that can destroy
//      work);
//    * `discard` does NOT flush — a session dropped because its record is
//      being deleted must not write the body back and resurrect the row, the
//      exact bug `ManuscriptSessionRegistry.discard(id:)` exists for;
//    * use ORDER decides the victim, not insertion order.
//

import XCTest

@testable import ImpressLayout

/// A session that records what was done to it.
private final class FakeSession: PaneSession {
    let sessionID: String
    private(set) var flushes = 0
    private(set) var abandons = 0

    init(_ id: String) {
        sessionID = id
    }

    var pinned = false

    func flush() { flushes += 1 }
    func abandon() { abandons += 1 }
    var isPinned: Bool { pinned }
}

@MainActor
final class PaneSessionRegistryTests: XCTestCase {

    private func registry(capacity: Int = 2) -> PaneSessionRegistry<FakeSession> {
        PaneSessionRegistry<FakeSession>(capacity: capacity, label: "test")
    }

    func testASessionIsMadeOnceAndReused() {
        let registry = registry()
        var made = 0
        let first = registry.session(for: "a") {
            made += 1
            return FakeSession("a")
        }
        let second = registry.session(for: "a") {
            made += 1
            return FakeSession("a")
        }
        XCTAssertEqual(made, 1)
        XCTAssertTrue(first === second)
        XCTAssertEqual(registry.count, 1)
        XCTAssertTrue(registry.contains("a"))
    }

    func testAFactoryThatDeclinesLeavesNothingBehind() {
        let registry = registry()
        XCTAssertNil(registry.session(for: "a") { nil })
        XCTAssertFalse(registry.contains("a"))
        XCTAssertEqual(registry.count, 0)
    }

    func testTheOldestSessionIsEvictedAndFlushed() {
        let registry = registry(capacity: 2)
        let a = registry.session(for: "a") { FakeSession("a") }
        _ = registry.session(for: "b") { FakeSession("b") }
        _ = registry.session(for: "c") { FakeSession("c") }

        XCTAssertEqual(registry.count, 2)
        XCTAssertFalse(registry.contains("a"))
        XCTAssertEqual(a?.flushes, 1, "an evicted session must be flushed, or its work is lost")
        XCTAssertEqual(registry.liveSessionIDs, ["b", "c"])
    }

    func testUseOrderDecidesTheVictim() {
        let registry = registry(capacity: 2)
        _ = registry.session(for: "a") { FakeSession("a") }
        _ = registry.session(for: "b") { FakeSession("b") }
        // Touch "a" — now "b" is the oldest.
        _ = registry.existingSession(for: "a")
        _ = registry.session(for: "c") { FakeSession("c") }

        XCTAssertTrue(registry.contains("a"))
        XCTAssertFalse(registry.contains("b"))
        XCTAssertEqual(registry.liveSessionIDs, ["a", "c"])
    }

    func testReleaseFlushesAndDiscardDoesNot() {
        let registry = registry()
        let a = registry.session(for: "a") { FakeSession("a") }
        registry.release(id: "a")
        XCTAssertEqual(a?.flushes, 1)
        XCTAssertEqual(a?.abandons, 0)
        XCTAssertFalse(registry.contains("a"))

        let b = registry.session(for: "b") { FakeSession("b") }
        registry.discard(id: "b")
        XCTAssertEqual(b?.flushes, 0, "a discarded session must NOT write its buffer back")
        XCTAssertEqual(b?.abandons, 1)
        XCTAssertFalse(registry.contains("b"))
    }

    func testReleasingAnUnknownIdIsANoOp() {
        let registry = registry()
        registry.release(id: "nobody")
        registry.discard(id: "nobody")
        XCTAssertEqual(registry.count, 0)
    }

    func testFlushAllTouchesEveryLiveSession() {
        let registry = registry(capacity: 3)
        let a = registry.session(for: "a") { FakeSession("a") }
        let b = registry.session(for: "b") { FakeSession("b") }
        registry.flushAll()
        XCTAssertEqual(a?.flushes, 1)
        XCTAssertEqual(b?.flushes, 1)
    }

    /// A capacity below 1 would evict a session the moment it was made.
    func testCapacityIsAtLeastOne() {
        let registry = PaneSessionRegistry<FakeSession>(capacity: 0, label: "test")
        let a = registry.session(for: "a") { FakeSession("a") }
        XCTAssertNotNil(a)
        XCTAssertTrue(registry.contains("a"))
    }

    /// A session on screen is never the LRU victim: evicting it would give
    /// the pane still showing it a second editor on its next lookup.
    func testAPinnedSessionIsNeverEvicted() {
        let registry = registry(capacity: 2)
        let visible = registry.session(for: "a") { FakeSession("a") }!
        visible.pinned = true
        registry.session(for: "b") { FakeSession("b") }
        registry.session(for: "c") { FakeSession("c") }
        XCTAssertTrue(registry.contains("a"), "the on-screen session stays")
        XCTAssertFalse(registry.contains("b"), "the oldest OFF-screen session goes")
        XCTAssertEqual(visible.flushes, 0)

        // Everything pinned: the registry runs over capacity instead.
        registry.existingSession(for: "c")?.pinned = true
        registry.session(for: "d") {
            let session = FakeSession("d")
            session.pinned = true  // on screen from the start
            return session
        }
        registry.session(for: "e") { FakeSession("e") }
        XCTAssertTrue(registry.contains("a") && registry.contains("c") && registry.contains("d"))
        XCTAssertEqual(registry.liveSessions.map(\.sessionID).sorted(), ["a", "c", "d"])
    }
}
#endif

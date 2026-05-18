import XCTest
@testable import imprint

/// Smoke tests for `ManuscriptStoreAdapter` covering Phase 0 verification:
/// CRUD round-trips, body round-trip (incl. a 100 KB string), and FTS-style
/// queryability via the FFI. Tests use a separate adapter pointed at an
/// in-memory store, not the shared singleton — the singleton is initialized
/// against the on-disk app-group store and shouldn't be touched from tests.
@MainActor
final class ManuscriptStoreAdapterTests: XCTestCase {

    /// Build a fresh in-memory adapter for each test. Each call opens a new
    /// `SharedStore.openInMemory()` — they don't share state.
    private func makeAdapter() throws -> ManuscriptStoreAdapter {
        try ManuscriptStoreAdapter.forTesting()
    }

    // MARK: - Create / read

    func testCreateAndReadManuscript() throws {
        let adapter = try makeAdapter()
        let id = try adapter.createManuscript(
            title: "Notes on Topology",
            format: .latex,
            body: "\\title{Notes on Topology}",
            authors: ["A. Researcher"]
        )

        let m = try XCTUnwrap(adapter.manuscript(id: id))
        XCTAssertEqual(m.id, id)
        XCTAssertEqual(m.title, "Notes on Topology")
        XCTAssertEqual(m.format, .latex)
        XCTAssertEqual(m.authors, ["A. Researcher"])
        XCTAssertEqual(m.body, "\\title{Notes on Topology}")
        XCTAssertEqual(m.status, "draft")
        XCTAssertNotNil(m.bodyContentHash)
    }

    func testManuscriptNotFoundReturnsNil() throws {
        let adapter = try makeAdapter()
        XCTAssertNil(adapter.manuscript(id: UUID()))
    }

    // MARK: - Body round-trip (100 KB)

    func testLargeBodyRoundTrip() throws {
        let adapter = try makeAdapter()
        // ~100 KB of Lorem ipsum-ish content.
        let chunk = "The Möbius strip is a non-orientable surface. "
        let body = String(repeating: chunk, count: 100_000 / chunk.utf8.count)
        XCTAssertGreaterThan(body.utf8.count, 90_000)

        let id = try adapter.createManuscript(
            title: "Long Manuscript",
            format: .typst,
            body: body
        )
        let m = try XCTUnwrap(adapter.manuscript(id: id))
        XCTAssertEqual(m.body, body, "100 KB body should round-trip unchanged")
        XCTAssertEqual(m.body.utf8.count, body.utf8.count)
    }

    // MARK: - setBody

    func testSetBodyUpdatesContentAndHash() throws {
        let adapter = try makeAdapter()
        let id = try adapter.createManuscript(
            title: "Mutable Manuscript",
            format: .typst,
            body: "initial"
        )
        let original = try XCTUnwrap(adapter.manuscript(id: id))

        try adapter.setBody(id: id, text: "updated body")
        let updated = try XCTUnwrap(adapter.manuscript(id: id))
        XCTAssertEqual(updated.body, "updated body")
        XCTAssertNotEqual(updated.bodyContentHash, original.bodyContentHash)
    }

    // MARK: - dataVersion + batch API

    func testDataVersionBumpsOnEachMutation() throws {
        let adapter = try makeAdapter()
        let v0 = adapter.dataVersion
        _ = try adapter.createManuscript(title: "A", format: .typst)
        let v1 = adapter.dataVersion
        XCTAssertGreaterThan(v1, v0)

        let id = try adapter.createManuscript(title: "B", format: .typst)
        let v2 = adapter.dataVersion
        XCTAssertGreaterThan(v2, v1)

        try adapter.setBody(id: id, text: "x")
        XCTAssertGreaterThan(adapter.dataVersion, v2)
    }

    func testBatchMutationCollapsesEvents() throws {
        let adapter = try makeAdapter()
        let v0 = adapter.dataVersion
        adapter.beginBatchMutation()
        let id1 = try adapter.createManuscript(title: "A", format: .typst)
        let id2 = try adapter.createManuscript(title: "B", format: .latex)
        try adapter.setBody(id: id1, text: "hello")
        adapter.endBatchMutation()

        // dataVersion is bumped per mutation even inside a batch — the batch
        // only suppresses the cross-actor event fan-out.
        XCTAssertGreaterThanOrEqual(adapter.dataVersion, v0 + 3)
        XCTAssertNotNil(adapter.manuscript(id: id1))
        XCTAssertNotNil(adapter.manuscript(id: id2))
    }

    // MARK: - List + delete

    func testListAndDelete() throws {
        let adapter = try makeAdapter()
        let id1 = try adapter.createManuscript(title: "First", format: .typst)
        let id2 = try adapter.createManuscript(title: "Second", format: .latex)

        let list = adapter.listManuscripts()
        let listIDs = Set(list.map(\.id))
        XCTAssertTrue(listIDs.contains(id1))
        XCTAssertTrue(listIDs.contains(id2))

        try adapter.deleteManuscript(id: id1)
        XCTAssertNil(adapter.manuscript(id: id1))
        XCTAssertNotNil(adapter.manuscript(id: id2))
    }

    // MARK: - Collections

    func testCreateNestedCollections() throws {
        let adapter = try makeAdapter()
        let workspace = try adapter.createCollection(name: "Default", isWorkspace: true)
        let subA = try adapter.createCollection(name: "Drafts", parentID: workspace)
        let subB = try adapter.createCollection(name: "Submitted", parentID: workspace)

        // Phase 0 doesn't read collections back yet (phase 1 wires the
        // sidebar query path). Smoke test: creation doesn't throw and IDs
        // are distinct.
        XCTAssertNotEqual(workspace, subA)
        XCTAssertNotEqual(workspace, subB)
        XCTAssertNotEqual(subA, subB)
    }
}

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

        // Since the kernel switch these ARE readable back — one tree, built
        // from payload `parent_collection_ref`, never the envelope parent.
        let tree = adapter.listCollections()
        XCTAssertEqual(Set(tree.map(\.id)), [workspace, subA, subB])
        XCTAssertNil(tree.first { $0.id == workspace }?.parentID)
        XCTAssertEqual(tree.first { $0.id == subA }?.parentID, workspace)
        XCTAssertEqual(tree.first { $0.id == subB }?.parentID, workspace)
    }
}

// MARK: - Kernel-routed collections (ADR-0022)
//
// Every verb below runs on `SharedStore.collection*`. The point of the suite
// is not that the verbs work — the Rust kernel has its own tests — but that
// imprint's adapter routes through it, reports the ids that actually changed,
// and registers an exact inverse for each mutation.

@MainActor
final class ManuscriptStoreAdapterCollectionKernelTests: XCTestCase {

    private func makeAdapter() throws -> ManuscriptStoreAdapter {
        try ManuscriptStoreAdapter.forTesting()
    }

    func testCollectionRoundTripThroughTheKernel() throws {
        let adapter = try makeAdapter()
        let root = try adapter.createCollection(name: "Papers")
        let child = try adapter.createCollection(name: "2026", parentID: root)

        let m1 = try adapter.createManuscript(title: "One", format: .typst)
        let m2 = try adapter.createManuscript(title: "Two", format: .typst)

        let added = adapter.addToCollection(manuscriptIDs: [m1, m2], collectionID: child)
        XCTAssertEqual(Set(added), [m1, m2])
        XCTAssertEqual(adapter.collectionMemberCounts(collectionIDs: [child]), [2])

        // Folder scope reads membership back through the `Contains` edges.
        let inFolder = adapter.listManuscripts(scope: .folder(child))
        XCTAssertEqual(Set(inFolder.map(\.id)), [m1, m2])

        // Adding an existing member reports NO change, so an undo can never
        // unfile something it did not file.
        XCTAssertEqual(adapter.addToCollection(manuscriptIDs: [m1], collectionID: child), [])

        let removed = adapter.removeFromCollection(manuscriptIDs: [m1], collectionID: child)
        XCTAssertEqual(removed, [m1])
        XCTAssertEqual(adapter.collectionMemberCounts(collectionIDs: [child]), [1])
    }

    func testRenameReparentAndDeleteRunOnTheKernel() throws {
        let adapter = try makeAdapter()
        let a = try adapter.createCollection(name: "A")
        let b = try adapter.createCollection(name: "B")

        XCTAssertTrue(adapter.renameCollection(id: a, to: "Alpha"))
        XCTAssertEqual(adapter.listCollections().first { $0.id == a }?.name, "Alpha")

        XCTAssertTrue(adapter.reparentCollection(id: b, newParentID: a))
        XCTAssertEqual(adapter.listCollections().first { $0.id == b }?.parentID, a)

        // The cycle check is the KERNEL's, not Swift's.
        XCTAssertFalse(adapter.reparentCollection(id: a, newParentID: b))

        XCTAssertTrue(adapter.deleteCollection(id: b))
        XCTAssertNil(adapter.listCollections().first { $0.id == b })
    }

    // MARK: Undo — one inverse per mutating verb

    func testUndoInverseForCreateCollection() throws {
        let adapter = try makeAdapter()
        let undo = UndoManager()
        let id = try adapter.createCollection(name: "Temp", undoManager: undo)
        XCTAssertNotNil(adapter.listCollections().first { $0.id == id })

        undo.undo()
        XCTAssertNil(adapter.listCollections().first { $0.id == id })

        undo.redo()
        XCTAssertEqual(adapter.listCollections().first { $0.id == id }?.name, "Temp")
    }

    func testUndoInverseForRenameCollection() throws {
        let adapter = try makeAdapter()
        let undo = UndoManager()
        let id = try adapter.createCollection(name: "Before")
        XCTAssertTrue(adapter.renameCollection(id: id, to: "After", undoManager: undo))

        undo.undo()
        XCTAssertEqual(adapter.listCollections().first { $0.id == id }?.name, "Before")
        undo.redo()
        XCTAssertEqual(adapter.listCollections().first { $0.id == id }?.name, "After")
    }

    func testUndoInverseForReparentCollection() throws {
        let adapter = try makeAdapter()
        let undo = UndoManager()
        let parent = try adapter.createCollection(name: "Parent")
        let child = try adapter.createCollection(name: "Child")
        XCTAssertTrue(
            adapter.reparentCollection(id: child, newParentID: parent, undoManager: undo))

        undo.undo()
        XCTAssertNil(adapter.listCollections().first { $0.id == child }?.parentID)
        undo.redo()
        XCTAssertEqual(adapter.listCollections().first { $0.id == child }?.parentID, parent)
    }

    func testUndoInverseForDeleteCollectionRestoresMembership() throws {
        let adapter = try makeAdapter()
        let undo = UndoManager()
        let folder = try adapter.createCollection(name: "Doomed")
        let m = try adapter.createManuscript(title: "Filed", format: .typst)
        _ = adapter.addToCollection(manuscriptIDs: [m], collectionID: folder)

        XCTAssertTrue(adapter.deleteCollection(id: folder, undoManager: undo))
        XCTAssertNil(adapter.listCollections().first { $0.id == folder })
        // The member itself is never deleted.
        XCTAssertNotNil(adapter.manuscript(id: m))

        undo.undo()
        XCTAssertEqual(adapter.listCollections().first { $0.id == folder }?.name, "Doomed")
        // `collection_restore` puts the dropped membership back too.
        XCTAssertEqual(adapter.collectionMemberCounts(collectionIDs: [folder]), [1])
    }

    func testUndoInverseForAddAndRemoveMembers() throws {
        let adapter = try makeAdapter()
        let undo = UndoManager()
        let folder = try adapter.createCollection(name: "Folder")
        let m = try adapter.createManuscript(title: "M", format: .typst)

        _ = adapter.addToCollection(manuscriptIDs: [m], collectionID: folder, undoManager: undo)
        XCTAssertEqual(adapter.collectionMemberCounts(collectionIDs: [folder]), [1])
        undo.undo()
        XCTAssertEqual(adapter.collectionMemberCounts(collectionIDs: [folder]), [0])
        undo.redo()
        XCTAssertEqual(adapter.collectionMemberCounts(collectionIDs: [folder]), [1])

        let undo2 = UndoManager()
        _ = adapter.removeFromCollection(
            manuscriptIDs: [m], collectionID: folder, undoManager: undo2)
        XCTAssertEqual(adapter.collectionMemberCounts(collectionIDs: [folder]), [0])
        undo2.undo()
        XCTAssertEqual(adapter.collectionMemberCounts(collectionIDs: [folder]), [1])
    }
}

// MARK: - Triage + listing (descriptor-sourced, never literal)

@MainActor
final class ManuscriptStoreAdapterTriageTests: XCTestCase {

    private func makeAdapter() throws -> ManuscriptStoreAdapter {
        try ManuscriptStoreAdapter.forTesting()
    }

    /// The adapter must take its status vocabulary from the record-kind
    /// descriptor. If someone re-types "dismissed" into the adapter and then
    /// changes the descriptor, this is what catches it.
    func testStatusStringsComeFromTheDescriptorNotLiterals() {
        let triage = ManuscriptRecordKind.descriptor.triage
        guard case .statusChange(let dismissed, let restoreTo) = triage.dismissal else {
            return XCTFail("manuscript dismissal must be .statusChange")
        }
        XCTAssertEqual(ManuscriptStoreAdapter.dismissedStatus, dismissed)
        XCTAssertEqual(ManuscriptStoreAdapter.restoreStatus, restoreTo)
        XCTAssertEqual(ManuscriptStoreAdapter.archivedStatus, triage.archiveStatus)
        XCTAssertEqual(ManuscriptStoreAdapter.deletionIsHard, triage.deletion == .confirmHard)
        XCTAssertEqual(
            ManuscriptStoreAdapter.collectionBindingID,
            ManuscriptRecordKind.descriptor.collection?.bindingID)
        XCTAssertEqual(
            ManuscriptStoreAdapter.manuscriptSchemaRef,
            ManuscriptRecordKind.descriptor.schemaRefs.first)
    }

    func testDismissedManuscriptsAreExcludedFromUnscopedListings() throws {
        let adapter = try makeAdapter()
        let kept = try adapter.createManuscript(title: "Kept", format: .typst)
        let swept = try adapter.createManuscript(title: "Swept", format: .typst)

        XCTAssertTrue(adapter.dismiss(ids: [swept]))

        let all = adapter.listManuscripts()
        XCTAssertEqual(all.map(\.id), [kept], "dismissed manuscripts must leave every scope…")

        // …except the one that names the status.
        let dismissedStatus = try XCTUnwrap(ManuscriptStoreAdapter.dismissedStatus)
        let inDismissed = adapter.listManuscripts(scope: .status(dismissedStatus))
        XCTAssertEqual(inDismissed.map(\.id), [swept])

        // The INDEX read still sees everything — Spotlight and the importer's
        // dedup must not re-import a dismissed manuscript.
        XCTAssertEqual(Set(adapter.allManuscripts().map(\.id)), [kept, swept])
    }

    func testDismissedManuscriptsAreExcludedFromFolderAndFlaggedScopes() throws {
        let adapter = try makeAdapter()
        let folder = try adapter.createCollection(name: "F")
        let m = try adapter.createManuscript(title: "M", format: .typst)
        _ = adapter.addToCollection(manuscriptIDs: [m], collectionID: folder)
        adapter.setFlag(ids: [m], color: "red")

        XCTAssertEqual(adapter.listManuscripts(scope: .folder(folder)).map(\.id), [m])
        XCTAssertEqual(adapter.listManuscripts(scope: .flagged(nil)).map(\.id), [m])
        XCTAssertEqual(adapter.listManuscripts(scope: .flagged("red")).map(\.id), [m])
        XCTAssertEqual(adapter.listManuscripts(scope: .flagged("blue")).map(\.id), [])

        XCTAssertTrue(adapter.dismiss(ids: [m]))
        XCTAssertEqual(adapter.listManuscripts(scope: .folder(folder)), [])
        XCTAssertEqual(adapter.listManuscripts(scope: .flagged(nil)), [])
    }

    func testPagingFillsAPageEvenWhenRowsAreFilteredOut() throws {
        let adapter = try makeAdapter()
        var ids: [UUID] = []
        for i in 0..<6 {
            ids.append(try adapter.createManuscript(title: "M\(i)", format: .typst))
        }
        // Dismiss every other one; a page of 3 must still return 3 survivors.
        XCTAssertTrue(adapter.dismiss(ids: [ids[0], ids[2], ids[4]]))
        XCTAssertEqual(adapter.listManuscripts(limit: 3).count, 3)
        XCTAssertEqual(adapter.listManuscripts(limit: 0).count, 3)
    }

    func testSetStatusRefusesAStatusTheDescriptorNeverDeclares() throws {
        let adapter = try makeAdapter()
        let m = try adapter.createManuscript(title: "M", format: .typst)
        XCTAssertFalse(adapter.setStatus(ids: [m], to: "obliterated"))
        XCTAssertEqual(adapter.manuscript(id: m)?.status, "draft")
    }

    // MARK: Search

    func testSearchManuscriptsExcludesDismissed() throws {
        let adapter = try makeAdapter()
        let keep = try adapter.createManuscript(
            title: "Reionization history", format: .typst, body: "reionization")
        let drop = try adapter.createManuscript(
            title: "Reionization appendix", format: .typst, body: "reionization")

        XCTAssertEqual(Set(adapter.searchManuscripts(query: "reionization").map(\.id)),
                       [keep, drop])
        XCTAssertTrue(adapter.dismiss(ids: [drop]))
        XCTAssertEqual(adapter.searchManuscripts(query: "reionization").map(\.id), [keep])
        XCTAssertEqual(
            Set(adapter.searchManuscripts(query: "reionization", includeDismissed: true)
                .map(\.id)),
            [keep, drop])
    }

    // MARK: Undo — one inverse per mutating triage verb

    func testUndoInverseForSetStarredRestoresPriorPerItemState() throws {
        let adapter = try makeAdapter()
        let undo = UndoManager()
        let a = try adapter.createManuscript(title: "A", format: .typst)
        let b = try adapter.createManuscript(title: "B", format: .typst)
        adapter.setStarred(ids: [a], starred: true)   // a starred, b not

        adapter.setStarred(ids: [a, b], starred: true, undoManager: undo)
        XCTAssertEqual(adapter.manuscript(id: b)?.isStarred, true)

        undo.undo()
        // The MIXED prior state comes back — not "everything unstarred".
        XCTAssertEqual(adapter.manuscript(id: a)?.isStarred, true)
        XCTAssertEqual(adapter.manuscript(id: b)?.isStarred, false)

        undo.redo()
        XCTAssertEqual(adapter.manuscript(id: b)?.isStarred, true)
    }

    func testUndoInverseForSetFlag() throws {
        let adapter = try makeAdapter()
        let undo = UndoManager()
        let m = try adapter.createManuscript(title: "M", format: .typst)
        adapter.setFlag(ids: [m], color: "red")

        adapter.setFlag(ids: [m], color: "blue", undoManager: undo)
        XCTAssertEqual(adapter.manuscript(id: m)?.flagColor, "blue")
        undo.undo()
        XCTAssertEqual(adapter.manuscript(id: m)?.flagColor, "red")
        undo.redo()
        XCTAssertEqual(adapter.manuscript(id: m)?.flagColor, "blue")
    }

    func testUndoInverseForAddAndRemoveTag() throws {
        let adapter = try makeAdapter()
        let undo = UndoManager()
        let m = try adapter.createManuscript(title: "M", format: .typst)

        adapter.addTag(ids: [m], tagPath: "projects/reionization", undoManager: undo)
        XCTAssertTrue(adapter.manuscript(id: m)?.tags.contains("projects/reionization") ?? false)
        undo.undo()
        XCTAssertFalse(adapter.manuscript(id: m)?.tags.contains("projects/reionization") ?? true)
        undo.redo()
        XCTAssertTrue(adapter.manuscript(id: m)?.tags.contains("projects/reionization") ?? false)

        let undo2 = UndoManager()
        adapter.removeTag(ids: [m], tagPath: "projects/reionization", undoManager: undo2)
        XCTAssertFalse(adapter.manuscript(id: m)?.tags.contains("projects/reionization") ?? true)
        undo2.undo()
        XCTAssertTrue(adapter.manuscript(id: m)?.tags.contains("projects/reionization") ?? false)
    }

    func testUndoInverseForDismissRestoreAndArchive() throws {
        let adapter = try makeAdapter()
        let m = try adapter.createManuscript(title: "M", format: .typst)
        let dismissed = try XCTUnwrap(ManuscriptStoreAdapter.dismissedStatus)
        let restoreTo = try XCTUnwrap(ManuscriptStoreAdapter.restoreStatus)
        let archived = try XCTUnwrap(ManuscriptStoreAdapter.archivedStatus)

        let undo = UndoManager()
        XCTAssertTrue(adapter.dismiss(ids: [m], undoManager: undo))
        XCTAssertEqual(adapter.manuscript(id: m)?.status, dismissed)
        undo.undo()
        XCTAssertEqual(adapter.manuscript(id: m)?.status, restoreTo)
        undo.redo()
        XCTAssertEqual(adapter.manuscript(id: m)?.status, dismissed)

        let undo2 = UndoManager()
        XCTAssertTrue(adapter.restore(ids: [m], undoManager: undo2))
        XCTAssertEqual(adapter.manuscript(id: m)?.status, restoreTo)
        undo2.undo()
        XCTAssertEqual(adapter.manuscript(id: m)?.status, dismissed)

        let undo3 = UndoManager()
        XCTAssertTrue(adapter.archive(ids: [m], undoManager: undo3))
        XCTAssertEqual(adapter.manuscript(id: m)?.status, archived)
        undo3.undo()
        XCTAssertEqual(adapter.manuscript(id: m)?.status, dismissed)
    }
}

//
//  CollectionKernelReadParityTests.swift
//  PublicationManagerCoreTests
//
//  The flip-unblocking fix (ADR-0022 "flip gate"): `RustStoreAdapter`'s
//  collection reads now go through the kernel (`collectionTreeIn`), which
//  resolves the `collections.unified` marker — the legacy `list_collections`
//  export matches `schema_ref = "imbib/collection"` by equality and goes blind
//  once WP G7 has run. This suite proves the kernel read is a genuine drop-in
//  ON THE REAL WRITE PATH: both handles open the SAME file-backed store, the
//  data is created through imbib's own writers (`createLibrary`,
//  `createCollection`, `importBibtex`, `addToCollection`), and the two reads
//  must agree row for row — ids, names, tree parents, sort order, smart flag,
//  and the member count the sidebar badges render.
//
//  The Rust half of this proof (including invariance ACROSS the flip, which
//  Swift cannot run without mutating a marker) is
//  `crates/impress-core/tests/collection_container_axis.rs`.
//

import Foundation
import ImbibRustCore
import ImpressRustCore
import XCTest

@testable import PublicationManagerCore

final class CollectionKernelReadParityTests: XCTestCase {

    func testKernelTreeAgreesWithTheLegacyExportOnTheRealWritePath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernel-read-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("impress.sqlite").path

        // Two handles, one database — exactly RustStoreAdapter's production
        // shape (`imbibStore` + `kernelStore` over one WAL file).
        let imbib = try ImbibStore.open(path: dbPath)
        let kernel = try ImpressRustCore.SharedStore.open(path: dbPath)

        let library = try imbib.createLibrary(name: "Parity Library")
        let reading = try imbib.createCollection(
            name: "Reading", libraryId: library.id, isSmart: false, query: nil)
        let nested = try imbib.createCollection(
            name: "Nested", libraryId: library.id, isSmart: false, query: nil)
        // Nest via the payload parent ref, the invariant field (never
        // `item.parent`, which is the owning library — c902a22f).
        try imbib.updateField(id: nested.id, field: "parent_id", value: reading.id)
        let smart = try imbib.createCollection(
            name: "Starred smart", libraryId: library.id, isSmart: true, query: "starred:true")

        let pubIDs = try imbib.importBibtex(
            bibtex: """
            @article{ParityA, author = {A. Author}, title = {First}, year = {2001} }
            @article{ParityB, author = {B. Author}, title = {Second}, year = {2002} }
            """,
            libraryId: library.id)
        XCTAssertEqual(pubIDs.count, 2, "seed publications through the real importer")
        _ = try imbib.addToCollection(publicationIds: pubIDs, collectionId: reading.id)

        let legacy = try imbib.listCollections(libraryId: library.id)
            .map { CollectionModel(from: $0) }
        let viaKernel = try kernel.collectionTreeIn(
            binding: .publication, containerId: library.id.lowercased())
            .map { CollectionModel(fromKernel: $0) }

        XCTAssertEqual(legacy.count, 3)
        XCTAssertEqual(
            viaKernel, legacy,
            "the kernel tree must be a drop-in for the legacy export: same rows, "
                + "same order, same member counts")

        // The count the sidebar renders, spelled out — 2 filed papers.
        let readingRow = try XCTUnwrap(viaKernel.first { $0.name == "Reading" })
        XCTAssertEqual(readingRow.publicationCount, 2)
        let nestedRow = try XCTUnwrap(viaKernel.first { $0.name == "Nested" })
        XCTAssertEqual(nestedRow.parentID?.uuidString.lowercased(), reading.id.lowercased())
        XCTAssertEqual(nestedRow.publicationCount, 0)
        let smartRow = try XCTUnwrap(viaKernel.first { $0.name == "Starred smart" })
        XCTAssertTrue(smartRow.isSmart)
    }

    /// ADR-0022 F2. The REVERSE-membership read — "which collections hold this
    /// paper?" — has two imbib-core spellings that Swift consumes separately:
    /// `listCollectionsForPublication` (rows, for
    /// `PublicationListMutations.removeFromAllCollections` and `FirstSyncMerge`)
    /// and `getPublicationDetail(...).collections` (ids, for
    /// `EverythingExporter`'s `X-Imbib-Collections` header). Both now run the
    /// same marker-resolving kernel verb, and this pins them to each other and
    /// to the kernel tree on the real write path — so a future edit to one
    /// cannot quietly answer a different question from the other.
    ///
    /// Swift cannot set the `collections.unified` marker, so invariance ACROSS
    /// the flip is proved in Rust
    /// (`imbib-core/tests/collection_migration_legacy_readers.rs`
    /// `the_f2_exports_stay_correct_across_the_flip`). What Swift proves is that
    /// the two projections agree on the data imbib's own writers produce.
    func testReverseMembershipReadsAgreeWithEachOtherAndWithTheKernel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reverse-membership-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("impress.sqlite").path

        let imbib = try ImbibStore.open(path: dbPath)
        let kernel = try ImpressRustCore.SharedStore.open(path: dbPath)

        let library = try imbib.createLibrary(name: "Membership Library")
        let reading = try imbib.createCollection(
            name: "Reading", libraryId: library.id, isSmart: false, query: nil)
        let starred = try imbib.createCollection(
            name: "Starred", libraryId: library.id, isSmart: true, query: "starred:true")
        // A collection the paper is NOT in, so an over-broad query would show.
        _ = try imbib.createCollection(
            name: "Unrelated", libraryId: library.id, isSmart: false, query: nil)

        let pubIDs = try imbib.importBibtex(
            bibtex: """
            @article{MembershipA, author = {A. Author}, title = {First}, year = {2001} }
            @article{MembershipB, author = {B. Author}, title = {Second}, year = {2002} }
            """,
            libraryId: library.id)
        XCTAssertEqual(pubIDs.count, 2)
        let paper = pubIDs[0]
        _ = try imbib.addToCollection(publicationIds: [paper], collectionId: reading.id)
        _ = try imbib.addToCollection(publicationIds: [paper], collectionId: starred.id)
        // A second member of "Reading" only, so the two rows carry different
        // counts and a collapsed badge would not hide behind a coincidence.
        _ = try imbib.addToCollection(publicationIds: [pubIDs[1]], collectionId: reading.id)

        let holders = try imbib.listCollectionsForPublication(publicationId: paper)
            .map { CollectionModel(from: $0) }
        XCTAssertEqual(
            Set(holders.map(\.name)), ["Reading", "Starred"],
            "exactly the two collections the paper was filed into")
        let readingHolder = try XCTUnwrap(holders.first { $0.name == "Reading" })
        let starredHolder = try XCTUnwrap(holders.first { $0.name == "Starred" })
        XCTAssertEqual(readingHolder.publicationCount, 2, "each row's OWN member count")
        XCTAssertEqual(starredHolder.publicationCount, 1)
        XCTAssertTrue(starredHolder.isSmart)

        // The detail projection is the same query, id-only. Compared as sets:
        // both order by `sort_order`, and imbib's own creator writes 0 for all
        // of them, so the tie-break is not a contract either projection owes.
        let detail = try XCTUnwrap(imbib.getPublicationDetail(id: paper))
        XCTAssertEqual(
            Set(detail.collections), Set(holders.map { $0.id.uuidString.lowercased() }),
            "the detail pane's .collections and listCollectionsForPublication must "
                + "not be able to disagree — they are one kernel verb, two projections")

        // And both agree with the kernel tree the sidebar renders.
        let tree = try kernel.collectionTreeIn(
            binding: .publication, containerId: library.id.lowercased())
            .map { CollectionModel(fromKernel: $0) }
        for holder in holders {
            let fromTree = try XCTUnwrap(tree.first { $0.id == holder.id })
            XCTAssertEqual(fromTree, holder, "reverse read and tree read report one row")
        }

        // A collection created AFTER the kernel handle was opened is reachable
        // through both immediately: `createCollection`'s write now goes through
        // the kernel, and one tree must never have two writers.
        let late = try imbib.createCollection(
            name: "Late", libraryId: library.id, isSmart: false, query: nil)
        _ = try imbib.addToCollection(publicationIds: [paper], collectionId: late.id)
        let lateTree = try kernel.collectionTreeIn(
            binding: .publication, containerId: library.id.lowercased())
        XCTAssertTrue(
            lateTree.contains { $0.id == late.id },
            "the kernel sees a collection imbib-core created")
        XCTAssertTrue(
            try imbib.listCollectionsForPublication(publicationId: paper)
                .contains { $0.id == late.id })
    }

    /// ADR-0022 F3. `listManuscriptCollections` is imprint's LIVE folder read
    /// through the shared chassis (`ImbibSidebarViewModel.manuscriptFolderNodes`),
    /// and its writer has been the kernel since G2
    /// (`ManuscriptStoreAdapter.createCollection` → `CollectionStoreAdapter.create`).
    /// Until F3 the read was a `schema_ref = "manuscript-collection"` literal,
    /// so the write went one way and the read the other the moment the marker
    /// flipped.
    ///
    /// This pins the reshaper on the real cross-adapter write path: folders
    /// created through the kernel handle must surface through imbib-core's
    /// export with their tree parents, their member counts and — the field the
    /// kernel has no concept of — imprint's `is_workspace` flag.
    func testManuscriptFolderExportAgreesWithTheKernelOnTheRealWritePath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manuscript-folder-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("impress.sqlite").path

        let imbib = try ImbibStore.open(path: dbPath)
        let kernel = try ImpressRustCore.SharedStore.open(path: dbPath)

        // imprint's writer, verbatim: kernel create, then `is_workspace` as an
        // additive follow-up field on whatever schema the kernel just wrote.
        let workspace = try kernel.collectionCreate(
            binding: .manuscript, name: "Workspace", parentId: nil,
            kindScope: nil, sortOrder: 0)
        let workspaceSchema = try XCTUnwrap(try kernel.getItem(id: workspace.id)).schemaRef
        try kernel.upsertItemV2(row: SharedItemUpsert(
            id: workspace.id, schemaRef: workspaceSchema,
            payloadJson: #"{"is_workspace":true}"#, parentId: nil, tags: [],
            createdMs: nil, isRead: nil, isStarred: nil))
        let drafts = try kernel.collectionCreate(
            binding: .manuscript, name: "Drafts", parentId: workspace.id,
            kindScope: nil, sortOrder: 1)

        let alpha = try imbib.createManuscript(
            title: "Alpha", format: "typst", body: "", authors: [])
        let beta = try imbib.createManuscript(
            title: "Beta", format: "typst", body: "", authors: [])
        _ = try imbib.addToCollection(
            publicationIds: [alpha.id, beta.id], collectionId: drafts.id)

        let rows = try imbib.listManuscriptCollections()
        XCTAssertEqual(rows.map(\.id), [workspace.id, drafts.id], "ordered by sort_order")

        let workspaceRow = try XCTUnwrap(rows.first { $0.id == workspace.id })
        XCTAssertEqual(workspaceRow.name, "Workspace")
        XCTAssertNil(workspaceRow.parentId, "a workspace is a root")
        XCTAssertTrue(workspaceRow.isWorkspace, "imprint's flag survives the reshaper")
        XCTAssertEqual(workspaceRow.manuscriptCount, 0)

        let draftsRow = try XCTUnwrap(rows.first { $0.id == drafts.id })
        XCTAssertEqual(
            draftsRow.parentId, workspace.id,
            "the TREE parent, never the owning library (c902a22f)")
        XCTAssertFalse(draftsRow.isWorkspace)
        XCTAssertEqual(draftsRow.manuscriptCount, 2, "the badge imprint's sidebar renders")

        // The export and the kernel tree are one read now — a divergence here
        // is the two-writers/two-readers hazard reappearing.
        let tree = try kernel.collectionTree(binding: .manuscript)
        XCTAssertEqual(rows.map(\.id), tree.map(\.id))
        XCTAssertEqual(rows.map(\.name), tree.map(\.name))
        XCTAssertEqual(rows.map { Int64($0.sortOrder) }, tree.map(\.sortOrder))
        XCTAssertEqual(rows.map { Int64($0.manuscriptCount) }, tree.map(\.memberCount))
    }

    /// ADR-0022 F3. Deleting a library must round-trip its COLLECTIONS, not
    /// only its publications.
    ///
    /// `deleteLibraryUndoable` snapshots the ids the delete is about to orphan
    /// (`ON DELETE SET NULL` on the envelope parent) and `restoreLibrary`
    /// re-parents them. The collection half of that snapshot was a legacy
    /// schema query, so post-flip it came back empty and the "Undo Delete
    /// Library" entry restored a library with no collections in it — the one
    /// residue item that lost DATA rather than a display.
    ///
    /// Invariance across the marker is proved in Rust (Swift cannot set it);
    /// this is the pre-flip half, through the shipping export, so the
    /// round-trip itself is pinned on the path a user's ⌘Z takes.
    func testDeletingAndUndoingALibraryRestoresItsCollections() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-undo-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("impress.sqlite").path

        let imbib = try ImbibStore.open(path: dbPath)

        let library = try imbib.createLibrary(name: "Doomed")
        let root = try imbib.createCollection(
            name: "Reading", libraryId: library.id, isSmart: false, query: nil)
        let nested = try imbib.createCollection(
            name: "Reionization", libraryId: library.id, isSmart: false, query: nil)
        try imbib.updateField(id: nested.id, field: "parent_id", value: root.id)
        let pubIDs = try imbib.importBibtex(
            bibtex: "@article{Doomed, author = {A. Author}, title = {Paper}, year = {2001} }",
            libraryId: library.id)
        _ = try imbib.addToCollection(publicationIds: pubIDs, collectionId: nested.id)

        let before = try imbib.listCollections(libraryId: library.id)
        XCTAssertEqual(before.count, 2)

        let snapshot = try imbib.deleteLibraryUndoable(id: library.id)
        XCTAssertEqual(
            Set(snapshot.childCollectionIds), Set([root.id, nested.id]),
            "the snapshot names BOTH the root collection and the nested one — "
                + "every collection of a library carries it on the envelope, whatever "
                + "its depth in the tree")
        XCTAssertEqual(snapshot.childPublicationIds.count, 1)

        try imbib.restoreLibrary(snapshot: snapshot)

        let after = try imbib.listCollections(libraryId: library.id)
        XCTAssertEqual(after.map(\.id), before.map(\.id), "delete → undo is a round trip")
        XCTAssertEqual(
            after.map(\.parentId), before.map(\.parentId),
            "nesting comes back with them")
        XCTAssertEqual(
            after.map(\.publicationCount), before.map(\.publicationCount),
            "and so does membership")
    }
}

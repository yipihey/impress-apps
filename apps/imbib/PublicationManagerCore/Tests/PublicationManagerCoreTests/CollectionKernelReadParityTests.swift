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
}

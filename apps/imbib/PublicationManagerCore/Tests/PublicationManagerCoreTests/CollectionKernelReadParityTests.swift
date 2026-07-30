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
}

//
//  ManuscriptRevisionRoundTripTests.swift
//  PublicationManagerCoreTests
//
//  Deterministic, headless proof of the Versions "Save + Restore" data path
//  (the Info-tab Versions section → RustStoreAdapter.createManuscriptRevision /
//  manuscriptRevisionSource → ManuscriptSessionRegistry.restoreBody).
//
//  The round-trip can't be exercised through RustStoreAdapter under unit tests:
//  there, its ImbibStore and its review SharedStore each open a SEPARATE
//  in-memory DB, so a revision written via one is invisible to the other. The
//  running app avoids that because BOTH FFIs open the same on-disk file. We
//  reproduce the app faithfully here by opening both handles on ONE shared temp
//  DB path — the exact two-handle/one-file topology RustStoreAdapter uses in
//  production (schema identity between the two FFIs is proven by the Phase-0
//  cross-adapter tests).
//

import XCTest
import ImbibRustCore
import ImpressRustCore
@testable import PublicationManagerCore

final class ManuscriptRevisionRoundTripTests: XCTestCase {

    func testSaveVersionThenRestoreSourceRoundTrips() throws {
        let dbPath = NSTemporaryDirectory() + "manuscript-rev-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let v1 = "= Draft\nversion one — the original text"
        let v2 = "= Draft\nversion two — rewritten, nothing like v1"

        // --- Save Version -----------------------------------------------------
        // Write body v1, then snapshot it as the named revision "v1".
        let imbib = try ImbibStore.open(path: dbPath)
        let manuscript = try imbib.createManuscript(
            title: "Round Trip", format: "typst", body: "", authors: [])
        _ = try imbib.setManuscriptBody(id: manuscript.id, body: v1, expectedHash: nil)
        let revision = try imbib.createManuscriptRevision(
            manuscriptId: manuscript.id, revisionTag: "v1", snapshotReason: "user-tag")

        // Move the head on: the live body is now v2, diverged from the snapshot.
        _ = try imbib.setManuscriptBody(id: manuscript.id, body: v2, expectedHash: nil)

        // The saved version is listed with its tag and a non-empty word count.
        let revisions = try imbib.listManuscriptRevisions(manuscriptId: manuscript.id)
        let saved = try XCTUnwrap(revisions.first { $0.revisionTag == "v1" },
                                 "Save Version should persist a named revision")
        XCTAssertEqual(saved.id, revision.id)

        // --- Restore ----------------------------------------------------------
        // Restore reads the snapshot's inline source via the SharedStore handle
        // on the SAME db file — the exact read RustStoreAdapter.
        // manuscriptRevisionSource performs. It must return the body AS OF the
        // save (v1), not the current head (v2).
        let shared = try SharedStore.open(path: dbPath)
        let item = try XCTUnwrap(try shared.getItem(id: revision.id),
                                 "The revision item must be readable on the shared db")
        let payload = try JSONSerialization.jsonObject(
            with: Data(item.payloadJson.utf8)) as? [String: Any]
        let restoredSource = payload?["source_inline"] as? String

        XCTAssertEqual(restoredSource, v1,
                       "Restoring 'v1' must return the body as it was when the version was saved")
        XCTAssertNotEqual(restoredSource, v2)
    }
}

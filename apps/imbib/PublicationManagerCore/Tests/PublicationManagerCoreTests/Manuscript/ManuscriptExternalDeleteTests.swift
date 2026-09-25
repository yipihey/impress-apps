//
//  ManuscriptExternalDeleteTests.swift
//  PublicationManagerCoreTests
//
//  A manuscript deleted by ANOTHER writer while an editor session holds it
//  (review PH-M9, plan wave 7 T4). The GUI's own delete discards the session
//  first; an agent's or the CLI's cannot, so the session has to notice the
//  row is gone, drop itself without flushing, and refuse a later flush.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class ManuscriptExternalDeleteTests: XCTestCase {

    func testADeleteFromElsewhereDiscardsTheSessionAndNothingWritesItBack() async throws {
        let adapter = RustStoreAdapter.shared
        let registry = ManuscriptSessionRegistry.shared
        let row = try XCTUnwrap(UndoCoordinator.performAutomatic("test setup") {
            adapter.createManuscript(title: "Deleted elsewhere \(UUID().uuidString.prefix(6))", body: "= Hello")
        })
        let id = try XCTUnwrap(UUID(uuidString: row.id))
        let session = try XCTUnwrap(registry.session(for: id))
        XCTAssertTrue(session.rowExists)
        #if os(macOS)
        let pane = try XCTUnwrap(SourcePaneSession.forPane("test-\(id.uuidString)"))
        pane.show(session)
        XCTAssertTrue(pane.manuscript === session)
        #endif

        // An unsaved edit in the buffer — what a late save would write back.
        session.source = "= Hello, edited after the delete"

        // Another writer deletes the row. Not `ManuscriptDeletion.perform`,
        // which discards first: this is the path that could not.
        UndoCoordinator.performAutomatic("test: another writer") { adapter.deleteItem(id: id) }
        XCTAssertFalse(session.rowExists)

        XCTAssertFalse(session.absorbExternalChange(), "the session did not notice its row is gone")
        registry.broadcastExternalChange(to: [id])
        XCTAssertFalse(registry.hasLiveSession(for: id), "the registry kept a session for a deleted manuscript")
        #if os(macOS)
        XCTAssertNil(pane.manuscript, "a source pane's editor still holds the deleted manuscript")
        #endif

        // Eviction or quit would flush it: that must write nothing.
        session.flush()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(adapter.getManuscriptDetail(id: id), "a flush after the delete wrote the manuscript back")
    }
}

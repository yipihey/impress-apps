//
//  AttachmentChangeEventTests.swift
//  PublicationManagerCoreTests
//
//  Deleting a PDF from the Info tab removed the file and the record, and
//  then left the row on screen until the user selected another paper and
//  came back (2026-09-11). The delete emitted a bare `.structural` event,
//  and every per-publication surface — the Info tab's attachment list, the
//  PDF and Notes tabs, the list row's PDF marker — filters the event stream
//  by the publication id it is showing, so all of them ignored it.
//
//  A linked file is a CHILD record: its own id matches nothing those
//  surfaces hold. The event has to name the OWNING publication.
//

import XCTest
import ImpressStoreKit
@testable import PublicationManagerCore

@MainActor
final class AttachmentChangeEventTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentChangeEventTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Harness

    private struct Fixture {
        let store: RustStoreAdapter
        let manager: AttachmentManager
        let library: UUID
        let publication: UUID
    }

    private func makeFixture() throws -> Fixture {
        let store = try RustStoreAdapter(inMemory: true)
        let manager = AttachmentManager(store: store, applicationSupportRoot: root)
        let library = try XCTUnwrap(store.createLibrary(name: "ULDM"))
        let publication = try XCTUnwrap(store.importBibTeX(
            "@article{Attach2022, title={An attached paper}, year={2022}}",
            libraryId: library.id).first)
        return Fixture(store: store, manager: manager, library: library.id, publication: publication)
    }

    /// The events the store emits while `action` runs, narrowed to the ones
    /// that name `publication` — exactly the filter every detail surface
    /// applies (`InfoTab`, `PDFTab`, `NotesTab`, `publicationDetailLifecycle`).
    ///
    /// Other test classes run in their own processes, but the publisher is a
    /// singleton within one, so the id filter keeps this test honest either
    /// way. Returns an empty array rather than hanging when nothing is
    /// emitted, which is the failure this test exists to catch.
    private func eventsNaming(
        _ publication: UUID,
        during action: () throws -> Void
    ) async throws -> [StoreEvent] {
        let stream = ImbibImpressStore.shared.events.subscribe()
        try action()
        let collector = Task { () -> [StoreEvent] in
            var matched: [StoreEvent] = []
            for await event in stream {
                if case .itemsMutated(_, let ids) = event, ids.contains(publication) {
                    matched.append(event)
                    break  // one is enough for every assertion here
                }
            }
            return matched
        }
        let deadline = Task {
            try? await Task.sleep(for: .milliseconds(750))
            collector.cancel()
        }
        let matched = await collector.value
        deadline.cancel()
        return matched
    }

    // MARK: - Tests

    func testDeletingAnAttachmentTellsThePublicationsSurfaces() async throws {
        let f = try makeFixture()
        let file = try f.manager.importPDF(
            data: PDFImportIntegrityTests.makePDF(), for: f.publication, in: f.library)

        let events = try await eventsNaming(f.publication) {
            try f.manager.delete(file, in: f.library, for: f.publication)
        }

        XCTAssertEqual(events.first, .itemsMutated(kind: .attachment, ids: [f.publication]),
                       "a bare .structural event leaves the deleted row on screen")
        XCTAssertTrue(f.store.listLinkedFiles(publicationId: f.publication).isEmpty)
        let detail = try XCTUnwrap(f.store.getPublicationDetail(id: f.publication))
        XCTAssertTrue(detail.linkedFiles.isEmpty, "what the Info tab re-reads on the event")
    }

    func testDeletingOneOfTwoAttachmentsStillTellsThem() async throws {
        // The regression was invisible when the last PDF went away: clearing
        // `has_pdf_downloaded` emitted a publication-scoped event of its own.
        // With a second PDF left behind, nothing did.
        let f = try makeFixture()
        let first = try f.manager.importPDF(
            data: PDFImportIntegrityTests.makePDF(), for: f.publication, in: f.library)
        _ = try f.manager.importPDF(
            data: PDFImportIntegrityTests.makePDF(), for: f.publication, in: f.library,
            precomputedHash: "not-a-duplicate")

        let events = try await eventsNaming(f.publication) {
            try f.manager.delete(first, in: f.library, for: f.publication)
        }

        XCTAssertEqual(events.first, .itemsMutated(kind: .attachment, ids: [f.publication]))
        XCTAssertEqual(f.store.listLinkedFiles(publicationId: f.publication).count, 1)
    }

    func testAddingAnAttachmentTellsThePublicationsSurfaces() async throws {
        let f = try makeFixture()
        let events = try await eventsNaming(f.publication) {
            _ = try f.manager.importPDF(
                data: PDFImportIntegrityTests.makePDF(), for: f.publication, in: f.library)
        }
        XCTAssertEqual(events.first, .itemsMutated(kind: .attachment, ids: [f.publication]),
                       "the add path's own event, not the has_pdf_downloaded side effect")
    }
}

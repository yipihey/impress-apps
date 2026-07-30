//
//  ImprintImpressStoreTests.swift
//  ImprintCoreTests
//
//  Tests for the ImprintImpressStore gateway read methods. Uses
//  SharedStore.openInMemory() for isolation so the real user database
//  is never touched.
//
//  Coverage:
//  - loadSection round-trip (write via upsertItem, read via gateway)
//  - listSectionsForDocument client-side document_id filtering
//  - listSectionsForDocument sorting by order_index
//  - countSectionsForDocument
//  - listDocumentIDs aggregation
//  - listAllSections pagination bound
//  - Content-addressed body rehydration (missing file path)
//

import XCTest
@testable import ImprintCore
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

#if canImport(ImpressRustCore)
final class ImprintImpressStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Build a gateway backed by a fresh in-memory shared store.
    private func makeGateway() throws -> (ImprintImpressStore, SharedStore) {
        let store = try SharedStore.openInMemory()
        let gateway = ImprintImpressStore(testStore: store)
        return (gateway, store)
    }

    /// Write a manuscript section directly via SharedStore.upsertItem,
    /// bypassing ImprintStoreAdapter. Matches the payload shape that
    /// the adapter produces.
    private func writeSection(
        _ store: SharedStore,
        id: UUID = UUID(),
        title: String,
        body: String = "",
        sectionType: String? = nil,
        orderIndex: Int = 0,
        wordCount: Int? = nil,
        documentID: UUID,
        contentHash: String? = nil
    ) throws -> UUID {
        var payload: [String: Any] = [
            "title": title,
            "body": body,
            "order_index": orderIndex,
            "document_id": documentID.uuidString
        ]
        if let sectionType { payload["section_type"] = sectionType }
        if let wordCount { payload["word_count"] = wordCount }
        if let contentHash { payload["content_hash"] = contentHash }

        let json = try JSONSerialization.data(withJSONObject: payload)
        let jsonString = String(data: json, encoding: .utf8)!

        // Bare `manuscript-section` — the spelling BOTH writers use
        // (ImprintStoreAdapter.syncSections and Rust SectionStore). Seeding
        // `manuscript-section@1.0.0` here is what let the reader/writer
        // disagreement pass CI: the fixture and the reader agreed with each
        // other and with nothing that ever wrote a row.
        try store.upsertItem(
            id: id.uuidString,
            schemaRef: "manuscript-section",
            payloadJson: jsonString
        )
        return id
    }

    // MARK: - loadSection round-trip

    func testLoadSectionReturnsNilForUnknownID() throws {
        let (gateway, _) = try makeGateway()
        let section = gateway.loadSection(id: UUID())
        XCTAssertNil(section)
    }

    func testLoadSectionRoundTrip() throws {
        let (gateway, store) = try makeGateway()
        let docID = UUID()
        let sectionID = try writeSection(
            store,
            title: "Introduction",
            body: "Lorem ipsum dolor sit amet.",
            sectionType: "introduction",
            orderIndex: 0,
            wordCount: 5,
            documentID: docID
        )

        let loaded = gateway.loadSection(id: sectionID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, sectionID)
        XCTAssertEqual(loaded?.title, "Introduction")
        XCTAssertEqual(loaded?.body, "Lorem ipsum dolor sit amet.")
        XCTAssertEqual(loaded?.sectionType, "introduction")
        XCTAssertEqual(loaded?.orderIndex, 0)
        XCTAssertEqual(loaded?.wordCount, 5)
        XCTAssertEqual(loaded?.documentID, docID)
        XCTAssertNil(loaded?.contentHash)
    }

    // MARK: - listSectionsForDocument

    func testListSectionsForDocumentFiltersByDocumentID() throws {
        let (gateway, store) = try makeGateway()
        let docA = UUID()
        let docB = UUID()

        _ = try writeSection(store, title: "A intro", orderIndex: 0, documentID: docA)
        _ = try writeSection(store, title: "A methods", orderIndex: 1, documentID: docA)
        _ = try writeSection(store, title: "B abstract", orderIndex: 0, documentID: docB)

        let aSections = gateway.listSectionsForDocument(documentID: docA)
        XCTAssertEqual(aSections.count, 2)
        XCTAssertTrue(aSections.allSatisfy { $0.documentID == docA })

        let bSections = gateway.listSectionsForDocument(documentID: docB)
        XCTAssertEqual(bSections.count, 1)
        XCTAssertEqual(bSections.first?.title, "B abstract")
    }

    func testListSectionsForDocumentSortedByOrderIndex() throws {
        let (gateway, store) = try makeGateway()
        let docID = UUID()

        _ = try writeSection(store, title: "Third", orderIndex: 2, documentID: docID)
        _ = try writeSection(store, title: "First", orderIndex: 0, documentID: docID)
        _ = try writeSection(store, title: "Second", orderIndex: 1, documentID: docID)

        let sections = gateway.listSectionsForDocument(documentID: docID)
        XCTAssertEqual(sections.map(\.title), ["First", "Second", "Third"])
    }

    func testListSectionsForUnknownDocumentIsEmpty() throws {
        let (gateway, store) = try makeGateway()
        _ = try writeSection(store, title: "Orphan", documentID: UUID())

        let sections = gateway.listSectionsForDocument(documentID: UUID())
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - countSectionsForDocument

    func testCountSectionsForDocument() throws {
        let (gateway, store) = try makeGateway()
        let docID = UUID()
        let otherDocID = UUID()

        _ = try writeSection(store, title: "One", orderIndex: 0, documentID: docID)
        _ = try writeSection(store, title: "Two", orderIndex: 1, documentID: docID)
        _ = try writeSection(store, title: "Other", documentID: otherDocID)

        XCTAssertEqual(gateway.countSectionsForDocument(documentID: docID), 2)
        XCTAssertEqual(gateway.countSectionsForDocument(documentID: otherDocID), 1)
        XCTAssertEqual(gateway.countSectionsForDocument(documentID: UUID()), 0)
    }

    // MARK: - listDocumentIDs

    func testListDocumentIDsDistinct() throws {
        let (gateway, store) = try makeGateway()
        let a = UUID()
        let b = UUID()
        let c = UUID()

        _ = try writeSection(store, title: "A1", documentID: a)
        _ = try writeSection(store, title: "A2", documentID: a)
        _ = try writeSection(store, title: "B1", documentID: b)
        _ = try writeSection(store, title: "C1", documentID: c)

        let ids = gateway.listDocumentIDs()
        XCTAssertEqual(ids, Set([a, b, c]))
    }

    func testListDocumentIDsEmptyStore() throws {
        let (gateway, _) = try makeGateway()
        XCTAssertTrue(gateway.listDocumentIDs().isEmpty)
    }

    // MARK: - listAllSections

    func testListAllSectionsRespectsPagination() throws {
        let (gateway, store) = try makeGateway()
        let docID = UUID()
        for i in 0..<5 {
            _ = try writeSection(store, title: "Section \(i)", orderIndex: i, documentID: docID)
        }

        let page1 = gateway.listAllSections(limit: 3, offset: 0)
        XCTAssertEqual(page1.count, 3)

        let page2 = gateway.listAllSections(limit: 3, offset: 3)
        XCTAssertEqual(page2.count, 2)
    }

    // MARK: - Content-addressed body rehydration

    func testLoadSectionWithMissingContentHashFile() throws {
        let (gateway, store) = try makeGateway()
        let docID = UUID()
        // Reference a content hash that does NOT exist on disk. The
        // gateway should still return the section, but with body=nil.
        let fakeHash = String(repeating: "a", count: 64)
        let sectionID = try writeSection(
            store,
            title: "Large section",
            body: "",
            orderIndex: 0,
            documentID: docID,
            contentHash: fakeHash
        )

        let loaded = gateway.loadSection(id: sectionID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.title, "Large section")
        XCTAssertEqual(loaded?.contentHash, fakeHash)
        XCTAssertNil(loaded?.body, "body should be nil when content file is missing")
    }

    // MARK: - MalformedPayload defensive behavior

    func testLoadSectionRejectsNonManuscriptSchema() throws {
        let (gateway, store) = try makeGateway()
        let id = UUID()
        let payload = ["title": "Wrong schema"]
        let json = try JSONSerialization.data(withJSONObject: payload)
        let jsonString = String(data: json, encoding: .utf8)!
        try store.upsertItem(
            id: id.uuidString,
            schemaRef: "not-a-manuscript-section",
            payloadJson: jsonString
        )

        let loaded = gateway.loadSection(id: id)
        XCTAssertNil(loaded, "loadSection must reject rows with the wrong schema")
    }
}
#endif

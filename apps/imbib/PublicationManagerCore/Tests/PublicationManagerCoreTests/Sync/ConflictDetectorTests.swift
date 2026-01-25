//
//  ConflictDetectorTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-16.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

final class ConflictDetectorTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(configuration: .preview)
        context = persistenceController.viewContext
    }

    override func tearDown() {
        context = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Cite Key Conflict Tests

    func testCiteKeyConflict_init() {
        let incomingID = UUID()
        let existingID = UUID()

        let conflict = CiteKeyConflict(
            incomingPublicationID: incomingID,
            existingPublicationID: existingID,
            citeKey: "Einstein1905",
            suggestedResolutions: [.merge, .keepExisting]
        )

        XCTAssertEqual(conflict.citeKey, "Einstein1905")
        XCTAssertEqual(conflict.incomingPublicationID, incomingID)
        XCTAssertEqual(conflict.existingPublicationID, existingID)
        XCTAssertEqual(conflict.suggestedResolutions.count, 2)
    }

    func testCiteKeyResolution_descriptions() {
        XCTAssertEqual(CiteKeyResolution.merge.description, "Merge publications")
        XCTAssertEqual(CiteKeyResolution.keepExisting.description, "Keep existing, discard incoming")
        XCTAssertEqual(CiteKeyResolution.keepIncoming.description, "Replace existing with incoming")
        XCTAssertEqual(CiteKeyResolution.keepBoth.description, "Keep both (auto-rename)")
        XCTAssertTrue(CiteKeyResolution.renameIncoming(newCiteKey: "test").description.contains("incoming"))
        XCTAssertTrue(CiteKeyResolution.renameExisting(newCiteKey: "test").description.contains("existing"))
    }

    func testCiteKeyResolution_ids() {
        XCTAssertEqual(CiteKeyResolution.merge.id, "merge")
        XCTAssertEqual(CiteKeyResolution.keepExisting.id, "keep-existing")
        XCTAssertEqual(CiteKeyResolution.keepIncoming.id, "keep-incoming")
        XCTAssertEqual(CiteKeyResolution.keepBoth.id, "keep-both")
        XCTAssertTrue(CiteKeyResolution.renameIncoming(newCiteKey: "test").id.starts(with: "rename-incoming"))
        XCTAssertTrue(CiteKeyResolution.renameExisting(newCiteKey: "test").id.starts(with: "rename-existing"))
    }

    // MARK: - PDF Conflict Tests

    func testPDFConflict_init() {
        let pubID = UUID()
        let localDate = Date()
        let remoteDate = Date().addingTimeInterval(100)

        let conflict = PDFConflict(
            publicationID: pubID,
            localFilePath: "Papers/test.pdf",
            remoteFilePath: "Papers/test.pdf",
            localModifiedDate: localDate,
            remoteModifiedDate: remoteDate
        )

        XCTAssertEqual(conflict.publicationID, pubID)
        XCTAssertEqual(conflict.localFilePath, "Papers/test.pdf")
        XCTAssertEqual(conflict.localModifiedDate, localDate)
        XCTAssertEqual(conflict.remoteModifiedDate, remoteDate)
    }

    // MARK: - Conflict Detector Tests

    func testConflictDetector_detectCiteKeyConflict_noCollision() async {
        // Create existing publication
        let existing = CDPublication(context: context)
        existing.id = UUID()
        existing.citeKey = "Existing2020"
        existing.entryType = "article"
        existing.dateAdded = Date()
        existing.dateModified = Date()

        try? context.save()

        // Create incoming publication with different cite key
        let incoming = CDPublication(context: context)
        incoming.id = UUID()
        incoming.citeKey = "Incoming2021"
        incoming.entryType = "article"
        incoming.dateAdded = Date()
        incoming.dateModified = Date()

        // Detect
        let conflict = await ConflictDetector.shared.detectCiteKeyConflict(
            incoming: incoming,
            in: context
        )

        XCTAssertNil(conflict)
    }

    func testConflictDetector_detectCiteKeyConflict_collision() async {
        // Create existing publication
        let existing = CDPublication(context: context)
        existing.id = UUID()
        existing.citeKey = "Einstein1905"
        existing.entryType = "article"
        existing.dateAdded = Date()
        existing.dateModified = Date()

        try? context.save()

        // Create incoming publication with same cite key
        let incoming = CDPublication(context: context)
        incoming.id = UUID()
        incoming.citeKey = "Einstein1905"
        incoming.entryType = "article"
        incoming.dateAdded = Date()
        incoming.dateModified = Date()

        // Detect
        let conflict = await ConflictDetector.shared.detectCiteKeyConflict(
            incoming: incoming,
            in: context
        )

        XCTAssertNotNil(conflict)
        XCTAssertEqual(conflict?.citeKey, "Einstein1905")
        XCTAssertEqual(conflict?.existingPublicationID, existing.id)
        XCTAssertEqual(conflict?.incomingPublicationID, incoming.id)
        XCTAssertFalse(conflict?.suggestedResolutions.isEmpty ?? true)
    }

    // MARK: - Duplicate Detection Tests

    func testConflictDetector_detectDuplicate_byDOI() async {
        // Create existing publication with DOI
        let existing = CDPublication(context: context)
        existing.id = UUID()
        existing.citeKey = "Existing2020"
        existing.entryType = "article"
        existing.doi = "10.1234/test.doi"
        existing.dateAdded = Date()
        existing.dateModified = Date()

        try? context.save()

        // Create incoming publication with same DOI
        let incoming = CDPublication(context: context)
        incoming.id = UUID()
        incoming.citeKey = "Incoming2021"
        incoming.entryType = "article"
        incoming.doi = "10.1234/test.doi"
        incoming.dateAdded = Date()
        incoming.dateModified = Date()

        // Detect
        let duplicate = await ConflictDetector.shared.detectDuplicateByIdentifiers(
            incoming: incoming,
            in: context
        )

        XCTAssertNotNil(duplicate)
        XCTAssertEqual(duplicate?.id, existing.id)
    }

    func testConflictDetector_detectDuplicate_byArxivID() async {
        // Create existing publication with arXiv ID
        let existing = CDPublication(context: context)
        existing.id = UUID()
        existing.citeKey = "Existing2020"
        existing.entryType = "article"
        existing.arxivIDNormalized = "2301.12345"
        existing.dateAdded = Date()
        existing.dateModified = Date()

        try? context.save()

        // Create incoming publication with same arXiv ID
        let incoming = CDPublication(context: context)
        incoming.id = UUID()
        incoming.citeKey = "Incoming2021"
        incoming.entryType = "article"
        incoming.arxivIDNormalized = "2301.12345"
        incoming.dateAdded = Date()
        incoming.dateModified = Date()

        // Detect
        let duplicate = await ConflictDetector.shared.detectDuplicateByIdentifiers(
            incoming: incoming,
            in: context
        )

        XCTAssertNotNil(duplicate)
        XCTAssertEqual(duplicate?.id, existing.id)
    }

    func testConflictDetector_detectDuplicate_noDuplicate() async {
        // Create existing publication
        let existing = CDPublication(context: context)
        existing.id = UUID()
        existing.citeKey = "Existing2020"
        existing.entryType = "article"
        existing.doi = "10.1234/existing.doi"
        existing.dateAdded = Date()
        existing.dateModified = Date()

        try? context.save()

        // Create incoming publication with different identifiers
        let incoming = CDPublication(context: context)
        incoming.id = UUID()
        incoming.citeKey = "Incoming2021"
        incoming.entryType = "article"
        incoming.doi = "10.1234/different.doi"
        incoming.dateAdded = Date()
        incoming.dateModified = Date()

        // Detect
        let duplicate = await ConflictDetector.shared.detectDuplicateByIdentifiers(
            incoming: incoming,
            in: context
        )

        XCTAssertNil(duplicate)
    }
}

//
//  EverythingImportTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-29.
//

import XCTest
@testable import PublicationManagerCore

final class EverythingImportTests: XCTestCase {

    // MARK: - Import Options Tests

    func testDefaultImportOptions() {
        let options = EverythingImportOptions.default

        XCTAssertEqual(options.duplicateHandling, .skip)
        XCTAssertTrue(options.importFiles)
        XCTAssertTrue(options.preserveUUIDs)
        XCTAssertTrue(options.importTriageState)
        XCTAssertTrue(options.importMutedItems)
        XCTAssertTrue(options.importDismissedPapers)
        XCTAssertTrue(options.libraryConflictResolutions.isEmpty)
    }

    func testCustomImportOptions() {
        let libraryID = UUID()
        let options = EverythingImportOptions(
            duplicateHandling: .merge,
            importFiles: false,
            preserveUUIDs: false,
            importTriageState: false,
            importMutedItems: false,
            importDismissedPapers: false,
            libraryConflictResolutions: [libraryID: .replace]
        )

        XCTAssertEqual(options.duplicateHandling, .merge)
        XCTAssertFalse(options.importFiles)
        XCTAssertFalse(options.preserveUUIDs)
        XCTAssertFalse(options.importTriageState)
        XCTAssertFalse(options.importMutedItems)
        XCTAssertFalse(options.importDismissedPapers)
        XCTAssertEqual(options.libraryConflictResolutions[libraryID], .replace)
    }

    // MARK: - Library Conflict Resolution Tests

    func testLibraryConflictResolutionValues() {
        XCTAssertEqual(LibraryConflictResolution.merge.rawValue, "Merge")
        XCTAssertEqual(LibraryConflictResolution.replace.rawValue, "Replace")
        XCTAssertEqual(LibraryConflictResolution.rename.rawValue, "Rename")
        XCTAssertEqual(LibraryConflictResolution.skip.rawValue, "Skip")
    }

    func testLibraryConflictResolutionDescriptions() {
        XCTAssertTrue(LibraryConflictResolution.merge.description.contains("Merge"))
        XCTAssertTrue(LibraryConflictResolution.replace.description.contains("Replace"))
        XCTAssertTrue(LibraryConflictResolution.rename.description.contains("new library"))
        XCTAssertTrue(LibraryConflictResolution.skip.description.contains("Skip"))
    }

    // MARK: - Library Conflict Tests

    func testLibraryConflictCreation() {
        let conflict = LibraryConflict(
            importName: "My Library",
            importType: .user,
            existingID: UUID(),
            existingName: "My Library"
        )

        XCTAssertEqual(conflict.importName, "My Library")
        XCTAssertEqual(conflict.importType, .user)
        XCTAssertEqual(conflict.resolution, .merge)  // Default
    }

    // MARK: - Import Preview Tests

    func testImportPreviewTotalItemCount() {
        let dummyMessage = MboxMessage(
            from: "Test",
            subject: "Test",
            date: Date(),
            messageID: "test"
        )

        let preview = EverythingImportPreview(
            manifest: EverythingManifest(),
            libraries: [],
            publications: [
                PublicationPreview(
                    id: UUID(),
                    citeKey: "Test2024a",
                    title: "Test Paper 1",
                    authors: "Author",
                    message: dummyMessage
                ),
                PublicationPreview(
                    id: UUID(),
                    citeKey: "Test2024b",
                    title: "Test Paper 2",
                    authors: "Author",
                    message: dummyMessage
                )
            ],
            duplicates: [
                DuplicateInfo(
                    importPublication: PublicationPreview(
                        id: UUID(),
                        citeKey: "Existing2024",
                        title: "Existing Paper",
                        authors: "Author",
                        message: dummyMessage
                    ),
                    existingCiteKey: "Existing2024",
                    existingTitle: "Existing Paper",
                    matchType: .citeKey
                )
            ],
            parseErrors: [],
            libraryConflicts: []
        )

        XCTAssertEqual(preview.totalItemCount, 3)  // 2 publications + 1 duplicate
        XCTAssertEqual(preview.publications.count, 2)
        XCTAssertEqual(preview.duplicates.count, 1)
    }

    // MARK: - Library Import Preview Tests

    func testLibraryImportPreview() {
        let metadata = LibraryMetadata(
            libraryID: UUID(),
            name: "Test Library",
            libraryType: .user
        )

        let preview = LibraryImportPreview(
            id: UUID(),
            metadata: metadata,
            publicationCount: 50,
            isNew: true
        )

        XCTAssertEqual(preview.metadata.name, "Test Library")
        XCTAssertEqual(preview.publicationCount, 50)
        XCTAssertTrue(preview.isNew)
    }

    // MARK: - Import Result Tests

    func testImportResultSummary() {
        let result = EverythingImportResult(
            librariesCreated: 2,
            librariesMerged: 1,
            collectionsCreated: 5,
            smartSearchesCreated: 3,
            publicationsImported: 100,
            publicationsSkipped: 10,
            publicationsMerged: 5,
            mutedItemsImported: 3,
            dismissedPapersImported: 15,
            errors: []
        )

        XCTAssertFalse(result.hasErrors)
        XCTAssertTrue(result.summary.contains("created"))
        XCTAssertTrue(result.summary.contains("imported"))
    }

    func testImportResultWithErrors() {
        let result = EverythingImportResult(
            librariesCreated: 1,
            publicationsImported: 50,
            errors: [
                MboxImportErrorInfo(citeKey: "Test2024", description: "Parse error")
            ]
        )

        XCTAssertTrue(result.hasErrors)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.summary.contains("error"))
    }

    // MARK: - Export Version Tests

    func testExportVersionRawValues() {
        XCTAssertEqual(ExportVersion.singleLibrary.rawValue, "1.0")
        XCTAssertEqual(ExportVersion.everything.rawValue, "2.0")
        XCTAssertEqual(ExportVersion.unknown.rawValue, "unknown")
    }

    // MARK: - Import Error Tests

    func testEverythingImportErrorDescription() {
        let wrongVersionError = EverythingImportError.wrongExportVersion(.singleLibrary)
        XCTAssertTrue(wrongVersionError.errorDescription?.contains("not an Everything export") ?? false)

        let parseError = EverythingImportError.parseError("Invalid JSON")
        XCTAssertTrue(parseError.errorDescription?.contains("Parse error") ?? false)

        let saveError = EverythingImportError.saveError("Database error")
        XCTAssertTrue(saveError.errorDescription?.contains("Save error") ?? false)
    }

    // MARK: - Version Detection Tests

    func testVersionDetectionEverything() async throws {
        // Create an Everything export mbox content
        let mboxContent = """
        From imbib@imbib.local Thu Jan 01 00:00:00 1970
        From: imbib@imbib.local
        Subject: [imbib Everything Export]
        Date: Thu, 01 Jan 1970 00:00:00 +0000
        Message-ID: <manifest-test@imbib.local>
        X-Imbib-Export-Type: everything
        X-Imbib-Manifest-Version: 2.0
        Content-Type: text/plain; charset=utf-8

        {"manifestVersion":"2.0","libraries":[],"mutedItems":[],"dismissedPapers":[],"totalPublications":0}

        From imbib@imbib.local Thu Jan 01 00:00:00 1970
        From: imbib@imbib.local
        Subject: [imbib Library Export]
        Date: Thu, 01 Jan 1970 00:00:00 +0000
        Message-ID: <library-test@imbib.local>
        X-Imbib-Library-ID: 550E8400-E29B-41D4-A716-446655440000
        X-Imbib-Library-Type: user
        Content-Type: text/plain; charset=utf-8

        {}
        """

        let parser = MboxParser()
        let messages = try await parser.parseContent(mboxContent)

        // Check that manifest is detected
        let hasManifest = messages.contains { $0.headers[MboxHeader.exportType] == "everything" }
        XCTAssertTrue(hasManifest)
    }

    func testVersionDetectionSingleLibrary() async throws {
        // Create a single library export mbox content
        let mboxContent = """
        From imbib@imbib.local Thu Jan 01 00:00:00 1970
        From: imbib@imbib.local
        Subject: [imbib Library Export]
        Date: Thu, 01 Jan 1970 00:00:00 +0000
        Message-ID: <library-test@imbib.local>
        X-Imbib-Library-ID: 550E8400-E29B-41D4-A716-446655440000
        X-Imbib-Export-Version: 1.0
        Content-Type: text/plain; charset=utf-8

        {}
        """

        let parser = MboxParser()
        let messages = try await parser.parseContent(mboxContent)

        // Check that it's detected as single library (no Everything manifest)
        let hasManifest = messages.contains { $0.headers[MboxHeader.exportType] == "everything" }
        let hasLibraryHeader = messages.contains { $0.subject == "[imbib Library Export]" }

        XCTAssertFalse(hasManifest)
        XCTAssertTrue(hasLibraryHeader)
    }
}

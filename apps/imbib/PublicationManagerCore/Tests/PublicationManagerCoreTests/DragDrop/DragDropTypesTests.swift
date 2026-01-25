//
//  DragDropTypesTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-16.
//

import XCTest
@testable import PublicationManagerCore

final class DragDropTypesTests: XCTestCase {

    // MARK: - DropTarget Tests

    func testDropTarget_library_hasCorrectLibraryID() {
        let libraryID = UUID()
        let target = DropTarget.library(libraryID: libraryID)

        XCTAssertEqual(target.libraryID, libraryID)
    }

    func testDropTarget_collection_hasCorrectLibraryID() {
        let libraryID = UUID()
        let collectionID = UUID()
        let target = DropTarget.collection(collectionID: collectionID, libraryID: libraryID)

        XCTAssertEqual(target.libraryID, libraryID)
    }

    func testDropTarget_publication_hasCorrectLibraryID() {
        let libraryID = UUID()
        let publicationID = UUID()
        let target = DropTarget.publication(publicationID: publicationID, libraryID: libraryID)

        XCTAssertEqual(target.libraryID, libraryID)
    }

    func testDropTarget_newLibraryZone_hasNilLibraryID() {
        let target = DropTarget.newLibraryZone
        XCTAssertNil(target.libraryID)
    }

    func testDropTarget_inbox_hasNilLibraryID() {
        let target = DropTarget.inbox
        XCTAssertNil(target.libraryID)
    }

    func testDropTarget_equatable() {
        let id = UUID()
        let target1 = DropTarget.library(libraryID: id)
        let target2 = DropTarget.library(libraryID: id)
        let target3 = DropTarget.library(libraryID: UUID())

        XCTAssertEqual(target1, target2)
        XCTAssertNotEqual(target1, target3)
    }

    // MARK: - DropValidation Tests

    func testDropValidation_invalid_returnsCorrectState() {
        let validation = DropValidation.invalid
        XCTAssertFalse(validation.isValid)
    }

    func testDropValidation_valid_returnsCorrectState() {
        let validation = DropValidation(
            isValid: true,
            category: .pdf,
            badgeText: "Import",
            badgeIcon: "doc.fill"
        )

        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.category, .pdf)
        XCTAssertEqual(validation.badgeText, "Import")
        XCTAssertEqual(validation.badgeIcon, "doc.fill")
    }

    // MARK: - DroppedFileCategory Tests

    func testDroppedFileCategory_displayName() {
        XCTAssertEqual(DroppedFileCategory.pdf.displayName, "PDF")
        XCTAssertEqual(DroppedFileCategory.bibtex.displayName, "BibTeX")
        XCTAssertEqual(DroppedFileCategory.ris.displayName, "RIS")
        XCTAssertEqual(DroppedFileCategory.publicationTransfer.displayName, "Publication")
        XCTAssertEqual(DroppedFileCategory.attachment.displayName, "File")
        XCTAssertEqual(DroppedFileCategory.unknown.displayName, "Item")
    }

    func testDroppedFileCategory_hashable() {
        var set = Set<DroppedFileCategory>()
        set.insert(.pdf)
        set.insert(.bibtex)
        set.insert(.pdf)  // Duplicate

        XCTAssertEqual(set.count, 2)
        XCTAssertTrue(set.contains(.pdf))
        XCTAssertTrue(set.contains(.bibtex))
    }

    // MARK: - DropResult Tests

    func testDropResult_success_isSuccessTrue() {
        let result = DropResult.success(message: "Done")
        XCTAssertTrue(result.isSuccess)
    }

    func testDropResult_failure_isSuccessFalse() {
        let result = DropResult.failure(error: DragDropError.noFilesFound)
        XCTAssertFalse(result.isSuccess)
    }

    func testDropResult_needsConfirmation_isSuccessFalse() {
        let result = DropResult.needsConfirmation
        XCTAssertFalse(result.isSuccess)
    }

    func testDropResult_processing_isSuccessFalse() {
        let result = DropResult.processing
        XCTAssertFalse(result.isSuccess)
    }

    // MARK: - ImportItemStatus Tests

    func testImportItemStatus_displayText() {
        XCTAssertEqual(ImportItemStatus.pending.displayText, "Pending")
        XCTAssertEqual(ImportItemStatus.extractingMetadata.displayText, "Extracting...")
        XCTAssertEqual(ImportItemStatus.enriching.displayText, "Looking up...")
        XCTAssertEqual(ImportItemStatus.ready.displayText, "Ready")
        XCTAssertEqual(ImportItemStatus.importing.displayText, "Importing...")
        XCTAssertEqual(ImportItemStatus.completed.displayText, "Imported")
        XCTAssertEqual(ImportItemStatus.skipped.displayText, "Skipped")

        let failed = ImportItemStatus.failed(DragDropError.noFilesFound)
        XCTAssertEqual(failed.displayText, "Failed")
    }

    // MARK: - ImportAction Tests

    func testImportAction_allCases() {
        let cases = ImportAction.allCases
        XCTAssertEqual(cases.count, 4)
        XCTAssertTrue(cases.contains(.importAsNew))
        XCTAssertTrue(cases.contains(.attachToExisting))
        XCTAssertTrue(cases.contains(.skip))
        XCTAssertTrue(cases.contains(.replace))
    }

    // MARK: - PDFImportPreview Tests

    func testPDFImportPreview_identifiable() {
        let preview = PDFImportPreview(
            sourceURL: URL(fileURLWithPath: "/tmp/test.pdf"),
            filename: "test.pdf",
            fileSize: 1024
        )

        XCTAssertNotNil(preview.id)
    }

    func testPDFImportPreview_defaultValues() {
        let preview = PDFImportPreview(
            sourceURL: URL(fileURLWithPath: "/tmp/test.pdf"),
            filename: "test.pdf",
            fileSize: 1024
        )

        XCTAssertFalse(preview.isDuplicate)
        XCTAssertNil(preview.existingPublication)
        XCTAssertNil(preview.extractedMetadata)
        XCTAssertNil(preview.enrichedMetadata)
    }

    // MARK: - BibFileFormat Tests

    func testBibFileFormat_fileExtensions() {
        XCTAssertTrue(BibFileFormat.bibtex.fileExtensions.contains("bib"))
        XCTAssertTrue(BibFileFormat.bibtex.fileExtensions.contains("bibtex"))
        XCTAssertTrue(BibFileFormat.ris.fileExtensions.contains("ris"))
    }

    // MARK: - BibImportEntry Tests

    func testBibImportEntry_identifiable() {
        let entry = BibImportEntry(
            citeKey: "Test2024",
            entryType: "article"
        )

        XCTAssertNotNil(entry.id)
    }

    func testBibImportEntry_defaultValues() {
        let entry = BibImportEntry(
            citeKey: "Test2024",
            entryType: "article"
        )

        XCTAssertNil(entry.title)
        XCTAssertTrue(entry.authors.isEmpty)
        XCTAssertNil(entry.year)
        XCTAssertTrue(entry.isSelected)
        XCTAssertFalse(entry.isDuplicate)
        XCTAssertNil(entry.existingPublicationID)
    }

    // MARK: - EnrichedMetadata Tests

    func testEnrichedMetadata_creation() {
        let metadata = EnrichedMetadata(
            title: "Test Paper",
            authors: ["Author One", "Author Two"],
            year: 2024,
            journal: "Test Journal",
            doi: "10.1234/test",
            source: "TestSource"
        )

        XCTAssertEqual(metadata.title, "Test Paper")
        XCTAssertEqual(metadata.authors.count, 2)
        XCTAssertEqual(metadata.year, 2024)
        XCTAssertEqual(metadata.journal, "Test Journal")
        XCTAssertEqual(metadata.doi, "10.1234/test")
        XCTAssertEqual(metadata.source, "TestSource")
    }

    // MARK: - DropPreviewData Tests

    func testDropPreviewData_pdfImport_id() {
        let preview = PDFImportPreview(
            sourceURL: URL(fileURLWithPath: "/tmp/test.pdf"),
            filename: "test.pdf",
            fileSize: 1024
        )

        let data = DropPreviewData.pdfImport([preview])
        XCTAssertTrue(data.id.hasPrefix("pdf-"))
    }

    func testDropPreviewData_bibImport_id() {
        let preview = BibImportPreview(
            sourceURL: URL(fileURLWithPath: "/tmp/test.bib"),
            format: .bibtex,
            entries: []
        )

        let data = DropPreviewData.bibImport(preview)
        XCTAssertTrue(data.id.hasPrefix("bib-"))
    }

    // MARK: - PDFExtractedMetadata Tests

    func testPDFExtractedMetadata_hasIdentifier_withDOI() {
        let metadata = PDFExtractedMetadata(extractedDOI: "10.1234/test")
        XCTAssertTrue(metadata.hasIdentifier)
    }

    func testPDFExtractedMetadata_hasIdentifier_withArXiv() {
        let metadata = PDFExtractedMetadata(extractedArXivID: "2401.12345")
        XCTAssertTrue(metadata.hasIdentifier)
    }

    func testPDFExtractedMetadata_hasIdentifier_withBibcode() {
        let metadata = PDFExtractedMetadata(extractedBibcode: "2024ApJ...123..456A")
        XCTAssertTrue(metadata.hasIdentifier)
    }

    func testPDFExtractedMetadata_hasIdentifier_none() {
        let metadata = PDFExtractedMetadata()
        XCTAssertFalse(metadata.hasIdentifier)
    }

    func testPDFExtractedMetadata_bestTitle_prefersDocumentTitle() {
        let metadata = PDFExtractedMetadata(
            title: "Document Title",
            firstPageText: "First Page Title"
        )
        XCTAssertEqual(metadata.bestTitle, "Document Title")
    }

    func testPDFExtractedMetadata_bestTitle_ignoresUntitled() {
        let metadata = PDFExtractedMetadata(title: "Untitled")
        XCTAssertNil(metadata.bestTitle)
    }

    func testPDFExtractedMetadata_bestTitle_ignoresEmpty() {
        let metadata = PDFExtractedMetadata(title: "")
        XCTAssertNil(metadata.bestTitle)
    }

    // MARK: - MetadataConfidence Tests

    func testMetadataConfidence_comparable() {
        XCTAssertTrue(MetadataConfidence.none < MetadataConfidence.low)
        XCTAssertTrue(MetadataConfidence.low < MetadataConfidence.medium)
        XCTAssertTrue(MetadataConfidence.medium < MetadataConfidence.high)
    }
}

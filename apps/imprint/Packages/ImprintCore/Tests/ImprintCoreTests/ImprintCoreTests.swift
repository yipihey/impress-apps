import XCTest
@testable import ImprintCore

final class ImprintCoreTests: XCTestCase {

    // MARK: - Document Creation Tests

    func testDocumentCreation() {
        let doc = ImprintCoreDocument()
        XCTAssertEqual(doc.source, "")
    }

    func testDocumentCreationWithMetadata() {
        let doc = ImprintCoreDocument()
        XCTAssertEqual(doc.metadata.title, "")
        XCTAssertEqual(doc.metadata.authors, [])
        XCTAssertEqual(doc.editMode, .splitView)
    }

    // MARK: - Text Operations Tests

    func testInsertText() {
        let doc = ImprintCoreDocument()
        doc.insertText("Hello", at: 0)
        XCTAssertEqual(doc.source, "Hello")

        doc.insertText(" World", at: 5)
        XCTAssertEqual(doc.source, "Hello World")
    }

    func testInsertTextAtMiddle() {
        let doc = ImprintCoreDocument()
        doc.source = "HelloWorld"
        doc.insertText(" ", at: 5)
        XCTAssertEqual(doc.source, "Hello World")
    }

    func testInsertTextAtInvalidPosition() {
        let doc = ImprintCoreDocument()
        doc.source = "Hello"
        doc.insertText("X", at: -1)  // Invalid position
        XCTAssertEqual(doc.source, "Hello")  // Should be unchanged

        doc.insertText("X", at: 100)  // Beyond end
        XCTAssertEqual(doc.source, "Hello")  // Should be unchanged
    }

    func testDeleteText() {
        let doc = ImprintCoreDocument()
        doc.source = "Hello World"

        doc.deleteText(from: 5, to: 11)
        XCTAssertEqual(doc.source, "Hello")
    }

    func testDeleteTextFromMiddle() {
        let doc = ImprintCoreDocument()
        doc.source = "Hello Beautiful World"
        doc.deleteText(from: 6, to: 16)
        XCTAssertEqual(doc.source, "Hello World")
    }

    func testDeleteTextInvalidRange() {
        let doc = ImprintCoreDocument()
        doc.source = "Hello"

        doc.deleteText(from: -1, to: 3)  // Invalid start
        XCTAssertEqual(doc.source, "Hello")

        doc.deleteText(from: 3, to: 100)  // Beyond end
        XCTAssertEqual(doc.source, "Hello")

        doc.deleteText(from: 4, to: 2)  // Start > end
        XCTAssertEqual(doc.source, "Hello")
    }

    // MARK: - Document Serialization Tests

    func testDocumentToBytes() {
        let doc = ImprintCoreDocument()
        doc.source = "Test content"
        let data = doc.toBytes()
        XCTAssertEqual(String(data: data, encoding: .utf8), "Test content")
    }

    func testDocumentFromBytes() throws {
        let sourceText = "Loaded from bytes"
        let data = sourceText.data(using: .utf8)!
        let doc = try ImprintCoreDocument.fromBytes(data)
        XCTAssertEqual(doc.source, sourceText)
    }

    func testDocumentFromEmptyBytes() throws {
        let doc = try ImprintCoreDocument.fromBytes(Data())
        XCTAssertEqual(doc.source, "")
    }

    // MARK: - Selection Tests

    func testSelection() {
        let cursor = Selection.cursor(5)
        XCTAssertEqual(cursor.anchor, 5)
        XCTAssertEqual(cursor.head, 5)
        XCTAssertTrue(cursor.isEmpty)

        let range = Selection(anchor: 0, head: 10)
        XCTAssertEqual(range.start, 0)
        XCTAssertEqual(range.end, 10)
        XCTAssertFalse(range.isEmpty)
    }

    func testSelectionReversed() {
        // Selection with head before anchor
        let range = Selection(anchor: 10, head: 0)
        XCTAssertEqual(range.start, 0)  // start should be min
        XCTAssertEqual(range.end, 10)   // end should be max
        XCTAssertFalse(range.isEmpty)
    }

    func testSelectionSet() {
        let primary = Selection(anchor: 0, head: 5)
        let selectionSet = SelectionSet(primary: primary)

        XCTAssertEqual(selectionSet.selections.count, 1)
        XCTAssertEqual(selectionSet.primaryIndex, 0)
        XCTAssertEqual(selectionSet.primary.anchor, 0)
        XCTAssertEqual(selectionSet.primary.head, 5)
    }

    // MARK: - Edit Mode Tests

    func testEditModeCycle() {
        var mode = DocumentEditMode.splitView

        mode.cycle()
        XCTAssertEqual(mode, .textOnly)

        mode.cycle()
        XCTAssertEqual(mode, .directPdf)

        mode.cycle()
        XCTAssertEqual(mode, .splitView)
    }

    func testEditModeRawValues() {
        XCTAssertEqual(DocumentEditMode.directPdf.rawValue, "direct_pdf")
        XCTAssertEqual(DocumentEditMode.splitView.rawValue, "split_view")
        XCTAssertEqual(DocumentEditMode.textOnly.rawValue, "text_only")
    }

    func testEditModeAllCases() {
        XCTAssertEqual(DocumentEditMode.allCases.count, 3)
        XCTAssertTrue(DocumentEditMode.allCases.contains(.directPdf))
        XCTAssertTrue(DocumentEditMode.allCases.contains(.splitView))
        XCTAssertTrue(DocumentEditMode.allCases.contains(.textOnly))
    }

    // MARK: - Metadata Tests

    func testDocumentMetadataDefaults() {
        let metadata = DocumentMetadata()
        XCTAssertEqual(metadata.title, "")
        XCTAssertEqual(metadata.authors, [])
    }

    func testDocumentMetadataInitialization() {
        let metadata = DocumentMetadata(
            title: "My Paper",
            authors: ["Alice", "Bob"]
        )
        XCTAssertEqual(metadata.title, "My Paper")
        XCTAssertEqual(metadata.authors, ["Alice", "Bob"])
    }

    // MARK: - Citation Tests

    func testCitationReference() {
        let citation = CitationReference(
            citeKey: "einstein1905",
            publicationId: "123",
            title: "On the Electrodynamics of Moving Bodies",
            authorsShort: "Einstein",
            year: 1905,
            bibtex: "@article{einstein1905}"
        )

        XCTAssertEqual(citation.typstCitation, "@einstein1905")
        XCTAssertEqual(citation.latexCitation, "\\cite{einstein1905}")
    }

    func testCitationReferenceNilYear() {
        let citation = CitationReference(
            citeKey: "unknown",
            publicationId: "456",
            title: "Unknown Publication",
            authorsShort: "Author",
            year: nil,
            bibtex: "@misc{unknown}"
        )

        XCTAssertNil(citation.year)
        XCTAssertEqual(citation.typstCitation, "@unknown")
    }

    func testCitationReferenceHashable() {
        let citation1 = CitationReference(
            citeKey: "test1",
            publicationId: "1",
            title: "Test",
            authorsShort: "Author",
            year: 2024,
            bibtex: "@article{test1}"
        )
        let citation2 = CitationReference(
            citeKey: "test2",
            publicationId: "2",
            title: "Test 2",
            authorsShort: "Author",
            year: 2024,
            bibtex: "@article{test2}"
        )

        var set: Set<CitationReference> = []
        set.insert(citation1)
        set.insert(citation2)
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - LaTeX Conversion Tests

    func testLatexDetection() {
        let converter = LatexConverter()

        XCTAssertTrue(converter.isLatex("\\section{Introduction}"))
        XCTAssertTrue(converter.isLatex("\\cite{smith2024}"))
        XCTAssertTrue(converter.isLatex("\\begin{document}"))
        XCTAssertTrue(converter.isLatex("\\textbf{bold}"))
        XCTAssertFalse(converter.isLatex("= Introduction"))
        XCTAssertFalse(converter.isLatex("@smith2024"))
        XCTAssertFalse(converter.isLatex("Plain text"))
    }

    func testJournalTemplates() {
        XCTAssertEqual(LatexConverter.JournalTemplate.generic.rawValue, "article")
        XCTAssertEqual(LatexConverter.JournalTemplate.mnras.rawValue, "mnras")
        XCTAssertEqual(LatexConverter.JournalTemplate.apj.rawValue, "aastex")
        XCTAssertEqual(LatexConverter.JournalTemplate.aa.rawValue, "aa")
        XCTAssertEqual(LatexConverter.JournalTemplate.physrevd.rawValue, "revtex4")
        XCTAssertEqual(LatexConverter.JournalTemplate.jcap.rawValue, "jcap")
    }

    // MARK: - Render Options Tests

    func testRenderOptionsDefaults() {
        let options = RenderOptions()
        XCTAssertEqual(options.pageSize, .a4)
        XCTAssertFalse(options.isDraft)
    }

    func testRenderOptionsCustom() {
        let options = RenderOptions(pageSize: .letter, isDraft: true)
        XCTAssertEqual(options.pageSize, .letter)
        XCTAssertTrue(options.isDraft)
    }

    func testPageSizeRawValues() {
        XCTAssertEqual(RenderOptions.PageSize.a4.rawValue, "a4")
        XCTAssertEqual(RenderOptions.PageSize.letter.rawValue, "us-letter")
        XCTAssertEqual(RenderOptions.PageSize.a5.rawValue, "a5")
    }

    // MARK: - Source Map Entry Tests

    func testSourceMapEntryCreation() {
        let entry = SourceMapEntry(
            sourceStart: 0,
            sourceEnd: 10,
            page: 0,
            x: 72.0,
            y: 100.0,
            width: 200.0,
            height: 20.0,
            contentType: .text
        )

        XCTAssertEqual(entry.sourceStart, 0)
        XCTAssertEqual(entry.sourceEnd, 10)
        XCTAssertEqual(entry.page, 0)
        XCTAssertEqual(entry.x, 72.0)
        XCTAssertEqual(entry.y, 100.0)
        XCTAssertEqual(entry.width, 200.0)
        XCTAssertEqual(entry.height, 20.0)
        XCTAssertEqual(entry.contentType, .text)
    }

    func testSourceMapContentTypes() {
        let types: [SourceMapContentType] = [
            .text, .heading, .math, .code,
            .figure, .table, .citation, .listItem, .other
        ]
        XCTAssertEqual(types.count, 9)

        // Test raw values
        XCTAssertEqual(SourceMapContentType.text.rawValue, "text")
        XCTAssertEqual(SourceMapContentType.heading.rawValue, "heading")
        XCTAssertEqual(SourceMapContentType.math.rawValue, "math")
        XCTAssertEqual(SourceMapContentType.code.rawValue, "code")
    }

    // MARK: - Render Region Tests

    func testRenderRegionCreation() {
        let region = RenderRegion(
            page: 0,
            x: 100.0,
            y: 200.0,
            width: 50.0,
            height: 20.0
        )

        XCTAssertEqual(region.page, 0)
        XCTAssertEqual(region.x, 100.0)
        XCTAssertEqual(region.y, 200.0)
        XCTAssertEqual(region.width, 50.0)
        XCTAssertEqual(region.height, 20.0)
    }

    func testRenderRegionCenter() {
        let region = RenderRegion(
            page: 0,
            x: 100.0,
            y: 200.0,
            width: 50.0,
            height: 20.0
        )

        let center = region.center
        XCTAssertEqual(center.x, 125.0)  // 100 + 50/2
        XCTAssertEqual(center.y, 210.0)  // 200 + 20/2
    }

    func testRenderRegionCenterAtOrigin() {
        let region = RenderRegion(
            page: 0,
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 100.0
        )

        let center = region.center
        XCTAssertEqual(center.x, 50.0)
        XCTAssertEqual(center.y, 50.0)
    }

    // MARK: - Source Map Lookup Result Tests

    func testSourceMapLookupResultFound() {
        let result = SourceMapLookupResult(
            sourceOffset: 42,
            found: true,
            contentType: .heading
        )

        XCTAssertEqual(result.sourceOffset, 42)
        XCTAssertTrue(result.found)
        XCTAssertEqual(result.contentType, .heading)
    }

    func testSourceMapLookupResultNotFound() {
        let result = SourceMapLookupResult(
            sourceOffset: 0,
            found: false,
            contentType: .other
        )

        XCTAssertFalse(result.found)
    }

    // MARK: - Render Position Tests

    func testRenderPositionDefaults() {
        let pos = RenderPosition()
        XCTAssertEqual(pos.page, 0)
        XCTAssertEqual(pos.x, 0)
        XCTAssertEqual(pos.y, 0)
    }

    func testRenderPositionCustom() {
        let pos = RenderPosition(page: 2, x: 150.0, y: 300.0)
        XCTAssertEqual(pos.page, 2)
        XCTAssertEqual(pos.x, 150.0)
        XCTAssertEqual(pos.y, 300.0)
    }

    // MARK: - Source Span Tests

    func testSourceSpan() {
        let span = SourceSpan(start: 10, end: 20)
        XCTAssertEqual(span.start, 10)
        XCTAssertEqual(span.end, 20)
    }

    // MARK: - Version Info Tests

    func testVersionInfo() {
        let version = ImprintCoreVersion.string
        XCTAssertFalse(version.isEmpty)
        XCTAssertTrue(version.contains("."))
    }

    func testVersionComponents() {
        XCTAssertGreaterThanOrEqual(ImprintCoreVersion.major, 0)
        XCTAssertGreaterThanOrEqual(ImprintCoreVersion.minor, 0)
        XCTAssertGreaterThanOrEqual(ImprintCoreVersion.patch, 0)
    }

    // MARK: - Error Types Tests

    func testImprintErrorCases() {
        let docError = ImprintError.documentError("Test document error")
        let renderError = ImprintError.renderError("Test render error")
        let exportError = ImprintError.exportError("Test export error")
        let syncError = ImprintError.syncError("Test sync error")

        // Verify errors can be created
        if case .documentError(let msg) = docError {
            XCTAssertEqual(msg, "Test document error")
        } else {
            XCTFail("Expected documentError")
        }

        if case .renderError(let msg) = renderError {
            XCTAssertEqual(msg, "Test render error")
        } else {
            XCTFail("Expected renderError")
        }

        if case .exportError(let msg) = exportError {
            XCTAssertEqual(msg, "Test export error")
        } else {
            XCTFail("Expected exportError")
        }

        if case .syncError(let msg) = syncError {
            XCTAssertEqual(msg, "Test sync error")
        } else {
            XCTFail("Expected syncError")
        }
    }
}

// MARK: - Source Map Utils Integration Tests

/// Tests for SourceMapUtils that require the Rust FFI
final class SourceMapUtilsTests: XCTestCase {

    func testSourceMapLookupEmptyEntries() {
        let result = SourceMapUtils.lookup(entries: [], page: 0, x: 100, y: 100)
        XCTAssertFalse(result.found)
    }

    func testSourceMapLookupWithEntries() {
        let entries = [
            SourceMapEntry(
                sourceStart: 0,
                sourceEnd: 10,
                page: 0,
                x: 72.0,
                y: 100.0,
                width: 200.0,
                height: 20.0,
                contentType: .text
            ),
            SourceMapEntry(
                sourceStart: 11,
                sourceEnd: 25,
                page: 0,
                x: 72.0,
                y: 130.0,
                width: 200.0,
                height: 20.0,
                contentType: .heading
            )
        ]

        // Click inside first entry
        let result1 = SourceMapUtils.lookup(entries: entries, page: 0, x: 150.0, y: 110.0)
        if result1.found {
            XCTAssertEqual(result1.contentType, .text)
        }

        // Click inside second entry
        let result2 = SourceMapUtils.lookup(entries: entries, page: 0, x: 150.0, y: 140.0)
        if result2.found {
            XCTAssertEqual(result2.contentType, .heading)
        }
    }

    func testSourceMapLookupWrongPage() {
        let entries = [
            SourceMapEntry(
                sourceStart: 0,
                sourceEnd: 10,
                page: 0,
                x: 72.0,
                y: 100.0,
                width: 200.0,
                height: 20.0,
                contentType: .text
            )
        ]

        // Click on wrong page
        let result = SourceMapUtils.lookup(entries: entries, page: 1, x: 150.0, y: 110.0)
        XCTAssertFalse(result.found)
    }

    func testSourceToRenderEmptyEntries() {
        let result = SourceMapUtils.sourceToRender(entries: [], sourceOffset: 5)
        XCTAssertNil(result)
    }

    func testSourceToRenderWithEntries() {
        let entries = [
            SourceMapEntry(
                sourceStart: 0,
                sourceEnd: 10,
                page: 0,
                x: 72.0,
                y: 100.0,
                width: 200.0,
                height: 20.0,
                contentType: .text
            ),
            SourceMapEntry(
                sourceStart: 11,
                sourceEnd: 25,
                page: 0,
                x: 72.0,
                y: 130.0,
                width: 200.0,
                height: 20.0,
                contentType: .heading
            )
        ]

        // Cursor in first entry
        if let result = SourceMapUtils.sourceToRender(entries: entries, sourceOffset: 5) {
            XCTAssertEqual(result.page, 0)
            XCTAssertEqual(result.x, 72.0)
            XCTAssertEqual(result.y, 100.0)
            XCTAssertEqual(result.width, 200.0)
            XCTAssertEqual(result.height, 20.0)
        }

        // Cursor in second entry
        if let result = SourceMapUtils.sourceToRender(entries: entries, sourceOffset: 15) {
            XCTAssertEqual(result.page, 0)
            XCTAssertEqual(result.y, 130.0)
        }
    }

    func testSourceToRenderOutsideRange() {
        let entries = [
            SourceMapEntry(
                sourceStart: 10,
                sourceEnd: 20,
                page: 0,
                x: 72.0,
                y: 100.0,
                width: 200.0,
                height: 20.0,
                contentType: .text
            )
        ]

        // Cursor before any entry - should snap to nearest entry
        let result1 = SourceMapUtils.sourceToRender(entries: entries, sourceOffset: 5)
        XCTAssertNotNil(result1)  // Returns nearest entry for cursor sync
        XCTAssertEqual(result1?.page, 0)

        // Cursor after all entries - should snap to nearest entry
        let result2 = SourceMapUtils.sourceToRender(entries: entries, sourceOffset: 25)
        XCTAssertNotNil(result2)  // Returns nearest entry for cursor sync
        XCTAssertEqual(result2?.page, 0)

        // Empty entries should return nil
        let result3 = SourceMapUtils.sourceToRender(entries: [], sourceOffset: 5)
        XCTAssertNil(result3)
    }

    func testSourceToRenderMultiplePages() {
        let entries = [
            SourceMapEntry(
                sourceStart: 0,
                sourceEnd: 100,
                page: 0,
                x: 72.0,
                y: 100.0,
                width: 200.0,
                height: 500.0,
                contentType: .text
            ),
            SourceMapEntry(
                sourceStart: 101,
                sourceEnd: 200,
                page: 1,
                x: 72.0,
                y: 100.0,
                width: 200.0,
                height: 500.0,
                contentType: .text
            )
        ]

        // Cursor on page 0
        if let result = SourceMapUtils.sourceToRender(entries: entries, sourceOffset: 50) {
            XCTAssertEqual(result.page, 0)
        }

        // Cursor on page 1
        if let result = SourceMapUtils.sourceToRender(entries: entries, sourceOffset: 150) {
            XCTAssertEqual(result.page, 1)
        }
    }
}

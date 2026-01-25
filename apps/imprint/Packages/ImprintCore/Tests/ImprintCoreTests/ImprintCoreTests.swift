import XCTest
@testable import ImprintCore

final class ImprintCoreTests: XCTestCase {

    func testDocumentCreation() {
        let doc = ImprintCoreDocument()
        XCTAssertEqual(doc.source, "")
    }

    func testInsertText() {
        let doc = ImprintCoreDocument()
        doc.insertText("Hello", at: 0)
        XCTAssertEqual(doc.source, "Hello")

        doc.insertText(" World", at: 5)
        XCTAssertEqual(doc.source, "Hello World")
    }

    func testDeleteText() {
        let doc = ImprintCoreDocument()
        doc.source = "Hello World"

        doc.deleteText(from: 5, to: 11)
        XCTAssertEqual(doc.source, "Hello")
    }

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

    func testEditModeCycle() {
        var mode = DocumentEditMode.splitView

        mode.cycle()
        XCTAssertEqual(mode, .textOnly)

        mode.cycle()
        XCTAssertEqual(mode, .directPdf)

        mode.cycle()
        XCTAssertEqual(mode, .splitView)
    }

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

    func testLatexDetection() {
        let converter = LatexConverter()

        XCTAssertTrue(converter.isLatex("\\section{Introduction}"))
        XCTAssertTrue(converter.isLatex("\\cite{smith2024}"))
        XCTAssertFalse(converter.isLatex("= Introduction"))
        XCTAssertFalse(converter.isLatex("@smith2024"))
    }

    func testVersionInfo() {
        let version = ImprintCoreVersion.string
        XCTAssertFalse(version.isEmpty)
        XCTAssertTrue(version.contains("."))
    }
}

import XCTest
@testable import imprint

final class ImprintTests: XCTestCase {

    func testDocumentCreation() throws {
        let doc = ImprintDocument()
        XCTAssertEqual(doc.title, "Untitled")
        XCTAssertTrue(doc.bibliography.isEmpty)
    }

    func testInsertText() throws {
        var doc = ImprintDocument()
        doc.insertText("Hello", at: 0)
        XCTAssertTrue(doc.source.contains("Hello"))
    }

    func testAddCitation() throws {
        var doc = ImprintDocument()
        doc.addCitation(key: "smith2024", bibtex: "@article{smith2024}")
        XCTAssertEqual(doc.bibliography["smith2024"], "@article{smith2024}")
    }

    func testInsertCitation() throws {
        var doc = ImprintDocument()
        doc.source = "Some text here."
        doc.insertCitation(key: "smith2024", at: 9)
        XCTAssertTrue(doc.source.contains("@smith2024"))
    }

    func testEditModeCycle() throws {
        var mode = EditMode.splitView

        mode.cycle()
        XCTAssertEqual(mode, .textOnly)

        mode.cycle()
        XCTAssertEqual(mode, .directPdf)

        mode.cycle()
        XCTAssertEqual(mode, .splitView)
    }
}

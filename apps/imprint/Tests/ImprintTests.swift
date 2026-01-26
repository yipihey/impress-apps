import XCTest
import ImprintCore
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

    func testTypstAvailable() throws {
        // Verify Typst rendering is available via Rust FFI
        let available = TypstRenderer.isNativeAvailable
        XCTAssertTrue(available, "Typst should be available via Rust FFI")
    }

    func testTypstVersion() throws {
        // Verify we can get the Typst version string
        let version = TypstRenderer.typstVersion
        XCTAssertFalse(version.isEmpty, "Typst version should not be empty")
        print("Typst version: \(version)")
    }

    func testTypstCompileSimple() async throws {
        // Test basic Typst compilation
        let renderer = TypstRenderer()
        let source = "= Hello World\n\nThis is a test document."

        let output = try await renderer.render(source)

        XCTAssertTrue(output.isSuccess, "Compilation should succeed: \(output.errors)")
        XCTAssertFalse(output.pdfData.isEmpty, "PDF should have data")
        XCTAssertTrue(output.pdfData.starts(with: [0x25, 0x50, 0x44, 0x46]), "PDF should start with %PDF header")
    }
}

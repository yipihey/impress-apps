//
//  PDFValidationTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-16.
//

import XCTest
@testable import PublicationManagerCore

/// Tests for PDF magic byte validation.
///
/// PDF files must start with the magic bytes %PDF (0x25 0x50 0x44 0x46).
/// This is how we detect when a server returns an HTML error page instead
/// of the actual PDF content.
final class PDFValidationTests: XCTestCase {

    // MARK: - Test Helpers

    /// Validate PDF magic bytes (same logic as in DetailView.swift)
    private func isValidPDF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x25 && // %
               data[1] == 0x50 && // P
               data[2] == 0x44 && // D
               data[3] == 0x46    // F
    }

    /// Create valid PDF data with proper header
    private func validPDFData() -> Data {
        let pdfString = """
        %PDF-1.4
        1 0 obj
        << /Type /Catalog /Pages 2 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [] /Count 0 >>
        endobj
        xref
        0 3
        0000000000 65535 f
        0000000009 00000 n
        0000000058 00000 n
        trailer
        << /Size 3 /Root 1 0 R >>
        startxref
        114
        %%EOF
        """
        return pdfString.data(using: .utf8)!
    }

    /// Create HTML data (common error page)
    private func htmlData() -> Data {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Error</title></head>
        <body><h1>404 Not Found</h1></body>
        </html>
        """
        return html.data(using: .utf8)!
    }

    // MARK: - Valid PDF Tests

    func testPDFValidation_validPDF_passes() {
        // Given
        let pdfData = validPDFData()

        // When
        let result = isValidPDF(pdfData)

        // Then
        XCTAssertTrue(result)
    }

    func testPDFValidation_pdfWithDifferentVersion_passes() {
        // Given - PDF version 1.7
        let pdfData = "%PDF-1.7\n...".data(using: .utf8)!

        // When
        let result = isValidPDF(pdfData)

        // Then
        XCTAssertTrue(result)
    }

    func testPDFValidation_pdfWithPDF2_passes() {
        // Given - PDF 2.0 format
        let pdfData = "%PDF-2.0\n...".data(using: .utf8)!

        // When
        let result = isValidPDF(pdfData)

        // Then
        XCTAssertTrue(result)
    }

    func testPDFValidation_minimalValidHeader() {
        // Given - just the magic bytes
        let pdfData = Data([0x25, 0x50, 0x44, 0x46])

        // When
        let result = isValidPDF(pdfData)

        // Then
        XCTAssertTrue(result)
    }

    // MARK: - Invalid Content Tests

    func testPDFValidation_htmlContent_fails() {
        // Given - HTML content (starts with <)
        let htmlData = htmlData()

        // When
        let result = isValidPDF(htmlData)

        // Then
        XCTAssertFalse(result)
        XCTAssertEqual(htmlData[0], 0x3C) // <
    }

    func testPDFValidation_htmlWithDoctype_fails() {
        // Given - HTML with DOCTYPE
        let html = "<!DOCTYPE html><html>...</html>"
        let htmlData = html.data(using: .utf8)!

        // When
        let result = isValidPDF(htmlData)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_jsonContent_fails() {
        // Given - JSON error response
        let json = """
        {"error": "Rate limited", "retry_after": 60}
        """
        let jsonData = json.data(using: .utf8)!

        // When
        let result = isValidPDF(jsonData)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_xmlContent_fails() {
        // Given - XML content
        let xml = "<?xml version=\"1.0\"?><error>Not found</error>"
        let xmlData = xml.data(using: .utf8)!

        // When
        let result = isValidPDF(xmlData)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_plainText_fails() {
        // Given - plain text error message
        let text = "Error: File not found"
        let textData = text.data(using: .utf8)!

        // When
        let result = isValidPDF(textData)

        // Then
        XCTAssertFalse(result)
    }

    // MARK: - Edge Cases

    func testPDFValidation_emptyData_fails() {
        // Given
        let emptyData = Data()

        // When
        let result = isValidPDF(emptyData)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_truncatedHeader_fails() {
        // Given - only 3 bytes (not enough for magic bytes)
        let truncatedData = Data([0x25, 0x50, 0x44])

        // When
        let result = isValidPDF(truncatedData)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_singleByte_fails() {
        // Given
        let singleByte = Data([0x25])

        // When
        let result = isValidPDF(singleByte)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_almostPDF_wrongSecondByte_fails() {
        // Given - starts with % but not PDF
        let notPDF = "%XXX-1.4\n...".data(using: .utf8)!

        // When
        let result = isValidPDF(notPDF)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_binaryGarbage_fails() {
        // Given - random binary data
        let garbage = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG header

        // When
        let result = isValidPDF(garbage)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_jpegFile_fails() {
        // Given - JPEG magic bytes (common mistaken content-type)
        let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

        // When
        let result = isValidPDF(jpegHeader)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_pngFile_fails() {
        // Given - PNG magic bytes
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // When
        let result = isValidPDF(pngHeader)

        // Then
        XCTAssertFalse(result)
    }

    func testPDFValidation_zipFile_fails() {
        // Given - ZIP magic bytes (some servers return .zip by mistake)
        let zipHeader = Data([0x50, 0x4B, 0x03, 0x04])

        // When
        let result = isValidPDF(zipHeader)

        // Then
        XCTAssertFalse(result)
    }

    // MARK: - Magic Byte Value Tests

    func testMagicBytes_correctValues() {
        // Verify the expected magic byte values
        XCTAssertEqual(0x25, UInt8(ascii: "%"))
        XCTAssertEqual(0x50, UInt8(ascii: "P"))
        XCTAssertEqual(0x44, UInt8(ascii: "D"))
        XCTAssertEqual(0x46, UInt8(ascii: "F"))
    }

    func testMagicBytes_inValidPDF() {
        // Given
        let pdfData = validPDFData()

        // Then - verify magic bytes are at the start
        XCTAssertEqual(pdfData[0], 0x25) // %
        XCTAssertEqual(pdfData[1], 0x50) // P
        XCTAssertEqual(pdfData[2], 0x44) // D
        XCTAssertEqual(pdfData[3], 0x46) // F
    }

    // MARK: - HTML Detection Tests

    func testHTMLDetection_startsWithLessThan() {
        // Given - HTML always starts with < (0x3C)
        let htmlData = htmlData()

        // Then
        XCTAssertEqual(htmlData[0], 0x3C) // <
        XCTAssertFalse(isValidPDF(htmlData))
    }

    func testHTMLDetection_rateLimit503Response() {
        // Given - common arXiv rate limit response
        let html = """
        <html>
        <head><title>503 Service Temporarily Unavailable</title></head>
        <body>
        <center><h1>503 Service Temporarily Unavailable</h1></center>
        <hr><center>nginx</center>
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8)!

        // When
        let result = isValidPDF(htmlData)

        // Then
        XCTAssertFalse(result)
    }

    func testHTMLDetection_cloudflareChallenge() {
        // Given - Cloudflare challenge page (sometimes returned instead of PDF)
        let html = """
        <!DOCTYPE HTML>
        <html lang="en-US">
        <head>
            <title>Please Wait... | Cloudflare</title>
        </head>
        <body>
            <h1>Checking your browser before accessing...</h1>
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8)!

        // When
        let result = isValidPDF(htmlData)

        // Then
        XCTAssertFalse(result)
    }
}

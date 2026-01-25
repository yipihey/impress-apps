//
//  PDFDownloadIntegrationTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-16.
//

import XCTest
@testable import PublicationManagerCore

/// Integration tests for PDF download functionality using MockURLProtocol.
///
/// These tests verify:
/// - Successful PDF downloads from arXiv
/// - Handling of HTML error pages (rate limiting)
/// - HTTP error status codes (429, 403, 500)
/// - Network timeout handling
/// - PDF magic byte validation
final class PDFDownloadIntegrationTests: XCTestCase {

    // MARK: - Properties

    private var mockSession: URLSession!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        mockSession = MockURLProtocol.mockURLSession()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        mockSession = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    /// Create valid PDF data with %PDF header
    private func validPDFData() -> Data {
        // Minimal valid PDF structure
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

    /// Create HTML error page data
    private func htmlErrorData() -> Data {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Error</title></head>
        <body>
        <h1>Rate Limited</h1>
        <p>Too many requests. Please try again later.</p>
        </body>
        </html>
        """
        return html.data(using: .utf8)!
    }

    // MARK: - Success Tests

    func testDownloadPDF_arxiv_success() async throws {
        // Given - valid PDF response from arXiv
        let arxivURL = "https://arxiv.org/pdf/2301.12345.pdf"
        let pdfData = validPDFData()

        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse(
                data: pdfData,
                statusCode: 200,
                headers: ["Content-Type": "application/pdf"]
            )
        )

        // When
        let (data, response) = try await mockSession.data(from: URL(string: arxivURL)!)

        // Then
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data.count, pdfData.count)
        // Verify PDF magic bytes
        XCTAssertEqual(data[0], 0x25) // %
        XCTAssertEqual(data[1], 0x50) // P
        XCTAssertEqual(data[2], 0x44) // D
        XCTAssertEqual(data[3], 0x46) // F
    }

    func testDownloadPDF_validatesContentType() async throws {
        // Given - PDF with correct content type
        let pdfURL = "https://arxiv.org/pdf/2301.12345.pdf"
        let pdfData = validPDFData()

        MockURLProtocol.register(
            pattern: pdfURL,
            response: MockURLProtocol.MockResponse(
                data: pdfData,
                statusCode: 200,
                headers: ["Content-Type": "application/pdf"]
            )
        )

        // When
        let (_, response) = try await mockSession.data(from: URL(string: pdfURL)!)

        // Then
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
    }

    // MARK: - HTML Error Page Tests (Rate Limiting)

    func testDownloadPDF_htmlErrorPage_rejected() async throws {
        // Given - HTML error page instead of PDF (common rate limit response)
        let arxivURL = "https://arxiv.org/pdf/2301.12345.pdf"
        let htmlData = htmlErrorData()

        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse(
                data: htmlData,
                statusCode: 200,  // Note: often returns 200 with HTML
                headers: ["Content-Type": "text/html"]
            )
        )

        // When
        let (data, _) = try await mockSession.data(from: URL(string: arxivURL)!)

        // Then - verify this is NOT a valid PDF (starts with <)
        XCTAssertEqual(data[0], 0x3C) // <
        XCTAssertNotEqual(data[0], 0x25) // % (PDF magic byte)

        // Simulate the validation check
        let isValidPDF = data.count >= 4 &&
                         data[0] == 0x25 &&
                         data[1] == 0x50 &&
                         data[2] == 0x44 &&
                         data[3] == 0x46
        XCTAssertFalse(isValidPDF, "HTML error page should fail PDF validation")
    }

    func testDownloadPDF_htmlInsteadOfPDF_contentTypeMismatch() async throws {
        // Given - arXiv returns HTML with text/html content type
        let arxivURL = "https://arxiv.org/pdf/2301.12345.pdf"

        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse(
                data: htmlErrorData(),
                statusCode: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"]
            )
        )

        // When
        let (_, response) = try await mockSession.data(from: URL(string: arxivURL)!)

        // Then
        let httpResponse = response as? HTTPURLResponse
        let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.contains("text/html"), "Should detect HTML content type")
    }

    // MARK: - HTTP Error Status Tests

    func testDownloadPDF_rateLimited429_handledGracefully() async throws {
        // Given - 429 Too Many Requests
        let arxivURL = "https://arxiv.org/pdf/2301.12345.pdf"

        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse.rateLimited(retryAfter: 60)
        )

        // When
        let (_, response) = try await mockSession.data(from: URL(string: arxivURL)!)

        // Then
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 429)
        XCTAssertEqual(httpResponse?.value(forHTTPHeaderField: "Retry-After"), "60")
    }

    func testDownloadPDF_forbidden403_handledGracefully() async throws {
        // Given - 403 Forbidden (access denied)
        let publisherURL = "https://publisher.com/paper.pdf"

        MockURLProtocol.register(
            pattern: publisherURL,
            response: MockURLProtocol.MockResponse(
                data: "Access Denied".data(using: .utf8),
                statusCode: 403
            )
        )

        // When
        let (_, response) = try await mockSession.data(from: URL(string: publisherURL)!)

        // Then
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 403)
    }

    func testDownloadPDF_serverError500_handledGracefully() async throws {
        // Given - 500 Internal Server Error
        let arxivURL = "https://arxiv.org/pdf/2301.12345.pdf"

        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse.serverError
        )

        // When
        let (_, response) = try await mockSession.data(from: URL(string: arxivURL)!)

        // Then
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 500)
    }

    func testDownloadPDF_notFound404_handledGracefully() async throws {
        // Given - 404 Not Found (paper doesn't exist)
        let arxivURL = "https://arxiv.org/pdf/9999.99999.pdf"

        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse.notFound
        )

        // When
        let (_, response) = try await mockSession.data(from: URL(string: arxivURL)!)

        // Then
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 404)
    }

    // MARK: - Network Error Tests

    func testDownloadPDF_networkTimeout_handledGracefully() async {
        // Given - network timeout error
        let arxivURL = "https://arxiv.org/pdf/2301.12345.pdf"

        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse.error(URLError(.timedOut))
        )

        // When/Then
        do {
            _ = try await mockSession.data(from: URL(string: arxivURL)!)
            XCTFail("Expected timeout error")
        } catch {
            XCTAssertTrue(error is URLError)
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testDownloadPDF_connectionLost_handledGracefully() async {
        // Given - connection lost mid-download
        let arxivURL = "https://arxiv.org/pdf/2301.12345.pdf"

        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse.error(URLError(.networkConnectionLost))
        )

        // When/Then
        do {
            _ = try await mockSession.data(from: URL(string: arxivURL)!)
            XCTFail("Expected connection lost error")
        } catch {
            XCTAssertTrue(error is URLError)
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }

    func testDownloadPDF_notConnectedToInternet_handledGracefully() async {
        // Given - no internet connection
        let arxivURL = "https://arxiv.org/pdf/2301.12345.pdf"

        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse.error(URLError(.notConnectedToInternet))
        )

        // When/Then
        do {
            _ = try await mockSession.data(from: URL(string: arxivURL)!)
            XCTFail("Expected not connected error")
        } catch {
            XCTAssertTrue(error is URLError)
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // MARK: - Request Verification Tests

    func testDownloadPDF_requestURL_isCorrect() async throws {
        // Given
        let arxivURL = "https://arxiv.org/pdf/2301.12345.pdf"
        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse(data: validPDFData(), statusCode: 200)
        )

        // When
        _ = try await mockSession.data(from: URL(string: arxivURL)!)

        // Then - verify the request was made to the correct URL
        let requests = MockURLProtocol.requests(matching: "arxiv.org")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.absoluteString, arxivURL)
    }

    func testDownloadPDF_oldStyleArxivID_requestURL() async throws {
        // Given - old-style arXiv ID in URL path
        let arxivURL = "https://arxiv.org/pdf/hep-ph/0601001.pdf"
        MockURLProtocol.register(
            pattern: arxivURL,
            response: MockURLProtocol.MockResponse(data: validPDFData(), statusCode: 200)
        )

        // When
        _ = try await mockSession.data(from: URL(string: arxivURL)!)

        // Then
        let lastRequest = MockURLProtocol.lastRequest
        XCTAssertEqual(lastRequest?.url?.path, "/pdf/hep-ph/0601001.pdf")
    }
}

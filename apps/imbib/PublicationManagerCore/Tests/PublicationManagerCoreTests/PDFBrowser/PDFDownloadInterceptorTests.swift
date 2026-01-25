//
//  PDFDownloadInterceptorTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-06.
//

import XCTest
@testable import PublicationManagerCore

#if canImport(WebKit)

final class PDFDownloadInterceptorTests: XCTestCase {

    var interceptor: PDFDownloadInterceptor!

    override func setUp() {
        super.setUp()
        interceptor = PDFDownloadInterceptor()
    }

    override func tearDown() {
        interceptor = nil
        super.tearDown()
    }

    // MARK: - PDF Magic Byte Detection Tests

    func testIsHTML_withHTMLContent_returnsTrue() {
        let htmlData = Data("<html><body>Error</body></html>".utf8)

        let result = interceptor.isHTML(data: htmlData)

        XCTAssertTrue(result)
    }

    func testIsHTML_withHTMLAndWhitespace_returnsTrue() {
        let htmlData = Data("  \n  <html>".utf8)

        let result = interceptor.isHTML(data: htmlData)

        XCTAssertTrue(result)
    }

    func testIsHTML_withPDFMagicBytes_returnsFalse() {
        let pdfData = Data([0x25, 0x50, 0x44, 0x46]) // %PDF

        let result = interceptor.isHTML(data: pdfData)

        XCTAssertFalse(result)
    }

    func testIsHTML_withEmptyData_returnsFalse() {
        let emptyData = Data()

        let result = interceptor.isHTML(data: emptyData)

        XCTAssertFalse(result)
    }

    // MARK: - Callback Tests

    func testCallbacks_initialized_areNil() {
        XCTAssertNil(interceptor.onPDFDownloaded)
        XCTAssertNil(interceptor.onDownloadStarted)
        XCTAssertNil(interceptor.onDownloadProgress)
        XCTAssertNil(interceptor.onDownloadFailed)
        XCTAssertNil(interceptor.onNonPDFDownloaded)
    }

    func testCallbacks_canBeSet() {
        var pdfDownloadedCalled = false
        var downloadStartedCalled = false
        var progressCalled = false
        var failedCalled = false
        var nonPDFCalled = false

        interceptor.onPDFDownloaded = { _, _ in pdfDownloadedCalled = true }
        interceptor.onDownloadStarted = { _ in downloadStartedCalled = true }
        interceptor.onDownloadProgress = { _ in progressCalled = true }
        interceptor.onDownloadFailed = { _ in failedCalled = true }
        interceptor.onNonPDFDownloaded = { _, _, _ in nonPDFCalled = true }

        interceptor.onPDFDownloaded?("test.pdf", Data())
        interceptor.onDownloadStarted?("test.pdf")
        interceptor.onDownloadProgress?(0.5)
        interceptor.onDownloadFailed?(NSError(domain: "test", code: 1))
        interceptor.onNonPDFDownloaded?("test.html", Data(), "text/html")

        XCTAssertTrue(pdfDownloadedCalled)
        XCTAssertTrue(downloadStartedCalled)
        XCTAssertTrue(progressCalled)
        XCTAssertTrue(failedCalled)
        XCTAssertTrue(nonPDFCalled)
    }
}

#else

// Stub tests for non-WebKit platforms
final class PDFDownloadInterceptorTests: XCTestCase {

    func testStub_existsOnNonWebKitPlatforms() {
        let interceptor = PDFDownloadInterceptor()
        XCTAssertNil(interceptor.onPDFDownloaded)
    }
}

#endif // canImport(WebKit)

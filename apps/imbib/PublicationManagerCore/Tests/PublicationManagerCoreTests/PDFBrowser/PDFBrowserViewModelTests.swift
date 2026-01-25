//
//  PDFBrowserViewModelTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-06.
//

import XCTest
@testable import PublicationManagerCore
import CoreData

#if canImport(WebKit)
import WebKit

@MainActor
final class PDFBrowserViewModelTests: XCTestCase {

    private var persistenceController: PersistenceController!
    var testPublication: CDPublication!

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview
        testPublication = createTestPublication()
    }

    override func tearDown() async throws {
        testPublication = nil
        persistenceController = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInit_setsInitialState() throws {
        let url = URL(string: "https://example.com/pdf")!
        let libraryID = UUID()

        let viewModel = PDFBrowserViewModel(
            publication: testPublication,
            initialURL: url,
            libraryID: libraryID
        )

        XCTAssertEqual(viewModel.currentURL, url)
        XCTAssertEqual(viewModel.initialURL, url)
        XCTAssertEqual(viewModel.libraryID, libraryID)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.canGoBack)
        XCTAssertFalse(viewModel.canGoForward)
        XCTAssertNil(viewModel.detectedPDFData)
        XCTAssertNil(viewModel.detectedPDFFilename)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.downloadProgress)
    }

    // MARK: - State Update Tests

    func testNavigationDidFinish_updatesState() throws {
        let viewModel = createViewModel()

        let newURL = URL(string: "https://example.com/page2")!
        viewModel.navigationDidFinish(url: newURL, title: "Page 2")

        XCTAssertEqual(viewModel.currentURL, newURL)
        XCTAssertEqual(viewModel.pageTitle, "Page 2")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testNavigationDidStart_setsLoadingTrue() throws {
        let viewModel = createViewModel()
        viewModel.isLoading = false

        viewModel.navigationDidStart()

        XCTAssertTrue(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testNavigationDidFail_setsErrorMessage() throws {
        let viewModel = createViewModel()

        let error = NSError(domain: "test", code: 123, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        viewModel.navigationDidFail(error: error)

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.errorMessage, "Test error")
    }

    // MARK: - PDF Detection Tests

    func testPdfDetected_setsDetectedPDF() throws {
        let viewModel = createViewModel()
        viewModel.downloadProgress = 0.5

        let pdfData = Data([0x25, 0x50, 0x44, 0x46]) // %PDF
        viewModel.pdfDetected(filename: "test.pdf", data: pdfData)

        XCTAssertEqual(viewModel.detectedPDFFilename, "test.pdf")
        XCTAssertEqual(viewModel.detectedPDFData, pdfData)
        XCTAssertNil(viewModel.downloadProgress)
    }

    func testClearDetectedPDF_clearsState() throws {
        let viewModel = createViewModel()
        viewModel.detectedPDFFilename = "test.pdf"
        viewModel.detectedPDFData = Data([0x25, 0x50, 0x44, 0x46])

        viewModel.clearDetectedPDF()

        XCTAssertNil(viewModel.detectedPDFFilename)
        XCTAssertNil(viewModel.detectedPDFData)
    }

    func testSaveDetectedPDF_callsCallback() async throws {
        let viewModel = createViewModel()
        let pdfData = Data([0x25, 0x50, 0x44, 0x46])
        viewModel.detectedPDFData = pdfData
        viewModel.detectedPDFFilename = "test.pdf"

        var capturedData: Data?
        viewModel.onPDFCaptured = { data in
            capturedData = data
        }

        await viewModel.saveDetectedPDF()

        XCTAssertEqual(capturedData, pdfData)
        XCTAssertNil(viewModel.detectedPDFData)
        XCTAssertNil(viewModel.detectedPDFFilename)
    }

    func testSaveDetectedPDF_withNoData_doesNothing() async throws {
        let viewModel = createViewModel()
        viewModel.detectedPDFData = nil

        var callbackCalled = false
        viewModel.onPDFCaptured = { _ in
            callbackCalled = true
        }

        await viewModel.saveDetectedPDF()

        XCTAssertFalse(callbackCalled)
    }

    // MARK: - Download Progress Tests

    func testUpdateDownloadProgress_setsProgress() throws {
        let viewModel = createViewModel()

        viewModel.updateDownloadProgress(0.5)

        XCTAssertEqual(viewModel.downloadProgress, 0.5)
    }

    func testDownloadDidStart_resetsProgress() throws {
        let viewModel = createViewModel()

        viewModel.downloadDidStart(filename: "paper.pdf")

        XCTAssertEqual(viewModel.downloadProgress, 0)
    }

    func testDownloadDidFail_setsError() throws {
        let viewModel = createViewModel()
        viewModel.downloadProgress = 0.5

        let error = NSError(domain: "test", code: 456)
        viewModel.downloadDidFail(error: error)

        XCTAssertNil(viewModel.downloadProgress)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.errorMessage!.contains("Download failed"))
    }

    // MARK: - Dismiss Tests

    func testDismiss_callsCallback() throws {
        let viewModel = createViewModel()

        var dismissCalled = false
        viewModel.onDismiss = {
            dismissCalled = true
        }

        viewModel.dismiss()

        XCTAssertTrue(dismissCalled)
    }

    // MARK: - Helpers

    private func createTestPublication() -> CDPublication {
        let pub = CDPublication(context: persistenceController.viewContext)
        pub.id = UUID()
        pub.citeKey = "TestCiteKey2024"
        pub.entryType = "article"
        pub.title = "Test Publication for Browser"
        pub.year = 2024
        pub.dateAdded = Date()
        pub.dateModified = Date()
        pub.fields = [
            "author": "Test Author",
            "bibcode": "2024TEST....1T"
        ]
        return pub
    }

    private func createViewModel() -> PDFBrowserViewModel {
        let url = URL(string: "https://example.com/pdf")!
        return PDFBrowserViewModel(
            publication: testPublication,
            initialURL: url,
            libraryID: UUID()
        )
    }
}

#endif // canImport(WebKit)

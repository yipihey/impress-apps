//
//  PDFImportIntegrityTests.swift
//  PublicationManagerCoreTests
//
//  The 2026-09-11 APS import, pinned. A browser capture stored a truncated PDF
//  (two downloads of the same file shared one temp slot, so the first to
//  finish read the other's half-written bytes), and stored it under the UI's
//  active library rather than the paper's — so Open, Show in Finder and Delete,
//  which look under the paper's library, never found it.
//

import CoreGraphics
import XCTest
@testable import PublicationManagerCore

final class PDFImportIntegrityTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFImportIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A real one-page PDF, written by CoreGraphics.
    static func makePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 120, height: 80))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: - What counts as a PDF

    func testAWholePDFIsCompleteAndItsHeadIsNot() {
        let pdf = Self.makePDF()
        XCTAssertEqual(PDFDataValidator.check(pdf), .complete)
        let head = Data(pdf.prefix(pdf.count / 2))
        XCTAssertTrue(PDFDataValidator.hasPDFHeader(head), "a cut-short download still starts with %PDF")
        guard case .incomplete = PDFDataValidator.check(head) else {
            return XCTFail("the head of a PDF must not pass as a PDF")
        }
    }

    func testHTMLAndShortDownloadsAreRefused() {
        XCTAssertEqual(PDFDataValidator.check(Data("<!DOCTYPE html><html>Sign in</html>".utf8)), .notPDF)
        let pdf = Self.makePDF()
        guard case .incomplete(let reason) = PDFDataValidator.check(pdf, expectedLength: Int64(pdf.count) + 1000) else {
            return XCTFail("fewer bytes than the server announced is an incomplete download")
        }
        XCTAssertTrue(reason.contains("stopped early"), reason)
    }

    // MARK: - Downloads in flight

    func testConcurrentDownloadsOfTheSamePDFKeepTheirOwnBytes() throws {
        let ledger = PDFDownloadLedger(directory: root)
        let first = NSObject()
        let second = NSObject()
        let a = ledger.begin(ObjectIdentifier(first), filename: "PhysRevD.105.023512.pdf", expectedLength: 5)
        let b = ledger.begin(ObjectIdentifier(second), filename: "PhysRevD.105.023512.pdf", expectedLength: 5)
        XCTAssertNotEqual(a, b, "each download writes its own file")
        try Data("AAAAA".utf8).write(to: a)
        try Data("BB".utf8).write(to: b)  // the second is still being written

        let finished = try XCTUnwrap(ledger.finish(ObjectIdentifier(first)))
        XCTAssertEqual(finished.data, Data("AAAAA".utf8), "the first reads its own file, not the other's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path), "and leaves the other's alone")
        XCTAssertEqual(ledger.inFlightCount, 1)

        XCTAssertNotNil(ledger.fail(ObjectIdentifier(second)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertNil(ledger.finish(ObjectIdentifier(second)), "a download is forgotten once it ends")
    }

    // MARK: - Filing and finding

    @MainActor
    func testAPDFIsFiledUnderThePapersOwnLibraryWhateverTheCallerHadInView() throws {
        let store = try RustStoreAdapter(inMemory: true)
        let manager = AttachmentManager(store: store, applicationSupportRoot: root)
        let uldm = try XCTUnwrap(store.createLibrary(name: "ULDM"))
        let inbox = try XCTUnwrap(store.createLibrary(name: "Inbox"))
        let paper = try XCTUnwrap(store.importBibTeX(
            "@article{YavetzLiHui2022, author={Yavetz, Tomer D. and Li, Xinyu and Hui, Lam}, "
                + "title={Construction of wave dark matter halos}, year={2022}}",
            libraryId: uldm.id).first)

        // The browser import asked for the active library (the Inbox).
        let file = try manager.importPDF(data: Self.makePDF(), for: paper, in: inbox.id)

        let underPaper = manager.containerURL(for: uldm.id)
            .appendingPathComponent(try XCTUnwrap(file.relativePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: underPaper.path), "filed under ULDM, not the Inbox")
        XCTAssertEqual(manager.resolveURL(for: file, in: uldm.id), underPaper)
        XCTAssertEqual(manager.resolveURL(for: file, in: inbox.id), underPaper,
                       "found whichever library the caller names")
    }

    @MainActor
    func testATruncatedPDFIsNotImported() throws {
        let store = try RustStoreAdapter(inMemory: true)
        let manager = AttachmentManager(store: store, applicationSupportRoot: root)
        let library = try XCTUnwrap(store.createLibrary(name: "ULDM"))
        let paper = try XCTUnwrap(store.importBibTeX(
            "@article{Truncated2022, title={Truncated}, year={2022}}", libraryId: library.id).first)
        let pdf = Self.makePDF()

        XCTAssertThrowsError(try manager.importPDF(data: Data(pdf.prefix(pdf.count / 2)), for: paper, in: library.id)) { error in
            guard case AttachmentError.unusablePDF = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(store.listLinkedFiles(publicationId: paper).isEmpty, "no record for a PDF that cannot open")
    }

    @MainActor
    func testAFileMisfiledUnderAnotherLibraryIsFoundOnlyWhenItIsTheSameFile() throws {
        let store = try RustStoreAdapter(inMemory: true)
        let manager = AttachmentManager(store: store, applicationSupportRoot: root)
        let uldm = try XCTUnwrap(store.createLibrary(name: "ULDM"))
        let inbox = try XCTUnwrap(store.createLibrary(name: "Inbox"))
        let paper = try XCTUnwrap(store.importBibTeX(
            "@article{Misfiled2022, title={Misfiled}, year={2022}}", libraryId: uldm.id).first)
        let pdf = Self.makePDF()
        // What an import that followed the active library left behind.
        let misfiled = manager.containerURL(for: inbox.id).appendingPathComponent("Papers/Misfiled_2022.pdf")
        try FileManager.default.createDirectory(
            at: misfiled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: misfiled)
        let record = try XCTUnwrap(store.addLinkedFile(
            publicationId: paper, filename: "Misfiled_2022.pdf", relativePath: "Papers/Misfiled_2022.pdf",
            fileType: "pdf", fileSize: Int64(pdf.count), isPdf: true))

        XCTAssertEqual(manager.resolveURL(for: record, in: uldm.id), misfiled)

        // A same-named file of another size belongs to some other paper.
        try Data("%PDF-1.4 someone else's".utf8).write(to: misfiled)
        let resolved = try XCTUnwrap(manager.resolveURL(for: record, in: uldm.id))
        XCTAssertNotEqual(resolved, misfiled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
    }
}

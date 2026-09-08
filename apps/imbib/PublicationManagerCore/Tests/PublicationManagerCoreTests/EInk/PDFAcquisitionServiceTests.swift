//
//  PDFAcquisitionServiceTests.swift
//  PublicationManagerCoreTests
//
//  The one PDF download path (ADR-025 P7): two callers for one paper share
//  one download, a cancel reaches every waiter, bytes without `%PDF` are
//  refused before import, and the policy decides whether a paywall is an
//  error (interactive: open a browser) or nothing (background: never).
//  Every step is injected; no network, no store.
//

import Foundation
import XCTest
@testable import PublicationManagerCore

final class PDFAcquisitionServiceTests: XCTestCase {

    private static let pdfBytes = Data("%PDF-1.7\n%âãÏÓ\n1 0 obj\n".utf8)
    private static let htmlBytes = Data("<!DOCTYPE html><html><body>Please sign in</body></html>".utf8)
    private static let source = URL(string: "https://arxiv.org/pdf/2601.00001")!

    /// What the import closure saw, on the main actor where it runs.
    @MainActor
    final class ImportLog {
        var count = 0
        var bytes: [Int] = []
        let destination = URL(fileURLWithPath: "/tmp/EInkTests/Key2026.pdf")
    }

    private func makeService(
        status: PDFAccessStatus = .available(source: ResolvedPDFSource(type: .arxiv, url: PDFAcquisitionServiceTests.source)),
        localPDF: URL? = nil,
        knownPublication: Bool = true,
        fetch: @escaping @Sendable (URL) async throws -> Data,
        fetchCount: CountBox,
        imports: ImportLog
    ) -> PDFAcquisitionService {
        let deps = PDFAcquisitionDependencies(
            lookup: { id in
                guard knownPublication else { return nil }
                return PDFAcquisitionSubject(publicationID: id, citeKey: "Key2026", libraryID: nil, localPDF: localPDF)
            },
            resolve: { _, _ in status },
            fetch: { url in
                fetchCount.bump()
                return try await fetch(url)
            },
            importPDF: { data, _ in
                imports.count += 1
                imports.bytes.append(data.count)
                return imports.destination
            }
        )
        return PDFAcquisitionService(dependencies: deps)
    }

    // MARK: - Dedupe

    func testConcurrentAcquiresForOnePublicationShareOneDownload() async throws {
        let fetches = CountBox()
        let imports = await ImportLog()
        let service = makeService(
            fetch: { _ in
                try await Task.sleep(for: .milliseconds(150))
                return Self.pdfBytes
            },
            fetchCount: fetches, imports: imports)
        let id = UUID()

        async let first = service.acquire(publicationID: id, policy: .interactive)
        async let second = service.acquire(publicationID: id, policy: .background)
        let (a, b) = try await (first, second)

        let awaited1 = await imports.destination
        XCTAssertEqual(a, awaited1)
        let awaited2 = await imports.destination
        XCTAssertEqual(b, awaited2)
        XCTAssertEqual(fetches.count, 1, "the second caller must join the first download, not start its own")
        let awaited3 = await imports.count
        XCTAssertEqual(awaited3, 1)
        let awaited4 = await service.inFlightPublicationIDs.isEmpty
        XCTAssertTrue(awaited4, "the in-flight entry is released after completion")
    }

    func testDifferentPublicationsDownloadIndependently() async throws {
        let fetches = CountBox()
        let imports = await ImportLog()
        let service = makeService(fetch: { _ in Self.pdfBytes }, fetchCount: fetches, imports: imports)

        async let a = service.acquire(publicationID: UUID(), policy: .background)
        async let b = service.acquire(publicationID: UUID(), policy: .background)
        _ = try await (a, b)

        XCTAssertEqual(fetches.count, 2)
    }

    // MARK: - Cancel

    func testCancelReachesEveryWaiterAndFreesTheSlot() async throws {
        let fetches = CountBox()
        let imports = await ImportLog()
        let service = makeService(
            fetch: { _ in
                try await Task.sleep(for: .seconds(10))
                return Self.pdfBytes
            },
            fetchCount: fetches, imports: imports)
        let id = UUID()

        let waiterA = Task { try await service.acquire(publicationID: id, policy: .interactive) }
        _ = try await EInkTestSupport.waitUntil { await service.inFlightPublicationIDs.contains(id) }
        let waiterB = Task { try await service.acquire(publicationID: id, policy: .background) }
        try await Task.sleep(for: .milliseconds(50))

        await service.cancel(publicationID: id)

        for waiter in [waiterA, waiterB] {
            do {
                _ = try await waiter.value
                XCTFail("a cancelled acquisition must throw")
            } catch let error as PDFAcquisitionError {
                XCTAssertEqual(error, .cancelled)
            }
        }
        let awaited5 = await imports.count
        XCTAssertEqual(awaited5, 0, "nothing is imported after a cancel")
        let awaited6 = await service.inFlightPublicationIDs.isEmpty
        XCTAssertTrue(awaited6)

        // A fresh request after the cancel starts a new download.
        let quick = makeService(fetch: { _ in Self.pdfBytes }, fetchCount: fetches, imports: imports)
        let awaited7 = try await quick.acquire(publicationID: id, policy: .background)
        XCTAssertNotNil(awaited7)
    }

    func testCancelWithoutAnInFlightDownloadIsANoOp() async {
        let service = makeService(fetch: { _ in Self.pdfBytes }, fetchCount: CountBox(), imports: await ImportLog())
        await service.cancel(publicationID: UUID())
        let awaited8 = await service.inFlightPublicationIDs.isEmpty
        XCTAssertTrue(awaited8)
    }

    // MARK: - %PDF sniff

    func testBytesWithoutPDFMagicAreRefusedBeforeImport() async throws {
        let imports = await ImportLog()
        let service = makeService(fetch: { _ in Self.htmlBytes }, fetchCount: CountBox(), imports: imports)

        do {
            _ = try await service.acquire(publicationID: UUID(), policy: .background)
            XCTFail("an HTML page must not become the paper's PDF")
        } catch let error as PDFAcquisitionError {
            guard case .notAPDF(let url, let preview) = error else {
                return XCTFail("expected notAPDF, got \(error)")
            }
            XCTAssertEqual(url, Self.source)
            XCTAssertTrue(preview.hasPrefix("<!DOCTYPE html>"), "the preview names what came back: \(preview)")
            XCTAssertEqual(error.sourceURL, Self.source, "the caller can offer the URL in a browser")
        }
        let awaited9 = await imports.count
        XCTAssertEqual(awaited9, 0)
    }

    func testPDFMagicSniff() {
        XCTAssertTrue(PDFAcquisitionService.hasPDFMagic(Self.pdfBytes))
        XCTAssertFalse(PDFAcquisitionService.hasPDFMagic(Self.htmlBytes))
        XCTAssertFalse(PDFAcquisitionService.hasPDFMagic(Data("%PD".utf8)), "fewer than four bytes is never a PDF")
        XCTAssertFalse(PDFAcquisitionService.hasPDFMagic(Data()))
    }

    // MARK: - Policy

    func testInteractiveReportsAPaywallAsUserActionWhereBackgroundReturnsNil() async throws {
        let browser = URL(string: "https://publisher.example/doi/10.1/abc")!
        let fetches = CountBox()
        let imports = await ImportLog()
        let service = makeService(
            status: .paywalled(publisher: "Publisher", browserURL: browser),
            fetch: { _ in Self.pdfBytes }, fetchCount: fetches, imports: imports)
        let id = UUID()

        do {
            _ = try await service.acquire(publicationID: id, policy: .interactive)
            XCTFail("interactive must surface the browser URL")
        } catch let error as PDFAcquisitionError {
            guard case .requiresUserAction(let url, _) = error else {
                return XCTFail("expected requiresUserAction, got \(error)")
            }
            XCTAssertEqual(url, browser)
        }

        let background = try await service.acquire(publicationID: id, policy: .background)
        XCTAssertNil(background, "background callers get nothing to fetch, never a browser")
        XCTAssertEqual(fetches.count, 0)
        let awaited10 = await imports.count
        XCTAssertEqual(awaited10, 0)
    }

    func testNoSourceIsNilForBothPolicies() async throws {
        let service = makeService(
            status: .unavailable(reason: .noPDFFound),
            fetch: { _ in Self.pdfBytes }, fetchCount: CountBox(), imports: await ImportLog())
        let awaited11 = try await service.acquire(publicationID: UUID(), policy: .interactive)
        XCTAssertNil(awaited11)
        let awaited12 = try await service.acquire(publicationID: UUID(), policy: .background)
        XCTAssertNil(awaited12)
    }

    // MARK: - Short circuits

    func testAnExistingLocalPDFIsReturnedWithoutFetching() async throws {
        let local = URL(fileURLWithPath: "/tmp/EInkTests/existing.pdf")
        let fetches = CountBox()
        let service = makeService(localPDF: local, fetch: { _ in Self.pdfBytes }, fetchCount: fetches, imports: await ImportLog())

        let url = try await service.acquire(publicationID: UUID(), policy: .background)

        XCTAssertEqual(url, local)
        XCTAssertEqual(fetches.count, 0)
    }

    func testUnknownPublicationThrows() async {
        let service = makeService(knownPublication: false, fetch: { _ in Self.pdfBytes }, fetchCount: CountBox(), imports: await ImportLog())
        let id = UUID()
        do {
            _ = try await service.acquire(publicationID: id, policy: .background)
            XCTFail("must throw")
        } catch let error as PDFAcquisitionError {
            XCTAssertEqual(error, .publicationNotFound(id))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTransportFailuresCarryTheURLForTheBrowserFallback() async {
        let service = makeService(
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            fetchCount: CountBox(), imports: await ImportLog())
        do {
            _ = try await service.acquire(publicationID: UUID(), policy: .interactive)
            XCTFail("must throw")
        } catch let error as PDFAcquisitionError {
            guard case .downloadFailed(let url, _) = error else { return XCTFail("expected downloadFailed, got \(error)") }
            XCTAssertEqual(url, Self.source)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

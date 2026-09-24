//
//  LibraryFilesLocationTests.swift
//  PublicationManagerCoreTests
//
//  Library files moved from imbib's private container to the suite's shared
//  one (2026-09-24), because impress, imprint and the tree's `pdf` pane —
//  the same code in other sandboxes — could not read imbib's container and
//  showed every library PDF as "not found". Pinned here: the migration never
//  loses or overwrites a file, and the resolver finds a file on either side
//  of it. Every test runs on scratch directories, never a real library.
//

import XCTest
@testable import PublicationManagerCore

final class LibraryFilesLocationTests: XCTestCase {

    private var scratch: URL!
    private var legacy: URL!
    private var shared: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        scratch = fm.temporaryDirectory
            .appendingPathComponent("LibraryFilesLocationTests-\(UUID().uuidString)", isDirectory: true)
        legacy = scratch.appendingPathComponent("Containers/com.impress.imbib/Application Support/imbib", isDirectory: true)
        shared = scratch.appendingPathComponent("Group Containers/suite/workspace/imbib", isDirectory: true)
        try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: scratch)
        super.tearDown()
    }

    @discardableResult
    private func write(_ data: Data, _ relative: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func contents(_ relative: String, under root: URL) -> Data? {
        fm.contents(atPath: root.appendingPathComponent(relative).path)
    }

    private let library = "1AD5E936-0F53-4FDC-BE37-D1217D2D33FA"

    // MARK: - Migration

    func testTheMigrationCopiesEveryFileKeepingTheLayoutAndTheOriginals() throws {
        let pdf = PDFImportIntegrityTests.makePDF()
        let notes = Data("ink".utf8)
        try write(pdf, "Libraries/\(library)/Papers/Banik_2024.pdf", under: legacy)
        try write(notes, "Libraries/\(library)/Ink/page-1.png", under: legacy)
        try write(pdf, "DefaultLibrary/Papers/Loose_2020.pdf", under: legacy)
        try write(Data("finder".utf8), "Libraries/\(library)/.DS_Store", under: legacy)

        let summary = LibraryFilesMigration(source: legacy, destination: shared).run()

        XCTAssertEqual(summary.copied, 3, "\(summary.files)")
        XCTAssertEqual(summary.failed + summary.conflicts, 0)
        XCTAssertEqual(summary.bytesCopied, Int64(pdf.count * 2 + notes.count))
        XCTAssertEqual(contents("Libraries/\(library)/Papers/Banik_2024.pdf", under: shared), pdf)
        XCTAssertEqual(contents("Libraries/\(library)/Ink/page-1.png", under: shared), notes)
        XCTAssertEqual(contents("DefaultLibrary/Papers/Loose_2020.pdf", under: shared), pdf)
        XCTAssertNil(contents("Libraries/\(library)/.DS_Store", under: shared), "dot-files are not library files")
        XCTAssertEqual(contents("Libraries/\(library)/Papers/Banik_2024.pdf", under: legacy), pdf, "originals kept")
        XCTAssertEqual(summary.originalsRemoved, 0)

        // No staging copy is left behind.
        let papers = shared.appendingPathComponent("Libraries/\(library)/Papers")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: papers.path), ["Banik_2024.pdf"])
    }

    func testASecondRunCopiesNothing() throws {
        try write(PDFImportIntegrityTests.makePDF(), "Libraries/\(library)/Papers/A.pdf", under: legacy)
        LibraryFilesMigration(source: legacy, destination: shared).run()

        let again = LibraryFilesMigration(source: legacy, destination: shared).run()
        XCTAssertEqual(again.copied, 0)
        XCTAssertEqual(again.alreadyPresent, 1)

        // …but it picks up what an older build wrote to the private root since.
        try write(PDFImportIntegrityTests.makePDF(), "Libraries/\(library)/Papers/B.pdf", under: legacy)
        let third = LibraryFilesMigration(source: legacy, destination: shared).run()
        XCTAssertEqual(third.copied, 1)
        XCTAssertEqual(third.alreadyPresent, 1)
    }

    func testADryRunWritesNothing() throws {
        let pdf = PDFImportIntegrityTests.makePDF()
        try write(pdf, "Libraries/\(library)/Papers/A.pdf", under: legacy)

        let summary = LibraryFilesMigration(source: legacy, destination: shared, dryRun: true).run()

        XCTAssertEqual(summary.wouldCopy, 1)
        XCTAssertEqual(summary.copied, 0)
        XCTAssertEqual(summary.files["Libraries/\(library)/Papers/A.pdf"], .wouldCopy(bytes: Int64(pdf.count)))
        XCTAssertFalse(fm.fileExists(atPath: shared.path), "a dry run creates nothing, not even the root")
    }

    func testAnExistingDifferentFileIsNeverOverwritten() throws {
        let pdf = PDFImportIntegrityTests.makePDF()
        let theirs = Data("%PDF-1.4 a different paper".utf8)
        try write(pdf, "Libraries/\(library)/Papers/A.pdf", under: legacy)
        try write(theirs, "Libraries/\(library)/Papers/A.pdf", under: shared)

        let summary = LibraryFilesMigration(source: legacy, destination: shared,
                                            originals: .removeAfterVerification).run()

        XCTAssertEqual(summary.conflicts, 1)
        XCTAssertEqual(contents("Libraries/\(library)/Papers/A.pdf", under: shared), theirs, "not overwritten")
        XCTAssertEqual(contents("Libraries/\(library)/Papers/A.pdf", under: legacy), pdf, "original kept on a conflict")
        XCTAssertEqual(summary.originalsRemoved, 0)
    }

    func testRemovingOriginalsHappensOnlyAfterAVerifiedCopy() throws {
        let pdf = PDFImportIntegrityTests.makePDF()
        try write(pdf, "Libraries/\(library)/Papers/A.pdf", under: legacy)

        let summary = LibraryFilesMigration(source: legacy, destination: shared,
                                            originals: .removeAfterVerification).run()

        XCTAssertEqual(summary.copied, 1)
        XCTAssertEqual(summary.originalsRemoved, 1)
        XCTAssertEqual(contents("Libraries/\(library)/Papers/A.pdf", under: shared), pdf)
        XCTAssertNil(contents("Libraries/\(library)/Papers/A.pdf", under: legacy))
    }

    func testAnAlreadyDamagedPDFIsCopiedByteForByteNotDropped() throws {
        let pdf = PDFImportIntegrityTests.makePDF()
        let truncated = Data(pdf.prefix(pdf.count / 2))
        XCTAssertFalse(PDFDataValidator.check(truncated).isComplete)
        try write(truncated, "Libraries/\(library)/Papers/Half.pdf", under: legacy)

        let summary = LibraryFilesMigration(source: legacy, destination: shared).run()

        XCTAssertEqual(summary.copied, 1, "the user's file, damaged or not, is still theirs")
        XCTAssertEqual(contents("Libraries/\(library)/Papers/Half.pdf", under: shared), truncated)
    }

    func testNothingHappensWhenThereIsNoPrivateRoot() {
        let summary = LibraryFilesMigration(
            source: scratch.appendingPathComponent("nowhere"), destination: shared).run()
        XCTAssertEqual(summary, LibraryFilesMigration.Summary())
    }

    // MARK: - Resolver

    @MainActor
    func testTheResolverFindsAFileOnEitherSideOfTheMigration() throws {
        let store = try RustStoreAdapter(inMemory: true)
        let manager = AttachmentManager(store: store, applicationSupportRoot: shared, legacyRoot: legacy)
        let lib = try XCTUnwrap(store.createLibrary(name: "ULDM"))
        let paper = try XCTUnwrap(store.importBibTeX(
            "@article{Banik2024, title={Banik}, year={2024}}", libraryId: lib.id).first)
        let pdf = PDFImportIntegrityTests.makePDF()
        let relative = "Libraries/\(lib.id.uuidString)/Papers/Banik_2024.pdf"
        let old = try write(pdf, relative, under: legacy)
        let record = try XCTUnwrap(store.addLinkedFile(
            publicationId: paper, filename: "Banik_2024.pdf", relativePath: "Papers/Banik_2024.pdf",
            fileType: "pdf", fileSize: Int64(pdf.count), isPdf: true))

        XCTAssertEqual(manager.resolveURL(for: record, in: lib.id), old, "not migrated yet: the private copy")

        LibraryFilesMigration(source: legacy, destination: shared).run()

        let new = shared.appendingPathComponent(relative)
        XCTAssertEqual(manager.resolveURL(for: record, in: lib.id), new, "migrated: the shared copy, which every app reads")
        XCTAssertEqual(manager.containerURL(for: lib.id), shared.appendingPathComponent("Libraries/\(lib.id.uuidString)"))
    }

    @MainActor
    func testANewImportIsWrittenUnderTheSharedRoot() throws {
        let store = try RustStoreAdapter(inMemory: true)
        let manager = AttachmentManager(store: store, applicationSupportRoot: shared, legacyRoot: legacy)
        let lib = try XCTUnwrap(store.createLibrary(name: "ULDM"))
        let paper = try XCTUnwrap(store.importBibTeX(
            "@article{New2026, title={New}, year={2026}}", libraryId: lib.id).first)

        let file = try manager.importPDF(data: PDFImportIntegrityTests.makePDF(), for: paper, in: lib.id)

        let url = try XCTUnwrap(manager.resolveURL(for: file, in: lib.id))
        XCTAssertTrue(url.path.hasPrefix(shared.path), "\(url.path) is under the shared root")
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.appendingPathComponent("Libraries").path))
    }

    @MainActor
    func testDeleteRemovesThePrivateTwinSoTheMigrationCannotBringItBack() throws {
        let store = try RustStoreAdapter(inMemory: true)
        let manager = AttachmentManager(store: store, applicationSupportRoot: shared, legacyRoot: legacy)
        let lib = try XCTUnwrap(store.createLibrary(name: "ULDM"))
        let paper = try XCTUnwrap(store.importBibTeX(
            "@article{Gone2024, title={Gone}, year={2024}}", libraryId: lib.id).first)
        let pdf = PDFImportIntegrityTests.makePDF()
        let relative = "Libraries/\(lib.id.uuidString)/Papers/Gone_2024.pdf"
        try write(pdf, relative, under: legacy)
        LibraryFilesMigration(source: legacy, destination: shared).run()
        let record = try XCTUnwrap(store.addLinkedFile(
            publicationId: paper, filename: "Gone_2024.pdf", relativePath: "Papers/Gone_2024.pdf",
            fileType: "pdf", fileSize: Int64(pdf.count), isPdf: true))

        try manager.delete(record, in: lib.id, for: paper)

        XCTAssertFalse(fm.fileExists(atPath: shared.appendingPathComponent(relative).path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.appendingPathComponent(relative).path))
        XCTAssertEqual(LibraryFilesMigration(source: legacy, destination: shared).run().copied, 0)
    }

    @MainActor
    func testMovingANotYetMigratedFileLandsItInTheSharedRoot() throws {
        let store = try RustStoreAdapter(inMemory: true)
        let manager = AttachmentManager(store: store, applicationSupportRoot: shared, legacyRoot: legacy)
        let from = try XCTUnwrap(store.createLibrary(name: "Inbox"))
        let to = try XCTUnwrap(store.createLibrary(name: "ULDM"))
        let paper = try XCTUnwrap(store.importBibTeX(
            "@article{Moved2024, title={Moved}, year={2024}}", libraryId: from.id).first)
        let pdf = PDFImportIntegrityTests.makePDF()
        try write(pdf, "Libraries/\(from.id.uuidString)/Papers/Moved_2024.pdf", under: legacy)
        let record = try XCTUnwrap(store.addLinkedFile(
            publicationId: paper, filename: "Moved_2024.pdf", relativePath: "Papers/Moved_2024.pdf",
            fileType: "pdf", fileSize: Int64(pdf.count), isPdf: true))

        try manager.moveLinkedFile(record, from: from.id, to: to.id)

        XCTAssertEqual(contents("Libraries/\(to.id.uuidString)/Papers/Moved_2024.pdf", under: shared), pdf)
    }

    @MainActor
    func testAScratchRootWithoutALegacyRootNeverReachesARealContainer() throws {
        let store = try RustStoreAdapter(inMemory: true)
        let manager = AttachmentManager(store: store, applicationSupportRoot: shared)
        XCTAssertNil(manager.legacyContainerURL(for: UUID()))
    }
}

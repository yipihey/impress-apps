//
//  ImprintiOSTests.swift
//  imprint-iOSTests
//
//  Created by Claude on 2026-01-27.
//
//  The `.imprint` package is the document format and iOS is a first-class
//  editor for it — so this target's job is to prove a document survives being
//  written and read back, not merely that a struct can be initialised.
//
//  This suite could not build at all until 2026-07-29: it imported a module
//  (`imprint_iOS`) that did not exist, and `TEST_HOST` pointed at
//  `imprint-iOS.app/imprint-iOS` while the product is `imprint.app` — the
//  imprint-iOS target inherits `PRODUCT_NAME: imprint` from the project base
//  settings. Both are fixed in project.yml.
//

import XCTest
import UniformTypeIdentifiers
@testable import imprint_iOS

final class ImprintiOSTests: XCTestCase {

    // MARK: - Package round trip
    //
    // `FileDocument`'s `ReadConfiguration`/`WriteConfiguration` have no public
    // initialisers, which is why `ImprintDocument` exposes `makePackageWrapper()`
    // and `init(packageWrapper:)` as internal — their doc comments say, in as
    // many words, "so tests can exercise the package round-trip directly".
    // Nothing had taken them up on it.

    func testTypstPackageRoundTripPreservesIdentityAndContent() throws {
        var original = ImprintDocument()
        original.title = "Structure Formation in the Early Universe"
        original.authors = ["Ada Lovelace", "Grace Hopper"]
        original.source = "= Introduction\n\nSee @einstein1905 for the original argument.\n"
        original.linkedImbibManuscriptID = UUID()

        let restored = try ImprintDocument(packageWrapper: original.makePackageWrapper())

        XCTAssertEqual(restored.id, original.id, "the stable document id must survive a save")
        XCTAssertEqual(restored.title, original.title)
        XCTAssertEqual(restored.authors, original.authors)
        XCTAssertEqual(restored.source, original.source, "the buffer is the whole point")
        XCTAssertEqual(restored.linkedImbibManuscriptID, original.linkedImbibManuscriptID)
        XCTAssertEqual(
            restored.createdAt.timeIntervalSince1970,
            original.createdAt.timeIntervalSince1970,
            accuracy: 1.0,
            "createdAt is preserved; only modifiedAt is restamped on write")
    }

    func testRoundTripPreservesBibliographyKeyedByCiteKey() throws {
        var original = ImprintDocument()
        original.bibliography = [
            "einstein1905":
                "@article{einstein1905,\n  title = {On the Electrodynamics of Moving Bodies}\n}",
            "bohr1913":
                "@article{bohr1913,\n  title = {On the Constitution of Atoms and Molecules}\n}",
        ]

        let restored = try ImprintDocument(packageWrapper: original.makePackageWrapper())

        XCTAssertEqual(
            Set(restored.bibliography.keys), ["einstein1905", "bohr1913"],
            "bibliography.bib is written as concatenated entries and re-parsed by cite key")
    }

    func testRoundTripCarriesFigureFilesThroughUntouched() throws {
        // `figureFiles` exists so a read → write cycle cannot silently DROP
        // plot sources. Losing them is data loss, not a diff.
        var original = ImprintDocument()
        original.figureFiles = [
            "pulse.vsz": Data("# veusz document\n".utf8),
            "pulse.pdf": Data([0x25, 0x50, 0x44, 0x46]),  // %PDF
        ]

        let restored = try ImprintDocument(packageWrapper: original.makePackageWrapper())

        XCTAssertEqual(restored.figureFiles, original.figureFiles)
    }

    func testEmptyDocumentRoundTripsWithoutAFiguresDirectory() throws {
        // Documents that never touched figures stay byte-identical on disk —
        // the `figures/` wrapper is only emitted when non-empty.
        let wrapper = try ImprintDocument().makePackageWrapper()
        XCTAssertNil(
            wrapper.fileWrappers?["figures"],
            "an empty figures/ directory would rewrite every legacy document on first save")
        XCTAssertNotNil(wrapper.fileWrappers?["main.typ"])
        XCTAssertNotNil(wrapper.fileWrappers?["metadata.json"])
    }

    // MARK: - Import paths

    func testLaTeXImportIsReadAsLaTeXRatherThanSniffed() throws {
        let tex = "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}\n"
        let document = try ImprintDocument(
            regularFileContents: Data(tex.utf8), contentType: .latexSource)

        XCTAssertEqual(document.format, .latex, "the content type is authoritative for .tex")
        XCTAssertEqual(document.source, tex)
    }

    func testCorruptRegularFileIsRejectedRatherThanSilentlyEmptied() {
        XCTAssertThrowsError(
            try ImprintDocument(regularFileContents: nil, contentType: .plainText),
            "a nil file must not read back as an empty document the user could then save over")
    }

    // MARK: - Construction
    //
    // The two assertions this suite shipped with. They cover the default
    // initialiser and Swift property assignment — kept as a cheap smoke test
    // now that the target builds, but they were never a round trip despite the
    // original name (`testDocumentMetadataRoundTrip`), which is why the real
    // ones above were added.

    func testDocumentCreation() throws {
        let document = ImprintDocument()
        XCTAssertFalse(document.id.uuidString.isEmpty)
        XCTAssertEqual(document.title, "Untitled")
        XCTAssertEqual(document.format, .typst, "the default new document is Typst")
    }

    func testDocumentMetadataAssignment() throws {
        var document = ImprintDocument()
        document.title = "Test Document"
        document.authors = ["Author One", "Author Two"]

        XCTAssertEqual(document.title, "Test Document")
        XCTAssertEqual(document.authors.count, 2)
    }
}

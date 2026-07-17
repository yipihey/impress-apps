//
//  BibTeXExporterByteEquivalenceTests.swift
//  PublicationManagerCoreTests
//
//  Phase 1D verification: compares Swift `BibTeXExporter` output against the
//  Rust `bibtexFormatEntry` UniFFI export on a representative corpus.
//
//  Status (2026-05-23): structural divergence confirmed for 7/7 corpus
//  entries. Both exporters produce valid BibTeX that parses back to the same
//  fields, but they are not byte-identical because:
//    1. Field ordering — Swift sorts by `BibTeXFieldNames.defaultFieldOrder`
//       then alphabetical; the Rust path iterates `Vec<BibTeXField>` in the
//       order it was built from a Swift `[String: String]`, which is
//       non-deterministic (Swift Dictionary iteration order).
//    2. Trailing comma — Swift omits the comma on the last field; Rust always
//       writes one.
//    3. Numeric bare — Swift unbraces only `{year, volume, number, pages}` when
//       parseable as Int; Rust unbraces any all-digit value (e.g. an ISBN that
//       happens to contain no hyphens).
//
//  Per the Phase 1D playbook, the Swift `BibTeXExporter` therefore stays in
//  place until `im_bibtex::format_entry_with_options(...)` is added and
//  re-exported through UniFFI. See the TODO at the top of
//  `crates/im-bibtex/src/formatter.rs`.
//
//  The tests below are written to fail-fast WHEN parity is achieved (i.e.
//  `expectedDivergent` becomes 0). Flip the expectation, route every caller to
//  the Rust path, and delete `BibTeXExporter.swift`.
//

import XCTest
import ImbibRustCore
@testable import PublicationManagerCore

final class BibTeXExporterByteEquivalenceTests: XCTestCase {

    private var exporter: BibTeXExporter!

    override func setUp() {
        super.setUp()
        exporter = BibTeXExporter()
    }

    override func tearDown() {
        exporter = nil
        super.tearDown()
    }

    // MARK: - Corpus

    private static func corpus() -> [PublicationManagerCore.BibTeXEntry] {
        [
            // 1. Simple article — ordered fields, numeric year
            PublicationManagerCore.BibTeXEntry(
                citeKey: "Einstein1905",
                entryType: "article",
                fields: [
                    "author": "Albert Einstein",
                    "title": "On the Electrodynamics of Moving Bodies",
                    "journal": "Annalen der Physik",
                    "year": "1905",
                    "volume": "17",
                    "pages": "891--921",
                ]
            ),
            // 2. Book with hyphen-bearing ISBN (mixed digits + hyphens)
            PublicationManagerCore.BibTeXEntry(
                citeKey: "Hawking1988",
                entryType: "book",
                fields: [
                    "author": "Stephen Hawking",
                    "title": "A Brief History of Time",
                    "publisher": "Bantam Books",
                    "year": "1988",
                    "isbn": "978-0553380163",
                ]
            ),
            // 3. ISBN that is *purely* digits — the canonical numeric-bare divergence
            PublicationManagerCore.BibTeXEntry(
                citeKey: "DigitISBN2020",
                entryType: "book",
                fields: [
                    "author": "Author, Test",
                    "title": "Digit-Only ISBN",
                    "year": "2020",
                    "isbn": "9780553380163",
                ]
            ),
            // 4. Inproceedings with booktitle
            PublicationManagerCore.BibTeXEntry(
                citeKey: "Turing1950",
                entryType: "inproceedings",
                fields: [
                    "author": "Alan Turing",
                    "title": "Computing Machinery and Intelligence",
                    "booktitle": "Mind",
                    "year": "1950",
                    "volume": "59",
                    "pages": "433--460",
                ]
            ),
            // 5. Entry with LaTeX markup in title/author
            PublicationManagerCore.BibTeXEntry(
                citeKey: "Schroedinger1926",
                entryType: "article",
                fields: [
                    "author": "Schr\\\"{o}dinger, Erwin",
                    "title": "{An} Undulatory Theory",
                    "journal": "Phys. Rev.",
                    "year": "1926",
                ]
            ),
            // 6. Entry with abstract, keywords, note (later in fieldOrder)
            PublicationManagerCore.BibTeXEntry(
                citeKey: "Multi2024",
                entryType: "article",
                fields: [
                    "title": "Many Fields",
                    "author": "Smith, J. and Jones, K.",
                    "year": "2024",
                    "journal": "Nature",
                    "abstract": "Lorem ipsum dolor sit amet.",
                    "keywords": "ml, ai",
                    "note": "Editor's pick",
                    "doi": "10.1000/example",
                ]
            ),
            // 7. Entry with custom fields NOT in defaultFieldOrder
            PublicationManagerCore.BibTeXEntry(
                citeKey: "Custom2024",
                entryType: "misc",
                fields: [
                    "author": "Anonymous",
                    "title": "Custom",
                    "year": "2024",
                    "customfield": "value1",
                    "anothercustom": "value2",
                ]
            ),
        ]
    }

    // MARK: - Helpers

    /// Format the Swift entry through the Rust path (UniFFI).
    private func rustExport(_ entry: PublicationManagerCore.BibTeXEntry) -> String {
        let rustEntry = BibTeXEntryConversions.toRust(entry)
        return ImbibRustCore.bibtexFormatEntry(entry: rustEntry)
    }

    /// Re-parse and compare entries semantically (cite key + entry type + fields).
    /// Even though the byte output differs, the round-trip must yield identical
    /// data — otherwise the divergence is more than cosmetic.
    private func semanticEqual(
        _ a: PublicationManagerCore.BibTeXEntry,
        _ b: PublicationManagerCore.BibTeXEntry
    ) -> Bool {
        guard a.citeKey == b.citeKey, a.entryType == b.entryType else { return false }
        // Compare lowercased keys → values
        let aMap = Dictionary(uniqueKeysWithValues: a.fields.map { ($0.key.lowercased(), $0.value) })
        let bMap = Dictionary(uniqueKeysWithValues: b.fields.map { ($0.key.lowercased(), $0.value) })
        return aMap == bMap
    }

    // MARK: - Tests

    /// Phase 1D status check: byte-equivalence currently fails. This test
    /// passes while divergence persists and FAILS once Rust catches up — at
    /// which point Swift `BibTeXExporter` can be deleted.
    func testByteEquivalence_status() {
        var divergent: [(citeKey: String, swift: String, rust: String)] = []
        for entry in Self.corpus() {
            let swiftOut = exporter.export(entry)
            let rustOut = rustExport(entry)
            if swiftOut != rustOut {
                divergent.append((entry.citeKey, swiftOut, rustOut))
            }
        }

        // Surface the divergences so the regression record is in the log.
        for d in divergent {
            NSLog("[Phase1D] divergence for \(d.citeKey)\nSWIFT:\n\(d.swift)\n---\nRUST:\n\(d.rust)\n===")
        }

        // Today: every corpus entry diverges. When this assertion fails
        // (because Rust gained options-based formatting), flip the file:
        // - Set the body to `XCTAssertTrue(divergent.isEmpty)` instead.
        // - Route callers through `bibtexFormatEntry`.
        // - Delete `BibTeXExporter.swift`.
        XCTAssertEqual(
            divergent.count, Self.corpus().count,
            "Byte-divergence count changed. Expected all \(Self.corpus().count) " +
            "entries to differ between Swift `BibTeXExporter` and Rust " +
            "`bibtexFormatEntry` until parity lands (see file header)."
        )
    }

    /// Round-trip equivalence: both formatters produce BibTeX whose re-parsed
    /// fields match the input. This is the *minimum* invariant that must hold
    /// regardless of byte-equivalence.
    func testRoundTripEquivalence() throws {
        let parser = RustBibTeXParser(decodeLaTeX: false)
        for entry in Self.corpus() {
            let swiftOut = exporter.export(entry)
            let rustOut = rustExport(entry)

            let swiftReparsed = try parser.parseEntry(swiftOut)
            let rustReparsed = try parser.parseEntry(rustOut)

            XCTAssertTrue(
                semanticEqual(swiftReparsed, rustReparsed),
                "Round-trip parity broken for \(entry.citeKey)."
            )
            XCTAssertTrue(
                semanticEqual(entry, swiftReparsed),
                "Swift formatter lost data for \(entry.citeKey)."
            )
            XCTAssertTrue(
                semanticEqual(entry, rustReparsed),
                "Rust formatter lost data for \(entry.citeKey)."
            )
        }
    }
}

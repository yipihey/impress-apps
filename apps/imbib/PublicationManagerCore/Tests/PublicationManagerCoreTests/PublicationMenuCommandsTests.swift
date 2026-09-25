//
//  PublicationMenuCommandsTests.swift
//  PublicationManagerCoreTests
//
//  The list's side of three menu commands that posted to nobody until
//  2026-09-25: Window ▸ Toggle PDF Filter (⇧⌘\), Edit ▸ Copy as Citation
//  (⇧⌘C) and Paper ▸ Share… (⇧⌘F).
//

import ImprintCore
import XCTest

@testable import PublicationManagerCore

@MainActor
final class PublicationMenuCommandsTests: XCTestCase {

    private func row(
        _ key: String, pdf: Bool, isRead: Bool = false,
        doi: String? = nil, arxivID: String? = nil, bibcode: String? = nil
    ) -> PublicationRowData {
        PublicationRowData(
            id: UUID(),
            citeKey: key,
            title: "Title \(key)",
            isRead: isRead,
            hasDownloadedPDF: pdf,
            doi: doi,
            arxivID: arxivID,
            bibcode: bibcode,
            dateAdded: Date(timeIntervalSince1970: 0),
            dateModified: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Toggle PDF Filter

    func testHasPDFIsAPostFilterOnTheRowsPDFData() {
        let rows = [row("a", pdf: true), row("b", pdf: false), row("c", pdf: true, isRead: true)]
        let service = LocalFilterService.shared

        let has = service.parse("has:pdf")
        XCTAssertEqual(has.pdfState, .has)
        XCTAssertFalse(has.isEmpty)
        XCTAssertEqual(service.apply(has, to: rows).map(\.citeKey), ["a", "c"])

        XCTAssertEqual(service.parse("-has:pdf").pdfState, .missing)
        XCTAssertEqual(service.apply(service.parse("-has:pdf"), to: rows).map(\.citeKey), ["b"])

        // Combines with the other terms, like flag: and tags: do.
        XCTAssertEqual(service.apply(service.parse("has:pdf unread"), to: rows).map(\.citeKey), ["a"])
        // Not a text term: it must not reach the full-text search.
        XCTAssertEqual(has.textTerms, [])
    }

    func testTheCommandTogglesTheTokenAndLeavesTheRestOfTheFilter() {
        XCTAssertEqual(LocalFilterService.togglingHasPDF(in: ""), "has:pdf")
        XCTAssertEqual(LocalFilterService.togglingHasPDF(in: "has:pdf"), "")
        XCTAssertEqual(LocalFilterService.togglingHasPDF(in: "flag:red"), "flag:red has:pdf")
        XCTAssertEqual(LocalFilterService.togglingHasPDF(in: "flag:red has:pdf year:2020"), "flag:red year:2020")
        XCTAssertEqual(LocalFilterService.togglingHasPDF(in: "-has:pdf tags:x"), "tags:x has:pdf")
        XCTAssertEqual(
            LocalFilterService.togglingHasPDF(in: #""dark  matter" x"#), #""dark  matter" x has:pdf"#,
            "a quoted phrase keeps its spacing")
    }

    // MARK: - Share…

    func testShareItemsAreTheBibTeXThenEachPapersWebURL() {
        let rows = [
            row("doi", pdf: false, doi: "10.1000/x"),
            row("arxiv", pdf: false, arxivID: "2401.00001"),
            row("none", pdf: false),
        ]
        let items = PublicationShareItems.items(bibtex: "@article{doi,}\n", rows: rows)
        XCTAssertEqual(items.first as? String, "@article{doi,}")
        XCTAssertEqual(
            items.compactMap { ($0 as? URL)?.absoluteString },
            ["https://doi.org/10.1000/x", "https://arxiv.org/abs/2401.00001"])
        XCTAssertTrue(PublicationShareItems.items(bibtex: "", rows: []).isEmpty)
    }

    // MARK: - Copy as Citation

    func testExtractedReferencesLoseTheirListLabels() {
        let text = "[1] A. Author, “One,” J, 2020.\n\n[2] B. Author, “Two,” 2021.\n"
        XCTAssertEqual(
            PublicationCitationFormatter.references(fromExtractedText: text),
            ["A. Author, “One,” J, 2020.", "B. Author, “Two,” 2021."])
        XCTAssertEqual(
            PublicationCitationFormatter.references(fromExtractedText: "1. Solo, S. (2019). Title."),
            ["Solo, S. (2019). Title."])
        // What PDFKit returned for three references in the app (2026-09-25):
        // the label column first, all on the first line.
        XCTAssertEqual(
            PublicationCitationFormatter.references(
                fromExtractedText: "[1] [2] [3] S. Scratch, “C,” 2021.\nT. Tester, “B,” 2020.\nT. Abel, “A,” 2002."),
            ["S. Scratch, “C,” 2021.", "T. Tester, “B,” 2020.", "T. Abel, “A,” 2002."])
        XCTAssertEqual(PublicationCitationFormatter.references(fromExtractedText: "[1]\n[2]\nA.\nB."), ["A.", "B."])
    }

    /// The real path: imprint's Typst renderer formats a BibTeX entry.
    func testTypstFormatsAReferenceFromBibTeX() async throws {
        try XCTSkipUnless(ImprintCoreAvailability.typst, "Typst renderer not linked in this build")
        let bibtex = """
            @article{Abel2002,
              author = {Abel, Tom and Bryan, Greg L. and Norman, Michael L.},
              title = {The Formation of the First Star in the Universe},
              journal = {Science},
              volume = {295},
              pages = {93--98},
              year = {2002},
              doi = {10.1126/science.295.5552.93}
            }
            """
        let formatted = await PublicationCitationFormatter.typstReferences(bibtex: bibtex)
        let text = try XCTUnwrap(formatted, "Typst returned no reference")
        print("Copy as Citation (Typst, imprint's default style): \(text)")
        XCTAssertTrue(text.contains("The Formation of the First Star in the Universe"), text)
        XCTAssertTrue(text.contains("Abel"), text)
        XCTAssertTrue(text.contains("2002"), text)
        XCTAssertFalse(text.hasPrefix("["), "the numeric label is stripped: \(text)")
        XCTAssertEqual(text.components(separatedBy: "\n").count, 1, "one reference, one line: \(text)")
    }
}

private enum ImprintCoreAvailability {
    static var typst: Bool { TypstRenderer.isNativeAvailable }
}

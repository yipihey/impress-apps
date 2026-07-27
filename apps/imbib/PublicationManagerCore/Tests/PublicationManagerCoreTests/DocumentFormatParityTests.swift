//
//  DocumentFormatParityTests.swift
//  PublicationManagerCoreTests
//
//  WS2 invariant: the Swift `DocumentFormat` enum and the Rust
//  `SUPPORTED_MANUSCRIPT_FORMATS` set (impress-core, the single source of
//  truth enforced by `create_manuscript`) must always agree — a format added
//  on one side but not the other either can't be created or can't be edited.
//

import XCTest
import ImpressRustCore
@testable import PublicationManagerCore

final class DocumentFormatParityTests: XCTestCase {

    func testSwiftFormatsMatchRustSupportedSet() {
        let swiftFormats = Set(DocumentFormat.allCases.map(\.rawValue))
        let rustFormats = Set(supportedManuscriptFormats())
        XCTAssertEqual(
            swiftFormats, rustFormats,
            "DocumentFormat and impress-core SUPPORTED_MANUSCRIPT_FORMATS diverged"
        )
    }

    // MARK: - Inference (the "ADR compiled as Typst" bug)

    func testMarkdownBodyIsNotMistakenForTypst() {
        let adr = """
        # ADR-0011: The impress Journal

        ## Status
        Accepted

        ## Context
        Manuscripts need a review pipeline.
        """
        XCTAssertEqual(DocumentFormat.detect(from: adr), .markdown)
    }

    func testTitleExtensionWinsOverContentHeuristics() {
        XCTAssertEqual(DocumentFormat.detect(from: "", title: "ADR-0011.md"), .markdown)
        XCTAssertEqual(DocumentFormat.detect(from: "", title: "notes.txt"), .plaintext)
        XCTAssertEqual(DocumentFormat.detect(from: "", title: "paper.tex"), .latex)
        XCTAssertEqual(DocumentFormat.detect(from: "", title: "paper.typ"), .typst)
    }

    func testTypstAndLatexStillDetectedCorrectly() {
        // Typst code mode uses `#` with NO space — must not read as Markdown.
        let typst = """
        #import "@preview/cetz:0.2.0"
        #set page(margin: 2cm)

        = Introduction
        Some *bold* text.
        """
        XCTAssertEqual(DocumentFormat.detect(from: typst), .typst)

        let latex = "\\documentclass{article}\n\\begin{document}\nhi\n\\end{document}"
        XCTAssertEqual(DocumentFormat.detect(from: latex), .latex)

        // Unknown title extensions fall through to content heuristics.
        XCTAssertEqual(DocumentFormat.detect(from: typst, title: "Some Paper"), .typst)
    }

    func testFencedCodeBlockImpliesMarkdown() {
        let md = "Intro paragraph\n\n```swift\nlet x = 1\n```\n"
        XCTAssertEqual(DocumentFormat.detect(from: md), .markdown)
    }

    func testEmptyBodyWithNoHintsStaysTypst() {
        // The empty ADR shells: nothing to infer from, keep the suite default.
        XCTAssertEqual(DocumentFormat.detect(from: "", title: "ADR-0011: The impress Journal"), .typst)
    }

    func testMarkdownAndPlaintextNeverCompile() {
        XCTAssertEqual(DocumentFormat.markdown.previewKind, .renderedMarkdown)
        XCTAssertEqual(DocumentFormat.plaintext.previewKind, .none)
        XCTAssertEqual(DocumentFormat.typst.previewKind, .compiledPDF)
        XCTAssertEqual(DocumentFormat.latex.previewKind, .compiledPDF)
    }

    func testPreviewKindsAreTotal() {
        // Every format must resolve a preview kind and a file extension.
        for format in DocumentFormat.allCases {
            XCTAssertFalse(format.fileExtension.isEmpty)
            XCTAssertFalse(format.mainFileName.isEmpty)
            _ = format.previewKind
        }
    }
}

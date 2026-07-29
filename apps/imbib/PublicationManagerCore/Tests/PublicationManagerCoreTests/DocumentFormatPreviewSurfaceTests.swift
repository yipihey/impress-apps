//
//  DocumentFormatPreviewSurfaceTests.swift
//  PublicationManagerCoreTests
//
//  The two declarative seams the iOS editor now sources its behavior from:
//
//  1. `DocumentFormat.previewKind` → `hasPreview` / `requiresCompile`, which
//     decide whether a host shows a preview affordance at all and whether it
//     may schedule a compile. iPhone used to have NO preview surface and
//     compiled unconditionally.
//  2. `DocumentFormat.highlightLanguage` / `resolveHighlighter`, the ONE
//     mapping the AppKit editor (`SourceEditorView`) and the UIKit editor
//     (`IOSSourceEditorView`) share. A format added on one side and not the
//     other is exactly the drift this replaces.
//

import XCTest
import ImpressSyntaxHighlight

@testable import PublicationManagerCore

final class DocumentFormatPreviewSurfaceTests: XCTestCase {

    // MARK: - Preview surface

    func testHasPreviewMatchesPreviewKind() {
        for format in DocumentFormat.allCases {
            XCTAssertEqual(
                format.hasPreview, format.previewKind != DocumentFormat.PreviewKind.none,
                "\(format.rawValue): hasPreview must be derived from previewKind")
        }
    }

    func testPlainTextIsTheOnlyFormatWithoutAPreview() {
        XCTAssertFalse(DocumentFormat.plaintext.hasPreview)
        XCTAssertTrue(DocumentFormat.typst.hasPreview)
        XCTAssertTrue(DocumentFormat.latex.hasPreview)
        XCTAssertTrue(DocumentFormat.markdown.hasPreview)
    }

    func testOnlyCompiledPDFFormatsRequireACompile() {
        XCTAssertTrue(DocumentFormat.typst.requiresCompile)
        XCTAssertTrue(DocumentFormat.latex.requiresCompile)
        // Markdown renders live from the buffer; plain text has no preview.
        XCTAssertFalse(DocumentFormat.markdown.requiresCompile)
        XCTAssertFalse(DocumentFormat.plaintext.requiresCompile)
    }

    // MARK: - Syntax highlighting

    func testHighlightLanguageMapping() {
        XCTAssertEqual(DocumentFormat.typst.highlightLanguage, .typst)
        XCTAssertEqual(DocumentFormat.latex.highlightLanguage, .latex)
        XCTAssertNil(DocumentFormat.markdown.highlightLanguage)
        XCTAssertNil(DocumentFormat.plaintext.highlightLanguage)
    }

    func testIsSyntaxHighlightedTracksTheGrammar() {
        for format in DocumentFormat.allCases {
            XCTAssertEqual(format.isSyntaxHighlighted, format.highlightLanguage != nil)
        }
    }

    /// A highlighter holds the parser + last tree, so it must be REUSED across
    /// keystrokes (that's what makes `applyEdit` incremental).
    func testResolveHighlighterReusesTheSameInstanceForTheSameFormat() {
        var cache: SyntaxHighlighter?
        let first = DocumentFormat.typst.resolveHighlighter(&cache)
        let second = DocumentFormat.typst.resolveHighlighter(&cache)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "the parser/tree must survive between edits")
    }

    /// …and REPLACED when the format flips (the default `.typst` becoming
    /// `.latex` once the document loads).
    func testResolveHighlighterRebuildsOnFormatChange() {
        var cache: SyntaxHighlighter?
        let typst = DocumentFormat.typst.resolveHighlighter(&cache)
        let latex = DocumentFormat.latex.resolveHighlighter(&cache)
        XCTAssertEqual(typst?.language, .typst)
        XCTAssertEqual(latex?.language, .latex)
        XCTAssertFalse(typst === latex)
    }

    /// …and CLEARED for a format with no grammar, so stale colors from the
    /// previous grammar can be reset instead of lingering.
    func testResolveHighlighterClearsForFormatsWithoutAGrammar() {
        var cache: SyntaxHighlighter?
        _ = DocumentFormat.typst.resolveHighlighter(&cache)
        XCTAssertNotNil(cache)
        let none = DocumentFormat.plaintext.resolveHighlighter(&cache)
        XCTAssertNil(none)
        XCTAssertNil(cache)
    }

    // MARK: - Theme

    /// The iOS branch of the default theme used to be `colors: [:]` — every
    /// capture resolved to the default color, i.e. no highlighting at all on
    /// iPhone/iPad even though the whole engine was cross-platform.
    func testDefaultThemeHasColorsOnEveryPlatform() {
        let theme = ImpressSyntaxTheme.impressDefault
        XCTAssertFalse(theme.colors.isEmpty)
        for capture in ["comment", "keyword", "function", "string", "markup.heading"] {
            XCTAssertNotNil(theme.color(for: capture), "no color for @\(capture)")
        }
        // Dotted fallback still works (function.macro.builtin → function).
        XCTAssertNotNil(theme.color(for: "function.macro.builtin"))
    }
}

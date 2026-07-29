//
//  ManuscriptCiteKeyLocatorTests.swift
//  PublicationManagerCoreTests
//
//  "Which cite key is under this index?" — the detection behind imprint's
//  citation-inspection affordances (macOS hover, iOS long press).
//
//  These tests deliberately assert the ANSWERS, not the mechanism, because the
//  mechanism is Rust: `ManuscriptCiteKeyLocator` holds no grammar, it forwards
//  to `imprint_core::citations::hit`, which is derived from the canonical
//  scanner `citations::extract`. The last three cases are the ones a
//  hand-rolled Swift scanner gets wrong (and the macOS `CiteKeyAtLocation` one
//  does): `@param` annotations, email addresses, and prefix-sharing keys.
//

import XCTest
@testable import PublicationManagerCore

final class ManuscriptCiteKeyLocatorTests: XCTestCase {

    private func key(_ source: String, _ offset: Int, _ format: DocumentFormat = .typst) -> String? {
        ManuscriptCiteKeyLocator.citeKey(in: source, atUTF16Offset: offset, format: format)?.key
    }

    // MARK: - Typst

    func testTypstHitSpanCoversTheSigilAndTheKey() {
        //             0123456789
        let source = "see @abc."
        XCTAssertNil(key(source, 3), "the space before the @ is not on the citation")
        XCTAssertEqual(key(source, 4), "abc", "the @ itself is part of the token a user taps")
        XCTAssertEqual(key(source, 5), "abc")
        XCTAssertEqual(key(source, 7), "abc", "last character of the key")
        XCTAssertNil(key(source, 8), "one past the key is after the citation")
    }

    func testTypstRangesAddressKeyAndTokenSeparately() {
        let source = "see @abc."
        let hit = ManuscriptCiteKeyLocator.citeKey(in: source, atUTF16Offset: 5, format: .typst)
        XCTAssertEqual(hit?.command, "typst-at")
        XCTAssertEqual(hit?.keyRange, NSRange(location: 5, length: 3), "the key, for renaming")
        XCTAssertEqual(hit?.hitRange, NSRange(location: 4, length: 4), "the token, for anchoring")
        XCTAssertEqual(
            (source as NSString).substring(with: hit!.hitRange), "@abc",
            "the hit range must select exactly what the reader sees")
    }

    func testTypstPrefersTheLongestKeyWhenTwoSharePrefix() {
        // A naive "scan forward from the @ for the shorter key" answers "abc"
        // for the second citation.
        let source = "@abc and @abcdef"
        XCTAssertEqual(key(source, 12), "abcdef")
        XCTAssertEqual(key(source, 1), "abc")
    }

    func testTypstAnnotationsAreNotCitations() {
        // The canonical scanner excludes these `@`-annotation prefixes; the
        // macOS Swift scanner does not, and previews them as citations.
        for source in ["@param foo", "@example x", "@deprecated y", "@available z"] {
            XCTAssertNil(key(source, 2), "\(source) is an annotation, not a citation")
        }
    }

    func testEmailAddressesAreNotCitations() {
        let source = "write to ada@example.org for details"
        XCTAssertNil(key(source, 14))
    }

    func testMarkdownUsesTheTypstGrammar() {
        XCTAssertEqual(key("see @abc.", 5, .markdown), "abc")
    }

    // MARK: - LaTeX

    func testLatexHitSpanIsTheKeyInsideTheBraces() {
        //                        1         2
        //              0123456789012345678901
        let source = "We cite \\cite{smith24}."
        XCTAssertNil(key(source, 10, .latex), "the command name is not the target")
        XCTAssertNil(key(source, 13, .latex), "the opening brace is not the target")
        XCTAssertEqual(key(source, 14, .latex), "smith24")
        XCTAssertEqual(key(source, 20, .latex), "smith24")
        XCTAssertNil(key(source, 21, .latex), "the closing brace is not the target")
    }

    func testLatexGroupedKeysResolvePerKey() {
        let source = "\\citep{a2020, b2021}"
        XCTAssertEqual(key(source, 7, .latex), "a2020")
        XCTAssertEqual(key(source, 14, .latex), "b2021")
        XCTAssertEqual(
            ManuscriptCiteKeyLocator.citeKey(in: source, atUTF16Offset: 7, format: .latex)?.command,
            "citep",
            "the command kind survives, so a caller can tell parenthetical from in-text")
    }

    func testLatexGrammarDoesNotFireOnTypstSourceAndViceVersa() {
        XCTAssertNil(key("see @abc.", 5, .latex), "@key is not a LaTeX citation")
        XCTAssertNil(key("\\cite{abc}", 7, .typst), "\\cite{} is not a Typst citation")
    }

    // MARK: - Formats without citations

    func testPlaintextHasNoCitations() {
        XCTAssertNil(key("see @abc.", 5, .plaintext))
        XCTAssertTrue(ManuscriptCiteKeyLocator.allCiteKeys(in: "@abc", format: .plaintext).isEmpty)
    }

    // MARK: - Touch tolerance

    func testNearOffsetRecoversTheCaretPositionPastTheCitation() {
        // `UITextView.closestPosition(to:)` answers with the nearest CARET
        // position: a finger on the right half of the final `c` in `@abc`
        // yields offset 8 — one past the citation. The touch-tolerant probe is
        // what makes the long press hit what the user aimed at.
        let source = "see @abc."
        XCTAssertNil(
            ManuscriptCiteKeyLocator.citeKey(in: source, atUTF16Offset: 8, format: .typst),
            "the strict probe is half-open")
        XCTAssertEqual(
            ManuscriptCiteKeyLocator.citeKey(in: source, nearUTF16Offset: 8, format: .typst)?.key,
            "abc")
    }

    func testNearOffsetDoesNotInventAHitTwoCharactersAway() {
        let source = "see @abc.  x"
        XCTAssertNil(ManuscriptCiteKeyLocator.citeKey(
            in: source, nearUTF16Offset: 11, format: .typst))
    }

    // MARK: - Offsets

    func testUTF16OffsetsSurviveAstralCharacters() {
        // "𝄞" is one Character, 4 UTF-8 bytes, 2 UTF-16 code units. A byte
        // offset leaking into an NSRange would land inside the citation.
        let source = "𝄞 @abc"
        let ns = source as NSString
        let at = ns.range(of: "@").location
        XCTAssertEqual(at, 3, "2 code units for 𝄞 + 1 for the space")
        let hit = ManuscriptCiteKeyLocator.citeKey(in: source, atUTF16Offset: at, format: .typst)
        XCTAssertEqual(hit?.key, "abc")
        XCTAssertEqual(ns.substring(with: hit!.hitRange), "@abc")
    }

    func testOutOfRangeOffsetsAreMissesNotCrashes() {
        XCTAssertNil(key("@abc", 999))
        XCTAssertNil(key("@abc", -1))
        XCTAssertNil(key("", 0))
    }

    // MARK: - Enumeration

    func testAllCiteKeysReturnsSourceOrderWithSpans() {
        let source = "@alpha, then @beta, then @gamma"
        let hits = ManuscriptCiteKeyLocator.allCiteKeys(in: source, format: .typst)
        XCTAssertEqual(hits.map(\.key), ["alpha", "beta", "gamma"])
        let ns = source as NSString
        for hit in hits {
            XCTAssertEqual(ns.substring(with: hit.hitRange), "@\(hit.key)")
            XCTAssertEqual(ns.substring(with: hit.keyRange), hit.key)
        }
    }

    /// The anti-drift property, asserted rather than asserted-about: whatever
    /// the canonical scanner considers a cite key is exactly what the locator
    /// finds at that position. If the Rust grammar changes, both sides move
    /// together and this still holds; a Swift copy of the grammar would not.
    func testEveryKeyTheCanonicalScannerFindsIsHitTestableAtItsOwnOffset() {
        let source = """
        = Draft

        Compare @einstein1905 with @bohr1913 and @param (not a citation),
        plus ada@example.org and @heisenberg1927.
        """
        let located = ManuscriptCiteKeyLocator.allCiteKeys(in: source, format: .typst)
        XCTAssertFalse(located.isEmpty)
        for hit in located {
            XCTAssertEqual(
                ManuscriptCiteKeyLocator.citeKey(
                    in: source, atUTF16Offset: hit.keyRange.location, format: .typst)?.key,
                hit.key,
                "every enumerated occurrence must be findable at its own offset")
        }
        XCTAssertEqual(
            Set(located.map(\.key)),
            ["einstein1905", "bohr1913", "heisenberg1927"],
            "annotations and email addresses are excluded by the scanner, not by this file")
    }
}

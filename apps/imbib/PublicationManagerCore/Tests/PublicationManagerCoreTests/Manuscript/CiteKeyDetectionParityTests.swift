//
//  CiteKeyDetectionParityTests.swift
//  PublicationManagerCoreTests
//
//  macOS hover and iOS long press must answer "which cite key is here?"
//  identically. They used to answer differently: iOS asked the Rust scanner via
//  `ManuscriptCiteKeyLocator`, while the macOS hover carried its own Swift
//  scanner (`CiteKeyAtLocation` in `CiteKeyHoverPreview.swift`) that treated
//  `@param` annotations and the domain half of an e-mail address as citations.
//
//  Parity is now STRUCTURAL rather than coincidental — one detector, two
//  probes — so this suite asserts it in both registers:
//
//    1. Behaviourally, over one shared fixture, offset by offset, through the
//       macOS probe (`atUTF16Offset`) and the iOS probe (`nearUTF16Offset`).
//    2. Structurally, that no second copy of the grammar exists in Swift and
//       that both platform hit-test sites call the locator. Neither platform
//       entry point is reachable from `swift test` (one wants an NSTextView in
//       a window, the other a UITextView), so the guarantee that the shared
//       detector is what actually runs has to be asserted against the sources.
//

import XCTest
@testable import PublicationManagerCore

final class CiteKeyDetectionParityTests: XCTestCase {

    // MARK: - The shared fixture

    /// One buffer carrying every case the two implementations used to disagree
    /// about, plus the cases they agreed on (so a regression that breaks
    /// ordinary citations fails here too).
    private static let typstFixture = """
    = Draft

    Compare @einstein1905 with @bohr1913, and see @abc and @abcdef.
    @param is an annotation, so is @available, and write to ada@example.org.
    Trailing citation: @heisenberg1927
    """

    private static let latexFixture =
        "We cite \\cite{smith24} and \\citep{a2020, b2021} here."

    /// Keys the canonical scanner finds in `typstFixture` — the yardstick both
    /// probes are measured against.
    private func enumeratedKeys(_ source: String, _ format: DocumentFormat) -> [String] {
        ManuscriptCiteKeyLocator.allCiteKeys(in: source, format: format).map(\.key)
    }

    // MARK: - 1. Behavioural parity, offset by offset

    /// The macOS probe and the iOS probe must agree at every offset where the
    /// macOS probe finds anything. The iOS probe may find MORE (that is its
    /// job — the touch-tolerant retry at `offset - 1` recovers the caret
    /// position one past a citation), but it must never find something
    /// DIFFERENT where the macOS probe already has an answer.
    func testBothPlatformProbesAgreeAtEveryOffsetOfTheSharedFixture() {
        for (source, format) in [
            (Self.typstFixture, DocumentFormat.typst),
            (Self.typstFixture, .markdown),
            (Self.latexFixture, .latex),
        ] {
            let length = (source as NSString).length
            for offset in 0..<length {
                let macOS = ManuscriptCiteKeyLocator.citeKey(
                    in: source, atUTF16Offset: offset, format: format)
                let iOS = ManuscriptCiteKeyLocator.citeKey(
                    in: source, nearUTF16Offset: offset, format: format)
                guard let macOS else { continue }
                XCTAssertEqual(
                    Optional(macOS), iOS,
                    """
                    \(format) offset \(offset): macOS hover sees \
                    \(macOS.key) but iOS long press sees \
                    \(iOS.map(\.key) ?? "nothing")
                    """)
            }
        }
    }

    /// The iOS probe's extra reach is EXACTLY the one-past-the-end caret
    /// position, never a second citation invented two characters away.
    func testTheIOSProbeOnlyAddsTheOnePastTheEndCaretPosition() {
        let source = Self.typstFixture
        let ns = source as NSString
        for offset in 0..<ns.length where ManuscriptCiteKeyLocator.citeKey(
            in: source, atUTF16Offset: offset, format: .typst) == nil {
            guard let recovered = ManuscriptCiteKeyLocator.citeKey(
                in: source, nearUTF16Offset: offset, format: .typst) else { continue }
            XCTAssertEqual(
                recovered.hitRange.upperBound, offset,
                """
                offset \(offset) is not on a citation; the touch probe may only \
                recover the citation ending exactly here, not \(recovered.key)
                """)
        }
    }

    // MARK: - 2. The cases the deleted Swift scanner got wrong

    /// `@param`, `@available` and friends are annotations. The deleted
    /// `CiteKeyAtLocation.findTypst` returned a key for every one of these
    /// offsets, so the hover popped a preview for a non-citation.
    func testAnnotationsAreNotCitationsAtAnyOffsetOnEitherProbe() {
        for annotation in ["@param x", "@example x", "@deprecated x", "@available x"] {
            let ns = annotation as NSString
            let keyEnd = ns.range(of: " ").location
            for offset in 0..<keyEnd {
                XCTAssertNil(
                    ManuscriptCiteKeyLocator.citeKey(
                        in: annotation, atUTF16Offset: offset, format: .typst),
                    "macOS hover previews \(annotation) offset \(offset) as a citation")
                XCTAssertNil(
                    ManuscriptCiteKeyLocator.citeKey(
                        in: annotation, nearUTF16Offset: offset, format: .typst),
                    "iOS long press inspects \(annotation) offset \(offset) as a citation")
            }
        }
    }

    /// `ada@example.org` is an address. The deleted scanner walked back from
    /// `example` to the `@` and answered "example" — a cite key that is not
    /// there.
    func testEmailAddressesAreNotCitationsAtAnyOffsetOnEitherProbe() {
        let source = "write to ada@example.org for details"
        let ns = source as NSString
        let at = ns.range(of: "@").location
        // The whole `@example.org` span, i.e. everything the old backwards `@`
        // walk would have claimed.
        for offset in at...(at + 11) {
            XCTAssertNil(
                ManuscriptCiteKeyLocator.citeKey(
                    in: source, atUTF16Offset: offset, format: .typst),
                "macOS hover reads offset \(offset) of an e-mail address as a citation")
            XCTAssertNil(
                ManuscriptCiteKeyLocator.citeKey(
                    in: source, nearUTF16Offset: offset, format: .typst),
                "iOS long press reads offset \(offset) of an e-mail address as a citation")
        }
    }

    /// Positive control for the two tests above: the fixture's REAL citations
    /// are still found, so "nothing is ever a citation" cannot pass this suite.
    func testTheFixturesRealCitationsAreStillFound() {
        XCTAssertEqual(
            Set(enumeratedKeys(Self.typstFixture, .typst)),
            ["einstein1905", "bohr1913", "abc", "abcdef", "heisenberg1927"],
            "annotations and the e-mail are excluded by the scanner, not by the app")
        XCTAssertEqual(
            enumeratedKeys(Self.latexFixture, .latex), ["smith24", "a2020", "b2021"])
    }

    // MARK: - Anchor convention (what the macOS hover passes to the popover)

    /// The macOS hover anchors the popover to `hitRange`, and iOS selects
    /// `hitRange` on long press — so both platforms highlight the same glyphs.
    /// For Typst that INCLUDES the `@`; for LaTeX it is the bare key inside the
    /// braces. This is the one user-visible delta from the migration: the old
    /// hover anchored to the key alone, one glyph narrower on Typst.
    func testHitRangeIsTheWholeTokenOnTypstAndTheBareKeyOnLatex() {
        let typst = "see @abc."
        let typstHit = ManuscriptCiteKeyLocator.citeKey(
            in: typst, atUTF16Offset: 5, format: .typst)
        XCTAssertEqual((typst as NSString).substring(with: typstHit!.hitRange), "@abc")
        XCTAssertEqual((typst as NSString).substring(with: typstHit!.keyRange), "abc")

        let latex = "We cite \\cite{smith24}."
        let latexHit = ManuscriptCiteKeyLocator.citeKey(
            in: latex, atUTF16Offset: 15, format: .latex)
        XCTAssertEqual((latex as NSString).substring(with: latexHit!.hitRange), "smith24")
        XCTAssertEqual(latexHit!.hitRange, latexHit!.keyRange, "LaTeX has no sigil to include")
    }

    // MARK: - 3. Structural: one grammar, and both platforms use it

    func testNoSecondCiteKeyGrammarSurvivesInSwift() throws {
        // CODE, not prose: several files name the deleted scanner in a comment
        // explaining why it is gone, and those tombstones are the point.
        let offenders = try Self.swiftSources()
            .filter { url in
                try Self.strippingLineComments(String(contentsOf: url, encoding: .utf8))
                    .contains("CiteKeyAtLocation")
            }
            .map(\.lastPathComponent)
        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(offenders) still reference `CiteKeyAtLocation`, the hand-rolled \
            Swift cite-key scanner. It was deleted because it disagreed with \
            the canonical Rust scanner about `@param` and e-mail addresses. \
            Hit-testing goes through `ManuscriptCiteKeyLocator`.
            """)
    }

    func testBothPlatformHitTestSitesCallTheSharedLocator() throws {
        // macOS hover and iOS long press. If either stops calling the locator,
        // the behavioural parity above stops describing the shipping app.
        for (relativePath, affordance) in [
            ("Manuscript/Editor/SourceEditorView.swift", "the macOS hover"),
            ("SharedViews/IOSSourceEditorView.swift", "the iOS long press"),
        ] {
            let text = try String(
                contentsOf: Self.sourcesRoot.appendingPathComponent(relativePath),
                encoding: .utf8)
            XCTAssertTrue(
                text.contains("ManuscriptCiteKeyLocator.citeKey("),
                "\(relativePath) hit-tests \(affordance) without the shared locator")
        }
    }

    // MARK: - Helpers

    /// Drops `//` line comments so a source scan sees declarations and calls
    /// rather than the comments that discuss them. (This codebase does not use
    /// `/* */` blocks; a string literal containing `//` would be a false
    /// negative, which is the safe direction for a guard like this.)
    private static func strippingLineComments(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func swiftSources() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil) else { return [] }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    /// `<package>/Sources/PublicationManagerCore`, derived from this test's own
    /// path so the suite is location-independent.
    private static let sourcesRoot: URL = {
        URL(fileURLWithPath: #filePath)      // …/Tests/PublicationManagerCoreTests/Manuscript/<this>
            .deletingLastPathComponent()      // …/Manuscript
            .deletingLastPathComponent()      // …/PublicationManagerCoreTests
            .deletingLastPathComponent()      // …/Tests
            .deletingLastPathComponent()      // …/PublicationManagerCore
            .appendingPathComponent("Sources/PublicationManagerCore")
    }()
}

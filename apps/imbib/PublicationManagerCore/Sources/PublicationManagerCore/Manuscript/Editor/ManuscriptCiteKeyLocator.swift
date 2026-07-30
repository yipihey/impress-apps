//
//  ManuscriptCiteKeyLocator.swift
//  PublicationManagerCore
//
//  "Which cite key is under this caret / finger?" — the question behind
//  imprint's citation-inspection affordances (hover on macOS, long-press on
//  iOS).
//
//  Every answer here comes from Rust. `ImprintCore.citeKeyAtUtf16Offset` is a
//  thin UniFFI wrapper over `imprint_core::citations::hit`, which is itself
//  derived from `imprint_core::citations::extract` — the canonical cite-key
//  scanner that also backs the compile-time bibliography, the usage index and
//  the `imprint-text-service_extract-cite-key-usages` MCP tool. Nothing in this
//  file knows that Typst citations start with `@`, that LaTeX ones live inside
//  braces, that `@param` is an annotation rather than a citation, or that
//  `ada@example.org` is an email address. That is the point: this detection
//  CANNOT drift from the scanner, because it does not contain a second copy of
//  the grammar to drift from.
//
//  BOTH platform affordances now come through here: the macOS hover
//  (`SourceEditorNSTextView.handleHover`, strict `atUTF16Offset` — a pointer is
//  exactly where the user put it) and the iOS long press
//  (`IOSSourceEditorView`, `nearUTF16Offset` — a finger is not). The hover's
//  hand-rolled `CiteKeyAtLocation` scanner was deleted when it migrated;
//  `CiteKeyDetectionParityTests` asserts no second grammar comes back.
//

import Foundation
import ImprintCore

// MARK: - Occurrence

/// One cite-key occurrence located in a manuscript source buffer.
///
/// Both ranges are UTF-16 `NSRange`s, i.e. directly usable with
/// `UITextView.selectedRange`, `NSTextView.firstRect(forCharacterRange:)` and
/// `NSString` — the offsets are converted from Rust byte offsets on the Rust
/// side, so no index arithmetic over a foreign encoding happens in Swift.
public struct CiteKeyOccurrence: Equatable, Sendable {
    /// The cite key as written, without the `@` sigil or the `\cite{}` wrapper.
    public let key: String
    /// Which citation command produced it: `typst-at`, `cite`, `citep`,
    /// `citet`, `cite-author-year`, `cite-other`, `textcite`, `parencite`,
    /// `autocite`, `other-biblatex`.
    public let command: String
    /// Range of the KEY text — what to replace when renaming a citation.
    public let keyRange: NSRange
    /// Range of the span that counts as "on the citation" for a pointer or
    /// touch hit-test. Includes the Typst `@`; equals `keyRange` for LaTeX.
    /// This is what to anchor a popover to.
    public let hitRange: NSRange

    init(_ hit: FfiCiteKeyHit) {
        self.key = hit.key
        self.command = hit.command
        self.keyRange = NSRange(location: Int(hit.keyOffset), length: Int(hit.keyLength))
        self.hitRange = NSRange(location: Int(hit.hitOffset), length: Int(hit.hitLength))
    }
}

// MARK: - Locator

/// Cite-key hit-testing over a manuscript source buffer.
public enum ManuscriptCiteKeyLocator {

    /// The `syntax` argument the Rust scanner expects for a document format,
    /// or nil when the format has no citations at all.
    ///
    /// Markdown maps to Typst because imprint's Markdown manuscripts use the
    /// same `@key` citation form — the stance the macOS hover already takes.
    static func syntaxName(for format: DocumentFormat) -> String? {
        switch format {
        case .typst, .markdown: return "typst"
        case .latex: return "latex"
        case .plaintext: return nil
        }
    }

    /// The cite key whose span covers `offset`, or nil.
    ///
    /// `offset` is a UTF-16 code-unit index (an `NSRange.location`). The span
    /// is half-open, so a caret sitting immediately AFTER `@smith2024` is not a
    /// hit — it is after the citation. For touch, use
    /// ``citeKey(in:nearUTF16Offset:format:)`` instead.
    public static func citeKey(
        in source: String,
        atUTF16Offset offset: Int,
        format: DocumentFormat
    ) -> CiteKeyOccurrence? {
        guard let syntax = syntaxName(for: format), offset >= 0 else { return nil }
        guard let hit = ImprintCore.citeKeyAtUtf16Offset(
            source: source,
            utf16Offset: UInt32(offset),
            syntax: syntax
        ) else { return nil }
        return CiteKeyOccurrence(hit)
    }

    /// Touch-tolerant hit test: probes `offset`, then `offset - 1`.
    ///
    /// `UITextView.closestPosition(to:)` answers with the nearest *caret*
    /// position, not the character that was touched — a finger on the right
    /// half of the final `4` in `@smith2024` yields the offset one PAST the
    /// citation. Probing one to the left recovers that case. This is index
    /// arithmetic, not grammar: both probes ask Rust the same question.
    public static func citeKey(
        in source: String,
        nearUTF16Offset offset: Int,
        format: DocumentFormat
    ) -> CiteKeyOccurrence? {
        if let hit = citeKey(in: source, atUTF16Offset: offset, format: format) {
            return hit
        }
        guard offset > 0 else { return nil }
        return citeKey(in: source, atUTF16Offset: offset - 1, format: format)
    }

    /// Every cite-key occurrence in `source`, in source order.
    public static func allCiteKeys(
        in source: String,
        format: DocumentFormat
    ) -> [CiteKeyOccurrence] {
        guard let syntax = syntaxName(for: format) else { return [] }
        return ImprintCore.citeKeyHits(source: source, syntax: syntax)
            .map(CiteKeyOccurrence.init)
    }
}

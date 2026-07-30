//
//  SectionExtractor.swift
//  imprint
//
//  Extract section boundaries from a manuscript source file.
//
//  Sections are defined by headings — Typst `= Title` / `== Subtitle` or LaTeX
//  `\section{Title}` / `\subsection{Title}`. A section runs from its heading
//  line up to the next heading (of any level) or end of file.
//
//  Each section gets a deterministic UUID derived from the document id plus
//  the heading's normalized title plus its order index — stable across
//  edits to body content, unstable only when a heading is added, removed,
//  or renamed. That's the right level of stability for agent workflows:
//  agents refer to sections by id across turns, and the id naturally
//  rebinds when you rename a heading.
//
//  Stage 7 item 6: the heading scanners, the section-type classifier and the
//  id derivation moved to `imprint_core::sections`, alongside the section STORE
//  (`imprint_service::sections`) that persists these ids as row ids. What is
//  left here is the shim: the same public API, so the ~15 call sites across
//  imbib and imprint do not change, over `extractSections` / `sectionIdFor`.
//
//  The ids are the whole reason this is a careful port rather than a rewrite —
//  they are persisted, so a derivation change does not error, it silently
//  orphans every existing `manuscript-section` row.
//  `crates/imprint-core/tests/golden_parity.rs` compares the full id set of
//  every fixture document against output captured from the Swift
//  implementation, plus ten id-derivation cases on their own. The subtle part
//  is that Swift's `UUID.uuidString` is UPPERCASE and Rust's is not; the digest
//  differs completely if you forget.
//

import Foundation
import ImprintCore

/// A section extracted from a manuscript source.
public struct ExtractedSection: Sendable, Equatable {
    /// Stable identifier derived from `(documentID, normalized title, order index)`.
    public let id: UUID

    /// Section title (heading text, without leading `=` or `\section{}`).
    public let title: String

    /// Heading level. Typst: number of `=`. LaTeX: 1 for `\section`, 2 for `\subsection`, etc.
    public let level: Int

    /// `Character` offset where the section starts (inclusive) — the heading line.
    ///
    /// **Character, not UTF-16.** Use this against `Array(source)`,
    /// `String.index(_:offsetBy:)` or `source.count`; use ``startUTF16`` for
    /// anything in `NSRange` terms (`NSString`, `NSTextView`, `UITextView`).
    /// The two agree only for ASCII source.
    public let start: Int

    /// `Character` offset where the section ends (exclusive) — start of the next heading or EOF.
    public let end: Int

    /// `Character` offset of the body start — first character after the heading line.
    public let bodyStart: Int

    /// ``start`` in UTF-16 code units — an `NSRange` location.
    public let startUTF16: Int

    /// ``end`` in UTF-16 code units.
    public let endUTF16: Int

    /// ``bodyStart`` in UTF-16 code units.
    public let bodyStartUTF16: Int

    /// Zero-based position of this section among all headings in the source.
    public let orderIndex: Int

    /// Semantic classification derived from the heading title
    /// ("introduction", "methods", "results", "discussion", "abstract", …) or `nil`.
    public let sectionType: String?

    /// Approximate word count of the section body.
    public let wordCount: Int

    init(_ ffi: FfiExtractedSection) {
        self.id = UUID(uuidString: ffi.id) ?? UUID()
        self.title = ffi.title
        self.level = Int(ffi.level)
        self.start = Int(ffi.start)
        self.end = Int(ffi.end)
        self.bodyStart = Int(ffi.bodyStart)
        self.startUTF16 = Int(ffi.startUtf16)
        self.endUTF16 = Int(ffi.endUtf16)
        self.bodyStartUTF16 = Int(ffi.bodyStartUtf16)
        self.orderIndex = Int(ffi.orderIndex)
        self.sectionType = ffi.sectionType
        self.wordCount = Int(ffi.wordCount)
    }
}

/// Document format used for heading detection.
public enum SectionFormat: Sendable {
    case typst
    case latex

    /// The lowercase name the Rust `imprint-core` composition/extraction
    /// functions expect for their `format`/`syntax` string parameter.
    public var rustName: String {
        switch self {
        case .typst: return "typst"
        case .latex: return "latex"
        }
    }

    /// Auto-detect from source content. Defaults to `.typst` when ambiguous.
    public static func autoDetect(_ source: String) -> SectionFormat {
        detectSectionFormat(source: source) == "latex" ? .latex : .typst
    }
}

public enum SectionExtractor {

    /// Extract every section from the source. Returned in document order.
    public static func extract(
        from source: String,
        documentID: UUID,
        format: SectionFormat? = nil
    ) -> [ExtractedSection] {
        extractSections(
            source: source,
            documentId: documentID.uuidString,
            format: format?.rustName
        )
        .map(ExtractedSection.init)
    }

    /// Find the section with the given id in the source.
    public static func find(
        id sectionID: UUID,
        in source: String,
        documentID: UUID,
        format: SectionFormat? = nil
    ) -> ExtractedSection? {
        extract(from: source, documentID: documentID, format: format)
            .first { $0.id == sectionID }
    }

    /// Find the section with the given order index.
    public static func find(
        index: Int,
        in source: String,
        documentID: UUID,
        format: SectionFormat? = nil
    ) -> ExtractedSection? {
        let all = extract(from: source, documentID: documentID, format: format)
        guard index >= 0, index < all.count else { return nil }
        return all[index]
    }

    /// The deterministic id a section with this `(document, title, order index)`
    /// would have — for callers that need the id *before* the source re-parses.
    ///
    /// SHA-256 of `manuscript-section:<UPPERCASE doc uuid>:<index>:<lowercased,
    /// trimmed title>`, truncated to 16 bytes with the RFC 4122 version (5) and
    /// variant bits set. Frozen: these are persisted row ids.
    public static func sectionID(documentID: UUID, title: String, orderIndex: Int) -> UUID {
        UUID(uuidString: sectionIdFor(
            documentId: documentID.uuidString,
            title: title,
            orderIndex: UInt32(max(0, orderIndex))
        )) ?? UUID()
    }
}

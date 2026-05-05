//
//  SectionExtractor.swift
//  imprint
//
//  Extract section boundaries from a manuscript source file.
//
//  Sections are defined by headings — Typst `= Title` / `== Subtitle` or LaTeX
//  `\section{Title}` / `\subsection{Title}`. A section runs from its heading
//  line up to the next heading of equal-or-lower level (or end of file).
//
//  Each section gets a deterministic UUID derived from the document id plus
//  the heading's normalized title plus its order index — stable across
//  edits to body content, unstable only when a heading is added, removed,
//  or renamed. That's the right level of stability for agent workflows:
//  agents refer to sections by id across turns, and the id naturally
//  rebinds when you rename a heading.
//

import Foundation
import CommonCrypto

/// A section extracted from a manuscript source.
public struct ExtractedSection: Sendable, Equatable {
    /// Stable identifier derived from `(documentID, normalized title, order index)`.
    public let id: UUID

    /// Section title (heading text, without leading `=` or `\section{}`).
    public let title: String

    /// Heading level. Typst: number of `=`. LaTeX: 1 for `\section`, 2 for `\subsection`, etc.
    public let level: Int

    /// Character offset where the section starts (inclusive) — the heading line.
    public let start: Int

    /// Character offset where the section ends (exclusive) — start of the next heading or EOF.
    public let end: Int

    /// Character offset of the body start — first character after the heading line.
    public let bodyStart: Int

    /// Zero-based position of this section among all headings in the source.
    public let orderIndex: Int

    /// Semantic classification derived from the heading title
    /// ("introduction", "methods", "results", "discussion", "abstract", …) or `nil`.
    public let sectionType: String?

    /// Approximate word count of the section body.
    public let wordCount: Int
}

/// Document format used for heading detection.
public enum SectionFormat: Sendable {
    case typst
    case latex

    /// Auto-detect from source content. Defaults to `.typst` when ambiguous.
    public static func autoDetect(_ source: String) -> SectionFormat {
        // LaTeX documents almost always start with \documentclass or have
        // \begin{document}. Typst documents use #import or bare content.
        if source.contains("\\documentclass") || source.contains("\\begin{document}") {
            return .latex
        }
        return .typst
    }
}

public enum SectionExtractor {

    /// Extract every section from the source. Returned in document order.
    public static func extract(
        from source: String,
        documentID: UUID,
        format: SectionFormat? = nil
    ) -> [ExtractedSection] {
        let fmt = format ?? .autoDetect(source)
        let headings = findHeadings(in: source, format: fmt)
        guard !headings.isEmpty else { return [] }

        var sections: [ExtractedSection] = []
        for (idx, h) in headings.enumerated() {
            let end = idx + 1 < headings.count ? headings[idx + 1].start : source.count
            let bodyText = slice(source, start: h.bodyStart, end: end)
            let wordCount = countWords(bodyText)
            let id = sectionID(documentID: documentID, title: h.title, orderIndex: idx)
            sections.append(ExtractedSection(
                id: id,
                title: h.title,
                level: h.level,
                start: h.start,
                end: end,
                bodyStart: h.bodyStart,
                orderIndex: idx,
                sectionType: classifySectionType(h.title),
                wordCount: wordCount
            ))
        }
        return sections
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

    // MARK: - Heading scanning

    private struct Heading {
        let title: String
        let level: Int
        let start: Int      // line start (char offset)
        let bodyStart: Int  // first char after heading line
    }

    private static func findHeadings(in source: String, format: SectionFormat) -> [Heading] {
        switch format {
        case .typst: return typstHeadings(in: source)
        case .latex: return latexHeadings(in: source)
        }
    }

    private static func typstHeadings(in source: String) -> [Heading] {
        var result: [Heading] = []
        var lineStart = 0
        let chars = Array(source)

        while lineStart < chars.count {
            // Find end of this line
            var lineEnd = lineStart
            while lineEnd < chars.count, chars[lineEnd] != "\n" {
                lineEnd += 1
            }

            // Skip any leading whitespace
            var idx = lineStart
            while idx < lineEnd, chars[idx].isWhitespace {
                idx += 1
            }

            // Count leading `=` signs
            var level = 0
            while idx < lineEnd, chars[idx] == "=" {
                level += 1
                idx += 1
            }

            // A real heading has `=`(s) followed by a space then text
            if level > 0, level <= 6, idx < lineEnd, chars[idx] == " " {
                let titleStart = idx + 1
                let rawTitle = String(chars[titleStart..<lineEnd])
                let title = rawTitle.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    let bodyStart = lineEnd < chars.count ? lineEnd + 1 : lineEnd
                    result.append(Heading(
                        title: title,
                        level: level,
                        start: lineStart,
                        bodyStart: bodyStart
                    ))
                }
            }

            lineStart = lineEnd + 1
        }
        return result
    }

    private static func latexHeadings(in source: String) -> [Heading] {
        var result: [Heading] = []
        let levels: [(String, Int)] = [
            ("\\section", 1),
            ("\\subsection", 2),
            ("\\subsubsection", 3),
            ("\\paragraph", 4),
            ("\\subparagraph", 5)
        ]

        let chars = Array(source)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\" else { i += 1; continue }
            var matched: (String, Int)? = nil
            for (prefix, lvl) in levels {
                let end = i + prefix.count
                if end <= chars.count, String(chars[i..<end]) == prefix {
                    // Must be followed by `{` or `*{`
                    var after = end
                    if after < chars.count, chars[after] == "*" { after += 1 }
                    if after < chars.count, chars[after] == "{" {
                        matched = (prefix, lvl)
                        i = after
                        break
                    }
                }
            }
            guard let (_, lvl) = matched else {
                i += 1
                continue
            }
            // i currently points at `{` — scan until matching `}` with brace depth
            let braceStart = i + 1
            var depth = 1
            var j = braceStart
            while j < chars.count, depth > 0 {
                if chars[j] == "{" { depth += 1 }
                else if chars[j] == "}" { depth -= 1 }
                if depth > 0 { j += 1 }
            }
            let title = String(chars[braceStart..<j]).trimmingCharacters(in: .whitespaces)
            // Heading "line" in LaTeX is the whole `\section{...}` token; move
            // bodyStart past any trailing newline so the body begins cleanly.
            var bodyStart = j + 1  // after the `}`
            if bodyStart < chars.count, chars[bodyStart] == "\n" { bodyStart += 1 }
            // Walk back to the start of the line containing the `\section`
            var lineStart = i
            while lineStart > 0, chars[lineStart - 1] != "\n" {
                lineStart -= 1
            }
            // Step back past the `\sectionN{` we landed on — we want the
            // backslash, not the opening brace.
            while lineStart < chars.count, chars[lineStart] == " " || chars[lineStart] == "\t" {
                lineStart += 1
            }
            if !title.isEmpty {
                result.append(Heading(
                    title: title,
                    level: lvl,
                    start: lineStart,
                    bodyStart: bodyStart
                ))
            }
            i = bodyStart
        }
        return result
    }

    // MARK: - Helpers

    private static func slice(_ source: String, start: Int, end: Int) -> String {
        let chars = Array(source)
        let lo = max(0, min(start, chars.count))
        let hi = max(lo, min(end, chars.count))
        return String(chars[lo..<hi])
    }

    private static func countWords(_ text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    private static func classifySectionType(_ title: String) -> String? {
        let normalized = title.lowercased().trimmingCharacters(in: .whitespaces)
        let keywords: [(String, [String])] = [
            ("abstract", ["abstract"]),
            ("introduction", ["introduction", "intro"]),
            ("background", ["background", "related work"]),
            ("methods", ["methods", "methodology", "approach", "experimental setup"]),
            ("results", ["results", "findings", "experiments", "experimental results"]),
            ("discussion", ["discussion", "analysis"]),
            ("conclusion", ["conclusion", "conclusions", "summary"]),
            ("acknowledgements", ["acknowledgement", "acknowledgements", "acknowledgment", "acknowledgments"]),
            ("references", ["references", "bibliography"]),
            ("appendix", ["appendix", "appendices"])
        ]
        for (kind, patterns) in keywords {
            if patterns.contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") || normalized.hasSuffix(" " + $0) }) {
                return kind
            }
        }
        return nil
    }

    /// Deterministic UUID-v5-ish id for a section — SHA-256 truncated to 16
    /// bytes, version/variant bits set per RFC 4122.
    public static func sectionID(documentID: UUID, title: String, orderIndex: Int) -> UUID {
        let normalized = title.lowercased().trimmingCharacters(in: .whitespaces)
        let composed = "manuscript-section:\(documentID.uuidString):\(orderIndex):\(normalized)"
        guard let data = composed.data(using: .utf8) else { return UUID() }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &digest)
        }
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

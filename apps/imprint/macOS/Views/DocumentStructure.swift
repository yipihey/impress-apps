import Foundation

/// A structural element of the manuscript source with its character range,
/// used to draw Mathematica-style cell brackets in the editor's right margin.
/// Levels: heading nesting (chapter → section → subsection → …) and, deepest,
/// paragraphs (blank-line split).
struct StructureNode: Equatable {
    enum Kind: Equatable { case section, paragraph }
    /// Character range in the source (NSRange semantics, i.e. UTF-16 offsets —
    /// matches what the NSTextView layout manager expects). For typical ASCII
    /// LaTeX/Typst source this equals the Character offsets from SectionExtractor.
    let range: NSRange
    /// Nesting depth (0 = outermost, closest to the margin). Drives how far the
    /// bracket is indented: deeper elements sit further left.
    let level: Int
    let kind: Kind
}

/// Builds the hierarchical structure (sections → paragraphs) for cell brackets.
enum DocumentStructure {

    /// Produce structure nodes for `source`. Headings come from
    /// `SectionExtractor` and are turned into a *true* nesting hierarchy
    /// (a chapter/section bracket encloses all of its subsections), with
    /// paragraphs — non-blank runs split on blank lines — as the deepest level.
    static func build(source: String, format: SectionFormat) -> [StructureNode] {
        guard !source.isEmpty else { return [] }
        let ns = source as NSString
        let total = ns.length
        var nodes: [StructureNode] = []

        // SectionExtractor needs a documentID; the value is irrelevant to ranges.
        let sections = SectionExtractor.extract(from: source, documentID: UUID(), format: format)

        if sections.isEmpty {
            // No headings: the whole document is a flat list of paragraphs.
            return paragraphNodes(in: ns, range: NSRange(location: 0, length: total), level: 0)
        }

        // Normalize heading levels so the shallowest heading present becomes
        // depth 0 (outermost bracket). Handles docs that start at \subsection
        // or use only `==` in Typst.
        let minLevel = sections.map { $0.level }.min() ?? 1

        // Preamble before the first heading (imports, \documentclass, title,
        // abstract environment …) — flat paragraphs at the outermost depth.
        let firstStart = min(max(0, sections[0].start), total)
        if firstStart > 0 {
            nodes.append(contentsOf: paragraphNodes(in: ns, range: NSRange(location: 0, length: firstStart), level: 0))
        }

        for (idx, section) in sections.enumerated() {
            let start = min(max(0, section.start), total)
            let depth = section.level - minLevel

            // A heading encloses everything up to the next heading of
            // equal-or-shallower level — so its bracket wraps all descendant
            // subsections (true nesting), not just its own paragraphs.
            var enclosingEnd = total
            var j = idx + 1
            while j < sections.count {
                if sections[j].level <= section.level {
                    enclosingEnd = min(max(start, sections[j].start), total)
                    break
                }
                j += 1
            }
            nodes.append(StructureNode(range: NSRange(location: start, length: enclosingEnd - start),
                                       level: depth,
                                       kind: .section))

            // The heading's *own* body paragraphs run only until the next
            // heading of ANY level (deeper headings own the text past that).
            let ownEnd = (idx + 1 < sections.count)
                ? min(max(start, sections[idx + 1].start), total)
                : total
            let bodyStart = min(max(start, section.bodyStart), ownEnd)
            if bodyStart < ownEnd {
                nodes.append(contentsOf: paragraphNodes(
                    in: ns,
                    range: NSRange(location: bodyStart, length: ownEnd - bodyStart),
                    level: depth + 1
                ))
            }
        }
        return nodes
    }

    /// Split `range` of `ns` into paragraph nodes: maximal runs of non-blank
    /// lines, separated by one or more blank lines. Leading/trailing blank
    /// space is trimmed from each paragraph's range.
    private static func paragraphNodes(in ns: NSString, range: NSRange, level: Int) -> [StructureNode] {
        var result: [StructureNode] = []
        let end = range.location + range.length
        var i = range.location
        while i < end {
            // Skip blank lines (whitespace-only) to find a paragraph start.
            while i < end, isBlankLine(ns, at: i, limit: end) {
                i = lineEnd(ns, at: i, limit: end)
            }
            if i >= end { break }
            let paraStart = i
            // Consume non-blank lines until a blank line or the range end.
            while i < end, !isBlankLine(ns, at: i, limit: end) {
                i = lineEnd(ns, at: i, limit: end)
            }
            // Trim a trailing newline from the paragraph range for a tight bracket.
            var paraEnd = i
            while paraEnd > paraStart, ns.character(at: paraEnd - 1) == 10 /* \n */ {
                paraEnd -= 1
            }
            if paraEnd > paraStart {
                result.append(StructureNode(
                    range: NSRange(location: paraStart, length: paraEnd - paraStart),
                    level: level,
                    kind: .paragraph
                ))
            }
        }
        return result
    }

    /// Index just past the end of the line containing `at` (past its `\n`).
    private static func lineEnd(_ ns: NSString, at: Int, limit: Int) -> Int {
        var j = at
        while j < limit, ns.character(at: j) != 10 { j += 1 }
        return min(j + 1, limit) // include the newline
    }

    /// True if the line starting at `at` contains only whitespace.
    private static func isBlankLine(_ ns: NSString, at: Int, limit: Int) -> Bool {
        var j = at
        while j < limit {
            let c = ns.character(at: j)
            if c == 10 { return true }              // reached EOL with only ws
            if c != 32 && c != 9 && c != 13 { return false } // non-ws char
            j += 1
        }
        return true // trailing whitespace to EOF
    }
}
